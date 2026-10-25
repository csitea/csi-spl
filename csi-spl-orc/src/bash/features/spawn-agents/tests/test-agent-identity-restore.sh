#!/usr/bin/env bash
# test-agent-identity-restore.sh — the identity map, step (d): a reboot
# restore starts each agent's OWN session in its OWN worktree, under its own
# id, and refuses - named, never guessed - everything it cannot prove.
#
# Fixture records stand for the map as the reboot left it; a fake
# restore-claude.sh (IDENTITY_RESTORE_ADAPTER_DIR) records its arguments and
# becomes a process with argv[0]=claude carrying SPOOL_AGENT_ID, as the real
# adapter's CLI would. Transcripts live in AI_TRANSCRIPT_HOME. A private tmux
# server re-issues low pane ids, as a restarted server does.
#
#   1. the dry run plans RESTORE for the two agents the restart killed and
#      starts nothing
#   2. it SKIPs an agent that went dead long before the restart, and REFUSEs,
#      with the reason: a session whose transcript belongs to another agent,
#      a session on two records, a session already running, a worktree that
#      is gone, a session with no transcript
#   3. DRY_RUN=0 starts exactly those two, each in a NEW window, with its own
#      session + worktree + id - a record's pre-restart pane id, now re-issued
#      to an unrelated window, is never touched
#   4. each started agent gets a fresh registry row naming its NEW pane
#   5. afterwards the windows are named from the map and check reports no
#      drift for them
#   6. the automatic pass (no IDENTITY_RESTORE_IDS) runs each adapter with
#      RESTORE_KEEP_HOLD=1: a spec 102 6.1 hold is the admin's to clear, and
#      only a restore by hand clears it (restore-core.inc.sh)
#   7. (SPL-2638, sat reboot 2026-10-18: g-002 and g-003 REFUSEd, "its session
#      is unknown") a ROLE seat (g-002 grok, c-003 claude) with no recorded
#      session plans RESTORE with session '-', a fresh start from its role
#      handoff; controls: a role seat without <id>/handoff.md and a sessionless
#      lane are still refused; the real restore-grok.sh / restore-claude.sh
#      start a NEW session (no --resume) kicked to the handoff, and an empty
#      session id is still refused; red control: the code before the fix
#      refuses the sessionless g- role seat
#   8. (SPL-3378, 2026-10-25: a restore by id on a box with no record of the
#      id printed only the since-window line and "0 started") a restore by id
#      prints one line per requested id it did not start, with the reason (no
#      record on this box; already running, with its pid), and no since-window
#      line, which it does not apply
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID
H="$T_TMP/home"; W="$T_TMP/wt"; A="$T_TMP/adapters"
mkdir -p "$H/.claude/sessions" "$W" "$A" "$SPOOL_ROOT/agents"
export AI_TRANSCRIPT_HOME="$H" AI_OWNER_HOP=0 IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=2
export IDENTITY_RESTORE_SINCE=2026-10-01T03:00:00Z IDENTITY_RESTORE_WINDOW=15 IDENTITY_RESTORE_SESSION=t
. "$T_FEAT/lib/agent-identity.inc.sh"
tm() { tmux -S "$SPOOL_TMUX_SOCKET" "$@"; }

# The fake adapter: restore-claude.sh ID RUNDIR SID [BRIEF]
cat > "$A/restore-claude.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T_TMP/started"
printf '%s keep=%s\n' "\$1" "\${RESTORE_KEEP_HOLD:-}" >> "$T_TMP/keep"
cd "\$2" || exit 1
export HOME="$H" SPOOL_AGENT_ID="\$1"
st=\$(sed 's/^.*) //' /proc/\$\$/stat | cut -d' ' -f20)
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","name":"%s restored"}' \$\$ "\$3" "\$2" "\$st" "\$1" > "$H/.claude/sessions/\$\$.json"
exec -a claude sleep 600
EOF
chmod +x "$A/restore-claude.sh"

slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
transcript() {  # SID WORKTREE-DIR-FOR-PROJECT
  mkdir -p "$H/.claude/projects/$(slug "$2")"
  printf '{"type":"agent-name","agentName":"x"}\n' > "$H/.claude/projects/$(slug "$2")/$1.jsonl"
}
record() {  # ID SID WORKTREE ALIVE UPDATED_AT [PANE]
  python3 - "$SPOOL_ROOT/agents/$1.json" "$@" <<'PY'
import json, sys
f, i, sid, wt, alive, upd = sys.argv[1:7]
pane = sys.argv[7] if len(sys.argv) > 7 else "%9"
json.dump({"v": 1, "id": i, "kind": "claude", "session_id": sid or None, "worktree": wt, "title": "lane " + i[-2:],
           "user": None, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": pane,
           "alive": alive == "true", "updated_at": upd}, open(f, "w"), indent=1, sort_keys=True)
PY
}

t_tmux
NOTES="$(t_window 'notes' 'sleep 600')"             # takes a low pane id, as after a restart
mkdir -p "$W/CLE-81" "$W/CLE-82" "$W/CLE-83" "$W/CLE-85" "$W/CLE-86" "$W/CLE-89" "$W/CLE-90"
transcript s-81 "$W/CLE-81"; transcript s-82 "$W/CLE-82"; transcript s-83 "$W/CLE-83"
transcript s-84 "$W/CLE-85"; transcript s-86 "$W/CLE-86"; transcript s-89 "$W/CLE-89"
record CLE-81 s-81 "$W/CLE-81" true  2026-10-01T02:00:00Z "$NOTES"   # alive at the last pass; its old pane id now belongs to 'notes'
record CLE-82 s-82 "$W/CLE-82" false 2026-10-01T03:05:00Z            # the first pass after the restart flipped it
record CLE-83 s-83 "$W/CLE-83" false 2026-09-30T12:00:00Z            # exited on its own, long before
record CLE-84 s-84 "$W/CLE-85" true  2026-10-01T02:00:00Z            # its transcript is CLE-85's
record CLE-86 s-86 "$W/CLE-86" true  2026-10-01T02:00:00Z            # same session as CLE-87
record CLE-87 s-86 "$W/CLE-86" true  2026-10-01T02:00:00Z
record CLE-88 s-88 "$W/gone"   true  2026-10-01T02:00:00Z            # worktree gone
record CLE-89 s-89 "$W/CLE-89" true  2026-10-01T02:00:00Z            # its session is running already
record CLE-90 s-90 "$W/CLE-90" true  2026-10-01T02:00:00Z            # no transcript
# A live CLI already holding s-89: argv "claude -c ... x --resume s-89".
RUNNER="$(t_window 'other' "bash -c 'exec -a claude bash -c \"sleep 600; :\" x --resume s-89'")"
sleep 0.5
act() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-identity-restore.func.sh"; do_spl_agent_identity_restore'
}

# --- 1 + 2 --------------------------------------------------------------------------
before="$(tm list-windows -a | wc -l)"
out="$(act)"
has "1. dry run plans CLE-81" "RESTORE CLE-81: claude session s-81 in $W/CLE-81" "$out"
has "1. dry run plans CLE-82" "RESTORE CLE-82: claude session s-82 in $W/CLE-82" "$out"
eq "1. ... and starts nothing" "$before" "$(tm list-windows -a | wc -l)"
has "2. an agent gone long before the restart is skipped" "SKIP    CLE-83: not killed by the restart" "$out"
has "2. a transcript of another agent is refused" "REFUSE  CLE-84: session s-84 belongs to CLE-85, not to CLE-84" "$out"
has "2. a session on two records is refused (1)" "REFUSE  CLE-86: session s-86 is on 2 records" "$out"
has "2. a session on two records is refused (2)" "REFUSE  CLE-87: session s-86 is on 2 records" "$out"
has "2. a gone worktree is refused" "REFUSE  CLE-88: its worktree $W/gone is gone" "$out"
has "2. a session already running is refused" "REFUSE  CLE-89: session s-89 is already running in another process" "$out"
has "2. no transcript is refused" "REFUSE  CLE-90: the transcript of s-90 is not under the project dir of $W/CLE-90" "$out"

# --- 3 + 4 + 5 ----------------------------------------------------------------------
out="$(act DRY_RUN=0)"; rc=$?
eq "3. DRY_RUN=0 exits 0" 0 "$rc"
eq "3. exactly CLE-81 and CLE-82 were started, each with its own session + worktree" \
  "CLE-81|$W/CLE-81|s-81 CLE-82|$W/CLE-82|s-82" "$(sort "$T_TMP/started" | tr '\n' ' ' | sed 's/ $//')"
eq "3. the window holding the re-issued pre-restart pane id is untouched" "notes" "$(tm display -p -t "$NOTES" '#{window_name}')"
p81="$(printf '%s\n' "$out" | sed -n 's/^STARTED CLE-81: .*\[\(%[0-9]*\)\]$/\1/p')"
check "3. CLE-81 got a NEW pane, not its pre-restart one" test -n "$p81" -a "$p81" != "$NOTES"
has "4. a fresh registry row names CLE-81's new pane" "CLE-81	claude	$p81	$W/CLE-81	" "$(cat "$SPOOL_ROOT/registry.tsv" 2>/dev/null)"
has "5. its window is named from the map" "CLE-81 restored" "$(tm display -p -t "$p81" '#{window_name}')"
for i in CLE-81 CLE-82; do
  has "5. check: $i is alive and consistent" "$i " "$(printf '%s\n' "$out" | grep -E "^$i +[0-9]+ .* alive +ok$")"
done

eq "6. the automatic pass keeps every hold (RESTORE_KEEP_HOLD=1)" "CLE-81 keep=1 CLE-82 keep=1" "$(sort "$T_TMP/keep" | tr '\n' ' ' | sed 's/ $//')"

# --- 7 a sessionless role seat starts fresh from its role handoff ------------------
recordk() {  # ID KIND WORKTREE
  python3 - "$SPOOL_ROOT/agents/$1.json" "$@" <<'PY'
import json, sys
f, i, kind, wt = sys.argv[1:5]
json.dump({"v": 1, "id": i, "kind": kind, "session_id": None, "worktree": wt, "title": "role " + i,
           "user": None, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": "%9",
           "alive": True, "updated_at": "2026-10-01T02:00:00Z"}, open(f, "w"), indent=1, sort_keys=True)
PY
}
ME="$(id -un)"
mkdir -p "$W/g-002" "$W/c-003" "$W/g-001" "$W/c-591"
for i in g-002 c-003 c-591; do mkdir -p "$SPOOL_ROOT/$i"; echo "# handoff $i" > "$SPOOL_ROOT/$i/handoff.md"; done
recordk g-002 grok   "$W/g-002"   # role seat, its handoff on disk
recordk c-003 claude "$W/c-003"   # role seat, its handoff on disk
recordk g-001 grok   "$W/g-001"   # role seat, NO handoff
recordk c-591 claude "$W/c-591"   # a lane, not a role seat
rp() { ai_panes | python3 "${1:-$T_SCRIPTS/agent-identity.py}" --dir "$SPOOL_ROOT/agents" restore-plan --ids "g-002 c-003 g-001 c-591" --agent-user "$ME"; }
plan="$(rp)"
has "7. a sessionless grok role seat plans a fresh restore ('-')" "RESTORE	g-002	grok	$ME	-	$W/g-002	" "$plan"
has "7. a sessionless claude role seat plans a fresh restore ('-')" "RESTORE	c-003	claude	$ME	-	$W/c-003	" "$plan"
has "7. control: a role seat with no role handoff is refused" "REFUSE	g-001	its session is unknown and it has no role handoff $SPOOL_ROOT/g-001/handoff.md" "$plan"
has "7. control: a sessionless lane is still refused" "REFUSE	c-591	its session is unknown; not guessing one" "$plan"

git init -q "$T_TMP/main" && git -C "$T_TMP/main" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
mkdir -p "$SPOOL_ROOT/g-002/lifetime"; echo "# Brief: dispatch" > "$SPOOL_ROOT/g-002/lifetime/brief.md"
out="$(env RESTORE_PRINT=1 GROK_BIN=grok bash "$T_SCRIPTS/restore-grok.sh" g-002 "$T_TMP/main" - 2>&1)"
hasnt "7. restore-grok.sh '-': a NEW session, no --resume" "--resume" "$out"
has "7. ... kicked to its restore note" "\"Read and follow your restore note: $SPOOL_ROOT/g-002/lifetime/kick.txt\"" "$out"
has "7. ... which names the role handoff and the brief" "First read your role handoff at $SPOOL_ROOT/g-002/handoff.md, then your brief at $SPOOL_ROOT/g-002/lifetime/brief.md" "$out"
out="$(env RESTORE_PRINT=1 CLAUDE_BIN=claude bash "$T_SCRIPTS/restore-claude.sh" c-003 "$T_TMP/main" - 2>&1)"
hasnt "7. restore-claude.sh '-': a NEW session, no --resume" "--resume" "$out"
has "7. ... kicked to the role handoff" "FRESH START: the box restarted and no session of the role seat c-003 was recorded" "$out"
has "7. control: a session id still resumes it" "--resume s-3" "$(env RESTORE_PRINT=1 GROK_BIN=grok bash "$T_SCRIPTS/restore-grok.sh" g-002 "$T_TMP/main" s-3 2>&1)"
has "7. control: an empty session id is still refused" "a session id is required" "$(env RESTORE_PRINT=1 GROK_BIN=grok bash "$T_SCRIPTS/restore-grok.sh" g-002 "$T_TMP/main" "" 2>&1)"

OLD="$T_TMP/agent-identity.old.py"
PRE=f35ebaaaf  # master just before SPL-2638 (a shallow clone lacks it: skipped, named)
if git -C "$T_REPO" show "$PRE:csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-identity.py" > "$OLD" 2>/dev/null; then
  has "7. red control: the code before the fix refuses the sessionless g- role seat" "REFUSE	g-002	its session is unknown; not guessing one" "$(rp "$OLD")"
else
  echo "SKIP 7 red control: $PRE is not in this clone (shallow?)"
fi

# --- 8 a restore by id names every id it did not start (SPL-3378) ---------------
out="$(act IDENTITY_RESTORE_IDS="c-001 CLE-81")"
has "8. an id with no record on this box is named, with the reason" "SKIP    c-001: no record on this box ($SPOOL_ROOT/agents/c-001.json)" "$out"
check "8. a running id is named with its pid" grep -qE '^SKIP    CLE-81: already running \(pid [0-9]+\)$' <<<"$out"
hasnt "8. no since-window line: a restore by id does not apply it" "restore: agents the restart at" "$out"
has "8. ... it says it is a restore by id instead" "restore: by id (c-001 CLE-81), from $SPOOL_ROOT/agents" "$out"

t_done
