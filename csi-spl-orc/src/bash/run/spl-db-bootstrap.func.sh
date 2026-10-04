#!/bin/bash
#------------------------------------------------------------------------------
# @description Bootstrap the hub's database in a cloud env (after 040, before
# @description 030): the two Postgres logins (017 T029), their DSN secret
# @description VERSIONS, and the spool schema (`spool migrate` over the Cloud
# @description SQL Auth Proxy). 040 deliberately holds no user, no password
# @description and no secret version (they would sit in the state bucket in
# @description clear); this is the out-of-band half.
# @description   OWNER  cnf hub.db_owner_user, a Cloud SQL API user; its DSN is
# @description          hub.db_owner_dsn_secret. `spool migrate` runs as it.
# @description   RUNTIME cnf hub.db_user, created by the owner in SQL with
# @description          DML-only grants (spl-db-roles.func.sh); its DSN is the
# @description          SPOOL_HUB_DB_DSN slot 030 injects.
# @description
# @description Idempotent. The migrate runs as the owner DSN; after it the
# @description runtime grants are re-applied, so default privileges and older
# @description tables stay covered. A fresh env (both slots empty) gets the
# @description owner through the Cloud SQL Admin API (token and password in a
# @description header / body file, never argv) and then the runtime role. An
# @description env whose runtime slot still holds the owner (not split yet)
# @description migrates with that DSN and says to run do_spl_db_owner_split.
# @description The passwords and the DSNs are never logged.
# @description Under SPOOL_CLOUD_PROVIDER=none (spec 076 T008): no GCP account
# @description is pinned, and a fresh env (no runtime DSN) is seeded through
# @description the T009 secrets seam (self-host .env, mode 600) instead of
# @description Secret Manager. Under gcp the calls are unchanged.
# @description
# @description DRY_RUN=1 (default): print the IDs it would touch, call no cloud.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account) (cloudsql.admin + secretmanager.admin + cloudsql.client)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_db_bootstrap
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap
#------------------------------------------------------------------------------
# Classify the two logins for do_spl_db_bootstrap. $1 is 1 when a fresh none
# env was just seeded. Sets the caller's owner_dsn and runtime (fresh, split
# or owner). The passwords stay out of the log.
_spl_db_bootstrap_classify() {
  local none_fresh="$1" rt_dsn rt_user
  if (( none_fresh )); then
    # shellcheck disable=SC2034 # caller's owner_dsn, via dynamic scope
    owner_dsn="$(SPOOL_HUB_DB_DSN='postgres://local@127.0.0.1:5432/local' spl_read_owner_dsn)" || return 1
    [[ -n "$owner_dsn" ]] || { do_log "FATAL no owner DSN after seeding the self-host .env"; return 1; }
    # shellcheck disable=SC2034 # caller's runtime, via dynamic scope
    runtime=fresh
    return 0
  fi
  # shellcheck disable=SC2034 # caller's owner_dsn, via dynamic scope
  owner_dsn="$(spl_read_owner_dsn)"
  rt_dsn="$(spl_read_dsn)"
  rt_user=""; [[ -n "$rt_dsn" ]] && rt_user="$(spl_dsn_user "$rt_dsn")"
  case "$rt_user" in
    "") runtime=fresh ;;
    "$SPL_DB_USER") runtime='split' ;;
    "$SPL_DB_OWNER_USER") runtime=owner ;;
    *) do_log "FATAL $SPL_DSN_SECRET holds '$rt_user', neither $SPL_DB_USER nor $SPL_DB_OWNER_USER"; return 1 ;;
  esac
  if [[ -z "$owner_dsn" ]]; then
    case "$runtime" in
      owner) owner_dsn="$rt_dsn"
             do_log "INFO $SPL_OWNER_DSN_SECRET is empty and $SPL_DSN_SECRET still holds the owner: migrating with it (not split: run do_spl_db_owner_split)" ;;
      fresh) do_spl_cloud_dispatch db_login ensure || return 1
             owner_dsn="$(spl_read_owner_dsn)"
             [[ -n "$owner_dsn" ]] || { do_log "FATAL secret $SPL_OWNER_DSN_SECRET still has no readable version"; return 1; } ;;
      split) do_log "FATAL $SPL_DSN_SECRET holds the runtime login but $SPL_OWNER_DSN_SECRET is empty: the owner's DSN is lost; resetting the $SPL_DB_OWNER_USER password is an owner decision, not done here"; return 1 ;;
    esac
  fi
}

do_spl_db_bootstrap() {
  do_require_bin yq openssl psql python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  if (( dry )); then
    do_log "INFO DRY_RUN would: ensure the owner $SPL_DB_OWNER_USER on $SPL_SQL_CONN (Admin API) when $SPL_OWNER_DSN_SECRET and $SPL_DSN_SECRET are both empty"
    do_log "INFO DRY_RUN would: spool migrate $SPL_IMAGE_SQL_SRC -> $SPL_DB_NAME as $SPL_DB_OWNER_USER via the Cloud SQL proxy"
    do_log "INFO DRY_RUN would: as $SPL_DB_OWNER_USER ensure the runtime role $SPL_DB_USER + DML-only grants; its DSN in $SPL_DSN_SECRET in $SPL_PROJECT"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  if [[ "$provider" != none ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_require_bin gcloud curl || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  [[ -d "$SPL_IMAGE_SQL_SRC" ]] || { do_log "FATAL no DDL dir $SPL_IMAGE_SQL_SRC (cnf hub.image.sql_src)"; return 1; }

  # A fresh none env has no runtime DSN. Seed the self-host .env (T009, mode
  # 600) before the reads, and do not export SPOOL_HUB_DB_DSN yet: the fresh
  # classification is "no runtime login". The owner read borrows a host only
  # for that call; the shell's SPOOL_HUB_DB_DSN stays empty.
  local none_fresh=0
  if [[ "$provider" == none && -z "${SPOOL_HUB_DB_DSN:-}" ]]; then
    do_spl_cloud_dispatch db_login ensure || return 1
    none_fresh=1
  fi

  # runtime: split = the runtime slot holds $SPL_DB_USER; owner = not split
  # yet (the old single login); fresh = the env has no login at all
  local owner_dsn runtime
  _spl_db_bootstrap_classify "$none_fresh" || return 1
  [[ "$(spl_dsn_user "$owner_dsn")" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL the owner DSN is not the login $SPL_DB_OWNER_USER (cnf hub.db_owner_user)"; return 1; }

  local pdsn rc=0
  spl_host_spool || return 1
  spl_sql_proxy_start || return 1
  pdsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the owner DSN is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  SPOOL_HUB_DB_DSN="$pdsn" "$SPL_SPOOL" migrate --sql-dir "$SPL_IMAGE_SQL_SRC" || rc=$?
  if (( rc != 0 )); then
    spl_sql_proxy_stop
    do_log "FATAL spool migrate against $SPL_SQL_CONN/$SPL_DB_NAME failed (rc=$rc; proxy log $SPL_STATE_DIR/sql-proxy.log)"; return 1
  fi
  case "$runtime" in
    fresh) spl_db_runtime_ensure "$pdsn" 1 || rc=1 ;;
    split) spl_db_runtime_ensure "$pdsn" 0 || rc=1 ;;
    owner) : ;;
  esac
  spl_sql_proxy_stop
  (( rc == 0 )) || { do_log "FATAL the runtime role $SPL_DB_USER on $SPL_SQL_CONN/$SPL_DB_NAME was not ensured"; return 1; }
  do_log "OK $SPL_DB_NAME on $SPL_SQL_CONN is migrated as $SPL_DB_OWNER_USER; runtime login: $([[ $runtime == owner ]] && echo "still the owner (run do_spl_db_owner_split)" || echo "$SPL_DB_USER, grants re-applied"); 030 reads $SPL_DSN_SECRET"
}
