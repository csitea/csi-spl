#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY minute-by-minute view of the hub's Cloud Run log over
# @description a short window (SPL-1981): per minute the requests, their status
# @description (2xx / 429 / other 4xx / 5xx), the WebSocket upgrades, the
# @description distinct callers, the p95 of the non-socket requests, the top
# @description routes and the "no available instance" errors. Then the callers
# @description of the window (remote IP + user agent class) ranked by requests,
# @description with their 429 count. This is what a saturation burst is read
# @description with: a reconnect storm shows as one caller class jumping, real
# @description traffic as every class rising, a slow handler as the p95 rising
# @description before the 429s.
# @description Nothing is mutated: one `gcloud logging read` as the env SA, or
# @description none when REQ_JSON_IN names a saved read.
# @param ENV - required: dev or prd
# @param REQ_SINCE - required: RFC 3339 UTC start, e.g. 2026-10-15T07:15:00Z
# @param REQ_MINUTES (optional) - window length in minutes, default 30 (1..360)
# @param REQ_LIMIT (optional) - log entries read at most, default 100000
# @param REQ_TOP (optional) - routes per minute, default 3; callers listed = 5 x this
# @param REQ_JSON_OUT (optional) - also save the raw read to this file
# @param REQ_JSON_IN (optional) - summarise this saved read instead of calling gcloud
# @example ENV=prd REQ_SINCE=2026-10-15T07:15:00Z REQ_MINUTES=25 ./run -a do_spl_hub_request_minutes
#------------------------------------------------------------------------------
do_spl_hub_request_minutes() {
  local since="${REQ_SINCE:-}" minutes="${REQ_MINUTES:-30}" limit="${REQ_LIMIT:-100000}" top="${REQ_TOP:-3}"
  spl_hub_request_minutes_check_args "$since" "$minutes" "$limit" "$top" || return 1
  if [[ -n "${REQ_JSON_IN:-}" ]]; then
    [[ -s "$REQ_JSON_IN" ]] || { do_log "FATAL REQ_JSON_IN=$REQ_JSON_IN is missing or empty"; return 1; }
    spl_hub_request_minutes_table "$top" "$limit" <"$REQ_JSON_IN"
    return
  fi
  do_require_bin gcloud python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local svc until out
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL env.hub.service_name is not set in $SPL_CNF"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  until="$(date -u -d "$since + $minutes minutes" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  printf '===== csi-spl hub minutes: env=%s project=%s service=%s (%s .. %s)\n' "$ENV" "$SPL_PROJECT" "$svc" "$since" "$until"
  out="${REQ_JSON_OUT:-$(mktemp)}"
  gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\" AND timestamp>=\"$since\" AND timestamp<\"$until\"" \
    --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --limit="$limit" --format=json >"$out" || return 1
  spl_hub_request_minutes_table "$top" "$limit" <"$out"
  [[ -n "${REQ_JSON_OUT:-}" ]] || rm -f "$out"
}

# spl_hub_request_minutes_check_args <since> <minutes> <limit> <top> -> 0 when sane.
spl_hub_request_minutes_check_args() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    { do_log "FATAL REQ_SINCE must be RFC 3339 UTC (YYYY-MM-DDThh:mm:ssZ), got '$1'"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 360 )) || { do_log "FATAL REQ_MINUTES must be 1..360, got '$2'"; return 1; }
  [[ "$3" =~ ^[0-9]+$ ]] && (( $3 >= 1 && $3 <= 200000 )) || { do_log "FATAL REQ_LIMIT must be 1..200000, got '$3'"; return 1; }
  [[ "$4" =~ ^[0-9]+$ ]] && (( $4 >= 1 )) || { do_log "FATAL REQ_TOP must be a positive integer, got '$4'"; return 1; }
}

# spl_hub_request_minutes_table <top> [limit] -> a `gcloud logging read
# --format=json` array on stdin, one row per minute, then the callers. Ids in
# paths are folded as in do_spl_hub_route_latency.
spl_hub_request_minutes_table() {
  python3 -c '
import json, re, sys
from urllib.parse import urlparse
top = int(sys.argv[1])
limit = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else 0
try:
    entries = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if not isinstance(entries, list) or not entries:
    print("no log entries in the window"); sys.exit(0)
FOLD = [(re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), "{id}"),
        (re.compile(r"/[0-9a-f]{32,}(?=/|$)"), "/{hash}"), (re.compile(r"/[0-9]+(?=/|$)"), "/{n}")]
def ua_class(ua):
    u = (ua or "").lower()
    for k in ("spool", "go-http-client", "curl", "python", "node", "playwright", "headlesschrome", "googlehc", "mozilla"):
        if k in u:
            return k
    return u[:20] or "-"
def pct(a, q):
    if not a:
        return 0.0
    a = sorted(a)
    return a[min(len(a) - 1, int(round(q * (len(a) - 1))))]
mins, callers, t0, t1 = {}, {}, None, None
for e in entries:
    ts = e.get("timestamp", "")
    if not ts:
        continue
    t0 = min(t0 or ts, ts); t1 = max(t1 or ts, ts)
    m = mins.setdefault(ts[11:16], {"n": 0, "2xx": 0, "429": 0, "4xx": 0, "5xx": 0, "ws": 0, "ips": set(), "ms": [], "routes": {}, "noinst": 0})
    text = e.get("textPayload") or (e.get("jsonPayload") or {}).get("message") or ""
    if "no available instance" in text:
        m["noinst"] += 1
    h = e.get("httpRequest")
    if not h or not h.get("requestUrl"):
        continue
    st = int(h.get("status", 0) or 0)
    path = urlparse(h["requestUrl"]).path
    for rx, to in FOLD:
        path = rx.sub(to, path)
    m["n"] += 1
    m["2xx" if 100 <= st < 400 else "429" if st == 429 else "4xx" if st < 500 else "5xx"] += 1
    ip = h.get("remoteIp", "-")
    m["ips"].add(ip)
    if path.endswith("/ws"):
        m["ws"] += 1
    elif h.get("latency"):
        m["ms"].append(float(h["latency"].rstrip("s")) * 1000.0)
    m["routes"][path] = m["routes"].get(path, 0) + 1
    c = callers.setdefault((ip, ua_class(h.get("userAgent"))), {"n": 0, "429": 0, "ws": 0})
    c["n"] += 1; c["429"] += st == 429; c["ws"] += path.endswith("/ws")
print("entries=%d first=%s last=%s" % (len(entries), t0, t1))
if limit and len(entries) >= limit:
    print("TRUNCATED: REQ_LIMIT=%d entries were read; the span is only %s..%s, not the whole window" % (limit, t0, t1))
print("%5s %6s %6s %5s %5s %5s %5s %6s %4s %8s  %s" % ("min", "req", "2xx", "429", "4xx", "5xx", "ws", "noinst", "ips", "p95_ms", "top routes"))
for k in sorted(mins):
    m = mins[k]
    tr = ", ".join("%s %d" % r for r in sorted(m["routes"].items(), key=lambda r: -r[1])[:top])
    print("%5s %6d %6d %5d %5d %5d %5d %6d %4d %8.0f  %s" % (k, m["n"], m["2xx"], m["429"], m["4xx"], m["5xx"], m["ws"], m["noinst"], len(m["ips"]), pct(m["ms"], .95), tr))
print(); print("--- callers by requests (top %d)" % (top * 5))
print("%6s %5s %5s  %-40s %s" % ("req", "429", "ws", "remote_ip", "agent"))
for (ip, ua), c in sorted(callers.items(), key=lambda kv: -kv[1]["n"])[:top * 5]:
    print("%6d %5d %5d  %-40s %s" % (c["n"], c["429"], c["ws"], ip[:40], ua))
' "$1" "${2:-}"
}
