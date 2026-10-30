#!/bin/bash
#------------------------------------------------------------------------------
# @description Watchdog self-update on desk-cron changes (spec 102 10.4.4,
# @description WD3, T025). The watchdogs never run from the moving desk-cron
# @description checkout: each sha is exported (git archive <sha> of
# @description <org>-<app>-orc plus what code run from it reads beside it:
# @description <org>-<app>-iac/lib/bash and <org>-<app>-cnf/<org>-<app>; drill 5)
# @description into <wd dir>/code/<sha>/, and code/good names the verified one
# @description (spl_wd_inst_start starts every instance from it). At its tick
# @description start instance 1 compares the checkout HEAD with code/good:
# @description the code (orc + iac lib) unchanged -> code/good moves, nothing restarts;
# @description changed -> a rolling restart under update.lock: all 3
# @description instances must be alive (else deferred + alert), the candidate
# @description passes a pre-flight (bash -n of every script + one dry proof
# @description tick from the snapshot), then instance 1 execs into it
# @description (same pid, same lock fds), its next tick is the self-check
# @description (no script error, heartbeat written, on the new sha; judged by
# @description its result, not its wall time: a tick ends past WD_UPD_STEP_MAX s
# @description only when it hangs, which the peers fail anyway; load alone
# @description never quarantines a sha),
# @description and the baton (update.state) goes to 2, then 3, which wait in
# @description WD_UPD_SLICE s sleep slices; after 3, candidate becomes good.
# @description A self-check step that only runs past WD_UPD_STEP_MAX s (no
# @description script error: a loaded box) is retried, up to
# @description WD_UPD_STEP_TRIES windows of WD_UPD_STEP_MAX s in all, and its
# @description line names the box load; a self-check that fails is not.
# @description Stop rule: a failed pre-flight or self-check, an instance that
# @description dies in its check, or a step past its last try halts the
# @description rollout, quarantines the sha (code/<sha>.bad: never rolled
# @description again), alerts the orchestrator, and every instance on that
# @description sha execs back into code/good. A pre-flight proof tick that
# @description only TIMED OUT (rc 124/137, no script error: a loaded box) is no
# @description failure: RETRY, the sha stays un-quarantined and is pre-flighted
# @description again on a later tick, quarantined only after
# @description WD_UPD_TIMEOUT_TRIES timeouts in a row. The proof tick's limit
# @description fits the box: WD_UPD_CHECK_MAX x 2 x the load per cpu (loadavg
# @description 1 min / nproc, when over 0.5), at most WD_UPD_CHECK_CAP s, never
# @description under WD_UPD_CHECK_MAX (spl_wd_upd_check_limit). Every step is an UPDATE
# @description line in wd.log. The action prints the state, read-only.
# @param WD_SELF_UPDATE (optional) - 1 rolls out new desk-cron code; default 1, and 0 under SPOOL_TEST=1
# @param WD_UPD_SRC (optional) - the desk-cron checkout; default DESK_CRON_SRC, then <wd dir>/starter.src
# @param WD_UPD_SLICE (optional) - seconds per sleep slice of a waiting instance, default 5
# @param WD_UPD_CHECK_MAX (optional) - seconds for the pre-flight proof tick on an idle box (the base, scaled by the load per cpu), default 20
# @param WD_UPD_CHECK_CAP (optional) - seconds the load-scaled pre-flight limit never exceeds, default 60 (under the peers' 180 s hang bound)
# @param WD_UPD_LOAD1 (optional) - tests only: the 1-min load average instead of /proc/loadavg
# @param WD_UPD_NPROC (optional) - tests only: the cpu count instead of nproc
# @param WD_UPD_TIMEOUT_TRIES (optional) - pre-flight proof ticks that time out in a row before the sha is quarantined, default 5
# @param WD_UPD_STEP_MAX (optional) - seconds one step (exec + check, or a baton wait) may take, default 45; the self-check tick's hang bound
# @param WD_UPD_STEP_TRIES (optional) - windows of WD_UPD_STEP_MAX s a self-check step that only times out gets before the sha is quarantined, default 2 (one retry); not WD_UPD_TIMEOUT_TRIES, which counts pre-flight timeouts
# @param WD_UPD_KEEP (optional) - snapshots kept besides the ones in use, default 3
# @param WD_UPD_PREFLIGHT (optional) - 1 (default): pre-flight the candidate; 0 skips it (tests only)
# @example ./run -a do_spl_wd_self_update
#------------------------------------------------------------------------------
declare -F spl_wd_peer_state >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-peers.func.sh"

# the bash error lines a self-check tick must not show
SPL_WD_UPD_ERR_RE=': line [0-9]+: |syntax error|command not found|unbound variable|bad substitution'

do_spl_wd_self_update() {
  local src head s
  spl_rotate_conf || return 1
  WD_DIR="${WD_STATE_DIR:-$LEASE_DIR/wd}"
  src="$(spl_wd_upd_src)"
  head=""
  [[ -n "$src" ]] && head="$(spl_wd_upd_git "$src" rev-parse HEAD 2>/dev/null || true)"
  echo "checkout: ${src:-<none>} HEAD ${head:-unknown}"
  echo "good: $(spl_wd_upd_link good)"
  echo "candidate: $(spl_wd_upd_link candidate)"
  echo "rollout: $(cat "$WD_DIR/update.state" 2>/dev/null || echo none)"
  for s in "$WD_DIR"/code/*.bad; do
    [[ -f "$s" ]] && echo "bad: $(basename "$s" .bad) $(head -n 1 "$s")"
  done
  for s in "$WD_DIR"/code/*.slow; do
    [[ -f "$s" ]] && echo "pre-flight timed out: $(basename "$s" .slow) $(head -n 1 "$s") time(s)"
  done
  return 0
}

spl_wd_upd_conf() {
  local k
  if [[ -z "${WD_SELF_UPDATE:-}" ]]; then
    WD_SELF_UPDATE=1
    [[ "${SPOOL_TEST:-}" == 1 ]] && WD_SELF_UPDATE=0
  fi
  : "${WD_UPD_SLICE:=5}" "${WD_UPD_CHECK_MAX:=20}" "${WD_UPD_CHECK_CAP:=60}" "${WD_UPD_STEP_MAX:=45}" "${WD_UPD_KEEP:=3}" "${WD_UPD_PREFLIGHT:=1}" "${WD_UPD_TIMEOUT_TRIES:=5}" "${WD_UPD_STEP_TRIES:=2}"
  for k in WD_SELF_UPDATE WD_UPD_SLICE WD_UPD_CHECK_MAX WD_UPD_CHECK_CAP WD_UPD_STEP_MAX WD_UPD_KEEP WD_UPD_PREFLIGHT WD_UPD_TIMEOUT_TRIES WD_UPD_STEP_TRIES; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  (( WD_UPD_SLICE > 0 )) || { do_log "FATAL WD_UPD_SLICE must be at least 1"; return 1; }
  (( WD_UPD_STEP_TRIES > 0 )) || { do_log "FATAL WD_UPD_STEP_TRIES must be at least 1"; return 1; }
  return 0
}

# spl_wd_code_sha RUN_DIR: the full sha this code is: <snapshot>/.sha when
# RUN_DIR is in a snapshot, else the git HEAD of its checkout, else unknown.
spl_wd_code_sha() {
  local s
  s="$(cat "$1/../../../../.sha" 2>/dev/null || true)"
  if [[ "$s" =~ ^[0-9a-f]{40}$ ]]; then echo "$s"; return 0; fi
  s="$(git -c safe.directory='*' -C "$1" rev-parse HEAD 2>/dev/null || true)"
  echo "${s:-unknown}"
}

# git in the desk-cron checkout, owned by another user than the watchdog's
spl_wd_upd_git() { local src="$1"; shift; git -c safe.directory="$src" -C "$src" "$@"; }

spl_wd_upd_src() {
  local s="${WD_UPD_SRC:-${DESK_CRON_SRC:-$(cat "$WD_DIR/starter.src" 2>/dev/null || true)}}"
  [[ -n "$s" && -d "$s" ]] && echo "$s"
  return 0
}

# the sha a code/<name> symlink points at, or empty
spl_wd_upd_link() {
  local t
  t="$(readlink "$WD_DIR/code/$1" 2>/dev/null || true)"
  echo "${t##*/}"
}

# the orc dir name inside a snapshot (the checkout's <org>-<app>-orc)
spl_wd_upd_orc() { basename "${PROJ_PATH:-csi-spl-orc}"; }

# the code paths of a snapshot that a change restarts the watchdogs for:
# the orc tree and the iac bash lib its scripts source (spl-cloud-cnf, lde-cnf)
spl_wd_upd_code_paths() {
  local orc
  orc="$(spl_wd_upd_orc)"
  echo "$orc ${orc%-orc}-iac/lib/bash"
}

# every path a snapshot carries: the code paths plus the cnf the scripts read
# next to the orc tree (spawn-mistral.sh's max_price, the merged cnf). Drill 5
# (2026-10-09): an orc-only snapshot made every Mistral boot restore refuse
# "no cost cap" and lane-map die on a missing iac lib. No wui, api or doc.
spl_wd_upd_paths() {
  local oa
  oa="$(spl_wd_upd_orc)"; oa="${oa%-orc}"
  echo "$(spl_wd_upd_code_paths) $oa-cnf/$oa"
}

# spl_wd_upd_snapshot SRC SHA: <wd dir>/code/<sha>/ from git archive, once;
# of spl_wd_upd_paths only those the sha has (git archive refuses a missing one)
spl_wd_upd_snapshot() {
  local src="$1" sha="$2" code="$WD_DIR/code" tmp orc paths
  [[ -f "$code/$sha/.sha" ]] && return 0
  orc="$(spl_wd_upd_orc)"
  # shellcheck disable=SC2046
  mapfile -t paths < <(spl_wd_upd_git "$src" ls-tree --name-only "$sha" -- $(spl_wd_upd_paths) 2>/dev/null)
  tmp="$code/.tmp.$sha.$$"
  mkdir -p "$tmp" || return 1
  if ((${#paths[@]} == 0)) ||
     ! spl_wd_upd_git "$src" archive --format=tar "$sha" "${paths[@]}" 2>/dev/null | tar -x -C "$tmp" 2>/dev/null ||
     [[ ! -x "$tmp/$orc/run" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  echo "$sha" > "$tmp/.sha"
  rm -rf "${code:?}/$sha"
  mv "$tmp" "$code/$sha" || { rm -rf "$tmp"; return 1; }
  return 0
}

# update.state: one line "sha=<sha> next=<inst> stage=<exec|wait> pid=<pid>
# since=<epoch> start=<epoch> try=<n>" (try: the step's timed-out windows so
# far; a line without it, from an older code, reads try 0). A number is
# decimal with no leading zero: "try=08" passed ^[0-9]+$ and then broke the
# arithmetic ("value too great for base"), so every peer tick stalled on it.
spl_wd_upd_state_read() {
  local line kv n='^(0|[1-9][0-9]*)$'
  U_SHA="" U_NEXT="" U_STAGE="" U_PID="" U_SINCE="" U_START="" U_TRY=0
  line="$(cat "$WD_DIR/update.state" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  for kv in $line; do
    case "$kv" in
      sha=*) U_SHA="${kv#sha=}" ;;
      next=*) U_NEXT="${kv#next=}" ;;
      stage=*) U_STAGE="${kv#stage=}" ;;
      pid=*) U_PID="${kv#pid=}" ;;
      since=*) U_SINCE="${kv#since=}" ;;
      start=*) U_START="${kv#start=}" ;;
      try=*) U_TRY="${kv#try=}" ;;
    esac
  done
  [[ "$U_SHA" =~ ^[0-9a-f]{40}$ && "$U_NEXT" =~ ^[1-3]$ && "$U_STAGE" =~ ^(exec|wait)$ && "$U_PID" =~ $n && "$U_SINCE" =~ $n && "$U_START" =~ $n && "$U_TRY" =~ $n ]] || return 1
  return 0
}

spl_wd_upd_state_write() {
  local f="$WD_DIR/update.state"
  echo "sha=$1 next=$2 stage=$3 pid=$4 since=$5 start=$6 try=${7:-0}" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# spl_wd_upd_load: the box load for a timeout line, "load <1 min>/<n> cpus"
spl_wd_upd_load() {
  local l1 np
  l1="${WD_UPD_LOAD1:-$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)}"
  np="${WD_UPD_NPROC:-$(nproc 2>/dev/null || true)}"
  echo "load ${l1:-?}/${np:-?} cpus"
}

spl_wd_upd_log() {
  echo "UPDATE $*"
  spl_wd_log "UPDATE instance ${WD_INST:-0}: $*" 2>/dev/null || true
}

# spl_wd_self_update NOW: the update part of one tick of instance WD_INST,
# after its peer checks. May exec (never returns then).
spl_wd_self_update() {
  local now="$1"
  [[ -n "${WD_INST:-}" && "${WD_SELF_UPDATE:-0}" == 1 ]] || return 0
  [[ -n "${WD_UPD_EXEC:-}" ]] && return 0
  mkdir -p "$WD_DIR/code" 2>/dev/null || return 0
  # a quarantined sha never keeps running: back to good
  if [[ -f "$WD_DIR/code/$WD_CODE_SHA.bad" ]]; then
    spl_wd_upd_exec "$(spl_wd_upd_link good)" rollback "$now" "sha ${WD_CODE_SHA:0:9} is quarantined"
    return 0
  fi
  exec 5>>"$WD_DIR/update.lock"
  if flock -n 5; then
    spl_wd_upd_step "$now"
  fi
  exec 5>&-
  return 0
}

# spl_wd_upd_step NOW: under update.lock (fd 5)
spl_wd_upd_step() {
  local now="$1"
  if spl_wd_upd_state_read; then
    spl_wd_upd_baton "$now"
    return 0
  fi
  [[ "$WD_INST" == 1 ]] || return 0
  spl_wd_upd_detect "$now"
  return 0
}

# a rollout is on: take the baton, or end a step that died or timed out
spl_wd_upd_baton() {
  local now="$1"
  if [[ "$U_STAGE" == exec && "$U_NEXT" == "$WD_INST" && "$U_PID" != "$$" ]]; then
    spl_wd_upd_fail "$U_SHA" "$now" "instance $WD_INST died during its self-check (pid $U_PID; now pid $$, started on good)"
    return 0
  fi
  # a crash with no restart yet: no heartbeat, quarantined at once, never a
  # timeout retry (/proc, not kill -0: that is EPERM for another user's pid)
  if [[ "$U_STAGE" == exec && ! -d "/proc/$U_PID" ]]; then
    spl_wd_upd_fail "$U_SHA" "$now" "instance $U_NEXT died during its self-check (pid $U_PID is gone)"
    return 0
  fi
  if (( now - U_SINCE > WD_UPD_STEP_MAX )); then
    if [[ "$U_STAGE" == exec ]]; then
      spl_wd_upd_step_timeout "$now" "instance $U_NEXT did not finish its self-check in ${WD_UPD_STEP_MAX}s"
    else
      # a peer that is down cannot take the baton: not the code's fault, no quarantine
      rm -f "$WD_DIR/update.state" "$WD_DIR/code/candidate"
      spl_wd_upd_log "HALT ${U_SHA:0:9}: instance $U_NEXT did not take the baton in ${WD_UPD_STEP_MAX}s ($(spl_wd_upd_load)); retried when all 3 run"
      spl_wd_peer_alert "update_${U_SHA:0:9}" "$now" \
        "WATCHDOG (102 10.4.4): the rollout of ${U_SHA:0:9} on box $(spl_wd_peer_box) halted: instance $U_NEXT did not take the baton in ${WD_UPD_STEP_MAX}s. The sha is not quarantined; it is retried when all 3 instances run."
    fi
    return 0
  fi
  [[ "$U_STAGE" == wait && "$U_NEXT" == "$WD_INST" ]] || return 0
  spl_wd_upd_state_write "$U_SHA" "$WD_INST" exec "$$" "$now" "$U_START"
  exec 5>&-
  spl_wd_upd_exec "$U_SHA" forward "$now" "baton from instance $(( WD_INST - 1 ))"
  # the exec failed: the step times out and halts the rollout
  return 0
}

# spl_wd_upd_step_timeout NOW WHY: a peer saw the self-check step (U_*) run
# past its WD_UPD_STEP_MAX s window. A timeout alone is the box's load, not
# the commit's fault (a desk box 2026-10-24..30: 4 commits quarantined at
# 45 s, one touching no watchdog code, load 49 on 16 cpus): the step gets a
# new window, up to WD_UPD_STEP_TRIES in all, then the sha is quarantined.
# The instance in its check keeps its tick; a failed check never comes here.
spl_wd_upd_step_timeout() {
  local now="$1" why try=$(( U_TRY + 1 ))
  why="$2 ($(spl_wd_upd_load))"
  if (( try >= WD_UPD_STEP_TRIES )); then
    spl_wd_upd_fail "$U_SHA" "$now" "$why, try $try of $WD_UPD_STEP_TRIES"
    return 0
  fi
  spl_wd_upd_state_write "$U_SHA" "$U_NEXT" exec "$U_PID" "$now" "$U_START" "$try"
  spl_wd_upd_log "RETRY ${U_SHA:0:9}: $why, try $try of $WD_UPD_STEP_TRIES; not quarantined, another ${WD_UPD_STEP_MAX}s"
  return 0
}

# instance 1, no rollout on: has the checkout moved past code/good?
spl_wd_upd_detect() {
  local now="$1" src head good orc
  src="$(spl_wd_upd_src)"
  [[ -n "$src" ]] || return 0
  head="$(spl_wd_upd_git "$src" rev-parse HEAD 2>/dev/null || true)"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
  good="$(spl_wd_upd_link good)"
  if [[ -z "$good" || ! -f "$WD_DIR/code/$good/.sha" ]]; then
    good="$(spl_wd_upd_first_good "$src" "$head")" || return 0
  fi
  [[ "$head" != "$good" && ! -f "$WD_DIR/code/$head.bad" ]] || return 0
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    [[ "${WD_UPD_DRY_SEEN:-}" == "$head" ]] || spl_wd_upd_log "DRY_RUN would roll out ${head:0:9} (good ${good:0:9})"
    WD_UPD_DRY_SEEN="$head"
    return 0
  fi
  spl_wd_upd_snapshot "$src" "$head" || { spl_wd_upd_log "cannot snapshot ${head:0:9} from $src"; return 0; }
  orc="$(spl_wd_upd_orc)"
  # shellcheck disable=SC2046
  if spl_wd_upd_git "$src" diff --quiet "$good" "$head" -- $(spl_wd_upd_code_paths) 2>/dev/null; then
    ln -sfn "$head" "$WD_DIR/code/good"
    spl_wd_upd_log "good := ${head:0:9} ($orc unchanged since ${good:0:9}: no restart)"
    spl_wd_upd_prune
    return 0
  fi
  spl_wd_upd_quorum "$now" "$head" || return 0
  spl_wd_upd_preflight "$head" "$now" || return 0
  # the step starts now: the pre-flight before it is not the self-check's time
  now="$(spl_lease_now)"
  ln -sfn "$head" "$WD_DIR/code/candidate"
  spl_wd_upd_state_write "$head" 1 exec "$$" "$now" "$now"
  spl_wd_upd_log "START ${head:0:9} (good ${good:0:9}): instance 1 self-execs"
  exec 5>&-
  spl_wd_upd_exec "$head" forward "$now" "rollout start"
  return 0
}

# spl_wd_upd_first_good SRC HEAD: no code/good yet: the sha this instance
# runs (when the checkout knows it), else HEAD, becomes good. Prints it.
spl_wd_upd_first_good() {
  local src="$1" good="$2"
  if [[ "$WD_CODE_SHA" =~ ^[0-9a-f]{40}$ ]] && spl_wd_upd_git "$src" cat-file -e "$WD_CODE_SHA^{commit}" 2>/dev/null; then
    good="$WD_CODE_SHA"
  fi
  spl_wd_upd_snapshot "$src" "$good" || { spl_wd_upd_log "cannot snapshot ${good:0:9} from $src" >&2; return 1; }
  ln -sfn "$good" "$WD_DIR/code/good"
  spl_wd_upd_log "good := ${good:0:9} (first snapshot)" >&2
  echo "$good"
}

# all 3 alive and progressing, else the rollout waits (and alerts once)
spl_wd_upd_quorum() {
  local now="$1" head="$2" p st bad=""
  for p in 1 2 3; do
    [[ "$p" == "$WD_INST" ]] && continue
    st="$(spl_wd_peer_state "$p" "$now")"
    [[ "$st" == ok* ]] || bad+="instance $p: $st; "
  done
  [[ -z "$bad" ]] && return 0
  spl_wd_upd_log "DEFER ${head:0:9}: not all 3 instances are healthy (${bad%; })"
  spl_wd_peer_alert update_quorum "$now" \
    "WATCHDOG (102 10.4.4): the rollout of ${head:0:9} on box $(spl_wd_peer_box) waits: ${bad%; }"
  return 1
}

# the candidate's scripts parse, and one dry proof tick from it runs green.
# A tick that only timed out is retried (spl_wd_upd_slow), not quarantined.
spl_wd_upd_preflight() {
  local sha="$1" now="$2" orc f out rc=0 pf="$WD_DIR/preflight" t0 took
  [[ "$WD_UPD_PREFLIGHT" == 1 ]] || return 0
  orc="$WD_DIR/code/$sha/$(spl_wd_upd_orc)"
  while IFS= read -r -d '' f; do
    if ! out="$(bash -n "$f" 2>&1)"; then
      spl_wd_upd_fail "$sha" "$now" "pre-flight: bash -n ${f#"$orc"/}: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
      return 1
    fi
  done < <(find "$orc/src/bash/run" "$orc/src/bash/features/watchdog" -name '*.sh' -print0 2>/dev/null)
  rm -rf "$pf"; mkdir -p "$pf"
  spl_wd_upd_check_limit
  t0="$SECONDS"
  out="$(timeout -k 2 "$WD_UPD_LIM" env WD_INST= INSTANCE= WD_UPD_EXEC= WD_STATE_DIR="$pf" \
    WD_ONLY=wd-preflight WD_TICKS=1 DRY_RUN=1 WD_SELF_UPDATE=0 WD_PEERS=0 \
    "$orc/run" -a do_spl_watchdog 2>&1 5>&- 7>&- 9>&-)" || rc=$?
  took=$(( SECONDS - t0 ))
  if grep -qE "$SPL_WD_UPD_ERR_RE" <<<"$out" || grep -qE "$SPL_WD_UPD_ERR_RE" "$pf/tick/err" 2>/dev/null ||
     (( rc != 0 && rc != 124 && rc != 137 )); then
    spl_wd_upd_fail "$sha" "$now" "pre-flight: the proof tick from the snapshot failed (rc $rc, took ${took}s): $(tail -n 3 <<<"$out" | tr '\n' ' ')"
    return 1
  fi
  if (( rc != 0 )); then
    spl_wd_upd_slow "$sha" "$now" "$rc" "$took"
    return 1
  fi
  rm -f "$WD_DIR/code/$sha.slow"
  return 0
}

# spl_wd_upd_check_limit: WD_UPD_LIM, the proof tick's limit for this box
# now, and WD_UPD_LIM_WHY, how it was reached. A fixed 20 s never fits a
# loaded box (a desk box 2026-10-10, load 77-100 on 16 cpus: 10 of 10 pre-flights
# hit 20 s, two correct commits quarantined, the watchdogs left on old code).
# WD_UPD_CHECK_MAX x (2 x load1 / nproc when over 1), rounded up, at most
# WD_UPD_CHECK_CAP s, never under WD_UPD_CHECK_MAX. The scaling starts at 0.5
# load per cpu, not 1: sat 2026-10-18, load 5.5-9.8 on 16 cpus, the tick took
# 20 s against the unscaled 20 s, 2 good commits quarantined (SPL-2510; the
# tick itself was slow, spl_wdo_tasks, now 4-6 s). A commit that hangs still
# times out at that limit, every try, and is quarantined after
# WD_UPD_TIMEOUT_TRIES of them.
spl_wd_upd_check_limit() {
  local base="$WD_UPD_CHECK_MAX" cap="${WD_UPD_CHECK_CAP:-60}" l1 np
  l1="${WD_UPD_LOAD1:-$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)}"
  np="${WD_UPD_NPROC:-$(nproc 2>/dev/null || true)}"
  [[ "$l1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || l1=0
  [[ "$np" =~ ^[1-9][0-9]*$ ]] || np=1
  WD_UPD_LIM="$(awk -v b="$base" -v c="$cap" -v l="$l1" -v n="$np" 'BEGIN {
    f = 2 * l / n; if (f < 1) f = 1
    x = b * f; if (x > int(x)) x = int(x) + 1
    if (x > c) x = c; if (x < b) x = b
    print x }')"
  WD_UPD_LIM_WHY="base ${base}s x load ${l1}/${np} cpus, cap ${cap}s"
}

# spl_wd_upd_slow SHA NOW RC TOOK: the proof tick only timed out (rc 124/137,
# no script error): a loaded box, not a bad sha (2026-10-09, load ~10: three
# commits quarantined at rc 124, the next one green in 5 s). code/<sha>.slow
# counts the timeouts in a row; the sha stays un-quarantined and is
# pre-flighted again on a later tick, until WD_UPD_TIMEOUT_TRIES of them.
spl_wd_upd_slow() {
  local sha="$1" now="$2" rc="$3" took="$4" n f="$WD_DIR/code/$1.slow" s
  # a timeout count is for the sha in the checkout now, never a superseded one
  for s in "$WD_DIR"/code/*.slow; do [[ -f "$s" && "$s" != "$f" ]] && rm -f "$s"; done
  n="$(head -n 1 "$f" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$(( n + 1 ))
  if (( n >= ${WD_UPD_TIMEOUT_TRIES:-5} )); then
    rm -f "$f"
    spl_wd_upd_fail "$sha" "$now" "pre-flight: the proof tick from the snapshot timed out $n times in a row (rc $rc, last took ${took}s, limit ${WD_UPD_LIM:-$WD_UPD_CHECK_MAX}s: ${WD_UPD_LIM_WHY:-fixed})"
    return 0
  fi
  echo "$n" > "$f" 2>/dev/null || true
  spl_wd_upd_log "RETRY ${sha:0:9}: pre-flight: the proof tick from the snapshot timed out (rc $rc, took ${took}s, limit ${WD_UPD_LIM:-$WD_UPD_CHECK_MAX}s: ${WD_UPD_LIM_WHY:-fixed}), $n of ${WD_UPD_TIMEOUT_TRIES:-5}; not quarantined, pre-flighted again on a later tick"
  return 0
}

# spl_wd_upd_fail SHA NOW REASON: halt, quarantine, alert
spl_wd_upd_fail() {
  local sha="$1" now="$2" why="$3" good
  good="$(spl_wd_upd_link good)"
  echo "$why" > "$WD_DIR/code/$sha.bad" 2>/dev/null || true
  rm -f "$WD_DIR/code/$sha.slow"
  rm -f "$WD_DIR/update.state" "$WD_DIR/code/candidate"
  spl_wd_upd_log "FAILED ${sha:0:9}: $why; rollout halted, ${sha:0:9} quarantined (code/$sha.bad), the instances on it go back to good ${good:0:9}"
  spl_wd_peer_alert "update_${sha:0:9}" "$now" \
    "WATCHDOG (102 10.4.4): the desk-cron commit ${sha:0:9} failed its rollout on box $(spl_wd_peer_box) and is quarantined: $why. The watchdogs stay on ${good:0:9}; a fixed commit rolls out by itself."
  return 0
}

# spl_wd_upd_exec SHA ROLE NOW WHY: exec this instance into code/<sha> (same
# pid; the run lock fd 7 and the keeper fd 9 stay open). Returns only when
# it cannot.
spl_wd_upd_exec() {
  local sha="$1" role="$2" now="$3" why="$4" run
  run="$WD_DIR/code/$sha/$(spl_wd_upd_orc)/run"
  if [[ -z "$sha" || ! -x "$run" ]]; then
    spl_wd_upd_log "cannot exec into '${sha:0:9}' ($why): no $run"
    return 0
  fi
  spl_wd_upd_log "EXEC $role into ${sha:0:9} ($why; was ${WD_CODE_SHA:0:9})"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then return 0; fi
  # T0 is the exec itself: the self-check times its own tick, not the work before
  WD_UPD_T0="$(spl_lease_now)"
  export WD_UPD_EXEC="$sha" WD_UPD_ROLE="$role" WD_UPD_T0 WD_INST INSTANCE="$WD_INST"
  # ./run's tee pipes end with this process: the new code writes the instance log itself
  exec >>"$WD_DIR/run.$WD_INST.out" 2>&1
  spl_wd_upd_close_fds
  cd / || true
  shopt -s execfail
  # shellcheck disable=SC2093 # execfail: a failed exec returns here
  exec "$run" -a do_spl_watchdog
  spl_wd_upd_log "exec into ${sha:0:9} failed"
  unset WD_UPD_EXEC WD_UPD_ROLE WD_UPD_T0
  return 0
}

# spl_wd_upd_close_fds: before the exec, close every fd above 2 but the run
# lock (7) and the keeper (9). ./run starts an action as `main_exec >
# >(tee ..out.log) 2> >(tee ..err.log >&2)`, and the write ends of those two
# pipes (fds 62/63) survive exec: the old code's tee subshells never saw EOF,
# and each reload left them behind for good, carried on by every later exec
# (SPL-1732: a desk box, 2026-10-13, 926 processes over ~220 code/<sha>
# trees, ~4 per master push). Closed, they end with the code that made them.
# 7 and 9 stay only as lock files: once the keeper closed fd 9, a later tee
# pipe can land on 9 (a sat instance, 2026-10-13: fd 9 a pipe, 54 tee
# subshells kept alive behind it after the first fixed reload).
spl_wd_upd_close_fds() {
  local fd
  for fd in "/proc/$BASHPID/fd/"*; do
    fd="${fd##*/}"
    [[ "$fd" =~ ^[0-9]+$ ]] || continue
    (( fd > 2 && fd != 255 )) || continue
    if (( fd == 7 || fd == 9 )) && [[ "$(readlink "/proc/$BASHPID/fd/$fd" 2>/dev/null)" != pipe:* ]]; then continue; fi
    eval "exec $fd>&-" 2>/dev/null || true
  done
  return 0
}

# spl_wd_upd_checked TICK [START]: the end of the first tick after an exec
# (START: that tick's own start, the time the log names, not the exec's
# WD_UPD_T0, which a pre-flight in an older exec code can push back; the
# hang bound is the step's window from update.state since): the
# self-check. Green -> baton to the next instance (or code/good after 3);
# red -> quarantine and back to good.
spl_wd_upd_checked() {
  local tick="$1" now took sha="${WD_UPD_EXEC:-}" role="${WD_UPD_ROLE:-}" t0="${2:-${WD_UPD_T0:-0}}" why n
  [[ -n "$sha" ]] || return 0
  unset WD_UPD_EXEC WD_UPD_ROLE WD_UPD_T0
  now="$(spl_lease_now)"
  [[ "$t0" =~ ^[0-9]+$ ]] || t0="$now"
  took=$(( now - t0 ))
  n="$(find "$tick" -maxdepth 1 -name 'out.*' -size +0 2>/dev/null | wc -l)"
  if [[ "$role" != forward ]]; then
    spl_wd_upd_log "back on ${sha:0:9} ($role): tick green in ${took}s, ${n:-0} agent(s)"
    return 0
  fi
  why="$(spl_wd_upd_verdict "$tick" "$sha")"
  exec 5>>"$WD_DIR/update.lock"
  flock -w 10 5 || true
  if ! spl_wd_upd_state_read || [[ "$U_SHA" != "$sha" || "$U_NEXT" != "$WD_INST" || "$U_STAGE" != exec ]]; then
    exec 5>&-
    spl_wd_upd_log "self-check of ${sha:0:9} done (${why:-green in ${took}s}), but the rollout is no longer this instance's step"
    return 0
  fi
  # the hang bound: the peers' own test (spl_wd_upd_baton), the step's
  # current window from since, so the two never disagree on the same state
  # (a tick bound from its own start let a re-armed tick end green at 60 s
  # while a peer at 46 s quarantined it: a race for update.lock)
  if [[ -z "$why" ]] && (( now - U_SINCE > WD_UPD_STEP_MAX )); then
    why="self-check step ran $(( now - U_SINCE ))s of its ${WD_UPD_STEP_MAX}s window (tick ${took}s, $(spl_wd_upd_load))"
    if (( U_TRY + 1 < WD_UPD_STEP_TRIES )); then
      spl_wd_upd_check_again "$sha" "$now" "$why"
      exec 5>&-
      return 0
    fi
    why+=", try $(( U_TRY + 1 )) of $WD_UPD_STEP_TRIES"
  fi
  if [[ -n "$why" ]]; then
    spl_wd_upd_fail "$sha" "$now" "instance $WD_INST failed its self-check tick: $why"
    exec 5>&-
    spl_wd_upd_exec "$(spl_wd_upd_link good)" rollback "$now" "self-check failed"
    return 0
  fi
  spl_wd_upd_pass "$sha" "$now" "$took" "${n:-0}"
  exec 5>&-
  return 0
}

# spl_wd_upd_last LAST: the tick start the gap of this tick is measured
# from. The first tick after an exec measures it from the exec (WD_UPD_T0),
# not from the tick before it: that gap is this instance's own pre-flight
# and exec, not a suspend. Read as a resume (> 3 x WD_TICK) it skipped every
# agent ("resume grace") and the self-check judged nothing, green on a
# broken sha (SPL-3332: a loaded box, pre-flight 16+ s at tick 5, rolled a
# bad commit on to instance 2).
spl_wd_upd_last() {
  local last="$1" t0="${WD_UPD_T0:-}"
  if [[ -n "${WD_UPD_EXEC:-}" && "$t0" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] && (( t0 > last )); then
    echo "$t0"
  else
    echo "$last"
  fi
}

# spl_wd_upd_check_again SHA NOW WHY: a green self-check tick that only ran
# past its hang bound (a loaded box, not the commit) is checked again: the
# next tick of this instance is the self-check once more, a try later. Its
# window starts at that tick (now + WD_TICK), not now: the loop's sleep
# between the two is no part of the step. Under update.lock (fd 5).
spl_wd_upd_check_again() {
  local sha="$1" now="$2" why="$3" try=$(( U_TRY + 1 ))
  spl_wd_upd_state_write "$sha" "$WD_INST" exec "$$" "$(( now + ${WD_TICK:-30} ))" "$U_START" "$try"
  export WD_UPD_EXEC="$sha" WD_UPD_ROLE=forward WD_UPD_T0="$now"
  spl_wd_upd_log "RETRY ${sha:0:9}: instance $WD_INST: $why, try $try of $WD_UPD_STEP_TRIES; not quarantined, its next tick checks again"
  return 0
}

# spl_wd_upd_verdict TICK SHA: why the self-check tick is red, or empty.
# By its result, not its wall time: on a loaded box a correct tick took 24
# and 26 s (a desk box, 2026-10-08: two harmless commits quarantined at a 20 s
# limit). The only time bound is the hang bound, WD_UPD_STEP_MAX s per try,
# the one the peers already time an unfinished check by (spl_wd_upd_baton);
# spl_wd_upd_checked applies it.
spl_wd_upd_verdict() {
  local tick="$1" sha="$2"
  if grep -qE "$SPL_WD_UPD_ERR_RE" "$tick/err" 2>/dev/null; then
    echo "script errors: $(grep -E "$SPL_WD_UPD_ERR_RE" "$tick/err" | tail -n 3 | tr '\n' ' ')"
  elif [[ "$sha" != "$WD_CODE_SHA" ]]; then
    echo "runs ${WD_CODE_SHA:0:9}, not ${sha:0:9}"
  elif [[ "${WD_HB_OK:-1}" != 1 ]]; then
    echo "cannot write its heartbeat"
  fi
  return 0
}

# spl_wd_upd_pass SHA NOW TOOK N: a green self-check: baton to the next
# instance, or, after the last, the candidate becomes good
spl_wd_upd_pass() {
  local sha="$1" now="$2" took="$3" n="$4" p next=""
  for p in 1 2 3; do (( p > WD_INST )) && { next="$p"; break; }; done
  if [[ -n "$next" ]]; then
    spl_wd_upd_state_write "$sha" "$next" wait 0 "$now" "$U_START"
    spl_wd_upd_log "instance $WD_INST on ${sha:0:9}: self-check tick green in ${took}s, $n agent(s); baton -> $next"
    return 0
  fi
  ln -sfn "$sha" "$WD_DIR/code/good"
  rm -f "$WD_DIR/code/candidate" "$WD_DIR/update.state"
  spl_wd_upd_log "instance $WD_INST on ${sha:0:9}: self-check tick green in ${took}s; DONE instances 1 2 3 on ${sha:0:9} in $(( now - U_START ))s, good := ${sha:0:9}"
  spl_wd_upd_prune
  return 0
}

# spl_wd_upd_force ID: 0 when the self-check tick judges ID although a peer
# judged it less than WD_TICK - 5 s ago (10.4.4 step 3: the check evaluates
# at least 1 agent; in the pool one instance can judge every agent for
# hours). One agent per check tick, under its judge lock as always, and only
# one with no hit pending: an extra judgment can then start a debounce, never
# finish one.
spl_wd_upd_force() {
  [[ -n "${WD_UPD_EXEC:-}" && "${WD_UPD_ROLE:-}" == forward ]] || return 1
  [[ -s "$WD_DIR/$1.hits" ]] && return 1
  mkdir "$WD_DIR/tick$WD_SFX/upd.force" 2>/dev/null || return 1
  echo "$1" > "$WD_DIR/tick$WD_SFX/upd.force/id"
  return 0
}

# spl_wd_upd_lock_wait FD: 0 once the self-check tick holds the judge lock
# on FD that a peer held. The check must judge at least 1 agent (10.4.4 step
# 3); with flock -n a peer mid-check of the only agent left it 0, and a tick
# that judged nothing read green on a broken sha. Waits only while no agent
# of this tick is forced yet, at most WD_SCRIPT_TIMEOUT + 5 s.
spl_wd_upd_lock_wait() {
  [[ -n "${WD_UPD_EXEC:-}" && "${WD_UPD_ROLE:-}" == forward ]] || return 1
  [[ -d "$WD_DIR/tick$WD_SFX/upd.force" ]] && return 1
  flock -w $(( WD_SCRIPT_TIMEOUT + 5 )) "$1"
}

# spl_wd_upd_sleep SECS: the loop's sleep, in WD_UPD_SLICE s slices, cut
# short when the baton names this instance or its sha is quarantined
spl_wd_upd_sleep() {
  local left="$1" s
  if [[ -z "${WD_INST:-}" || "${WD_SELF_UPDATE:-0}" != 1 ]]; then sleep "$left"; return 0; fi
  while (( left > 0 )); do
    s=$(( left < WD_UPD_SLICE ? left : WD_UPD_SLICE ))
    sleep "$s"
    left=$(( left - s ))
    [[ -f "$WD_DIR/code/${WD_CODE_SHA:-x}.bad" ]] && return 0
    grep -qE "(^| )next=$WD_INST stage=wait " "$WD_DIR/update.state" 2>/dev/null && return 0
  done
  return 0
}

# keep code/good, code/candidate, the shas the instances run, and the
# newest snapshots up to WD_UPD_KEEP in all; the rest goes
spl_wd_upd_prune() {
  local -A keep=()
  local d s n h
  for s in "$(spl_wd_upd_link good)" "$(spl_wd_upd_link candidate)" "$WD_CODE_SHA"; do
    [[ -n "$s" ]] && keep["$s"]=1
  done
  for h in "$WD_DIR"/heartbeat.[1-3].json; do
    s="$(jq -r '.git_sha // empty' "$h" 2>/dev/null || true)"
    [[ "$s" =~ ^[0-9a-f]{7,40}$ ]] || continue
    for d in "$WD_DIR/code/$s"*/; do [[ -d "$d" ]] && keep["$(basename "$d")"]=1; done
  done
  n="${#keep[@]}"
  while IFS= read -r d; do
    s="$(basename "$d")"
    [[ "$s" =~ ^[0-9a-f]{40}$ ]] || continue
    [[ -n "${keep[$s]:-}" ]] && continue
    if (( n < WD_UPD_KEEP )); then n=$((n + 1)); continue; fi
    rm -rf "${WD_DIR:?}/code/$s"
  done < <(ls -1dt "$WD_DIR"/code/*/ 2>/dev/null || true)
  return 0
}
