#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: 017-github-wif-deploy lets ONLY trunk runs of ONE repository
#          impersonate the deploy SA:
#   1. the provider's attribute_condition requires the repository AND the ref
#   2. the deploy SA's workloadIdentityUser member is the ref's principal set,
#      never a repository-wide or pool-wide one
#   3. cnf pins both envs to the repo's trunk, and every workflow that
#      authenticates runs from it (push to master, schedule or dispatch)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/terraform/017-github-wif-deploy/03-github-wif.tf"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

# --- 1. provider condition ------------------------------------------------------
grep -qF 'attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"${var.github_ref}\""' "$S" \
  && pass "provider admits only <repository> on <ref>" || fail "provider attribute_condition does not pin repository AND ref"

# --- 2. IAM member ------------------------------------------------------------------
members=$(grep -E '^\s*member\s*=\s*"principal' "$S")
[[ "$(wc -l <<<"$members")" -eq 1 ]] && grep -qF '/attribute.ref/${var.github_ref}"' <<<"$members" \
  && pass "the deploy SA's WIF member is the trunk ref's principal set" || fail "WIF member is not the ref principal set: $members"
grep -qE 'attribute\.repository/|/\*"' <<<"$members" && fail "a repository-wide or wildcard WIF member remains" \
  || pass "no repository-wide or wildcard WIF member"

# --- 3. cnf + workflows ---------------------------------------------------------------
for env in dev prd; do
  grep -qx 'github_ref = "refs/heads/master"' "$CNF/$env/tf/017-github-wif-deploy.vars.tfvars" \
    && pass "$env 017 pinned to refs/heads/master" || fail "$env 017 github_ref is not refs/heads/master"
done
for w in "$APP_ROOT"/.github/workflows/*.yml; do
  grep -q 'google-github-actions/auth@' "$w" || continue
  on=$(sed -n '/^on:/,/^[a-z]/p' "$w")
  if grep -qE '^\s+pull_request' <<<"$on"; then fail "$(basename "$w") authenticates and runs on pull_request (ref is not the trunk)"
  elif grep -qE '^\s+push:' <<<"$on" && ! grep -qE 'branches: \[master\]' <<<"$on"; then fail "$(basename "$w") authenticates on push to a non-trunk branch"
  else pass "$(basename "$w") authenticates only from the trunk"; fi
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
