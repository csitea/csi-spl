#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_handover_agy (t1 ba8104f6, topic ab98ad27), offline.
#          The harness of spl-lane-handover-mistral.tst.sh: a bare repo plays
#          origin, $T/repo the main checkout with FROM's linked worktree; ssh
#          is a stub that plays the target box (its env file, every $T/repo
#          path moved to $T/r/repo). sudo, tmux and the spawn scripts are stubs
#          that log. FROM's agy conversation sits in
#          $T/ahome/.gemini/antigravity-cli, next to an older one of the same
#          worktree and one of another (history.jsonl names them).
#   1. refusals before any call: a bad FROM, the same id on this box, a
#      non-agy lane
#   2. DRY_RUN is the default: mode A on the NEWEST history.jsonl conversation
#      of FROM's worktree, the plan, no ssh call, nothing pushed; the
#      conversation FROM's live agy holds open wins over history
#   3. mode B when TO_ID differs, when no conversation names the worktree, and
#      when the conversation holds key material
#   4. RED CONTROL: key material in FROM's WIP -> exit 3, no ssh, no close,
#      NOTHING pushed
#   5. DRY_RUN=0, A: the wip ref, the target worktree AT it, the conversation
#      over ssh stdin (never argv) into the agent user's antigravity-cli,
#      restore-agy.sh resumes it, and the LAUNCH line that script really runs
#      carries `--conversation <c>` in the skip-permissions mode; FROM closed
#      first, retired last
#   6. RED CONTROL on 15415d332: its start, spawn-window.sh agy ... handover
#      --conversation <c>, launches through spawn-agy.sh with no
#      --conversation: the same launch check fails on it
#   7. DRY_RUN=0, B: spawn-window.sh agy <TO_ID> with the handover brief
#   8. a failed conversation copy exits 4 BEFORE FROM is touched (no close,
#      nothing pushed) and a rerun replaces the staged copy; a failed prep
#      after the WIP push exits 4 and names the step, nothing started
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v zstd >/dev/null && command -v jq >/dev/null || { echo "SKIP: no zstd or jq"; exit 0; }

ME="$(id -un)"
REAL_HOME="$HOME"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME" "$T/spool/agents" "$T/r" "$T/ahome" "$T/rhome" "$T/fs/lib" "$T/stub/remote-bin"
git config --global init.defaultBranch master
git config --global safe.directory '*'
git config --global user.name "FirstName LastName"
git config --global user.email "owner@example.com"
KEYLINE="$(printf -- '-----%s %s %s-----' BEGIN PRIVATE KEY)"
CONV=aaaaaaaa-1111-2222-3333-444444444444
OLD=bbbbbbbb-1111-2222-3333-444444444444
OTHER=cccccccc-1111-2222-3333-444444444444
LIVE=dddddddd-1111-2222-3333-444444444444
SECRET_T="conversation-body-$RANDOM$RANDOM"
G="$T/ahome/.gemini/antigravity-cli"
SPAWN_SCRIPTS="$PROJ_ROOT/src/bash/features/spawn-agents/scripts"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
echo base >"$T/repo/a.txt"; git -C "$T/repo" add a.txt; git -C "$T/repo" commit -qm base; git -C "$T/repo" push -q origin master
git -C "$T/repo" remote set-head origin master >/dev/null
git clone -q "$T/origin.git" "$T/r/repo" 2>/dev/null

# conv CONV WT: an agy conversation of WT (db, wal, brain, annotations) and its history.jsonl line
conv() {
  mkdir -p "$G/conversations" "$G/brain/$1/.system_generated" "$G/annotations" "$G/presence"
  echo "db $SECRET_T" >"$G/conversations/$1.db"; echo wal >"$G/conversations/$1.db-wal"
  echo "brain $1" >"$G/brain/$1/.system_generated/steps.txt"; echo note >"$G/annotations/$1.pbtxt"
  : >"$G/presence/$1.lock"
  jq -cn --arg c "$1" --arg w "$2" '{display:"hi", workspace:$w, conversationId:$c}' >>"$G/history.jsonl"
}

# lane <id> [kind]: FROM's worktree, identity record (no session id, as live a- records), registry row, brief, outbox
lane() {
  local id="$1" kind="${2:-agy}" wt="$T/repo-wt/$1"
  git -C "$T/repo" worktree add -q -b "$id-x" "$wt" origin/master
  echo "wip of $id" >"$wt/w.txt"
  jq -n --arg id "$id" --arg k "$kind" --arg w "$wt" --arg u "$ME" \
    '{id:$id, kind:$k, session_id:null, worktree:$w, user:$u, alive:true}' >"$T/spool/agents/$id.json"
  printf '%s\tagy\t%%9\t%s\t20261010T000000Z\tc-001\n' "$id" "$wt" >>"$T/spool/registry.tsv"
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
[[ -n "${FAKE_SSH_FAIL:-}" && "$cmd" == *" $FAKE_SSH_FAIL "* ]] && { echo "ssh: $FAKE_SSH_FAIL refused" >&2; exit 255; }
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
cat >"$T/fs/lib/spool-env.inc.sh" <<'EOF'
spool_env_resolve() { SPOOL_ROOT="${SPOOL_ROOT:-/nonexistent}"; }
spool_tmux_argv() { SPOOL_TM=(faketmux); }
spool_decorate() { printf '%s@sat' "$1"; }
EOF
mkdir -p "$T/fs/scripts"
printf '#!/bin/sh\necho "next-agent-id $*" >>"$STUB_LOG"\n' >"$T/fs/scripts/next-agent-id.sh"
printf '#!/bin/sh\necho "trust $*" >>"$STUB_LOG"\n' >"$T/fs/scripts/trust-workdir.sh"
printf '#!/bin/sh\n' >"$T/fs/scripts/install-pre-push-hook.sh"
printf '#!/bin/sh\necho "spawn-window $*" >>"$STUB_LOG"\necho "$2 %%77"\n' >"$T/fs/scripts/spawn-window.sh"

run_ho() {
  SNIPPET=do_spl_lane_handover_agy in_orc SPOOL_ROOT="$T/spool" BOX=pc HANDOVER_AGENT_HOME="$T/ahome" \
    HANDOVER_SCRIPTS_DIR="$T/fs/scripts" HANDOVER_CLOSE_CMD="$T/stub/close" HANDOVER_RETIRE_CMD="$T/stub/retire" \
    HANDOFF_CAPTURE_CMD="echo terminal-line" FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" FAKE_REMOTE_HOME="$T/rhome" \
    FAKE_LOCAL_REPO="$T/repo" FAKE_REMOTE_REPO="$T/r/repo" "$@" >"$T/o" 2>&1
}
ref_of() { git -C "$T/origin.git" rev-parse -q --verify "refs/heads/wip/handover/$1" 2>/dev/null; }
calls() { cat "$T/calls.log" 2>/dev/null; }

# launch_resumes ID CONV <launcher argv...>: the launcher prints (RESTORE_PRINT /
# SPAWN_DRY_RUN) the line it would exec; true when that line starts agy for ID
# with --conversation CONV in the skip-permissions mode
launch_resumes() {
  local id="$1" c="$2" line; shift 2
  line="$(env -u SPOOL_AGENT_ID HOME="$REAL_HOME" SPOOL_ROOT="$T/lspool" AGY_BIN=agy RESTORE_PRINT=1 SPAWN_DRY_RUN=1 SPAWN_TEST_SANDBOX=1 \
    bash "$@" 2>&1 | sed -n "s/^PLAN launch *//; /spool-harness.sh' --as '$id'/p" | sed -n 1p)"
  echo "$line" >"$T/launch"
  [[ "$line" == *"'agy' --dangerously-skip-permissions --conversation $c "* ]]
}

lane a-950
lane a-951 claude
lane a-952
conv "$OLD" "$T/repo-wt/a-950"
conv "$OTHER" "$T/repo-wt/a-952-elsewhere"
conv "$CONV" "$T/repo-wt/a-950"

# --- 1. refusals ---------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "FROM=c-950 TO_BOX=sat" "FROM=a-950 TO_BOX=pc" "FROM=a-951 TO_BOX=sat" "FROM=a-950 TO_BOX=Sat!" "FROM=a-950 TO_BOX=sat HANDOVER_MODE=C" "FROM=a-950 TO_BOX=sat TO_ID=m-070"; do
  # shellcheck disable=SC2086 # the words are VAR=value pairs
  run_ho $bad; rc=$?
  [[ $rc -ne 0 ]] || fail "1: '$bad' was not refused"
done
[[ ! -s "$T/calls.log" && -z "$(ref_of a-950)" ]] && pass "1: refusals: no call, nothing pushed" || fail "1: calls: $(calls)"

# --- 2. dry run ---------------------------------------------------------------------------
run_ho FROM=a-950 TO_BOX=sat; rc=$?
[[ $rc -eq 0 ]] && grep -q '^HANDOVER a-950@pc -> a-950@sat mode=A$' "$T/o" && grep -q "^PLAN session .*agy conversation $CONV .*--conversation $CONV" "$T/o" &&
  pass "2a: DRY_RUN default: mode A on the newest history.jsonl conversation of the worktree" || fail "2a: rc=$rc $(cat "$T/o")"
[[ ! -s "$T/calls.log" && -z "$(ref_of a-950)" ]] && pass "2b: dry run: no ssh, no close, nothing pushed" || fail "2b: $(calls)"
conv "$LIVE" "$T/repo-wt/a-953-elsewhere"
(exec env SPOOL_AGENT_ID=a-950 sleep 60 3<"$G/conversations/$LIVE.db") & lp=$!
sleep 0.3
run_ho FROM=a-950 TO_BOX=sat
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
grep -q "^PLAN session .*agy conversation $LIVE " "$T/o" && pass "2c: the conversation FROM's live agy holds open wins over history" || fail "2c: $(cat "$T/o")"

# --- 3. B: another TO_ID, no conversation, key material in it ---------------------------------
run_ho FROM=a-950 TO_BOX=sat TO_ID=a-970
grep -q 'mode=B (TO_ID a-970 != a-950' "$T/o" && grep -q '^PLAN spawn .*spawn-window.sh agy a-970' "$T/o" && pass "3a: another TO_ID: B" || fail "3a: $(cat "$T/o")"
run_ho FROM=a-952 TO_BOX=sat
grep -q 'mode=B (no agy conversation of a-952' "$T/o" && pass "3b: no conversation of the worktree (another's does not count): B" || fail "3b: $(cat "$T/o")"
cp "$G/brain/$CONV/.system_generated/steps.txt" "$T/s.bak"; printf '%s\n' "$KEYLINE" >>"$G/brain/$CONV/.system_generated/steps.txt"
run_ho FROM=a-950 TO_BOX=sat
grep -q 'mode=B (the conversation scan found key material' "$T/o" && pass "3c: key material in the conversation: B, it stays here" || fail "3c: $(cat "$T/o")"
cp "$T/s.bak" "$G/brain/$CONV/.system_generated/steps.txt"

# --- 4. RED CONTROL: key material in the WIP ------------------------------------------------
printf '%s\n' "$KEYLINE" >"$T/repo-wt/a-950/leak.txt"
: >"$T/calls.log"
run_ho FROM=a-950 TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -eq 3 ]] && grep -qx 'HIT leak.txt key' "$T/o" && pass "4a: WIP key material: exit 3, the file named" || fail "4a: rc=$rc $(cat "$T/o")"
[[ -z "$(ref_of a-950)" && ! -s "$T/calls.log" ]] && pass "4b: nothing pushed, no ssh call, FROM not closed" || fail "4b: $(calls)"
rm -f "$T/repo-wt/a-950/leak.txt"

# --- 5. DRY_RUN=0, mode A -------------------------------------------------------------------
: >"$T/calls.log"
run_ho FROM=a-950 TO_BOX=sat DRY_RUN=0; rc=$?
sha="$(ref_of a-950)"
[[ $rc -eq 0 && -n "$sha" ]] && grep -q '^OK HANDOVER a-950@pc -> a-950@sat mode=A' "$T/o" &&
  pass "5a: handed over in mode A, the wip ref pushed" || fail "5a: rc=$rc $(cat "$T/o")"
RW="$T/r/repo-wt/a-950"
[[ "$(git -C "$RW" rev-parse HEAD 2>/dev/null)" == "$sha" && "$(git -C "$RW" rev-parse --abbrev-ref HEAD)" == a-950-handover && -f "$RW/w.txt" ]] &&
  pass "5b: the target worktree is on a-950-handover AT the wip ref, FROM's WIP in it" || fail "5b: $(git -C "$RW" log --oneline -1 2>&1)"
RG="$T/rhome/.gemini/antigravity-cli"
cmp -s "$RG/conversations/$CONV.db" "$G/conversations/$CONV.db" && [[ -f "$RG/conversations/$CONV.db-wal" && -f "$RG/brain/$CONV/.system_generated/steps.txt" && -f "$RG/annotations/$CONV.pbtxt" ]] &&
  [[ ! -e "$RG/conversations/$OLD.db" && ! -e "$RG/conversations/$OTHER.db" && ! -e "$RG/presence" ]] &&
  pass "5c: only conversation $CONV (db, wal, brain, annotations; no presence lock) lands in the agent user's antigravity-cli" || fail "5c: $(cd "$T/rhome" && find . | sed -n 1,20p)"
! grep -qF "$SECRET_T" "$T/calls.log" "$T/o" && pass "5d: the conversation never rides argv or the output" || fail "5d: conversation in argv/output"
nw="$(grep "^tmux new-window .*restore-agy.sh' 'a-950' '$RW' '$CONV' 'HANDOVER: .*$T/spool/handover/a-950-from-a-950.md" "$T/calls.log")"
[[ -n "$nw" ]] && grep -q '^next-agent-id --claim a-950' "$T/calls.log" && grep -q "^trust $RW agentx agy" "$T/calls.log" &&
  pass "5e: restore-agy.sh resumes conversation $CONV in the new worktree (claimed, trusted)" || fail "5e: $(calls | grep -E 'tmux|next|trust')"
kick="$(sed -n "s/.*'$CONV' '\(HANDOVER: [^']*\)'.*/\1/p" <<<"$nw")"
if launch_resumes a-950 "$CONV" "$SPAWN_SCRIPTS/restore-agy.sh" a-950 "$RW" "$CONV" "$kick"; then
  pass "5f: the LAUNCH line restore-agy.sh runs: agy --dangerously-skip-permissions --conversation $CONV"
else fail "5f: launch line: $(cat "$T/launch")"; fi
grep -q "^a-950	agy	%88	$RW	" "$T/spool/registry.tsv" && pass "5g: registry row kind agy" || fail "5g: $(tail -n2 "$T/spool/registry.tsv")"
c="$(grep -n '^close --agent a-950' "$T/calls.log" | cut -d: -f1)"; p="$(grep -n ' prep ' "$T/calls.log" | sed -n 1p | cut -d: -f1)"
r="$(grep -n '^retire RETIRE_WORKTREE=0 --apply a-950' "$T/calls.log" | cut -d: -f1)"
[[ -n "$c" && -n "$p" && -n "$r" && "$c" -lt "$p" && "$p" -lt "$r" && -d "$T/repo-wt/a-950" ]] && grep -q '^sudo-as agentx' "$T/calls.log" &&
  pass "5h: FROM closed before the WIP push, retired after the start, worktree kept; the conversation lands as the agent user" ||
  fail "5h: $(calls | grep -E '^(close|retire|sudo-as)| prep ')"

# --- 6. RED CONTROL on 15415d332: spawn-window's extra words never reach the launch -----------
mkdir -p "$T/lspool" "$T/wd"; echo "# b" >"$T/wd.md"
if ! launch_resumes a-950 "$CONV" "$SPAWN_SCRIPTS/spawn-agy.sh" a-950 "$T/wd" "$T/wd.md" handover --conversation "$CONV" &&
  grep -q "spool-harness.sh' --as 'a-950'" "$T/launch"; then
  pass "6: RED CONTROL: 15415d332's start (spawn-agy.sh ... handover --conversation $CONV) launches agy with no --conversation"
else fail "6: control did not fail: $(cat "$T/launch")"; fi

# --- 7. DRY_RUN=0, mode B -------------------------------------------------------------------
lane a-960
conv eeeeeeee-1111-2222-3333-444444444444 "$T/repo-wt/a-960"
: >"$T/calls.log"
run_ho FROM=a-960 TO_BOX=sat DRY_RUN=0 HANDOVER_MODE=B; rc=$?
B="$T/spool/handover/a-960-from-a-960.md"
[[ $rc -eq 0 ]] && grep -q "^spawn-window agy a-960 $T/r/repo $B handover" "$T/calls.log" &&
  pass "7a: B: spawn-window.sh agy a-960 with the handover brief" || fail "7a: rc=$rc $(cat "$T/o") $(calls | grep spawn)"
grep -q "^## a-960's handoff (spec 102)" "$B" && grep -q 'dispatch-abcd1234' "$B" && grep -q '# Brief: the task of a-960' "$B" &&
  ! grep -q '^tmux new-window' "$T/calls.log" && [[ ! -e "$RG/conversations/eeeeeeee-1111-2222-3333-444444444444.db" ]] &&
  pass "7b: the B brief carries brief, task and handoff; no resume, no conversation copied" || fail "7b: $(sed -n 1,30p "$B")"

# --- 8. failures after the WIP push ------------------------------------------------------------
lane a-961
conv ffffffff-1111-2222-3333-444444444444 "$T/repo-wt/a-961"
: >"$T/calls.log"
run_ho FROM=a-961 TO_BOX=sat DRY_RUN=0 FAKE_SSH_FAIL=session; rc=$?
[[ $rc -eq 4 ]] && grep -q '^FATAL HANDOVER a-961: step session, the conversation copy to sat failed (ssh: session refused): a-961 untouched, nothing pushed' "$T/o" &&
  [[ -z "$(ref_of a-961)" ]] && ! grep -qE '^(close|retire|spawn-window|tmux new-window)' "$T/calls.log" &&
  pass "8a: a failed conversation copy: exit 4 before FROM is closed, nothing pushed, nothing started" || fail "8a: rc=$rc $(cat "$T/o") $(calls | grep -E '^(close|retire)')"
F="$RG/conversations/ffffffff-1111-2222-3333-444444444444.db"
mkdir -p "${F%/*}"; echo stale >"$F"
: >"$T/calls.log"
run_ho FROM=a-961 TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$F" "$G/conversations/ffffffff-1111-2222-3333-444444444444.db" && grep -q '^OK HANDOVER a-961@pc -> a-961@sat mode=A' "$T/o" &&
  [[ ! -e "$T/rhome/.gemini/.handover-ffffffff-1111-2222-3333-444444444444" ]] &&
  pass "8b: the rerun replaces a stale copy on the target and hands over in A" || fail "8b: rc=$rc $(cat "$T/o")"
lane a-962
: >"$T/calls.log"
run_ho FROM=a-962 TO_BOX=sat DRY_RUN=0 FAKE_SSH_FAIL=prep; rc=$?
[[ $rc -eq 4 ]] && grep -q '^FATAL HANDOVER a-962: step prep' "$T/o" && ! grep -q '^OK HANDOVER a-962@' "$T/o" &&
  ! grep -qE '^(retire|spawn-window|tmux new-window)' "$T/calls.log" &&
  pass "8c: a failed prep after the WIP push: exit 4, step named, nothing started, FROM not retired" || fail "8c: rc=$rc $(cat "$T/o")"

echo "spl-lane-handover-agy: $fails failure(s)"
[[ $fails -eq 0 ]]
