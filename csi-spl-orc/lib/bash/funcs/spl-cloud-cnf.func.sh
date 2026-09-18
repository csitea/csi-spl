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
  unset -f _spl_get
  SPL_SQL_CONN="$SPL_PROJECT:$SPL_REGION:$SPL_SQL_INSTANCE"
  SPL_REGISTRY_HOST="${SPL_IMAGE_REF%%/*}"

  local v
  for v in SPL_PROJECT SPL_REGION SPL_FQDN SPL_IMAGE_REF SPL_MIGRATIONS_DIR SPL_SQL_INSTANCE SPL_DB_NAME \
           SPL_DB_USER SPL_DSN_SECRET; do
    [[ -n "${!v}" && "${!v}" != null ]] || { do_log "FATAL $v is empty: check $ENV.env.yaml / all.env.yaml"; return 1; }
  done
  [[ "$SPL_PROJECT" == "$SPL_ORG_APP-$ENV" ]] || { do_log "FATAL cnf gcp_project=$SPL_PROJECT, the convention says $SPL_ORG_APP-$ENV; refusing"; return 1; }
  export SPL_ORG_APP SPL_STATE_DIR SPL_CNF SPL_PROJECT SPL_REGION SPL_FQDN SPL_IMAGE_REF SPL_IMAGE_SQL_SRC \
    SPL_MIGRATIONS_DIR SPL_SQL_INSTANCE SPL_DB_NAME SPL_DB_USER SPL_DSN_SECRET SPL_SQL_CONN SPL_REGISTRY_HOST
}

# spl_dry_run -> 0 when DRY_RUN is 1 (the default), 1 when 0; fails otherwise
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}
