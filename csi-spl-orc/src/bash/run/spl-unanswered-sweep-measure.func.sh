#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY latency of do_spl_unanswered_sweep's hub statement
# @description (api perf round d-02): the sweep's own text
# @description (_spl_sweep_rows_sql, never a hand copy) run MEASURE_N times as
# @description EXPLAIN (ANALYZE) in the sweep's frame - a READ ONLY transaction,
# @description operator row-level-security scope, as the env SA. Prints p50 /
# @description p95 / max of Postgres' own Execution Time. MEASURE_REF_SQL names
# @description a second statement (e.g. the previous text, from git show) run
# @description interleaved with it, so a before/after pair sees the same cache.
# @param ENV - required: dev or prd
# @param MEASURE_N (optional) - samples per statement, 3..50, default 20
# @param MEASURE_REF_SQL (optional) - a file holding a reference statement (psql variable :days)
# @param MEASURE_PLANS (optional) - 1 also prints one EXPLAIN (ANALYZE, BUFFERS) per statement
# @param SWEEP_DAYS (optional) - the sweep's lookback, default 7
# @example ENV=dev MEASURE_N=20 ./run -a do_spl_unanswered_sweep_measure
# @example ENV=prd MEASURE_N=20 MEASURE_PLANS=1 ./run -a do_spl_unanswered_sweep_measure
# @example ENV=dev MEASURE_REF_SQL=/tmp/old.sql ./run -a do_spl_unanswered_sweep_measure
#------------------------------------------------------------------------------
do_spl_unanswered_sweep_measure() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  do_require_bin yq psql python3 || return 1
  local script rc
  script="$(mktemp)" || return 1
  spl_sweep_measure_sql "${MEASURE_N:-20}" "${MEASURE_REF_SQL:-}" "${MEASURE_PLANS:-0}" >"$script" &&
    do_spl_cloud_cnf && do_gcp_pin_account "$SPL_CNF" && do_gcp_require_live_account "$GCP_ACCOUNT" &&
    spl_via_proxy _spl_sweep_measure_run "$script"
  rc=$?
  rm -f "$script"
  return $rc
}

# spl_sweep_measure_sql <n> <ref sql file> <plans> -> the psql script: one
# read-only operator transaction, the statements interleaved n times.
spl_sweep_measure_sql() {
  local n="$1" ref="$2" plans="$3" i name days="${SWEEP_DAYS:-7}"
  [[ "$n" =~ ^[0-9]{1,2}$ ]] && ((n >= 3 && n <= 50)) || { do_log "FATAL MEASURE_N must be 3..50, got: $n" >&2; return 1; }
  [[ "$days" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL SWEEP_DAYS must be a positive integer, got: $days" >&2; return 1; }
  [[ -z "$ref" || -s "$ref" ]] || { do_log "FATAL MEASURE_REF_SQL $ref is missing or empty" >&2; return 1; }
  local -A text=([sweep]="$(_spl_sweep_rows_sql)")
  local -a names=(sweep)
  [[ -n "$ref" ]] && { text[ref]="$(sed 's/;[[:space:]]*$//' "$ref")"; names+=(ref); }
  echo "\\set days $days"
  echo "BEGIN READ ONLY;"
  echo "SET LOCAL app.rls_scope = 'operator';"
  if [[ "$plans" == 1 ]]; then
    for name in "${names[@]}"; do
      echo "\\echo @@plan $name"
      echo "EXPLAIN (ANALYZE, BUFFERS) ${text[$name]};"
    done
  fi
  for ((i = 0; i < n; i++)); do
    for name in "${names[@]}"; do
      echo "\\echo @@ $name"
      echo "EXPLAIN (ANALYZE, FORMAT JSON) ${text[$name]};"
    done
  done
  echo "ROLLBACK;"
}

# Inside spl_via_proxy: run the script, print the plans and the summary.
_spl_sweep_measure_run() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -f "$1" | spl_sweep_measure_summary
}

# stdin: the script's output -> the @@plan blocks as they are, then one line
# per statement: <name> n=<n> p50=<ms> p95=<ms> max=<ms>.
spl_sweep_measure_summary() {
  python3 -c '
import json, sys
name, buf, plan, ms, order = None, [], False, {}, []
def flush():
    if name and not plan and buf:
        if name not in ms:
            ms[name] = []; order.append(name)
        ms[name].append(json.loads("".join(buf))[0]["Execution Time"])
for line in sys.stdin:
    if line.startswith("@@"):
        flush(); f = line.split(); buf = []
        plan, name = f[0] == "@@plan", f[-1]
        if plan:
            print(line, end="")
    elif plan:
        print(line, end="")
    else:
        buf.append(line)
flush()
for n in order:
    v = sorted(ms[n]); k = len(v)
    print("%s n=%d p50=%.1f p95=%.1f max=%.1f ms" % (n, k, v[(k - 1) // 2], v[-(-k * 95 // 100) - 1], v[-1]))'
}
