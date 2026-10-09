#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: sat drill 4 (2026-10-09, defect 1): a 6.1 hold (spec 102,
#          <id>/lifetime/heldout) written in drill 3 outlived the seats'
#          restore BY HAND, so the next boot pass left them alone ("held out
#          until the admin clears it"). The hold still never expires; a
#          restore by hand is the admin's clearing act (restore-core.inc.sh
#          _rs_clear_hold). Sandbox: the real restore-claude.sh with a stub
#          CLI, then the boot branch of do_spl_watchdog with ps, tmux, send
#          and the restart stubbed (as wd-reboot.tst.sh).
#   1. c-201 and c-202 ran here before the boot, both held out (lifetime +
#      <WD_DIR>/<id>.heldout); c-201 is restored by hand: its hold goes,
#      wd.log has HOLD-CLEARED with the old reason, and the boot pass
#      starts c-201
#   2. control: c-202, not restored, stays held out and is not started
#   3. control: the same hand restore with RESTORE_KEEP_HOLD=1 (the
#      automatic identity restore) keeps the hold; the boot pass starts
#      nothing; RESTORE_PRINT=1 (a plan) keeps it too
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
BT=1800000000
S="$T/spool"; D="$S/dispatch"; W="$D/wd"
ADAPTER="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/restore-claude.sh"
mkdir -p "$T/bin" "$T/sit" "$T/tmux"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$T/box.env"

printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
printf '#!/usr/bin/env bash\ncase "$1" in list-panes) cat "%s/tmux/panes" ;; esac\nexit 0\n' "$T" > "$T/bin/tmux"
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\necho "takeover $ID cause=$CAUSE" >> "%s/takeovers"\n' "$T" > "$T/bin/takeover"
printf '#!/usr/bin/env bash\necho "claude $*" >> "%s/claude.log"\n' "$T" > "$T/bin/claude"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --norm|--scrub) cat ;; esac\nexit 0\n' > "$T/sit/s3.sh"
chmod +x "$T/bin/"* "$T/sit/"*

row() {
  mkdir -p "$S/$1/lifetime" "$S/$1/inbox" "$T/wt/$1"
  printf '%s\tclaude\t%%9\t%s\t20270115T0600Z\n' "$1" "$T/wt/$1" >> "$S/registry.tsv"
  echo "OK $(( BT - 30 ))" > "$D/wd.$1"; touch -d "@$(( BT - 30 ))" "$D/wd.$1"
  echo "2027-01-15T05:58:00Z 3 restarts in the last hour, then S3 again" > "$S/$1/lifetime/heldout"
  echo "$(( BT - 7000 ))" > "$W/$1.heldout"
}
box() {
  rm -rf "${S:?}" "${T:?}/proc" "${T:?}/wt" "${T:?}/takeovers" "${T:?}/sent" "${T:?}/claude.log"
  mkdir -p "$W" "$T/proc" "$T/wt"; : > "$T/ps"; : > "$T/tmux/panes"; : > "$S/registry.tsv"
  cp "$T/box.env" "$S/box.env"; touch "$S/.mirror-off"
  printf 'cpu  1 2 3\nbtime %s\nprocesses 1\n' "$BT" > "$T/proc/stat"
  echo "$(( BT - 120 ))" > "$W/last.tick"; touch "$T/fresh"
  row c-201; row c-202
}
# hand <id> [env...]: the real adapter, by hand, the CLI a stub
hand() {
  env -u TMUX -u TMUX_PANE SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" CLAUDE_BIN="$T/bin/claude" SPOOL_AGENT_PTY=0 "${@:2}" \
    timeout 30 bash "$ADAPTER" "$1" "$T/wt/$1" "sid-$1" < /dev/null > "$T/hand.out" 2>&1
}
wd_env=(PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc"
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover"
  WD_SITUATIONS="$T/sit" LEASE_TRANSCRIPT_CMD=true)
wd() {
  if [[ -f "$T/fresh" ]]; then rm -f "${T:?}/fresh"; else echo "$(( $1 - 30 ))" > "$W/last.tick"; fi
  env "${wd_env[@]}" LEASE_NOW="$1" WD_TICKS=1 WD_TICK=30 DRY_RUN=0 bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    do_spl_watchdog' > "$T/out" 2>&1
  if grep -q ERR-TRAP "$T/out"; then fail "the ERR trap fired: $(grep -m3 ERR-TRAP "$T/out")"; fi
}
started() { grep -c . "$T/takeovers" 2>/dev/null || echo 0; }
settle() { for _ in $(seq 1 40); do (( $(started) >= $1 )) && break; sleep 0.05; done; sleep 0.3; }
ids() { awk '{print $2}' "$T/takeovers" 2>/dev/null | sort | paste -sd' ' -; }
boot() { wd $(( BT + 60 )); wd $(( BT + 300 )); settle "$1"; }

# ---- 1 + 2 ---------------------------------------------------------------------
echo "=== 1. a held-out id restored by hand comes back at the boot; 2. one not restored stays held out"
box
hand c-201
grep -q 'claude --name c-201@box1 .*--resume sid-c-201' "$T/claude.log" 2>/dev/null && pass "the hand restore ran the CLI" || fail "no CLI run: $(cat "$T/hand.out")"
[[ ! -e "$S/c-201/lifetime/heldout" && ! -e "$W/c-201.heldout" ]] && pass "1. c-201's hold is cleared (lifetime/heldout and <WD_DIR>/c-201.heldout)" ||
  fail "1. c-201 still held: $(ls "$S/c-201/lifetime" "$W" 2>&1 | tr '\n' ' ')"
grep -q 'HOLD-CLEARED OK c-201: restored by hand (restore-claude.sh as .*was: 2027-01-15T05:58:00Z 3 restarts' "$D/wd.log" 2>/dev/null &&
  pass "1. wd.log: HOLD-CLEARED with the old reason" || fail "1. wd.log: $(cat "$D/wd.log" 2>/dev/null)"
boot 1
[[ "$(ids)" == "c-201" ]] && pass "1. the boot pass starts c-201 (and only it)" || fail "1. started: '$(ids)', want 'c-201'"
grep -qF "c-202 left alone: held out until the admin clears it" "$D/wd.log" && pass "2. control: c-202, not restored, is left alone: held out" ||
  fail "2. wd.log: $(grep BOOT "$D/wd.log" | tail -3)"
[[ -s "$S/c-202/lifetime/heldout" && -s "$W/c-202.heldout" ]] && pass "2. control: c-202's hold is untouched" || fail "2. c-202's hold went"

# ---- 3 -------------------------------------------------------------------------
echo "=== 3. control: the automatic restore (RESTORE_KEEP_HOLD=1) and a plan keep the hold"
box
hand c-201 RESTORE_KEEP_HOLD=1
grep -q 'claude --name c-201' "$T/claude.log" 2>/dev/null && pass "3. the automatic restore ran the CLI" || fail "3. no CLI run: $(cat "$T/hand.out")"
[[ -s "$S/c-201/lifetime/heldout" && -s "$W/c-201.heldout" ]] && pass "3. RESTORE_KEEP_HOLD=1: the hold stays" || fail "3. the hold went"
hand c-201 RESTORE_PRINT=1
[[ -s "$S/c-201/lifetime/heldout" ]] && pass "3. RESTORE_PRINT=1 (a plan): the hold stays" || fail "3. a plan cleared the hold"
boot 0
[[ "$(started)" == 0 ]] && pass "3. the boot pass starts nothing: both held out" || fail "3. started: '$(ids)'"

echo
if (( fails == 0 )); then echo "wd-heldout-hand-restore: all passed"; else echo "wd-heldout-hand-restore: $fails failed"; fi
exit $(( fails > 0 ))
