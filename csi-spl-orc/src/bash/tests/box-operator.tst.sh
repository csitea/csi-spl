#!/usr/bin/env bash
#------------------------------------------------------------------------------
# do_spl_box_operator_{grant,revoke,list} (rdb 0040, specs/036 FR-010):
#   1. DRY_RUN (default) calls no cloud; bad input is refused before any call
#   2. DRY_RUN=0 runs as the env's project SA through the proxy, in the
#      tenant's RLS scope; values reach psql as -v variables (never spliced
#      into the SQL); the DSN is never printed
#   3. grant: the owner / admin rule and the member rule are in the statement;
#      zero returned rows is a FATAL, not a silent success
#   4. list is read-only (BEGIN READ ONLY .. ROLLBACK) and exits 2 on none
# gcloud and psql are stubbed and record every call (CONTROL: an absent call
# means "not made", not "not recorded").
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
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
# psql: record argv and stdin; answer $PSQL_OUT (default: one returned row)
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
printf '%s' "${PSQL_OUT-t1 | box-a | HUM-4 | operator | 2026-09-25 00:00:00+00
}"
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

G=(TENANT_ID=t1 BOX_ID=box-a HUMAN_ID=HUM-4)

# --- 1. dry run + input ---------------------------------------------------------------
for a in grant revoke; do
  in_orc "do_spl_box_operator_$a" "${G[@]}"; rc=$?
  [[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would' "$T/out" && pass "1. $a DRY_RUN: no cloud call" || fail "1. $a dry: rc=$rc $(cat "$T/out")"
  for bad in "HUMAN_ID=HUM-4' or '1'='1" 'HUMAN_ID=bob' 'BOX_ID=Box_A' 'TENANT_ID=T 1' 'HUMAN_ID=' 'DRY_RUN=yes'; do
    in_orc "do_spl_box_operator_$a" "${G[@]}" DRY_RUN=0 "$bad"; rc=$?
    [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $a $bad refused before any call" || fail "1. $a $bad: rc=$rc"
  done
done
for bad in 'GRANTED_BY=HUM-4; drop table x' 'GRANTED_BY=admin'; do
  in_orc do_spl_box_operator_grant "${G[@]}" "$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. grant $bad refused before any call" || fail "1. grant $bad: rc=$rc"
done
in_orc do_spl_box_operator_list TENANT_ID=t1 'BOX_ID=a b'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. list BOX_ID='a b' refused before any call" || fail "1. list bad box: rc=$rc"

# --- 2. real grant --------------------------------------------------------------------
in_orc do_spl_box_operator_grant "${G[@]}" GRANTED_BY=HUM-9 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && pass "2. grant DRY_RUN=0 runs as the env SA $DEV_SA" || fail "2. grant real: rc=$rc $(cat "$T/out" "$T/calls.log")"
grep -q '\[tenant=t1\]' "$T/calls.log" && grep -q '\[box=box-a\]' "$T/calls.log" && grep -q '\[human=HUM-4\]' "$T/calls.log" && grep -q '\[by=HUM-9\]' "$T/calls.log" \
  && ! grep -qE 'HUM-4|HUM-9|box-a' "$T/stdin" && pass "2. values reach psql as -v variables; the SQL holds only :'var' references" || fail "2. grant vars: $(cat "$T/calls.log")"
grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" && pass "2. grant runs in the tenant's RLS scope (rdb 0040 FORCE RLS)" || fail "2. grant: no tenant RLS scope"
grep -q "role IN ('biz_owner', 'admin', 'owner')" "$T/stdin" && grep -q 'FROM tenant_memberships WHERE tenant_id = :'"'"'tenant'"'"' AND human_id = :'"'"'human'"'"'' "$T/stdin" \
  && pass "3. the owner / admin rule and the member rule are in the statement" || fail "3. grant rules missing: $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" && fail "2. the DSN password leaked" || pass "2. the DSN password is in neither output nor argv"
in_orc do_spl_box_operator_grant "${G[@]}" DRY_RUN=0; rc=$?
grep -q '\[by=operator\]' "$T/calls.log" && pass "2. GRANTED_BY defaults to 'operator'" || fail "2. default granted_by: $(cat "$T/calls.log")"
in_orc do_spl_box_operator_grant "${G[@]}" DRY_RUN=0 PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no grant' "$T/out" && pass "3. zero returned rows (not a member / not an owner) is a FATAL" || fail "3. zero rows: rc=$rc $(cat "$T/out")"

# --- 2. revoke ------------------------------------------------------------------------
in_orc do_spl_box_operator_revoke "${G[@]}" DRY_RUN=0 PSQL_OUT='t1 | box-a | HUM-4'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'revoked' "$T/out" && grep -q "DELETE FROM box_operators WHERE tenant_id = :'tenant'" "$T/stdin" \
  && pass "2. revoke DRY_RUN=0 deletes the one binding" || fail "2. revoke: rc=$rc $(cat "$T/out")"
in_orc do_spl_box_operator_revoke "${G[@]}" DRY_RUN=0 PSQL_OUT=''; rc=$?
[[ $rc -eq 0 ]] && grep -q 'nothing to revoke' "$T/out" && pass "2. revoking an absent binding is a no-op that says so" || fail "2. revoke absent: rc=$rc $(cat "$T/out")"

# --- 4. list --------------------------------------------------------------------------
in_orc do_spl_box_operator_list TENANT_ID=t1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'BEGIN TRANSACTION READ ONLY;' "$T/stdin" && grep -qx 'ROLLBACK;' "$T/stdin" && grep -q 'HUM-4' "$T/out" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && pass "4. list is read-only, as $DEV_SA, and prints the rows" || fail "4. list: rc=$rc $(cat "$T/out")"
in_orc do_spl_box_operator_list TENANT_ID=t1 PSQL_OUT=''; rc=$?
[[ $rc -eq 2 ]] && pass "4. list exits 2 when there is none" || fail "4. list none: rc=$rc"

# --- identity: never the owner account -------------------------------------------------
in_orc do_spl_box_operator_grant "${G[@]}" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json" HOME="$T/nohome"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" && pass "2. no SA key: refused, no proxy, no psql" || fail "2. no key: rc=$rc $(cat "$T/calls.log")"

echo "box-operator: $fails failure(s)"
[[ $fails -eq 0 ]]
