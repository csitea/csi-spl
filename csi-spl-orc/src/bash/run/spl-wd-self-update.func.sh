#!/bin/bash
#------------------------------------------------------------------------------
# @description Watchdog self-update on desk-cron changes (spec 102 10.4.4,
# @description WD3, T025). The watchdogs never run from the moving desk-cron
# @description checkout: each sha is exported (git archive <sha> <org>-<app>-orc)
# @description into <wd dir>/code/<sha>/, and code/good names the verified one
# @description (spl_wd_inst_start starts every instance from it). At its tick
# @description start instance 1 compares the checkout HEAD with code/good:
# @description the orc tree unchanged -> code/good moves, nothing restarts;
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
# @description Stop rule: a failed pre-flight or self-check, an instance that
# @description dies in its check, or a step past WD_UPD_STEP_MAX s halts the
# @description rollout, quarantines the sha (code/<sha>.bad: never rolled
# @description again), alerts the orchestrator, and every instance on that
# @description sha execs back into code/good. A pre-flight proof tick that
# @description only TIMED OUT (rc 124/137, no script error: a loaded box) is no
# @description failure: RETRY, the sha stays un-quarantined and is pre-flighted
# @description again on a later tick, quarantined only after
# @description WD_UPD_TIMEOUT_TRIES timeouts in a row. Every step is an UPDATE
# @description line in wd.log. The action prints the state, read-only.
# @param WD_SELF_UPDATE (optional) - 1 rolls out new desk-cron code; default 1, and 0 under SPOOL_TEST=1
# @param WD_UPD_SRC (optional) - the desk-cron checkout; default DESK_CRON_SRC, then <wd dir>/starter.src
# @param WD_UPD_SLICE (optional) - seconds per sleep slice of a waiting instance, default 5
# @param WD_UPD_CHECK_MAX (optional) - seconds for the pre-flight proof tick, default 20
# @param WD_UPD_TIMEOUT_TRIES (optional) - pre-flight proof ticks that time out in a row before the sha is quarantined, default 5
# @param WD_UPD_STEP_MAX (optional) - seconds one step (exec + check, or a baton wait) may take, default 45; the self-check tick's hang bound
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
  : "${WD_UPD_SLICE:=5}" "${WD_UPD_CHECK_MAX:=20}" "${WD_UPD_STEP_MAX:=45}" "${WD_UPD_KEEP:=3}" "${WD_UPD_PREFLIGHT:=1}" "${WD_UPD_TIMEOUT_TRIES:=5}"
  for k in WD_SELF_UPDATE WD_UPD_SLICE WD_UPD_CHECK_MAX WD_UPD_STEP_MAX WD_UPD_KEEP WD_UPD_PREFLIGHT WD_UPD_TIMEOUT_TRIES; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  (( WD_UPD_SLICE > 0 )) || { do_log "FATAL WD_UPD_SLICE must be at least 1"; return 1; }
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

# spl_wd_upd_snapshot SRC SHA: <wd dir>/code/<sha>/ from git archive, once
spl_wd_upd_snapshot() {
  local src="$1" sha="$2" code="$WD_DIR/code" tmp orc
  [[ -f "$code/$sha/.sha" ]] && return 0
  orc="$(spl_wd_upd_orc)"
  tmp="$code/.tmp.$sha.$$"
  mkdir -p "$tmp" || return 1
  if ! spl_wd_upd_git "$src" archive --format=tar "$sha" "$orc" 2>/dev/null | tar -x -C "$tmp" 2>/dev/null ||
     [[ ! -x "$tmp/$orc/run" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  echo "$sha" > "$tmp/.sha"
  rm -rf "${code:?}/$sha"
  mv "$tmp" "$code/$sha" || { rm -rf "$tmp"; return 1; }
  return 0
}

# update.state: one line "sha=<sha> next=<inst> stage=<exec|wait> pid=<pid> since=<epoch> start=<epoch>"
spl_wd_upd_state_read() {
  local line kv
  U_SHA="" U_NEXT="" U_STAGE="" U_PID="" U_SINCE="" U_START=""
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
    esac
  done
  [[ "$U_SHA" =~ ^[0-9a-f]{40}$ && "$U_NEXT" =~ ^[1-3]$ && "$U_STAGE" =~ ^(exec|wait)$ && "$U_SINCE" =~ ^[0-9]+$ && "$U_START" =~ ^[0-9]+$ ]] || return 1
  return 0
}

spl_wd_upd_state_write() {
  local f="$WD_DIR/update.state"
  echo "sha=$1 next=$2 stage=$3 pid=$4 since=$5 start=$6" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
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
  if (( now - U_SINCE > WD_UPD_STEP_MAX )); then
    if [[ "$U_STAGE" == exec ]]; then
      spl_wd_upd_fail "$U_SHA" "$now" "instance $U_NEXT did not finish its self-check in ${WD_UPD_STEP_MAX}s"
    else
      # a peer that is down cannot take the baton: not the code's fault, no quarantine
      rm -f "$WD_DIR/update.state" "$WD_DIR/code/candidate"
      spl_wd_upd_log "HALT ${U_SHA:0:9}: instance $U_NEXT did not take the baton in ${WD_UPD_STEP_MAX}s; retried when all 3 run"
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
  if spl_wd_upd_git "$src" diff --quiet "$good" "$head" -- "$orc" 2>/dev/null; then
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
  t0="$SECONDS"
  out="$(timeout -k 2 "$WD_UPD_CHECK_MAX" env WD_INST= INSTANCE= WD_UPD_EXEC= WD_STATE_DIR="$pf" \
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
    spl_wd_upd_fail "$sha" "$now" "pre-flight: the proof tick from the snapshot timed out $n times in a row (rc $rc, last took ${took}s, limit ${WD_UPD_CHECK_MAX}s)"
    return 0
  fi
  echo "$n" > "$f" 2>/dev/null || true
  spl_wd_upd_log "RETRY ${sha:0:9}: pre-flight: the proof tick from the snapshot timed out (rc $rc, took ${took}s, limit ${WD_UPD_CHECK_MAX}s), $n of ${WD_UPD_TIMEOUT_TRIES:-5}; not quarantined, pre-flighted again on a later tick"
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
  cd / || true
  shopt -s execfail
  # shellcheck disable=SC2093 # execfail: a failed exec returns here
  exec "$run" -a do_spl_watchdog
  spl_wd_upd_log "exec into ${sha:0:9} failed"
  unset WD_UPD_EXEC WD_UPD_ROLE WD_UPD_T0
  return 0
}

# spl_wd_upd_checked TICK [START]: the end of the first tick after an exec
# (START: that tick's own start, timed from there and not from the exec's
# WD_UPD_T0, which a pre-flight in an older exec code can push back): the
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
  why="$(spl_wd_upd_verdict "$tick" "$sha" "$took")"
  exec 5>>"$WD_DIR/update.lock"
  flock -w 10 5 || true
  if ! spl_wd_upd_state_read || [[ "$U_SHA" != "$sha" || "$U_NEXT" != "$WD_INST" || "$U_STAGE" != exec ]]; then
    exec 5>&-
    spl_wd_upd_log "self-check of ${sha:0:9} done (${why:-green}), but the rollout is no longer this instance's step"
    return 0
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

# spl_wd_upd_verdict TICK SHA TOOK: why the self-check tick is red, or empty.
# By its result, not its wall time: on a loaded box a correct tick took 24
# and 26 s (a desk box, 2026-10-08: two harmless commits quarantined at a 20 s
# limit). The only time bound is the hang bound WD_UPD_STEP_MAX, the one the
# peers already fail an unfinished check at (spl_wd_upd_baton).
spl_wd_upd_verdict() {
  local tick="$1" sha="$2" took="$3"
  if grep -qE "$SPL_WD_UPD_ERR_RE" "$tick/err" 2>/dev/null; then
    echo "script errors: $(grep -E "$SPL_WD_UPD_ERR_RE" "$tick/err" | tail -n 3 | tr '\n' ' ')"
  elif [[ "$sha" != "$WD_CODE_SHA" ]]; then
    echo "runs ${WD_CODE_SHA:0:9}, not ${sha:0:9}"
  elif [[ "${WD_HB_OK:-1}" != 1 ]]; then
    echo "cannot write its heartbeat"
  elif (( took > WD_UPD_STEP_MAX )); then
    echo "self-check tick took ${took}s (hang bound ${WD_UPD_STEP_MAX}s)"
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
