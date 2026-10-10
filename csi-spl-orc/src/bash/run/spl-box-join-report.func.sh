#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only report of spec 108 box joining in a cloud env's hub
# @description DB (section 3.8): per workspace, the live boxes seated by a join
# @description token (an active pin whose latest pins_history row is 'join'),
# @description and, once rdb 0170 is applied, the workspaces whose switch
# @description (tenants.box_join_enabled) is on. Prints one line per workspace
# @description that has either, then the env total:
# @description   BOXJOIN <env> <workspace> seated=<n> switch=<on|off|n/a>
# @description   BOXJOIN <env> total seated=<n> switch_on=<n>
# @description Inside BEGIN READ ONLY .. ROLLBACK with the operator RLS scope,
# @description through the Cloud SQL proxy as the env's project SA.
# @param ENV - required: dev or prd
# @example ENV=prd ./run -a do_spl_box_join_report
#------------------------------------------------------------------------------
do_spl_box_join_report() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_box_join_report_run
}

_spl_box_join_report_run() {
  local out
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_name = 'tenants' AND column_name = 'box_join_enabled') AS has_switch \gset
\if :has_switch
SELECT t.tenant_id, coalesce(s.n, 0), CASE WHEN t.box_join_enabled THEN 'on' ELSE 'off' END
  FROM tenants t LEFT JOIN (
    SELECT p.tenant_id, count(*) AS n FROM pins p
      CROSS JOIN LATERAL (SELECT h.reason FROM pins_history h
        WHERE h.tenant_id = p.tenant_id AND h.box_id = p.box_id ORDER BY h.at DESC LIMIT 1) h
     WHERE p.revoked_at IS NULL AND p.box_id <> 'box-wui' AND h.reason = 'join'
     GROUP BY p.tenant_id) s ON s.tenant_id = t.tenant_id
 WHERE coalesce(s.n, 0) > 0 OR t.box_join_enabled
 ORDER BY 1;
\else
SELECT p.tenant_id, count(*), 'n/a' FROM pins p
  CROSS JOIN LATERAL (SELECT h.reason FROM pins_history h
    WHERE h.tenant_id = p.tenant_id AND h.box_id = p.box_id ORDER BY h.at DESC LIMIT 1) h
 WHERE p.revoked_at IS NULL AND p.box_id <> 'box-wui' AND h.reason = 'join'
 GROUP BY p.tenant_id ORDER BY 1;
\endif
ROLLBACK;
SQL
)" || { do_log "FATAL the $ENV box join report failed: $out"; return 1; }
  spl_box_join_report_lines "$ENV" <<<"$out"
}

# spl_box_join_report_lines <env> - "<workspace> <seated> <switch>" rows on
# stdin -> one BOXJOIN line per workspace, then the env total.
spl_box_join_report_lines() {
  awk -v env="$1" '
    NF == 3 { printf "BOXJOIN %s %s seated=%d switch=%s\n", env, $1, $2, $3; n += $2; if ($3 == "on") on++ }
    END { printf "BOXJOIN %s total seated=%d switch_on=%d\n", env, n, on }'
}
