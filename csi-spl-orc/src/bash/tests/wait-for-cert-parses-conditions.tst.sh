#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: prove that do_wait_for_cert can actually SEE an ACTIVE Certificate
#          Manager cert -- by running it against a stubbed gcloud, not by
#          reading it.
#
#          The donor (csi-rel-orc) used
#            --format='value(status.conditions[?type=CertificateProvisioned].status)'
#          The [?key=value] predicate is not supported by this gcloud and
#          yields an EMPTY string whether the condition is True, False or
#          absent, so the loop could never succeed. pas-psf-orc F-28 is that
#          finding; this copy polls managed.state instead (031 is Certificate
#          Manager, not a Cloud Run domain mapping) and the test still drives
#          the function with a stub, not a grep of the source.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/wait-for-cert.func.sh"

fails=0
check() {
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got rc=$1, want $2)"; fails=$((fails+1)); fi
}

[[ -f "$FUNC" ]] || { echo "FAIL: function not found: $FUNC"; exit 1; }
bash -n "$FUNC" || { echo "FAIL: bash -n on $FUNC"; exit 1; }
echo "PASS: bash -n wait-for-cert.func.sh"

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
STUB_LOG="$STUB_DIR/calls.log"
: >"$STUB_LOG"

cat > "$STUB_DIR/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"${STUB_LOG:-/dev/null}"
case "${CERT_FIXTURE:-}" in
  provisioned) printf 'ACTIVE\n' ;;
  pending)     printf 'PROVISIONING\n' ;;
  failed)      printf 'FAILED\n' ;;
  absent)      exit 1 ;;
  *)           printf '' ;;
esac
STUB
chmod +x "$STUB_DIR/gcloud"
export STUB_LOG
PATH="$STUB_DIR:$PATH"

COMMON=(DOMAIN=example.test GCP_PROJECT=proj-test GCP_ACCOUNT=op@example.com
        CERT_NAME=proj-test-hub-cert TIMEOUT_SECONDS=1 POLL_SECONDS=1)

run_case() {
  env "${COMMON[@]}" CERT_FIXTURE="$1" STUB_LOG="$STUB_LOG" PATH="$PATH" bash -c '
    do_log() { :; }
    do_require_bin() { command -v "$1" >/dev/null 2>&1; }
    source "'"$FUNC"'"
    do_wait_for_cert
  ' >/dev/null 2>&1
  echo $?
}

check "$(run_case provisioned)" 0 "an ACTIVE certificate returns 0"
check "$(run_case pending)" 1 "a PROVISIONING certificate does not read as ACTIVE"
check "$(run_case failed)" 1 "a FAILED certificate does not read as ACTIVE"
check "$(run_case absent)" 1 "an absent certificate does not read as ACTIVE"

check "$(env GCP_PROJECT=p GCP_ACCOUNT=a PATH="$PATH" bash -c 'do_log(){ :; }; do_require_bin(){ return 0; }; source "'"$FUNC"'"; do_wait_for_cert' >/dev/null 2>&1; echo $?)" 1 "missing DOMAIN is refused"
check "$(env DOMAIN=d GCP_ACCOUNT=a PATH="$PATH" bash -c 'do_log(){ :; }; do_require_bin(){ return 0; }; source "'"$FUNC"'"; do_wait_for_cert' >/dev/null 2>&1; echo $?)" 1 "missing GCP_PROJECT is refused"
check "$(env DOMAIN=d GCP_PROJECT=p PATH="$PATH" bash -c 'do_log(){ :; }; do_require_bin(){ return 0; }; source "'"$FUNC"'"; do_wait_for_cert' >/dev/null 2>&1; echo $?)" 1 "missing GCP_ACCOUNT is refused"

: >"$STUB_LOG"
env "${COMMON[@]}" CERT_FIXTURE=provisioned STUB_LOG="$STUB_LOG" PATH="$PATH" bash -c '
  do_log() { :; }
  do_require_bin() { command -v "$1" >/dev/null 2>&1; }
  source "'"$FUNC"'"
  do_wait_for_cert
' >/dev/null 2>&1
if grep -q -- '--account=op@example.com' "$STUB_LOG" && grep -q -- '--project=proj-test' "$STUB_LOG"; then
  echo "PASS: describe passes --account and --project"
else
  echo "FAIL: describe did not pass --account/--project: $(tr '\n' ';' <"$STUB_LOG")"
  fails=$((fails+1))
fi
if grep -q 'config set' "$STUB_LOG" || grep -q 'activate-service-account' "$STUB_LOG"; then
  echo "FAIL: gcloud wrote shared config: $(tr '\n' ';' <"$STUB_LOG")"
  fails=$((fails+1))
else
  echo "PASS: describe does not config set / activate-service-account"
fi

echo "--- Summary: wait-for-cert-parses-conditions $fails failed ---"
[[ $fails -eq 0 ]]
