#!/bin/bash
#------------------------------------------------------------------------------
# @description Live token burn of this box's lanes (spec 140 section 2, tasks
# @description T020-T022): one incremental tick. It reads only the bytes the
# @description transcripts grew by since the last tick (byte offset per file,
# @description reset to 0 on a new inode or a shorter file), sums them into
# @description one bucket per agent and UTC minute, and pushes the buckets that
# @description changed as `spool fleet-tokens push --json -` (lane_op
# @description fleet_tokens_push, spec 140 section 3.4) over the box's hub
# @description connection. Claude: the shared spec 123 parse
# @description (spl_cost_tokens_jq_def), MAX per message.id. Mistral (vibe) and
# @description grok: their per-session cumulative counters (vibe journal
# @description tokenUsage, grok usage.json), so a vibe compaction loses or
# @description doubles nothing. agy and qwen lanes with a live pane: one
# @description unmetered sample a minute, never 0 tokens. A bucket carries the
# @description minute's full totals (the hub replaces on its natural key), and
# @description stays queued until a push is acked. Stdout carries counts and
# @description the tick's milliseconds, never a token total.
# @param TOKEN_BURN_STATE_DIR (optional) - default /var/csi/csi-spl/token-burn
# @param TOKEN_BURN_HOMES (optional) - space-separated homes read as the
# @param   current user (tests); default the home of each COST_AGENT_USERS
# @param   user (spl_cost_agent_users), read as that user
# @param TOKEN_BURN_PUSH (optional) - 1 (default) push the changed buckets, 0 queue only
# @param TOKEN_BURN_PUSH_CMD (optional, tests) - replaces `spool fleet-tokens push --json -`
# @param TOKEN_BURN_LIVE_CMD (optional, tests) - prints the live agent ids, one per line
# @example ./run -a do_spl_token_burn_collect
# @example TOKEN_BURN_PUSH=0 ./run -a do_spl_token_burn_collect
#------------------------------------------------------------------------------

declare -F spl_cost_tokens_jq_def >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"

# Seconds a bucket and a late row stay in reach (spec 140 1.1 lag is 60 s);
# the per-id MAX cache keeps 2 h (spec 140 2.4); a transcript is tracked
# while it changed in the last 3 h (one idle longer is read again from 0 when
# it moves: its old rows fall outside the window). Only the first tick lists
# every transcript dir; after it a tick lists the dirs whose mtime moved,
# one slice of the rest (TOKEN_BURN_SLICES, one slice a tick: every dir in
# 10 x 30 s = 5 min) and the subagents dir of each claude session whose
# transcript moved in the last TOKEN_BURN_ACTIVE_S.
TOKEN_BURN_WINDOW_S=3600 TOKEN_BURN_ID_TTL_S=7200 TOKEN_BURN_FILE_MMIN=180
TOKEN_BURN_SLICES="${TOKEN_BURN_SLICES:-10}" TOKEN_BURN_ACTIVE_S="${TOKEN_BURN_ACTIVE_S:-600}"

# A tick forks few processes (flock, the reader, jq only when a transcript
# grew by a usage row, awk twice, mv, rm): on a loaded box every fork waits
# for a core.
do_spl_token_burn_collect() {
  local dir="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}" t0="${EPOCHREALTIME//[.,]/}" now mode rc stats
  now="${TOKEN_BURN_NOW:-$EPOCHSECONDS}"
  [[ -d "$dir/next" ]] || mkdir -p "$dir/next" || { echo "FATAL cannot create $dir" >&2; return 1; }
  exec 9>"$dir/collect.lock"
  flock -n 9 || { echo "SKIP token-burn: another tick holds $dir/collect.lock"; exec 9>&-; return 0; }
  mode=next; [[ -e "$dir/state.v1" ]] || mode=first
  spl_token_burn_tick "$dir" "$now" "$mode"; rc=$?
  (( rc != 0 )) || [[ "$mode" == next ]] || : >"$dir/state.v1"
  exec 9>&-
  (( rc == 0 )) || return "$rc"
  read -r stats <"$dir/tick.stats"
  echo "$stats ms=$(( (${EPOCHREALTIME//[.,]/} - t0) / 1000 ))"
}

# spl_token_burn_tick DIR NOW MODE: read, sum, write the state, push. The
# reader exits 3 when it found usage rows: only then does jq run (it passes
# the file rows through), else the sum reads the reader's rows as they are.
# DIR/scan.since holds the last tick's time and slice; without it (first
# tick, lost state) the tick lists every dir.
spl_token_burn_tick() {
  local dir="$1" now="$2" mode="$3" raw="$1/tick.raw" ev="$1/tick.events" live="$1/tick.live" src s since=0 last slot=-1 rc
  for s in files ids sessions buckets agents; do [[ -e "$dir/$s.tsv" ]] || : >"$dir/$s.tsv" || return 1; done
  if [[ "$mode" == next ]] && read -r last s 2>/dev/null <"$dir/scan.since" && [[ "$last" =~ ^[0-9]+$ && "$s" =~ ^[0-9]+$ ]]; then
    since=$((last - 2)) slot=$(( (s + 1) % TOKEN_BURN_SLICES ))
  fi
  spl_token_burn_read "$dir" "$mode" "$since" "$slot" >"$raw"; rc=$?
  src="$raw"
  if (( rc == 3 )); then
    spl_token_burn_events "$now" <"$raw" >"$ev" || { echo "FATAL token-burn: parsing the new rows failed" >&2; rm -f "$raw" "$ev"; return 1; }
    src="$ev"
  elif (( rc != 0 )); then
    echo "FATAL token-burn: reading the transcripts failed" >&2; rm -f "$raw"; return 1
  fi
  spl_token_burn_agents "$dir" "$src"
  spl_token_burn_live "$dir" "$now" >"$live"
  spl_token_burn_sum "$dir" "$now" "$mode" "$src" "$live" || { echo "FATAL token-burn: summing the tick failed" >&2; rm -f "$raw" "$ev" "$live"; return 1; }
  rm -f "$raw" "$ev" "$live"
  printf '%s %s\n' "$now" "$(( slot < 0 ? 0 : slot ))" >"$dir/scan.since"
  printf ' scan=%s' "$( (( slot < 0 )) && echo full || echo "slice$slot")" >>"$dir/tick.stats"
  spl_token_burn_push "$dir"
}

# spl_token_burn_read DIR MODE SINCE SLOT: the reader (spl_token_burn_reader_py)
# over every home, each as its user (transcripts are mode 600), on
# DIR/files.tsv. Its "F" rows are the next files.tsv, "L" the dirs it
# listed; "R" rows carry a new transcript line, "M" a vibe session's start
# dir, "V" the vibe model. Exit 3: some home had "R" rows, 0: none.
spl_token_burn_read() {
  local dir="$1" row u h rc=0 r TOKEN_BURN_PY
  local -a homes=() args=("$2" "$TOKEN_BURN_FILE_MMIN" "" "$3" "$4" "$TOKEN_BURN_SLICES" "$TOKEN_BURN_ACTIVE_S")
  spl_token_burn_reader_py
  spl_token_burn_homes "$dir"
  for row in "${homes[@]}"; do
    u="${row%% *}" h="${row#* }" args[2]="$h"
    if [[ "$u" == - ]]; then python3 -I -S -c "$TOKEN_BURN_PY" "${args[@]}" <"$dir/files.tsv"; r=$?
    else sudo -n -u "$u" python3 -I -S -c "$TOKEN_BURN_PY" "${args[@]}" <"$dir/files.tsv"; r=$?
    fi
    case "$r" in 0) ;; 3) rc=3 ;; *) return 1 ;; esac
  done
  return "$rc"
}

# spl_token_burn_homes DIR: the caller's homes[] as "<user> <home>" per
# agent user, the user "-" when it is the current one (no sudo), and one
# "- <home>" per TOKEN_BURN_HOMES entry. Cached an hour in DIR/homes.txt
# (first line its epoch): resolving them forks six times.
spl_token_burn_homes() {
  local f="$1/homes.txt" u h me
  if [[ -n "${TOKEN_BURN_HOMES:-}" ]]; then
    for h in $TOKEN_BURN_HOMES; do homes+=("- $h"); done
    return 0
  fi
  [[ -s "$f" ]] && mapfile -t homes <"$f"
  if [[ "${homes[0]:-}" =~ ^[0-9]+$ ]] && (( EPOCHSECONDS - homes[0] < 3600 )); then
    homes=("${homes[@]:1}")
    return 0
  fi
  homes=() me="$(id -un)"
  for u in $(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}"); do
    h="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$h" ]] && homes+=("$([[ "$u" == "$me" ]] && echo - || echo "$u") $h")
  done
  printf '%s\n' "$EPOCHSECONDS" "${homes[@]}" >"$f"
}

# The reader: byte IO and file bookkeeping only, it parses no transcript
# (jq does, below). Per file: seek to the offset, read to the last newline,
# keep the lines that can carry usage. A new inode or a file shorter than
# its offset starts again at 0. MODE first (no state yet) starts every
# jsonl at its end. grok usage.json is small and rewritten whole: re-read
# when its mtime moved. SLOT -1 lists every transcript dir; else only the
# known files are stat'ed, and a dir is listed when its mtime moved since
# SINCE or when it falls in this tick's SLOT of SLICES (crc32 of its name):
# a walk of every dir is ~2700 entries (~0.4 s on a busy box). A claude
# transcript that moved in the last ACTIVE s has its subagents dir listed:
# a subagent's new file does not move any dir the walk would list.
# Sets the caller's TOKEN_BURN_PY: read builtins, no process forked.
spl_token_burn_reader_py() {
  local a b c
  spl_token_burn_reader_py_find
  spl_token_burn_reader_py_read
  spl_token_burn_reader_py_models
  TOKEN_BURN_PY="$a$b$c"
}

# The reader's first half: the state in, the candidate transcripts found.
spl_token_burn_reader_py_find() {
  IFS= read -r -d '' a <<'EOF_PY' || :
import json, os, sys, time, zlib
mode, mmin, home, since, slot, slices, active = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
now = time.time()
cutoff, cap, out, listed, rows = now - mmin * 60, 32 << 20, sys.stdout, [0], [0]
prev, cand = {}, {}
for l in sys.stdin:
    p = l.rstrip("\n").split("\t")
    if len(p) == 4 and p[3].isdigit():
        prev[p[1]] = (p[2], int(p[3]))
        cand[p[1]] = p[0]
def emit(*a):
    out.write("\t".join(a) + "\n")
def ls(d):
    try:
        with os.scandir(d) as it:
            r = list(it)
    except OSError:
        return []
    listed[0] += 1
    return r
def look(name, d):
    if slot < 0 or zlib.crc32(name.encode("utf-8", "surrogateescape")) % slices == slot:
        return True
    try:
        return os.stat(d).st_mtime >= since
    except OSError:
        return False
def jsonl(entries, vendor):
    for f in entries:
        if f.name.endswith(".jsonl"):
            cand[f.path] = vendor
for e in ls(home + "/.claude/projects"):
    if e.is_dir() and look(e.name, e.path):
        sub = ls(e.path)
        jsonl(sub, "claude")
        for s in sub:
            if s.is_dir():
                jsonl(ls(s.path + "/subagents"), "claude")
for e in ls(home + "/.vibe/logs/session/unified"):
    if look(e.name, e.path + "/journal"):
        jsonl(ls(e.path + "/journal"), "mistral")
for e in ls(home + "/.grok/sessions"):
    if e.is_dir() and look(e.name, e.path):
        for s in ls(e.path):
            if s.is_dir():
                cand[s.path + "/usage.json"] = "grok"
for e in ls(home + "/.gemini/antigravity-cli/brain"):
    if e.is_dir() and look(e.name, e.path):
        p = e.path + "/.system_generated/logs/transcript.jsonl"
        if not os.path.exists(p) and os.path.exists(e.path + "/transcript.jsonl"):
            p = e.path + "/transcript.jsonl"
        cand[p] = "agy"
EOF_PY
}

# The reader's second half: each candidate read from its offset.
spl_token_burn_reader_py_read() {
  IFS= read -r -d '' b <<'EOF_PY' || :
def tail(vendor, f, st, needles):
    ino, size, old = str(st.st_ino), st.st_size, prev.get(f)
    if old is None:
        off = size if mode == "first" else 0
    else:
        off = old[1] if old[0] == ino and size >= old[1] else 0
    start = off
    if off < size:
        with open(f, "rb") as fh:
            fh.seek(off)
            data = fh.read(min(size - off, cap))
        cut = data.rfind(b"\n")
        if cut >= 0:
            for line in data[:cut].split(b"\n"):
                if all(n in line for n in needles):
                    emit("R", vendor, f, line.decode("utf-8", "replace"))
                    rows[0] += 1
            off += cut + 1
    emit("F", vendor, f, ino, str(off))
    return off != start
def grok(f, st):
    ino, mt, old = str(st.st_ino), str(st.st_mtime_ns), prev.get(f)
    if old is None or old[0] != ino or str(old[1]) != mt:
        try:
            emit("R", "grok", f, json.dumps(json.load(open(f)), separators=(",", ":")))
            rows[0] += 1
        except (OSError, ValueError):
            pass
    emit("F", "grok", f, ino, mt)
vibe, todo = set(), list(cand.items())
for f, vendor in todo:
    try:
        st = os.stat(f)
    except OSError:
        continue
    if st.st_mtime < cutoff:
        continue
    if vendor == "grok":
        grok(f, st)
    elif vendor == "mistral":
        if tail(vendor, f, st, (b'"tokenUsage"',)):
            vibe.add(os.path.dirname(os.path.dirname(f)))
    elif vendor == "agy":
        tail(vendor, f, st, (b'"PLANNER_RESPONSE"', b'"input_tokens"'))
    else:
        tail(vendor, f, st, (b'"usage"', b'"assistant"'))
        if st.st_mtime >= now - active and "/subagents/" not in f:
            for s in ls(f[:-6] + "/subagents"):
                if s.name.endswith(".jsonl") and s.path not in cand:
                    cand[s.path] = "claude"
                    todo.append((s.path, "claude"))
EOF_PY
}

# The reader's third half: emit vibe and agy metadata.
spl_token_burn_reader_py_models() {
  IFS= read -r -d '' c <<'EOF_PY' || :
for d in vibe:
    try:
        emit("M", "mistral", d, json.load(open(d + "/meta.json")).get("origin_directory") or "")
    except (OSError, ValueError):
        pass
if vibe:
    import re
    try:
        cfg = open(home + "/.vibe/config.toml").read()
        act = re.search(r'^active_model\s*=\s*"([^"]+)"', cfg, re.M)
        names = dict(re.findall(r'name\s*=\s*"([^"]+)"\s*\n\s*alias\s*=\s*"([^"]+)"', cfg))
        alias = {a: n for n, a in names.items()}
        emit("V", "mistral", alias.get(act.group(1), act.group(1)) if act else "unknown")
    except OSError:
        emit("V", "mistral", "unknown")
if any(v == "agy" for _, v in todo):
    import json
    m_name = "gemini-3.8-flash"
    try:
        s_cfg = json.load(open(home + "/.gemini/antigravity-cli/settings.json"))
        raw_m = s_cfg.get("model", "")
        if "flash" in raw_m.lower(): m_name = "gemini-3.8-flash"
        elif "pro" in raw_m.lower(): m_name = "gemini-3.8-pro"
        elif raw_m: m_name = raw_m.lower().replace(" ", "-")
    except Exception:
        pass
    emit("V", "agy", m_name)
emit("L", str(listed[0]))
out.flush()
sys.exit(3 if rows[0] else 0)
EOF_PY
}

# spl_token_burn_events NOW <reader rows: one normalized row per usage:
#   C <path> <message id> <ts> <model> <in> <out> <cache_read> <cache_write>
#   S <vendor> <session> <ts> <model> <in> <out> <cache_read> <cache_write> <created> <path> [<base x4>]
# (S = a session's cumulative counters). F, L, M, V rows pass through. Input
# counts exclude cache reads, as claude's input_tokens do. A grok row adds
# its baseline: the counters of the turns that ended before the window (each
# turn carries its own, and they sum to the session's), empty when a turn
# lacks them.
spl_token_burn_events() {
  jq -R -r --argjson now "$1" --argjson win "$TOKEN_BURN_WINDOW_S" "$(spl_cost_tokens_jq_def)"'
    def epoch: if type == "number" then (if . > 1e11 then ./1000 else . end | floor)
      elif type == "string" then (sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z") | try fromdateiso8601 catch $now)
      else $now end;
    def nz: if type == "number" and . > 0 then floor else 0 end;
    split("\t") as $f |
    if $f[0] != "R" then .
    else ($f[3:] | join("\t") | try fromjson catch null) as $r | select($r != null) |
      if $f[1] == "claude" then
        $r | select(.type == "assistant") | claude_usage_row as $u |
        ["C", $f[2], $u[2], ($r.timestamp | epoch), $u[0], ($u[3] | nz), ($u[4] | nz), ($u[5] | nz), ($u[6] | nz)] | @tsv
      elif $f[1] == "mistral" then
        [$r.payload.delta[]? | .state.session? | select(type == "object" and .tokenUsage != null)] | last |
        select(. != null) | .tokenUsage as $t |
        ["S", "mistral", .id, (.updatedAt | epoch), "", (($t.inputTokens | nz) - ($t.cachedInputTokens | nz) | nz),
         ($t.outputTokens | nz), ($t.cachedInputTokens | nz), 0, (.createdAt | epoch), ($f[2] | split("/journal/")[0])] | @tsv
      elif $f[1] == "agy" then
        $r | select(.type == "PLANNER_RESPONSE") |
        ["A", $f[2], ($f[2] + ":" + (.step_index | tostring)), ($r.created_at | epoch), ($r.model // ""),
         (.input_tokens | nz), (.output_tokens | nz), (.cache_read_tokens | nz), 0] | @tsv
      else
        $r | .session as $s | select($s | type == "object") |
        ["S", "grok", .sessionId, (.updatedAt | epoch), ($s.primaryModelId // ($s.modelUsage // {} | keys | first) // "unknown"),
         (($s.inputTokens | nz) - ($s.cachedReadTokens | nz) | nz), ($s.outputTokens | nz), ($s.cachedReadTokens | nz),
         ($s.cacheCreationTokens | nz), (.turns[0].endedAt // .updatedAt | epoch), $f[2]] +
        ((.turns // []) as $t | if ($t | all(type == "object" and has("inputTokens"))) then
          ($t | map(select((.endedAt | epoch) < $now - $win))) as $o |
          [($o | map((.inputTokens | nz) - (.cachedReadTokens | nz) | nz) | add // 0), ($o | map(.outputTokens | nz) | add // 0),
           ($o | map(.cachedReadTokens | nz) | add // 0), ($o | map(.cacheCreationTokens | nz) | add // 0)]
        else ["", "", "", ""] end) | @tsv
      end
    end'
}

# spl_token_burn_agents DIR EVENTS: the agent of each claude or agy transcript
# not yet in DIR/agents.tsv, cached: one lookup per file.
spl_token_burn_agents() {
  local f vendor
  awk -F'\t' 'FILENAME == ARGV[1] { known[$1] = 1; next }
    $1 == "F" && ($2 == "claude" || $2 == "agy") && !($3 in known) { print $2, $3 }' "$1/agents.tsv" "$2" |
    while IFS=' ' read -r vendor f; do
      if [[ "$vendor" == "agy" ]]; then
        printf '%s\t%s\n' "$f" "$(spl_cost_tokens_agy_agent "$f")"
      else
        printf '%s\t%s\n' "$f" "$(spl_cost_tokens_agent "${SPOOL_ROOT:-/var/spool-hub}" "$f")"
      fi
    done >>"$1/agents.tsv"
}

# spl_token_burn_live DIR NOW: "U <vendor> <id>" for each agy or qwen lane
# with a live pane (spl_lane_live_here), whose transcripts are not read: an
# unmetered sample, never 0 tokens (spec 140 2.3.4). The pane list is cached
# for 120 s in DIR/live.txt (first line its epoch): a tmux read every tick
# costs more than the rest of it. The sum keeps the agy and qwen ids.
spl_token_burn_live() {
  local cache="$1/live.txt" ids
  local -a c=()
  if [[ -n "${TOKEN_BURN_LIVE_CMD:-}" ]]; then
    $TOKEN_BURN_LIVE_CMD 2>/dev/null
    return 0
  fi
  [[ -s "$cache" ]] && mapfile -t c <"$cache"
  if [[ "${c[0]:-}" =~ ^[0-9]+$ ]] && (( $2 - c[0] < 120 )); then
    printf '%s\n' "${c[@]:1}"
    return 0
  fi
  declare -F spl_lane_live_here >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
  ids="$(spl_lane_live_here | jq -r '.[]?' 2>/dev/null)"
  printf '%s\n%s\n' "$2" "$ids" >"$cache"
  printf '%s\n' "$ids"
}

# TOKEN_BURN_GROK_AWK: the awk function naming a grok usage.json's bucket
# (the live sum and the backfill share it). The agent is the lane id of the
# session's cwd (the url-encoded dir under .grok/sessions): a <x>-wt/<id>
# worktree, or a claude scratch dir naming <x>-wt-<id>. A grok id (g-NNN,
# legacy GRK-NNN) is the agent; another vendor's lane running grok is
# "<id> (grok)", and a cwd with no lane id is "unattributed (cwd <dir>)",
# every /tmp dir as /tmp. The buckets key on (agent, minute), here and on
# the hub, and the daily rollup on (day, agent): a grok bucket named like a
# claude one was summed into it, its vendor lost (SPL-2461).
TOKEN_BURN_GROK_AWK='
    function grok_agent(p,   c, i, id) {
      c = p; i = index(c, "/.grok/sessions/"); if (i) c = substr(c, i + 16); sub(/\/.*/, "", c)
      gsub(/%2[Ff]/, "/", c); gsub(/%20/, " ", c); gsub(/%25/, "%", c)
      if (match(c "/", /-wt[0-9]*[-\/][A-Za-z]+-[0-9]+\//)) {
        id = substr(c "/", RSTART, RLENGTH - 1); sub(/^-wt[0-9]*[-\/]/, "", id)
        return id ~ /^(g|GRK)-[0-9]+$/ ? id : id " (grok)"
      }
      if (c ~ /^\/tmp(\/|$)/) c = "/tmp"
      return "unattributed (cwd " substr(c, 1, 81) ")"
    }'

# spl_token_burn_sum DIR NOW MODE ROWS LIVE: the per-id MAX (claude) and the
# session counter deltas (mistral, grok) added to the agent's minute bucket.
# A row older than the window is counted late and dropped: its bucket is
# gone, and the hub replaces a bucket with what it is sent. A session seen
# for the first time counts from 0 when it began inside the window, else its
# counters are the baseline; a grok session's baseline is the turns that
# ended before the window (its new turns count, however old the session). LIVE: the live lane ids, one per line; an agy
# or qwen lane is an unmetered sample. Writes the next state files into
# DIR/next and moves them in with one mv, then tick.stats.
spl_token_burn_sum() {
  local dir="$1" n="$1/next" s
  for s in files ids sessions buckets; do : >"$n/$s.tsv" || return 1; done
  awk -F'\t' -v OFS='\t' -v now="$2" -v mode="$3" -v win="$TOKEN_BURN_WINDOW_S" -v ttl="$TOKEN_BURN_ID_TTL_S" -v d="$dir" -v nx="$n" -v live="$5" "$TOKEN_BURN_GROK_AWK"'
    function minute(t) { if (t > now) t = now; if (t < now - win) t = now; return t - t % 60 }
    function agent_of(p,   i) {
      gsub(/%2[Ff]/, "/", p)
      if (!match(p, /-wt[0-9]*\/[A-Za-z]+-[0-9]+(\/|$)/)) return "unattributed"
      p = substr(p, RSTART, RLENGTH); sub(/\/$/, "", p); i = split(p, s, "/"); return s[i]
    }
    function add(a, v, m, t, x1, x2, x3, x4, met,   k) {
      k = a SUBSEP minute(t)
      if (met && x1 + x2 + x3 + x4 == 0) return
      if (!(k in bv)) { bv[k] = v; bm[k] = m; bmet[k] = met; dirty[k] = 1 }
      if (met) bmet[k] = 1
      if (m != "") bm[k] = m
      if (x1 + x2 + x3 + x4 > 0) { b1[k] += x1; b2[k] += x2; b3[k] += x3; b4[k] += x4; dirty[k] = 1; bmet[k] = 1 }
    }
    FILENAME == d "/ids.tsv" { if ($2 >= now - ttl) { iseen[$1] = $2; for (j = 1; j <= 4; j++) im[$1, j] = $(j + 2) }; next }
    FILENAME == d "/sessions.tsv" { if ($7 >= now - 172800) { k = $1 SUBSEP $2; sseen[k] = $7; for (j = 1; j <= 4; j++) sc[k, j] = $(j + 2) }; next }
    FILENAME == d "/agents.tsv" { agent[$1] = $2; next }
    FILENAME == d "/buckets.tsv" { if ($4 >= now - win) { k = $1 SUBSEP $4; bv[k] = $2; bm[k] = $3; b1[k] = $5; b2[k] = $6; b3[k] = $7; b4[k] = $8; bmet[k] = ($5 + $6 + $7 + $8 > 0 ? 1 : $9); dirty[k] = $10; if (bmet[k] == 1) metered_agents[$1] = 1 }; next }
    FILENAME == live { id = $1; sub(/@.*/, "", id)
      if (id ~ /^(a-[0-9]+|AGY-[0-9]+)$/) ev[++n] = "U\tagy\t" id
      else if (id ~ /^(q-[0-9]+|QWN-[0-9]+)$/) ev[++n] = "U\tqwen\t" id
      next }
    $1 == "F" { print $2, $3, $4, $5 > (nx "/files.tsv"); files++; next }
    $1 == "L" { listed += $2; next }
    $1 == "M" { origin[$3] = $4; next }
    $1 == "V" { if ($2 == "mistral") vmodel = $3; else if ($2 == "agy") agymodel = $3; else vmodel = $3; next }
    { ev[++n] = $0 }
    END {
      for (e = 1; e <= n; e++) {
        split(ev[e], f, "\t")
        if (f[1] == "A") {
          if (f[4] < now - win) { late++; continue }
          id = f[3]; if (id in iseen) continue; iseen[id] = now
          a = (f[2] in agent) ? agent[f[2]] : "unattributed"
          m = (f[5] != "") ? f[5] : (agymodel != "") ? agymodel : "gemini-3.8-flash"
          add(a, "agy", m, f[4], f[6], f[7], f[8], f[9], 1); metered_agents[a] = 1; agy++; continue
        }
        if (f[1] == "C") {
          if (f[4] < now - win) { late++; continue }
          id = f[3]; iseen[id] = now
          for (j = 1; j <= 4; j++) { x[j] = f[j + 5] - im[id, j]; if (x[j] < 0) x[j] = 0; else im[id, j] = f[j + 5] }
          a = (f[2] in agent) ? agent[f[2]] : "unattributed"
          add(a, "claude", f[5], f[4], x[1], x[2], x[3], x[4], 1); metered_agents[a] = 1; claude++; continue
        }
        if (f[1] == "S") {
          k = f[2] SUBSEP f[3]
          if (!(k in sseen)) for (j = 1; j <= 4; j++) sc[k, j] = (f[2] == "grok" && f[12] != "" ? f[11 + j] : f[10] >= now - win ? 0 : f[j + 5])
          sseen[k] = now
          for (j = 1; j <= 4; j++) { x[j] = f[j + 5] - sc[k, j]; if (x[j] < 0) x[j] = f[j + 5]; sc[k, j] = f[j + 5] }
          a = (f[2] == "mistral" ? agent_of(origin[f[11]]) : grok_agent(f[11]))
          add(a, f[2], (f[2] == "mistral" ? vmodel : f[5]), f[4], x[1], x[2], x[3], x[4], 1); metered_agents[a] = 1; sessions++; continue
        }
      }
      for (e = 1; e <= n; e++) {
        split(ev[e], f, "\t")
        if (f[1] == "U") {
          if (f[2] == "agy" && (f[3] in metered_agents)) continue
          add(f[3], f[2], "", now, 0, 0, 0, 0, 0); unm++; continue
        }
      }
      for (id in iseen) print id, iseen[id], im[id, 1] + 0, im[id, 2] + 0, im[id, 3] + 0, im[id, 4] + 0 > (nx "/ids.tsv")
      for (k in sseen) { split(k, p, SUBSEP); print p[1], p[2], sc[k, 1] + 0, sc[k, 2] + 0, sc[k, 3] + 0, sc[k, 4] + 0, sseen[k] > (nx "/sessions.tsv") }
      for (k in bv) { split(k, p, SUBSEP); q += dirty[k]; nb++
        print p[1], bv[k], bm[k], p[2], b1[k] + 0, b2[k] + 0, b3[k] + 0, b4[k] + 0, bmet[k], dirty[k] + 0 > (nx "/buckets.tsv") }
      printf "token-burn tick mode=%s files=%d listed=%d claude_rows=%d agy_rows=%d session_rows=%d unmetered=%d late=%d buckets=%d queued=%d",
        mode, files, listed, claude, agy, sessions, unm, late, nb, q > (d "/tick.stats")
    }' "$dir/ids.tsv" "$dir/sessions.tsv" "$dir/agents.tsv" "$dir/buckets.tsv" "$4" "$5" || return 1
  mv -f -t "$dir" "$n/files.tsv" "$n/ids.tsv" "$n/sessions.tsv" "$n/buckets.tsv" || return 1
}

# spl_token_burn_frame DIR: the queued buckets as one fleet_tokens_push frame
# (spec 140 section 3.4). An unmetered sample has a null model.
spl_token_burn_frame() {
  awk -F'\t' '$10 == 1' "$1/buckets.tsv" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") |
    {agent_id: .[0], vendor: .[1], model: (if .[2] == "" then null else .[2] end),
     minute: (.[3] | tonumber | todate), tokens_in: (.[4] | tonumber), tokens_out: (.[5] | tonumber),
     cache_read: (.[6] | tonumber), cache_write: (.[7] | tonumber),
     is_metered: (.[8] == "1" or ((.[4] | tonumber) + (.[5] | tonumber) + (.[6] | tonumber) + (.[7] | tonumber) > 0))}) |
    {type: "lane", lane_op: "fleet_tokens_push", samples: .}'
}

# spl_token_burn_push DIR: push the queued buckets; an ack unqueues them,
# anything else keeps them queued for the next tick (still inside the window).
spl_token_burn_push() {
  local dir="$1" frame out rc n=0 stats
  read -r stats <"$dir/tick.stats"
  [[ "$stats" =~ \ queued=([0-9]+) ]] && n="${BASH_REMATCH[1]}"
  [[ "${TOKEN_BURN_PUSH:-1}" == 1 && "$n" -gt 0 ]] || { printf ' pushed=0' >>"$dir/tick.stats"; return 0; }
  frame="$(spl_token_burn_frame "$dir")" || return 1
  printf '%s\n' "$frame" >"$dir/last-frame.json"
  if [[ -n "${TOKEN_BURN_PUSH_CMD:-}" ]]; then out="$($TOKEN_BURN_PUSH_CMD <<<"$frame" 2>&1)"; rc=$?
  else out="$(spl_token_burn_spool <<<"$frame" 2>&1)"; rc=$?
  fi
  if (( rc == 0 )) && jq -e '.inserted | numbers' >/dev/null 2>&1 <<<"$out"; then
    awk -F'\t' -v OFS='\t' '{ $10 = 0; print }' "$dir/buckets.tsv" >"$dir/buckets.tsv.new" && mv -f "$dir/buckets.tsv.new" "$dir/buckets.tsv"
    printf ' pushed=%d' "$n" >>"$dir/tick.stats"
    return 0
  fi
  printf ' pushed=0 push_rc=%d push_out=%s' "$rc" "$(tail -1 <<<"$out" | tr -s '\t ' ' ' | cut -c1-160)" >>"$dir/tick.stats"
}

# spl_token_burn_spool <frame: `spool fleet-tokens push --json -` as the box's
# desk, with the hub settings DIR/push.env holds (do_spl_token_burn_push_env
# writes it: resolving them costs seconds, a tick has half of one).
spl_token_burn_spool() {
  local env_file="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}/push.env" k v
  local -a e=()
  [[ -s "$env_file" ]] || { echo "no $env_file yet: ./run -a do_spl_token_burn_push_env"; return 3; }
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^(SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPL_SPOOL)$ ]] && e+=("$k=$v")
  done <"$env_file"
  env "${e[@]}" bash -c '[[ -x "$SPL_SPOOL" ]] || { echo "no spool binary $SPL_SPOOL"; exit 3; }
    timeout 20 "$SPL_SPOOL" fleet-tokens push --json -'
}
