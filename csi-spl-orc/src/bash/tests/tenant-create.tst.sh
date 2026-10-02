#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_tenant_create (006 T003) builds the tenant URL from cnf,
#          never a baked hostname; DRY_RUN prints no private key; missing
#          tenant id fails; the action source has no product domain literal.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# nosa_home: a HOME with no ~/.gcp: no per-env SA key, while the REAL cnf
# still carries env.gcp.gcp_account_owner_email -- the CONTROL that a missing
# key is refused and the owner account is NEVER the fallback (owner rule
# 2026-09-19: the per-env service accounts only)
mkdir -p "$T/nosa_home"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

FUNC="$PROJ_ROOT/src/bash/run/spl-tenant-create.func.sh"
[[ -f "$FUNC" ]] || { echo "FAIL: missing $FUNC"; exit 1; }

# --- 1. action source has no product domain (cnf/doc only) --------------------
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
domain=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$CNF")
if [[ -n "$domain" ]] && grep -F "$domain" "$FUNC" >/dev/null; then
  fail "do_spl_tenant_create source bakes $domain"
else
  pass "do_spl_tenant_create source has no $domain literal"
fi

# --- 2. missing tenant id fails -----------------------------------------------
SNIPPET='do_spl_tenant_create' in_orc >"$T/none.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "missing TENANT_ID fails (rc=$rc)" || fail "missing TENANT_ID succeeded: $(cat "$T/none.out")"

SNIPPET='do_spl_tenant_create' in_orc TENANT_ID='Bad' >"$T/bad.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "uppercase TENANT_ID fails" || fail "uppercase tenant succeeded"

# --- 3. DRY_RUN lde: URL from cnf pattern, no private key ---------------------
out=$(SNIPPET='do_spl_tenant_create' in_orc TENANT_ID=acme DRY_RUN=1 2>"$T/dry.err") || {
  fail "DRY_RUN lde exited $? $(cat "$T/dry.err")"; out=""; }
json=$(grep '^{' <<<"$out" | tail -1)
echo "$json" >"$T/dry.json"
if echo "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["tenant"]=="acme" and d.get("dry_run") is True and "root_private_key" not in d and d["url"].startswith("http://acme.localhost:"); assert d["billing_status"]=="manual"' 2>"$T/py.err"; then
  pass "DRY_RUN JSON: tenant acme, http://acme.localhost:<port>, no private key"
else
  fail "DRY_RUN JSON: $out $(cat "$T/py.err")"
fi
if grep -qiE 'root_private_key|BEGIN|ed25519' "$T/dry.err"; then
  fail "DRY_RUN logs look like they contain a key: $(cat "$T/dry.err")"
else
  pass "DRY_RUN logs do not mention a private key"
fi
if echo "$out" | grep -F "$domain" >/dev/null && [[ -n "$domain" ]]; then
  fail "lde DRY_RUN URL baked the product domain: $out"
else
  pass "lde DRY_RUN URL is the lde pattern, not the product domain"
fi

# --- 4. DRY_RUN cloud: URL from merged cnf pattern ----------------------------
out=$(SNIPPET='do_spl_tenant_create' in_orc ENV=dev TENANT_ID=acme DRY_RUN=1 SPL_STATE_DIR="$T/cloud" 2>"$T/dev.err") || {
  fail "DRY_RUN dev exited $? $(cat "$T/dev.err")"; out=""; }
json=$(grep '^{' <<<"$out" | tail -1)
if echo "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["tenant"]=="acme" and d["url"].startswith("https://acme.") and "root_private_key" not in d' 2>"$T/dev.py.err"; then
  pass "DRY_RUN dev JSON: https://acme.<cnf fqdn>, no private key"
else
  fail "DRY_RUN dev JSON: $out $(cat "$T/dev.py.err") $(cat "$T/dev.err")"
fi

# --- 5. DRY_RUN=0 cloud, no DSN, no account (env or SA key): refused before any key
# SPOOL_BIN is a stub so no build runs; the refusal must come before keygen.
out=$(SNIPPET='do_spl_tenant_create' in_orc ENV=dev TENANT_ID=acme DRY_RUN=0 GCP_ACCOUNT= HOME="$T/nosa_home" SPOOL_HUB_DB_DSN= \
  SPOOL_BIN=/bin/true SPL_STATE_DIR="$T/cloud0" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && grep -q 'no project SA key' <<<"$out" && ! grep -qiE 'root_private_key|sql proxy up' <<<"$out"; then
  pass "DRY_RUN=0 dev without DSN or GCP_ACCOUNT refused before keygen/proxy (rc=$rc)"
else
  fail "DRY_RUN=0 dev without DSN or GCP_ACCOUNT: rc=$rc $out"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
