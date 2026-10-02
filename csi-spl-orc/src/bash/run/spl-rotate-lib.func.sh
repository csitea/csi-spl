#!/bin/bash
#------------------------------------------------------------------------------
# The shared pieces of the hourly role rotation (spec 060, plan section 1):
# do_spl_orch_rotate (CLE-77939) and do_spl_dispatch_rotate (CLE-77940) both
# source this file. No action lives here. Mechanical only (FR-001): every input
# is a file, a run action, /proc or tmux; nothing calls a model.
#
#   spl_rotate_conf                         settings: env > rotate.conf > defaults (FR-074, FR-090)
#   spl_rotate_log RID PHASE RESULT DETAIL  one rotate.log line + the .state file (FR-002)
#   spl_rotate_quiesce PANE                 grace, Escape, re-wait; prints idle|interrupted|busy-rotated (FR-011)
#   spl_rotate_handoff ROLE ID RID OUT      the handoff file, spec section 6 (FR-012, FR-025)
#   spl_rotate_spawn ID SEED                rename the old window, spawn under the same id, adopt it in the map (FR-006, FR-007, FR-013)
#   spl_rotate_restore ID OLD_PANE NEW_PANE the failure path: new closed, old name and map entry back (FR-013, FR-014, FR-027)
#   spl_rotate_retire PANE PID              /exit-clean, wait, TERM, wait, KILL (FR-015)
#   spl_rotate_ack_wait ID RID TIMEOUT      the new session's result on task <role>-rotate-<rid> in <ID>/outbox (FR-041)
#   spl_rotate_ack_send ROLE ID             the ROTATE_CMD=ack sender, run by the new session (FR-041)
#   spl_rotate_alert ROLE RID PHASE REASON  an ask (blocker) + an immediate owner DM (FR-075)
#
# The globals a rotation sets and these read: ROTATE_RID, ROTATE_OLD_PID,
# ROTATE_OLD_PANE, ROTATE_OLD_NAME, ROTATE_NEW_PID, ROTATE_NEW_PANE,
# ROTATE_QUIESCE, ROTATE_HANDOFF (spl_rotate_ctx_save / _load keep them for a
# resume). The outside world is replaceable for the tests: ROTATE_TMUX (tmux),
# ROTATE_SPAWN (spawn-window.sh), ROTATE_RUN (./run), ROTATE_SEND
# (spool-send.sh), ROTATE_KILL (kill), ROTATE_AI (the identity-map calls),
# LEASE_PROC_ROOT (/proc).
#
# NOTE ./run runs every action under `set -E` and an ERR trap that exits: a
# plain command that fails ends the whole action. Every probe here that may
# fail sits in a condition or an `||`, or prints nothing and returns 0.
#------------------------------------------------------------------------------
declare -F spl_lease_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

SPL_ROTATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- settings ----------------------------------------------------------------

# spl_rotate_conf: the libs, the lease settings, and every ROTATE_* knob:
# the environment wins, then <spool root>/dispatch/rotate.conf (KEY=value,
# read, never sourced), then the defaults named in the spec.
spl_rotate_conf() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  ROTATE_FEAT="$(cd "$SPL_ROTATE_LIB_DIR/../features/spawn-agents" && pwd)"
  declare -F spool_env_resolve >/dev/null || source "$ROTATE_FEAT/lib/spool-env.inc.sh"
  declare -F classify_screen >/dev/null || source "$ROTATE_FEAT/lib/agent-state.inc.sh"
  SPOOL_ENV_NO_BINS=1 spool_env_resolve
  spl_lease_init || return 1
  spl_lease_conf
  ROTATE_CONF="$LEASE_DIR/rotate.conf"
  local k v
  if [[ -f "$ROTATE_CONF" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v"
    done < <(grep -E '^ROTATE[A-Z_]*=[A-Za-z0-9._/@:-]*$' "$ROTATE_CONF")
  fi
  : "${ROTATE:=1}" "${ROTATE_ORCH:=1}" "${ROTATE_DISPATCH:=1}"
  : "${ROTATE_MIN_AGE:=3300}" "${ROTATE_IDLE_SEC:=10}" "${ROTATE_IDLE_GRACE:=60}" "${ROTATE_ESC_WAIT:=30}"
  : "${ROTATE_START_WAIT:=120}" "${ROTATE_ACK_TIMEOUT:=900}" "${ROTATE_EXIT_WAIT:=300}" "${ROTATE_TERM_WAIT:=30}"
  : "${ROTATE_NEW_EXIT_WAIT:=30}" "${ROTATE_POLL:=5}" "${ROTATE_BOOT_GRACE:=900}" "${ROTATE_HANDOFF_KEEP_DAYS:=7}"
  for k in ROTATE ROTATE_ORCH ROTATE_DISPATCH ROTATE_MIN_AGE ROTATE_IDLE_SEC ROTATE_IDLE_GRACE ROTATE_ESC_WAIT \
           ROTATE_START_WAIT ROTATE_ACK_TIMEOUT ROTATE_EXIT_WAIT ROTATE_TERM_WAIT ROTATE_NEW_EXIT_WAIT ROTATE_POLL \
           ROTATE_BOOT_GRACE ROTATE_HANDOFF_KEEP_DAYS; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  (( ROTATE_POLL > 0 )) || { do_log "FATAL ROTATE_POLL must be at least 1"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  ROTATE_LOG="$LEASE_DIR/rotate.log"
  ROTATE_HANDOFF_DIR="${ROTATE_HANDOFF_DIR:-$LEASE_DIR/handoff}"
  ROTATE_HOLD_DIR="${ROTATE_HOLD_DIR:-/var/tmp/CLE-parent-level/dispatch/hold}"
  ROTATE_BOX="${LEASE_MACHINE:-$(spl_desk_box_default)}"
  ROTATE_AGENT_HOME="$(getent passwd "${SPOOL_AGENT_USER:-$USER}" 2>/dev/null | cut -d: -f6 || true)"
  ROTATE_AGENT_HOME="${ROTATE_AGENT_HOME:-$HOME}"
  ROTATE_MEMORY_DIR="${ROTATE_MEMORY_DIR:-$ROTATE_AGENT_HOME/.claude/projects/-opt/memory}"
  local app; app="$(basename "$PROJ_PATH")"; app="${app%-orc}"
  ROTATE_SPEC="${ROTATE_SPEC:-$(cd "$PROJ_PATH/.." && pwd)/$app-doc/doc/md/SPEC-spool-fleet-roles.md}"
  ROTATE_SPAWN="${ROTATE_SPAWN:-$ROTATE_FEAT/scripts/spawn-window.sh}"
  ROTATE_RUN="${ROTATE_RUN:-$PROJ_PATH/run}"
  ROTATE_SEND="${ROTATE_SEND:-$ROTATE_FEAT/scripts/spool-send.sh}"
  return 0
}

# The id that holds a role on this machine (lease.conf).
spl_rotate_role_id() {
  case "$1" in orch) echo "${LEASE_ORCH:-}" ;; master) echo "${LEASE_MASTER:-}" ;; failover) echo "${LEASE_FAILOVER:-}" ;; esac
}

# The .state / .lock / task family of a role: orch -> orch, master|failover -> dispatch.
spl_rotate_family() { [[ "$1" == orch ]] && echo orch || echo dispatch; }

# A new run id: <UTC yyyymmddThhmmZ>-<role> (spec section 2).
spl_rotate_new_rid() { echo "$(date -u +%Y%m%dT%H%MZ)-$1"; }

# ---- the log -----------------------------------------------------------------

# spl_rotate_log RID PHASE RESULT DETAIL: one line
# "<UTC ts> <rid> <PHASE> <RESULT> <detail>" to rotate.log and stdout; a
# result other than SKIP / PLAN also records "<rid> <phase> <epoch>" in
# rotate.<orch|dispatch>.state. A dry run (DRY_RUN=1, not an ack) and PLAN
# lines only print: "nothing touched" (FR-005).
spl_rotate_log() {
  local rid="$1" phase="$2" res="$3" line
  line="$(date -u +%FT%TZ) $rid $phase $res ${4:-}"
  printf '%s\n' "$line"
  [[ "$res" == PLAN ]] && return 0
  [[ "${DRY_RUN:-1}" == 1 && "${ROTATE_CMD:-auto}" == auto ]] && return 0
  echo "$line" >> "$ROTATE_LOG"
  [[ "$res" == SKIP ]] && return 0
  printf '%s %s %s\n' "$rid" "$phase" "$(date +%s)" > "$LEASE_DIR/rotate.$(spl_rotate_family "${rid##*-}").state.tmp.$$" &&
    mv -f "$LEASE_DIR/rotate.$(spl_rotate_family "${rid##*-}").state.tmp.$$" "$LEASE_DIR/rotate.$(spl_rotate_family "${rid##*-}").state"
  return 0
}

# The resume context: rotate.<family>.ctx, KEY=value, read, never sourced.
ROTATE_CTX_KEYS=(ROTATE_RID ROTATE_PHASE ROTATE_OLD_PID ROTATE_OLD_PANE ROTATE_OLD_NAME ROTATE_NEW_PID ROTATE_NEW_PANE ROTATE_QUIESCE ROTATE_HANDOFF)
spl_rotate_ctx_save() {  # FAMILY
  local k f="$LEASE_DIR/rotate.$1.ctx"
  { for k in "${ROTATE_CTX_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k:-}"; done; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
spl_rotate_ctx_load() {  # FAMILY -> non-zero when there is none
  local k v f="$LEASE_DIR/rotate.$1.ctx"
  for k in "${ROTATE_CTX_KEYS[@]}"; do printf -v "$k" '%s' ""; done
  [[ -f "$f" ]] || return 1
  while IFS='=' read -r k v; do
    [[ " ${ROTATE_CTX_KEYS[*]} " == *" $k "* ]] && printf -v "$k" '%s' "$v"
  done < "$f"
  return 0
}

# ---- processes and panes -------------------------------------------------------

spl_rotate_tmux() {
  if [[ -n "${ROTATE_TMUX:-}" ]]; then "$ROTATE_TMUX" "$@"; return; fi
  spool_tmux_argv
  "${SPOOL_TM[@]}" "$@"
}

# spl_rotate_pids ID: every live claude pid whose environment carries
# SPOOL_AGENT_ID=<ID>, ascending (spl_lease_agent_pid gives only the lowest).
spl_rotate_pids() {
  local id="$1" d pid comm root="${LEASE_PROC_ROOT:-/proc}"
  local -a other=()
  {
    for d in "$root"/[0-9]*; do
      pid="${d##*/}"
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null || true
      [[ "$comm" == claude ]] || continue
      if [[ -r "$d/environ" ]]; then
        if grep -zx "SPOOL_AGENT_ID=$id" "$d/environ" >/dev/null 2>&1; then echo "$pid"; fi
      else
        other+=("$pid")
      fi
    done
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" | awk -v id="$id" '$2 == id {print $1}'
    fi
  } | sort -n
}

# spl_rotate_alive PID: 0 while it is a live claude process. Not `kill -0`:
# the box user may not signal the agent user's process (EPERM reads as dead).
spl_rotate_alive() {
  local comm=""
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  { read -r comm < "${LEASE_PROC_ROOT:-/proc}/$1/comm"; } 2>/dev/null || true
  [[ "$comm" == claude ]]
}

# spl_rotate_age PID: its age in seconds; empty when it is gone.
spl_rotate_age() {
  local start now root="${LEASE_PROC_ROOT:-/proc}"
  start="$(awk '{sub(/^.*\) /, ""); print $20}' "$root/$1/stat" 2>/dev/null || true)"
  [[ "$start" =~ ^[0-9]+$ ]] || return 0
  now="$(awk '{print int($1)}' "$root/uptime" 2>/dev/null || awk '{print int($1)}' /proc/uptime)"
  echo $(( now - start / $(getconf CLK_TCK) ))
}

# spl_rotate_uptime: seconds since boot (FR-052).
spl_rotate_uptime() { awk '{print int($1)}' "${LEASE_PROC_ROOT:-/proc}/uptime" 2>/dev/null || awk '{print int($1)}' /proc/uptime; }

# spl_rotate_user PID: the user that runs it; empty when it is gone.
spl_rotate_user() {
  local uid
  uid="$(awk '/^Uid:/ {print $2}' "${LEASE_PROC_ROOT:-/proc}/$1/status" 2>/dev/null || true)"
  [[ -n "$uid" ]] && getent passwd "$uid" | cut -d: -f1
  return 0
}

# spl_rotate_pane_of_pid PID: the tmux pane whose process tree holds it; empty when none.
spl_rotate_pane_of_pid() {
  local p="$1" panes pane
  panes="$(spl_rotate_tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)" || return 0
  for _ in $(seq 1 64); do
    pane="$(awk -v p="$p" '$1 == p {print $2; exit}' <<<"$panes")"
    [[ -n "$pane" ]] && { echo "$pane"; return 0; }
    p="$(awk '{sub(/^.*\) /, ""); print $2}' "${LEASE_PROC_ROOT:-/proc}/$p/stat" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 0
  done
  return 0
}

# spl_rotate_claude_ancestor: the nearest claude process above this shell
# (the session that ran the ack command); empty when there is none.
spl_rotate_claude_ancestor() {
  local p="$$" comm
  for _ in $(seq 1 32); do
    comm=""; { read -r comm < "/proc/$p/comm"; } 2>/dev/null || true
    [[ "$comm" == claude ]] && { echo "$p"; return 0; }
    p="$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$p/stat" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 0
  done
  return 0
}

spl_rotate_screen() { spl_rotate_tmux capture-pane -p -t "$1" 2>/dev/null || true; }

# spl_rotate_idle PANE: 0 when the screen reads idle (classify_screen) AND is
# byte-identical over ROTATE_IDLE_SEC (spec section 2, "idle pane").
spl_rotate_idle() {
  local a b
  a="$(spl_rotate_screen "$1")"
  [[ -n "$a" && "$(classify_screen "$a")" == idle ]] || return 1
  sleep "$ROTATE_IDLE_SEC"
  b="$(spl_rotate_screen "$1")"
  [[ "$a" == "$b" ]]
}

# spl_rotate_stalled PANE: the CLE-77935 footer text when the pane is stalled
# (usage limit, login, trust screen ...), nothing otherwise (FR-009).
spl_rotate_stalled() {
  spl_rotate_screen "$1" | grep -v '^[[:space:]]*$' | tail -n "${LEASE_PANE_TAIL:-8}" |
    grep -oiE -m1 -- "${LEASE_STALL_RE:-${LEASE_STALL_RE_DEFAULT:-usage limit reached}}" | head -1
  return 0
}

# ---- QUIESCE (FR-011) --------------------------------------------------------

# spl_rotate_quiesce PANE: wait up to ROTATE_IDLE_GRACE for an idle pane;
# still busy (or a dialog on screen): Escape, wait up to ROTATE_ESC_WAIT.
# Prints idle (it was idle), interrupted (Escape stopped a turn) or
# busy-rotated (still not idle: the rotation goes on anyway, owner D1).
spl_rotate_quiesce() {
  local pane="$1" t0
  t0=$SECONDS
  while (( SECONDS - t0 < ROTATE_IDLE_GRACE )); do
    [[ "$(classify_screen "$(spl_rotate_screen "$pane")")" == dialog ]] && break
    spl_rotate_idle "$pane" && { echo idle; return 0; }
    sleep "$ROTATE_POLL"
  done
  spl_rotate_tmux send-keys -t "$pane" Escape 2>/dev/null || true
  t0=$SECONDS
  while (( SECONDS - t0 < ROTATE_ESC_WAIT )); do
    spl_rotate_idle "$pane" && { echo interrupted; return 0; }
    sleep "$ROTATE_POLL"
  done
  echo busy-rotated
}

# ---- HANDOFF (spec section 6) --------------------------------------------------

# spl_rotate_handoff ROLE ID RID OUT: the handoff file. The old session is
# ROTATE_OLD_PID / ROTATE_OLD_PANE when set, else the id's lowest live pid.
# Every section is capped; a source that fails prints "UNAVAILABLE: <why>"
# and blocks nothing. OUT "-" prints instead of writing.
spl_rotate_handoff() {
  local role="$1" id="$2" rid="$3" out="$4" pid="${ROTATE_OLD_PID:-}" pane="${ROTATE_OLD_PANE:-}" asks lanes tr age
  [[ -n "$pid" ]] || pid="$(spl_rotate_pids "$id" | head -1)"
  [[ -n "$pane" || -z "$pid" ]] || pane="$(spl_rotate_pane_of_pid "$pid")"
  age="$(spl_rotate_age "$pid")"
  asks="$(spl_rotate_json "ASKS_ROLE=${ROTATE_ASKS_ROLE:-orch}" ASKS_FORMAT=json -a do_spl_asks_open)"
  lanes="$(spl_rotate_json LANE_FORMAT=json -a do_spl_lane_map)"
  tr="$(spl_rotate_transcript "$id")"
  # "-" prints: never `> /dev/stdout`, which truncates a stdout that is a file
  if [[ "$out" == - ]]; then spl_rotate_handoff_body; else spl_rotate_handoff_body > "$out"; fi
  return 0
}

# The body of spl_rotate_handoff; reads its locals (bash dynamic scope).
spl_rotate_handoff_body() {
  {
    echo "# $id@$ROTATE_BOX handoff, rotation $rid (role $role)"
    echo
    echo "Written by the rotation script from files, /proc and tmux (spec 060 section 6); no model wrote it."
    echo "- old session: pid ${pid:-?}, $(( ${age:-0} / 60 )) min old, pane ${pane:-?}; quiesce: ${ROTATE_QUIESCE:-not run}"
    echo "- transcript: ${tr:-UNAVAILABLE: no session id in the identity map}"
    echo "- lease (dispatch): $(cat "$LEASE_FILE" 2>/dev/null || echo none)"
    echo "- lease.orch: $(cat "$LEASE_FILE.orch" 2>/dev/null || echo none)"
    echo "- role: $ROTATE_SPEC section 1 (+ 1.2 rotation, 4.1 fleet lease, 4.3 asks)"
    echo
    echo "## 2. In flight: the old pane's last terminal lines (after quiesce)"
    if [[ -n "$pane" ]]; then
      echo '```text'
      spl_rotate_tmux capture-pane -p -J -S -300 -t "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' |
        tail -n "${ROTATE_SCREEN_LINES:-60}" | sed -E 's/^(.{200}).*/\1/' || true
      echo '```'
    else echo "UNAVAILABLE: no pane"; fi
    echo
    echo "## 3. Open asks, oldest first (ack: do_spl_ask_ack, close: do_spl_ask_close)"
    spl_rotate_handoff_asks "$asks"
    echo
    echo "## 4. Sent by the old session in its last hour (its outbox)"
    spl_rotate_msgs "$SPOOL_ROOT/$id/outbox" to 60 40 160
    echo
    echo "## 5. Unread inbox: $(find "$SPOOL_ROOT/$id/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) message(s), the 20 newest"
    spl_rotate_msgs "$SPOOL_ROOT/$id/inbox" from "" 20 120
    echo
    echo "## 6. Live lanes (do_spl_lane_map)"
    if [[ -n "$lanes" ]]; then
      jq -r 'def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
        [.lanes[] | select((.state // "live") == "live")] | if length == 0 then "none" else (.[0:60][] |
        "- \(.agent_id)@\(.agent_box // "?") \(.branch // "-") (\(.age_s | dur)): \(.scope // "" | .[0:80])") end' \
        <<<"$lanes" 2>/dev/null || echo "UNAVAILABLE: unreadable lane map"
    else echo "UNAVAILABLE: do_spl_lane_map failed (run it yourself)"; fi
    echo
    echo "## 7. Hold notes ($ROTATE_HOLD_DIR)"
    spl_rotate_holds
    echo
    echo "## 8. Session tail (the old transcript: last 10 user lines, last 10 assistant texts)"
    spl_rotate_transcript_tail "$tr"
    echo
    echo "## 9. Memory files (names only; read them in $ROTATE_MEMORY_DIR, MEMORY.md is the index)"
    spl_rotate_as_agent find "$ROTATE_MEMORY_DIR" -maxdepth 1 -name '*.md' ! -name MEMORY.md -printf '%f\n' 2>/dev/null |
      sort | sed 's/\.md$//' | tr '\n' ' ' | fold -s -w 110 || true
    echo
  }
  return 0
}

spl_rotate_handoff_asks() {
  [[ -n "$1" ]] || { echo "UNAVAILABLE: do_spl_asks_open failed (run it yourself)"; return 0; }
  jq -r 'def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    [.asks[] | select(.state == "open" or .state == "acked")] | sort_by(-(.age_s // 0)) |
    if length == 0 then "none" else (.[0:40][] |
    "- \(.ask_id[0:8]) \(.kind) from \(.from), \(.age_s | dur), \(.state)\(if .state == "acked" then " by \(.acked_by // "?")" else "" end), topic \(.topic // "-" | .[0:12]): \(.summary // "" | .[0:120])") end' \
    <<<"$1" 2>/dev/null || echo "UNAVAILABLE: unreadable ask book"
  return 0
}

# spl_rotate_json VAR=value... -a <action>: that action's JSON line (its
# do_log lines dropped), or nothing.
spl_rotate_json() {
  local -a kv=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do kv+=("$1"); shift; done
  local out
  out="$(env "${kv[@]}" timeout "${ROTATE_SRC_TIMEOUT:-120}" "$ROTATE_RUN" "$@" 2>/dev/null 7>&- 8>&- 9>&- | grep -m1 '^{')" || true
  jq -e . >/dev/null 2>&1 <<<"$out" && printf '%s' "$out"
  return 0
}

# Run as the agent user (its home is not readable by the box user).
spl_rotate_as_agent() {
  if [[ -z "${SPOOL_AGENT_USER:-}" || "$(id -un)" == "$SPOOL_AGENT_USER" || -n "${ROTATE_AS_AGENT_DIRECT:-}" ]]; then "$@"
  else sudo -n -u "$SPOOL_AGENT_USER" "$@"; fi
}

# spl_rotate_msgs DIR to|from MINUTES|"" MAX WIDTH: the spool messages in a
# dir (only the last MINUTES when given), the newest MAX, oldest first.
spl_rotate_msgs() {
  local lines age=()
  [[ -n "$3" ]] && age=(-mmin "-$3")
  lines="$(find "$1" -maxdepth 1 -name '*.json' "${age[@]}" -print0 2>/dev/null |
    xargs -0 -r jq -r --arg who "$2" --argjson w "$5" '[.ts // "", (if $who == "to" then "-> " + (.to // "") else "<- " + (.from // "") end),
      .kind // "", (.task_id // "" | .[0:12]),
      ((.body // "") | split("\n") | map(select(test("\\S"))) | join(" ") | .[0:$w])]
      | "- \(.[0][5:16]) \(.[1]) \(.[2]) [\(.[3])] \(.[4])"' 2>/dev/null |
    sort | tail -n "$4")"
  printf '%s\n' "${lines:-none}"
}

# The hold notes touched in the last ROTATE_HOLD_DAYS (3) days: name, age,
# title line, up to three NEXT lines; at most 20 topics.
spl_rotate_holds() {
  local d f n=0 head next
  [[ -d "$ROTATE_HOLD_DIR" ]] || { echo "UNAVAILABLE: $ROTATE_HOLD_DIR not found"; return 0; }
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    f="$d"
    [[ -d "$d" ]] && f="$(ls -t "$d"/notes.md "$d"/runbook.md "$d"/*.md 2>/dev/null | head -1)"
    head="" next=""
    if [[ -f "$f" && "$f" == *.md ]]; then
      head="$(grep -m1 -E '^#+ ' "$f" 2>/dev/null | sed -E 's/^#+ +//' | cut -c1-100)"
      next="$(grep -m3 -iE '(^|[^a-z])next( step)?:' "$f" 2>/dev/null | sed -E 's/^[-* ]+//' | cut -c1-140 | sed 's/^/    /')"
    fi
    echo "- $(basename "$d") ($(( ( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || date +%s) ) / 3600 ))h ago): ${head:-no notes}"
    [[ -n "$next" ]] && echo "$next"
    n=$((n + 1)); (( n < 20 )) || break
  done < <(find "$ROTATE_HOLD_DIR" -mindepth 1 -maxdepth 1 -mtime "-${ROTATE_HOLD_DAYS:-3}" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  (( n )) || echo "none touched in ${ROTATE_HOLD_DAYS:-3} days"
  return 0
}

# spl_rotate_transcript ID: the old session's transcript path, from its
# identity-map record (session_id + worktree): <agent home>/.claude/projects/
# <worktree with every non-alphanumeric as '-'>/<session_id>.jsonl.
# ROTATE_TRANSCRIPT overrides it.
spl_rotate_transcript() {
  [[ -n "${ROTATE_TRANSCRIPT:-}" ]] && { echo "$ROTATE_TRANSCRIPT"; return 0; }
  local rec="$SPOOL_ROOT/agents/$1.json" sid wt
  sid="$(jq -r '.session_id // empty' "$rec" 2>/dev/null || true)"
  wt="$(jq -r '.worktree // empty' "$rec" 2>/dev/null || true)"
  [[ "$sid" =~ ^[0-9a-f-]{36}$ && -n "$wt" ]] || return 0
  echo "$ROTATE_AGENT_HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")/$sid.jsonl"
}

# The last 10 user lines and 10 assistant text blocks, in order, 300 chars
# each; tool calls and tool results skipped.
spl_rotate_transcript_tail() {
  [[ -n "$1" ]] || { echo "UNAVAILABLE: no transcript path"; return 0; }
  local out
  out="$(spl_rotate_as_agent tail -n "${ROTATE_TRANSCRIPT_LINES:-4000}" "$1" 2>/dev/null | jq -c -R 'fromjson? //empty |
      if .type == "user" and (.message.content | type) == "string" then {r: "user", t: .message.content}
      elif .type == "assistant" and (.message.content | type) == "array" then
        ([.message.content[] | select(.type == "text") | .text] | join(" ") | select(length > 0) | {r: "assistant", t: .})
      else empty end' 2>/dev/null |
    jq -s -r 'to_entries | map(.value + {i: .key}) | ([.[] | select(.r == "user")][-10:] + [.[] | select(.r == "assistant")][-10:])
      | sort_by(.i)[] | "- \(.r): \(.t | gsub("\\s+"; " ") | .[0:300])"' 2>/dev/null)" || true
  printf '%s\n' "${out:-UNAVAILABLE: $1 is unreadable or empty}"
}

# Drop handoffs older than ROTATE_HANDOFF_KEEP_DAYS.
spl_rotate_handoff_prune() {
  find "$ROTATE_HANDOFF_DIR" -maxdepth 1 -name '*.md' -mtime "+$ROTATE_HANDOFF_KEEP_DAYS" -delete 2>/dev/null || true
}

# ---- SPAWN / RESTORE (FR-006, FR-007, FR-013) -----------------------------------

# The identity-map calls (agent-identity.inc.sh); ROTATE_AI replaces them in
# tests: "$ROTATE_AI adopt <ID> <PID>" / "$ROTATE_AI pane-of <ID>".
spl_rotate_ai() {
  if [[ -n "${ROTATE_AI:-}" ]]; then "$ROTATE_AI" "$@"; return; fi
  declare -F ai_adopt >/dev/null || source "$ROTATE_FEAT/lib/agent-identity.inc.sh"
  case "$1" in
    adopt) ai_adopt "$2" "$3" ;;
    pane-of) ai_pane_of "$2" ;;
  esac
}

# The retiring name (FR-007): <ID>-<UTC hhmm>Z-retiring; SPOOL_ID_RE fails on it.
spl_rotate_retiring_name() { echo "$1-${ROTATE_RID:9:4}Z-retiring"; }

# spl_rotate_spawn ID SEED: rename the old window (ROTATE_OLD_PANE) to its
# retiring name, start a new session under the same id with SEED (a brief
# file) through spawn-window.sh (SPAWN_REUSE_ID=1: same spool dir, same
# inbox) in the old window's tmux session, wait ROTATE_START_WAIT for its
# pid, check it runs as the agent user, adopt it in the identity map, and
# check ai_pane_of <ID> is the new pane. Sets ROTATE_NEW_PANE / ROTATE_NEW_PID.
# Non-zero = failed, the reason in ROTATE_ERR; the caller runs spl_rotate_restore.
# shellcheck disable=SC2034 # ROTATE_ERR is read by the caller
spl_rotate_spawn() {
  local id="$1" seed="$2" sess out pid user t0 got tag bin
  ROTATE_ERR="" ROTATE_NEW_PANE="" ROTATE_NEW_PID=""
  spl_rotate_tmux rename-window -t "$ROTATE_OLD_PANE" "$(spl_rotate_retiring_name "$id")" 2>/dev/null ||
    { ROTATE_ERR="tmux refused to rename $ROTATE_OLD_PANE"; return 1; }
  sess="$(spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{session_id}' 2>/dev/null || true)"
  # the box tag the old window showed (<ID>@<tag>), so the new one is named alike
  tag="${SPOOL_BOX_TAG:-}"
  [[ -z "$tag" && "${ROTATE_OLD_NAME:-}" =~ ^$id@([a-z0-9][a-z0-9-]*) ]] && tag="${BASH_REMATCH[1]}"
  # the agent user's own claude, not whatever `claude` a login PATH finds
  bin="${ROTATE_CLAUDE_BIN:-${CLAUDE_BIN:-}}"
  [[ -z "$bin" && -x "$ROTATE_AGENT_HOME/.local/bin/claude" ]] && bin="$ROTATE_AGENT_HOME/.local/bin/claude"
  out="$(env SPOOL_SESSION="$sess" SPAWN_REUSE_ID=1 SPOOL_ORCHESTRATOR_ID="${LEASE_ORCH:-}" SPOOL_BOX_TAG="$tag" ${bin:+"CLAUDE_BIN=$bin"} \
    SPAWN_LANE_SCOPE="role $id (rotation $ROTATE_RID)" \
    bash "$ROTATE_SPAWN" claude "$id" "$(spl_rotate_workdir "$id")" "$seed" rotate 2>&1 7>&- 8>&- 9>&-)" || true
  ROTATE_NEW_PANE="$(grep -m1 -oE "^$id %[0-9]+" <<<"$out" | cut -d' ' -f2)"
  [[ -n "$ROTATE_NEW_PANE" ]] || { ROTATE_ERR="spawn printed no pane: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  t0=$SECONDS
  while (( SECONDS - t0 < ROTATE_START_WAIT )); do
    for pid in $(spl_rotate_pids "$id"); do
      [[ "$pid" != "$ROTATE_OLD_PID" && "$(spl_rotate_pane_of_pid "$pid")" == "$ROTATE_NEW_PANE" ]] && { ROTATE_NEW_PID="$pid"; break 2; }
    done
    sleep "$ROTATE_POLL"
  done
  [[ -n "$ROTATE_NEW_PID" ]] || { ROTATE_ERR="no claude carrying $id started in $ROTATE_NEW_PANE within ${ROTATE_START_WAIT}s"; return 1; }
  # the ack sender reads the new pid from the ctx: record it at once
  ROTATE_PHASE=SPAWN spl_rotate_ctx_save "$(spl_rotate_family "${ROTATE_RID##*-}")"
  # agents run as the agent user, never as the box user (FR-006)
  user="$(spl_rotate_user "$ROTATE_NEW_PID")"
  if [[ -n "${SPOOL_AGENT_USER:-}" && "$user" != "$SPOOL_AGENT_USER" ]]; then
    ROTATE_ERR="the new session runs as '$user', not the agent user $SPOOL_AGENT_USER"; return 1
  fi
  # pokes must reach the NEW pane from here on (FR-006, FR-018): the map
  # beats window names in spool_pane_of, and with two live processes on one
  # id the plain record keeps the old one, so the new pid is adopted
  spl_rotate_ai adopt "$id" "$ROTATE_NEW_PID" >/dev/null 2>&1 || true
  got="$(spl_rotate_ai pane-of "$id" 2>/dev/null || true)"
  [[ "$got" == "$ROTATE_NEW_PANE" ]] ||
    { ROTATE_ERR="the identity map routes $id to '${got:-nothing}', not the new pane $ROTATE_NEW_PANE"; return 1; }
  return 0
}

# The new session's working dir: ROTATE_WORKDIR, else the id's newest
# registry rundir, else the old process's cwd, else HOME.
spl_rotate_workdir() {
  local d="${ROTATE_WORKDIR:-}"
  [[ -n "$d" ]] || d="$(awk -F'\t' -v id="$1" '$1 == id {r = $4} END {print r}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true)"
  [[ -n "$d" && -d "$d" ]] || d="$(readlink "${LEASE_PROC_ROOT:-/proc}/${ROTATE_OLD_PID:-0}/cwd" 2>/dev/null || true)"
  echo "${d:-$HOME}"
}

# spl_rotate_restore ID OLD_PANE NEW_PANE: the failure path. The new session
# (ROTATE_NEW_PID, if any) gets /exit and is killed after
# ROTATE_NEW_EXIT_WAIT, its window is closed by pane id, the old window gets
# its name back (ROTATE_OLD_NAME), and the identity map points at the old pid
# again, so pokes reach the session that keeps the role.
spl_rotate_restore() {
  local id="$1" old="$2" new="$3"
  if [[ -n "${ROTATE_NEW_PID:-}" && -n "$new" ]]; then
    spl_rotate_end "$new" "$ROTATE_NEW_PID" /exit "$ROTATE_NEW_EXIT_WAIT" 5 || true
  fi
  [[ -n "$new" ]] && { spl_rotate_tmux kill-window -t "$new" 2>/dev/null || true; }
  if [[ -n "$old" ]]; then
    spl_rotate_tmux rename-window -t "$old" "${ROTATE_OLD_NAME:-$(spool_decorate "$id")}" 2>/dev/null || true
  fi
  if [[ -n "${ROTATE_OLD_PID:-}" ]] && spl_rotate_alive "$ROTATE_OLD_PID"; then
    spl_rotate_ai adopt "$id" "$ROTATE_OLD_PID" >/dev/null 2>&1 || true
  fi
  return 0
}

# ---- RETIRE (FR-015) -----------------------------------------------------------

# spl_rotate_input PANE: the text in the CLI's input box, one line per row,
# blank rows dropped: the rows between the last two ─ rules, with the ❯
# marker, the indent and the DIM ghost suggestion cut away (the ghost cut is
# spool_notify_strip_ghost's). Exit 1 when no box is on screen. Measured on a
# throwaway claude 2026-10-02: an empty box is "❯<NBSP>ESC[2mTry ...", three
# typed rows are "❯ a" / "  b" / "  c", and the slash menu draws ABOVE it.
spl_rotate_input() {
  local esc=$'\033' nbsp=$' '
  spl_rotate_tmux capture-pane -p -e -t "$1" 2>/dev/null |
    sed -E "s/${esc}\[7m.*//; s/${esc}\[([0-9;]*;)?2m.*//; s/${esc}\[[0-9;]*[A-Za-z]//g; s/${nbsp}/ /g" |
    awk '{ l[NR] = $0 } /^─/ { r[++n] = NR }
      END { if (n < 2) exit 1
        for (i = r[n - 1] + 1; i < r[n]; i++) {
          s = l[i]; sub(/^ */, "", s); sub(/^❯/, "", s); sub(/^ +/, "", s); sub(/ +$/, "", s)
          if (s != "") print s } }'
}

# spl_rotate_type PANE CMD: the WHOLE input box emptied, CMD typed, 0 only
# when the box then reads exactly CMD; what it read is left in
# ROTATE_INPUT_READ. C-u empties one row only: CLE-77939's QUIESCE Escape put
# a multi-row poke back into the box and /exit-clean was sent appended to it.
# C-c empties every row, and is sent only to a box that holds text: on an
# empty box it arms "Press Ctrl-C again to exit" (both measured 2026-10-02).
spl_rotate_type() {
  local pane="$1" cmd="$2"
  ROTATE_INPUT_READ="$(spl_rotate_input "$pane")" || { ROTATE_INPUT_READ="(no input box)"; return 1; }
  if [[ -n "$ROTATE_INPUT_READ" ]]; then
    spl_rotate_tmux send-keys -t "$pane" C-c 2>/dev/null || true
    sleep 1
    ROTATE_INPUT_READ="$(spl_rotate_input "$pane")" || { ROTATE_INPUT_READ="(no input box)"; return 1; }
    [[ -z "$ROTATE_INPUT_READ" ]] || return 1
  fi
  spl_rotate_tmux send-keys -t "$pane" -l "$cmd" 2>/dev/null || true
  sleep 1
  ROTATE_INPUT_READ="$(spl_rotate_input "$pane")" || { ROTATE_INPUT_READ="(no input box)"; return 1; }
  [[ "$ROTATE_INPUT_READ" == "$cmd" ]]
}

# spl_rotate_end PANE PID CMD WAIT TERM_WAIT: CMD typed into the emptied input
# box and Enter only once the box reads exactly CMD (one retry; a busy session
# queues it), then SIGTERM after WAIT s, SIGKILL after TERM_WAIT s more. A box
# that never reads CMD gets no Enter and goes straight to SIGTERM. Each
# fallback logged. 0 once gone.
spl_rotate_end() {
  local pane="$1" pid="$2" cmd="$3" wait="$4" twait="$5" t0 try typed=0
  spl_rotate_alive "$pid" || return 0
  for try in 1 2; do
    spl_rotate_type "$pane" "$cmd" && { typed=1; break; }
    spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "try $try: input box of $pane reads '$(printf '%s' "$ROTATE_INPUT_READ" | tr '\n' '|' | cut -c1-120)', not '$cmd'"
  done
  if (( typed )); then
    spl_rotate_tmux send-keys -t "$pane" Enter 2>/dev/null || true
    t0=$SECONDS; while (( SECONDS - t0 < wait )); do spl_rotate_alive "$pid" || return 0; sleep 1; done
    spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid alive ${wait}s after '$cmd': SIGTERM"
  else
    spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid: '$cmd' never read back, no Enter: SIGTERM"
  fi
  ${ROTATE_KILL:-sudo -n kill} -TERM "$pid" 2>/dev/null || true
  t0=$SECONDS; while (( SECONDS - t0 < twait )); do spl_rotate_alive "$pid" || return 0; sleep 1; done
  spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid alive ${twait}s after SIGTERM: SIGKILL"
  ${ROTATE_KILL:-sudo -n kill} -KILL "$pid" 2>/dev/null || true
  t0=$SECONDS; while (( SECONDS - t0 < 5 )); do spl_rotate_alive "$pid" || return 0; sleep 1; done
  return 1
}

# spl_rotate_retire PANE PID: /exit-clean, ROTATE_EXIT_WAIT (300 s), TERM,
# ROTATE_TERM_WAIT (30 s), KILL. Non-zero = it survived SIGKILL.
spl_rotate_retire() { spl_rotate_end "$1" "$2" /exit-clean "$ROTATE_EXIT_WAIT" "$ROTATE_TERM_WAIT"; }

# ---- ACK (FR-041) ----------------------------------------------------------------

spl_rotate_ack_task() { echo "$(spl_rotate_family "${1##*-}")-rotate-$1"; }

# spl_rotate_ack_wait ID RID TIMEOUT: 0 once <ID>/outbox holds a result from
# <ID> on task <family>-rotate-<rid>; 2 when the new session
# (ROTATE_NEW_PID) dies first; 1 on the timeout. Only the outbox counts: an
# inbox copy may be drained by someone else (FR-041).
spl_rotate_ack_wait() {
  local id="$1" rid="$2" timeout="$3" task t0
  task="$(spl_rotate_ack_task "$rid")"
  t0=$SECONDS
  while (( SECONDS - t0 < timeout )); do
    spl_rotate_ack_seen "$id" "$task" && return 0
    [[ -n "${ROTATE_NEW_PID:-}" ]] && ! spl_rotate_alive "$ROTATE_NEW_PID" && return 2
    sleep "$ROTATE_POLL"
  done
  spl_rotate_ack_seen "$id" "$task"
}

spl_rotate_ack_seen() {  # ID TASK
  find "$SPOOL_ROOT/$1/outbox" -maxdepth 1 -name '*.json' -mmin -120 -print0 2>/dev/null |
    xargs -0 -r jq -r --arg id "$1" --arg t "$2" 'select(.kind == "result" and .task_id == $t and ((.from // "") | sub("@.*"; "")) == $id) | .msg_id' 2>/dev/null |
    grep -m1 . >/dev/null
}

# spl_rotate_ack_send ROLE ID: the new session's ack (ROTATE_CMD=ack
# ROTATE_ID=<rid>). Refused with exit 3 unless ROTATE_ID is the rotation in
# flight, its phase waits for the ack, and the claude process that ran the
# command (the nearest claude above this shell; ROTATE_CALLER_PID in tests)
# is that rotation's NEW pid. Then one `result` from <ID> on task
# <family>-rotate-<rid>, which lands in <ID>/outbox.
spl_rotate_ack_send() {
  local role="$1" id="$2" fam caller rc=0
  fam="$(spl_rotate_family "$role")"
  [[ "${ROTATE_ID:-}" =~ ^[0-9]{8}T[0-9]{4}Z-[a-z]+$ ]] || { do_log "FATAL ROTATE_ID must be the rotation id from your seed"; return 3; }
  if ! spl_rotate_ctx_load "$fam" || [[ "$ROTATE_RID" != "$ROTATE_ID" ]]; then
    spl_rotate_log "$ROTATE_ID" ACK FAIL "refused: not the rotation in flight (${ROTATE_RID:-none})"; return 3
  fi
  # a quick new session may ack before the rotation has recorded its pid
  local t0=$SECONDS
  while [[ ( "$ROTATE_PHASE" == HANDOFF || -z "$ROTATE_NEW_PID" ) && "$ROTATE_RID" == "$ROTATE_ID" ]] && (( SECONDS - t0 < ${ROTATE_ACK_EARLY_WAIT:-60} )); do
    sleep 1; spl_rotate_ctx_load "$fam" || true
  done
  [[ "$ROTATE_PHASE" == SPAWN || "$ROTATE_PHASE" == ACK ]] ||
    { spl_rotate_log "$ROTATE_ID" ACK FAIL "refused: rotation is at $ROTATE_PHASE, not waiting for an ack"; return 3; }
  caller="${ROTATE_CALLER_PID:-$(spl_rotate_claude_ancestor)}"
  [[ -n "$caller" && "$caller" == "$ROTATE_NEW_PID" ]] ||
    { spl_rotate_log "$ROTATE_ID" ACK FAIL "refused: caller pid '${caller:-none}' is not the new session $ROTATE_NEW_PID"; return 3; }
  SPOOL_ROOT="$SPOOL_ROOT" bash "$ROTATE_SEND" --from "$id" --to "$id" --kind result --task "$(spl_rotate_ack_task "$ROTATE_ID")" \
    --no-ask --no-poke --body "ACK rotation $ROTATE_ID: $id pid $caller read the handoff and the inbox." >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  (( rc < 10 && rc != 2 )) || { spl_rotate_log "$ROTATE_ID" ACK FAIL "spool-send exit $rc"; return 1; }
  spl_rotate_log "$ROTATE_ID" ACK OK "sent by pid $caller"
}

# ---- ALERT (FR-075) ----------------------------------------------------------------

# spl_rotate_alert ROLE RID PHASE REASON: an ask in the ask book (kind
# blocker, topic <family>-rotate-<rid>) and, at once, a DM to the owner
# (ASKS_OWNER_CMD, else ASKS_OWNER from lease.conf through do_spl_desk_reply).
# No owner setting: one WARN, the ask alone. Best effort, logged.
spl_rotate_alert() {
  local role="$1" rid="$2" phase="$3" reason="$4" id body ask owner
  id="$(spl_rotate_role_id "$role")"
  body="ROTATION FAILED $role $phase $reason; old session kept: $id@$ROTATE_BOX pid ${ROTATE_OLD_PID:-?}"
  ask="$(cat /proc/sys/kernel/random/uuid)"
  if env ASK_ID="$ask" ASK_KIND=blocker ASK_FROM="$id" ASK_TO="${LEASE_ORCH:-}" ASK_TOPIC="$(spl_rotate_ack_task "$rid")" \
      ASK_SUMMARY="$body" timeout 120 "$ROTATE_RUN" -a do_spl_ask_put >/dev/null 2>&1 7>&- 8>&- 9>&-; then
    spl_rotate_log "$rid" ALERT OK "ask ${ask:0:8} in the ask book"
  else spl_rotate_log "$rid" ALERT FAIL "do_spl_ask_put failed"; fi
  owner="${ASKS_OWNER:-$(sed -n 's/^ASKS_OWNER=\(HUM-[0-9]*\)$/\1/p' "$LEASE_CONF" 2>/dev/null | tail -1)}"
  if [[ -n "${ASKS_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    if ASK_JSON="{\"ask_id\":\"$ask\"}" $ASKS_OWNER_CMD <<<"**$body**" >/dev/null 2>&1 7>&- 8>&- 9>&-; then
      spl_rotate_log "$rid" ALERT OK "owner told (ASKS_OWNER_CMD)"
    else spl_rotate_log "$rid" ALERT FAIL "ASKS_OWNER_CMD failed"; fi
  elif [[ "$owner" =~ ^HUM-[0-9]+$ && -n "${LEASE_ENV:-}" && -n "${LEASE_TENANT:-}" ]]; then
    if env ENV="$LEASE_ENV" TENANT_ID="$LEASE_TENANT" DESK_AGENT="$id" DESK_TO="$owner" DESK_TASK="$ask" DESK_KIND=blocker \
        DESK_BODY="**$body**" DRY_RUN=0 timeout 120 "$ROTATE_RUN" -a do_spl_desk_reply >/dev/null 2>&1 7>&- 8>&- 9>&-; then
      spl_rotate_log "$rid" ALERT OK "DM to $owner"
    else spl_rotate_log "$rid" ALERT FAIL "the DM to $owner failed"; fi
  else
    spl_rotate_log "$rid" ALERT WARN "no owner leg (ASKS_OWNER_CMD, or ASKS_OWNER + LEASE_ENV + LEASE_TENANT in $LEASE_CONF): the ask alone"
  fi
  return 0
}

# spl_rotate_note TO TASK BODY: a spool note (FR-073: FAILs, stalls, DONE).
spl_rotate_note() {
  local from="${LEASE_ORCH:-$1}" kind="${4:-note}" rc=0
  SPOOL_ROOT="$SPOOL_ROOT" bash "$ROTATE_SEND" --from "$from" --to "$1" --kind "$kind" --task "$2" --no-ask --body "$3" \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  return 0
}
