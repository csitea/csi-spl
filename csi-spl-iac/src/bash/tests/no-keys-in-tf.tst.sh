#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 007 T017 / FR-007 — no keys in terraform. A google_service_
#          account_key, tls_private_key, private_key assignment, credentials
#          = file(), or a PEM private-key header in .tf / .tfvars / .tpl
#          writes secret material into git or tf state. Comments that name
#          the forbidden resource (the 020 relay-SA rationale) are not hits.
#
#          CONTROLS: plant the forbidden forms in a scratch tree and require
#          those hits; plant the existing comment shape and require none;
#          missing terraform dir is an error, not a pass.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# key_hits <root> -> prints file:line hits relative to root
key_hits() {
  local root="$1"
  grep -rInE --include='*.tf' --include='*.tfvars' --include='*.tpl' --exclude-dir=.terraform \
    'resource[[:space:]]+"(google_service_account_key|tls_private_key)"|(^|[[:space:]])private_key[[:space:]]*=|credentials[[:space:]]*=[[:space:]]*file\(|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
    "$root" 2>/dev/null | sed "s#^$root/##" || true
}

TF="$PROJ_ROOT/src/terraform"
[[ -d "$TF" ]] || { echo "FAIL: missing $TF"; exit 1; }
n=$(find "$TF" -name '*.tf' -type f | wc -l)
[[ "$n" -ge 1 ]] && pass "src/terraform has $n .tf file(s)" || fail "no .tf files under $TF"

# --- the real tree: terraform sources, tpl-gen templates, rendered tfvars -----
hits=$(
  { key_hits "$TF"
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
echo "$hits" | grep -q 'google_service_account_key' || { fail "control: planted google_service_account_key not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep -q 'tls_private_key' || { fail "control: planted tls_private_key not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep -qE 'private_key[[:space:]]*=' || { fail "control: planted private_key= not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep -q 'credentials' || { fail "control: planted credentials=file() not caught: ${hits:-<nothing>}"; ok=0; }
echo "$hits" | grep -q 'BEGIN' || { fail "control: planted PEM header not caught: ${hits:-<nothing>}"; ok=0; }
[[ "$ok" -eq 1 ]] && pass "control: planted SA key, tls_private_key, PEM, private_key= and credentials=file() are caught"

# --- control 2: rationale comments are not hits -------------------------------
hits=$(key_hits "$tmp/ok")
[[ -z "$hits" ]] && pass "control: comments naming google_service_account_key / private-key-file are not hits" \
  || fail "control: false positive on comment-only tf: $hits"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
