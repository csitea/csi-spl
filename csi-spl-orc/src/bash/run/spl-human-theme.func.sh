#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one human's preferred_theme (rdb 0057) in a cloud env's hub
# @description DB, through the Cloud SQL proxy as the env's project service
# @description account. humans is hub-wide and outside row level security
# @description (0014, 0017), so the statement has no tenant scope. Values
# @description travel as psql variables (:'var'), never spliced into the SQL.
# @description Exactly one row must change, or the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param HUMAN_ID - required: e.g. HUM-4
# @param THEME - required: dark, light, light-violet, light-green, or
# @param   light-yellow. light is the light-blue palette. Compared lower-cased.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd HUMAN_ID=HUM-4 THEME=light DRY_RUN=0 ./run -a do_spl_human_theme
#------------------------------------------------------------------------------
do_spl_human_theme() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local human="${HUMAN_ID:-}" theme="${THEME:-}" dry=1
  # rdb 0057 humans_preferred_theme_check, in that order. A new theme is a migration first.
  local themes='dark|light|light-violet|light-green|light-yellow'
  [[ "$human" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  theme="${theme,,}"
  [[ "$theme" =~ ^($themes)$ ]] || { do_log "FATAL THEME must be one of the palette themes (dark, light, light-violet, light-green, light-yellow). light is the light-blue palette ($themes), got: '${THEME:-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set preferred_theme of $human to $theme on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_human_theme_run "$human" "$theme"
}

_spl_human_theme_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v human="$1" -v theme="$2" <<'SQL'
BEGIN;
UPDATE humans SET preferred_theme = :'theme'
 WHERE human_id = :'human'
RETURNING format('%s | %s', human_id, preferred_theme);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL theme update of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched $1: rolled back"; return 1; }
  do_log "OK $1 preferred_theme is now $2 ($GCP_ACCOUNT): $out"
}
