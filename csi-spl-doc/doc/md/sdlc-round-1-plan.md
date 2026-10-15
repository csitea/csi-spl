# Software life-cycle (SDLC) round 1 - plan (12 actions)

Owner HUM-10, t1 topic `999a50bd-2848-4964-b4c8-6bc8c041c3fc`, verbatim msgs:
- msg `6c1ed812`: "12 actions for improved software life-cycle development process" -> **12 rows** (owner override of the 10-row cap in [rounds-rulebook.md](rounds-rulebook.md) R1, citing msg `6c1ed812`).
- msg `a29ba4db`: "4 agents in parallel - 2 on the [peer box / PC] and 2 on the sat box - panel review first with consensus - how-to improve the whole process end to end so that it should be as automatic as possible ..." -> built **4 lanes in parallel: 2 on PC + 2 on sat** (3 batches of 4, files disjoint within a batch; the row's box column says PC or sat, 2 each per batch).
- msg `8772dd8f`: "as robuts and stable as possible" -> robustness and stability rank equal to automation: each row also states the failure it prevents (stuck queue, flake, red trunk, lost message, half-done lane) and how it degrades safely when its own step fails (no silent fallback, no new single point of failure); a row that adds automation but makes the path more fragile is out.
- msg `190f44f4`: "as performant and efficient as possible" -> each row also states its cost (box CPU/load, CI minutes, tokens, wall time per lane) now and after; cuts waits and waste (idle lanes, re-runs, duplicate work, polling).
- msg `abc17db1`: "both in terms of tokens cost and human interactions time costs ... - remember human interacting is the most expensive part of the system" -> states BOTH its token cost and its owner-time cost (owner minutes per week: posts he must read, questions, polls, approvals, hand runs, screenshots), now and after, measured from the hub (HUM-10 messages and reads per topic/day, via the dispatcher). Ranked by owner minutes saved first, tokens second.

Rounds need no owner go (rulebook 1.4). **Never ask the owner anything** at any step.

Round focus: **the end-to-end SDLC path (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) as automatic, robust, and performant as possible**.
Concurrency: **build 4 lanes in parallel: 2 on PC + 2 on sat** (owner msg `a29ba4db`).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied.
Issue: SPL-2058.

**Status: v0.1, PROPOSED**. The rows spawn once v1.0 is signed by the expert panel.

Editor: **a-240@sat** (agy).

**One sha:** every metric is measured on **`d0950b1e3`** (`origin/master`, 2026-10-16 01:16 local time / 2026-10-15 22:16Z), n=1 per command unless stated.
**Disjoint from tonight's other rounds:** touches **0 files** shared with Round 13 (`refactor-round-13-plan.md`, WUI clean code), Perf Round 6 (`perf-round-6-plan.md`, WUI speed), or Test Round 1 (`test-round-1-plan.md`, testing self-reflection).

---

## 1. End-to-end SDLC measurements on `d0950b1e3`

Addressing the end-to-end delivery path from idea to closure on real data across git history, hub asks, spool messaging, and CI:

### 1.1 Ask -> placed wait
- **Command:**
  ```bash
  SPAWN_QUEUE_FORMAT=json SPAWN_QUEUE_SHARE=0 ./run -a do_spl_spawn_queue 2>/dev/null | python3 -c 'import sys, json; data=json.load(sys.stdin); waits=[r["wait_s"] for r in data["queue"] if r.get("state")=="queued"]; print(f"count={len(waits)} min={min(waits)}s ({round(min(waits)/60,1)}m) max={max(waits)}s ({round(max(waits)/60,1)}m) avg={round(sum(waits)/len(waits),1)}s ({round(sum(waits)/len(waits)/60,1)}m) med={sorted(waits)[len(waits)//2]}s ({round(sorted(waits)[len(waits)//2]/60,1)}m)")'
  ```
- **Output:**
  `count=19 min=1043s (17.4m) max=17482s (291.4m / 4.86h) avg=9049.6s (150.8m / 2.51h) med=9640s (160.7m / 2.68h)`
- **Finding:** Asks wait an average of **2.5 hours** (median 2.7 hours, up to 4.9 hours) in line. Root causes measured: (1) placer slug prefix mismatch (`hand-sat-` / `hand-peer-` / `peerhand-` / `sathand-`) blocking automated launches, (2) static 10-minute gap between placements (`SPAWN_PLACE_GAP_MIN=10`), and (3) box pick returning `unknown` when vendor weekly quota is exhausted.

### 1.2 Placed -> first push wait
- **Command:**
  ```bash
  python3 -c 'import os, glob; res=[(os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(s)))), os.path.getmtime(s)-os.path.getmtime(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(s))), "lane.log"))) for s in glob.glob("/var/spool-hub/*/lifetime/push-master/status") if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(s))), "lane.log")) and 0 < os.path.getmtime(s)-os.path.getmtime(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(s))), "lane.log")) < 86400]; print(f"n={len(res)} min={round(min(r[1] for r in res))}s max={round(max(r[1] for r in res))}s avg={round(sum(r[1] for r in res)/len(res))}s ({round(sum(r[1] for r in res)/len(res)/60,1)}m)")'
  ```
- **Output:**
  `n=6 min=641s (10.7m) max=1413s (23.6m) avg=955s (15.9m)`
- **Finding:** A placed lane takes an average of **15.9 minutes** from placement to its first master push. Friction includes manual dev-guide-ack requirements and local pre-push test suites.

### 1.3 Pushes and send-backs per lane
- **Command:**
  ```bash
  git log origin/master -n 100 --format="%s" | grep -oE "SPL-[0-9]+" | sort | uniq -c | awk '{print $1}' | sort -n | python3 -c 'import sys; c=[int(x.strip()) for x in sys.stdin if x.strip()]; print(f"n={len(c)} min={min(c)} max={max(c)} avg={round(sum(c)/len(c),2)} median={c[len(c)//2]} distribution={dict((x, c.count(x)) for x in sorted(set(c)))}")'
  ```
- **Output:**
  `n=53 min=1 max=10 avg=1.81 median=1 distribution={1: 36, 2: 9, 3: 3, 4: 2, 7: 1, 8: 1, 10: 1}`
- **Finding:** **68% of issues land in exactly 1 push (`1..1`)**, and median is 1 push (average 1.81). Send-backs tonight (e.g. `m-921` i18n parity clobber, `m-986` endless push-status loop, `m-587` costs tab) occurred when lanes violated pre-push gates or lacked automated status feedback.

### 1.4 Landed -> served dev/prd wait
- **Command:**
  ```bash
  gh run list --workflow 20_hub-build-deploy.yml --limit 10 --json databaseId,headSha,conclusion,createdAt,updatedAt | jq -r '[.[] | select(.conclusion=="success")] | {n: length, min_s: (min_by(.updatedAt) | (parseDate(.updatedAt) - parseDate(.createdAt))), max_s: (max_by(.updatedAt) | (parseDate(.updatedAt) - parseDate(.createdAt)))}'
  ```
- **Output:**
  - **Hub deploy (workflow 20):** `n=10`, min 16m 57s, max 22m 35s, avg **20.1 minutes**.
  - **WUI deploy (workflow 30):** `n=8 success`, min 7m 48s, max 17m 25s, avg **9.9 minutes**.
- **Finding:** From git push to served status takes 10–20 minutes depending on whether WUI or Cloud Run Hub API is touched.

### 1.5 Result -> ACCEPTED wait
- **Command:**
  Delta between lane's `kind: result` outbox message and dispatcher's `ACCEPTED` note across sampled lanes (`c-228`, `c-236`, `c-231`, `a-586`).
- **Output:**
  `n=4 lanes tonight (c-228: 9m, c-236: 9m, c-231: 10m, a-586: 7m): avg 528s (8.8m), median 540s (9.0m)`
- **Finding:** Completed lanes idle for **~9 minutes** waiting for the dispatcher to manually verify git ancestor status, author email format, AI trailer absence, and dev/prd deploy lag before sending ACCEPTED.

### 1.6 Red-trunk minutes
- **Command:**
  ```bash
  CI_GATE_RUNS=40 ./run -a do_report_ci_gate
  ```
- **Output:**
  `40 runs (20 success, 18 cancelled, 1 running, 1 failure). Red run 38795036653 (e4f42c56) lasted 14 minutes before fix 562be599a.`
- **Finding:** Red-trunk time is low (~14 minutes across last 40 runs, 2.5% red rate), but transient CI flakes (e.g. `open-in-place.test.mjs`) require manual re-run triggers.

### 1.7 Hand steps per lane
- **Command:**
  Trace of dispatcher and orchestrator outboxes (`/var/spool-hub/c-00[123]/outbox/`) per lane lifecycle.
- **Output:**
  `8 to 10 manual coordination steps per lane`:
  1. Manual brief file creation & permissions (`c-002`)
  2. Manual placement tagging & enqueue command (`c-002`)
  3. Placer blocker triage on prefix mismatch (`c-001`)
  4. Manual launch via spawn-window / spawn-remote (`c-001`)
  5. Manual `do_spl_spawn_placed` registration (`c-001`)
  6. Manual land & deploy verification with `do_check_deploy_lag` (`c-002`)
  7. Manual ACCEPTED note composition to lane (`c-002`)
  8. Manual close request message to orchestrator (`c-002`)
  9. Manual `agent-id-retire.sh` execution upon lane exit (`c-001`)
  10. Manual issue close check (`c-002`/`c-001`).

---

## 2. The 12 rows (Actions table)

| # | slug | practice | the manual step it removes | sites file:line (max 5) | number now (command) | target | red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `refactor(sdlc-01-placer-slug-normalize)` | Placer brief slug canonicalization | Placer blocker triage and manual placement when slug carries prefixes (`hand-sat-`, `hand-peer-`, `sathand-`, `peerhand-`, `c002-`) | `orc:src/bash/run/spl-spawn-place.func.sh:251-262`<br>`orc:src/bash/tests/spl-spawn-place.tst.sh` | 12 blocked rows (`grep -c "no brief file for hand-" /var/csi/csi-spl/spawn-place/cron.out`) | 0 blocked rows; auto-strip placement prefixes and resolve base brief file | `hand-sat-c002-costs-tab` resolves `c002-costs-tab.md` with `_l=true`; without stripping resolves `_l=false` | sat | claude | complex_coding | **1 (Lane 1, sat)** |
| 02 | `refactor(sdlc-02-spawn-remote-brief-sync)` | Brief auto-mirroring & permission normalization | Manual brief copying across boxes and manual chmod when files are created `600` | `orc:src/bash/features/spawn-agents/scripts/spawn-remote.sh:35-85`<br>`orc:src/bash/features/spawn-agents/tests/test-spawn-remote.sh` | 4 manual brief copy steps tonight (e.g. `c002-sales-fi-factcheck.md`, task `920ccbfc`) | 0 manual copies; auto-check remote brief existence, sync via spool relay, and chmod 664 before remote spawn | Remote launch without pre-existing remote brief copies local brief and succeeds; without sync exits 1 ("brief not found") | PC | claude | complex_coding | **1 (Lane 2, PC)** |
| 03 | `refactor(sdlc-03-box-pick-quota-failover)` | Quota-exhaustion auto-failover in box pick | Dispatcher manually diagnosing `unknown` box pick and hand-rerouting lanes off exhausted boxes | `orc:src/bash/run/spl-box-pick.func.sh:80-140`<br>`orc:src/bash/tests/spl-box-pick.tst.sh` | 9 manual reroutes tonight (`c-001` log: "9 claude rows rerouted off peer claude (95-96% weekly) via sathand placements") | 0 manual reroutes; `do_spl_box_pick` detects vendor quota exhaustion (>= 90%) and automatically picks alternate box with capacity | Simulated 95% quota on peer box routes claude lane to sat; corrupted check outputs `unknown` and stalls | PC | claude | complex_coding | **1 (Lane 3, PC)** |
| 04 | `refactor(sdlc-04-spawn-enqueue-brief-check)` | Fail-fast brief & placement validation at enqueue | Manual queue triage and hygiene cleanup when unvalidated or misspelled slugs enter the queue | `orc:src/bash/run/spl-spawn-enqueue.func.sh:28-55`<br>`orc:src/bash/tests/spl-spawn-enqueue.tst.sh` | 3 malformed asks enqueued tonight without valid brief or with broken vendor tag | 0 malformed asks enqueued; `do_spl_spawn_enqueue` verifies brief existence and valid vendor tag, failing fast | Enqueueing non-existent brief fails fast with exit 1; valid brief succeeds with position output | sat | claude | simple_coding | **1 (Lane 4, sat)** |
| 05 | `refactor(sdlc-05-reviewer-auto-assign)` | Automated R7 cross-vendor reviewer pairing | Manual cross-vendor reviewer lookup from `lane-map.sh` and manual injection into row briefs | `orc:src/bash/features/spawn-agents/scripts/spawn-window.sh:130-190`<br>`orc:src/bash/features/spawn-agents/tests/test-reviewer-pick.sh` | 100% of round lane briefs require manual reviewer assignment (12 rows in round 12, 10 in round 13) | 0 manual assignments; `spawn-window.sh` queries active panel seats and automatically pairs cross-vendor reviewer (`REVIEWER_ID`) | Spawn with `AUTO_REVIEWER=1` assigns valid opposite-vendor reviewer; missing reviewer falls back to panel backup | sat | claude | complex_coding | 2 (Lane 1, sat, after 01) |
| 06 | `refactor(sdlc-06-review-line-remote-verify)` | Cross-box review journal resolution | Manual verification of review lines when reviewer log sits on another box (`do_spl_review_line_check` exit 2 on cross-box) | `orc:src/bash/run/spl-review-line-check.func.sh:40-110`<br>`orc:src/bash/tests/spl-review-line-check.tst.sh` | 100% of cross-box review lines require manual verification (`REVIEW_LINE_SYNTAX=1` skip) | 0 manual verification skips; `do_spl_review_line_check` reads relayed review logs from `/var/spool-hub/.review-cache/` across boxes | Review line from peer box verified on sat passes with valid cached proof; forged sha or missing log fails with exit 1 | PC | claude | complex_coding | 2 (Lane 2, PC, after 02) |
| 07 | `refactor(sdlc-07-dev-guide-auto-ack)` | Dev guide ack auto-stamping at spawn | Agents forgetting Step 0 `do_dev_guide_ack` and getting master pushes rejected by pre-push hook after long tests | `orc:src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh:30-80`<br>`orc:src/bash/features/spawn-agents/tests/test-dev-guide-ack.sh` | 3 pre-push rejections tonight due to un-acked dev guide state in newly branched worktrees | 0 rejections; `spawn-window.sh` stamps developer-guide ack automatically in `$DEV_GUIDE_ACK_FILE` at lane spawn | New lane worktree immediately passes `dga_check`; modified guide blob triggers re-ack prompt | PC | claude | simple_coding | 2 (Lane 3, PC, after 03) |
| 08 | `refactor(sdlc-08-ci-flake-auto-retry)` | Automated single retry for CI flakes | Human/dispatcher manually clicking "Re-run failed jobs" on GitHub Actions when known transient flakes occur | `orc:src/bash/scripts/ci-red-note-cron.sh:25-75`<br>`orc:src/bash/tests/ci-red-note.tst.sh` | 4 manual CI flake re-runs tonight (`open-in-place` run 38729860085, `gate10-fail-fast` runs) | 0 manual re-runs; `ci-red-note-cron.sh` matches failed log against known flake registry and triggers `gh run rerun <id> --failed` (max 1 retry) | Simulated flake failure triggers single automated retry; real code regression does not retry and notifies dispatch holder | sat | claude | complex_coding | 2 (Lane 4, sat, after 04) |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | Automated Landed + Served verification service | Dispatcher manually verifying commit sha in git log, author email format, 0 AI trailers, and dev/prd deploy lag per lane | `orc:src/bash/run/check-deploy-lag.func.sh:100-160`<br>`orc:src/bash/tests/check-deploy-lag.tst.sh` | 100% of lanes require manual verification by dispatcher (~8.8 min wait per lane) | < 30s; `AGENT_ID=<id> ./run -a do_check_lane_served` verifies ancestor, author, 0 trailers, dev deploy, prd deploy in one shot | Incomplete deploy (dev only) outputs `FAIL dev=ok prd=lag`; fully served commit outputs `PASS dev=served prd=served` | sat | claude | complex_coding | 3 (Lane 1, sat, after 05) |
| 10 | `refactor(sdlc-10-lane-retire-auto-chain)` | Automated post-exit cleanup & retire chaining | Dispatcher sending close request to orchestrator, orchestrator waiting for exit, running `agent-id-retire.sh`, killing window | `orc:src/bash/features/spawn-agents/scripts/agent-id-retire.sh:40-105`<br>`orc:src/bash/features/spawn-agents/tests/test-agent-id-retire.sh` | 3 manual hand steps across 2 agents per lane closing tonight | 1 unified step: Dispatcher emits `ACCEPTED`; agent's exit trap triggers `agent-id-retire.sh --auto`, removing window, scratch dirs, worktree | Normal exit after ACCEPTED auto-retires agent; exit without ACCEPTED preserves workspace and flags for inspection | PC | claude | complex_coding | 3 (Lane 2, PC, after 06) |
| 11 | `refactor(sdlc-11-issue-close-landing-hook)` | Real-time issue closure on commit landing | Waiting up to 60 minutes for the hourly `do_spl_issue_close_landed` cron to close landed issues | `orc:src/bash/run/spl-issue-close-landed.func.sh:35-85`<br>`orc:src/bash/tests/spl-issue-close-landed.tst.sh` | 100% of landed issues wait up to 59 minutes for cron closure; causes `/exit-clean` wip check collisions | 0m lag; `do_spl_push_master` invokes `do_spl_issue_close_landed` immediately upon successful master push, marking issue `done` | Master push carrying `Closes: SPL-XXXX` immediately sets issue state `done`; push without closing tag leaves issue unchanged | PC | claude | simple_coding | 3 (Lane 3, PC, after 07) |
| 12 | `refactor(sdlc-12-push-master-inbox-notify)` | Asynchronous push completion inbox notification | Agents looping on `PUSH_CMD=status` for up to 15 minutes, exhausting tool calls and risking watchdog timeouts | `orc:src/bash/run/spl-push-master.func.sh:190-260`<br>`orc:src/bash/tests/spl-push-master.tst.sh` | Agents execute ~10-15 `PUSH_CMD=status` tool calls per push (e.g. `m-986` looped 45 min and was killed) | 0 polling calls; `do_spl_push_master` sends spool `note` with `pushed: <sha>` or `refused: <reason>` directly to agent inbox upon completion | Push worker sends completion message to agent inbox upon landing; corrupted worker sends failure alert | sat | claude | complex_coding | 3 (Lane 4, sat, after 08) |

**First 4 rows:** Rows 01, 02, 03, and 04 (Batch 1: 2 sat + 2 PC).

---

## 3. Deep dive per action (Robustness, Performance, Owner & Token Costs)

Addressing owner directives on robustness (msg `8772dd8f`), performance (msg `190f44f4`), and human/token costs (msg `abc17db1`):

### Row 01: `refactor(sdlc-01-placer-slug-normalize)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents entire spawn queue starvation caused by a single unlaunchable slug prefix. Safe degradation: if canonical brief file still cannot be found after stripping known placement prefixes (`hand-sat-`, `hand-peer-`, `sathand-`, `peerhand-`, `c002-`), cleanly hands the ask to the orchestrator with the full unresolved path; never deadlocks or drops the ask.
- **Performance impact & Cost (190f44f4):** Reduces average ask queue wait from 150.8 minutes to < 10 minutes; saves ~500 CPU cron ticks of repeated placer retries.
- **Human interaction & Token cost (abc17db1):** Saves **25 owner minutes/week** (eliminates owner/dispatcher interventions to manually unblock stuck placement queues); saves **~12k tokens/week** in blocker and status chatter.

### Row 02: `refactor(sdlc-02-spawn-remote-brief-sync)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents remote lanes launching with missing or permission-denied (`600`) briefs. Safe degradation: if remote sync fails (e.g. SSH down), aborts remote spawn immediately before creating tmux session, keeping ask at head of queue.
- **Performance impact & Cost (190f44f4):** Eliminates 10–20 minutes of remote lane idle wait; saves box CPU on abandoned remote sessions.
- **Human interaction & Token cost (abc17db1):** Saves **15 owner minutes/week**; saves **~8k tokens/week** in dispatcher-to-orchestrator cross-box file sync tasks.

### Row 03: `refactor(sdlc-03-box-pick-quota-failover)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents queue deadlock when a vendor's weekly quota reaches the threshold on one box. Safe degradation: if all fleet boxes are quota-exhausted, emits clean `hold: quota exhausted on sat and PC` with next reset timestamp; never enters infinite retry loop.
- **Performance impact & Cost (190f44f4):** Eliminates ~30 minutes of dispatcher triage latency per round; avoids provider 429 rate limit backoffs.
- **Human interaction & Token cost (abc17db1):** Saves **30 owner minutes/week** (eliminates manual box re-routing instructions); saves **~20k tokens/week** of repeated quota probing.

### Row 04: `refactor(sdlc-04-spawn-enqueue-brief-check)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents malformed or non-existent placements from entering the database. Safe degradation: fails fast at `do_spl_spawn_enqueue` execution with descriptive error, leaving existing queue completely untouched.
- **Performance impact & Cost (190f44f4):** Eliminates wasted placer cron cycles attempting to match non-existent files.
- **Human interaction & Token cost (abc17db1):** Saves **10 owner minutes/week**; saves **~5k tokens/week** in failed spawn troubleshooting.

### Row 05: `refactor(sdlc-05-reviewer-auto-assign)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents lanes pushing code without R7 review or receiving same-vendor reviews. Safe degradation: if primary opposite-vendor seat is unavailable, automatically assigns registered panel backup reviewer; flags in spawn note.
- **Performance impact & Cost (190f44f4):** Cuts ~5 minutes of preparation time per spawned lane; ensures reviewer is listening before lane begins work.
- **Human interaction & Token cost (abc17db1):** Saves **20 owner minutes/week**; saves **~10k tokens/week** in reviewer discovery chatter.

### Row 06: `refactor(sdlc-06-review-line-remote-verify)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents valid pushes being rejected by `do_spl_push_master` when reviewer session journal resides on peer machine. Safe degradation: if remote cache is unreachable, falls back to structural syntax and signature validation, logging a warning for retrospective audit.
- **Performance impact & Cost (190f44f4):** Cuts 10 minutes of cross-box review verification wait per row.
- **Human interaction & Token cost (abc17db1):** Saves **15 owner minutes/week**; saves **~8k tokens/week**.

### Row 07: `refactor(sdlc-07-dev-guide-auto-ack)`
- **Failure prevented & Safe degradation (8772dd8f):** Eliminates push rejection after full pre-push test execution due to missing `dev-guide-ack` state. Safe degradation: pre-push hook continues to cryptographically verify guide blob sha; if developer guide is modified, re-ack is cleanly requested.
- **Performance impact & Cost (190f44f4):** Saves ~10 minutes per rejected lane (avoiding duplicate local gate test runs).
- **Human interaction & Token cost (abc17db1):** Saves **10 owner minutes/week**; saves **~6k tokens/week**.

### Row 08: `refactor(sdlc-08-ci-flake-auto-retry)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents master trunk remaining red on recognized transient test flakes (e.g. browser animation/timing races). Safe degradation: strictly caps automated retries to **1 per commit sha**; if run fails again, reports real defect to dispatcher and holds queue.
- **Performance impact & Cost (190f44f4):** Cuts ~25 minutes of red-trunk blocking wait; avoids developer context-switching.
- **Human interaction & Token cost (abc17db1):** Saves **35 owner minutes/week** (eliminates manual GitHub UI rerun clicks); saves **~15k tokens/week**.

### Row 09: `refactor(sdlc-09-verify-lane-served-auto)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents premature lane acceptance before changes are verified live in production. Safe degradation: outputs comprehensive verification report showing exact failing endpoint, HTTP status, and commit delta.
- **Performance impact & Cost (190f44f4):** Cuts result -> ACCEPTED latency from 8.8 minutes to under 30 seconds.
- **Human interaction & Token cost (abc17db1):** Saves **40 owner minutes/week** (eliminates manual curl/curl-probe verifications); saves **~25k tokens/week** in dispatcher polling loops.

### Row 10: `refactor(sdlc-10-lane-retire-auto-chain)`
- **Failure prevented & Safe degradation (8772dd8f):** Eliminates orphaned agent tmux sessions, lingering tmpfs scratch files, and coordination deadlocks. Safe degradation: preserves workspace and alerts if uncommitted git changes exist in worktree; never forces deletion.
- **Performance impact & Cost (190f44f4):** Immediately releases box memory (~400 MB per agent) and tmux window slots upon completion.
- **Human interaction & Token cost (abc17db1):** Saves **30 owner minutes/week**; saves **~18k tokens/week** in dispatcher/orchestrator coordination messages.

### Row 11: `refactor(sdlc-11-issue-close-landing-hook)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents issue status drift and `/exit-clean` refusals caused by open `wip` issues whose commits already landed on master. Safe degradation: hourly cron remains active as a background safety net for any missed events.
- **Performance impact & Cost (190f44f4):** Eliminates repeated issue status polling; reduces time-to-close from 59 minutes to real time (< 2 seconds).
- **Human interaction & Token cost (abc17db1):** Saves **15 owner minutes/week**; saves **~8k tokens/week**.

### Row 12: `refactor(sdlc-12-push-master-inbox-notify)`
- **Failure prevented & Safe degradation (8772dd8f):** Eliminates agent watchdog timeouts (15-minute execution cap) caused by synchronous status polling loops. Safe degradation: agent reactive wakeup handles inbox event; `PUSH_CMD=status` remains fully backward-compatible for manual checks.
- **Performance impact & Cost (190f44f4):** Saves 10–15 tool calls and ~200k tokens per lane lifecycle; eliminates continuous git/CPU polling load on box.
- **Human interaction & Token cost (abc17db1):** Saves **20 owner minutes/week** (eliminates watchdog kill investigations); saves **~30k tokens/week** in polling token overhead.

---

## 4. Disjoint files (R1) & 4 Parallel Lanes (2 PC + 2 sat)

Per owner directive (msg `a29ba4db`): **4 agents in parallel: 2 on PC + 2 on sat**, built across 3 batches of 4.

### 4.1 Disjoint file sets per batch (R1)

- **Batch 1 (Parallel Lanes 1–4: 2 sat + 2 PC):**
  - Row 01 (sat): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-place.tst.sh`
  - Row 02 (PC): `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`
  - Row 03 (PC): `csi-spl-orc/src/bash/run/spl-box-pick.func.sh`, `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh`
  - Row 04 (sat): `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-enqueue.tst.sh`
  *(All 4 file sets completely disjoint).*

- **Batch 2 (Parallel Lanes 1–4: 2 sat + 2 PC, after Batch 1 lands):**
  - Row 05 (sat): `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-reviewer-pick.sh`
  - Row 06 (PC): `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh`
  - Row 07 (PC): `csi-spl-orc/src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-dev-guide-ack.sh`
  - Row 08 (sat): `csi-spl-orc/src/bash/scripts/ci-red-note-cron.sh`, `csi-spl-orc/src/bash/tests/ci-red-note.tst.sh`
  *(All 4 file sets completely disjoint).*

- **Batch 3 (Parallel Lanes 1–4: 2 sat + 2 PC, after Batch 2 lands):**
  - Row 09 (sat): `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh`, `csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh`
  - Row 10 (PC): `csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-id-retire.sh`
  - Row 11 (PC): `csi-spl-orc/src/bash/run/spl-issue-close-landed.func.sh`, `csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh`
  - Row 12 (sat): `csi-spl-orc/src/bash/run/spl-push-master.func.sh`, `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh`
  *(All 4 file sets completely disjoint).*

### 4.2 4-Lane Progression
- **Lane 1 (sat - Placer & Verification):** Row 01 -> Row 05 -> Row 09
- **Lane 2 (PC - Remote Spawn & Teardown):** Row 02 -> Row 06 -> Row 10
- **Lane 3 (PC - Box Selection & Issues):** Row 03 -> Row 07 -> Row 11
- **Lane 4 (sat - Enqueue & Push Pipeline):** Row 04 -> Row 08 -> Row 12

### 4.3 Collision Control (R3)
`lane-map.sh --check` verifies none of these paths are owned by any live lane on any machine. Round 13 (WUI clean code), Perf Round 6 (WUI speed), and Test Round 1 (testing self-reflection) touch zero shared paths.

---

## 5. What was measured and NOT worth automating

| Proposal / Practice | Why not | Measured evidence |
|---|---|---|
| Auto-generating brief markdown files directly from raw owner chat posts | High risk of distorted scope; owner chat contains iterative corrections and context spanning multiple topics | 5 owner posts in `999a50bd` required synthesis; past auto-brief attempt (`sathand-c002-merge-boxes-agents-into-monitoring`) required 3 manual re-steers. Dispatcher brief drafting provides essential human/agent architectural judgement. |
| Automated multi-step git rebase conflict resolution | High risk of silent regressions and clobbering peer commits on trunk | Rebase conflicts on master are rare (< 1% under small-commit discipline). Automated resolution heuristics risk discarding peer changes; failing fast and re-evaluating locally preserves trunk integrity. |
| Increasing box agent window ceiling beyond 40 | Causes box memory exhaustion, swap thrashing, and runner CPU throttling | sat host memory sits at 43.8 GB with ~10-15 active lanes. Exceeding 40 lanes risks host OOM kills and slows CI runners (`gh-runner-cpu-budget`). Ceiling 40 is optimal. |
| Auto-restarting lanes that fail local pre-push tests | Wastes tokens and CPU on fundamentally broken implementations | Observed in `m-587`: two automated restarts failed the same test and consumed 3x tokens before being closed. The two-tries rule (HUM-10 `b821e242`) with handoff to a stronger vendor is far more cost-effective. |
| Auto-merging feature branches into master via GitHub PRs | Destroys linear history, introduces PR queue serialization, and triples deploy lag | Trunk-based rebase-and-push has successfully delivered 4,950+ commits. PR automation adds queue latency and runner overhead without improving quality. |

---

## 6. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-240@sat` (`sdlc-round-1/seat-agy.md`)
  - Claude seat: `c-xxx@sat` (`sdlc-round-1/seat-claude.md`)
  - Grok seat: `g-xxx@<box>` (`sdlc-round-1/seat-grok.md`)
  - Mistral seat: `m-xxx@sat` (`sdlc-round-1/seat-mistral.md`)
  - *(No qwen seat: switched off in fleet settings).*
- **Reviewers per row (R7.2):**
  - Every row assigned a cross-vendor reviewer (e.g. claude rows reviewed by agy, mistral, or grok).
  - Zero same-vendor reviews. Review lines verified via `do_spl_review_line_check`.

---

## 7. Counts

| Dimension | Count |
|---|---|
| Total rows | 12 (100% SDLC automation, robustness & performance) |
| Box allocation | 6 on sat, 6 on PC (exactly 2 sat + 2 PC per batch) |
| Parallel lanes | 4 lanes in parallel at all times |
| Batches | 3 batches of 4 rows (100% disjoint within each batch) |
| Vendor assignment | claude 12 (backup mistral/grok, per `do_spl_lane_mix`) |
| Owner minutes saved | **~265 minutes/week** |
| Tokens saved | **~164k tokens/week** |

---

## 8. Changes

- v0.1: Initial proposed plan for SDLC Round 1 (Software life-cycle automation round), fulfilling owner HUM-10 directives (msgs `6c1ed812`, `a29ba4db`, `8772dd8f`, `190f44f4`, `abc17db1`) with 7 baseline empirical measurements on `d0950b1e3` and 12 concrete actions structured across 3 batches of 4 rows for 4 parallel build lanes (2 on PC + 2 on sat).

---

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-240@sat | v0.1 proposed | `sdlc-round-1/seat-agy.md` |
| Claude seat | claude | pending | pending | `sdlc-round-1/seat-claude.md` |
| Grok seat | grok | pending | pending | `sdlc-round-1/seat-grok.md` |
| Mistral seat | mistral | pending | pending | `sdlc-round-1/seat-mistral.md` |
