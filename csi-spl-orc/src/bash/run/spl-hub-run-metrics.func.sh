#!/bin/bash
# do_spl_hub_run_metrics: the Cloud Run side of the same window (SPL-1981),
# per minute: instances by state, the p99 / max of requests in flight per
# instance (a WebSocket holds one for its life), and the p99 CPU. Read-only:
# the Monitoring v3 timeSeries REST endpoint (gcloud has no verb for it, see
# spl_db_health_metrics) with an access token for the env SA in a 0600 -K file.
# @param ENV, REQ_SINCE, REQ_MINUTES as do_spl_hub_request_minutes
# @example ENV=prd REQ_SINCE=2026-10-15T07:15:00Z REQ_MINUTES=25 ./run -a do_spl_hub_run_metrics
do_spl_hub_run_metrics() {
  local since="${REQ_SINCE:-}" minutes="${REQ_MINUTES:-30}"
  spl_hub_request_minutes_check_args "$since" "$minutes" 1 1 || return 1
  do_require_bin gcloud curl python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local svc until tok hdr spec rc=0
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL env.hub.service_name is not set in $SPL_CNF"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  until="$(date -u -d "$since + $minutes minutes" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || { do_log "ERROR no access token for $GCP_ACCOUNT"; return 1; }
  hdr="$(mktemp)" || return 1
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$hdr"; )
  printf '===== csi-spl hub run metrics: env=%s service=%s (%s .. %s)\n' "$ENV" "$svc" "$since" "$until"
  for spec in "container/instance_count ALIGN_MAX state" \
              "container/max_request_concurrencies ALIGN_PERCENTILE_99 -" \
              "container/cpu/utilizations ALIGN_PERCENTILE_99 -" \
              "request_count ALIGN_SUM response_code_class"; do
    set -- $spec
    echo "--- $1 ($2 per minute${3/#-/}${3:+ by $3})"
    curl -s --connect-timeout 10 --max-time 30 -G "https://monitoring.googleapis.com/v3/projects/$SPL_PROJECT/timeSeries" \
      -K "$hdr" \
      --data-urlencode "filter=metric.type=\"run.googleapis.com/$1\" AND resource.labels.service_name=\"$svc\"" \
      --data-urlencode "interval.startTime=$since" --data-urlencode "interval.endTime=$until" \
      --data-urlencode "aggregation.alignmentPeriod=60s" --data-urlencode "aggregation.perSeriesAligner=$2" |
      spl_hub_run_metrics_table "$3" || rc=1
  done
  rm -f "$hdr"
  return $rc
}

# spl_hub_run_metrics_table <label|-> -> a Monitoring v3 timeSeries response on
# stdin as one line per minute, one column per series (named by that metric
# label, or by the revision when the label is -).
spl_hub_run_metrics_table() {
  python3 -c '
import json, sys
lab = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if "error" in d:
    print("error: %s" % d["error"].get("message", d["error"])); sys.exit(1)
cols, rows = [], {}
for s in d.get("timeSeries", []):
    ml, rl = s.get("metric", {}).get("labels", {}), s.get("resource", {}).get("labels", {})
    name = ml.get(lab, "?") if lab != "-" else rl.get("revision_name", "?")[-9:]
    if name not in cols:
        cols.append(name)
    for p in s.get("points", []):
        v = p.get("value", {})
        val = v.get("int64Value", v.get("doubleValue"))
        if val is not None:
            r = rows.setdefault(p["interval"]["endTime"][11:16], {})
            r[name] = r.get(name, 0.0) + float(val)
if not rows:
    print("no points in the window"); sys.exit(0)
print("%5s " % "min" + " ".join("%12s" % c[:12] for c in cols))
for k in sorted(rows):
    print("%5s " % k + " ".join("%12s" % ("%.2f" % rows[k][c] if c in rows[k] else "-") for c in cols))
' "$1"
}
