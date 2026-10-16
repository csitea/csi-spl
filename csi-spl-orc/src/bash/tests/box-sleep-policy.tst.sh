#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_box_sleep_policy (SPL-2269) offline: /etc is a temp root
#          (SLEEP_POLICY_ROOT), systemctl / gsettings / busctl are stubs.
#   1. refusals: SLEEP_POLICY_CMD=x, DRY_RUN=2 - no call, no file
#   2. DRY_RUN is the default: prints the drop-in, writes nothing, no reload
#   3. DRY_RUN=0: the drop-in (idle ignore, lid suspends on AC too), one
#      reload of logind, gsettings AC idle -> nothing; never a restart
#   4. a second run changes nothing: no write, no reload, no gsettings set
#   5. a drifted drop-in is rewritten and logind reloaded again
#   6. no GNOME schema: skipped, still OK
#   7. show: the drop-in in place, logind props, AC, battery, UPower action
#   8. CONTROL: a stub call IS recorded (the "no call" checks can fail)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/root"; SYS="$T/sys"; DROPIN="$R/etc/systemd/logind.conf.d/50-csi-spl-sleep-policy.conf"
mkdir -p "$R/etc/UPower" "$SYS/AC" "$SYS/BAT0" "$T/stub"
printf '[UPower]\nCriticalPowerAction=HybridSleep\n' >"$R/etc/UPower/UPower.conf"
echo Mains >"$SYS/AC/type"; echo 1 >"$SYS/AC/online"
echo Battery >"$SYS/BAT0/type"; echo Discharging >"$SYS/BAT0/status"; echo 18 >"$SYS/BAT0/capacity"

orc_stub 0 systemctl
# gsettings: a one-key store in $GS_STATE; GS_NO_SCHEMA=1 plays a box without GNOME
cat >"$T/stub/gsettings" <<'EOF'
#!/usr/bin/env bash
echo "gsettings $*" >>"$STUB_LOG"
[[ "${GS_NO_SCHEMA:-0}" == 1 ]] && { echo "No such schema" >&2; exit 1; }
case "$1" in
  get) [[ "$3" == sleep-inactive-ac-type ]] && cat "$GS_STATE" || echo 3600 ;;
  set) echo "'$4'" >"$GS_STATE" ;;
esac
EOF
cat >"$T/stub/busctl" <<'EOF'
#!/usr/bin/env bash
case "$5" in IdleAction) echo 's "ignore"' ;; HandleLidSwitch*) echo 's "suspend"' ;; *) exit 1 ;; esac
EOF
chmod +x "$T/stub/gsettings" "$T/stub/busctl"
echo "'suspend'" >"$T/gs"

run_bsp() {
  SNIPPET=do_box_sleep_policy in_orc SLEEP_POLICY_ROOT="$R" SLEEP_POLICY_SYS="$SYS" GS_STATE="$T/gs" "$@" >"$T/o" 2>&1
}
calls() { grep -c "$1" "$T/calls.log" 2>/dev/null || true; }

# --- 1. refusals ---------------------------------------------------------------------------
for bad in SLEEP_POLICY_CMD=x DRY_RUN=2; do
  : >"$T/calls.log"
  if run_bsp "$bad"; then fail "accepts $bad"; else pass "refuses $bad"; fi
  [[ ! -e "$DROPIN" ]] && [[ "$(calls systemctl)" == 0 ]] && pass "$bad: no file, no systemctl" || fail "$bad touched: $(cat "$T/calls.log")"
done

# --- 2. DRY_RUN default --------------------------------------------------------------------
: >"$T/calls.log"
run_bsp; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would write' "$T/o" && grep -q '^IdleAction=ignore$' "$T/o" &&
  pass "dry run prints the planned drop-in" || fail "dry run: rc=$rc $(cat "$T/o")"
[[ ! -e "$DROPIN" && "$(calls systemctl)" == 0 && "$(calls 'gsettings set')" == 0 && "$(cat "$T/gs")" == "'suspend'" ]] &&
  pass "dry run writes nothing, reloads nothing, sets nothing" || fail "dry run changed: $(cat "$T/calls.log")"
grep -q 'would run: gsettings set .* sleep-inactive-ac-type nothing' "$T/o" && pass "dry run names the gsettings change" || fail "dry gsettings: $(cat "$T/o")"

# --- 3. apply ------------------------------------------------------------------------------
: >"$T/calls.log"
run_bsp DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && pass "DRY_RUN=0 exits 0" || fail "apply rc=$rc $(cat "$T/o")"
for line in '[Login]' IdleAction=ignore HandleLidSwitch=suspend HandleLidSwitchExternalPower=suspend; do
  grep -qxF "$line" "$DROPIN" 2>/dev/null && pass "drop-in has $line" || fail "drop-in lacks $line"
done
[[ "$(calls 'systemctl reload systemd-logind')" == 1 ]] && pass "logind reloaded once" || fail "reloads: $(cat "$T/calls.log")"
grep -qE 'systemctl (restart|stop|kill)' "$T/calls.log" && fail "logind restarted/stopped" || pass "logind never restarted"
[[ "$(cat "$T/gs")" == "'nothing'" ]] && pass "gsettings AC idle -> nothing" || fail "gsettings: $(cat "$T/gs")"
grep -q 'sleep-inactive-battery' "$T/calls.log" && fail "battery key touched" || pass "battery keys untouched"
SUM="$(sha256sum <"$DROPIN")"

# --- 4. idempotent -------------------------------------------------------------------------
: >"$T/calls.log"
run_bsp DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(calls systemctl)" == 0 && "$(calls 'gsettings set')" == 0 && "$(sha256sum <"$DROPIN")" == "$SUM" ]] &&
  pass "second run changes nothing" || fail "second run: rc=$rc $(cat "$T/calls.log")"
grep -q 'already in place' "$T/o" && grep -q "already 'nothing'" "$T/o" && pass "second run says unchanged" || fail "second run text: $(cat "$T/o")"

# --- 5. drift ------------------------------------------------------------------------------
printf '[Login]\nIdleAction=suspend\n' >"$DROPIN"
: >"$T/calls.log"
run_bsp DRY_RUN=0
[[ "$(sha256sum <"$DROPIN")" == "$SUM" && "$(calls 'systemctl reload systemd-logind')" == 1 ]] &&
  pass "a drifted drop-in is rewritten and logind reloaded" || fail "drift: $(cat "$DROPIN") $(cat "$T/calls.log")"

# --- 6. no GNOME ---------------------------------------------------------------------------
run_bsp DRY_RUN=0 GS_NO_SCHEMA=1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'no GNOME idle policy' "$T/o" && pass "no GNOME schema: skipped, OK" || fail "no schema: rc=$rc $(cat "$T/o")"

# --- 7. show -------------------------------------------------------------------------------
run_bsp SLEEP_POLICY_CMD=show; rc=$?
for want in 'in_place=yes' 'logind IdleAction=ignore' 'logind HandleLidSwitchExternalPower=suspend' \
  "gsettings sleep-inactive-ac-type='nothing'" 'power ac=AC online=1' 'power battery=BAT0 status=Discharging capacity=18%' \
  'upower CriticalPowerAction=HybridSleep'; do
  grep -qF "$want" "$T/o" && pass "show: $want" || fail "show lacks '$want': $(cat "$T/o")"
done
[[ $rc -eq 0 ]] && pass "show exits 0" || fail "show rc=$rc"

# --- 8. CONTROL ----------------------------------------------------------------------------
: >"$T/calls.log"
PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" systemctl reload x
[[ "$(calls systemctl)" == 1 ]] && pass "control: a stub call is recorded" || fail "control: stub log empty"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
