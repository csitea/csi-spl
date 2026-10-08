#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box disk sweep's steps and its cron line, on fixtures in a
# mktemp dir (the session step has its own test, spl-session-prune.tst.sh).
#   1. do_tmp_stale_sweep: the dry run removes nothing; DRY_RUN=0 removes ONLY
#      the idle go-build / tmp.X (read-only Go module cache inside too) /
#      Test* / *-gocache entries, never a recent
#      one, one a process works in, a symlink (or its target) or a name of
#      another shape
#   2. do_wt_dead_sweep: DRY_RUN=0 removes ONLY the dead, clean, landed, idle
#      worktree (and its merged branch); keeps a role seat, an alive record, a
#      dirty one, one off the trunk, a recent one and one a process works in
#   3. do_box_disk_sweep: runs the steps in order with DRY_RUN and the docker
#      age passed on, a failing step does not stop the next (rc 1), an
#      unknown step is refused, a held lock skips
#   4. do_box_disk_sweep_install_cron: the dry run prints the 4-hourly line
#      and changes nothing; DRY_RUN=0 adds ONE tagged line, every other kept;
#      a second install is a no-op; remove restores the crontab byte for byte
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
old() { find "$@" -exec touch -h -d '3 days ago' {} +; }

# ---- 1. /tmp leftovers -------------------------------------------------------
M="$T/tmp" OUT="$T/outside"
mkdir -p "$OUT/precious" "$M/go-build123/b001" "$M/tmp.AbCdEf1234" "$M/TestFoo123/001" "$M/c999-gocache/aa" \
  "$M/go-build456" "$M/go-build789" "$M/tmp.short" "$M/claude-1234/x" "$M/other"
for d in go-build123/b001 tmp.AbCdEf1234 TestFoo123/001 c999-gocache/aa go-build456 go-build789 tmp.short claude-1234/x other; do echo x >"$M/$d/f"; done
echo x >"$OUT/precious/f"; ln -s "$OUT/precious" "$M/go-build321"
mkdir -p "$M/tmp.AbCdEf1234/go/pkg/mod/m@v1"; echo x >"$M/tmp.AbCdEf1234/go/pkg/mod/m@v1/f"; chmod -R a-w "$M/tmp.AbCdEf1234/go"
old "$M" "$OUT"; touch "$M/go-build456/f"
( cd "$M/go-build789" && exec sleep 30 ) & busy_pid=$!
sleep 0.3
tsw() { SNIPPET='do_tmp_stale_sweep' in_orc TMP_STALE_ROOT="$M" TMP_STALE_SUDO=0 "$@" 2>&1; }
n0="$(find "$M" "$OUT" | wc -l)"
out="$(tsw)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'PLAN remove' <<<"$out")" = 4 ] && [ "$(find "$M" "$OUT" | wc -l)" = "$n0" ] \
  && pass "1. the dry run (default) plans the four idle leftovers and removes nothing" || fail "1. dry run (rc $rc: $out)"
out="$(tsw DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && for d in go-build123 tmp.AbCdEf1234 TestFoo123 c999-gocache; do [ ! -e "$M/$d" ] || rc=9; done
[ "$rc" = 0 ] && pass "1. DRY_RUN=0 removes go-build / tmp.X (a read-only Go module cache too) / Test* / *-gocache when idle" || fail "1. live run (rc $rc: $out)"
grep -q "KEEP recent $M/go-build456\$" <<<"$out" && pass "1. a recent leftover is kept" || fail "1. recent ($out)"
grep -q "KEEP in-use $M/go-build789\$" <<<"$out" && [ -f "$M/go-build789/f" ] && pass "1. a dir a process works in is kept" || fail "1. in-use ($out)"
grep -q "KEEP symlink $M/go-build321\$" <<<"$out" && [ -f "$OUT/precious/f" ] && pass "1. a symlink and its target are kept" || fail "1. symlink ($out)"
[ -f "$M/tmp.short/f" ] && [ -f "$M/claude-1234/x/f" ] && [ -f "$M/other/f" ] && pass "1. names of another shape are untouched" || fail "1. touched another shape"
kill "$busy_pid" 2>/dev/null; wait "$busy_pid" 2>/dev/null

# ---- 2. dead worktrees -------------------------------------------------------
G="$T/repo" W="$T/repo-wt" SP="$T/spool"
gq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
mkdir -p "$G" "$SP/agents"; gq -C "$G" init; echo a >"$G/a"; gq -C "$G" add a; gq -C "$G" commit -m a
for id in c-901 c-902 c-903 c-904 c-001 c-905 c-906; do gq -C "$G" worktree add -b "$id-x" "$W/$id"; done
echo dirt >"$W/c-902/untracked"
echo b >"$W/c-903/b"; gq -C "$W/c-903" add b; gq -C "$W/c-903" commit -m b
printf '{"id":"c-904","alive":true}\n' >"$SP/agents/c-904.json"
printf '{"id":"c-901","alive":false}\n' >"$SP/agents/c-901.json"
old "$W"; touch "$W/c-905/a"
( cd "$W/c-906" && exec sleep 30 ) & busy_pid=$!
sleep 0.3
wsw() { SNIPPET='do_wt_dead_sweep' in_orc WT_REPO="$G" WT_TRUNK=master SPOOL_ROOT="$SP" "$@" 2>&1; }
out="$(wsw)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'PLAN remove' <<<"$out")" = 1 ] && [ -d "$W/c-901" ] && pass "2. the dry run plans one worktree and removes nothing" || fail "2. dry run (rc $rc: $out)"
out="$(wsw DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$W/c-901" ] && ! git -C "$G" rev-parse -q --verify c-901-x >/dev/null \
  && pass "2. DRY_RUN=0 removes the dead landed worktree and its branch" || fail "2. live run (rc $rc: $out)"
for k in "role-seat c-001" "alive c-904" "dirty c-902" "not-on-trunk c-903" "recent c-905" "in-use c-906"; do
  grep -q "KEEP ${k% *} $W/${k#* }\$" <<<"$out" && [ -d "$W/${k#* }" ] && pass "2. kept: ${k% *}" || fail "2. ${k% *} ($out)"
done
kill "$busy_pid" 2>/dev/null; wait "$busy_pid" 2>/dev/null

# ---- 3. the sweep runs the steps --------------------------------------------
F="$T/fake" O="$T/fake-orc" L="$T/steps.log"
mkdir -p "$F" "$O"
for s in spl-session-prune tmp-stale-sweep wt-dead-sweep prune-docker-images; do
  printf '#!/bin/sh\necho "%s DRY_RUN=$DRY_RUN UNTIL=${PRUNE_UNTIL:-}" >>%q\n[ %s != tmp-stale-sweep ]\n' "$s" "$L" "$s" >"$F/$s.sh"
done
printf '#!/bin/sh\necho "go $* DRY_RUN=$DRY_RUN" >>%q\n' "$L" >"$O/run"; chmod +x "$O/run"
bsw() { SNIPPET='do_box_disk_sweep' in_orc BOX_SWEEP_SCRIPTS="$F" BOX_SWEEP_ORC="$O" BOX_SWEEP_LOCK="$T/sweep.lock" BOX_SWEEP_MOUNTS="$T" "$@" 2>&1; }
out="$(bsw DRY_RUN=0)"; rc=$?
want="spl-session-prune DRY_RUN=0 UNTIL=
tmp-stale-sweep DRY_RUN=0 UNTIL=
wt-dead-sweep DRY_RUN=0 UNTIL=
go -a do_prune_go_build_cache DRY_RUN=0
prune-docker-images DRY_RUN=0 UNTIL=72h"
[ "$(cat "$L")" = "$want" ] && pass "3. the steps run in order, DRY_RUN and the docker age passed on" || fail "3. steps: $(cat "$L")"
[ "$rc" = 1 ] && grep -q 'FAIL step tmp rc=1' <<<"$out" && grep -q 'DONE rc=1' <<<"$out" && pass "3. a failing step is reported and the next still runs" || fail "3. rc $rc ($out)"
out="$(bsw BOX_SWEEP_STEPS='tmp rm-rf')"; rc=$?
[ "$rc" = 2 ] && grep -q "unknown step 'rm-rf'" <<<"$out" && pass "3. an unknown step is refused" || fail "3. unknown step (rc $rc: $out)"
: >"$L"
flock "$T/sweep.lock" sleep 30 & lock_pid=$!
sleep 0.3
out="$(bsw)"; rc=$?
kill "$lock_pid" 2>/dev/null; wait "$lock_pid" 2>/dev/null
[ "$rc" = 0 ] && grep -q 'SKIP another box disk sweep' <<<"$out" && [ ! -s "$L" ] && pass "3. a held lock skips the sweep" || fail "3. lock (rc $rc: $out)"

# ---- 4. the cron line --------------------------------------------------------
CT="$T/crontab"
printf '%s\n' '*/5 * * * * bash /x/a.sh # csi-spl:desk-reconcile-prd' '* * * * * bash /x/b.sh # csi-spl:box-disk-sweep-other' '@reboot /usr/bin/true' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_box_disk_sweep_install_cron' in_orc BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" BOX_SWEEP_ALLOW_WORKTREE=1 "$@" 2>&1; }
out="$(inst)"
grep -q '^  +41 \*/4 \* \* \* DRY_RUN=0 BOX_SWEEP_LOCK='"$T"'/log/box-disk-sweep.lock bash .*/box-disk-sweep.sh >> '"$T"'/log/box-disk-sweep.log 2>&1 # csi-spl:box-disk-sweep$' <<<"$out" \
  && pass "4. the dry run prints the 4-hourly line" || fail "4. dry-run diff ($out)"
cmp -s "$CT" "$T/crontab.orig" && pass "4. ...and changes nothing" || fail "4. the dry run wrote the crontab"
inst DRY_RUN=0 >/dev/null
[ "$(grep -c ' # csi-spl:box-disk-sweep$' "$CT")" = 1 ] && [ -d "$T/log" ] && pass "4. DRY_RUN=0 adds one tagged line and the log dir" || fail "4. tagged lines: $(cat "$CT")"
cmp -s <(grep -v ' # csi-spl:box-disk-sweep$' "$CT") "$T/crontab.orig" && pass "4. ...every other line kept (the -other tag too)" || fail "4. other lines changed"
out="$(inst DRY_RUN=0)"
grep -q 'OK cron: nothing to change' <<<"$out" && pass "4. a second install is a no-op" || fail "4. second install ($out)"
inst DRY_RUN=0 BOX_SWEEP_CRON_ACTION=remove >/dev/null
cmp -s "$CT" "$T/crontab.orig" && pass "4. remove restores the crontab byte for byte" || fail "4. remove ($(cat "$CT"))"

echo "box-disk-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]
