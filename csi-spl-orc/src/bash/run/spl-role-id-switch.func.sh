#!/bin/bash
#------------------------------------------------------------------------------
# @description Move ONE role of THIS machine from its legacy id to its spec 061
# @description id (L6: CLE-001/002/003 -> c-001/002/003), in one go, so the
# @description lease never names an id no process carries:
# @description   1. do_spl_agent_id_rename RENAME_ROLES=1 (spool dir, registry,
# @description      identity record, window, the desks in SWITCH_DESK_ENVS)
# @description   2. lease.conf: the LEASE_ORCH / LEASE_MASTER / LEASE_FAILOVER
# @description      line naming the old id names the new one (backup kept as
# @description      lease.conf.bak-<UTC>)
# @description   3. agent-name-resume.sh --only <new>, as the agent user: the
# @description      role's claude is resumed in its pane, same session, as
# @description      --name <new>@<tag> with SPOOL_AGENT_ID=<new>
# @description   4. the check: the --name, the window's first token, lease.conf
# @description Go one role at a time, dispatchers first (the failover, then the
# @description master), the orchestrator last. Dry run unless DRY_RUN=0.
# @param ROLE_ID - required: the legacy role id (CLE-003) or its new id (c-003)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SWITCH_DESK_ENVS (optional) - default "dev prd"
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ROLE_ID=CLE-003 ./run -a do_spl_role_id_switch
# @example DRY_RUN=0 ROLE_ID=CLE-003 ./run -a do_spl_role_id_switch
#------------------------------------------------------------------------------
do_spl_role_id_switch() {
  local dry=1 root="${SPOOL_ROOT:-/var/spool-hub}" id="${ROLE_ID:-}" old new key conf feat agent_user
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  feat="$PROJ_PATH/src/bash/features/spawn-agents"
  conf="${LEASE_CONF:-$root/dispatch/lease.conf}"
  read -r old new < <(awk -F'\t' -v id="$id" '($1 == id || $2 == id) && $2 ~ /^[acgq]-00[123]$/ {print $1, $2; exit}' "$root/agent-id-aliases.tsv" 2>/dev/null)
  [[ -n "$old" && -n "$new" ]] || { do_log "FATAL ROLE_ID '$id' is no role row (new id 001-003) of $root/agent-id-aliases.tsv"; return 1; }
  key="$(grep -E "^LEASE_(ORCH|MASTER|FAILOVER)=($old|$new)$" "$conf" 2>/dev/null | cut -d= -f1 | head -1)"
  [[ -n "$key" ]] || { do_log "FATAL no LEASE_ORCH / LEASE_MASTER / LEASE_FAILOVER line names $old or $new in $conf"; return 1; }
  agent_user="${SPOOL_AGENT_USER:-$(sed -n 's/^SPOOL_AGENT_USER=//p' "$root/box.env" 2>/dev/null | head -1)}"
  agent_user="${agent_user:-$USER}"
  echo "== role $key: $old -> $new (DRY_RUN=$dry)"
  echo "== 1. rename"
  SPOOL_ROOT="$root" DRY_RUN="$dry" RENAME_ROLES=1 RENAME_IDS="$old" RENAME_DESK_ENVS="${SWITCH_DESK_ENVS-dev prd}" RENAME_NOTE=0 \
    do_spl_agent_id_rename || { do_log "FATAL the rename of $old failed; lease.conf left as it was"; return 1; }
  echo "== 2. lease.conf $key=$new"
  if (( ! dry )) && ! grep -qx "$key=$new" "$conf"; then
    cp -p "$conf" "$conf.bak-$(date -u +%Y%m%dT%H%M%SZ)" && sed -i "s/^$key=$old\$/$key=$new/" "$conf" ||
      { do_log "FATAL could not write $conf"; return 1; }
  fi
  echo "== 3. resume as $agent_user"
  local -a resume=(env SPOOL_ROOT="$root" bash "$feat/scripts/agent-name-resume.sh" --only "$new,$old")
  (( dry )) || resume+=(--apply)
  if [[ "$(id -un)" == "$agent_user" ]]; then "${resume[@]}"; else sudo -u "$agent_user" "${resume[@]}"; fi ||
    { do_log "FATAL the resume of $new failed; see above"; return 1; }
  echo "== 4. check"
  grep -E "^$key=" "$conf"
  (( dry )) && { echo "DRY_RUN: nothing touched. Re-run with DRY_RUN=0."; return 0; }
  sleep "${SWITCH_SETTLE:-15}"
  ps -eo user=,pid=,args= | awk -v n="$new" '$3 ~ /(^|\/)claude$/ && index($0, "--name " n "@") {print "process", $1, $2, "--name", n "@..."}'
  return 0
}
