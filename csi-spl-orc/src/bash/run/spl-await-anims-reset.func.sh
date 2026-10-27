#!/bin/bash
#------------------------------------------------------------------------------
# @description Reset every member's "Thinking animation" pick (SPL-3836,
# @description owner HUM-10, t1 f372652e msg 35afc373: "add all of the
# @description animations to be selected for all users - even those which have
# @description checkd their own for all workspaces"). Removes the await_anims
# @description key from tenant_memberships.settings (rdb 0078) in EVERY
# @description workspace, so each member falls back to null = the WUI's
# @description default, which is every drawing of its catalogue
# @description (csi-spl-wui/src/utils/await-reply.mjs DEFAULT_AWAIT_SET).
# @description ONE transaction under the operator RLS scope, lock_timeout 5s.
# @description Same path as do_spl_db_query: the env's project service account
# @description (do_gcp_pin_account, never the owner account), the hub runtime
# @description DSN, the Cloud SQL proxy on 127.0.0.1.
# @description DRY_RUN=1 (default): print, per workspace, how many members
# @description hold a pick (an array) or the key at all, in a READ ONLY
# @description transaction, and write nothing.
# @param ENV - required: dev or prd (prd only with the owner's go)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_await_anims_reset
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_await_anims_reset
#------------------------------------------------------------------------------
do_spl_await_anims_reset() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( dry )); then
    spl_via_proxy _spl_await_anims_reset_dry
    return $?
  fi
  spl_via_proxy _spl_await_anims_reset_run
}

# spl_await_anims_psql -> psql (the SQL on stdin) as the login in $SPL_PROXY_DSN (PG*
# env vars, no password in argv), unaligned, stop on the first error; the one
# psql call, so a test stubs spl_pg_env.
spl_await_anims_psql() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -F '|' -v ON_ERROR_STOP=1
}

# spl_await_anims_report <dry|reset> <psql rows> -> one log line per workspace
# ("<tenant>|<picked>|<keyed>|<members>") and a total line.
spl_await_anims_report() {
  local mode="$1" rows="$2" t p k m tp=0 tk=0 tm=0 n=0
  while IFS='|' read -r t p k m; do
    [[ -n "$t" ]] || continue
    [[ "$p" =~ ^[0-9]+$ && "$k" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]] || { do_log "FATAL unexpected row: '$t|$p|$k|$m'"; return 1; }
    do_log "INFO $ENV workspace $t: members=$m picked=$p keyed=$k"
    tp=$((tp + p)); tk=$((tk + k)); tm=$((tm + m)); n=$((n + 1))
  done <<<"$rows"
  if [[ "$mode" == dry ]]; then
    do_log "OK DRY_RUN $ENV workspaces=$n members=$tm picked=$tp would_reset=$tk; nothing written. Re-run with DRY_RUN=0."
  else
    do_log "OK $ENV reset workspaces=$n members=$tm picked=$tp reset=$tk: every member now sees every drawing (${GCP_ACCOUNT:-})"
  fi
}

# the per-workspace counts: members, a pick (array), the key at all (array or null)
SPL_AWAIT_ANIMS_COUNT_SQL="SELECT tenant_id,
       count(*) FILTER (WHERE jsonb_typeof(settings -> 'await_anims') = 'array'),
       count(*) FILTER (WHERE settings ? 'await_anims'),
       count(*)
  FROM tenant_memberships GROUP BY tenant_id ORDER BY tenant_id;"

# _spl_await_anims_reset_dry -> the counts per workspace, read only.
_spl_await_anims_reset_dry() {
  local out
  out="$(spl_await_anims_psql <<SQL 2>&1
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
$SPL_AWAIT_ANIMS_COUNT_SQL
ROLLBACK;
SQL
  )" || { do_log "FATAL the read on $ENV failed: $out"; return 1; }
  spl_await_anims_report dry "$out"
}

# _spl_await_anims_reset_run -> the counts, then the key removed from every
# membership that has it, in ONE transaction; a failure rolls it all back.
_spl_await_anims_reset_run() {
  local out
  out="$(spl_await_anims_psql <<SQL 2>&1
BEGIN;
SET LOCAL app.rls_scope = 'operator';
SET LOCAL lock_timeout = '5s';
$SPL_AWAIT_ANIMS_COUNT_SQL
UPDATE tenant_memberships SET settings = settings - 'await_anims' WHERE settings ? 'await_anims';
COMMIT;
SQL
  )" || { do_log "FATAL the reset on $ENV failed, nothing written: $out"; return 1; }
  spl_await_anims_report reset "$out"
}
