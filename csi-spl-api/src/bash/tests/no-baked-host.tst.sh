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

# csi-rel's rails (paytrail, klarna, vipps/mobilepay) added with 006 T018: the
# spool names rails by protocol (hosted-hmac), cnf says which vendor.
vendors='stripe|paypal|braintree|adyen|squareup|checkout\.com|lemonsqueezy|paddle|paytrail|klarna|vipps|mobilepay'
vhits=$(grep -rIinE --include='*.go' -- "$vendors" "$SRC" || true)
if [[ -n "$vhits" ]]; then
  echo "FAIL - payment vendor name in Go (must live in cnf only):"
  echo "$vhits"
  exit 1
fi
echo "ok   - no payment vendor name in spool Go source"
