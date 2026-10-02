#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the specs/061 L5 actions on a throwaway root, every cloud call
#          stubbed (the scripts' own cases are features/spawn-agents/tests/
#          test-agent-id-map.sh and test-agent-id-rename.sh).
#   1. do_spl_agent_id_map: the default is a dry run that writes no table
#   2. DRY_RUN=0 writes it; HUB_ENV dry run plans one hub row per (id, tenant
#      whose desk seats it) and calls no proxy
#   3. HUB_ENV DRY_RUN=0: one transaction, operator scope, ON CONFLICT DO
#      NOTHING, a differing row rolls back; the counts are logged
#   4. do_spl_agent_id_rename passes DRY_RUN / ids / desk envs to the script
#   5. do_spl_agent_id_legacy_report: the local lines; with HUB_ENV the hub
#      rows become one LEGACY line per source, the roles counted apart
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"; ST="$T/state/dev"
mkdir -p "$R/agents" "$R/CLE-77/inbox" "$ST/desk/t1/box-t/spool/CLE-77" "$ST/desk/t2/box-t/spool/CLE-001" "$ST/desk/t3/box-t/spool/c-099"
printf '{"id":"CLE-77","alive":true}\n' >"$R/agents/CLE-77.json"
SOCK="$T/tmux.sock"
tmux -S "$SOCK" -f /dev/null new-session -d -s t -n 'CLE-77 lane' 'sleep 600'
trap 'tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"' EXIT
STUBS='do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }
spl_via_proxy() { echo "PROXY $1" >>"$STUB_LOG"; SPL_PROXY_DSN=x "$@"; }
spl_pg_env() { shift; { echo "PSQL $*"; cat; } >>"$SQL_LOG"; printf "%b" "$PG_OUT"; }'
run() {  # ACTION [VAR=value]...
  local a="$1"; shift
  SNIPPET="$STUBS; $a" in_orc SPOOL_ROOT="$R" SPOOL_TEST=1 SPOOL_TMUX_SOCKET="$SOCK" SPOOL_DESK_BOX=box-t \
    SQL_LOG="$T/sql.log" PG_OUT="" "$@" 2>&1
}

# 1 --------------------------------------------------------------------------
out="$(run do_spl_agent_id_map)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'CLE-77	c-004	claude	box-t' <<<"$out" && pass "1. the dry run plans CLE-77 -> c-004" || fail "1. dry run (rc $rc: $out)"
[ ! -e "$R/agent-id-aliases.tsv" ] && pass "1. ...and writes no table" || fail "1. the dry run wrote the table"

# 2 --------------------------------------------------------------------------
out="$(run do_spl_agent_id_map DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c . "$R/agent-id-aliases.tsv")" = 4 ] && pass "2. DRY_RUN=0 writes 3 roles + 1 agent" || fail "2. write (rc $rc: $out)"
: >"$T/calls.log"
out="$(run do_spl_agent_id_map HUB_ENV=dev)"; rc=$?
grep -q 'INFO dev t1: CLE-77 -> c-004' <<<"$out" && grep -q 'INFO dev t2: CLE-001 -> c-001' <<<"$out" \
  && grep -q 'would write 2 alias row' <<<"$out" && pass "2. the hub dry run plans the tenants whose desk seats each id" || fail "2. hub plan (rc $rc: $out)"
grep -q 't3' <<<"$out" && fail "2. a desk seating no mapped id got a row" || pass "2. ...and no other tenant"
[ ! -s "$T/calls.log" ] && pass "2. ...and calls no proxy" || fail "2. the dry run called $(cat "$T/calls.log")"
out="$(run do_spl_agent_id_map HUB_ENV=stage)"; [ $? -ne 0 ] && pass "2. HUB_ENV other than dev/prd is refused" || fail "2. HUB_ENV=stage accepted"

# 3 --------------------------------------------------------------------------
: >"$T/sql.log"
out="$(run do_spl_agent_id_map HUB_ENV=dev DRY_RUN=0 PG_OUT='differ | 0\ninserted | 1\n')"; rc=$?
[ "$rc" -eq 0 ] && grep -q '2 row(s) wanted, 1 inserted, 1 already there' <<<"$out" && pass "3. the write logs wanted / inserted / already there" || fail "3. write (rc $rc: $out)"
grep -q "SET LOCAL app.rls_scope = 'operator'" "$T/sql.log" && grep -q "ON CONFLICT (tenant_id, old_id, box_id) DO NOTHING" "$T/sql.log" \
  && grep -q "('t1','CLE-77','c-004','claude','box-t','" "$T/sql.log" && pass "3. one operator-scope tx, idempotent insert of the checked rows" || fail "3. SQL ($(cat "$T/sql.log"))"
grep -q '\\if :bad' "$T/sql.log" && grep -q 'ROLLBACK' "$T/sql.log" && pass "3. a differing row rolls the write back" || fail "3. no rollback branch"
out="$(run do_spl_agent_id_map HUB_ENV=dev DRY_RUN=0 PG_OUT='differ | 1\n')"
[ $? -ne 0 ] && grep -q 'ANOTHER new id: rolled back' <<<"$out" && pass "3. ...and fails naming it" || fail "3. differ ($out)"

# 4 --------------------------------------------------------------------------
out="$(run do_spl_agent_id_rename RENAME_IDS=CLE-77 RENAME_DESK_ENVS=dev)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'PLAN spool     CLE-77' <<<"$out" && grep -q 'PLAN desk      CLE-77     dev/t1' <<<"$out" \
  && pass "4. the rename action plans by default, ids and desk envs passed on" || fail "4. rename dry (rc $rc: $out)"
[ -d "$R/CLE-77/inbox" ] && [ ! -L "$R/CLE-77" ] && pass "4. ...and moves nothing" || fail "4. the dry run moved"

# 5 --------------------------------------------------------------------------
out="$(run do_spl_agent_id_legacy_report)"
grep -q '^LEGACY windows    1 CLE-77$' <<<"$out" && pass "5. the local report counts the window" || fail "5. local ($out)"
: >"$T/calls.log"
out="$(run do_spl_agent_id_legacy_report HUB_ENV=prd PG_OUT='hub_lanes_live CLE-77 1\nhub_sends_24h CLE-002 4\nhub_sends_24h CLE-77 3\n')"
grep -q '^LEGACY prd:hub_sends_24h 7 roles 1 CLE-002 CLE-77$' <<<"$out" && grep -q '^LEGACY prd:hub_lanes_live 1 CLE-77$' <<<"$out" \
  && pass "5. HUB_ENV adds the hub lines, roles apart" || fail "5. hub ($out)"
grep -q 'default_transaction_read_only\|READ ONLY' "$T/sql.log" && pass "5. the hub read is a read-only transaction" || fail "5. not read-only"

echo "agent-id-map: ${fails} failure(s)"
[ "$fails" -eq 0 ]
