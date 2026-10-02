#!/bin/bash
#------------------------------------------------------------------------------
# @description Wipe the MESSAGE data of a cloud env (or of one tenant in it),
# @description to start a test round clean. Spec 033 T013: the named form of
# @description the 2026-09-25 owner order "delete all of te msgs data from the
# @description dev and prd , to start clean with the testing" (033 T012), which
# @description first ran as a one-off - the repo rule "nothing ad hoc" wants it
# @description here, reusable.
# @description
# @description WHAT GOES: every messages row (of TENANT_ID when set), and by
# @description ON DELETE CASCADE its deliveries (rdb 0001), message_revisions
# @description (0026) and message_reactions (0037). The 0023 trigger
# @description message_period_counts_sub decrements the period meters; their
# @description rows are kept. Blobs are not touched: the file sweeper deletes
# @description orphans older than 24 h (spec 031 file retention).
# @description WHAT STAYS: tenants, humans, pins, boxes, roster, channels,
# @description channel members and subscriptions - identities, never history.
# @description
# @description SAFETY. DRY_RUN=1 (default) runs the SAME delete inside a
# @description transaction that is rolled back, and prints the before/after
# @description counts it would leave. DRY_RUN=0 needs MSG_WIPE_CONFIRM set to
# @description "<env>/<tenant or all>", so a wrong ENV or a forgotten TENANT_ID
# @description cannot wipe what nobody named, and it takes a backup FIRST
# @description (do_spl_db_backup into <env>/pre-msg-wipe-<utc date>/): no backup,
# @description no wipe. The delete runs under the operator RLS scope, the same
# @description scope do_spl_db_query reads under.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - one tenant slug; empty wipes every tenant
# @param DRY_RUN (optional) - 1 (default) or 0
# @param MSG_WIPE_CONFIRM (DRY_RUN=0 only) - "<env>/<tenant>" or "<env>/all"
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev ./run -a do_spl_msg_wipe
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 MSG_WIPE_CONFIRM=dev/t1 ./run -a do_spl_msg_wipe
#------------------------------------------------------------------------------
do_spl_msg_wipe() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" dry=1
  [[ -z "$tenant" || "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug or empty, got: '$tenant'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local scope="$ENV/${tenant:-all}"
  if (( ! dry )); then
    [[ "${MSG_WIPE_CONFIRM:-}" == "$scope" ]] ||
      { do_log "FATAL DRY_RUN=0 wipes the messages of $scope: set MSG_WIPE_CONFIRM=$scope to confirm, got: '${MSG_WIPE_CONFIRM:-}'"; return 1; }
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( ! dry )); then
    local prefix
    prefix="$ENV/pre-msg-wipe-$(date -u +%Y%m%d)/"
    do_log "INFO backup first: $ENV -> <045 bucket>/$prefix"
    DRY_RUN=0 SPL_BACKUP_PREFIX="$prefix" do_spl_db_backup ||
      { do_log "FATAL the backup failed: nothing was wiped"; return 1; }
  fi
  SPL_WIPE_TENANT="$tenant" SPL_WIPE_DRY="$dry" spl_via_proxy _spl_msg_wipe_run
}

# Before counts, the delete, after counts - ONE transaction under the operator
# RLS scope, committed only when SPL_WIPE_DRY=0. Its last line reads
#   <msgs> <deliveries> <revisions> <reactions> <meter> -> <same, after> deleted=<n> committed=<t|f>
_spl_msg_wipe_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_WIPE_TENANT" -v dry="$SPL_WIPE_DRY" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
SELECT (SELECT count(*) FROM messages WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT count(*) FROM deliveries WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT count(*) FROM message_revisions WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT count(*) FROM message_reactions WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT coalesce(sum(messages), 0) FROM message_period_counts WHERE :'tenant' = '' OR tenant_id = :'tenant')
    AS before \gset
WITH d AS (DELETE FROM messages WHERE :'tenant' = '' OR tenant_id = :'tenant' RETURNING 1)
SELECT count(*) AS deleted FROM d \gset
SELECT (SELECT count(*) FROM messages WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT count(*) FROM deliveries WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT count(*) FROM message_revisions WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT count(*) FROM message_reactions WHERE :'tenant' = '' OR tenant_id = :'tenant')
    || ' ' || (SELECT coalesce(sum(messages), 0) FROM message_period_counts WHERE :'tenant' = '' OR tenant_id = :'tenant')
    AS after \gset
\if :dry
ROLLBACK;
\echo :before -> :after deleted=:deleted committed=f
\else
COMMIT;
\echo :before -> :after deleted=:deleted committed=t
\endif
SQL
  )" || { do_log "FATAL the wipe statement failed on $ENV (nothing was committed): $out"; return 1; }

  local line
  line="$(tail -n1 <<<"$out")"
  do_log "INFO messages deliveries revisions reactions meter: $line"
  if (( SPL_WIPE_DRY )); then
    do_log "OK DRY_RUN rolled back: nothing was deleted in $ENV/${SPL_WIPE_TENANT:-all}. Re-run with DRY_RUN=0 MSG_WIPE_CONFIRM=$ENV/${SPL_WIPE_TENANT:-all}."
  else
    do_log "OK wiped the messages of $ENV/${SPL_WIPE_TENANT:-all} ($GCP_ACCOUNT): $line"
  fi
}
