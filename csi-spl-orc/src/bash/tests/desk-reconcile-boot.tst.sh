#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hub-run sidecars come back AT BOOT, not at the next desk tick.
#          2026-10-09 on a satellite box: booted 16:23:00Z, the prd sidecar was up only at
#          16:25:09Z (the next tick), and every cross-box send failed rc=3 in
#          that gap. do_spl_desk_install_service now also writes an @reboot
#          twin of each env's tick line that runs desk-reconcile-cron.sh --boot.
#          `crontab` is a stub over a file; a scratch git repo stands in for
#          the shared checkout; the --boot run's probe and reconcile are stubs.
#   1. install writes ONE @reboot line per env, tagged <tag>@boot, with
#      --boot, the hub host, the env's mute/probe, and no self-update fetch
#      (red on the old code: no @reboot line at all)
#   2. re-installing changes no byte: one @boot line per env, never two
#   3. the box-restart desk pass regex never picks up an @reboot line
#   4. check reports the boot line; a missing one is a WARN, not a FAIL
#   5. remove on dev drops the dev tick + boot lines and keeps prd's
#   6. --boot waits for the network, runs the reconcile once, logs ONE BOOT
#      line with the boot time and rc, and exits with the reconcile's rc
#   7. --boot is bounded: no network -> net=timeout, the reconcile still runs
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
R="$T/repo" C="$T/repo-desk-cron" L="$T/log" CT="$T/crontab.txt"
git init -q "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
mkdir -p "$C/$OA-orc/src/bash/scripts" "$T/stub"
SCRIPT="$C/$OA-orc/src/bash/scripts/desk-reconcile-cron.sh"
printf '#!/bin/sh\nexit 0\n' >"$SCRIPT"; chmod +x "$SCRIPT"
cat >"$T/stub/crontab" <<'EOF'
#!/bin/sh
F="${STUB_CRONTAB:?}"
case "${1:-}" in
  -l) [ -s "$F" ] && cat "$F"; exit 0 ;;
  "") exit 2 ;;
  *)  cat "$1" >"$F"; exit 0 ;;
esac
EOF
chmod +x "$T/stub/crontab"

svc() {
  env SPOOL_TEST=1 SPOOL_BOX_ENV="$T/no-box.env" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" SPL_ORG_APP="$OA" STUB_CRONTAB="$CT" PATH="$T/stub:$PATH" \
    TENANT_ID=t1 DESK_CRON_LOG_DIR="$L" DESK_BOOT_HOST=hub.example.com DESK_MUTE=c-010 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { :; }
    do_spl_desk_install_service' 2>&1
}

PD="\$HOME/.local/share/$OA/cloud/prd/m3-e2e/e2e"
# the boot gate every @reboot line starts with (boot-cron-gate.tst.sh covers it)
gate() { bash -c 'do_log() { echo "$*"; }; source "$1"; shift; spl_cron_boot_gate "$@"' _ "$PROJ_ROOT/src/bash/run/spl-desk-install-service.func.sh" "$@"; }
DEVB="@reboot $(gate $L/cron.out $SCRIPT $OA:desk-reconcile@boot)ENV=dev TENANT_ID=t1 DESK_MUTE=c-010 DESK_BOOT_HOST=hub.example.com $SCRIPT --boot >> $L/cron.out 2>&1 # $OA:desk-reconcile@boot"
PRDB="@reboot $(gate $L/cron-prd.out $SCRIPT $OA:desk-reconcile-prd@boot)ENV=prd TENANT_ID=t1 DESK_MUTE=c-010 PROBE_EMAIL=\$(cat $PD/human-email) PROBE_PW_FILE=$PD/pw-human DESK_BOOT_HOST=hub.example.com $SCRIPT --boot >> $L/cron-prd.out 2>&1 # $OA:desk-reconcile-prd@boot"
OTHER="0 4 * * * /usr/bin/true # someone-elses-job"

# --- 1. install writes the @reboot twin --------------------------------------------------
printf '%s\n' "$OTHER" >"$CT"
svc ENV=dev DESK_CRON_EVERY=3 DRY_RUN=0 >"$T/o1"
svc ENV=prd DESK_CRON_EVERY=3 DRY_RUN=0 >>"$T/o1"
grep -qxF "$DEVB" "$CT" && grep -qxF "$PRDB" "$CT" &&
  pass "1. install writes one @reboot --boot line per env (host, mute, probe, no fetch)" ||
  fail "1. no @reboot line as expected. crontab: $(cat "$CT") out: $(cat "$T/o1")"
[[ "$(grep '@reboot' "$CT")" == *'git fetch'* ]] && fail "1. the @reboot line fetches before the network is up" ||
  pass "1. ...without the self-update fetch"
grep -qxF "$OTHER" "$CT" && [[ "$(wc -l <"$CT")" == 5 ]] &&
  pass "1. ...next to the two tick lines and the unrelated line" || fail "1. crontab: $(cat "$CT")"

# --- 2. idempotent -------------------------------------------------------------------------------
cp "$CT" "$T/after1"
svc ENV=dev DESK_CRON_EVERY=3 DRY_RUN=0 >/dev/null
svc ENV=prd DESK_CRON_EVERY=3 DRY_RUN=0 >/dev/null
cmp -s "$CT" "$T/after1" && pass "2. re-installing dev and prd changes no byte" || fail "2. drift: $(diff "$T/after1" "$CT")"
[[ "$(grep -c "# $OA:desk-reconcile@boot\$" "$CT")" == 1 && "$(grep -c "# $OA:desk-reconcile-prd@boot\$" "$CT")" == 1 ]] &&
  pass "2. ...exactly one @boot line per env" || fail "2. boot line count: $(cat "$CT")"
out="$(svc ENV=dev DESK_CRON_EVERY=3)"
[[ "$(grep -c '(no change)' <<<"$out")" == 2 ]] && pass "2. the dry run says no change for both lines" || fail "2. dry: $out"

# --- 3. the box-restart desk pass never runs an @reboot line ------------------------------
n="$(grep -E "# $OA:desk-reconcile(-[a-z]+)?\$" "$CT" | grep -c '@reboot')"
[[ "$n" == 0 ]] && pass "3. spl_brx_after_desk's tag regex matches no @reboot line" || fail "3. $n @reboot line(s) match"

# --- 4. check ------------------------------------------------------------------------------------
out="$(svc ENV=dev DESK_CRON_EVERY=3 DESK_SERVICE_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *'"boot_installed": true'* && "$out" != *WARN* ]] &&
  pass "4. check reports the installed @reboot line" || fail "4. rc=$rc $out"
grep -vF "$DEVB" "$CT" >"$T/nb"; cp "$T/nb" "$CT"
out="$(svc ENV=dev DESK_CRON_EVERY=3 DESK_SERVICE_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *'"boot_installed": false'* && "$out" == *"WARN no @reboot"* ]] &&
  pass "4. a missing @reboot line is a WARN, the tick line still passes" || fail "4. rc=$rc $out"
svc ENV=dev DESK_CRON_EVERY=3 DRY_RUN=0 >/dev/null

# --- 5. remove ----------------------------------------------------------------------------------
svc ENV=dev DESK_SERVICE_ACTION=remove DRY_RUN=0 >/dev/null
! grep -q "# $OA:desk-reconcile\$" "$CT" && ! grep -qxF "$DEVB" "$CT" && grep -qxF "$PRDB" "$CT" && grep -qxF "$OTHER" "$CT" &&
  pass "5. removing dev drops its tick and @reboot lines, keeps prd's" || fail "5. crontab: $(cat "$CT")"

# --- 6. --boot: wait, run once, one BOOT line, the reconcile's rc -------------------------
REAL="$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh"
printf '#!/bin/sh\necho "RUN $*" >>"%s/runs"\nexit 7\n' "$T" >"$T/stub/reconcile"; chmod +x "$T/stub/reconcile"
printf '#!/bin/sh\nn=$(cat "%s/probes" 2>/dev/null || echo 0); n=$((n + 1)); echo $n >"%s/probes"; [ $n -ge 3 ]\n' "$T" "$T" >"$T/stub/probe"
chmod +x "$T/stub/probe"
out="$(env DESK_BOOT_PROBE="$T/stub/probe" DESK_BOOT_RUN="$T/stub/reconcile" DESK_BOOT_POLL=0 DESK_BOOT_WAIT=30 \
  DESK_BOOT_HOST=hub.example.com bash "$REAL" --env prd --tenant t1 --boot 2>&1)"; rc=$?
[[ $rc -eq 7 && "$(cat "$T/probes")" == 3 && "$(cat "$T/runs")" == "RUN --env prd --tenant t1" ]] &&
  pass "6. --boot polls until the network is up, runs the reconcile ONCE, exits with its rc" ||
  fail "6. rc=$rc probes=$(cat "$T/probes" 2>/dev/null) runs=$(cat "$T/runs" 2>/dev/null) out=$out"
[[ "$(grep -c ' BOOT ' <<<"$out")" == 1 && "$out" =~ BOOT\ booted=([0-9T:-]+Z|unknown)\ env=prd\ host=hub.example.com\ net=up\ waited=[0-9]+s\ reconcile_rc=7 ]] &&
  pass "6. ...and logs one BOOT line with the boot time and the rc" || fail "6. log: $out"

# --- 7. bounded wait ----------------------------------------------------------------------------
rm -f "$T/runs"
s=$(date +%s)
out="$(env DESK_BOOT_PROBE=false DESK_BOOT_RUN="$T/stub/reconcile" DESK_BOOT_POLL=1 DESK_BOOT_WAIT=1 \
  bash "$REAL" --env dev --tenant t1 --boot 2>&1)"; rc=$?
e=$(( $(date +%s) - s ))
[[ $rc -eq 7 && $e -le 5 && "$out" == *"net=timeout"* && -s "$T/runs" ]] &&
  pass "7. no network: the wait ends at DESK_BOOT_WAIT (${e}s) and the reconcile still runs" || fail "7. rc=$rc e=${e}s out=$out"

echo "desk-reconcile-boot: $fails failure(s)"
[[ $fails -eq 0 ]]
