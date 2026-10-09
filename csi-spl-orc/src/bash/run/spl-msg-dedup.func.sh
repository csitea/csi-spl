#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the DUPLICATED messages of a cloud env (or of one tenant
# @description in it), over every workspace and every channel, DM and topic -
# @description the owner order of t1 topic 35582e7b (2026-10-01): "remove all
# @description of the duplicated msgs which were sent till now also, for all
# @description the channels". The source (the responder posting one "Seen" per post
# @description instead of one per topic) is fixed in do_spl_responder_run;
# @description this action cleans what it left behind, and anything like it.
# @description
# @description A DUPLICATE is a later copy of an earlier message: same tenant,
# @description same topic (task_id), same sender (from_id), same body after
# @description trimming and collapsing whitespace, same attached files. The
# @description FIRST copy (ts, then received_at, then msg_id) is kept, every
# @description later one is deleted. Deleted exactly as the hub's
# @description DELETE /v1/messages/{msg_id} deletes one (store DeleteMessage:
# @description DELETE FROM messages), so deliveries, message_revisions and
# @description message_reactions cascade and the period meters decrement via
# @description their trigger. Open browsers drop them on their next load.
# @description
# @description REPORT ONLY, never deleted: a human post answered by two or
# @description more DIFFERENT agents (not identical messages - an operator
# @description decides). The non-AI responder's "Seen" (SPL_RSP_AGENT, or a
# @description stored RSP-*) is its ack by
# @description design and does not count as an answer.
# @description
# @description SAFETY. DRY_RUN=1 (default) runs the SAME delete inside a
# @description transaction that is rolled back, and lists every duplicate
# @description (tenant, channel, topic, msg_id, ts, sender, kept msg_id, first
# @description 60 chars) plus the count per workspace. DRY_RUN=0 needs
# @description MSG_DEDUP_CONFIRM="<env>/<tenant or all>" and takes a backup
# @description FIRST (do_spl_db_backup into <env>/pre-msg-dedup-<utc date>/):
# @description no backup, no delete. It is NOT do_spl_msg_wipe, which deletes
# @description every message. Runs under the operator RLS scope.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - one tenant slug; empty covers every tenant
# @param DRY_RUN (optional) - 1 (default) or 0
# @param MSG_DEDUP_CONFIRM (DRY_RUN=0 only) - "<env>/<tenant>" or "<env>/all"
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd ./run -a do_spl_msg_dedup
# @example ENV=prd DRY_RUN=0 MSG_DEDUP_CONFIRM=prd/all ./run -a do_spl_msg_dedup
#------------------------------------------------------------------------------
do_spl_msg_dedup() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" dry=1
  [[ -z "$tenant" || "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug or empty, got: '$tenant'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local scope="$ENV/${tenant:-all}"
  if (( ! dry )); then
    [[ "${MSG_DEDUP_CONFIRM:-}" == "$scope" ]] ||
      { do_log "FATAL DRY_RUN=0 deletes the duplicated messages of $scope: set MSG_DEDUP_CONFIRM=$scope to confirm, got: '${MSG_DEDUP_CONFIRM:-}'"; return 1; }
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( ! dry )); then
    local prefix
    prefix="$ENV/pre-msg-dedup-$(date -u +%Y%m%d)/"
    do_log "INFO backup first: $ENV -> <045 bucket>/$prefix"
    DRY_RUN=0 SPL_BACKUP_PREFIX="$prefix" do_spl_db_backup ||
      { do_log "FATAL the backup failed: nothing was deleted"; return 1; }
  fi
  SPL_DEDUP_TENANT="$tenant" SPL_DEDUP_DRY="$dry" spl_via_proxy _spl_msg_dedup_run
}

# The multi-agent report, then the delete of every later copy - ONE transaction
# under the operator RLS scope, committed only when SPL_DEDUP_DRY=0. psql prints
# TAB-separated rows: MULTI <tenant> <channel> <topic> <human msg> <agents>, and
# DUP <tenant> <channel> <topic> <msg_id> <ts> <sender> <kept msg_id> <head>.
_spl_msg_dedup_run() {
  local out
  # shellcheck source=../../../lib/bash/funcs/spl-desk-agents.func.sh
  [[ -n "${SPL_RSP_AGENT:-}" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-agents.func.sh"
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_DEDUP_TENANT" -v dry="$SPL_DEDUP_DRY" -v rsp="$SPL_RSP_AGENT" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
WITH m AS (
  SELECT tenant_id, task_id, channel, msg_id, ts, received_at, from_id
  FROM messages WHERE :'tenant' = '' OR tenant_id = :'tenant'
), h AS (
  SELECT tenant_id, task_id, channel, msg_id, ts, received_at,
         lead(ts) OVER (PARTITION BY tenant_id, task_id ORDER BY ts, received_at, msg_id) AS next_ts
  FROM m WHERE from_id LIKE 'HUM-%'
)
SELECT 'MULTI', h.tenant_id, coalesce(h.channel, '-'), h.task_id, h.msg_id,
       string_agg(DISTINCT a.from_id, ',' ORDER BY a.from_id)
FROM h JOIN m a ON a.tenant_id = h.tenant_id AND a.task_id = h.task_id
  AND a.from_id NOT LIKE 'HUM-%' AND a.from_id NOT LIKE 'RSP-%' AND a.from_id <> :'rsp'
  AND (a.ts, a.received_at, a.msg_id) > (h.ts, h.received_at, h.msg_id)
  AND (h.next_ts IS NULL OR a.ts < h.next_ts)
GROUP BY h.tenant_id, h.channel, h.task_id, h.msg_id, h.ts
HAVING count(DISTINCT a.from_id) > 1
ORDER BY h.tenant_id, h.ts;
WITH c AS (
  SELECT tenant_id, msg_id,
         first_value(msg_id) OVER w AS keep_id,
         row_number() OVER w AS rn
  FROM messages WHERE :'tenant' = '' OR tenant_id = :'tenant'
  WINDOW w AS (PARTITION BY tenant_id, task_id, from_id,
                            regexp_replace(btrim(body), '\s+', ' ', 'g'), files::text
               ORDER BY ts, received_at, msg_id)
), d AS (
  DELETE FROM messages x USING c
  WHERE c.rn > 1 AND x.tenant_id = c.tenant_id AND x.msg_id = c.msg_id
  RETURNING x.tenant_id, x.channel, x.task_id, x.msg_id, x.ts, x.from_id, c.keep_id, x.body
)
SELECT 'DUP', tenant_id, coalesce(channel, '-'), task_id, msg_id,
       to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), from_id, keep_id,
       left(regexp_replace(btrim(body), '\s+', ' ', 'g'), 60)
FROM d ORDER BY tenant_id, channel, task_id, ts, msg_id;
\if :dry
ROLLBACK;
\else
COMMIT;
\endif
SQL
  )" || { do_log "FATAL the dedup statement failed on $ENV (nothing was committed): $out"; return 1; }

  local scope="$ENV/${SPL_DEDUP_TENANT:-all}" n
  n="$(grep -c $'^DUP\t' <<<"$out")"
  printf '%s\n' "$out" | awk -F'\t' '
    $1 == "MULTI" { printf "MULTI tenant=%s channel=%s topic=%s human_msg=%s agents=%s\n", $2, $3, $4, $5, $6 }
    $1 == "DUP"   { printf "DUP tenant=%s channel=%s topic=%s msg=%s ts=%s sender=%s kept=%s | %s\n", $2, $3, $4, $5, $6, $7, $8, $9; per[$2]++ }
    END { for (t in per) printf "COUNT tenant=%s duplicates=%d\n", t, per[t] }' | sort -s -k1,1
  do_log "INFO multi-agent answers are listed (MULTI) and never deleted: $(grep -c $'^MULTI\t' <<<"$out") in $scope"
  if (( SPL_DEDUP_DRY )); then
    do_log "OK DRY_RUN rolled back: $n duplicate(s) in $scope would be deleted, nothing was. Re-run with DRY_RUN=0 MSG_DEDUP_CONFIRM=$scope."
  else
    do_log "OK deleted $n duplicate(s) in $scope ($GCP_ACCOUNT); the first copy of each is kept"
  fi
}
