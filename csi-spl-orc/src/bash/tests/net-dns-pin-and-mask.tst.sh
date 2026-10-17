#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_dns_pin_and_mask (networking round row 06, SPL-2362) pins
#   NM's DNS mode (dns=default, rc-manager=symlink) and masks systemd-resolved.
#   1. DRY_RUN default: prints the state, the file and the commands; writes no
#      file, runs no mask or reload; a bad DRY_RUN and a relative NET_ROOT are
#      refused
#   2. DRY_RUN=0: the conf.d file under NET_ROOT holds exactly the plan's
#      lines, mode 0644; systemctl mask systemd-resolved and nmcli general
#      reload conf run; read-back masked, dns=default rc-manager=symlink,
#      resolv.conf -> /run/NetworkManager/resolv.conf -> OK; a second run:
#      SAME file, SAME masked, no second mask; a purged unit (is-enabled
#      not-found) is masked too
#   3. the refusal (dry run and DRY_RUN=0): resolv.conf a regular file, a
#      symlink to resolved's stub, missing; systemd-resolved active or
#      activating -> FATAL, no file, no mask, no reload
#   4. read-back misses: another conf.d file wins (rc-manager=file), the unit
#      not masked after the mask, resolv.conf replaced on reload -> FATAL
#   5. red controls: a copy without the refusal, a copy writing
#      rc-manager = file and a copy without the mask are each caught
#   No real /etc, NetworkManager or systemd: NET_ROOT, stubs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/net-dns-pin-and-mask.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CALLS="$T/calls" ST="$T/state"
NMLINK=/run/NetworkManager/resolv.conf

# systemctl: the unit's words live in $ST/enabled and $ST/active; the exit
# codes follow systemctl(1) (is-enabled 1 on masked/disabled, is-active 3)
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$CALLS"
case "$*" in
  "is-enabled systemd-resolved") w="$(cat "$ST/enabled")"; echo "$w"; [[ "$w" == enabled ]] ;;
  "is-active systemd-resolved") w="$(cat "$ST/active")"; echo "$w"; [[ "$w" == active ]] || exit 3 ;;
  "mask systemd-resolved") [[ -n "${MASK_NOOP:-}" ]] || echo masked >"$ST/enabled" ;;
  *) exit 1 ;;
esac
EOF
# nmcli: RELOAD_BREAKS=1 makes the reload point resolv.conf at resolved's stub
cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALLS"
[[ "$*" == "general reload conf" && -n "${RELOAD_BREAKS:-}" ]] &&
  ln -sfn /run/systemd/resolve/stub-resolv.conf "$NET_ROOT/etc/resolv.conf"
exit 0
EOF
# NetworkManager --print-config: PRINT_CONFIG, else the pin file without spaces
cat >"$T/bin/NetworkManager" <<'EOF'
#!/usr/bin/env bash
echo "NetworkManager $*" >>"$CALLS"
[[ "$*" == --print-config ]] || exit 1
if [[ -n "${PRINT_CONFIG:-}" ]]; then printf '%b\n' "$PRINT_CONFIG"; exit 0; fi
echo '# NetworkManager configuration'
f="$NET_ROOT/etc/NetworkManager/conf.d/10-dns-pin.conf"
if [[ -f "$f" ]]; then sed 's/ = /=/' "$f"; else echo '[main]'; fi
EOF
chmod +x "$T/bin/systemctl" "$T/bin/nmcli" "$T/bin/NetworkManager"

# reset <root> <resolv: nm|stub|file|none> [active] [enabled] - fresh root, calls, unit
reset() {
  rm -rf "$1" "$CALLS" "$ST"; mkdir -p "$1/etc" "$ST"
  case "$2" in
    nm) ln -s "$NMLINK" "$1/etc/resolv.conf" ;;
    stub) ln -s /run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf" ;;
    file) echo 'nameserver 192.0.2.53' >"$1/etc/resolv.conf" ;;
  esac
  echo "${3:-inactive}" >"$ST/active"; echo "${4:-disabled}" >"$ST/enabled"
  : >"$CALLS"
}
# run <func file> <root> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1" root="$2"; shift 2
  env NET_ROOT="$root" NET_NMCLI="$T/bin/nmcli" NET_SYSTEMCTL="$T/bin/systemctl" NET_NM="$T/bin/NetworkManager" NET_SUDO="" "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_dns_pin_and_mask' "$f"
}
want='[main]
dns = default
rc-manager = symlink'
conf() { echo "$1/etc/NetworkManager/conf.d/10-dns-pin.conf"; }

# 1. dry run
reset "$T/r1" nm; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
if ((rc == 0)) && [[ ! -e "$(conf "$T/r1")" ]] && ! grep -qE 'mask|reload' "$CALLS" &&
  grep -q "NOW resolv.conf -> $NMLINK systemd-resolved is-active=inactive is-enabled=disabled" <<<"$out" &&
  grep -q 'PLAN write .*10-dns-pin.conf (0644):' <<<"$out" && grep -q '  rc-manager = symlink' <<<"$out" &&
  grep -q 'PLAN .*systemctl mask systemd-resolved' <<<"$out" && grep -q 'PLAN .*nmcli general reload conf' <<<"$out" &&
  grep -q 'OK DRY_RUN' <<<"$out" && [[ "$(cat "$ST/enabled")" == disabled ]]; then
  pass "1 DRY_RUN default plans, writes nothing, masks and reloads nothing"
else fail "1 dry run (rc=$rc): $out / $(cat "$CALLS")"; fi
out="$(run "$FUNC" "$T/r1" DRY_RUN=yes 2>&1)" && fail "1 DRY_RUN=yes accepted" || pass "1 bad DRY_RUN refused"
out="$(run "$FUNC" "rel" 2>&1)" && fail "1 relative NET_ROOT accepted" || pass "1 relative NET_ROOT refused"

# 2. apply, then again
reset "$T/r2" nm; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
f="$(conf "$T/r2")"
if ((rc == 0)) && [[ "$(cat "$f" 2>/dev/null)" == "$want" && "$(stat -c %a "$f")" == 644 ]]; then
  pass "2 DRY_RUN=0 writes the exact conf.d file, 0644"
else fail "2 file (rc=$rc): $out / $(cat "$f" 2>&1)"; fi
if grep -qx 'systemctl mask systemd-resolved' "$CALLS" && grep -qx 'nmcli general reload conf' "$CALLS" &&
  grep -q "READ is-enabled=masked dns=default rc-manager=symlink resolv.conf -> $NMLINK" <<<"$out" &&
  grep -q 'OK NM DNS pinned' <<<"$out" && [[ "$(readlink "$T/r2/etc/resolv.conf")" == "$NMLINK" ]]; then
  pass "2 masks, reloads NM, reads masked + dns=default rc-manager=symlink + NM's link"
else fail "2 commands: $(cat "$CALLS") / $out"; fi
: >"$CALLS"; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q "SAME $f" <<<"$out" && grep -q 'SAME systemd-resolved masked' <<<"$out" &&
  ! grep -q 'mask systemd-resolved' "$CALLS" && pass "2 second run: SAME file, SAME masked, no second mask" ||
  fail "2 second run (rc=$rc): $out / $(cat "$CALLS")"
reset "$T/r2" nm inactive not-found; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q 'is-enabled=not-found' <<<"$out" && grep -qx 'systemctl mask systemd-resolved' "$CALLS" &&
  grep -q 'READ is-enabled=masked' <<<"$out" && pass "2 purged unit (not-found): masked anyway, reads masked" ||
  fail "2 not-found (rc=$rc): $out / $(cat "$CALLS")"

# 3. the refusal: DNS not NM's, or resolved running
# refused <func> <label> <resolv> <active> <want-msg> - rc 0 when both modes
# refuse with <want-msg> and nothing was written, masked or reloaded
refused() {
  local fn="$1" d o r
  for d in 1 0; do
    reset "$T/r3" "$3" "$4"; o="$(run "$fn" "$T/r3" DRY_RUN=$d 2>&1)"; r=$?
    ((r != 0)) && grep -q "FATAL .*$5.*refusing; nothing was changed" <<<"$o" && [[ ! -e "$(conf "$T/r3")" ]] &&
      ! grep -qE 'mask|reload' "$CALLS" && [[ "$(cat "$ST/enabled")" == disabled ]] || return 1
  done
}
refuse() { refused "$FUNC" "$@" && pass "3 $1 -> refused, nothing changed" || fail "3 $1: $(cat "$CALLS")"; }
refuse "resolv.conf a regular file" file inactive "is 'not a symlink'"
refuse "resolv.conf -> resolved's stub" stub inactive "is '/run/systemd/resolve/stub-resolv.conf'"
refuse "resolv.conf missing" none inactive "is 'missing'"
refuse "systemd-resolved active" nm active "systemd-resolved is 'active'"
refuse "systemd-resolved activating" nm activating "systemd-resolved is 'activating'"
reset "$T/r3" nm failed; out="$(run "$FUNC" "$T/r3" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q 'OK NM DNS pinned' <<<"$out" && pass "3 systemd-resolved failed (not running) -> applied" ||
  fail "3 failed unit (rc=$rc): $out"

# 4. the read-back misses
reset "$T/r4" nm; out="$(run "$FUNC" "$T/r4" DRY_RUN=0 PRINT_CONFIG='[main]\ndns=default\nrc-manager=file' 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL NetworkManager --print-config reads 'dns=default rc-manager=file'" <<<"$out" &&
  pass "4 another conf.d file wins (rc-manager=file) -> FATAL" || fail "4 print-config (rc=$rc): $out"
reset "$T/r4" nm; out="$(run "$FUNC" "$T/r4" DRY_RUN=0 MASK_NOOP=1 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL systemd-resolved is-enabled reads 'disabled', not masked" <<<"$out" &&
  pass "4 unit not masked after the mask -> FATAL" || fail "4 not masked (rc=$rc): $out"
reset "$T/r4" nm; out="$(run "$FUNC" "$T/r4" DRY_RUN=0 RELOAD_BREAKS=1 2>&1)"; rc=$?
((rc != 0)) && grep -q "FATAL .*resolv.conf is now '/run/systemd/resolve/stub-resolv.conf'" <<<"$out" &&
  pass "4 resolv.conf replaced on reload -> FATAL" || fail "4 link replaced (rc=$rc): $out"

# 5. red controls
sed 's/ndp_precheck "$root" || return 1/:/' "$FUNC" >"$T/red1.func.sh"
cmp -s "$FUNC" "$T/red1.func.sh" && fail "5 red control: the refusal sed did not change the copy"
refused "$T/red1.func.sh" x file inactive "is 'not a symlink'" && fail "5 red control: a copy without the refusal not caught" ||
  pass "5 red control: a copy without the refusal is caught"
sed 's/rc-manager = symlink/rc-manager = file/' "$FUNC" >"$T/red2.func.sh"
reset "$T/r5" nm; out="$(run "$T/red2.func.sh" "$T/r5" DRY_RUN=0 2>&1)"; rc=$?
((rc != 0)) && [[ "$(cat "$(conf "$T/r5")" 2>/dev/null)" != "$want" ]] &&
  pass "5 red control: a copy writing rc-manager = file is caught" || fail "5 red control: rc-manager = file not caught (rc=$rc)"
sed 's/$NDP_SUDO $NDP_SYSTEMCTL mask systemd-resolved ||/: ||/' "$FUNC" >"$T/red3.func.sh"
cmp -s "$FUNC" "$T/red3.func.sh" && fail "5 red control: the mask sed did not change the copy"
reset "$T/r5" nm; out="$(run "$T/red3.func.sh" "$T/r5" DRY_RUN=0 2>&1)" && fail "5 red control: a copy without the mask not caught" ||
  pass "5 red control: a copy without the mask is caught"

echo "net-dns-pin-and-mask: $fails failure(s)"
exit $((fails > 0))
