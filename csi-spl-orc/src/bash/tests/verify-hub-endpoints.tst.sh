#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: verify-hub-endpoints.sh (spec 008 FR-P12) turns HTTPS probes into
#          the right verdict and exit code, with curl stubbed per URL:
#   1. all ok (site 200 + body, api 200 + {version,commit,built_at}) -> rc 0
#   2. not reachable YET is UNKNOWN (rc 2), never a failure:
#      DNS (curl 6), connection refused (curl 7), TLS / cert not ACTIVE
#      (curl 35, 60), LB allowlist 403
#   3. broken is a failure (rc 1): 5xx, 404, api 200 with a wrong JSON shape,
#      a timeout; and a failure outranks a pending
#   4. a probe that turns ok on a later attempt is ok (retries)
#   5. with no override the list is derived from cnf: site = https://<fqdn>/,
#      api = https://[<env_subdomain>.]api.<BASE_DOMAIN>/version, per env
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
SCRIPT="$PROJ_ROOT/src/bash/scripts/verify-hub-endpoints.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# curl stub. $STUB_MAP lines: "<url> <curl-exit> <http-code> <body-file|->".
# A url may appear several times: the Nth call gets the Nth line (the last one
# repeats), which is how retries are scripted. Every call is logged.
mkdir -p "$T/stub"
cat >"$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; -w|--max-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "$url" >>"$STUB_LOG"
n=$(grep -cxF "$url" "$STUB_LOG")
line=$(awk -v u="$url" '$1 == u' "$STUB_MAP" | sed -n "${n}p")
[[ -n "$line" ]] || line=$(awk -v u="$url" '$1 == u' "$STUB_MAP" | tail -1)
[[ -n "$line" ]] || { echo "curl: (6) Could not resolve host" >&2; printf 000; exit 6; }
read -r _ rc code bodyf <<<"$line"
[[ "$bodyf" != - && -n "$out" ]] && cp "$bodyf" "$out"
[[ "$bodyf" == - && -n "$out" ]] && : >"$out"
printf '%s' "$code"; exit "$rc"
EOF
chmod +x "$T/stub/curl"

printf '{"version":"0.1.0","commit":"abc1234","built_at":"2026-09-18T19:00:00Z"}' >"$T/version.json"
printf '{"version":"0.1.0"}' >"$T/short.json"
printf 'hello from the spool hub\n' >"$T/hello.txt"

S=https://site.example.test/ A=https://api.example.test/version
run() { # <map lines...> -> sets out, rc
  printf '%s\n' "$@" >"$T/map"; : >"$T/log"
  out=$(env PATH="$T/stub:$PATH" STUB_MAP="$T/map" STUB_LOG="$T/log" ENV_NAME=dev \
        VERIFY_ATTEMPTS="${ATT:-1}" VERIFY_DELAY=0 GITHUB_STEP_SUMMARY= \
        VERIFY_ENDPOINTS="site $S
api $A" bash "$SCRIPT" 2>&1); rc=$?
}
want() { # <label> <rc>
  [[ $rc -eq $2 ]] && pass "$1 (rc $rc)" || fail "$1: rc=$rc want $2 -- $(tail -3 <<<"$out" | tr '\n' ' ')"
}

# --- 1 ------------------------------------------------------------------------
run "$S 0 200 $T/hello.txt" "$A 0 200 $T/version.json"; want "site 200 + api {version,commit,built_at}" 0
grep -q 'ok {"version":"0.1.0","commit":"abc1234"' <<<"$out" && pass "the api verdict echoes the served version JSON" || fail "api verdict line missing the JSON"

# --- 2 ------------------------------------------------------------------------
run "$S 0 200 $T/hello.txt" "$A 6 000 -";            want "api name does not resolve -> UNKNOWN" 2
grep -q '::warning::.*NOT PROVEN -- dns' <<<"$out" && pass "dns pending is a ::warning::" || fail "no dns ::warning::"
run "$S 7 000 -" "$A 0 200 $T/version.json";          want "connection refused (name not on the LB yet) -> UNKNOWN" 2
run "$S 35 000 -" "$A 0 200 $T/version.json";         want "TLS handshake rejected (cert not ACTIVE) -> UNKNOWN" 2
run "$S 60 000 -" "$A 0 200 $T/version.json";         want "cert not trusted -> UNKNOWN" 2
run "$S 0 403 -" "$A 0 403 -";                         want "LB allowlist 403 -> UNKNOWN" 2
grep -q '::error::' <<<"$out" && fail "a pending probe printed ::error::" || pass "no ::error:: for pending probes"

# --- 3 ------------------------------------------------------------------------
run "$S 0 502 -" "$A 0 200 $T/version.json";          want "site 502 -> failure" 1
run "$S 0 200 $T/hello.txt" "$A 0 404 -";             want "api 404 -> failure" 1
run "$S 0 200 $T/hello.txt" "$A 0 200 $T/short.json"; want "api 200 without commit/built_at -> failure" 1
run "$S 0 200 $T/hello.txt" "$A 0 200 $T/hello.txt";  want "api 200 with a non-JSON body -> failure" 1
run "$S 0 200 -" "$A 0 200 $T/version.json";          want "site 200 with an empty body -> failure" 1
run "$S 28 000 -" "$A 0 200 $T/version.json";         want "timeout -> failure" 1
run "$S 6 000 -" "$A 0 500 -";                         want "a failure outranks a pending" 1
grep -q '::error::.*api.*FAILED -- HTTP 500' <<<"$out" && pass "the failure is an ::error:: naming the probe" || fail "no ::error:: for the 500"

# --- 4 ------------------------------------------------------------------------
ATT=3 run "$S 35 000 -" "$S 0 403 -" "$S 0 200 $T/hello.txt" "$A 0 200 $T/version.json"; want "cert pending, then 403, then 200 on attempt 3 -> ok" 0
[[ $(grep -cxF "$S" "$T/log") -eq 3 && $(grep -cxF "$A" "$T/log") -eq 1 ]] \
  && pass "retries stop at the first ok (site 3 calls, api 1)" || fail "retry counts: site $(grep -cxF "$S" "$T/log"), api $(grep -cxF "$A" "$T/log")"

# --- 5: the list comes from cnf -------------------------------------------------
: >"$T/map"
for e in dev prd; do
  : >"$T/log"
  env PATH="$T/stub:$PATH" STUB_MAP="$T/map" STUB_LOG="$T/log" ENV_NAME=$e VERIFY_ATTEMPTS=1 VERIFY_DELAY=0 \
      GITHUB_STEP_SUMMARY= APP_PATH="$APP_ROOT" bash "$SCRIPT" >/dev/null 2>&1
  base=$(yq -r '.env.dns.BASE_DOMAIN' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")
  sub=$(yq -r '.env.dns.env_subdomain // ""' "$APP_ROOT/csi-spl-cnf/csi-spl/$e.env.yaml")
  want_site="https://${sub:+$sub.}$base/" want_api="https://${sub:+$sub.}api.$base/version"
  got=$(tr '\n' ' ' <"$T/log")
  [[ "$got" == "$want_site $want_api " ]] && pass "$e: probes derived from cnf ($want_site, $want_api)" \
    || fail "$e: probed '$got', want '$want_site $want_api'"
done

[[ $fails -eq 0 ]] && echo "PASS: all verify-hub-endpoints assertions" || { echo "FAILED: $fails"; exit 1; }
