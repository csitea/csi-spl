#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the iac README keeps the bootstrap contract, as csi-rel-iac's
#          do_test_iac_readme_bootstrap asserts for its own README: the facts
#          come from the environment (GCP_ORG_ID, GCP_ACCOUNT,
#          GCP_BILLING_ACCOUNT_ID), the SA key layout is documented, the one
#          human step (`gcloud auth login` as the org admin) is named, and
#          terraform goes through the tf-runner make targets. And no baked-in
#          org id, billing id, mailbox, or the spool domain from the cnf.
#          CONTROL: a copy with one token removed, and a copy with a planted
#          12-digit id, must both be refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

domain=$(yq -r '.env.dns.BASE_DOMAIN // .BASE_DOMAIN // ""' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" 2>/dev/null)
[[ -n "$domain" && "$domain" != null ]] || domain=$(command grep -m1 -oE '^[[:space:]]*BASE_DOMAIN:[[:space:]]*[^[:space:]#]+' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" | awk '{print $2}')

# check <readme> -> prints the problems, one per line; nothing = ok
check() {
  local readme="$1" needle
  for needle in \
    'GCP_ORG_ID' \
    'GCP_ACCOUNT' \
    'GCP_BILLING_ACCOUNT_ID' \
    '~/.gcp/.<org>/key-<org>-<app>-<env>.json' \
    'gcloud auth login' \
    'org admin' \
    'do_gcp_000_bootstrap_gcp_env' \
    'make do-setup-app-inf' \
    'make do-provision'
  do
    command grep -qF -- "$needle" "$readme" || echo "missing: $needle"
  done
  [[ -n "$domain" ]] && command grep -qiF -- "$domain" "$readme" && echo "leak: the spool domain"
  command grep -Eq -- '[0-9]{12}' "$readme" && echo "leak: numeric org id"
  command grep -Eq -- '[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}' "$readme" && echo "leak: billing account id"
  command grep -Eq -- '@[A-Za-z0-9.-]+\.(net|com|fi|org|ai)\b' "$readme" && echo "leak: mailbox"
}

[[ -n "$domain" ]] && pass "the spool domain is read from the cnf (leak check armed)" || fail "could not read BASE_DOMAIN from all.env.yaml"
out=$(check "$PROJ_ROOT/README.md")
[[ -z "$out" ]] && pass "README carries the bootstrap contract, no baked-in ids/mailboxes/domain" || fail "README: $(tr '\n' ';' <<<"$out")"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command grep -vF 'gcloud auth login' "$PROJ_ROOT/README.md" >"$T/no-login.md"
[[ -n "$(check "$T/no-login.md")" ]] && pass "control: a README without the human login step is refused" || fail "control: a README missing 'gcloud auth login' passed"
{ cat "$PROJ_ROOT/README.md"; echo 'GCP_ORG_ID=123456789012'; } >"$T/leak.md"
[[ "$(check "$T/leak.md")" == *"numeric org id"* ]] && pass "control: a planted 12-digit org id is refused" || fail "control: a planted org id passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
