#!/bin/bash
#------------------------------------------------------------------------------
# @description Grok token burn history into the hub, once per box (SPL-2461,
# @description spec 140 section 3.7): every grok usage.json under each home's
# @description ~/.grok/sessions, one bucket per agent and UTC minute from the
# @description per-turn counters (each turn carries its own; they sum to the
# @description session's), the agent named as the live collector names it
# @description (TOKEN_BURN_GROK_AWK: g-NNN / GRK-NNN, "<id> (grok)",
# @description "unattributed (cwd <dir>)"). Idempotent: the hub replaces a
# @description bucket on its natural key (box, agent, minute), so a re-run
# @description writes the same rows. The hub refuses a minute older than 30
# @description days; turns older than TOKEN_BURN_BACKFILL_DAYS are counted and
# @description skipped. A session that moved inside the live window
# @description (TOKEN_BURN_WINDOW_S) is the live collector's and is skipped.
# @description DRY_RUN=1 (default) writes the frames under
# @description <TOKEN_BURN_STATE_DIR>/backfill and pushes nothing. Stdout
# @description carries counts, never a token total.
# @param DRY_RUN (optional) - 1 (default) frames only, 0 push them
# @param TOKEN_BURN_STATE_DIR (optional) - default /var/csi/csi-spl/token-burn (push.env)
# @param TOKEN_BURN_BACKFILL_DAYS (optional) - default 29: the hub keeps 30 days of minutes
# @param TOKEN_BURN_HOMES (optional) - space-separated homes read as the
# @param   current user (tests); default the home of each agent user
# @param   (spl_cost_agent_users) and of the box user (SPOOL_BOX_USER, else
# @param   the box.env one, else the current user), each read as that user
# @param TOKEN_BURN_PUSH_CMD (optional, tests) - replaces `spool fleet-tokens push --json -`
# @example ./run -a do_spl_token_burn_grok_backfill
# @example DRY_RUN=0 ./run -a do_spl_token_burn_grok_backfill
#------------------------------------------------------------------------------

declare -F spl_token_burn_tick >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-token-burn-collect.func.sh"

do_spl_token_burn_grok_backfill() {
  local dir="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}" now="${TOKEN_BURN_NOW:-$EPOCHSECONDS}" days="${TOKEN_BURN_BACKFILL_DAYS:-29}"
  local out rows buckets f n=0 stats
  [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= 29 )) || { echo "FATAL TOKEN_BURN_BACKFILL_DAYS must be 1..29, got '$days'" >&2; return 2; }
  out="$dir/backfill"
  mkdir -p "$out" || { echo "FATAL cannot create $out" >&2; return 1; }
  rm -f "$out"/frame-*.json
  rows="$out/turns.tsv" buckets="$out/buckets.tsv"
  spl_token_burn_grok_turns "$now" $((now - days * 86400)) $((now - TOKEN_BURN_WINDOW_S)) 1 >"$rows" ||
    { echo "FATAL reading the grok sessions failed" >&2; return 1; }
  awk -F'\t' -v OFS='\t' "$TOKEN_BURN_GROK_AWK"'
    $1 == "N" { for (j = 2; j <= 7; j++) st[j] += $j; next }
    $1 != "T" { next }
    { k = grok_agent($2) SUBSEP ($3 - $3 % 60); m[k] = $4; for (j = 5; j <= 8; j++) s[k, j] += $j }
    END {
      for (k in m) { split(k, p, SUBSEP); nb++; ag[p[1]]++; dy[int(p[2] / 86400)] = 1
        print p[1], m[k], p[2], s[k, 5] + 0, s[k, 6] + 0, s[k, 7] + 0, s[k, 8] + 0 }
      for (a in ag) agents++; for (x in dy) days++
      printf "grok-backfill homes=%d files=%d sessions=%d turns=%d skipped_old=%d skipped_live=%d agents=%d days=%d buckets=%d\n",
        st[2], st[3], st[4], st[5], st[6], st[7], agents, days, nb > "/dev/stderr"
    }' "$rows" 2>"$out/stats.txt" | sort -t$'\t' -k3,3n -k1,1 >"$buckets" ||
    { echo "FATAL summing the grok turns failed" >&2; return 1; }
  read -r stats <"$out/stats.txt"
  # one frame per 2000 samples (wire.FleetTokenSamplesMax): an agent's
  # minute is one row of buckets.tsv, so no frame repeats (agent, minute)
  split -l 2000 -d -a 3 "$buckets" "$out/chunk-" 2>/dev/null || true
  for f in "$out"/chunk-*; do
    [[ -s "$f" ]] || continue
    ( umask 077; jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") |
      {agent_id: .[0], vendor: "grok", model: (if .[1] == "" then null else .[1] end), minute: (.[2] | tonumber | todate),
       tokens_in: (.[3] | tonumber), tokens_out: (.[4] | tonumber), cache_read: (.[5] | tonumber),
       cache_write: (.[6] | tonumber), is_metered: true}) | {type: "lane", lane_op: "fleet_tokens_push", samples: .}' \
      "$f" >"$out/frame-${f##*-}.json" ) || { echo "FATAL framing $f failed" >&2; return 1; }
    rm -f "$f"; n=$((n + 1))
  done
  echo "$stats frames=$n"
  awk -F'\t' '{ c[$1]++ } END { for (a in c) printf "  agent %s buckets=%d\n", a, c[a] }' "$buckets" | sort
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    echo "DRY_RUN=1: $n frame(s) in $out, nothing pushed; DRY_RUN=0 pushes them"
    return 0
  fi
  spl_token_burn_grok_push "$out" "$n"
}

# spl_token_burn_grok_push DIR N: push DIR's frames in order; any refusal stops
# the run (a re-run replaces what landed: the push is idempotent).
spl_token_burn_grok_push() {
  local f r rc i=0
  for f in "$1"/frame-*.json; do
    [[ -s "$f" ]] || continue
    i=$((i + 1))
    if [[ -n "${TOKEN_BURN_PUSH_CMD:-}" ]]; then r="$($TOKEN_BURN_PUSH_CMD <"$f" 2>&1)"; rc=$?
    else r="$(spl_token_burn_spool <"$f" 2>&1)"; rc=$?
    fi
    if (( rc != 0 )) || ! jq -e '.inserted | numbers' >/dev/null 2>&1 <<<"$r"; then
      echo "FATAL push of ${f##*/} ($i of $2) refused rc=$rc: $(tail -1 <<<"$r" | cut -c1-200)" >&2
      return 1
    fi
    echo "OK pushed ${f##*/} ($i of $2): inserted $(jq -r .inserted <<<"$r")"
  done
  echo "OK grok backfill pushed $i frame(s)"
}

# spl_token_burn_grok_turns NOW FROM CUT SKIP: one row per grok turn that
# ended in [FROM, CUT), over every home, each read as its user; SKIP 1 skips
# a session updated at or after CUT (the live collector's), 0 reads its
# turns before CUT (the daily cost source, spl_cost_tokens_grok):
#   T <usage.json path> <ended epoch> <model> <in> <out> <cache_read> <cache_write>
# and one "N <homes> <files> <sessions> <turns> <skipped old> <skipped live>"
# row per home. Input counts exclude cache reads, as the live collector's do.
spl_token_burn_grok_turns() {
  local row u h r
  local -a homes=()
  spl_token_burn_grok_homes
  for row in "${homes[@]}"; do
    u="${row%% *}" h="${row#* }"
    if [[ "$u" == - ]]; then python3 -I -S -c "$(spl_token_burn_grok_py)" "$h" "$@"; r=$?
    else sudo -n -u "$u" python3 -I -S -c "$(spl_token_burn_grok_py)" "$h" "$@"; r=$?
    fi
    (( r == 0 )) || return 1
  done
}

# spl_token_burn_grok_homes: the caller's homes[] as "<user> <home>", the
# user "-" when it is the current one; each home once.
spl_token_burn_grok_homes() {
  local u h me box seen=" "
  if [[ -n "${TOKEN_BURN_HOMES:-}" ]]; then
    for h in $TOKEN_BURN_HOMES; do homes+=("- $h"); done
    return 0
  fi
  me="$(id -un)" box="${SPOOL_BOX_USER:-}"
  [[ -n "$box" ]] || box="$(sed -n 's/^SPOOL_BOX_USER=//p' "${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}" 2>/dev/null | sed -n 1p | tr -d "\"'")"
  for u in $(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}") "${box:-$me}"; do
    [[ -n "$u" && "$seen" != *" $u "* ]] || continue
    seen+="$u "
    h="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$h" ]] && homes+=("$([[ "$u" == "$me" ]] && echo - || echo "$u") $h")
  done
}

# The reader: counts and ids only, no prompt text leaves it.
spl_token_burn_grok_py() {
  cat <<'EOF_PY'
import datetime, glob, json, re, sys
home, now, frm, cut, skip = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "1"
def epoch(s):
    if not isinstance(s, str) or not s:
        return None
    s = re.sub(r"(\.\d{6})\d+", r"\1", s.strip()).replace("Z", "+00:00")
    try:
        d = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp())
def n(v):
    return int(v) if isinstance(v, (int, float)) and v > 0 else 0
files = sessions = turns = old = live = 0
out = sys.stdout
for f in sorted(glob.glob(glob.escape(home) + "/.grok/sessions/*/*/usage.json")):
    files += 1
    try:
        j = json.load(open(f))
    except (OSError, ValueError):
        continue
    s = j.get("session") if isinstance(j, dict) else None
    if not isinstance(s, dict):
        continue
    up = epoch(j.get("updatedAt"))
    if up is None:
        continue
    if skip and up >= cut:
        live += 1
        continue
    model = s.get("primaryModelId") or next(iter(s.get("modelUsage") or {}), None) or "unknown"
    t = j.get("turns") if isinstance(j.get("turns"), list) else []
    if not t or not all(isinstance(x, dict) and "inputTokens" in x for x in t):
        t = [dict(s, endedAt=j.get("updatedAt"))]
    sessions += 1
    for x in t:
        e = epoch(x.get("endedAt")) or up
        c = (n(x.get("inputTokens")) - n(x.get("cachedReadTokens")), n(x.get("outputTokens")), n(x.get("cachedReadTokens")), n(x.get("cacheCreationTokens")))
        if sum(c) == 0:
            continue
        if e < frm:
            old += 1
            continue
        if e >= cut:
            continue
        turns += 1
        out.write("T\t%s\t%d\t%s\t%d\t%d\t%d\t%d\n" % ((f, e, x.get("primaryModelId") or model) + tuple(max(v, 0) for v in c)))
out.write("N\t1\t%d\t%d\t%d\t%d\t%d\n" % (files, sessions, turns, old, live))
EOF_PY
}
