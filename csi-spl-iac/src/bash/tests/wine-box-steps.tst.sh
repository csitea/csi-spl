#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the wine-box steps (058 budget, 061 VM), offline:
#   dev only, own VPC, no Cloud NAT, one ingress rule (tcp/22), the public
#   address is the CKV_GCP_40 exception, ansible-only keys stay out of tfvars,
#   and the prd render is the dev-only marker the cover test skips.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
TF="$PROJ_ROOT/src/terraform"
TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

b058="$TF/058-gcp-wine-box-budget"
b061="$TF/061-gcp-vm-wine-box"
[[ -f "$b058/03-budget.tf" && -f "$b061/03-vm.tf" && -f "$b061/05-network.tf" ]] \
  && pass "058 and 061 exist" || fail "058 or 061 is missing"

grep -q 'var.env == "dev"' "$b058/02-variables.tf" && grep -q 'var.env == "dev"' "$b061/02-variables.tf" \
  && pass "both steps refuse any env but dev" || fail "env validation is not dev-only"

! grep -q 'google_compute_router' "$b061"/*.tf \
  && pass "061 has no Cloud NAT router" || fail "061 declares a router"
grep -q 'ports    = \["22"\]' "$b061/05-network.tf" \
  && [[ "$(grep -c 'google_compute_firewall' "$b061/05-network.tf")" == 1 ]] \
  && pass "the only firewall is one rule, tcp/22" || fail "firewall is not a single tcp/22 rule"
grep -q '0.0.0.0/0' "$b061/02-variables.tf" && grep -q '::/0' "$b061/02-variables.tf" \
  && pass "ssh_source_ranges rejects the whole internet" || fail "no rejection of 0.0.0.0/0"
grep -q 'assign_external_ip ? \[1\] : \[\]' "$b061/03-vm.tf" \
  && pass "the public address is gated on assign_external_ip" || fail "access_config is not gated"
grep -q 'CKV_GCP_40' "$b061/03-vm.tf" \
  && pass "the public address carries the CKV_GCP_40 skip" || fail "no CKV_GCP_40 skip"
grep -q 'block-project-ssh-keys  = "TRUE"' "$b061/03-vm.tf" \
  && pass "project-wide ssh keys are blocked" || fail "block-project-ssh-keys is not TRUE"
grep -q 'debian-13-trixie-v\[0-9\]{8}' "$b061/02-variables.tf" \
  && pass "the boot image must be a dated trixie image" || fail "boot image validation drifted"
grep -q 'for_each = toset(var.iap_members)' "$b061/06-iap.tf" \
  && ! grep -qE 'member\s*=\s*"user:' "$b061"/*.tf \
  && pass "an empty iap_members list adds no binding" || fail "iap members are not the cnf list"
grep -q 'for disk in google_compute_disk.data' "$b061/03-vm.tf" \
  && pass "a disabled data disk is an empty for_each map" || fail "attached_disk for_each is not a map"
! grep -Eq '^[[:space:]]*currency_code[[:space:]]*=' "$b058/03-budget.tf" \
  && grep -q 'var.budget_label_key' "$b058/03-budget.tf" \
  && pass "the budget amount has no currency_code and filters on the label" || fail "budget shape drifted"
! grep -q 'variable "ansible_step"' "$b061"/*.tf \
  && pass "no ansible_step variable (it is not in tfvars)" || fail "ansible_step is declared"
grep -q -- '-e @' "$b061/07-ansible.tf" \
  && pass "the generated playbook run passes -e @<vars>" || fail "the run script does not pass -e @file"

v061="$TPL/061-gcp-vm-wine-box.vars.tfvars.tpl"
v058="$TPL/058-gcp-wine-box-budget.vars.tfvars.tpl"
grep -q '# dev-only-step' "$v061" && grep -q 'ENV != "dev"' "$v061" \
  && grep -q '# dev-only-step' "$v058" \
  && pass "prd renders of 058 and 061 are the dev-only marker" || fail "templates do not emit the dev-only marker"
grep -q 'runtime-vars: proj_path' "$v061" && grep -q 'runtime-vars: billing_account_id' "$v058" \
  && pass "proj_path and billing_account_id are runtime vars" || fail "runtime-vars markers missing"
grep -q 'timezone' "$v061" && grep -q 'vnc_passwd_bin' "$v061" && grep -q 'not in' "$v061" \
  && pass "the tfvars template drops the ansible-only keys" || fail "ansible-only keys are not excluded"
! grep -q 'gcp\["gcp_region"\]' "$v061" \
  && pass "061 does not take the region from env.gcp" || fail "061 region comes from env.gcp"

grep -q '# dev-only-step' "$PROJ_ROOT/src/bash/tests/tfvars-cover-declared-vars.tst.sh" \
  && pass "the cover test skips a dev-only step" || fail "the cover test has no dev-only skip"

grep -q 'e2-standard-2' "$CNF/dev.env.yaml" && grep -q 'europe-west2-a' "$CNF/dev.env.yaml" \
  && grep -q 'debian-13-trixie-v20261006' "$CNF/dev.env.yaml" && grep -q '10.81.0.0/24' "$CNF/dev.env.yaml" \
  && grep -q 'assign_external_ip: true' "$CNF/dev.env.yaml" && grep -q 'budget_amount_month: 180' "$CNF/dev.env.yaml" \
  && grep -q '35.235.240.0/20' "$CNF/dev.env.yaml" \
  && pass "dev cnf has the wine-box size, zone, image and budget" || fail "dev cnf is missing a wine-box value"
! grep -q '061-gcp-vm-wine-box:' "$CNF/prd.env.yaml" && ! grep -q '058-gcp-wine-box-budget:' "$CNF/prd.env.yaml" \
  && pass "prd cnf has no wine-box step" || fail "prd cnf contains a wine-box step"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
