#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_connectivity_check (networking round row 02, SPL-2207) writes
#   the NM conf.d file that turns the connectivity check on and verifies it.
#   1. DRY_RUN default: prints the state, rp_filter, the file and the commands;
#      writes no file, runs no reload or check; a bad DRY_RUN / relative
#      NET_ROOT refused
#   2. DRY_RUN=0: the file under NET_ROOT holds exactly the [connectivity]
#      uri / interval = 10 / timeout = 5, mode 0644; nmcli reload conf and
#      connectivity check run; check says full -> OK; a second run: SAME
#   3. the check says limited -> FATAL
#   4. rp_filter strict (1) on an uplink, on conf/default or on conf/all, or
#      unreadable -> FATAL, nothing written; dev=1 under all=2 is loose -> OK
#   5. red control: a copy writing timeout = 20 is caught by the content check
#   No real /etc, /proc, NetworkManager or interface: NET_ROOT, NET_PROC,
#   stubs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/net-connectivity-check.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CALLS="$T/calls"

cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALLS"
case "$*" in
  "-t -f DEVICE,TYPE dev") printf 'enp0s31f6:ethernet\nwlp0s20f3:wifi\nlo:loopback\n' ;;
  "networking connectivity") echo unknown ;;
  "networking connectivity check") echo "${NMCLI_CONN:-full}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/nmcli"

# proc <dir> <all> <default> <enp0s31f6> <wlp0s20f3> - a fake /proc; "-" = absent
proc() {
  local d="$1" n v i=0; shift
  for n in all default enp0s31f6 wlp0s20f3; do
    i=$((i + 1)); v="${!i}"; [[ "$v" == - ]] && continue
    mkdir -p "$d/sys/net/ipv4/conf/$n" && echo "$v" >"$d/sys/net/ipv4/conf/$n/rp_filter"
  done
}
# run <func file> <root> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1" root="$2"; shift 2
  env NET_ROOT="$root" NET_PROC="$T/proc" NET_NMCLI="$T/bin/nmcli" NET_SUDO="" "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_connectivity_check' "$f"
}
reset() { rm -rf "$1" "$CALLS" "$T/proc"; proc "$T/proc" 0 2 2 2; }
want='[connectivity]
uri = http://network-test.debian.org/nm
interval = 10
timeout = 5'
conf() { echo "$1/etc/NetworkManager/conf.d/30-connectivity.conf"; }

# 1. dry run
reset "$T/r1"; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
if ((rc == 0)) && [[ ! -e "$(conf "$T/r1")" ]] && ! grep -qE 'reload|check' "$CALLS" &&
  grep -q 'NOW connectivity=unknown uplinks=enp0s31f6,wlp0s20f3' <<<"$out" &&
  grep -q 'RP wlp0s20f3=2' <<<"$out" && grep -q 'timeout = 5' <<<"$out" &&
  grep -q 'PLAN .*nmcli general reload conf' <<<"$out" && grep -q 'OK DRY_RUN' <<<"$out"; then
  pass "1 DRY_RUN default plans, writes nothing, reloads and checks nothing"
else fail "1 dry run (rc=$rc): $out"; fi
out="$(run "$FUNC" "$T/r1" DRY_RUN=yes 2>&1)" && fail "1 DRY_RUN=yes accepted" || pass "1 bad DRY_RUN refused"
out="$(run "$FUNC" "rel" 2>&1)" && fail "1 relative NET_ROOT accepted" || pass "1 relative NET_ROOT refused"

# 2. apply, then again
reset "$T/r2"; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
f="$(conf "$T/r2")"
if ((rc == 0)) && [[ "$(cat "$f" 2>/dev/null)" == "$want" && "$(stat -c %a "$f")" == 644 ]]; then
  pass "2 DRY_RUN=0 writes the exact file, 0644"
else fail "2 file (rc=$rc): $out / $(cat "$f" 2>&1)"; fi
if grep -qx 'nmcli general reload conf' "$CALLS" && grep -qx 'nmcli networking connectivity check' "$CALLS" &&
  grep -q 'OK connectivity full' <<<"$out"; then
  pass "2 reloads NM, the check says full"
else fail "2 commands: $(cat "$CALLS") / $out"; fi
out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q "SAME $f" <<<"$out" && pass "2 second run leaves the file" || fail "2 second run (rc=$rc): $out"

# 3. the check does not say full
reset "$T/r3"; out="$(run "$FUNC" "$T/r3" DRY_RUN=0 NMCLI_CONN=limited 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL .*says 'limited', not full" <<<"$out" && pass "3 check limited -> FATAL" ||
  fail "3 limited (rc=$rc): $out"

# 4. rp_filter
# rp <label> <all> <default> <enp0s31f6> <wlp0s20f3> <want rc 0|1>
rp() {
  local label="$1" wrc="$6"
  rm -rf "$T/r4" "$CALLS" "$T/proc"; proc "$T/proc" "$2" "$3" "$4" "$5"
  out="$(run "$FUNC" "$T/r4" DRY_RUN=0 2>&1)"; rc=$?
  if ((wrc == 1)); then
    ((rc != 0)) && grep -q 'FATAL a strict rp_filter' <<<"$out" && [[ ! -e "$(conf "$T/r4")" ]] &&
      ! grep -q reload "$CALLS" && pass "4 $label -> FATAL, nothing written" || fail "4 $label (rc=$rc): $out"
  else
    ((rc == 0)) && [[ -f "$(conf "$T/r4")" ]] && pass "4 $label -> OK" || fail "4 $label (rc=$rc): $out"
  fi
}
rp "wifi strict" 0 2 2 1 1
rp "ethernet strict" 0 2 1 2 1
rp "conf/default strict" 0 1 2 2 1
rp "conf/all strict" 1 0 0 0 1
rp "wifi unreadable" 0 2 2 - 1
rp "wifi 1 under all=2 is loose" 2 2 2 1 0

# 5. red control
sed 's/timeout = 5/timeout = 20/' "$FUNC" >"$T/red.func.sh"
reset "$T/r5"; run "$T/red.func.sh" "$T/r5" DRY_RUN=0 >/dev/null 2>&1
[[ "$(cat "$(conf "$T/r5")" 2>/dev/null)" == "$want" ]] && fail "5 red control: timeout = 20 not caught" ||
  pass "5 red control: a wrong value is caught"

echo "net-connectivity-check: $fails failure(s)"
exit $((fails > 0))
