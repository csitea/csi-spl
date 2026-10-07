# Fleet hot commands, 2026-10-07

Where the fleet's agents spent their time **waiting on Bash calls** over 24
hours, measured from their own transcripts, and what to do about the top 10.
The method is the one in
[lesson-speed-up-measure-first.md](lesson-speed-up-measure-first.md): measure
the real wait first, trace ONE call to count what it costs, and only then pick
a fix. This page measures and recommends. It changes no code; each fix
becomes its own lane.

## 1. How it was measured

```bash
cd csi-spl-orc && SINCE=2026-10-06T20:00:00Z UNTIL=2026-10-07T20:00:00Z CMD_TIME_TOP=40 ./run -a do_spl_cmd_time_report
```

- `do_spl_cmd_time_report` (sha 4a9b62f6) reads every Claude Code transcript
  of the agent user and the box user. For each Bash call it takes the result's
  timestamp minus the call's timestamp, which is the time the agent waited.
- It names the command by its **action**: the `./run -a do_X` name, a script's
  basename, or the program plus the verb (`git fetch`, `gh run watch`). A
  `while` / `until` / sleeping `for` loop is `poll-loop <action>`. It never
  prints arguments or output.
- Calls started with `run_in_background` are skipped because nobody waited
  on them. A call cut by the Bash tool's 600 s cap counts as 600 s, so
  **max 600 s means the cap was hit**.
- Run on both boxes for the same window. Box A (the desk box): 8415 calls,
  174,715 s. Box B: about 247,000 s (from its row 1, 58,847 s = 23.8 %).
  That is about **117 agent-hours of Bash wait a day**. Lanes run in
  parallel, so this is agent time spent waiting, not wall-clock time.
- Caveats:
  - The roles come from today's lease. A seat whose cwd is not under
    `csi-spl-wt/` reads as `other`; that is where box B's orchestrator lands.
  - A cheap command such as `cat` or `sed` with a max near 600 s does not
    mean the command is slow. It means the box stalled under load, or the
    command blocked on a pipe.

## 2. The table, both boxes

Rows ranked by total wait across both boxes (s = seconds). The full per-box
tables are what the action prints.

| # | action | box A calls / total s | box B calls / total s | both total s | median s (A / B) | p90 s (A / B) |
|---|---|---|---|---|---|---|
| 1 | `poll-loop grep` | 113 / 31,785 | 169 / 58,847 | 90,632 | 175 / 336 | 600 / 601 |
| 2 | `do_check_pre_push` | 147 / 16,163 | 138 / 20,634 | 36,797 | 25 / 60 | 398 / 470 |
| 3 | `poll-loop cat` | 22 / 6,785 | 36 / 15,057 | 21,842 | 263 / 566 | 600 / 601 |
| 4 | `gh run watch` | 32 / 10,433 | 22 / 6,205 | 16,638 | 285 / 227 | 600 / 601 |
| 5 | `python3` (inline) | 377 / 4,582 | 452 / 11,257 | 15,839 | 0.4 / 0.8 | 29 / 94 |
| 6 | `git fetch` | 448 / 7,415 | 398 / 7,572 | 14,987 | 1.6 / 3.6 | 21 / 24 |
| 7 | `pnpm run` | 37 / 6,036 | 40 / 8,325 | 14,361 | 140 / 155 | 307 / 381 |
| 8 | `poll-loop tail` | under 754 | 27 / 12,022 | about 12,500 | n/a / 581 | n/a / 582 |
| 9 | `run-all-tests.sh` | 16 / 7,367 | 2 / 1,148 | 8,515 | 600 / 574 | 601 / 601 |
| 10 | `cat` | 871 / 2,057 | 1,114 / 6,298 | 8,355 | 0.2 / 0.4 | 1.3 / 3.0 |

Rows 11 to 13 by total wait: `poll-loop gh run view` (7,428 s),
`do_check_dist_hygiene` (6,474 s, 153 calls, median 5.5 / 7.1 s) and `sed`
(6,245 s).

The orchestrator's ask-book calls (`do_spl_ask_close`, `do_spl_ask_ack`,
`do_spl_asks_open`, `do_spl_orch_inbox`) together cost about 17,000 s across
both boxes, at medians of 57 to 120 s. That was **already fixed** inside this
window, by c-509 in 65066935. Re-measured after the fix:

- `do_spl_asks_open`: 2.0 s, 211 processes.
- `do_spl_orch_inbox`: 2.0 s, 229 processes.
- `do_spl_ask_ack` on box A since 19:25Z: median 6.5 s, n=5 (before: 64 s).

## 3. The top 10: cause and fix class

Fix classes:

- **(a)** shape fix in bash (one pass, incremental).
- **(b)** move the hot path into the Go `spool` CLI.
- **(c)** cache, or skip when nothing changed.
- **(d)** not worth it, or not a command problem.

Each trace was run once on box A (load 8 to 12 on 16 cores), with n=1. To
count the processes a call starts, the call ran in its own pid namespace
(`unshare --pid`, then read `ns_last_pid`), because the box has no strace.

### 3.1 `poll-loop grep`: 90,632 s

- **Measured:** 282 calls, median 175 / 336 s, p90 at the 600 s cap.
- **Cause:** the loop is only the waiting room. From a sample of 207 polling
  commands on box A:
  - 107 wait on a background job's output file (a test suite, a gate)
  - 52 wait on CI
  - 38 wait on the spool inbox

  The time belongs to the job being waited on (rows 2, 4 and 9). The loop
  itself adds at most one sleep interval, and it holds the turn until the
  600 s cap.
- **Fix:** class **(d)** for the loop. Agents should use the harness's
  background-completion notice instead of a sleep loop. Estimated saving:
  the overshoot, about 5 %, so about 4,500 s a day.

### 3.2 `do_check_pre_push`: 36,797 s

- **Measured:** 285 calls, median 25 / 60 s, p90 398 / 470 s.
- **Trace:**

  | diff checked | time | processes |
  |---|---|---|
  | nothing touched | 1.9 s | 341 |
  | 3 orc files (this lane's commit) | 11.5 s | 855 |
  | a 10-commit diff touching the WUI | 294 s | 6,194 |

  The 294 s run spent its time in parts `wui` and `wui-vendor`.
- **Cause:** the slow tail is the WUI and api parts. On top of that, the
  pre-push hook runs the whole gate again inside `git push`, right after the
  lane ran it by hand on the same tree. On a busy trunk this doubling
  widens the push window: 3 rejections in a row were seen on 2026-10-04.
- **Fix:** class **(c)**. The hook should skip when this exact tree
  (`HEAD^{tree}` plus its base) already passed. Estimated saving: the second
  run, at least 40 %, so about 15,000 s a day.

### 3.3 `poll-loop cat`: 21,842 s

- **Measured:** 58 calls, median 263 / 566 s.
- **Cause:** same as 3.1. The loop reads a job's output file.
- **Fix:** class **(d)**, covered by 3.1.

### 3.4 `gh run watch`: 16,638 s

- **Measured:** 54 calls, median 285 / 227 s.
- **Cause:** CI's own wall time. On master, the last 60 runs:
  - `10 ci: quality gate`: median 112 s, n=10
  - `20 ci-cd: spool hub build + deploy`: 806 s, n=1
  - `30 ci-cd: spool WUI build + deploy`: median 224 s, n=2

  Each lane holds a turn for its own watch.
- **Fix:** class **(d)** on the agent side, because the CI time is the cost.
  The agent's turn can be freed by watching in the background (as in 3.1).
  Making CI itself faster is a separate measurement.

### 3.5 `python3` (inline scripts): 15,839 s

- **Measured:** 829 calls, median 0.4 / 0.8 s.
- **Cause:** not one action. These are ad-hoc heredoc scripts, and the total
  comes from a long tail of a few long runs.
- **Fix:** class **(d)**.

### 3.6 `git fetch`: 14,987 s

- **Measured:** 846 calls, median 1.6 / 3.6 s, p90 21 / 24 s.
- **Trace:** 0.79 s and 6 processes, so one round trip to the remote.
- **Cause:** the tail comes from contention. About 20 worktrees share one
  object store and one ref namespace. The integration loop fetches 2 to 3
  times per push, and lanes poll with fetch (`poll-loop git fetch`, another
  2,690 s on box A).
- **Fix:** class **(c)**. Skip the fetch when `origin/master` was fetched in
  the last 60 s (FETCH_HEAD mtime). Estimated saving: half the calls, about
  7,000 s a day.

### 3.7 `pnpm run`: 14,361 s

- **Measured:** 77 calls, median 140 / 155 s. These are `nuxt generate` and
  the e2e runs.
- **Cause:** each lane rebuilds the static bundle, even when `csi-spl-wui/`
  has not changed since its last build.
- **Fix:** class **(c)**. Cache the generated bundle, keyed on the WUI tree
  hash. Estimated saving: 30 to 50 % of generate time, about 5,000 s a day.

### 3.8 `poll-loop tail`: about 12,500 s

- **Measured:** median 581 s on box B, so nearly every call hit the cap.
- **Cause:** same as 3.1.
- **Fix:** class **(d)**, covered by 3.1.

### 3.9 `run-all-tests.sh` (orc suite): 8,515 s

- **Measured:** 18 calls, median 600 / 574 s, so nearly every call hit the
  Bash cap.
- **Trace:** the full orc suite took about 11 minutes on box A: 254 files at
  `ORC_TEST_JOBS=4`, at load 8 to 12.
- **Cause:** lanes run the whole suite in the foreground, to check one new
  action.
- **Fix:** class **(a)**. Run only the tests whose action changed (test to
  function by name), plus the always-run ones such as
  `require-cloud-env.tst.sh`, in the background. Estimated saving: about
  6,000 s a day.

### 3.10 `cat`: 8,355 s

- **Measured:** 1,985 calls, median 0.2 / 0.4 s, max 600 s.
- **Cause:** the total is outliers. A cheap command blocked on a pipe, or
  the box stalled.
- **Fix:** class **(d)**. Watch it as a signal of box load instead.

## 4. Smaller, one-call traces worth a lane later

**`do_spl_db_query`**
- **Measured:** 201 calls, median 8 / 16 s.
- **Trace:** one `select 1` took 13.3 s and 247 processes. About 7.7 s of
  that was 4 `gcloud` starts (activating the key and starting the proxy), and
  1 s was sleeps. psql itself took 0.13 s.
- **Fix:** class **(b)** or **(c)**. Keep one proxy and token per env warm
  for N minutes. Estimated saving: about 80 % of 2,989 s, so about 2,400 s a day.

**`do_check_dist_hygiene`**
- **Measured:** median 5.5 / 7.1 s, but p90 109 / 87 s.
- **Trace:** 2.9 s and 89 processes.
- **Cause:** the tail is box load, not the action itself.
- **Fix:** class **(d)**.

## 5. The three to fix first

1. **The pre-push hook skips a tree that already passed** (class c,
   about 15,000 s a day). This is the largest wait that a code change can
   remove, and it is fully local to `check-pre-push`.
2. **`git fetch` skips when the fetch is fresh** (class c, about 7,000 s a
   day). It is a small wrapper, and it also takes load off the shared object
   store.
3. **The orc suite runs only the changed tests, in the background** (class a,
   about 6,000 s a day). Today almost every foreground run is cut at the
   600 s cap, so the lane then waits a second time.

Next in line: the WUI generate cache (about 5,000 s) and the `do_spl_db_query`
warm proxy (about 2,400 s, on the dispatcher's own path).
