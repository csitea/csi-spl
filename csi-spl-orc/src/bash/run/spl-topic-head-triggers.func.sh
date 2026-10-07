#!/bin/bash
#------------------------------------------------------------------------------
# @description Rollback level 2 of the topic heads (spec 099 section 8, T006):
# @description switch the four rdb 0144 triggers on messages off or on.
# @description   OP=disable  ALTER TABLE messages DISABLE TRIGGER topic_head_mark_ins,
# @description               topic_head_mark_upd, topic_head_mark_del and
# @description               topic_head_apply: the write cost is gone and the
# @description               heads go stale. In the same transaction every
# @description               topic_head_tenants mark is deleted, so no read can
# @description               serve a stale head even if the flag is turned on.
# @description   OP=enable   ENABLE the four, then the backfill with
# @description               REBUILD=all (do_spl_topic_head_backfill's loop),
# @description               which rebuilds every head and sets the marks again.
# @description               Then run do_spl_topic_head_verify, then shadow.
# @description REFUSES unless the env's hub reports topic_heads "off" on
# @description GET /version (host: cnf env.dns.api_fqdn, never a literal): a hub
# @description that reads heads must not lose its triggers under it.
# @description ALTER TABLE needs the table owner: the DSN is the OWNER login
# @description (cnf hub.db_owner_dsn_secret, as do_spl_db_bootstrap), read as
# @description the env's project service account, through the Cloud SQL proxy.
# @description lock_timeout 5s on the ALTER. Prints the triggers' states.
# @description DRY_RUN=1 (default): the /version check, then print the plan.
# @param ENV - required: dev or prd (prd only with the owner's go)
# @param OP - required: disable or enable
# @param DRY_RUN (optional) - 1 (default) or 0
# @param TOPIC_HEAD_VERSION_URL (optional) - the /version URL, default https://<env.dns.api_fqdn>/version
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev OP=disable ./run -a do_spl_topic_head_triggers
# @example ENV=dev OP=enable DRY_RUN=0 ./run -a do_spl_topic_head_triggers
#------------------------------------------------------------------------------
do_spl_topic_head_triggers() {
  do_require_bin yq psql python3 curl || return 1
  local op="${OP:-}" dry=1
  [[ "$op" == disable || "$op" == enable ]] || { do_log "FATAL OP must be disable or enable, got: '$op'"; return 1; }
  do_spl_cloud_cnf || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_topic_head_require_off || return 1
  if (( dry )); then
    do_log "OK DRY_RUN would: as the owner login of $SPL_DB_NAME, $op the 4 topic_head triggers on messages$(
      [[ $op == disable ]] && echo ' and delete every topic_head_tenants mark' ||
      echo ', then backfill with REBUILD=all'); nothing changed. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local owner_dsn rc=0
  owner_dsn="$(spl_read_dsn owner)"
  [[ -n "$owner_dsn" ]] || { do_log "FATAL cannot read $SPL_OWNER_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; return 1; }
  spl_sql_proxy_start || return 1
  # shellcheck disable=SC2034 # read by spl_topic_head_psql, via dynamic scope
  SPL_PROXY_DSN="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL unexpected DSN shape in $SPL_OWNER_DSN_SECRET"; return 1; }
  unset owner_dsn
  SPL_TH_OP="$op" _spl_topic_head_triggers_run || rc=$?
  spl_sql_proxy_stop
  unset SPL_PROXY_DSN
  return $rc
}

# spl_topic_head_require_off -> 0 only when GET /version of the env's hub
# carries "topic_heads": "off". A hub that does not report it, or any other
# mode, is refused.
spl_topic_head_require_off() {
  local url="${TOPIC_HEAD_VERSION_URL:-}" fqdn body mode
  if [[ -z "$url" ]]; then
    fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
    [[ -n "$fqdn" && "$fqdn" != null ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
    url="https://$fqdn/version"
  fi
  body="$(curl -sS --max-time 15 -H 'Cache-Control: no-cache' "$url" 2>&1)" ||
    { do_log "FATAL GET $url failed: $body"; return 1; }
  mode="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("topic_heads", ""))' "$body" 2>/dev/null)" ||
    { do_log "FATAL GET $url is not JSON: ${body:0:200}"; return 1; }
  [[ "$mode" == off ]] || {
    do_log "FATAL refused: $url reports topic_heads='${mode:-<absent>}', not 'off'. Roll the hub to SPOOL_HUB_TOPIC_HEADS=off first (rollback level 1)."
    return 1
  }
  do_log "INFO $url reports topic_heads=off"
}

# _spl_topic_head_triggers_run -> the ALTER (and on disable the mark delete)
# in ONE transaction; on enable then the REBUILD=all backfill loop.
_spl_topic_head_triggers_run() {
  local out verb="DISABLE" marks=""
  if [[ "$SPL_TH_OP" == enable ]]; then verb="ENABLE"; else marks="DELETE FROM topic_head_tenants;"; fi
  out="$(spl_topic_head_psql <<SQL 2>&1
BEGIN;
SET LOCAL app.rls_scope = 'operator';
SET LOCAL lock_timeout = '5s';
ALTER TABLE messages $verb TRIGGER topic_head_mark_ins, $verb TRIGGER topic_head_mark_upd,
                     $verb TRIGGER topic_head_mark_del, $verb TRIGGER topic_head_apply;
$marks
COMMIT;
SELECT string_agg(tgname || '=' || tgenabled::text, ' ' ORDER BY tgname) FROM pg_trigger
 WHERE tgrelid = 'messages'::regclass AND tgname LIKE 'topic\_head\_%';
SQL
  )" || { do_log "FATAL $SPL_TH_OP the topic_head triggers on $ENV failed (nothing committed): $out"; return 1; }
  do_log "OK $ENV topic_head triggers ${SPL_TH_OP}d: $(tail -n 1 <<<"$out") (O = on, D = off)"
  [[ "$SPL_TH_OP" == enable ]] || return 0
  SPL_TH_ALL=true SPL_TH_CHUNK="${TOPIC_HEAD_CHUNK:-100}" _spl_topic_head_backfill_run || return 1
  do_log "INFO next: ENV=$ENV ./run -a do_spl_topic_head_verify, then shadow (spec 099 section 8)"
}
