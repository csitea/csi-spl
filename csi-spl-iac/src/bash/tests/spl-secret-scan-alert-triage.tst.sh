#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_secret_scan_alert_triage (security round 1 row 8, SPL-1967)
#          resolves a secret-scanning alert as used_in_tests only when it is
#          proven a fixture, and never prints the secret or a real hash.
#   1. DRY_RUN unset: the test-file line holds the secret verbatim, it matches
#      none of the 4 real *linkedin* versions (2 per env), NO PATCH; the secret
#      and any full sha256 never reach the output
#   2. every gcloud call as THAT env's project SA on that env's project
#   3. DRY_RUN=0: one PATCH, state=resolved resolution=used_in_tests
#   4. CONTROL: a real version holds the same value -> refused, no PATCH
#      (fails when the real-secret compare is removed)
#   5. a location outside a test dir -> refused
#   6. the secret is not on the reported line -> refused
#   7. no real *linkedin* secret at all -> refused (nothing proven)
#   8. a resolved alert, or a bad ALERT -> refused
# gh and gcloud are stubs on PATH; the repo is a temp git repo. No network.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-secret-scan-alert-triage.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$ACTION"

FIX="FIXTURE-li-5c1f-not-a-secret=="
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/repo/x/tests" "$T/repo/x/src"
for e in dev prd; do
  printf '{"type":"service_account","client_email":"csi-spl-%s@csi-spl-%s.iam.gserviceaccount.com"}\n' "$e" "$e" >"$T/home/.gcp/.csi/key-csi-spl-$e.json"
done
printf 'line one\nSECRET="%s"\n' "$FIX" >"$T/repo/x/tests/seed.tst.sh"
cp "$T/repo/x/tests/seed.tst.sh" "$T/repo/x/src/seed.sh"
git -C "$T/repo" init -q && git -C "$T/repo" add . && git -C "$T/repo" -c user.name=t -c user.email=t@example.com commit -qm fixture
SHA=$(git -C "$T/repo" rev-parse HEAD)

cat >"$T/stub/gh" <<'EOF_GH'
#!/usr/bin/env bash
echo "gh|$*" >>"$STUB_LOG"
case "$*" in
  "api -X PATCH"*) ;;
  *"/locations") printf '[{"type":"commit","details":{"path":"%s","start_line":%s,"end_line":%s,"commit_sha":"%s"}}]\n' "${STUB_PATH:-x/tests/seed.tst.sh}" "${STUB_LINE:-2}" "${STUB_LINE:-2}" "$STUB_SHA" ;;
  "api repos/"*) printf '{"number":1,"state":"%s","secret_type":"linkedin_client_secret","secret":"%s"}\n' "${STUB_STATE:-open}" "$STUB_FIX" ;;
esac
EOF_GH
cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets list"*) [[ -z "${STUB_NO_LI:-}" ]] && echo csi-spl-hub-auth-linkedin-client-secret; echo csi-spl-hub-wui-key ;;
  "secrets versions list"*) printf '1\n2\n' ;;
  "secrets versions access 2"*) [[ -n "${STUB_REAL:-}" ]] && printf '%s' "$STUB_FIX" || printf 'real-two' ;;
  "secrets versions access"*) printf 'real-one' ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/"*

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u SM_ENVS HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    STUB_FIX="$FIX" STUB_SHA="$SHA" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/repo" GH_REPO=o/r ALERT=1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-secret-scan-alert-triage.func.sh; do source "$f"; done
    do_spl_secret_scan_alert_triage' >"$T/out" 2>&1
}
patches() { grep -c '^gh|api -X PATCH' "$T/calls.log"; }

# --- 1. dry run ----------------------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 && $(patches) -eq 0 ]] && grep -q 'x/tests/seed.tst.sh:2 at .* holds its secret verbatim' "$T/out" \
  && grep -q 'matches none of 4 real \*linkedin\* secret version(s) in dev prd' "$T/out" && grep -q 'DRY_RUN would resolve alert #1 of o/r as used_in_tests' "$T/out" \
  && pass "1. DRY_RUN unset: proven a fixture against 4 real versions, no PATCH" || fail "1. rc=$rc $(cat "$T/out")"
! grep -qF "$FIX" "$T/out" && ! grep -qE '[0-9a-f]{64}' "$T/out" && pass "1. neither the secret nor a full sha256 is printed" || fail "1. leaked: $(cat "$T/out")"
! grep -q 'versions access .*wui-key' "$T/calls.log" && pass "1. only *linkedin* secrets are read" || fail "1. other secret read"

# --- 2. identity per env -----------------------------------------------------------------
ok=1
for e in dev prd; do
  n=$(grep '|secrets ' "$T/calls.log" | grep -c -- "--project=csi-spl-$e")
  m=$(grep '|secrets ' "$T/calls.log" | grep -- "--project=csi-spl-$e" | grep -c -- "--account=csi-spl-$e@csi-spl-$e.iam.gserviceaccount.com")
  [[ $n -eq 4 && $n -eq $m ]] || ok=0
done
(( ok )) && pass "2. each env's calls as its own project SA" || fail "2. identity: $(cat "$T/calls.log")"

# --- 3. real run -------------------------------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc -eq 0 && $(patches) -eq 1 ]] && grep -q '^gh|api -X PATCH repos/o/r/secret-scanning/alerts/1 -f state=resolved -f resolution=used_in_tests' "$T/calls.log" \
  && pass "3. DRY_RUN=0: one PATCH resolved/used_in_tests" || fail "3. rc=$rc $(cat "$T/calls.log")"

# --- 4. CONTROL: real secret equal ----------------------------------------------------------
act DRY_RUN=0 STUB_REAL=1; rc=$?
[[ $rc -ne 0 && $(patches) -eq 0 ]] && grep -q 'EQUALS 2 real secret version(s): rotate it' "$T/out" \
  && pass "4. CONTROL: a real version holds the value -> refused, no PATCH" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5..8. refusals ------------------------------------------------------------------------
act DRY_RUN=0 STUB_PATH=x/src/seed.sh; rc=$?
[[ $rc -ne 0 && $(patches) -eq 0 ]] && grep -q 'not a test file' "$T/out" && pass "5. a non-test location -> refused" || fail "5. rc=$rc $(cat "$T/out")"
act DRY_RUN=0 STUB_LINE=1; rc=$?
[[ $rc -ne 0 && $(patches) -eq 0 ]] && grep -q 'secret is not on' "$T/out" && pass "6. the secret not on the line -> refused" || fail "6. rc=$rc $(cat "$T/out")"
act DRY_RUN=0 STUB_NO_LI=1; rc=$?
[[ $rc -ne 0 && $(patches) -eq 0 ]] && grep -q 'nothing proven' "$T/out" && pass "7. no real linkedin secret -> refused" || fail "7. rc=$rc $(cat "$T/out")"
act DRY_RUN=0 STUB_STATE=resolved; rc=$?
[[ $rc -ne 0 && $(patches) -eq 0 ]] && pass "8. a resolved alert -> refused" || fail "8. state: rc=$rc"
act ALERT=x; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "8. a bad ALERT -> refused, no call" || fail "8. alert: rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
