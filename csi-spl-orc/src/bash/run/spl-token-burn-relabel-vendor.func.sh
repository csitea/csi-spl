#!/bin/bash
#------------------------------------------------------------------------------
# @description Re-label unpriced fleet_token_burn_events minutes whose stored
# @description vendor does not match their model (SPL-5370, spec 140 2.3.4 /
# @description 3.9: before agy_agent named non-agy sessions apart, an agy turn
# @description in the same (agent_id, minute) as claude kept vendor=claude and
# @description overwrote model=gemini-3.8-flash). Only metered rows with
# @description priced=false and cost_micros=0 matching TOKEN_RELABEL_FROM_VENDOR,
# @description TOKEN_RELABEL_MODEL and minute_bucket >= TOKEN_RELABEL_FROM (and
# @description TOKEN_RELABEL_BOX when set) are touched; priced rows, other
# @description models/vendors and older rows are untouched.
# @description DRY_RUN=1 (default): READ ONLY transaction, rolled back; prints
# @description matched row count and before/after lines, writes nothing.
# @description DRY_RUN=0: ONE operator transaction; refuses when
# @description TOKEN_RELABEL_EXPECT disagrees with matched count, updates
# @description vendor, re-rolls affected UTC days in fleet_token_burn_daily,
# @description and commits. Uses the env service account and Cloud SQL proxy.
# @param ENV - required: dev or prd
# @param TOKEN_RELABEL_MODEL - required: stored model name (no default), e.g. gemini-3.8-flash
# @param TOKEN_RELABEL_FROM_VENDOR - required: wrong stored vendor (claude|mistral|grok|agy|qwen)
# @param TOKEN_RELABEL_TO_VENDOR - required: target vendor (distinct from TOKEN_RELABEL_FROM_VENDOR)
# @param TOKEN_RELABEL_FROM - required: first minute, YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (UTC)
# @param TOKEN_RELABEL_BOX (optional) - restrict to one box_tag ([a-z0-9_-]{1,32})
# @param TOKEN_RELABEL_EXPECT (optional) - exact row count required on DRY_RUN=0
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd TOKEN_RELABEL_MODEL=gemini-3.8-flash TOKEN_RELABEL_FROM_VENDOR=claude TOKEN_RELABEL_TO_VENDOR=agy TOKEN_RELABEL_FROM=2026-11-01 ./run -a do_spl_token_burn_relabel_vendor
# @example ENV=prd TOKEN_RELABEL_MODEL=gemini-3.8-flash TOKEN_RELABEL_FROM_VENDOR=claude TOKEN_RELABEL_TO_VENDOR=agy TOKEN_RELABEL_FROM=2026-11-01 DRY_RUN=0 ./run -a do_spl_token_burn_relabel_vendor
#------------------------------------------------------------------------------
do_spl_token_burn_relabel_vendor() {
  do_require_bin yq psql || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_token_relabel_args || return 1
  do_spl_cloud_cnf || return 1
  ( spl_token_relabel_main "$dry" )
}

# spl_token_relabel_args -> validates all required/optional env inputs before any DB call.
spl_token_relabel_args() {
  local m="${TOKEN_RELABEL_MODEL:-}" fv="${TOKEN_RELABEL_FROM_VENDOR:-}" tv="${TOKEN_RELABEL_TO_VENDOR:-}"
  local frm="${TOKEN_RELABEL_FROM:-}" bx="${TOKEN_RELABEL_BOX:-}" exp="${TOKEN_RELABEL_EXPECT:-}"
  local vrx='^(claude|mistral|grok|agy|qwen)$'
  [[ -n "$m" ]] || { do_log "FATAL TOKEN_RELABEL_MODEL is required (no default)"; return 1; }
  [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}(-\([0-9a-z]{1,16}\))?(\[[0-9a-z]{1,8}\])?$ ]] ||
    { do_log "FATAL TOKEN_RELABEL_MODEL: bad model name '$m'"; return 1; }
  [[ -n "$fv" ]] || { do_log "FATAL TOKEN_RELABEL_FROM_VENDOR is required (no default)"; return 1; }
  [[ "$fv" =~ $vrx ]] || { do_log "FATAL TOKEN_RELABEL_FROM_VENDOR must be claude|mistral|grok|agy|qwen, got '$fv'"; return 1; }
  [[ -n "$tv" ]] || { do_log "FATAL TOKEN_RELABEL_TO_VENDOR is required (no default)"; return 1; }
  [[ "$tv" =~ $vrx ]] || { do_log "FATAL TOKEN_RELABEL_TO_VENDOR must be claude|mistral|grok|agy|qwen, got '$tv'"; return 1; }
  [[ "$fv" != "$tv" ]] || { do_log "FATAL TOKEN_RELABEL_TO_VENDOR must differ from TOKEN_RELABEL_FROM_VENDOR ('$fv')"; return 1; }
  [[ -n "$frm" ]] || { do_log "FATAL TOKEN_RELABEL_FROM is required (no default)"; return 1; }
  [[ "$frm" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9](T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z)?$ ]] ||
    { do_log "FATAL TOKEN_RELABEL_FROM must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (UTC), got '$frm'"; return 1; }
  [[ -z "$bx" || "$bx" =~ ^[a-z0-9_-]{1,32}$ ]] || { do_log "FATAL TOKEN_RELABEL_BOX: bad box_tag '$bx'"; return 1; }
  [[ -z "$exp" || "$exp" =~ ^[0-9]{1,7}$ ]] || { do_log "FATAL TOKEN_RELABEL_EXPECT must be a non-negative integer, got '$exp'"; return 1; }
}

# spl_token_relabel_main <dry> -> builds the SQL in a 0700 temp dir, pins SA, runs via proxy.
spl_token_relabel_main() {
  local dry="$1" work
  work="$(mktemp -d "${TMPDIR:-/tmp}/spl-token-relabel.XXXXXX")" || { do_log "FATAL mktemp"; return 1; }
  chmod 700 "$work"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  spl_token_relabel_sql "$dry" >"$work/run.sql" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_TRV_SQL="$work/run.sql" SPL_TRV_DRY="$dry" spl_via_proxy _spl_token_relabel_run
}

# spl_token_relabel_sql <dry> -> the operator transaction SQL (READ ONLY when dry=1).
spl_token_relabel_sql() {
  local dry="$1"
  if ((dry)); then
    cat <<'SQL'
\set VERBOSITY terse
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SET LOCAL timezone = 'UTC';
SET LOCAL lock_timeout = '5s';
SELECT count(*) AS matched
  FROM fleet_token_burn_events
 WHERE vendor = :'from_vendor' AND model = :'model' AND minute_bucket >= (:'from_ts')::timestamptz
   AND (:'box' = '' OR box_tag = :'box') AND is_metered AND NOT priced AND cost_micros = 0 \gset
\echo PLAN matched=:matched from_vendor=:from_vendor to_vendor=:to_vendor model=:model from=:from_ts box=:box
SELECT 'DRY_ROW' || E'\t' || id || E'\t' || box_tag || E'\t' || agent_id || E'\t' ||
       to_char(minute_bucket, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || E'\t' ||
       vendor || '->' || :'to_vendor' || E'\t' || coalesce(model, '') ||
       E'\tin=' || tokens_in || ' out=' || tokens_out || ' cr=' || cache_read || ' cw=' || cache_write || ' priced=' || priced
  FROM fleet_token_burn_events
 WHERE vendor = :'from_vendor' AND model = :'model' AND minute_bucket >= (:'from_ts')::timestamptz
   AND (:'box' = '' OR box_tag = :'box') AND is_metered AND NOT priced AND cost_micros = 0
 ORDER BY minute_bucket, box_tag, agent_id;
ROLLBACK;
SQL
    return 0
  fi
  spl_token_relabel_write_sql
}

# spl_token_relabel_write_sql -> the atomic update + daily re-roll SQL for DRY_RUN=0.
# Update runs as its own statement before the daily rollup so Postgres's next
# command-id snapshot sees the relabelled vendor in fleet_token_burn_events.
spl_token_relabel_write_sql() {
  cat <<'SQL'
\set VERBOSITY terse
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL app.rls_scope = 'operator';
SET LOCAL timezone = 'UTC';
SET LOCAL lock_timeout = '5s';
SELECT count(*) AS matched,
       coalesce(min((minute_bucket AT TIME ZONE 'UTC')::date)::text, '') AS min_day,
       coalesce(max((minute_bucket AT TIME ZONE 'UTC')::date)::text, '') AS max_day
  FROM (
    SELECT id, minute_bucket FROM fleet_token_burn_events
     WHERE vendor = :'from_vendor' AND model = :'model' AND minute_bucket >= (:'from_ts')::timestamptz
       AND (:'box' = '' OR box_tag = :'box') AND is_metered AND NOT priced AND cost_micros = 0
       FOR UPDATE
  ) l \gset
\echo PLAN matched=:matched from_vendor=:from_vendor to_vendor=:to_vendor model=:model from=:from_ts box=:box
SELECT (:'expect' = '' OR :matched = nullif(:'expect', '')::int) AS go \gset
\if :go
\else
  ROLLBACK;
  \echo REFUSED matched=:matched expect=:expect
  \quit
\endif
SELECT 'BEFORE' || E'\t' || id || E'\t' || box_tag || E'\t' || agent_id || E'\t' ||
       to_char(minute_bucket, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || E'\t' ||
       vendor || E'\t' || coalesce(model, '') || E'\tcw=' || cache_write || ' priced=' || priced
  FROM fleet_token_burn_events
 WHERE vendor = :'from_vendor' AND model = :'model' AND minute_bucket >= (:'from_ts')::timestamptz
   AND (:'box' = '' OR box_tag = :'box') AND is_metered AND NOT priced AND cost_micros = 0
 ORDER BY minute_bucket, box_tag, agent_id;
WITH upd AS (
  UPDATE fleet_token_burn_events
     SET vendor = :'to_vendor', updated_at = now()
   WHERE vendor = :'from_vendor' AND model = :'model' AND minute_bucket >= (:'from_ts')::timestamptz
     AND (:'box' = '' OR box_tag = :'box') AND is_metered AND NOT priced AND cost_micros = 0
  RETURNING id, box_tag, agent_id, minute_bucket, vendor, coalesce(model, '') AS model, priced, cache_write
)
SELECT line FROM (
  SELECT 1 AS ord, minute_bucket, box_tag, agent_id,
         'AFTER' || E'\t' || id || E'\t' || box_tag || E'\t' || agent_id || E'\t' ||
         to_char(minute_bucket, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || E'\t' ||
         vendor || E'\t' || model || E'\tcw=' || cache_write || ' priced=' || priced AS line
    FROM upd
  UNION ALL
  SELECT 2, 'epoch'::timestamptz, '', '', 'UPDATED_N=' || (SELECT count(*) FROM upd)
) q ORDER BY ord, minute_bucket, box_tag, agent_id;
SELECT (:matched > 0) AS has_days \gset
\set rolled_days 0
\if :has_days
WITH roll AS (
  INSERT INTO fleet_token_burn_daily AS d (day_bucket, box_tag, agent_id, vendor, model, minutes,
    tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, is_metered, work_tenant, rolled_at)
  SELECT (e.minute_bucket AT TIME ZONE 'UTC')::date, e.box_tag, e.agent_id,
    (array_agg(e.vendor ORDER BY e.minute_bucket DESC))[1], (array_agg(e.model ORDER BY e.minute_bucket DESC))[1],
    count(*), sum(e.tokens_in), sum(e.tokens_out), sum(e.cache_read), sum(e.cache_write), sum(e.cost_micros),
    coalesce(min(e.currency) FILTER (WHERE e.priced), min(e.currency)), bool_or(e.is_metered),
    (array_agg(e.work_tenant ORDER BY e.minute_bucket DESC))[1], now()
  FROM fleet_token_burn_events e
  WHERE e.minute_bucket >= (:'min_day')::timestamptz
    AND e.minute_bucket < ((:'max_day')::date + 1)::timestamptz
  GROUP BY 1, 2, 3
  ON CONFLICT (day_bucket, box_tag, agent_id) DO UPDATE SET vendor = EXCLUDED.vendor, model = EXCLUDED.model,
    minutes = EXCLUDED.minutes, tokens_in = EXCLUDED.tokens_in, tokens_out = EXCLUDED.tokens_out,
    cache_read = EXCLUDED.cache_read, cache_write = EXCLUDED.cache_write, cost_micros = EXCLUDED.cost_micros,
    currency = EXCLUDED.currency, is_metered = EXCLUDED.is_metered, work_tenant = EXCLUDED.work_tenant, rolled_at = now()
  RETURNING day_bucket
)
SELECT count(DISTINCT day_bucket) AS rolled_days FROM roll \gset
\endif
COMMIT;
\echo SUMMARY updated=:matched rolled_days=:rolled_days
SQL
}

# _spl_token_relabel_run -> executes psql with DSN in env only and logs the verdict.
_spl_token_relabel_run() {
  local out rc=0 plan sum l
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1     -v model="$TOKEN_RELABEL_MODEL" -v from_vendor="$TOKEN_RELABEL_FROM_VENDOR"     -v to_vendor="$TOKEN_RELABEL_TO_VENDOR" -v from_ts="$TOKEN_RELABEL_FROM"     -v box="${TOKEN_RELABEL_BOX:-}" -v expect="${TOKEN_RELABEL_EXPECT:-}"     -f "$SPL_TRV_SQL" 2>&1)" || rc=$?
  plan="$(grep -m1 '^PLAN ' <<<"$out")"
  if ((rc)); then
    do_log "FATAL psql failed on $ENV (rc $rc), rolled back: $(grep -m1 -E 'ERROR|FATAL' <<<"$out" | cut -c1-200)"
    return 1
  fi
  [[ -n "$plan" ]] || { do_log "FATAL no PLAN line from psql on $ENV"; return 1; }
  grep -E '^(DRY_ROW|BEFORE|AFTER)	' <<<"$out" | while IFS= read -r l; do do_log "INFO $ENV $l"; done
  if [[ "$SPL_TRV_DRY" == 1 ]]; then
    do_log "OK DRY_RUN $ENV: ${plan#PLAN }; rolled back, nothing written. Re-run with DRY_RUN=0."
    return 0
  fi
  if grep -q '^REFUSED ' <<<"$out"; then
    do_log "FATAL $ENV ${plan#PLAN }; $(grep -m1 '^REFUSED ' <<<"$out"); rolled back, nothing written"
    return 1
  fi
  sum="$(grep -m1 '^SUMMARY ' <<<"$out")"
  [[ -n "$sum" ]] || { do_log "FATAL $ENV ${plan#PLAN }: missing SUMMARY line"; return 1; }
  do_log "OK $ENV committed: ${plan#PLAN }; ${sum#SUMMARY } (${GCP_ACCOUNT:-})"
}
