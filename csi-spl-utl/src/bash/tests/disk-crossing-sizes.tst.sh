#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_disk_crossing_sizes (SPL-4629), on a fixture tree in a temp
# dir; a slow or failing du is a stub.
#   1. DRY_RUN=1 prints the dirs biggest first and writes no record
#   2. DRY_RUN=0 records the top rows complete, with their biggest children
#   3. A du cut at its cap records a partial lower bound, within the budget
#   4. A dir left with no budget is unmeasured, never a size
#   5. A du that cannot read part of a dir is partial, reason du-error
#   6. Red control: a script that calls a cut du complete fails the check of 3
#   7. A bad budget is refused, exit 2, nothing recorded
#   8. Another run holding the mount's lock: SKIP, nothing recorded
#   9. Invocation via the csi-spl-utl ./run harness
#  10. A top dir on another device (a mountpoint) is not sized
#  11. Top dirs that cannot be listed read partial with a row, not complete (W1)
#  12. Child rows of a du error are partial (W2)
#  13. A hanging find counts against the budget (W3)
#  14. A lock that cannot be opened is FATAL, not a SKIP (W4)
#  15. The record keeps its newest lines (W5)
#  16. A du that cannot start is unmeasured
#  17. Time left over goes to the dir that was cut
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
SCRIPT="$UTL_ROOT/src/bash/scripts/disk-crossing-sizes.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

M="$T/mnt"
mkdir -p "$M/big/a" "$M/big/b" "$M/small/x"
head -c 2097152 /dev/zero >"$M/big/a/f"
head -c 1048576 /dev/zero >"$M/big/b/f"
head -c 102400 /dev/zero >"$M/small/x/f"

# a du that prints one finished child and then hangs; exec, so timeout kills it
cat >"$T/du-slow" <<'EOF'
#!/bin/bash
d="${!#}"
printf '4096\t%s/done-child\n' "$d"
exec sleep 30
EOF
# a du that finishes but could not read part of the dir
cat >"$T/du-denied" <<'EOF'
#!/bin/bash
d="${!#}"
printf '8192\t%s\n' "$d"
exit 1
EOF
chmod +x "$T/du-slow" "$T/du-denied"

run() { env DISK_CROSSING_MOUNT="$M" DISK_CROSSING_BOX=fixture DISK_CROSSING_TSV="$TSV" "$@"; }
top_row() { awk -F'\t' -v p="$2" '$5 == "top" && $6 == p { print $7, $8, $9 }' "$1"; }

# 1. dry run
TSV="$T/1/sizes.tsv"
out="$(run bash "$SCRIPT" 2>&1)"; rc=$?
first="$(sed -n 1p <<<"$out")"
[[ $rc -eq 0 && "$first" == *"$M/big"$'\t'complete* && ! -e "$TSV" && "$out" == *"complete, 2 of 2 dirs"* ]] \
  && pass "1. a dry run prints the biggest dir first and records nothing" || fail "1. rc=$rc out=$out"

# 2. the record
TSV="$T/2/sizes.tsv"
run DRY_RUN=0 DISK_CROSSING_TRIGGER=blocks:/x bash "$SCRIPT" >/dev/null 2>&1
read -r b s r <<<"$(top_row "$TSV" "$M/big")"
[[ "${b:-0}" -ge 3145728 && "$s" == complete && "$r" == - ]] \
  && pass "2. the top row is complete with the dir's bytes" || fail "2. top row '$b $s $r'"
awk -F'\t' -v p="$M/big/a" '$4 == "blocks:/x" && $5 == "child" && $6 == p && $7 >= 2097152 { f = 1 } END { exit !f }' "$TSV" \
  && pass "2. the biggest children are recorded" || fail "2. child rows: $(cat "$TSV")"

# check_cut <tsv> <dir>: a cut du must read partial with the finished child only
check_cut() {
  local b s r
  read -r b s r <<<"$(top_row "$1" "$2")"
  [[ "$b" == 4096 && "$s" == partial && "$r" == timeout ]]
}

# 3. a du cut at its cap
mkdir -p "$T/one/only"
TSV="$T/3/sizes.tsv"
s0=$SECONDS
env DISK_CROSSING_MOUNT="$T/one" DISK_CROSSING_BOX=fixture DISK_CROSSING_TSV="$TSV" DISK_CROSSING_DU="$T/du-slow" \
  DISK_CROSSING_BUDGET_S=2 DRY_RUN=0 bash "$SCRIPT" >"$T/3.out" 2>&1; rc=$?
elapsed=$(( SECONDS - s0 ))
check_cut "$TSV" "$T/one/only" && pass "3. a cut du records partial, the finished child's bytes" || fail "3. $(cat "$TSV")"
[[ $rc -eq 0 && $elapsed -le 6 ]] && pass "3. a partial run exits 0 within the budget (${elapsed}s)" || fail "3. rc=$rc elapsed=${elapsed}s"
grep -q "partial, 0 of 1 dirs complete" "$T/3.out" && pass "3. the summary says partial" || fail "3. summary: $(cat "$T/3.out")"

# 4. no budget left for the second dir
TSV="$T/4/sizes.tsv"
run DISK_CROSSING_DU="$T/du-slow" DISK_CROSSING_BUDGET_S=1 DRY_RUN=0 bash "$SCRIPT" >/dev/null 2>&1
[[ "$(top_row "$TSV" "$M/small")" == "0 unmeasured budget" ]] \
  && pass "4. a dir with no budget left is unmeasured" || fail "4. $(cat "$TSV")"

# 5. du could not read part of a dir
TSV="$T/5/sizes.tsv"
run DISK_CROSSING_DU="$T/du-denied" DRY_RUN=0 bash "$SCRIPT" >/dev/null 2>&1
[[ "$(top_row "$TSV" "$M/big")" == "8192 partial du-error" ]] \
  && pass "5. a du error is partial, not complete" || fail "5. $(cat "$TSV")"

# 6. red control: the planted defect must fail the check of case 3
sed 's/124|137)  *reason=timeout; if \[\[ -n "\$out" \]\]; then state=partial; else state=unmeasured; fi ;;/124|137) reason=-; state=complete ;;/' \
  "$SCRIPT" >"$T/planted.sh"
if cmp -s "$SCRIPT" "$T/planted.sh"; then
  fail "6. the planted defect did not change the script"
else
  TSV="$T/6/sizes.tsv"
  env DISK_CROSSING_MOUNT="$T/one" DISK_CROSSING_BOX=fixture DISK_CROSSING_TSV="$TSV" DISK_CROSSING_DU="$T/du-slow" \
    DISK_CROSSING_BUDGET_S=1 DRY_RUN=0 bash "$T/planted.sh" >/dev/null 2>&1
  check_cut "$TSV" "$T/one/only" && fail "6. the check passed on the planted defect" \
    || pass "6. red control: the check fails on a script that calls a cut du complete"
fi

# 7. usage
TSV="$T/7/sizes.tsv"
run DISK_CROSSING_BUDGET_S=0 DRY_RUN=0 bash "$SCRIPT" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 && ! -e "$TSV" ]] && pass "7. a bad budget is refused, exit 2" || fail "7. rc=$rc"

# 8. the lock
TSV="$T/8/sizes.tsv"
mkdir -p "$T/8"
exec 7>>"$T/8/lock.${M//\//_}"
flock -n 7
out="$(run DRY_RUN=0 bash "$SCRIPT" 7>&- 2>&1)"; rc=$?
exec 7>&-
[[ $rc -eq 0 && "$out" == *"SKIP another run"* && ! -e "$TSV" ]] \
  && pass "8. a held lock skips and records nothing" || fail "8. rc=$rc out=$out"

# 9. the ./run harness
out="$(cd "$UTL_ROOT" && DISK_CROSSING_MOUNT="$M" DISK_CROSSING_BOX=fixture ./run -a do_disk_crossing_sizes 2>&1)"
[[ "$out" == *"complete, 2 of 2 dirs"* ]] && pass "9. runs through ./run" || fail "9. $out"

# 10. a mountpoint in the mount
cat >"$T/stat-mp" <<'EOF'
#!/bin/bash
[[ "${!#}" == */small ]] && { echo 99; exit 0; }
exec stat "$@"
EOF
chmod +x "$T/stat-mp"
TSV="$T/10/sizes.tsv"
out="$(run DISK_CROSSING_STAT="$T/stat-mp" bash "$SCRIPT" 2>&1)"
[[ "$out" == *"complete, 1 of 1 dirs"* && "$out" != *"$M/small"* ]] \
  && pass "10. a top dir on another device is not sized" || fail "10. $out"

# 11. a mount that cannot be listed
mkdir -p "$T/locked"
chmod 000 "$T/locked"
TSV="$T/11/sizes.tsv"
out="$(env DISK_CROSSING_MOUNT="$T/locked" DISK_CROSSING_BOX=fixture DISK_CROSSING_TSV="$TSV" DRY_RUN=0 bash "$SCRIPT" 2>&1)"; rc=$?
chmod 755 "$T/locked"
[[ $rc -eq 0 && "$out" == *"partial, 0 of 0 dirs"* && "$(top_row "$TSV" "$T/locked")" == "0 unmeasured find-error" ]] \
  && pass "11. an unlistable mount reads partial, with a row" || fail "11. rc=$rc out=$out"

# 12. child rows of a du error
cat >"$T/du-kid-denied" <<'EOF'
#!/bin/bash
d="${!#}"
printf '8192\t%s/kid\n12288\t%s\n' "$d" "$d"
exit 1
EOF
chmod +x "$T/du-kid-denied"
TSV="$T/12/sizes.tsv"
run DISK_CROSSING_DU="$T/du-kid-denied" DRY_RUN=0 bash "$SCRIPT" >/dev/null 2>&1
awk -F'\t' -v p="$M/big/kid" '$5 == "child" && $6 == p && $8 == "partial" && $9 == "du-error" { f = 1 } END { exit !f }' "$TSV" \
  && pass "12. a du error marks its child rows partial" || fail "12. $(cat "$TSV")"

# 13. a hanging find
printf '#!/bin/bash\nexec sleep 30\n' >"$T/find-hang"
chmod +x "$T/find-hang"
TSV="$T/13/sizes.tsv"
s0=$SECONDS
out="$(run DISK_CROSSING_FIND="$T/find-hang" DISK_CROSSING_BUDGET_S=2 DRY_RUN=0 bash "$SCRIPT" 2>&1)"
elapsed=$(( SECONDS - s0 ))
[[ $elapsed -le 4 && "$out" == *"partial, 0 of 0 dirs"* && "$(top_row "$TSV" "$M")" == "0 unmeasured find-timeout" ]] \
  && pass "13. a hanging find ends inside the budget + 2 s (${elapsed}s)" || fail "13. ${elapsed}s out=$out"

# 14. a lock that cannot be opened
TSV="$T/14/sizes.tsv"
mkdir -p "$T/14/lock.${M//\//_}"
out="$(run DRY_RUN=0 bash "$SCRIPT" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL cannot open the lock"* && "$out" != *SKIP* ]] \
  && pass "14. an unopenable lock is FATAL, not a SKIP" || fail "14. rc=$rc out=$out"

# 15. the record's cap
TSV="$T/15/sizes.tsv"
run DRY_RUN=0 DISK_CROSSING_TRIGGER=first DISK_CROSSING_CHILDREN=0 bash "$SCRIPT" >/dev/null 2>&1
run DRY_RUN=0 DISK_CROSSING_TRIGGER=second DISK_CROSSING_CHILDREN=0 DISK_CROSSING_KEEP_LINES=2 bash "$SCRIPT" >/dev/null 2>&1
[[ "$(wc -l <"$TSV")" == 2 && "$(cut -f4 "$TSV" | sort -u)" == second && ! -e "$TSV.tmp" ]] \
  && pass "15. the record keeps its newest lines" || fail "15. $(cat "$TSV")"

# 16. a du that cannot start
TSV="$T/16/sizes.tsv"
run DISK_CROSSING_DU="$T/no-such-du" DRY_RUN=0 bash "$SCRIPT" >/dev/null 2>&1
[[ "$(top_row "$TSV" "$M/big")" == "0 unmeasured du-not-run" ]] \
  && pass "16. a du that cannot start is unmeasured" || fail "16. $(cat "$TSV")"

# 17. a du of big that hangs the first time only, small finishes at once
cat >"$T/du-once" <<EOF
#!/bin/bash
d="\${!#}"
if [[ "\$d" == */big && ! -e "$T/du-once.flag" ]]; then : >"$T/du-once.flag"; exec sleep 30; fi
printf '5000\t%s\n' "\$d"
EOF
chmod +x "$T/du-once"
TSV="$T/17/sizes.tsv"
run DISK_CROSSING_DU="$T/du-once" DISK_CROSSING_BUDGET_S=4 DRY_RUN=0 bash "$SCRIPT" >/dev/null 2>&1
[[ "$(top_row "$TSV" "$M/big")" == "5000 complete -" ]] \
  && pass "17. time left over finishes the dir that was cut" || fail "17. $(cat "$TSV")"

echo
if (( fails == 0 )); then echo "OK: disk-crossing-sizes"; exit 0; fi
echo "FAILED: $fails"
exit 1
