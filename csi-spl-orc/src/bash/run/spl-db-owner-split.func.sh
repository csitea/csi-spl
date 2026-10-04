#!/bin/bash
#------------------------------------------------------------------------------
# @description 017 T029 / FR-SEC-014: split the hub DB's schema OWNER from the
# @description login the hub RUNS as, so the hub cannot ALTER TABLE .. NO
# @description FORCE ROW LEVEL SECURITY on its own tables.
# @description
# @description The existing Cloud SQL login (cnf hub.db_owner_user) owned every
# @description table because `spool migrate` ran with the hub's DSN. It KEEPS
# @description ownership and becomes the migration owner: its DSN is copied to
# @description the owner slot (hub.db_owner_dsn_secret, 040), which 030 never
# @description injects or grants. As that owner the action creates the runtime
# @description login (hub.db_user) with DML-only grants + default privileges
# @description (csi-spl-rdb spool-hub-roles/*.sql, the SQL hub-pg.tst.sh runs),
# @description then adds the runtime DSN as the newest version of the slot the
# @description hub reads (hub.secret_env.SPOOL_HUB_DB_DSN), then verifies AS
# @description the runtime login (flags, owns 0, and ALTER .. NO FORCE / GRANT
# @description <owner> refused), then disables the older versions of the
# @description runtime slot so the hub's SA cannot read the owner's DSN from
# @description one of them. No ALTER OWNER, so no table lock and no write pause.
# @description The running hub keeps its owner connection until the deploy lane
# @description rolls a new revision (030 injects the slot at `latest`).
# @description Why the owner keeps ownership instead of moving it to a new
# @description role: on Postgres 16 the creator of a role holds an ADMIN grant
# @description on it that it can never revoke, and a Cloud SQL API user cannot
# @description grant another; a runtime that created the new owner could grant
# @description itself that owner (spool-hub-roles/runtime-role.sql).
# @description
# @description Idempotent: once split, a re-run only re-applies the grants and
# @description re-verifies. DRY_RUN=1 (default) prints the IDs and calls no cloud.
# @description ROLLBACK=1: the owner DSN becomes the newest runtime version
# @description again (then a hub roll); the runtime role is left in place.
# @description ROTATE_OWNER=1 (after the roll): new owner password through the
# @description Cloud SQL Admin API + a new owner-slot version, older owner
# @description versions disabled. Refused while another session is logged in
# @description as the owner (a hub not yet rolled would lose new connections).
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ROLLBACK (optional) - 1: undo the split (see above)
# @param ROTATE_OWNER (optional) - 1: rotate the owner password (see above)
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_pin_account; never the owner account)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_db_owner_split
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_db_owner_split
# @example ENV=dev DRY_RUN=0 ROLLBACK=1 ./run -a do_spl_db_owner_split
# @example ENV=dev DRY_RUN=0 ROTATE_OWNER=1 ./run -a do_spl_db_owner_split
#------------------------------------------------------------------------------
do_spl_db_owner_split() {
  do_require_bin yq psql python3 openssl || return 1
  do_spl_cloud_cnf || return 1
  local dry=1 mode=split
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "${ROLLBACK:-0}" =~ ^[01]$ && "${ROTATE_OWNER:-0}" =~ ^[01]$ ]] || { do_log "FATAL ROLLBACK / ROTATE_OWNER must be 0 or 1"; return 1; }
  [[ "${ROLLBACK:-0}" == 1 && "${ROTATE_OWNER:-0}" == 1 ]] && { do_log "FATAL ROLLBACK=1 and ROTATE_OWNER=1 are separate runs"; return 1; }
  [[ "${ROLLBACK:-0}" == 1 ]] && mode=rollback
  [[ "${ROTATE_OWNER:-0}" == 1 ]] && mode=rotate_owner

  if (( dry )); then
    case "$mode" in
      split)
        do_log "INFO DRY_RUN would: copy the $SPL_DB_OWNER_USER DSN from $SPL_DSN_SECRET to $SPL_OWNER_DSN_SECRET in $SPL_PROJECT when that slot is empty"
        do_log "INFO DRY_RUN would: as $SPL_DB_OWNER_USER on $SPL_SQL_CONN/$SPL_DB_NAME create runtime role $SPL_DB_USER + DML-only grants ($SPL_DB_ROLES_SQL)"
        do_log "INFO DRY_RUN would: add the $SPL_DB_USER DSN to $SPL_DSN_SECRET, verify as $SPL_DB_USER, disable the older $SPL_DSN_SECRET versions" ;;
      rollback)
        do_log "INFO DRY_RUN would: add the $SPL_DB_OWNER_USER DSN from $SPL_OWNER_DSN_SECRET as the newest $SPL_DSN_SECRET version" ;;
      rotate_owner)
        do_log "INFO DRY_RUN would: reset the $SPL_DB_OWNER_USER password on $SPL_SQL_INSTANCE (Admin API), add it to $SPL_OWNER_DSN_SECRET, disable the older versions" ;;
    esac
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  if [[ "$(do_spl_cloud_provider)" != none ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_require_bin gcloud curl || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  "_spl_db_owner_split_$mode"
}

# _spl_db_owner_split_split -> adopt the owner slot, ensure the runtime role,
# switch the runtime slot, verify, disable the older runtime versions.
_spl_db_owner_split_split() {
  local rt_dsn owner_dsn rt_user owner_user mint=0
  rt_dsn="$(spl_read_dsn)"
  [[ -n "$rt_dsn" ]] || { do_log "FATAL $SPL_DSN_SECRET has no readable version: run do_spl_db_bootstrap first"; return 1; }
  rt_user="$(spl_dsn_user "$rt_dsn")"
  owner_dsn="$(spl_read_owner_dsn)"
  if [[ -z "$owner_dsn" ]]; then
    [[ "$rt_user" == "$SPL_DB_OWNER_USER" ]] || {
      do_log "FATAL $SPL_OWNER_DSN_SECRET is empty and $SPL_DSN_SECRET holds '$rt_user', not the owner $SPL_DB_OWNER_USER: refusing to guess the owner's DSN"; return 1; }
    printf '%s' "$rt_dsn" | spl_secret_add "$SPL_OWNER_DSN_SECRET" ||
      { do_log "FATAL could not add a version to $SPL_OWNER_DSN_SECRET"; return 1; }
    owner_dsn="$(spl_read_owner_dsn)"
    [[ "$owner_dsn" == "$rt_dsn" ]] || { do_log "FATAL $SPL_OWNER_DSN_SECRET does not read back what was written"; return 1; }
    do_log "INFO secret $SPL_OWNER_DSN_SECRET: the $SPL_DB_OWNER_USER DSN copied from $SPL_DSN_SECRET (value not logged)"
  fi
  owner_user="$(spl_dsn_user "$owner_dsn")"
  [[ "$owner_user" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET holds '$owner_user', cnf hub.db_owner_user says $SPL_DB_OWNER_USER"; return 1; }
  case "$rt_user" in
    "$SPL_DB_OWNER_USER") mint=1 ;;
    "$SPL_DB_USER") do_log "INFO $SPL_DSN_SECRET already holds $SPL_DB_USER: re-applying grants and verifying only" ;;
    *) do_log "FATAL $SPL_DSN_SECRET holds '$rt_user', neither $SPL_DB_OWNER_USER nor $SPL_DB_USER"; return 1 ;;
  esac

  local odsn rdsn rc=0
  spl_sql_proxy_start || return 1
  odsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the DSN in $SPL_OWNER_DSN_SECRET is not the /cloudsql socket form"; return 1; }
  spl_db_runtime_ensure "$odsn" "$mint" || rc=1
  if (( rc == 0 )); then
    rt_dsn="$(spl_read_dsn)"
    [[ "$(spl_dsn_user "$rt_dsn")" == "$SPL_DB_USER" ]] || { do_log "FATAL $SPL_DSN_SECRET does not hold $SPL_DB_USER after the switch"; rc=1; }
  fi
  if (( rc == 0 )); then
    rdsn="$(spl_local_dsn "$rt_dsn" "$SPL_PROXY_PORT")" && spl_db_runtime_verify "$rdsn" || rc=1
  fi
  spl_sql_proxy_stop
  if (( rc != 0 )); then
    do_log "FATAL split not verified. The hub still runs its current revision; nothing was disabled. Undo the slot with ROLLBACK=1 if its newest version is the runtime login."
    return 1
  fi
  local n
  n="$(spl_secret_disable_older "$SPL_DSN_SECRET")" || return 1
  do_log "INFO $SPL_DSN_SECRET: $n older version(s) disabled; only the $SPL_DB_USER DSN is readable"
  do_log "OK $SPL_DB_NAME on $SPL_SQL_CONN is split: owner $SPL_DB_OWNER_USER ($SPL_OWNER_DSN_SECRET), runtime $SPL_DB_USER ($SPL_DSN_SECRET). next: the deploy lane rolls the hub (a new revision reads the new version), then ENV=$ENV EXPECT_NOT_LIFTABLE=1 ./run -a do_spl_db_rls_check, then ROTATE_OWNER=1"
}

# _spl_db_owner_split_rollback -> the owner DSN becomes the runtime slot's
# newest version again (the pre-split state); a hub roll picks it up.
_spl_db_owner_split_rollback() {
  local owner_dsn
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" && "$(spl_dsn_user "$owner_dsn")" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET has no $SPL_DB_OWNER_USER DSN to roll back to"; return 1; }
  printf '%s' "$owner_dsn" | spl_secret_add "$SPL_DSN_SECRET" ||
    { do_log "FATAL could not add a version to $SPL_DSN_SECRET"; return 1; }
  [[ "$(spl_dsn_user "$(spl_read_dsn)")" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_DSN_SECRET does not read back the owner login"; return 1; }
  do_log "OK ROLLBACK: $SPL_DSN_SECRET newest version is the $SPL_DB_OWNER_USER DSN again (the runtime role $SPL_DB_USER is left in place). next: roll the hub"
}

# _spl_db_owner_split_rotate_owner -> new owner password, only when no other
# session is logged in as the owner.
_spl_db_owner_split_rotate_owner() {
  local owner_dsn rt_dsn odsn others rc=0
  rt_dsn="$(spl_read_dsn)"
  [[ "$(spl_dsn_user "$rt_dsn")" == "$SPL_DB_USER" ]] ||
    { do_log "FATAL $SPL_DSN_SECRET does not hold $SPL_DB_USER: split first (rotating now would cut the hub off)"; return 1; }
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" && "$(spl_dsn_user "$owner_dsn")" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET has no $SPL_DB_OWNER_USER DSN"; return 1; }
  spl_sql_proxy_start || return 1
  odsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" &&
    others="$(printf 'SELECT count(*) FROM pg_stat_activity WHERE usename = current_user AND pid <> pg_backend_pid();\n' |
      spl_pg_env "$odsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>&1)" || rc=1
  spl_sql_proxy_stop
  (( rc == 0 )) && [[ "$others" =~ ^[0-9]+$ ]] || { do_log "FATAL cannot count the $SPL_DB_OWNER_USER sessions: $others"; return 1; }
  [[ "$others" == 0 ]] || {
    do_log "FATAL $others other session(s) are logged in as $SPL_DB_OWNER_USER (a hub revision not yet rolled?): not rotating"; return 1; }
  # shellcheck source=spl-cloud-dispatch.func.sh
  declare -F do_spl_cloud_dispatch >/dev/null || source "${BASH_SOURCE[0]%/*}/../../../lib/bash/funcs/spl-cloud-dispatch.func.sh"
  do_spl_cloud_dispatch db_login rotate || return 1
  local n
  n="$(spl_secret_disable_older "$SPL_OWNER_DSN_SECRET")" || return 1
  do_log "OK $SPL_DB_OWNER_USER has a new password (in $SPL_OWNER_DSN_SECRET only); $n older owner version(s) disabled"
}
