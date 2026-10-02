#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: owner 2026-09-29 (topic e802196b, "you should fix the infra too"):
#          www.<apex> had no DNS. cnf env.dns.redirect_hosts is the ONE list;
#          do_tpl_gen renders it into
#            019 redirect_fqdns       = ["<host>.<fqdn>", ...]  (Firebase custom
#                                        domain, redirect_target = var.fqdn)
#            025 cloud_run_mapping_records += <host> A 199.36.158.100
#                                           + <host> TXT "hosting-site=<site>"
#          This test re-derives both from the yaml and compares them with the
#          committed tfvars, so a cnf edit without a re-render fails here.
#
#          CONTROL: a scratch copy of prd's 019 tfvars with one more host must
#          FAIL the same comparison (the check is not vacuous).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
TF="$PROJ_ROOT/src/terraform/019-firebase-static-site"
fails=0

# want_019 <env> -> the JSON list 019 must carry
want_019() {
  local env="$1" fqdn
  fqdn=$(yq -r '.env.dns.fqdn' "$CNF/$env.env.json")
  yq -o=json -I=0 "[(.env.dns.redirect_hosts // [])[] | . + \".$fqdn\"]" "$CNF/$env.env.yaml"
}

# got_019 <tfvars> -> the rendered redirect_fqdns, normalised to compact JSON
got_019() {
  sed -n 's/^redirect_fqdns = //p' "$1" | yq -p=json -o=json -I=0 '.'
}

for env in dev prd; do
  want=$(want_019 "$env")
  got=$(got_019 "$CNF/$env/tf/019-firebase-static-site.vars.tfvars")
  [[ "$got" == "$want" ]] && pass "$env 019 redirect_fqdns = cnf redirect_hosts ($got)" \
    || fail "$env 019 redirect_fqdns '$got', cnf says '$want': re-run ENV=$env ./run -a do_tpl_gen"

  site="csi-spl-$env-site"
  recs=$(sed -n 's/^cloud_run_mapping_records = //p' "$CNF/$env/tf/025-gcp-dns-zone.vars.tfvars")
  for h in $(yq -r '(.env.dns.redirect_hosts // [])[]' "$CNF/$env.env.yaml"); do
    a=$(yq -p=json -r "[.[] | select(.name == \"$h\" and .type == \"A\")][0].rrdatas[0] // \"\"" <<<"$recs")
    t=$(yq -p=json -r "[.[] | select(.name == \"$h\" and .type == \"TXT\")][0].rrdatas[0] // \"\"" <<<"$recs")
    [[ "$a" == "199.36.158.100" ]] && pass "$env 025 $h A 199.36.158.100" || fail "$env 025 $h A: '$a'"
    [[ "$t" == "\"hosting-site=$site\"" ]] && pass "$env 025 $h TXT hosting-site=$site" || fail "$env 025 $h TXT: '$t'"
  done
done

# prd carries www (the owner's ask), dev carries none
[[ "$(want_019 prd)" == *'"www.'* ]] && pass "prd redirects www" || fail "prd cnf has no www redirect host"

# the terraform: one redirecting custom domain per entry, never also serving
grep -q 'resource "google_firebase_hosting_custom_domain" "redirect"' "$TF/03-firebase-site.tf" \
  && pass "019 has the redirect custom domain resource" || fail "019 redirect resource missing"
grep -q 'redirect_target *= var.fqdn' "$TF/03-firebase-site.tf" \
  && pass "019 redirect_target = var.fqdn" || fail "019 redirect_target is not var.fqdn"

# --- control: one more host in the rendered file must fail the comparison ----
tmp=$(mktemp)
sed 's/^redirect_fqdns = \[\(.*\)\]$/redirect_fqdns = [\1, "ctl.example.com"]/' \
  "$CNF/prd/tf/019-firebase-static-site.vars.tfvars" >"$tmp"
[[ "$(got_019 "$tmp")" != "$(want_019 prd)" ]] \
  && pass "control: a planted extra redirect host is caught" || fail "control: the comparison passed a planted host"
rm -f "$tmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
