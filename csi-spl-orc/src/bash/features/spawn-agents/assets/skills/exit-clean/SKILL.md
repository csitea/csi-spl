---
name: exit-clean
description: >
  Cleanly finish THIS agent: land the finished work, send the handoff report,
  schedule the deferred tmux window close, then /exit with status 0. Use when
  the user runs /exit-clean, says "exit clean", "I'm done" or "close this window".
---

# /exit-clean — finish this agent cleanly

Order is hard: **commit and push the finished work → report → schedule the
window close → end the turn (the caller then sends `/exit`, status 0)**. Never force-kill the agent CLI, never
close the window before `/exit`.

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

Send the summary to your orchestrator (`{{ORCHESTRATOR_ID}}` unless your brief names
another): what landed (shas), what is open, and
anything another lane must act on. The result is <= 800 chars + a path: the
sha(s), the one-line outcome and the numbers, with the full detail in a file.

```bash
bash {{HARNESS_DIR}}/scripts/kill-your-self-report.sh --result --outcome "<one line>" --sha <sha> --numbers "<n, before -> after>" --detail <detail-file> > <summary-file>
```

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-send.sh --from <YOUR-ID> {{ORCHESTRATOR_ID}} --kind result --file <summary-file>
```

## 3. Schedule the window close, then exit

Pass YOUR OWN id; the helper refuses any window that does not carry it.
Run it with NO outer `sudo`: `--defer` also needs your own pane
(`$CLE_TMUX_PANE` ...), which sudo strips, and without it the helper refuses
and closes nothing (an id alone may name your rotation successor's window).
`--retire` then retires the id once the window is gone (specs/061 3.6): your
spool dir, registry row and identity record move aside, so the number can be
handed out again after a 24 h quarantine. A role id (001-003) is never retired.

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <YOUR-AGENT-ID> --defer --retire
```

It writes `lifetime/done` in your spool dir first, while you still run, so
the watchdog reads your exit as finished, never as a crash to restart.

With `--rebirth` (the 1 h rebirth, specs/102): land what is green, write your
notes, then mark the rebirth instead of closing. The window stays open, the id
is not retired, and the watchdog restarts you with your handoff.

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <YOUR-AGENT-ID> --rebirth
```

Then end your turn: your last message is the one-line report, nothing after it.

`/exit` is a built-in CLI command, not a tool: you cannot run it, and asking
the human to type it is wrong. Whoever invoked `/exit-clean` ends the session
once your turn is over: the hourly rotation's RETIRE step sends
`/exit-clean no-close` and types `/exit` into this pane when it reads idle
(it closes the window itself: a retiring session whose successor carries the
same id never schedules the close above), and the
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
| `--rebirth` | sections 1-2, then the `--rebirth` marker (section 3), then `/exit`; no close, no retire |
