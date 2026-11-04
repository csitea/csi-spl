#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tmp_scratch_sweep and do_tmp_scratch_sweep_install_cron on a
# fixture scratch tree in a mktemp dir and a fixture crontab.
#   1. the sweep: a sessions dir it cannot read decides nothing (exit 2);
#      the dry run plans the old dead dir and removes nothing; DRY_RUN=0
#      removes ONLY the old dead session dir (and its emptied project dir),
#      never a live one (registry pid, or the uuid on a running command
#      line), a recently written one, a non-session dir, or a symlink target;
#      the default age is 2 h: a dead dir idle 3 h goes, a live one never
#   3. inode pressure (a fake df): below SCRATCH_INODE_MIN_FREE_PCT the sweep
#      removes the dead dirs idle past SCRATCH_PRESSURE_AGE_M, oldest first,
#      and stops once the projected free inodes reach the threshold; a live
#      or freshly written dir is kept; the dry run removes nothing
#   3b. a failed du --inodes stops the pressure pass (WARN, nothing more
#      removed; CONTROL: a working du plans two); a df row with a non-numeric
#      IFree or total is no count, no false pressure
#   2. the install: the dry run prints the diff and changes nothing; DRY_RUN=0
#      adds ONE tagged line, DRY_RUN=0 inside it, every other line kept; a
#      second install is a no-op; remove restores the crontab byte for byte
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/scratch" S="$T/sessions" OUT="$T/outside"
# Fresh uuids per run: the sweep reads a uuid on ANY running command line of
# ours as live, so a fixed one shared with another test (spl-session-prune's
# running process carried this file's u_recent) or a second run of this test
# on the box turns a fixture dir "live" (FAIL "1. recent dir", run 37868560155).
uuid() { cat /proc/sys/kernel/random/uuid; }
u_dead=$(uuid) u_live=$(uuid) u_resumed=$(uuid) u_recent=$(uuid) u_link=$(uuid) u_keep=$(uuid)
u_dead3h=$(uuid) u_live3h=$(uuid)
mkdir -p "$R/-opt-f/$u_dead3h/scratchpad" "$R/-opt-f/$u_live3h/scratchpad"
mkdir -p "$S" "$OUT/precious" "$R/gocache/aa" "$R/-opt-a/$u_dead/scratchpad" "$R/-opt-b/$u_live/scratchpad" \
  "$R/-opt-b/$u_resumed/tasks" "$R/-opt-c/$u_recent/scratchpad" "$R/-opt-d" "$R/-opt-e/$u_keep"
echo x >"$R/-opt-a/$u_dead/scratchpad/big"; echo x >"$OUT/precious/file"; echo x >"$R/gocache/aa/obj"
echo x >"$R/-opt-b/$u_live/scratchpad/f"; echo x >"$R/-opt-b/$u_resumed/tasks/f"; echo x >"$R/-opt-c/$u_recent/scratchpad/f"
ln -s "$OUT/precious" "$R/-opt-d/$u_link"
find "$R" "$OUT" -exec touch -h -d '3 days ago' {} +
touch "$R/-opt-c/$u_recent/scratchpad/f"
echo x >"$R/-opt-f/$u_dead3h/scratchpad/f"; echo x >"$R/-opt-f/$u_live3h/scratchpad/f"
find "$R/-opt-f" -exec touch -h -d '3 hours ago' {} +
printf '{"pid":%s,"sessionId":"%s"}\n' "$$" "$u_live" >"$S/$$.json"
printf '{"pid":%s,"sessionId":"%s"}\n' "$$" "$u_live3h" >"$S/$$-3h.json"
printf '{"pid":%s,"sessionId":"%s"}\n' 999999999 "$u_keep" >"$S/999999999.json"
printf 'not json' >"$S/bad.json"
# A resumed session: its uuid on a running process's command line only (the
# second command stops bash from exec'ing sleep, which would drop the uuid;
# 600 s outlives a loaded CI runner, and TERM at the end kills the sleep too).
bash -c 'sleep 600 & trap "kill $!" TERM; wait' "$u_resumed" & resumed_pid=$!
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
grep -q "PLAN remove [0-9]*KB $R/-opt-f/$u_dead3h\$" <<<"$out" && [ -d "$R/-opt-f/$u_dead3h" ] \
  && pass "1. the default age is 2 h: a dead dir idle 3 h is planned" || fail "1. dead 3 h dir (rc $rc: $out)"
[ "$(grep -c 'PLAN remove' <<<"$out")" = 2 ] && pass "1. ...and plans exactly those two" || fail "1. planned: $(grep PLAN <<<"$out")"

out="$(sweep DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$R/-opt-a" ] && grep -q "REMOVE [0-9]*KB $R/-opt-a/$u_dead\$" <<<"$out" \
  && pass "1. DRY_RUN=0 removes the old dead dir and its emptied project dir" || fail "1. live run (rc $rc: $out)"
grep -q "KEEP live $R/-opt-b/$u_live\$" <<<"$out" && [ -f "$R/-opt-b/$u_live/scratchpad/f" ] \
  && pass "1. a registry-live session is kept" || fail "1. live session ($out)"
grep -q "KEEP live $R/-opt-f/$u_live3h\$" <<<"$out" && [ -f "$R/-opt-f/$u_live3h/scratchpad/f" ] && [ ! -e "$R/-opt-f/$u_dead3h" ] \
  && pass "1. DRY_RUN=0 removes the dead 3 h dir, keeps the live 3 h one" || fail "1. 3 h dirs ($out)"
grep -q "KEEP live $R/-opt-b/$u_resumed\$" <<<"$out" && [ -f "$R/-opt-b/$u_resumed/tasks/f" ] \
  && pass "1. a session named on a running command line is kept" || fail "1. resumed session ($out)"
grep -q "KEEP recent $R/-opt-c/$u_recent\$" <<<"$out" && [ -f "$R/-opt-c/$u_recent/scratchpad/f" ] \
  && pass "1. a dead dir written inside the age window is kept" || fail "1. recent dir ($out)"
grep -q "KEEP recent $R/-opt-e/$u_keep\$" <<<"$out" && pass "1. a dead registry pid alone does not remove a recent dir" || fail "1. dead-pid recent ($out)"
[ -f "$R/gocache/aa/obj" ] && [ -f "$OUT/precious/file" ] && [ -L "$R/-opt-d/$u_link" ] \
  && pass "1. non-session dirs, the symlink and its target are untouched" || fail "1. touched something outside the session dirs"
kill "$resumed_pid" 2>/dev/null; wait "$resumed_pid" 2>/dev/null

# 3. inode pressure on its own root. A fake df reports 1000 inodes, 80 free:
# below 10 % (100). Each dead dir holds 16 inodes (itself, scratchpad, 14
# files): removing the oldest gives 96, the next 112 >= 100, so it stops.
P="$T/pressure"
p_old=$(uuid) p_mid=$(uuid) p_new=$(uuid) p_fresh=$(uuid) p_live=$(uuid)
for u in "$p_old" "$p_mid" "$p_new" "$p_fresh" "$p_live"; do
  mkdir -p "$P/-opt-p/$u/scratchpad"; for i in $(seq 14); do echo x >"$P/-opt-p/$u/scratchpad/f$i"; done
done
age_dir() { find "$P/-opt-p/$1" -exec touch -h -d "$2 minutes ago" {} +; }
age_dir "$p_old" 100; age_dir "$p_mid" 80; age_dir "$p_new" 60; age_dir "$p_fresh" 5; age_dir "$p_live" 110
printf '{"pid":%s,"sessionId":"%s"}\n' "$$" "$p_live" >"$S/$$-p.json"
cat >"$T/fake-df" <<'EOF'
#!/bin/sh
case "$*" in
  *-i*) printf '%s\n' 'Filesystem Inodes IUsed IFree IUse% Mounted' 'tmpfs 1000 920 80 92% /tmp' ;;
  *) printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' 'tmpfs 100 54 46 54% /tmp' ;;
esac
EOF
chmod +x "$T/fake-df"
psweep() { SNIPPET='do_tmp_scratch_sweep' in_orc SCRATCH_ROOT="$P" SCRATCH_SESSIONS="$S" SCRATCH_DF="$T/fake-df" "$@" 2>&1; }
line_of() { grep -m1 -n "$1" <<<"$2" | cut -d: -f1; }

out="$(psweep)"; rc=$?
grep -q "PRESSURE ifree=80 of 1000 want=100" <<<"$out" && [ "$(grep -c 'PLAN remove' <<<"$out")" = 2 ] \
  && [ -d "$P/-opt-p/$p_old" ] && [ -d "$P/-opt-p/$p_mid" ] \
  && pass "3. the dry run plans two under inode pressure and removes nothing" || fail "3. pressure dry run (rc $rc: $out)"
out="$(psweep DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$P/-opt-p/$p_old" ] && [ ! -e "$P/-opt-p/$p_mid" ] && [ -d "$P/-opt-p/$p_new" ] \
  && pass "3. inode pressure removes the two oldest dead dirs and stops at the threshold" || fail "3. pressure live (rc $rc: $out)"
lo="$(line_of "REMOVE [0-9]*KB $P/-opt-p/$p_old (inode pressure)$" "$out")" lm="$(line_of "REMOVE [0-9]*KB $P/-opt-p/$p_mid (inode pressure)$" "$out")"
[ -n "$lo" ] && [ -n "$lm" ] && [ "$lo" -lt "$lm" ] && pass "3. ...oldest first" || fail "3. order ($out)"
grep -q "PRESSURE OK ifree=112" <<<"$out" && pass "3. ...and says the threshold is met" || fail "3. stop line ($out)"
[ -d "$P/-opt-p/$p_fresh" ] && [ -d "$P/-opt-p/$p_live" ] && grep -q "KEEP live $P/-opt-p/$p_live\$" <<<"$out" \
  && pass "3. a fresh dead dir and a live dir are kept under pressure" || fail "3. kept under pressure ($out)"
out="$(psweep DRY_RUN=0 SCRATCH_INODE_MIN_FREE_PCT=0)"
[ -d "$P/-opt-p/$p_new" ] && ! grep -q PRESSURE <<<"$out" && pass "3. SCRATCH_INODE_MIN_FREE_PCT=0 turns the guard off" || fail "3. guard off ($out)"
out="$(psweep SCRATCH_PRESSURE_AGE_M=x)"; rc=$?
[ "$rc" = 2 ] && grep -q 'SCRATCH_PRESSURE_AGE_M must be' <<<"$out" && pass "3. the knobs are checked" || fail "3. bad knob (rc $rc: $out)"

# 3b. a count the pressure pass cannot trust stops it (SPL-4761, review of
# SPL-4538). Fresh dirs: three dead ones idle 60..100 min, under pressure.
Q="$T/pressure-b"
q_old=$(uuid) q_mid=$(uuid) q_new=$(uuid)
for u in "$q_old" "$q_mid" "$q_new"; do
  mkdir -p "$Q/-opt-q/$u/scratchpad"; for i in $(seq 14); do echo x >"$Q/-opt-q/$u/scratchpad/f$i"; done
done
find "$Q/-opt-q/$q_old" -exec touch -h -d '100 minutes ago' {} +; find "$Q/-opt-q/$q_mid" -exec touch -h -d '80 minutes ago' {} +
find "$Q/-opt-q/$q_new" -exec touch -h -d '60 minutes ago' {} +
# A du whose --inodes count fails (no output, exit 1); the size count works.
printf '#!/bin/sh\ncase "$*" in *--inodes*) exit 1 ;; *) exec du "$@" ;; esac\n' >"$T/fake-du"; chmod +x "$T/fake-du"
qsweep() { SNIPPET='do_tmp_scratch_sweep' in_orc SCRATCH_ROOT="$Q" SCRATCH_SESSIONS="$S" SCRATCH_DF="$T/fake-df" "$@" 2>&1; }
out="$(qsweep)"
[ "$(grep -c 'PLAN remove.*(inode pressure)' <<<"$out")" = 2 ] && pass "3b. CONTROL: with a working du, the dirs below plan two" || fail "3b. control ($out)"
out="$(qsweep SCRATCH_DU="$T/fake-du" DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && ! grep -q '(inode pressure)' <<<"$out" && [ -d "$Q/-opt-q/$q_old" ] && [ -d "$Q/-opt-q/$q_mid" ] && [ -d "$Q/-opt-q/$q_new" ] \
  && grep -q "PRESSURE WARN cannot count the inodes of $Q/-opt-q/$q_old: no more removal by pressure" <<<"$out" \
  && pass "3b. a failed du --inodes stops the pressure pass: WARN, nothing removed" || fail "3b. failed du (rc $rc: $out)"
# A df line with a numeric total but a non-numeric IFree (or the reverse) is
# no count: "0 0", the guard is skipped, not a false pressure.
for row in 'tmpfs 1000 920 - 92% /tmp' 'tmpfs - 920 80 92% /tmp'; do
  printf '#!/bin/sh\ncase "$*" in *-i*) printf "%%s\\n" "Filesystem Inodes IUsed IFree IUse%% Mounted" "%s" ;; *) exec "%s" "$@" ;; esac\n' "$row" "$T/fake-df" >"$T/fake-df-bad"
  chmod +x "$T/fake-df-bad"
  out="$(qsweep SCRATCH_DF="$T/fake-df-bad")"; rc=$?
  [ "$rc" = 0 ] && ! grep -q PRESSURE <<<"$out" && ! grep -q 'PLAN remove' <<<"$out" && grep -q 'ifree~0/0$' <<<"$out" \
    && pass "3b. a df row '$row' reads as no count: no pressure" || fail "3b. bad df '$row' (rc $rc: $out)"
done

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
