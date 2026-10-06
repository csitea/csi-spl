#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_export_json_section_vars_as_tf_vars is sourced into ./run, so a
#          refusal must RETURN, not exit: an exit kills the whole ./run and
#          skips execute_step's POST hook and error handler.
#          1. a missing json file returns 1 and the calling shell survives.
#          2. an empty section returns 1 and the calling shell survives.
#          3. a section absent from the file is skipped: returns 0.
#          4. a present section exports its string values as TF_VAR_<KEY>.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '{"env":{"steps":{"s1":{"gcp_region":"europe-north1","n":3}}}}\n' >"$T/env.json"

# <json-file> <section>: prints rc=<rc>, the exported var, then SURVIVED if the shell lived on
run_export() {
  env -i PATH="$PATH" HOME="$T" FUNC="$PROJ_ROOT/src/bash/run/export-json-section-vars-as-tf-vars.func.sh" \
    bash -c '
      do_log() { :; }
      source "$FUNC"
      do_export_json_section_vars_as_tf_vars "$1" "$2"
      echo "rc=$?"
      echo "TF_VAR_GCP_REGION=${TF_VAR_GCP_REGION:-}"
      echo SURVIVED
    ' _ "$1" "$2" 2>&1
}

out=$(run_export "$T/absent.json" '.env.steps.s1')
if grep -qx 'rc=1' <<<"$out" && grep -qx SURVIVED <<<"$out"; then
  pass "missing json file: returns 1, the calling shell survives"
else
  fail "missing json file: want rc=1 + SURVIVED, got: $(tr '\n' ' ' <<<"$out")"
fi

out=$(run_export "$T/env.json" '')
if grep -qx 'rc=1' <<<"$out" && grep -qx SURVIVED <<<"$out"; then
  pass "empty section: returns 1, the calling shell survives"
else
  fail "empty section: want rc=1 + SURVIVED, got: $(tr '\n' ' ' <<<"$out")"
fi

out=$(run_export "$T/env.json" '.env.steps.nope')
if grep -qx 'rc=0' <<<"$out" && grep -qx 'TF_VAR_GCP_REGION=' <<<"$out"; then
  pass "absent section: skipped, returns 0, exports nothing"
else
  fail "absent section: want rc=0 and no export, got: $(tr '\n' ' ' <<<"$out")"
fi

out=$(run_export "$T/env.json" '.env.steps.s1')
if grep -qx 'rc=0' <<<"$out" && grep -qx 'TF_VAR_GCP_REGION=europe-north1' <<<"$out"; then
  pass "present section: TF_VAR_GCP_REGION exported, returns 0"
else
  fail "present section: want rc=0 + TF_VAR_GCP_REGION=europe-north1, got: $(tr '\n' ' ' <<<"$out")"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
