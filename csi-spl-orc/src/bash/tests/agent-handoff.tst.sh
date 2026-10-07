#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_handoff + do_spl_agent_handoff_note + the hook's
#   compose trigger (spec 102 5.1, 5.2; tasks.md T006). A fixture lane (a
#   registry row, a git worktree with a pushed and an unpushed commit, an
#   outbox, a heartbeat, a pane seam) is composed:
#     - every section of 5.2 is present, the terminal lines are scrubbed
#     - a note survives 100 composes byte for byte; the agent's files are
#       never written by the compose
#     - a KILL mid-compose (seam) leaves the previous complete file
#     - the hook starts one detached compose per 60 s, on PostToolUse only
#   Controls: two composes racing WITHOUT the lock (seam off) publish a file
#   that lost its brief; WITH the lock the second one waits and keeps it. A
#   held lock -> exit 4; a PreToolUse never composes; the live root is refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export PROJ_PATH="$PROJ_ROOT"
# shellcheck source=../run/spl-agent-handoff.func.sh
source "$PROJ_ROOT/src/bash/run/spl-agent-handoff.func.sh"
# shellcheck source=../run/spl-agent-handoff-note.func.sh
source "$PROJ_ROOT/src/bash/run/spl-agent-handoff-note.func.sh"
HOOK="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spool-agent-hook.sh"

ID=c-901
R="$T/root"; D="$R/$ID"; W="$T/wt"
mkdir -p "$D/inbox" "$D/outbox" "$D/archive" "$R/peer/$ID"
export SPOOL_ROOT="$R" ID SPOOL_BOX_ID=box-t HANDOFF_BRIEF="$T/brief.md"
unset SPOOL_AGENT_ID HANDOFF_LOCK HANDOFF_PAUSE_FILE HANDOFF_KILL_AT HANDOFF_WORKDIR
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ID" claude '%99' "$W" 20200101T000000Z c-001 >"$R/registry.tsv"
printf '# Brief: fixture task\n\nBuild the widget.\n' >"$T/brief.md"
printf '{"v": 1, "harness": "claude", "state": "in-tool", "tool": "Bash", "tool_since": "2026-10-07T08:00:00Z", "progress_ts": "2026-10-07T08:00:00Z"}\n' >"$D/heartbeat.json"
printf 'job-77 2026-10-07T08:00:00Z\n' >"$R/peer/$ID/held"
msg() { printf '{"v":1,"msg_id":"%s","task_id":"%s","ts":"%s","from":"%s","to":"%s","kind":"%s","body":"%s"}\n' "$@"; }
msg m1 topic-a 2026-10-07T08:01:00Z "$ID" c-002 blocker 'need the deploy go' >"$D/outbox/20261007T080100Z--m1.json"
msg m2 topic-b 2026-10-07T08:02:00Z "$ID" c-003 msg 'which env first?' >"$D/outbox/20261007T080200Z--m2.json"
msg m3 topic-b 2026-10-07T08:03:00Z c-003 "$ID" msg 'dev first' >"$D/archive/20261007T080300Z--m3.json"
export HANDOFF_CAPTURE_CMD="printf '%s\n' 'running tests' 'export PGPASSWORD=hunter2xyz' 'token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123' 'ok 12 passed'"

g() { git -C "$W" -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$W" 2>/dev/null
echo a >"$W/a.txt"; g add a.txt; g commit -m 'feat: pushed one'; g push -q origin HEAD:master
echo b >"$W/b.txt"; g add b.txt; g commit -m 'feat: local one'
echo dirty >>"$W/a.txt"

sect() { python3 - "$1" "$2" <<'EOF'
import sys
t = open(sys.argv[1]).read()
h = "\n## %s\n\n" % sys.argv[2]
i = t.find(h)
if i < 0:
    sys.exit(3)
b = t[i + len(h):]
j = b.find("\n## ")
sys.stdout.write(b[:j] if j >= 0 else b)
EOF
}
compose() { ( do_spl_agent_handoff ) >"$T/out" 2>"$T/err"; }

# --- the agent's files
( SECTION=next TEXT='push the fix, then watch CI' do_spl_agent_handoff_note ) >/dev/null &&
  ( SECTION=notes TEXT='c-002 holds the deploy go' do_spl_agent_handoff_note ) >/dev/null &&
  ( SECTION=notes TEXT='second note: `quoted` | piped' do_spl_agent_handoff_note ) >/dev/null &&
  ( SECTION=lesson TEXT='the hook re-runs the gate' do_spl_agent_handoff_note ) >/dev/null \
  && pass "note writes next, notes x2, lesson" || fail "note writes next, notes x2, lesson"
[[ "$(wc -l <"$D/handoff.d/notes.md")" == 2 ]] && grep -q '^- 20[0-9-]*T[0-9:]*Z c-002 holds the deploy go$' "$D/handoff.d/notes.md" \
  && pass "notes append one timestamped line each" || fail "notes append one timestamped line each"
( SECTION=next TEXT='rerun the suite' do_spl_agent_handoff_note ) >/dev/null
[[ "$(cat "$D/handoff.d/next.md")" == 'rerun the suite' ]] && pass "next replaces next.md" || fail "next replaces next.md"
( SECTION=bogus TEXT=x do_spl_agent_handoff_note ) >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && pass "CONTROL a bad SECTION is refused (exit 2)" || fail "CONTROL a bad SECTION is refused (rc=$rc)"
( SECTION=next TEXT='  ' do_spl_agent_handoff_note ) >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && pass "an empty TEXT is refused" || fail "an empty TEXT is refused (rc=$rc)"

# --- compose: every section of 5.2
compose; rc=$?
H="$D/handoff.md"
[[ "$rc" == 0 && -f "$H" ]] && pass "compose exit 0" || fail "compose exit 0 (rc=$rc: $(cat "$T/err"))"
missing=""
for s in "1. header" "2. brief" "3. done" "4. in flight" "5. next step" "6. open questions" "7. owned topics" "8. notes" "9. lessons"; do
  sect "$H" "$s" >/dev/null || missing+=" [$s]"
done
[[ -z "$missing" ]] && pass "all 9 sections present" || fail "sections missing:$missing"
sect "$H" "1. header" | grep '^- id: c-901$' >/dev/null && sect "$H" "1. header" | grep '^- harness: claude$' >/dev/null \
  && sect "$H" "1. header" | grep '^- hard_killed: false$' >/dev/null && pass "header: id, harness, hard_killed" || fail "header: id, harness, hard_killed"
sect "$H" "2. brief" | grep 'Build the widget.' >/dev/null && pass "brief filled from the brief file" || fail "brief filled from the brief file"
sect "$H" "3. done" >"$T/done"
grep -q 'feat: local one (NOT pushed)' "$T/done" && grep -q 'feat: pushed one (pushed)' "$T/done" \
  && pass "done: pushed and NOT pushed commits" || fail "done: pushed and NOT pushed commits ($(cat "$T/done"))"
sect "$H" "4. in flight" >"$T/fl"
grep -q '^dirty files: 1$' "$T/fl" && grep -q 'tool: Bash' "$T/fl" && grep -q 'ok 12 passed' "$T/fl" \
  && pass "in flight: dirty files, tool, terminal lines" || fail "in flight: dirty files, tool, terminal lines"
! grep -q 'hunter2xyz\|ghp_ABCDEF' "$H" && pass "terminal lines scrubbed (password, token)" || fail "terminal lines scrubbed"
sect "$H" "5. next step" | grep -x 'rerun the suite' >/dev/null && pass "next step from next.md" || fail "next step from next.md"
sect "$H" "6. open questions" >"$T/oq"
grep -q 'blocker to c-002, task topic-a' "$T/oq" && ! grep -q 'topic-b' "$T/oq" \
  && pass "open questions: the unanswered blocker, not the answered msg" || fail "open questions ($(cat "$T/oq"))"
sect "$H" "7. owned topics" >"$T/ot"
grep -q '^- topic-a ' "$T/ot" && grep -q '^- topic-b ' "$T/ot" && grep -q 'held job job-77' "$T/ot" \
  && pass "owned topics: outbox task ids + held job" || fail "owned topics ($(cat "$T/ot"))"
sect "$H" "9. lessons" | grep 'the hook re-runs the gate' >/dev/null && pass "lessons from lessons.md" || fail "lessons from lessons.md"
(( $(wc -l <"$H") <= 260 )) && pass "within the ~250 line cap ($(wc -l <"$H"))" || fail "over the line cap"
[[ "$(stat -c %a "$H")" == 640 ]] && pass "handoff.md mode 0640" || fail "handoff.md mode $(stat -c %a "$H")"

# --- a note survives 100 composes byte for byte; the agent's files are never written
sum0="$(md5sum "$D"/handoff.d/*.md)"
for ((i = 0; i < 100; i++)); do compose || break; done
[[ "$i" == 100 ]] && pass "100 composes ran" || fail "100 composes ran (stopped at $i)"
[[ "$(sect "$H" "8. notes")" == "$(cat "$D/handoff.d/notes.md")" ]] \
  && pass "the note is byte for byte in handoff.md after 100 composes" || fail "the note changed after 100 composes"
[[ "$(md5sum "$D"/handoff.d/*.md)" == "$sum0" ]] && pass "the compose never wrote the agent's files" || fail "the agent's files changed"
sect "$H" "2. brief" | grep 'Build the widget.' >/dev/null && [[ "$(grep -c 'Build the widget' "$H")" == 1 ]] \
  && pass "the brief carried once, not duplicated" || fail "the brief carried once"

# --- the old file becomes handoff.prev.md
cp "$H" "$T/before"
compose
cmp -s "$T/before" "$D/handoff.prev.md" && pass "the previous file is handoff.prev.md" || fail "the previous file is handoff.prev.md"

# --- KILL mid-compose (seam): the previous complete file stays
cp "$H" "$T/before"
( ( HANDOFF_KILL_AT=4 do_spl_agent_handoff ) >/dev/null 2>&1 ) 2>/dev/null; rc=$?
cmp -s "$T/before" "$H" && pass "KILL mid-compose (rc=$rc) leaves the previous complete file" || fail "KILL mid-compose changed handoff.md"
ls "$D"/handoff.md.tmp.* >/dev/null 2>&1 && pass "the killed compose left its partial tmp" || fail "CONTROL no partial tmp: the kill seam did not fire"
compose
! ls "$D"/handoff.md.tmp.* >/dev/null 2>&1 && sect "$H" "9. lessons" >/dev/null \
  && pass "the next compose removes the dead tmp and completes" || fail "the next compose removes the dead tmp"

# --- the lock matters: race two composes, the first paused between its renames
waitgone() { local n; for ((n = 0; n < 100; n++)); do [[ -e "$H" ]] || return 0; sleep 0.1; done; return 1; }
mv "$T/brief.md" "$T/brief.gone"
compose
rm -f "$T/go"
( HANDOFF_LOCK=0 HANDOFF_PAUSE_FILE="$T/go" do_spl_agent_handoff ) >/dev/null 2>&1 & a=$!
waitgone
( HANDOFF_LOCK=0 do_spl_agent_handoff ) >/dev/null 2>&1
[[ "$(sect "$H" "2. brief")" == "(none)" ]] && pass "CONTROL without the lock a racing compose publishes a file that lost its brief" \
  || fail "CONTROL without the lock the race lost nothing: the test cannot see the lock"
touch "$T/go"; wait "$a"
compose
rm -f "$T/go"
( HANDOFF_PAUSE_FILE="$T/go" do_spl_agent_handoff ) >/dev/null 2>&1 & a=$!
waitgone
( do_spl_agent_handoff ) >/dev/null 2>&1 & b=$!
sleep 1
kill -0 "$b" 2>/dev/null && pass "with the lock the second compose waits" || fail "with the lock the second compose did not wait"
touch "$T/go"; wait "$a"; wait "$b"; rc=$?
[[ "$rc" == 0 ]] && sect "$H" "2. brief" | grep 'Build the widget.' >/dev/null \
  && pass "with the lock both composes finish and the brief survives" || fail "with the lock the brief was lost (rc=$rc)"
mv "$T/brief.gone" "$T/brief.md"

# --- a held lock -> exit 4
exec 7>>"$D/lifetime/handoff.lock"; flock -x 7
( HANDOFF_LOCK_WAIT=0 do_spl_agent_handoff ) >/dev/null 2>&1; rc=$?
exec 7>&-
[[ "$rc" == 4 ]] && pass "a held lock -> exit 4" || fail "a held lock -> exit 4 (rc=$rc)"

# --- the live root is refused under SPOOL_TEST
( SPOOL_ROOT="$T/live" SPOOL_LIVE_ROOT="$T/live" do_spl_agent_handoff ) >/dev/null 2>&1; rc=$?
( SPOOL_ROOT="$T/live" SPOOL_LIVE_ROOT="$T/live" SECTION=next TEXT=x do_spl_agent_handoff_note ) >/dev/null 2>&1; rc2=$?
[[ "$rc" == 97 && "$rc2" == 97 ]] && pass "SPOOL_TEST=1 refuses the live root (97, 97)" || fail "live root refused ($rc, $rc2)"

# --- the hook: one detached compose per 60 s, on PostToolUse only
hook() { SPOOL_AGENT_ID="$ID" SPOOL_HARNESS=claude HOOK_NOW="$2" HOOK_PID=1 bash "$HOOK" "$1" <<<'{}' >/dev/null 2>&1; }
kicks() { local n; for ((n = 0; n < 30; n++)); do [[ "$( { wc -l <"$T/kicks"; } 2>/dev/null)" -ge "$1" ]] && break; sleep 0.1; done; sleep 0.3; { wc -l <"$T/kicks"; } 2>/dev/null || echo 0; }
export HANDOFF_COMPOSE_CMD="echo kick >>'$T/kicks'"
rm -f "$D/lifetime/handoff.kick" "$T/kicks"
hook PreToolUse 1000
[[ "$(kicks 1)" == 0 ]] && pass "CONTROL a PreToolUse starts no compose" || fail "CONTROL a PreToolUse started a compose"
hook PostToolUse 1000
[[ "$(kicks 1)" == 1 ]] && pass "PostToolUse starts one compose" || fail "PostToolUse starts one compose ($(kicks 1))"
hook PostToolUse 1030
[[ "$(kicks 2)" == 1 ]] && pass "a PostToolUse 30 s later starts none" || fail "a PostToolUse 30 s later started one"
hook PostToolUse 1061
[[ "$(kicks 2)" == 2 ]] && pass "a PostToolUse 61 s later starts the next" || fail "a PostToolUse 61 s later ($(kicks 2))"
unset HANDOFF_COMPOSE_CMD
rm -f "$D/lifetime/handoff.kick" "$H"
hook PostToolUse 2000
for ((n = 0; n < 50; n++)); do [[ -f "$H" ]] && break; sleep 0.1; done
sect "$H" "8. notes" >/dev/null && pass "the hook's detached compose writes handoff.md" || fail "the hook's detached compose wrote nothing ($(cat "$D/hook.err" 2>/dev/null))"

if [[ "$fails" -eq 0 ]]; then echo "ALL PASS: agent-handoff"; exit 0; fi
echo "FAILED: $fails"; exit 1
