#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a watcher seat is read-only (spec 165 3.3, row B4, SPL-4344). With a
#          `.watcher-role` marker in the sandbox spool root, every mutating
#          action refuses a caller whose PROCESS CHAIN holds a watcher, while
#          the caller names another seat: AGENT_ID=c-599, DESK_AGENT=c-002,
#          --from c-001. The chain is a FAKE /proc (SPL_WATCHER_PROC) built
#          here, in three shapes, each keyed on what the caller cannot set:
#            env   the watcher's agent process carries SPOOL_AGENT_ID=a-901;
#                  its child sets c-599 / c-002 (a child cannot rewrite it)
#            uid   a detached process (parent pid 1, environment cleared)
#                  whose real uid is the marker's user= (nobody)
#            pane  no id in any environ; the tmux window of its pane is a-902
#          Gates: do_spl_push_master, do_spl_take, do_spl_desk_reply,
#          spool-send.sh, the pre-push hook, spool_spawn_gate.
#   control: a lane's chain (c-777) passes every gate as before, and with no
#          marker on the box a watcher's chain passes too (nothing to key on).
#   R7 c-700 W1-W3: a hop named tmux / tmux-sh (real and fake /proc) is
#          still walked and the caller's own uid is checked first; a caller
#          adds panes (SPL_WATCHER_PANES_CMD, SPOOL_TMUX_SOCKET), never
#          removes the box socket's; a marker counts only when root owns it
#          (a test's own root excepted).
#   red control: in the CODE, never here: `return 0` as the first line of
#          spl_watcher_why (spool-env.inc.sh) lets every shape through, and
#          each refusal below fails; one plant per W1-W3 in the commit body.
# Hermetic: own spool root, fake /proc, fake pane list, stub reply and send;
# no hub, no tmux server, no push.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE 2>/dev/null || true
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../features/spawn-agents/tests/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
ORC="$(cd "$T_FEAT/../../../.." && pwd)"
RUN="$ORC/src/bash/run"
SS="$T_SCRIPTS/spool-send.sh"
HOOK="$T_FEAT/hooks/pre-push"
P="$T_TMP/proc"
ME="$(id -u)"
NOBODY="$(id -u nobody)"

# A fake process: PID, its parent, its comm, its real uid, then NAME=VAL
# environ entries. Pids above the kernel's pid_max (4194304) are never real.
mkproc() {  # PID PPID COMM UID [ENV...]
  local pid="$1" ppid="$2" comm="$3" uid="$4"
  shift 4
  mkdir -p "$P/$pid"
  printf '%s\n' "$comm" >"$P/$pid/comm"
  printf 'Name:\t%s\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$ppid" "$uid" "$uid" "$uid" "$uid" >"$P/$pid/status"
  if [ "$#" -gt 0 ]; then printf '%s\0' "$@" >"$P/$pid/environ"; else : >"$P/$pid/environ"; fi
}
mkproc 5000099 1 'tmux: server' "$ME"
# env: the watcher a-901's agent process, its Bash tool claiming other seats
mkproc 5000100 5000099 agy "$ME" SPOOL_AGENT_ID=a-901 MCP_BOT_AGENT_ID=a-901
mkproc 5000101 5000100 bash "$ME" SPOOL_AGENT_ID=c-599 AGENT_ID=c-599 DESK_AGENT=c-002 MCP_BOT_AGENT_ID=c-599
mkproc 5000102 5000101 bash "$ME" AGENT_ID=c-599 DESK_AGENT=c-002
# uid: detached, environment cleared, runs as the watcher's OS user
mkproc 5000200 1 bash "$NOBODY"
mkproc 5000201 5000200 bash "$NOBODY" AGENT_ID=c-599 DESK_AGENT=c-002
# pane: no id anywhere in the chain; its pane's window is a-902
mkproc 5000300 5000099 agy "$ME"
mkproc 5000301 5000300 bash "$ME" AGENT_ID=c-599 DESK_AGENT=c-002
# a lane, not a watcher
mkproc 5000400 5000099 claude "$ME" SPOOL_AGENT_ID=c-777
mkproc 5000401 5000400 bash "$ME" SPOOL_AGENT_ID=c-777 AGENT_ID=c-777
printf '#!/usr/bin/env bash\nprintf "5000300\\ta-902\\n5000400\\tc-777\\n"\n' >"$T_TMP/panes.sh"
chmod +x "$T_TMP/panes.sh"
export SPL_WATCHER_PROC="$P" SPL_WATCHER_PANES_CMD="$T_TMP/panes.sh"

marks_on() {
  mkdir -p "$SPOOL_ROOT/a-901" "$SPOOL_ROOT/a-902"
  printf 'user=nobody\n' >"$SPOOL_ROOT/a-901/.watcher-role"
  : >"$SPOOL_ROOT/a-902/.watcher-role"
}
marks_off() { rm -f "$SPOOL_ROOT"/a-90[12]/.watcher-role; }
mkdir -p "$SPOOL_ROOT/c-778/inbox" "$SPOOL_ROOT/c-001/inbox" "$SPOOL_ROOT/dispatch"
printf 'c-778\tclaude\t%%0\t/x\t20260101T000000Z\n' >>"$SPOOL_ROOT/registry.tsv"
jsons() { find "$SPOOL_ROOT" -name '*.json' 2>/dev/null | wc -l; }
declare -A PID=([env]=5000102 [uid]=5000201 [pane]=5000301)
declare -A WHO=([env]="watcher a-901 (by its environ)" [uid]="watcher nobody (by its uid)" [pane]="watcher a-902 (by its pane)")

# an action function in a clean shell, as the fake process PID; rc in $rc.
# FUNC_FILES: ':'-separated, the action's file last.
act() {  # PID FUNC_FILES FUNC [VAR=VAL ...]
  local pid="$1" files="$2" fn="$3"
  shift 3
  out="$(env SPL_WATCHER_PID="$pid" AGENT_ID=c-599 DESK_AGENT=c-002 PROJ_PATH="$ORC" "$@" bash -c '
    do_log() { echo "$*" >&2; }
    IFS=: read -r -a fs <<<"$1"
    for f in "${fs[@]}"; do source "$f"; done
    "$2"' _ "$files" "$fn" 2>&1)"; rc=$?
}
# take's own deps: without the gate it really posts (the stub) and records
TAKE_FILES="$ORC/lib/bash/funcs/spl-desk-box.func.sh:$RUN/spl-dispatch-lease.func.sh:$RUN/spl-take.func.sh"
send_as() {  # PID ARGS...
  local pid="$1"
  shift
  out="$(SPL_WATCHER_PID="$pid" bash "$SS" "$@" 2>&1)"; rc=$?
}
REPO="$T_TMP/repo"
git init -q "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c1
ln -s "$ORC" "$REPO/csi-spl-orc"
hook_as() {  # PID
  out="$(cd "$REPO" && printf 'refs/heads/x %s refs/heads/x %040d\n' "$(git rev-parse HEAD)" 0 |
    env SPL_WATCHER_PID="$1" SPL_PREPUSH_LOG_DIR="$T_TMP/pp" SPL_PREPUSH_OVERRIDE=1 bash "$HOOK" origin "$T_TMP/none.git" 2>&1)"; rc=$?
}
gate_as() {  # PID
  out="$(env SPL_WATCHER_PID="$1" SPOOL_AGENT_ID=c-001 bash -c '. "$1"; spool_spawn_gate' _ "$T_FEAT/lib/spool-env.inc.sh" 2>&1)"; rc=$?
}

marks_on
for s in env uid pane; do
  p="${PID[$s]}" w="${WHO[$s]}"
  # ---- push ----------------------------------------------------------------
  act "$p" "$RUN/spl-push-master.func.sh" do_spl_push_master PUSH_WORKTREE="$REPO" PUSH_STATE_DIR="$T_TMP/push-$s"
  eq "[$s] do_spl_push_master: refused, rc 1" 1 "$rc"
  has "[$s] …names the watcher and how it was read" "$w" "$out"
  check "[$s] …no push state written (no worker started)" test ! -e "$T_TMP/push-$s"
  # ---- take ----------------------------------------------------------------
  act "$p" "$TAKE_FILES" do_spl_take ENV=prd TENANT_ID=t1 DESK_TO=HUM-10 TAKE_PLAN=x DRY_RUN=0 TAKE_BOX=box-a \
    DESK_TASK=00000000-0000-4000-8000-0000000000a1 TAKE_REPLY_CMD="touch $T_TMP/reply.log.hit" TAKE_SEND=true
  eq "[$s] do_spl_take with DESK_AGENT=c-002: refused, rc 1" 1 "$rc"
  has "[$s] …names the action" "do_spl_take refused" "$out"
  check "[$s] …no take posted" test ! -e "$T_TMP/reply.log.hit"
  check "[$s] …no take.log row" test ! -e "$SPOOL_ROOT/dispatch/take.log"
  # ---- desk reply ----------------------------------------------------------
  act "$p" "$RUN/spl-desk-reply.func.sh" do_spl_desk_reply ENV=prd TENANT_ID=t1 DESK_BODY=x DRY_RUN=0
  eq "[$s] do_spl_desk_reply with DESK_AGENT=c-002: refused, rc 1" 1 "$rc"
  has "[$s] …names the watcher" "$w" "$out"
  # ---- spool send ----------------------------------------------------------
  n0="$(jsons)"
  send_as "$p" --from c-001 --to c-778 --kind result --no-poke --body 'ACCEPTED forged'
  eq "[$s] spool-send --from c-001 --kind result: refused, exit 10" 10 "$rc"
  has "[$s] …names the watcher" "$w" "$out"
  send_as "$p" --from c-599 --to orchestrator --kind note --no-poke --body x
  eq "[$s] spool-send --from c-599 (not the watcher's id) to orchestrator: refused" 10 "$rc"
  send_as "$p" --from a-901 --to c-778 --kind task --no-poke --body x
  eq "[$s] spool-send --kind task to a lane: refused" 10 "$rc"
  send_as "$p" --from a-901 --to orchestrator --kind blocker --no-poke --body x
  eq "[$s] spool-send --kind blocker to orchestrator: refused" 10 "$rc"
  send_as "$p" --to c-778 --poke-only
  eq "[$s] spool-send --poke-only: refused" 10 "$rc"
  eq "[$s] …nothing written in the spool root" "$n0" "$(jsons)"
  # ---- git push (the pre-push hook), override set --------------------------
  hook_as "$p"
  eq "[$s] pre-push hook with SPL_PREPUSH_OVERRIDE=1: refused, exit 1" 1 "$rc"
  has "[$s] …names the watcher" "$w" "$out"
  has "[$s] …says the override does not skip it" "SPL_PREPUSH_OVERRIDE=1 does not skip this" "$out"
  # ---- spawn ---------------------------------------------------------------
  gate_as "$p"
  eq "[$s] spool_spawn_gate with SPOOL_AGENT_ID=c-001: refused, rc 9" 9 "$rc"
done

# ---- the one send a watcher may make ----------------------------------------
n0="$(jsons)"
send_as 5000102 --from a-901 --to orchestrator --kind note --no-poke --body 'finding: lane c-777 idle 40 min'
eq "env watcher --from a-901 --kind note --to orchestrator: sent" 0 "$rc"
check "…one message written" test "$(jsons)" -gt "$n0"
send_as 5000201 --from a-902 --to orchestrator --kind note --no-poke --body 'finding'
eq "uid watcher --from a watcher id (a-902) --kind note --to orchestrator: sent" 0 "$rc"

# ---- control: a lane passes every gate as before ----------------------------
act 5000401 "$RUN/spl-push-master.func.sh" do_spl_push_master PUSH_WORKTREE="$T_TMP/not-a-repo"
hasnt "lane c-777: do_spl_push_master not refused as a watcher" "the caller is watcher" "$out"
has "…it reaches its own checks" "is not a git checkout" "$out"
send_as 5000401 --from c-777 --to c-778 --kind result --no-poke --body 'the result'
eq "lane c-777: spool-send of a result delivered" 0 "$rc"
gate_as 5000401
hasnt "lane c-777: spool_spawn_gate not refused as a watcher" "the caller is watcher" "$out"

# ---- control: no marker on the box, nothing to key on ----------------------
marks_off
act 5000102 "$RUN/spl-push-master.func.sh" do_spl_push_master PUSH_WORKTREE="$T_TMP/not-a-repo"
hasnt "no marker: a-901's chain is not refused as a watcher" "the caller is watcher" "$out"
send_as 5000201 --from c-777 --to c-778 --kind result --no-poke --body 'the result'
eq "no marker: the uid chain's send is delivered" 0 "$rc"

# ---- R7 c-700 W1: a process names itself; the walk never stops on a name ---
LIB="$T_FEAT/lib/spool-env.inc.sh"
marks_on
mkproc 5000500 1 'tmux-sh' "$NOBODY"
mkproc 5000501 5000500 tmux "$NOBODY" AGENT_ID=c-599
out="$(SPL_WATCHER_PID=5000501 bash -c '. "$1"; spl_watcher_refuse do_x' _ "$LIB" 2>&1)"; rc=$?
eq "W1 fake chain whose hops call themselves tmux / tmux-sh, uid nobody: refused" 1 "$rc"
has "…by its uid" "watcher nobody (by its uid)" "$out"
W1R="$T_TMP/w1root"; mkdir -p "$W1R/a-904"
printf 'user=%s\n' "$(id -un)" >"$W1R/a-904/.watcher-role"
out="$(SPOOL_ROOT="$W1R" bash -c 'printf tmux >/proc/$$/comm; . "$1"; spl_watcher_refuse do_x' _ "$LIB" 2>&1)"; rc=$?
eq "W1 real /proc: this uid is a marker's user, comm set to tmux: refused" 1 "$rc"
has "…by its uid" "by its uid" "$out"
cp "$(command -v bash)" "$T_TMP/tmux-sh"
out="$(SPOOL_ROOT="$W1R" "$T_TMP/tmux-sh" -c '. "$1"; spl_watcher_refuse do_x' _ "$LIB" 2>&1)"; rc=$?
eq "W1 real /proc: run under a bash copy named tmux-sh: refused" 1 "$rc"

# ---- R7 c-700 W2: a caller adds panes, never removes them -------------------
# A box with no /var/spool-hub (a CI runner) has no box socket: nothing.
want_sock=""
box_uid="$(stat -c %u /var/spool-hub 2>/dev/null)" && want_sock="/tmp/tmux-$box_uid/default"
eq "W2 the box socket is the spool root owner's, whatever SPOOL_TMUX_SOCKET says" \
  "$want_sock" \
  "$(SPOOL_TMUX_SOCKET=/nonexistent bash -c '. "$1"; _spl_watcher_box_socket' _ "$LIB")"
t_tmux
cat >"$T_TMP/probe.sh" <<PROBE
#!/usr/bin/env bash
export SPOOL_ROOT='$SPOOL_ROOT' SPOOL_TEST=1 SPOOL_TMUX_SOCKET='$SPOOL_TMUX_SOCKET' SPL_WATCHER_PANES_CMD=true
unset SPL_WATCHER_PROC SPOOL_AGENT_ID MCP_BOT_AGENT_ID
. '$LIB'
spl_watcher_why >'$T_TMP/probe.out' 2>'$T_TMP/probe.err'
echo done >>'$T_TMP/probe.out'
sleep 600
PROBE
chmod +x "$T_TMP/probe.sh"
mkdir -p "$SPOOL_ROOT/a-903"; : >"$SPOOL_ROOT/a-903/.watcher-role"
t_window a-903 "$T_TMP/probe.sh" >/dev/null
for _ in $(seq 1 100); do grep -q 'done' "$T_TMP/probe.out" 2>/dev/null && break; sleep 0.1; done
has "W2 a pane in window a-903, SPL_WATCHER_PANES_CMD=true set: still refused by its pane" "a-903 pane" "$(cat "$T_TMP/probe.out" 2>/dev/null)"
has "…and a marker with no user= line warns" "names no user= line" "$(cat "$T_TMP/probe.err" 2>/dev/null)"

# ---- R7 c-700 W3: a marker counts only when root owns it --------------------
eq "W3 a marker not owned by root, outside a test root: no watcher" "" \
  "$(SPOOL_TEST='' bash -c '. "$1"; spl_watcher_markers' _ "$LIB")"
has "W3 …the same marker in this test's own root counts" "a-901 nobody" \
  "$(bash -c '. "$1"; spl_watcher_markers' _ "$LIB")"
SPOOL_TEST=1 bash -c '. "$1"; _spl_watcher_marker_ok "$2/a-901/.watcher-role" "$(readlink -m /var/spool-hub)"' _ "$LIB" "$SPOOL_ROOT"
eq "W3 …under /var/spool-hub a non-root marker never counts, SPOOL_TEST=1 or not" 1 "$?"
mkdir -p "$SPOOL_ROOT/a-905"; printf 'user=%s\n' "$(id -un)" >"$SPOOL_ROOT/a-905/.watcher-role"
out="$(SPOOL_TEST='' bash -c '. "$1"; spl_watcher_refuse do_spl_take' _ "$LIB" 2>&1)"; rc=$?
eq "W3 …so a planted non-root marker naming this user (user=$(id -un)) does not stop its take" 0 "$rc"
rm -f "$SPOOL_ROOT/a-905/.watcher-role"

t_done
