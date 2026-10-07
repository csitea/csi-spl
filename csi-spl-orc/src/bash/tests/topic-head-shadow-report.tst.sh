#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_head_shadow_report (spec 099 T006) with gcloud
#          stubbed by a fixture of hub log lines.
#   1. the counts: compared and mismatched summed per shape over the
#      topic_head_shadow lines, topic_head_mismatch lines counted per shape
#   2. 0 mismatches is exit 0; one mismatch (counter or line) is exit 3
#   3. the read filters the env's service and both messages, as the SA
#   4. a bad SHADOW_HOURS is refused before any call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

printf 'env:\n  hub:\n    service_name: hub-svc\n' >"$T/cnf.yaml"
mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
printf 'gcloud' >>"$STUB_LOG"; for a in "$@"; do printf ' [%s]' "$a" >>"$STUB_LOG"; done; echo >>"$STUB_LOG"
cat "$LOG_FIXTURE"
STUB
chmod +x "$T/stub/gcloud"
STUBS='do_spl_cloud_cnf() { SPL_CNF="$CNF"; SPL_PROJECT=p-dev; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }'
run() { # [VAR=value]...
  : >"$T/calls.log"
  SNIPPET="$STUBS; do_spl_topic_head_shadow_report" in_orc CNF="$T/cnf.yaml" LOG_FIXTURE="$T/log.json" "$@" 2>&1
}
sh_line() { printf '{"jsonPayload":{"message":"topic_head_shadow","shape":"%s","compared":%s,"mismatched":%s}}' "$1" "$2" "$3"; }

# 1 + 2 ----------------------------------------------------------------------
printf '[%s,%s,%s,{"jsonPayload":{"message":"other"}}]' "$(sh_line dm 120 0)" "$(sh_line dm 80 0)" "$(sh_line all 300 0)" >"$T/log.json"
out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'compared=500 mismatched=0 mismatch_lines=0 shapes=2' <<<"$out" \
  && grep -qE '^dm +200 +0 +0$' <<<"$out" && grep -qE '^all +300 +0 +0$' <<<"$out" \
  && pass "1. compares summed per shape (dm 200, all 300, n=500); 0 mismatches is exit 0" || fail "1. rc=$rc $out"
printf '[%s,%s,{"jsonPayload":{"message":"topic_head_mismatch","shape":"dm","tenant":"t1"}}]' \
  "$(sh_line dm 120 1)" "$(sh_line channel 40 0)" >"$T/log.json"
out="$(run)"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'compared=160 mismatched=1 mismatch_lines=1 shapes=2' <<<"$out" && grep -qE '^dm +120 +1 +1$' <<<"$out" \
  && pass "2. one mismatch is counted and exits 3" || fail "2. rc=$rc $out"
printf '[{"jsonPayload":{"message":"topic_head_mismatch","shape":"all"}}]' >"$T/log.json"
out="$(run)"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'compared=0 mismatched=0 mismatch_lines=1' <<<"$out" \
  && pass "2. a mismatch line alone (no counter yet) exits 3" || fail "2. line only: rc=$rc $out"
printf '[]' >"$T/log.json"
out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'compared=0 mismatched=0 mismatch_lines=0 shapes=0' <<<"$out" \
  && pass "2. an empty window reads n=0" || fail "2. empty: rc=$rc $out"

# 3 --------------------------------------------------------------------------
grep -q 'resource.labels.service_name="hub-svc"' "$T/calls.log" && grep -q 'jsonPayload.message="topic_head_shadow" OR jsonPayload.message="topic_head_mismatch"' "$T/calls.log" \
  && grep -q '\[--project=p-dev\] \[--account=sa@example.com\]' "$T/calls.log" \
  && pass "3. one logging read of the service's two messages, as the SA" || fail "3. call: $(cat "$T/calls.log")"

# 4 --------------------------------------------------------------------------
out="$(run SHADOW_HOURS=0)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'SHADOW_HOURS must be 1..168' <<<"$out" && [[ ! -s "$T/calls.log" ]] \
  && pass "4. a bad SHADOW_HOURS is refused before any call" || fail "4. rc=$rc $out"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
