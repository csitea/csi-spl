#!/usr/bin/env bash
# test-kill-your-self-report.sh — the read-only discovery (specs/048, SPL-1160).
#   the id from the env, else the worktree path; unread spool mail counted; git
#   dirty + unpushed counts; tasks.md candidates with open/done counts; and it
#   changes nothing it looks at.
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
eq "it changed nothing" "$before" "$(cd "$T_TMP" && find . -type f -newer "$R" | sort | md5sum)"
t_done
