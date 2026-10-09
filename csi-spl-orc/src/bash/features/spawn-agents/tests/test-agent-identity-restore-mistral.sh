#!/usr/bin/env bash
# test-agent-identity-restore-mistral.sh — a fresh m- lane has no session id
# yet; a reboot restore still brings it back: the plan hands restore-mistral.sh
# '-' (it continues the worktree's latest vibe session). Every other vendor
# keeps the rule: no session, no restore.
#
#   1. an m- record with no session plans RESTORE with session '-'
#   2. control: the same record as c- (claude) is still refused
#   3. an m- record WITH a session still plans that session, unchanged
#   4. an m- record with no session and a gone worktree is refused
#   5. DRY_RUN=0 starts restore-mistral.sh ID WORKTREE - for the fresh lane and
#      restore-mistral.sh ID WORKTREE SID for the one with a session
#   6..10 (restart fix 4): the real restore-mistral.sh hands a restored seat its
#      task back - the kick re-points at its brief, found as arg 4 (the
#      action's <id>/brief.md), lifetime/session.json .brief, lifetime/brief.md
#      or handoff.md section 2; no brief on disk = no prompt, a NO-BRIEF report
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID
H="$T_TMP/home"; W="$T_TMP/wt"; A="$T_TMP/adapters"
mkdir -p "$H/.claude/sessions" "$W" "$A" "$SPOOL_ROOT/agents" "$SPOOL_ROOT/dispatch"
export AI_TRANSCRIPT_HOME="$H" AI_OWNER_HOP=0 IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=0
export IDENTITY_RESTORE_SINCE=2026-10-01T03:00:00Z IDENTITY_RESTORE_WINDOW=15 IDENTITY_RESTORE_SESSION=t
. "$T_FEAT/lib/agent-identity.inc.sh"

# The fake adapter: restore-mistral.sh ID RUNDIR SID [BRIEF] records its arguments.
cat > "$A/restore-mistral.sh" <<EOS
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T_TMP/started"
EOS
chmod +x "$A/restore-mistral.sh"

record() {  # ID KIND SID WORKTREE
  python3 - "$SPOOL_ROOT/agents/$1.json" "$@" <<'PY'
import json, sys
f, i, kind, sid, wt = sys.argv[1:6]
json.dump({"v": 1, "id": i, "kind": kind, "session_id": sid or None, "worktree": wt, "title": "lane " + i[-2:],
           "user": None, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": "%9",
           "alive": True, "updated_at": "2026-10-01T02:00:00Z"}, open(f, "w"), indent=1, sort_keys=True)
PY
}

t_tmux
mkdir -p "$W/m-901" "$W/c-902" "$W/m-903"
record m-901 mistral ""    "$W/m-901"     # fresh m- lane: no session id yet
record c-902 claude  ""    "$W/c-902"     # control: the same, as claude
record m-903 mistral s-903 "$W/m-903"     # m- lane with a session
record m-904 mistral ""    "$W/gone"      # fresh m- lane, worktree gone

plan="$(ai_panes | ai_py restore-plan --since "$IDENTITY_RESTORE_SINCE" --agent-user "$(id -un)")"
has "1. m- with no session plans RESTORE with session '-'" "RESTORE	m-901	mistral	$(id -un)	-	$W/m-901	" "$plan"
has "2. control: c- with no session is still refused" "REFUSE	c-902	its session is unknown; not guessing one" "$plan"
has "3. m- with a session plans that session" "RESTORE	m-903	mistral	$(id -un)	s-903	$W/m-903	" "$plan"
has "4. m- with no session and a gone worktree is refused" "REFUSE	m-904	its worktree $W/gone is gone" "$plan"

act() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-identity-restore.func.sh"; do_spl_agent_identity_restore'
}
act DRY_RUN=0 >/dev/null
sleep 1
eq "5. restore-mistral.sh got '-' for the fresh lane and the session for the other" \
  "m-901|$W/m-901|- m-903|$W/m-903|s-903" "$(sort "$T_TMP/started" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# --- 6..10: the real adapter, rendered (RESTORE_PRINT=1) --------------------------
git init -q "$T_TMP/main" && git -C "$T_TMP/main" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/main" branch -M master
git -C "$T_TMP/main" worktree add -q -b m-910-x "$T_TMP/wt910" master
rr() {  # ID [SID] [ARG4] -> the rendered command (+ stderr)
  env RESTORE_PRINT=1 MISTRAL_BIN=vibe SPOOL_MISTRAL_MAX_PRICE=3.50 bash "$T_SCRIPTS/restore-mistral.sh" "$1" "$T_TMP/wt910" "${2:--}" ${3:+"$3"} 2>&1
}
B="$T_TMP/brief-910.md"; echo "# Brief: task 910" > "$B"
out="$(rr m-910 - "$B")"
has "6. a brief file as arg 4 (the action's <id>/brief.md) becomes the restore kick" "--continue \"Read and follow your restore note: $SPOOL_ROOT/m-910/lifetime/kick.txt\"" "$out"
has "6. ... whose text is the restore kick" "SESSION RESTORED" "$out"
has "6. ... re-pointing the seat at its brief" "Re-read your task brief at $B to reload the full scope" "$out"
hasnt "6. ... not the bare path as the prompt" "--continue \"$B\"" "$out"
has "6. ... and with a session it resumes that session with the kick" "--resume s-910 \"Read and follow your restore note: $SPOOL_ROOT/m-910/lifetime/kick.txt\"" "$(rr m-910 s-910 "$B")"

L="$SPOOL_ROOT/m-910/lifetime"; mkdir -p "$L"
B2="$T_TMP/brief-910-sj.md"; echo "# Brief: from session.json" > "$B2"
printf '{"v": 1, "id": "m-910", "brief": "%s"}\n' "$B2" > "$L/session.json"
has "7. no arg 4: lifetime/session.json .brief" "Re-read your task brief at $B2 " "$(rr m-910)"
rm -f "$L/session.json"; echo "# Brief: lifetime" > "$L/brief.md"
has "8. else lifetime/brief.md" "Re-read your task brief at $L/brief.md " "$(rr m-910)"
rm -f "$L/brief.md"
printf '# handoff m-910\n\n## 2. brief\n\nbrief: %s\n\n# Brief: task 910\n\n## 3. done\n\n(none)\n' "$B" > "$SPOOL_ROOT/m-910/handoff.md"
has "9. else the spec 102 handoff's brief path" "Re-read your task brief at $B " "$(rr m-910)"
printf '# handoff m-910\n\n## 2. brief\n\nbrief: %s\n\n## 3. done\n' "$T_TMP/gone.md" > "$SPOOL_ROOT/m-910/handoff.md"
has "9. ... a gone brief path: the handoff itself" "Re-read your task brief at $SPOOL_ROOT/m-910/handoff.md " "$(rr m-910)"

printf '# handoff m-910\n\n## 2. brief\n\n(none)\n\n## 3. done\n' > "$SPOOL_ROOT/m-910/handoff.md"
out="$(rr m-910)"
hasnt "10. no brief on disk: no prompt is invented" "SESSION RESTORED" "$out"
has "10. ... the seat still resumes" "--max-price 3.50 --continue" "$out"
has "10. ... and it is reported" "NO-BRIEF m-910: restored with no prompt" "$out"
printf '#!/usr/bin/env bash\nprintf "%%s " "$@" > "%s"\n' "$T_TMP/sent" > "$T_TMP/send.sh"
env RESTORE_REPORT_SEND="bash $T_TMP/send.sh" RESTORE_PRINT=1 MISTRAL_BIN=vibe SPOOL_MISTRAL_MAX_PRICE=3.50 \
  bash "$T_SCRIPTS/restore-mistral.sh" m-910 "$T_TMP/wt910" - >/dev/null 2>&1
has "10. ... to the orchestrator, as a blocker" "--from m-910 --to orchestrator --kind blocker --task restore-m-910" "$(cat "$T_TMP/sent" 2>/dev/null)"
has "10. control: a literal (non-file) arg 4 is still the kick" "--continue \"Read and follow your restore note: $SPOOL_ROOT/m-910/lifetime/kick.txt\"
KICK-BEGIN $SPOOL_ROOT/m-910/lifetime/kick.txt
go on" "$(rr m-910 - 'go on')"

t_done
