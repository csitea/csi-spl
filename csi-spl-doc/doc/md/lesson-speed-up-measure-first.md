# Lesson: how to speed up the system — measure first

Owner ask (topic `ed59d520`, msg [46ba8b00](https://spool-hub.ai/m/46ba8b00-0f38-4ed6-a96d-dd4a906cce89)):
"take the gist of this discussion as a lesson learnt on how to successfully
speed up the system". Rules first, the case that taught them after.

## 1. Checklist

1. **Measure the real waiting before choosing a fix.** Time what the slow
   session actually waits on, per command, and rank it. A plausible fix that
   the measurement does not point at is dropped, however obvious it sounded.
2. **Find the cause with a trace and a count, not a guess.** Trace one slow
   call and count what it does (process starts, queries, files). A high share
   of *system* time is the hint that starting processes, not the logic, is the
   cost.
3. **Fix the shape, not the speed of each step.** One pass over all records
   instead of one process per record; only the records that changed do extra
   work.
4. **Same behaviour, same output.** Same order, same calls, same result. A
   damaged input falls back to the slow path for that input only.
5. **Guard it with a test that counts the cost**, plus a CONTROL showing the
   old shape fails that test, so the regression cannot come back quietly.
6. **Prove before / after on real data, with n stated, on every machine.**
7. **Report in plain words: cause, change, proof.**

## 2. Worked example: the ask book, ~60 s -> ~1.3 s per call

### 2.1 The symptom

The orchestrator was restarted twice in 7 minutes by its watchdog: a message
sat unread for over 4 minutes while it waited on ONE shell command
([018a93f6](https://spool-hub.ai/m/018a93f6-4983-4139-b516-60288c842b1e)).
That command closed 5 asks in a loop: 10 ask-book calls at ~60 s each,
19 s user and 40 s sys per call, n=2 plus 6 more that day
([55380ad0](https://spool-hub.ai/m/55380ad0-9a2f-4c28-b607-da7fe7957b7c)).

### 2.2 Rule 1 — two fixes dropped once measured

| proposed fix | measurement | verdict |
|---|---|---|
| spawns return at once | ~20 spawns took 0.2-2.7 s each | dropped ([eb3ab9cf](https://spool-hub.ai/m/eb3ab9cf-b37e-44ee-95d8-c8ec48d83862)) |
| cross-box sends in the background | median 1.0 s over n=158 sends; the two slow ones had an ask-book loop inside | dropped ([19a66fe9](https://spool-hub.ai/m/19a66fe9-3fa5-46b1-a416-dfda1c86f517)) |
| ask-book call under 3 s | **59 %** of the orchestrator's command waiting that day was the ask book (lane c-512) | the one lever |

### 2.3 Rule 2 — the trace and the count

An xtrace of one `do_spl_asks_open` on the live book (841 hub rows, 840
journal files) counted the process starts (commit `65066935`):

| step | process starts per call |
|---|---|
| journal read: one `jq` per file, list read twice | 1,680 |
| hub mirror: ~5 `jq`/`cat` per hub row, even when nothing changed | 4,201 |
| **total** | **~5,900** |

About 10 ms per start on a busy machine x 5,900 = about a minute, and 2/3 of
it system time ([bbad99a2](https://spool-hub.ai/m/bbad99a2-d5db-4ab6-b74c-1de824a69d97)).

### 2.4 Rules 3 and 4 — the change

`65066935`, two code files plus the test:

- the journal is read with **one** `jq` over every file; the per-file loop
  runs only when a file does not parse, so a damaged file skips only itself;
- the mirror picks the changed hub rows with **one** `jq` against the journal;
  only a changed row (usually 0-2) does the per-row work;
- same journal-first order, same hub calls, same output: 11-15 process starts
  per call.

### 2.5 Rule 5 — the test that counts

`csi-spl-orc/src/bash/tests/asks.tst.sh` section 15 puts a counting `jq` on
`PATH` and builds a 300-ask book: open, ack, close and the orchestrator's
inbox each must run at most **40** `jq` (11-15 measured). CONTROL: the
per-file fallback runs 302 on the same book; the old code reaches ~1,810
(bbad99a2). A second check proves one changed hub row mirrors exactly that row.

### 2.6 Rule 6 — before / after on real data

| call (first machine, n=3 each) | before | after |
|---|---|---|
| list open asks | 71-105 s | 1.0-1.4 s |
| acknowledge | 77-102 s | 1.1-1.5 s |
| close | 72-102 s | 1.2-1.7 s |
| orchestrator inbox read | 67-113 s | 1.0-1.3 s |

Second machine: 7.5 s on the first call (catching up on changes), then 1.9 s
([f4c97f1f](https://spool-hub.ai/m/f4c97f1f-13ea-4321-af9e-7a81867e8d36)).

### 2.7 Rule 7 — the plain-words report

Cause: every call started ~5,900 tiny programs. Change: read the whole book in
one pass; only changed entries cost extra. Proof: the table above and a test
that fails if the per-entry pattern returns
([f4c97f1f](https://spool-hub.ai/m/f4c97f1f-13ea-4321-af9e-7a81867e8d36),
[bbad99a2](https://spool-hub.ai/m/bbad99a2-d5db-4ab6-b74c-1de824a69d97)).
