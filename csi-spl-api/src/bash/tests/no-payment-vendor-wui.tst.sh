#!/usr/bin/env bash
# T015 / contracts/payment.md: the WUI must not name a payment vendor, with ONE
# deliberate exception (006 T021w, the Go side's rule mirrored): the copied
# card step src/utils/card-element.mjs (csi-rel's storefront path: the
# vendor's SDK + Payment Element) and its unit test may. Every other WUI file
# speaks of "card". CONTROLS: a vendor name planted in any other file fails the
# gate, and the allowed file must still exist (an allow-list entry that points
# at nothing proves nothing).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WUI="$(cd "$HERE/../../../../csi-spl-wui" && pwd)"
ALLOWED=(src/utils/card-element.mjs tests/unit/card-element.test.mjs)
VENDOR_RE='\bstripe\b|\bpaypal\b|\bpaytrail\b|\bklarna\b|\bvipps\b'

# hits <root> -> vendor-name hits outside the allowed files. Skips generated trees.
hits() {
  local root="$1" ex=() a
  for a in "${ALLOWED[@]}"; do ex+=(--exclude="$(basename "$a")"); done
  grep -rniE "$VENDOR_RE" \
    --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=dist \
    --exclude-dir=.output --exclude='pnpm-lock.yaml' "${ex[@]}" \
    "$root" 2>/dev/null || true
}
# the basename exclusion must not hide a same-named file elsewhere
misplaced() {
  local root="$1" a f
  for a in "${ALLOWED[@]}"; do
    while IFS= read -r f; do
      [[ "$f" == "$root/$a" ]] || echo "$f"
    done < <(find "$root" -name "$(basename "$a")" -not -path '*/node_modules/*' -not -path '*/.nuxt/*' -not -path '*/.output/*')
  done
}

fail=0
for a in "${ALLOWED[@]}"; do
  [[ -f "$WUI/$a" ]] || { echo "FAIL - allowed file $a is missing (drop it from ALLOWED)"; fail=1; }
done
HITS="$(hits "$WUI")"
MIS="$(misplaced "$WUI")"
if [ -n "$HITS" ] || [ -n "$MIS" ]; then
  echo "FAIL - payment vendor name in csi-spl-wui outside ${ALLOWED[*]}:"
  echo "$HITS$MIS"
  fail=1
fi

# CONTROLS on a scratch copy of the tree shape
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/utils" "$T/src/pages" "$T/tests/unit" "$T/src/lib"
echo "load the Stripe sdk" >"$T/src/utils/card-element.mjs"
echo "win.Stripe" >"$T/tests/unit/card-element.test.mjs"
echo "just a card" >"$T/src/pages/checkout.vue"
[ -z "$(hits "$T")$(misplaced "$T")" ] || { echo "FAIL - control: the allowed files themselves were flagged"; fail=1; }
echo "PayPal button" >"$T/src/pages/checkout.vue"
[ -n "$(hits "$T")" ] || { echo "FAIL - control: a vendor name planted in a page was NOT caught"; fail=1; }
echo "just a card" >"$T/src/pages/checkout.vue"
echo "Stripe" >"$T/src/lib/card-element.mjs"
[ -n "$(misplaced "$T")" ] || { echo "FAIL - control: a same-named file outside the allowed path was NOT caught"; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "ok   - no payment vendor name in csi-spl-wui outside the card step (controls ok)"
