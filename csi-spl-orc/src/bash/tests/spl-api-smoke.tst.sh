#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_api_smoke (gap T6) judges the live hub API from what it
#          serves, driven with a stubbed curl (no network). prd without
#          API_SMOKE_PRD_GO=1, an unknown ENV and a non-test TENANT refuse
#          before any request. A healthy hub -> 0 (member tier SKIP without a
#          cookie); an open door, a /version without commit -> 1. With a 0600
#          cookie of e2e every member read runs and the cookie never reaches
#          curl's argv or the output; a session of another tenant stops after
#          /v1/view/me -> 1; an expired cookie (401) -> SKIP, 0; a 0644 cookie
#          -> 1. Every request is a GET; prd waits 1 s between requests.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-api-smoke.func.sh"
CNF_LIB="$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
fails=0
check() { if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fails=$((fails + 1)); fi; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# The stub curl: logs its argv (one line per call), answers by path, and
# reads the session cookie only from the -H @file it was given.
cat >"$tmp/bin/curl" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
out="" hdr="" url="${!#}"
while (( $# )); do
  case "$1" in -o) out="$2"; shift ;; -H) hdr="${2#@}"; shift ;; esac
  shift
done
cookie=""; [[ -n "$hdr" && -f "$hdr" ]] && cookie="$(cat "$hdr")"
reply() { printf '%s' "$2" >"$out"; printf '%s' "$1"; }
case "$url" in
  */version) reply 200 "$STUB_VERSION" ;;
  */v1/health) reply 200 '{"status":"ok"}' ;;
  */v1/view/me)
    if [[ "$cookie" == *spool_session=* ]]; then
      [[ "$STUB_ME" == expired ]] && reply 401 '{"error":"view_door"}' \
        || reply 200 "{\"tenant_id\":\"$STUB_ME\",\"permissions\":[\"topics.read\"]}"
    else
      reply "${STUB_DOOR:-401}" '{"error":"view_door"}'
    fi ;;
  */v1/operator/workspaces) reply 401 '{"error":"view_door"}' ;;
  */v1/view/channels) reply 200 '{"channels":[]}' ;;
  */v1/view/roster) reply 200 '{"agents":[]}' ;;
  */v1/openapi.json) reply 200 '{"paths":{}}' ;;
  *) reply 404 '{}' ;;
esac
S
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/curl.log"
V='{"version":"1.2.3","commit":"abc123","built_at":"2026-10-14T00:00:00Z"}'
printf 'spool_session=s3cr3t-cookie\n' >"$tmp/cookie"; chmod 600 "$tmp/cookie"
printf 'spool_session=s3cr3t-cookie\n' >"$tmp/cookie644"; chmod 644 "$tmp/cookie644"

# run <out file> VAR=value... -> the action's exit code; sleeps go to sleep.log
run() {
  local o="$1"; shift
  : >"$STUB_LOG"; : >"$tmp/sleep.log"
  ( export STUB_VERSION="$V" STUB_ME=e2e API_SMOKE_HOST=api.example.test
    env "$@" bash -c "do_log() { echo \"\$*\"; }; do_require_bin() { :; }
      sleep() { echo \"\$1\" >>'$tmp/sleep.log'; }
      source '$CNF_LIB'; source '$FUNC'; do_spl_api_smoke" >"$o" 2>&1 )
}
calls() { wc -l <"$STUB_LOG" | tr -d ' '; }

run "$tmp/o" ENV=prd; check $? 1 "prd without API_SMOKE_PRD_GO -> 1"
check "$(calls)" 0 "  ... and no request was sent"
run "$tmp/o" ENV=stg; check $? 1 "ENV=stg -> 1"
run "$tmp/o" ENV=dev TENANT=t1; check $? 1 "TENANT=t1 (not a test workspace) -> 1"
check "$(calls)" 0 "  ... and no request was sent"

run "$tmp/o" ENV=dev API_SMOKE_COOKIE_FILE="$tmp/none"; check $? 0 "healthy hub, no cookie -> 0"
check "$(calls)" 4 "  ... four public GETs"
check "$(grep -c '^member *SKIP' "$tmp/o")" 1 "  ... member tier SKIP"
check "$(grep -cvE '^-sS --max-time 15 -o ' "$STUB_LOG")" 0 "  ... every call is a plain GET (no -X/-d)"
check "$(grep -c . "$tmp/sleep.log")" 4 "  ... one gap per request"
check "$(sort -u "$tmp/sleep.log")" 0 "  ... dev gap 0 s"

run "$tmp/o" ENV=dev STUB_DOOR=200 API_SMOKE_COOKIE_FILE="$tmp/none"; check $? 1 "anonymous /v1/view/me answers 200 (door open) -> 1"
run "$tmp/o" ENV=dev STUB_VERSION='{"version":"1"}' API_SMOKE_COOKIE_FILE="$tmp/none"; check $? 1 "/version without commit -> 1"

run "$tmp/o" ENV=prd API_SMOKE_PRD_GO=1 API_SMOKE_COOKIE_FILE="$tmp/cookie"; check $? 0 "prd opt-in, e2e member session -> 0"
check "$(calls)" 8 "  ... four public + four member GETs"
check "$(grep -c PASS "$tmp/o")" 8 "  ... eight PASS lines"
check "$(sort -u "$tmp/sleep.log")" 1 "  ... prd gap 1 s"
check "$(cat "$STUB_LOG" "$tmp/o" | grep -c s3cr3t)" 0 "  ... the cookie is in neither curl argv nor the output"

run "$tmp/o" ENV=dev STUB_ME=t1 API_SMOKE_COOKIE_FILE="$tmp/cookie"; check $? 1 "session of t1, not e2e -> 1"
check "$(calls)" 5 "  ... stops after /v1/view/me"
run "$tmp/o" ENV=dev STUB_ME=expired API_SMOKE_COOKIE_FILE="$tmp/cookie"; check $? 0 "expired cookie (401) -> SKIP, 0"
check "$(grep -c '^member *SKIP.*expired' "$tmp/o")" 1 "  ... says the cookie expired"
run "$tmp/o" ENV=dev API_SMOKE_COOKIE_FILE="$tmp/cookie644"; check $? 1 "cookie file 0644 -> 1"
check "$(calls)" 4 "  ... no member read with a readable cookie"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
