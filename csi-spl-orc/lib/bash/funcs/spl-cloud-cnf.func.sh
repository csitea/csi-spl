#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve a CLOUD env's (dev / prd) settings for the owner-gated
# @description cloud actions and export them as SPL_* variables. The values
# @description come from the effective cnf (csi-spl-iac's do_spl_merged_cnf:
# @description all.env.yaml deep-merged under <env>.env.yaml, plus derived
# @description env.dns.fqdn and env.hub.image.ref); nothing here restates one.
# @description The ONE place the cloud actions read names from, so the IDs a
# @description dry run prints are the IDs a real run touches.
# @description No GCP call is made here.
# @param ENV - required: dev or prd
# @param PROJ_PATH / APP_PATH - set by run.sh
# @param SPL_STATE_DIR (optional) - default: $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=dev do_spl_cloud_cnf && echo "$SPL_IMAGE_REF"
#------------------------------------------------------------------------------
do_spl_cloud_cnf() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
  local proj_base
  proj_base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
  [[ "$proj_base" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH (expected <org>-<app>-orc)"; return 1; }
  SPL_ORG_APP="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  local cnf_dir="$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP"
  local iac_lib="$APP_PATH/$SPL_ORG_APP-iac/lib/bash/funcs"
  [[ -f "$iac_lib/spl-merged-cnf.func.sh" ]] || { do_log "FATAL missing $iac_lib/spl-merged-cnf.func.sh"; return 1; }
  # shellcheck disable=SC1091
  source "$iac_lib/spl-merged-cnf.func.sh"
  # shellcheck disable=SC1091
  source "$iac_lib/gcp-require-live-account.func.sh"

  SPL_STATE_DIR="${SPL_STATE_DIR:-$HOME/.local/share/$SPL_ORG_APP/cloud/$ENV}"
  mkdir -p "$SPL_STATE_DIR" && chmod 700 "$SPL_STATE_DIR" || return 1
  SPL_CNF="$SPL_STATE_DIR/$ENV.env.yaml"
  do_spl_merged_cnf "$cnf_dir" "$ENV" "$SPL_CNF" || { do_log "FATAL cannot merge the $ENV cnf"; return 1; }

  _spl_get() { yq -r "$1 // \"\"" "$SPL_CNF"; }
  SPL_PROJECT="$(_spl_get .env.gcp.gcp_project)"
  SPL_REGION="$(_spl_get .env.gcp.gcp_region)"
  SPL_FQDN="$(_spl_get .env.dns.fqdn)"
  SPL_IMAGE_REF="$(_spl_get .env.hub.image.ref)"
  SPL_IMAGE_SQL_SRC="$APP_PATH/$(_spl_get .env.hub.image.sql_src)"
  SPL_MIGRATIONS_DIR="$(_spl_get .env.hub.env.SPOOL_HUB_MIGRATIONS_DIR)"
  SPL_SQL_INSTANCE="$(_spl_get '.env.steps."040-cloud-sql-postgres".instance_name')"
  SPL_DB_NAME="$(_spl_get '.env.steps."040-cloud-sql-postgres".database_name')"
  SPL_DB_USER="$(_spl_get .env.hub.db_user)"
  SPL_DSN_SECRET="$(_spl_get .env.hub.secret_env.SPOOL_HUB_DB_DSN)"
  SPL_SQL_PROXY_IMAGE="$(_spl_get .env.hub.cloud_sql_proxy_image)"
  unset -f _spl_get
  SPL_SQL_CONN="$SPL_PROJECT:$SPL_REGION:$SPL_SQL_INSTANCE"
  SPL_REGISTRY_HOST="${SPL_IMAGE_REF%%/*}"

  local v
  for v in SPL_PROJECT SPL_REGION SPL_FQDN SPL_IMAGE_REF SPL_MIGRATIONS_DIR SPL_SQL_INSTANCE SPL_DB_NAME \
           SPL_DB_USER SPL_DSN_SECRET SPL_SQL_PROXY_IMAGE; do
    [[ -n "${!v}" && "${!v}" != null ]] || { do_log "FATAL $v is empty: check $ENV.env.yaml / all.env.yaml"; return 1; }
  done
  [[ "$SPL_PROJECT" == "$SPL_ORG_APP-$ENV" ]] || { do_log "FATAL cnf gcp_project=$SPL_PROJECT, the convention says $SPL_ORG_APP-$ENV; refusing"; return 1; }
  export SPL_ORG_APP SPL_STATE_DIR SPL_CNF SPL_PROJECT SPL_REGION SPL_FQDN SPL_IMAGE_REF SPL_IMAGE_SQL_SRC \
    SPL_MIGRATIONS_DIR SPL_SQL_INSTANCE SPL_DB_NAME SPL_DB_USER SPL_DSN_SECRET SPL_SQL_CONN SPL_REGISTRY_HOST \
    SPL_SQL_PROXY_IMAGE
}

# spl_dry_run -> 0 when DRY_RUN is 1 (the default), 1 when 0; fails otherwise
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}

# spl_host_spool -> builds the host `spool` CLI into the state dir (local only)
# and sets SPL_SPOOL to it
spl_host_spool() {
  local build="$APP_PATH/$SPL_ORG_APP-api/src/bash/build.sh"
  SPL_SPOOL="$SPL_STATE_DIR/bin/spool"
  mkdir -p "$SPL_STATE_DIR/bin" && bash "$build" "$SPL_SPOOL" >/dev/null ||
    { do_log "FATAL spool build failed ($build)"; return 1; }
}

# spl_read_dsn -> prints the latest version of the DSN secret. The value is
# never logged; the caller keeps it in a local.
spl_read_dsn() {
  gcloud secrets versions access latest --secret="$SPL_DSN_SECRET" --project="$SPL_PROJECT" \
    --account="$GCP_ACCOUNT" 2>/dev/null
}

# spl_proxy_dsn <cloud dsn> <port> -> the same login through the local proxy.
# The cloud DSN is the one 040 documents and 030 runs:
#   postgres://<user>:<pw>@/<db>?host=/cloudsql/<connection_name>
spl_proxy_dsn() {
  local re='^postgres(ql)?://([^@/]+)@/([^?]+)[?]host=/cloudsql/[^&]+$'
  [[ "$1" =~ $re ]] || return 1
  printf 'postgres://%s@127.0.0.1:%s/%s?sslmode=disable' "${BASH_REMATCH[2]}" "$2" "${BASH_REMATCH[3]}"
}

# spl_sql_proxy_start -> the Cloud SQL Auth Proxy on 127.0.0.1:$SPL_PROXY_PORT
# (default 55499) for $SPL_SQL_CONN, as $GCP_ACCOUNT. The access token goes
# through the environment (CSQL_PROXY_TOKEN), never argv. A cloud-sql-proxy
# binary on PATH wins; otherwise the cnf image runs in docker on the host net.
# Stop it with spl_sql_proxy_stop.
spl_sql_proxy_start() {
  SPL_PROXY_PORT="${SPL_PROXY_PORT:-55499}"
  _SPL_PROXY_PID="" _SPL_PROXY_CON=""
  if (exec 3<>"/dev/tcp/127.0.0.1/$SPL_PROXY_PORT") 2>/dev/null; then
    do_log "FATAL 127.0.0.1:$SPL_PROXY_PORT is already in use (set SPL_PROXY_PORT)"; return 1
  fi
  CSQL_PROXY_TOKEN="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$CSQL_PROXY_TOKEN" ]] || { do_log "FATAL no access token for $GCP_ACCOUNT"; return 1; }
  export CSQL_PROXY_TOKEN
  if command -v cloud-sql-proxy >/dev/null; then
    cloud-sql-proxy --address 127.0.0.1 --port "$SPL_PROXY_PORT" "$SPL_SQL_CONN" >"$SPL_STATE_DIR/sql-proxy.log" 2>&1 &
    _SPL_PROXY_PID=$!
  else
    _SPL_PROXY_CON="$SPL_ORG_APP-$ENV-sql-proxy-$$"
    docker run -d --rm --name "$_SPL_PROXY_CON" --network host -e CSQL_PROXY_TOKEN "$SPL_SQL_PROXY_IMAGE" \
      --address 127.0.0.1 --port "$SPL_PROXY_PORT" "$SPL_SQL_CONN" >/dev/null ||
      { unset CSQL_PROXY_TOKEN; do_log "FATAL could not start $SPL_SQL_PROXY_IMAGE"; return 1; }
  fi
  unset CSQL_PROXY_TOKEN
  local i
  for i in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$SPL_PROXY_PORT") 2>/dev/null && { do_log "INFO Cloud SQL proxy up: 127.0.0.1:$SPL_PROXY_PORT -> $SPL_SQL_CONN"; return 0; }
    sleep 0.5
  done
  do_log "FATAL the Cloud SQL proxy did not listen on 127.0.0.1:$SPL_PROXY_PORT"
  spl_sql_proxy_stop; return 1
}

spl_sql_proxy_stop() {
  [[ -n "${_SPL_PROXY_PID:-}" ]] && { kill "$_SPL_PROXY_PID" 2>/dev/null || true; }
  [[ -n "${_SPL_PROXY_CON:-}" ]] && { docker stop "$_SPL_PROXY_CON" >/dev/null 2>&1 || true; }
  _SPL_PROXY_PID="" _SPL_PROXY_CON=""
  return 0
}

# spl_pg_env <dsn> <cmd> [args] -> runs <cmd> with the DSN's login in PG* env
# vars (PGUSER, PGPASSWORD, PGHOST, PGPORT, PGDATABASE), so a password never
# sits in a psql argv that `ps` shows. For the local proxy DSN of spl_proxy_dsn.
spl_pg_env() {
  local parts
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$1")" || return 1
  shift
  local -a f
  mapfile -t f <<<"$parts"
  PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}" \
    PGSSLMODE=disable PGCONNECT_TIMEOUT=15 "$@"
}

# spl_via_proxy <cmd> [args] -> as the pinned $GCP_ACCOUNT (do_gcp_pin_account:
# the env's project SA), runs <cmd> with SPL_PROXY_DSN set to the hub DB's
# login through a local Cloud SQL proxy, then stops the proxy. The DSN lives in
# the environment of <cmd> only, never argv or a log.
spl_via_proxy() {
  local cloud_dsn dsn rc=0
  cloud_dsn="$(spl_read_dsn)"
  [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; return 1; }
  spl_sql_proxy_start || return 1
  dsn="$(spl_proxy_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the DSN in $SPL_DSN_SECRET is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  SPL_PROXY_DSN="$dsn" "$@" || rc=$?
  spl_sql_proxy_stop
  return $rc
}

# spl_role_id <role>: prints the 025 role id (legacy owner|member mapped),
# or fails on a malformed id. Existence is the hub DB's call (rbac_roles FK).
spl_role_id() {
  local r="$1"
  case "$r" in owner) r=biz_owner ;; member) r=developer ;; esac
  [[ "$r" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || return 1
  printf '%s' "$r"
}
