#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY top statements of a cloud env's hub DB from Cloud SQL
# @description Query Insights (spec 029 D1, on since 2026-09-21): the no-restart
# @description stand-in for pg_stat_statements when that is not installed.
# @description Reads the Monitoring v3 series
# @description database/postgresql/insights/perquery/latencies (a distribution:
# @description count = calls, mean = mean latency) over a window, summed per
# @description normalised query, and prints the top N by total time, by mean
# @description time and by calls. Query text arrives NORMALISED by Cloud SQL
# @description (literals replaced), so no tenant data is printed.
# @description Nothing is mutated: one token for the env SA, GETs only.
# @param ENV - required: dev or prd
# @param INSIGHTS_HOURS (optional) - window in hours, default 24 (max 168)
# @param INSIGHTS_TOP (optional) - rows per table, default 15
# @param INSIGHTS_WIDTH (optional) - query text width, default 110
# @example ENV=prd ./run -a do_spl_db_insights
# @example ENV=dev INSIGHTS_HOURS=168 INSIGHTS_TOP=25 ./run -a do_spl_db_insights
#------------------------------------------------------------------------------
do_spl_db_insights() {
  do_require_bin gcloud curl python3 yq || return 1
  local hours="${INSIGHTS_HOURS:-24}" top="${INSIGHTS_TOP:-15}" width="${INSIGHTS_WIDTH:-110}"
  spl_db_insights_check_args "$hours" "$top" "$width" || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local since until tok
  until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  since="$(date -u -d "$hours hours ago" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  printf '===== csi-spl db insights: env=%s project=%s instance=%s window=%sh (%s .. %s)\n' \
    "$ENV" "$SPL_PROJECT" "$SPL_SQL_INSTANCE" "$hours" "$since" "$until"
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || { do_log "FATAL no access token for $GCP_ACCOUNT"; return 1; }

  # One aligned point per series over the whole window: ALIGN_DELTA on a
  # cumulative distribution gives the calls and the latency sum inside it.
  curl -s -G "https://monitoring.googleapis.com/v3/projects/$SPL_PROJECT/timeSeries" \
    -H "Authorization: Bearer $tok" \
    --connect-timeout 10 --max-time 60 \
    --data-urlencode "filter=metric.type=\"cloudsql.googleapis.com/database/postgresql/insights/perquery/latencies\" AND resource.labels.resource_id=\"$SPL_PROJECT:$SPL_SQL_INSTANCE\"" \
    --data-urlencode "interval.startTime=$since" \
    --data-urlencode "interval.endTime=$until" \
    --data-urlencode "aggregation.alignmentPeriod=$((hours * 3600))s" \
    --data-urlencode "aggregation.perSeriesAligner=ALIGN_DELTA" \
    --data-urlencode "pageSize=100000" |
    spl_db_insights_table "$top" "$width"
}

# spl_db_insights_check_args <hours> <top> <width> -> 0 when all are sane.
spl_db_insights_check_args() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 168 )) ||
    { do_log "FATAL INSIGHTS_HOURS must be 1..168 (Query Insights keeps 7 days), got '$1'"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 )) || { do_log "FATAL INSIGHTS_TOP must be a positive integer, got '$2'"; return 1; }
  [[ "$3" =~ ^[0-9]+$ ]] && (( $3 >= 20 )) || { do_log "FATAL INSIGHTS_WIDTH must be >= 20, got '$3'"; return 1; }
}

# spl_db_insights_table <top> <width> -> a Monitoring v3 timeSeries body on
# stdin, summed per (querystring, user), printed as three tables: by total
# time, by mean time and by calls. Latencies are in microseconds; printed as ms.
spl_db_insights_table() {
  python3 -c '
import json, re, sys
top, width = int(sys.argv[1]), int(sys.argv[2])
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if "error" in d:
    print("error: %s" % d["error"].get("message", d["error"])); sys.exit(1)
agg = {}
for s in d.get("timeSeries", []):
    lab = s.get("metric", {}).get("labels", {})
    q = re.sub(r"\s+", " ", lab.get("querystring", "?")).strip()
    key = (q, lab.get("user", "?"))
    calls = total_us = 0.0
    for p in s.get("points", []):
        dv = p.get("value", {}).get("distributionValue", {})
        c = float(dv.get("count", 0) or 0)
        calls += c
        total_us += c * float(dv.get("mean", 0) or 0)
    if calls <= 0:
        continue
    a = agg.setdefault(key, [0.0, 0.0])
    a[0] += calls; a[1] += total_us
if not agg:
    print("no Query Insights points in the window"); sys.exit(0)
rows = [(q, u, c, t / 1000.0, t / 1000.0 / c) for (q, u), (c, t) in agg.items()]
all_ms = sum(r[3] for r in rows); all_calls = sum(r[2] for r in rows)
print("statements=%d calls=%d total_ms=%.1f" % (len(rows), all_calls, all_ms))
def table(title, key):
    print(); print("--- insights: top %d by %s" % (top, title))
    print("%10s %12s %9s %6s  %-12s %s" % ("calls", "total_ms", "mean_ms", "pct", "user", "query"))
    for q, u, c, t, m in sorted(rows, key=key, reverse=True)[:top]:
        print("%10d %12.1f %9.2f %5.1f%%  %-12s %s" % (c, t, m, 100.0 * t / all_ms if all_ms else 0, u[:12], q[:width]))
table("total time", lambda r: r[3])
table("mean time", lambda r: r[4])
table("calls", lambda r: r[2])
' "$1" "$2"
}
