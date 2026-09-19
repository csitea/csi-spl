#!/usr/bin/env bash
# 006 T002 / T015: Go source must not bake the product hostname (cnf only)
# and must not name a payment vendor (provider stays in cnf).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../go"
CNF="$HERE/../../../../csi-spl-cnf/csi-spl/all.env.yaml"

domain=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$CNF")
[[ -n "$domain" && "$domain" == *.* ]] || { echo "FAIL - could not read env.dns.BASE_DOMAIN"; exit 1; }
label="${domain%.*}" tld="${domain##*.}"
label_re=$(printf '%s' "$label" | sed 's/[.\\]/\\&/g')
tld_re=$(printf '%s' "$tld" | sed 's/[.\\]/\\&/g')

hits=$(grep -rInE --include='*.go' -- "${label_re}[\"' +\\]*\.${tld_re}" "$SRC" || true)
if [[ -n "$hits" ]]; then
  echo "FAIL - product hostname baked in Go:"
  echo "$hits"
  exit 1
fi
echo "ok   - no $domain (or split/escaped form) in spool Go source"

# Vendor names: owner direction 2026-09-19 ("payment exactly the way csi-rel
# implements it with Stripe", plus csi-rel's PayPal off by default) puts the
# copied provider code under internal/payments/, the ONE place Go may name a
# payment vendor (006 payment.md "Vendor-name gate"). Everywhere else it fails.
vendors='stripe|paypal|braintree|adyen|squareup|checkout\.com|lemonsqueezy|paddle|paytrail|klarna|vipps|mobilepay'
allowed='/internal/payments/'
vendor_hits() {  # <dir> -> offending lines outside the allowed package
  grep -rIinE --include='*.go' -- "$vendors" "$1" | grep -v -- "$allowed" || true
}
vhits=$(vendor_hits "$SRC")
if [[ -n "$vhits" ]]; then
  echo "FAIL - payment vendor name in Go outside internal/payments (must live in cnf / the provider package):"
  echo "$vhits"
  exit 1
fi
echo "ok   - no payment vendor name in spool Go source outside internal/payments"

# CONTROL: the allow-list must not blind the gate: a vendor name planted in
# any other package is caught, one in internal/payments is not.
ctl=$(mktemp -d); trap 'rm -rf "$ctl"' EXIT
mkdir -p "$ctl/m/internal/hub" "$ctl/m/internal/payments"
echo '// talks to Stripe' > "$ctl/m/internal/hub/x.go"
echo '// talks to Stripe' > "$ctl/m/internal/payments/x.go"
chits=$(vendor_hits "$ctl")
if [[ "$chits" == *"/internal/hub/x.go"* && "$chits" != *"/internal/payments/x.go"* ]]; then
  echo "ok   - control: a vendor name planted outside internal/payments fails the gate"
else
  echo "FAIL - control: planted vendor name not caught as expected: ${chits:-<nothing>}"
  exit 1
fi
