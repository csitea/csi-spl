#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Supply-chain freshness: .github/dependabot.yml keeps all three dependency
# surfaces from drifting behind their security releases — the hub Go module
# (gomod), the WUI (npm/pnpm), and the SHA-pinned actions (github-actions).
# A missing ecosystem means that surface silently rots; this asserts all three
# are configured, at the right directories.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
CFG="$APP_ROOT/.github/dependabot.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$CFG" ]] && pass "dependabot config exists" || { fail "no $CFG (fails-before)"; exit 1; }

grep -qE '^version:[[:space:]]*2' "$CFG" && pass "config is version 2" || fail "config is not version 2"

# has_eco <ecosystem> — the config declares an update block for it.
has_eco() { grep -qE "package-ecosystem:[[:space:]]*[\"']?$1[\"']?" "$CFG"; }

for eco in gomod npm github-actions; do
  if has_eco "$eco"; then pass "dependabot covers $eco"; else fail "dependabot is MISSING $eco (that surface rots silently)"; fi
done

# directories point at the real module roots
grep -qE 'directory:[[:space:]]*"/csi-spl-api/src/go/spool-hub-api"' "$CFG" \
  && pass "gomod points at the hub module" || fail "gomod directory is wrong"
grep -qE 'directory:[[:space:]]*"/csi-spl-wui"' "$CFG" \
  && pass "npm points at the WUI" || fail "npm directory is wrong"

# --- negative control: a config lacking an ecosystem is caught ---------------
CTL=$(mktemp)
printf 'version: 2\nupdates:\n  - package-ecosystem: "gomod"\n    directory: "/"\n    schedule:\n      interval: "weekly"\n' >"$CTL"
if grep -qE "package-ecosystem:[[:space:]]*[\"']?github-actions[\"']?" "$CTL"; then
  fail "CONTROL: planted config wrongly reported as covering github-actions"
else
  pass "CONTROL: a config missing the github-actions ecosystem is detected"
fi
rm -f "$CTL"

[[ "$fails" -eq 0 ]] && echo "PASS: all dependabot-config.tst.sh assertions"
exit "$fails"
