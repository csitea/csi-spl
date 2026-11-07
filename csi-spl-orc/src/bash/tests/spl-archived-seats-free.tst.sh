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
#   c-701 seat, `Task: dispatch-<topic8>`, issue open    -> freed, issue on hold
#   c-720 `Ask-Topic:` line, the topic only in prose     -> freed (SPL-4955)
#   c-721 bound by `Discussion:`                         -> freed (SPL-4955)
#   c-722 bound, seated on 2 workspaces' desks           -> skipped (SPL-4955)
#   c-723 bound, seated on another desk box              -> skipped (SPL-4955)
#   c-725 bound, brief heading "standing seat"           -> skipped (SPL-4955)
#   c-724 bound, one desk dir on this box's own desk     -> freed: the red control of c-722/c-723
#   c-708 lane, `Topic: prd t1 <uuid>`, clean worktree  -> freed, no issue
#   c-702 lane on a live topic (not in the hub answer)  -> untouched
#   c-703 bound, uncommitted file                       -> kept, "1 changed"
#   c-710 bound, a commit on no remote branch           -> kept, "1 unpushed"
#   c-001 role seat                                     -> skipped, never closed
#   c-705 names the topic in prose only                 -> skipped (SPL-4092)
#   c-706 `Task:` line names another topic              -> skipped (SPL-4092)
#   c-709 brief written after the archive               -> kept
#   c-707 lane row live, no window here                 -> skipped silently
# A skipped lane is neither freed nor named in the blocker: the hub row names
# its topic only because the spawn stores the first topic a brief mentions
# (SPL-4092: n=3 blockers in 1.5 h, each answered "leave"). It is only a
# `skip` line of the run's own output. Then: a second run frees nothing and
# sends no second blocker; a new kept lane sends it again; a dry run calls
# nothing. RED CONTROL: without the action file every case fails
# (`do_spl_archived_seats_free: command not found`). SPL-4955, without the desk
# check c-722 and c-723 are closed, without the heading check c-725; without the Ask-Topic read c-720 is skipped.
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

brief c-720 $'# Lane\n\nThe owner decided (t1 topic aaaaaaaa, msg 1).\n\nAsk-Topic: '"$ARCH"
brief c-721 $'# Lane\n\nDiscussion: '"$ARCH"
brief c-722 $'# Seat\n\nTask: dispatch-aaaaaaaa'
brief c-723 $'# Seat\n\nTask: dispatch-aaaaaaaa'
brief c-724 $'# Lane\n\nTask: dispatch-aaaaaaaa'
brief c-725 $'# Seat brief: a workspace, channel #alerts - answer the posts there (standing seat, runs here)\n\nTask: dispatch-aaaaaaaa'

{
  for id in c-701 c-702 c-705 c-706 c-709 c-707 c-001 c-720 c-721 c-722 c-723 c-724 c-725; do printf '%s\tclaude\t%%1\t/opt\t20261026T000000Z\n' "$id"; done
  for id in c-703 c-708 c-710; do printf '%s\tclaude\t%%1\t%s\t20261026T000000Z\n' "$id" "$T/wt/$id"; done
} >"$SP/registry.tsv"

# The hub answers the archived lanes of box-a; c-702's live topic is absent.
printf '%s\n' c-701 c-708 c-703 c-710 c-001 c-705 c-706 c-709 c-707 c-720 c-721 c-722 c-723 c-724 c-725 >"$T/archived.ids"
printf '%s\n' c-701 c-702 c-708 c-703 c-710 c-001 c-705 c-706 c-709 c-720 c-721 c-722 c-723 c-724 c-725 >"$T/windows"
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
# the desks: c-722 on two workspaces, c-723 on a responder box, c-724 one plain dir
cat >"$T/bin/desks" <<EOF
#!/usr/bin/env bash
case "\$1" in
  c-722) printf 't1/box-a\\nws2/box-a\\n' ;;
  c-723) echo t1/box-rsp ;;
  c-724) echo t1/box-a ;;
esac
EOF
chmod +x "$T/bin/"*

run() {
  SNIPPET="${SNIPPET:-do_spl_archived_seats_free}" in_orc SPOOL_ROOT="$SP" LANE_FLEET=main LANE_BOX=box-a \
    LANE_HUB_CMD="$T/bin/hub" LANE_PANES_CMD="$T/bin/panes" ARCHIVED_SEATS_CLOSE_CMD="$T/bin/close" \
    ARCHIVED_SEATS_DESKS_CMD="$T/bin/desks" ARCHIVED_SEATS_ISSUE_CMD="$T/bin/issue" ARCHIVED_SEATS_SEND="$T/bin/send" ARCHIVED_SEATS_FROM=c-001 \
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
# skipped <out> <case>: the role seat and the unbound lanes are skip lines of
# the output, never KEEP lines and never in the blocker the run prints.
skipped() {
  local id
  for id in c-001 c-705 c-706; do
    if grep -qE "INFO $id: " <<<"$1" && ! grep -qE "KEEP $id |- $id," <<<"$1"; then pass "$2 $id is a skip line only"
    else fail "$2 $id not a skip line only: $(grep -- "$id" <<<"$1")"; fi
  done
}
skipped "$out" "1c dry run:"

# 2. the live run
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 ]] && pass "2 rc 0" || fail "2 rc $rc: $out"
skipped "$out" "2i live run:"
[[ "$(closed c-701)" == 1 ]] && pass "2a archived topic, Task: line -> c-701 freed" || fail "2a c-701 closed $(closed c-701)x: $out"
grep -q '^issue c-701 end onhold discussion archived by the owner' "$LOG" && pass "2b c-701's open issue on hold with the reason, never diss (SPL-4955)" ||
  fail "2b issue end: $(grep '^issue' "$LOG")"
[[ "$(closed c-708)" == 1 ]] && ! grep -q '^issue c-708' "$LOG" && pass "2c Topic: line, clean pushed worktree -> c-708 freed, no issue to end" ||
  fail "2c c-708: $(closed c-708) // $(grep c-708 "$LOG")"
for id in c-720 c-721 c-724; do
  [[ "$(closed "$id")" == 1 ]] && pass "2c2 $id bound and no workspace seat -> freed" || fail "2c2 $id closed $(closed "$id")x: $out"
done
for id in c-722 c-723 c-725; do
  if [[ "$(closed "$id")" == 0 ]] && grep -qE "INFO $id: (it answers a whole workspace|its brief makes it a standing seat)" <<<"$out"; then pass "2c3 $id a whole-workspace seat: a skip line, not closed"
  else fail "2c3 $id closed $(closed "$id")x: $(grep -- "$id" <<<"$out")"; fi
done
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
  [c-703]="1 changed, 0 unpushed" [c-710]="0 changed, 1 unpushed" [c-709]="written after the archive")
for id in "${!want[@]}"; do
  if grep -q -- "- $id, topic $ARCH: .*${want[$id]}" <<<"$b"; then pass "2g blocker names $id: ${want[$id]}"
  else fail "2g blocker lacks $id (${want[$id]}): $b"; fi
done
named=""
for id in c-707 c-701 c-708 c-702 c-001 c-705 c-706 c-722 c-723 c-725; do grep -q -- "- $id," <<<"$b" && named+=" $id"; done
[[ -z "$named" && "$b" == *"- c-703,"* ]] && pass "2h the blocker names no freed, live-topic, absent, role or unbound lane" ||
  fail "2h blocker names:${named:- (no blocker)}"

# 3. a second run frees nothing more and sends no second blocker
n_close="$(grep -c '^close ' "$LOG")" n_send="$(grep -c '^send ' "$LOG")"
out="$(run DRY_RUN=0)"; rc=$?
if [[ $rc -eq 0 && "$(grep -c '^close ' "$LOG")" == "$n_close" && "$(grep -c '^send ' "$LOG")" == "$n_send" ]]; then
  pass "3 second run: nothing more freed, no second blocker"
else fail "3 second run (rc $rc): $out"; fi

# 4. a new unbound lane sends no blocker; a new kept lane sends it again
echo c-712 >>"$T/archived.ids" && echo c-712 >>"$T/windows"
brief c-712 $'# Lane\n\nNo binding here, only dispatch-aaaaaaaa in passing.'
out="$(run DRY_RUN=0)"
[[ "$(grep -c '^send ' "$LOG")" == "$n_send" && "$(closed c-712)" == 0 && "$out" == *"INFO c-712: "* ]] &&
  pass "4a a new unbound lane: a skip line, no blocker, not freed" || fail "4a c-712: $out"
echo c-711 >>"$T/archived.ids" && echo c-711 >>"$T/windows"
brief c-711 $'# Lane\n\nTask: dispatch-aaaaaaaa'
wt c-711 && echo wip >"$T/wt/c-711/wip.txt"
printf 'c-711\tclaude\t%%1\t%s\t20261026T000000Z\n' "$T/wt/c-711" >>"$SP/registry.tsv"
out="$(run DRY_RUN=0)"
[[ "$(grep -c '^send ' "$LOG")" == $((n_send + 1)) && "$(blocker)" == *"- c-711,"* && "$(blocker)" != *"- c-712,"* ]] &&
  pass "4b a new kept lane sends the blocker again" || fail "4b resend: $out"

# 5. the hub read fails -> rc 1, nothing freed
n_close="$(grep -c '^close ' "$LOG")"
out="$(run DRY_RUN=0 LANE_HUB_CMD=false)"; rc=$?
[[ $rc -eq 1 && "$(grep -c '^close ' "$LOG")" == "$n_close" && "$out" == *FATAL* ]] &&
  pass "5 a failed hub read frees nothing, rc 1" || fail "5 hub down (rc $rc): $out"

# 6. a workspace seat whose desks are only under another user's 0700 root: the
# real desk walk, no desks stub. RED CONTROL: without spl_archived_seat_desks_closed
# 6a frees it.
mkdir -p "$T/closed/desk/w1/box-a/spool/c-730" "$T/closed/desk/w2/box-a/spool/c-730"
chmod 000 "$T/closed/desk"
cat >"$T/bin/as" <<EOF
#!/usr/bin/env bash
shift; [[ "\$1" == "--" ]] && shift
chmod 755 "$T/closed/desk"; "\$@"; rc=\$?; chmod 000 "$T/closed/desk"; exit \$rc
EOF
chmod +x "$T/bin/as"
echo c-730 >>"$T/archived.ids" && echo c-730 >>"$T/windows"
brief c-730 $'# Lane\n\nAsk-Topic: aaaaaaaa'
real_walk() {
  SNIPPET="spl_desk_roots() { printf '%s\t%s\n' \"\$(id -un)\" \"\$SPL_STATE_DIR\"; printf 'desk-u\t%s\n' '$T/closed'; }; do_spl_archived_seats_free" run ARCHIVED_SEATS_DESKS_CMD= "$@"
}
out="$(real_walk SPL_DESK_AS_CMD="$T/bin/as" DRY_RUN=0)"
[[ "$(closed c-730)" == 0 && "$out" == *"c-730: it answers a whole workspace (w1/box-a w2/box-a)"* ]] &&
  pass "6a a seat on 2 workspaces under another user's closed root is not freed" || fail "6a: $out"
out="$(real_walk SPL_DESK_AS_CMD=false DRY_RUN=1)"
[[ "$out" == *"WARN c-730: cannot read desk-u's desks"* && "$out" == *"WOULD free c-730"* ]] &&
  pass "6b CONTROL: a root it cannot read warns, and the guard alone would not hold" || fail "6b: $out"
chmod 755 "$T/closed/desk"

echo "spl-archived-seats-free: $fails failure(s)"
[[ $fails -eq 0 ]]
