#!/bin/bash
#------------------------------------------------------------------------------
# @description The nightly maintenance of a cloud env's hub DB, run inside the
# @description owner's window 01:00-05:00 Europe/Helsinki by workflow 47.
# @description Owner, t1 ea9dc09a msg d0aa6c7a: "what you are doing here should
# @description be done on a regular basis ... Emphasize running during the hours
# @description after 1:00 Helsinki time up till 5:00 Helsinki time. During this
# @description time, we can do much more maintenance and even allow some small
# @description availability breaks."
# @description
# @description One proxy session as the schema OWNER (only an owner may VACUUM
# @description or REINDEX a table), read through the env's project SA:
# @description   1. BEFORE snapshot: per table live/dead rows, rows changed since
# @description      the last analyze, last (auto)vacuum/analyze, heap and total
# @description      bytes, an estimated heap bloat; per index bytes, scans and an
# @description      estimated btree bloat; the top statements by mean time from
# @description      Query Insights (pg_stat_statements is not installed, 029 6.3).
# @description   2. the plan: VACUUM (ANALYZE) for a table past MAINT_DEAD_MIN dead
# @description      rows and MAINT_DEAD_PCT %, or with MAINT_DEAD_MIN changed rows
# @description      (and >= 10 % of it) since its last analyze, or MAINT_DEAD_MIN rows
# @description      never analyzed;
# @description      REINDEX INDEX CONCURRENTLY for a btree past MAINT_REINDEX_PCT %
# @description      estimated bloat and MAINT_REINDEX_MIN_MB. Neither blocks the
# @description      hub's reads or writes (SHARE UPDATE EXCLUSIVE).
# @description      VACUUM (FULL, ANALYZE) of a heap past MAINT_FULL_PCT % and
# @description      MAINT_FULL_MIN_MB takes an ACCESS EXCLUSIVE lock - a short
# @description      availability break of that table - so it runs ONLY with
# @description      MAINT_HEAVY=1 and ONLY inside the window, never forced.
# @description   3. AFTER snapshot, and one before/after report file.
# @description
# @description DRY_RUN=1 (default) reads, prints the plan and writes the report;
# @description it changes nothing and may run at any hour. DRY_RUN=0 outside the
# @description window is refused unless MAINT_FORCE=1. Every step runs (a
# @description failed one never holds back the rest) and any failure makes the
# @description action exit non-zero.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) plan only; 0 run it
# @param MAINT_FORCE (optional) - 1 lets DRY_RUN=0 run outside the window (not MAINT_HEAVY)
# @param MAINT_HEAVY (optional) - 1 also runs the VACUUM FULL steps (window only)
# @param MAINT_DEAD_MIN (optional) - rows, default 1000
# @param MAINT_DEAD_PCT (optional) - % dead of live+dead, default 5
# @param MAINT_REINDEX_PCT (optional) - % estimated index bloat, default 30
# @param MAINT_REINDEX_MIN_MB (optional) - MB, default 1
# @param MAINT_FULL_PCT (optional) - % estimated heap bloat, default 40
# @param MAINT_FULL_MIN_MB (optional) - MB, default 8
# @param MAINT_SAMPLE_ROWS (optional) - rows per width probe, default 2000
# @param MAINT_LOCK_TIMEOUT (optional) - default 5s
# @param MAINT_STATEMENT_TIMEOUT (optional) - default 30min
# @param MAINT_REPORT_DIR (optional) - default $SPL_STATE_DIR/db-maint
# @param MAINT_INSIGHTS (optional) - 1 (default) adds the Query Insights top 10
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_db_maint
# @example ENV=dev DRY_RUN=0 MAINT_FORCE=1 ./run -a do_spl_db_maint
# @example ENV=prd DRY_RUN=0 MAINT_HEAVY=1 ./run -a do_spl_db_maint
#------------------------------------------------------------------------------
do_spl_db_maint() {
  do_require_bin yq psql python3 || return 1
  spl_db_maint_check || return 1
  do_spl_cloud_cnf || return 1
  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  if [[ "$provider" != none ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  local owner_dsn user
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" ]] || { do_log "FATAL cannot read $SPL_OWNER_DSN_SECRET: VACUUM and REINDEX need the table owner"; return 1; }
  user="$(spl_dsn_user "$owner_dsn")"
  [[ "$user" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET logs in as '$user', not the owner $SPL_DB_OWNER_USER"; return 1; }

  local dir work report rc=0 pdsn
  dir="${MAINT_REPORT_DIR:-$SPL_STATE_DIR/db-maint}"
  mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  report="$dir/db-maint-$ENV-$(date -u +%Y%m%dT%H%M%SZ).txt"
  work="$(mktemp -d)" || return 1
  spl_sql_proxy_start || { rm -rf "$work"; return 1; }
  if pdsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")"; then
    spl_db_maint_run "$pdsn" "$work" "$provider" >"$report" 2>&1 || rc=$?
  else
    do_log "FATAL the owner DSN is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; rc=1
  fi
  spl_sql_proxy_stop
  rm -rf "$work"
  cat "$report"
  printf 'report=%s\n' "$report"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'report=%s\n' "$report" >>"$GITHUB_OUTPUT"
  if (( rc != 0 )); then do_log "ERROR $ENV db maint: a step failed (exit $rc), see $report"; return "$rc"; fi
  do_log "OK $ENV db maint done, report $report"
}

# spl_db_maint_run <owner proxy dsn> <work dir> <provider> -> the report body
# on stdout: snapshot, plan, steps, snapshot, before/after. Non-zero when a
# snapshot or a step failed.
spl_db_maint_run() {
  local dsn="$1" work="$2" provider="$3" rc=0 dry="${DRY_RUN:-1}"
  printf '===== csi-spl db maint: env=%s project=%s instance=%s db=%s utc=%s helsinki=%s dry_run=%s heavy=%s force=%s\n' \
    "$ENV" "${SPL_PROJECT:-}" "${SPL_SQL_INSTANCE:-}" "${SPL_DB_NAME:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(TZ=Europe/Helsinki date +%H:%M)" "$dry" "${MAINT_HEAVY:-0}" "${MAINT_FORCE:-0}"
  spl_db_maint_facts "$dsn" "$work/before" || { echo "FATAL the BEFORE snapshot failed"; return 1; }
  echo; echo "--- BEFORE"
  _spl_db_maint_py render "$work/before"
  if [[ "$provider" != none && "${MAINT_INSIGHTS:-1}" == 1 ]]; then
    echo; echo "--- BEFORE: top statements (Query Insights, last 24 h; ms per call)"
    INSIGHTS_HOURS=24 INSIGHTS_TOP=10 do_spl_db_insights 2>&1 | sed -n '/top 10 by mean time/,/^$/p' ||
      echo "(Query Insights not readable: not a failed step)"
  fi
  _spl_db_maint_py plan "$work/before" >"$work/plan" || { echo "FATAL the plan failed"; return 1; }
  echo; echo "--- PLAN (n=$(grep -cE '^(VACUUM|REINDEX|FULL)\|' "$work/plan") steps; HELD = needs MAINT_HEAVY=1 inside the window)"
  sed 's/|/  /g' "$work/plan"
  if [[ "$dry" == 1 ]]; then
    echo; echo "DRY_RUN=1: nothing was run. DRY_RUN=0 runs the steps above."
    return 0
  fi
  echo; echo "--- STEPS"
  spl_db_maint_steps "$dsn" "$work/plan" || rc=1
  spl_db_maint_facts "$dsn" "$work/after" || { echo "FATAL the AFTER snapshot failed"; return 1; }
  echo; echo "--- AFTER"
  _spl_db_maint_py render "$work/after"
  echo; echo "--- BEFORE -> AFTER"
  _spl_db_maint_py delta "$work/before" "$work/after"
  return $rc
}

# spl_db_maint_check -> the arguments and the window, before any cloud call.
spl_db_maint_check() {
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" v n
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 1; }
  for v in MAINT_FORCE MAINT_HEAVY MAINT_INSIGHTS; do
    [[ "${!v:-0}" == 0 || "${!v:-0}" == 1 ]] || { do_log "FATAL $v must be 0 or 1, got '${!v}'"; return 1; }
  done
  for v in MAINT_DEAD_MIN MAINT_DEAD_PCT MAINT_REINDEX_PCT MAINT_REINDEX_MIN_MB MAINT_FULL_PCT MAINT_FULL_MIN_MB MAINT_SAMPLE_ROWS; do
    n="${!v:-1}"
    [[ "$n" =~ ^[0-9]{1,7}$ ]] && (( n >= 1 )) || { do_log "FATAL $v must be a whole number >= 1, got '$n'"; return 1; }
  done
  [[ "${MAINT_LOCK_TIMEOUT:-5s}" =~ ^[0-9]+(ms|s)$ ]] ||
    { do_log "FATAL MAINT_LOCK_TIMEOUT must look like 5s or 500ms, got '$MAINT_LOCK_TIMEOUT'"; return 1; }
  [[ "${MAINT_STATEMENT_TIMEOUT:-30min}" =~ ^[0-9]+(s|min)$ ]] ||
    { do_log "FATAL MAINT_STATEMENT_TIMEOUT must look like 600s or 30min, got '$MAINT_STATEMENT_TIMEOUT'"; return 1; }
  [[ "$dry" == 1 ]] && return 0
  spl_db_maint_in_window && return 0
  if [[ "${MAINT_HEAVY:-0}" == 1 ]]; then
    do_log "FATAL MAINT_HEAVY=1 takes table locks: only inside 01:00-05:00 Europe/Helsinki (now $(spl_db_maint_hour):xx); MAINT_FORCE does not lift this"
    return 1
  fi
  [[ "${MAINT_FORCE:-0}" == 1 ]] && { do_log "WARN outside 01:00-05:00 Europe/Helsinki, running because MAINT_FORCE=1"; return 0; }
  do_log "FATAL DRY_RUN=0 runs only inside 01:00-05:00 Europe/Helsinki (now $(spl_db_maint_hour):xx); MAINT_FORCE=1 to run the non-blocking steps anyway"
  return 1
}

# spl_db_maint_hour -> the hour now in Europe/Helsinki, 00..23 (DST included).
spl_db_maint_hour() {
  TZ=Europe/Helsinki date +%H
}

# spl_db_maint_in_window -> 0 inside the owner's window, 01:00 to 05:00 Helsinki.
spl_db_maint_in_window() {
  local h
  h="$(spl_db_maint_hour)" || return 1
  [[ "$h" =~ ^[0-9]{2}$ ]] || return 1
  (( 10#$h >= 1 && 10#$h < 5 ))
}

# spl_db_maint_facts <dsn> <out> -> the snapshot's estimated facts in <out>
# (T and I rows, see _spl_db_maint_py). Read-only session, operator RLS scope.
spl_db_maint_facts() {
  local dsn="$1" out="$2" sql
  sql="$(dirname "${BASH_SOURCE[0]}")/../../sql/db-maint/facts.sql"
  [[ -f "$sql" ]] || { echo "FATAL missing $sql"; return 1; }
  { printf 'BEGIN READ ONLY;\nSET LOCAL app.rls_scope = '\''operator'\'';\n'; cat "$sql"; printf 'ROLLBACK;\n'; } |
    PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$dsn" psql -X -q -At -F'|' \
      -v ON_ERROR_STOP=1 -v sample="${MAINT_SAMPLE_ROWS:-2000}" -f - >"$out.raw" 2>"$out.err" ||
    { echo "psql: $(tr '\n' ' ' <"$out.err")"; return 1; }
  _spl_db_maint_py estimate "$out.raw" >"$out" || return 1
  grep -q '^T|' "$out" || { echo "FATAL the snapshot read no table"; return 1; }
}

# spl_db_maint_stmt <kind> <schema> <name> -> the SQL of one plan step. The
# names come from the catalog and are refused unless plain lower-case
# identifiers, so the quoting below is exact.
spl_db_maint_stmt() {
  local re='^[a-z_][a-z0-9_]{0,62}$'
  [[ "$2" =~ $re && "$3" =~ $re ]] || return 1
  case "$1" in
    VACUUM) printf 'VACUUM (ANALYZE) "%s"."%s"' "$2" "$3" ;;
    REINDEX) printf 'REINDEX INDEX CONCURRENTLY "%s"."%s"' "$2" "$3" ;;
    FULL) printf 'VACUUM (FULL, ANALYZE) "%s"."%s"' "$2" "$3" ;;
    *) return 1 ;;
  esac
}

# spl_db_maint_steps <dsn> <plan> -> runs every VACUUM, REINDEX and (heavy)
# FULL line of the plan, each its own psql with lock and statement timeouts
# (VACUUM and REINDEX CONCURRENTLY cannot run inside a transaction block).
# Prints one line per step: OK|FAILED, seconds, the statement.
spl_db_maint_steps() {
  local dsn="$1" kind schema name _ stmt t0 n=0 bad=0 err
  err="$(mktemp)" || return 1
  while IFS='|' read -r kind schema name _; do
    [[ "$kind" == VACUUM || "$kind" == REINDEX || "$kind" == FULL ]] || continue
    stmt="$(spl_db_maint_stmt "$kind" "$schema" "$name")" ||
      { echo "FAILED      0 s  refused name $schema.$name"; bad=$((bad + 1)); continue; }
    n=$((n + 1)); t0=$SECONDS
    if spl_pg_env "$dsn" psql -X -q -v ON_ERROR_STOP=1 \
         -c "SET lock_timeout = '${MAINT_LOCK_TIMEOUT:-5s}'" \
         -c "SET statement_timeout = '${MAINT_STATEMENT_TIMEOUT:-30min}'" \
         -c "$stmt" >/dev/null 2>"$err"; then
      printf 'OK     %6s s  %s\n' "$((SECONDS - t0))" "$stmt"
    else
      bad=$((bad + 1))
      printf 'FAILED %6s s  %s: %s\n' "$((SECONDS - t0))" "$stmt" "$(tr '\n' ' ' <"$err")"
      [[ "$kind" == REINDEX ]] && echo "       a failed REINDEX CONCURRENTLY can leave an INVALID ${name}_ccnew index: see the AFTER indexes"
    fi
  done <"$2"
  rm -f "$err"
  echo "steps run n=$n, failed n=$bad"
  (( bad == 0 ))
}

# _spl_db_maint_py <estimate raw | plan facts | render facts | delta before after>
# -> src/bash/scripts/db-maint.py (the estimate, the plan and the report tables).
_spl_db_maint_py() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/../scripts/db-maint.py" "$@"
}
