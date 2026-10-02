#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY backup of one env's GCP estate to a 0700 local dir,
# @description as the env's project service account in a private gcloud
# @description config (harvested from the 2026-09-19 pre-destroy backup,
# @description adhoc-harvest.md). Nothing in GCP is mutated. Takes:
# @description   state/     every object of the terraform state bucket
# @description   secrets/   the latest version of each secret, one 0600 file
# @description              each (the VALUE is never printed or logged; a
# @description              secret with no readable version is logged as a slot)
# @description   dns-*.zone every Cloud DNS zone, zone-file format, + its NS
# @description   buckets/   the relay (020) and files (050) buckets
# @description   artifact-tags.txt  the 028 registry's images and tags
# @description   sql/       pg_dump of the hub DB (040) through the Cloud SQL
# @description              proxy, with per-table row counts
# @description Every name comes from the effective cnf (all + <env> merged).
# @description RESTORE_CHECK_PG_CONTAINER restores the dump into a scratch DB
# @description of that LOCAL postgres container, compares row counts, and
# @description drops the scratch DB; the container's own data is not touched.
# @param ENV - required: dev or prd
# @param BACKUP_ROOT (optional) - default /var/<org>/<org>-<app>/backup; the run
# @param   writes <BACKUP_ROOT>/<env>/<utc-ts>/
# @param RESTORE_CHECK_PG_CONTAINER (optional) - local postgres container name
# @param RESTORE_CHECK_PG_USER (optional) - its superuser, default spool
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55497
# @example ENV=dev ./run -a do_gcp_backup_env
# @example ENV=prd RESTORE_CHECK_PG_CONTAINER=csi-spl-lde-main-pg-1 ./run -a do_gcp_backup_env
#------------------------------------------------------------------------------
do_gcp_backup_env() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml"
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  _bk() { yq -r "$1 // \"\"" "$cnf"; }
  local state_bucket relay files region repo dsn_secret proxy_image
  state_bucket="$(_bk .env.gcp.state_bucket)"
  relay="$(_bk '.env.steps."020-gcp-relay-bucket".relay_bucket_name')"
  files="$(_bk '.env.steps."050-gcs-files".files_bucket_name')"
  region="$(_bk .env.gcp.gcp_region)"
  repo="$(_bk '.env.steps."028-gcp-artifact-registry".repository_id')"
  dsn_secret="$(_bk .env.hub.secret_env.SPOOL_HUB_DB_DSN)"
  proxy_image="$(_bk .env.hub.cloud_sql_proxy_image)"
  unset -f _bk
  [[ -n "$state_bucket" && -n "$region" ]] || { do_log "FATAL cnf lacks env.gcp.state_bucket / gcp_region for $ENV"; return 1; }

  # the env's project SA from its key, in this private config (cc7f79f)
  do_gcp_pin_account || return 1
  local sa="$GCP_ACCOUNT"

  local out
  out="${BACKUP_ROOT:-/var/$ORG/$ORG-$APP/backup}/$ENV/$(date -u +%Y%m%dT%H%M%SZ)"
  (umask 077 && mkdir -p "$out"/{state,secrets,buckets,sql}) && chmod 700 "$out" || { do_log "FATAL cannot create $out"; return 1; }
  _bklog() { do_log "$*"; echo "$*" >>"$out/backup.log"; }
  _bklog "INFO backup $p as $sa -> $out"
  local errs=0

  # terraform state
  gcloud storage cp -r "gs://$state_bucket/*" "$out/state/" --account="$sa" >/dev/null 2>&1 ||
    { _bklog "ERROR state copy from gs://$state_bucket"; errs=$((errs + 1)); }
  _bklog "INFO state: $(find "$out/state" -type f | wc -l) file(s) from gs://$state_bucket"

  # secrets: 0600 files, value never on stdout
  local s n=0
  for s in $(gcloud secrets list --project="$p" --account="$sa" --format='value(name)' 2>/dev/null); do
    if (umask 077 && gcloud secrets versions access latest --secret="$s" --project="$p" --account="$sa" >"$out/secrets/$s" 2>/dev/null); then
      n=$((n + 1)); _bklog "INFO secret: $s ($(stat -c %s "$out/secrets/$s") bytes, value not shown)"
    else
      rm -f "$out/secrets/$s"; _bklog "INFO secret: $s has no readable version (slot only)"
    fi
  done
  _bklog "INFO secrets: $n value(s) saved"

  # DNS
  local z
  for z in $(gcloud dns managed-zones list --project="$p" --account="$sa" --format='value(name)' 2>/dev/null); do
    gcloud dns record-sets export "$out/dns-$z.zone" --zone="$z" --zone-file-format --project="$p" --account="$sa" >/dev/null 2>&1 ||
      { _bklog "ERROR dns export $z"; errs=$((errs + 1)); }
    gcloud dns managed-zones describe "$z" --project="$p" --account="$sa" --format='value(nameServers)' >"$out/dns-$z.ns" 2>/dev/null
    _bklog "INFO dns: zone $z exported, NS $(tr ';' ' ' <"$out/dns-$z.ns" 2>/dev/null)"
  done

  # buckets
  local b
  for b in "$relay" "$files"; do
    [[ -n "$b" ]] || continue
    mkdir -p "$out/buckets/$b"
    gcloud storage rsync -r "gs://$b" "$out/buckets/$b" --account="$sa" >/dev/null 2>&1 ||
      { _bklog "ERROR rsync gs://$b"; errs=$((errs + 1)); }
    _bklog "INFO bucket: $b -> $(find "$out/buckets/$b" -type f | wc -l) object(s)"
  done

  # registry tags (rebuilt, not restored: a record of what ran)
  if [[ -n "$repo" ]]; then
    gcloud artifacts docker images list "$region-docker.pkg.dev/$p/$repo" --include-tags --account="$sa" \
      --format='value(package,tags)' >"$out/artifact-tags.txt" 2>/dev/null
    _bklog "INFO artifact registry: $(wc -l <"$out/artifact-tags.txt") image row(s)"
  fi

  # Cloud SQL: pg_dump through the proxy, with the DSN from its secret file
  _gcp_backup_sql "$out" "$sa" "$dsn_secret" "$proxy_image" || errs=$((errs + 1))

  chmod -R go-rwx "$out"
  unset -f _bklog
  (( errs == 0 )) || { do_log "ERROR backup of $p finished with $errs error(s): $out/backup.log"; return 1; }
  do_log "OK backup of $p in $out ($(du -sb "$out" | cut -f1) bytes)"
}

# _gcp_backup_sql <out> <sa> <dsn secret> <proxy image> -> sql/<db>.sql and
# row counts; the restore check when RESTORE_CHECK_PG_CONTAINER is set.
_gcp_backup_sql() {
  local out="$1" sa="$2" dsn_secret="$3" proxy_image="$4" dsn
  [[ -n "$dsn_secret" && -s "$out/secrets/$dsn_secret" ]] ||
    { echo "INFO sql: no readable DSN secret '$dsn_secret': no SQL backup" >>"$out/backup.log"; return 0; }
  dsn="$(cat "$out/secrets/$dsn_secret")"
  local re='^postgres(ql)?://([^@/]+)@/([^?]+)[?]host=/cloudsql/(.+)$'
  [[ "$dsn" =~ $re ]] || { do_log "ERROR the DSN secret is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  local login="${BASH_REMATCH[2]}" db="${BASH_REMATCH[3]}" conn="${BASH_REMATCH[4]}"
  local port="${SPL_PROXY_PORT:-55497}" con="$ORG-$APP-$ENV-bk-proxy-$$" i
  CSQL_PROXY_TOKEN="$(gcloud auth print-access-token --account="$sa" 2>/dev/null)" \
    docker run -d --rm --name "$con" --network host -e CSQL_PROXY_TOKEN "$proxy_image" \
    --address 127.0.0.1 --port "$port" "$conn" >/dev/null || { do_log "ERROR cannot start $proxy_image"; return 1; }
  for i in $(seq 60); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.5; done
  local rc=0
  # the login travels in PG* env vars only, never in an argv that `ps` shows
  local PGHOST=127.0.0.1 PGPORT="$port" PGDATABASE="$db" PGSSLMODE=disable PGUSER PGPASSWORD
  PGUSER="$(python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))' "${login%%:*}")"
  PGPASSWORD="$(python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))' "${login#*:}")"
  # rdb 0014 FORCE RLS binds the hub login: the operator scope (session-wide,
  # this connection only) sees every tenant, and pg_dump must be told to run
  # under row security or it refuses the forced tables.
  local PGOPTIONS='-c app.rls_scope=operator'
  export PGHOST PGPORT PGDATABASE PGSSLMODE PGUSER PGPASSWORD PGOPTIONS
  _gcp_backup_counts() { psql -XAtc "SELECT format('%I.%I', table_schema, table_name) FROM information_schema.tables
      WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1" |
    while read -r t; do echo "$t $(psql -XAtc "SELECT count(*) FROM $t")"; done; }
  _gcp_backup_counts >"$out/sql/rowcounts-source.txt" 2>>"$out/backup.log"
  pg_dump --no-owner --no-privileges --enable-row-security >"$out/sql/$db.sql" 2>>"$out/backup.log" || rc=1
  docker stop "$con" >/dev/null 2>&1
  (( rc == 0 )) || { do_log "ERROR pg_dump $db"; return 1; }
  echo "INFO sql: $db dump $(stat -c %s "$out/sql/$db.sql") bytes, $(wc -l <"$out/sql/rowcounts-source.txt") table(s)" >>"$out/backup.log"

  local lde="${RESTORE_CHECK_PG_CONTAINER:-}" u="${RESTORE_CHECK_PG_USER:-spool}"
  [[ -n "$lde" ]] || return 0
  local scratch
  scratch="restorecheck_${ENV}_$(date -u +%H%M%S)"
  docker exec "$lde" createdb -U "$u" "$scratch" &&
    docker exec -i "$lde" psql -q -U "$u" -d "$scratch" -v ON_ERROR_STOP=0 <"$out/sql/$db.sql" >"$out/sql/restore.log" 2>&1
  docker exec "$lde" psql -U "$u" -d "$scratch" -XAtc "SELECT format('%I.%I', table_schema, table_name) FROM information_schema.tables
      WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1" |
    while read -r t; do echo "$t $(docker exec "$lde" psql -U "$u" -d "$scratch" -XAtc "SELECT count(*) FROM $t")"; done >"$out/sql/rowcounts-restored.txt"
  docker exec "$lde" dropdb -U "$u" "$scratch"
  if cmp -s "$out/sql/rowcounts-source.txt" "$out/sql/rowcounts-restored.txt"; then
    echo "INFO sql: restore check OK, row counts identical" >>"$out/backup.log"
  else
    do_log "ERROR sql restore check: row counts differ (sql/rowcounts-*.txt)"; return 1
  fi
}
