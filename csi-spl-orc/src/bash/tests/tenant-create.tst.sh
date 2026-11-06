#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_tenant_create (006 T003) builds the tenant URL from cnf,
#          never a baked hostname; DRY_RUN prints no private key; missing
#          tenant id fails; the action source has no product domain literal;
#          a DRY_RUN other than 0 or 1 is refused before anything runs; a
#          hub-tenant refusal never prints the private key; an lde create
#          returns 0 after its JSON and pins nothing (r51-02).
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

# --- 6. DRY_RUN=0 lde with a stub CLI: the refusals and the lde stop (r51-02)
# The stub logs its args to $STUB_LOG; root-keygen writes a fixed fake key to
# its --out file (exits $KG_RC when set); hub-tenant fails with $HT_RC when set.
cat >"$T/spool" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$1" in
  root-keygen) [[ -n "${KG_RC:-}" ]] && exit "$KG_RC"; echo PRIVKEY-STUB >"$3"; echo PUBKEY-STUB ;;
  hub-tenant) [[ -n "${HT_RC:-}" ]] && { echo "tenant exists" >&2; exit "$HT_RC"; } ;;
esac
exit 0
STUB
chmod +x "$T/spool"

# (D) a DRY_RUN other than 0 or 1 is refused before the CLI runs
: >"$T/d.log"
out=$(SNIPPET='do_spl_tenant_create' in_orc TENANT_ID=acme DRY_RUN=yes SPOOL_BIN="$T/spool" STUB_LOG="$T/d.log" 2>&1); rc=$?
if [[ $rc -eq 2 ]] && grep -q 'FATAL DRY_RUN must be 0 or 1, got: yes' <<<"$out" && [[ ! -s "$T/d.log" ]]; then
  pass "DRY_RUN=yes refused before anything runs (rc=2, CLI not called)"
else
  fail "DRY_RUN=yes: rc=$rc stub log: $(cat "$T/d.log") $out"
fi

# (K) a hub-tenant refusal never prints the private key
: >"$T/k.log"
out=$(SNIPPET='do_spl_tenant_create' in_orc TENANT_ID=acme DRY_RUN=0 HT_RC=1 SPOOL_BIN="$T/spool" STUB_LOG="$T/k.log" 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q 'FATAL hub-tenant refused acme: tenant exists; the private key was NOT printed' <<<"$out" \
    && ! grep -qE 'PRIVKEY-STUB|root_private_key' <<<"$out"; then
  pass "hub-tenant refusal: rc=1, the private key is not printed"
else
  fail "hub-tenant refusal: rc=$rc $out"
fi

# (L) an lde create returns 0 after its JSON and pins nothing
: >"$T/l.log"
out=$(SNIPPET='do_spl_tenant_create' in_orc TENANT_ID=acme DRY_RUN=0 SPOOL_BIN="$T/spool" STUB_LOG="$T/l.log" 2>&1); rc=$?
json=$(grep '^{' <<<"$out" | tail -1)
if [[ $rc -eq 0 ]] && grep -qF '"root_private_key":"PRIVKEY-STUB"' <<<"$json" \
    && grep -q '^hub-tenant --tenant acme --root-pubkey PUBKEY-STUB --billing-status manual --db postgres://.*@127.0.0.1:' "$T/l.log" \
    && ! grep -qiE 'pin|box-wui' <<<"$out"; then
  pass "lde create: rc=0 after the JSON, box-wui not pinned"
else
  fail "lde create: rc=$rc stub log: $(cat "$T/l.log") $out"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
