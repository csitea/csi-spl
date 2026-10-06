#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the rdb 0135 invariant while search_sig is the search
# @description fallback (spec 100 section 5.2, T010). Every signed message's
# @description stored search_sig must equal spool_search_sig(search_tsv) as
# @description this server computes it now: hashtext is not documented as
# @description stable across Postgres major versions, and a drift makes silent
# @description false negatives in search. Counts the rows that differ; prints
# @description one line "mismatched=<n>". Exit 0 when n = 0, 1 when n > 0 or
# @description on any error. Runs after "Apply DB migrations" in the hub
# @description deploy (20) and after a Postgres upgrade. Removed by T013.
# @description Identity as do_spl_db_bootstrap: GCP_ACCOUNT (the CI deploy SA)
# @description or the env's project SA key (do_gcp_pin_account). Reads as the
# @description runtime login over the Cloud SQL Auth Proxy, psql in BEGIN READ
# @description ONLY with the operator row-level-security scope (spl_psql_ro).
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_search_sig_check
# @example ENV=prd ./run -a do_spl_search_sig_check
#------------------------------------------------------------------------------
do_spl_search_sig_check() {
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  if [[ "$(do_spl_cloud_provider)" != none ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_require_bin gcloud || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  local dsn rc=0
  spl_db_runtime_local || return 1
  _spl_search_sig_check_query || rc=$?
  unset dsn
  return "$rc"
}

# _spl_search_sig_check_query -> the read, once $dsn is the local login.
# Stops the proxy; the verdict's exit is this function's.
_spl_search_sig_check_query() {
  local out qrc
  out="$(spl_psql_ro "$dsn" "$(spl_search_sig_check_sql)")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  spl_search_sig_check_verdict "$out"
}

# spl_search_sig_check_sql -> the spec 5.2 invariant query, bounded so a deploy
# step cannot hang on it. A read: no row is locked or written.
spl_search_sig_check_sql() {
  cat <<'EOF_SQL'
SET LOCAL statement_timeout = '120s';
SELECT count(*) FROM messages WHERE search_sig IS NOT NULL AND search_sig <> spool_search_sig(search_tsv);
EOF_SQL
}

# spl_search_sig_check_verdict <psql output> -> exit 0 when the count is 0,
# 1 when it is above 0 or not a count, with one log line.
spl_search_sig_check_verdict() {
  local n="${1//[[:space:]]/}"
  [[ "$n" =~ ^[0-9]+$ ]] || { do_log "FATAL the invariant query returned no count: $1"; return 1; }
  printf 'mismatched=%s\n' "$n"
  if (( 10#$n > 0 )); then
    do_log "FAIL $n message(s) in $SPL_PROJECT/$SPL_DB_NAME carry a search_sig that differs from spool_search_sig(search_tsv): rdb 0135 search misses them (hashtext drift?)"
    return 1
  fi
  do_log "OK every search_sig in $SPL_PROJECT/$SPL_DB_NAME equals spool_search_sig(search_tsv) (read-only, as ${GCP_ACCOUNT:-the local login})"
}
