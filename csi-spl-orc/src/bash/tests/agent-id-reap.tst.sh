#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_id_reap and do_spl_agent_id_reap_install_cron
# (specs/061 section 3.6) on a throwaway root and a fixture crontab.
#   1. do_spl_agent_id_reap: DRY_RUN (the default) is the dry run; with no
#      tmux to ask it decides nothing (exit 1)
#   2. the install: the dry run prints the diff and changes nothing; DRY_RUN=0
#      adds ONE tagged line, DRY_RUN=1 inside it, every other line kept; a
#      second install is a no-op; remove restores the crontab byte for byte
# The reaper's own cases are features/spawn-agents/tests/test-agent-id-reap.sh.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"; mkdir -p "$R/c-004/inbox"
out="$(SNIPPET='do_spl_agent_id_reap' in_orc SPOOL_ROOT="$R" SPOOL_TEST=1 SPOOL_TMUX_SOCKET="$T/none.sock" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'could not be asked: nothing decided' <<<"$out" && pass "1. a blind view decides nothing" || fail "1. blind view (rc $rc: $out)"
[ -d "$R/c-004/inbox" ] && pass "1. ...and moves nothing" || fail "1. the reap moved c-004"
out="$(SNIPPET='do_spl_agent_id_reap' in_orc SPOOL_ROOT="$R" DRY_RUN=2 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. DRY_RUN is checked" || fail "1. DRY_RUN=2 ($out)"

CT="$T/crontab"
printf '%s\n' '*/5 * * * * bash /x/a.sh # csi-spl:desk-reconcile-prd' '* * * * * bash /x/b.sh # csi-spl:agent-id-reap-other' '@reboot /usr/bin/true' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_spl_agent_id_reap_install_cron' in_orc SPOOL_ROOT="$R" REAP_CRONTAB="$T/fake-crontab" REAP_ALLOW_WORKTREE=1 "$@" 2>&1; }
out="$(inst)"
grep -q '^  +\*/15 \* \* \* \* DRY_RUN=1 bash .*agent-id-reap.sh >> '"$R"'/.reap/reap.log 2>&1 # csi-spl:agent-id-reap$' <<<"$out" \
  && pass "2. the dry run prints the line, DRY_RUN=1 inside" || fail "2. dry-run diff ($out)"
cmp -s "$CT" "$T/crontab.orig" && pass "2. ...and changes nothing" || fail "2. the dry run wrote the crontab"
inst DRY_RUN=0 >/dev/null
[ "$(grep -c ' # csi-spl:agent-id-reap$' "$CT")" = 1 ] && pass "2. DRY_RUN=0 adds one tagged line" || fail "2. tagged lines: $(cat "$CT")"
cmp -s <(grep -v ' # csi-spl:agent-id-reap$' "$CT") "$T/crontab.orig" && pass "2. ...every other line kept (the -other tag too)" || fail "2. other lines changed"
grep -q 'DRY_RUN=1 bash' "$CT" && pass "2. ...the line reports only (DRY_RUN=1)" || fail "2. the line is live"
out="$(inst DRY_RUN=0)"
grep -q 'OK cron: nothing to change' <<<"$out" && pass "2. a second install is a no-op" || fail "2. second install ($out)"
inst DRY_RUN=0 REAP_CRON_ACTION=remove >/dev/null
cmp -s "$CT" "$T/crontab.orig" && pass "2. remove restores the crontab byte for byte" || fail "2. remove ($(cat "$CT"))"

echo "agent-id-reap: ${fails} failure(s)"
[ "$fails" -eq 0 ]
