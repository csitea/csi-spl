#!/usr/bin/env bash
# test-kill-your-self-report.sh — the read-only discovery (specs/048, SPL-1160).
#   the id from the env, else the worktree path; unread spool mail counted; git
#   dirty + unpushed counts; tasks.md candidates with open/done counts; and it
#   changes nothing it looks at. --reporter: the lane's named reporter (brief
#   line > seed spawner > registry requester > orchestrator), and both exit
#   skills send their report there (c-894 finding 2, 2026-10-10), on the
#   ACCEPTED's task (c-895 msg 8dcc064b point 2).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_AGENT_ID MCP_BOT_AGENT_ID
R="$T_SCRIPTS/kill-your-self-report.sh"
W="$T_TMP/repo-wt/QWN-07"
git init -q --bare "$T_TMP/o.git"
git init -q "$W" && git -C "$W" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$W" remote add origin "$T_TMP/o.git" && git -C "$W" push -q origin HEAD:master && git -C "$W" fetch -q origin
git -C "$W" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m mine
mkdir -p "$W/doc/specs/042-thing" && printf -- '- [x] T1\n- [ ] T2\n- [ ] T3\n' >"$W/doc/specs/042-thing/tasks.md"
mkdir -p "$SPOOL_ROOT/QWN-07/inbox" && echo '{}' >"$SPOOL_ROOT/QWN-07/inbox/a.json"
before="$(cd "$T_TMP" && find . -type f -newer "$R" | sort | md5sum)"

out="$(bash "$R" "$W" 2>&1)"; rc=$?
eq "exits 0" 0 "$rc"
has "the id from the worktree path, with its kind" "agent id: QWN-07 (from path)   kind: qwen" "$out"
has "unread spool mail is counted" "spool:    1 unread in $SPOOL_ROOT/QWN-07/inbox" "$out"
has "an untracked spec dir counts as dirty" "dirty:    1 path(s)" "$out"
has "the commit not on the trunk is counted" "not on origin/master: 1 commit(s)" "$out"
has "the tasks.md candidate is listed" "slug=042-thing  open=2  done=1" "$out"
has "the env id wins over the path" "agent id: CLE-09 (from env)   kind: claude" "$(SPOOL_AGENT_ID=CLE-09 bash "$R" "$W" 2>&1)"
has "an m- id is a mistral agent (spec 110)" "agent id: m-009 (from env)   kind: mistral" "$(SPOOL_AGENT_ID=m-009 bash "$R" "$W" 2>&1)"
eq "it changed nothing" "$before" "$(cd "$T_TMP" && find . -type f -newer "$R" | sort | md5sum)"

# --reporter, first match wins; each case removes the source above it.
# --no-gate: the exit gate in front of it has its own suite (-gate.sh).
L="$SPOOL_ROOT/m-097/lifetime" && mkdir -p "$L"
printf '# Brief\n\nSpawner: c-094 (the exit-clean lane).\n' >"$L/brief.md"
printf 'seed ... Report status, blockers and your final summary to your spawner: spool-send.sh --to c-001@box1 (kind result ...' >"$L/prompt.txt"
printf 'm-097\tmistral\t%%9\t/x\t20261010T000000Z\tc-005\n' >>"$SPOOL_ROOT/registry.tsv"
rep() { SPOOL_AGENT_ID=m-097 SPOOL_BOX_TAG=box2 bash "$R" --reporter --no-gate "$W" 2>&1; }
eq "the brief's Spawner: line wins (m-897 named c-894 there)" "reporter: c-094 (from brief)"$'\n'"c-094" "$(rep)"
eq "REPORT_TO overrides the brief" "c-077" "$(REPORT_TO=c-077 SPOOL_AGENT_ID=m-097 bash "$R" --reporter --no-gate "$W" 2>/dev/null)"
printf -- '- **Report to:** `c-095@box3`, cc c-001\n' >"$L/brief.md"
eq "a markdown Report to: line, with its box" "c-095@box3" "$(rep | tail -n 1)"
printf 'Report to the dispatch holder on dispatch-x.\n' >"$L/brief.md"
eq "prose naming no id falls to the seed's spawner" "reporter: c-001@box1 (from seed)"$'\n'"c-001@box1" "$(rep)"
# A report line naming the dispatch lease holder resolves to the live holder
# (SPL-3418: c-236's final went to the spawner); a failed lease read falls
# through to the seed. KSR_LEASE_CMD stubs the lease read: no live lease.
printf 'h() { printf "c-002@box9 44\\n"; }; h\n' >"$T_TMP/lease-ok" && printf 'exit 1\n' >"$T_TMP/lease-bad"
printf '## Report\nreporter: the dispatch lease holder. Kind result to the CURRENT dispatch lease holder (`LEASE_CMD=show`) on task dispatch-orc.\n' >"$L/brief.md"
eq "reporter: the dispatch lease holder -> the live holder" "reporter: c-002@box9 (from brief-lease)"$'\n'"c-002@box9" "$(KSR_LEASE_CMD="bash $T_TMP/lease-ok" rep)"
for line in 'Kind result to the CURRENT dispatch lease holder (`x`).' 'To the dispatch lease holder on task dispatch-y, kind result.' '- Report on `--task dispatch-d8ca583e`, kind result, to the CURRENT dispatch lease holder (`x`).' 'Send a result to the dispatch lease holder.'; do
  printf '%s\n' "$line" >"$L/brief.md"
  eq "holder line: ${line:0:40}" "c-002@box9" "$(KSR_LEASE_CMD="bash $T_TMP/lease-ok" rep | tail -n 1)"
done
out="$(KSR_LEASE_CMD="bash $T_TMP/lease-bad" rep)"
has "a failed lease read says so" "the lease read failed; trying the next source" "$out"
eq "a failed lease read falls to the seed's spawner" "c-001@box1" "$(tail -n 1 <<<"$out")"
printf 'Step 0: the dispatch lease holder reads it first.\n' >"$L/brief.md"
eq "a line that only mentions the holder is no report line" "c-001@box1" "$(KSR_LEASE_CMD="bash $T_TMP/lease-ok" rep | tail -n 1)"
printf 'Report to the dispatch holder on dispatch-x.\n' >"$L/brief.md"
rm -f "$L/prompt.txt"
eq "no seed line: the registry requester, decorated" "reporter: c-005@box2 (from registry)"$'\n'"c-005@box2" "$(rep)"
eq "nothing named: the orchestrator" "reporter: orchestrator (from fallback)"$'\n'"orchestrator" "$(SPOOL_AGENT_ID=m-098 bash "$R" --reporter --no-gate "$W" 2>&1)"

# Every vendor renders these two templates; the send must use --reporter, and
# go on the ACCEPTED's task (c-895 msg 8dcc064b point 2): agent-send.sh has no
# --task, so the send is spool-send.sh.
for s in exit-clean kill-your-self; do
  f="$T_FEAT/assets/skills/$s/SKILL.md"
  send="$(grep -F -- '--kind result' "$f" | grep -F -- '--reporter)')"
  has "$s: the report goes to the named reporter" 'spool-send.sh --from <YOUR-ID> --to "$(bash {{HARNESS_DIR}}/scripts/kill-your-self-report.sh --reporter)" --kind result' "$send"
  has "$s: the report goes on the ACCEPTED's task" ' --task <ACCEPTED-TASK-ID> ' "$send"
  hasnt "$s: no report send without --task (agent-send.sh takes none)" 'agent-send.sh' "$send"
  hasnt "$s: no send straight to {{ORCHESTRATOR_ID}}" 'agent-send.sh --from <YOUR-ID> {{ORCHESTRATOR_ID}}' "$(cat "$f")"
done
t_done
