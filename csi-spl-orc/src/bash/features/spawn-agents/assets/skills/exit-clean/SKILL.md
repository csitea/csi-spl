---
name: exit-clean
description: >
  Cleanly finish THIS agent: land the finished work, send the handoff report,
  schedule the deferred tmux window close, then /exit with status 0. Use when
  the user runs /exit-clean, says "exit clean", "I'm done" or "close this window".
---

# /exit-clean — finish this agent cleanly

Order is hard: **commit and push the finished work → report → schedule the
window close → `/exit` (status 0)**. Never force-kill the agent CLI, never
close the window before `/exit`.

## 1. Land the work

Everything finished is committed with explicit pathspecs and on the trunk
(fetch, rebase, push, then confirm with `git merge-base --is-ancestor HEAD
origin/<trunk>`). Tick the spec's `tasks.md` in the same commit as the work.
Work that is not finished is named in the report, never silently dropped.

## 2. Report

Send the summary to your orchestrator: what landed (shas), what is open, and
anything another lane must act on.

```bash
bash {{HARNESS_DIR}}/scripts/spool-send.sh --from <YOUR-ID> --to <ORCHESTRATOR-ID> --kind result --body-file <summary-file>
```

## 3. Schedule the window close, then exit

Pass YOUR OWN id; the helper refuses any window that does not carry it.

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <YOUR-AGENT-ID> --defer
```

Then run `/exit`.

## 4. Arguments

| arg | behaviour |
|---|---|
| (none) | sections 1-3, then `/exit` |
| `report-only` | sections 1-2; do not exit, do not close |
| `no-close` | `/exit` without scheduling the window close |
