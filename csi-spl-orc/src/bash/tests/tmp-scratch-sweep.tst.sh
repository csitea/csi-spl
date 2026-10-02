#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tmp_scratch_sweep and do_tmp_scratch_sweep_install_cron on a
# fixture scratch tree in a mktemp dir and a fixture crontab.
#   1. the sweep: a sessions dir it cannot read decides nothing (exit 2);
#      the dry run plans the old dead dir and removes nothing; DRY_RUN=0
#      removes ONLY the old dead session dir (and its emptied project dir),
#      never a live one (registry pid, or the uuid on a running command
#      line), a recently written one, a non-session dir, or a symlink target
#   2. the install: the dry run prints the diff and changes nothing; DRY_RUN=0
#      adds ONE tagged line, DRY_RUN=0 inside it, every other line kept; a
#      second install is a no-op; remove restores the crontab byte for byte
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/scratch" S="$T/sessions" OUT="$T/outside"
u_dead=11111111-1111-4111-8111-111111111111 u_live=22222222-2222-4222-8222-222222222222
u_resumed=33333333-3333-4333-8333-333333333333 u_recent=44444444-4444-4444-8444-444444444444
u_link=55555555-5555-4555-8555-555555555555 u_keep=66666666-6666-4666-8666-666666666666
mkdir -p "$S" "$OUT/precious" "$R/gocache/aa" "$R/-opt-a/$u_dead/scratchpad" "$R/-opt-b/$u_live/scratchpad" \
  "$R/-opt-b/$u_resumed/tasks" "$R/-opt-c/$u_recent/scratchpad" "$R/-opt-d" "$R/-opt-e/$u_keep"
echo x >"$R/-opt-a/$u_dead/scratchpad/big"; echo x >"$OUT/precious/file"; echo x >"$R/gocache/aa/obj"
echo x >"$R/-opt-b/$u_live/scratchpad/f"; echo x >"$R/-opt-b/$u_resumed/tasks/f"; echo x >"$R/-opt-c/$u_recent/scratchpad/f"
ln -s "$OUT/precious" "$R/-opt-d/$u_link"
find "$R" "$OUT" -exec touch -h -d '3 days ago' {} +
touch "$R/-opt-c/$u_recent/scratchpad/f"
printf '{"pid":%s,"sessionId":"%s"}\n' "$$" "$u_live" >"$S/$$.json"
printf '{"pid":%s,"sessionId":"%s"}\n' 999999999 "$u_keep" >"$S/999999999.json"
printf 'not json' >"$S/bad.json"
# A resumed session: its uuid on a running process's command line only (the
# trailing ':' stops bash from exec'ing sleep, which would drop the uuid).
bash -c 'sleep 30; :' "$u_resumed" & resumed_pid=$!
# u_keep's registry pid is dead, but the dir is kept by a later test below.
touch "$R/-opt-e/$u_keep"

sweep() { SNIPPET='do_tmp_scratch_sweep' in_orc SCRATCH_ROOT="$R" SCRATCH_SESSIONS="$S" "$@" 2>&1; }

out="$(sweep SCRATCH_SESSIONS="$T/nope" DRY_RUN=0)"; rc=$?
[ "$rc" = 2 ] && grep -q 'REFUSE cannot read the live sessions' <<<"$out" && [ -d "$R/-opt-a/$u_dead" ] \
  && pass "1. an unreadable sessions dir decides nothing" || fail "1. unreadable sessions (rc $rc: $out)"
out="$(sweep DRY_RUN=2)"; rc=$?
[ "$rc" = 2 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. DRY_RUN is checked" || fail "1. DRY_RUN=2 ($out)"

out="$(sweep)"; rc=$?
[ "$rc" = 0 ] && grep -q "PLAN remove [0-9]*KB $R/-opt-a/$u_dead\$" <<<"$out" && [ -d "$R/-opt-a/$u_dead" ] \
  && pass "1. the dry run (default) plans the dead dir and removes nothing" || fail "1. dry run (rc $rc: $out)"
[ "$(grep -c 'PLAN remove' <<<"$out")" = 1 ] && pass "1. ...and plans exactly one" || fail "1. planned: $(grep PLAN <<<"$out")"

out="$(sweep DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$R/-opt-a" ] && grep -q "REMOVE [0-9]*KB $R/-opt-a/$u_dead\$" <<<"$out" \
  && pass "1. DRY_RUN=0 removes the old dead dir and its emptied project dir" || fail "1. live run (rc $rc: $out)"
grep -q "KEEP live $R/-opt-b/$u_live\$" <<<"$out" && [ -f "$R/-opt-b/$u_live/scratchpad/f" ] \
  && pass "1. a registry-live session is kept" || fail "1. live session ($out)"
grep -q "KEEP live $R/-opt-b/$u_resumed\$" <<<"$out" && [ -f "$R/-opt-b/$u_resumed/tasks/f" ] \
  && pass "1. a session named on a running command line is kept" || fail "1. resumed session ($out)"
grep -q "KEEP recent $R/-opt-c/$u_recent\$" <<<"$out" && [ -f "$R/-opt-c/$u_recent/scratchpad/f" ] \
  && pass "1. a dead dir written inside the age window is kept" || fail "1. recent dir ($out)"
grep -q "KEEP recent $R/-opt-e/$u_keep\$" <<<"$out" && pass "1. a dead registry pid alone does not remove a recent dir" || fail "1. dead-pid recent ($out)"
[ -f "$R/gocache/aa/obj" ] && [ -f "$OUT/precious/file" ] && [ -L "$R/-opt-d/$u_link" ] \
  && pass "1. non-session dirs, the symlink and its target are untouched" || fail "1. touched something outside the session dirs"
kill "$resumed_pid" 2>/dev/null; wait "$resumed_pid" 2>/dev/null

CT="$T/crontab"
printf '%s\n' '*/5 * * * * bash /x/a.sh # csi-spl:desk-reconcile-prd' '* * * * * bash /x/b.sh # csi-spl:tmp-scratch-sweep-other' '@reboot /usr/bin/true' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_tmp_scratch_sweep_install_cron' in_orc SCRATCH_CRONTAB="$T/fake-crontab" SCRATCH_CRON_LOG_DIR="$T/log" SCRATCH_ALLOW_WORKTREE=1 "$@" 2>&1; }
out="$(inst)"
grep -q '^  +17 \* \* \* \* DRY_RUN=0 bash .*tmp-scratch-sweep.sh >> '"$T"'/log/tmp-scratch-sweep.log 2>&1 # csi-spl:tmp-scratch-sweep$' <<<"$out" \
  && pass "2. the dry run prints the line" || fail "2. dry-run diff ($out)"
cmp -s "$CT" "$T/crontab.orig" && pass "2. ...and changes nothing" || fail "2. the dry run wrote the crontab"
inst DRY_RUN=0 >/dev/null
[ "$(grep -c ' # csi-spl:tmp-scratch-sweep$' "$CT")" = 1 ] && [ -d "$T/log" ] && pass "2. DRY_RUN=0 adds one tagged line and the log dir" || fail "2. tagged lines: $(cat "$CT")"
cmp -s <(grep -v ' # csi-spl:tmp-scratch-sweep$' "$CT") "$T/crontab.orig" && pass "2. ...every other line kept (the -other tag too)" || fail "2. other lines changed"
out="$(inst DRY_RUN=0)"
grep -q 'OK cron: nothing to change' <<<"$out" && pass "2. a second install is a no-op" || fail "2. second install ($out)"
inst DRY_RUN=0 SCRATCH_CRON_ACTION=remove >/dev/null
cmp -s "$CT" "$T/crontab.orig" && pass "2. remove restores the crontab byte for byte" || fail "2. remove ($(cat "$CT"))"

echo "tmp-scratch-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]
