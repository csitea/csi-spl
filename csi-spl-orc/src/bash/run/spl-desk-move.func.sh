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
# @description move and back hold the reconcile pause of each env
# @description (<spool root>/.desk-reconcile.<env>.pause, refreshed before
# @description every desk) and leave it: the reconcile cron lines move to
# @description the desk user first (do_spl_desk_install_service), then the
# @description pause file goes. Keys are named by count and mode only; their
# @description content and digests are never printed. The desk user's side
# @description runs through `sudo -n -u <desk user>` (files) and its ./run
# @description (the sidecar steps); nothing is chowned, nothing needs root.
# @description Downtime per desk = stop to proof, in seconds.
# @description Dry run unless DRY_RUN=0 (plan always is one).
# @param MOVE_CMD (optional) - plan (default) | move | back | prune
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
# @param   read of the proof, as do_spl_desk_check documents them
# @param DRY_RUN (optional) - 1 (default) or 0
# @example MOVE_DESK_USER=<agent-user> ./run -a do_spl_desk_move
# @example MOVE_CMD=move MOVE_DESK_USER=<agent-user> DRY_RUN=0 ./run -a do_spl_desk_move
# @example MOVE_CMD=back DRY_RUN=0 ./run -a do_spl_desk_move
# @example MOVE_CMD=prune DRY_RUN=0 ./run -a do_spl_desk_move
#------------------------------------------------------------------------------
do_spl_desk_move() {
  local cmd="${MOVE_CMD:-plan}"
  case "$cmd" in
    _stop | _start | _proof) _spl_dm_side "${cmd#_}"; return $? ;;
    plan | move | back | prune) ;;
    *) do_log "FATAL MOVE_CMD must be plan, move, back or prune, got: '$cmd'"; return 1 ;;
  esac
  do_require_bin tar sha256sum flock || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$cmd" == plan ]] && dry=1
  _spl_dm_ctx "$cmd" || return 1
  [[ "$cmd" == prune ]] && { _spl_dm_prune "$dry"; return $?; }
  local -a desks=()
  mapfile -t desks < <(_spl_dm_list)
  _spl_dm_plan "${desks[@]}"
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
  local cmd="$1" x e ws id rc=0 secs moved=() json=""; shift
  _spl_dm_pause || return 1
  for x in "$@"; do
    read -r e ws id <<<"$x"
    _spl_dm_pause || return 1
    _spl_dm_one "$e" "$ws" "$id"; rc=$?
    (( rc == 0 )) || { do_log "FAIL $cmd stopped at $e $ws/$id; the desks before it are done, the rest are untouched"; break; }
    secs="$DM_SECS"; moved+=("$e/$ws/$id")
    json+="${json:+, }{\"desk\": \"$e/$ws/$id\", \"downtime_secs\": $secs}"
    (( secs <= DM_MAX )) || { do_log "FAIL $e $ws/$id was down ${secs} s (> MOVE_MAX_SECS $DM_MAX): the box stops here"; rc=4; break; }
  done
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

# _spl_dm_finish <cmd> <done> <all>: every desk done and no MOVE_DESKS filter:
# box.env follows (move: SPOOL_DESK_USER=<desk user>; back: removed), then
# the steps left to the operator are printed.
_spl_dm_finish() {
  local cmd="$1" bc
  bc="$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/box-config.sh"
  if [[ -n "${MOVE_DESKS:-}" ]]; then
    do_log "INFO MOVE_DESKS was set: box.env is left alone"
  elif [[ "$cmd" == move ]]; then
    bash "$bc" "SPOOL_DESK_USER=$DM_DESK" >/dev/null || { do_log "FAIL box.env: cannot set SPOOL_DESK_USER=$DM_DESK"; return 1; }
    do_log "OK box.env: SPOOL_DESK_USER=$DM_DESK"
  else
    bash "$bc" "SPOOL_DESK_USER=" >/dev/null || { do_log "FAIL box.env: cannot remove SPOOL_DESK_USER"; return 1; }
    do_log "OK box.env: SPOOL_DESK_USER removed"
  fi
  do_log "OK $cmd done: $2 of $3 desk(s). The reconcile pause stays until the reconcile cron lines run as $DM_TO (do_spl_desk_install_service) and the agents' MCP follows (do_spl_agent_mcp_install); it is ignored after DESK_PAUSE_MAX_SECS (default 1800 s)"
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
  if ! _spl_dm_copy "$src" "$dst" "$troot" "$base" || ! _spl_dm_verify "$src" "$dst" "$base"; then
    _spl_dm_undo_copy "$dst" "$base"
    [[ -n "$pid" ]] && _spl_dm_side_as "$DM_FROM" start "$e" "$ws" "$id" "$froot"
    do_log "FAIL $e $ws/$id rolled back: the source is in place$([[ -n "$pid" ]] && echo ", its sidecar restarted as $DM_FROM")"
    return 1
  fi
  if ! { _spl_dm_as "$DM_FROM" mkdir -p "${aside%/*}" && _spl_dm_as "$DM_FROM" mv "$src" "$aside"; }; then
    _spl_dm_undo_copy "$dst" "$base"; do_log "FAIL cannot rename $src aside"; return 1
  fi
  if [[ -n "$pid" ]] && ! { _spl_dm_side_as "$DM_TO" start "$e" "$ws" "$id" "$troot" && _spl_dm_side_as "$DM_TO" proof "$e" "$ws" "$id" "$troot"; }; then
    _spl_dm_undo_all "$e" "$ws" "$id" "$src" "$dst" "$aside" "$froot" "$troot"; return 1
  fi
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
  if [[ -n "$base" ]]; then _spl_dm_as "$DM_TO" mv "$base" "$dst" || return 1
  else _spl_dm_as "$DM_TO" mkdir -m 700 "$dst" || return 1; fi
  _spl_dm_as "$DM_FROM" tar -C "$src" -cf - . 2>/dev/null | _spl_dm_as "$DM_TO" tar -C "$dst" -xpf - 2>/dev/null
  ps=("${PIPESTATUS[@]}")
  [[ "${ps[0]}" == 0 && "${ps[1]}" == 0 ]] || do_log "WARN the copy of $src exited ${ps[0]}/${ps[1]} (tar read/write): the verify decides"
  return 0
}

# _spl_dm_verify <src> <dst> <base>: the copy is the desk. Every source file
# is in dst (move: the lists are equal), the key digest is equal (compared,
# never printed), dst and dst/keys are 0700 and every key is 0600.
_spl_dm_verify() {
  local src="$1" dst="$2" base="$3" w miss extra ka kb bad=0 m
  w="$(umask 077 && mktemp -d)" || return 1
  _spl_dm_as "$DM_FROM" find "$src" -type f -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$w/a"
  _spl_dm_as "$DM_TO" find "$dst" -type f -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$w/b"
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

# _spl_dm_undo_all <env> <ws> <id> <src> <dst> <aside> <from root> <to root>:
# the start or its proof failed. Stop DM_TO's sidecar, copy dst over the
# aside source (messages since are kept), rename it back, set dst aside in
# DM_TO's own desk.moved-<stamp>, start as DM_FROM.
_spl_dm_undo_all() {
  local e="$1" ws="$2" id="$3" src="$4" dst="$5" aside="$6" froot="$7" troot="$8" tas
  tas="$troot/desk.moved-$DM_STAMP/$ws/$id"
  do_log "FAIL the desk $e $ws/$id did not come up as $DM_TO: rolling it back"
  _spl_dm_side_as "$DM_TO" stop "$e" "$ws" "$id" "$troot"
  _spl_dm_as "$DM_TO" tar -C "$dst" -cf - . 2>/dev/null | _spl_dm_as "$DM_FROM" tar -C "$aside" -xpf - 2>/dev/null
  _spl_dm_as "$DM_FROM" mv "$aside" "$src" || { do_log "FATAL cannot rename $aside back to $src: put it back by hand, then MOVE_CMD=back"; return 1; }
  _spl_dm_as "$DM_TO" mkdir -p "${tas%/*}" && _spl_dm_as "$DM_TO" mv "$dst" "$tas"
  if _spl_dm_side_as "$DM_FROM" start "$e" "$ws" "$id" "$froot" && _spl_dm_side_as "$DM_FROM" proof "$e" "$ws" "$id" "$froot"; then
    do_log "OK $e $ws/$id is back as $DM_FROM"
  else
    do_log "FAIL $e $ws/$id is back on disk as $DM_FROM but its sidecar did not come up: do_spl_desk_check"
  fi
}

# _spl_dm_side_as <user> <stop|start|proof> <env> <ws> <id> <root>: one
# sidecar step as that user. The caller's runs in a subshell; another user's
# runs its ./run (MOVE_RUN, default this checkout) under sudo with its HOME.
_spl_dm_side_as() {
  local u="$1" step="$2" e="$3" ws="$4" id="$5" root="$6" k
  if [[ "$u" == "$DM_ME" ]]; then
    ENV="$e" SPL_STATE_DIR="$root" TENANT_ID="$ws" DESK_BOX="$id" _spl_dm_side "$step"
    return $?
  fi
  local -a pass=(HOME="$(_spl_dm_home "$u")" PATH="$PATH" ENV="$e" SPL_STATE_DIR="$root" TENANT_ID="$ws" DESK_BOX="$id" MOVE_CMD="_$step")
  for k in SPOOL_ROOT SPOOL_TEST SPOOL_BOX_ENV PROBE_EMAIL PROBE_PW_FILE DESK_ROSTER_JSON MOVE_CHECK_SECS MOVE_CHECK_EVERY SPL_PRIVATE_CNF; do
    [[ -n "${!k:-}" ]] && pass+=("$k=${!k}")
  done
  sudo -n -u "$u" -- env "${pass[@]}" bash -c 'cd "$1" && ./run -a do_spl_desk_move' _ "${MOVE_RUN:-$PROJ_PATH}"
}

# _spl_dm_side <stop|start|proof>: the step on the desk ENV / TENANT_ID /
# DESK_BOX in SPL_STATE_DIR, as the user running it.
#   stop   do_spl_desk_down DESK_ALL=1 (no seat is released)
#   start  spl_desk_box_restart with its first seat (do_spl_desk_up)
#   proof  do_spl_desk_check for that seat, until ok / muted / agent-missing
#          (MOVE_CHECK_SECS, default 60)
_spl_dm_side() {
  local d="$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX" seat v i out
  case "$1" in
    stop) DESK_AGENT="" DESK_ALL=1 DRY_RUN=0 do_spl_desk_down >/dev/null; return $? ;;
  esac
  seat="$(spl_desk_box_agents "$d" | sed -n 1p)"
  [[ -n "$seat" ]] || { do_log "FAIL $TENANT_ID/$DESK_BOX has no seat to start its sidecar with"; return 1; }
  if [[ "$1" == start ]]; then spl_desk_box_restart "$d" "$TENANT_ID" "$DESK_BOX" "$seat"; return $?; fi
  for ((i = 0; i <= ${MOVE_CHECK_SECS:-60}; i += ${MOVE_CHECK_EVERY:-5})); do
    out="$(DESK_AGENT="$seat" DRY_RUN=1 do_spl_desk_check 2>&1)"
    v="$(grep -o '"verdict": "[a-z-]*"' <<<"$out" | tail -n 1 | cut -d'"' -f4)"
    case "$v" in ok | muted | agent-missing) do_log "INFO proof $TENANT_ID/$DESK_BOX: $v"; return 0 ;; esac
    sleep "${MOVE_CHECK_EVERY:-5}"
  done
  do_log "FAIL proof $TENANT_ID/$DESK_BOX: do_spl_desk_check says '${v:-no verdict}' after ${MOVE_CHECK_SECS:-60} s"
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
