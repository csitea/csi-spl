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
# @description The full compare is a ~2.4 s scan that holds 1 of the hub's 4
# @description pool slots (perf round 5 row P5-05), so it runs only when the
# @description server's fingerprint "<Postgres major>:<md5 of spool_search_sig's
# @description definition>" differs from the one the last full compare passed
# @description on (SPL_SEARCH_SIG_PASSED_ON). An equal fingerprint prints
# @description "mismatched=skipped" and exits 0; a full pass on a new one logs
# @description the value to record below.
# @description Identity as do_spl_db_bootstrap: GCP_ACCOUNT (the CI deploy SA)
# @description or the env's project SA key (do_gcp_pin_account). Reads as the
# @description runtime login over the Cloud SQL Auth Proxy, psql in BEGIN READ
# @description ONLY with the operator row-level-security scope (spl_psql_ro).
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @param SPL_SEARCH_SIG_PASSED_ON (optional) - the fingerprint the last full compare passed on, default: SPL_SEARCH_SIG_PASSED_ON_RECORDED
# @param SPL_SEARCH_SIG_FULL (optional) - 1 runs the full compare whatever the fingerprint
# @example ENV=dev ./run -a do_spl_search_sig_check
# @example ENV=prd ./run -a do_spl_search_sig_check
# @example ENV=prd SPL_SEARCH_SIG_FULL=1 ./run -a do_spl_search_sig_check
#------------------------------------------------------------------------------

# The fingerprint the last full compare passed on: dev and prd, mismatched=0,
# 2026-10-12 (SPL_SEARCH_SIG_FULL=1). A Postgres major upgrade or a new
# spool_search_sig changes the live one, and every deploy runs the full
# compare until its passing value is recorded here.
SPL_SEARCH_SIG_PASSED_ON_RECORDED='16:b38c7d65d8beff4b544b665e870136d7'

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
  local out qrc record="${SPL_SEARCH_SIG_PASSED_ON-$SPL_SEARCH_SIG_PASSED_ON_RECORDED}" passed=""
  [[ "${SPL_SEARCH_SIG_FULL:-0}" == 1 ]] || passed="$record"
  out="$(spl_psql_ro "$dsn" "$(spl_search_sig_check_sql "$passed")")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  spl_search_sig_check_verdict "$out" "$record"
}

# spl_search_sig_check_sql [passed fingerprint] -> the spec 5.2 invariant
# query, bounded so a deploy step cannot hang on it, behind the fingerprint
# gate. Prints "skipped <fp>" when the live fingerprint equals the passed one,
# else "fp <fp>" and the count. A value not of the fingerprint's form never
# reaches the SQL and never matches. A read: no row is locked or written.
spl_search_sig_check_sql() {
  local passed="$1"
  [[ "$passed" =~ ^[0-9]+:[0-9a-f]{32}$ ]] || passed=none
  cat <<EOF_SQL
SET LOCAL statement_timeout = '120s';
SELECT (current_setting('server_version_num')::int / 10000)::text || ':' || md5(pg_get_functiondef('spool_search_sig(tsvector)'::regprocedure)) AS sig_fp \gset
SELECT (:'sig_fp' = '$passed') AS sig_same \gset
\if :sig_same
SELECT 'skipped ' || :'sig_fp';
\else
SELECT 'fp ' || :'sig_fp';
SELECT count(*) FROM messages WHERE search_sig IS NOT NULL AND search_sig <> spool_search_sig(search_tsv);
\endif
EOF_SQL
}

# spl_search_sig_check_verdict <psql output> [recorded fingerprint] -> exit 0
# when the compare was skipped or its count is 0, 1 when the count is above 0
# or not a count, with one log line.
spl_search_sig_check_verdict() {
  local head fp n
  head="$(sed -n 1p <<<"$1")"
  fp="${head#* }"
  if [[ "$head" =~ ^skipped\ [0-9]+:[0-9a-f]{32}$ ]]; then
    printf 'mismatched=skipped fp=%s\n' "$fp"
    do_log "OK search_sig full compare skipped in $SPL_PROJECT/$SPL_DB_NAME: it passed on this fingerprint ($fp, Postgres major:spool_search_sig md5); SPL_SEARCH_SIG_FULL=1 forces it"
    return 0
  fi
  [[ "$head" =~ ^fp\ [0-9]+:[0-9a-f]{32}$ ]] || { do_log "FATAL the invariant query returned no fingerprint: $1"; return 1; }
  n="$(sed -n 2p <<<"$1")"
  n="${n//[[:space:]]/}"
  [[ "$n" =~ ^[0-9]+$ ]] || { do_log "FATAL the invariant query returned no count: $1"; return 1; }
  printf 'mismatched=%s fp=%s\n' "$n" "$fp"
  if (( 10#$n > 0 )); then
    do_log "FAIL $n message(s) in $SPL_PROJECT/$SPL_DB_NAME carry a search_sig that differs from spool_search_sig(search_tsv): rdb 0135 search misses them (hashtext drift?)"
    return 1
  fi
  do_log "OK every search_sig in $SPL_PROJECT/$SPL_DB_NAME equals spool_search_sig(search_tsv) (read-only, as ${GCP_ACCOUNT:-the local login})"
  [[ "$fp" == "$2" ]] ||
    do_log "NOTE the full compare passed on fingerprint $fp, not the recorded one: record SPL_SEARCH_SIG_PASSED_ON_RECORDED='$fp' in spl-search-sig-check.func.sh to skip it on the next deploys"
}
