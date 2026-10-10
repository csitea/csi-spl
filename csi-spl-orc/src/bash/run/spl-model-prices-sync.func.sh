#!/bin/bash
#------------------------------------------------------------------------------
# @description Fills the hub-wide model_prices table (rdb 0171, spec 121
# @description section 7, T303) from cnf env.model_prices: one row per
# @description (provider, model, kind, valid_from) with its micros per million
# @description units. A price change is a NEW row (a later valid_from); a row
# @description the table already holds is never updated, and re-using a
# @description valid_from the table holds at another price is refused, so an
# @description old balance re-prices the same. A cnf row equal to the price in
# @description force at its valid_from adds nothing: re-running writes nothing
# @description new. The SQL runs in OPERATOR RLS scope, one transaction.
# @description Prints one JSON line: env, dry_run, the cnf rows ("cnf") and
# @description the rows new to the table ("new").
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default): count in a READ ONLY transaction, write nothing
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (do_gcp_account)
# @example ENV=dev ./run -a do_spl_model_prices_sync
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_model_prices_sync
#------------------------------------------------------------------------------
do_spl_model_prices_sync() {
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" rows n out rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  rows="$(spl_model_prices_rows "$SPL_CNF")" || return 1
  n="$(grep -c . <<<"$rows")"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  out="$(mktemp)" || return 1
  MP_DRY="$dry" MP_ROWS="$rows" spl_via_proxy _spl_model_prices_sync_run "$out" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the model prices sync in $ENV failed, nothing was committed: $(tr '\n' ' ' <"$out")"
    rm -f "$out"; return 1
  fi
  printf '{"env":"%s","dry_run":%s,"cnf":%s,"new":%s}\n' "$ENV" \
    "$([[ "$dry" == 1 ]] && echo true || echo false)" "$n" "$(tail -n 1 "$out")"
  rm -f "$out"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN counted the model prices new to $ENV, wrote nothing"
    return 0
  fi
  do_log "OK synced the model prices of cnf into $ENV"
}

# spl_model_prices_rows <cnf> -> one TSV line per (provider, model, kind):
# provider, model, kind, micros per million, currency, valid_from. Every field
# is checked against rdb 0171's constraints before any DB call (the values go
# into the SQL as literals); an absent or empty block, or two rows for one
# (provider, model, kind, valid_from), is refused.
spl_model_prices_rows() {
  local tsv key p m k mpm cur vf
  local -A seen=()
  tsv="$(yq -r '(.env.model_prices // [])[] | . as $r | ($r.per_million // {}) | to_entries[] |
    [$r.provider, $r.model, .key, .value, $r.currency, $r.valid_from] | map(. // "" | tostring) | @tsv' "$1")" ||
    { do_log "FATAL cannot read cnf env.model_prices"; return 1; }
  [[ -n "$tsv" ]] || { do_log "FATAL cnf env.model_prices holds no price"; return 1; }
  while IFS=$'\t' read -r p m k mpm cur vf; do
    key="$p/$m/$k/$vf"
    [[ "$p" =~ ^[a-z][a-z0-9_.-]{0,63}$ ]] || { do_log "FATAL cnf env.model_prices: bad provider '$p'"; return 1; }
    [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,199}$ ]] || { do_log "FATAL cnf env.model_prices: bad model '$m'"; return 1; }
    [[ "$k" =~ ^(llm_tokens_(in|out|cache_read|cache_write)|agent_seconds|storage_bytes|cloud_share)$ ]] ||
      { do_log "FATAL cnf env.model_prices: $p/$m: unknown kind '$k'"; return 1; }
    [[ "$mpm" =~ ^(0|[1-9][0-9]{0,17})$ ]] ||
      { do_log "FATAL cnf env.model_prices: $key: per_million is not whole micros >= 0: '$mpm'"; return 1; }
    [[ "$cur" =~ ^[A-Z]{3}$ ]] || { do_log "FATAL cnf env.model_prices: $p/$m: bad currency '$cur'"; return 1; }
    [[ "$vf" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
      { do_log "FATAL cnf env.model_prices: $p/$m: valid_from is not YYYY-MM-DDTHH:MM:SSZ: '$vf'"; return 1; }
    [[ -z "${seen[$key]:-}" ]] || { do_log "FATAL cnf env.model_prices: $key twice"; return 1; }
    seen[$key]=1
  done <<<"$tsv"
  echo "$tsv"
}

# _spl_model_prices_sync_run <out> - one transaction through $SPL_PROXY_DSN
# over the cnf rows in $MP_ROWS: refuse a (provider, model, kind, valid_from)
# the table holds at another price, then insert (MP_DRY=0) or count (MP_DRY=1)
# the rows whose price differs from the one in force before their valid_from.
# The last line of <out> is that count.
_spl_model_prices_sync_run() {
  local begin='BEGIN;' values="" p m k mpm cur vf c pick body
  while IFS=$'\t' read -r p m k mpm cur vf; do
    values+="${values:+, }('$p', '$m', '$k', $mpm::bigint, '$cur', '$vf'::timestamptz)"
  done <<<"$MP_ROWS"
  c="c (provider, model, kind, micros_per_million, currency, valid_from) AS (VALUES $values)"
  pick="SELECT c.* FROM c WHERE NOT EXISTS (SELECT 1 FROM model_prices m WHERE m.provider = c.provider
      AND m.model = c.model AND m.kind = c.kind AND m.valid_from = c.valid_from)
    AND (SELECT ROW(m.micros_per_million, m.currency) FROM model_prices m WHERE m.provider = c.provider
      AND m.model = c.model AND m.kind = c.kind AND m.valid_from < c.valid_from
      ORDER BY m.valid_from DESC LIMIT 1) IS DISTINCT FROM ROW(c.micros_per_million, c.currency)"
  if [[ "$MP_DRY" == 1 ]]; then
    begin='BEGIN READ ONLY;'
    body="WITH $c, n AS ($pick) SELECT count(*) FROM n;"
  else
    body="WITH $c, n AS ($pick), i AS (INSERT INTO model_prices
      (provider, model, kind, micros_per_million, currency, valid_from) SELECT * FROM n RETURNING 1)
    SELECT count(*) FROM i;"
  fi
  printf '%s\n' "$begin" "SET LOCAL app.rls_scope = 'operator';" \
    "DO \$mp\$ DECLARE bad text; BEGIN
  WITH $c SELECT string_agg(format('%s/%s/%s/%s: table %s %s, cnf %s %s', c.provider, c.model, c.kind,
      c.valid_from, m.micros_per_million, m.currency, c.micros_per_million, c.currency), '; ') INTO bad
    FROM c JOIN model_prices m USING (provider, model, kind, valid_from)
   WHERE (m.micros_per_million, m.currency) IS DISTINCT FROM (c.micros_per_million, c.currency);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'model_prices: a price change needs a new valid_from, a held row is never rewritten: %', bad;
  END IF;
END \$mp\$;" "$body" 'COMMIT;' |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 >"$1" 2>&1
}
