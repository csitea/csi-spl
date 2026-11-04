#!/usr/bin/env bash
# lane-test-server-reap.sh, and agent-id-retire.sh step 8 that runs it: an e2e
# test server (serve-generated.mjs, serve-hosting-h2.mjs, wui-e2e-mock-api.py)
# that a RETIRED lane left running under its worktree or its /tmp scratch is
# stopped (SIGTERM, SIGKILL after the grace), so the scratch reap that follows
# can remove the scratch. Defect (SPL-4762): on sat the retired c-810 left
# `node src/node/test/serve-generated.mjs --root /tmp/claude-<uid>/<slug>/
# <session>/scratchpad/bundle-head` running for ~4 h; its scratch held 57136
# /tmp inodes and every sweep kept it, because a process held it.
# The fake servers are this user's own orphaned python3 sleepers; the real
# /tmp, the live spool and the box tmux are never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/lane-test-server-reap.sh"
RET="$T_SCRIPTS/agent-id-retire.sh"
R="$SPOOL_ROOT" TR="$T_TMP/tmp" LOGF="$T_TMP/srv.log"
export LANE_SCRATCH_TMP="$TR" LANE_SCRATCH_SUDO=0 LANE_TEST_SERVER_SUDO=0
export LANE_TEST_SERVER_LOG="$LOGF" LANE_TEST_SERVER_GRACE_S=1
S="$TR/claude-$(id -u)"
wt() { printf '%s' "$T_TMP/wt/$1"; }
slug() { local p; p="$(wt "$1")"; printf '%s' "${p//[^A-Za-z0-9]/-}"; }
# serve() runs in $(...): each pid goes to a file, the trap stops them all
PIDF="$T_TMP/pids"
trap 'while read -r p; do kill -9 "$p" 2>/dev/null; done <"$PIDF" 2>/dev/null; t_cleanup' EXIT

# retired ID: its worktree and scratch, a row in registry.retired.tsv only
retired() {
  mkdir -p "$(wt "$1")/csi-spl-wui/src/node/test" "$S/$(slug "$1")/sess-1/scratchpad/bundle-head"
  printf '%s\tclaude\t%%9\t%s\t20261101T000000Z\t20261101T040000Z\t-\n' "$1" "$(wt "$1")" >>"$R/registry.retired.tsv"
}
# live ID: the same, with its row still in registry.tsv
live() {
  retired "$1"
  printf '%s\tclaude\t%%9\t%s\t20261102T000000Z\n' "$1" "$(wt "$1")" >>"$R/registry.tsv"
}
# serve DIR SCRIPT ARG... -> pid of `python3 SCRIPT ARG...` run in DIR and
# orphaned (its parent shell exits), as the c-810 server was. SCRIPT is a
# sleeper; IGNORE_TERM=1 makes it ignore SIGTERM.
serve() {
  local dir="$1" script="$2" p; shift 2
  mkdir -p "${script%/*}" "$dir"
  if [ "${IGNORE_TERM:-0}" = 1 ]; then
    printf 'import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(600)\n' >"$script"
  else
    printf 'import time\ntime.sleep(600)\n' >"$script"
  fi
  p="$(cd "$dir" && bash -c 'python3 "$@" >/dev/null 2>&1 </dev/null & echo $!' _ "$script" "$@")"
  echo "$p" >>"$PIDF"
  for _ in $(seq 100); do [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$dir" ] && break; sleep 0.05; done
  printf '%s' "$p"
}
alive() { local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1; s="${s##*) }"; [ "${s%% *}" != Z ]; }
gone() { for _ in $(seq 60); do alive "$1" || return 0; sleep 0.1; done; return 1; }

# 1. a dry run plans the stop of a retired lane's server (its --root names
#    the lane's scratch) and signals nothing.
retired c-801
p1="$(serve "$T_TMP" "$(wt c-801)/csi-spl-wui/src/node/test/serve-generated.mjs" \
  --root "$S/$(slug c-801)/sess-1/scratchpad/bundle-head" --port 54435)"
out="$(bash "$REAP" c-801 2>&1)"; rc=$?
eq "1. the dry run exits 0" 0 "$rc"
check "1. a PLAN stop line names its pid, lane and args" \
  grep -qE "PLAN stop pid=$p1 lane=c-801 user=$(id -un) .*args=python3 .*serve-generated.mjs --root $S/$(slug c-801)/sess-1/scratchpad/bundle-head --port 54435" <<<"$out"
check "1. ...and it is still running" alive "$p1"
check "1. ...and no log line is written" test ! -e "$LOGF"

# 2. --apply stops it with SIGTERM and logs pid, args and lane.
out="$(bash "$REAP" --apply c-801 2>&1)"; rc=$?
eq "2. the apply exits 0" 0 "$rc"
check "2. the retired lane's server is stopped" gone "$p1"
check "2. a DO stop line names pid, lane, signal and args" \
  grep -qE "DO stop pid=$p1 lane=c-801 user=$(id -un) signal=TERM .*args=python3 .*serve-generated.mjs" <<<"$out"
check "2. ...and the same line is in the log" grep -qE "DO stop pid=$p1 lane=c-801 " "$LOGF"

# 3. a server whose cwd alone is under the retired worktree (the mock api).
p3="$(serve "$(wt c-801)/csi-spl-wui" "$T_TMP/elsewhere/wui-e2e-mock-api.py" 33921)"
bash "$REAP" --apply c-801 >"$T_TMP/o" 2>&1
check "3. a server held in the worktree by its cwd is stopped" gone "$p3"
check "3. ...the DO line names its cwd" grep -qF "cwd=$(wt c-801)/csi-spl-wui " "$T_TMP/o"

# 4. CONTROL (live lane): the same server of a lane with a registry.tsv row is
#    kept, untouched, under --apply.
live c-802
p4="$(serve "$T_TMP" "$(wt c-802)/csi-spl-wui/src/node/test/serve-generated.mjs" \
  --root "$S/$(slug c-802)/sess-1/scratchpad/bundle-head")"
out="$(bash "$REAP" --apply c-802 2>&1)"
check "4. a live lane's server keeps running" alive "$p4"
has "4. ...a KEEP live-lane line names the registry row" "KEEP live-lane c-802 (a row in" "$out"
hasnt "4. ...and nothing is stopped" "DO stop" "$out"

# 4b. CONTROL (live window): a retired row, no registry.tsv row, but a tmux
#     window still carries the id (a reused id): kept.
retired c-803
t_tmux; t_window "c-803 work" 'sleep 600' >/dev/null
p4b="$(serve "$(wt c-803)" "$(wt c-803)/csi-spl-wui/tests/e2e/lib/serve-hosting-h2.mjs" --port 8443)"
out="$(bash "$REAP" --apply c-803 2>&1)"
check "4b. a lane a tmux window carries keeps its server" alive "$p4b"
has "4b. ...KEEP live-lane names the window" "KEEP live-lane c-803 (a tmux window" "$out"
tmux -S "$SPOOL_TMUX_SOCKET" kill-server 2>/dev/null; rm -f "$SPOOL_TMUX_SOCKET"

# 4c. CONTROL (never retired): no row in either registry: not proven retired.
mkdir -p "$(wt c-804)"
p4c="$(serve "$(wt c-804)" "$(wt c-804)/serve-generated.mjs")"
out="$(bash "$REAP" --apply --worktree "$(wt c-804)" c-804 2>&1)"
check "4c. a lane with no retired row keeps its server" alive "$p4c"
has "4c. ...KEEP not-retired" "KEEP not-retired c-804" "$out"

# 5. CONTROL (not a test server): any other process under the retired dirs is
#    kept, even one whose script sits in the retired worktree.
retired c-805
p5="$(serve "$(wt c-805)" "$(wt c-805)/csi-spl-orc/build-cache.py")"
p5b="$(serve "$S/$(slug c-805)/sess-1" "$T_TMP/x/serve-generated.mjs.bak")"
out="$(bash "$REAP" --apply c-805 2>&1)"
check "5. a non-test process in the retired worktree keeps running" alive "$p5"
check "5. ...and one in its scratch" alive "$p5b"
hasnt "5. ...and nothing is stopped" "DO stop" "$out"

# 6. a known test server of a retired lane owned by another user than the
#    agent user is kept.
p6="$(serve "$(wt c-805)" "$(wt c-805)/csi-spl-wui/src/node/test/serve-generated.mjs")"
out="$(LANE_TEST_SERVER_USERS=nobody bash "$REAP" --apply c-805 2>&1)"
check "6. a server owned by a non-agent user keeps running" alive "$p6"
has "6. ...KEEP not-agent-user names it" "KEEP not-agent-user pid=$p6 lane=c-805" "$out"

# 7. a server that ignores SIGTERM gets SIGKILL after the grace.
p7="$(IGNORE_TERM=1 serve "$(wt c-805)" "$(wt c-805)/csi-spl-wui/src/node/test/serve-generated.mjs.d/serve-generated.mjs")"
out="$(bash "$REAP" --apply c-805 2>&1)"
check "7. a SIGTERM-deaf server is stopped" gone "$p7"
has "7. ...by TERM then KILL" "DO stop pid=$p7 lane=c-805 user=$(id -un) signal=TERM+KILL" "$out"
check "7. (and 6's server, a non-agent user's then, goes now)" gone "$p6"

# 8. a lane whose id, worktree and slug are a prefix of another's (CLE-8 vs
#    CLE-80, both valid ids) reaches nobody else's server; nor does a lane
#    whose worktree is not named for it.
retired CLE-8
mkdir -p "$S/$(slug CLE-80)/sess-1"
p8a="$(serve "$(wt CLE-80)" "$(wt CLE-80)/serve-generated.mjs")"
p8b="$(serve "$S/$(slug CLE-80)/sess-1" "$T_TMP/y/serve-generated.mjs")"
p8c="$(serve "$S/$(slug CLE-80)-csi-spl-wui" "$T_TMP/z/serve-generated.mjs")"
out="$(bash "$REAP" --apply CLE-8 2>&1)"; rc=$?
eq "8. CLE-8's reap exits 0 (it ran)" 0 "$rc"
check "8. ...and leaves a server under CLE-80's worktree" alive "$p8a"
check "8. ...one in CLE-80's scratch" alive "$p8b"
check "8. ...and one in CLE-80's subdir session scratch" alive "$p8c"
hasnt "8. ...nothing is stopped" "DO stop" "$out"
p8="$(serve "$(wt c-806)" "$(wt c-806)/serve-generated.mjs")"
bash "$REAP" --apply --worktree "$T_TMP/wt" c-806 >"$T_TMP/o" 2>&1; rc=$?
eq "8. a worktree not named for the id is refused (exit 2)" 2 "$rc"
check "8. ...and the server keeps running" alive "$p8"

# 8b. W1 (reused pid): a pid whose start time is not the one the scan read
#     is a different process: it is never signalled.
retired c-810
p8r="$(serve "$(wt c-810)" "$(wt c-810)/serve-generated.mjs")"
out="$(LANE_TEST_SERVER_START_OVERRIDE=1 bash "$REAP" --apply c-810 2>&1)"
check "8b. a pid whose start time changed is not signalled" alive "$p8r"
has "8b. ...KEEP gone-or-reused names it" "KEEP gone-or-reused pid=$p8r lane=c-810" "$out"
hasnt "8b. ...and no DO stop" "DO stop" "$out"

# 8c. W3 (fail closed): an unreadable registry.tsv refuses the run; c-811's
#     live row is in it, and its server lives.
live c-811
p8u="$(serve "$(wt c-811)" "$(wt c-811)/serve-generated.mjs")"
chmod 000 "$R/registry.tsv"
out="$(bash "$REAP" --apply c-811 2>&1)"; rc=$?
chmod 644 "$R/registry.tsv"
eq "8c. an unreadable registry.tsv refuses (exit 4)" 4 "$rc"
has "8c. ...naming it" "registry.tsv exists but cannot be read" "$out"
check "8c. ...and the live lane's server keeps running" alive "$p8u"
out="$(bash "$REAP" --retired 2>&1)"; rc=$?
eq "8c. (readable again: the run goes on)" 0 "$rc"

# 8d. W3: a tmux socket path that does not answer (a regular file, a dead
#     server) refuses the run: a window it would list is unknown.
: >"$SPOOL_TMUX_SOCKET"
out="$(bash "$REAP" --apply c-810 2>&1)"; rc=$?
rm -f "$SPOOL_TMUX_SOCKET"
eq "8d. an unread tmux window list refuses (exit 4)" 4 "$rc"
has "8d. ...naming it" "the tmux window list was not read" "$out"
check "8d. ...and the server keeps running" alive "$p8r"

# 8e. N1: a server whose --root names a retired lane's scratch but whose cwd
#     is under a LIVE lane's worktree is kept.
p8l="$(serve "$(wt c-811)/csi-spl-wui" "$(wt c-811)/csi-spl-wui/src/node/test/serve-generated.mjs" \
  --root "$S/$(slug c-810)/sess-1/scratchpad/bundle-head")"
out="$(bash "$REAP" --apply c-810 2>&1)"
check "8e. a server working in a live lane's worktree keeps running" alive "$p8l"
has "8e. ...KEEP cwd-in-live-lane names it" "KEEP cwd-in-live-lane pid=$p8l lane=c-810" "$out"
check "8e. (c-810's own server goes)" gone "$p8r"

# 9. --retired: every retired lane of the box in one dry run; a known test
#    server under no retired lane is named KEEP, a live lane's too.
retired c-807
p9="$(serve "$S/$(slug c-807)-csi-spl-wui/sess-2" "$(wt c-807)/serve-generated.mjs")"
out="$(bash "$REAP" --retired 2>&1)"; rc=$?
eq "9. the --retired dry run exits 0" 0 "$rc"
has "9. it plans c-807's server (held by a subdir session's scratch)" "PLAN stop pid=$p9 lane=c-807 " "$out"
has "9. it keeps the live c-802's" "KEEP live-lane c-802" "$out"
hasnt "9. ...and never reaches CLE-80's servers" "pid=$p8a lane=" "$out"
has "9. a server under no retired lane is KEEP no-retired-lane" "KEEP no-retired-lane pid=$p8 " "$out"
check "9. ...and nothing was signalled" alive "$p9"
check "9. ...nor the live lane's" alive "$p4"

# 10. agent-id-retire.sh step 8: the retire stops the lane's server FIRST, so
#     the scratch reap that follows removes the scratch it held at once.
export RETIRE_WORKTREE=0 RETIRE_DESKS=0 RETIRE_LANE=0 RETIRE_SCRATCH=1 RETIRE_SERVERS=1 LANE_SCRATCH_LOG=""
mkdir -p "$R/c-808/inbox" "$S/$(slug c-808)/sess-1/scratchpad/bundle-head" "$(wt c-808)"
printf '%s\tclaude\t%%1\t%s\t20261102T080000Z\n' c-808 "$(wt c-808)" >>"$R/registry.tsv"
p10="$(serve "$S/$(slug c-808)/sess-1/scratchpad" "$(wt c-808)/csi-spl-wui/src/node/test/serve-generated.mjs" \
  --root "$S/$(slug c-808)/sess-1/scratchpad/bundle-head")"
out="$(bash "$RET" c-808 2>&1)"
has "10. the retire's dry run plans the server's stop" "PLAN servers   stop pid=$p10 lane=c-808 " "$out"
check "10. ...and stops nothing" alive "$p10"
bash "$RET" --apply c-808 >"$T_TMP/o" 2>&1; eq "10. retire exits 0" 0 "$?"
check "10. the retired lane's server is stopped" gone "$p10"
check "10. ...a DO servers line names it" grep -qE "^DO servers +stop pid=$p10 lane=c-808 " "$T_TMP/o"
check "10. ...and the scratch it held is removed in the same retire" test ! -e "$S/$(slug c-808)"
check "10. ...not listed for the 24 h sweep" bash -c "! grep -qF '$S/$(slug c-808)' '$R/workdirs.tsv' 2>/dev/null"

# 11. CONTROL: with RETIRE_SERVERS=0 (the SPOOL_TEST default) the retire
#     leaves the server, and the scratch it holds stays (listed): the defect.
mkdir -p "$R/c-809/inbox" "$S/$(slug c-809)/sess-1/scratchpad" "$(wt c-809)"
printf '%s\tclaude\t%%1\t%s\t20261102T080000Z\n' c-809 "$(wt c-809)" >>"$R/registry.tsv"
p11="$(serve "$S/$(slug c-809)/sess-1/scratchpad" "$(wt c-809)/serve-generated.mjs")"
RETIRE_SERVERS=0 bash "$RET" --apply c-809 >"$T_TMP/o" 2>&1
check "11. without the step the server keeps running" alive "$p11"
check "11. ...and its scratch stays (KEEP in-use)" grep -qF "KEEP in-use $S/$(slug c-809) " "$T_TMP/o"

t_done
