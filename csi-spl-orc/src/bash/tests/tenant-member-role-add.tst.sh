#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_tenant_member_role_add ADDS a role to a member's role set and
#          keeps the primary role (SPL-2588). gcloud and psql are stubbed.
#   1. DRY_RUN (the default) prints the plan and calls no cloud; legacy
#      member maps to developer.
#   2. bad input is refused before any gcloud or psql call, including a value
#      that would splice into SQL if it were interpolated.
#   3. DRY_RUN=0 with no project SA key never reaches psql.
#   4. DRY_RUN=0 runs as the env SA, one transaction: it INSERTs into
#      tenant_member_roles ON CONFLICT DO NOTHING and never writes
#      tenant_memberships (the primary). Values are -v, not text in the SQL.
#      RED CONTROL: the sibling do_spl_tenant_member_role (it REPLACES the
#      primary) run under the same stubs fails that same SQL check.
#   5. the runner reports added / already held, and refuses a non-member, an
#      empty read-back and a set that lacks the role.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "FAIL: no yq"; exit 1; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<EOF
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
if [[ -n "${STUB_PSQL_OUT+x}" ]]; then
  printf '%s\n' "$STUB_PSQL_OUT"
else
  printf '%s\n' 'added | example-ws | HUM-4 | developer' 'set | example-ws | HUM-4 | biz_owner | biz_owner,developer'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
for b in cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u FROM_ROLE \
    -u TENANT_ID -u MEMBER_ROLE -u STUB_PSQL_OUT -u STUB_PSQL_RC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/spl-tenant-member-role-add.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && pass "0. the SQL heredoc has no shell expansion" \
  || fail "0. the SQL heredoc is empty or expanded by the shell"

# --- 1. DRY_RUN plan, no cloud ------------------------------------------------
in_orc 'do_spl_tenant_member_role_add' TENANT_ID=example-ws HUMAN_ID=HUM-4 MEMBER_ROLE=member; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would add developer to the role set of HUM-4 in example-ws (primary role kept)' "$T/out" \
  && grep -q 'Re-run with DRY_RUN=0' "$T/out" \
  && pass "1. DRY_RUN (default): plan, legacy member->developer, no cloud" \
  || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 2. bad input, before any call --------------------------------------------
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_tenant_member_role_add' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing TENANT_ID" HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=0
refuse "bad tenant slug" TENANT_ID=T_1 HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=0
refuse "missing HUMAN_ID" TENANT_ID=example-ws MEMBER_ROLE=developer DRY_RUN=0
refuse "lower-case HUMAN_ID" TENANT_ID=example-ws HUMAN_ID=hum-4 MEMBER_ROLE=developer DRY_RUN=0
refuse "injected HUMAN_ID" TENANT_ID=example-ws "HUMAN_ID=HUM-4' or '1'='1" MEMBER_ROLE=developer DRY_RUN=0
refuse "missing MEMBER_ROLE" TENANT_ID=example-ws HUMAN_ID=HUM-4 DRY_RUN=0
refuse "bad MEMBER_ROLE" TENANT_ID=example-ws HUMAN_ID=HUM-4 MEMBER_ROLE='Dev!' DRY_RUN=0
refuse "DRY_RUN=2" TENANT_ID=example-ws HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=2
refuse "ENV=stg" ENV=stg TENANT_ID=example-ws HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=0

# --- 3. no project SA key -----------------------------------------------------
base=(TENANT_ID=example-ws HUMAN_ID=HUM-4 MEMBER_ROLE=developer)
in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "3. no SA key: refused, no proxy, no psql" || fail "3. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 4. the transaction -------------------------------------------------------
# sql_shape: an ADD keeps the primary: it inserts into the set and never
# writes tenant_memberships.
sql_shape() {
  grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" && grep -qx 'ROLLBACK;' "$T/stdin" \
    && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
    && grep -q 'INSERT INTO tenant_member_roles (tenant_id, human_id, role_id, granted_by)' "$T/stdin" \
    && grep -q "VALUES (:'tenant', :'human', :'role', 'operator')" "$T/stdin" \
    && grep -q 'ON CONFLICT DO NOTHING' "$T/stdin" \
    && grep -q "format('refuse-not-member | %s | %s'" "$T/stdin" \
    && grep -q "format('set | %s | %s | %s | %s'" "$T/stdin" \
    && ! grep -qiE 'UPDATE[[:space:]]+tenant_memberships|INSERT INTO tenant_memberships' "$T/stdin" \
    && ! grep -qiE '\b(delete|drop|truncate|alter)\b' "$T/stdin"
}

in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && sql_shape \
  && grep -q '\[tenant=example-ws\]' "$T/calls.log" && grep -q '\[human=HUM-4\]' "$T/calls.log" \
  && grep -q '\[role=developer\]' "$T/calls.log" \
  && ! grep -q 'HUM-4' "$T/stdin" && ! grep -q 'developer' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK example-ws member HUM-4 now also holds developer ($DEV_SA): set | example-ws | HUM-4 | biz_owner | biz_owner,developer" "$T/out" \
  && pass "4. DRY_RUN=0: one transaction into the set, primary untouched, values as -v, as $DEV_SA" \
  || fail "4. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "4. the DSN password leaked" || pass "4. the DSN password is in neither output, argv nor SQL"

# RED CONTROL: the REPLACE action's SQL must fail the ADD shape check.
in_orc 'do_spl_tenant_member_role' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='example-ws | HUM-4 | developer | operator'
if [[ -s "$T/stdin" ]] && ! sql_shape; then
  pass "4. red control: do_spl_tenant_member_role (replaces the primary) fails the ADD SQL check"
else
  fail "4. red control: the replace action's SQL passed the ADD check (or sent none): $(cat "$T/stdin")"
fi

# --- 5. runner outcomes -------------------------------------------------------
in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='set | example-ws | HUM-4 | biz_owner | biz_owner,developer'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK example-ws member HUM-4 already held developer, nothing changed' "$T/out" \
  && pass "5. a role already held: OK, nothing changed" || fail "5. already: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='refuse-not-member | example-ws | HUM-4'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL HUM-4 is not a member of example-ws' "$T/out" \
  && pass "5. not a member: refused, rolled back" || fail "5. not member: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no role set read back' "$T/out" \
  && pass "5. empty read-back refused" || fail "5. empty: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='set | example-ws | HUM-4 | biz_owner | biz_owner,tester'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL developer is not in the role set' "$T/out" \
  && pass "5. a set without the role refused" || fail "5. missing role: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_tenant_member_role_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_RC=3 STUB_PSQL_OUT='ERROR: role developer cannot share a role set'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL adding developer to HUM-4 in example-ws failed' "$T/out" \
  && pass "5. a psql error (e.g. the exclusive-role trigger) fails the run" || fail "5. psql err: rc=$rc $(cat "$T/out")"

echo
if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
