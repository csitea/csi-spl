#!/usr/bin/env bash
# T015 / contracts/payment.md: the WUI must not name a payment vendor
# (M2 checkout is hub-side; M3 shop pages are out of this lane).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WUI="$(cd "$HERE/../../../../csi-spl-wui" && pwd)"

# Skip generated trees. Match vendor tokens as whole words.
HITS="$(grep -rniE '\bstripe\b|\bpaypal\b|\bpaytrail\b|\bklarna\b|\bvipps\b' \
        --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=dist \
        --exclude-dir=.output --exclude='pnpm-lock.yaml' \
        "$WUI" 2>/dev/null || true)"

if [ -n "$HITS" ]; then
  echo "FAIL - payment vendor name in csi-spl-wui:"
  echo "$HITS"
  exit 1
fi
echo "ok   - no payment vendor name in csi-spl-wui"
