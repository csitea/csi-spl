#!/bin/bash
#------------------------------------------------------------------------------
# @description Create the demo workspace of one env (spec 077 T023/T024), the
# @description tenant cnf env.demo.workspace names. Idempotent: it READS
# @description first, and a workspace that exists is reported and left as it
# @description is (exit 0, "created":false); a second run changes nothing.
# @description Prints one JSON line on stdout: workspace, env, created, and
# @description where the root key was saved. The root private key itself is
# @description never printed or logged: do_spl_tenant_create's create JSON
# @description goes to DEMO_TENANT_FILE (mode 0600), outside git.
# @description PATH TODAY: a wrapper over do_spl_tenant_create (the per-env SA,
# @description the DSN secret, the Cloud SQL proxy; box-wui pinned, no tenant
# @description host). The 074 operator API (POST /v1/operator/workspaces)
# @description takes only an operator-admin browser session, which no SA holds
# @description (c-001 decision, 2026-10-05, task 4979bb24).
# @description SWITCH when 074 T007 lands (the operator API reachable as the env SA): the read
# @description becomes GET /v1/operator/workspaces/<id> and the create POST
# @description /v1/operator/workspaces; demo-workspace-create.tst.sh names it.
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default): read only, say what would be made
# @param DEMO_TENANT_FILE (optional) - where the create JSON (root key) is saved,
# @param   default $HOME/.spool-hub/tenants/<env>-<workspace>.json
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (do_gcp_account)
# @example ENV=dev ./run -a do_spl_demo_workspace_create
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_demo_workspace_create
#------------------------------------------------------------------------------
do_spl_demo_workspace_create() {
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" ws exists file
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  ws="$(yq -r '.env.demo.workspace // ""' "$SPL_CNF")"
  [[ "$ws" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL cnf env.demo.workspace is not a workspace slug: '$ws'"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  exists="$(spl_demo_workspace_exists "$ws")" || { do_log "FATAL could not read workspace $ws of $ENV"; return 1; }
  if [[ "$exists" == yes ]]; then
    do_log "OK workspace $ws exists in $ENV: nothing to do"
    printf '{"workspace":"%s","env":"%s","created":false}\n' "$ws" "$ENV"
    return 0
  fi
  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN workspace $ws is missing in $ENV: DRY_RUN=0 creates it"
    printf '{"workspace":"%s","env":"%s","created":false,"dry_run":true}\n' "$ws" "$ENV"
    return 0
  fi
  file="${DEMO_TENANT_FILE:-$HOME/.spool-hub/tenants/$ENV-$ws.json}"
  [[ -e "$file" ]] && { do_log "FATAL $file exists but workspace $ws does not: move it aside first"; return 1; }
  ( umask 077 && mkdir -p "$(dirname "$file")" ) || return 1
  local rc=0
  ( umask 077 && TENANT_ID="$ws" TENANT_HOST=0 DRY_RUN=0 do_spl_tenant_create >"$file" ) || rc=$?
  if [[ ! -s "$file" ]]; then
    rm -f "$file"
    do_log "FATAL do_spl_tenant_create made no workspace $ws in $ENV (rc=$rc)"
    return 1
  fi
  (( rc == 0 )) || do_log "WARN workspace $ws exists in $ENV but do_spl_tenant_create exited $rc (4 = box-wui not pinned)"
  do_log "OK created workspace $ws in $ENV; its create JSON (root key) is in $file, never in git"
  printf '{"workspace":"%s","env":"%s","created":true,"tenant_file":"%s"}\n' "$ws" "$ENV" "$file"
  return $rc
}

# spl_demo_workspace_exists <id> -> "yes" or "no" on stdout: one READ ONLY
# transaction in operator RLS scope as the env SA, through the proxy.
spl_demo_workspace_exists() {
  local tmp rc=0
  tmp="$(mktemp)" || return 1
  DEMO_WS="$1" spl_via_proxy _spl_demo_workspace_read "$tmp" || rc=1
  (( rc == 0 )) && { [[ "$(tr -d '[:space:]' <"$tmp")" == 1 ]] && echo yes || echo no; }
  rm -f "$tmp"
  return $rc
}

_spl_demo_workspace_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v ws="$DEMO_WS" >"$1" <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT count(*) FROM tenants WHERE tenant_id = :'ws';
COMMIT;
SQL
}
