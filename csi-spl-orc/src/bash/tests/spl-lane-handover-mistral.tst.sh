#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_handover_mistral (t1 ba8104f6, topic 9d603c3d), offline.
#          The harness of spl-lane-handover.tst.sh: a bare repo plays origin,
#          $T/repo the main checkout with FROM's linked worktree; ssh is a stub
#          that plays the target box (its env file, every $T/repo path moved to
#          $T/r/repo). sudo, tmux and the spawn scripts are stubs that log.
#          FROM's vibe session sits in $T/ahome/.vibe/logs/session/unified,
#          next to an older one of the same worktree and one of another.
#   1. refusals before any call: a bad FROM, the same id on this box, a
#      non-mistral lane
#   2. DRY_RUN is the default: mode A on the NEWEST session of FROM's
#      worktree, the plan, no ssh call, nothing pushed
#   3. mode B when TO_ID differs, when no session names the worktree, and
#      when the session holds key material
#   4. RED CONTROL: key material in FROM's WIP -> exit 3, no ssh, no close,
#      NOTHING pushed
#   5. DRY_RUN=0, A: the wip ref, the target worktree AT it, the session dir
#      over ssh stdin (never argv) into the agent user's unified/, FROM closed
#      BEFORE the wip push and retired with RETIRE_WORKTREE=0 after the start.
#      The resume RUNS: the tmux stub executes the window command, i.e. the
#      REAL restore-mistral.sh / restore-core / spool-env, as the agent user,
#      down to a vibe stand-in that applies vibe 2.26.0's own --resume rule
#      (unified/<sid>/CURRENT under its HOME) and replays the session: the old
#      conversation reaches the resumed CLI. Control: without the copied
#      session the same window command finds nothing.
#      5h: the handover brief is the target lane's lifetime/brief.md and the
#      worktree is trusted for vibe (the stand-in stops on vibe's trust
#      prompt otherwise). Control: an untrusted worktree stops there.
#   7. RED CONTROL: a failed session copy -> exit 1, FROM not closed, nothing
#      pushed
#   8. RED CONTROL: the trust does not verify -> exit 1, no window, no retire
#   6. DRY_RUN=0, B: spawn-window.sh mistral <TO_ID> with the handover brief;
#      no session copied
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v zstd >/dev/null && command -v jq >/dev/null || { echo "SKIP: no zstd or jq"; exit 0; }

ME="$(id -un)"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME" "$T/spool/agents" "$T/r" "$T/ahome" "$T/rhome" "$T/fs/lib" "$T/stub/remote-bin"
git config --global init.defaultBranch master
git config --global safe.directory '*'
git config --global user.name "FirstName LastName"
git config --global user.email "owner@example.com"
KEYLINE="$(printf -- '-----%s %s %s-----' BEGIN PRIVATE KEY)"
SID=aaaaaaaa-1111-2222-3333-444444444444
OLD=bbbbbbbb-1111-2222-3333-444444444444
OTHER=cccccccc-1111-2222-3333-444444444444
SECRET_T="session-body-$RANDOM$RANDOM"
U="$T/ahome/.vibe/logs/session/unified"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
echo base >"$T/repo/a.txt"; git -C "$T/repo" add a.txt; git -C "$T/repo" commit -qm base; git -C "$T/repo" push -q origin master
git -C "$T/repo" remote set-head origin master >/dev/null
git clone -q "$T/origin.git" "$T/r/repo" 2>/dev/null

# session SID WT AGE_S [PARENT]: a vibe unified session of WT, CURRENT AGE_S old
session() {
  mkdir -p "$U/$1/chunks"
  jq -n --arg s "$1" --arg w "$2" --arg p "${4:-}" \
    '{session_id:$s, parent_session_id:(if $p == "" then null else $p end), environment:{working_directory:$w}}' >"$U/$1/meta.json"
  echo "{\"x\":\"$SECRET_T\"}" >"$U/$1/chunks/c1.json"
  echo "{\"session_id\":\"$1\"}" >"$U/$1/CURRENT"
  touch -d "-$3 seconds" "$U/$1/CURRENT"
}

# lane <id> [kind]: FROM's worktree, identity record (no session id, as live m- records), registry row, brief, outbox
lane() {
  local id="$1" kind="${2:-mistral}" wt="$T/repo-wt/$1"
  git -C "$T/repo" worktree add -q -b "$id-x" "$wt" origin/master
  echo "wip of $id" >"$wt/w.txt"
  jq -n --arg id "$id" --arg k "$kind" --arg w "$wt" --arg u "$ME" \
    '{id:$id, kind:$k, session_id:null, worktree:$w, user:$u, alive:true}' >"$T/spool/agents/$id.json"
  printf '%s\tmistral\t%%9\t%s\t20261010T000000Z\tc-001\n' "$id" "$wt" >>"$T/spool/registry.tsv"
  mkdir -p "$T/spool/$id/lifetime" "$T/spool/$id/outbox"
  echo "# Brief: the task of $id" >"$T/spool/$id/lifetime/brief.md"
  jq -n '{kind:"note", to:"c-001", task_id:"dispatch-abcd1234", ts:"2026-10-10T00:00:00Z", body:"half done"}' >"$T/spool/$id/outbox/1.json"
}

printf 'OWNER_USER=ownerx\nAGENT_USER=agentx\nBOX_TAG=sat\n' >"$T/box.env"
cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -o ]]; do shift 2; done
dest="$1" cmd="$2"
printf 'ssh %s %s\n' "$dest" "$cmd" >>"$STUB_LOG"
[[ "$cmd" == 'cat /etc/csi-spl-satellite.env' ]] && { cat "$FAKE_BOX_ENV"; exit 0; }
cmd="${cmd//$FAKE_LOCAL_REPO/$FAKE_REMOTE_REPO}"
PATH="$FAKE_STUB_DIR/remote-bin:$PATH" eval "$cmd"
EOF
cat >"$T/stub/remote-bin/sudo" <<'EOF'
#!/usr/bin/env bash
u=""
while [[ "$1" == -* ]]; do case "$1" in -u) u="$2"; shift 2 ;; *) shift ;; esac; done
echo "sudo-as $u" >>"$STUB_LOG"
[[ "$u" == agentx ]] && export HOME="$FAKE_REMOTE_HOME"
exec "$@"
EOF
# the target's tmux server: new-window RUNS its command (the last argument)
cat >"$T/stub/remote-bin/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -u || "$1" == -S ]]; do [[ "$1" == -S ]] && shift; shift; done
echo "tmux $*" >>"$STUB_LOG"
case "$1" in
  list-sessions) echo '1 $0' ;;
  new-window) printf '%s' "${!#}" >"$FAKE_WINDOW_CMD"; bash -c "${!#}" </dev/null >>"$FAKE_WINDOW_LOG" 2>&1; echo '%88' ;;
esac
EOF
# vibe 2.26.0's --resume rule (app_server/_runtime.py, _resolve_unified_session_id):
# <save dir>/unified/<sid>/CURRENT under the user's HOME; a hit replays the session
cat >"$T/stub/vibe" <<'EOF'
#!/usr/bin/env bash
{
  echo "vibe cwd=$PWD home=$HOME argv=$*"
  sid=""; while [ $# -gt 0 ]; do [ "$1" = --resume ] && sid="$2"; shift; done
  # vibe stops on "Trust this folder?" unless ~/.vibe/trusted_folders.toml lists the cwd
  grep -qF "\"$(pwd -P)\"" "$HOME/.vibe/trusted_folders.toml" 2>/dev/null || { echo "TRUST-PROMPT $(pwd -P)"; exit 1; }
  s="$HOME/.vibe/logs/session/unified/$sid"
  if [ -n "$sid" ] && [ -f "$s/CURRENT" ]; then echo "RESUMED $sid"; cat "$s"/chunks/*.json; else echo "NOT-FOUND ${sid:-none}"; exit 1; fi
} >>"$FAKE_VIBE_LOG"
EOF
# close records whether FROM's wip ref was already pushed: it must not be
printf '#!/bin/sh\nr=no; git -C "$FAKE_ORIGIN" rev-parse -q --verify "refs/heads/wip/handover/$2" >/dev/null && r=yes\necho "close $* pushed=$r" >>"$STUB_LOG"\nexit 3\n' >"$T/stub/close"
printf '#!/bin/sh\necho "retire RETIRE_WORKTREE=$RETIRE_WORKTREE $*" >>"$STUB_LOG"\n' >"$T/stub/retire"
chmod +x "$T/stub/"* "$T/stub/remote-bin/"*
# the target's spawn-agents dir: the real scripts and lib, with the id claim,
# the hook install, spawn-window and the harness wrapper stubbed
SA="$(cd "$TEST_DIR/../features/spawn-agents" && pwd)"
rm -rf "$T/fs"; mkdir -p "$T/fs"; cp -r "$SA/scripts" "$SA/lib" "$T/fs/"
printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift; exec "$@"\n' >"$T/fs/scripts/spool-harness.sh"
export FAKE_ORIGIN="$T/origin.git" FAKE_WINDOW_CMD="$T/window.cmd" FAKE_WINDOW_LOG="$T/window.log" FAKE_VIBE_LOG="$T/vibe.log"
export MISTRAL_BIN="$T/stub/vibe" SPOOL_MISTRAL_MAX_PRICE=1 SPOOL_RUN_AS_AGENT=sudo-i SPOOL_AGENT_PTY=0 SPOOL_TMUX_SOCKET="$T/tmux.sock"
unset SPOOL_BOX_USER SPOOL_AGENT_USER SPOOL_BOX_TAG BOX_TAG TMUX TMUX_PANE SPOOL_AGENT_ID
printf '#!/bin/sh\necho "next-agent-id $*" >>"$STUB_LOG"\n' >"$T/fs/scripts/next-agent-id.sh"
printf '#!/bin/sh\n' >"$T/fs/scripts/install-pre-push-hook.sh"
printf '#!/bin/sh\necho "spawn-window $*" >>"$STUB_LOG"\necho "$2 %%77"\n' >"$T/fs/scripts/spawn-window.sh"

run_ho() {
  SNIPPET=do_spl_lane_handover_mistral in_orc SPOOL_ROOT="$T/spool" BOX=pc HANDOVER_AGENT_HOME="$T/ahome" \
    HANDOVER_SCRIPTS_DIR="$T/fs/scripts" HANDOVER_CLOSE_CMD="$T/stub/close" HANDOVER_RETIRE_CMD="$T/stub/retire" \
    HANDOFF_CAPTURE_CMD="echo terminal-line" FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" FAKE_REMOTE_HOME="$T/rhome" \
    FAKE_LOCAL_REPO="$T/repo" FAKE_REMOTE_REPO="$T/r/repo" "$@" >"$T/o" 2>&1
}
ref_of() { git -C "$T/origin.git" rev-parse -q --verify "refs/heads/wip/handover/$1" 2>/dev/null; }
calls() { cat "$T/calls.log" 2>/dev/null; }

lane m-050
lane m-051 claude
lane m-052
session "$SID" "$T/repo-wt/m-050" 10
session "$OLD" "$T/repo-wt/m-050" 900
session "$OTHER" "$T/repo-wt/m-052-elsewhere" 5
session dddddddd-1111-2222-3333-444444444444 "$T/repo-wt/m-050" 1 "$SID"

# --- 1. refusals ---------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "FROM=c-050 TO_BOX=sat" "FROM=m-050 TO_BOX=pc" "FROM=m-051 TO_BOX=sat" "FROM=m-050 TO_BOX=Sat!" "FROM=m-050 TO_BOX=sat HANDOVER_MODE=C" "FROM=m-050 TO_BOX=sat TO_ID=c-070"; do
  # shellcheck disable=SC2086 # the words are VAR=value pairs
  run_ho $bad; rc=$?
  [[ $rc -ne 0 ]] || fail "1: '$bad' was not refused"
done
[[ ! -s "$T/calls.log" && -z "$(ref_of m-050)" ]] && pass "1: refusals: no call, nothing pushed" || fail "1: calls: $(calls)"

# --- 2. dry run ---------------------------------------------------------------------------
run_ho FROM=m-050 TO_BOX=sat; rc=$?
[[ $rc -eq 0 ]] && grep -q '^HANDOVER m-050@pc -> m-050@sat mode=A$' "$T/o" && grep -q "^PLAN session .*vibe session $SID " "$T/o" &&
  pass "2a: DRY_RUN default: mode A on the newest root session of the worktree" || fail "2a: rc=$rc $(cat "$T/o")"
[[ ! -s "$T/calls.log" && -z "$(ref_of m-050)" ]] && pass "2b: dry run: no ssh, no close, nothing pushed" || fail "2b: $(calls)"

# --- 3. B: another TO_ID, no session, key material in the session ------------------------------
run_ho FROM=m-050 TO_BOX=sat TO_ID=m-070
grep -q 'mode=B (TO_ID m-070 != m-050' "$T/o" && grep -q '^PLAN spawn .*spawn-window.sh mistral m-070' "$T/o" && pass "3a: another TO_ID: B" || fail "3a: $(cat "$T/o")"
run_ho FROM=m-052 TO_BOX=sat
grep -q 'mode=B (no vibe session of ' "$T/o" && pass "3b: no session of the worktree (another's does not count): B" || fail "3b: $(cat "$T/o")"
cp "$U/$SID/chunks/c1.json" "$T/c1.bak"; printf '%s\n' "$KEYLINE" >>"$U/$SID/chunks/c1.json"
run_ho FROM=m-050 TO_BOX=sat
grep -q 'mode=B (the session scan found key material' "$T/o" && pass "3c: key material in the session: B, it stays here" || fail "3c: $(cat "$T/o")"
cp "$T/c1.bak" "$U/$SID/chunks/c1.json"

# --- 4. RED CONTROL: key material in the WIP ------------------------------------------------
printf '%s\n' "$KEYLINE" >"$T/repo-wt/m-050/leak.txt"
: >"$T/calls.log"
run_ho FROM=m-050 TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -eq 3 ]] && grep -qx 'HIT leak.txt key' "$T/o" && pass "4a: WIP key material: exit 3, the file named" || fail "4a: rc=$rc $(cat "$T/o")"
[[ -z "$(ref_of m-050)" && ! -s "$T/calls.log" ]] && pass "4b: nothing pushed, no ssh call, FROM not closed" || fail "4b: $(calls)"
rm -f "$T/repo-wt/m-050/leak.txt"

# --- 5. DRY_RUN=0, mode A -------------------------------------------------------------------
: >"$T/calls.log"
run_ho FROM=m-050 TO_BOX=sat DRY_RUN=0; rc=$?
sha="$(ref_of m-050)"
[[ $rc -eq 0 && -n "$sha" ]] && grep -q '^OK HANDOVER m-050@pc -> m-050@sat mode=A' "$T/o" &&
  pass "5a: handed over in mode A, the wip ref pushed" || fail "5a: rc=$rc $(cat "$T/o")"
RW="$T/r/repo-wt/m-050"
[[ "$(git -C "$RW" rev-parse HEAD 2>/dev/null)" == "$sha" && "$(git -C "$RW" rev-parse --abbrev-ref HEAD)" == m-050-handover && -f "$RW/w.txt" ]] &&
  pass "5b: the target worktree is on m-050-handover AT the wip ref, FROM's WIP in it" || fail "5b: $(git -C "$RW" log --oneline -1 2>&1)"
RU="$T/rhome/.vibe/logs/session/unified"
cmp -s "$RU/$SID/chunks/c1.json" "$U/$SID/chunks/c1.json" && [[ -f "$RU/$SID/CURRENT" && ! -e "$RU/$OLD" && ! -e "$RU/$OTHER" ]] &&
  pass "5c: only session $SID lands in the agent user's unified/" || fail "5c: $(ls -R "$T/rhome" 2>&1 | sed -n 1,10p)"
! grep -qF "$SECRET_T" "$T/calls.log" "$T/o" && pass "5d: the session never rides argv or the output" || fail "5d: session in argv/output"
grep -q '^next-agent-id --claim m-050' "$T/calls.log" && grep -qx "RESUMED $SID" "$T/vibe.log" && grep -qF "$SECRET_T" "$T/vibe.log" &&
  grep -q "^vibe cwd=$RW home=$T/rhome argv=.*--resume $SID " "$T/vibe.log" &&
  pass "5e: the window ran vibe --resume $SID as the agent user in the new worktree; the old conversation came back" ||
  fail "5e: $(cat "$T/vibe.log" 2>&1 | cut -c1-200) / $(tail -n5 "$T/window.log" 2>&1)"
mv "$RU/$SID" "$T/sid.moved"; : >"$T/vibe.log"
PATH="$T/stub/remote-bin:$PATH" STUB_LOG="$T/calls.log" SPOOL_ROOT="$T/spool" FAKE_REMOTE_HOME="$T/rhome" bash -c "$(cat "$T/window.cmd")" </dev/null >/dev/null 2>&1
grep -qx "NOT-FOUND $SID" "$T/vibe.log" && ! grep -q RESUMED "$T/vibe.log" &&
  pass "5e: control: the same window command without the copied session resumes nothing" || fail "5e control: $(cat "$T/vibe.log")"
mv "$T/sid.moved" "$RU/$SID"
LB="$T/spool/m-050/lifetime/brief.md" TF="$T/rhome/.vibe/trusted_folders.toml"
grep -q '^# Handover: m-050@sat continues the lane m-050@pc' "$LB" && grep -qF "'$LB'" "$T/window.cmd" &&
  grep -qF "\"$(cd "$RW" && pwd -P)\"" "$TF" && grep -q '^sudo-as agentx' "$T/calls.log" &&
  pass "5h: the handover brief is the target lane's lifetime/brief.md, the kick names it; the worktree is trusted for vibe" ||
  fail "5h: $(head -n1 "$LB" 2>&1) / $(cat "$TF" 2>&1)"
# trust-workdir's detached settler re-asserts the entry while it holds the spawn lock: wait it out
flock "$T/rhome/.spool-spawn-trust.lock" true
cp "$TF" "$T/tf.ok"; printf 'trusted = []\nuntrusted = []\n' >"$TF"; : >"$T/vibe.log"
PATH="$T/stub/remote-bin:$PATH" STUB_LOG="$T/calls.log" SPOOL_ROOT="$T/spool" FAKE_REMOTE_HOME="$T/rhome" bash -c "$(cat "$T/window.cmd")" </dev/null >/dev/null 2>&1
grep -q '^TRUST-PROMPT ' "$T/vibe.log" && ! grep -q RESUMED "$T/vibe.log" &&
  pass "5h: control: the same window command in an untrusted worktree stops on the trust prompt" || fail "5h control: $(cat "$T/vibe.log")"
cp "$T/tf.ok" "$TF"
grep -q "^m-050	mistral	%88	$RW	" "$T/spool/registry.tsv" && grep -qx 'close --agent m-050 pushed=no' "$T/calls.log" && pass "5f: registry row kind mistral; FROM was closed before its wip ref was pushed" || fail "5f: $(tail -n2 "$T/spool/registry.tsv")"
c="$(grep -n '^close --agent m-050' "$T/calls.log" | cut -d: -f1)"; r="$(grep -n '^retire RETIRE_WORKTREE=0 --apply m-050' "$T/calls.log" | cut -d: -f1)"
[[ -n "$c" && -n "$r" && "$c" -lt "$r" && -d "$T/repo-wt/m-050" ]] && grep -q '^sudo-as agentx' "$T/calls.log" &&
  pass "5g: FROM closed first, retired last, worktree kept; the session lands as the agent user" || fail "5g: $(calls | grep -E '^(close|retire|sudo-as)')"

# --- 6. DRY_RUN=0, mode B -------------------------------------------------------------------
lane m-060
session eeeeeeee-1111-2222-3333-444444444444 "$T/repo-wt/m-060" 3
: >"$T/calls.log"
run_ho FROM=m-060 TO_BOX=sat DRY_RUN=0 HANDOVER_MODE=B; rc=$?
B="$T/spool/handover/m-060-from-m-060.md"
[[ $rc -eq 0 ]] && grep -q "^spawn-window mistral m-060 $T/r/repo $B handover" "$T/calls.log" &&
  pass "6a: B: spawn-window.sh mistral m-060 with the handover brief" || fail "6a: rc=$rc $(cat "$T/o") $(calls | grep spawn)"
grep -q "^## m-060's handoff (spec 102)" "$B" && grep -q 'dispatch-abcd1234' "$B" && grep -q '# Brief: the task of m-060' "$B" &&
  ! grep -q '^tmux new-window' "$T/calls.log" && [[ ! -e "$RU/eeeeeeee-1111-2222-3333-444444444444" ]] &&
  pass "6b: the B brief carries brief, task and handoff; no resume, no session copied" || fail "6b: $(sed -n 1,30p "$B")"

# --- 7. RED CONTROL: a failed session copy --------------------------------------------------
lane m-055
session ffffffff-1111-2222-3333-444444444444 "$T/repo-wt/m-055" 3
mv "$T/rhome" "$T/rhome.ok"; printf 'not a dir\n' >"$T/rhome"
: >"$T/calls.log"
run_ho FROM=m-055 TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -ne 0 && -z "$(ref_of m-055)" ]] && ! grep -q '^close' "$T/calls.log" && grep -q 'the session copy to sat failed' "$T/o" &&
  pass "7: a failed session copy: exit $rc, FROM not closed, nothing pushed" || fail "7: rc=$rc $(cat "$T/o") $(calls | grep -E '^(close|retire)')"
rm -f "$T/rhome"; mv "$T/rhome.ok" "$T/rhome"

# --- 8. RED CONTROL: the worktree's trust does not verify -----------------------------------
lane m-057
session 77777777-1111-2222-3333-444444444444 "$T/repo-wt/m-057" 3
mv "$TF" "$T/tf.ok"; mkdir "$TF"
: >"$T/calls.log"
run_ho FROM=m-057 TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'did not verify: vibe would stop on its trust prompt' "$T/o" && ! grep -q '^tmux new-window' "$T/calls.log" &&
  ! grep -q '^retire' "$T/calls.log" &&
  pass "8: trust that does not verify: exit $rc, no window started, FROM not retired" || fail "8: rc=$rc $(cat "$T/o") $(calls | grep -E '^(tmux|retire)')"
rmdir "$TF"; mv "$T/tf.ok" "$TF"

echo "spl-lane-handover-mistral: $fails failure(s)"
[[ $fails -eq 0 ]]
