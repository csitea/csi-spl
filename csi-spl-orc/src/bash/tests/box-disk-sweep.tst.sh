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
#      age passed on, the workdirs step as csi-spl-utl's ./run -a
#      do_sweep_workdirs with the measured free % (its own test:
#      workdir-sweep.tst.sh), a failing step does not stop the next (rc 1), an
#      unknown step is refused, a held lock skips
#   3b. the free-space trigger, on a planted free %: 50 runs the normal
#      limits (72h / 1440 min), 10 the low ones (12h / 360), 3 the crit ones
#      (2h / 60) and, still under 7% after, ONE note to the orchestrator
#      (CONTROLS: 15 and 7, the boundaries, are not low / crit; the dry run
#      only plans the note); the gate skips a normal tick younger than 4 h
#      but never a low one
#   3d. /var/tmp: the /tmp name shapes never touch a lane leftover (RED
#      CONTROL); TMP_STALE_ANY=1 removes a planted idle 1 MB one and reports
#      it, keeps a live lane's, a recent one and a dot entry; the vartmp and
#      logs steps never run at the normal level (CONTROL), run at low (72 h)
#      and crit (24 h)
#   3e. the logs step on a stubbed logrotate: the dry run touches nothing; a
#      planted 2 MB log over 1M is rotated once and the DONE line reports the
#      measured delta; RED CONTROL: under the limit nothing is rotated, 0 B
#   3c. the build cache cap, through the REAL docker step on a stubbed docker
#      (sat buildx: --keep-storage only): a planted 25 GB cache, all under
#      12 h old, on a 100 GB disk at the LOW level is cut to 10 GB (10%);
#      RED CONTROL: the old rule (BOX_SWEEP_BUILDER_CAP_PCT=0, until=12h
#      only) leaves all 25 GB
#   4. do_box_disk_sweep_install_cron: the dry run prints the 15-min gated line
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
# busy_in <dir>: a process works in <dir> until killed (busy_pid); waited for
# by its cwd, not a fixed sleep: on a starved runner (gate 10 run 37793965167,
# c-551) a 0.3 s wait and a 30 s holder both lost the race
busy_in() {
  local want; want="$(cd "$1" && pwd -P)"
  ( cd "$1" && exec sleep 600 ) >/dev/null 2>&1 & busy_pid=$!
  for _ in $(seq 300); do [ "$(readlink "/proc/$busy_pid/cwd")" = "$want" ] && return 0; sleep 0.1; done
}
busy_in "$M/go-build789"
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
busy_in "$W/c-906"
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
F="$T/fake" O="$T/fake-orc" U="$T/fake-utl" L="$T/steps.log"
mkdir -p "$F" "$O" "$U"
for s in spl-session-prune tmp-stale-sweep wt-dead-sweep prune-docker-images journal-sweep runner-sweep; do
  printf '#!/bin/sh\necho "%s DRY_RUN=$DRY_RUN UNTIL=${PRUNE_UNTIL:-}" >>%q\n[ %s != tmp-stale-sweep ]\n' "$s" "$L" "$s" >"$F/$s.sh"
done
printf '#!/bin/sh\necho "go $* DRY_RUN=$DRY_RUN AGE=${GO_CACHE_MAX_AGE_MIN:-}" >>%q\n' "$L" >"$O/run"; chmod +x "$O/run"
printf '#!/bin/sh\necho "workdirs $* DRY_RUN=$DRY_RUN FREE=$WORKDIR_SWEEP_FREE_PCT" >>%q\n' "$L" >"$U/run"; chmod +x "$U/run"
printf '#!/bin/sh\necho "send $*" >>%q\n' "$T/sent" >"$T/send"
bsw() { SNIPPET='do_box_disk_sweep' in_orc BOX_SWEEP_SCRIPTS="$F" BOX_SWEEP_ORC="$O" BOX_SWEEP_UTL="$U" BOX_SWEEP_LOCK="$T/sweep.lock" BOX_SWEEP_MOUNTS="$T" \
  BOX_SWEEP_SEND="$T/send" BOX_SWEEP_FREE_PCT="${FREE:-50}" "$@" 2>&1; }
out="$(bsw DRY_RUN=0)"; rc=$?
want="spl-session-prune DRY_RUN=0 UNTIL=
tmp-stale-sweep DRY_RUN=0 UNTIL=
wt-dead-sweep DRY_RUN=0 UNTIL=
workdirs -a do_sweep_workdirs DRY_RUN=0 FREE=50
go -a do_prune_go_build_cache DRY_RUN=0 AGE=1440
prune-docker-images DRY_RUN=0 UNTIL=72h
journal-sweep DRY_RUN=0 UNTIL=
runner-sweep DRY_RUN=0 UNTIL="
[ "$(cat "$L")" = "$want" ] && pass "3. the steps run in order, DRY_RUN, the docker age and (to the utl workdirs action) the free % passed on" || fail "3. steps: $(cat "$L")"
[ "$rc" = 1 ] && grep -q 'FAIL step tmp rc=1' <<<"$out" && grep -q 'DONE rc=1' <<<"$out" && pass "3. a failing step is reported and the next still runs" || fail "3. rc $rc ($out)"
out="$(bsw BOX_SWEEP_STEPS='tmp rm-rf')"; rc=$?
[ "$rc" = 2 ] && grep -q "unknown step 'rm-rf'" <<<"$out" && pass "3. an unknown step is refused" || fail "3. unknown step (rc $rc: $out)"
: >"$L"
# the holder IS the sleep (flock on its own fd 9), so the kill below frees it
( exec 9>"$T/sweep.lock"; flock 9 && exec sleep 600 ) >/dev/null 2>&1 & lock_pid=$!
for _ in $(seq 300); do flock -n "$T/sweep.lock" true || break; sleep 0.1; done
out="$(bsw)"; rc=$?
kill "$lock_pid" 2>/dev/null; wait "$lock_pid" 2>/dev/null
[ "$rc" = 0 ] && grep -q 'SKIP another box disk sweep' <<<"$out" && [ ! -s "$L" ] && pass "3. a held lock skips the sweep" || fail "3. lock (rc $rc: $out)"

# ---- 3b. the free-space trigger ------------------------------------------------
lim() { grep -oE '^(go .* AGE=[0-9]*|prune-docker-images .* UNTIL=[0-9]+h)$' "$L" | sed -E 's/.*(AGE|UNTIL)=/\1=/' | tr '\n' ' '; }
for c in "50 normal AGE=1440 UNTIL=72h" "15 normal AGE=1440 UNTIL=72h" "10 low AGE=360 UNTIL=12h" "7 low AGE=360 UNTIL=12h" "3 crit AGE=60 UNTIL=2h"; do
  read -r f lv a u <<<"$c"; : >"$L"; : >"$T/sent"
  out="$(FREE=$f bsw DRY_RUN=0)"
  [ "$(lim)" = "$a $u " ] && grep -q "START .* level=$lv free=$f% (planted) docker_until=${u#UNTIL=} builder_cap_pct=10 " <<<"$out" \
    && pass "3b. free $f% -> level $lv, go $a, docker $u" || fail "3b. free $f% ($(lim) / $out)"
done
grep -q "FAIL level=crit: still 3% free" <<<"$out" && [ "$(grep -c . "$T/sent")" = 1 ] \
  && grep -q -- '--to orchestrator --kind note --task disk-sweep-.* CRITICAL planted is still at 3% free after a crit sweep' "$T/sent" \
  && pass "3b. a crit sweep that leaves the disk under 7% sends ONE note to the orchestrator" || fail "3b. crit note ($out / $(cat "$T/sent"))"
: >"$T/sent"; FREE=3 bsw DRY_RUN=0 >/dev/null
[ ! -s "$T/sent" ] && pass "3b. ...once: the next crit tick sends nothing new" || fail "3b. crit repeat ($(cat "$T/sent"))"
FREE=20 bsw DRY_RUN=0 >/dev/null; : >"$T/sent"; FREE=3 bsw DRY_RUN=0 >/dev/null
[ "$(grep -c . "$T/sent")" = 1 ] && pass "3b. ...and again after the disk went back over 7%" || fail "3b. crit re-cross ($(cat "$T/sent"))"
: >"$T/sent"; out="$(FREE=10 bsw DRY_RUN=0)"
[ ! -s "$T/sent" ] && pass "3b. CONTROL: a low (not crit) sweep sends no note" || fail "3b. low note ($(cat "$T/sent"))"
rm -f "$T/sweep.lock.crit-noted"; : >"$T/sent"; out="$(FREE=3 bsw)"
[ ! -s "$T/sent" ] && grep -q 'PLAN note to orchestrator: CRITICAL' <<<"$out" && pass "3b. the dry run only plans the note" || fail "3b. dry note ($out)"
rm -f "$T/sweep.lock.last-normal"; FREE=50 bsw DRY_RUN=0 BOX_SWEEP_GATE=1 >/dev/null; : >"$L"
out="$(FREE=50 bsw DRY_RUN=0 BOX_SWEEP_GATE=1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP level=normal free=50%' <<<"$out" && [ ! -s "$L" ] \
  && pass "3b. the gate skips a normal tick when the last normal sweep is under 4 h old" || fail "3b. gate (rc $rc: $out)"
out="$(FREE=10 bsw DRY_RUN=0 BOX_SWEEP_GATE=1)"
grep -q 'level=low' <<<"$out" && [ -s "$L" ] && pass "3b. ...but never a low-space tick" || fail "3b. gate low ($out)"
touch -d '5 hours ago' "$T/sweep.lock.last-normal"; : >"$L"
out="$(FREE=50 bsw DRY_RUN=0 BOX_SWEEP_GATE=1)"
grep -q 'level=normal' <<<"$out" && [ -s "$L" ] && pass "3b. CONTROL: a 5 h old normal sweep lets the gate run" || fail "3b. gate old ($out)"

out="$(bsw BOX_SWEEP_FREE_PCT=)"
grep -qE "START .* level=[a-z]+ free=[0-9]+% \($T\)" <<<"$out" && pass "3b. CONTROL: unplanted, the real df measures the mount" || fail "3b. real df ($out)"

# ---- 3c. the build cache cap on a planted young cache ----------------------------
# the REAL docker step on a stubbed docker with sat's buildx (--keep-storage
# only): the cache lives in $D/cache as bytes, the until= prune finds nothing
# old, --keep-storage <n> cuts it to n; the disk is 100 GB
D="$T/dock"; mkdir -p "$D/bin" "$D/droot"
cat >"$D/bin/docker" <<EOF
#!/bin/bash
D='$D'; echo "docker \$*" >>"\$D/calls"
case "\$1 \$2" in
  "info --format") echo "\$D/droot" ;;
  "image prune") printf 'Total reclaimed space: 0B\n' ;;
  "system df") echo "Build Cache|\$(cat "\$D/cache")B" ;;
  "builder prune")
    [ "\$3" = --help ] && { echo '  --keep-storage bytes'; exit 0; }
    c="\$(cat "\$D/cache")"
    if [ "\$3 \$4" = "-f --keep-storage" ] && [ "\$c" -gt "\$5" ]; then
      echo "\$5" >"\$D/cache"; printf 'Total:\t%sB\n' "\$(( c - \$5 ))"
    else printf 'Total:\t0B\n'; fi ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$D/bin/ps"
printf '#!/bin/sh\nprintf "Filesystem 1-blocks Used Available Capacity Mounted\\n/dev/x 100000000000 90000000000 10000000000 90%%%% /fake\\n"\n' >"$D/bin/df"
# The sweep puts /usr/bin etc. FIRST on PATH, which shadowed these stubs once
# and pruned the main box's real daemon (c-961, 2026-10-11T00:59Z). So the docker step
# is a wrapper that (1) puts the stubs first again and (2) GUARDS: it refuses,
# exit 97, before the real step runs unless `docker` resolves to the stub;
# and (3) DOCKER_HOST points at no daemon, so a real docker that slips past
# both fails instead of pruning. wrap <prepend 0|1> <guard 0|1> <file>
wrap() {
  { echo '#!/bin/bash'
    [ "$1" = 1 ] && printf 'PATH=%q:$PATH\n' "$D/bin"
    [ "$2" = 1 ] && printf '[ "$(command -v docker)" = %q ] || { echo "GUARD docker is $(command -v docker), not the stub: refused"; exit 97; }\n' "$D/bin/docker"
    printf 'exec bash %q\n' "$PROJ_ROOT/src/bash/scripts/prune-docker-images.sh"
  } >"$3"; chmod +x "$3"
}
mkdir -p "$D/w" "$D/w-noguard"
wrap 1 1 "$D/prune-docker-images.sh"; wrap 0 1 "$D/w/prune-docker-images.sh"; wrap 0 0 "$D/w-noguard/prune-docker-images.sh"
chmod +x "$D/bin/docker" "$D/bin/ps" "$D/bin/df"
csw() {
  echo 25000000000 >"$D/cache"; : >"$D/calls"
  env DOCKER_HOST="unix://$D/no-daemon.sock" BOX_SWEEP_SCRIPTS="${CW:-$D}" PRUNE_LOCK="$D/plock" PRUNE_NOTE=0 PRUNE_BOX=testbox DRY_RUN=0 BOX_SWEEP_STEPS=docker \
    BOX_SWEEP_LOCK="$D/sweep.lock" BOX_SWEEP_MOUNTS="$D" BOX_SWEEP_FREE_PCT=10 BOX_SWEEP_NOTE=0 "$@" \
    bash "$PROJ_ROOT/src/bash/scripts/box-disk-sweep.sh" 2>&1
}
out="$(csw)"; rc=$?
[ "$rc" = 0 ] && ! grep -q GUARD <<<"$out" && grep -q 'START .* level=low .* docker_until=12h builder_cap_pct=10 ' <<<"$out" \
  && grep -q '^docker builder prune -f --filter until=12h$' "$D/calls" \
  && grep -q 'PRUNE builder rc=0 reclaimed_bytes=0$' <<<"$out" \
  && grep -q 'PRUNE builder-cap --keep-storage 10000000000 rc=0 reclaimed_bytes=15000000000 cache_bytes_before=25000000000 cache_bytes_after=10000000000$' <<<"$out" \
  && [ "$(cat "$D/cache")" = 10000000000 ] \
  && pass "3c. LOW level: a planted 25 GB young cache (until=12h frees 0 B) is cut to the 10 GB cap" || fail "3c. cap (rc $rc: $out / $(cat "$D/calls"))"
out="$(csw BOX_SWEEP_BUILDER_CAP_PCT=0)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$D/cache")" = 25000000000 ] && ! grep -q -- '--keep-storage [0-9]' "$D/calls" \
  && pass "3c. RED CONTROL: the old rule (no cap, until=12h only) leaves all 25 GB" || fail "3c. control (rc $rc: $out)"
out="$(CW="$D/w" csw)"; rc=$?
[ "$rc" = 1 ] && grep -q 'GUARD docker is .*, not the stub: refused' <<<"$out" && grep -q 'FAIL step docker rc=97' <<<"$out" \
  && ! grep -qE 'CHECK|PRUNE' <<<"$out" && [ ! -s "$D/calls" ] \
  && pass "3c. RED CONTROL: stubs shadowed by the sweep's PATH -> the guard refuses before the step runs" || fail "3c. guard (rc $rc: $out)"
out="$(CW="$D/w-noguard" csw)"; rc=$?
grep -q 'FAIL user .* cannot reach the docker daemon' <<<"$out" && ! grep -q 'PRUNE' <<<"$out" && [ ! -s "$D/calls" ] \
  && pass "3c. RED CONTROL: shadowed with no guard, the real docker reaches no daemon and prunes nothing" || fail "3c. no guard (rc $rc: $out)"

# ---- 3d. /var/tmp lane leftovers, under pressure only --------------------------
V="$T/vartmp"; mkdir -p "$V/c777-copy" "$V/c-778-base" "$V/c779-recent" "$V/.pnpm-store" "$V/notes"
head -c 1048576 /dev/zero >"$V/c777-copy/f"; for d in c-778-base c779-recent .pnpm-store notes; do echo x >"$V/$d/f"; done
old "$V"; touch "$V/c779-recent/f"
vsw() { TMP_STALE_ROOT="$V" TMP_STALE_SUDO=0 TMP_STALE_AGE_H=24 TMP_STALE_LIVE_IDS="c-778@sat c-001" bash "$PROJ_ROOT/src/bash/scripts/tmp-stale-sweep.sh" 2>&1; }
out="$(DRY_RUN=0 vsw)"
[ -d "$V/c777-copy" ] && ! grep -q 'REMOVE' <<<"$out" && pass "3d. RED CONTROL: the /tmp name shapes alone never touch a lane leftover" || fail "3d. shapes ($out)"
out="$(DRY_RUN=0 TMP_STALE_ANY=1 vsw)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$V/c777-copy" ] && [ ! -e "$V/notes" ] && grep -qE "REMOVE 10[0-9]{2}KB owner=.* $V/c777-copy\$" <<<"$out" \
  && grep -q 'DONE removed=2 (1 MB)' <<<"$out" && pass "3d. TMP_STALE_ANY=1 removes the idle leftovers and reports the 1 MB it freed" || fail "3d. any (rc $rc: $out)"
grep -q "KEEP live-lane $V/c-778-base\$" <<<"$out" && [ -f "$V/c-778-base/f" ] && pass "3d. a live lane's leftover is kept" || fail "3d. live-lane ($out)"
grep -q "KEEP recent $V/c779-recent\$" <<<"$out" && [ -f "$V/.pnpm-store/f" ] && ! grep -q pnpm <<<"$out" \
  && pass "3d. a recent one and a dot entry are kept" || fail "3d. recent/dot ($out)"
: >"$L"; out="$(FREE=50 bsw DRY_RUN=0 BOX_SWEEP_STEPS='vartmp logs')"
grep -q 'SKIP step vartmp: level normal' <<<"$out" && grep -q 'SKIP step logs: level normal' <<<"$out" && [ ! -s "$L" ] \
  && pass "3d. CONTROL: at the normal level vartmp and logs never run (free space drives them)" || fail "3d. normal ($out / $(cat "$L"))"
printf '#!/bin/sh\necho "log-sweep DRY_RUN=$DRY_RUN MAX=$LOG_SWEEP_MAX" >>%q\n' "$L" >"$F/log-sweep.sh"
printf '#!/bin/sh\necho "tmp-stale-sweep DRY_RUN=$DRY_RUN ROOT=$TMP_STALE_ROOT ANY=${TMP_STALE_ANY:-} AGE=$TMP_STALE_AGE_H" >>%q\n' "$L" >"$F/tmp-stale-sweep.sh"
for c in "10 72" "3 24"; do
  read -r f a <<<"$c"; : >"$L"
  FREE=$f bsw DRY_RUN=0 BOX_SWEEP_STEPS='vartmp logs' BOX_SWEEP_VARTMP_ROOT=/x/vt >/dev/null
  [ "$(cat "$L")" = "tmp-stale-sweep DRY_RUN=0 ROOT=/x/vt ANY=1 AGE=$a
log-sweep DRY_RUN=0 MAX=256M" ] && pass "3d. free $f%: vartmp (idle $a h) and logs run" || fail "3d. free $f% ($(cat "$L"))"
done

# ---- 3e. the logs step: a planted oversize log, the real delta ---------------
G2="$T/logs"; mkdir -p "$G2/apt"
printf '%s/big.log\n%s/small.log\n{\n\trotate 4\n}\n' "$G2" "$G2" >"$G2/conf"
# a logrotate stub: each named log -> <log>.1.gz, the live one emptied
printf '#!/bin/sh\necho "logrotate $*" >>%q\nfor f in %q %q; do gzip -c "$f" >"$f.1.gz"; : >"$f"; done\n' "$G2/calls" "$G2/big.log" "$G2/small.log" >"$G2/lr"
chmod +x "$G2/lr"
lsw() { env LOG_SWEEP_CONF="$G2/conf" LOG_SWEEP_LOGROTATE="$G2/lr" LOG_SWEEP_APT=true LOG_SWEEP_APT_DIR="$G2/apt" LOG_SWEEP_MAX=1M "$@" bash "$PROJ_ROOT/src/bash/scripts/log-sweep.sh" 2>&1; }
head -c 2097152 /dev/zero >"$G2/big.log"; echo x >"$G2/small.log"; : >"$G2/calls"
out="$(lsw DRY_RUN=1)"
[ ! -s "$G2/calls" ] && [ "$(stat -c %s "$G2/big.log")" = 2097152 ] && grep -q "PLAN logrotate -f $G2/conf ($G2/big.log is 2097152 bytes > 1M)" <<<"$out" \
  && pass "3e. the dry run plans the forced rotation and touches nothing" || fail "3e. dry ($out)"
out="$(lsw DRY_RUN=0)"; rc=$?
after="$(du -scb "$G2"/big.log* "$G2"/small.log* | tail -1 | cut -f1)"
[ "$rc" = 0 ] && [ "$(grep -c . "$G2/calls")" = 1 ] && grep -q "logrotate -f $G2/conf" "$G2/calls" && [ ! -s "$G2/big.log" ] \
  && grep -q "DONE log sweep rc=0 log_bytes=2097154->$after apt_bytes=0->0 freed_bytes=$((2097154 - after))\$" <<<"$out" \
  && pass "3e. a planted 2 MB log over 1M is rotated once and the DONE line reports the real delta ($((2097154 - after)) B)" || fail "3e. live (rc $rc: $out / $(cat "$G2/calls"))"
rm -f "$G2"/*.gz; echo x >"$G2/big.log"; : >"$G2/calls"
out="$(lsw DRY_RUN=0)"
[ ! -s "$G2/calls" ] && grep -q 'freed_bytes=0$' <<<"$out" && pass "3e. RED CONTROL: logs under the limit are not rotated, 0 B freed" || fail "3e. control ($out)"

# ---- 4. the cron line --------------------------------------------------------
CT="$T/crontab"
printf '%s\n' '*/5 * * * * bash /x/a.sh # csi-spl:desk-reconcile-prd' '* * * * * bash /x/b.sh # csi-spl:box-disk-sweep-other' '@reboot /usr/bin/true' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_box_disk_sweep_install_cron' in_orc BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" BOX_SWEEP_ALLOW_WORKTREE=1 "$@" 2>&1; }
out="$(inst)"
grep -q '^  +11-59/15 \* \* \* \* DRY_RUN=0 BOX_SWEEP_GATE=1 BOX_SWEEP_LOCK='"$T"'/log/box-disk-sweep.lock bash .*/box-disk-sweep.sh >> '"$T"'/log/box-disk-sweep.log 2>&1 # csi-spl:box-disk-sweep$' <<<"$out" \
  && pass "4. the dry run prints the 15-min gated line" || fail "4. dry-run diff ($out)"
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
