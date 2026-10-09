#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every @reboot line waits for its mounts, then leaves a trace. Drill 8
#          on sat, 2026-10-09: cron ran the five @reboot jobs at 18:38:48Z, but
#          /opt, /var/csi and /var/spool-hub (nofail binds of /mnt/data) came
#          up 1..6 s later. Each `>> /var/csi/.../x.out` redirect failed
#          ("Directory nonexistent"), no job ran, and cron mailed the error to
#          no MTA: not one line anywhere. The lines are built by the real
#          builders (desk reconcile @boot, agent boot restore, wd starter boot,
#          the box-sessions-boot row of do_install_box_crons) and run with
#          /bin/sh as cron runs them.
#   1. the race: the script and the log dir are absent when the line starts
#      and appear 2 s later -> every line writes its BOOT start line and runs
#      its job (red on the old lines: the redirect fails, empty log)
#   2. the bound: a log dir that never comes -> the line gives up after
#      BOOT_CRON_WAIT and says so in syslog (logger)
#   3. the start line comes before the git step and the network wait; with
#      systemd, the git step waits for network-online.target
#   4. the line's first path is still its script (spec 068 8.1, check)
#   5. the wd starter install drops the hand-installed, ungated T023b pair
#      (wd-inst-start, wd-inst-start-boot): no ungated @reboot line is left
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
SRC="$T/shared" L="$T/var" B="$T/bin"
mkdir -p "$SRC/$OA-orc/src/bash/scripts" "$SRC/$OA-orc/src/bash/features/box-sessions/scripts" "$B"
git init -q "$SRC"
for s in desk-reconcile-cron.sh agent-boot-restore-cron.sh; do
  printf '#!/bin/sh\necho "RAN %s $*"\n' "$s" > "$SRC/$OA-orc/src/bash/scripts/$s"
done
printf '#!/bin/sh\necho "RAN run $*"\n' > "$SRC/$OA-orc/run"
printf '#!/bin/sh\necho "RAN sessions-boot.sh $*"\n' > "$SRC/$OA-orc/src/bash/features/box-sessions/scripts/sessions-boot.sh"
chmod +x "$SRC/$OA-orc/run" "$SRC/$OA-orc/src/bash/scripts/"*.sh "$SRC/$OA-orc/src/bash/features/box-sessions/scripts/"*.sh
# stubs: logger to a file; git notes whether the network was up; systemctl
# says network-online is active only once $T/net exists
printf '#!/bin/sh\necho "LOGGER $*" >> "%s/syslog"\n' "$T" > "$B/logger"
printf '#!/bin/sh\n[ -e "%s/net" ] && echo up >> "%s/git" || echo down >> "%s/git"\nexit 1\n' "$T" "$T" "$T" > "$B/git"
printf '#!/bin/sh\n[ -e "%s/net" ]\n' "$T" > "$B/systemctl"
chmod +x "$B/logger" "$B/git" "$B/systemctl"
printf '#!/bin/sh\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' > "$B/crontab"
chmod +x "$B/crontab"

# lines: the four @reboot lines, one per line of $T/lines, from the builders
env PATH="$B:$PATH" FAKE_CRONTAB="$T/crontab" PROJ_PATH="$PROJ_ROOT" APP_PATH="$SRC" SPL_ORG_APP="$OA" \
  DESK_CRON_SRC="$SRC" DESK_CRON_SELF_UPDATE=1 BOOT_CRON_LOG_DIR="$L/agent-boot-restore" WD_CRON_LOG_DIR="$L/wd" \
  BOOT_CRON_WAIT="${GATE_WAIT:-20}" SPOOL_TEST=1 bash -c '
  do_log() { echo "$*" >&2; }
  do_require_bin() { return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-agent-boot-restore-install-cron.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-wd-ensure-install-cron.func.sh"
  source "$PROJ_PATH/src/bash/run/install-box-crons.func.sh"
  SPL_DESK_CRON_SELF_UPDATE=0 SPL_DESK_CRON_BOOT=1 spl_desk_cron_build_line 3 dev t1 "" "$DESK_CRON_SRC" \
    "$DESK_CRON_SRC/$SPL_ORG_APP-orc/src/bash/scripts/desk-reconcile-cron.sh" "'"$L"'/desk-reconcile" "$SPL_ORG_APP:desk-reconcile@boot"
  DRY_RUN=0 do_spl_agent_boot_restore_install_cron >/dev/null 2>&1
  grep "# $SPL_ORG_APP:agent-boot-restore\$" "$FAKE_CRONTAB"
  spl_wd_cron_prep && printf "%s\n" "${SPL_WD_CRON_LINES[1]}"
  : > "$FAKE_CRONTAB"
  BOX_CRONS_MANIFEST="$PROJ_PATH/cnf/box-crons/box-crons.manifest" PROJ_PATH="$DESK_CRON_SRC/$SPL_ORG_APP-orc" BOX_CRONS_CRONTAB=crontab \
    BOX_CRONS_STATE_DIR="'"$L"'" BOX_CRONS_ONLY=box-sessions-boot DRY_RUN=0 do_install_box_crons >/dev/null 2>&1
  grep "# csi-spl:box-cron:box-sessions-boot\$" "$FAKE_CRONTAB"' > "$T/lines" 2>"$T/build.err"
[[ "$(grep -c '^@reboot ' "$T/lines")" == 4 ]] && pass "0. the four builders give four @reboot lines" ||
  fail "0. lines: $(cat "$T/lines") $(cat "$T/build.err")"
rm -rf "$L"   # the install made the boot restore's log dir: a boot has none

# run_lines: each line as cron runs it (/bin/sh -c, cron's PATH plus the stubs)
run_lines() {
  local l pids=()
  while IFS= read -r l; do
    env -i HOME="$T" PATH="$B:/usr/bin:/bin" /bin/sh -c "${l#@reboot }" 2>>"$T/mail" & pids+=($!)
  done < "$T/lines"
  wait "${pids[@]}"
}
LOGS=("$L/desk-reconcile/cron.out" "$L/agent-boot-restore/cron.out" "$L/wd/starter.out" "$L/box-sessions/boot.log")
JOBS=("desk-reconcile-cron.sh --boot" "agent-boot-restore-cron.sh" "run -a do_spl_wd_inst_start" "sessions-boot.sh")

# --- 1. the race: mounts arrive 2 s after cron started the lines -----------------------
mv "$SRC" "$SRC.off"; : > "$T/net"
( sleep 2; mv "$SRC.off" "$SRC"; mkdir -p "$L/desk-reconcile" "$L/agent-boot-restore" "$L/wd" "$L/box-sessions" ) &
run_lines; wait
for i in 0 1 2 3; do
  if grep -q ' BOOT start ' "${LOGS[$i]}" 2>/dev/null && grep -qF "RAN ${JOBS[$i]}" "${LOGS[$i]}"; then
    pass "1. mounts late by 2 s: ${JOBS[$i]%% *} logs BOOT start and runs"
  else
    fail "1. ${JOBS[$i]%% *}: log '$(cat "${LOGS[$i]}" 2>/dev/null)' mail '$(cat "$T/mail")'"
  fi
done

# --- 2. the bound: the log dir never comes -----------------------------------------------
rm -rf "$L" "$T/syslog"; mkdir -p "$L/agent-boot-restore" "$L/wd"
l="$(grep 'desk-reconcile@boot$' "$T/lines")"
l="${l//-ge 20 ]/-ge 2 ]}"   # the bound, cut from 20 s to 2 s
s0=$(date +%s)
env -i HOME="$T" PATH="$B:/usr/bin:/bin" /bin/sh -c "${l#@reboot }" 2>/dev/null
el=$(( $(date +%s) - s0 ))
(( el < 15 )) && grep -q 'BOOT start .*desk-reconcile@boot: no .*cron.out after 2s' "$T/syslog" 2>/dev/null &&
  pass "2. no log dir: gives up after the bound (${el}s) and says so in syslog" || fail "2. ${el}s syslog: $(cat "$T/syslog" 2>/dev/null)"

# --- 3. the start line first, then the network, then git -----------------------------------
l="$(grep 'agent-boot-restore$' "$T/lines")"
b="${l%%BOOT start*}"; g="${l%%git fetch*}"; n="${l%%network-online*}"
(( ${#b} < ${#n} && ${#n} < ${#g} )) && pass "3. agent boot restore: BOOT start, then the network wait, then git fetch" ||
  fail "3. order: $l"
if [[ -d /run/systemd/system ]]; then
  rm -f "$T/net" "$T/git"; rm -rf "$L"; mkdir -p "$L/agent-boot-restore"
  ( sleep 2; : > "$T/net" ) &
  env -i HOME="$T" PATH="$B:/usr/bin:/bin" /bin/sh -c "${l#@reboot }" 2>/dev/null; wait
  [[ "$(cat "$T/git" 2>/dev/null)" == up ]] && grep -q ' BOOT start ' "$L/agent-boot-restore/cron.out" &&
    pass "3. network-online 2 s late: git fetch waits for it" || fail "3. git saw: $(cat "$T/git" 2>/dev/null)"
else
  echo "SKIP: 3. no systemd here: the network wait is a no-op"
fi

# --- 4. the first path of each line is still its script -------------------------------------
ok=0
while IFS= read -r l; do
  s="$(bash -c 'do_log() { :; }; source "$1"; source "$2"; spl_peer_cron_script_of "$3"' _ \
    "$PROJ_ROOT/src/bash/run/spl-desk-install-service.func.sh" "$PROJ_ROOT/src/bash/run/spl-peer-crons.func.sh" "$l")"
  [[ "$s" == "$SRC/$OA-orc/"* && -x "$s" ]] && ok=$((ok + 1))
done < "$T/lines"
[[ "$ok" == 4 ]] && pass "4. spec 068 8.1 reads each gated line's script" || fail "4. $ok of 4 lines name their script"

# --- 5. the wd starter install drops the hand-installed, ungated pair -------------------------
P="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cat > "$T/crontab.wd" <<EOF
* * * * * $P WD_INST_START="1 2 3" $SRC/$OA-orc/run -a do_spl_watchdog >> $L/wd/inst-start.out 2>&1 # $OA:wd-inst-start
@reboot $P WD_INST_START="1 2 3" $SRC/$OA-orc/run -a do_spl_watchdog >> $L/wd/inst-start.out 2>&1 # $OA:wd-inst-start-boot
0 8 * * * /opt/other/run-me.sh # other:job
EOF
env PROJ_PATH="$PROJ_ROOT" SPL_ORG_APP="$OA" DESK_CRON_SRC="$SRC" WD_CRON_LOG_DIR="$L/wd" SPOOL_TEST=1 bash -c '
  do_log() { echo "$*" >&2; }
  source "$PROJ_PATH/src/bash/run/spl-wd-ensure-install-cron.func.sh"
  spl_wd_cron_prep && spl_wd_cron_render_all' < "$T/crontab.wd" > "$T/crontab.after" 2>"$T/wd.err"
ungated="$(grep '^@reboot ' "$T/crontab.after" | grep -vc ' BOOT start ')"
[[ "$ungated" == 0 && "$(grep -c '^@reboot ' "$T/crontab.after")" == 1 ]] && ! grep -q 'wd-inst-start' "$T/crontab.after" &&
  grep -q '# other:job$' "$T/crontab.after" &&
  pass "5. the wd starter install drops wd-inst-start(-boot): every @reboot line is gated" ||
  fail "5. $ungated ungated: $(cat "$T/crontab.after") $(cat "$T/wd.err")"

echo "boot-cron-gate: $fails failure(s)"
(( fails == 0 ))
