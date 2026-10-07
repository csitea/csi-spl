#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the reboot path of spec 102 10.1 (T014) in a sandbox: the boot
#          branch of do_spl_watchdog (spl_wd_boot) on a simulated boot. ps,
#          tmux, spool-send.sh and the restart are stubs; the boot time is
#          <proc root>/stat's btime; the clock LEASE_NOW. Before the boot
#          the box ran c-101 and c-102 (verdicts just before it); c-103 had
#          finished (lifetime/done), c-104 runs as a guest on box2
#          (running_box), c-105 was an open row dead for hours, c-106's
#          worktree is gone, c-107 is back already (a window and a process),
#          c-108 never ran here.
#   1. inside the start and resume grace nothing starts; after it every
#      open agent that ran here is restarted ONCE, cause reboot, with
#      WD_BOOT_ID for the restart's gate; the done, the guest-elsewhere, the
#      stale, the gone, the running and the never-seen ones are not; the
#      next tick starts nothing (boot.seen, boot.d/<id>)
#   2. control: the same boot with running_box = another box for every
#      agent -> nothing started; shown red: the running_box check cut out
#      of a copy of the watchdog starts them
#   3. control of "once": the boot.d check cut out -> a second pass starts
#      them again (red), so 1's "once" is the check's doing
#   4. the restart's gate sees a windowless id only with WD_BOOT_ID (control:
#      without it, no row)
#   5. first run of this code: a boot a day old is the baseline (nothing
#      started, boot.seen written); the next boot is handled
#   6. a fenced box (spl_wd_box_fenced, T017) starts nothing and retries; a dry
#      run starts nothing and records nothing
#   7. after the drill: do_spl_agent_boot_restore_install_cron
#      BOOT_CRON_ACTION=retire takes the @reboot line out (dry run: nothing)
#      and leaves <log dir>/retired; a later install (a re-provision) skips,
#      check passes; control: BOOT_CRON_FORCE=1 installs it again
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v setsid >/dev/null || { echo "FAIL: setsid is required"; exit 1; }
BT=1800000000   # 2027-01-15T08:00:00Z, the boot
iso() { date -u -d "@$1" +%FT%TZ; }
S="$T/spool"; D="$S/dispatch"; W="$D/wd"
mkdir -p "$T/bin" "$T/sit" "$T/tmux"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$T/box.env"

# ---- stubs -------------------------------------------------------------------
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
printf '#!/usr/bin/env bash\ncase "$1" in list-panes) cat "%s/tmux/panes" ;; esac\nexit 0\n' "$T" > "$T/bin/tmux"
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\necho "takeover $ID cause=$CAUSE boot_id=${WD_BOOT_ID:-} ev=$WD_EVIDENCE" >> "%s/takeovers"\n' "$T" > "$T/bin/takeover"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --norm|--scrub) cat ;; esac\nexit 0\n' > "$T/sit/s3.sh"
chmod +x "$T/bin/"* "$T/sit/"*
export T

# row <id> [rundir]: an open registry row (its worktree made unless named).
row() {
  local rd="${2:-$T/wt/$1}"
  mkdir -p "$S/$1/lifetime" "$S/$1/inbox"
  [[ -n "${2:-}" ]] || mkdir -p "$rd"
  printf '%s\tclaude\t%%9\t%s\t20270115T0600Z\n' "$1" "$rd" >> "$S/registry.tsv"
}
# verdict <id> <epoch>: the watchdog judged <id> at <epoch> (dispatch/wd.<id>)
verdict() { echo "OK $2" > "$D/wd.$1"; touch -d "@$2" "$D/wd.$1"; }
# box <boot epoch>: the box after that boot, the verdicts of the boot before
box() {
  local bt="$1"
  rm -rf "${S:?}" "${T:?}/proc" "${T:?}/wt" "${T:?}/takeovers" "${T:?}/sent"
  mkdir -p "$W" "$T/proc" "$T/wt"; : > "$T/ps"; : > "$T/tmux/panes"; : > "$S/registry.tsv"
  cp "$T/box.env" "$S/box.env"
  printf 'cpu  1 2 3\nbtime %s\nprocesses 1\n' "$bt" > "$T/proc/stat"
  echo "$(( bt - 120 ))" > "$W/last.tick"; touch "$T/fresh"
  row c-101; verdict c-101 $(( bt - 30 ))
  row c-102; verdict c-102 $(( bt - 400 ))
  row c-103; verdict c-103 $(( bt - 60 ))
  echo '{"started": "'"$(iso $(( bt - 3600 )))"'"}' > "$S/c-103/lifetime/session.json"
  touch -d "@$(( bt - 120 ))" "$S/c-103/lifetime/done"
  row c-104; verdict c-104 $(( bt - 60 )); echo box2 > "$S/c-104/lifetime/running_box"
  row c-105; verdict c-105 $(( bt - 9000 ))
  row c-106 "$T/wt/gone-106"; verdict c-106 $(( bt - 60 ))
  row c-107; verdict c-107 $(( bt - 60 ))
  printf '%%7\t5107\t$1\tc-107@box1\tclaude\n' > "$T/tmux/panes"
  printf '5107 1 60 sh\n6107 5107 60 claude\n' > "$T/ps"
  mkdir -p "$T/proc/6107"; printf 'SPOOL_AGENT_ID=c-107\0' > "$T/proc/6107/environ"
  row c-108
}
wd_env=(PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc"
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover"
  WD_SITUATIONS="$T/sit" LEASE_TRANSCRIPT_CMD=true)
# wd <now> [dry]: one tick under ./run's set -E + ERR trap. The first tick
# after a boot ($T/fresh) sees the gap (the resume); later ones had a tick
# 30 s before. WD_EXTRA: bash run after the source (a mutant redefines a
# function there).
wd() {
  if [[ -f "$T/fresh" ]]; then rm -f "${T:?}/fresh"; else echo "$(( $1 - 30 ))" > "$W/last.tick"; fi
  env "${wd_env[@]}" LEASE_NOW="$1" WD_TICKS=1 WD_TICK=30 DRY_RUN="${2:-0}" \
    WD_EXTRA="${WD_EXTRA:-}" bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    eval "$WD_EXTRA"
    do_spl_watchdog' > "$T/out" 2>&1
  if grep -q ERR-TRAP "$T/out"; then fail "the ERR trap fired: $(grep -m3 ERR-TRAP "$T/out")"; fi
}
started() { grep -c . "$T/takeovers" 2>/dev/null || echo 0; }
# settle <n>: the detached takeovers have landed (n lines), then a short wait for strays
settle() { for _ in $(seq 1 40); do (( $(started) >= $1 )) && break; sleep 0.05; done; sleep 0.3; }
ids() { awk '{print $2}' "$T/takeovers" 2>/dev/null | sort | paste -sd' ' -; }
# mutant <function> <sed>: WD_EXTRA that redefines <function> with one check
# cut out by <sed> (the control shown red)
mutant() { printf 'eval "$(declare -f %s | sed %q)"' "$1" "$2"; }

# ---- 1. the boot ---------------------------------------------------------------
echo "=== 1. a simulated boot: every open agent that ran here restarted once"
box "$BT"
wd $(( BT + 60 )); settle 0
[[ "$(started)" == 0 ]] && pass "60 s after the boot (start and resume grace): nothing started" || fail "inside the grace: $(ids)"
grep -q 'waits' "$T/out" && pass "the boot branch says it waits" || fail "no wait line: $(grep BOOT "$T/out")"
[[ ! -f "$W/boot.seen" ]] && pass "the boot is not marked handled yet" || fail "boot.seen written inside the grace"
wd $(( BT + 300 )); settle 2
[[ "$(ids)" == "c-101 c-102" ]] && pass "after the grace: exactly c-101 and c-102 restarted" || fail "restarted: '$(ids)', want 'c-101 c-102'"
[[ "$(grep -c 'cause=reboot boot_id=c-10[12] ' "$T/takeovers")" == 2 ]] && pass "cause reboot, WD_BOOT_ID = the id (the restart's gate lists it)" || fail "takeover lines: $(cat "$T/takeovers")"
L="$D/wd.log"
for c in "c-103 left alone: done: lifetime/done" "c-104 left alone: running_box is box2" "c-105 left alone: not running here at the boot (its last" \
    "c-106 left alone: done: its workdir" "c-107 left alone: it runs" "c-108 left alone: not running here at the boot (no verdict"; do
  grep -qF "$c" "$L" && pass "wd.log: $c" || fail "wd.log lacks: $c"
done
[[ "$(cat "$W/boot.seen" 2>/dev/null)" == "$BT" ]] && pass "boot.seen = the btime" || fail "boot.seen: $(cat "$W/boot.seen" 2>/dev/null)"
[[ -n "$(cat "$W/c-101.ep.S3.takeover" 2>/dev/null)" ]] && pass "the S3 takeover flag is set (no second restart by S3)" || fail "no c-101.ep.S3.takeover"
wd $(( BT + 330 )); settle 3
[[ "$(started)" == 2 ]] && pass "the next tick starts nothing more (once per boot)" || fail "after a second tick: $(ids)"
rm -f "${W:?}/boot.seen"
wd $(( BT + 360 )); settle 3
[[ "$(started)" == 2 ]] && pass "boot.seen gone: boot.d/<id> still keeps each id to one restart" || fail "boot.seen gone -> $(ids)"

# ---- 2. control: running_box another box ------------------------------------------
echo "=== 2. control: the same boot with running_box = another box -> nothing started"
other() { local i; for i in 101 102 103 105 106 107 108; do echo box2 > "$S/c-$i/lifetime/running_box"; done; }
box "$BT"; other; wd $(( BT + 60 ))
wd $(( BT + 300 )); settle 1
[[ "$(started)" == 0 ]] && pass "running_box = box2 for every agent: nothing started" || fail "started under another running_box: $(ids)"
[[ "$(grep -c 'c-10[12] left alone: running_box is box2' "$D/wd.log")" == 2 ]] && pass "c-101 and c-102 named as running elsewhere" || fail "wd.log: $(grep BOOT "$D/wd.log")"
box "$BT"; other; wd $(( BT + 60 ))
WD_EXTRA="$(mutant spl_wd_boot_why 's/rb="$(spl_wd_boot_running_box "$id")"/rb=""/')" wd $(( BT + 300 )); settle 2
[[ "$(ids)" == "c-101 c-102 c-104" ]] && pass "red: with the running_box check cut out, the control starts c-101, c-102 (and the guest c-104)" || fail "mutant running_box started: '$(ids)'"

# ---- 3. control of once -----------------------------------------------------------
echo "=== 3. control: the boot.d check cut out -> restarted again"
M="$(mutant spl_wd_boot_pass 's/\&\& continue/\&\& :/')"
box "$BT"; wd $(( BT + 60 ))
WD_EXTRA="$M" wd $(( BT + 300 )); settle 2
rm -f "${W:?}/boot.seen"
WD_EXTRA="$M" wd $(( BT + 330 )); settle 4
[[ "$(started)" == 4 ]] && pass "red: without boot.d a second pass restarts c-101 and c-102 again" || fail "mutant once: $(started) starts ($(ids))"

# ---- 4. the restart's gate --------------------------------------------------------
echo "=== 4. the restart's gate lists a windowless id only with WD_BOOT_ID"
box "$BT"
gate() {
  env "${wd_env[@]}" LEASE_NOW=$(( BT + 300 )) "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    spl_wd_init >/dev/null || exit 1
    mkdir -p "$T/gate"; : > "$T/gate/panes"; : > "$T/gate/ps"
    spl_wd_agents "$T/gate"' 2>&1
}
[[ "$(gate WD_BOOT_ID=c-101 | awk -F'\t' '$1 == "c-101"')" == "c-101	-	-" ]] && pass "WD_BOOT_ID=c-101: the gate's agent list has c-101 (no pid, no pane)" || fail "with WD_BOOT_ID: $(gate WD_BOOT_ID=c-101)"
[[ -z "$(gate | awk -F'\t' '$1 == "c-101"')" ]] && pass "control: without it, no c-101 row (the restart would refuse it)" || fail "c-101 listed without WD_BOOT_ID"

# ---- 5. first run: the baseline ---------------------------------------------------
echo "=== 5. first run of this code: a day-old boot is the baseline"
box "$BT"
wd $(( BT + 86400 )); settle 1
[[ "$(started)" == 0 ]] && pass "a boot a day old, no boot.seen: nothing started" || fail "baseline started: $(ids)"
[[ "$(cat "$W/boot.seen" 2>/dev/null)" == "$BT" ]] && grep -q "baseline" "$D/wd.log" && pass "recorded as the baseline" || fail "no baseline: $(grep BOOT "$D/wd.log")"
B2=$(( BT + 90000 ))
printf 'btime %s\n' "$B2" > "$T/proc/stat"
verdict c-101 $(( B2 - 30 )); verdict c-102 $(( B2 - 50 ))
echo "$(( B2 - 120 ))" > "$W/last.tick"; touch "$T/fresh"
wd $(( B2 + 60 )); settle 0
[[ "$(started)" == 0 && -f "$W/resume" ]] && pass "the next boot: its first tick is a resume, nothing started yet" || fail "next boot, first tick: '$(ids)'"
wd $(( B2 + 300 )); settle 2
[[ "$(ids)" == "c-101 c-102" ]] && pass "the next boot is handled: c-101 and c-102 restarted" || fail "next boot: '$(ids)'"

# ---- 6. fenced, dry run -----------------------------------------------------------
echo "=== 6. a fenced box starts nothing; a dry run starts and records nothing"
box "$BT"; wd $(( BT + 60 ))
WD_EXTRA='spl_wd_box_fenced() { return 0; }' wd $(( BT + 300 )); settle 1
[[ "$(started)" == 0 ]] && grep -q 'fenced' "$D/wd.log" && pass "fenced (spl_wd_box_fenced): nothing started, logged" || fail "fenced: $(ids)"
[[ ! -f "$W/boot.seen" ]] && pass "fenced: the boot is retried (no boot.seen)" || fail "fenced wrote boot.seen"
WD_EXTRA='spl_wd_box_fenced() { return 1; }' wd $(( BT + 330 )); settle 2
[[ "$(ids)" == "c-101 c-102" ]] && pass "the fence lifted: the next tick restarts c-101 and c-102" || fail "after the fence: '$(ids)'"
box "$BT"; wd $(( BT + 60 )) 1
wd $(( BT + 300 )) 1; settle 1
[[ "$(started)" == 0 && ! -f "$W/boot.seen" && ! -d "$W/boot.d" ]] && pass "dry run: nothing started, nothing recorded" || fail "dry run: $(ids); $(ls "$W")"
grep -q 'would restart' "$D/wd.log" && pass "dry run: 'would restart' logged" || fail "dry run log: $(grep BOOT "$D/wd.log")"

# ---- 7. the old @reboot line retired ----------------------------------------------
echo "=== 7. the boot restore's @reboot line retired after the drill"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' > "$T/bin/crontab"
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/agent-boot-restore-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
tag='# csi-spl:agent-boot-restore'
printf '5 * * * * x # csi-spl:orch-rotate\n@reboot %s/csi-spl-orc/src/bash/scripts/agent-boot-restore-cron.sh >> %s/log/cron.out 2>&1 %s\n' "$SRC" "$T" "$tag" > "$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" BOOT_CRON_LOG_DIR="$T/log" \
      PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-agent-boot-restore-install-cron.func.sh"
    do_spl_agent_boot_restore_install_cron' 2>&1
}
before="$(md5sum < "$T/crontab")"
cron BOOT_CRON_ACTION=retire >/dev/null
[[ "$(md5sum < "$T/crontab")" == "$before" && ! -e "$T/log/retired" ]] && pass "retire, dry run: nothing touched" || fail "retire dry run touched something"
out="$(cron BOOT_CRON_ACTION=retire DRY_RUN=0)"; rc=$?
[[ "$rc" == 0 ]] && ! grep -qF "$tag" "$T/crontab" && grep -q orch-rotate "$T/crontab" && pass "retire: the @reboot line is out, the other line kept" || fail "retire rc=$rc: $out; $(cat "$T/crontab")"
[[ -s "$T/log/retired" ]] && pass "retire: the marker <log dir>/retired" || fail "no retired marker"
out="$(cron DRY_RUN=0)"
! grep -qF "$tag" "$T/crontab" && grep -q 'SKIP the boot restore was retired' <<<"$out" && pass "a later install (re-provision) skips: the line stays out" || fail "install after retire: $out"
cron BOOT_CRON_ACTION=check >/dev/null && pass "check passes while retired and out" || fail "check after retire: $(cron BOOT_CRON_ACTION=check)"
out="$(cron DRY_RUN=0 BOOT_CRON_FORCE=1)"
grep -qF "$tag" "$T/crontab" && [[ ! -e "$T/log/retired" ]] && pass "control: BOOT_CRON_FORCE=1 installs it again, marker gone" || fail "force install: $out"

echo
if (( fails == 0 )); then echo "wd-reboot: all passed"; else echo "wd-reboot: $fails failed"; fi
exit $(( fails > 0 ))
