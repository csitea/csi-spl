---
name: kill-your-self
description: >
  Alias of /exit-clean: land the work, report, schedule the deferred window
  close, then /exit with status 0. Use when the user runs /kill-your-self or
  asks this agent to shut down gracefully.
---

# /kill-your-self — finish this agent cleanly

Order is hard: **commit and push the finished work → report → schedule the
window close → end the turn (the caller then sends `/exit`, status 0)**. Never force-kill the agent CLI, never
close the window before `/exit`.

This is an alias of `/exit-clean`; the two follow the same steps.

## 0. When

A lane runs this only after the reviewer's verdict: a spool message on its
task whose body starts with `ACCEPTED`, from the dispatch holder or its
spawner, or a human typing `/exit-clean`. Its own "done" is not that: send the
result, then stay idle and answer send-backs. A lane that retired before the
verdict made the ACCEPTED bounce ("retired on this machine less than 24 h
ago", c-878 and a-884, 2026-10-10). Every kind, mistral (vibe,
`~/.vibe/skills`) included.

## 1. Land the work

Start with the read-only discovery: your id, unread spool mail, what git
holds unpushed, and the spec tasks.md files to tick. It changes nothing.

```bash
bash {{HARNESS_DIR}}/scripts/kill-your-self-report.sh
```

Everything finished is committed with explicit pathspecs and on the trunk
(fetch, rebase, push, then confirm with `git merge-base --is-ancestor HEAD
origin/<trunk>`). Tick the spec's `tasks.md` in the same commit as the work.
Work that is not finished is named in the report, never silently dropped.

Then mark your lane done in the fleet-wide lane map, so no other machine's
scope check still reads you as owning your files:

```bash
bash {{HARNESS_DIR}}/scripts/lane-map.sh done --agent <YOUR-AGENT-ID>
```

A role seat (c-001..c-003, the ids in the dispatch lease) runs it too: it
prints one INFO line and changes nothing, because the rotation successor keeps
the same id and so the lane.

## 2. Report

Send the summary to your named reporter (the one your brief or seed says to
report to; `{{ORCHESTRATOR_ID}}` only when none is named): what landed (shas),
what is open, and anything another lane must act on. Write it with
`kill-your-self-report.sh --result` as in `/exit-clean` section 2.

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-send.sh --from <YOUR-ID> "$(bash {{HARNESS_DIR}}/scripts/kill-your-self-report.sh --reporter)" --kind result --file <summary-file>
```

`--reporter` prints your named reporter: a `Spawner:` / `Reporter:` /
`Report to:` line in your brief, else the spawner your seed names, else your
registry row's requester, else `{{ORCHESTRATOR_ID}}` (stderr says which).
`REPORT_TO=<id>` overrides it when your brief names a reporter in prose. The
`--file` is the summary `--result` printed, never the detail file.

## 3. Schedule the window close, then exit

Pass YOUR OWN id; the helper refuses any window that does not carry it.
`--retire` then retires the id once the window is gone (specs/061 3.6): your
spool dir, registry row and identity record move aside, so the number can be
handed out again after a 24 h quarantine. A role id (001-003) is never retired.

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <YOUR-AGENT-ID> --defer --retire
```

Then end your turn: your last message is the one-line report, nothing after it.

`/exit` is a built-in CLI command, not a tool: you cannot run it, and asking
the human to type it is wrong. Whoever invoked this skill ends the session
once your turn is over: the hourly rotation's RETIRE step types `/exit` into
this pane when it reads idle (and closes the window itself, so a retiring
session whose successor carries the same id skips the close above), and the
deferred close kills the window after its timeout. On agy the closer types
`/exit` itself once agy sits idle at an empty `>` prompt, so agy leaves with
status 0 and the window closes then; it runs detached, so agy ending your
command does not stop it.

## 4. Arguments

| arg | behaviour |
|---|---|
| (none) | sections 1-3, then `/exit` |
| `report-only` | sections 1-2; do not exit, do not close |
| `no-close` | `/exit` without scheduling the window close |
