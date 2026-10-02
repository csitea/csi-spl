#!/bin/bash
#------------------------------------------------------------------------------
# @description Move this machine's agent mailboxes to the <ID>@<box> layout
# @description (specs/058 section 6): the dir $SPOOL_ROOT/<ID> becomes
# @description $SPOOL_ROOT/<ID>@<box>, and <ID> stays as the compat symlink
# @description <ID> -> <ID>@<box>, so every reader and writer that builds the
# @description bare path keeps reaching the SAME dir. No message is lost: each
# @description move is ONE renameat2(RENAME_EXCHANGE) of the dir with a
# @description pre-made self-loop link named <ID>@<box>, so there is no instant
# @description where <ID> is missing and a writer could mkdir an orphan in a
# @description gap (a plain mv + ln -s has that gap).
# @description Idempotent: a mailbox already moved is skipped; a self-loop left
# @description by a killed run is finished (forward) or removed (rollback).
# @description ROLLBACK=1 is the same exchange back, then the self-loop goes.
# @description The id set the scan sees (<ID> and <ID>@<box> dirs, links never
# @description counted - the rule of `spool layout` / the hub-run roster) must
# @description be the same before and after, or the ids moved by this run are
# @description moved back and the action fails.
# @description A forward run refuses unless SPOOL_BIN answers `spool layout`:
# @description an older spool reads a migrated root as empty (`spool tail`).
# @description Order: plain lanes first, then the role ids 003, 002, 001 last.
# @description Prints one line per id and a JSON summary. Dry run unless DRY_RUN=0.
# @param SPOOL_ROOT (optional) - the harness spool root, default /var/spool-hub
# @param NAMING_BOX (optional) - the <box>, default spl_desk_box_default
# @param   (box.env SPOOL_DESK_BOX). The legacy box-desk is refused: the home
# @param   box is renamed ONCE, to its own 3-letter box (CLE-001, 2026-10-02)
# @param ONLY (optional) - space-separated ids to move, default every mailbox
# @param SKIP (optional) - space-separated ids to leave as they are
# @param ROLLBACK (optional) - 1 moves <ID>@<box> back to <ID>; default 0
# @param SPOOL_BIN (optional) - the spool CLI the gate asks, default spool
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_naming_migrate
# @example NAMING_BOX=<box> DRY_RUN=0 ./run -a do_spl_naming_migrate
# @example ROLLBACK=1 NAMING_BOX=<box> DRY_RUN=0 ./run -a do_spl_naming_migrate
#------------------------------------------------------------------------------
do_spl_naming_migrate() {
  do_require_bin python3 || return 1
  local root="${SPOOL_ROOT:-/var/spool-hub}" box="${NAMING_BOX:-$(spl_desk_box_default)}"
  local back="${ROLLBACK:-0}" only=" ${ONLY:-} " skip=" ${SKIP:-} " dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$back" == 0 || "$back" == 1 ]] || { do_log "FATAL ROLLBACK must be 0 or 1, got: '$back'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL NAMING_BOX '$box' is not a box id"; return 1; }
  [[ "$box" != box-desk ]] || { do_log "FATAL NAMING_BOX is the legacy box-desk: give this machine its own box first (SPOOL_DESK_BOX in box.env, specs/058 M5)"; return 1; }
  [[ -d "$root" ]] || { do_log "FATAL SPOOL_ROOT $root is not a dir"; return 1; }
  if [[ "${SPOOL_TEST:-}" == 1 && "$(readlink -m -- "$root")" == "$(readlink -m -- "${SPOOL_LIVE_ROOT:-/var/spool-hub}")" ]]; then
    do_log "FATAL SPOOL_TEST=1 and SPOOL_ROOT is the live root: a test must give its own SPOOL_ROOT"; return 1
  fi
  if (( ! dry && ! back )); then
    SPOOL_ROOT="$root" "${SPOOL_BIN:-spool}" layout >/dev/null 2>&1 ||
      { do_log "FATAL '${SPOOL_BIN:-spool}' does not answer 'spool layout': roll the spool binary first (specs/058 6.4 step 1)"; return 1; }
  fi

  local -a ids=()
  mapfile -t ids < <(_spl_naming_ids "$root" "$box" "$back")
  local before after id rc=0 n=0 done_n=0 skip_n=0 fail_n=0
  local -a moved=()
  before="$(_spl_naming_scan "$root")"
  for id in "${ids[@]}"; do
    [[ "$only" == "  " || "$only" == *" $id "* ]] || continue
    [[ "$skip" == *" $id "* ]] && { skip_n=$((skip_n + 1)); continue; }
    n=$((n + 1))
    if (( dry )); then
      do_log "INFO DRY_RUN would $( ((back)) && echo "move $id@$box back to $id" || echo "move $id to $id@$box (link $id kept)")"
      continue
    fi
    if _spl_naming_one "$root" "$id" "$box" "$back"; then
      done_n=$((done_n + 1)); moved+=("$id")
    else
      fail_n=$((fail_n + 1)); rc=1
    fi
  done
  if (( ! dry )); then
    after="$(_spl_naming_scan "$root")"
    if [[ "$before" != "$after" ]]; then
      do_log "FATAL the id set changed (before: $(wc -w <<<"$before"), after: $(wc -w <<<"$after")): moving the ${#moved[@]} ids of this run back"
      for id in "${moved[@]}"; do _spl_naming_one "$root" "$id" "$box" "$((1 - back))" || true; done
      rc=1
    fi
  fi
  printf '{"root":"%s","box":"%s","rollback":%s,"dry_run":%s,"planned":%s,"moved":%s,"skipped":%s,"failed":%s}\n' \
    "$root" "$box" "$back" "$dry" "$n" "$done_n" "$skip_n" "$fail_n"
  (( dry )) && do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
  return $rc
}

# _spl_naming_ids <root> <box> <rollback> -> the ids to visit, one per line:
# forward = every real dir named <ID> (plus any <ID> with a self-loop
# <ID>@<box> left by a killed run); rollback = every <ID>@<box> dir. The role
# ids 001-003 come last, 003 first and 001 at the very end.
_spl_naming_ids() {
  local root="$1" box="$2" back="$3" e name
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for e in "$root"/*; do
    name="${e##*/}"
    if (( back )); then
      [[ "$name" == *"@$box" && -d "$e" && ! -L "$e" ]] || continue
      name="${name%@"$box"}"
    else
      [[ -d "$e" && ! -L "$e" ]] || continue
    fi
    [[ "$name" =~ ^${SPOOL_PARTICIPANT_RX}$ && "${name%%-*}" != BOX ]] && printf '%s\n' "$name"
  done | awk '{ r = ($0 ~ /^[A-Z]+-00[1-3]$/) ? 4 - substr($0, length($0)) : 0; print r "\t" $0 }' |
    sort -t$'\t' -k1,1n -k2,2 | cut -f2
}

# _spl_naming_scan <root> -> the sorted id set: dirs <ID> or <ID>@<box>, never
# a link (spool.ScanAgents' rule).
_spl_naming_scan() {
  local e name
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for e in "$1"/*; do
    [[ -d "$e" && ! -L "$e" ]] || continue
    name="${e##*/}"; name="${name%%@*}"
    [[ "$name" =~ ^${SPOOL_PARTICIPANT_RX}$ ]] && printf '%s\n' "$name"
  done | sort -u
}

# _spl_naming_one <root> <id> <box> <rollback> -> one mailbox moved (or found
# already moved); non-zero when its state is not one this action made.
_spl_naming_one() {
  local root="$1" id="$2" q="$2@$3" back="$4"
  local b="$root/$id" qp="$root/$2@$3"
  if (( ! back )); then
    if [[ -L "$b" && "$(readlink "$b")" == "$q" && -d "$qp" && ! -L "$qp" ]]; then
      do_log "INFO $id: already $q"; return 0
    fi
    [[ -d "$b" && ! -L "$b" ]] || { do_log "ERROR $id: $b is not a dir, left as it is"; return 1; }
    if [[ -e "$qp" ]] || { [[ -L "$qp" ]] && [[ "$(readlink "$qp")" != "$q" ]]; }; then
      do_log "ERROR $id: $qp exists and is not this action's self-loop, left as it is"; return 1
    fi
    [[ -L "$qp" ]] || ln -s "$q" "$qp" || { do_log "ERROR $id: cannot create the self-loop $qp"; return 1; }
    _spl_naming_exchange "$b" "$qp" || { rm -f "$qp"; do_log "ERROR $id: exchange failed, left as $id"; return 1; }
    do_log "OK $id -> $q (link $id kept)"
    return 0
  fi
  if [[ -d "$b" && ! -L "$b" ]]; then
    [[ -L "$qp" && "$(readlink "$qp")" == "$q" ]] && rm -f "$qp"
    do_log "INFO $id: already $id"; return 0
  fi
  [[ -L "$b" && "$(readlink "$b")" == "$q" && -d "$qp" && ! -L "$qp" ]] ||
    { do_log "ERROR $id: not in the shape this action leaves ($b -> $q), left as it is"; return 1; }
  _spl_naming_exchange "$b" "$qp" || { do_log "ERROR $id: exchange back failed"; return 1; }
  rm -f "$qp"
  do_log "OK $q -> $id"
}

# _spl_naming_exchange <a> <b> -> atomically swap two names (renameat2
# RENAME_EXCHANGE, Linux >= 3.15). coreutils `mv --exchange` refuses when both
# names resolve to the same dir, which is exactly the rollback case.
_spl_naming_exchange() {
  python3 - "$1" "$2" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
AT_FDCWD, RENAME_EXCHANGE = -100, 2
if libc.renameat2(AT_FDCWD, os.fsencode(sys.argv[1]), AT_FDCWD, os.fsencode(sys.argv[2]), RENAME_EXCHANGE) != 0:
    sys.exit("renameat2: " + os.strerror(ctypes.get_errno()))
PY
}
