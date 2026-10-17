#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_wlan_ladder (networking round row 05, SPL-2352) puts the
#   saved Wi-Fi profiles named by UUID in the ladder map on their rungs: home
#   10 > hotspot-a 8 > hotspot-b 7 > travel 5, all metric 600, hotspots metered.
#   1. no map: DRY_RUN lists the Wi-Fi profiles (no ethernet one) and says how
#      to write the map, changes nothing; DRY_RUN=0 without a map and a bad
#      DRY_RUN are refused
#   2. DRY_RUN with a map: one PLAN modify per profile off its rung, runs none
#   3. DRY_RUN=0: each profile reads back its rung (home and travel keep their
#      metered value), unmapped profiles untouched; a second run: SAME, no modify
#   4. a bad map (not a UUID, unknown rung, a UUID twice, two homes, an
#      ethernet or unknown UUID, an extra field, no profile) -> FATAL, no modify
#   5. NM does not take a value (metered stays unknown) -> FATAL; the read-back
#      in nmcli's one-line colon form is read the same
#   6. no SSID in any output: the profile names (made-up SSIDs) never appear
#   7. red controls: copies with hotspot-a at 9, without metered on the
#      hotspots, travel at 6, and reading the NAME field, each caught
#   No real NetworkManager: a stub nmcli on a state dir, made-up UUIDs and
#   SSIDs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/net-wlan-ladder.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CALLS="$T/calls" NM="$T/nm"
HOME_U=11111111-1111-4111-8111-111111111111
HSA_U=22222222-2222-4222-8222-222222222222
HSB_U=33333333-3333-4333-8333-333333333333
TR1_U=44444444-4444-4444-8444-444444444444
TR2_U=55555555-5555-4555-8555-555555555555
OLD_U=66666666-6666-4666-8666-666666666666
ETH_U=77777777-7777-4777-8777-777777777777

# nmcli: one file per profile under $NM: "name type prio metered r4 r6 active"
cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALLS"
case "$*" in
  "-t -f UUID,TYPE,AUTOCONNECT-PRIORITY,ACTIVE connection show")
    for f in "$NM"/*; do read -r n t p m r4 r6 a <"$f"; echo "${f##*/}:$t:$p:$a"; done ;;
  "-t -f NAME,UUID,TYPE,AUTOCONNECT-PRIORITY,ACTIVE connection show")
    for f in "$NM"/*; do read -r n t p m r4 r6 a <"$f"; echo "$n:${f##*/}:$t:$p:$a"; done ;;
  "-g connection.autoconnect-priority,connection.metered,ipv4.route-metric,ipv6.route-metric connection show uuid "*)
    u="${*: -1}"; f="$NM/$u"
    [[ -f "$f" ]] || { echo "Error: $u - no such connection profile."; exit 10; }
    read -r n t p m r4 r6 a <"$f"
    if [[ -n "${NMCLI_COLON:-}" ]]; then echo "$p:$m:$r4:$r6"; else printf '%s\n' "$p" "$m" "$r4" "$r6"; fi ;;
  "connection modify uuid "*)
    shift 3; f="$NM/$1"; shift
    [[ -f "$f" ]] || exit 10
    read -r n t p m r4 r6 a <"$f"
    while (($# >= 2)); do
      case "$1" in
        connection.autoconnect-priority) p="$2" ;;
        connection.metered) [[ -n "${NM_DROPS_METERED:-}" ]] || m="$2" ;;
        ipv4.route-metric) r4="$2" ;;
        ipv6.route-metric) r6="$2" ;;
        *) exit 2 ;;
      esac
      shift 2
    done
    echo "$n $t $p $m $r4 $r6 $a" >"$f" ;;
esac
exit 0
EOF
chmod +x "$T/bin/nmcli"

# reset - fresh profiles (names are made-up SSIDs the output must never show)
reset() {
  rm -rf "$NM" "$CALLS"; mkdir -p "$NM"; : >"$CALLS"
  echo "SSID-HOME-x1 802-11-wireless 0 unknown -1 -1 yes" >"$NM/$HOME_U"
  echo "SSID-PHONE-A-x2 802-11-wireless 0 unknown -1 -1 no" >"$NM/$HSA_U"
  echo "SSID-PHONE-B-x3 802-11-wireless 0 no -1 -1 no" >"$NM/$HSB_U"
  echo "SSID-HOTEL-x4 802-11-wireless 0 no -1 -1 no" >"$NM/$TR1_U"
  echo "SSID-CAFE-x5 802-11-wireless 3 unknown 600 600 no" >"$NM/$TR2_U"
  echo "SSID-OLD-x6 802-11-wireless 0 unknown -1 -1 no" >"$NM/$OLD_U"
  echo "Wired-x7 802-3-ethernet 100 unknown 100 100 no" >"$NM/$ETH_U"
}
MAP="$T/ladder.tsv"
printf '# made-up ladder\n%s home\n%s hotspot-a\n\n%s hotspot-b\n%s travel\n%s travel\n' \
  "$HOME_U" "$HSA_U" "$HSB_U" "$TR1_U" "$TR2_U" >"$MAP"
# run <func file> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1"; shift
  env NET_NMCLI="$T/bin/nmcli" NET_SUDO="" NET_WLAN_LADDER_FILE="$MAP" "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_wlan_ladder' "$f"
}
# state <uuid> - "prio metered r4 r6"
state() { awk '{print $3, $4, $5, $6}' "$NM/$1"; }
no_ssid() { ! grep -qE 'SSID-|Wired-x7' <<<"$1"; }
ladder_ok() {
  [[ "$(state "$HOME_U")" == "10 unknown 600 600" && "$(state "$HSA_U")" == "8 yes 600 600" &&
    "$(state "$HSB_U")" == "7 yes 600 600" && "$(state "$TR1_U")" == "5 no 600 600" &&
    "$(state "$TR2_U")" == "5 unknown 600 600" && "$(state "$OLD_U")" == "0 unknown -1 -1" &&
    "$(state "$ETH_U")" == "100 unknown 100 100" ]]
}

# 1. no map
reset; out="$(run "$FUNC" NET_WLAN_LADDER_FILE="$T/none.tsv" 2>&1)"; rc=$?
if ((rc == 0)) && ! grep -q 'connection modify' "$CALLS" && grep -q "NOW wifi $HOME_U priority=0 active=yes rung=unmapped" <<<"$out" &&
  [[ "$(grep -c '^NOW wifi' <<<"$out")" == 6 ]] && ! grep -q "$ETH_U" <<<"$out" &&
  grep -q "PLAN no ladder map at $T/none.tsv" <<<"$out" && grep -q 'OK DRY_RUN nothing was touched' <<<"$out"; then
  pass "1 no map: DRY_RUN lists the 6 Wi-Fi profiles (not the ethernet one), says how to write the map, changes nothing"
else fail "1 no map (rc=$rc): $out"; fi
out="$(run "$FUNC" NET_WLAN_LADDER_FILE="$T/none.tsv" DRY_RUN=0 2>&1)" && fail "1 DRY_RUN=0 without a map accepted" ||
  { grep -q 'FATAL no ladder map' <<<"$out" && pass "1 DRY_RUN=0 without a map refused" || fail "1 no map apply: $out"; }
out="$(run "$FUNC" DRY_RUN=yes 2>&1)" && fail "1 DRY_RUN=yes accepted" || pass "1 bad DRY_RUN refused"

# 2. dry run with the map
reset; out="$(run "$FUNC" 2>&1)"; rc=$?
if ((rc == 0)) && ! grep -q 'connection modify' "$CALLS" &&
  grep -q "PLAN .*nmcli connection modify uuid $HOME_U connection.autoconnect-priority 10 ipv4.route-metric 600 ipv6.route-metric 600 (now 0 unknown -1 -1)" <<<"$out" &&
  grep -q "PLAN .*nmcli connection modify uuid $HSA_U connection.autoconnect-priority 8 connection.metered yes ipv4.route-metric 600 ipv6.route-metric 600" <<<"$out" &&
  grep -q "PLAN .*nmcli connection modify uuid $HSB_U connection.autoconnect-priority 7 connection.metered yes ipv4.route-metric 600 ipv6.route-metric 600" <<<"$out" &&
  grep -q "PLAN .*nmcli connection modify uuid $TR2_U connection.autoconnect-priority 5 ipv4.route-metric 600" <<<"$out" &&
  grep -q "NOW wifi $OLD_U priority=0 active=no rung=unmapped" <<<"$out" && grep -q "NOW wifi $HSB_U priority=0 active=no rung=hotspot-b" <<<"$out" &&
  grep -q 'OK DRY_RUN 5 profile(s) to change, nothing was touched' <<<"$out" && [[ "$(state "$HOME_U")" == "0 unknown -1 -1" ]]; then
  pass "2 DRY_RUN plans one modify per mapped profile, runs none"
else fail "2 dry run (rc=$rc): $out / $(cat "$CALLS")"; fi

# 3. apply, then again
reset; out="$(run "$FUNC" DRY_RUN=0 2>&1)"; rc=$?
if ((rc == 0)) && ladder_ok && [[ "$(grep -c 'connection modify' "$CALLS")" == 5 ]] &&
  grep -q "READ $HSA_U hotspot-a (8 yes 600 600)" <<<"$out" && grep -q "READ $HOME_U home (10 unknown 600 600)" <<<"$out" &&
  grep -q 'OK the Wi-Fi ladder is in place (5 profile(s), 5 changed)' <<<"$out"; then
  pass "3 DRY_RUN=0 puts each profile on its rung, hotspots metered, home/travel metered kept, unmapped and ethernet untouched"
else fail "3 apply (rc=$rc): $out / $(for u in "$NM"/*; do echo "${u##*/} $(state "${u##*/}")"; done)"; fi
: >"$CALLS"; out="$(run "$FUNC" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && ! grep -q 'connection modify' "$CALLS" && [[ "$(grep -c '^SAME ' <<<"$out")" == 5 ]] &&
  grep -q '(5 profile(s), 0 changed)' <<<"$out" && pass "3 second run: all SAME, no modify" || fail "3 second run (rc=$rc): $out"

# 4. bad maps
# badmap <label> <map text> <FATAL text>
badmap() {
  reset; printf '%b' "$2" >"$T/bad.tsv"
  out="$(run "$FUNC" DRY_RUN=0 NET_WLAN_LADDER_FILE="$T/bad.tsv" 2>&1)"; rc=$?
  ((rc != 0)) && grep -q "FATAL .*$3" <<<"$out" && ! grep -q 'connection modify' "$CALLS" &&
    pass "4 $1 -> FATAL, no modify" || fail "4 $1 (rc=$rc): $out"
}
badmap "not a UUID" "home-wifi home\n" "not a profile UUID"
badmap "unknown rung" "$HOME_U office\n" "rung must be home, hotspot-a, hotspot-b or travel"
badmap "a UUID twice" "$TR1_U travel\n$TR1_U travel\n" "mapped twice"
badmap "two homes" "$HOME_U home\n$TR1_U home\n" "rung home takes one profile"
badmap "an ethernet UUID" "$ETH_U travel\n" "no saved Wi-Fi profile"
badmap "an unknown UUID" "88888888-8888-4888-8888-888888888888 travel\n" "no saved Wi-Fi profile"
badmap "an extra field" "$HOME_U home 10\n" "got more fields"
badmap "no profile" "# empty\n" "maps no profile"

# 5. NM does not take it; the colon read-back form
reset; out="$(run "$FUNC" DRY_RUN=0 NM_DROPS_METERED=1 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL nmcli reads $HSA_U as '8 unknown 600 600', not rung hotspot-a (8 yes 600 600)" <<<"$out" &&
  pass "5 metered not taken -> FATAL" || fail "5 dropped metered (rc=$rc): $out"
reset; out="$(run "$FUNC" DRY_RUN=0 NMCLI_COLON=1 2>&1)"; rc=$?
((rc == 0)) && ladder_ok && grep -q "READ $HSB_U hotspot-b (7 yes 600 600)" <<<"$out" &&
  pass "5 the one-line colon read-back reads the same" || fail "5 colon form (rc=$rc): $out"

# 6. no SSID anywhere
reset; o1="$(run "$FUNC" NET_WLAN_LADDER_FILE="$T/none.tsv" 2>&1)"; o2="$(run "$FUNC" 2>&1)"; o3="$(run "$FUNC" DRY_RUN=0 2>&1)"
no_ssid "$o1$o2$o3" && pass "6 no profile name / SSID in any output" || fail "6 SSID leaked: $o1 $o2 $o3"

# 7. red controls
# red <label> <sed> <check: ladder|ssid>
red() {
  sed "$2" "$FUNC" >"$T/red.func.sh"
  cmp -s "$FUNC" "$T/red.func.sh" && { fail "7 red control $1: the sed did not change the copy"; return; }
  reset; out="$(run "$T/red.func.sh" DRY_RUN=0 2>&1)"
  if [[ "$3" == ssid ]]; then no_ssid "$out" && fail "7 red control $1: not caught" || pass "7 red control $1 is caught"
  else ladder_ok && fail "7 red control $1: not caught" || pass "7 red control $1 is caught"; fi
}
red "hotspot-a at 9" 's/hotspot-a) echo "8 yes"/hotspot-a) echo "9 yes"/' ladder
red "hotspots not metered" 's/m=" connection.metered yes"/m=""/' ladder
red "travel at 6" 's/travel) echo "5 -"/travel) echo "6 -"/' ladder
red "reading the NAME field" 's/-t -f UUID,TYPE,AUTOCONNECT-PRIORITY,ACTIVE/-t -f NAME,UUID,TYPE,AUTOCONNECT-PRIORITY,ACTIVE/; s/{print \$1, \$3, \$4}/{print \$2, \$4, \$5; print "seen " $1}/; s/\$2 == "802-11-wireless"/$3 == "802-11-wireless"/' ssid

echo "net-wlan-ladder: $fails failure(s)"
exit $((fails > 0))
