#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one human's Settings -> Behaviour "Text fields" choice,
# @description humans.submit_key (rdb 0062, SPL-976), in a cloud env's hub DB,
# @description through the Cloud SQL proxy as the env's project service
# @description account. humans is hub-wide and outside row level security
# @description (0014, 0017), so the statement has no tenant scope. Values
# @description travel as psql variables (:'var'), never spliced into the SQL.
# @description Exactly one row must change, or the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param HUMAN_ID - required: e.g. HUM-4
# @param SUBMIT_KEY - required: enter (Enter sends, Shift+Enter adds a line)
# @param   or ctrl-enter (Enter adds a line, Ctrl/Cmd+Enter sends). Compared
# @param   lower-cased.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd HUMAN_ID=HUM-4 SUBMIT_KEY=ctrl-enter DRY_RUN=0 ./run -a do_spl_human_behaviour
#------------------------------------------------------------------------------
do_spl_human_behaviour() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local human="${HUMAN_ID:-}" key="${SUBMIT_KEY:-}" dry=1
  # rdb 0062 humans_submit_key_check, in that order. A new choice is a migration first.
  local keys='enter|ctrl-enter'
  [[ "$human" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  key="${key,,}"
  [[ "$key" =~ ^($keys)$ ]] || { do_log "FATAL SUBMIT_KEY must be enter (Enter sends) or ctrl-enter (Ctrl+Enter sends) ($keys), got: '${SUBMIT_KEY:-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set submit_key of $human to $key on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_human_behaviour_run "$human" "$key"
}

_spl_human_behaviour_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v human="$1" -v submit_key="$2" <<'SQL'
BEGIN;
UPDATE humans SET submit_key = :'submit_key'
 WHERE human_id = :'human'
RETURNING format('%s | %s', human_id, submit_key);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL submit_key update of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched $1: rolled back"; return 1; }
  do_log "OK $1 submit_key is now $2 ($GCP_ACCOUNT): $out"
}
