#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 007 T017 / FR-007 — no keys in terraform. A google_service_
#          account_key, tls_private_key, private_key assignment, credentials
#          = file(), or a PEM private-key header in .tf / .tfvars / .tpl
#          writes secret material into git or tf state. Comments that name
#          the forbidden resource (the 020 relay-SA rationale) are not hits.
#          ONE exception, the owner's (HUM-10, #laskut f655b326, msg
#          8d767855, SPL-5457): the billing SA's key resource
#          google_service_account_key.billing in step 002-gcp-billing-sa.
#          Only that resource, in only that step, is let through.
#
#          CONTROLS: plant the forbidden forms in a scratch tree and require
#          those hits; plant the existing comment shape and require none;
#          missing terraform dir is an error, not a pass; the exception
#          lets nothing else through (the same key in another step, another
#          key form in 002).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# key_hits <root> -> prints file:line hits relative to root
key_hits() {
  local root="$1"
  grep -rInE --include='*.tf' --include='*.tfvars' --include='*.tpl' --exclude-dir=.terraform \
    'resource[[:space:]]+"(google_service_account_key|tls_private_key)"|(^|[[:space:]])private_key[[:space:]]*=|credentials[[:space:]]*=[[:space:]]*file\(|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
    "$root" 2>/dev/null | sed "s#^$root/##" || true
}

# drop_allowed - drops the one owner-ordered hit (relative to src/terraform)
drop_allowed() {
  awk '!/^002-gcp-billing-sa\/[0-9a-z-]+\.tf:[0-9]+:resource "google_service_account_key" "billing" \{$/'
}

TF="$PROJ_ROOT/src/terraform"
[[ -d "$TF" ]] || { echo "FAIL: missing $TF"; exit 1; }
n=$(find "$TF" -name '*.tf' -type f | wc -l)
[[ "$n" -ge 1 ]] && pass "src/terraform has $n .tf file(s)" || fail "no .tf files under $TF"

# --- the real tree: terraform sources, tpl-gen templates, rendered tfvars -----
hits=$(
  { key_hits "$TF" | drop_allowed
    key_hits "$PROJ_ROOT/src/tpl"
    key_hits "$APP_ROOT/csi-spl-cnf"
  } | grep -v '^$' || true
)
if [[ -z "$hits" ]]; then
  pass "no SA key, tls_private_key, PEM, private_key= or credentials=file() in tf/tpl/tfvars"
else
  fail "a key appears in terraform:"
  printf '      %s\n' $hits
fi

# --- control 1: planted key forms are found -----------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bad" "$tmp/ok"
pem="-----BEGIN ""RSA"" PRIVATE KEY-----"
cat >"$tmp/bad/key.tf" <<EOF
resource "google_service_account_key" "relay" {}
resource "tls_private_key" "k" { algorithm = "RSA" }
private_key = "x"
credentials = file("key.json")
$pem
EOF
cat >"$tmp/ok/comment.tf" <<'EOF'
# The SA KEY is deliberately NOT a terraform resource: a
# google_service_account_key writes the private key into the state bucket in
# clear. It is minted once, out of band.
# gcloud storage sign-url --private-key-file
# No credentials path is baked in.
EOF

hits=$(key_hits "$tmp/bad")
ok=1
echo "$hits" | grep 'google_service_account_key' >/dev/null || { fail "control: planted google_service_account_key not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep 'tls_private_key' >/dev/null || { fail "control: planted tls_private_key not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep -E 'private_key[[:space:]]*=' >/dev/null || { fail "control: planted private_key= not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep 'credentials' >/dev/null || { fail "control: planted credentials=file() not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep 'BEGIN' >/dev/null || { fail "control: planted PEM header not caught: ${hits:-<nothing>}"; ok=0; }
[[ "$ok" -eq 1 ]] && pass "control: planted SA key, tls_private_key, PEM, private_key= and credentials=file() are caught"

# --- control 2: rationale comments are not hits -------------------------------
hits=$(key_hits "$tmp/ok")
[[ -z "$hits" ]] && pass "control: comments naming google_service_account_key / private-key-file are not hits" \
  || fail "control: false positive on comment-only tf: $hits"

# --- control 3: the exception is the billing key in 002 and nothing else ------
mkdir -p "$tmp/x/002-gcp-billing-sa" "$tmp/x/030-cloud-run-hub"
printf '%s\n' 'resource "google_service_account_key" "billing" {' >"$tmp/x/002-gcp-billing-sa/03-sa.tf"
hits=$(key_hits "$tmp/x" | drop_allowed)
[[ -z "$hits" ]] && pass "control: the billing key in 002 is let through" || fail "control: the owner-ordered 002 key is a hit: $hits"
printf '%s\n' 'resource "google_service_account_key" "billing" {' >"$tmp/x/030-cloud-run-hub/03-sa.tf"
printf '%s\n' 'resource "google_service_account_key" "other" {' 'resource "tls_private_key" "k" {' >"$tmp/x/002-gcp-billing-sa/04-more.tf"
hits=$(key_hits "$tmp/x" | drop_allowed)
ok=1
grep -q '^030-cloud-run-hub/03-sa.tf:' <<<"$hits" || { fail "control: the same key in another step was let through: ${hits:-<nothing>}"; ok=0; }
grep -q 'google_service_account_key" "other"' <<<"$hits" || { fail "control: a second key in 002 was let through: ${hits:-<nothing>}"; ok=0; }
grep -q 'tls_private_key' <<<"$hits" || { fail "control: a tls_private_key in 002 was let through: ${hits:-<nothing>}"; ok=0; }
[[ "$ok" -eq 1 ]] && pass "control: the same key in another step, a second key and a tls_private_key in 002 are caught"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
