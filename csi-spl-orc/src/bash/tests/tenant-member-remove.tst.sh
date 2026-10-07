#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_tenant_member_remove, the shell twin of the hub's
#          DELETE /v1/members/{human_id}. Part A stubs gcloud and psql (an
#          absent call is absent); part B runs the action's SQL against a REAL
#          throwaway Postgres with the real rdb migrations, as a NON-owner
#          login so rdb 0014 row-level security binds (SKIP when no docker /
#          psql / cached postgres image).
#   A1. DRY_RUN (the default) prints the plan and calls no cloud; EMAIL is
#       lower-cased in it; prd names the prd connection
#   A2. bad input is refused before any gcloud or psql call, including a
#       value that would splice into SQL if it were interpolated
#   A3. DRY_RUN=0 with no project SA key never reaches psql
#   A4. DRY_RUN=0 runs as the env SA through the proxy; the human id and the
#       email are -v values, not text in the SQL
#   A5. the runner reports each refusal marker as a FATAL; CONTROL: removed +
#       audit lines are an OK
#   B1. remove a member: the row is gone and one member_activity row says
#       'removed' by 'operator'; CONTROL: the other members stay
#   B2. the last owner is refused and nothing changes; CONTROL: once a second
#       owner exists, the same removal succeeds
#   B3. an unknown human, a non-member and an email with no identity are
#       refused and nothing changes; CONTROL: an email resolving to exactly
#       one member removes that member
#   B4. the last admin (members.invite) is refused; CONTROL: a non-admin in
#       the same workspace is removed
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-tenant-member-remove.func.sh"
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "FAIL: no yq"; exit 1; }

bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && pass "0. the SQL heredoc has no shell expansion" \
  || fail "0. the SQL heredoc is empty or expanded by the shell"

# A ---------------------------------------------------------------------------
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
  printf '%s\n' 'removed | t1 | HUM-4 | developer' 'audit | 7 | HUM-4 | operator'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
for b in cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u EMAIL \
    -u TENANT_ID -u STUB_PSQL_OUT -u STUB_PSQL_RC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    do_spl_tenant_member_remove' >"$T/out" 2>&1 </dev/null
}

in_orc TENANT_ID=t1 HUMAN_ID=HUM-4; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would remove HUM-4 from t1 (refusing the last owner or last admin)' "$T/out" \
  && grep -q "record member_activity 'removed' by operator on csi-spl-dev:" "$T/out" \
  && pass "A1. HUMAN_ID DRY_RUN (default): plan, no cloud" || fail "A1. human dry: rc=$rc $(cat "$T/out" "$T/calls.log")"
in_orc TENANT_ID=t1 EMAIL=Person@Example.COM DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'would remove person@example.com from t1' "$T/out" \
  && ! grep -q 'Person@Example.COM' "$T/out" \
  && pass "A1. EMAIL DRY_RUN: lower-cased, no cloud" || fail "A1. email dry: rc=$rc $(cat "$T/out")"
in_orc ENV=prd TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'on csi-spl-prd:' "$T/out" \
  && pass "A1. prd DRY_RUN names the prd connection, no cloud" || fail "A1. prd dry: rc=$rc $(cat "$T/out")"

refuse() {
  local label="$1"; shift
  in_orc "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "A2. $label refused before any call" || fail "A2. $label: rc=$rc $(cat "$T/out" "$T/calls.log")"
}
refuse "missing TENANT_ID" HUMAN_ID=HUM-4 DRY_RUN=0
refuse "bad tenant slug" TENANT_ID=T_1 HUMAN_ID=HUM-4 DRY_RUN=0
refuse "neither HUMAN_ID nor EMAIL" TENANT_ID=t1 DRY_RUN=0
refuse "both HUMAN_ID and EMAIL" TENANT_ID=t1 HUMAN_ID=HUM-4 EMAIL=a@example.com DRY_RUN=0
refuse "lower-case HUMAN_ID" TENANT_ID=t1 HUMAN_ID=hum-4 DRY_RUN=0
refuse "injected HUMAN_ID" TENANT_ID=t1 "HUMAN_ID=HUM-4' or '1'='1" DRY_RUN=0
refuse "EMAIL that is not an email" TENANT_ID=t1 EMAIL=nope DRY_RUN=0
refuse "DRY_RUN=2" TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=2
refuse "ENV=stg" ENV=stg TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=0

in_orc TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "A3. no SA key: refused, no proxy, no psql" || fail "A3. no key: rc=$rc $(cat "$T/calls.log" "$T/out")"

in_orc TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q '\[tenant=t1\]' "$T/calls.log" && grep -q '\[human=HUM-4\]' "$T/calls.log" && grep -q '\[email=\]' "$T/calls.log" \
  && ! grep -q 'HUM-4' "$T/stdin" && grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" \
  && grep -q "OK removed from t1 ($DEV_SA): removed | t1 | HUM-4 | developer; audit | 7 | HUM-4 | operator" "$T/out" \
  && pass "A4. DRY_RUN=0: as $DEV_SA, values as -v, one transaction" || fail "A4. real: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "A4. the DSN password leaked" || pass "A4. the DSN password is in neither output, argv nor SQL"
in_orc TENANT_ID=t1 EMAIL="o'ne@example.com" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "\[email=o'ne@example.com\]" "$T/calls.log" && grep -q '\[human=\]' "$T/calls.log" \
  && ! grep -q "o'ne@example.com" "$T/stdin" \
  && pass "A4. EMAIL reaches psql as -v (quote included), absent from the SQL" || fail "A4. email: rc=$rc $(cat "$T/calls.log")"

marker() {
  local label="$1" out="$2" want="$3"
  in_orc TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=0 STUB_PSQL_OUT="$out"; rc=$?
  [[ $rc -ne 0 ]] && grep -qF "$want" "$T/out" && ! grep -q '^OK removed' "$T/out" \
    && pass "A5. $label" || fail "A5. $label: rc=$rc $(cat "$T/out")"
}
marker "refuse-human -> FATAL" 'refuse-human | 0' 'matches 0 human(s) in human_identities'
marker "refuse-not-member -> FATAL" 'refuse-not-member | HUM-4' 'FATAL HUM-4 is not a member of t1'
marker "refuse-last-owner -> FATAL" 'refuse-last-owner | HUM-4' 'FATAL HUM-4 is the last owner of t1'
marker "refuse-last-admin -> FATAL" 'refuse-last-admin | HUM-4' 'FATAL HUM-4 is the last admin'
marker "no audit line -> FATAL" 'removed | t1 | HUM-4 | developer' 'no single removed+audit result'

# B ---------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: part B, no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-member-remove-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

# t1: HUM-1 biz_owner (the only owner), HUM-2 developer, HUM-3 tester (email
# three@example.com). t2: HUM-1 biz_owner, HUM-5 admin, HUM-6 developer.
q "INSERT INTO humans (human_id) VALUES ('HUM-1'), ('HUM-2'), ('HUM-3'), ('HUM-4'), ('HUM-5'), ('HUM-6')" >/dev/null
for t in t1 t2; do
  q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null
done
q "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
     ('t1', 'HUM-1', 'biz_owner', 'operator'), ('t1', 'HUM-2', 'developer', 'operator'),
     ('t1', 'HUM-3', 'tester', 'operator'),
     ('t2', 'HUM-1', 'biz_owner', 'operator'), ('t2', 'HUM-5', 'admin', 'operator'),
     ('t2', 'HUM-6', 'developer', 'operator')" >/dev/null
q "INSERT INTO human_identities (provider, subject, human_id, email) VALUES ('google', 's-3', 'HUM-3', 'three@example.com')" >/dev/null
members() { q "SELECT coalesce(string_agg(human_id || ':' || role, ',' ORDER BY human_id), '') FROM tenant_memberships WHERE tenant_id = '$1'"; }
audits() { q "SELECT coalesce(string_agg(subject_hum || ':' || kind || ':' || actor_hum, ',' ORDER BY activity_id), '') FROM member_activity WHERE tenant_id = '$1'"; }

# runb <tenant> <human> <email>: the action's runner against the real DB, as the runtime login
runb() {
  env FUNC="$FUNC" SPL_PROXY_DSN="$RT_DSN" GCP_ACCOUNT=sa@example.com bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$FUNC"
    _spl_tenant_member_remove_run "$@"' _ "$@" >"$T/o" 2>&1
}

runb t1 HUM-2 ""; rc=$?
[[ $rc -eq 0 && "$(members t1)" == "HUM-1:biz_owner,HUM-3:tester" && "$(audits t1)" == "HUM-2:removed:operator" ]] \
  && grep -q '^OK removed from t1 (sa@example.com): removed | t1 | HUM-2 | developer; audit | ' "$T/o" \
  && pass "B1. HUM-2 removed: row gone, one 'removed' audit row by operator" || fail "B1. rc=$rc $(cat "$T/o") / $(members t1) / $(audits t1)"
[[ "$(members t2)" == "HUM-1:biz_owner,HUM-5:admin,HUM-6:developer" && -z "$(audits t2)" ]] \
  && pass "B1. CONTROL: the other workspace is untouched" || fail "B1. t2: $(members t2) / $(audits t2)"

runb t1 HUM-1 ""; rc=$?
[[ $rc -ne 0 && "$(members t1)" == "HUM-1:biz_owner,HUM-3:tester" && "$(audits t1)" == "HUM-2:removed:operator" ]] \
  && grep -q 'FATAL HUM-1 is the last owner of t1' "$T/o" \
  && pass "B2. the last owner is refused; nothing changed" || fail "B2. rc=$rc $(cat "$T/o") / $(members t1) / $(audits t1)"
q "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES ('t1', 'HUM-4', 'biz_owner', 'operator')" >/dev/null
runb t1 HUM-1 ""; rc=$?
[[ $rc -eq 0 && "$(members t1)" == "HUM-3:tester,HUM-4:biz_owner" ]] \
  && pass "B2. CONTROL: with a second owner, the same removal succeeds" || fail "B2. control rc=$rc $(cat "$T/o") / $(members t1)"

before="$(members t1)|$(audits t1)"
runb t1 HUM-99 ""; rc=$?
[[ $rc -ne 0 && "$(members t1)|$(audits t1)" == "$before" ]] && grep -q 'FATAL HUM-99 is not a member of t1' "$T/o" \
  && pass "B3. an unknown human is refused; nothing changed" || fail "B3. unknown rc=$rc $(cat "$T/o")"
runb t1 HUM-6 ""; rc=$?
[[ $rc -ne 0 && "$(members t1)|$(audits t1)" == "$before" && "$(members t2)" == "HUM-1:biz_owner,HUM-5:admin,HUM-6:developer" ]] \
  && grep -q 'FATAL HUM-6 is not a member of t1' "$T/o" \
  && pass "B3. another workspace's member is refused; nothing changed anywhere" || fail "B3. non-member rc=$rc $(cat "$T/o")"
runb t1 "" nobody@example.com; rc=$?
[[ $rc -ne 0 && "$(members t1)|$(audits t1)" == "$before" ]] && grep -q 'matches 0 human(s)' "$T/o" \
  && pass "B3. an email with no identity is refused; nothing changed" || fail "B3. email rc=$rc $(cat "$T/o")"
runb t1 "" three@example.com; rc=$?
[[ $rc -eq 0 && "$(members t1)" == "HUM-4:biz_owner" && "$(audits t1)" == *",HUM-3:removed:operator" ]] \
  && pass "B3. CONTROL: an email resolving to one member removes that member" || fail "B3. control rc=$rc $(cat "$T/o") / $(members t1)"

# t2: a second owner, then both owners disabled: HUM-5 (admin) is the last
# ENABLED member holding members.invite.
q "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES ('t2', 'HUM-2', 'biz_owner', 'operator')" >/dev/null
q "UPDATE humans SET disabled_at = now() WHERE human_id IN ('HUM-1', 'HUM-2')" >/dev/null
runb t2 HUM-5 ""; rc=$?
[[ $rc -ne 0 && "$(members t2)" == "HUM-1:biz_owner,HUM-2:biz_owner,HUM-5:admin,HUM-6:developer" && -z "$(audits t2)" ]] \
  && grep -q 'FATAL HUM-5 is the last admin (members.invite) of t2' "$T/o" \
  && pass "B4. the last enabled admin is refused; nothing changed" || fail "B4. rc=$rc $(cat "$T/o") / $(members t2)"
runb t2 HUM-6 ""; rc=$?
[[ $rc -eq 0 && "$(members t2)" == "HUM-1:biz_owner,HUM-2:biz_owner,HUM-5:admin" && "$(audits t2)" == "HUM-6:removed:operator" ]] \
  && pass "B4. CONTROL: a non-admin in the same workspace is removed" || fail "B4. control rc=$rc $(cat "$T/o") / $(members t2)"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
