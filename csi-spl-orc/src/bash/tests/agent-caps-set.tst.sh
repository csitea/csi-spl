#!/usr/bin/env bash
# do_spl_agent_caps_set: the argument guards (hermetic), then the caps write
# against a REAL throwaway Postgres carrying the real rdb migrations, as the
# NON-owner runtime login so rdb 0212 row-level security binds.
#
# The controls are the point:
#   - DRY_RUN=1 runs the same writes and rolls them back: no cap, no audit row
#   - DRY_RUN=0 without AGENT_ID, ORDERED_BY and OWNER_MSG_ID is refused
#     before any cloud call; the audit row names the agent and the owner msg
#   - ALL=1 caps the one vendor in every workspace and NOTHING of another vendor
#   - a re-run writes nothing (an unchanged cap is no audit row)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-agent-caps-set.func.sh"
[[ -f "$FUNC" ]] || { echo "FAIL: no $FUNC"; exit 1; }
grep -q "SET LOCAL app.rls_scope = 'operator'" "$FUNC" && pass "the write runs in the operator RLS scope" || fail "no operator scope"

# --- the argument guards, sourced like the other orc tests (no ./run) ---------
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u TENANT_ID -u ALL -u CAPS_VENDOR -u CAPS_MAX_LIVE -u ORDERED_BY -u AGENT_ID -u OWNER_MSG_ID -u DRY_RUN \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_agent_caps_set' >"$T/out" 2>&1 </dev/null
}
guard() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  act "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
OK=(CAPS_VENDOR=grok CAPS_MAX_LIVE=0)
guard "no TENANT_ID and no ALL"     "TENANT_ID must be a tenant slug" "${OK[@]}"
guard "TENANT_ID and ALL=1"         "not both"                        "${OK[@]}" TENANT_ID=t1 ALL=1
guard "a bad ALL"                   "ALL must be 0 or 1"              "${OK[@]}" ALL=yes
guard "a bad TENANT_ID"             "TENANT_ID must be a tenant slug" "${OK[@]}" TENANT_ID=T_1
guard "a missing vendor"            "CAPS_VENDOR must be"             ALL=1 CAPS_MAX_LIVE=0
guard "an unknown vendor"           "CAPS_VENDOR must be"             ALL=1 CAPS_VENDOR=gpt CAPS_MAX_LIVE=0
guard "a missing max_live"          "CAPS_MAX_LIVE must be"           ALL=1 CAPS_VENDOR=grok
guard "a negative max_live"         "CAPS_MAX_LIVE must be"           ALL=1 CAPS_VENDOR=grok CAPS_MAX_LIVE=-1
guard "a padded max_live"           "CAPS_MAX_LIVE must be"           ALL=1 CAPS_VENDOR=grok CAPS_MAX_LIVE=01
guard "a bad DRY_RUN"               "DRY_RUN must be 0 or 1"          "${OK[@]}" ALL=1 DRY_RUN=yes
MSG=d131a690-2c55-4ff7-8863-f24e0c0a9276
WHO=(AGENT_ID=c-080 ORDERED_BY=HUM-10 "OWNER_MSG_ID=$MSG")
guard "DRY_RUN=0 without AGENT_ID"   "needs AGENT_ID=<the acting agent" "${OK[@]}" ALL=1 DRY_RUN=0 ORDERED_BY=HUM-10 OWNER_MSG_ID=$MSG
guard "a HUM- as AGENT_ID"           "needs AGENT_ID=<the acting agent" "${OK[@]}" ALL=1 DRY_RUN=0 "${WHO[@]}" AGENT_ID=HUM-10
guard "the -000 seat as AGENT_ID"    "needs AGENT_ID=<the acting agent" "${OK[@]}" ALL=1 DRY_RUN=0 "${WHO[@]}" AGENT_ID=c-000
guard "DRY_RUN=0 without ORDERED_BY" "needs ORDERED_BY=<HUM-n>"         "${OK[@]}" ALL=1 DRY_RUN=0 AGENT_ID=c-080 OWNER_MSG_ID=$MSG
guard "an agent as ORDERED_BY"       "needs ORDERED_BY=<HUM-n>"         "${OK[@]}" ALL=1 DRY_RUN=0 "${WHO[@]}" ORDERED_BY=c-080
guard "DRY_RUN=0 without OWNER_MSG_ID" "needs OWNER_MSG_ID=<the owner"  "${OK[@]}" ALL=1 DRY_RUN=0 AGENT_ID=c-080 ORDERED_BY=HUM-10
guard "a short OWNER_MSG_ID"         "needs OWNER_MSG_ID=<the owner"    "${OK[@]}" ALL=1 DRY_RUN=0 "${WHO[@]}" OWNER_MSG_ID=d131a690
act "${OK[@]}" ALL=1
grep -q REACHED-CLOUD "$T/out" && pass "CONTROL: a DRY_RUN with ALL=1 passes the guards (no AGENT_ID / ORDERED_BY / OWNER_MSG_ID needed)" || fail "dry ALL=1 refused: $(cat "$T/out")"
act "${OK[@]}" TENANT_ID=t1 DRY_RUN=0 "${WHO[@]}" AGENT_ID=c-080@sat
grep -q REACHED-CLOUD "$T/out" && pass "CONTROL: DRY_RUN=0 with AGENT_ID (c-080@sat), ORDERED_BY and OWNER_MSG_ID passes the guards" || fail "real refused: $(cat "$T/out")"

# --- the write against a real Postgres ---------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no cached $PG_IMAGE image; the SQL part is not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") guard assertions (SQL part skipped)"; exit 0; }
  echo "FAIL: $fails assertion(s)"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-agent-caps-set-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$HERE/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }

psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
for t in ops wa wb; do
  psql_owner -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab',32),'hex')) ON CONFLICT DO NOTHING" >/dev/null
done
psql_owner -c "UPDATE tenants SET is_operator = true WHERE tenant_id = 'ops'" >/dev/null
# wb already caps grok at 2, and claude at 3 (the other vendor that must stay)
psql_owner -c "INSERT INTO tenant_agent_caps (tenant_id, vendor, max_live, updated_by) VALUES ('wb','grok',2,'HUM-1'), ('wb','claude',3,'HUM-1')" >/dev/null
caps() { psql_owner -c "SELECT string_agg(tenant_id||':'||vendor||'='||max_live, ',' ORDER BY tenant_id, vendor) FROM tenant_agent_caps"; }
audits() { psql_owner -c "SELECT count(*) FROM operator_audit WHERE action IN ('set_agent_caps','delete_agent_cap')"; }

set_run() { # <dry> <tenant|''> <vendor> <n>
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com SPL_PROXY_DSN="$RT_DSN" \
    SPL_AC_DRY="$1" SPL_AC_TENANT="$2" SPL_AC_VENDOR="$3" SPL_AC_N="$4" SPL_AC_AGENT=c-080 SPL_AC_BY=HUM-10 SPL_AC_MSG="$MSG" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-agent-caps-set.func.sh"
    _spl_agent_caps_set_run' >"$T/out" 2>&1
}
before="$(caps)"
set_run 1 "" grok 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "workspaces=4 written=4 readback_match=4 committed=f" "$T/out" && grep -qx "wb | 2 -> 0" "$T/out" \
  && grep -qx "wa | uncapped -> 0" "$T/out" && [[ "$(caps)" == "$before" && "$(audits)" == 0 ]] \
  && pass "DRY_RUN prints before -> after per workspace and rolls back: no cap, no audit row" \
  || fail "dry: rc=$rc $(cat "$T/out") caps=$(caps) audits=$(audits)"

set_run 0 "" grok 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "workspaces=4 written=4 readback_match=4 committed=t" "$T/out" \
  && [[ "$(caps)" == "ops:grok=0,system:grok=0,wa:grok=0,wb:claude=3,wb:grok=0" ]] \
  && pass "ALL=1 grok=0 caps every workspace, reads back 4 of 4 (the migrations seed system)" || fail "all: rc=$rc $(cat "$T/out") caps=$(caps)"
[[ "$(caps)" == *"wb:claude=3"* ]] && pass "CONTROL: the claude cap of wb is untouched" || fail "claude touched: $(caps)"
a="$(psql_owner -c "SELECT concat_ws(' ', actor_tenant, actor_hum, detail->>'previous', detail->>'agent', detail->>'ordered_by', detail->>'owner_msg') FROM operator_audit WHERE tenant_id='wb' AND action='set_agent_caps'")"
[[ "$(audits)" == 4 && "$a" == "ops c-080 2 c-080 HUM-10 $MSG" ]] \
  && pass "one audit row per changed workspace: actor the agent c-080, ordered_by HUM-10, owner_msg, previous 2" \
  || fail "audit: n=$(audits) wb=$a"

u="$(psql_owner -c "SELECT string_agg(DISTINCT updated_by, ',') FROM tenant_agent_caps WHERE vendor='grok'")"
[[ "$u" == c-080 ]] && pass "the caps' updated_by is the acting agent" || fail "updated_by: $u"

set_run 0 "" grok 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "written=0 readback_match=4 committed=t" "$T/out" && [[ "$(audits)" == 4 ]] \
  && pass "a re-run writes nothing and adds no audit row" || fail "rerun: rc=$rc $(cat "$T/out") audits=$(audits)"

set_run 0 wa grok none; rc=$?
[[ $rc -eq 0 ]] && grep -q "workspaces=1 written=1 readback_match=1 committed=t" "$T/out" \
  && [[ "$(caps)" == "ops:grok=0,system:grok=0,wb:claude=3,wb:grok=0" ]] && [[ "$(psql_owner -c "SELECT count(*) FROM operator_audit WHERE action='delete_agent_cap'")" == 1 ]] \
  && pass "TENANT_ID=wa none removes only wa's grok cap (delete_agent_cap)" || fail "none: rc=$rc $(cat "$T/out") caps=$(caps)"

set_run 0 nope grok 0; rc=$?
[[ $rc -ne 0 ]] && grep -q "no workspace 'nope'" "$T/out" && pass "an unknown workspace fails and writes nothing" || fail "unknown: rc=$rc $(cat "$T/out")"

# CONTROL: without the operator scope the runtime login cannot write (rdb 0212 RLS)
w="$(PGPASSWORD=rt psql -X -q -At "$RT_DSN" -c "INSERT INTO tenant_agent_caps (tenant_id, vendor, max_live, updated_by) VALUES ('wa','qwen',1,'HUM-10')" 2>&1)"
[[ "$w" == *"row-level security"* ]] && pass "CONTROL: a write outside the operator scope is refused by RLS" || fail "RLS let a write through: $w"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
