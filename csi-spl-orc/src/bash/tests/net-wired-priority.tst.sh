#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_wired_priority (networking round row 03, SPL-2288) writes the
#   persistent wired NM profile at metric 100 and proves it wins the default.
#   1. DRY_RUN default: prints the state, the file and the commands; writes no
#      file, runs no reload or up; with a cable it plans the up; a bad DRY_RUN,
#      a relative NET_ROOT, a bad NET_WAIT and a missing NIC are refused
#   2. DRY_RUN=0, no cable: the keyfile under NET_ROOT holds exactly the plan's
#      profile, mode 0600; nmcli connection reload runs, no up; read-back
#      100 100 100 -> OK; a second run: SAME
#   3. read-back not 100 100 100 (NM ignored the file) -> FATAL
#   4. cable in, Wi-Fi up: up wired-default ifname <nic>; wired 100 ahead of
#      Wi-Fi 600 on IPv4 and IPv6 -> OK
#   5. the field fence: cable in, Wi-Fi gone -> the only default is via the
#      NIC -> OK
#   6. wired loses: another default at a lower metric, or the wired default
#      not 100, on IPv4 or IPv6 -> FATAL; no IPv6 default on wired -> WARN, OK
#   7. red controls: a copy writing route-metric = 600, a copy writing 0644,
#      and a copy without the route proof are each caught
#   No real /etc, /sys, NetworkManager, route or interface: NET_ROOT, NET_SYS,
#   stubs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/net-wired-priority.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CALLS="$T/calls" R4="$T/routes4" R6="$T/routes6"

# nmcli: "connection up" adds UP4 / UP6 (the routes the wired link brings)
cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALLS"
case "$*" in
  "-t -f DEVICE,STATE dev") printf 'wlp0s20f3:connected\nenp0s31f6:%s\nveth1:unmanaged\n' "${NIC_STATE:-unavailable}" ;;
  "-g connection.autoconnect-priority,ipv4.route-metric,ipv6.route-metric connection show wired-default")
    printf '%b\n' "${NMCLI_SHOW:-100\n100\n100}" ;;
  "connection up wired-default ifname enp0s31f6")
    [[ -n "${UP4:-}" ]] && printf '%b\n' "$UP4" >>"$R4"
    [[ -n "${UP6:-}" ]] && printf '%b\n' "$UP6" >>"$R6" ;;
esac
exit 0
EOF
cat >"$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >>"$CALLS"
case "$*" in
  "-4 route show default") cat "$R4" 2>/dev/null ;;
  "-6 route show default") cat "$R6" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$T/bin/nmcli" "$T/bin/ip"
W4='default via 192.0.2.1 dev wlp0s20f3 proto dhcp src 192.0.2.10 metric 600'
W6='default via fe80::1 dev wlp0s20f3 proto ra metric 600 pref high'
E4='default via 198.51.100.1 dev enp0s31f6 proto dhcp src 198.51.100.10 metric 100'
E6='default via fe80::2 dev enp0s31f6 proto ra metric 100 pref medium'

# reset <root> <carrier 0|1> [wifi 1|0] - fresh root, calls, /sys and routes
reset() {
  rm -rf "$1" "$CALLS" "$T/sys" "$R4" "$R6"
  mkdir -p "$T/sys/class/net/enp0s31f6/device" && echo "$2" >"$T/sys/class/net/enp0s31f6/carrier"
  : >"$R4"; : >"$R6"
  [[ "${3:-1}" == 1 ]] && { echo "$W4" >"$R4"; echo "$W6" >"$R6"; }
  return 0
}
# run <func file> <root> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1" root="$2"; shift 2
  env NET_ROOT="$root" NET_SYS="$T/sys" NET_NMCLI="$T/bin/nmcli" NET_IP="$T/bin/ip" NET_SUDO="" NET_WAIT=0 "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_wired_priority' "$f"
}
want='[connection]
id = wired-default
type = ethernet
interface-name = enp0s31f6
autoconnect = yes
autoconnect-priority = 100

[ipv4]
method = auto
route-metric = 100

[ipv6]
method = auto
route-metric = 100'
conf() { echo "$1/etc/NetworkManager/system-connections/wired-default.nmconnection"; }

# 1. dry run
reset "$T/r1" 0; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
if ((rc == 0)) && [[ ! -e "$(conf "$T/r1")" ]] && ! grep -qE 'reload|connection up' "$CALLS" &&
  grep -q 'NOW enp0s31f6 state=unavailable carrier=0' <<<"$out" && grep -q "NOW v4 $W4" <<<"$out" &&
  grep -q 'PLAN write .*wired-default.nmconnection (0600)' <<<"$out" && grep -q '  route-metric = 100' <<<"$out" &&
  grep -q 'PLAN no cable in enp0s31f6' <<<"$out" && grep -q 'OK DRY_RUN' <<<"$out"; then
  pass "1 DRY_RUN default plans, writes nothing, reloads and activates nothing"
else fail "1 dry run (rc=$rc): $out"; fi
reset "$T/r1" 1; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
((rc == 0)) && grep -q 'PLAN nmcli connection up wired-default ifname enp0s31f6\|PLAN .*nmcli connection up wired-default ifname enp0s31f6' <<<"$out" &&
  ! grep -q 'connection up' "$CALLS" && pass "1 DRY_RUN with a cable plans the up, runs none" || fail "1 dry cable (rc=$rc): $out"
out="$(run "$FUNC" "$T/r1" DRY_RUN=yes 2>&1)" && fail "1 DRY_RUN=yes accepted" || pass "1 bad DRY_RUN refused"
out="$(run "$FUNC" "rel" 2>&1)" && fail "1 relative NET_ROOT accepted" || pass "1 relative NET_ROOT refused"
out="$(run "$FUNC" "$T/r1" NET_WAIT=x 2>&1)" && fail "1 NET_WAIT=x accepted" || pass "1 bad NET_WAIT refused"
out="$(run "$FUNC" "$T/r1" NET_WIRED_IFACE=eth9 2>&1)"; rc=$?
((rc != 0)) && grep -q 'FATAL no wired NIC eth9' <<<"$out" && pass "1 missing NIC refused" || fail "1 missing NIC (rc=$rc): $out"

# 2. apply with no cable, then again
reset "$T/r2" 0; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
f="$(conf "$T/r2")"
if ((rc == 0)) && [[ "$(cat "$f" 2>/dev/null)" == "$want" && "$(stat -c %a "$f")" == 600 ]]; then
  pass "2 DRY_RUN=0 writes the exact keyfile, 0600"
else fail "2 file (rc=$rc): $out / $(cat "$f" 2>&1)"; fi
if grep -qx 'nmcli connection reload' "$CALLS" && ! grep -q 'connection up' "$CALLS" &&
  grep -q 'READ wired-default autoconnect-priority=100 ipv4.route-metric=100 ipv6.route-metric=100' <<<"$out" &&
  grep -q 'OK wired-default in place; no cable' <<<"$out"; then
  pass "2 reloads NM, reads 100 100 100, no cable -> no up"
else fail "2 commands: $(cat "$CALLS") / $out"; fi
out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q "SAME $f" <<<"$out" && pass "2 second run leaves the file" || fail "2 second run (rc=$rc): $out"

# 3. NM does not read it as 100 100 100
reset "$T/r3" 0; out="$(run "$FUNC" "$T/r3" DRY_RUN=0 NMCLI_SHOW='Error: wired-default - no such connection profile.' 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL nmcli reads wired-default as 'Error: wired-default - no such connection profile. ', not 100 100 100" <<<"$out" &&
  pass "3 profile not loaded -> FATAL" || fail "3 not loaded (rc=$rc): $out"
reset "$T/r3" 0; out="$(run "$FUNC" "$T/r3" DRY_RUN=0 NMCLI_SHOW='-999\n-1\n-1' 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL nmcli reads wired-default as '-999 -1 -1 '" <<<"$out" &&
  pass "3 read-back -999 -1 -1 -> FATAL" || fail "3 wrong read-back (rc=$rc): $out"

# 4. cable in, Wi-Fi up: wired wins on both families
reset "$T/r4" 1; out="$(run "$FUNC" "$T/r4" DRY_RUN=0 NIC_STATE=connected UP4="$E4" UP6="$E6" 2>&1)"; rc=$?
if ((rc == 0)) && grep -qx 'nmcli connection up wired-default ifname enp0s31f6' "$CALLS" &&
  grep -q 'ROUTE v4 enp0s31f6 metric 100 (next wlp0s20f3 metric 600)' <<<"$out" &&
  grep -q 'ROUTE v6 enp0s31f6 metric 100 (next wlp0s20f3 metric 600)' <<<"$out" &&
  grep -q 'OK wired-default up on enp0s31f6' <<<"$out"; then
  pass "4 cable in: up on the NIC, metric 100 ahead of Wi-Fi 600 (IPv4 + IPv6)"
else fail "4 cable (rc=$rc): $out / $(cat "$CALLS")"; fi

# 5. the field fence: Wi-Fi gone while wired is up
reset "$T/r5" 1 0; out="$(run "$FUNC" "$T/r5" DRY_RUN=0 NIC_STATE=connected UP4="$E4" UP6="$E6" 2>&1)"; rc=$?
((rc == 0)) && grep -q 'ROUTE v4 enp0s31f6 metric 100$' <<<"$out" && grep -q 'ROUTE v6 enp0s31f6 metric 100$' <<<"$out" &&
  grep -q 'NOW enp0s31f6' <<<"$out" && ! grep -q 'NOW v4' <<<"$out" &&
  pass "5 Wi-Fi gone, wired up: the default goes via the NIC" || fail "5 field case (rc=$rc): $out"

# 6. wired does not win
# lose <label> <up4> <up6> <want: fatal|warn>
lose() {
  reset "$T/r6" 1; out="$(run "$FUNC" "$T/r6" DRY_RUN=0 UP4="$2" UP6="$3" 2>&1)"; rc=$?
  if [[ "$4" == fatal ]]; then
    ((rc != 0)) && grep -q 'FATAL .*metric 100 ahead of the others' <<<"$out" && pass "6 $1 -> FATAL" || fail "6 $1 (rc=$rc): $out"
  else
    ((rc == 0)) && grep -q 'WARN no IPv6 default via enp0s31f6' <<<"$out" && pass "6 $1 -> WARN, OK" || fail "6 $1 (rc=$rc): $out"
  fi
}
lose "no IPv4 default via the NIC" "" "$E6" fatal
lose "IPv4 wired at 20100 (no connectivity)" "${E4/metric 100/metric 20100}" "$E6" fatal
lose "IPv4 another default at metric 50" "$E4\ndefault via 203.0.113.1 dev tun0 metric 50" "$E6" fatal
lose "IPv4 another default at the same metric 100" "$E4\ndefault via 203.0.113.1 dev tun0 metric 100" "$E6" fatal
lose "IPv6 wired at metric 1024" "$E4" "${E6/metric 100/metric 1024}" fatal
lose "no IPv6 default on the wired network" "$E4" "" warn

# 7. red controls
sed 's/route-metric = 100/route-metric = 600/' "$FUNC" >"$T/red1.func.sh"
reset "$T/r7" 0; run "$T/red1.func.sh" "$T/r7" DRY_RUN=0 >/dev/null 2>&1
[[ "$(cat "$(conf "$T/r7")" 2>/dev/null)" == "$want" ]] && fail "7 red control: route-metric = 600 not caught" ||
  pass "7 red control: a wrong metric is caught"
sed 's/install -D -m 0600/install -D -m 0644/' "$FUNC" >"$T/red2.func.sh"
cmp -s "$FUNC" "$T/red2.func.sh" && fail "7 red control: the mode sed did not change the copy"
reset "$T/r7" 0; run "$T/red2.func.sh" "$T/r7" DRY_RUN=0 >/dev/null 2>&1
[[ "$(stat -c %a "$(conf "$T/r7")" 2>/dev/null)" == 600 ]] && fail "7 red control: mode 0644 not caught" ||
  pass "7 red control: a group/other-readable keyfile is caught"
sed 's/nwp_wait_routes "$dev" || return 1/:/' "$FUNC" >"$T/red3.func.sh"
cmp -s "$FUNC" "$T/red3.func.sh" && fail "7 red control: the route sed did not change the copy"
reset "$T/r7" 1; out="$(run "$T/red3.func.sh" "$T/r7" DRY_RUN=0 UP4="${E4/metric 100/metric 20100}" UP6="$E6" 2>&1)" &&
  pass "7 red control: without the route proof a losing wired route passes (case 6 catches it)" ||
  fail "7 red control: the copy without the route proof still refused: $out"

echo "net-wired-priority: $fails failure(s)"
exit $((fails > 0))
