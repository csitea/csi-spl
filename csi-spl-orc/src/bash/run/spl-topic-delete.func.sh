#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete ONE topic and its whole thread from a cloud env's hub DB,
# @description by task id. The named, reusable form of the owner order
# @description (prd t1 #spool-hub-bugs 9f60d718, 2026-09-29): "remove all of the
# @description topics with their threads" that have no valid opening card and so
# @description cannot be cleared from the WUI (the e802196b class: a topic whose
# @description rows are all is_parent 0, or otherwise leaves resolveCard with no
# @description card to act on, so the hub's own DELETE /v1/messages/{card}/topic
# @description cannot reach it). "Nothing ad hoc" wants this as an action, not a
# @description shell one-off.
# @description
# @description WHAT GOES: every messages row of the topic - the task's rows, the
# @description message-rooted threads opened on its lines (task_id = a line's
# @description msg_id) and the sub-tasks under it, transitively, exactly the walk
# @description hub store.walkTopic makes - and by ON DELETE CASCADE their
# @description deliveries, message_revisions and message_reactions. The 0023
# @description trigger decrements the period meter. Blobs are swept separately.
# @description WHAT STAYS: every other topic, and all identities.
# @description
# @description SAFETY. DRY_RUN=1 (default) runs the SAME delete in a transaction
# @description that is rolled back and prints the rows it would remove. DRY_RUN=0
# @description needs TOPIC_DELETE_CONFIRM="<env>/<tenant>/<task>", so a wrong
# @description env, tenant or task deletes nothing, and it takes a backup FIRST
# @description (do_spl_db_backup into <env>/pre-topic-delete-<utc date>/): no
# @description backup, no delete. The delete runs under the operator RLS scope,
# @description the same do_spl_db_query reads under, in ONE transaction.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug the topic is in (never crosses tenants)
# @param TASK_ID - required: the topic's task uuid (the ?topic= of the WUI URL)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param TOPIC_DELETE_CONFIRM (DRY_RUN=0 only) - "<env>/<tenant>/<task>"
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=prd TENANT_ID=t1 TASK_ID=008fd14a-5311-418b-a5b6-33d0ea690215 ./run -a do_spl_topic_delete
# @example ENV=prd TENANT_ID=t1 TASK_ID=008fd14a-5311-418b-a5b6-33d0ea690215 DRY_RUN=0 TOPIC_DELETE_CONFIRM=prd/t1/008fd14a-5311-418b-a5b6-33d0ea690215 ./run -a do_spl_topic_delete
#------------------------------------------------------------------------------
do_spl_topic_delete() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" task="${TASK_ID:-}" dry=1
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [[ "$task" =~ $uuid_re ]] || { do_log "FATAL TASK_ID must be a lowercase task uuid, got: '$task'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local scope="$ENV/$tenant/$task"
  if (( ! dry )); then
    [[ "${TOPIC_DELETE_CONFIRM:-}" == "$scope" ]] ||
      { do_log "FATAL DRY_RUN=0 deletes topic $scope: set TOPIC_DELETE_CONFIRM=$scope to confirm, got: '${TOPIC_DELETE_CONFIRM:-}'"; return 1; }
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( ! dry )); then
    local prefix
    prefix="$ENV/pre-topic-delete-$(date -u +%Y%m%d)/"
    do_log "INFO backup first: $ENV -> <045 bucket>/$prefix"
    DRY_RUN=0 SPL_BACKUP_PREFIX="$prefix" do_spl_db_backup ||
      { do_log "FATAL the backup failed: nothing was deleted"; return 1; }
  fi
  SPL_TD_TENANT="$tenant" SPL_TD_TASK="$task" SPL_TD_DRY="$dry" spl_via_proxy _spl_topic_delete_run
}

# The recursive topic walk (hub store.walkTopic), before/after row count and the
# delete - ONE transaction under the operator RLS scope, committed only when
# SPL_TD_DRY=0. Its last line reads "<before> -> <after> deleted=<n> committed=<t|f>".
_spl_topic_delete_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_TD_TENANT" -v task="$SPL_TD_TASK" -v dry="$SPL_TD_DRY" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
CREATE TEMP TABLE td_topic ON COMMIT DROP AS
WITH RECURSIVE topic(msg_id, task_id) AS (
    SELECT msg_id, task_id FROM messages WHERE tenant_id = :'tenant' AND task_id = :'task'::uuid
  UNION
    SELECT m.msg_id, m.task_id FROM messages m JOIN topic t
      ON m.tenant_id = :'tenant' AND (m.task_id = t.msg_id OR m.parent_task_id = t.task_id)
)
SELECT msg_id FROM topic;
SELECT count(*) AS before FROM td_topic \gset
WITH d AS (DELETE FROM messages WHERE tenant_id = :'tenant' AND msg_id IN (SELECT msg_id FROM td_topic) RETURNING 1)
SELECT count(*) AS deleted FROM d \gset
SELECT count(*) AS after FROM messages WHERE tenant_id = :'tenant' AND task_id = :'task'::uuid \gset
\if :dry
ROLLBACK;
\echo :before -> :after deleted=:deleted committed=f
\else
COMMIT;
\echo :before -> :after deleted=:deleted committed=t
\endif
SQL
  )" || { do_log "FATAL the delete statement failed on $ENV (nothing was committed): $out"; return 1; }

  local line
  line="$(tail -n1 <<<"$out")"
  do_log "INFO topic rows before -> remaining with this task_id: $line"
  if (( SPL_TD_DRY )); then
    do_log "OK DRY_RUN rolled back: nothing was deleted from $ENV/$SPL_TD_TENANT topic $SPL_TD_TASK. Re-run with DRY_RUN=0 TOPIC_DELETE_CONFIRM=$ENV/$SPL_TD_TENANT/$SPL_TD_TASK."
  else
    do_log "OK deleted topic $ENV/$SPL_TD_TENANT/$SPL_TD_TASK ($GCP_ACCOUNT): $line"
  fi
}
