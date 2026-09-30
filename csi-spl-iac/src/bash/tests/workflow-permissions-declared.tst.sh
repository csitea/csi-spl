#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Least privilege: every workflow declares a top-level `permissions:` block.
# Without one, the job's GITHUB_TOKEN inherits the repository default, which
# can be read-write on contents, packages, id-token, etc. An explicit
# top-level block (start from `contents: read`, elevate per job) caps the
# blast radius of a compromised step or action.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
WF_DIR="$APP_ROOT/.github/workflows"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

has_top_permissions() { grep -qE '^permissions:' "$1"; }

[[ -d "$WF_DIR" ]] || { fail "no workflows dir at $WF_DIR"; exit 1; }

# --- negative control: a workflow with no permissions block is caught --------
CTL=$(mktemp)
printf 'name: x\non:\n  push: {}\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []\n' >"$CTL"
if has_top_permissions "$CTL"; then
  fail "CONTROL: a permission-less workflow was reported as compliant"
else
  pass "CONTROL: a workflow with no top-level permissions is detected"
fi
rm -f "$CTL"

n=0
for f in "$WF_DIR"/*.yml; do
  b=$(basename "$f")
  n=$((n + 1))
  if has_top_permissions "$f"; then
    pass "$b: declares a top-level permissions block"
  else
    fail "$b: no top-level permissions block (inherits the repo default token scope)"
  fi
done
[[ "$n" -gt 0 ]] && pass "checked top-level permissions on $n workflow file(s)" \
  || fail "no workflow files found"

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-permissions-declared.tst.sh assertions"
exit "$fails"
