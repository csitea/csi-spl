#!/bin/bash
#------------------------------------------------------------------------------
# @description Bind ONE agent (AGENT_ID on BOX_ID) as a dedicated agent of ONE
# @description scope of its workspace, a channel or a topic (rdb 0219
# @description dedicated_agents, specs/144; spec 158, SPL-4273). Until now the
# @description table had no write path: no hub route, no action (the store's
# @description SetDedicatedBinding has no caller). This is the operator path
# @description until spec 144 T005's hub endpoint lands.
# @description DEDICATED_CMD=bind (default) | unbind | list. bind is refused,
# @description in ONE statement that also writes, when: the agent is not seated
# @description in TENANT_ID on BOX_ID (agent_seats), SCOPE_ID is not a channel
# @description (channels) or a topic (a messages task_id) of TENANT_ID,
# @description BOUND_BY is missing or not an owner / admin member of TENANT_ID,
# @description or the agent is already bound to ANOTHER scope (one agent, one
# @description scope, spec 144 Q1 A: unbind first). The same binding again is
# @description a no-op. unbind deletes the agent's binding (none = a no-op).
# @description list prints the tenant's bindings (exit 2 on none).
# @description Values travel as psql variables (:'var'), never spliced; the
# @description statement sets app.tenant_id (rdb 0219 FORCE RLS); it runs as
# @description the env's project SA through the Cloud SQL proxy, never the
# @description owner account. Dry run unless DRY_RUN=0: the same checks run in
# @description a READ ONLY transaction that is rolled back, so the plan names
# @description the refusal a real run would hit.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param DEDICATED_CMD (optional) - bind (default) | unbind | list
# @param AGENT_ID - bind / unbind: the agent id, e.g. c-123
# @param BOX_ID - bind / unbind: the box the agent is seated on
# @param SCOPE_TYPE - bind: channel | topic
# @param SCOPE_ID - bind: a channel id, or a topic's task uuid (lower case)
# @param BOUND_BY - bind / unbind: the owner / admin HUM-* who decides it
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=example-ws AGENT_ID=c-123 BOX_ID=box-a SCOPE_TYPE=channel SCOPE_ID=general BOUND_BY=HUM-4 ./run -a do_spl_dedicated_bind
# @example ENV=prd TENANT_ID=example-ws AGENT_ID=c-123 BOX_ID=box-a SCOPE_TYPE=channel SCOPE_ID=general BOUND_BY=HUM-4 DRY_RUN=0 ./run -a do_spl_dedicated_bind
# @example ENV=prd TENANT_ID=example-ws AGENT_ID=c-123 BOX_ID=box-a BOUND_BY=HUM-4 DEDICATED_CMD=unbind DRY_RUN=0 ./run -a do_spl_dedicated_bind
# @example ENV=prd TENANT_ID=example-ws DEDICATED_CMD=list ./run -a do_spl_dedicated_bind
#------------------------------------------------------------------------------
do_spl_dedicated_bind() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local cmd="${DEDICATED_CMD:-bind}" dry=1
  case "$cmd" in bind | unbind | list) ;; *) do_log "FATAL DEDICATED_CMD must be bind | unbind | list, got: '$cmd'"; return 1 ;; esac
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_dedicated_args "$cmd" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_DA_DRY="$dry" spl_via_proxy "_spl_dedicated_${cmd}_run"
}

# spl_dedicated_args <cmd> -> validates the inputs into SPL_DA_{TENANT,AGENT,
# BOX,STYPE,SID,BY}, refusing before any cloud call (rdb 0219's checks).
spl_dedicated_args() {
  SPL_DA_TENANT="${TENANT_ID:-}" SPL_DA_AGENT="${AGENT_ID:-}" SPL_DA_BOX="${BOX_ID:-}"
  SPL_DA_STYPE="${SCOPE_TYPE:-}" SPL_DA_SID="${SCOPE_ID:-}" SPL_DA_BY="${BOUND_BY:-}"
  spl_require_tenant_slug "$SPL_DA_TENANT" || return 1
  [[ "$1" == list ]] && return 0
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_agent_id "$SPL_DA_AGENT" || { do_log "FATAL AGENT_ID must be an agent id (e.g. c-123), got: '$SPL_DA_AGENT'"; return 1; }
  [[ "$SPL_DA_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX_ID must be a box id, got: '$SPL_DA_BOX'"; return 1; }
  [[ -n "$SPL_DA_BY" ]] || { do_log "FATAL BOUND_BY is required: the owner / admin HUM-* who decides the binding"; return 1; }
  [[ "$SPL_DA_BY" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL BOUND_BY must be a HUM-* id, got: '$SPL_DA_BY'"; return 1; }
  [[ "$1" == unbind ]] && return 0
  case "$SPL_DA_STYPE" in
    channel) [[ "$SPL_DA_SID" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] ||
               { do_log "FATAL SCOPE_ID must be a channel id for SCOPE_TYPE=channel, got: '$SPL_DA_SID'"; return 1; } ;;
    topic) [[ "$SPL_DA_SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
             { do_log "FATAL SCOPE_ID must be a lower-case topic uuid for SCOPE_TYPE=topic, got: '$SPL_DA_SID'"; return 1; } ;;
    *) do_log "FATAL SCOPE_TYPE must be channel | topic, got: '$SPL_DA_STYPE'"; return 1 ;;
  esac
}

# _spl_dedicated_psql [psql args] -> psql as the proxy login, the tenant and
# the dry flag as variables; a dry run is READ ONLY in Postgres itself.
_spl_dedicated_psql() {
  local opts=""
  [[ "$SPL_DA_DRY" == 1 ]] && opts='-c default_transaction_read_only=on'
  PGOPTIONS="$opts" spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_DA_TENANT" -v dry="$SPL_DA_DRY" "$@"
}

# The checks and the write in one transaction: a VERDICT line, then a BOUND
# row only when the verdict is ok and this is no dry run.
_spl_dedicated_bind_run() {
  local out verdict who="$SPL_DA_AGENT@$SPL_DA_BOX" want="$SPL_DA_STYPE:$SPL_DA_SID"
  out="$(_spl_dedicated_psql -v agent="$SPL_DA_AGENT" -v box="$SPL_DA_BOX" -v stype="$SPL_DA_STYPE" \
    -v sid="$SPL_DA_SID" -v by="$SPL_DA_BY" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT CASE
  WHEN NOT EXISTS (SELECT 1 FROM agent_seats WHERE tenant_id = :'tenant' AND box_id = :'box' AND agent_id = :'agent')
    THEN 'not_seated'
  WHEN :'stype' = 'channel' AND NOT EXISTS (SELECT 1 FROM channels WHERE tenant_id = :'tenant' AND channel_id = :'sid')
    THEN 'no_scope'
  WHEN :'stype' = 'topic' AND NOT EXISTS (SELECT 1 FROM messages WHERE tenant_id = :'tenant'
         AND task_id = (CASE WHEN :'stype' = 'topic' THEN :'sid' END)::uuid)
    THEN 'no_scope'
  WHEN NOT EXISTS (SELECT 1 FROM tenant_memberships WHERE tenant_id = :'tenant' AND human_id = :'by'
         AND role IN ('biz_owner', 'admin', 'owner'))
    THEN 'not_owner'
  WHEN EXISTS (SELECT 1 FROM dedicated_agents WHERE tenant_id = :'tenant' AND agent_id = :'agent' AND box_id = :'box'
         AND scope_type = :'stype' AND scope_id = :'sid')
    THEN 'already'
  ELSE COALESCE((SELECT 'bound_elsewhere ' || scope_type || ':' || scope_id FROM dedicated_agents
                  WHERE tenant_id = :'tenant' AND agent_id = :'agent' AND box_id = :'box'), 'ok')
END AS verdict \gset
\echo VERDICT :verdict
SELECT :'verdict' = 'ok' AND :'dry' = '0' AS write \gset
\if :write
INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by)
VALUES (:'tenant', :'agent', :'box', :'stype', :'sid', :'by')
RETURNING format('BOUND %s@%s %s:%s by %s at %s', agent_id, box_id, scope_type, scope_id, bound_by, bound_at);
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL bind of $who to $want in $SPL_DA_TENANT ($ENV) failed (rolled back): $out"; return 1; }
  verdict="$(sed -n '/^VERDICT /{s///p;q}' <<<"$out")"
  case "$verdict" in
    not_seated) do_log "FATAL $who is not seated in $SPL_DA_TENANT (agent_seats): seat it first; nothing written"; return 1 ;;
    no_scope) do_log "FATAL $want is not a $SPL_DA_STYPE of $SPL_DA_TENANT; nothing written"; return 1 ;;
    not_owner) do_log "FATAL BOUND_BY $SPL_DA_BY is not an owner / admin member of $SPL_DA_TENANT; nothing written"; return 1 ;;
    bound_elsewhere*) do_log "FATAL $who is already dedicated to ${verdict#bound_elsewhere } in $SPL_DA_TENANT: one agent, one scope; unbind it first (DEDICATED_CMD=unbind); nothing written"; return 1 ;;
    already) do_log "OK $who is already dedicated to $want in $SPL_DA_TENANT ($ENV): nothing to do"; return 0 ;;
    ok) ;;
    *) do_log "FATAL no VERDICT from psql on $ENV; nothing written: $(head -c 300 <<<"$out")"; return 1 ;;
  esac
  if [[ "$SPL_DA_DRY" == 1 ]]; then
    do_log "OK DRY_RUN would bind $who to $want in $SPL_DA_TENANT ($ENV, bound by $SPL_DA_BY); every check passed, nothing written. Re-run with DRY_RUN=0."
    return 0
  fi
  grep -q '^BOUND ' <<<"$out" || { do_log "FATAL no BOUND row on $ENV for $who: $(head -c 300 <<<"$out")"; return 1; }
  do_log "OK $SPL_DA_TENANT ($ENV, $GCP_ACCOUNT): $(grep -m1 '^BOUND ' <<<"$out")"
}

_spl_dedicated_unbind_run() {
  local out who="$SPL_DA_AGENT@$SPL_DA_BOX"
  out="$(_spl_dedicated_psql -v agent="$SPL_DA_AGENT" -v box="$SPL_DA_BOX" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT :'dry' = '0' AS del \gset
\if :del
DELETE FROM dedicated_agents WHERE tenant_id = :'tenant' AND agent_id = :'agent' AND box_id = :'box'
RETURNING format('UNBOUND %s@%s %s:%s', agent_id, box_id, scope_type, scope_id);
COMMIT;
\else
SELECT format('UNBOUND %s@%s %s:%s', agent_id, box_id, scope_type, scope_id) FROM dedicated_agents
 WHERE tenant_id = :'tenant' AND agent_id = :'agent' AND box_id = :'box';
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL unbind of $who in $SPL_DA_TENANT ($ENV) failed (rolled back): $out"; return 1; }
  if ! grep -q '^UNBOUND ' <<<"$out"; then
    do_log "OK $who has no binding in $SPL_DA_TENANT ($ENV): nothing to unbind"; return 0
  fi
  if [[ "$SPL_DA_DRY" == 1 ]]; then
    do_log "OK DRY_RUN would unbind (by $SPL_DA_BY): $(grep -m1 '^UNBOUND ' <<<"$out"). Re-run with DRY_RUN=0."
    return 0
  fi
  do_log "OK $SPL_DA_TENANT ($ENV, $GCP_ACCOUNT, by $SPL_DA_BY): $(grep -m1 '^UNBOUND ' <<<"$out")"
}

_spl_dedicated_list_run() {
  local out
  out="$(SPL_DA_DRY=1 _spl_dedicated_psql -F ' | ' <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT agent_id, box_id, scope_type, scope_id, bound_by, bound_at FROM dedicated_agents
 WHERE tenant_id = :'tenant' ORDER BY scope_type, scope_id, agent_id, box_id;
ROLLBACK;
SQL
)" || { do_log "FATAL list of $SPL_DA_TENANT ($ENV) failed: $out"; return 1; }
  [[ -n "$out" ]] || { do_log "INFO $SPL_DA_TENANT ($ENV) has no dedicated agent"; return 2; }
  do_log "INFO $SPL_DA_TENANT ($ENV): agent | box | scope_type | scope_id | bound_by | bound_at"
  printf '%s\n' "$out"
}
