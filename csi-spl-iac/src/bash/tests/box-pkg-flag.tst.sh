#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 142 row B2 -- do_box_pkg_flag, the service-takeover check.
#          Fixtures (box probes measured read-only on 2026-10-17, temp roots
#          and a stubbed systemctl here, nothing read from this box):
#          1. PC 10-16: `Inst systemd-resolved`, `Inst libnss-resolve`,
#             resolv.conf -> NetworkManager           -> 2 FLAG lines
#          2. sat: the same packages, owner systemd-resolved, `resolve` on the
#             hosts: line                              -> 0 FLAG lines
#          3. `Remv network-manager`, NetworkManager active -> 1 FLAG line
#          4. probes passed in (BOX_PKG_OWNERS) and missing inputs (rc 2)
#
#          CONTROLS: the PC case must go red with libnss-resolve dropped from
#          the map (row B2), and cases 1 and 3 must go red against a no-op
#          do_box_pkg_flag: a check that cannot fail proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/../run/box-pkg-flag.func.sh" || { echo "FAIL: cannot source box-pkg-flag.func.sh"; exit 1; }
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ "$1 $2" == "is-active --quiet" ]] || exit 3
[[ " ${STUB_ACTIVE:-} " == *" $3 "* ]]
STUB
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH"

MAP='dns: systemd-resolved libnss-resolve resolvconf openresolv dnsmasq unbound bind9
network: network-manager ifupdown netplan.io connman dhcpcd isc-dhcp-client systemd-networkd
init: systemd-sysv sysvinit-core openrc runit-init
firewall: ufw firewalld nftables iptables-persistent
ssh: openssh-server dropbear'

# mkroot <dir> <resolv.conf link target> <hosts: line>
mkroot() {
  mkdir -p "$1/etc" "$1/sbin"
  ln -s "$2" "$1/etc/resolv.conf"
  printf 'passwd: files systemd\nhosts:          %s\n' "$3" > "$1/etc/nsswitch.conf"
  ln -s /lib/systemd/systemd "$1/sbin/init"
}
mkroot "$tmp/pc" /run/NetworkManager/resolv.conf 'files myhostname mdns4_minimal [NOTFOUND=return] dns'
mkroot "$tmp/sat" /run/systemd/resolve/resolv.conf 'files myhostname resolve [!UNAVAIL=return] dns'

cat > "$tmp/sim-pc" <<'SIM'
NOTE: This is only a simulation!
Inst systemd-resolved (257.9-1~deb13u1 Debian:13.1/stable [amd64])
Inst libnss-resolve (257.9-1~deb13u1 Debian:13.1/stable [amd64])
Conf systemd-resolved (257.9-1~deb13u1 Debian:13.1/stable [amd64])
Conf libnss-resolve (257.9-1~deb13u1 Debian:13.1/stable [amd64])
SIM
cat > "$tmp/sim-sat" <<'SIM'
Inst systemd-resolved [257.8-1~deb13u2] (257.9-1~deb13u1 Debian:13.1/stable [amd64])
Inst libnss-resolve [257.8-1~deb13u2] (257.9-1~deb13u1 Debian:13.1/stable [amd64])
SIM
printf 'Remv network-manager [1.52.1-1]\n' > "$tmp/sim-remv"

PC_WANT='FLAG dns systemd-resolved NetworkManager -> systemd-resolved
FLAG dns libnss-resolve nsswitch:myhostname,mdns4_minimal,dns -> resolve'
SAT_WANT=''
REMV_WANT='FLAG network network-manager network-manager -> none'

# check <label> <sim> <root> <active units> <map> <want>: 0 when the output equals want
check() {
  local out
  out="$(STUB_ACTIVE="$4" BOX_PKG_SIM="$2" BOX_PKG_ROOT="$3" BOX_PKG_SERVICES="$5" do_box_pkg_flag 2>&1)"
  if [[ "$out" == "$6" ]]; then return 0; fi
  printf '  %s: want\n%s\n  got\n%s\n' "$1" "${6:-<none>}" "${out:-<none>}"
  return 1
}
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

case_pc() { check "PC 10-16" "$tmp/sim-pc" "$tmp/pc" "NetworkManager ssh" "${1:-$MAP}" "$PC_WANT"; }
case_sat() { check "sat" "$tmp/sim-sat" "$tmp/sat" "systemd-networkd ssh" "$MAP" "$SAT_WANT"; }
case_remv() { check "Remv" "$tmp/sim-remv" "$tmp/pc" "NetworkManager ssh" "$MAP" "$REMV_WANT"; }

if case_pc; then pass "1 PC 10-16 -> 2 FLAG lines"; else fail "1 PC 10-16 -> 2 FLAG lines"; fi
if case_sat; then pass "2 sat probes -> 0 FLAG lines"; else fail "2 sat probes -> 0 FLAG lines"; fi
if case_remv; then pass "3 Remv network-manager -> 1 FLAG line"; else fail "3 Remv network-manager -> 1 FLAG line"; fi

# 4a: the probes passed in: same verdict as probing the PC root
owners='dns NetworkManager
network network-manager
nsswitch-hosts files myhostname mdns4_minimal [NOTFOUND=return] dns'
out="$(BOX_PKG_SIM="$tmp/sim-pc" BOX_PKG_SERVICES="$MAP" BOX_PKG_OWNERS="$owners" BOX_PKG_ROOT=/nonexistent do_box_pkg_flag 2>&1)"
if [[ "$out" == "$PC_WANT" ]]; then pass "4a BOX_PKG_OWNERS replaces the probes"; else fail "4a BOX_PKG_OWNERS replaces the probes: $out"; fi

# 4b: a missing input is refused with rc 2, never an empty (green-looking) output
rc=0; (BOX_PKG_SIM="$tmp/none" BOX_PKG_SERVICES="$MAP" do_box_pkg_flag >/dev/null 2>&1) || rc=$?
if [[ "$rc" == 2 ]]; then pass "4b missing BOX_PKG_SIM -> rc 2"; else fail "4b missing BOX_PKG_SIM -> rc $rc"; fi
rc=0; (BOX_PKG_SIM="$tmp/sim-pc" BOX_PKG_SERVICES='' do_box_pkg_flag >/dev/null 2>&1) || rc=$?
if [[ "$rc" == 2 ]]; then pass "4b empty BOX_PKG_SERVICES -> rc 2"; else fail "4b empty BOX_PKG_SERVICES -> rc $rc"; fi

# CONTROL 1 (row B2): libnss-resolve dropped from the map -> the PC case is red
if case_pc "${MAP/ libnss-resolve/}" >/dev/null; then
  fail "control: PC case stayed green without libnss-resolve in the map"
else
  pass "control: PC case red without libnss-resolve in the map"
fi

# CONTROL 2: a no-op do_box_pkg_flag -> cases 1 and 3 are red
(
  do_box_pkg_flag() { :; }
  if case_pc >/dev/null || case_remv >/dev/null; then exit 1; fi
) && pass "control: no-op do_box_pkg_flag turns cases 1 and 3 red" ||
  fail "control: a no-op do_box_pkg_flag passed case 1 or 3"

if (( fails )); then echo "box-pkg-flag: $fails FAILED"; exit 1; fi
echo "box-pkg-flag: all PASSED"
