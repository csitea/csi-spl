#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the watchdog's S2 login line asks for a human only when login-check
#          has failed or given up (SPL-5153: on 2026-11-07 "a human runs
#          /login" went out for seats login-check restored minutes later with
#          nobody at the keyboard). One tick of do_spl_watchdog in a sandbox,
#          as wd-human-window.tst.sh runs it: processes a ps stub + a fake
#          /proc, tmux a stub, spool-send.sh a stub that logs, the clock
#          LEASE_NOW, login-check's state a directory the test writes.
#   1. probe ok and fresh -> ONE note "login-check is on it", no blocker, no
#      request for a human
#   2. red control: the banner outlives the grace -> ONE blocker that calls
#      the human, after the note; a later tick sends nothing more
#   3. red controls, the human at once: the probe says expired; no probe
#      file; a stale probe; a harness login-check does not cover; a screen
#      login-check does not read; a restore that did not hold; an episode
#      clock that is empty, garbage, in the future or not a file
#   4. a seat login-check restored a minute ago, its old banner still up ->
#      on it; the last age that still counts as on it, for the probe (900 s)
#      and for a restore that did not hold (3600 s is past the relapse window)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
FL="$TEST_DIR/fixtures/fleet-lease"
T0=1800000000   # 2027-01-15T08:00:00Z
S="$T/spool"; D="$S/dispatch"; LC="$T/lc"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$S/peer" "$LC"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
cat > "$T/bin/tmux" <<'STUB'
#!/usr/bin/env bash
P="$T/tmux/panes"; cmd="$1"; shift; tgt="" esc=0
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -e) esc=1; shift ;; -F) shift 2 ;; -a|-p) shift ;; *) shift ;; esac; done
case "$cmd" in
  list-panes) cat "$P" ;;
  capture-pane) [ -f "$T/tmux/screen.$tgt" ] || exit 1; cat "$T/tmux/screen.$tgt"
    if [ "$esc" = 1 ]; then printf '────────\n❯ \n────────\n'; fi ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\necho "takeover $ID" >> "%s/takeovers"\n' "$T" > "$T/bin/takeover"
printf '#!/usr/bin/env bash\ncat "%s/tr.$1" 2>/dev/null\n' "$T" > "$T/bin/tr"
chmod +x "$T/bin/"*
export T

ID=c-951; PANE=%1; PID=4051
reset_box() {
  rm -rf "$D" "$S"/c-* "$T/sent" "$T/takeovers" "$T/proc" "$LC" "$S/registry.tsv"
  mkdir -p "$D" "$T/proc/$PID" "$LC" "$S/$ID/inbox"
  printf '%s\t5001\t$1\t%s@box1 a lane\tsh\t@1\n' "$PANE" "$ID" > "$T/tmux/panes"
  printf '5001 1 3600 sh\n%s 5001 3600 claude\n' "$PID" > "$T/ps"
  printf 'SPOOL_AGENT_ID=%s\0' "$ID" > "$T/proc/$PID/environ"
  cp "$FL/login-expired-2026-10-05.pane" "$T/tmux/screen.$PANE"
  cp "$FL/login-expired.jsonl" "$T/tr.$PID"
}
probe() { printf '%s %s\n' "$1" "$2" > "$LC/probe"; }
wd() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" \
    LOGIN_STATE_DIR="$LC" WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover" \
    LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_NOW="$1" WD_TICKS=1 WD_TICK=100 DRY_RUN=0 bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    do_spl_watchdog' 2>&1 | tee -a "$T/all.out"
}
# debounce 2: the second tick acts
two_ticks() { wd "$T0" >/dev/null; wd "$((T0 + 30))"; }
# at <s after T0>: a fresh probe and two ticks; a jump of the clock past 3
# ticks is a resume (spl_wd_resume), whose tick acts on nothing
at() { probe "$((T0 + $1))" ok; wd "$((T0 + $1 - 30))" >/dev/null; wd "$((T0 + $1))" >/dev/null; }
n_sent() { grep -cF -- "$1" "$T/sent" 2>/dev/null || true; }
BLOCKER="--to orchestrator --kind note --ask blocker --task wd-$ID"
HUMAN='a human runs /login'
ON_IT='login-check is on it'
# calls_human <label> <why, a substring of the blocker>: run after the ticks
calls_human() {
  if [[ "$(n_sent "$BLOCKER")" == 1 ]] && grep -qF "$HUMAN" "$T/sent" && grep -qF "$2" "$T/sent" && ! grep -qF "$ON_IT" "$T/sent"; then
    pass "$1"
  else fail "$1: $(cat "$T/sent" 2>/dev/null)"; fi
}

# 1. login-check healthy: it is on it
reset_box; probe "$T0" ok; two_ticks >/dev/null
if [[ "$(n_sent "$ON_IT")" == 1 && "$(n_sent "--ask blocker")" == 0 ]] && ! grep -qF "$HUMAN" "$T/sent"; then
  pass "1. probe ok: ONE note that login-check is on it, no blocker, no human"
else fail "1. on it: $(cat "$T/sent" 2>/dev/null)"; fi

# 2. the same episode, past the grace: the human after all, once
at 629
if [[ "$(n_sent "--ask blocker")" == 0 ]]; then pass "2. inside the grace: still no blocker"; else fail "2. inside: $(cat "$T/sent")"; fi
at 930
if [[ "$(n_sent "$BLOCKER")" == 1 && "$(n_sent "$HUMAN")" == 1 && "$(n_sent "did not restore it")" == 1 && "$(n_sent "$ON_IT")" == 1 ]]; then
  pass "2. control: past the grace, ONE blocker calls the human"
else fail "2. past the grace: $(cat "$T/sent" 2>/dev/null)"; fi
at 990
[[ "$(n_sent "$BLOCKER")" == 1 ]] && pass "2. a later tick sends nothing more" || fail "2. repeat: $(cat "$T/sent")"

# 3. what login-check cannot heal goes to the human at once
reset_box; probe "$T0" 'expired 401'; two_ticks >/dev/null
calls_human "3. control: the probe says expired -> the human" "login is expired"
reset_box; two_ticks >/dev/null
calls_human "3. control: no probe file (login-check never ran) -> the human" "login-check has not run"
reset_box; probe "$((T0 - 901))" ok; two_ticks >/dev/null
calls_human "3. control: a stale probe (login-check stopped) -> the human" "login-check last ran"
reset_box; probe "$T0" ok; printf '%s\tagy\n' "$ID" > "$S/registry.tsv"; two_ticks >/dev/null
calls_human "3. control: a harness login-check does not cover -> the human" "covers claude seats only"
reset_box; probe "$T0" ok; sed 's/Login expired · Please run \/login/Your organization has disabled this account/' "$FL/login-expired.jsonl" > "$T/tr.$PID"
two_ticks >/dev/null
calls_human "3. control: a screen login-check does not read -> the human" "does not act on this screen"
reset_box; probe "$T0" ok; echo "$((T0 - 1200))" > "$LC/restored.$ID"; two_ticks >/dev/null
calls_human "3. control: restored 20 min ago and back on the screen -> the human" "did not hold"
CLOCK="$D/wd/$ID.ep.S2.lc_since"
for shape in empty garbage future directory; do
  reset_box; probe "$T0" ok; mkdir -p "$D/wd"
  case "$shape" in
    empty) : > "$CLOCK" ;;
    garbage) echo garbage > "$CLOCK" ;;
    future) echo "$((T0 + 86400))" > "$CLOCK" ;;
    directory) mkdir "$CLOCK" ;;
  esac
  two_ticks >/dev/null
  calls_human "3. control: an episode clock that is $shape -> the human" "cannot read how long"
done

# 4. the resumed session still shows the old banner
reset_box; probe "$T0" ok; echo "$((T0 - 60))" > "$LC/restored.$ID"; two_ticks >/dev/null
if [[ "$(n_sent "$ON_IT")" == 1 && "$(n_sent "--ask blocker")" == 0 ]]; then
  pass "4. restored a minute ago, the old banner still up -> on it"
else fail "4. fresh restore: $(cat "$T/sent" 2>/dev/null)"; fi
# the acting tick is T0 + 30
on_it_at_edge() {
  if [[ "$(n_sent "$ON_IT")" == 1 && "$(n_sent "--ask blocker")" == 0 ]]; then pass "$1"; else fail "$1: $(cat "$T/sent" 2>/dev/null)"; fi
}
reset_box; probe "$((T0 - 870))" ok; two_ticks >/dev/null
on_it_at_edge "4. a probe exactly 900 s old is still fresh"
reset_box; probe "$T0" ok; echo "$((T0 + 30 - 3600))" > "$LC/restored.$ID"; two_ticks >/dev/null
on_it_at_edge "4. a restore exactly 3600 s old is past the relapse window"

grep -q ERR-TRAP "$T/all.out" && fail "no tick may fire ./run's ERR trap: $(grep -m3 ERR-TRAP "$T/all.out")"

echo "wd-login-line: $fails failure(s)"
exit $(( fails > 0 ))
