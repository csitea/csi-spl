#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_box_proc_sample (SPL-5698, spec 175 task 5.9): a fixture
# /proc tree, a fixture tmux pane list and a fixture crontab; the live box,
# its processes and its crontab are never read or changed.
#   1. the first run seeds state only: no box or proc file
#   2. the second run: own_pct and child_pct from the tick deltas, the lane
#      from the pane ancestor, busy_pct from /proc/stat, swap and RSS in MB,
#      a comm with spaces and a paren is one field, the args are the cmdline
#   3. a reused pid (other start time) counts its whole life, and is not in
#      sampled_pct
#   4. BOX_PROC_TOP_CPU / _TOP_MEM bound the proc rows
#   5. DRY_RUN=1 prints the rows and writes nothing
#   6. report: load p95 as % of the CPUs, the top lane by core-seconds and
#      the top by peak RSS + swap
#   7. cron: dry run touches nothing; install adds one tagged line and keeps
#      every other; a second install changes nothing; check OK; a hand-edited
#      line fails check; remove restores the crontab byte for byte
#   8. read-only: the action never kills or renices
#   9. through the csi-spl-utl ./run harness
#  10. a reaped child is counted once (R7 W1): a child at 100 % for 300 s,
#      then reaped, reports 300 core-s, not 600; nested (grandchild reaped by
#      the child, the child by the pane shell) also 300, not 900
#  11. check / install WARN when the user sees no tmux pane (R7 N1); cron.out
#      is cut to BOX_PROC_OUT_LINES (N2); a pid gone before its cmdline is
#      read prints nothing on stderr (N3)
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/box-proc-sample.func.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

HZ=$(getconf CLK_TCK)
PKB=$(($(getconf PAGESIZE) / 1024))
P="$T/proc"
mkdir -p "$P"

# mkproc <pid> <ppid> <start> <utime> <cutime> <rss MB> <uid> <swap kB> <comm> <cmdline...>
mkproc() {
  local pid="$1" ppid="$2" start="$3" ut="$4" cut="$5" rss="$6" uid="$7" sw="$8" comm="$9"
  shift 9
  mkdir -p "$P/$pid"
  printf '%s (%s) S %s 1 1 0 -1 0 0 0 0 0 %s 0 %s 0 20 0 1 0 %s 1000 %s 0 0\n' \
    "$pid" "$comm" "$ppid" "$ut" "$cut" "$start" $((rss * 1024 / PKB)) >"$P/$pid/stat"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\nVmSwap:\t%s kB\n' "$comm" "$uid" "$uid" "$uid" "$uid" "$sw" >"$P/$pid/status"
  printf '%s\0' "$@" >"$P/$pid/cmdline"
}
# box <busy ticks> <idle ticks> <load1> <swap free kB>
box() {
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0 0 0\ncpu1 0 0 0 0 0 0 0 0 0 0\n' "$1" "$2" >"$P/stat"
  printf '%s 1.00 0.50 3/200 999\n' "$3" >"$P/loadavg"
  printf 'MemTotal: 8388608 kB\nMemAvailable: 2097152 kB\nSwapTotal: 4194304 kB\nSwapFree: %s kB\n' "$4" >"$P/meminfo"
}
printf '%s\n' '200 c-123@box some lane title' '900 g-777@box other' >"$T/panes"

run_bp() {
  env PROJ_PATH="$T/fake/csi-spl-utl" BOX_PROC_ROOT="$P" BOX_PROC_DIR="$T/out" \
    BOX_PROC_PANES_CMD="cat $T/panes" SPOOL_TEST=1 SPOOL_DESK_BOX=box "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    source "'"$FUNC_SH"'"
    do_box_proc_sample' 2>&1
}
mkdir -p "$T/fake/csi-spl-utl"

# t0: pid 200 = the pane shell, 250 its child, 300 a grandchild; 400 not under a pane
mkproc 200 1 1000 10 0 20 1000 0 bash bash
mkproc 250 200 1100 0 0 10 1000 0 make make test
mkproc 300 250 1200 100 0 300 1000 2048 'go test (x)' go test ./...
mkproc 400 1 1300 50 0 50 0 0 cron /usr/sbin/cron -f
box 1000 9000 0.50 4194304

# 1. seed ----------------------------------------------------------------------
out="$(run_bp DRY_RUN=0 BOX_PROC_NOW=1700000000)"; rc=$?
[[ $rc == 0 && -s "$T/out/state.tsv" && -z "$(ls "$T/out"/box-*.tsv "$T/out"/proc-*.tsv 2>/dev/null)" ]] &&
  grep -q 'seeded' <<<"$out" && pass "1. the first run seeds state only" || fail "1. seed (rc $rc): $out"

# t1 = t0 + 300 s: 300 burns 150 s of CPU (50 %), 200 reaps children worth 300 s
# (100 %), 400 is a NEW process on the old pid (other start), 600 s of ticks
mkproc 200 1 1000 10 $((HZ * 300)) 20 1000 0 bash bash
mkproc 300 250 1200 $((100 + HZ * 150)) 0 300 1000 2048 'go test (x)' go test ./...
rm -rf "$P/400"; mkproc 400 1 1999 $((HZ * 3)) 0 50 0 0 cron /usr/sbin/cron -f
box $((1000 + HZ * 300)) $((9000 + HZ * 300)) 7.25 3145728

# 2. a sample -----------------------------------------------------------------
cp "$T/out/state.tsv" "$T/state.t0"
out="$(run_bp DRY_RUN=0 BOX_PROC_NOW=1700000300)"; rc=$?
B="$T/out/box-20231114.tsv" PR="$T/out/proc-20231114.tsv"
row() { awk -F'\t' -v p="$1" '$4 == p' "$PR" 2>/dev/null; }
[[ $rc == 0 && -s "$B" && -s "$PR" ]] && pass "2. the second run writes the box and proc files" || fail "2. sample (rc $rc): $out"
IFS=$'\t' read -r ts bx iv ncpu l1 _ _ busy mem swap procs sampled < <(cat "$B" 2>/dev/null)
[[ "$ts" == 2023-11-14T22:18:20Z && "$bx" == box && "$iv" == 300 && "$ncpu" == 2 && "$l1" == 7.25 && "$busy" == 100.0 &&
  "$mem" == 2048 && "$swap" == 1024 && "$procs" == 4 && "$sampled" == 50.0 ]] &&
  pass "2. box row: interval 300, 2 CPUs, busy 100.0 (core %), swap 1024 MB, sampled 50.0" ||
  fail "2. box row: $(cat "$B")"
IFS=$'\t' read -r _ _ _ _ _ lane own ch rss sw comm args <<<"$(row 300)"
[[ "$lane" == c-123@box && "$own" == 50.0 && "$ch" == 0.0 && "$rss" == 300.0 && "$sw" == 2.0 &&
  "$comm" == 'go_test_(x)' && "$args" == 'go test ./...' ]] &&
  pass "2. grandchild 300: lane c-123@box, own 50.0, rss 300 MB, swap 2 MB, comm one field, args" ||
  fail "2. row 300: $(row 300)"
IFS=$'\t' read -r _ _ _ _ _ lane own ch _ <<<"$(row 200)"
[[ "$lane" == c-123@box && "$own" == 0.0 && "$ch" == 100.0 ]] &&
  pass "2. pane shell 200: child_pct 100.0 from its reaped children" || fail "2. row 200: $(row 200)"

# 3. pid reuse ------------------------------------------------------------------
IFS=$'\t' read -r _ _ _ _ _ lane own _ <<<"$(row 400)"
[[ "$lane" == - && "$own" == 1.0 ]] && pass "3. a reused pid counts its whole life (1.0), no lane" ||
  fail "3. row 400: $(row 400)"
# 50.0 = only pid 300: the new 400 is outside sampled_pct (checked in 2)

# 4. top N ------------------------------------------------------------------------
cp "$T/state.t0" "$T/out/state.tsv"; rm -f "$B" "$PR"
run_bp DRY_RUN=0 BOX_PROC_NOW=1700000300 BOX_PROC_TOP_CPU=1 BOX_PROC_TOP_MEM=1 >/dev/null
[[ "$(cut -f4 "$PR" | sort -n | tr '\n' ' ')" == "200 300 " ]] &&
  pass "4. TOP_CPU=1 TOP_MEM=1 keep the top CPU (200, 100 %) and the top memory (300)" ||
  fail "4. top: $(cut -f4 "$PR" | tr '\n' ' ')"

# 5. dry run --------------------------------------------------------------------
cp "$T/state.t0" "$T/out/state.tsv"; rm -f "$B" "$PR"
out="$(run_bp DRY_RUN=1 BOX_PROC_NOW=1700000300)"; rc=$?
[[ $rc == 0 && ! -e "$B" && ! -e "$PR" ]] && cmp -s "$T/state.t0" "$T/out/state.tsv" &&
  grep -q $'^2023-11-14T22:18:20Z\tbox\t300\t300\t' <<<"$out" &&
  pass "5. DRY_RUN=1 prints the rows and writes nothing" || fail "5. dry run (rc $rc): $out"

# 6. report ----------------------------------------------------------------------
run_bp DRY_RUN=0 BOX_PROC_NOW=1700000300 >/dev/null
out="$(run_bp BOX_PROC_CMD=report BOX_PROC_NOW=1700000400)"; rc=$?
grep -q 'samples=1 ' <<<"$out" && grep -q 'p95=7.25 .*(p95 = 362% of 2 CPUs)' <<<"$out" &&
  [[ "$(grep -A1 '^top by CPU' <<<"$out" | tail -n 1)" =~ ^\ +450\ core-s\ +[0-9.]+%\ +c-123@box$ ]] &&
  [[ "$(grep -A1 '^top by peak' <<<"$out" | tail -n 1)" =~ ^\ +332\ MB\ +c-123@box$ ]] && [[ $rc == 0 ]] &&
  pass "6. report: load p95 362% of 2 CPUs, top lane c-123@box 450 core-s and 332 MB" || fail "6. report (rc $rc): $out"
out="$(run_bp BOX_PROC_CMD=report BOX_PROC_NOW=1800000000)"; rc=$?
[[ $rc == 1 ]] && grep -q '^FAIL no sample' <<<"$out" && pass "6. report on an empty window: FAIL, exit 1" ||
  fail "6. empty window (rc $rc): $out"

# 7. cron ------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/desk/csi-spl-utl"
printf '#!/bin/sh\n' >"$T/desk/csi-spl-utl/run"; chmod +x "$T/desk/csi-spl-utl/run"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then [ -s "$FAKE_CRONTAB" ] || { echo "no crontab for x" >&2; exit 1; }; cat "$FAKE_CRONTAB"; exit 0; fi
cat >"$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
CT="$T/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/a.sh # csi-spl:box-stats' '* * * * * /x/b.sh # csi-spl:box-proc-sample-other' >"$CT"
cp "$CT" "$T/crontab.orig"
cr() { run_bp BOX_PROC_CRONTAB="$T/bin/crontab" FAKE_CRONTAB="$CT" BOX_PROC_DESK_SRC="$T/desk" "$@"; }
out="$(cr BOX_PROC_CMD=install)"; rc=$?
[[ $rc == 0 ]] && cmp -s "$CT" "$T/crontab.orig" && grep -q '^> \*/5 .*# csi-spl:box-proc-sample$' <<<"$out" &&
  pass "7. install dry run prints the line, touches nothing" || fail "7. dry install (rc $rc): $out"
out="$(cr BOX_PROC_CMD=install DRY_RUN=0)"; rc=$?
want="*/5 * * * * cd $T/desk/csi-spl-utl && flock -n $T/out/cron.lock env DRY_RUN=0 ./run -a do_box_proc_sample >> $T/out/cron.out 2>&1 # csi-spl:box-proc-sample"
[[ $rc == 0 && "$(head -n 3 "$CT")" == "$(cat "$T/crontab.orig")" && "$(tail -n 1 "$CT")" == "$want" && "$(wc -l <"$CT")" == 4 ]] &&
  pass "7. install adds one tagged line, the other three kept" || fail "7. install (rc $rc): $out / $(cat "$CT")"
cp "$CT" "$T/crontab.inst"
out="$(cr BOX_PROC_CMD=install DRY_RUN=0)"
cmp -s "$CT" "$T/crontab.inst" && grep -q 'nothing to change' <<<"$out" && pass "7. a second install changes no byte" ||
  fail "7. re-install: $out"
out="$(cr BOX_PROC_CMD=check)"; rc=$?
[[ $rc == 0 ]] && pass "7. check: installed" || fail "7. check (rc $rc): $out"
sed 's|\*/5 \(.*box-proc-sample\)$|*/9 \1|' "$T/crontab.inst" >"$CT"
out="$(cr BOX_PROC_CMD=check)"; rc=$?
[[ $rc == 1 ]] && grep -q 'differs' <<<"$out" && pass "7. CONTROL: a hand-edited line fails check" || fail "7. differs (rc $rc): $out"
out="$(cr BOX_PROC_CMD=remove DRY_RUN=0)"; rc=$?
[[ $rc == 0 ]] && cmp -s "$CT" "$T/crontab.orig" && pass "7. remove restores the crontab byte for byte" ||
  fail "7. remove (rc $rc): $out / $(cat "$CT")"

# 8. read-only ---------------------------------------------------------------------
n=$(grep -cE '(^|[^a-z_])(kill|pkill|killall|renice|ionice)([^a-z_]|$)' "$FUNC_SH")
[[ "$n" == 0 ]] && pass "8. the action has no kill / renice / ionice call" || fail "8. read-only: $n line(s)"

# 9. ./run harness ------------------------------------------------------------------
out="$(cd "$UTL_ROOT" && BOX_PROC_ROOT="$P" BOX_PROC_DIR="$T/run-out" BOX_PROC_PANES_CMD="cat $T/panes" \
  SPOOL_TEST=1 SPOOL_DESK_BOX=box ./run -a do_box_proc_sample 2>&1)"; rc=$?
[[ $rc == 0 && ! -e "$T/run-out" ]] && grep -q 'no previous sample' <<<"$out" &&
  pass "9. ./run -a do_box_proc_sample: dry run, exit 0, nothing written" || fail "9. harness (rc $rc): $out"

# 10. a reaped child counted once ----------------------------------------------
# reap_report <name> <steps...>: one sample per step, then the top lane; a step is "<t offset>|<mkproc args;...>|<gone pids>"
reap_report() {
  local name="$1" step off procs gone a list
  P="$T/proc-$name"; rm -rf "$P"; mkdir -p "$P"
  shift
  for step in "$@"; do
    IFS='|' read -r off procs gone <<<"$step"
    for a in $gone; do rm -rf "${P:?}/$a"; done
    IFS=';' read -r -a list <<<"$procs"
    for a in "${list[@]}"; do [[ -n "$a" ]] && eval "mkproc $a"; done
    box $((1000 + HZ * off)) $((9000 + HZ * off)) 1.00 4194304
    run_bp BOX_PROC_ROOT="$P" BOX_PROC_DIR="$T/out-$name" DRY_RUN=0 BOX_PROC_NOW=$((1700000000 + off)) >/dev/null
  done
  run_bp BOX_PROC_ROOT="$P" BOX_PROC_DIR="$T/out-$name" BOX_PROC_CMD=report BOX_PROC_NOW=1700001000 |
    grep -A1 '^top by CPU' | tail -n 1
}
out="$(reap_report flat \
  "0|200 1 1000 0 0 1 1000 0 bash bash;500 200 1100 0 0 1 1000 0 make make|" \
  "300|500 200 1100 $((HZ * 300)) 0 1 1000 0 make make|" \
  "600|200 1 1000 0 $((HZ * 300)) 1 1000 0 bash bash|500")"
[[ "$out" =~ ^\ +300\ core-s\ +100.0%\ +c-123@box$ ]] &&
  pass "10. a child 300 s at 100 %, then reaped: 300 core-s, not 600" || fail "10. flat: '$out'"
out="$(reap_report nested \
  "0|200 1 1000 0 0 1 1000 0 bash bash;500 200 1100 0 0 1 1000 0 make make;501 500 1200 0 0 1 1000 0 go go|" \
  "300|501 500 1200 $((HZ * 300)) 0 1 1000 0 go go|" \
  "600|500 200 1100 0 $((HZ * 300)) 1 1000 0 make make|501" \
  "900|200 1 1000 0 $((HZ * 300)) 1 1000 0 bash bash|500")"
[[ "$out" =~ ^\ +300\ core-s\ +100.0%\ +c-123@box$ ]] &&
  pass "10. nested: grandchild reaped by the child, the child by the shell: 300, not 900" || fail "10. nested: '$out'"
P="$T/proc"

# 11. notes N1..N3 ------------------------------------------------------------------
cp "$T/crontab.inst" "$CT"
out="$(cr BOX_PROC_CMD=check BOX_PROC_PANES_CMD=true)"; rc=$?
[[ $rc == 0 ]] && grep -q "^WARN .* sees no tmux pane" <<<"$out" &&
  pass "11. N1: check warns when this user sees no tmux pane" || fail "11. N1 (rc $rc): $out"
out="$(cr BOX_PROC_CMD=check)"
! grep -q 'WARN' <<<"$out" && pass "11. N1: no warning when panes are seen" || fail "11. N1 quiet: $out"
mkdir -p "$T/out"; seq 1 50 >"$T/out/cron.out"
cp "$T/state.t0" "$T/out/state.tsv"
run_bp DRY_RUN=0 BOX_PROC_NOW=1700000300 BOX_PROC_OUT_LINES=10 >/dev/null
[[ "$(wc -l <"$T/out/cron.out")" == 10 && "$(tail -n 1 "$T/out/cron.out")" == 50 ]] &&
  pass "11. N2: cron.out cut to its last BOX_PROC_OUT_LINES" || fail "11. N2: $(wc -l <"$T/out/cron.out") lines"
err="$(bash -c 'do_log() { :; }; source "'"$FUNC_SH"'"; box_proc_args "'"$P"'" 99999' 2>&1 >/dev/null)"
[[ -z "$err" ]] && pass "11. N3: a gone pid's cmdline prints nothing on stderr" || fail "11. N3: $err"

echo "box-proc-sample: $fails failure(s)"
[[ "$fails" -eq 0 ]]
