#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_usb_tether_profiles (networking round row 04, SPL-2292)
#   writes the persistent USB-tether NM profile (match by driver, metered,
#   metric 650) and proves its routes sit behind Wi-Fi and take over without it.
#   1. DRY_RUN default: prints the state, the file and the commands; writes no
#      file, runs no reload or up; with a phone it plans the up; only tether
#      drivers count (the e1000e NIC and iwlwifi do not); a bad DRY_RUN, a
#      relative NET_ROOT and a bad NET_WAIT are refused
#   2. DRY_RUN=0, no phone: the keyfile under NET_ROOT holds exactly the plan's
#      profile (metered as 1), mode 0600; nmcli connection reload runs, no up;
#      read-back 50 yes <drivers> 650 650 -> OK; a second run: SAME
#   3. read-back wrong (not loaded, metered unknown) -> FATAL
#   4. phone in, Wi-Fi up: up usb-tether ifname <tether>; tether 650 behind
#      Wi-Fi 600 on IPv4 and IPv6 -> OK
#   5. Wi-Fi gone, or Wi-Fi at +20000 (no internet): the tether carries the
#      traffic -> OK
#   6. the tether default not 650 (e.g. NM's auto-default 100) or missing on
#      IPv4, or not 650 on IPv6 -> FATAL; no IPv6 default via it -> WARN, OK
#   7. red controls: copies writing route-metric = 200, mode 0644, the plan's
#      literal "metered = yes" (NM drops it), and no route proof, each caught
#   The nmcli stub reads the written keyfile the way NM 1.52.1 does for
#   metered (1 -> yes, 2 -> no, anything else, "yes" included -> unknown),
#   measured with nmcli --offline connection modify on the PC.
#   No real /etc, /sys, NetworkManager, route or interface: NET_ROOT, NET_SYS,
#   stubs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/net-usb-tether-profiles.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CALLS="$T/calls" R4="$T/routes4" R6="$T/routes6"
TD=enp0s20f0u1

# nmcli: the read-back parses the written keyfile (CONF) unless NMCLI_SHOW is
# set; "connection up" adds UP4 / UP6 (the routes the tether brings)
cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALLS"
case "$*" in
  "-t -f DEVICE,STATE dev") printf 'wlp0s20f3:connected\nenp0s31f6:unavailable\nenp0s20f0u1:%s\n' "${TD_STATE:-disconnected}" ;;
  "-g connection.autoconnect-priority,connection.metered,match.driver,ipv4.route-metric,ipv6.route-metric connection show usb-tether")
    if [[ -n "${NMCLI_SHOW:-}" ]]; then printf '%b\n' "$NMCLI_SHOW"; exit 0; fi
    [[ -f "$CONF" ]] || { echo "Error: usb-tether - no such connection profile."; exit 10; }
    awk -F' *= *' '
      /^\[/ { s = $0; next }
      s == "[connection]" && $1 == "autoconnect-priority" { p = $2 }
      s == "[connection]" && $1 == "metered" { m = ($2 == "1") ? "yes" : ($2 == "2") ? "no" : "unknown" }
      s == "[match]" && $1 == "driver" { d = $2; sub(/;$/, "", d); gsub(/;/, ",", d) }
      s == "[ipv4]" && $1 == "route-metric" { r4 = $2 }
      s == "[ipv6]" && $1 == "route-metric" { r6 = $2 }
      END { print (p == "" ? 0 : p); print (m == "" ? "unknown" : m); print d; print (r4 == "" ? -1 : r4); print (r6 == "" ? -1 : r6) }' "$CONF" ;;
  "connection up usb-tether ifname enp0s20f0u1")
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
U4='default via 198.51.100.1 dev enp0s20f0u1 proto dhcp src 198.51.100.10 metric 650'
U6='default via fe80::2 dev enp0s20f0u1 proto ra metric 650 pref medium'

# nic <name> <driver> - a /sys/class/net entry bound to <driver>
nic() { mkdir -p "$T/sys/class/net/$1/device" && ln -s "../../../../bus/usb/drivers/$2" "$T/sys/class/net/$1/device/driver"; }
# reset <root> <phone 0|1> [wifi 1|0|penalty] - fresh root, calls, /sys and routes
reset() {
  rm -rf "$1" "$CALLS" "$T/sys" "$R4" "$R6"
  nic enp0s31f6 e1000e; nic wlp0s20f3 iwlwifi; mkdir -p "$T/sys/class/net/lo"
  [[ "$2" == 1 ]] && nic "$TD" cdc_ncm
  : >"$R4"; : >"$R6"
  case "${3:-1}" in
    1) echo "$W4" >"$R4"; echo "$W6" >"$R6" ;;
    penalty) echo "${W4/metric 600/metric 20600}" >"$R4"; echo "${W6/metric 600/metric 20600}" >"$R6" ;;
  esac
  export CONF; CONF="$(conf "$1")"
  return 0
}
# run <func file> <root> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1" root="$2"; shift 2
  env NET_ROOT="$root" NET_SYS="$T/sys" NET_NMCLI="$T/bin/nmcli" NET_IP="$T/bin/ip" NET_SUDO="" NET_WAIT=0 "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_usb_tether_profiles' "$f"
}
want='[connection]
id = usb-tether
type = ethernet
autoconnect = yes
autoconnect-priority = 50
metered = 1

[match]
driver = rndis_host;cdc_ncm;cdc_ether;ipheth;huawei_cdc_ncm;

[ipv4]
method = auto
route-metric = 650

[ipv6]
method = auto
route-metric = 650'
conf() { echo "$1/etc/NetworkManager/system-connections/usb-tether.nmconnection"; }

# 1. dry run
reset "$T/r1" 0; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
if ((rc == 0)) && [[ ! -e "$(conf "$T/r1")" ]] && ! grep -qE 'reload|connection up' "$CALLS" &&
  grep -q 'NOW no USB tether plugged in' <<<"$out" && ! grep -q 'NOW tether' <<<"$out" && grep -q "NOW v4 $W4" <<<"$out" &&
  grep -q 'PLAN write .*usb-tether.nmconnection (0600)' <<<"$out" && grep -q '  route-metric = 650' <<<"$out" &&
  grep -q '  driver = rndis_host;cdc_ncm;cdc_ether;ipheth;huawei_cdc_ncm;' <<<"$out" &&
  grep -q 'PLAN no USB tether plugged in' <<<"$out" && grep -q 'OK DRY_RUN' <<<"$out"; then
  pass "1 DRY_RUN default plans, writes nothing, reloads and activates nothing; e1000e/iwlwifi are no tether"
else fail "1 dry run (rc=$rc): $out"; fi
reset "$T/r1" 1; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
((rc == 0)) && grep -q "NOW tether $TD driver=cdc_ncm state=disconnected" <<<"$out" &&
  grep -q "PLAN .*nmcli connection up usb-tether ifname $TD" <<<"$out" && ! grep -q 'connection up' "$CALLS" &&
  pass "1 DRY_RUN with a phone names it and plans the up, runs none" || fail "1 dry phone (rc=$rc): $out"
out="$(run "$FUNC" "$T/r1" DRY_RUN=yes 2>&1)" && fail "1 DRY_RUN=yes accepted" || pass "1 bad DRY_RUN refused"
out="$(run "$FUNC" "rel" 2>&1)" && fail "1 relative NET_ROOT accepted" || pass "1 relative NET_ROOT refused"
out="$(run "$FUNC" "$T/r1" NET_WAIT=x 2>&1)" && fail "1 NET_WAIT=x accepted" || pass "1 bad NET_WAIT refused"

# 2. apply with no phone, then again
reset "$T/r2" 0; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
f="$(conf "$T/r2")"
if ((rc == 0)) && [[ "$(cat "$f" 2>/dev/null)" == "$want" && "$(stat -c %a "$f")" == 600 ]]; then
  pass "2 DRY_RUN=0 writes the exact keyfile, 0600"
else fail "2 file (rc=$rc): $out / $(cat "$f" 2>&1)"; fi
if grep -qx 'nmcli connection reload' "$CALLS" && ! grep -q 'connection up' "$CALLS" &&
  grep -q 'READ usb-tether autoconnect-priority=50 metered=yes match.driver=rndis_host,cdc_ncm,cdc_ether,ipheth,huawei_cdc_ncm ipv4.route-metric=650 ipv6.route-metric=650' <<<"$out" &&
  grep -q 'OK usb-tether in place; no USB tether plugged in' <<<"$out"; then
  pass "2 reloads NM, reads 50 yes <drivers> 650 650, no phone -> no up"
else fail "2 commands: $(cat "$CALLS") / $out"; fi
out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q "SAME $f" <<<"$out" && pass "2 second run leaves the file" || fail "2 second run (rc=$rc): $out"

# 3. NM does not read it back right
reset "$T/r3" 0; out="$(run "$FUNC" "$T/r3" DRY_RUN=0 NMCLI_SHOW='Error: usb-tether - no such connection profile.' 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL nmcli reads usb-tether as 'Error: usb-tether - no such connection profile.'" <<<"$out" &&
  pass "3 profile not loaded -> FATAL" || fail "3 not loaded (rc=$rc): $out"
reset "$T/r3" 0; out="$(run "$FUNC" "$T/r3" DRY_RUN=0 NMCLI_SHOW='50\nunknown\nrndis_host,cdc_ncm,cdc_ether,ipheth,huawei_cdc_ncm\n650\n650' 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL nmcli reads usb-tether as '50 unknown " <<<"$out" &&
  pass "3 metered unknown -> FATAL" || fail "3 metered (rc=$rc): $out"

# 4. phone in, Wi-Fi up: the tether is the backup on both families
reset "$T/r4" 1; out="$(run "$FUNC" "$T/r4" DRY_RUN=0 UP4="$U4" UP6="$U6" 2>&1)"; rc=$?
if ((rc == 0)) && grep -qx "nmcli connection up usb-tether ifname $TD" "$CALLS" &&
  grep -q "ROUTE v4 $TD metric 650, backup behind wlp0s20f3 metric 600" <<<"$out" &&
  grep -q "ROUTE v6 $TD metric 650, backup behind wlp0s20f3 metric 600" <<<"$out" &&
  grep -qE "UP usb-tether on $TD, routes in [0-9]+s$" <<<"$out" && grep -q "OK usb-tether up on $TD" <<<"$out"; then
  pass "4 phone in: up on the tether, metric 650 behind Wi-Fi 600 (IPv4 + IPv6)"
else fail "4 phone (rc=$rc): $out / $(cat "$CALLS")"; fi

# 5. Wi-Fi gone, or Wi-Fi without internet (+20000): the tether takes over
reset "$T/r5" 1 0; out="$(run "$FUNC" "$T/r5" DRY_RUN=0 UP4="$U4" UP6="$U6" 2>&1)"; rc=$?
((rc == 0)) && grep -q "ROUTE v4 $TD metric 650, carries the traffic$" <<<"$out" &&
  grep -q "ROUTE v6 $TD metric 650, carries the traffic$" <<<"$out" &&
  pass "5 Wi-Fi gone: the tether carries the traffic" || fail "5 Wi-Fi gone (rc=$rc): $out"
reset "$T/r5" 1 penalty; out="$(run "$FUNC" "$T/r5" DRY_RUN=0 UP4="$U4" UP6="$U6" 2>&1)"; rc=$?
((rc == 0)) && grep -q "ROUTE v4 $TD metric 650, carries the traffic (next wlp0s20f3 metric 20600)" <<<"$out" &&
  grep -q "ROUTE v6 $TD metric 650, carries the traffic (next wlp0s20f3 metric 20600)" <<<"$out" &&
  pass "5 Wi-Fi at +20000: the tether carries the traffic" || fail "5 penalty (rc=$rc): $out"

# 6. the tether route is wrong
# lose <label> <up4> <up6> <want: fatal|warn>
lose() {
  reset "$T/r6" 1; out="$(run "$FUNC" "$T/r6" DRY_RUN=0 UP4="$2" UP6="$3" 2>&1)"; rc=$?
  if [[ "$4" == fatal ]]; then
    ((rc != 0)) && grep -q 'FATAL .*metric 650' <<<"$out" && pass "6 $1 -> FATAL" || fail "6 $1 (rc=$rc): $out"
  else
    ((rc == 0)) && grep -q "WARN no IPv6 default via $TD" <<<"$out" && pass "6 $1 -> WARN, OK" || fail "6 $1 (rc=$rc): $out"
  fi
}
lose "no IPv4 default via the tether" "" "$U6" fatal
lose "IPv4 tether at 100 (an auto-default ahead of Wi-Fi)" "${U4/metric 650/metric 100}" "$U6" fatal
lose "IPv6 tether at metric 1024" "$U4" "${U6/metric 650/metric 1024}" fatal
lose "no IPv6 default from the phone" "$U4" "" warn

# 7. red controls
sed 's/route-metric = 650/route-metric = 200/' "$FUNC" >"$T/red1.func.sh"
cmp -s "$FUNC" "$T/red1.func.sh" && fail "7 red control: the metric sed did not change the copy"
reset "$T/r7" 0; out="$(run "$T/red1.func.sh" "$T/r7" DRY_RUN=0 2>&1)"; rc=$?
[[ "$(cat "$(conf "$T/r7")" 2>/dev/null)" != "$want" ]] && ((rc != 0)) &&
  pass "7 red control: route-metric = 200 is caught (file and read-back)" || fail "7 red control: metric 200 not caught (rc=$rc): $out"
sed 's/install -D -m 0600/install -D -m 0644/' "$FUNC" >"$T/red2.func.sh"
cmp -s "$FUNC" "$T/red2.func.sh" && fail "7 red control: the mode sed did not change the copy"
reset "$T/r7" 0; run "$T/red2.func.sh" "$T/r7" DRY_RUN=0 >/dev/null 2>&1
[[ "$(stat -c %a "$(conf "$T/r7")" 2>/dev/null)" == 600 ]] && fail "7 red control: mode 0644 not caught" ||
  pass "7 red control: a group/other-readable keyfile is caught"
sed 's/metered = 1/metered = yes/' "$FUNC" >"$T/red3.func.sh"
cmp -s "$FUNC" "$T/red3.func.sh" && fail "7 red control: the metered sed did not change the copy"
reset "$T/r7" 0; out="$(run "$T/red3.func.sh" "$T/r7" DRY_RUN=0 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL nmcli reads usb-tether as '50 unknown " <<<"$out" &&
  pass "7 red control: the plan's literal 'metered = yes' is caught by the read-back" || fail "7 red control: metered = yes not caught (rc=$rc): $out"
sed 's/nut_wait_routes "$dev" || return 1/:/' "$FUNC" >"$T/red4.func.sh"
cmp -s "$FUNC" "$T/red4.func.sh" && fail "7 red control: the route sed did not change the copy"
reset "$T/r7" 1; out="$(run "$T/red4.func.sh" "$T/r7" DRY_RUN=0 UP4="${U4/metric 650/metric 100}" UP6="$U6" 2>&1)" &&
  pass "7 red control: without the route proof a tether at 100 passes (case 6 catches it)" ||
  fail "7 red control: the copy without the route proof still refused: $out"

echo "net-usb-tether-profiles: $fails failure(s)"
exit $((fails > 0))
