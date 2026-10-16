#!/bin/bash
#------------------------------------------------------------------------------
# @description The hourly rotation of EVERY agent on this box (owner HUM-10,
# @description 2026-10-11, t1 0bb05176: "hourly rotation for every freaky
# @description agent"; "There shouldn't be an agent which is running for more
# @description than 1 hour"; "exactly the same type of rotation as the other
# @description important boxes have"). Every live agent CLI that carries a
# @description spool id (c-, g-, m-, a-, q-), except the role seats the role
# @description rotations of THIS box own (do_spl_orch_rotate while this box
# @description holds the orch lease, do_spl_dispatch_rotate while it holds the
# @description dispatch lease), gets a fresh session under the same id by the
# @description spec 060 flow of spl-rotate-lib.func.sh: QUIESCE, HANDOFF (from
# @description files, /proc and tmux), SPAWN (a new window beside the old one,
# @description seeded with the lane's brief + the handoff + the ACK command),
# @description ACK (no ack = the new session is closed, the old one keeps the
# @description lane), RETIRE (/exit, TERM, KILL), CLOSE. Mechanical: nothing
# @description calls a model. ROTATE_CMD=auto is one cron tick (every minute,
# @description row lane-rotate of cnf/box-crons/box-crons.manifest):
# @description   at ROTATE_LANE_WARN_AGE (45 min) of session age the agent gets
# @description     ONE spool note "rotation at <UTC>: push what is green, write
# @description     your state" (and the pane poke);
# @description   from then on it is rotated at a quiet point: an idle pane, no
# @description     unpushed commit in its worktree, no test, push or apply under
# @description     its process; else DEFERred, the reason logged;
# @description   at its deadline it is rotated anyway, the handoff naming what
# @description     was in flight. The deadline is ROTATE_LANE_MAX_AGE (60 min)
# @description     less ROTATE_LANE_SLOT (5 min) per stagger round ahead of it,
# @description     so the cap never pushes a session past 60 min;
# @description   at most ROTATE_LANE_CAP (3) rotations run at once on a box,
# @description     each in its own worker, each seat stopped and restored on
# @description     its own; a seat rotated < 1 h ago (or failed < RETRY ago)
# @description     is never stopped again; a lane whose work was ACCEPTED is
# @description     left to the orchestrator to close;
# @description   a claude seat starts only while the claude login probe (the
# @description     one do_spl_agent_login_check runs) says ok; else no rotation
# @description     and ONE note to the dispatch lease holder;
# @description   any session older than ROTATE_LANE_REPORT_AGE (65 min) is
# @description     reported to the dispatch lease holder (do_spl_agent_age_check).
# @description The worker is ROTATE_CMD=one ID=<id> (it holds the id lock of
# @description spec 102 4.2); the new session runs ROTATE_CMD=ack. One line
# @description per step in <spool root>/dispatch/rotate.log (run id
# @description <UTC>-lane-<id>, which the watchdog reads as in flight); a tick's
# @description decisions in dispatch/lane-rotate/lane-rotate.log, a line only
# @description when an agent's decision changes. Dry run unless DRY_RUN=0.
# @param ROTATE_CMD (optional) - auto (default, a tick) | one | ack | handoff
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ID (one, ack, handoff) - the agent id
# @param ROTATE_ID (ack) - the rotation id named in the new session's seed
# @param ROTATE / ROTATE_LANE (optional) - 0 turns it off (also <spool root>/dispatch/rotate.conf)
# @param ROTATE_LANE_CAP (optional) - rotations at once on this box, default 3
# @param ROTATE_LANE_WARN_AGE / ROTATE_LANE_MAX_AGE / ROTATE_LANE_SLOT (optional) - seconds, default 2700 / 3600 / 300
# @param ROTATE_LANE_RETRY (optional) - seconds after a failed rotation before the next try, default 900
# @param ROTATE_LANE_REPORT_AGE (optional) - seconds, default 3900
# @param ROTATE_LANE_ACK_TIMEOUT / ROTATE_LANE_EXIT_WAIT (optional) - seconds, default 600 / 120
# @example ./run -a do_spl_lane_rotate
# @example DRY_RUN=0 ./run -a do_spl_lane_rotate
# @example ROTATE_CMD=handoff ID=c-123 ./run -a do_spl_lane_rotate
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_lane_rotate() {
  spl_rotate_conf || return 1
  spl_lane_rotate_conf || return 1
  case "${ROTATE_CMD:-auto}" in
    auto)    spl_lane_rotate_tick ;;
    one)     spl_lane_rotate_one ;;
    ack)     spl_lane_rotate_seat "${ID:-}" || return 3
             spl_rotate_ack_send lane "$ID" ;;
    handoff) spl_lane_rotate_seat "${ID:-}" || return 1
             ROTATE_QUIESCE="not run (preview)" ROTATE_OLD_PID="$(spl_rotate_pids "$ID" | sed -n 1p)" spl_lane_rotate_handoff "$ID" preview - ;;
    *) do_log "FATAL ROTATE_CMD must be auto, one, ack or handoff, got: '${ROTATE_CMD:-}'"; return 1 ;;
  esac
}

# The ROTATE_LANE_* knobs (env > rotate.conf, read by spl_rotate_conf > defaults).
spl_lane_rotate_conf() {
  local k
  : "${ROTATE_LANE:=1}" "${ROTATE_LANE_CAP:=3}" "${ROTATE_LANE_WARN_AGE:=2700}" "${ROTATE_LANE_MAX_AGE:=3600}"
  : "${ROTATE_LANE_SLOT:=300}" "${ROTATE_LANE_RETRY:=900}" "${ROTATE_LANE_REPORT_AGE:=3900}"
  : "${ROTATE_LANE_ACK_TIMEOUT:=600}" "${ROTATE_LANE_EXIT_WAIT:=120}" "${ROTATE_LANE_PROBE_MAX_AGE:=600}" "${ROTATE_LANE_REPORT_GRACE:=900}"
  for k in ROTATE_LANE ROTATE_LANE_CAP ROTATE_LANE_WARN_AGE ROTATE_LANE_MAX_AGE ROTATE_LANE_SLOT ROTATE_LANE_RETRY \
           ROTATE_LANE_REPORT_AGE ROTATE_LANE_ACK_TIMEOUT ROTATE_LANE_EXIT_WAIT ROTATE_LANE_PROBE_MAX_AGE ROTATE_LANE_REPORT_GRACE; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  (( ROTATE_LANE_CAP > 0 )) || { do_log "FATAL ROTATE_LANE_CAP must be at least 1"; return 1; }
  : "${ROTATE_LANE_BUSY_RE:=git (push|rebase|commit|fetch|pull)|terraform|tf-(plan|apply)|do[_-]provision|do_check_pre_push|run-all-tests|\.tst\.sh|go test|playwright|pnpm|npm (run|test)|pytest|docker (build|compose)|gh run watch|make do-}"
  ROTATE_LANE_DIR="$LEASE_DIR/lane-rotate"
  mkdir -p "$ROTATE_LANE_DIR" 2>/dev/null || { do_log "FATAL cannot create $ROTATE_LANE_DIR"; return 1; }
  ROTATE_LANE_LOG="$ROTATE_LANE_DIR/lane-rotate.log"
  ROTATE_LANE_LOGIN_CACHE="${ROTATE_LANE_LOGIN_CACHE:-/var/csi/csi-spl/agent-login-check/probe}"
  return 0
}

# spl_lane_rotate_seat ID: the lib's globals for ID's rotation: its ctx and
# .state in <spool root>/<ID>/lifetime (family lane), its kind (the tick
# passes LANE_ROTATE_KIND; else the identity map; else claude).
spl_lane_rotate_seat() {
  local id="$1" k
  spl_is_agent_id "$id" || { do_log "FATAL ID must be an agent id like c-123, got: '$id'"; return 1; }
  # shellcheck disable=SC2034 # read by spl-rotate-lib.func.sh
  ROTATE_FAMILY=lane ROTATE_STATE_DIR="$SPOOL_ROOT/$id/lifetime"
  mkdir -p "$ROTATE_STATE_DIR" 2>/dev/null || true
  k="${LANE_ROTATE_KIND:-$(jq -r '.kind // empty' "$SPOOL_ROOT/agents/$id.json" 2>/dev/null || true)}"
  ROTATE_KIND="${k:-claude}"
  [[ "$ROTATE_KIND" =~ ^(claude|grok|mistral|agy|qwen)$ ]] || { do_log "FATAL unknown agent kind '$ROTATE_KIND' for $id"; return 1; }
  return 0
}

# ---- the tick ------------------------------------------------------------------

spl_lane_rotate_tick() {
  [[ "$ROTATE" != 0 && "$ROTATE_LANE" != 0 ]] || { echo "lane-rotate: disabled (ROTATE=$ROTATE ROTATE_LANE=$ROTATE_LANE)"; return 0; }
  exec 6>> "$ROTATE_LANE_DIR/tick.lock"
  flock -n 6 || { echo "lane-rotate: another tick holds $ROTATE_LANE_DIR/tick.lock - skipped"; return 0; }
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( $(spl_rotate_uptime) < ROTATE_BOOT_GRACE )); then
    echo "lane-rotate: boot ($(spl_rotate_uptime)s < ${ROTATE_BOOT_GRACE}s) - skipped"; exec 6>&-; return 0
  fi
  local scan rows id kind pid age pane n
  scan="$(spl_lane_rotate_scan)"
  LR_ROLES=" $(spl_lane_rotate_role_ids | tr '\n' ' ') " LR_INFLIGHT=" $(spl_lane_rotate_inflight | tr '\n' ' ') "
  LR_SLOTS=$(( ROTATE_LANE_CAP - $(wc -w <<<"$LR_INFLIGHT") )) LR_K=0 LR_STARTED=0 LR_STARTED_IDS=" " LR_DEFER=0 LR_LOGIN="" LR_LOGIN_HELD=""
  # one row per id, the oldest first: "<id> <kind> <pid> <age> <pane> <processes>"
  rows="$(awk '{n[$1]++; if (!($1 in r)) r[$1] = $0} END {for (i in r) print r[i], n[i]}' <<<"$scan" | sort -k4,4nr)"
  while read -r id kind pid age pane n; do
    [[ -n "$id" ]] || continue
    spl_lane_rotate_consider "$id" "$kind" "$pid" "$age" "$pane" "$n"
  done <<<"$rows"
  [[ -n "$LR_LOGIN_HELD" ]] && spl_lane_rotate_login_alert
  spl_lane_rotate_age_alert "$scan"
  echo "lane-rotate@$ROTATE_BOX: agents=$(grep -c . <<<"$rows" || true) in-flight=$(wc -w <<<"$LR_INFLIGHT") started=$LR_STARTED deferred=$LR_DEFER$([[ "${DRY_RUN:-1}" == 1 ]] && echo ' (DRY_RUN)')"
  exec 6>&-
  return 0
}

# spl_lane_rotate_consider ID KIND PID AGE PANE N: one agent's decision.
spl_lane_rotate_consider() {
  local id="$1" kind="$2" pid="$3" age="$4" pane="$5" n="$6" why forced=0 at
  [[ "$LR_ROLES" == *" $id "* || "$LR_INFLIGHT" == *" $id "* ]] && return 0
  if spl_lane_rotate_ctx_open "$id"; then
    (( LR_SLOTS > 0 )) || { spl_lane_rotate_say "$id" "DEFER resume: cap $ROTATE_LANE_CAP"; return 0; }
    spl_lane_rotate_start "$id" "$kind" "$pid" 0 "resume a rotation left mid-way"; return 0
  fi
  (( age >= ROTATE_LANE_WARN_AGE )) || return 0
  (( n == 1 )) || { spl_lane_rotate_say "$id" "DEFER duplicate: $n live processes carry $id"; return 0; }
  spl_lane_rotate_warn "$id" "$pid" "$age"
  why="$(spl_lane_rotate_recent "$id")"
  [[ -z "$why" ]] || { spl_lane_rotate_say "$id" "DEFER $why"; return 0; }
  spl_lane_rotate_accepted "$id" && { spl_lane_rotate_say "$id" "SKIP accepted: its task is done, the orchestrator closes it"; return 0; }
  # the stagger: the k-th oldest must start by MAX - (k/CAP + 1) * SLOT
  at=$(( ROTATE_LANE_MAX_AGE - (LR_K / ROTATE_LANE_CAP + 1) * ROTATE_LANE_SLOT )); LR_K=$((LR_K + 1))
  (( LR_SLOTS > 0 )) || { spl_lane_rotate_say "$id" "DEFER cap: $ROTATE_LANE_CAP rotating"; return 0; }
  [[ -n "$pane" && "$pane" != - ]] || { spl_lane_rotate_say "$id" "DEFER pid $pid is in no tmux pane"; return 0; }
  why="$(spl_rotate_stalled "$pane")"
  [[ -z "$why" ]] || { spl_lane_rotate_say "$id" "DEFER stalled: pane shows '$why' (the login self-heal acts)"; return 0; }
  why="$(spl_lane_rotate_busy "$pid" "$pane" "$(spl_lane_rotate_workdir "$id" "$pid")")"
  if [[ -n "$why" ]]; then
    (( age >= at )) || { spl_lane_rotate_say "$id" "DEFER not quiet: $why (rotated anyway from $((at / 60)) min)"; return 0; }
    forced=1
  fi
  if [[ "$kind" == claude ]] && ! spl_lane_rotate_login_ok; then
    LR_LOGIN_HELD+=" $id"; spl_lane_rotate_say "$id" "DEFER login: the claude probe says $LR_LOGIN"; return 0
  fi
  spl_lane_rotate_start "$id" "$kind" "$pid" "$forced" "$why"
}

# spl_lane_rotate_say ID LINE: LINE to stdout and lane-rotate.log when it
# differs from ID's last one (digits aside), so a tick a minute logs changes.
spl_lane_rotate_say() {
  local f="$ROTATE_LANE_DIR/why.$1" key last=""
  [[ "$2" == DEFER* ]] && LR_DEFER=$((LR_DEFER + 1))
  key="$(tr -d '0-9' <<<"$2")"
  [[ -r "$f" ]] && last="$(cat "$f" 2>/dev/null || true)"
  [[ "$key" == "$last" ]] && return 0
  echo "$(date -u +%FT%TZ) $1 $2"
  [[ "${DRY_RUN:-1}" == 1 ]] && return 0
  printf '%s' "$key" > "$f" 2>/dev/null || true
  echo "$(date -u +%FT%TZ) $1 $2" >> "$ROTATE_LANE_LOG"
  return 0
}

# spl_lane_rotate_scan: "<id> <kind> <pid> <age-s> <pane|->" for every agent
# CLI process on this box whose environment carries SPOOL_AGENT_ID.
spl_lane_rotate_scan() {
  local root="${LEASE_PROC_ROOT:-/proc}" d pid comm k id
  local -A kind=() idof=()
  local -a hop=()
  for d in "$root"/[0-9]*; do
    pid="${d##*/}"; comm=""; { read -r comm < "$d/comm"; } 2>/dev/null || true
    case "$comm" in claude|grok|agy|qwen|vibe|"Vibe CLI"|node|nodejs|bun|deno|python|python[0-9]*) ;; *) continue ;; esac
    for k in claude grok mistral agy qwen; do
      ROTATE_KIND="$k" spl_rotate_cli "$d" "$comm" && { kind[$pid]="$k"; break; }
    done
    [[ -n "${kind[$pid]:-}" ]] || continue
    if [[ -r "$d/environ" ]]; then
      id="$(tr '\0' '\n' < "$d/environ" 2>/dev/null | sed -n 's/^SPOOL_AGENT_ID=//p' | sed -n 1p)"
      [[ -n "$id" ]] && idof[$pid]="$id"
    else hop+=("$pid"); fi
  done
  if (( ${#hop[@]} )) && declare -F spool_proc_env_get >/dev/null; then
    while read -r pid id; do [[ -n "$id" ]] && idof[$pid]="$id"; done < <(spool_proc_env_get "$root" SPOOL_AGENT_ID "${hop[@]}")
  fi
  for pid in "${!idof[@]}"; do
    spl_is_agent_id "${idof[$pid]}" || continue
    echo "${idof[$pid]} ${kind[$pid]} $pid $(spl_rotate_age "$pid") $(spl_rotate_pane_of_pid "$pid" | grep . || echo -)"
  done
  return 0
}

# The role seats (lease.conf LEASE_ORCH, LEASE_MASTER, LEASE_FAILOVER): spec
# 060's own rotations (do_spl_orch_rotate, do_spl_dispatch_rotate) own them,
# holder or standby, so this rotation never touches them (c-001, 2026-10-11:
# two rotations must not race on one seat).
spl_lane_rotate_role_ids() {
  printf '%s\n' "${LEASE_ORCH:-}" "${LEASE_MASTER:-}" "${LEASE_FAILOVER:-}"
}

# The orch lease holder to tell, "<id>@<box>" (bare id when it is on this
# box): a bare id on a standby box reaches the standby seat, which acts on nothing.
spl_lane_rotate_holder_to() {
  local h=""
  [[ -s "$LEASE_FILE.orch" ]] && read -r h _ < "$LEASE_FILE.orch"
  spl_is_agent_id "${h%@*}" || { echo orchestrator; return 0; }
  [[ "${h#*@}" == "$ROTATE_BOX" ]] && h="${h%@*}"
  echo "$h"
}

# The ids whose worker runs now (<lane dir>/run.<id> names a live pid).
spl_lane_rotate_inflight() {
  local f p
  for f in "$ROTATE_LANE_DIR"/run.*; do
    [[ -s "$f" ]] || continue
    read -r p < "$f" || true
    [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && echo "${f##*/run.}"
  done
  return 0
}

# 0 when ID's last rotation was left mid-way (its ctx not final).
spl_lane_rotate_ctx_open() {
  local ph=""
  ph="$(sed -n 's/^ROTATE_PHASE=//p' "$SPOOL_ROOT/$1/lifetime/rotate.lane.ctx" 2>/dev/null || true)"
  [[ -n "$ph" && ! "$ph" =~ ^(DONE|FAIL|ABORT)$ ]]
}

# Why ID may not be rotated again yet: rotated (DONE) < MAX_AGE ago, or
# failed < RETRY ago (<id>/lifetime/rotate.lane.last "<epoch> <rid> <result>").
spl_lane_rotate_recent() {
  local t="" rid="" res="" d
  [[ -s "$SPOOL_ROOT/$1/lifetime/rotate.lane.last" ]] && read -r t rid res < "$SPOOL_ROOT/$1/lifetime/rotate.lane.last"
  [[ "$t" =~ ^[0-9]+$ ]] || return 0
  d=$(( $(date +%s) - t ))
  if [[ "$res" == DONE ]] && (( d < ROTATE_LANE_MAX_AGE )); then echo "rotated $((d / 60)) min ago ($rid): never twice in an hour"
  elif [[ "$res" != DONE ]] && (( d < ROTATE_LANE_RETRY )); then echo "rotation $rid failed $((d / 60)) min ago: next try after $((ROTATE_LANE_RETRY / 60)) min"; fi
  return 0
}

# 0 when ID's inbox or archive holds an ACCEPTED newer than any REJECT / SEND-BACK,
# unless ID is a standing seat (lifetime/standing exists).
spl_lane_rotate_accepted() {
  local a r
  # Standing seat: rotate even if ACCEPTED exists
  [[ -f "$SPOOL_ROOT/$1/lifetime/standing" ]] && return 1
  a="$(grep -lsE '"body" *: *"ACCEPTED' "$SPOOL_ROOT/$1"/inbox/*.json "$SPOOL_ROOT/$1"/archive/*.json 2>/dev/null | xargs -r ls -t 2>/dev/null | sed -n 1p || true)"
  [[ -n "$a" ]] || return 1
  r="$(grep -lsE '"body" *: *"(REJECT|SEND-BACK|SENDBACK)' "$SPOOL_ROOT/$1"/inbox/*.json "$SPOOL_ROOT/$1"/archive/*.json 2>/dev/null | xargs -r ls -t 2>/dev/null | sed -n 1p || true)"
  [[ -z "$r" || "$a" -nt "$r" ]]
}

# The warning, once per session (pid): a note + the pane poke.
spl_lane_rotate_warn() {
  local id="$1" pid="$2" age="$3" f="$SPOOL_ROOT/$1/lifetime/rotate.lane.warned" at
  [[ "$(cat "$f" 2>/dev/null || true)" == "$pid" ]] && return 0
  # an overdue session (older than MAX already) is rotated within minutes
  at=$(( ROTATE_LANE_MAX_AGE - age )); (( at > 120 )) || at=120
  at="$(date -u -d "@$(( $(date +%s) + at ))" +%H:%MZ)"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_lane_rotate_say "$id" "PLAN warn: rotation at $at"; return 0; fi
  echo "$pid" > "$f" 2>/dev/null || true
  SPOOL_ROOT="$SPOOL_ROOT" bash "$ROTATE_SEND" --from "${LEASE_ORCH:-$id}" --to "$id" --kind note --task "lane-rotate-$id" --no-ask \
    --body "rotation at $at UTC: push what is green, write your state (in your worktree and commits; do not reply to this note)" >/dev/null 2>&1 7>&- 8>&- 9>&- || true
  echo "$(date -u +%FT%TZ) $id WARN rotation at $at UTC (pid $pid, $((age / 60)) min)" | tee -a "$ROTATE_LANE_LOG"
}

# spl_lane_rotate_busy PID PANE WORKDIR: why the agent is not at a quiet
# point; nothing when it is (no test/push/apply under it, no unpushed
# commit, an idle pane).
spl_lane_rotate_busy() {
  local c n
  c="$(spl_lane_rotate_busy_child "$1")"
  [[ -z "$c" ]] || { echo "running '$c'"; return 0; }
  n="$(spl_lane_rotate_unpushed "$3")"
  [[ "$n" =~ ^[1-9] ]] && { echo "$n unpushed commit(s) in $3"; return 0; }
  spl_rotate_idle "$2" || echo "mid turn (the pane is not idle)"
  return 0
}

# The first descendant of PID whose command line matches ROTATE_LANE_BUSY_RE.
spl_lane_rotate_busy_child() {
  local root="${LEASE_PROC_ROOT:-/proc}" d p pp cl
  local -A kids=()
  # one awk over every stat file ("<pid> <ppid>"), not a fork per process
  while read -r d pp; do
    [[ "$pp" =~ ^[0-9]+$ ]] && kids[$pp]+=" $d"
  done < <(find "$root" -maxdepth 2 -path "$root/[0-9]*/stat" -print0 2>/dev/null |
    xargs -0 -r awk 'FNR == 1 {f = FILENAME; sub(/\/stat$/, "", f); sub(/^.*\//, "", f); sub(/^.*\) /, ""); print f, $2}' 2>/dev/null)
  local -a q=("$1")
  while (( ${#q[@]} )); do
    p="${q[0]}"; q=("${q[@]:1}")
    for d in ${kids[$p]:-}; do
      cl="$(tr '\0' ' ' < "$root/$d/cmdline" 2>/dev/null || true)"
      grep -qE -- "$ROTATE_LANE_BUSY_RE" <<<"$cl" && { cut -c1-120 <<<"$cl"; return 0; }
      q+=("$d")
    done
  done
  return 0
}

# Commits in WORKDIR that origin/<trunk> does not hold (0 for no git checkout).
spl_lane_rotate_unpushed() {
  local wt="$1" tr
  [[ -n "$wt" && -d "$wt" ]] || { echo 0; return 0; }
  tr="$(git -c safe.directory='*' -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
  git -c safe.directory='*' -C "$wt" rev-list --count "$tr..HEAD" 2>/dev/null || echo 0
}

# The agent's working dir: the identity map's worktree, else the registry's.
spl_lane_rotate_workdir() {
  local w
  w="$(jq -r '.worktree // empty' "$SPOOL_ROOT/agents/$1.json" 2>/dev/null || true)"
  [[ -n "$w" && -d "$w" ]] && { echo "$w"; return 0; }
  ROTATE_OLD_PID="$2" spl_rotate_workdir "$1"
}

# ---- the login probe (do_spl_agent_login_check's) -------------------------------

# 0 while the claude login probe says ok; LR_LOGIN keeps the verdict for the tick.
spl_lane_rotate_login_ok() {
  local at="" line=""
  if [[ -z "$LR_LOGIN" ]]; then
    if [[ -z "${ROTATE_LANE_PROBE_CMD:-}" && -r "$ROTATE_LANE_LOGIN_CACHE" ]]; then
      read -r at line < "$ROTATE_LANE_LOGIN_CACHE" || true
      [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ROTATE_LANE_PROBE_MAX_AGE )) || line=""
    fi
    [[ -n "$line" ]] || line="$(${ROTATE_LANE_PROBE_CMD:-bash $PROJ_PATH/src/bash/scripts/agent-login-cred.sh probe} 2>/dev/null | sed -n 1p || true)"
    LR_LOGIN="${line:-unknown no probe output}"
  fi
  [[ "${LR_LOGIN%% *}" == ok ]]
}

# One note to the dispatch lease holder per login verdict (deduplicated).
spl_lane_rotate_login_alert() {
  local f="$ROTATE_LANE_DIR/login.alert" v="${LR_LOGIN%% *}" to
  [[ "$(cat "$f" 2>/dev/null || true)" == "$v" ]] && return 0
  to="$(spl_lane_rotate_holder_to)"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then echo "PLAN alert $to: login $v, held:$LR_LOGIN_HELD"; return 0; fi
  echo "$v" > "$f" 2>/dev/null || true
  spl_rotate_note "$to" dispatch-lane-rotate \
    "**lane-rotate@$ROTATE_BOX**: the claude login probe says '$LR_LOGIN': no claude rotation starts until it is ok (held:$LR_LOGIN_HELD). The login self-heal (do_spl_agent_login_check) repairs it."
  echo "$(date -u +%FT%TZ) ALERT login $v to $to (held:$LR_LOGIN_HELD)" | tee -a "$ROTATE_LANE_LOG"
}

# ---- the age report (do_spl_agent_age_check) -----------------------------------

# Sessions older than ROTATE_LANE_REPORT_AGE in a scan, "<id>@<box> <kind> pid <pid> <min> min".
spl_lane_rotate_old() {
  awk -v max="$ROTATE_LANE_REPORT_AGE" -v box="$ROTATE_BOX" '$4 > max {printf "%s@%s %s pid %s %d min\n", $1, box, $2, $3, $4 / 60}' <<<"$1" | sort
}

# The incidents: sessions over ROTATE_LANE_REPORT_AGE that this cron could
# not rotate (no worker on them, none started, a role seat aside) for over
# ROTATE_LANE_REPORT_GRACE. ONE note per session (id + pid) to the orch lease
# holder; a normal tick sends nothing (c-002 msg bb8fe212: one a minute).
spl_lane_rotate_age_alert() {
  local old f="$ROTATE_LANE_DIR/age.reported" now id pid first new="" to line
  now="$(date +%s)"
  old="$(spl_lane_rotate_old "$1")"
  while read -r id _ _ pid _; do
    [[ -n "$id" ]] || continue
    id="${id%@*}"
    [[ "$LR_ROLES" == *" $id "* || "$LR_INFLIGHT" == *" $id "* || "$LR_STARTED_IDS" == *" $id "* ]] && continue
    first="$(sed -n "s/^over $id $pid //p" "$f" 2>/dev/null | sed -n 1p)"
    if [[ -z "$first" ]]; then [[ "${DRY_RUN:-1}" == 1 ]] || echo "over $id $pid $now" >> "$f"; continue; fi
    (( now - first >= ROTATE_LANE_REPORT_GRACE )) || continue
    grep -qx "told $id $pid" "$f" 2>/dev/null && continue
    line="$(grep "^$id@" <<<"$old" | sed -n 1p)"
    new+="${new:+; }$line ($(spl_lane_rotate_why_last "$id"))"
    [[ "${DRY_RUN:-1}" == 1 ]] || echo "told $id $pid" >> "$f"
  done <<<"$old"
  [[ -n "$new" ]] || return 0
  to="$(spl_lane_rotate_holder_to)"
  [[ "${DRY_RUN:-1}" == 1 ]] && { echo "PLAN age report to $to: $new"; return 0; }
  spl_rotate_note "$to" dispatch-lane-rotate \
    "**agent-age@$ROTATE_BOX**: not rotated, older than $((ROTATE_LANE_REPORT_AGE / 60)) min: $new. Log: $ROTATE_LANE_LOG"
  echo "$(date -u +%FT%TZ) ALERT age to $to: $new" | tee -a "$ROTATE_LANE_LOG"
}

# ID's last decision line (why it was not rotated), digits kept out.
spl_lane_rotate_why_last() { cat "$ROTATE_LANE_DIR/why.$1" 2>/dev/null | cut -c1-120 || echo "no decision"; }

# ---- the worker ------------------------------------------------------------------

# spl_lane_rotate_start ID KIND PID FORCED WHY: the worker of one seat, in
# the background (ROTATE_LANE_SYNC=1: in this shell, the tests).
spl_lane_rotate_start() {
  local id="$1" out="$ROTATE_LANE_DIR/worker.$1.out"
  LR_SLOTS=$((LR_SLOTS - 1)) LR_STARTED=$((LR_STARTED + 1)) LR_STARTED_IDS+="$id "
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_lane_rotate_say "$id" "PLAN rotate $2 pid $3$([[ "$4" == 1 ]] && echo " at its deadline, in flight: $5")"; return 0
  fi
  spl_lane_rotate_say "$id" "START rotate $2 pid $3$([[ "$4" == 1 ]] && echo " at its deadline, in flight: $5")"
  if [[ "${ROTATE_LANE_SYNC:-0}" == 1 ]]; then
    ( ID="$id" LANE_ROTATE_KIND="$2" LANE_ROTATE_PID="$3" LANE_ROTATE_FORCED="$4" LANE_ROTATE_WHY="$5" spl_lane_rotate_one ) >> "$out" 2>&1 7>&- 6>&- || true
    return 0
  fi
  local -a worker=("$ROTATE_RUN" -a do_spl_lane_rotate)
  [[ -n "${ROTATE_LANE_WORKER:-}" ]] && worker=("$ROTATE_LANE_WORKER")
  env ROTATE_CMD=one DRY_RUN=0 ID="$id" LANE_ROTATE_KIND="$2" LANE_ROTATE_PID="$3" LANE_ROTATE_FORCED="$4" LANE_ROTATE_WHY="$5" \
    setsid "${worker[@]}" >> "$out" 2>&1 < /dev/null 6>&- 7>&- 8>&- 9>&- &
  echo "$!" > "$ROTATE_LANE_DIR/run.$id"
  return 0
}

# ROTATE_CMD=one: rotate ID (resume first when its last rotation was left mid-way).
spl_lane_rotate_one() {
  local id="${ID:-}" rid pid age pane idl=0
  spl_lane_rotate_seat "$id" || return 1
  [[ "${DRY_RUN:-1}" == 1 ]] && { spl_rotate_log "lane-$id" GATE SKIP "DRY_RUN=1: no rotation"; return 0; }
  echo "$BASHPID" > "$ROTATE_LANE_DIR/run.$id" 2>/dev/null || true
  rid="$(date -u +%Y%m%dT%H%MZ)-lane-$id"
  spl_agent_id_lock "$id" do_spl_lane_rotate "$rid" || idl=$?
  (( idl == 0 )) || { spl_rotate_log "$rid" GATE SKIP "id lock: $SPL_ID_LOCK_WHY"; return 0; }
  if spl_rotate_ctx_load lane && [[ -n "$ROTATE_PHASE" && ! "$ROTATE_PHASE" =~ ^(DONE|FAIL|ABORT)$ ]]; then
    spl_lane_rotate_resume "$id"; return 0
  fi
  local -a pids
  mapfile -t pids < <(spl_rotate_pids "$id")
  (( ${#pids[@]} == 1 )) || { spl_rotate_log "$rid" GATE SKIP "${#pids[@]} live $ROTATE_KIND processes carry $id"; return 0; }
  pid="${pids[0]}"
  [[ -z "${LANE_ROTATE_PID:-}" || "$pid" == "$LANE_ROTATE_PID" ]] || { spl_rotate_log "$rid" GATE SKIP "pid $pid is not the tick's $LANE_ROTATE_PID: re-judged next tick"; return 0; }
  age="$(spl_rotate_age "$pid")"; age="${age:-0}"
  (( age >= ROTATE_LANE_WARN_AGE )) || { spl_rotate_log "$rid" GATE SKIP "young: pid $pid is ${age}s old"; return 0; }
  [[ -z "$(spl_lane_rotate_recent "$id")" ]] || { spl_rotate_log "$rid" GATE SKIP "$(spl_lane_rotate_recent "$id")"; return 0; }
  pane="$(spl_rotate_pane_of_pid "$pid")"
  [[ -n "$pane" ]] || { spl_rotate_log "$rid" GATE SKIP "pid $pid is in no tmux pane"; return 0; }
  if spl_lane_rotate_brief_is_seed "$id"; then
    spl_rotate_log "$rid" GATE SKIP "$SPOOL_ROOT/$id/lifetime/brief.md is a rotation seed, not a task brief: restore it first"; return 0
  fi
  # shellcheck disable=SC2034 # the lib's globals (spl_rotate_ctx_save, spl_rotate_spawn, spl_rotate_restore)
  ROTATE_RID="$rid" ROTATE_OLD_PID="$pid" ROTATE_OLD_PANE="$pane" ROTATE_NEW_PID="" ROTATE_NEW_PANE="" ROTATE_QUIESCE="" ROTATE_SWITCH_FROM=""
  # shellcheck disable=SC2034 # read by spl_rotate_spawn / spl_rotate_restore
  ROTATE_OLD_NAME="$(spl_rotate_tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null || true)"
  ROTATE_HANDOFF="$ROTATE_HANDOFF_DIR/$rid.md"
  ROTATE_ACK_TIMEOUT="$ROTATE_LANE_ACK_TIMEOUT"
  spl_lane_rotate_step GATE OK "$ROTATE_KIND pid $pid, $((age / 60)) min old, pane $pane$([[ "${LANE_ROTATE_FORCED:-0}" == 1 ]] && echo "; deadline, in flight: ${LANE_ROTATE_WHY:-}")"
  spl_lane_rotate_run "$id"
}

# Record the phase (log + .state + ctx).
spl_lane_rotate_step() {
  ROTATE_PHASE="$1"
  spl_rotate_ctx_save lane
  spl_rotate_log "$ROTATE_RID" "$1" "$2" "${3:-}"
}

# QUIESCE -> HANDOFF -> SPAWN -> ACK -> RETIRE -> CLOSE, one seat.
spl_lane_rotate_run() {
  local id="$1" seed head rc=0
  ROTATE_QUIESCE="$(spl_rotate_quiesce "$ROTATE_OLD_PANE")"
  spl_lane_rotate_step QUIESCE "$([[ "$ROTATE_QUIESCE" == busy-rotated ]] && echo WAIT || echo OK)" "$ROTATE_QUIESCE"
  mkdir -p "$ROTATE_HANDOFF_DIR" 2>/dev/null || true
  spl_rotate_handoff_prune
  spl_lane_rotate_handoff "$id" "$ROTATE_RID" "$ROTATE_HANDOFF"
  seed="$ROTATE_HANDOFF_DIR/$ROTATE_RID.seed.md" head="$ROTATE_HANDOFF_DIR/$ROTATE_RID.head.md"
  spl_lane_rotate_seed "$id" "$seed"
  spl_lane_rotate_prompt_head "$id" "$seed" > "$head"
  chmod 0644 "$ROTATE_HANDOFF" "$seed" "$head" 2>/dev/null || true
  spl_lane_rotate_step HANDOFF OK "$ROTATE_HANDOFF ($(wc -l < "$ROTATE_HANDOFF") lines)"
  # shellcheck disable=SC2034 # read by spl_rotate_spawn (the lane map row keeps the lane's scope)
  ROTATE_LANE_SCOPE="$(grep -m1 -E '^#+ ' "$SPOOL_ROOT/$id/lifetime/brief.md" 2>/dev/null | sed -E 's/^#+ +//; s/^Brief: *//' | cut -c1-120 || true)"
  # spawn-core records a BRIEF as lifetime/brief.md unless SPAWN_REUSE_ID
  # reaches it, which the launcher in the new window does not get: the seed
  # replaced the task brief (P0, 2026-10-11). The brief is put back
  # byte for byte right after the spawn; the new session reads the seed file.
  cp -p "$SPOOL_ROOT/$id/lifetime/brief.md" "$ROTATE_STATE_DIR/brief.keep.md" 2>/dev/null || true
  SPAWN_PROMPT_HEAD_FILE="$head" spl_rotate_spawn "$id" "$seed" || rc=1
  spl_lane_rotate_brief_back "$id"
  (( rc == 0 )) || { spl_lane_rotate_fail "$id" SPAWN "$ROTATE_ERR"; return 1; }
  spl_lane_rotate_step SPAWN OK "new $ROTATE_KIND pid $ROTATE_NEW_PID pane $ROTATE_NEW_PANE; old window $(spl_rotate_retiring_name "$id")"
  spl_lane_rotate_from_spawn "$id"
}

# The task brief back from brief.keep.md when the spawn changed it.
spl_lane_rotate_brief_back() {
  local b="$SPOOL_ROOT/$1/lifetime/brief.md" k="$ROTATE_STATE_DIR/brief.keep.md"
  [[ -s "$k" ]] || return 0
  cmp -s "$k" "$b" && return 0
  cp -f "$k" "$b" 2>/dev/null && chmod 0664 "$b" 2>/dev/null
  spl_rotate_log "$ROTATE_RID" SPAWN WAIT "the spawn rewrote $b: the task brief put back"
  return 0
}

spl_lane_rotate_from_spawn() {
  local id="$1" rc=0
  spl_lane_rotate_step ACK WAIT "up to ${ROTATE_ACK_TIMEOUT}s for $(spl_rotate_ack_task "$ROTATE_RID")"
  spl_rotate_ack_wait "$id" "$ROTATE_RID" "$ROTATE_ACK_TIMEOUT" || rc=$?
  case "$rc" in
    0) ;;
    2) spl_lane_rotate_fail "$id" ACK "the new session (pid $ROTATE_NEW_PID) ended before it acked"; return 1 ;;
    *) spl_lane_rotate_fail "$id" ACK "no ack within ${ROTATE_ACK_TIMEOUT}s"; return 1 ;;
  esac
  spl_lane_rotate_step ACK OK "acked by pid $ROTATE_NEW_PID"
  spl_lane_rotate_from_ack "$id"
}

# RETIRE: /exit (a lane's /exit-clean would land and report a task that goes
# on), the restore wrapper stopped before the TERM (it would relaunch the old
# session in place), TERM, KILL.
spl_lane_rotate_from_ack() {
  local id="$1"
  spl_lane_rotate_step RETIRE WAIT "/exit into $ROTATE_OLD_PANE (pid $ROTATE_OLD_PID)"
  if ! ROTATE_PRE_TERM=spl_lane_rotate_unwrap spl_rotate_end "$ROTATE_OLD_PANE" "$ROTATE_OLD_PID" /exit "$ROTATE_LANE_EXIT_WAIT" "$ROTATE_TERM_WAIT"; then
    spl_lane_rotate_step RETIRE FAIL "pid $ROTATE_OLD_PID survived SIGKILL: two sessions carry $id until a human clears it"
    spl_lane_rotate_last FAIL
    spl_rotate_note "$(spl_lane_rotate_holder_to)" dispatch-lane-rotate "**lane-rotate@$ROTATE_BOX**: $ROTATE_RID: the old session of $id (pid $ROTATE_OLD_PID) survived SIGKILL; the new one is pid $ROTATE_NEW_PID."
    return 1
  fi
  spl_lane_rotate_step RETIRE OK "pid $ROTATE_OLD_PID gone"
  spl_lane_rotate_close "$id"
}

# The pane's root process (a restore-core wrapper whose `||` fallback would
# start the old session again once it is signalled) goes first.
spl_lane_rotate_unwrap() {
  local root
  root="$(spl_rotate_tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null || true)"
  [[ "$root" =~ ^[0-9]+$ && "$root" != "$2" ]] || return 0
  spl_rotate_log "$ROTATE_RID" RETIRE WAIT "the pane's wrapper pid $root stopped before the TERM"
  ${ROTATE_KILL:-sudo -n kill} -TERM "$root" 2>/dev/null || true
}

# CLOSE: the old window by pane id, the checks, DONE.
spl_lane_rotate_close() {
  local id="$1" n mp warn=""
  if spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{pane_id}' >/dev/null 2>&1; then
    spl_rotate_tmux kill-window -t "$ROTATE_OLD_PANE" 2>/dev/null || true
  fi
  n="$(spl_rotate_pids "$id" | grep -c . || true)"
  [[ "$n" == 1 ]] || warn+=" processes=$n"
  mp="$(spl_rotate_ai pane-of "$id" 2>/dev/null || true)"
  [[ "$mp" == "$ROTATE_NEW_PANE" ]] || warn+=" map=${mp:-none}"
  spl_lane_rotate_step CLOSE "$([[ -z "$warn" ]] && echo OK || echo WAIT)" "old window closed; checks:${warn:- one process, map -> $ROTATE_NEW_PANE}"
  spl_lane_rotate_step DONE OK "$id@$ROTATE_BOX is $ROTATE_KIND pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE (was pid $ROTATE_OLD_PID)"
  spl_lane_rotate_last DONE
  return 0
}

spl_lane_rotate_last() { echo "$(date +%s) $ROTATE_RID $1" > "$ROTATE_STATE_DIR/rotate.lane.last" 2>/dev/null || true; }

# A failure before RETIRE: the new session closed, the old one keeps the
# lane (name and map back), one note to the dispatch lease holder; after an
# ack timeout the lane is told where its handoff is. Returns 0.
spl_lane_rotate_fail() {
  local id="$1" phase="$2" reason="$3"
  spl_rotate_restore "$id" "$ROTATE_OLD_PANE" "$ROTATE_NEW_PANE"
  spl_lane_rotate_step FAIL FAIL "$phase: $reason; the old session (pid $ROTATE_OLD_PID) keeps the lane"
  spl_lane_rotate_last FAIL
  spl_rotate_note "$(spl_lane_rotate_holder_to)" dispatch-lane-rotate \
    "**lane-rotate@$ROTATE_BOX**: rotation $ROTATE_RID of $id failed at $phase: $reason. The old session (pid $ROTATE_OLD_PID) keeps the lane; next try in $((ROTATE_LANE_RETRY / 60)) min."
  if [[ "$phase" == ACK ]] && spl_rotate_alive "$ROTATE_OLD_PID"; then
    spl_rotate_note "$id" "lane-rotate-$id" "Rotation $ROTATE_RID failed; you keep your task. Read $ROTATE_HANDOFF for anything you were interrupted on."
  fi
  return 0
}

# A rotation left mid-way (a worker that died, a reboot): finish what can be
# checked, else fail it the safe way (the old session keeps the lane).
spl_lane_rotate_resume() {
  local id="$1" old=0 new=0 why
  if why="$(spl_rotate_booted_after "$ROTATE_RID")"; then
    spl_rotate_log "$ROTATE_RID" ABORT BOOT "interrupted by boot at $ROTATE_PHASE: $why; ctx removed"
    rm -f "$ROTATE_STATE_DIR/rotate.lane.ctx"; return 0
  fi
  spl_rotate_alive "$ROTATE_OLD_PID" && old=1
  [[ -n "$ROTATE_NEW_PID" ]] && spl_rotate_alive "$ROTATE_NEW_PID" && new=1
  spl_rotate_log "$ROTATE_RID" RESUME OK "from $ROTATE_PHASE (old alive=$old, new alive=$new)"
  case "$ROTATE_PHASE:$old$new" in
    SPAWN:11|ACK:11) spl_lane_rotate_from_spawn "$id" || true ;;
    RETIRE:11)       spl_lane_rotate_from_ack "$id" || true ;;
    RETIRE:01|CLOSE:01|ACK:01) spl_lane_rotate_close "$id" ;;
    *:10|GATE:*|QUIESCE:*|HANDOFF:*) spl_lane_rotate_fail "$id" "$ROTATE_PHASE" "resumed with no live new session" ;;
    *) spl_lane_rotate_step FAIL FAIL "resumed at $ROTATE_PHASE with neither session alive"; spl_lane_rotate_last FAIL ;;
  esac
  return 0
}

# ---- handoff and seed ----------------------------------------------------------------

# spl_lane_rotate_handoff ID RID OUT: the lane's handoff from files, /proc and
# tmux ("-" prints). In flight first: the screen, the git state, the outbox.
spl_lane_rotate_handoff() {
  local id="$1" rid="$2" out="$3" pid="${ROTATE_OLD_PID:-}" pane="${ROTATE_OLD_PANE:-}" wt tr
  [[ -n "$pane" || -z "$pid" ]] || pane="$(spl_rotate_pane_of_pid "$pid")"
  wt="$(spl_lane_rotate_workdir "$id" "$pid")"
  tr=""; [[ "$ROTATE_KIND" == claude ]] && tr="$(spl_rotate_transcript "$id")"
  if [[ "$out" == - ]]; then spl_lane_rotate_handoff_body; else spl_lane_rotate_handoff_body > "$out"; fi
  return 0
}

# Every kind=result message in an outbox (the rotation acks aside), newest 10.
spl_lane_rotate_results() {
  local out
  out="$(find "$1" -maxdepth 1 -name '*.json' -print0 2>/dev/null | xargs -0 -r jq -r 'select(.kind == "result" and ((.task_id // "") | test("-rotate-") | not))
    | "- \(.ts // "" | .[5:16]) -> \(.to // "") [\(.task_id // "" | .[0:12])] \((.body // "") | split("\n") | map(select(test("\\S"))) | join(" ") | .[0:160])"' 2>/dev/null | sort | tail -n 10)"
  printf '%s\n' "${out:-none}"
}

spl_lane_rotate_handoff_body() {
  echo "# $id@$ROTATE_BOX handoff, rotation $rid ($ROTATE_KIND lane)"
  echo
  echo "Written by the rotation script from files, /proc and tmux (spec 060 section 6); no model wrote it."
  echo "- old session: pid ${pid:-?}, $(( $(spl_rotate_age "$pid" | grep . || echo 0) / 60 )) min old, pane ${pane:-?}; quiesce: ${ROTATE_QUIESCE:-not run}"
  [[ "${LANE_ROTATE_FORCED:-0}" == 1 ]] && echo "- rotated at its 60-min deadline while: ${LANE_ROTATE_WHY:-?}"
  echo "- task brief: $SPOOL_ROOT/$id/lifetime/brief.md; worktree: ${wt:-?}"
  echo
  echo "## 1. In flight: the old pane's last terminal lines (after quiesce)"
  if [[ -n "$pane" ]]; then
    echo '```text'
    spl_rotate_tmux capture-pane -p -J -S -300 -t "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' |
      tail -n "${ROTATE_SCREEN_LINES:-60}" | sed -E 's/^(.{200}).*/\1/' || true
    echo '```'
  else echo "UNAVAILABLE: no pane"; fi
  echo
  echo "## 2. Git: the worktree's status and its commits not on origin"
  if [[ -n "$wt" && -d "$wt/.git" || -f "$wt/.git" ]]; then
    git -c safe.directory='*' -C "$wt" status --short --branch 2>/dev/null | head -n 30 || true
    git -c safe.directory='*' -C "$wt" log --oneline -n 10 "$(git -c safe.directory='*' -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)..HEAD" 2>/dev/null || true
  else echo "UNAVAILABLE: no git worktree"; fi
  echo
  echo "## 3. Sent by the old session: its last hour, and every result it ever sent (never send those again)"
  spl_rotate_msgs "$SPOOL_ROOT/$id/outbox" to 60 40 160
  echo "Results already sent:"
  spl_lane_rotate_results "$SPOOL_ROOT/$id/outbox"
  echo
  echo "## 4. Unread inbox: $(find "$SPOOL_ROOT/$id/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) message(s), the 20 newest"
  spl_rotate_msgs "$SPOOL_ROOT/$id/inbox" from "" 20 120
  echo
  echo "## 5. Session tail (the old transcript: last 10 user lines, last 10 assistant texts)"
  if [[ -n "$tr" ]]; then spl_rotate_transcript_tail "$tr"; else echo "UNAVAILABLE: no transcript for a $ROTATE_KIND session; read sections 1-4"; fi
  return 0
}

# 0 when ID's lifetime/brief.md is one of this rotation's seeds.
spl_lane_rotate_brief_is_seed() {
  local l=""
  { IFS= read -r l < "$SPOOL_ROOT/$1/lifetime/brief.md"; } 2>/dev/null || true
  [[ "$l" =~ ^\#\ Brief:\ you\ are\ .*\ again\ \(hourly\ rotation\  ]]
}

# The ack the new session runs, as its seed and its first prompt state it.
spl_lane_rotate_ack_cmd() {
  echo "cd $PROJ_PATH && sudo -u ${SPOOL_BOX_USER:-$USER} env SPOOL_ROOT=$SPOOL_ROOT ROTATE_CMD=ack ROTATE_ID=$ROTATE_RID ID=$1 ./run -a do_spl_lane_rotate"
}

# spl_lane_rotate_prompt_head ID SEED: the head of the new session's FIRST
# prompt (spawn-core SPAWN_PROMPT_HEAD_FILE), the ack line itself. A pointer to
# the seed was not enough: n=4 new sessions on 2026-10-11 never opened the
# seed and never acked (msg 1764e609).
spl_lane_rotate_prompt_head() {
  printf '%s\n\nROTATION %s: you are the new %s session. Run the ack, exactly; run it before anything else (even the rename):\nACK-COMMAND: %s\nThen read your rotation seed %s (your task brief and the handoff) and continue.' \
    "$(spool_truth_rule)" "$ROTATE_RID" "$1" "$(spl_lane_rotate_ack_cmd "$1")" "$2"
}

# spl_lane_rotate_seed ID OUT: the new session's brief: its task brief
# unchanged (lifetime/brief.md; the old seed when no brief was recorded), the
# handoff, the ACK command. The brief's Files: line keeps the lane map row.
spl_lane_rotate_seed() {
  local id="$1" out="$2" brief="$SPOOL_ROOT/$1/lifetime/brief.md" ack files
  if [[ ! -s "$brief" ]]; then
    if [[ -s "$SPOOL_ROOT/$id/lifetime/prompt.txt" ]]; then cp -f "$SPOOL_ROOT/$id/lifetime/prompt.txt" "$brief" 2>/dev/null || true
    else echo "# Brief: $id (no brief was recorded at spawn: ask your spawner)" > "$brief" 2>/dev/null || true; fi
  fi
  files="$(grep -m1 -E '^Files: *' "$brief" 2>/dev/null || true)"
  ack="$(spl_lane_rotate_ack_cmd "$id")"
  cat > "$out" <<EOF
# Brief: you are $id@$ROTATE_BOX again (hourly rotation $ROTATE_RID)
${files}

You are the new $id@$ROTATE_BOX session: same id, same inbox, same worktree and branch, same task. The hourly rotation (owner HUM-10: no session runs past 60 min) replaced the previous session with you. Do not greet; post nothing about the rotation.

1. Your task brief, unchanged: $brief. Its steps you already did stay done (the git log, your outbox and the handoff show which).
2. The handoff: $ROTATE_HANDOFF - what the previous session was doing when it was stopped (its screen, git state, outbox, unread inbox, transcript tail).
3. Run the ack, exactly, before anything else:
ACK-COMMAND: $ack
   Without the ack within $((ROTATE_ACK_TIMEOUT / 60)) min you are closed and the previous session keeps the task.
4. Then continue the task where the previous session stopped. A result the previous session already sent (handoff section 3) is NOT sent again: when the task is done and waits for its verdict, stay idle and answer only send-backs.
EOF
}
