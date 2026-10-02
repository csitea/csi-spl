#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 057 (the satellite) — the two prd-only steps stay what the
#          owner approved, statically (no terraform, no network; fast tier):
#   1. 060 has exactly ONE firewall rule: INGRESS tcp/22 from the cnf ranges,
#      and the prd ranges are the Google IAP range only (R7, round 1 Q7 A).
#   2. no web: no port 80/443/8080/8443, no http/https tag, no LB/DNS resource.
#   3. no key in state (R14, round 2 Q3 b): no tls_private_key,
#      google_service_account_key or local_sensitive_file; the ssh key var is
#      the .pub half.
#   4. the image is a DATED debian-13-trixie image (R16).
#   5. both steps refuse any env but prd, and the dev renders carry no step
#      values (one satellite, in the prd project: R1, R2).
#   6. the budget (059) filters on the label 060 puts on the VM + data disk,
#      and the tf-runner make targets pass GCP_BILLING_ACCOUNT_ID through.
#   7. CONTROL: a planted second ingress rule is caught by check 1.
#   8. both steps run in csi-spl-all (owner 2026-10-01), as its SA, with the
#      state in its own bucket (the 046 pattern), on the satellite's own VPC.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
TFD="$PROJ_ROOT/src/terraform"
VM="$TFD/060-gcp-vm-satellite"
BUD="$TFD/059-gcp-satellite-budget"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0

[[ -d "$VM" && -d "$BUD" ]] && pass "059 and 060 steps exist" || fail "059/060 step dir missing"

# --- 1. exactly one ingress rule, tcp/22 --------------------------------------
# grep reads the files itself: 'cat *.tf | grep -q' under pipefail fails when
# grep -q exits before cat has written the next file (SIGPIPE, rc 141; 5/40 runs).
one_ssh_rule() {
  local dir=$1 n ports
  n=$(cat "$dir"/*.tf | grep -cE '^resource "google_compute_firewall"')
  ports=$(cat "$dir"/*.tf | grep -E '^\s*ports\s*=' | tr -d ' ')
  [[ "$n" == 1 && "$ports" == 'ports=["22"]' ]] \
    && grep -qhE '^\s*direction\s*=\s*"INGRESS"' "$dir"/*.tf
}
one_ssh_rule "$VM" && pass "060 has one firewall rule: INGRESS tcp/22" || fail "060 firewall is not exactly one INGRESS tcp/22 rule"
grep -qx 'ssh_source_ranges = \["35.235.240.0/20"\]' "$CNF/prd/tf/060-gcp-vm-satellite.vars.tfvars" \
  && pass "prd ssh source is the IAP range only" || fail "prd ssh_source_ranges is not exactly the IAP range"

# --- 2. no web ------------------------------------------------------------------
if grep -nE '"(80|443|8080|8443)"|allow-https?|http-server|https-server|google_compute_(global_)?forwarding_rule|google_compute_(backend_service|url_map|target_https?_proxy)|google_dns_record_set' "$VM"/*.tf; then
  fail "a web port, tag, LB or DNS resource appears in 060"
else
  pass "no web port, tag, LB or DNS resource in 060"
fi

grep -qE '^\s*access_config' "$VM"/*.tf && fail "060 gives the VM a public IP (access_config)" \
  || pass "060 VM has no public IP (outbound via Cloud NAT)"
grep -qE '^resource "google_compute_router_nat"' "$VM"/*.tf && pass "060 has Cloud NAT for outbound" || fail "060 has no Cloud NAT: the VM cannot reach the internet"

# --- 3. no key in state --------------------------------------------------------
if grep -nE 'resource "(tls_private_key|google_service_account_key|local_sensitive_file|random_password)"' "$VM"/*.tf "$BUD"/*.tf; then
  fail "a state-borne key resource appears in 059/060"
else
  pass "no key resource in 059/060"
fi
grep -qE '^ssh_public_key_file = ".*\.pub"$' "$CNF/prd/tf/060-gcp-vm-satellite.vars.tfvars" \
  && pass "terraform reads the .pub half only" || fail "ssh_public_key_file is not a .pub path"

# --- 4. dated image ---------------------------------------------------------------
grep -qE '^boot_disk_image = "projects/debian-cloud/global/images/debian-13-trixie-v[0-9]{8}"$' "$CNF/prd/tf/060-gcp-vm-satellite.vars.tfvars" \
  && pass "the image is a dated debian-13-trixie image" || fail "boot_disk_image is not a dated debian-13-trixie image"

# --- 5. prd only ----------------------------------------------------------------
for d in "$VM" "$BUD"; do
  grep -qE 'condition\s*=\s*var\.env == "prd"' "$d/02-variables.tf" \
    && pass "$(basename "$d") refuses any env but prd" || fail "$(basename "$d") has no prd-only env validation"
done
for s in 059-gcp-satellite-budget 060-gcp-vm-satellite; do
  f="$CNF/dev/tf/$s.vars.tfvars"
  # awk, not grep -v: the box grep is ugrep, whose -qv exit code differs
  if [[ -f "$f" ]] && awk '!/^(#.*|org .*|app .*|env .*|gcp_project .*|gcp_region .*|)$/ { bad = 1 } END { exit bad }' "$f"; then
    pass "dev $s render carries no step values"
  else
    fail "dev $s render carries step values (the satellite is prd only)"
  fi
done

# --- 6. budget wiring ---------------------------------------------------------
lk=$(sed -nE 's/^budget_label_key = "(.*)"$/\1/p' "$CNF/prd/tf/059-gcp-satellite-budget.vars.tfvars")
lv=$(sed -nE 's/^budget_label_value = "(.*)"$/\1/p' "$CNF/prd/tf/059-gcp-satellite-budget.vars.tfvars")
bl=$(sed -nE 's/^box_label = "(.*)"$/\1/p' "$CNF/prd/tf/060-gcp-vm-satellite.vars.tfvars")
[[ "$lk" == box && -n "$lv" && "$lv" == "$bl" ]] && grep -qE '^\s*box\s*=\s*var\.box_label' "$VM/03-vm.tf" \
  && pass "059 filters on box=$lv, the label 060 sets" || fail "059 label filter ($lk=$lv) does not match 060's box label ($bl)"
grep -qx 'budget_amount_month = 170' "$CNF/prd/tf/059-gcp-satellite-budget.vars.tfvars" \
  && pass "budget is 170/month" || fail "budget_amount_month is not 170"
mk="$APP_ROOT/csi-spl-orc/src/make/tf-tasks.func.mk"
n=$(grep -c 'TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}"' "$mk")
[[ "$n" -ge 2 ]] && pass "do-tf-plan + do-provision pass GCP_BILLING_ACCOUNT_ID" || fail "make does not pass GCP_BILLING_ACCOUNT_ID to the tf-runner ($n)"
if grep -rnE '[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}' "$CNF"/*.yaml "$BUD" >/dev/null; then
  fail "a billing account id literal is committed"
else
  pass "no billing account id literal in cnf or 059"
fi

# --- 8. csi-spl-all ---------------------------------------------------------------
for s in 059-gcp-satellite-budget 060-gcp-vm-satellite; do
  v="$CNF/prd/tf/$s.vars.tfvars" b="$CNF/prd/tf/$s.backend-config.tfvars"
  k=$(yq -r ".env.steps.\"$s\".tf_key_project" "$CNF/prd.env.yaml")
  grep -qx 'gcp_project = "csi-spl-all"' "$v" && grep -qx 'bucket = "csi-spl-all-tfstate"' "$b" && [[ "$k" == csi-spl-all ]] \
    && pass "$s runs in csi-spl-all as its SA, state in csi-spl-all-tfstate" || fail "$s is not wired to csi-spl-all (project/state/key)"
done
grep -qE 'subnetwork\s*=\s*google_compute_subnetwork\.satellite\.id' "$VM/03-vm.tf" && ! grep -qE '"default"' "$VM"/*.tf \
  && pass "060 uses its own VPC, never the default network" || fail "060 is on the default network"

# --- 7. control -------------------------------------------------------------------
tmp=$(mktemp -d); cp "$VM"/*.tf "$tmp/"
printf '%s\n' 'resource "google_compute_firewall" "planted" {' '  name = "x"' '  network = "default"' '  allow {' '    protocol = "tcp"' '    ports    = ["443"]' '  }' '}' >"$tmp/99-planted.tf"
one_ssh_rule "$tmp" && fail "control: a planted second ingress rule was NOT caught" || pass "control: a planted second ingress rule is caught"
rm -rf "$tmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
