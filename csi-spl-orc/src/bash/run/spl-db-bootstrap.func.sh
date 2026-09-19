#!/bin/bash
#------------------------------------------------------------------------------
# @description Bootstrap the hub's database in a cloud env (after 040, before
# @description 030): the hub's Postgres login, the DSN secret VERSION 030
# @description injects as SPOOL_HUB_DB_DSN, and the spool schema (`spool
# @description migrate` over the Cloud SQL Auth Proxy). 040 deliberately holds
# @description no user, no password and no secret version (they would sit in
# @description the state bucket in clear); this is the out-of-band half.
# @description
# @description Idempotent. When the secret already has a version, its DSN is
# @description reused and only the migrate runs (a re-run is a no-op). When it
# @description has none, a fresh password is minted and the user is created
# @description (or, if it exists, its password is reset) through the Cloud SQL
# @description Admin API with the token and the password in a header / body
# @description file, never in argv; the DSN goes to the secret on stdin.
# @description The password and the DSN are never logged.
# @description
# @description DRY_RUN=1 (default): print the IDs it would touch, call no cloud.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account) (cloudsql.admin + secretmanager.admin + cloudsql.client)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev ./run -a do_spl_db_bootstrap
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap
#------------------------------------------------------------------------------
do_spl_db_bootstrap() {
  do_require_bin yq openssl || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  if (( dry )); then
    do_log "INFO DRY_RUN would: ensure Postgres user $SPL_DB_USER on $SPL_SQL_CONN (Admin API)"
    do_log "INFO DRY_RUN would: add a version to secret $SPL_DSN_SECRET in $SPL_PROJECT when it has none"
    do_log "INFO DRY_RUN would: spool migrate $SPL_IMAGE_SQL_SRC -> $SPL_DB_NAME via the Cloud SQL proxy"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_require_bin gcloud curl || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  [[ -d "$SPL_IMAGE_SQL_SRC" ]] || { do_log "FATAL no DDL dir $SPL_IMAGE_SQL_SRC (cnf hub.image.sql_src)"; return 1; }

  local dsn
  dsn="$(spl_read_dsn)"
  if [[ -n "$dsn" ]]; then
    do_log "INFO secret $SPL_DSN_SECRET already has a version: reusing it (user not touched)"
  else
    _spl_db_ensure_user || return 1
    dsn="$(spl_read_dsn)"
    [[ -n "$dsn" ]] || { do_log "FATAL secret $SPL_DSN_SECRET still has no readable version"; return 1; }
  fi

  local pdsn rc=0
  spl_host_spool || return 1
  spl_sql_proxy_start || return 1
  pdsn="$(spl_proxy_dsn "$dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the DSN in $SPL_DSN_SECRET is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  SPOOL_HUB_DB_DSN="$pdsn" "$SPL_SPOOL" migrate --sql-dir "$SPL_IMAGE_SQL_SRC" || rc=$?
  spl_sql_proxy_stop
  (( rc == 0 )) || { do_log "FATAL spool migrate against $SPL_SQL_CONN/$SPL_DB_NAME failed (rc=$rc; proxy log $SPL_STATE_DIR/sql-proxy.log)"; return 1; }
  do_log "OK $SPL_DB_NAME on $SPL_SQL_CONN is migrated; 030 reads $SPL_DSN_SECRET. next: ENV=$ENV STEP=030-cloud-run-hub ./run -a do_tf_plan in csi-spl-iac"
}

# _spl_db_ensure_user -> mint a password, create (POST) or reset (PUT) the
# user, then add the DSN as a new secret version. Secrets travel in files
# (mode 600, removed on return) and on stdin only.
_spl_db_ensure_user() {
  local api="https://sqladmin.googleapis.com/v1/projects/$SPL_PROJECT/instances/$SPL_SQL_INSTANCE/users"
  local tmp pw method=POST url resp op
  tmp="$(umask 077 && mktemp -d)" || return 1
  pw="$(openssl rand -hex 24)" || { rm -rf "$tmp"; return 1; }
  printf 'Authorization: Bearer %s\n' "$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)" >"$tmp/h"
  printf '{"name":"%s","password":"%s"}' "$SPL_DB_USER" "$pw" >"$tmp/body"
  url="$api"
  if gcloud sql users list --instance="$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
       --format='value(name)' 2>/dev/null | grep -qx "$SPL_DB_USER"; then
    method=PUT url="$api?name=$SPL_DB_USER"
    do_log "INFO user $SPL_DB_USER exists but the secret has no version: resetting its password"
  fi
  resp="$(curl -sS -X "$method" -H @"$tmp/h" -H 'Content-Type: application/json' --data-binary @"$tmp/body" "$url")" ||
    { rm -rf "$tmp"; do_log "FATAL $method $SPL_SQL_INSTANCE/users failed"; return 1; }
  op="$(yq -r '.name // ""' <<<"$resp")"
  [[ -n "$op" && "$(yq -r '.error // ""' <<<"$resp")" == "" ]] ||
    { rm -rf "$tmp"; do_log "FATAL Cloud SQL users $method: $(yq -r '.error.message // "no operation"' <<<"$resp")"; return 1; }
  gcloud sql operations wait "$op" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --timeout=300 >/dev/null 2>&1 ||
    { rm -rf "$tmp"; do_log "FATAL operation $op did not finish"; return 1; }
  do_log "INFO Postgres user $SPL_DB_USER on $SPL_SQL_INSTANCE: $method done"
  printf 'postgres://%s:%s@/%s?host=/cloudsql/%s' "$SPL_DB_USER" "$pw" "$SPL_DB_NAME" "$SPL_SQL_CONN" |
    gcloud secrets versions add "$SPL_DSN_SECRET" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1 ||
    { rm -rf "$tmp"; do_log "FATAL could not add a version to $SPL_DSN_SECRET (the user now has a password nobody holds: re-run to reset it)"; return 1; }
  rm -rf "$tmp"
  do_log "INFO secret $SPL_DSN_SECRET: new version added (value not logged)"
}
