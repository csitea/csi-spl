#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the M1 hub front door (031-gcp-hub-ingress) is an IP ALLOWLIST in
#          front of an LB-only Cloud Run service, with a wildcard certificate
#          for the env's fqdn read from cnf, never a literal:
#   1. the rendered fqdn / service equal the effective cnf (env.dns.fqdn,
#      hub.service_name) for dev and prd
#   2. the Cloud Armor policy's default rule denies, and no rule but the
#      allowlist allows
#   3. HTTPS only: one forwarding rule, port 443
#   4. the certificate covers <fqdn> and *.<fqdn>
#   5. 001 enables the APIs 031 needs (compute, certificatemanager)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
S="$PROJ_ROOT/src/terraform/031-gcp-hub-ingress"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"

# --- 1. fqdn + service come from cnf -------------------------------------------
for env in dev prd; do
  v="$CNF/$env/tf/031-gcp-hub-ingress.vars.tfvars"
  do_spl_merged_cnf "$CNF" "$env" "$T/$env.yaml" || { fail "$env: cannot merge cnf"; continue; }
  fqdn=$(yq -r '.env.dns.fqdn' "$T/$env.yaml") svc=$(yq -r '.env.hub.service_name' "$T/$env.yaml")
  [[ -f "$v" ]] || { fail "$env: $v not rendered"; continue; }
  grep -qx "fqdn         = \"$fqdn\"" "$v" && pass "$env 031 fqdn = cnf env.dns.fqdn" || fail "$env 031 fqdn is not $fqdn"
  grep -qx "service_name = \"$svc\"" "$v" && pass "$env 031 fronts $svc" || fail "$env 031 service_name is not $svc"
  for api in compute.googleapis.com certificatemanager.googleapis.com; do
    grep -q "\"$api\"" "$CNF/$env/tf/001-enable-gcp-services.vars.tfvars" && pass "$env 001 enables $api" || fail "$env 001 does not enable $api"
  done
done

# --- 2. allowlist semantics -----------------------------------------------------
a="$S/03-cloud-armor.tf"
awk '/^  rule \{/,/^  \}/' "$a" | grep -q 'action      = "deny(403)"' && grep -q 'priority    = 2147483647' "$a" \
  && pass "the default rule (2147483647) denies" || fail "the default rule does not deny"
allows=$(grep -cE 'action\s*=\s*"allow"' "$a")
[[ "$allows" -eq 1 ]] && grep -q 'src_ip_ranges = rule.value' "$a" \
  && pass "the only allow rule is the cnf allowlist" || fail "expected exactly one allow (the allowlist), got $allows"
grep -q 'security_policy       = google_compute_security_policy.hub.id' "$S/05-load-balancer.tf" \
  && pass "the backend carries the allowlist policy" || fail "the backend service has no security_policy"

# --- 3. HTTPS only ----------------------------------------------------------------
n=$(cat "$S"/*.tf | grep -c 'resource "google_compute_global_forwarding_rule"')
[[ "$n" -eq 1 ]] && grep -q 'port_range            = "443"' "$S/05-load-balancer.tf" \
  && pass "one forwarding rule, 443" || fail "forwarding rules: $n (want exactly one, on 443)"

# --- 4. wildcard -------------------------------------------------------------------
grep -q 'domains            = \[var.fqdn, "\*.${var.fqdn}"\]' "$S/04-certificate.tf" \
  && pass "certificate covers <fqdn> and *.<fqdn>" || fail "certificate does not cover the wildcard"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
