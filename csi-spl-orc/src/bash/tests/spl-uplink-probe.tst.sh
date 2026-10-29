#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_uplink_probe takes one uplink sample (gateway ping, hub DNS,
#   hub TCP 443) and UPLINK_PROBE_CMD=report merges consecutive down samples
#   into outage windows (a box's drops, 2026-10-12).
#   1. an up sample: one TSV line `ts 0 1 ms 1 ms wlan0`, rc 0
#   2. a down sample (ping 100% loss, getent and tcp fail): `100 0 .. 0`, rc 0
#   3. no default route: loss 100, iface -; no hub host (cnf unreadable):
#      dns/tcp `-`, and the report does not count that as an outage
#   4. the hub host is the cnf's env.dns.api_fqdn, the host of the desk's
#      SPL_HUB_URL (do_spl_desk_cnf)
#   5. report: 3 down probe samples in a row = 1 window of 3; up/down/up
#      fixture = 2 windows, longest 2; an all-up file = 0 windows (control);
#      gateway 100% loss with DNS and TCP fine is NOT down (a cloud VM's
#      gateway may drop ICMP), only counted as gw_loss_100
#   6. red controls: a copy whose merge opens a window per down sample, and
#      a copy that counts gateway loss alone as down, are each caught
#   7. samples older than 7 days are dropped
#   8. bad UPLINK_PROBE_CMD / UPLINK_PROBE_HOURS are refused
#   9. the manifest row and the cron script: executable, exits 0 with the
#      link down, refuses a worktree unless allowed
#  10. UPLINK_PROBE_CMD=dns (the spawn gate, SPL-4253): resolves -> `ok` rc 0,
#      no answer -> `FAIL <host>` rc 1, a hanging lookup is cut at
#      UPLINK_DNS_TIMEOUT_S, no host -> `unknown` rc 0; no sample is written
#   No real ping, DNS or TCP: every network call is a stub via env.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/spl-uplink-probe.func.sh"
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }

B="$T/bin"; mkdir -p "$B"
printf '#!/bin/sh\necho "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.10 metric 600"\n' >"$B/route"
printf '#!/bin/sh\n' >"$B/route-none"
printf '#!/bin/sh\necho "3 packets transmitted, 3 received, 0%% packet loss, time 2003ms"\n' >"$B/ping-up"
printf '#!/bin/sh\necho "3 packets transmitted, 0 received, 100%% packet loss, time 2040ms"\nexit 1\n' >"$B/ping-down"
printf '#!/bin/sh\necho "192.0.2.80 $2"\n' >"$B/getent-up"
printf '#!/bin/sh\nexit 2\n' >"$B/getent-down"
printf '#!/bin/sh\nexit 0\n' >"$B/tcp-up"
printf '#!/bin/sh\nexit 1\n' >"$B/tcp-down"
chmod +x "$B"/*
D="$T/probe"
NOW=1791820800   # 2026-10-12T16:00:00Z

UP=(UPLINK_ROUTE_CMD="$B/route" UPLINK_PING_CMD="$B/ping-up" UPLINK_GETENT_CMD="$B/getent-up" UPLINK_TCP_CMD="$B/tcp-up")
DOWN=(UPLINK_ROUTE_CMD="$B/route" UPLINK_PING_CMD="$B/ping-down" UPLINK_GETENT_CMD="$B/getent-down" UPLINK_TCP_CMD="$B/tcp-down")

# probe [VAR=value]... - one do_spl_uplink_probe in a fresh orc shell
probe() { SNIPPET='do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$D" UPLINK_PROBE_BOX=bx UPLINK_HUB_HOST=hub.invalid "$@" 2>&1; }
last() { tail -n 1 "$D/bx.tsv" | cut -f2-3,5,7; }
tab() { local IFS=$'\t'; echo "$*"; }

# 1. up
out="$(probe "${UP[@]}" UPLINK_PROBE_NOW=$NOW)"; rc=$?
[[ $rc -eq 0 && "$(last)" == "$(tab 0 1 1 wlan0)" && "$(tail -n 1 "$D/bx.tsv" | cut -f1)" == 2026-10-12T16:00:00Z ]] &&
  pass "1. up sample: 0% loss, dns 1, tcp 1, wlan0, rc 0" || fail "1. up (rc $rc): $out / $(cat "$D/bx.tsv" 2>&1)"

# 2. down
out="$(probe "${DOWN[@]}" UPLINK_PROBE_NOW=$((NOW + 60)))"; rc=$?
[[ $rc -eq 0 && "$(last)" == "$(tab 100 0 0 wlan0)" ]] &&
  pass "2. down sample: 100% loss, dns 0, tcp 0, still rc 0" || fail "2. down (rc $rc): $out / $(last)"

# 3. no route, no hub host
out="$(probe "${UP[@]}" UPLINK_ROUTE_CMD="$B/route-none" UPLINK_PROBE_NOW=$((NOW + 120)))"; rc=$?
[[ $rc -eq 0 && "$(last)" == "$(tab 100 1 1 -)" ]] &&
  pass "3a. no default route: loss 100, iface -" || fail "3a. no route (rc $rc): $out / $(last)"
out="$(SNIPPET='do_spl_cloud_cnf() { return 1; }; do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$T/nohost" UPLINK_PROBE_BOX=bx \
  "${UP[@]}" UPLINK_PROBE_NOW=$NOW 2>&1)"; rc=$?
rep="$(SNIPPET='do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$T/nohost" UPLINK_PROBE_BOX=bx UPLINK_PROBE_CMD=report UPLINK_PROBE_NOW=$NOW 2>&1)"
[[ $rc -eq 0 && "$(cut -f2-3,5 "$T/nohost/bx.tsv")" == "$(tab 0 - -)" && "$out" == *WARN* && "$rep" == *"1 samples, 0 outage windows"* ]] &&
  pass "3b. no hub host: dns/tcp '-', a WARN, not an outage" || fail "3b. no host (rc $rc): $out / $rep"

# 4. the cnf host
out="$(SNIPPET='h="$(spl_uplink_hub_host)"; do_spl_desk_cnf >/dev/null 2>&1; echo "host=$h url=$SPL_HUB_URL"' in_orc ENV=prd 2>&1)"
h="${out#host=}"; h="${h%% *}"
[[ "$h" =~ ^[a-z0-9.-]+\.[a-z]+$ && "$out" == *" url=https://$h" ]] &&
  pass "4. hub host = cnf env.dns.api_fqdn = the desk's SPL_HUB_URL host" || fail "4. cnf host: $out"

# 5. report
rm -f "$D/bx.tsv"
for i in 0 1 2; do probe "${DOWN[@]}" UPLINK_PROBE_NOW=$((NOW + i * 60)) >/dev/null; done
REPORT=(UPLINK_PROBE_CMD=report UPLINK_PROBE_NOW=$((NOW + 600)))
win3_ok() {
  [[ "$1" == *"3 samples, 1 outage windows, longest 3 samples (2026-10-12T16:00:00Z .. 2026-10-12T16:02:00Z)"* &&
     "$1" == *"  2026-10-12T16:00:00Z .. 2026-10-12T16:02:00Z  3 samples  gw_down=3 dns_fail=3 tcp_fail=3"* ]]
}
out="$(probe "${REPORT[@]}")"; rc=$?
[[ $rc -eq 0 ]] && win3_ok "$out" && pass "5a. report merges 3 down probe samples into 1 window of 3" || fail "5a. merge (rc $rc): $out"

F="$T/fix"; mkdir -p "$F"
{
  tab 2026-10-12T15:00:00Z 0 1 5 1 30 wlan0
  tab 2026-10-12T15:01:00Z 100 1 5 1 30 wlan0
  tab 2026-10-12T15:02:00Z 0 0 5000 0 0 wlan0
  tab 2026-10-12T15:03:00Z 0 1 5 0 5000 wlan0
  tab 2026-10-12T15:04:00Z 0 1 5 1 30 wlan0
  tab 2026-10-12T15:05:00Z 33 0 5000 1 30 wlan0
  tab 2026-10-12T15:06:00Z 33 1 5 1 30 wlan0
} >"$F/bx.tsv"
out="$(SNIPPET='do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$F" UPLINK_PROBE_BOX=bx "${REPORT[@]}" 2>&1)"
[[ "$out" == *"7 samples, 2 outage windows, longest 2 samples (2026-10-12T15:02:00Z .. 2026-10-12T15:03:00Z); gw_loss_100=1 samples"* &&
   "$out" == *"15:02:00Z .. 2026-10-12T15:03:00Z  2 samples  gw_down=0 dns_fail=1 tcp_fail=2"* &&
   "$out" == *"15:05:00Z .. 2026-10-12T15:05:00Z  1 samples  gw_down=0 dns_fail=1 tcp_fail=0"* ]] &&
  pass "5b. up/down/up: 2 windows, longest 2, which check failed per window; gw loss counted apart" || fail "5b. fixture: $out"
out="$(SNIPPET='do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$F" UPLINK_PROBE_BOX=bx UPLINK_PROBE_CMD=report UPLINK_PROBE_HOURS=1 UPLINK_PROBE_NOW=$((NOW + 7200)) 2>&1)"
[[ "$out" == *"0 samples, 0 outage windows"* ]] && pass "5c. UPLINK_PROBE_HOURS=1: samples before the window are not counted" || fail "5c. cutoff: $out"
{ tab 2026-10-12T15:00:00Z 0 1 5 1 30 wlan0; tab 2026-10-12T15:01:00Z 33 1 5 1 30 wlan0; } >"$F/up.tsv"
out="$(SNIPPET='do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$F" UPLINK_PROBE_BOX=up "${REPORT[@]}" 2>&1)"
[[ "$out" == *"2 samples, 0 outage windows"* && "$out" != *" .. "* ]] &&
  pass "5d. up control: an all-up file reports no window" || fail "5d. up control: $out"

# 5e. gateway 100% loss with DNS and TCP fine (sat 2026-10-12T17:52:06Z)
G="$T/gw"; mkdir -p "$G"
{ tab 2026-10-12T15:00:00Z 100 1 9 1 10 ens4; tab 2026-10-12T15:01:00Z 100 1 9 1 10 ens4; } >"$G/bx.tsv"
gw_ok() { [[ "$1" == *"2 samples, 0 outage windows; gw_loss_100=2 samples"* && "$1" != *" .. "* ]]; }
out="$(SNIPPET='do_spl_uplink_probe' in_orc UPLINK_PROBE_DIR="$G" UPLINK_PROBE_BOX=bx "${REPORT[@]}" 2>&1)"
gw_ok "$out" && pass "5e. gw 100% loss, dns ok, tcp ok: no outage window, gw_loss_100=2" || fail "5e. gw-only: $out"
BADGW="$T/badgw.func.sh"
sed 's/down = (\$3 == "0"/down = ($2 == 100 || $3 == "0"/' "$FUNC" >"$BADGW"
if cmp -s "$FUNC" "$BADGW"; then
  fail "6b. red control: the gw mutation did not apply"
else
  out="$(SNIPPET="source '$BADGW'; do_spl_uplink_probe" in_orc UPLINK_PROBE_DIR="$G" UPLINK_PROBE_BOX=bx "${REPORT[@]}" 2>&1)"
  gw_ok "$out" && fail "6b. red control: gw loss counted as down passed the 5e check: $out" ||
    pass "6b. red control: a report that counts gw loss alone as down fails the 5e check"
fi

# 6. red control: a broken merge (each down sample its own window)
BAD="$T/bad.func.sh"
sed 's/if (!open) { open = 1; ws = \$1/close_window(); if (1) { open = 1; ws = $1/' "$FUNC" >"$BAD"
if cmp -s "$FUNC" "$BAD"; then
  fail "6. red control: the mutation did not apply"
else
  out="$(SNIPPET="source '$BAD'; do_spl_uplink_probe" in_orc UPLINK_PROBE_DIR="$D" UPLINK_PROBE_BOX=bx "${REPORT[@]}" 2>&1)"
  win3_ok "$out" && fail "6. red control: a broken merge passed the 5a check: $out" ||
    pass "6. red control: a broken merge (3 windows of 1) fails the 5a check"
fi

# 7. retention
R="$T/ret"; mkdir -p "$R"
{ tab 2026-10-04T15:59:00Z 0 1 5 1 30 wlan0; tab 2026-10-06T00:00:00Z 0 1 5 1 30 wlan0; } >"$R/bx.tsv"
probe "${UP[@]}" UPLINK_PROBE_DIR="$R" UPLINK_PROBE_NOW=$NOW >/dev/null
[[ "$(cut -f1 "$R/bx.tsv" | tr '\n' ' ')" == "2026-10-06T00:00:00Z 2026-10-12T16:00:00Z " ]] &&
  pass "7. samples older than 7 days are dropped" || fail "7. retention: $(cat "$R/bx.tsv")"

# 8. refusals
out="$(probe UPLINK_PROBE_CMD=bogus)"; rc=$?
[[ $rc -ne 0 && "$out" == *FATAL* ]] && pass "8a. UPLINK_PROBE_CMD=bogus is refused" || fail "8a. (rc $rc): $out"
out="$(probe UPLINK_PROBE_CMD=report UPLINK_PROBE_HOURS=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *FATAL* ]] && pass "8b. UPLINK_PROBE_HOURS=0 is refused" || fail "8b. (rc $rc): $out"

# 9. manifest row + cron script
M="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
CRON="$PROJ_ROOT/src/bash/scripts/uplink-probe-cron.sh"
grep -qE '^uplink-probe +\| \* \* \* \* \* +\| src/bash/scripts/uplink-probe-cron.sh +\| uplink-probe/cron.log' "$M" && [[ -x "$CRON" ]] &&
  pass "9a. manifest row uplink-probe, every minute, executable script" || fail "9a. manifest row / script"
C="$T/cron"
out="$(env "${DOWN[@]}" UPLINK_PROBE_DIR="$C" UPLINK_PROBE_BOX=bx UPLINK_HUB_HOST=hub.invalid UPLINK_PROBE_ALLOW_WORKTREE=1 bash "$CRON" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cut -f2-3,5 "$C/bx.tsv" 2>/dev/null)" == "$(tab 100 0 0)" && "$out" == *"uplink-probe "*"gw_loss=100%"* ]] &&
  pass "9b. the cron script samples a down link and exits 0" || fail "9b. cron (rc $rc): $out"
case "$PROJ_ROOT" in
  *-wt/*)
    out="$(env "${UP[@]}" UPLINK_PROBE_DIR="$C" UPLINK_HUB_HOST=hub.invalid bash "$CRON" 2>&1)"; rc=$?
    [[ $rc -eq 2 && "$out" == *"agent worktree"* ]] && pass "9c. the cron script refuses a worktree" || fail "9c. worktree (rc $rc): $out" ;;
  *) pass "9c. (not in a worktree: refusal not exercised)" ;;
esac

# 10. dns mode
printf '#!/bin/sh\nsleep 30\n' >"$B/getent-hang"; chmod +x "$B/getent-hang"
N="$T/dnsmode"
out="$(probe UPLINK_PROBE_DIR="$N" UPLINK_PROBE_CMD=dns UPLINK_GETENT_CMD="$B/getent-up")"; rc=$?
[[ $rc -eq 0 && "$out" == *"uplink-dns ok hub.invalid "* && ! -e "$N/bx.tsv" ]] &&
  pass "10a. dns: resolves -> ok, rc 0, no sample" || fail "10a. (rc $rc): $out"
out="$(probe UPLINK_PROBE_DIR="$N" UPLINK_PROBE_CMD=dns UPLINK_GETENT_CMD="$B/getent-down")"; rc=$?
[[ $rc -eq 1 && "$out" == *"uplink-dns FAIL hub.invalid"* && ! -e "$N/bx.tsv" ]] &&
  pass "10b. dns: no answer -> FAIL <host>, rc 1" || fail "10b. (rc $rc): $out"
t0=$SECONDS
out="$(probe UPLINK_PROBE_DIR="$N" UPLINK_PROBE_CMD=dns UPLINK_DNS_TIMEOUT_S=1 UPLINK_GETENT_CMD="$B/getent-hang")"; rc=$?
[[ $rc -eq 1 && "$out" == *"within 1s"* && $((SECONDS - t0)) -lt 15 ]] &&
  pass "10c. dns: a hanging lookup is cut at UPLINK_DNS_TIMEOUT_S" || fail "10c. (rc $rc, $((SECONDS - t0)) s): $out"
out="$(SNIPPET='do_spl_cloud_cnf() { return 1; }; do_spl_uplink_probe' in_orc UPLINK_PROBE_CMD=dns UPLINK_GETENT_CMD="$B/getent-down" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"uplink-dns unknown"* ]] &&
  pass "10d. dns: no hub host -> unknown, rc 0 (not a network fault)" || fail "10d. (rc $rc): $out"

echo
if [ "$fails" -eq 0 ]; then echo "spl-uplink-probe: all passed"; exit 0; fi
echo "spl-uplink-probe: $fails FAILED"; exit 1
