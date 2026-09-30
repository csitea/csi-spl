#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY monitor for SPL-1225: count and list the human posts a
# @description cloud env dropped - a signed browser post by a person, into a
# @description channel or an agent DM, that NO agent replied to in its topic
# @description within GRACE and that the fallback never took. It shares its
# @description definition of "unanswered" with the hub's escalation sweep
# @description (store.UnansweredPosts): "an agent box was sent the frame" and
# @description "an agent is online" both read true for a channel post the
# @description instant it reaches the shared box-desk, whose roster names every
# @description agent that ever had a dir there, so the only signal a stale
# @description roster cannot fake is a REPLY in the topic.
# @description
# @description After the SPL-1225 hub fix deploys, a recent post that goes
# @description unanswered is escalated to the tenant's responder (and so gains a
# @description fallback_deliveries row), so this report trends to zero for the
# @description recent window; a non-zero count is either the pre-fix backlog or
# @description a regression. Run it read-only through the Cloud SQL proxy, as
# @description the env's project service account, in a rolled-back READ ONLY
# @description transaction (like do_spl_db_query). It never writes and never
# @description prints the DSN.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - one tenant slug; default every tenant
# @param UNHEARD_WINDOW (optional) - lookback interval, default '7 days'
# @param UNHEARD_GRACE (optional) - reply grace, default '2 minutes'
# @example ENV=prd ./run -a do_spl_report_unheard
# @example ENV=prd TENANT_ID=t1 UNHEARD_WINDOW='24 hours' ./run -a do_spl_report_unheard
#------------------------------------------------------------------------------
do_spl_report_unheard() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" window="${UNHEARD_WINDOW:-7 days}" grace="${UNHEARD_GRACE:-2 minutes}"
  # interval literals are operator-supplied; keep them to a plain "N unit" so
  # they cannot smuggle a second statement or a quote into the query.
  local re='^[0-9]+[[:space:]]+(second|seconds|minute|minutes|hour|hours|day|days|week|weeks)$'
  [[ "$window" =~ $re ]] || { do_log "FATAL UNHEARD_WINDOW must be 'N unit' (e.g. '7 days'), got: '$window'"; return 1; }
  [[ "$grace"  =~ $re ]] || { do_log "FATAL UNHEARD_GRACE must be 'N unit' (e.g. '2 minutes'), got: '$grace'"; return 1; }
  local tclause=""
  if [[ -n "$tenant" ]]; then
    [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
    tclause="and m.tenant_id = '$tenant'"
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  export SPL_UNHEARD_SQL="
select m.tenant_id, m.channel, m.task_id,
       count(*) as unanswered_posts,
       min(m.received_at) as first_post,
       max(m.received_at) as last_post
from messages m
where m.from_box = 'box-wui' and m.from_id like 'HUM-%' and m.env_sig <> ''
  and m.received_at >= now() - interval '$window'
  and m.received_at <  now() - interval '$grace'
  $tclause
  and (m.channel is not null or (m.to_id not like 'HUM-%' and m.to_id not like 'GST-%' and m.to_id <> 'ALL-0'))
  and not exists (select 1 from channels c
                  where c.tenant_id = m.tenant_id and c.channel_id = m.channel and c.no_fallback)
  and not exists (select 1 from fallback_deliveries f
                  where f.tenant_id = m.tenant_id and f.msg_id = m.msg_id)
  and not exists (select 1 from messages r
                  where r.tenant_id = m.tenant_id and r.task_id = m.task_id
                    and r.received_at > m.received_at and r.from_box <> 'box-wui'
                    and r.from_id not like 'HUM-%' and r.from_id not like 'GST-%')
group by m.tenant_id, m.channel, m.task_id
order by unanswered_posts desc, last_post desc"
  do_log "INFO SPL-1225 monitor: unanswered human posts in the last $window (reply grace $grace)${tenant:+, tenant $tenant} on $ENV"
  spl_via_proxy _spl_report_unheard_run
}

_spl_report_unheard_run() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off -c 'BEGIN TRANSACTION READ ONLY' \
      -c "SET LOCAL app.rls_scope = 'operator'" -c "$SPL_UNHEARD_SQL" -c 'ROLLBACK'
}
