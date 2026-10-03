#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_domain_verify parses the siteVerification replies it gets,
#          driven with stubbed gcloud / curl that print canned JSON (no network,
#          no real gcloud): LIST prints the owned identifiers and fails on an
#          .error; VERIFY passes only when the SA is in .owners; the default
#          TOKEN mode prints the verification_records entry and fails on a
#          reply without a DNS_CNAME token, naming the API error message.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-domain-verify.func.sh"
fails=0
check() { if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fails=$((fails + 1)); fi; }
has() { if grep -qF -- "$2" "$1"; then echo "PASS: $3"; else echo "FAIL: $3 (no '$2' in $(cat "$1"))"; fails=$((fails + 1)); fi; }

bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/key.json"
export ENV=dev SPL_SA_KEY="$tmp/key.json" LOG="$tmp/log"

do_log() { echo "$*" >>"$LOG"; }
do_require_bin() { :; }
spl_require_cloud_env() { :; }
# shellcheck disable=SC2034 # read by the sourced action
do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev SPL_ORG_APP=csi-spl; }
yq() { echo example.test; }
do_gcp_isolated_active_account() { echo sa@example.test; }
do_gcp_log_identity() { :; }
gcloud() { [[ "$*" == *print-access-token* ]] && echo tok-123; return 0; }
curl() { printf '%s\n' "$CURL_OUT"; }
# shellcheck disable=SC1090
source "$FUNC"

run() { : >"$LOG"; (do_spl_domain_verify) >"$tmp/out" 2>&1; echo $?; }

rc=$(CURL_OUT='{"items":[{"site":{"identifier":"example.test"}},{"site":{"identifier":"other.test"}}]}' LIST=1 run)
check "$rc" 0 "LIST ok -> rc 0"
check "$(head -2 "$tmp/out" | tr '\n' ' ')" "example.test other.test " "LIST prints the owned identifiers"

rc=$(CURL_OUT='{"error":{"message":"denied"}}' LIST=1 run)
check "$rc" 1 "LIST with .error -> rc 1"
has "$LOG" 'FATAL "denied"' "LIST error names the API message"

rc=$(CURL_OUT='{"owners":["sa@example.test","x@example.test"]}' VERIFY=1 run)
check "$rc" 0 "VERIFY with SA in owners -> rc 0"
has "$LOG" 'owners: ["sa@example.test","x@example.test"]' "VERIFY logs the owners"

rc=$(CURL_OUT='{"error":{"message":"not verified"}}' VERIFY=1 run)
check "$rc" 1 "VERIFY without SA in owners -> rc 1"
has "$LOG" 'is not an owner of example.test: "not verified"' "VERIFY failure names the API message"

rc=$(CURL_OUT='{"token":"abc123 xyz.dv.example.net"}' run)
check "$rc" 0 "TOKEN ok -> rc 0"
has "$tmp/out" '- source: abc123.example.test.' "TOKEN prints the record source"
has "$tmp/out" 'target: xyz.dv.example.net.' "TOKEN prints the record target"

rc=$(CURL_OUT='{"error":{"message":"quota"}}' run)
check "$rc" 1 "TOKEN without a token -> rc 1"
has "$LOG" 'no DNS_CNAME token for example.test: "quota"' "TOKEN failure names the API message"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
