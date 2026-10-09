#!/usr/bin/env bash
# test-box-sessions.sh — save then restore on a PRIVATE tmux socket and a
# PRIVATE state dir (spec 069 lane Y2). Never touches the box's tmux server,
# its crontab or its state dir. The agent restore is a stub that plays
# do_spl_agent_boot_restore: it opens the seat's window, or (the failing
# control) opens nothing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"

T_PASS=0; T_FAIL=0
ok()  { T_PASS=$((T_PASS + 1)); echo "ok   - $*"; }
nok() { T_FAIL=$((T_FAIL + 1)); echo "FAIL - $*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) nok "$1 (missing '$2')" ;; esac; }
hasnt() { case "$3" in *"$2"*) nok "$1 (unexpected '$2')" ;; *) ok "$1" ;; esac; }

command -v tmux >/dev/null || { echo "SKIP - no tmux"; exit 0; }
unset TMUX TMUX_PANE SPOOL_TMUX_SOCKET BOX_SESSIONS_AGENT_RESTORE_CMD
T="$(mktemp -d)"
SOCK_DIR="$T/sock"; SOCK="$SOCK_DIR/default"
export BOX_SESSIONS_DIR="$T/state" BOX_SESSIONS_TMUX_SOCKET="$SOCK" HOME="$T/home"
export BOX_SESSIONS_SOCKET_WAIT=2 BOX_SESSIONS_LOCK_WAIT=2 BOX_SESSIONS_VERIFY_SEC=0
mkdir -p "$HOME" "$T/notes" "$T/logs" "$SOCK_DIR"; chmod 700 "$SOCK_DIR"
tm() { tmux -u -S "$SOCK" "$@"; }
cleanup() { tm kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

windows() { tm list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | sort | tr '\n' ' '; }
# The stub agent restore: opens a window carrying the seat's id, as the
# identity restore does ("<id>@<tag> <title>"), running something.
STUB_OK="tmux -u -S '$SOCK' new-window -d -t '=main:' -n 'c-901@box lane' \"bash -c 'sleep 300; :'\""

# ── 1. a workspace: two sessions, a live seat, an exited seat, shells ─────
tm new-session -d -s main -n notes -c "$T/notes"
tm new-window -d -t '=main:' -n 'c-901@box lane' "bash -c 'sleep 300; :'"
tm new-window -d -t '=main:' -n 'c-902@box gone' -c "$T/notes"
tm new-session -d -s work -n logs -c "$T/logs"
sleep 1
out="$(BOX_SESSIONS_SAVE_GRACE_SEC=0 bash "$SCRIPTS/save-sessions.sh" --stdout)"; rv=$?
eq "save exits 0" 0 "$rv"
has "save counts the seats" "4 windows (1 agent seats, 1 exited)" "$out"
st="$(cat "$BOX_SESSIONS_DIR/state.tsv")"
has "state: the live seat is an agent row" $'c-901@box lane\t' "$st"
has "state: c-901 kind agent" $'\tagent\tc-901' "$st"
has "state: c-902 at a bare prompt is exited" $'\texited\tc-902' "$st"
has "state: the shell keeps its cwd" $'main\t0\tnotes\t'"$T/notes"$'\t' "$st"
has "state: the second session" $'work\t0\tlogs\t'"$T/logs" "$st"
eq "one archive snapshot" 1 "$(ls "$BOX_SESSIONS_DIR"/archive/state.*.tsv | wc -l)"

# ── 2. it never clobbers a good state ──────────────────────────────────────
tm kill-server; sleep 0.3
before="$(md5sum < "$BOX_SESSIONS_DIR/state.tsv")"
out="$(bash "$SCRIPTS/save-sessions.sh" --stdout)"
has "no server: previous state kept" "previous state kept" "$out"
tm new-session -d -s main -n fresh
out="$(BOX_SESSIONS_SAVE_GRACE_SEC=600 bash "$SCRIPTS/save-sessions.sh" --stdout)"
has "young server, no restore yet: state kept" "younger than 600s" "$out"
eq "state unchanged by both" "$before" "$(md5sum < "$BOX_SESSIONS_DIR/state.tsv")"
flock "$BOX_SESSIONS_DIR/.lock" sleep 1.5 & holder=$!
sleep 0.5
BOX_SESSIONS_SAVE_GRACE_SEC=0 bash "$SCRIPTS/save-sessions.sh" --stdout > "$T/locked.out"
wait "$holder"
has "lock held: save skipped" "holds the lock - skipped" "$(cat "$T/locked.out")"
eq "state unchanged under the lock" "$before" "$(md5sum < "$BOX_SESSIONS_DIR/state.tsv")"

# ── 3. reboot: socket dir gone, no server; boot brings everything back ─────
tm kill-server; sleep 0.3; rm -rf "$SOCK_DIR"
BOX_SESSIONS_VERIFY_SEC=5 BOX_SESSIONS_AGENT_RESTORE_CMD="$STUB_OK" bash "$SCRIPTS/sessions-boot.sh" --foreground > "$T/boot.out" 2>&1; rv=$?
boot="$(cat "$T/boot.out")"
eq "boot exits 0" 0 "$rv"
eq "socket dir recreated 0700" 700 "$(stat -c %a "$SOCK_DIR" 2>/dev/null)"
w="$(windows)"
has "main:notes back" "main:notes " "$w"
has "work:logs back" "work:logs " "$w"
has "the seat is back" "main:c-901@box lane" "$w"
hasnt "the exited seat stays gone" "c-902" "$w"
hasnt "the placeholder is gone" "box-sessions-placeholder" "$w"
eq "notes window in its saved cwd" "$T/notes" "$(tm display -p -t '=main:notes' '#{pane_current_path}')"
has "verify line" "verify: 2 shell windows and 1 agent seats present" "$boot"
[ -e "$BOX_SESSIONS_DIR/boot-FAILED" ] && nok "no failure marker after a good boot" || ok "no failure marker after a good boot"
srv="$(tm display -p '#{pid} #{start_time}')"
[ -e "$BOX_SESSIONS_DIR/.restored.${srv%% *}.${srv##* }" ] && ok "restored stamp for this server" || nok "restored stamp for this server"
out="$(BOX_SESSIONS_SAVE_GRACE_SEC=600 bash "$SCRIPTS/save-sessions.sh" --stdout)"
has "after the boot the save trusts the young server" "3 windows (1 agent seats, 0 exited)" "$out"

# A second boot on a live server creates nothing twice.
BOX_SESSIONS_AGENT_RESTORE_CMD="" bash "$SCRIPTS/sessions-boot.sh" --foreground > "$T/boot2.out" 2>&1; rv=$?
eq "second boot exits 0" 0 "$rv"
eq "second boot: still 3 windows" 3 "$(tm list-windows -a | wc -l)"

# ── 4. FAILING CONTROL: the agent restore brings nothing back ──────────────
tm kill-server; sleep 0.3
cp "$BOX_SESSIONS_DIR/archive/"state.*.tsv "$T/snap.tsv" 2>/dev/null; snap="$(ls "$BOX_SESSIONS_DIR"/archive/state.*.tsv | tail -1)"
BOX_SESSIONS_AGENT_RESTORE_CMD="true" bash "$SCRIPTS/sessions-boot.sh" --foreground --state "$snap" > "$T/boot3.out" 2>&1; rv=$?
boot="$(cat "$T/boot3.out")"
eq "control: boot exits 1 when a seat is missing" 1 "$rv"
has "control: FAILED names the seat" "seat c-901;" "$boot"
has "control: marker names the seat" "seat c-901;" "$(cat "$BOX_SESSIONS_DIR/boot-FAILED" 2>/dev/null)"
has "control: the shells still came back" "main:notes " "$(windows)"

# A good boot afterwards clears the marker.
BOX_SESSIONS_VERIFY_SEC=5 BOX_SESSIONS_AGENT_RESTORE_CMD="$STUB_OK" bash "$SCRIPTS/sessions-boot.sh" --foreground --state "$snap" > /dev/null 2>&1; rv=$?
eq "recovery boot exits 0" 0 "$rv"
[ -e "$BOX_SESSIONS_DIR/boot-FAILED" ] && nok "marker cleared by a good boot" || ok "marker cleared by a good boot"

# ── 5. the boot log goes to the state dir without --foreground ─────────────
BOX_SESSIONS_AGENT_RESTORE_CMD="" bash "$SCRIPTS/sessions-boot.sh" --state "$snap" > "$T/quiet.out" 2>&1
eq "no stdout without --foreground" "" "$(cat "$T/quiet.out")"
has "boot.log written" "=== box-sessions boot done" "$(cat "$BOX_SESSIONS_DIR/boot.log")"

# ── 5b. a rotation's retiring window is not a window to bring back ────────
# box reboot 2026-10-09: state.tsv held c-003-1615Z-retiring (the old window of
# an hourly rotation, a bare shell) as a shell row; the boot made it, the box
# tag renamed it, and verify FAILED on it. The stub plays that rename.
tm kill-server; sleep 0.3
ret="$T/retiring.tsv"; cp "$snap" "$ret"
printf 'main\t9\tc-901-1615Z-retiring\t%s\t0\tshell\t-\n' "$T/notes" >> "$ret"
RENAME="tmux -u -S '$SOCK' rename-window -t 'main:c-901-1615Z-retiring' 'c-901@box ! -1615Z-retiring' 2>/dev/null; $STUB_OK"
BOX_SESSIONS_VERIFY_SEC=2 BOX_SESSIONS_AGENT_RESTORE_CMD="$RENAME" bash "$SCRIPTS/sessions-boot.sh" --foreground --state "$ret" > "$T/boot5.out" 2>&1; rv=$?
boot="$(cat "$T/boot5.out")"
eq "retiring: boot exits 0" 0 "$rv"
hasnt "retiring: the window is not made" "retiring" "$(windows)"
has "retiring: the skip is logged" "a rotation's retiring window" "$boot"
hasnt "retiring: verify does not want it" "retiring;" "$boot"

# ── 6. hygiene: no engine path, no literal home, no box user ───────────────
src="$(cat "$SCRIPTS"/*.sh)"
hasnt "no engine path" "ysg-box" "$src"
hasnt "no literal /home path" "/home/" "$src"
grep -q '^do_spl_agent_boot_restore()' "$SCRIPTS/../../../run/spl-agent-boot-restore.func.sh" \
  && ok "the default agent restore action exists" || nok "the default agent restore action exists"
for s in "$SCRIPTS"/*.sh; do bash -n "$s" && ok "parses: ${s##*/}" || nok "parses: ${s##*/}"; done

echo "-- $(basename "$0"): ${T_PASS} passed, ${T_FAIL} failed"
[ "$T_FAIL" -eq 0 ]
