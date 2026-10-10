#!/bin/bash
#------------------------------------------------------------------------------
# @description Move the seated non-AI desks off their retired legacy ids
# @description (specs/061 FR-011 for an agent with no window): RSP-01, the
# @description responder on every box-rsp / sat-rsp desk, becomes
# @description SPL_RSP_AGENT, and OPS-01, the CI ops desk on box-ci, becomes
# @description SPL_OPS_AGENT (lib/bash/funcs/spl-desk-agents.func.sh). spool-env
# @description refuses a legacy id since 2026-10-03T20:59:59Z, so every
# @description do_spl_desk_up_boxes and do_spl_responder_sweep tick that seats
# @description one fails. Per desk <SPL_STATE_DIR>/desk/<tenant>/<box> whose
# @description spool holds a real <old> dir, under that desk's up-all.lock:
# @description   spool  spool/<old> -> spool/<new>, and <old> stays as a link to
# @description          <new>, so a path built from the old id still lands; a
# @description          link is not an agent dir, so neither the sidecar nor
# @description          the reconcile ever seats <old> again
# @description   alias  <SPOOL_ROOT>/agent-id-aliases.tsv gets <old> <new> claude
# @description          <box> <utc> unless (old, box) has a row
# @description   seat   the re-seat is the next tick: a live sidecar announces
# @description          <new> on its next scan; a dead one is seated by
# @description          do_spl_desk_up_boxes (a box with a pid file) or, for the
# @description          responder, by do_spl_responder_sweep on the lease holder
# @description The inbox, mute marker (.no-poke) and desk key move with the dir
# @description or stay per box; no key is read or printed. A desk already moved
# @description is skipped, so a re-run is safe. A <new> that is only a
# @description SKELETON (empty dirs, at most a .no-poke file: what a seat of
# @description <new> lays down before the move, e.g. the lease holder's
# @description responder sweep) is removed under the lock first, its
# @description .no-poke with it: the mute state of <old> is the one that
# @description carries. <new> held by anything else: FAIL, nothing moved.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd (prd needs the owner's go)
# @param DESK_RENAME (optional) - "<old>:<new> ...", default
# @param   "RSP-01:$SPL_RSP_AGENT OPS-01:$SPL_OPS_AGENT"
# @param TENANT_ID (optional) - only this tenant's desks (default every one)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - the alias table's root, default /var/spool-hub
# @example ENV=prd ./run -a do_spl_desk_agent_rename
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_desk_agent_rename
#------------------------------------------------------------------------------
do_spl_desk_agent_rename() {
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local pairs="${DESK_RENAME:-RSP-01:$SPL_RSP_AGENT OPS-01:$SPL_OPS_AGENT}" p old new
  for p in $pairs; do
    old="${p%%:*}"; new="${p#*:}"
    [[ "$old" =~ ^[A-Z]{2,4}-[0-9]+$ && "$new" =~ ^[acgmq]-[0-9]{3}$ && "${new#?-}" != 00[0-3] ]] ||
      { do_log "FATAL DESK_RENAME takes <legacy id>:<new id> pairs (c-684), got: '$p'"; return 1; }
  done
  local tdir bdir t b rc=0 n=0
  SPL_DESK_RENAMED=0
  for tdir in "$SPL_STATE_DIR"/desk/*/; do
    t="${tdir%/}"; t="${t##*/}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
    [[ -z "${TENANT_ID:-}" || "$t" == "$TENANT_ID" ]] || continue
    for bdir in "$tdir"*/; do
      b="${bdir%/}"; b="${b##*/}"
      [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && -d "$bdir/spool" ]] || continue
      for p in $pairs; do
        spl_desk_agent_rename_one "${bdir%/}" "$t" "$b" "${p%%:*}" "${p#*:}" "$dry" || rc=1
      done
      n=$((n + 1))
    done
  done
  if (( dry )); then
    do_log "OK DRY_RUN $ENV: $SPL_DESK_RENAMED desk seat(s) of $n desk(s) would move ($pairs); nothing was touched. Re-run with DRY_RUN=0."
  else
    do_log "OK $ENV: $SPL_DESK_RENAMED desk seat(s) of $n desk(s) moved ($pairs); the next desk tick seats the new ids"
  fi
  return "$rc"
}

# spl_desk_agent_rename_one <desk dir> <tenant> <box> <old> <new> <dry>
spl_desk_agent_rename_one() {
  local d="$1" t="$2" b="$3" old="$4" new="$5" dry="$6" s="$1/spool"
  if [[ -L "$s/$old" && "$(readlink "$s/$old")" == "$new" ]]; then
    do_log "INFO $b of $t: $old already moved to $new"
    spl_desk_agent_alias "$old" "$new" "$b" "$dry"; return
  fi
  [[ -d "$s/$old" && ! -L "$s/$old" ]] || return 0
  if [[ -e "$s/$new" || -L "$s/$new" ]] && ! spl_desk_agent_skeleton "$s/$new"; then
    do_log "FAIL $b of $t: $s/$new is held; $old was not moved"; return 1
  fi
  SPL_DESK_RENAMED=$((SPL_DESK_RENAMED + 1))
  if (( dry )); then
    [[ -e "$s/$new" ]] && do_log "INFO DRY_RUN would: $b of $t: remove the empty skeleton spool/$new (the mute of $old carries)"
    do_log "INFO DRY_RUN would: $b of $t: spool/$old -> spool/$new (+ link $old -> $new)"
    spl_desk_agent_alias "$old" "$new" "$b" 1; return
  fi
  exec 7>"$d/up-all.lock" || { do_log "FATAL cannot open $d/up-all.lock"; return 1; }
  flock -w 30 7 || { exec 7>&-; do_log "FAIL $b of $t: $d/up-all.lock stayed locked; $old was not moved"; return 1; }
  if [[ -e "$s/$new" || -L "$s/$new" ]]; then
    spl_desk_agent_skeleton "$s/$new" && rm -f -- "$s/$new/.no-poke" && find "$s/$new" -depth -type d -empty -delete
    if [[ -e "$s/$new" || -L "$s/$new" ]]; then
      flock -u 7; exec 7>&-
      do_log "FAIL $b of $t: $s/$new is held; $old was not moved"; return 1
    fi
    do_log "INFO $b of $t: the empty skeleton spool/$new was removed"
  fi
  if mv -T "$s/$old" "$s/$new" && ln -s "$new" "$s/$old"; then
    flock -u 7; exec 7>&-
    do_log "INFO $b of $t: spool/$old -> spool/$new (+ link)"
    spl_desk_agent_alias "$old" "$new" "$b" 0
  else
    flock -u 7; exec 7>&-
    do_log "FAIL $b of $t: moving spool/$old to spool/$new failed"; return 1
  fi
}

# spl_desk_agent_skeleton <dir>: 0 when <dir> is a real dir holding nothing
# but dirs and at most a regular .no-poke at its top, else 1. Only such a
# dir is removed, and only by deleting empty dirs, so no message can go.
spl_desk_agent_skeleton() {
  local x="$1"
  [[ -d "$x" && ! -L "$x" ]] || return 1
  [[ ! -L "$x/.no-poke" ]] && [[ ! -e "$x/.no-poke" || -f "$x/.no-poke" ]] || return 1
  [[ -z "$(find "$x" -mindepth 1 ! -type d ! -path "$x/.no-poke" -print -quit 2>/dev/null)" ]]
}

# spl_desk_agent_alias <old> <new> <box> <dry>: the (old, box) row of the
# machine's alias table, written once.
spl_desk_agent_alias() {
  local old="$1" new="$2" b="$3" dry="$4" f="${SPOOL_ROOT:-/var/spool-hub}/agent-id-aliases.tsv"
  if [[ -r "$f" ]] && awk -F'\t' -v o="$old" -v b="$b" '$1 == o && $4 == b { x = 1 } END { exit !x }' "$f"; then
    return 0
  fi
  if (( dry )); then do_log "INFO DRY_RUN would: add alias row $old -> $new ($b) to $f"; return 0; fi
  ( flock -w 30 9 || exit 1
    printf '%s\t%s\tclaude\t%s\t%s\n' "$old" "$new" "$b" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$f" ) 9>>"$f.lock" ||
    { do_log "FAIL could not add the alias row $old -> $new ($b) to $f"; return 1; }
  do_log "INFO alias row $old -> $new ($b) added to $f"
}
