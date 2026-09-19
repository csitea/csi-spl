#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wait_for_mapping_cert's poll SEES a provisioned Cloud Run
#          domain-mapping cert, driven with a stubbed gcloud (not a grep):
#          CertificateProvisioned True -> 0; False / absent / describe error
#          at the deadline -> 1. Control for the donor bug (pas-psf F-28): the
#          csi-rel [?type=...] format predicate is empty on this gcloud, so a
#          poll built on it could never return 0 -- this one parses json.
#          Every stubbed call carries --account; none writes gcloud config.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-wait-for-mapping-cert.func.sh"
fails=0
check() { if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got rc=$1, want $2)"; fails=$((fails + 1)); fi; }

bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$STUB_MODE" in
  true)   echo '{"status":{"conditions":[{"type":"Ready","status":"Unknown"},{"type":"CertificateProvisioned","status":"True"}],"resourceRecords":[{"name":"t1","type":"CNAME","rrdata":"ghs.googlehosted.com."}]}}' ;;
  false)  echo '{"status":{"conditions":[{"type":"CertificateProvisioned","status":"False"}]}}' ;;
  absent) echo '{"status":{}}' ;;
  error)  echo 'ERROR: not found' >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gcloud"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log"
do_log() { :; }
# shellcheck disable=SC1090
source "$FUNC"

for m in true false absent error; do
  : >"$STUB_LOG"
  STUB_MODE=$m spl_mapping_cert_poll t1.dev.example.test csi-spl-dev europe-north1 sa@example.test 0 0 >/dev/null 2>&1
  rc=$?
  [[ $m == true ]] && want=0 || want=1
  check "$rc" "$want" "CertificateProvisioned=$m -> rc $want"
done
grep -q -- '--account=sa@example.test' "$STUB_LOG" && echo "PASS: describe carries --account" || { echo "FAIL: describe without --account"; fails=$((fails + 1)); }
grep -qE 'config set|activate-service-account' "$STUB_LOG" && { echo "FAIL: poll writes gcloud config"; fails=$((fails + 1)); } || echo "PASS: poll does not write gcloud config"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
