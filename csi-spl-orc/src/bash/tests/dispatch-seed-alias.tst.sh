#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the dispatcher rotation's seed after a spec 061 L6 role switch
#          (2026-10-02 20:16Z: "FAIL SPAWN: no dispatcher brief for c-002"):
#   1. brief-dispatcher-c-002.md present: used as it is
#   2. only the legacy brief-dispatcher-CLE-002.md: used, every aliased id in
#      it read as its new id (CLE-0022 and XCLE-002 are other words, untouched)
#   3. neither, or an id with no alias row: refused (the caller's FAIL SPAWN)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"; B="$R/dispatch/briefs"; mkdir -p "$B"
printf 'CLE-001\tc-001\tclaude\tbox-t\t2026-10-02T16:35:05Z\nCLE-002\tc-002\tclaude\tbox-t\t2026-10-02T16:35:05Z\nCLE-003\tc-003\tclaude\tbox-t\t2026-10-02T16:35:05Z\n' >"$R/agent-id-aliases.tsv"
printf 'You are CLE-002, the master; CLE-003 is the failover; tell CLE-001.\nspool recv --as CLE-002 (not CLE-0022, not XCLE-002)\n' >"$B/brief-dispatcher-CLE-002.md"
seed() { SNIPPET="spl_disp_seed $1" in_orc SPOOL_ROOT="$R" LEASE_DIR="$R/dispatch" ROTATE_RID=20261002T2015Z-master ROTATE_BOX=box-t ROTATE_HANDOFF="$R/handoff.md" SPOOL_BOX_USER=u ROTATE_ACK_TIMEOUT=600 ROTATE_POLL=5 LEASE_FAILOVER=c-003 2>&1; }

# 2 --------------------------------------------------------------------------
out="$(seed c-002)"; rc=$?
[ "$rc" -eq 0 ] && grep -qx 'You are c-002, the master; c-003 is the failover; tell c-001.' <<<"$out" &&
  pass "2. the legacy brief is used, its ids read as the new ones" || fail "2. legacy brief (rc $rc): $out"
grep -q 'spool recv --as c-002 (not CLE-0022, not XCLE-002)' <<<"$out" && pass "2. ... other words left alone" || fail "2. words: $out"
grep -q 'Hourly rotation 20261002T2015Z-master' <<<"$out" && pass "2. ... with the rotation line" || fail "2. rotation line: $out"
grep -q 'Real lane work is spawned by the dispatcher that took it (SPEC-spool-fleet-roles.md section 3: /spawn-an-agent), not asked of the orchestrator' <<<"${out//$'\n'/ }" &&
  pass "2. ... and the spec 101 R2 rule: the taking dispatcher spawns its own lanes" || fail "2. R2 rule: $out"

# 1 --------------------------------------------------------------------------
echo 'the new brief of c-002' >"$B/brief-dispatcher-c-002.md"
out="$(seed c-002)"; grep -q 'the new brief of c-002' <<<"$out" && ! grep -q 'the master' <<<"$out" &&
  pass "1. a brief for the new id wins" || fail "1. new brief: $out"

# 3 --------------------------------------------------------------------------
seed c-003 >/dev/null; [ "$?" -ne 0 ] && pass "3. no brief under either id: refused" || fail "3. c-003 accepted with no brief"
seed c-009 >/dev/null; [ "$?" -ne 0 ] && pass "3. an id with no alias row and no brief: refused" || fail "3. c-009 accepted"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
