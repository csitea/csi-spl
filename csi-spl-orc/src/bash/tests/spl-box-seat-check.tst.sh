#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_seat_check (spec 159 T2, SPL-3706) measures boxes
#          against the seat start checks of spec 127 5.3 kept by spec 159
#          5.2, read only, on fake box roots (no real /proc is read):
#   1. refusals: a bad box id, an empty list
#   2. a fake box where every check passes -> reported clean, exit 0
#   3. RED CONTROL (127 L13): the same box with plain swap on -> swap fails,
#      the box and the run fail
#   4. each other check planted bad (hidepid, ptrace, suid_dumpable, a piped
#      core_pattern, a disk runtime dir) -> that check, and only it, fails
#   5. encrypted swap and zram pass; a missing /proc/swaps fails
#   6. two boxes, one over a stub ssh: per-box rows, one failing box fails
#      the run; an unreachable box is reported, not skipped
#   7. read only: the fake roots are byte-for-byte unchanged
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# mk_box <root> -> a fake box where all six checks pass
mk_box() {
  local r="$1"
  mkdir -p "$r/proc/sys/kernel/yama" "$r/proc/sys/fs" "$r/sys/block/dm-1/dm" "$r/dev/mapper"
  printf '%s\n' 'sysfs /sys sysfs rw 0 0' \
    'proc /proc proc rw,nosuid,nodev,noexec,relatime,hidepid=invisible 0 0' \
    '/dev/sda1 / ext4 rw 0 0' 'tmpfs /run tmpfs rw 0 0' \
    'tmpfs /run/user/4242 tmpfs rw,mode=700 0 0' >"$r/proc/mounts"
  echo 2 >"$r/proc/sys/kernel/yama/ptrace_scope"
  echo 0 >"$r/proc/sys/fs/suid_dumpable"
  echo '|/usr/lib/systemd/systemd-coredump %P %u %g' >"$r/proc/sys/kernel/core_pattern"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n' >"$r/proc/swaps"
}
add_swap() { printf '%s\tpartition\t1024\t0\t-2\n' "$2" >>"$1/proc/swaps"; }

run_c() { SNIPPET=do_spl_box_seat_check in_orc SEAT_CHECK_UID=4242 "$@" >"$T/o" 2>&1; }
row() { grep -q "^box=$1 check=$2 verdict=$3 " "$T/o"; }
nfail() { grep -c ' verdict=fail ' "$T/o"; }

# --- 1. refusals ---------------------------------------------------------------------------
run_c BOX_SEAT_CHECK_BOXES='Bad_Box' && fail "accepts a bad box id" ||
  { grep -q "is not a box id" "$T/o" && pass "refuses a bad box id" || fail "bad id: $(cat "$T/o")"; }
run_c BOX_SEAT_CHECK_BOXES=' , ' && fail "accepts an empty list" ||
  { grep -q "is empty" "$T/o" && pass "refuses an empty box list" || fail "empty: $(cat "$T/o")"; }

# --- 2. all checks pass -> clean -----------------------------------------------------------
mk_box "$T/ok"
if run_c SEAT_CHECK_ROOT="$T/ok"; then
  [[ "$(grep -c '^box=local check=.* verdict=pass ' "$T/o")" == 6 ]] && grep -q "box local: clean, 6 of 6" "$T/o" &&
    pass "all checks pass -> reported clean, exit 0" || fail "clean box rows: $(cat "$T/o")"
else
  fail "clean box exits non-zero: $(cat "$T/o")"
fi
row local swap pass && grep -q 'detail=swap=none' "$T/o" && pass "no swap reads as none" || fail "no swap: $(cat "$T/o")"

# --- 3. RED CONTROL: plain swap on ---------------------------------------------------------
mk_box "$T/swap"; add_swap "$T/swap" /dev/nvme9n1p3
if run_c SEAT_CHECK_ROOT="$T/swap"; then
  fail "CONTROL: a box with plain swap on passes: $(cat "$T/o")"
else
  row local swap fail && [[ "$(nfail)" == 1 ]] && grep -q 'detail=swap=nvme9n1p3:plain' "$T/o" &&
    grep -q "box local: failing swap" "$T/o" && grep -q "1 of 1 box(es) fail" "$T/o" &&
    pass "CONTROL: plain swap on -> swap reported failing (127 L13), run fails" || fail "CONTROL swap: $(cat "$T/o")"
fi

# --- 4. each other check planted bad -------------------------------------------------------
plant() { # <name> <check> <edit command...>
  local n="$1" c="$2"; shift 2
  mk_box "$T/$n"; "$@" "$T/$n"
  if run_c SEAT_CHECK_ROOT="$T/$n"; then fail "$n: passes: $(cat "$T/o")"
  else row local "$c" fail && [[ "$(nfail)" == 1 ]] && pass "$n -> only $c fails" || fail "$n: $(cat "$T/o")"; fi
}
no_hidepid() { sed -i 's/,hidepid=invisible//' "$1/proc/mounts"; }
hidepid1() { sed -i 's/hidepid=invisible/hidepid=1/' "$1/proc/mounts"; }
ptrace1() { echo 1 >"$1/proc/sys/kernel/yama/ptrace_scope"; }
no_yama() { rm "$1/proc/sys/kernel/yama/ptrace_scope"; }
dump2() { echo 2 >"$1/proc/sys/fs/suid_dumpable"; }
pipe_core() { echo '|/usr/share/apport/apport %p' >"$1/proc/sys/kernel/core_pattern"; }
disk_runtime() { sed -i '/^tmpfs /d' "$1/proc/mounts"; }
plant no-hidepid hidepid no_hidepid
plant hidepid-1 hidepid hidepid1
plant ptrace-1 ptrace ptrace1
plant no-yama ptrace no_yama
plant dump-2 suid_dumpable dump2
plant pipe-core core_pattern pipe_core
plant disk-runtime tmpfs disk_runtime
grep -q 'detail=/run/user/4242:tmpfs' <(mk_box "$T/r2"; SNIPPET=do_spl_box_seat_check in_orc SEAT_CHECK_UID=4242 SEAT_CHECK_ROOT="$T/r2" 2>&1) &&
  pass "tmpfs row names the runtime dir and its fs type" || fail "tmpfs detail missing"

# --- 5. encrypted swap, zram, missing /proc/swaps ------------------------------------------
mk_box "$T/crypt"; echo CRYPT-LUKS2-0000-swap >"$T/crypt/sys/block/dm-1/dm/uuid"
ln -s ../dm-1 "$T/crypt/dev/mapper/swap"; : >"$T/crypt/dev/dm-1"; add_swap "$T/crypt" /dev/mapper/swap
add_swap "$T/crypt" /dev/zram0
run_c SEAT_CHECK_ROOT="$T/crypt" && grep -q 'detail=swap=dm-1:crypt,zram0:zram' "$T/o" &&
  pass "encrypted swap and zram pass" || fail "crypt/zram: $(cat "$T/o")"
mk_box "$T/dmplain"; : >"$T/dmplain/dev/dm-1"; add_swap "$T/dmplain" /dev/dm-1
run_c SEAT_CHECK_ROOT="$T/dmplain" && fail "a dm swap without CRYPT- passes" ||
  { row local swap fail && pass "a dm swap that is not dm-crypt fails" || fail "dm plain: $(cat "$T/o")"; }
mk_box "$T/noswaps"; rm "$T/noswaps/proc/swaps"
run_c SEAT_CHECK_ROOT="$T/noswaps" && fail "an unreadable /proc/swaps passes" ||
  { grep -q 'check=swap verdict=fail detail=swap=unreadable' "$T/o" && pass "an unreadable /proc/swaps fails" || fail "noswaps: $(cat "$T/o")"; }

# --- 6. two boxes, one over a stub ssh -----------------------------------------------------
mkdir -p "$T/bin" "$T/fleet"
cat >"$T/bin/fake-ssh" <<'EOF'
#!/usr/bin/env bash
# like ssh: drop -o pairs, take the destination, run the rest as one shell line
while [[ "${1:-}" == -o ]]; do shift 2; done
dest="$1"; shift
echo "$dest" >>"$FAKE_SSH_LOG"
[[ "$dest" == down-* ]] && { echo "ssh: connect to host $dest: timed out" >&2; exit 255; }
exec bash -c "$*"
EOF
chmod +x "$T/bin/fake-ssh"
mk_box "$T/fleet/box-a"; mk_box "$T/fleet/box-b"; add_swap "$T/fleet/box-b" /swapfile; : >"$T/fleet/box-b/swapfile"
run_c SEAT_CHECK_SSH="$T/bin/fake-ssh" FAKE_SSH_LOG="$T/ssh.log" SEAT_CHECK_ROOT="$T/fleet/{box}" \
  BOX_SEAT_CHECK_BOXES="box-a,box-b" BOX_SSH_BOX_B=alias-b && fail "a failing remote box passes the run" || {
  row box-a swap pass && row box-b swap fail && [[ "$(nfail)" == 1 ]] && grep -q "box box-a: clean" "$T/o" &&
    grep -q "box box-b: failing swap" "$T/o" && grep -q "1 of 2 box(es) fail" "$T/o" &&
    pass "two remote boxes: per-box rows, the failing one fails the run" || fail "two boxes: $(cat "$T/o")"
}
[[ "$(tr '\n' ' ' <"$T/ssh.log")" == "box-a alias-b " ]] && pass "ssh destination: BOX_SSH_<BOX>, else the box id" ||
  fail "ssh dests: $(cat "$T/ssh.log")"
run_c SEAT_CHECK_SSH="$T/bin/fake-ssh" FAKE_SSH_LOG="$T/ssh.log" SEAT_CHECK_ROOT="$T/fleet/{box}" \
  BOX_SEAT_CHECK_BOXES="down-x box-a" && fail "an unreachable box passes" || {
  grep -q '^box=down-x check=reach verdict=fail detail=unreachable' "$T/o" && grep -q "box box-a: clean" "$T/o" &&
    pass "an unreachable box is reported failing, the next box still measured" || fail "unreachable: $(cat "$T/o")"
}

# --- 7. read only ----------------------------------------------------------------------------
snap() { (cd "$T" && find ok swap crypt fleet -printf '%p %m %s %T@\n' | sort; cat ok/proc/mounts fleet/box-b/proc/swaps) | sha256sum; }
before="$(snap)"
run_c SEAT_CHECK_ROOT="$T/ok"; run_c SEAT_CHECK_ROOT="$T/swap"
run_c SEAT_CHECK_SSH="$T/bin/fake-ssh" FAKE_SSH_LOG="$T/ssh.log" SEAT_CHECK_ROOT="$T/fleet/{box}" BOX_SEAT_CHECK_BOXES="box-a,box-b"
[[ "$(snap)" == "$before" ]] && pass "read only: the fake roots are unchanged" || fail "a run changed a fake root"
A="$PROJ_ROOT/src/bash/run/spl-box-seat-check.func.sh"
if [[ ! -f "$A" ]]; then fail "no action file $A"
elif grep -nE '\b(sudo|chmod|chown|mount|swapoff|swapon|sysctl -w|tee|rm|mv|cp)\b' "$A" | grep -v '^[0-9]*:#'; then
  fail "the action carries a writing command"
else pass "the action carries no sudo or writing command"; fi

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
