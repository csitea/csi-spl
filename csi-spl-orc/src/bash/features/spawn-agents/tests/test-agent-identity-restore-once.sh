#!/usr/bin/env bash
# test-agent-identity-restore-once.sh — a restore starts each agent id at most
# once (SPL-3771). A box reboot 2026-10-26: two @reboot jobs (the
# agent-boot-restore cron and the box-sessions boot) each ran a full restore
# pass; both planned m-799 before either started anything, and the second
# started it again 13 s after the first ended and freed the id lock: two live
# sessions carried one id. The plan is read once, so each id is read again,
# under its id lock, right before its start.
#
# The second pass's stale plan is replayed by a python3 shim (its FIRST
# restore-plan call prints the plan saved before the first pass); every other
# call reaches the real python3. The fake restore-mistral.sh becomes a process
# with argv[0]=vibe carrying SPOOL_AGENT_ID, as the real CLI would.
#
#   1. two passes, the second on its stale plan: each id is started once; the
#      second pass names each with "SKIP ... a live window already carries it"
#      ("already running (pid N)" when only its live process carries the id)
#   2. a worktree gone between the plan and the start: REFUSEd with one line
#      naming the id and the path, the adapter is never run in another cwd
#   3. one id listed twice in one plan: started once, the second "already
#      started by this run"
#   4. control: a window named for the id whose pane is an idle shell (a
#      finished restore's "bash --norc") does not hold the id: it is started
#   5. control: the dry run plans, re-checks and starts nothing
#   Red control: IR_FUNC=<the file before the fix> -> 1, 2 and 3 fail.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID
W="$T_TMP/wt"; A="$T_TMP/adapters"; BIN="$T_TMP/bin"
mkdir -p "$W" "$A" "$BIN" "$SPOOL_ROOT/agents" "$SPOOL_ROOT/dispatch"
export IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=0
export IDENTITY_RESTORE_SINCE=2026-10-01T03:00:00Z IDENTITY_RESTORE_WINDOW=15 IDENTITY_RESTORE_SESSION=t
export ROTATE_LOG="$SPOOL_ROOT/dispatch/rotate.log"
. "$T_FEAT/lib/agent-identity.inc.sh"
IR_FUNC="${IR_FUNC:-$T_REPO/csi-spl-orc/src/bash/run/spl-agent-identity-restore.func.sh}"

# restore-mistral.sh ID RUNDIR SID [BRIEF]: one line per start, then a live CLI.
cat > "$A/restore-mistral.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> "$T_TMP/started"
cd "\$2" || exit 1
export SPOOL_AGENT_ID="\$1"
exec -a vibe sleep 600
EOF
chmod +x "$A/restore-mistral.sh"

REAL_PY="$(command -v python3)"
cat > "$BIN/python3" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" restore-plan "*) if [ -f "$T_TMP/stale.plan" ]; then cat "$T_TMP/stale.plan"; rm -f "$T_TMP/stale.plan"; exit 0; fi ;;
esac
exec "$REAL_PY" "\$@"
EOF
chmod +x "$BIN/python3"

record() {  # ID WORKTREE
  python3 - "$SPOOL_ROOT/agents/$1.json" "$@" <<'PY'
import json, sys
f, i, wt = sys.argv[1:4]
json.dump({"v": 1, "id": i, "kind": "mistral", "session_id": None, "worktree": wt, "title": "lane " + i[-2:],
           "user": None, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": "%9",
           "alive": True, "updated_at": "2026-10-01T02:00:00Z"}, open(f, "w"), indent=1, sort_keys=True)
PY
}
plan() { ai_panes | ai_py restore-plan --since "$IDENTITY_RESTORE_SINCE" --agent-user "$(id -un)"; }
act() {
  env PATH="$BIN:$PATH" PROJ_PATH="$T_REPO/csi-spl-orc" IR_FUNC="$IR_FUNC" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$IR_FUNC"; do_spl_agent_identity_restore'
}
starts() { grep -c "^$1|" "$T_TMP/started" 2>/dev/null || true; }

t_tmux
mkdir -p "$W/m-801" "$W/m-802" "$W/m-803"
record m-801 "$W/m-801"; record m-802 "$W/m-802"; record m-803 "$W/m-803"

# --- 5 the dry run (first: nothing is live yet) ----------------------------------
before="$(tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a | wc -l)"
out="$(act)"
has "5. the dry run plans m-801" "RESTORE m-801: mistral session - in $W/m-801" "$out"
eq "5. ... and starts nothing" "$before" "$(tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a | wc -l)"

# --- 1 + 2 two passes, the second on the plan made before the first ---------------
plan > "$T_TMP/stale.plan"
has "1. the saved plan lists m-801, m-802, m-803" "RESTORE	m-803	" "$(cat "$T_TMP/stale.plan")"
cp "$T_TMP/stale.plan" "$T_TMP/stale.keep"
mv "$T_TMP/stale.plan" "$T_TMP/stale.hold"
out1="$(act DRY_RUN=0 IDENTITY_RESTORE_IDS="m-801 m-802")"
has "1. the first pass starts m-801" "STARTED m-801: mistral session - in $W/m-801" "$out1"
sleep 1
rm -rf "$W/m-803"
# m-802's window no longer names it: only its live process carries the id
p802="$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{window_name}' | awk '$2 ~ /^m-802/ { print $1; exit }')"
tmux -S "$SPOOL_TMUX_SOCKET" rename-window -t "$p802" "renamed"
mv "$T_TMP/stale.hold" "$T_TMP/stale.plan"
out2="$(act DRY_RUN=0)"
sleep 1
eq "1. m-801 was started once, not twice" 1 "$(starts m-801)"
eq "1. m-802 was started once, not twice" 1 "$(starts m-802)"
has "1. the second pass names m-801 as carried by a live window" "SKIP    m-801: a live window already carries it" "$out2"
has "1. m-802, in a window not named for it, is found by its live process" "SKIP    m-802: already running (pid " "$out2"
hasnt "1. the second pass does not start m-801" "STARTED m-801" "$out2"
eq "2. m-803 (worktree gone after the plan) was never started" 0 "$(starts m-803)"
has "2. one line names m-803 and its missing worktree" "REFUSE  m-803: its worktree $W/m-803 is gone; not started in another directory" "$out2"

# --- 3 one id listed twice in one plan ---------------------------------------------
mkdir -p "$W/m-804"; record m-804 "$W/m-804"
grep -P '^RESTORE\tm-804\t' <(plan) > "$T_TMP/m804.line"
cat "$T_TMP/m804.line" "$T_TMP/m804.line" > "$T_TMP/stale.plan"
out3="$(act DRY_RUN=0)"
sleep 1
eq "3. m-804, listed twice, was started once" 1 "$(starts m-804)"
has "3. its second line is named, not started" "SKIP    m-804: already started by this run" "$out3"

# --- 4 control: an idle shell in a window named for the id does not hold it --------
mkdir -p "$W/m-805"; record m-805 "$W/m-805"
t_window "m-805 lane 05" "bash --norc" >/dev/null
sleep 0.5
out4="$(act DRY_RUN=0 IDENTITY_RESTORE_IDS=m-805)"
sleep 1
eq "4. m-805, whose window holds only an idle shell, is started" 1 "$(starts m-805)"
has "4. ... in its own worktree" "STARTED m-805: mistral session - in $W/m-805" "$out4"

t_done
