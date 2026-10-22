#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY view of the hub's Cloud SQL instance over one window
# @description (SPL-2880): is a stall our load on a too-small tier (CPU cap,
# @description memory, swap) or the platform's storage? Per Cloud Monitoring
# @description series the window's n / min / p50 / mean / p95 / max, aligned
# @description per DBW_STEP seconds: CPU and reserved cores, memory and its
# @description components, swap, disk ops / bytes / utilization, transactions,
# @description backends, backends in wait by wait event type, blocks read by
# @description source. Then the Postgres log of the window: the checkpoint
# @description lines (write, sync, total, longest file sync) and the
# @description statement timeouts. Put a stall window next to a quiet one of
# @description the same length to read it.
# @description Nothing is mutated: the Monitoring v3 timeSeries GET (gcloud has
# @description no verb for it, see spl_db_health_metrics) with a token for the
# @description env SA in a 0600 -K file, and one `gcloud logging read`; or no
# @description cloud call at all when DBW_JSON_IN names a saved read.
# @param ENV - required: dev or prd
# @param DBW_SINCE - required: RFC 3339 UTC start, e.g. 2026-10-22T09:20:00Z
# @param DBW_MINUTES (optional) - window length in minutes, default 60 (1..1440)
# @param DBW_STEP (optional) - alignment period in seconds, default 60 (60..3600)
# @param DBW_PART (optional) - all (default) | metrics | log
# @param DBW_LOG_LIMIT (optional) - Postgres log entries read at most, default 20000
# @param DBW_JSON_OUT (optional) - also save the raw reads into this directory
# @param DBW_JSON_IN (optional) - summarise the reads saved in this directory
# @example ENV=prd DBW_SINCE=2026-10-22T09:20:00Z DBW_MINUTES=55 ./run -a do_spl_db_window
# @example ENV=prd DBW_SINCE=2026-10-21T09:20:00Z DBW_MINUTES=55 DBW_PART=log ./run -a do_spl_db_window
#------------------------------------------------------------------------------
do_spl_db_window() {
  local since="${DBW_SINCE:-}" minutes="${DBW_MINUTES:-60}" step="${DBW_STEP:-60}"
  local part="${DBW_PART:-all}" limit="${DBW_LOG_LIMIT:-20000}"
  spl_db_window_check_args "$since" "$minutes" "$step" "$part" "$limit" || return 1
  local until rc=0
  until="$(date -u -d "$since + $minutes minutes" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [[ -n "${DBW_JSON_IN:-}" ]]; then
    [[ -d "$DBW_JSON_IN" ]] || { do_log "FATAL DBW_JSON_IN=$DBW_JSON_IN is not a directory"; return 1; }
    printf '===== csi-spl db window (saved read %s): %s .. %s\n' "$DBW_JSON_IN" "$since" "$until"
    spl_db_window_report "$DBW_JSON_IN" "$part" "$limit"
    return
  fi
  do_require_bin gcloud curl python3 yq || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local dir="${DBW_JSON_OUT:-}"
  if [[ -n "$dir" ]]; then mkdir -p "$dir" || return 1; else dir="$(mktemp -d)" || return 1; fi
  printf '===== csi-spl db window: env=%s project=%s instance=%s (%s .. %s, step %ss)\n' \
    "$ENV" "$SPL_PROJECT" "$SPL_SQL_INSTANCE" "$since" "$until" "$step"
  if [[ "$part" != log ]]; then
    spl_db_window_fetch_metrics "$dir" "$since" "$until" "$step" || rc=1
  fi
  if [[ "$part" != metrics ]]; then
    gcloud logging read "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"$SPL_PROJECT:$SPL_SQL_INSTANCE\" AND (textPayload:\"checkpoint complete\" OR textPayload:\"statement timeout\") AND timestamp>=\"$since\" AND timestamp<\"$until\"" \
      --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --limit="$limit" --format=json >"$dir/log.json" || rc=1
  fi
  spl_db_window_report "$dir" "$part" "$limit" || rc=1
  [[ -n "${DBW_JSON_OUT:-}" ]] || rm -rf "$dir"
  return $rc
}

# spl_db_window_check_args <since> <minutes> <step> <part> <limit> -> 0 when sane.
spl_db_window_check_args() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    { do_log "FATAL DBW_SINCE must be RFC 3339 UTC (YYYY-MM-DDThh:mm:ssZ), got '$1'"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 1440 )) || { do_log "FATAL DBW_MINUTES must be 1..1440, got '$2'"; return 1; }
  [[ "$3" =~ ^[0-9]+$ ]] && (( $3 >= 60 && $3 <= 3600 )) || { do_log "FATAL DBW_STEP must be 60..3600 seconds, got '$3'"; return 1; }
  [[ "$4" =~ ^(all|metrics|log)$ ]] || { do_log "FATAL DBW_PART must be all, metrics or log, got '$4'"; return 1; }
  [[ "$5" =~ ^[0-9]+$ ]] && (( $5 >= 1 && $5 <= 200000 )) || { do_log "FATAL DBW_LOG_LIMIT must be 1..200000, got '$5'"; return 1; }
}

# spl_db_window_metrics -> the series, one per line: <metric> <aligner> <label|->.
# A gauge is averaged per step; a delta or cumulative counter is a rate per
# second. A series the platform does not expose prints its error and the
# report goes on: "not exposed" is itself a finding.
spl_db_window_metrics() {
  cat <<'EOF'
database/cpu/utilization ALIGN_MEAN -
database/cpu/reserved_cores ALIGN_MEAN -
database/memory/utilization ALIGN_MEAN -
database/memory/components ALIGN_MEAN component
database/memory/total_usage ALIGN_MEAN -
database/swap/bytes_used ALIGN_MEAN -
database/swap/pages_swapped_in_count ALIGN_RATE -
database/swap/pages_swapped_out_count ALIGN_RATE -
database/disk/read_ops_count ALIGN_RATE -
database/disk/write_ops_count ALIGN_RATE -
database/disk/read_bytes_count ALIGN_RATE -
database/disk/write_bytes_count ALIGN_RATE -
database/disk/utilization ALIGN_MEAN -
database/postgresql/transaction_count ALIGN_RATE transaction_type
database/postgresql/num_backends ALIGN_MEAN -
database/postgresql/backends_in_wait ALIGN_MEAN wait_event_type
database/postgresql/blocks_read_count ALIGN_RATE source
EOF
}

# spl_db_window_fetch_metrics <dir> <since> <until> <step> -> one saved
# Monitoring response per series, <dir>/m.<metric with / as _>.json.
spl_db_window_fetch_metrics() {
  local dir="$1" since="$2" until="$3" step="$4" tok hdr m al lab rc=0
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || { do_log "ERROR no access token for $GCP_ACCOUNT: no platform metrics"; return 1; }
  hdr="$(mktemp)" || return 1
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$hdr"; )
  while read -r m al lab; do
    curl -s --connect-timeout 10 --max-time 60 -G "https://monitoring.googleapis.com/v3/projects/$SPL_PROJECT/timeSeries" \
      -K "$hdr" \
      --data-urlencode "filter=metric.type=\"cloudsql.googleapis.com/$m\" AND resource.labels.database_id=\"$SPL_PROJECT:$SPL_SQL_INSTANCE\"" \
      --data-urlencode "interval.startTime=$since" --data-urlencode "interval.endTime=$until" \
      --data-urlencode "aggregation.alignmentPeriod=${step}s" --data-urlencode "aggregation.perSeriesAligner=$al" \
      >"$dir/m.${m//\//_}.json" || rc=1
  done < <(spl_db_window_metrics)
  rm -f "$hdr"
  return $rc
}

# spl_db_window_report <dir> <part> <limit> -> the two tables out of the saved
# reads in <dir>.
spl_db_window_report() {
  local dir="$1" part="$2" limit="$3" m al lab
  if [[ "$part" != log ]]; then
    echo "--- metrics (per step; counters as a rate per second)"
    printf '%-46s %-18s %5s %12s %12s %12s %12s %12s\n' series label n min p50 mean p95 max
    while read -r m al lab; do
      if [[ -f "$dir/m.${m//\//_}.json" ]]; then
        spl_db_window_series "${m#database/}" "$lab" <"$dir/m.${m//\//_}.json"
      else
        printf '%-46s %-18s no saved read\n' "${m#database/}" -
      fi
    done < <(spl_db_window_metrics)
  fi
  if [[ "$part" != metrics ]]; then
    echo "--- postgres log: checkpoints and statement timeouts"
    if [[ -f "$dir/log.json" ]]; then spl_db_window_log "$limit" <"$dir/log.json"; else echo "no saved read"; fi
  fi
}

# spl_db_window_series <name> <label|-> -> a Monitoring v3 timeSeries response
# on stdin as one line per label value (series of one value summed per step).
spl_db_window_series() {
  python3 -c '
import json, sys
name, lab = sys.argv[1], sys.argv[2]
def out(label, rest):
    print("%-46s %-18s %s" % (name, label[:18], rest))
try:
    d = json.load(sys.stdin)
except Exception as e:
    out("-", "no data (%s)" % e); sys.exit(0)
if "error" in d:
    out("-", "error: %s" % str(d["error"].get("message", d["error"]))[:120]); sys.exit(0)
groups = {}
for s in d.get("timeSeries", []):
    key = s.get("metric", {}).get("labels", {}).get(lab, "?") if lab != "-" else "-"
    g = groups.setdefault(key, {})
    for p in s.get("points", []):
        v = p.get("value", {})
        val = v.get("int64Value", v.get("doubleValue"))
        if val is not None:
            t = p["interval"]["endTime"]
            g[t] = g.get(t, 0.0) + float(val)
if not any(groups.values()):
    out("-", "no points in the window"); sys.exit(0)
def pct(a, q):
    return a[min(len(a) - 1, int(round(q * (len(a) - 1))))]
def f(x):
    return "%.4f" % x if abs(x) < 10 else "%.0f" % x
for key in sorted(groups):
    a = sorted(groups[key].values())
    if a:
        out(key, "%5d %12s %12s %12s %12s %12s" % (len(a), f(a[0]), f(pct(a, .5)), f(sum(a) / len(a)), f(pct(a, .95)), f(a[-1])))
' "$1" "$2"
}

# spl_db_window_log <limit> -> a `gcloud logging read --format=json` array of
# Postgres log lines on stdin: the checkpoints of the window as p50 / p95 / max
# of write, sync, total and the longest one-file sync, the worst five by sync,
# and the statement timeouts per 10 minutes.
spl_db_window_log() {
  python3 -c '
import json, re, sys
limit = int(sys.argv[1])
try:
    entries = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if not isinstance(entries, list) or not entries:
    print("no log entries in the window"); sys.exit(0)
CK = re.compile(r"checkpoint complete:.*?wrote (\d+) buffers.*?write=([\d.]+) s, sync=([\d.]+) s, total=([\d.]+) s.*?longest=([\d.]+) s")
cks, tos = [], {}
for e in entries:
    ts = e.get("timestamp", "")
    text = e.get("textPayload") or (e.get("jsonPayload") or {}).get("message") or ""
    m = CK.search(text)
    if m:
        cks.append((ts, int(m.group(1)), float(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5))))
    elif "statement timeout" in text:
        k = ts[11:15] + "0"
        tos[k] = tos.get(k, 0) + 1
if len(entries) >= limit:
    print("TRUNCATED: DBW_LOG_LIMIT=%d entries were read, not the whole window" % limit)
def pct(a, q):
    a = sorted(a)
    return a[min(len(a) - 1, int(round(q * (len(a) - 1))))]
print("checkpoints n=%d" % len(cks))
if cks:
    print("%-10s %10s %10s %10s" % ("seconds", "p50", "p95", "max"))
    for i, nm in ((2, "write"), (3, "sync"), (4, "total"), (5, "longest")):
        a = [c[i] for c in cks]
        print("%-10s %10.3f %10.3f %10.3f" % (nm, pct(a, .5), pct(a, .95), max(a)))
    b = [c[1] for c in cks]
    print("%-10s %10d %10d %10d" % ("buffers", pct(b, .5), pct(b, .95), max(b)))
    print("worst by sync: " + "; ".join("%s sync=%.3f total=%.1f buf=%d" % (c[0][11:19], c[3], c[4], c[1])
                                        for c in sorted(cks, key=lambda c: -c[3])[:5]))
print("statement timeouts n=%d%s" % (sum(tos.values()), (" per 10 min: " + ", ".join("%s %d" % kv for kv in sorted(tos.items()))) if tos else ""))
' "$1"
}
