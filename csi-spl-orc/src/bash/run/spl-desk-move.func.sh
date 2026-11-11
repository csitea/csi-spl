#!/bin/bash
#------------------------------------------------------------------------------
# @description Move this box's desks from the box user's home to the desk
# @description user's (spec 069 section 8.4, row B7), or back, one desk at a
# @description time. A desk is <state>/<env>/desk/<workspace>/<desk id>/, with
# @description <state> each user's cloud state root (spl_desk_state_root).
# @description   plan  (default) read-only: per desk the source, the target,
# @description         its size, key count and modes, the live sidecar pid,
# @description         the seats, and the order: prd before dev, the fleet
# @description         desk (SPOOL_FLEET_ENV / SPOOL_FLEET_TENANT /
# @description         SPOOL_DESK_BOX of box.env) last
# @description   move  per desk: stop its live sidecar (do_spl_desk_down),
# @description         copy the desk to the desk user (tar, modes kept; the
# @description         desk user owns the copy), verify it (the same file
# @description         list, the same key digest, desk and keys 0700, every
# @description         key 0600), rename the source to desk.moved-<UTC>/,
# @description         start the sidecar as the desk user
# @description         (spl_desk_box_restart -> do_spl_desk_up) and prove it
# @description         (do_spl_desk_check: ok, muted or agent-missing; never
# @description         down, stranded or unpinned). A desk that fails is
# @description         rolled back at once and the box stops there; so does
# @description         one whose downtime passes MOVE_MAX_SECS. Every desk
# @description         moved: box.env gets SPOOL_DESK_USER (box-config.sh)
# @description   back  the same steps in reverse: the desk user's desk is
# @description         copied over the newest desk.moved-* source (messages
# @description         received since the move are kept), the desk user's
# @description         copy goes to its own desk.moved-<UTC>/, the sidecar
# @description         starts as the box user; all back: box.env loses
# @description         SPOOL_DESK_USER
# @description   prune removes the desk.moved-* copies of both users that are
# @description         older than MOVE_PRUNE_DAYS
# @description   switch box.env gets SPOOL_DESK_USER and no desk moves (8.4 step
# @description         4 on a box with desks left behind). Refused unless the
# @description         fleet desk is pinned and live under the desk user and no
# @description         desk under the box user has a live sidecar. Stubs and
# @description         sidecar-less desks stay where they are, one line each
# @description   unswitch box.env loses SPOOL_DESK_USER and no desk moves: the
# @description         reverse of switch, before a MOVE_DESKS rollback
# @description move and back hold the reconcile pause of each env
# @description (<spool root>/.desk-reconcile.<env>.pause, refreshed before
# @description every desk) and leave it: the reconcile cron lines move to
# @description the desk user first (do_spl_desk_install_service), then the
# @description pause file goes. Keys are named by count and mode only; their
# @description content and digests are never printed. The desk user's side
# @description runs through `sudo -n -u <desk user>` (files) and its ./run
# @description (the sidecar steps); nothing is chowned, nothing needs root.
# @description Downtime per desk = stop to proof, in seconds.
# @description The proof's credential (SPL-5233): the forward proof runs as
# @description the target user, the rollback's as the source user, and each
# @description reads its own probe password file: MOVE_DESK_PW_FILE (desk
# @description user) / MOVE_BOX_PW_FILE (box user), each defaulting to
# @description PROBE_PW_FILE, else that user's own
# @description <state>/m3-e2e/{<workspace>,e2e}/pw-human (DESK_ROSTER_JSON,
# @description when set, is the one file both read). The plan, and a real run
# @description before any stop or copy, check with `sudo -n -u <user> test -r`
# @description that each user can read its file for every desk with a live
# @description sidecar, and refuse with a FATAL naming the file and the user.
# @description The proof logs in once (the session is kept in a 0600 file of
# @description a mktemp dir of that user, removed after) and on a login 429
# @description waits and retries: the hub's Retry-After, else
# @description MOVE_CHECK_EVERY doubled per 429 (at most 60 s a wait; a
# @description Retry-After under 1 s counts as that), all 429 waits of one
# @description proof at most MOVE_CHECK_429_SECS (300 s, on top of
# @description MOVE_CHECK_SECS); past that bound: 'no verdict'. The session
# @description dir is removed also on INT / TERM / HUP.
# @description The quiesce window (spec 069 8.4.1): from the copy to the
# @description source's rename aside (or its rollback) the desk carries the
# @description marker <desk dir>.quiesce, written as the desk's owner and
# @description removed on success, on rollback and on INT/TERM/HUP. Every
# @description local writer of the desk's spool waits for it (the spool CLI,
# @description the MCP server, spool-mirror.py, desk-quiesce.inc.sh) up to
# @description DESK_QUIESCE_WAIT_SECS (120), then refuses (exit 75); a marker
# @description older than DESK_QUIESCE_MAX_SECS (300) is ignored. The copy
# @description starts DESK_QUIESCE_SETTLE_SECS (2) after the marker, so a
# @description write already under way ends first. The same marker sits
# @description beside the target for the copy and the verify (SPL-5247). The
# @description verify stays exact but for spool-mirror.py's seen/ markers.
# @description Dry run unless DRY_RUN=0 (plan always is one).
# @param MOVE_CMD (optional) - plan (default) | move | back | prune | switch | unswitch
# @param MOVE_DESK_USER (optional) - the desk user (<agent-user>); default
# @param   SPOOL_DESK_USER (environment, else box.env). Unset: refused
# @param MOVE_BOX_USER (optional) - the box user whose home held the desks;
# @param   default the caller. The action runs as it
# @param MOVE_ENVS (optional) - default "prd dev", in that order
# @param MOVE_DESKS (optional) - only these desks, "<env>/<workspace>/<desk id> ..."; box.env is then left alone
# @param MOVE_MAX_SECS (optional) - downtime of one desk that stops the box, default 120
# @param MOVE_CHECK_SECS / MOVE_CHECK_EVERY (optional) - the proof waits up to 60 s, re-reading every 5 s
# @param MOVE_RUN (optional) - the orc checkout whose ./run the desk user's
# @param   side runs, default this one (e.g. the desk-cron checkout)
# @param MOVE_PRUNE_DAYS (optional) - default 7
# @param PROBE_EMAIL / PROBE_PW_FILE / DESK_ROSTER_JSON (optional) - the roster
# @param   read of the proof, as do_spl_desk_check documents them. The file
# @param   must be readable by the user each proof runs as (see above)
# @param MOVE_DESK_PW_FILE / MOVE_BOX_PW_FILE (optional) - the probe password
# @param   file of the desk user's / the box user's proof, default PROBE_PW_FILE
# @param MOVE_CHECK_429_SECS (optional) - the 429 back-off bound of one proof, default 300
# @param DESK_QUIESCE_SETTLE_SECS (optional) - pause between the marker and the copy, default 2
# @param DESK_QUIESCE_MAX_SECS / DESK_QUIESCE_WAIT_SECS (optional) - the writers' side, see above
# @param DRY_RUN (optional) - 1 (default) or 0
# @example MOVE_DESK_USER=<agent-user> ./run -a do_spl_desk_move
# @example MOVE_CMD=move MOVE_DESK_USER=<agent-user> DRY_RUN=0 ./run -a do_spl_desk_move
# @example MOVE_CMD=back DRY_RUN=0 ./run -a do_spl_desk_move
# @example MOVE_CMD=prune DRY_RUN=0 ./run -a do_spl_desk_move
# @example MOVE_CMD=switch MOVE_DESK_USER=<agent-user> DRY_RUN=0 ./run -a do_spl_desk_move
#------------------------------------------------------------------------------
do_spl_desk_move() {
  local cmd="${MOVE_CMD:-plan}"
  case "$cmd" in
    _stop | _start | _proof) _spl_dm_side "${cmd#_}"; return $? ;;
    plan | move | back | prune | switch | unswitch) ;;
    *) do_log "FATAL MOVE_CMD must be plan, move, back, prune, switch or unswitch, got: '$cmd'"; return 1 ;;
  esac
  do_require_bin tar sha256sum flock || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$cmd" == plan ]] && dry=1
  [[ "$cmd" == unswitch && -z "${MOVE_DESK_USER:-}$(spl_desk_user)" ]] && { do_log "OK box.env has no SPOOL_DESK_USER: nothing to unswitch"; return 0; }
  _spl_dm_ctx "$cmd" || return 1
  [[ "$cmd" == prune ]] && { _spl_dm_prune "$dry"; return $?; }
  [[ "$cmd" == switch || "$cmd" == unswitch ]] && { _spl_dm_switch "$cmd" "$dry"; return $?; }
  local -a desks=()
  mapfile -t desks < <(_spl_dm_list)
  _spl_dm_plan "${desks[@]}"
  _spl_dm_cred_check "${desks[@]}" || { do_log "FATAL the proof could not run as every user it needs: nothing was touched"; return 1; }
  if (( dry )); then
    [[ "$cmd" == plan ]] || do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to $cmd ${#desks[@]} desk(s)."
    return 0
  fi
  _spl_dm_run "$cmd" "${desks[@]}"
}

# _spl_dm_ctx <cmd>: the move's users and roots. DM_FROM / DM_TO are the
# users the desks leave and reach (move: box -> desk user; back: reverse).
_spl_dm_ctx() {
  DM_ME="$(id -un)"
  DM_BOX="${MOVE_BOX_USER:-$DM_ME}"
  DM_DESK="${MOVE_DESK_USER:-$(spl_desk_user)}"
  [[ -n "$DM_DESK" ]] || { do_log "FATAL no desk user: set MOVE_DESK_USER=<agent-user> (or SPOOL_DESK_USER in box.env); nothing moves"; return 1; }
  [[ "$DM_DESK" != "$DM_BOX" ]] || { do_log "FATAL the desk user '$DM_DESK' is the box user: nothing to move"; return 1; }
  [[ "$DM_BOX" == "$DM_ME" ]] || { do_log "FATAL run this action as the box user $DM_BOX (you are $DM_ME)"; return 1; }
  local u
  for u in "$DM_BOX" "$DM_DESK"; do
    [[ -n "$(_spl_dm_home "$u")" ]] || { do_log "FATAL user '$u' has no home (getent passwd)"; return 1; }
  done
  DM_FROM="$DM_BOX" DM_TO="$DM_DESK"
  [[ "$1" == back ]] && DM_FROM="$DM_DESK" DM_TO="$DM_BOX"
  DM_ENVS="${MOVE_ENVS:-prd dev}"
  DM_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  DM_MAX="${MOVE_MAX_SECS:-120}"
  [[ "$DM_MAX" =~ ^[0-9]+$ ]] || { do_log "FATAL MOVE_MAX_SECS must be whole seconds, got '$DM_MAX'"; return 1; }
  DM_FLEET="$(_spl_dm_box_key SPOOL_FLEET_ENV prd)/$(_spl_dm_box_key SPOOL_FLEET_TENANT '')/$(spl_desk_box_default)"
}

# _spl_dm_home <user>: its home, from getent.
_spl_dm_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }

# _spl_dm_box_key <key> <default>: a key of the box config, as spl_desk_user reads it.
_spl_dm_box_key() {
  local f="${SPOOL_BOX_ENV:-${SPOOL_LIVE_ROOT:-/var/spool-hub}/box.env}" k val v="${!1:-}"
  [[ "${SPOOL_TEST:-}" == 1 && -z "${SPOOL_BOX_ENV:-}" ]] && f=""
  if [[ -z "$v" && -r "$f" ]]; then
    while IFS='=' read -r k val || [[ -n "$k" ]]; do
      [[ "$k" == "$1" ]] && { val="${val%$'\r'}"; val="${val//\"/}"; v="${val//\'/}"; }
    done <"$f"
  fi
  printf '%s' "${v:-$2}"
}

# _spl_dm_root <user> <env>: that user's cloud state root for env.
_spl_dm_root() { SPOOL_DESK_USER="$1" spl_desk_state_root "$2"; }

# _spl_dm_as <user> <cmd...>: cmd as that user; no sudo for the caller.
_spl_dm_as() {
  local u="$1"; shift
  if [[ "$u" == "$DM_ME" ]]; then "$@"; else sudo -n -u "$u" -- "$@"; fi
}

# _spl_dm_pw_for <user>: the probe password file the proof of that user
# reads: MOVE_DESK_PW_FILE for the desk user, MOVE_BOX_PW_FILE for the box
# user, each defaulting to PROBE_PW_FILE; empty = that user's own default.
_spl_dm_pw_for() {
  if [[ "$1" == "$DM_DESK" ]]; then printf '%s' "${MOVE_DESK_PW_FILE:-${PROBE_PW_FILE:-}}"
  else printf '%s' "${MOVE_BOX_PW_FILE:-${PROBE_PW_FILE:-}}"; fi
}

# _spl_dm_cred_check <desk>...: per desk with a live sidecar, the target user
# (its proof) and the source user (the rollback's proof) can each read the
# roster input that proof reads (DESK_ROSTER_JSON, else its password file,
# else its own m3-e2e default). Read as that user, never printed. 0 = all can.
_spl_dm_cred_check() {
  local x e ws id u f r why bad=0; local -A seen=()
  for x in "$@"; do
    read -r e ws id <<<"$x"
    [[ -n "$(_spl_dm_pid "$DM_FROM" "$(_spl_dm_root "$DM_FROM" "$e")/desk/$ws/$id")" ]] || continue
    for u in "$DM_TO" "$DM_FROM"; do
      why="the $([[ "$u" == "$DM_TO" ]] && echo proof || echo "rollback's proof") of $e $ws/$id"
      f="${DESK_ROSTER_JSON:-$(_spl_dm_pw_for "$u")}"
      if [[ -n "$f" ]]; then
        [[ -n "${seen[$u|$f]:-}" ]] && continue; seen[$u|$f]=1
        _spl_dm_as "$u" test -r "$f" && continue
        do_log "FATAL $u cannot read $f, the probe credential of $why (runs as $u): give $u a copy it can read and pass it as $([[ "$u" == "$DM_DESK" ]] && echo MOVE_DESK_PW_FILE || echo MOVE_BOX_PW_FILE)"
        bad=1; continue
      fi
      r="$(_spl_dm_root "$u" "$e")/m3-e2e"
      _spl_dm_as "$u" test -r "$r/$ws/pw-human" || _spl_dm_as "$u" test -r "$r/e2e/pw-human" || {
        do_log "FATAL $u can read neither $r/$ws/pw-human nor $r/e2e/pw-human, the probe credential of $why (runs as $u): pass $([[ "$u" == "$DM_DESK" ]] && echo MOVE_DESK_PW_FILE || echo MOVE_BOX_PW_FILE) or PROBE_PW_FILE"
        bad=1; }
    done
  done
  return "$bad"
}

# _spl_dm_list: "<env> <workspace> <desk id>" per desk of DM_FROM, in move
# order: MOVE_ENVS order, the fleet desk last, MOVE_DESKS when set.
_spl_dm_list() {
  local e r d ws id last=""
  for e in $DM_ENVS; do
    r="$(_spl_dm_root "$DM_FROM" "$e")" || continue
    while IFS= read -r d; do
      id="${d##*/}"; ws="${d%/*}"; ws="${ws##*/}"
      [[ "$ws" =~ ^[a-z0-9][a-z0-9-]*$ && "$id" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
      [[ -z "${MOVE_DESKS:-}" || " $MOVE_DESKS " == *" $e/$ws/$id "* ]] || continue
      if [[ "$e/$ws/$id" == "$DM_FLEET" ]]; then last="$e $ws $id"; else echo "$e $ws $id"; fi
    done < <(_spl_dm_as "$DM_FROM" find "$r/desk" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | LC_ALL=C sort)
  done
  [[ -n "$last" ]] && echo "$last"
  return 0
}

# _spl_dm_pid <user> <desk dir>: the live hub-run pid of that desk, else empty.
_spl_dm_pid() {
  local p
  p="$(_spl_dm_as "$1" cat "$2/spool/.hub/hub-run.pid" 2>/dev/null)"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)" == *" hub-run"* ]] && echo "$p"
  return 0
}

# _spl_dm_plan <desk>...: the step 0 printout, one PLAN line per desk.
_spl_dm_plan() {
  local n=0 x e ws id src dst sz keys seats pid tag
  do_log "INFO desk $([[ "$DM_FROM" == "$DM_BOX" ]] && echo move || echo back): $# desk(s) from $DM_FROM to $DM_TO, stamp $DM_STAMP"
  for x in "$@"; do
    read -r e ws id <<<"$x"; n=$((n + 1))
    src="$(_spl_dm_root "$DM_FROM" "$e")/desk/$ws/$id" dst="$(_spl_dm_root "$DM_TO" "$e")/desk/$ws/$id"
    sz="$(_spl_dm_as "$DM_FROM" du -sh "$src" 2>/dev/null | cut -f1)"
    keys="$(_spl_dm_as "$DM_FROM" find "$src/keys" -type f -printf '%m\n' 2>/dev/null | sort | uniq -c | awk '{printf "%s%s x %s", (NR>1?", ":""), $1, $2}')"
    seats="$(_spl_dm_as "$DM_FROM" find "$src/spool" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l)"
    pid="$(_spl_dm_pid "$DM_FROM" "$src")"; tag=""
    [[ "$e/$ws/$id" == "$DM_FLEET" ]] && tag=" (fleet desk: last)"
    do_log "PLAN $n/$# $e $ws/$id $src -> $dst size ${sz:-?} keys ${keys:-none} sidecar ${pid:-down} seats $seats$tag"
  done
  do_log "INFO order per desk: pause reconcile -> stop sidecar -> copy -> verify (files, key digest, modes) -> rename source to desk.moved-$DM_STAMP -> start as $DM_TO -> proof (do_spl_desk_check); a failure rolls that desk back and stops the box"
}

# _spl_dm_run <cmd> <desk>...: move (or back) every desk; the box stops at the
# first desk that fails or that runs past DM_MAX.
_spl_dm_run() {
  local cmd="$1" x e ws id rc=0 secs moved=() json="" old_traps; shift
  _spl_dm_pause || return 1
  old_traps="$(trap -p INT TERM HUP)"
  trap '_spl_dm_quiesce_off; exit 130' INT TERM HUP
  for x in "$@"; do
    read -r e ws id <<<"$x"
    _spl_dm_pause || { rc=1; break; }
    _spl_dm_one "$e" "$ws" "$id"; rc=$?
    (( rc == 0 )) || { do_log "FAIL $cmd stopped at $e $ws/$id; the desks before it are done, the rest are untouched"; break; }
    secs="$DM_SECS"; moved+=("$e/$ws/$id")
    json+="${json:+, }{\"desk\": \"$e/$ws/$id\", \"downtime_secs\": $secs}"
    (( secs <= DM_MAX )) || { do_log "FAIL $e $ws/$id was down ${secs} s (> MOVE_MAX_SECS $DM_MAX): the box stops here"; rc=4; break; }
  done
  _spl_dm_quiesce_off
  trap - INT TERM HUP; eval "$old_traps"
  (( rc == 0 )) && _spl_dm_finish "$cmd" "${#moved[@]}" "$#"
  printf '{"cmd": "%s", "from": "%s", "to": "%s", "stamp": "%s", "desks": %s, "done": [%s], "ok": %s}\n' \
    "$cmd" "$DM_FROM" "$DM_TO" "$DM_STAMP" "$#" "$json" "$([[ $rc == 0 ]] && echo true || echo false)"
  return "$rc"
}

# _spl_dm_pause: write (or refresh) the reconcile pause of every env.
_spl_dm_pause() {
  local e f
  for e in $DM_ENVS; do
    f="${SPOOL_ROOT:-/var/spool-hub}/.desk-reconcile.$e.pause"
    printf 'do_spl_desk_move %s -> %s %s\n' "$DM_FROM" "$DM_TO" "$DM_STAMP" >"$f" ||
      { do_log "FATAL cannot write the reconcile pause $f"; return 1; }
  done
}

# _spl_dm_quiesce_on <desk dir>: the quiesce marker of the desk, written as
# DM_FROM (its owner) beside it, then DESK_QUIESCE_SETTLE_SECS for a write
# already under way. DM_QUIESCED names it for _spl_dm_quiesce_off.
_spl_dm_quiesce_on() {
  local m="$1.quiesce"
  printf 'do_spl_desk_move %s -> %s %s pid %s\n' "$DM_FROM" "$DM_TO" "$DM_STAMP" "$$" |
    _spl_dm_as "$DM_FROM" tee "$m" >/dev/null || { do_log "FAIL cannot write the quiesce marker $m"; return 1; }
  DM_QUIESCED="$m"
  do_log "INFO quiesce $m: the desk's local writers wait (DESK_QUIESCE_WAIT_SECS, default 120 s)"
  sleep "${DESK_QUIESCE_SETTLE_SECS:-2}"
}

# _spl_dm_quiesce_to <dst>: the same marker beside the target, written as
# DM_TO, for the copy and the verify: a writer still holding the target's path
# (back: the box user's own desk) waits on it too (SPL-5247). DM_QUIESCED_TO
# names it; lifted before the start, whose proof writes the target's spool.
_spl_dm_quiesce_to() {
  local m="$1.quiesce"
  printf 'do_spl_desk_move %s -> %s %s pid %s\n' "$DM_FROM" "$DM_TO" "$DM_STAMP" "$$" |
    _spl_dm_as "$DM_TO" tee "$m" >/dev/null || { do_log "FAIL cannot write the quiesce marker $m"; return 1; }
  DM_QUIESCED_TO="$m"
  do_log "INFO quiesce $m: the target's local writers wait too"
}

# _spl_dm_quiesce_to_off: remove the marker _spl_dm_quiesce_to wrote, if any.
_spl_dm_quiesce_to_off() {
  [[ -n "${DM_QUIESCED_TO:-}" ]] || return 0
  _spl_dm_as "$DM_TO" rm -f -- "$DM_QUIESCED_TO" || { do_log "WARN cannot remove $DM_QUIESCED_TO: it is ignored after DESK_QUIESCE_MAX_SECS (300 s)"; return 1; }
  DM_QUIESCED_TO=""
}

# _spl_dm_quiesce_touch: renew the marker's mtime, so DESK_QUIESCE_MAX_SECS
# counts from the start and the proof, not from the copy.
_spl_dm_quiesce_touch() {
  [[ -n "${DM_QUIESCED:-}" ]] || return 0
  _spl_dm_as "$DM_FROM" touch -- "$DM_QUIESCED" || do_log "WARN cannot renew $DM_QUIESCED"
}

# _spl_dm_quiesce_off: remove the markers _spl_dm_quiesce_on and
# _spl_dm_quiesce_to wrote, if any.
_spl_dm_quiesce_off() {
  _spl_dm_quiesce_to_off
  [[ -n "${DM_QUIESCED:-}" ]] || return 0
  _spl_dm_as "$DM_FROM" rm -f -- "$DM_QUIESCED" || { do_log "WARN cannot remove $DM_QUIESCED: it is ignored after DESK_QUIESCE_MAX_SECS (300 s)"; return 1; }
  do_log "INFO quiesce off: $DM_QUIESCED removed"
  DM_QUIESCED=""
}

# _spl_dm_finish <cmd> <done> <all>: every desk done and no MOVE_DESKS filter:
# box.env follows (move: SPOOL_DESK_USER=<desk user>; back: removed), then
# the steps left to the operator are printed.
_spl_dm_finish() {
  local cmd="$1"
  if [[ -n "${MOVE_DESKS:-}" ]]; then
    do_log "INFO MOVE_DESKS was set: box.env is left alone"
  else
    _spl_dm_box_env "$([[ "$cmd" == move ]] && echo "$DM_DESK")" || return 1
  fi
  do_log "OK $cmd done: $2 of $3 desk(s). The reconcile pause stays until the reconcile cron lines run as $DM_TO (do_spl_desk_install_service) and the agents' MCP follows (do_spl_agent_mcp_install); it is ignored after DESK_PAUSE_MAX_SECS (default 1800 s)"
}

# _spl_dm_box_env <desk user>: SPOOL_DESK_USER of box.env set to it; empty removes it.
_spl_dm_box_env() {
  local bc
  bc="$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/box-config.sh"
  bash "$bc" "SPOOL_DESK_USER=$1" >/dev/null || { do_log "FAIL box.env: cannot write SPOOL_DESK_USER=$1"; return 1; }
  if [[ -n "$1" ]]; then do_log "OK box.env: SPOOL_DESK_USER=$1"; else do_log "OK box.env: SPOOL_DESK_USER removed"; fi
}

# _spl_dm_switch <switch|unswitch> <dry>: box.env alone, no desk moves. A full
# move run is no way to write it on a box with desks left behind: its first stub
# (a desk already under the desk user) stops the run, and it moves every other
# desk (sat 2026-11-07: 9 such desks, 3 of them stubs, in the full plan).
_spl_dm_switch() {
  local cmd="$1" dry="$2" x e ws id d bad=0 fenv fws fid
  [[ -z "${MOVE_DESKS:-}" ]] || { do_log "FATAL $cmd looks at every desk: MOVE_DESKS must be unset"; return 1; }
  [[ -z "${MOVE_ENVS:-}" ]] || { do_log "FATAL $cmd looks at every desk of both envs: MOVE_ENVS must be unset"; return 1; }
  if [[ "$cmd" == unswitch ]]; then
    (( dry )) && { do_log "OK DRY_RUN box.env would lose SPOOL_DESK_USER; no desk moves"; return 0; }
    _spl_dm_box_env ""; return $?
  fi
  IFS=/ read -r fenv fws fid <<<"$DM_FLEET"
  d="$(_spl_dm_root "$DM_DESK" "$fenv")/desk/$fws/$fid"
  _spl_dm_as "$DM_DESK" test -s "$d/pinned" || { do_log "FAIL switch: the fleet desk $DM_FLEET is not pinned under $DM_DESK"; bad=1; }
  [[ -n "$(_spl_dm_pid "$DM_DESK" "$d")" ]] || { do_log "FAIL switch: the fleet desk $DM_FLEET has no live sidecar under $DM_DESK"; bad=1; }
  while read -r e ws id; do
    [[ -n "$e" ]] || continue
    d="$(_spl_dm_root "$DM_BOX" "$e")/desk/$ws/$id"
    if [[ -n "$(_spl_dm_pid "$DM_BOX" "$d")" ]]; then do_log "FAIL switch: $e $ws/$id has a live sidecar under $DM_BOX"; bad=1
    else do_log "INFO switch: $e $ws/$id stays under $DM_BOX, no live sidecar"; fi
  done < <(_spl_dm_list)
  (( bad == 0 )) || { do_log "FAIL switch refused: box.env is unchanged"; return 1; }
  (( dry )) && { do_log "OK DRY_RUN box.env would get SPOOL_DESK_USER=$DM_DESK; no desk moves"; return 0; }
  _spl_dm_box_env "$DM_DESK"
}

# _spl_dm_one <env> <ws> <id>: one desk, steps 2 and 3 of spec 069 8.4. Sets
# DM_SECS (the downtime). 0 done; 1 refused or rolled back.
_spl_dm_one() {
  local e="$1" ws="$2" id="$3" froot troot src dst aside base="" pid t0
  froot="$(_spl_dm_root "$DM_FROM" "$e")" && troot="$(_spl_dm_root "$DM_TO" "$e")" || return 1
  src="$froot/desk/$ws/$id" dst="$troot/desk/$ws/$id" aside="$froot/desk.moved-$DM_STAMP/$ws/$id"
  _spl_dm_as "$DM_TO" test -e "$dst" && { do_log "FATAL $dst already exists: not overwritten"; return 1; }
  [[ "$DM_TO" == "$DM_BOX" ]] && base="$(_spl_dm_as "$DM_TO" find "$troot" -mindepth 3 -maxdepth 3 -type d -path "$troot/desk.moved-*/$ws/$id" 2>/dev/null | LC_ALL=C sort | tail -n 1)"
  pid="$(_spl_dm_pid "$DM_FROM" "$src")"; t0="$(date +%s)"; DM_SECS=0
  if [[ -n "$pid" ]]; then
    _spl_dm_side_as "$DM_FROM" stop "$e" "$ws" "$id" "$froot" || { do_log "FAIL cannot stop the sidecar of $e $ws/$id (pid $pid)"; return 1; }
  fi
  if ! _spl_dm_quiesce_on "$src" || ! _spl_dm_copy "$src" "$dst" "$troot" "$base" || ! _spl_dm_verify "$src" "$dst" "$base"; then
    _spl_dm_undo_copy "$dst" "$base"
    _spl_dm_quiesce_off
    [[ -n "$pid" ]] && _spl_dm_side_as "$DM_FROM" start "$e" "$ws" "$id" "$froot"
    do_log "FAIL $e $ws/$id rolled back: the source is in place$([[ -n "$pid" ]] && echo ", its sidecar restarted as $DM_FROM")"
    return 1
  fi
  if ! { _spl_dm_as "$DM_FROM" mkdir -p "${aside%/*}" && _spl_dm_as "$DM_FROM" mv "$src" "$aside"; }; then
    _spl_dm_undo_copy "$dst" "$base"; _spl_dm_quiesce_off; do_log "FAIL cannot rename $src aside"; return 1
  fi
  # The marker stays until the proof passes or the rollback has the source
  # back: a writer held by it re-checks the desk dir after its wait (75 when
  # the desk is gone), so none re-creates <src> under the aside (R7 W1).
  _spl_dm_quiesce_touch; _spl_dm_quiesce_to_off
  if [[ -n "$pid" ]] && ! _spl_dm_up "$DM_TO" "$e" "$ws" "$id" "$troot" "$dst"; then
    _spl_dm_undo_all "$e" "$ws" "$id" "$src" "$dst" "$aside" "$froot" "$troot"; return 1
  fi
  _spl_dm_quiesce_off
  _spl_dm_as "$DM_FROM" find "$froot/desk" -mindepth 0 -maxdepth 1 -type d -empty -delete 2>/dev/null
  DM_SECS=$(( $(date +%s) - t0 ))
  do_log "OK moved $e $ws/$id to $DM_TO ($dst; source kept at $aside); downtime $DM_SECS s$([[ -z "$pid" ]] && echo ' (no sidecar was live: none started)')"
}

# _spl_dm_copy <src> <dst> <to root> <base>: the desk into dst as DM_TO, modes
# kept. A base (back: the newest desk.moved-* copy) is renamed to dst first
# and the copy lands over it. desk/ and <workspace>/ are 0700.
_spl_dm_copy() {
  local src="$1" dst="$2" troot="$3" base="$4"; local -a ps
  _spl_dm_as "$DM_TO" mkdir -p "${dst%/*}" && _spl_dm_as "$DM_TO" chmod 700 "$troot" "$troot/desk" "${dst%/*}" || return 1
  _spl_dm_quiesce_to "$dst" || return 1
  if [[ -n "$base" ]]; then _spl_dm_as "$DM_TO" mv "$base" "$dst" || return 1
  else _spl_dm_as "$DM_TO" mkdir -m 700 "$dst" || return 1; fi
  _spl_dm_as "$DM_FROM" tar -C "$src" -cf - . 2>/dev/null | _spl_dm_as "$DM_TO" tar -C "$dst" -xpf - 2>/dev/null
  ps=("${PIPESTATUS[@]}")
  [[ "${ps[0]}" == 0 && "${ps[1]}" == 0 ]] || do_log "WARN the copy of $src exited ${ps[0]}/${ps[1]} (tar read/write): the verify decides"
  return 0
}

# _spl_dm_verify <src> <dst> <base>: the copy is the desk. Every source file
# is in dst (move: the lists are equal), the key digest is equal (compared,
# never printed), dst and dst/keys are 0700 and every key is 0600. The
# mirror's 60 s dedupe markers (<seat>/.mirror/seen/*, spool-mirror.py
# first_sighting) are not compared: a hook pruned them mid-copy (SPL-5247).
_spl_dm_verify() {
  local src="$1" dst="$2" base="$3" w miss extra ka kb bad=0 m
  w="$(umask 077 && mktemp -d)" || return 1
  _spl_dm_as "$DM_FROM" find "$src" -type f ! -path '*/.mirror/seen/*' -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$w/a"
  _spl_dm_as "$DM_TO" find "$dst" -type f ! -path '*/.mirror/seen/*' -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$w/b"
  miss="$(LC_ALL=C comm -23 "$w/a" "$w/b" | wc -l)" extra="$(LC_ALL=C comm -13 "$w/a" "$w/b" | wc -l)"
  rm -rf "$w"
  (( miss == 0 )) || { do_log "FAIL verify $dst: $miss file(s) missing in the copy"; bad=1; }
  [[ -n "$base" || "$extra" == 0 ]] || { do_log "FAIL verify $dst: $extra file(s) not in the source"; bad=1; }
  ka="$(_spl_dm_keysum "$DM_FROM" "$src")" kb="$(_spl_dm_keysum "$DM_TO" "$dst")"
  [[ -n "$ka" && "$ka" == "$kb" ]] || { do_log "FAIL verify $dst: the keys differ from the source (digest compared, not printed)"; bad=1; }
  m="$(_spl_dm_as "$DM_TO" stat -c %a "$dst" "$dst/keys" 2>/dev/null | tr '\n' ' ')"
  [[ "$m" == "700 700 " ]] || { do_log "FAIL verify $dst: desk and keys/ modes are '$m', want 700 700"; bad=1; }
  while read -r m; do
    [[ -n "$m" ]] && { do_log "FAIL verify $dst: key mode $m (want 600)"; bad=1; }
  done < <(_spl_dm_as "$DM_TO" find "$dst/keys" -type f ! -perm 600 -printf '%m\n' 2>/dev/null | sort | uniq -c | awk '{print $2 " x " $1}')
  return "$bad"
}

# _spl_dm_keysum <user> <desk dir>: one digest over the desk's key files (names
# and bytes), for a yes/no compare. Never logged.
_spl_dm_keysum() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  _spl_dm_as "$1" bash -c 'cd "$1/keys" 2>/dev/null && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-64' _ "$2"
}

# _spl_dm_undo_copy <dst> <base>: the copy goes away; a base is renamed back.
_spl_dm_undo_copy() {
  local dst="$1" base="$2"
  [[ "$dst" == */desk/*/* ]] || return 1
  if [[ -n "$base" ]]; then _spl_dm_as "$DM_TO" mv "$dst" "$base"
  else _spl_dm_as "$DM_TO" rm -rf -- "$dst"; fi
}

# _spl_dm_up <user> <env> <ws> <id> <root> <desk dir>: start the sidecar as
# that user, then the proof. 0 = proven; else DM_WHY says which step failed
# and whether the sidecar is up (pid file + a live hub-run), so a proof that
# could not run (no verdict: no probe login) never reads as a sidecar down.
_spl_dm_up() {
  local u="$1" p; DM_WHY=""
  _spl_dm_side_as "$u" start "$2" "$3" "$4" "$5" || { DM_WHY="its sidecar did not start"; return 1; }
  _spl_dm_side_as "$u" proof "$2" "$3" "$4" "$5" && return 0
  p="$(_spl_dm_pid "$u" "$6")"
  if [[ -n "$p" ]]; then
    DM_WHY="its sidecar is up (pid $p) but the proof did not pass (the 'FAIL proof' line above; 'no verdict' = do_spl_desk_check could not run, e.g. no readable probe login)"
  else
    DM_WHY="its sidecar is not up (no live hub-run behind its pid file)"
  fi
  return 1
}

# _spl_dm_undo_all <env> <ws> <id> <src> <dst> <aside> <from root> <to root>:
# the start or its proof failed (DM_WHY says which). Stop DM_TO's sidecar, copy dst over the
# aside source (messages since are kept), rename it back (refused when
# something re-created <src>: the aside would nest inside it), lift the
# quiesce marker, set dst aside in DM_TO's own desk.moved-<stamp>, start as
# DM_FROM.
_spl_dm_undo_all() {
  local e="$1" ws="$2" id="$3" src="$4" dst="$5" aside="$6" froot="$7" troot="$8" tas
  tas="$troot/desk.moved-$DM_STAMP/$ws/$id"
  do_log "FAIL the desk $e $ws/$id failed as $DM_TO: $DM_WHY; rolling it back"
  _spl_dm_side_as "$DM_TO" stop "$e" "$ws" "$id" "$troot"
  _spl_dm_as "$DM_TO" tar -C "$dst" -cf - . 2>/dev/null | _spl_dm_as "$DM_FROM" tar -C "$aside" -xpf - 2>/dev/null
  if _spl_dm_as "$DM_FROM" test -e "$src"; then
    _spl_dm_quiesce_off
    do_log "FATAL $src exists again (a writer that ignores the quiesce re-created it): $aside is NOT renamed back into it; merge the two by hand, then MOVE_CMD=back"
    return 1
  fi
  _spl_dm_as "$DM_FROM" mv "$aside" "$src" || { _spl_dm_quiesce_off; do_log "FATAL cannot rename $aside back to $src: put it back by hand, then MOVE_CMD=back"; return 1; }
  _spl_dm_quiesce_off
  _spl_dm_as "$DM_TO" mkdir -p "${tas%/*}" && _spl_dm_as "$DM_TO" mv "$dst" "$tas"
  if _spl_dm_up "$DM_FROM" "$e" "$ws" "$id" "$froot" "$src"; then
    do_log "OK $e $ws/$id is back as $DM_FROM"
  else
    do_log "FAIL $e $ws/$id is back on disk as $DM_FROM, but $DM_WHY: do_spl_desk_check"
  fi
}

# _spl_dm_side_as <user> <stop|start|proof> <env> <ws> <id> <root>: one
# sidecar step as that user. The caller's runs in a subshell; another user's
# runs its ./run (MOVE_RUN, default this checkout) under sudo with its HOME.
_spl_dm_side_as() {
  local u="$1" step="$2" e="$3" ws="$4" id="$5" root="$6" k
  local pw; pw="$(_spl_dm_pw_for "$u")"
  if [[ "$u" == "$DM_ME" ]]; then
    ENV="$e" SPL_STATE_DIR="$root" TENANT_ID="$ws" DESK_BOX="$id" PROBE_PW_FILE="$pw" _spl_dm_side "$step"
    return $?
  fi
  local -a pass=(HOME="$(_spl_dm_home "$u")" PATH="$PATH" ENV="$e" SPL_STATE_DIR="$root" TENANT_ID="$ws" DESK_BOX="$id" MOVE_CMD="_$step")
  [[ -n "$pw" ]] && pass+=("PROBE_PW_FILE=$pw")
  for k in SPOOL_ROOT SPOOL_TEST SPOOL_BOX_ENV PROBE_EMAIL DESK_ROSTER_JSON MOVE_CHECK_SECS MOVE_CHECK_EVERY MOVE_CHECK_429_SECS SPL_PRIVATE_CNF; do
    [[ -n "${!k:-}" ]] && pass+=("$k=${!k}")
  done
  sudo -n -u "$u" -- env "${pass[@]}" bash -c 'cd "$1" && ./run -a do_spl_desk_move' _ "${MOVE_RUN:-$PROJ_PATH}"
}

# _spl_dm_side <stop|start|proof>: the step on the desk ENV / TENANT_ID /
# DESK_BOX in SPL_STATE_DIR, as the user running it.
#   stop   do_spl_desk_down DESK_ALL=1 (no seat is released)
#   start  spl_desk_box_restart with its first seat (do_spl_desk_up)
#   proof  _spl_dm_proof for that seat
_spl_dm_side() {
  local d="$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX" seat
  case "$1" in
    stop) DESK_AGENT="" DESK_ALL=1 DRY_RUN=0 do_spl_desk_down >/dev/null; return $? ;;
  esac
  seat="$(spl_desk_box_agents "$d" | sed -n 1p)"
  [[ -n "$seat" ]] || { do_log "FAIL $TENANT_ID/$DESK_BOX has no seat to start its sidecar with"; return 1; }
  if [[ "$1" == start ]]; then spl_desk_box_restart "$d" "$TENANT_ID" "$DESK_BOX" "$seat"; return $?; fi
  _spl_dm_proof "$seat"
}

# _spl_dm_proof <seat>: do_spl_desk_check until ok / muted / agent-missing,
# every MOVE_CHECK_EVERY (5) s for MOVE_CHECK_SECS (60). One member login for
# the whole proof: roster-show.py keeps the session in PROBE_COOKIE_FILE, a
# 0600 file of a mktemp dir of this user, removed after (SPL-5233: one login
# per attempt was up to 13 a desk against the hub's 10 per address per 15
# min). A login 429 waits the hub's Retry-After, else MOVE_CHECK_EVERY
# doubled per 429 (at most 60 s), and retries; the 429 waits of one proof sum
# to at most MOVE_CHECK_429_SECS (300) and do not count against
# MOVE_CHECK_SECS. A Retry-After under 1 s counts as the doubled wait, so
# every 429 spends at least 1 s of that bound. A wait past it ends the proof:
# 'no verdict'. The session dir goes on every return, and on INT / TERM / HUP
# before the caller's own trap runs (exit 130 when there is none).
_spl_dm_proof() {
  local seat="$1" every="${MOVE_CHECK_EVERY:-5}" left="${MOVE_CHECK_SECS:-60}" budget="${MOVE_CHECK_429_SECS:-300}"
  local back jar out v="" w ra line rc=1 old_traps h sig
  [[ "$every" =~ ^[1-9][0-9]*$ && "$left" =~ ^[0-9]+$ && "$budget" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL MOVE_CHECK_EVERY (>= 1), MOVE_CHECK_SECS and MOVE_CHECK_429_SECS must be whole seconds"; return 1; }
  back="$every"
  jar="$(umask 077 && mktemp -d)" || { do_log "FAIL proof $TENANT_ID/$DESK_BOX: no temp dir for its session"; return 1; }
  old_traps="$(trap -p INT TERM HUP)"
  # each signal keeps its OWN caller handler: INT is ignored in a bash
  # started under & without job control, so INT's handler cannot stand in
  # for TERM's (SPL-5233, CI run 42889002535)
  for sig in INT TERM HUP; do
    h="$(trap -p "$sig")"; [[ -n "$h" ]] && eval "set -- $h" && h="$3"
    # shellcheck disable=SC2064  # expands now on purpose: this jar, the caller's handler
    trap "rm -rf -- $(printf '%q' "$jar"); ${h:-exit 130}" "$sig"
  done
  while :; do
    out="$(DESK_AGENT="$seat" DRY_RUN=1 PROBE_COOKIE_FILE="$jar/session" do_spl_desk_check 2>&1)"
    v="$(grep -o '"verdict": "[a-z-]*"' <<<"$out" | tail -n 1 | cut -d'"' -f4)"
    case "$v" in ok | muted | agent-missing) do_log "INFO proof $TENANT_ID/$DESK_BOX: $v"; rc=0; break ;; esac
    if grep -q '"status": 429' <<<"$out"; then
      ra="$(grep -o '"retry_after": [0-9]*' <<<"$out" | tail -n 1 | grep -o '[0-9]*$')"
      w="${ra:-$back}"; (( w >= 1 )) || w="$back"
      if (( w > budget )); then
        do_log "FAIL proof $TENANT_ID/$DESK_BOX: the member login is rate limited (429); the next try is in $w s, past the $budget s left of MOVE_CHECK_429_SECS (${MOVE_CHECK_429_SECS:-300})"
        break
      fi
      do_log "INFO proof $TENANT_ID/$DESK_BOX: login 429 (rate_limited), retrying in $w s ($budget s of 429 back-off left)"
      sleep "$w"; budget=$((budget - w)); back=$((back * 2)); (( back > 60 )) && back=60
      continue
    fi
    (( left >= every )) || break
    sleep "$every"; left=$((left - every))
  done
  rm -rf -- "$jar"
  trap - INT TERM HUP; [[ -n "$old_traps" ]] && eval "$old_traps"
  (( rc == 0 )) && return 0
  do_log "FAIL proof $TENANT_ID/$DESK_BOX: do_spl_desk_check says '${v:-no verdict}' after ${MOVE_CHECK_SECS:-60} s"
  # the reason from the last check: 'no verdict' alone cannot tell an
  # unreadable probe login from a login 429 (SPL-4985, 2026-11-09)
  while IFS= read -r line; do do_log "FAIL proof output: $line"; done < <(grep -E 'FATAL|FAIL' <<<"$out" | tail -n 5)
  return 1
}

# _spl_dm_prune <dry>: the desk.moved-<UTC> copies of both users older than
# MOVE_PRUNE_DAYS, removed by their owner.
_spl_dm_prune() {
  local dry="$1" days="${MOVE_PRUNE_DAYS:-7}" u e r d st n=0 cut
  [[ "$days" =~ ^[0-9]+$ ]] || { do_log "FATAL MOVE_PRUNE_DAYS must be whole days, got '$days'"; return 1; }
  cut="$(date -u -d "-$days days" +%Y%m%dT%H%M%SZ)"
  for u in "$DM_BOX" "$DM_DESK"; do
    for e in $DM_ENVS; do
      r="$(_spl_dm_root "$u" "$e")" || continue
      while IFS= read -r d; do
        st="${d##*/desk.moved-}"
        [[ "$st" =~ ^[0-9]{8}T[0-9]{6}Z$ && ! "$st" > "$cut" ]] || continue
        n=$((n + 1))
        if (( dry )); then do_log "INFO DRY_RUN would remove $d ($u, $(_spl_dm_as "$u" du -sh "$d" 2>/dev/null | cut -f1))"
        elif _spl_dm_as "$u" rm -rf -- "$d"; then do_log "OK removed $d ($u)"
        else do_log "FAIL cannot remove $d"; return 1; fi
      done < <(_spl_dm_as "$u" find "$r" -mindepth 1 -maxdepth 1 -type d -name 'desk.moved-*' 2>/dev/null | LC_ALL=C sort)
    done
  done
  (( n > 0 )) || { do_log "OK nothing to prune (no desk.moved-* older than $days day(s))"; return 0; }
  (( dry )) && do_log "OK DRY_RUN nothing was removed. Re-run with DRY_RUN=0 to remove $n cop(ies)."
  return 0
}
