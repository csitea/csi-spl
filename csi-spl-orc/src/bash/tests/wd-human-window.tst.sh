#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the watchdog's human client guard keys on the agent's WINDOW, not
#          its tmux session (c-491, t1 637269bb: on a box whose fleet windows
#          share the owner's session, an owner typing anywhere refused
#          every guarded restart). One tick of do_spl_watchdog in a sandbox,
#          as wd-situations.tst.sh runs it: processes a ps stub + a fake
#          /proc, tmux a stub keeping panes ("...\t<window id>") and clients
#          ("<session> <activity> <window id>") in files, spool-send.sh and
#          the takeover stubs that log, the clock LEASE_NOW.
#   1. S1: the owner active in ANOTHER window of the same session -> the ring
#      runs; control: active in THAT window -> refused
#   2. S2 (login): another window -> ONE blocker; control: that window ->
#      refused, nothing sent
#   3. S3 (the session died): another window -> takeover; control: that
#      window -> refused (the restart renames and closes that window)
#   4. a client line with no window id (an older capture) still counts on
#      its session -> refused; control: that client idle past WD_HUMAN_IDLE
#      -> the takeover runs
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
FX="$TEST_DIR/fixtures/wd-situations"
FL="$TEST_DIR/fixtures/fleet-lease"
T0=1800000000   # 2027-01-15T08:00:00Z
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$S/peer"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
cat > "$T/bin/tmux" <<'STUB'
#!/usr/bin/env bash
P="$T/tmux/panes"; cmd="$1"; shift; tgt="" esc=0
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -e) esc=1; shift ;; -F) shift 2 ;; -a|-p) shift ;; *) a="$1"; shift ;; esac; done
case "$cmd" in
  list-panes) cat "$P" ;;
  list-clients) cat "$T/tmux/clients" 2>/dev/null ;;
  capture-pane) [ -f "$T/tmux/screen.$tgt" ] || exit 1; cat "$T/tmux/screen.$tgt"
    if [ "$esc" = 1 ]; then printf '────────\n❯ \n────────\n'; fi ;;
  send-keys) echo "keys $tgt $a" >> "$T/tmux/log" ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
cat > "$T/bin/takeover" <<'STUB'
#!/usr/bin/env bash
echo "takeover $ID $REASON" >> "$T/takeovers"
mkdir -p "$SPOOL_ROOT/$ID/lifetime"; echo "$LEASE_NOW $CAUSE" >> "$SPOOL_ROOT/$ID/lifetime/restarts"
STUB
printf '#!/usr/bin/env bash\ncat "%s/tr.$1" 2>/dev/null\n' "$T" > "$T/bin/tr"
chmod +x "$T/bin/"*
export T

reset_box() {
  rm -rf "$D" "$S"/c-* "$T/sent" "$T/takeovers" "$T/tmux/log" "$T/proc"; mkdir -p "$D" "$T/proc"; rm -f "$T/tmux/screen."*
  : > "$T/ps"; : > "$T/tmux/panes"; : > "$T/tmux/clients"
}
# agent <id> <pane> <pid|-> [screen]: pane %N sits in window @N of session $1
agent() {
  local id="$1" pane="$2" pid="$3" scr="${4:-$FX/idle.pane}" shellpid
  shellpid=$(( ${pane#%} + 5000 ))
  mkdir -p "$S/$id/inbox"
  printf '%s\t%s\t$1\t%s@box1 a lane\t%s\t@%s\n' "$pane" "$shellpid" "$id" sh "${pane#%}" >> "$T/tmux/panes"
  echo "$shellpid 1 3600 sh" >> "$T/ps"
  cp "$scr" "$T/tmux/screen.$pane"
  if [[ "$pid" != - ]]; then
    echo "$pid $shellpid 3600 claude" >> "$T/ps"
    mkdir -p "$T/proc/$pid"; printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$pid/environ"
  fi
}
# owner <window id|-> <s ago>: the owner's client in session $1, showing that window
owner() { if [[ "$1" == - ]]; then echo "\$1 $((T0 - $2))"; else echo "\$1 $((T0 - $2)) $1"; fi > "$T/tmux/clients"; }
wd() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" \
    WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover" \
    LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_NOW="${NOW:-$T0}" WD_TICKS=1 WD_TICK=100 DRY_RUN=0 bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    do_spl_watchdog' 2>&1 | tee -a "$T/all.out"
}
settle() { for _ in $(seq 1 20); do [[ -s "$T/takeovers" ]] && return; sleep 0.1; done; }
human='a human client was active 20s ago'

# 1. S1: a lane's task waits 130 s past its last progress -> the ring
s1_lane() {
  reset_box; agent c-931 %1 4031; agent c-932 %2 4032
  echo '{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"content":[{"type":"text","text":"done"}]}}' > "$T/tr.4031"
  echo '{"v":1,"kind":"task","from":"c-002","to":"c-931","body":"do"}' > "$S/c-931/inbox/m.json"
  touch -d "@$((T0 - 130))" "$S/c-931/inbox/m.json"
}
s1_lane; owner @2 20; out="$(wd)"
grep -q 'c-931 HIT S1 age=130 .*-> ring' <<<"$out" && grep -q -- '--to c-931' "$T/sent" 2>/dev/null &&
  pass "1. S1: the owner active in ANOTHER window of the same session -> the ring runs" || fail "1. S1 other window: $out"
s1_lane; owner @1 20; out="$(wd)"
grep -q "c-931 HIT S1 .*would ring ($human)" <<<"$out" && [[ ! -s "$T/sent" ]] &&
  pass "1. control: the owner active in THAT window -> refused, no ring" || fail "1. S1 that window: $out"

# 2. S2: the login screen of 2026-10-05; debounce 2 -> two ticks
s2_lane() {
  reset_box; agent c-933 %3 4033 "$FL/login-expired-2026-10-05.pane"; agent c-934 %4 4034
  cp "$FL/login-expired.jsonl" "$T/tr.4033"
}
s2_lane; owner @4 20; NOW=$T0 wd >/dev/null; out="$(NOW=$((T0 + 30)) wd)"
grep -q 'c-933 HIT S2 kind=login' <<<"$out" && [[ "$(grep -c -- '--to orchestrator --kind blocker --task wd-c-933' "$T/sent" 2>/dev/null)" == 1 ]] &&
  pass "2. S2: the owner in another window -> ONE blocker" || fail "2. S2 other window: $out / $(cat "$T/sent" 2>/dev/null)"
s2_lane; owner @3 20; NOW=$T0 wd >/dev/null; owner @3 20; out="$(NOW=$((T0 + 30)) wd)"
grep -q "c-933 HIT S2 kind=login.*would dm (a human client was active" <<<"$out" && [[ ! -s "$T/sent" ]] &&
  pass "2. control: the owner in THAT window -> refused, nothing sent" || fail "2. S2 that window: $out / $(cat "$T/sent" 2>/dev/null)"

# 3. S3: the harness died, a bare shell in its window; debounce 2
s3_lane() { reset_box; agent c-935 %5 -; agent c-936 %6 4036; }
s3_lane; owner @6 20; NOW=$T0 wd >/dev/null; out="$(NOW=$((T0 + 30)) wd)"; settle
grep -q 'c-935 HIT S3 .*-> takeover$' <<<"$out" && grep -qx 'takeover c-935 S3' "$T/takeovers" &&
  pass "3. S3 (died): the owner in another window -> takeover" || fail "3. S3 other window: $out"
s3_lane; owner @5 20; NOW=$T0 wd >/dev/null; out="$(NOW=$((T0 + 30)) wd)"
grep -q "c-935 HIT S3 .*would takeover (a human client was active" <<<"$out" && [[ ! -s "$T/takeovers" ]] &&
  pass "3. control: the owner in THAT window -> refused (its window is renamed and closed)" || fail "3. S3 that window: $out"

# 4. no window id on the client line: the session still counts
s3_lane; owner - 20; NOW=$T0 wd >/dev/null; out="$(NOW=$((T0 + 30)) wd)"
grep -q "c-935 HIT S3 .*would takeover (a human client was active" <<<"$out" && [[ ! -s "$T/takeovers" ]] &&
  pass "4. a client line with no window id counts on its session -> refused" || fail "4. no window id: $out"
s3_lane; owner - 300; NOW=$T0 wd >/dev/null; out="$(NOW=$((T0 + 30)) wd)"; settle
grep -qx 'takeover c-935 S3' "$T/takeovers" && pass "4. control: that client idle 330 s -> the takeover runs" || fail "4. idle: $out"

grep -q ERR-TRAP "$T/all.out" && fail "no tick may fire ./run's ERR trap: $(grep -m3 ERR-TRAP "$T/all.out")" || pass "no tick fired ./run's ERR trap"

echo "wd-human-window: $fails failure(s)"
exit $(( fails > 0 ))
