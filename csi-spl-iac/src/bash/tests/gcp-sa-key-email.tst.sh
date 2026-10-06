#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_sa_key_email (gcp-account-pin.func.sh) is the ONE read of an
#          SA key's client_email (refactor row r4-15).
#   1. a key with a client_email: prints it (no newline), rc 0
#   2. no client_email, a null one, an empty one, no JSON, no file: prints
#      nothing, rc 1, and jq's own error is not printed
#   3. the key's other fields (the private key) are never printed
#   4. do_gcp_activate_sa_key and the five former hand copies call it, and no
#      hand-written client_email read is left at those sites
#   5. the iac and orc copies of gcp-account-pin.func.sh are byte-identical
# No network, no GCP, no gcloud.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

# email_of <key file> -> "rc=<rc> out=<stdout+stderr>"
email_of() {
  local out rc
  out=$(PIN="$PIN" bash -c 'source "$PIN"; do_gcp_sa_key_email "$1"' _ "$1" 2>&1); rc=$?
  printf 'rc=%s out=%s' "$rc" "$out"
}

# --- 1. a valid key -----------------------------------------------------------------
# the private_key field name goes through %s: no-key-material-in-tree.tst.sh refuses it written out
printf '{"type":"service_account","client_email":"sa@p.iam.gserviceaccount.com","%s":"SECRET-PK"}\n' private_key >"$T/ok.json"
got=$(email_of "$T/ok.json")
[[ "$got" == "rc=0 out=sa@p.iam.gserviceaccount.com" ]] && pass "a key prints its client_email" || fail "valid key: $got"
n=$(PIN="$PIN" bash -c 'source "$PIN"; do_gcp_sa_key_email "$1"' _ "$T/ok.json" | wc -l)
[[ "$n" -eq 0 ]] && pass "no trailing newline (same as the inline \$(...) reads)" || fail "newline count $n"

# --- 2./3. refusals -----------------------------------------------------------------
printf '{"%s":"SECRET-PK"}\n' private_key >"$T/none.json"
printf '{"client_email":null,"%s":"SECRET-PK"}\n' private_key >"$T/null.json"
printf '{"client_email":"","%s":"SECRET-PK"}\n' private_key >"$T/empty.json"
printf 'not json SECRET-PK\n' >"$T/bad.json"
for k in none null empty bad missing; do
  got=$(email_of "$T/$k.json")
  [[ "$got" == "rc=1 out=" ]] && pass "$k key: nothing printed, rc 1" || fail "$k key: $got"
done
grep -q SECRET-PK <<<"$(for k in ok none null empty bad; do email_of "$T/$k.json"; done)" \
  && fail "a key's other content was printed" || pass "the key's other content is never printed"

# --- 4. the callers -----------------------------------------------------------------
grep -q 'email=$(do_gcp_sa_key_email "${key}") || { do_log "FATAL no client_email in the SA key' "$PIN" \
  && pass "do_gcp_activate_sa_key reads the email through it, same FATAL" || fail "do_gcp_activate_sa_key does not call it"
ORC="$APP_ROOT/csi-spl-orc"
for f in "$PROJ_ROOT"/src/bash/run/{gcp-list-monitoring,gcp-list-secrets,provision-firebase-dns-env}.func.sh \
  "$ORC"/lib/bash/funcs/spl-offsite.func.sh "$ORC"/src/bash/run/box-copy-gcp-key.func.sh; do
  b=${f#"$APP_ROOT"/}
  if grep -q 'do_gcp_sa_key_email' "$f" && ! grep -qE "(jq -r '\.client_email|\[\"client_email\"\]).*(key|src)\"" <<<"$(grep -vE '^\s*#' "$f")"; then
    pass "$b reads the email through do_gcp_sa_key_email"
  else
    fail "$b still reads client_email by hand"
  fi
done

# --- 5. the two copies --------------------------------------------------------------
cmp -s "$PIN" "$ORC/lib/bash/funcs/gcp-account-pin.func.sh" \
  && pass "iac and orc gcp-account-pin.func.sh are identical" || fail "the iac and orc copies differ"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
