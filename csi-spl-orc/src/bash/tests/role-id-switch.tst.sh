#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_role_id_switch (spec 061 L6) on a throwaway root: one role
#          moves from CLE-00N to c-00N - spool dir, lease.conf line, resume -
#          with no live process (the resume finds none in the sandbox).
#   1. the default is a dry run: plans the rename, touches nothing
#   2. an id that is no role row, and a role no lease line names, are refused
#   3. DRY_RUN=0: c-003 is the dir, CLE-003 its link, LEASE_FAILOVER=c-003,
#      the other lease lines untouched, a backup kept
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"
mkdir -p "$R/dispatch" "$R/agents" "$R/CLE-003/inbox" "$T/sessions"
ln -s CLE-003 "$R/c-003"
printf 'CLE-001\tc-001\tclaude\tbox-t\t2026-10-02T16:35:05Z\nCLE-003\tc-003\tclaude\tbox-t\t2026-10-02T16:35:05Z\nCLE-77\tc-004\tclaude\tbox-t\t2026-10-02T16:35:05Z\n' >"$R/agent-id-aliases.tsv"
printf 'LEASE_MASTER=CLE-002\nLEASE_FAILOVER=CLE-003\nLEASE_ORCH=CLE-009\nLEASE_ENV=prd\n' >"$R/dispatch/lease.conf"
printf 'SPOOL_AGENT_USER=%s\n' "$(id -un)" >"$R/box.env"
SOCK="$T/tmux.sock"
tmux -S "$SOCK" -f /dev/null new-session -d -s t -n 'CLE-003@tg dispatcher' 'sleep 600'
trap 'tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"' EXIT
run() {  # [VAR=value]...
  SNIPPET="do_spl_role_id_switch" in_orc SPOOL_ROOT="$R" SPOOL_TEST=1 SPOOL_TMUX_SOCKET="$SOCK" SPOOL_DESK_BOX=box-t \
    SPOOL_BOX_TAG=tg SPOOL_BOX_USER="$(id -un)" RESUME_SESSIONS_DIR="$T/sessions" SWITCH_DESK_ENVS="" SWITCH_SETTLE=0 "$@" 2>&1
}

# 1 --------------------------------------------------------------------------
out="$(run ROLE_ID=CLE-003)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'role LEASE_FAILOVER: CLE-003 -> c-003' <<<"$out" && grep -q 'PLAN spool     CLE-003' <<<"$out" &&
  pass "1. the dry run plans the failover switch" || fail "1. dry run (rc $rc: $out)"
[ -L "$R/c-003" ] && grep -qx LEASE_FAILOVER=CLE-003 "$R/dispatch/lease.conf" && pass "1. ...and touches nothing" || fail "1. the dry run touched something"

# 2 --------------------------------------------------------------------------
out="$(run ROLE_ID=CLE-77)"; [ "$?" -ne 0 ] && grep -q 'is no role row' <<<"$out" && pass "2. a lane id is refused" || fail "2. lane id: $out"
out="$(run ROLE_ID=c-001)"; [ "$?" -ne 0 ] && grep -q 'no LEASE_ORCH / LEASE_MASTER / LEASE_FAILOVER line names CLE-001' <<<"$out" &&
  pass "2. a role no lease line names is refused" || fail "2. unnamed role: $out"

# 3 --------------------------------------------------------------------------
out="$(run ROLE_ID=c-003 DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ -d "$R/c-003" ] && [ ! -L "$R/c-003" ] && [ "$(readlink "$R/CLE-003")" = c-003 ] &&
  pass "3. c-003 is the dir, CLE-003 its link" || fail "3. layout (rc $rc: $out)"
[ "$(grep -E '^LEASE_(MASTER|FAILOVER|ORCH)=' "$R/dispatch/lease.conf" | tr '\n' ' ')" = "LEASE_MASTER=CLE-002 LEASE_FAILOVER=c-003 LEASE_ORCH=CLE-009 " ] &&
  pass "3. lease.conf: LEASE_FAILOVER=c-003, the others untouched" || fail "3. lease.conf: $(cat "$R/dispatch/lease.conf")"
compgen -G "$R/dispatch/lease.conf.bak-*" >/dev/null && pass "3. a backup is kept" || fail "3. no backup"
tmux -S "$SOCK" list-windows -F '#{window_name}' | grep -x 'c-003@tg dispatcher' >/dev/null && pass "3. the window carries c-003@tg" || fail "3. window: $(tmux -S "$SOCK" list-windows -F '#{window_name}')"
out="$(run ROLE_ID=CLE-003 DRY_RUN=0)"; [ "$?" -eq 0 ] && grep -q 'already renamed to c-003' <<<"$out" && pass "3. a re-run is a no-op" || fail "3. re-run: $out"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
