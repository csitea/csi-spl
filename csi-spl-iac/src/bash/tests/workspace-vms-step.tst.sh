#!/usr/bin/env bash
# pre-push-tier: slow -- terraform init + test of one step (provider download)
# test-timeout: 480 -- the tf-steps-render-and-validate budget: one init per run
#------------------------------------------------------------------------------
# Purpose: spec 181 row B5. Step 062-gcp-workspace-vms plans one private VM
#          per private workspace: for_each over the cnf map workspace_vms
#          (<tenant> -> machine type), each VM and its boot disk labelled
#          workspace=<tenant> and box=<instance name>. PLAN ONLY. Proven with
#          `terraform test` on a mocked provider: no GCP, no state, no apply.
#   1. the VM map is no cnf key and never rendered: both renders mark it
#      '# runtime-vars: workspace_vms' and carry no workspace_vms line
#   2. an empty map plans no resource (no VPC, no rule, no VM, no account)
#   3. two entries plan two VMs, each labelled by its tenant and its name,
#      boot disk included, one VPC and one tcp/22 rule between them
#   4. a key that is no tenant id (no valid workspace label) is refused, and
#      so is one ending in '-' (no valid instance name)
#   4b. RED CONTROL (R7 W1): TF_VAR_workspace_vms with the rendered dev
#      -var-file plans its VM; a -var-file carrying workspace_vms = {} (the
#      3a8561316 render) beats TF_VAR_* and plans none
#   5. RED CONTROL (the row's): an entry without a workspace label is
#      refused by the step's check (a copy of the step whose label line is
#      removed), and the same run on the real step fails with "Missing
#      expected failure": the real step labels every entry
#   terraform: $TF_BIN, else the newest $HOME/.local/share/csi-spl/bin/terraform-*,
#   else terraform on PATH; none is a FAIL unless SPL_TF_ALLOW_SKIP=1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP=062-gcp-workspace-vms
SD="$PROJ_ROOT/src/terraform/$STEP"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0

# --- 1. the cnf map and its renders --------------------------------------------
[[ -f "$SD/03-vm.tf" ]] && pass "$STEP exists" || { fail "$STEP is missing ($SD)"; echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
! grep -q 'workspace_vms:' "$CNF/all.env.yaml" \
  && pass "all.env.yaml: workspace_vms is no cnf key (tenant ids are not committed)" || fail "all.env.yaml carries workspace_vms"
for env in dev prd; do
  grep -qx '# runtime-vars: workspace_vms' "$CNF/$env/tf/$STEP.vars.tfvars" \
    && ! grep -qE '^workspace_vms[[:space:]]*=' "$CNF/$env/tf/$STEP.vars.tfvars" \
    && grep -qx "prefix = \"terraform/$STEP\"" "$CNF/$env/tf/$STEP.backend-config.tfvars" \
    && pass "$env render: workspace_vms is a runtime var, never rendered; state under terraform/$STEP" || fail "$env render of $STEP drifted (a rendered workspace_vms beats TF_VAR_workspace_vms)"
done

TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
if [[ -z "$TF" || ! -x "$TF" ]]; then
  if [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then echo "PARTIAL: no terraform, sections 2..5 SKIPPED"; exit $((fails > 0)); fi
  fail "no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH); SPL_TF_ALLOW_SKIP=1 for a PARTIAL run"
  echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM
mkdir -p "$tmp/cache"

plan_runs() {
  cat <<'HCL'
mock_provider "google" {}

run "empty_map_plans_nothing" {
  command = plan
  assert {
    condition = (length(google_compute_instance.workspace) + length(google_compute_network.workspace)
      + length(google_compute_firewall.ssh) + length(google_service_account.workspace)
    + length(google_project_iam_member.workspace)) == 0
    error_message = "an empty workspace_vms planned a resource"
  }
}

run "two_entries_labelled" {
  command = plan
  variables {
    workspace_vms = { "tenant-a" = "e2-standard-2", "0b" = "e2-medium" }
  }
  assert {
    condition     = length(google_compute_instance.workspace) == 2 && length(google_compute_network.workspace) == 1 && length(google_compute_firewall.ssh) == 1
    error_message = "two entries did not plan two VMs in one VPC with one rule"
  }
  assert {
    condition = alltrue([for t, vm in google_compute_instance.workspace :
      vm.labels.workspace == t && vm.labels.box == "csi-spl-dev-ws-${t}" && vm.name == "csi-spl-dev-ws-${t}"
      && vm.boot_disk[0].initialize_params[0].labels.workspace == t
    && vm.boot_disk[0].initialize_params[0].labels.box == "csi-spl-dev-ws-${t}"])
    error_message = "a VM or its boot disk is not labelled workspace=<tenant>, box=<name>"
  }
  assert {
    condition     = google_compute_instance.workspace["0b"].machine_type == "e2-medium"
    error_message = "the machine type is not the map's value"
  }
}

run "no_tenant_id_refused" {
  command = plan
  variables {
    workspace_vms = { "Tenant_A" = "e2-standard-2" }
  }
  expect_failures = [var.workspace_vms]
}

run "trailing_dash_refused" {
  command = plan
  variables {
    workspace_vms = { "abc-" = "e2-standard-2" }
  }
  expect_failures = [var.workspace_vms]
}
HCL
}

# the map comes from TF_VAR_workspace_vms, so this run sets no variables
tfvar_run() {
  cat <<'HCL'
mock_provider "google" {}

run "tf_var_map_plans_its_vm" {
  command = plan
  assert {
    condition     = length(google_compute_instance.workspace) == 1 && contains(keys(google_compute_instance.workspace), "tenant-a")
    error_message = "TF_VAR_workspace_vms did not reach the plan: a -var-file value beats it"
  }
}
HCL
}

nolabel_run() {
  cat <<'HCL'
mock_provider "google" {}

run "entry_without_workspace_label_refused" {
  command = plan
  variables {
    workspace_vms = { "tenant-a" = "e2-standard-2" }
  }
  expect_failures = [google_compute_instance.workspace]
}
HCL
}

# tf_run <step dir copy> <hcl fn> [var-file]: init (3 tries, flaky download) + test
tf_run() {
  local dir=$1 vf=${3:-$CNF/dev/tf/$STEP.vars.tfvars} _
  mkdir -p "$dir/tests"
  "$2" >"$dir/tests/b5.tftest.hcl"
  for _ in 1 2 3; do
    TF_PLUGIN_CACHE_DIR="$tmp/cache" "$TF" -chdir="$dir" init -backend=false -input=false -no-color >"$dir.log" 2>&1 && break
  done
  TF_PLUGIN_CACHE_DIR="$tmp/cache" "$TF" -chdir="$dir" test -no-color -var-file="$vf" >>"$dir.log" 2>&1
}

# --- 2..4. the real step --------------------------------------------------------
cp -r "$SD" "$tmp/real"
if tf_run "$tmp/real" plan_runs; then
  pass "$STEP: an empty map plans nothing; two entries plan two labelled VMs; a non-tenant key is refused"
else
  fail "$STEP plan runs"; grep -E 'run "|Error|Failure' "$tmp/real.log" | sed 's/^/      /'
fi

# --- 4b. W1's red control: TF_VAR_workspace_vms against the var-file -------------
cp -r "$SD" "$tmp/tfvar"
if TF_VAR_workspace_vms='{"tenant-a"="e2-medium"}' tf_run "$tmp/tfvar" tfvar_run; then
  pass "TF_VAR_workspace_vms with the rendered dev var-file plans its VM"
else
  fail "TF_VAR_workspace_vms with the rendered dev var-file plans no VM"; grep -E 'run "|Error|Failure' "$tmp/tfvar.log" | sed 's/^/      /'
fi
{ cat "$CNF/dev/tf/$STEP.vars.tfvars"; echo 'workspace_vms = {}'; } >"$tmp/rendered-map.tfvars"
cp -r "$SD" "$tmp/tfvar-red"
if ! TF_VAR_workspace_vms='{"tenant-a"="e2-medium"}' tf_run "$tmp/tfvar-red" tfvar_run "$tmp/rendered-map.tfvars" \
  && grep -q 'TF_VAR_workspace_vms did not reach the plan' "$tmp/tfvar-red.log"; then
  pass "RED CONTROL: a var-file carrying workspace_vms = {} beats TF_VAR_workspace_vms (plans no VM)"
else
  fail "RED CONTROL: a rendered workspace_vms = {} did not beat TF_VAR_workspace_vms: the check above proves nothing"
fi

# --- 5. the row's red control ---------------------------------------------------
cp -r "$SD" "$tmp/nolabel"
grep -vE '^\s*workspace = tenant$' "$SD/03-vm.tf" >"$tmp/nolabel/03-vm.tf"
if ! grep -q 'workspace = tenant' "$tmp/nolabel/03-vm.tf" && tf_run "$tmp/nolabel" nolabel_run; then
  pass "RED CONTROL: an entry without a workspace label is refused by the step's check"
else
  fail "RED CONTROL: an entry without a workspace label plans"; grep -E 'run "|Error|Failure' "$tmp/nolabel.log" | sed 's/^/      /'
fi
cp -r "$SD" "$tmp/labelled"
if ! tf_run "$tmp/labelled" nolabel_run && grep -q 'Missing expected failure' "$tmp/labelled.log"; then
  pass "CONTROL: the same entry on the real step plans (it carries the workspace label)"
else
  fail "CONTROL: the real step refuses a labelled entry, or the run proves nothing"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
