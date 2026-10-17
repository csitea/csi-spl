#!/bin/bash
#------------------------------------------------------------------------------
# @description Price, once, the fleet token burn minutes (rdb 0199
# @description fleet_token_burn_events) stored unpriced because their model had
# @description no model_prices row yet (SPL-2405, spec 140 T010; the rows came
# @description with SPL-2323: the dated id claude-haiku-4-5-20251001 and
# @description mistral-large). It runs `spool fleet-tokens-reprice`, the hub's
# @description own pricer on the hub DB, so each minute gets exactly the cost a
# @description push of that minute gets now. Only metered rows with priced=false
# @description and cost 0 of the named models at or after TOKEN_REPRICE_FROM
# @description are priced; a priced row, another model's and an older one are
# @description never touched. ONE operator transaction, then the daily rollup of
# @description every day from TOKEN_REPRICE_FROM's day is re-rolled in it.
# @description DRY_RUN=1 (default): the same transaction, rolled back: prints per
# @description model the unpriced count, how many it would price and their cost.
# @description DRY_RUN=0: commits, prints before/after; fails when a model keeps
# @description an unpriced minute. A re-run prices 0 rows. Same path as
# @description do_spl_db_query: the env's project service account (never the
# @description owner account), the Cloud SQL proxy, the DSN in the environment
# @description only. The spool binary is the state dir's (spl_host_spool), or
# @description TOKEN_REPRICE_SPOOL; it must know the verb.
# @param ENV - required: dev or prd
# @param TOKEN_REPRICE_MODELS - required: the stored model names, comma separated (no default)
# @param TOKEN_REPRICE_FROM - required: the first minute, YYYY-MM-DD (UTC) or YYYY-MM-DDTHH:MM:SSZ (no default)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param TOKEN_REPRICE_SPOOL (optional) - the spool binary, default the state dir's
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd TOKEN_REPRICE_MODELS=claude-haiku-4-5-20251001,mistral-large TOKEN_REPRICE_FROM=2026-10-16 ./run -a do_spl_token_burn_reprice
# @example ENV=prd TOKEN_REPRICE_MODELS=claude-haiku-4-5-20251001,mistral-large TOKEN_REPRICE_FROM=2026-10-16 DRY_RUN=0 ./run -a do_spl_token_burn_reprice
#------------------------------------------------------------------------------
do_spl_token_burn_reprice() {
  do_require_bin jq python3 || return 1
  local dry=1 models="${TOKEN_REPRICE_MODELS:-}" from="${TOKEN_REPRICE_FROM:-}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_token_reprice_args "$models" "$from" || return 1
  do_spl_cloud_cnf || return 1
  local bin="${TOKEN_REPRICE_SPOOL:-}"
  if [[ -z "$bin" ]]; then
    spl_host_spool || return 1
    bin="$SPL_SPOOL"
  fi
  grep -q 'fleet-tokens-reprice' <<<"$("$bin" help 2>&1)" ||
    { do_log "FATAL $bin has no fleet-tokens-reprice verb: build it from origin/master (SPL_SPOOL_REBUILD=1) or set TOKEN_REPRICE_SPOOL"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_TR_BIN="$bin" SPL_TR_MODELS="$models" SPL_TR_FROM="$from" SPL_TR_DRY="$dry" spl_via_proxy _spl_token_reprice_run
}

# spl_token_reprice_args <models> <from> -> refuses an absent, empty, repeated
# or odd model name and a from that is not a UTC date or a Z timestamp.
spl_token_reprice_args() {
  local models="$1" from="$2" m
  [[ -n "$models" ]] || { do_log "FATAL TOKEN_REPRICE_MODELS is required (no default), e.g. claude-haiku-4-5-20251001,mistral-large"; return 1; }
  [[ -n "$from" ]] || { do_log "FATAL TOKEN_REPRICE_FROM is required (no default), e.g. 2026-10-16"; return 1; }
  local -A seen=()
  local -a list=()
  IFS=, read -r -a list <<<"$models"
  [[ "${models: -1}" != , && ${#list[@]} -gt 0 ]] || { do_log "FATAL TOKEN_REPRICE_MODELS has an empty name: '$models'"; return 1; }
  for m in "${list[@]}"; do
    [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}(\[[0-9a-z]{1,8}\])?$ ]] ||
      { do_log "FATAL TOKEN_REPRICE_MODELS: bad model name '$m'"; return 1; }
    [[ -z "${seen[$m]:-}" ]] || { do_log "FATAL TOKEN_REPRICE_MODELS names '$m' twice"; return 1; }
    seen[$m]=1
  done
  [[ "$from" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9](T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z)?$ ]] ||
    { do_log "FATAL TOKEN_REPRICE_FROM must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (UTC), got: '$from'"; return 1; }
}

# _spl_token_reprice_run -> runs the verb with the DSN of $SPL_PROXY_DSN in its
# environment (never argv) and prints one line per model.
_spl_token_reprice_run() {
  local out rc=0 write=()
  [[ "$SPL_TR_DRY" == 0 ]] && write=(--write)
  out="$(SPOOL_HUB_DB_DSN="$SPL_PROXY_DSN" "$SPL_TR_BIN" fleet-tokens-reprice --models "$SPL_TR_MODELS" \
    --from "$SPL_TR_FROM" "${write[@]}" 2>&1)" || rc=$?
  if ((rc)) || ! jq -e '.models | type == "array"' >/dev/null 2>&1 <<<"$out"; then
    do_log "FATAL fleet-tokens-reprice failed on $ENV (rc $rc), nothing written: $(head -c 300 <<<"$out")"
    return 1
  fi
  spl_token_reprice_report "$out" "$SPL_TR_DRY"
}

# spl_token_reprice_report <json> <dry> -> the per-model lines; fails when a
# committed run leaves a model with an unpriced minute.
spl_token_reprice_report() {
  local json="$1" dry="$2" verb=priced left
  ((dry)) && verb=would_price
  jq -r --arg v "$verb" '.models[] | "\(.model) unpriced_before=\(.unpriced_before) \($v)=\(.priced) cost_usd=\((.cost_micros | tonumber) / 1e6) unpriced_after=\(.unpriced_after)"' <<<"$json" |
    while IFS= read -r l; do do_log "INFO $ENV $l"; done
  left="$(jq '[.models[].unpriced_after] | add' <<<"$json")"
  if ((dry)); then
    do_log "OK DRY_RUN $ENV from $(jq -r .from <<<"$json"): rolled back, nothing written; $left minute(s) would stay unpriced. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$left" != 0 ]]; then
    do_log "FAIL $ENV committed, but $left minute(s) found no price (a model_prices row is missing)"
    return 1
  fi
  do_log "OK $ENV committed: 0 unpriced minutes left for $SPL_TR_MODELS from $(jq -r .from <<<"$json"); rolled_days=$(jq -r .rolled_days <<<"$json") (${GCP_ACCOUNT:-})"
}
