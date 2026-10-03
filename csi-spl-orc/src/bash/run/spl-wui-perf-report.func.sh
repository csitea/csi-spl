#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY field report of the WUI's perceived performance (spec
# @description 066 section 6 (a), lane L8): GET /v1/admin/perf/summary on the
# @description env's API host (env.dns.api_fqdn), which runs percentile_cont
# @description server-side, and prints one row per (metric, device, view): n,
# @description p50, p75, p95 and failed, ranked by p75 (slowest first). p95
# @description prints "-" under n = 50 (the route omits it, section 8). A "*"
# @description marks the rows a perf round may plan from (n >= 100); the top 5
# @description of them are named under each ranking. PERF_BUILD_A / PERF_BUILD_B
# @description print a before / after of two builds: both rankings, then one
# @description compare table of the p75 per group with its change in percent.
# @description The route is tenant.settings in the caller's workspace, so the
# @description read is a member session of a workspace admin (the same door the
# @description WUI's Performance page uses); the password and the session
# @description cookie are never printed. Nothing is written but the session.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - the workspace slug, default the cnf's
# @param   steps.019 wui_default_tenant
# @param PERF_DAYS (optional) - the window, 1..30 days, default 7
# @param PERF_BUILD_A (optional) - a build version: only its samples
# @param PERF_BUILD_B (optional) - a second build, compared to PERF_BUILD_A
# @param PERF_EMAIL (optional) - default <state>/m3-e2e/<tenant>/human-email,
# @param   else m3-e2e-human@example.com
# @param PERF_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PERF_API (optional) - overrides https://<env.dns.api_fqdn>
# @param PERF_SUMMARY_FILE (optional, tests) - a summary JSON read instead of the hub
# @example ENV=prd PERF_DAYS=7 ./run -a do_spl_wui_perf_report
# @example ENV=dev PERF_BUILD_A=1.3.4 PERF_BUILD_B=1.3.5 ./run -a do_spl_wui_perf_report
#------------------------------------------------------------------------------
do_spl_wui_perf_report() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" days="${PERF_DAYS:-7}" a="${PERF_BUILD_A:-}" b="${PERF_BUILD_B:-}"
  [[ -n "$tenant" ]] || tenant="$(yq -r '.env.steps."019-firebase-static-site".wui_default_tenant // ""' "$SPL_CNF")"
  spl_require_tenant_slug "$tenant" || return 1
  spl_wui_perf_report_validate "$days" "$a" "$b" || return 1

  local summary rc=0
  if [[ -n "${PERF_SUMMARY_FILE:-}" ]]; then
    summary="$(cat "$PERF_SUMMARY_FILE")" || { do_log "FATAL cannot read PERF_SUMMARY_FILE $PERF_SUMMARY_FILE"; return 1; }
  else
    summary="$(spl_wui_perf_report_fetch "$tenant" "$days" "$a" "$b")" || rc=$?
    (( rc == 0 )) || { do_log "FATAL cannot read the $ENV/$tenant perf summary (exit $rc): $summary"; return 1; }
  fi
  local out
  out="$(PERF_SUMMARY="$summary" python3 -c "$(spl_wui_perf_report_py_format)")" || {
    do_log "FATAL the $ENV/$tenant perf summary is not the route's shape: $out"; return 1; }
  printf '%s\n' "${out#*$'\n'}"
  do_log "OK GET /v1/admin/perf/summary on $ENV/$tenant: ${out%%$'\n'*} (read-only, printed above)"
}

# spl_wui_perf_report_validate <days> <build_a> <build_b> -> 0 when the window
# is 1..30 and each build is the route's version token; logs the FATAL else.
spl_wui_perf_report_validate() {
  [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 30 )) ||
    { do_log "FATAL PERF_DAYS must be 1..30, got: '$1'"; return 1; }
  local v
  for v in "$2" "$3"; do
    [[ "$v" =~ ^[0-9A-Za-z.+-]{0,40}$ ]] || { do_log "FATAL PERF_BUILD_A / PERF_BUILD_B must be a build version, got: '$v'"; return 1; }
  done
  [[ -z "$3" || -n "$2" ]] || { do_log "FATAL PERF_BUILD_B needs PERF_BUILD_A (the before of the compare)"; return 1; }
}

# spl_wui_perf_report_fetch <tenant> <days> <build_a> <build_b> -> the summary
# JSON on stdout, through a member session. Exit 2 = no sign-in, 3 = the
# member lacks tenant.settings, 1 = any other refusal (its verdict on stdout).
spl_wui_perf_report_fetch() {
  local tenant="$1" api state="$SPL_STATE_DIR/m3-e2e/$1" email
  spl_cnf_api_fqdn api || return 1
  email="${PERF_EMAIL:-$(cat "$state/human-email" 2>/dev/null)}"
  local pw="${PERF_PW_FILE:-$state/pw-human}"
  [[ -r "$pw" ]] || { echo "no readable password file $pw (set PERF_PW_FILE to a workspace admin's)"; return 1; }
  PERF_API="${PERF_API:-https://$api}" PERF_TENANT="$tenant" PERF_EMAIL="${email:-m3-e2e-human@example.com}" \
    PERF_PW_FILE="$pw" PERF_QUERY="days=$((10#$2))${3:+&build=$3}${4:+&build_b=$4}" python3 -c "$(spl_wui_perf_report_py_fetch)"
}

spl_wui_perf_report_py_fetch() {
  cat <<'PY'
import json, os, sys, urllib.error, urllib.request
api = os.environ["PERF_API"].rstrip("/")
def http(method, url, body=None, cookie=""):
    h = {"Accept": "application/json"}
    data = None
    if body is not None:
        data, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    if cookie:
        h["Cookie"] = cookie
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h, method=method), timeout=20)
        st, hdrs, raw = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        st, hdrs, raw = e.code, e.headers, e.read()
    except (urllib.error.URLError, OSError) as e:
        print(json.dumps({"step": "connect", "error": type(e).__name__}))
        sys.exit(1)
    try:
        out = json.loads(raw.decode()) if raw else None
    except ValueError:
        out = None
    return st, hdrs, out
def err(o):
    return o.get("error", "") if isinstance(o, dict) else ""
with open(os.environ["PERF_PW_FILE"]) as f:
    pw = f.read().strip()
st, hdrs, out = http("POST", api + "/api/v1/auth/login",
                     {"email": os.environ["PERF_EMAIL"], "password": pw, "tenant": os.environ["PERF_TENANT"]})
cookie = ""
for v in (hdrs.get_all("Set-Cookie") or []) if st == 200 else []:
    pair = v.split(";", 1)[0]
    if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
        cookie = pair
        break
if not cookie:
    print(json.dumps({"step": "login", "status": st, "error": err(out)}))
    sys.exit(2)
st, _, out = http("GET", api + "/v1/admin/perf/summary?" + os.environ["PERF_QUERY"], cookie=cookie)
if st == 403:
    print(json.dumps({"step": "summary", "status": st, "error": err(out),
                      "hint": "the member lacks tenant.settings; set PERF_EMAIL / PERF_PW_FILE to a workspace admin"}))
    sys.exit(3)
if st != 200 or not isinstance(out, dict):
    print(json.dumps({"step": "summary", "status": st, "error": err(out)}))
    sys.exit(1)
print(json.dumps(out))
PY
}

# spl_wui_perf_report_py_format: PERF_SUMMARY (the route's JSON) -> line 1 the
# one-line verdict for the OK log, then the tables. Exit 1 on a wrong shape.
spl_wui_perf_report_py_format() {
  cat <<'PY'
import json, os, sys
try:
    s = json.loads(os.environ["PERF_SUMMARY"])
    rows = s["rows"]
    rows_b = s.get("rows_b")
    assert isinstance(rows, list) and isinstance(s["days"], int)
    assert rows_b is None or isinstance(rows_b, list)
    for r in rows + (rows_b or []):
        assert isinstance(r["metric"], str) and isinstance(r["n"], int)
except (ValueError, KeyError, TypeError, AssertionError) as e:
    print("bad shape: %s" % type(e).__name__)
    sys.exit(1)
PLAN_N, TOP = 100, 5
def ms(v):
    return "-" if v is None else ("%.0f" % v if v >= 10 else "%.1f" % v)
def table(title, rs):
    out = ["", "## %s" % title, "",
           "| # | metric | device | view | n | p50 ms | p75 ms | p95 ms | failed |",
           "|---|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rs, 1):
        mark = "*" if r["n"] >= PLAN_N else ""
        out.append("| %d%s | %s | %s | %s | %d | %s | %s | %s | %d |" % (
            i, mark, r["metric"], r["device"], r["view"], r["n"], ms(r.get("p50")), ms(r.get("p75")),
            ms(r.get("p95")), r.get("failed", 0)))
    if not rs:
        out.append("| - | no samples in this window | | | | | | | |")
    top = [r for r in rs if r["n"] >= PLAN_N and r.get("p75") is not None][:TOP]
    out += ["", "top %d with n >= %d (a round plans from these): %s" % (
        TOP, PLAN_N, ", ".join("%s/%s/%s p75 %s ms n %d" % (r["metric"], r["device"], r["view"], ms(r["p75"]), r["n"])
                               for r in top) or "none yet")]
    return out
def key(r):
    return (r["metric"], r["device"], r["view"])
build, build_b = s.get("build") or "", s.get("build_b") or ""
head = "%d group(s), %d day(s)" % (len(rows), s["days"])
if build:
    head += ", build %s" % build
if rows_b is not None:
    head += " vs %s: %d group(s)" % (build_b, len(rows_b))
if s.get("off"):
    head += ", the hub keeps no samples (off)"
lines = [head]
lines += table("%s, last %d day(s), ranked by p75" % (("build " + build) if build else "every build", s["days"]), rows)
if rows_b is not None:
    lines += table("build %s, last %d day(s), ranked by p75" % (build_b, s["days"]), rows_b)
    a, b = {key(r): r for r in rows}, {key(r): r for r in rows_b}
    lines += ["", "## p75 %s -> %s" % (build, build_b), "",
              "| metric | device | view | n A | p75 A ms | n B | p75 B ms | change |", "|---|---|---|---|---|---|---|---|"]
    for k in sorted(set(a) | set(b)):
        ra, rb = a.get(k, {}), b.get(k, {})
        pa, pb = ra.get("p75"), rb.get("p75")
        ch = "-" if pa in (None, 0) or pb is None else "%+.1f %%" % ((pb - pa) * 100.0 / pa)
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            k[0], k[1], k[2], ra.get("n", "-"), ms(pa), rb.get("n", "-"), ms(pb), ch))
print("\n".join(lines))
PY
}
