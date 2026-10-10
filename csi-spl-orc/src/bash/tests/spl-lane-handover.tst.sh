#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_handover (t1 ba8104f6), offline. A bare repo plays
#          origin, $T/repo the main checkout with FROM's linked worktree; ssh
#          is a stub that plays the target box: its env file, and the command
#          run with every $T/repo path moved to $T/r/repo (the other box's
#          disk). sudo, tmux and the spawn scripts are stubs that log.
#   1. refusals before any call: a bad FROM, the same id on this box, a
#      non-claude lane
#   2. DRY_RUN is the default: mode A, the plan, no ssh call, nothing pushed
#   3. mode B when TO_ID differs, and when the transcript holds key material
#   4. RED CONTROL: key material in FROM's WIP -> exit 3, no ssh, no close,
#      NOTHING pushed
#   5. a box answering to another tag: refused before FROM is closed or pushed
#   6. DRY_RUN=0, A: the wip ref, the target worktree AT it, the transcript
#      copied over ssh stdin (never in argv), restore-claude.sh resumes the
#      session id, the brief on the target, FROM closed then retired with
#      RETIRE_WORKTREE=0, FROM's worktree kept
#   7. DRY_RUN=0, B: spawn-window.sh claude <TO_ID> with the handover brief,
#      which carries FROM's brief, task id and handoff
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
SID=11111111-2222-3333-4444-555555555555
SECRET_T="transcript-body-$RANDOM$RANDOM"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
echo base >"$T/repo/a.txt"; git -C "$T/repo" add a.txt; git -C "$T/repo" commit -qm base; git -C "$T/repo" push -q origin master
git -C "$T/repo" remote set-head origin master >/dev/null
git clone -q "$T/origin.git" "$T/r/repo" 2>/dev/null

# lane <id> [kind]: FROM's worktree, identity record, registry row, brief, outbox, transcript
lane() {
  local id="$1" kind="${2:-claude}" wt="$T/repo-wt/$1" slug
  git -C "$T/repo" worktree add -q -b "$id-x" "$wt" origin/master
  echo "wip of $id" >"$wt/w.txt"
  jq -n --arg id "$id" --arg k "$kind" --arg s "$SID" --arg w "$wt" --arg u "$ME" \
    '{id:$id, kind:$k, session_id:$s, worktree:$w, user:$u, alive:true}' >"$T/spool/agents/$id.json"
  printf '%s\tclaude\t%%9\t%s\t20261010T000000Z\tc-001\n' "$id" "$wt" >>"$T/spool/registry.tsv"
  mkdir -p "$T/spool/$id/lifetime" "$T/spool/$id/outbox"
  echo "# Brief: the task of $id" >"$T/spool/$id/lifetime/brief.md"
  jq -n '{kind:"note", to:"c-001", task_id:"dispatch-abcd1234", ts:"2026-10-10T00:00:00Z", body:"half done"}' >"$T/spool/$id/outbox/1.json"
  slug="$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$T/ahome/.claude/projects/$slug/$SID"
  echo "{\"x\":\"$SECRET_T\"}" >"$T/ahome/.claude/projects/$slug/$SID.jsonl"
  echo sub >"$T/ahome/.claude/projects/$slug/$SID/sub.txt"
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
cat >"$T/stub/remote-bin/faketmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >>"$STUB_LOG"
case "$1" in list-sessions) echo '1 $0' ;; new-window) echo '%88' ;; esac
EOF
printf '#!/bin/sh\necho "close $*" >>"$STUB_LOG"\nexit 3\n' >"$T/stub/close"
printf '#!/bin/sh\necho "retire RETIRE_WORKTREE=$RETIRE_WORKTREE $*" >>"$STUB_LOG"\n' >"$T/stub/retire"
chmod +x "$T/stub/"* "$T/stub/remote-bin/"*
# the target's spawn-agents scripts
cat >"$T/fs/lib/spool-env.inc.sh" <<'EOF'
spool_env_resolve() { SPOOL_ROOT="${SPOOL_ROOT:-/nonexistent}"; }
spool_tmux_argv() { SPOOL_TM=(faketmux); }
spool_decorate() { printf '%s@sat' "$1"; }
EOF
mkdir -p "$T/fs/scripts"
printf '#!/bin/sh\necho "next-agent-id $*" >>"$STUB_LOG"\n' >"$T/fs/scripts/next-agent-id.sh"
printf '#!/bin/sh\n' >"$T/fs/scripts/install-pre-push-hook.sh"
printf '#!/bin/sh\necho "spawn-window $*" >>"$STUB_LOG"\necho "$2 %%77"\n' >"$T/fs/scripts/spawn-window.sh"

run_ho() {
  SNIPPET=do_spl_lane_handover in_orc SPOOL_ROOT="$T/spool" BOX=pc HANDOVER_AGENT_HOME="$T/ahome" \
    HANDOVER_SCRIPTS_DIR="$T/fs/scripts" HANDOVER_CLOSE_CMD="$T/stub/close" HANDOVER_RETIRE_CMD="$T/stub/retire" \
    HANDOFF_CAPTURE_CMD="echo terminal-line" FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" FAKE_REMOTE_HOME="$T/rhome" \
    FAKE_LOCAL_REPO="$T/repo" FAKE_REMOTE_REPO="$T/r/repo" "$@" >"$T/o" 2>&1
}
ref_of() { git -C "$T/origin.git" rev-parse -q --verify "refs/heads/wip/handover/$1" 2>/dev/null; }
calls() { cat "$T/calls.log" 2>/dev/null; }

lane c-050
lane c-051 grok

# --- 1. refusals ---------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "FROM=x-050 TO_BOX=sat" "FROM=c-050 TO_BOX=pc" "FROM=c-051 TO_BOX=sat" "FROM=c-050 TO_BOX=Sat!" "FROM=c-050 TO_BOX=sat HANDOVER_MODE=C"; do
  # shellcheck disable=SC2086 # the words are VAR=value pairs
  run_ho $bad; rc=$?
  [[ $rc -ne 0 ]] || fail "1: '$bad' was not refused"
done
[[ ! -s "$T/calls.log" && -z "$(ref_of c-050)" ]] && pass "1: refusals: no call, nothing pushed" || fail "1: calls: $(calls)"

# --- 2. dry run ---------------------------------------------------------------------------
run_ho FROM=c-050 TO_BOX=sat; rc=$?
[[ $rc -eq 0 ]] && grep -q '^HANDOVER c-050@pc -> c-050@sat mode=A$' "$T/o" && grep -q '^PLAN session' "$T/o" &&
  pass "2a: DRY_RUN default: mode A, the plan" || fail "2a: rc=$rc $(cat "$T/o")"
[[ ! -s "$T/calls.log" && -z "$(ref_of c-050)" ]] && pass "2b: dry run: no ssh, no close, nothing pushed" || fail "2b: $(calls)"

# --- 3. B when TO_ID differs, or the transcript holds key material --------------------------
run_ho FROM=c-050 TO_BOX=sat TO_ID=c-070
grep -q 'mode=B (TO_ID c-070 != c-050' "$T/o" && grep -q '^PLAN spawn' "$T/o" && pass "3a: another TO_ID: B" || fail "3a: $(cat "$T/o")"
tj="$(ls "$T/ahome/.claude/projects/"*c-050/$SID.jsonl)"
cp "$tj" "$T/tj.bak"; printf '%s\n' "$KEYLINE" >>"$tj"
run_ho FROM=c-050 TO_BOX=sat
grep -q 'mode=B (the transcript scan found key material' "$T/o" && pass "3b: key material in the transcript: B, it stays here" || fail "3b: $(cat "$T/o")"
cp "$T/tj.bak" "$tj"

# --- 4. RED CONTROL: key material in the WIP ------------------------------------------------
printf '%s\n' "$KEYLINE" >"$T/repo-wt/c-050/leak.txt"
: >"$T/calls.log"
run_ho FROM=c-050 TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -eq 3 ]] && grep -qx 'HIT leak.txt key' "$T/o" && pass "4a: WIP key material: exit 3, the file named" || fail "4a: rc=$rc $(cat "$T/o")"
[[ -z "$(ref_of c-050)" ]] && pass "4b: nothing pushed when the scan fails" || fail "4b: a ref was pushed"
[[ ! -s "$T/calls.log" ]] && pass "4c: no ssh call, FROM not closed" || fail "4c: $(calls)"
rm -f "$T/repo-wt/c-050/leak.txt"

# --- 5. a box answering to another tag ------------------------------------------------------
printf 'OWNER_USER=ownerx\nAGENT_USER=agentx\nBOX_TAG=pc\n' >"$T/box2.env"
: >"$T/calls.log"
run_ho FROM=c-050 TO_BOX=sat DRY_RUN=0 FAKE_BOX_ENV="$T/box2.env"; rc=$?
[[ $rc -ne 0 && -z "$(ref_of c-050)" ]] && ! grep -q '^close' "$T/calls.log" && grep -q "answers as box 'pc'" "$T/o" &&
  pass "5: another BOX_TAG: refused before FROM is closed or pushed" || fail "5: rc=$rc $(cat "$T/o") $(calls)"

# --- 6. DRY_RUN=0, mode A -------------------------------------------------------------------
: >"$T/calls.log"
run_ho FROM=c-050 TO_BOX=sat DRY_RUN=0; rc=$?
sha="$(ref_of c-050)"
[[ $rc -eq 0 && -n "$sha" ]] && grep -q '^OK HANDOVER c-050@pc -> c-050@sat mode=A' "$T/o" &&
  pass "6a: handed over in mode A, the wip ref pushed" || fail "6a: rc=$rc $(cat "$T/o")"
RW="$T/r/repo-wt/c-050"
[[ "$(git -C "$RW" rev-parse HEAD 2>/dev/null)" == "$sha" && "$(git -C "$RW" rev-parse --abbrev-ref HEAD)" == c-050-handover && -f "$RW/w.txt" ]] &&
  pass "6b: the target worktree is on c-050-handover AT the wip ref, FROM's WIP in it" || fail "6b: $(git -C "$RW" log --oneline -1 2>&1)"
slug="$(printf '%s' "$T/repo-wt/c-050" | sed 's/[^A-Za-z0-9]/-/g')"
cmp -s "$T/rhome/.claude/projects/$slug/$SID.jsonl" "$tj" && [[ -f "$T/rhome/.claude/projects/$slug/$SID/sub.txt" ]] &&
  pass "6c: the transcript and its <sid>/ dir are in the agent user's projects, same slug" || fail "6c: $(ls -R "$T/rhome" 2>&1 | sed -n 1,10p)"
! grep -qF "$SECRET_T" "$T/calls.log" "$T/o" && pass "6d: the transcript never rides argv or the output" || fail "6d: transcript in argv/output"
grep -q "^tmux new-window .*restore-claude.sh' 'c-050' '$RW' '$SID' '$T/spool/handover/c-050-from-c-050.md'" "$T/calls.log" &&
  grep -q '^next-agent-id --claim c-050' "$T/calls.log" && pass "6e: restore-claude.sh resumes session $SID in the new worktree" || fail "6e: $(calls | grep -E 'tmux|next')"
B="$T/spool/handover/c-050-from-c-050.md"
grep -q 'dispatch-abcd1234' "$B" && grep -qF "git push origin :refs/heads/wip/handover/c-050" "$B" && grep -q '# Brief: the task of c-050' "$B" &&
  pass "6f: the brief: FROM's brief, task id, the delete-ref step" || fail "6f: $(sed -n 1,20p "$B" 2>&1)"
c="$(grep -n '^close --agent c-050' "$T/calls.log" | cut -d: -f1)"; r="$(grep -n '^retire RETIRE_WORKTREE=0 --apply c-050' "$T/calls.log" | cut -d: -f1)"
[[ -n "$c" && -n "$r" && "$c" -lt "$r" ]] && [[ -d "$T/repo-wt/c-050" ]] &&
  pass "6g: FROM closed first, retired last with RETIRE_WORKTREE=0, its worktree kept" || fail "6g: $(calls | grep -E '^(close|retire)')"
grep -q '^sudo-as agentx' "$T/calls.log" && grep -q '^sudo-as ownerx' "$T/calls.log" &&
  pass "6h: the transcript lands as the agent user, the rest as the owner" || fail "6h: $(calls | grep sudo-as)"

# --- 7. DRY_RUN=0, mode B -------------------------------------------------------------------
lane c-060
: >"$T/calls.log"
run_ho FROM=c-060 TO_BOX=sat DRY_RUN=0 HANDOVER_MODE=B; rc=$?
B="$T/spool/handover/c-060-from-c-060.md"
[[ $rc -eq 0 ]] && grep -q "^spawn-window claude c-060 $T/r/repo $B handover" "$T/calls.log" &&
  pass "7a: B: spawn-window.sh claude c-060 with the handover brief" || fail "7a: rc=$rc $(cat "$T/o") $(calls | grep spawn)"
grep -q "^## c-060's handoff (spec 102)" "$B" && grep -q 'dispatch-abcd1234' "$B" && ! grep -q '^tmux new-window' "$T/calls.log" &&
  pass "7b: the B brief carries the handoff; no resume" || fail "7b: $(sed -n 1,30p "$B")"
[[ ! -e "$T/rhome/.claude/projects/$(printf '%s' "$T/repo-wt/c-060" | sed 's/[^A-Za-z0-9]/-/g')" ]] &&
  pass "7c: B copies no transcript" || fail "7c: a transcript was copied"

echo "spl-lane-handover: $fails failure(s)"
[[ $fails -eq 0 ]]
