#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_powersave_off (networking round row 01, SPL-2205) writes the
#   NM conf.d file that turns Wi-Fi power save off and sets it at runtime.
#   1. DRY_RUN default: prints the state, the file and the commands; writes no
#      file, runs no set or reload; a bad DRY_RUN / relative NET_ROOT refused
#   2. DRY_RUN=0: the file under NET_ROOT holds exactly [connection] +
#      wifi.powersave = 2, mode 0644; nmcli reload conf and iw set run; the
#      read-back says off -> OK; a second run leaves the file (SAME)
#   3. iw set runs but power save still reads on -> FATAL
#   4. no iw: the file lands, a WARN, nothing installed; no wifi device: same
#   5. red control: a copy writing wifi.powersave = 3 is caught by the content
#      check
#   No real /etc, NetworkManager, iw or interface: NET_ROOT, stubs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/net-powersave-off.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CALLS="$T/calls" PS_STATE="$T/ps" PS_STICKY=""

cat >"$T/bin/iw" <<'EOF'
#!/usr/bin/env bash
echo "iw $*" >>"$CALLS"
case "$3" in
  get) echo "Power save: $(cat "$PS_STATE")" ;;
  set) [[ -n "$PS_STICKY" ]] || echo "$5" >"$PS_STATE" ;;
esac
EOF
cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALLS"
[[ "$*" == "-t -f DEVICE,TYPE dev" ]] && printf '%s\n' "${NMCLI_DEVS-enp0s31f6:ethernet
wlp0s20f3:wifi}"
exit 0
EOF
chmod +x "$T/bin/iw" "$T/bin/nmcli"

# run <func file> <root> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1" root="$2"; shift 2
  env NET_ROOT="$root" NET_IW="$T/bin/iw" NET_NMCLI="$T/bin/nmcli" NET_SUDO="" "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_powersave_off' "$f"
}
reset() { rm -rf "$1" "$CALLS"; echo on >"$PS_STATE"; }
want='[connection]
wifi.powersave = 2'
conf() { echo "$1/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf"; }

# 1. dry run
reset "$T/r1"; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
if ((rc == 0)) && [[ ! -e "$(conf "$T/r1")" ]] && ! grep -qE 'set|reload' "$CALLS" &&
  grep -q 'NOW wlan=wlp0s20f3 power_save=on' <<<"$out" && grep -q 'wifi.powersave = 2' <<<"$out" &&
  grep -q 'PLAN .*iw dev wlp0s20f3 set power_save off' <<<"$out" && grep -q 'OK DRY_RUN' <<<"$out"; then
  pass "1 DRY_RUN default plans, writes nothing, sets nothing"
else fail "1 dry run (rc=$rc): $out"; fi
out="$(run "$FUNC" "$T/r1" DRY_RUN=yes 2>&1)" && fail "1 DRY_RUN=yes accepted" || pass "1 bad DRY_RUN refused"
out="$(run "$FUNC" "rel" 2>&1)" && fail "1 relative NET_ROOT accepted" || pass "1 relative NET_ROOT refused"

# 2. apply, then again
reset "$T/r2"; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
f="$(conf "$T/r2")"
if ((rc == 0)) && [[ "$(cat "$f" 2>/dev/null)" == "$want" && "$(stat -c %a "$f")" == 644 ]]; then
  pass "2 DRY_RUN=0 writes the exact file, 0644"
else fail "2 file (rc=$rc): $out / $(cat "$f" 2>&1)"; fi
if grep -qx 'nmcli general reload conf' "$CALLS" && grep -qx 'iw dev wlp0s20f3 set power_save off' "$CALLS" &&
  grep -q 'OK wlp0s20f3 Power save: off' <<<"$out"; then
  pass "2 reloads NM, sets power save off, reads off back"
else fail "2 commands: $(cat "$CALLS") / $out"; fi
out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q "SAME $f" <<<"$out" && pass "2 second run leaves the file" || fail "2 second run (rc=$rc): $out"

# 3. the set does not take
reset "$T/r3"; out="$(PS_STICKY=1 run "$FUNC" "$T/r3" DRY_RUN=0 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL .*reads 'on', not off" <<<"$out" && pass "3 power save still on -> FATAL" ||
  fail "3 sticky (rc=$rc): $out"

# 4. no iw; no wifi device
reset "$T/r4"; out="$(run "$FUNC" "$T/r4" DRY_RUN=0 NET_IW="$T/bin/none" 2>&1)"; rc=$?
((rc == 0)) && [[ "$(cat "$(conf "$T/r4")")" == "$want" ]] && grep -q "WARN $T/bin/none not found" <<<"$out" &&
  ! grep -q '^iw ' "$CALLS" && pass "4 no iw: file lands, WARN" || fail "4 no iw (rc=$rc): $out"
reset "$T/r5"; out="$(run "$FUNC" "$T/r5" DRY_RUN=0 NMCLI_DEVS="enp0s31f6:ethernet" 2>&1)"; rc=$?
((rc == 0)) && [[ -f "$(conf "$T/r5")" ]] && grep -q 'WARN no Wi-Fi device' <<<"$out" &&
  ! grep -q '^iw .* set' "$CALLS" && pass "4 no wifi device: file lands, WARN, no iw set" || fail "4 no wlan (rc=$rc): $out"

# 5. red control
sed 's/wifi.powersave = 2/wifi.powersave = 3/' "$FUNC" >"$T/red.func.sh"
reset "$T/r6"; run "$T/red.func.sh" "$T/r6" DRY_RUN=0 >/dev/null 2>&1
[[ "$(cat "$(conf "$T/r6")" 2>/dev/null)" == "$want" ]] && fail "5 red control: powersave = 3 not caught" ||
  pass "5 red control: a wrong value is caught"

echo "net-powersave-off: $fails failure(s)"
exit $((fails > 0))
