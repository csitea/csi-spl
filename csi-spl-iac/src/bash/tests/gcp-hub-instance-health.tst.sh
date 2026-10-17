#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_hub_instance_health (SPL-2412, spec 146), offline: gcloud is a
#          stub that records every call and serves a fixture shaped like the
#          2026-10-16 prd outage (t1 bd226c16): one stuck instance (WS
#          requests, 0 upgrades, 503s) and one healthy one.
#   1. WARN_MIN_WS / SINCE / UNTIL wrong -> refused before any gcloud call.
#   2. Read-only: every non-auth call pinned --account=<env SA>, in a private
#      gcloud config, no mutating verb; the filter names the hub service, the
#      window and both sources (request log, 'ws hello accepted').
#   3. The rows: per (revision, instance) WS requests, 101s, 5xx, sign-in 503s,
#      ws hello, first/last seen; the stuck instance gets a WARN, the healthy
#      one none; WARN_MIN_WS above the stuck count silences it.
#   4. A failing `logging read` -> rc != 0, FATAL, no table.
#   CONTROL: break the healthy instance's 101s (-> 200) and it is flagged too.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
F="$PROJ_ROOT/src/bash/run/gcp-hub-instance-health.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
printf 'env:\n  hub:\n    service_name: hub-svc-dev\n' >"$T/cnf.yaml"

STUCK=0010dd8607ae39d1aaaaaaaaaaaaaaaa3c41ff56
OK=0010dd8607f520a7bbbbbbbbbbbbbbbb8cb6e37b
# req <instance> <status> <path> <second>
req() {
  printf '{"timestamp":"2026-10-16T19:%s:00Z","resource":{"labels":{"revision_name":"hub-svc-dev-00734-7ln"}},"labels":{"instanceId":"%s"},"httpRequest":{"status":%s,"requestUrl":"https://hub.example.com%s"}}' "$4" "$1" "$2" "$3"
}
# hello <instance> <second>
hello() {
  printf '{"timestamp":"2026-10-16T19:%s:00Z","resource":{"labels":{"revision_name":"hub-svc-dev-00734-7ln"}},"labels":{"instanceId":"%s"},"jsonPayload":{"message":"ws hello accepted"}}' "$2" "$1"
}
fixture() {
  local ok_ws="$1" i
  echo '['
  for i in 01 02 03 04 05 06; do req "$STUCK" 503 /v1/ws "$i"; echo ,; done
  req "$STUCK" 503 /api/v1/auth/github/callback 07; echo ,
  req "$STUCK" 503 '/api/v1/auth/session?x=1' 08; echo ,
  req "$STUCK" 200 /v1/health 09; echo ,
  for i in 10 11 12 13 14 15; do req "$OK" "$ok_ws" /v1/wui/ws "$i"; echo ,; hello "$OK" "$i"; echo ,; done
  req "$OK" 200 /api/v1/auth/session 16
  echo ']'
}
fixture 101 >"$T/entries.json"
fixture 200 >"$T/entries-broken.json"

cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "logging read"*) [[ "${READ_FAIL:-}" == 1 ]] && { echo "ERROR: PERMISSION_DENIED" >&2; exit 1; }; cat "$ENTRIES" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u SINCE -u UNTIL -u WARN_MIN_WS -u HUB_HEALTH_LIMIT \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" CNF="$T/cnf.yaml" \
    ENTRIES="$T/entries.json" ORG=csi APP=spl PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-hub-instance-health.func.sh; do source "$f"; done
    do_spl_merged_cnf() { cp "$CNF" "$3"; }
    do_gcp_hub_instance_health' >"$T/out" 2>&1
}
MUT='(add-iam-policy-binding|remove-iam-policy-binding|set-iam-policy| create | delete | update | deploy |sinks |buckets )'
# row <instance_8> -> its table row's fields 3..7 (ws_req ws_101 5xx login_503 ws_hello)
row() { awk -F'\t' -v i="$1" '$2 == i {print $3, $4, $5, $6, $7}' "$T/out"; }

# --- 1. input guards -----------------------------------------------------------
for bad in WARN_MIN_WS=0 WARN_MIN_WS=x SINCE=abc SINCE=30 UNTIL=30m HUB_HEALTH_LIMIT=0; do
  act "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "FATAL ${bad%%=*}" "$T/out" && pass "1. $bad refused before gcloud" || fail "1. $bad: rc=$rc $(cat "$T/out")"
done

# --- 2. read-only, pinned --------------------------------------------------------
act SINCE=2026-10-16T19:00:00Z UNTIL=2026-10-16T19:30:00Z; rc=$?
[[ $rc -eq 0 ]] && pass "2. a clean run (rc=0)" || fail "2. run: rc=$rc $(tail -5 "$T/out")"
n=$(grep -vE '\|auth ' "$T/calls.log" | wc -l); na=$(grep -vE '\|auth ' "$T/calls.log" | grep -c -- "--account=$DEV_SA")
[[ $n -eq 1 && $na -eq 1 ]] && pass "2. the one gcloud read is pinned --account=$DEV_SA" || fail "2. $na of $n calls pinned: $(cat "$T/calls.log")"
grep -q '<unset>|' "$T/calls.log" && fail "2. a call ran under the shared config" || pass "2. every call ran in a private gcloud config"
grep -qE "$MUT" "$T/calls.log" && fail "2. a mutating verb: $(grep -E "$MUT" "$T/calls.log")" || pass "2. no mutating gcloud verb"
rd=$(grep 'logging read' "$T/calls.log")
grep -q 'service_name="hub-svc-dev"' <<<"$rd" && grep -q 'timestamp>="2026-10-16T19:00:00Z" AND timestamp<="2026-10-16T19:30:00Z"' <<<"$rd" \
  && grep -q 'run.googleapis.com%2Frequests' <<<"$rd" && grep -q 'jsonPayload.message="ws hello accepted"' <<<"$rd" \
  && pass "2. the filter names the service, the window and both sources" || fail "2. filter: $rd"
act SINCE=30m
grep -qE 'timestamp>="20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' <<<"$(grep 'logging read' "$T/calls.log")" && ! grep -q 'timestamp<=' "$T/calls.log" \
  && pass "2. SINCE=30m becomes an RFC3339 start, no end" || fail "2. SINCE=30m: $(grep 'logging read' "$T/calls.log")"

# --- 3. rows + WARN -------------------------------------------------------------
act
[[ "$(row 3c41ff56)" == "6 0 8 2 0" ]] && pass "3. stuck row: 6 WS, 0 upgrades, 8 5xx, 2 sign-in 503s, 0 hello" || fail "3. stuck row: '$(row 3c41ff56)' $(cat "$T/out")"
[[ "$(row 8cb6e37b)" == "6 6 0 0 6" ]] && pass "3. healthy row: 6 WS, 6 upgrades, 0 5xx, 0 sign-in 503s, 6 hello" || fail "3. healthy row: '$(row 8cb6e37b)'"
grep -q $'3c41ff56\t.*\t2026-10-16T19:01:00Z\t2026-10-16T19:09:00Z$' "$T/out" && pass "3. first/last seen per instance" || fail "3. seen: $(grep 3c41ff56 "$T/out")"
grep -q "^WARN stuck? .*instance $STUCK: 6 WS requests, 0 upgrades" "$T/out" && pass "3. the stuck instance is flagged (full id)" || fail "3. no WARN for stuck: $(cat "$T/out")"
grep -q "^WARN.*$OK" "$T/out" && fail "3. the healthy instance was flagged" || pass "3. the healthy instance is not flagged"
act WARN_MIN_WS=7
grep -q '^WARN stuck?' "$T/out" && fail "3. WARN_MIN_WS=7 still flagged 6 WS requests" || pass "3. WARN_MIN_WS=7 > 6 WS requests: no WARN"

# --- 4. failing read --------------------------------------------------------------
act READ_FAIL=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL gcloud logging read failed' "$T/out" && ! grep -q '^revision' "$T/out" && pass "4. a failing read: rc=$rc, FATAL, no table" || fail "4. read fail: rc=$rc $(tail -3 "$T/out")"

# --- CONTROL ------------------------------------------------------------------------
act ENTRIES="$T/entries-broken.json"
[[ "$(row 8cb6e37b)" == "6 0 0 0 6" ]] && grep -q "^WARN stuck? .*instance $OK" "$T/out" \
  && pass "CONTROL: the healthy instance's 101s broken to 200 -> 0 upgrades, flagged" || fail "CONTROL: '$(row 8cb6e37b)' $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
