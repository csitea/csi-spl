#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: verify the topic heads (rdb 0144, spec 099 section 8
# @description step 3, T006) of a cloud env's hub DB: topic_head_diff for every
# @description tenant, which compares each stored head and part with a rebuild
# @description from the topic's rows. Prints the topics checked (n), the
# @description tenants and their backfill marks, the mismatches, and up to
# @description TOPIC_HEAD_SHOW of them as "<tenant> <task> <what>".
# @description Exit 0 when there is none, 1 on ONE mismatch or more (or on an
# @description error). T005's head read waits for 0 mismatches on dev.
# @description Same path as do_spl_db_query: the env's project service account,
# @description the Cloud SQL proxy, BEGIN READ ONLY in the operator RLS scope.
# @param ENV - required: dev or prd
# @param TOPIC_HEAD_SHOW (optional) - mismatches listed at most, default 20
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_topic_head_verify
#------------------------------------------------------------------------------
do_spl_topic_head_verify() {
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  local show="${TOPIC_HEAD_SHOW:-20}"
  [[ "$show" =~ ^[0-9]{1,4}$ ]] || { do_log "FATAL TOPIC_HEAD_SHOW must be 0..9999, got: '$show'"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_TH_SHOW="$show" spl_via_proxy _spl_topic_head_verify_run
}

# _spl_topic_head_verify_run -> the diff over every tenant, read only. Its
# first line is "topics=<n> tenants=<t> marked=<m> mismatches=<k>", then one
# line per listed mismatch. Exit 1 when k > 0.
_spl_topic_head_verify_run() {
  local out sum k
  out="$(spl_topic_head_psql -v show="${SPL_TH_SHOW:-20}" <<'SQL' 2>&1
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
WITH d AS MATERIALIZED (
  SELECT t.tenant_id, d.task_id, d.what FROM tenants t, LATERAL topic_head_diff(t.tenant_id) d
)
SELECT z.line FROM (
  SELECT 0 AS o, '' AS tn, NULL::uuid AS tk,
         'topics=' || (SELECT count(*) FROM (SELECT tenant_id, task_id FROM messages
                                             UNION SELECT tenant_id, task_id FROM topic_heads) k)
      || ' tenants=' || (SELECT count(*) FROM tenants)
      || ' marked=' || (SELECT count(*) FROM topic_head_tenants WHERE backfilled_at IS NOT NULL)
      || ' mismatches=' || (SELECT count(*) FROM d) AS line
  UNION ALL
  SELECT 1, x.tenant_id, x.task_id, x.tenant_id || ' ' || x.task_id || ' ' || x.what
    FROM (SELECT * FROM d ORDER BY tenant_id, task_id LIMIT :show) x
) z ORDER BY z.o, z.tn, z.tk;
ROLLBACK;
SQL
  )" || { do_log "FATAL the verify read on $ENV failed: $out"; return 1; }
  sum="$(grep -m 1 '^topics=' <<<"$out")"
  [[ "$sum" =~ mismatches=([0-9]+)$ ]] || { do_log "FATAL unexpected verify output: $out"; return 1; }
  k="${BASH_REMATCH[1]}"
  printf '%s\n' "$out"
  if (( k > 0 )); then
    do_log "FAIL $ENV topic heads: $sum (${GCP_ACCOUNT:-})"
    return 1
  fi
  do_log "OK $ENV topic heads: $sum (${GCP_ACCOUNT:-})"
}
