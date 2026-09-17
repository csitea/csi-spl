#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_plan starts by wiping the step's run dir. After a local-backend
#          apply (the 000 bootstrap) that dir holds the ONLY copy of the state,
#          so a plan must REFUSE and leave it untouched. Reported by CLE-1030
#          as D2 on 6fa4783, where 000 was forced local and `rm -rf` ran first.
#          Calls the real function with terraform stubbed by TF_BIN=/bin/true.
#          Control: with no state in the run dir the plan proceeds and re-copies.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_FILE="$PROJ_ROOT/src/bash/run/tf-plan.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl/csi-spl-iac/src/terraform/000-gcp-remote-bucket" "$T/csi-spl/csi-spl-cnf/csi-spl/dev/tf"
echo 'terraform {}' >"$T/csi-spl/csi-spl-iac/src/terraform/000-gcp-remote-bucket/01-providers.tf"
: >"$T/csi-spl/csi-spl-cnf/csi-spl/dev/tf/000-gcp-remote-bucket.vars.tfvars"
: >"$T/csi-spl/csi-spl-cnf/csi-spl/dev/tf/000-gcp-remote-bucket.backend-config.tfvars"
RUN="$T/csi-spl/csi-spl-iac/bin/csi/spl/dev/000-gcp-remote-bucket"

plan() {
  env PROJ_PATH="$T/csi-spl/csi-spl-iac" APP_PATH="$T/csi-spl" ENV=dev STEP=000-gcp-remote-bucket \
      TF_BIN=/bin/true HOME="$T/home" FUNC_FILE="$FUNC_FILE" "$@" bash -c '
    do_log() { echo "$*"; }
    do_resolve_oap() { export ORG=csi APP=spl; }
    do_require_var() { [[ -n "${2:-}" ]] || exit 1; }
    source "$FUNC_FILE"
    do_tf_plan' >"$T/out" 2>&1
}

for f in terraform.tfstate terraform.tfstate.backup .terraform.tfstate.lock.info; do
  rm -rf "$RUN"; mkdir -p "$RUN"; echo '{"serial": 7}' >"$RUN/$f"
  plan TF_BACKEND=local; rc=$?
  if [[ $rc -ne 0 && "$(cat "$RUN/$f" 2>/dev/null)" == '{"serial": 7}' ]] && grep -q "refusing to wipe" "$T/out"; then
    pass "a run dir holding $f is refused and the file is untouched"
  else
    fail "a run dir holding $f: rc=$rc, file now: $(cat "$RUN/$f" 2>/dev/null || echo GONE)"
  fi
done

# The refusal does not depend on the backend chosen for the new plan.
rm -rf "$RUN"; mkdir -p "$RUN"; echo '{"serial": 7}' >"$RUN/terraform.tfstate"
plan; rc=$?
[[ $rc -ne 0 && -f "$RUN/terraform.tfstate" ]] && pass "refused with the default gcs backend too" || fail "gcs backend: rc=$rc"

# Control: an empty run dir is wiped and re-copied, and the plan goes on.
rm -rf "$RUN"; mkdir -p "$RUN"; echo stale >"$RUN/stale.tf"
plan TF_BACKEND=local; rc=$?
if [[ $rc -eq 0 && ! -e "$RUN/stale.tf" && -f "$RUN/01-providers.tf" && -f "$RUN/backend_override.tf" ]]; then
  pass "control: without state the run dir is re-copied (local override written for 000 too)"
else
  fail "control: rc=$rc; $(tail -3 "$T/out")"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
