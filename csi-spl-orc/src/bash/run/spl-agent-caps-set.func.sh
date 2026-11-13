#!/bin/bash
#------------------------------------------------------------------------------
# @description Set ONE vendor's agent cap (spec 147, rdb 0212) in one workspace
# @description or in every workspace of a cloud env's hub DB: the named form of
# @description PUT /v1/operator/workspaces/{id}/agent-caps, whose door takes
# @description only the operator workspace admin's member session. Through the
# @description Cloud SQL proxy as the env's project service account, under the
# @description operator RLS scope (the one scope rdb 0212 lets write), the same
# @description rows the hub's store.SetAgentCaps writes: the cap and one
# @description operator_audit row (set_agent_caps / delete_agent_cap) per
# @description workspace whose cap changes; an unchanged cap writes nothing.
# @description Each use is recorded with the acting agent (actor_hum and the
# @description cap's updated_by) and the owner's message (detail.owner_msg,
# @description detail.ordered_by): owner HUM-10 t1 476aff8f msg d131a690,
# @description "each use is recorded with the agent and your message".
# @description One transaction; it prints "<ws> | <before> -> <after>" per
# @description workspace, then reads every one back. DRY_RUN=1 (default) runs
# @description the same writes and rolls them back.
# @param ENV - required: dev or prd
# @param TENANT_ID - the workspace slug; or ALL=1 for every workspace (one of the two)
# @param ALL (optional) - 1: every workspace of the env
# @param CAPS_VENDOR - required: claude, grok, mistral, agy, qwen or codex
# @param CAPS_MAX_LIVE - required: a whole number >= 0 (0 forbids the vendor), or none (uncapped)
# @param AGENT_ID (DRY_RUN=0 only) - the acting agent (c-080, c-080@sat): the audit row's actor_hum
# @param ORDERED_BY (DRY_RUN=0 only) - the HUM-n who ordered it
# @param OWNER_MSG_ID (DRY_RUN=0 only) - the uuid of the owner's message that ordered it
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ALL=1 CAPS_VENDOR=grok CAPS_MAX_LIVE=0 DRY_RUN=0 AGENT_ID=c-080 ORDERED_BY=HUM-10 OWNER_MSG_ID=<uuid> ./run -a do_spl_agent_caps_set
#------------------------------------------------------------------------------
do_spl_agent_caps_set() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" all="${ALL:-0}" vendor="${CAPS_VENDOR:-}" n="${CAPS_MAX_LIVE:-}" dry=1
  local agent="${AGENT_ID:-}" by="${ORDERED_BY:-}" omsg="${OWNER_MSG_ID:-}"
  case "$all" in
    1) [[ -z "$tenant" ]] || { do_log "FATAL set TENANT_ID or ALL=1, not both"; return 1; } ;;
    0) spl_require_tenant_slug "$tenant" || return 1 ;;
    *) do_log "FATAL ALL must be 0 or 1, got: '$all'"; return 1 ;;
  esac
  [[ "$vendor" =~ ^(claude|grok|mistral|agy|qwen|codex)$ ]] ||
    { do_log "FATAL CAPS_VENDOR must be claude, grok, mistral, agy, qwen or codex, got: '$vendor'"; return 1; }
  [[ "$n" =~ ^(0|[1-9][0-9]{0,3}|none)$ ]] ||
    { do_log "FATAL CAPS_MAX_LIVE must be a whole number 0..9999 or none, got: '$n'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  (( dry )) || _spl_agent_caps_set_who "$agent" "$by" "$omsg" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_AC_TENANT="$tenant" SPL_AC_VENDOR="$vendor" SPL_AC_N="$n" SPL_AC_DRY="$dry" \
    SPL_AC_AGENT="${agent:-dry-run}" SPL_AC_BY="${by:-HUM-0}" SPL_AC_MSG="$omsg" \
    spl_via_proxy _spl_agent_caps_set_run
}

# _spl_agent_caps_set_who <agent> <ordered_by> <owner msg id>: a write names
# who carried it (an agent id, never a HUM-, never -000) and the owner's order.
_spl_agent_caps_set_who() {
  [[ "$1" =~ ^[acgmoqu]-[0-9]{3}(@[a-z0-9-]{1,32})?$ && "$1" != ?-000* ]] ||
    { do_log "FATAL DRY_RUN=0 needs AGENT_ID=<the acting agent, e.g. c-080>, got: '$1'"; return 1; }
  [[ "$2" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL DRY_RUN=0 needs ORDERED_BY=<HUM-n>, got: '$2'"; return 1; }
  [[ "$3" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL DRY_RUN=0 needs OWNER_MSG_ID=<the owner message uuid>, got: '$3'"; return 1; }
}

# The caps write, its audit rows and the read back: ONE transaction under the
# operator RLS scope, committed only when SPL_AC_DRY=0. SPL_AC_TENANT empty =
# every workspace. Lines "<ws> | <before> -> <after>", then "<ws> = <read back>",
# then "workspaces=<n> written=<n> readback_match=<n> committed=<t|f>".
_spl_agent_caps_set_run() {
  local out want="$SPL_AC_N"
  [[ "$want" == none ]] && want=""
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_AC_TENANT" -v vendor="$SPL_AC_VENDOR" -v want="$want" -v dry="$SPL_AC_DRY" \
    -v agent="$SPL_AC_AGENT" -v by="$SPL_AC_BY" -v omsg="$SPL_AC_MSG" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
CREATE TEMP TABLE ac_plan ON COMMIT DROP AS
SELECT t.tenant_id, c.max_live AS before, NULLIF(:'want', '')::int AS after
  FROM tenants t
  LEFT JOIN tenant_agent_caps c ON c.tenant_id = t.tenant_id AND c.vendor = :'vendor'
 WHERE :'tenant' = '' OR t.tenant_id = :'tenant';
SELECT count(*) > 0 AS any FROM ac_plan \gset
\if :any
\else
\echo FATAL-NO-WORKSPACE
ROLLBACK;
\quit
\endif
SELECT count(*) AS ws FROM ac_plan \gset
SELECT format('%s | %s -> %s', tenant_id, coalesce(before::text, 'uncapped'), coalesce(after::text, 'uncapped'))
  FROM ac_plan ORDER BY tenant_id;
CREATE TEMP TABLE ac_change ON COMMIT DROP AS
SELECT * FROM ac_plan WHERE before IS DISTINCT FROM after;
DELETE FROM tenant_agent_caps c USING ac_change a
 WHERE a.after IS NULL AND c.tenant_id = a.tenant_id AND c.vendor = :'vendor';
INSERT INTO tenant_agent_caps (tenant_id, vendor, max_live, created_at, updated_at, updated_by)
SELECT tenant_id, :'vendor', after, now(), now(), :'agent' FROM ac_change WHERE after IS NOT NULL
ON CONFLICT (tenant_id, vendor) DO UPDATE SET max_live = EXCLUDED.max_live,
  updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
SELECT now(), a.tenant_id, coalesce((SELECT tenant_id FROM tenants WHERE is_operator), ''), :'agent',
       CASE WHEN a.after IS NULL THEN 'delete_agent_cap' ELSE 'set_agent_caps' END,
       jsonb_build_object('vendor', :'vendor', 'max_live', a.after, 'previous', a.before, 'via', 'do_spl_agent_caps_set',
                          'agent', :'agent', 'ordered_by', :'by', 'owner_msg', :'omsg')
  FROM ac_change a;
SELECT count(*) AS written FROM ac_change \gset
SELECT format('%s = %s', p.tenant_id, coalesce(c.max_live::text, 'uncapped'))
  FROM ac_plan p LEFT JOIN tenant_agent_caps c ON c.tenant_id = p.tenant_id AND c.vendor = :'vendor'
 ORDER BY p.tenant_id;
SELECT count(*) AS matched FROM ac_plan p LEFT JOIN tenant_agent_caps c ON c.tenant_id = p.tenant_id AND c.vendor = :'vendor'
 WHERE c.max_live IS NOT DISTINCT FROM p.after \gset
\if :dry
ROLLBACK;
\echo workspaces=:ws written=:written readback_match=:matched committed=f
\else
COMMIT;
\echo workspaces=:ws written=:written readback_match=:matched committed=t
\endif
SQL
  )" || { do_log "FATAL the caps write failed on $ENV (nothing was committed): $out"; return 1; }
  if grep -qx FATAL-NO-WORKSPACE <<<"$out"; then
    do_log "FATAL no workspace '${SPL_AC_TENANT:-<all>}' in $ENV: nothing written"; return 1
  fi
  local line ws m
  line="$(tail -n1 <<<"$out")"
  sed '$d' <<<"$out"
  ws="$(sed -n 's/^workspaces=\([0-9]*\) .*/\1/p' <<<"$line")"
  m="$(sed -n 's/.* readback_match=\([0-9]*\) .*/\1/p' <<<"$line")"
  [[ -n "$ws" && "$ws" == "$m" ]] ||
    { do_log "FATAL read back of $SPL_AC_VENDOR=$SPL_AC_N in $ENV does not match: $line"; return 1; }
  if (( SPL_AC_DRY )); then
    do_log "OK DRY_RUN rolled back: $SPL_AC_VENDOR cap $SPL_AC_N in $ENV, $line. Re-run with DRY_RUN=0 AGENT_ID=<you> ORDERED_BY=<HUM-n> OWNER_MSG_ID=<uuid>."
  else
    do_log "OK $SPL_AC_VENDOR cap $SPL_AC_N in $ENV ($GCP_ACCOUNT, agent=$SPL_AC_AGENT, ordered_by=$SPL_AC_BY, owner_msg=$SPL_AC_MSG): $line"
  fi
}
