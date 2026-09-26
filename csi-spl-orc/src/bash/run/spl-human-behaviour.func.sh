#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one human's Settings -> Behaviour choices in a cloud env's
# @description hub DB: "Text fields" humans.submit_key (rdb 0062, SPL-976)
# @description and/or "Left panel order" humans.rail_order (rdb 0063, 0064,
# @description SPL-979, SPL-983), through the Cloud SQL proxy as the env's project
# @description service account. humans is hub-wide and outside row level
# @description security (0014, 0017), so the statement has no tenant scope.
# @description Values travel as psql variables (:'var'), never spliced into
# @description the SQL; a key that is not given keeps its stored value.
# @description Exactly one row must change, or the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param HUMAN_ID - required: e.g. HUM-4
# @param SUBMIT_KEY - enter (Enter sends, Shift+Enter adds a line) or
# @param   ctrl-enter (Enter adds a line, Ctrl/Cmd+Enter sends). Lower-cased.
# @param RAIL_ORDER - the seven rail ids, comma separated, each once:
# @param   dm,channels,issues,topics,flow,events,archive in any order. Lower-cased.
# @param   At least one of SUBMIT_KEY and RAIL_ORDER is required.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd HUMAN_ID=HUM-4 SUBMIT_KEY=ctrl-enter DRY_RUN=0 ./run -a do_spl_human_behaviour
# @example ENV=dev HUMAN_ID=HUM-4 RAIL_ORDER=topics,dm,channels,issues,flow,events,archive ./run -a do_spl_human_behaviour
#------------------------------------------------------------------------------
do_spl_human_behaviour() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local human="${HUMAN_ID:-}" key="${SUBMIT_KEY:-}" rail="${RAIL_ORDER:-}" dry=1
  # rdb 0062 humans_submit_key_check, in that order. A new choice is a migration first.
  local keys='enter|ctrl-enter'
  # rdb 0064 humans_rail_order_check: each of these once, in the default order.
  local rail_ids='dm,channels,issues,topics,flow,events,archive'
  [[ "$human" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  [[ -n "$key" || -n "$rail" ]] || { do_log "FATAL set SUBMIT_KEY (enter or ctrl-enter) and/or RAIL_ORDER ($rail_ids in any order)"; return 1; }
  key="${key,,}"
  if [[ -n "$key" ]]; then
    [[ "$key" =~ ^($keys)$ ]] || { do_log "FATAL SUBMIT_KEY must be enter (Enter sends) or ctrl-enter (Ctrl+Enter sends) ($keys), got: '${SUBMIT_KEY:-}'"; return 1; }
  fi
  rail="${rail,,}"
  if [[ -n "$rail" ]]; then
    [[ "$rail" =~ ^[a-z]+(,[a-z]+){6}$ ]] \
      && [[ "$(tr ',' '\n' <<<"$rail" | sort | paste -sd,)" == "$(tr ',' '\n' <<<"$rail_ids" | sort | paste -sd,)" ]] \
      || { do_log "FATAL RAIL_ORDER must hold each of $rail_ids exactly once, got: '${RAIL_ORDER:-}'"; return 1; }
  fi
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local plan=""
  [[ -n "$key" ]] && plan+=" submit_key=$key"
  [[ -n "$rail" ]] && plan+=" rail_order=$rail"
  if (( dry )); then
    do_log "OK DRY_RUN would set$plan of $human on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local arr=""
  [[ -n "$rail" ]] && arr="{$rail}"
  spl_via_proxy _spl_human_behaviour_run "$human" "$key" "$arr" "$plan"
}

_spl_human_behaviour_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v human="$1" -v submit_key="$2" -v rail="$3" <<'SQL'
BEGIN;
UPDATE humans SET submit_key = COALESCE(NULLIF(:'submit_key', ''), submit_key),
                  rail_order = COALESCE(NULLIF(:'rail', '')::text[], rail_order)
 WHERE human_id = :'human'
RETURNING format('%s | %s | %s', human_id, submit_key, array_to_string(rail_order, ','));
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL behaviour update of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched $1: rolled back"; return 1; }
  do_log "OK $1 now has$4 ($GCP_ACCOUNT): $out"
}
