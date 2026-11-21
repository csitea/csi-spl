#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: print one workspace's model per agent kind (spec 184
# @description row H1, contract 7.1.5, rdb 0309) as the one line the resolver
# @description spool_agent_model reads (contract 7.1.2 step 2):
# @description   SPAWN_MODEL_MAP=claude:*=sonnet,claude:complex_coding=opus,grok:tests=grok-4.6
# @description kind * is the vendor's default. A workspace with no row prints
# @description SPAWN_MODEL_MAP= (nothing set: the cnf env.box.agent_model
# @description applies). Through the Cloud SQL proxy as the env's project
# @description service account, one SELECT under the tenant's RLS scope, the
# @description tenant id as a psql variable. A row outside rdb 0309's rules
# @description (vendor, kind, the 7.1.2 model syntax) is a FATAL, never a line
# @description a launcher should trust. Prints no secret.
# @param ENV (required) - dev or prd
# @param TENANT_ID (required) - the tenant slug
# @param SPL_SA_KEY (optional) - default the env project SA key; or set
# @param   GCP_SA_KEY_FILE, which do_gcp_pin_account reads
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_agent_model_show
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_agent_model_show
#------------------------------------------------------------------------------
do_spl_agent_model_show() {
  do_require_bin psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}"
  spl_require_tenant_slug "$tenant" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_agent_model_show_run "$tenant"
}

# _spl_agent_model_line <rows> -> the SPAWN_MODEL_MAP line from
# "vendor|kind|model" rows (one per line), each checked against rdb 0309:
# the six vendors, * or the seven split kinds, the 7.1.2 model syntax.
_spl_agent_model_line() {
  local rows="$1" v k m extra map=""
  local rx='^[A-Za-z0-9._:/-]{1,80}$'
  while IFS='|' read -r v k m extra; do
    [[ -z "$v$k$m" ]] && continue
    case "$v" in claude | grok | agy | qwen | mistral | codex) ;; *) v="" ;; esac
    case "$k" in '*' | specs_and_docs | tests | simple_coding | complex_coding | i18n | secret | orchestration) ;; *) k="" ;; esac
    if [[ -z "$v" || -z "$k" || -n "$extra" ]] || ! [[ "$m" =~ $rx ]]; then
      do_log "FATAL agent model row is outside rdb 0309: '${v:-?}|${k:-?}|$m${extra:+|$extra}'"
      return 1
    fi
    map="${map:+$map,}$v:$k=$m"
  done <<<"$rows"
  printf 'SPAWN_MODEL_MAP=%s\n' "$map"
}

# _spl_agent_model_show_run <tenant> -> the SPAWN_MODEL_MAP line. Rows come
# sorted by vendor (the split order), then kind (* first).
_spl_agent_model_show_run() {
  local tenant="$1" out line n
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT vendor || '|' || kind || '|' || model
  FROM tenant_agent_model WHERE tenant_id = :'tenant'
 ORDER BY array_position(ARRAY['claude', 'grok', 'agy', 'qwen', 'mistral', 'codex'], vendor),
          array_position(ARRAY['*', 'specs_and_docs', 'tests', 'simple_coding', 'complex_coding',
                               'i18n', 'secret', 'orchestration'], kind);
ROLLBACK;
SQL
)" || { do_log "FATAL agent model read of $tenant failed: ${out:-}"; return 1; }
  line="$(_spl_agent_model_line "$out")" || { echo "$line"; return 1; }
  echo "$line"
  n=$(grep -c . <<<"$out")
  do_log "OK agent model of $tenant on $SPL_SQL_CONN: $n cell(s) (read-only, as $GCP_ACCOUNT)"
}
