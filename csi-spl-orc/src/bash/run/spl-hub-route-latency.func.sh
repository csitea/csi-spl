#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY latency and size of the hub's HTTP routes, per route,
# @description from the Cloud Run request log of a cloud env (CLE-35061): the
# @description server's own time (httpRequest.latency, no client network) and
# @description the bytes it sent (httpRequest.responseSize, after compression).
# @description Ids in paths (uuids, HUM-/CLE-/issue keys, file hashes, numbers) are
# @description folded, so one row is one route. Prints n, p50 / p95 / max ms,
# @description 4xx and 5xx counts, and p50 / p95 KB per (method, route), ranked
# @description by total server time; WebSocket rows are listed apart, since
# @description their latency is the socket's life, not a request's.
# @description This is the per-route before/after of a hub change: run it over
# @description a window before the roll and over one after it.
# @description Nothing is mutated: one `gcloud logging read` as the env SA.
# @param ENV - required: dev or prd
# @param ROUTE_HOURS (optional) - window in hours ending now, default 6 (1..168)
# @param ROUTE_SINCE (optional) - an RFC 3339 UTC start instead (e.g. 2026-09-27T21:00:00Z); ROUTE_HOURS then sets the window's length
# @param ROUTE_TOP (optional) - rows printed, default 30
# @param ROUTE_LIMIT (optional) - log entries read at most, default 50000
# @param ROUTE_QUERY (optional) - 1 splits each route by its query shape: the
# @param   parameter names with their short values (ids folded, a long value
# @param   reads {v}), e.g. ?dm=true&limit=50&per_topic=50 (CLE-77914); default 0
# @example ENV=prd ./run -a do_spl_hub_route_latency
# @example ENV=prd ROUTE_SINCE=2026-09-27T21:00:00Z ROUTE_HOURS=2 ./run -a do_spl_hub_route_latency
# @example ENV=prd ROUTE_QUERY=1 ROUTE_HOURS=3 ./run -a do_spl_hub_route_latency
#------------------------------------------------------------------------------
do_spl_hub_route_latency() {
  do_require_bin gcloud python3 yq || return 1
  local hours="${ROUTE_HOURS:-6}" top="${ROUTE_TOP:-30}" limit="${ROUTE_LIMIT:-50000}" since="${ROUTE_SINCE:-}"
  local query="${ROUTE_QUERY:-0}"
  spl_hub_route_latency_check_args "$hours" "$top" "$limit" "$since" || return 1
  [[ "$query" == 0 || "$query" == 1 ]] || { do_log "FATAL ROUTE_QUERY must be 0 or 1, got '$query'"; return 1; }
  do_spl_cloud_cnf || return 1
  local svc
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL env.hub.service_name is not set in $SPL_CNF"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local until
  if [[ -n "$since" ]]; then
    until="$(date -u -d "$since + $hours hours" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  else
    until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    since="$(date -u -d "$hours hours ago" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  fi
  printf '===== csi-spl hub routes: env=%s project=%s service=%s window=%sh (%s .. %s)\n' \
    "$ENV" "$SPL_PROJECT" "$svc" "$hours" "$since" "$until"
  gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\" AND httpRequest.requestUrl:\"/\" AND timestamp>=\"$since\" AND timestamp<\"$until\"" \
    --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --limit="$limit" --format=json |
    spl_hub_route_latency_table "$top" "$query" "$limit"
}

# spl_hub_route_latency_check_args <hours> <top> <limit> <since> -> 0 when sane.
spl_hub_route_latency_check_args() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 168 )) ||
    { do_log "FATAL ROUTE_HOURS must be 1..168, got '$1'"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 )) || { do_log "FATAL ROUTE_TOP must be a positive integer, got '$2'"; return 1; }
  [[ "$3" =~ ^[0-9]+$ ]] && (( $3 >= 1 && $3 <= 200000 )) ||
    { do_log "FATAL ROUTE_LIMIT must be 1..200000, got '$3'"; return 1; }
  [[ -z "$4" || "$4" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    { do_log "FATAL ROUTE_SINCE must be RFC 3339 UTC (YYYY-MM-DDThh:mm:ssZ), got '$4'"; return 1; }
}

# spl_hub_route_latency_table <top> [query 0|1] [limit] -> a `gcloud logging
# read --format=json` array on stdin, printed as one row per (method, folded
# route), or per (method, folded route + query shape) when query is 1. When
# the read stopped at limit (ROUTE_LIMIT), the window is cut short: gcloud
# reads newest first, so the oldest entries are missing, and a TRUNCATED line
# says so with the span actually read (api perf ap-00).
spl_hub_route_latency_table() {
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  SPL_ID_RX="$SPOOL_PARTICIPANT_RX" python3 -c '
import json, os, re, sys
from urllib.parse import urlparse, parse_qsl
top = int(sys.argv[1])
by_query = len(sys.argv) > 2 and sys.argv[2] == "1"
limit = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else 0
W = 78 if by_query else 46
try:
    entries = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if not isinstance(entries, list) or not entries:
    print("no request log entries in the window"); sys.exit(0)
FOLD = [
    (re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), "{id}"),
    (re.compile(r"/[0-9a-f]{32,}(?=/|$)"), "/{hash}"),
    (re.compile(r"/" + os.environ["SPL_ID_RX"] + r"(?=/|$)"), "/{key}"),
    (re.compile(r"/[0-9]+(?=/|$)"), "/{n}"),
]
rows, revs, t0, t1 = {}, set(), None, None
for e in entries:
    h = e.get("httpRequest") or {}
    url, lat = h.get("requestUrl"), h.get("latency")
    if not url or not lat:
        continue
    u = urlparse(url)
    path = u.path
    for rx, to in FOLD:
        path = rx.sub(to, path)
    if by_query and u.query:
        def fold(v):
            v = FOLD[0][0].sub("{id}", v)
            return v if len(v) <= 16 else "{v}"
        path += "?" + "&".join("%s=%s" % (k, fold(v)) for k, v in sorted(parse_qsl(u.query, keep_blank_values=True)))
    r = rows.setdefault((h.get("requestMethod", "?"), path), {"ms": [], "kb": [], "4xx": 0, "5xx": 0})
    r["ms"].append(float(lat.rstrip("s")) * 1000.0)
    if int(h.get("status", 0) or 0) == 200:
        r["kb"].append(int(h.get("responseSize", 0) or 0) / 1024.0)
    st = int(h.get("status", 0) or 0)
    r["4xx"] += 400 <= st < 500
    r["5xx"] += st >= 500
    revs.add((e.get("resource", {}).get("labels", {}) or {}).get("revision_name", "?"))
    ts = e.get("timestamp", "")
    t0 = min(t0 or ts, ts); t1 = max(t1 or ts, ts)
def pct(a, q):
    if not a:
        return 0.0
    a = sorted(a)
    return a[min(len(a) - 1, int(round(q * (len(a) - 1))))]
print("entries=%d routes=%d first=%s last=%s revisions=%s" % (len(entries), len(rows), t0, t1, ",".join(sorted(revs))))
if limit and len(entries) >= limit:
    print("TRUNCATED: ROUTE_LIMIT=%d entries were read; the span is only %s..%s, not the whole window (raise ROUTE_LIMIT, max 200000, or narrow ROUTE_HOURS)" % (limit, t0, t1))
hdr = "%6s %-7s %-*s %8s %8s %8s %5s %5s %8s %8s" % ("n", "method", W, "route", "p50_ms", "p95_ms", "max_ms", "4xx", "5xx", "p50_kb", "p95_kb")
def line(k, r):
    m = r["ms"]
    return "%6d %-7s %-*s %8.1f %8.1f %8.0f %5d %5d %8.1f %8.1f" % (len(m), k[0][:7], W, k[1][:W], pct(m, .5), pct(m, .95), max(m), r["4xx"], r["5xx"], pct(r["kb"], .5), pct(r["kb"], .95))
ws = {k: r for k, r in rows.items() if k[1].split("?")[0].endswith("/ws")}
rest = sorted(((k, r) for k, r in rows.items() if k not in ws), key=lambda kr: -sum(kr[1]["ms"]))
print(); print("--- routes by total server time (top %d)" % top); print(hdr)
for k, r in rest[:top]:
    print(line(k, r))
if ws:
    print(); print("--- websockets (latency = the socket life; 4xx = refused upgrades)"); print(hdr)
    for k, r in sorted(ws.items()):
        print(line(k, r))
' "$1" "${2:-0}" "${3:-}"
}
