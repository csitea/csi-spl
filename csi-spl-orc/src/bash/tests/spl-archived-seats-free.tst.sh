#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_archived_seats_free (SPL-3983; owner HUM-10, 2026-10-27:
# "the discusoin has been archieved -> the agents should be killed / freed").
# Hermetic: the hub read (LANE_HUB_CMD), the tmux read (LANE_PANES_CMD), the
# close+retire (ARCHIVED_SEATS_CLOSE_CMD), the issue end and the sender are
# stubs that log; the registry and the briefs live in a temp spool root; the
# worktrees are throwaway git repos. The hub answers only archived lanes, so a
# lane on a live topic is absent from it; c-706 is the lane row that names
# the archived topic while its brief binds it to another one.
#   c-701 seat, `Task: dispatch-<topic8>`, issue open    -> freed, issue ended
#   c-708 lane, `Topic: prd t1 <uuid>`, clean worktree  -> freed, no issue
#   c-702 lane on a live topic (not in the hub answer)  -> untouched
#   c-703 bound, uncommitted file                       -> kept, "1 changed"
#   c-710 bound, a commit on no remote branch           -> kept, "1 unpushed"
#   c-001 role seat                                     -> kept, never closed
#   c-705 names the topic in prose only                 -> kept
#   c-706 `Task:` line names another topic              -> kept
#   c-709 brief written after the archive               -> kept
#   c-707 lane row live, no window here                 -> skipped silently
# Then: a second run frees nothing and sends no second blocker; a dry run
# calls nothing. RED CONTROL: without the action file every case fails
# (`do_spl_archived_seats_free: command not found`).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool"
LOG="$T/calls.log"
ARCH="aaaaaaaa-0000-4000-8000-000000000001"
AT="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$SP" "$T/bin"
: >"$LOG"

# brief <id> <text>: the lane's lifetime brief, written a day before the archive.
brief() {
  mkdir -p "$SP/$1/lifetime"
  printf '%s\n' "$2" >"$SP/$1/lifetime/brief.md"
  touch -d '-1 day' "$SP/$1/lifetime/brief.md"
}
# wt <id>: a linked worktree of a repo with a bare origin, its branch pushed.
git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
gr() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
gr "$T/repo" commit -q --allow-empty -m base && gr "$T/repo" push -q origin HEAD:master
wt() {
  gr "$T/repo" worktree add -q -b "$1-br" "$T/wt/$1" master
  gr "$T/wt/$1" push -q origin "$1-br"
}

brief c-701 $'# Seat brief\n\nTask: dispatch-aaaaaaaa\nKind: secret'
echo SPL-9001 >"$SP/c-701/lifetime/issue"
brief c-708 $'# Lane brief\n\nTopic: prd t1 '"$ARCH"
wt c-708
brief c-702 $'# Lane brief\n\nTask: dispatch-bbbbbbbb'
brief c-703 $'# Lane\n\nTask: dispatch-aaaaaaaa'
wt c-703 && echo wip >"$T/wt/c-703/wip.txt"
brief c-710 $'# Lane\n\nTask: dispatch-aaaaaaaa'
wt c-710 && gr "$T/wt/c-710" commit -q --allow-empty -m "not pushed"
brief c-001 $'# Orchestrator\n\nTask: dispatch-aaaaaaaa'
brief c-705 $'# Lane brief\n\nThe case: the seats of task dispatch-aaaaaaaa kept running.'
brief c-706 $'# Lane\n\nTask: dispatch-cccccccc'
brief c-709 $'# Lane\n\nTask: dispatch-aaaaaaaa'
touch "$SP/c-709/lifetime/brief.md"
brief c-707 $'Task: dispatch-aaaaaaaa'

{
  for id in c-701 c-702 c-705 c-706 c-709 c-707 c-001; do printf '%s\tclaude\t%%1\t/opt\t20261026T000000Z\n' "$id"; done
  for id in c-703 c-708 c-710; do printf '%s\tclaude\t%%1\t%s\t20261026T000000Z\n' "$id" "$T/wt/$id"; done
} >"$SP/registry.tsv"

# The hub answers the archived lanes of box-a; c-702's live topic is absent.
printf '%s\n' c-701 c-708 c-703 c-710 c-001 c-705 c-706 c-709 c-707 >"$T/archived.ids"
printf '%s\n' c-701 c-702 c-708 c-703 c-710 c-001 c-705 c-706 c-709 >"$T/windows"
cat >"$T/bin/hub" <<EOF
#!/usr/bin/env bash
echo "hub \$*" >>"$LOG"
jq -R -s -c --arg t "$ARCH" --arg at "$AT" '{fleet: "main", lanes: [split("\n")[] | select(length > 0)
  | {agent_id: ., agent_box: "box-a", topic: \$t, state: "live", topic_archived_at: \$at}]}' "$T/archived.ids"
EOF
cat >"$T/bin/panes" <<EOF
#!/usr/bin/env bash
sed 's/^/0 /' "$T/windows"
EOF
# the close+retire: its window gone, its lane row done (out of the hub answer)
cat >"$T/bin/close" <<EOF
#!/usr/bin/env bash
echo "close \$*" >>"$LOG"
grep -vx "\$2" "$T/windows" >"$T/w.tmp"; mv "$T/w.tmp" "$T/windows"
grep -vx "\$2" "$T/archived.ids" >"$T/a.tmp"; mv "$T/a.tmp" "$T/archived.ids"
EOF
cat >"$T/bin/issue" <<EOF
#!/usr/bin/env bash
echo "issue \$AGENT_ID \$LANE_ISSUE_OP \$LANE_ISSUE_STATUS \$LANE_ISSUE_REASON" >>"$LOG"
EOF
# the sender: one log line without the body, the body kept in last-body
cat >"$T/bin/send" <<EOF
#!/usr/bin/env bash
a=(); while [ \$# -gt 0 ]; do case "\$1" in --body) printf '%s\\n' "\$2" >"$T/last-body"; shift 2 ;; *) a+=("\$1"); shift ;; esac; done
echo "send \${a[*]}" >>"$LOG"
EOF
chmod +x "$T/bin/"*

run() {
  SNIPPET="do_spl_archived_seats_free" in_orc SPOOL_ROOT="$SP" LANE_FLEET=main LANE_BOX=box-a \
    LANE_HUB_CMD="$T/bin/hub" LANE_PANES_CMD="$T/bin/panes" ARCHIVED_SEATS_CLOSE_CMD="$T/bin/close" \
    ARCHIVED_SEATS_ISSUE_CMD="$T/bin/issue" ARCHIVED_SEATS_SEND="$T/bin/send" ARCHIVED_SEATS_FROM=c-001 \
    ARCHIVED_SEATS_STATE_DIR="$T/state" "$@" 2>&1
}
closed() { grep -c "^close --agent $1 --retire$" "$LOG"; }
blocker() { grep '^send ' "$LOG" | tail -1; cat "$T/last-body" 2>/dev/null; }

# 1. a dry run reads the hub, prints its plan, and calls nothing
out="$(run DRY_RUN=1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"WOULD free c-701"* && "$out" == *"WOULD send the orchestrator"* ]] &&
  ! grep -qE '^(close|issue|send) ' "$LOG"; then pass "1 dry run: the plan printed, nothing closed, ended or sent"
else fail "1 dry run (rc $rc): $out // $(cat "$LOG")"; fi
grep -q '^hub lane --fleet main --archived --box box-a$' "$LOG" && pass "1b the hub read is lane --archived --box box-a" ||
  fail "1b the hub read: $(grep '^hub' "$LOG")"

# 2. the live run
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 ]] && pass "2 rc 0" || fail "2 rc $rc: $out"
[[ "$(closed c-701)" == 1 ]] && pass "2a archived topic, Task: line -> c-701 freed" || fail "2a c-701 closed $(closed c-701)x: $out"
grep -q '^issue c-701 end diss discussion archived by the owner' "$LOG" && pass "2b c-701's open issue ended with the reason" ||
  fail "2b issue end: $(grep '^issue' "$LOG")"
[[ "$(closed c-708)" == 1 ]] && ! grep -q '^issue c-708' "$LOG" && pass "2c Topic: line, clean pushed worktree -> c-708 freed, no issue to end" ||
  fail "2c c-708: $(closed c-708) // $(grep c-708 "$LOG")"
[[ "$(closed c-702)" == 0 ]] && pass "2d a live topic -> c-702 untouched" || fail "2d c-702 closed"
for id in c-703 c-710 c-001 c-705 c-706 c-709 c-707; do
  [[ "$(closed "$id")" == 0 ]] || fail "2e $id was closed"
done
[[ -d "$T/wt/c-703" && -f "$T/wt/c-703/wip.txt" ]] && pass "2e no kept lane closed; the dirty worktree is kept" || fail "2e worktree gone"
b="$(blocker)"
if [[ "$(grep -c '^send ' "$LOG")" == 1 && "$b" == *"--to orchestrator --kind blocker --task archived-seats-free"* ]]; then
  pass "2f one blocker to the orchestrator"
else fail "2f sends: $(grep '^send' "$LOG")"; fi
declare -A want=(
  [c-703]="1 changed, 0 unpushed" [c-710]="0 changed, 1 unpushed" [c-001]="a role seat"
  [c-705]="names it in passing only" [c-706]="binds it to cccccccc" [c-709]="written after the archive")
for id in "${!want[@]}"; do
  if grep -q -- "- $id, topic $ARCH: .*${want[$id]}" <<<"$b"; then pass "2g blocker names $id: ${want[$id]}"
  else fail "2g blocker lacks $id (${want[$id]}): $b"; fi
done
named=""
for id in c-707 c-701 c-708 c-702; do grep -q -- "- $id," <<<"$b" && named+=" $id"; done
[[ -z "$named" && "$b" == *"- c-703,"* ]] && pass "2h the blocker names no freed, live-topic or absent lane" ||
  fail "2h blocker names:${named:- (no blocker)}"

# 3. a second run frees nothing more and sends no second blocker
n_close="$(grep -c '^close ' "$LOG")" n_send="$(grep -c '^send ' "$LOG")"
out="$(run DRY_RUN=0)"; rc=$?
if [[ $rc -eq 0 && "$(grep -c '^close ' "$LOG")" == "$n_close" && "$(grep -c '^send ' "$LOG")" == "$n_send" ]]; then
  pass "3 second run: nothing more freed, no second blocker"
else fail "3 second run (rc $rc): $out"; fi

# 4. a new kept lane re-sends the blocker
echo c-711 >>"$T/archived.ids" && echo c-711 >>"$T/windows"
brief c-711 $'# Lane\n\nNo binding here, only dispatch-aaaaaaaa in passing.'
out="$(run DRY_RUN=0)"
[[ "$(grep -c '^send ' "$LOG")" == $((n_send + 1)) && "$(blocker)" == *"- c-711,"* ]] &&
  pass "4 a new kept lane sends the blocker again" || fail "4 resend: $out"

# 5. the hub read fails -> rc 1, nothing freed
n_close="$(grep -c '^close ' "$LOG")"
out="$(run DRY_RUN=0 LANE_HUB_CMD=false)"; rc=$?
[[ $rc -eq 1 && "$(grep -c '^close ' "$LOG")" == "$n_close" && "$out" == *FATAL* ]] &&
  pass "5 a failed hub read frees nothing, rc 1" || fail "5 hub down (rc $rc): $out"

echo "spl-archived-seats-free: $fails failure(s)"
[[ $fails -eq 0 ]]
