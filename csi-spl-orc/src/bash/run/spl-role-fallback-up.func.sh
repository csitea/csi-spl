#!/bin/bash
#------------------------------------------------------------------------------
# @description Keep the fallback role seats of this box live as STANDBY
# @description (SPL-2532, follow-up of SPL-2521; owner HUM-10 t1 b3e90079,
# @description msg dfe76b16: "the order is claude -> grok -> agy"). The fleet
# @description lease hands a role to a fallback seat (LEASE_ORCH_FALLBACK,
# @description LEASE_DISPATCH_FALLBACK) only when that seat is a LIVE, able
# @description process; on 2026-10-19 no box ran one (0 processes carried
# @description g-001/g-002/g-003 on either fleet box), so the failover could never
# @description happen. Per box, for each fallback id of the two lists (the
# @description lease's own lists and defaults, spl_fleet_fallback; never a
# @description hard-coded id) with no live seat (spl_lease_agent_pid), it
# @description starts that seat through the rotation's start path
# @description (spl_rotate_spawn: spawn-window.sh SPAWN_REUSE_ID=1, the start
# @description check, the identity map) with a STANDBY seed: the seat acts
# @description only once the lease names it. It moves NO lease and never
# @description touches a claude holder: the lease code hands over after
# @description LEASE_STALE + LEASE_FALLBACK_WAIT per vendor step and hands
# @description back after LEASE_HOLDDOWN.
# @description A seat that cannot act is REFUSED by the lease's own test
# @description (spl_fleet_try: spl_lease_agent_able - login, limit, modal, a
# @description fresh watchdog HIT - plus spl_fleet_stuck), never a second
# @description detector: a live one is reported and left alone; one this run
# @description started (a dialog at start, or not able ROLE_FALLBACK_SETTLE s
# @description later) is closed (spl_rotate_restore) and not started again
# @description for ROLE_FALLBACK_BACKOFF s, so a seat on its weekly limit is
# @description not restarted every tick.
# @description Idempotent; one run at a time per box (flock on
# @description <spool root>/dispatch/role-fallback.lock) and per id (the id
# @description lock, spec 102 4.2). Dry run unless DRY_RUN=0: PLAN lines only.
# @description ROLE_FALLBACK_CMD picks:
# @description   up      - (default) the pass above, now
# @description   cron    - the desk reconcile's step (every 5 min): the pass
# @description             only while <spool root>/dispatch/role-fallback.conf
# @description             says ROLE_FALLBACK=1 (the opt-in; no file = nothing)
# @description   enable  - write ROLE_FALLBACK=1 (+ ROLE_FALLBACK_IDS when set)
# @description             into role-fallback.conf
# @description   disable - write ROLE_FALLBACK=0 there; started seats keep running
# @description One line per verdict in <spool root>/dispatch/role-fallback.log
# @description (a seat's line only when its verdict changes).
# @param ROLE_FALLBACK_CMD (optional) - up (default) | cron | enable | disable
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ROLE_FALLBACK_IDS (optional) - comma-separated: only these ids of the fallback lists (env, else role-fallback.conf); an id in no list is ignored with a WARN
# @param LEASE_ORCH_FALLBACK / LEASE_DISPATCH_FALLBACK (optional) - the lease's lists (env or lease.conf), default g-001,a-001 / g-002,g-003,a-002,a-003; none = off
# @param ROLE_FALLBACK_SETTLE (optional) - seconds between the start and the able test, default 30
# @param ROLE_FALLBACK_BACKOFF (optional) - seconds a refused start is not retried, default 3600
# @example ./run -a do_spl_role_fallback_up
# @example ROLE_FALLBACK_IDS=g-001,g-002 DRY_RUN=0 ./run -a do_spl_role_fallback_up
# @example ROLE_FALLBACK_CMD=enable ROLE_FALLBACK_IDS=g-001,g-002 DRY_RUN=0 ./run -a do_spl_role_fallback_up
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_role_fallback_up() {
  spl_rotate_conf || return 1
  local cmd="${ROLE_FALLBACK_CMD:-up}"
  RF_CONF="$LEASE_DIR/role-fallback.conf"
  RF_LOG="$LEASE_DIR/role-fallback.log"
  RF_DIR="$LEASE_DIR/role-fallback"
  case "$cmd" in
    up) ;;
    cron)
      [[ "$(spl_role_fallback_conf ROLE_FALLBACK)" == 1 ]] ||
        { echo "SKIP role fallback: not enabled in $RF_CONF (ROLE_FALLBACK_CMD=enable)"; return 0; } ;;
    enable|disable) spl_role_fallback_switch "$cmd"; return ;;
    *) do_log "FATAL ROLE_FALLBACK_CMD must be up, cron, enable or disable, got: '$cmd'"; return 1 ;;
  esac
  [[ -n "${ROLE_FALLBACK_IDS:-}" ]] || ROLE_FALLBACK_IDS="$(spl_role_fallback_conf ROLE_FALLBACK_IDS)"
  [[ "${ROLE_FALLBACK_SETTLE:=30}" =~ ^[0-9]+$ && "${ROLE_FALLBACK_BACKOFF:=3600}" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL ROLE_FALLBACK_SETTLE and ROLE_FALLBACK_BACKOFF must be whole seconds"; return 1; }
  [[ -n "${LEASE_FLEET:-}" ]] ||
    { echo "SKIP role fallback: no LEASE_FLEET in $LEASE_CONF (the fallback is fleet mode only)"; return 0; }
  : "${LEASE_ORCH:=}" "${LEASE_MASTER:=}" "${LEASE_FAILOVER:=}"
  if [[ "${DRY_RUN:-1}" == 0 ]]; then
    mkdir -p "$RF_DIR" || { do_log "FATAL cannot create $RF_DIR"; return 1; }
    exec 6>>"$LEASE_DIR/role-fallback.lock"
    flock -n 6 || { echo "SKIP role fallback: another run holds $LEASE_DIR/role-fallback.lock"; return 0; }
  fi
  local role id n=0
  while read -r role id; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    spl_role_fallback_one "$role" "$id"
  done < <(spl_role_fallback_ids)
  (( n )) || echo "SKIP role fallback: no fallback id to keep (lists: orch '$(spl_fleet_fallback orch)', dispatch '$(spl_fleet_fallback dispatch)'; ROLE_FALLBACK_IDS '${ROLE_FALLBACK_IDS:-}')"
  [[ "${DRY_RUN:-1}" == 1 ]] && echo "OK DRY_RUN nothing was started. Re-run with DRY_RUN=0."
  return 0
}

# KEY from role-fallback.conf (KEY=value, read, never sourced); empty when unset.
spl_role_fallback_conf() {
  sed -n "s/^$1=\([A-Za-z0-9,_-]*\)$/\1/p" "$RF_CONF" 2>/dev/null | tail -1
}

# enable | disable: ROLE_FALLBACK=1|0 (and ROLE_FALLBACK_IDS when set) into
# role-fallback.conf through the one KEY=value writer (keeps other keys, backup).
spl_role_fallback_switch() {
  local v=0 text
  [[ "$1" == enable ]] && v=1
  text="ROLE_FALLBACK=$v${ROLE_FALLBACK_IDS:+$'\n'ROLE_FALLBACK_IDS=$ROLE_FALLBACK_IDS}"
  [[ -z "${ROLE_FALLBACK_IDS:-}" || "$ROLE_FALLBACK_IDS" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] ||
    { do_log "FATAL ROLE_FALLBACK_IDS must be comma-separated ids, got: '$ROLE_FALLBACK_IDS'"; return 1; }
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    echo "PLAN $RF_CONF <- $(tr '\n' ' ' <<<"$text")"
    echo "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_lease_conf_write "$RF_CONF" role-fallback <<<"$text" || return 1
  echo "OK $RF_CONF: $(tr '\n' ' ' <<<"$text")"
}

# "<role> <id>" per fallback id of both lists, in the lease's order; narrowed
# to ROLE_FALLBACK_IDS when set. An id in both lists is kept once (its first role).
spl_role_fallback_ids() {
  local role id seen=" " want=",${ROLE_FALLBACK_IDS:-},"
  for role in orch dispatch; do
    for id in $(spl_fleet_fallback "$role"); do
      [[ "$seen" == *" $id "* ]] && continue
      seen+="$id "
      [[ -z "${ROLE_FALLBACK_IDS:-}" || "$want" == *",$id,"* ]] && echo "$role $id"
    done
  done
  for id in ${ROLE_FALLBACK_IDS//,/ }; do
    [[ "$seen" == *" $id "* ]] || echo "WARN role fallback: $id is in no fallback list (orch '$(spl_fleet_fallback orch)', dispatch '$(spl_fleet_fallback dispatch)'): ignored" >&2
  done
}

# spl_role_fallback_say RESULT ID DETAIL: one line to stdout; to role-fallback.log
# (not in a dry run) only when ID's RESULT differs from its last one.
spl_role_fallback_say() {
  local line last f="$RF_DIR/state.$2"
  line="$(date -u +%FT%TZ) $ROTATE_BOX $1 $2 $3"
  echo "$line"
  [[ "${DRY_RUN:-1}" == 1 || "$1" == PLAN ]] && return 0
  last="$(cat "$f" 2>/dev/null || true)"
  [[ "$last" == "$1" ]] && return 0
  echo "$line" >> "$RF_LOG"
  printf '%s\n' "$1" > "$f"
}

# One fallback id: OK (live and able), REFUSED (live, cannot act; or started
# and closed), BACKOFF, PLAN (dry run) or STARTED.
spl_role_fallback_one() {
  local role="$1" id="$2" kind pid why rid t now
  kind="$(spl_rotate_id_kind "$id")"
  case "$kind" in grok|agy) ;; *) spl_role_fallback_say SKIP "$id" "vendor '${kind:-unknown}' is no fallback vendor (grok, agy)"; return 0 ;; esac
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -n "$pid" ]]; then
    if spl_fleet_try "$id" >/dev/null; then spl_role_fallback_say OK "$id" "live and able, pid $pid ($kind, $role standby)"
    else spl_role_fallback_say REFUSED "$id" "live but cannot act: $(cat "$LEASE_DIR/able.$id" 2>/dev/null) (left as it is)"; fi
    return 0
  fi
  now="$(date +%s)"
  read -r t why 2>/dev/null < "$RF_DIR/refused.$id" || t=""
  if [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < ROLE_FALLBACK_BACKOFF )); then
    spl_role_fallback_say BACKOFF "$id" "refused $(( (now - t) / 60 )) min ago ($why): next try in $(( (ROLE_FALLBACK_BACKOFF - now + t + 59) / 60 )) min"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_role_fallback_say PLAN "$id" "no live seat: would start $kind $id@$ROTATE_BOX as $role STANDBY (spawn-window.sh SPAWN_REUSE_ID=1)"
    return 0
  fi
  rid="$(spl_rotate_new_rid fallback)"
  local idl=0
  spl_agent_id_lock "$id" do_spl_role_fallback_up "$rid" || idl=$?
  (( idl == 0 )) || { spl_role_fallback_say SKIP "$id" "id lock: $SPL_ID_LOCK_WHY"; return 0; }
  spl_role_fallback_start "$role" "$id" "$kind" "$rid"
  spl_agent_id_unlock "$id"
  return 0
}

# Start one seat through the rotation's path, then judge it with the lease's
# test; a seat that cannot act is closed and backed off.
spl_role_fallback_start() {
  local role="$1" id="$2" kind="$3" seed="$RF_DIR/$2.seed.md" why=""
  spl_role_fallback_seed "$role" "$id" > "$seed" || { spl_role_fallback_say REFUSED "$id" "cannot write $seed"; return 0; }
  chmod 0644 "$seed" 2>/dev/null || true
  # shellcheck disable=SC2034 # the rotation globals spl_rotate_spawn / spl_rotate_restore read
  ROTATE_RID="$4" ROTATE_KIND="$kind" ROTATE_FAMILY=fallback ROTATE_STATE_DIR="$RF_DIR" \
    ROTATE_OLD_PANE="" ROTATE_OLD_PID="" ROTATE_OLD_NAME="" ROTATE_LANE_SCOPE="role $id $role standby (fallback)"
  if ! spl_rotate_spawn "$id" "$seed"; then
    why="$ROTATE_ERR"
  else
    sleep "$ROLE_FALLBACK_SETTLE"
    spl_fleet_try "$id" >/dev/null || why="not able ${ROLE_FALLBACK_SETTLE}s after the start: $(cat "$LEASE_DIR/able.$id" 2>/dev/null)"
  fi
  if [[ -z "$why" ]]; then
    rm -f "$RF_DIR/refused.$id"
    spl_role_fallback_say STARTED "$id" "$kind pid $ROTATE_NEW_PID pane $ROTATE_NEW_PANE, $role STANDBY"
    return 0
  fi
  spl_rotate_restore "$id" "" "${ROTATE_NEW_PANE:-}"
  printf '%s %s\n' "$(date +%s)" "$(tr '\n' ' ' <<<"$why" | cut -c1-200)" > "$RF_DIR/refused.$id"
  spl_role_fallback_say REFUSED "$id" "started and closed: $why (no retry for ${ROLE_FALLBACK_BACKOFF}s)"
}

# The STANDBY seed (a brief file for spawn-window.sh).
spl_role_fallback_seed() {
  local role="$1" id="$2" show="cd $PROJ_PATH && sudo -u ${SPOOL_BOX_USER:-$USER} env SPOOL_ROOT=$SPOOL_ROOT LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease"
  cat <<EOF
# Brief: you are $id@$ROTATE_BOX, the STANDBY fallback seat of the $role role

Started by do_spl_role_fallback_up (SPL-2532). This is not a coding task and it has no end.

1. You are STANDBY. The fleet lease gives the $role role to a fallback seat only
   when no claude seat of any box can act (owner order: claude -> grok -> agy).
   Until then do nothing: post nothing, start nothing, answer no one, stay idle.
2. You act ONLY when the lease names you: a spool note
   "FLEET LEASE $role: you are now ACTIVE", which you check with: $show
3. When ACTIVE: your role is $ROTATE_SPEC section 1 ($role). When a note says
   STANDBY again (a claude seat took the role back), stop acting and go idle.
4. Never run /exit-clean and never close this window: the seat must stay live.
EOF
}
