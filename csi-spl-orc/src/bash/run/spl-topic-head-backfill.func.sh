#!/bin/bash
#------------------------------------------------------------------------------
# @description Backfill the topic heads (rdb 0144, spec 099 section 8 step 2,
# @description T006) of a cloud env's hub DB: loop
# @description SELECT topic_head_backfill(chunk => 100, rebuild_all, after)
# @description until a chunk comes back empty. The function is a keyset walk
# @description over every (tenant_id, task_id) of messages that rebuilds every
# @description topic it passes, head or not; REBUILD=all also walks
# @description topic_heads, so a head whose topic has no row left is deleted.
# @description Each chunk is ONE short transaction under the operator RLS scope
# @description and lock_timeout 5s; a failed chunk (a lock timeout) is retried
# @description from the same cursor, 3 tries, so no topic is skipped.
# @description The function sets each tenant's topic_head_tenants mark once the
# @description walk has passed it; the final empty chunk marks the rest.
# @description Prints the chunks and the topics passed.
# @description Same path as do_spl_db_query: the env's project service account
# @description (do_gcp_pin_account, never the owner account), the hub runtime
# @description DSN from Secret Manager, the Cloud SQL proxy on 127.0.0.1.
# @description DRY_RUN=1 (default): count the topics it would pass, in a READ
# @description ONLY transaction, and write nothing.
# @param ENV - required: dev or prd (prd only with the owner's go: spec 099 Q4)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param REBUILD (optional) - all: also delete heads whose topic is gone; default: messages only
# @param TOPIC_HEAD_CHUNK (optional) - topics per chunk, default 100 (1..1000)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_topic_head_backfill
# @example ENV=dev DRY_RUN=0 REBUILD=all ./run -a do_spl_topic_head_backfill
#------------------------------------------------------------------------------
do_spl_topic_head_backfill() {
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1 all chunk="${TOPIC_HEAD_CHUNK:-100}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  all="$(spl_topic_head_rebuild_all)" || return 1
  spl_topic_head_check_chunk "$chunk" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( dry )); then
    SPL_TH_ALL="$all" spl_via_proxy _spl_topic_head_backfill_dry
    return $?
  fi
  SPL_TH_ALL="$all" SPL_TH_CHUNK="$chunk" spl_via_proxy _spl_topic_head_backfill_run
}

# spl_topic_head_rebuild_all -> "true" for REBUILD=all, "false" when unset;
# any other value is refused.
spl_topic_head_rebuild_all() {
  case "${REBUILD:-}" in
    all) echo true ;;
    "") echo false ;;
    *) do_log "FATAL REBUILD must be 'all' or unset, got: '${REBUILD:-}'" >&2; return 1 ;;
  esac
}

# spl_topic_head_check_chunk <n> -> 0 when n is 1..1000.
spl_topic_head_check_chunk() {
  if [[ ! "$1" =~ ^[1-9][0-9]{0,3}$ ]] || (( $1 > 1000 )); then
    do_log "FATAL TOPIC_HEAD_CHUNK must be 1..1000, got: '$1'"; return 1
  fi
}

# spl_topic_head_psql [psql args] -> psql as the login in $SPL_PROXY_DSN (PG*
# env vars, no password in argv), unaligned, stop on the first error. The
# one psql call of the four topic-head actions, so a test stubs spl_pg_env.
spl_topic_head_psql() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 "$@"
}

# _spl_topic_head_backfill_dry -> the topics and tenants the walk would pass,
# read only.
_spl_topic_head_backfill_dry() {
  local out
  out="$(spl_topic_head_psql -v all="$SPL_TH_ALL" <<'SQL' 2>&1
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT 'topics=' || (SELECT count(*) FROM (
          SELECT tenant_id, task_id FROM messages
          UNION SELECT tenant_id, task_id FROM topic_heads WHERE :'all'::boolean) k)
    || ' heads=' || (SELECT count(*) FROM topic_heads)
    || ' tenants=' || (SELECT count(*) FROM tenants)
    || ' marked=' || (SELECT count(*) FROM topic_head_tenants WHERE backfilled_at IS NOT NULL);
ROLLBACK;
SQL
  )" || { do_log "FATAL the read on $ENV failed: $out"; return 1; }
  do_log "OK DRY_RUN $ENV would pass $(tail -n 1 <<<"$out") rebuild_all=$SPL_TH_ALL; nothing written. Re-run with DRY_RUN=0."
}

# _spl_topic_head_backfill_run -> the chunk loop: one transaction per chunk,
# from cursor '' until the function returns NULL (an empty chunk).
_spl_topic_head_backfill_run() {
  local cursor="" next chunks=0 topics=0 n tries
  while :; do
    tries=0
    until next="$(spl_topic_head_chunk "$cursor")"; do
      tries=$((tries + 1))
      (( tries < 3 )) || { do_log "FATAL chunk $((chunks + 1)) after '${cursor:-<start>}' failed $tries times: $next"; return 1; }
      do_log "WARN chunk $((chunks + 1)) after '${cursor:-<start>}' failed (try $tries), retrying: $next"
      sleep "${SPL_TH_RETRY_SLEEP:-2}"
    done
    next="$(tail -n 1 <<<"$next")"
    n="${next%% *}"; next="${next#"$n"}"; next="${next# }"
    [[ "$n" =~ ^[0-9]+$ ]] || { do_log "FATAL unexpected chunk output: '$n $next'"; return 1; }
    chunks=$((chunks + 1)); topics=$((topics + n))
    [[ -n "$next" ]] || break
    cursor="$next"
  done
  do_log "OK $ENV backfill done: chunks=$chunks topics=$topics rebuild_all=$SPL_TH_ALL (${GCP_ACCOUNT:-})"
}

# spl_topic_head_chunk <cursor> -> "<topics passed> <next cursor>" for ONE
# chunk in its own transaction (operator scope, lock_timeout 5s); the next
# cursor is empty once the chunk came back empty. The count is read first,
# with the function's own keyset (a REBUILD=all chunk deletes orphan heads,
# so a count after it would miss them).
spl_topic_head_chunk() {
  spl_topic_head_psql -v after="$1" -v chunk="$SPL_TH_CHUNK" -v all="$SPL_TH_ALL" <<'SQL' 2>&1
BEGIN;
SET LOCAL app.rls_scope = 'operator';
SET LOCAL lock_timeout = '5s';
SELECT count(*) AS n FROM (
    SELECT k.tenant_id, k.task_id FROM (
        SELECT tenant_id, task_id FROM messages
        UNION SELECT tenant_id, task_id FROM topic_heads WHERE :'all'::boolean) k
     WHERE :'after' = ''
        OR (k.tenant_id, k.task_id) > (left(:'after', length(:'after') - 37), right(nullif(:'after', ''), 36)::uuid)
     ORDER BY k.tenant_id, k.task_id LIMIT :chunk) c \gset
SELECT coalesce(topic_head_backfill(:chunk, :'all'::boolean, :'after'), '') AS next \gset
COMMIT;
\echo :n :next
SQL
}
