#!/usr/bin/env bash
# pre-push-tier: slow -- terraform init + test of two steps (provider download)
# test-timeout: 480 -- the tf-steps-render-and-validate budget: one init per step
#------------------------------------------------------------------------------
# Purpose: SPL-5262. A GCE persistent disk cannot shrink, so a smaller
#          data_disk_size_gb plans as destroy + create of the data disk (its
#          data wiped) unless the plan refuses it. Steps 060 (the satellite)
#          and 061 (the wine box, data_disk_enabled) carry a precondition that
#          reads the LIVE disk (08-data-disk-guard.tf). Proven with
#          `terraform test` on mocked providers: no GCP, no state, no apply.
#   1. the same size and a grow plan; a shrink and a type change are refused
#      (061: a rename too); with no applied state (after a destroy drill, or
#      061 with its data disk off) any size plans.
#   2. the remote-state read points at the step's own backend-config render.
#   3. 060 still has no prevent_destroy (the owner's destroy drills).
#   4. CONTROL: the same runs against a step whose precondition is removed
#      FAIL ("Missing expected failure": the refused change plans), so the
#      PASS of 1 comes from the guard.
#   terraform: $TF_BIN, else the newest $HOME/.local/share/csi-spl/bin/terraform-*,
#   else terraform on PATH; none is a FAIL unless SPL_TF_ALLOW_SKIP=1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
TFD="$PROJ_ROOT/src/terraform"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0

# --- 2. the remote state is the step's own -------------------------------------
for s in prd/060-gcp-vm-satellite dev/061-gcp-vm-wine-box; do
  env=${s%%/*} step=${s#*/}
  proj=$(sed -nE 's/^gcp_project *= *"(.*)"$/\1/p' "$CNF/$env/tf/$step.vars.tfvars")
  b="$CNF/$env/tf/$step.backend-config.tfvars"
  grep -qx "bucket = \"$proj-tfstate\"" "$b" && grep -qx "prefix = \"terraform/$step\"" "$b" \
    && grep -qF 'bucket = "${var.gcp_project}-tfstate"' "$TFD/$step/08-data-disk-guard.tf" \
    && grep -qF 'prefix = "terraform/${local.labels.step}"' "$TFD/$step/08-data-disk-guard.tf" \
    && grep -qE "^\s*step\s*=\s*\"$step\"" "$TFD/$step/03-vm.tf" \
    && pass "$step reads its own state ($proj-tfstate, terraform/$step)" || fail "$step guard state != its backend-config ($b)"
done

# --- 3. drills stay possible ----------------------------------------------------
grep -qE '^\s*prevent_destroy\s*=\s*true' "$TFD/060-gcp-vm-satellite/03-vm.tf" \
  && fail "060 carries prevent_destroy: the owner's destroy drill is blocked" || pass "060 has no prevent_destroy (destroy drills run)"

# --- 1. + 4. terraform test -------------------------------------------------------
TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
if [[ -z "$TF" || ! -x "$TF" ]]; then
  if [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then echo "PARTIAL: no terraform, section 1 SKIPPED"; exit $((fails > 0)); fi
  fail "no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH); SPL_TF_ALLOW_SKIP=1 for a PARTIAL run"
  echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM
mkdir -p "$tmp/cache"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test" >"$tmp/k.pub"

# the runs both steps share; $1 = the mocked live disk's name, $2 = extra variables
common_runs() {
  cat <<HCL
mock_provider "google" {}
mock_provider "local" {}

override_data {
  target = data.google_compute_disk.data_live
  values = { name = "$1", size = 200, type = "pd-balanced" }
}

variables {
  data_disk_name    = "$1"
  data_disk_size_gb = 200
  data_disk_type    = "pd-balanced"
$2
}

run "same_size_plans" {
  command = plan
}

run "grow_plans" {
  command = plan
  variables {
    data_disk_size_gb = 300
  }
  assert {
    condition     = local.data_disk_keeps
    error_message = "a grow was refused"
  }
}

run "shrink_refused" {
  command = plan
  variables {
    data_disk_size_gb = 150
  }
  expect_failures = [google_compute_disk.data]
}

run "type_change_refused" {
  command = plan
  variables {
    data_disk_type = "pd-ssd"
  }
  expect_failures = [google_compute_disk.data]
}

run "no_applied_state_any_size_plans" {
  command = plan
  override_data {
    target = data.terraform_remote_state.self
    values = { outputs = {} }
  }
  variables {
    data_disk_size_gb = 150
  }
}
HCL
}

tf_060() {
  cat <<'HCL'
override_data {
  target = data.terraform_remote_state.self
  values = { outputs = { instance_name = "satellite" } }
}

HCL
  common_runs csi-spl-all-satellite-data ""
}

tf_061() {
  cat <<'HCL'
override_data {
  target = data.terraform_remote_state.self
  values = { outputs = { data_disk_name = "csi-spl-dev-wine-box-data" } }
}

run "rename_refused" {
  command = plan
  variables {
    data_disk_name = "csi-spl-dev-wine-box-data-2"
  }
  expect_failures = [google_compute_disk.data]
}

run "disk_off_any_size_plans" {
  command = plan
  variables {
    data_disk_enabled = false
    data_disk_size_gb = 150
  }
}

HCL
  common_runs csi-spl-dev-wine-box-data "  data_disk_enabled = true"
}

# tf_run <step dir copy> <tfvars> <hcl fn>: init (3 tries, flaky download) + test
tf_run() {
  local dir=$1 vars=$2 _
  mkdir -p "$dir/tests"
  "$3" >"$dir/tests/guard.tftest.hcl"
  for _ in 1 2 3; do
    TF_PLUGIN_CACHE_DIR="$tmp/cache" "$TF" -chdir="$dir" init -backend=false -input=false -no-color >"$dir.log" 2>&1 && break
  done
  TF_PLUGIN_CACHE_DIR="$tmp/cache" "$TF" -chdir="$dir" test -no-color -var-file="$vars" \
    -var ssh_public_key_file="$tmp/k.pub" >>"$dir.log" 2>&1
}

for s in prd/060-gcp-vm-satellite dev/061-gcp-vm-wine-box; do
  env=${s%%/*} step=${s#*/} n=${step%%-*}
  cp -r "$TFD/$step" "$tmp/$n"
  if tf_run "$tmp/$n" "$CNF/$env/tf/$step.vars.tfvars" "tf_$n"; then
    pass "$step: same size and grow plan; shrink and type change refused; no applied state plans"
  else
    fail "$step guard runs"; grep -E 'run "|Error|Failure' "$tmp/$n.log" | sed 's/^/      /'
  fi
  # 4. control: no precondition, the same runs must fail (a refused change plans)
  cp -r "$TFD/$step" "$tmp/$n-ctl"
  awk '/^  lifecycle \{/ { skip = 1 } !skip { print } skip && /^  \}/ { skip = 0 }' "$TFD/$step/03-vm.tf" >"$tmp/$n-ctl/03-vm.tf"
  if ! grep -q precondition "$tmp/$n-ctl/03-vm.tf" && ! tf_run "$tmp/$n-ctl" "$CNF/$env/tf/$step.vars.tfvars" "tf_$n" \
    && grep -q 'Missing expected failure' "$tmp/$n-ctl.log"; then
    pass "CONTROL $step: without the precondition a refused change plans and the runs fail"
  else
    fail "CONTROL $step: the runs pass without the precondition, so they prove nothing"
  fi
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
