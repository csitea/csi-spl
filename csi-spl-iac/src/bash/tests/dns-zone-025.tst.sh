#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: 025-gcp-dns-zone ADOPTS the env's public zone and can never
#          recreate it (a new zone = new name servers = a broken registrar
#          delegation):
#   1. the zone resource carries prevent_destroy and an import block, and no
#      other step declares a google_dns_managed_zone
#   2. prd adopts a zone that serves env.dns.fqdn; dev has its own subzone,
#      delegated from the prd apex zone
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/terraform/025-gcp-dns-zone"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

# --- 1. adopt, never recreate ---------------------------------------------------
grep -q 'prevent_destroy = true' "$S/03-dns-zone.tf" && pass "025 zone has prevent_destroy" || fail "025 zone lacks prevent_destroy"
grep -qE '^import \{' "$S/03-dns-zone.tf" && grep -q 'to *= google_dns_managed_zone.env' "$S/03-dns-zone.tf" \
  && pass "025 imports the existing zone" || fail "025 has no import block for the zone"
other=$(grep -rl 'resource "google_dns_managed_zone"' "$PROJ_ROOT/src/terraform" | grep -v '/025-gcp-dns-zone/')
[[ -z "$other" ]] && pass "no other step declares a managed zone" || fail "managed zone declared outside 025: $other"

# --- 2. cnf wiring ----------------------------------------------------------------
grep -qx 'zone_name = "spool-hub"' "$CNF/prd/tf/025-gcp-dns-zone.vars.tfvars" && pass "prd 025 adopts zone spool-hub" || fail "prd 025 zone_name"
# dev: the subzone dev.<domain> in csi-spl-dev, delegated from the prd apex zone
# (owner 2026-09-19, csi-rel 007-dns); the dev key never writes the prd zone
# except through the parent/extra providers on the prd key.
V="$CNF/dev/tf/025-gcp-dns-zone.vars.tfvars"
grep -qx 'zone_name = "spool-hub-dev"' "$V" && grep -qx 'parent_zone_name = "spool-hub"' "$V" && grep -qx 'parent_zone_project = "csi-spl-prd"' "$V" \
  && pass "dev 025 creates subzone spool-hub-dev, delegated from prd spool-hub" || fail "dev 025 subzone wiring"
grep -qx 'parent_zone_name = ""' "$CNF/prd/tf/025-gcp-dns-zone.vars.tfvars" && pass "prd 025 is the apex (no parent)" || fail "prd 025 parent_zone_name is set"
# the cross-project writes run on the PARENT project's own key, never the env key
for s in 025-gcp-dns-zone/01-providers.tf 005-gcp-domain-verification/01.providers.tf; do
  grep -q 'file(pathexpand("~/.gcp/.${var.org}/key-${var.' "$PROJ_ROOT/src/terraform/$s" \
    && pass "$s parent-zone provider uses the parent project's key file" || fail "$s parent-zone provider credentials"
done
grep -q 'provider = google.parent' "$PROJ_ROOT/src/terraform/025-gcp-dns-zone/03-dns-zone.tf" \
  && pass "025 delegation NS is written through the parent provider" || fail "025 delegation provider"
# the adopted apex zone keeps prevent_destroy; the created subzone does not need it
awk '/resource "google_dns_managed_zone" "env"/,/^}/' "$PROJ_ROOT/src/terraform/025-gcp-dns-zone/03-dns-zone.tf" | grep 'prevent_destroy = true' >/dev/null \
  && pass "025 adopted apex zone keeps prevent_destroy" || fail "025 apex zone lost prevent_destroy"
for env in dev prd; do
  a=$(sed -n 's/^fqdn *= "\(.*\)"$/\1/p' "$CNF/$env/tf/025-gcp-dns-zone.vars.tfvars")
  b=$(jq -r '.env.dns.fqdn' "$CNF/$env.env.json")
  [[ -n "$a" && "$a" == "$b" ]] && pass "$env 025 serves env.dns.fqdn ($a)" || fail "$env fqdn 025 '$a' vs env.dns.fqdn '$b'"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
