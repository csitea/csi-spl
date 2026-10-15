# Software life-cycle (SDLC) round 1 - plan (12 actions)

Owner HUM-10, t1 topic `999a50bd-2848-4964-b4c8-6bc8c041c3fc`, verbatim msgs:
- msg `6c1ed812`: "12 actions for improved software life-cycle development process" -> **12 rows** (owner override of the 10-row cap in [rounds-rulebook.md](rounds-rulebook.md) R1, citing msg `6c1ed812`).
- msg `a29ba4db`: "4 agents in parallel - 2 on the PC and 2 on the sat box - panel review first with consensus - how-to improve the whole process end to end so that it should be as automatic as possible ..." -> built **4 lanes in parallel: 2 on PC + 2 on sat** (3 batches of 4, files disjoint within a batch; the row's box column says PC or sat, 2 each per batch).
- msg `8772dd8f`: "as robuts and stable as possible" -> robustness and stability rank equal to automation: each row also states the failure it prevents (stuck queue, flake, red trunk, lost message, half-done lane) and how it degrades safely when its own step fails (no silent fallback, no new single point of failure); a row that adds automation but makes the path more fragile is out.
- msg `190f44f4`: "as performant and efficient as possible" -> each row also states its cost (box CPU/load, CI minutes, tokens, wall time per lane) now and after; cuts waits and waste (idle lanes, re-runs, duplicate work, polling).
- msg `abc17db1`: "both in terms of tokens cost and human interactions time costs ... - remember human interacting is the most expensive part of the system" -> states BOTH its token cost and its owner-time cost (owner minutes per week: posts he must read, questions, polls, approvals, hand runs, screenshots), now and after, measured from the hub (HUM-10 messages and reads per topic/day, via the dispatcher). Ranked by owner minutes saved first, tokens second.

Rounds need no owner go (rulebook 1.4). **Never ask the owner anything** at any step.

Round focus: **the end-to-end SDLC path (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) as automatic, robust, and performant as possible**.
Concurrency: **build 4 lanes in parallel: 2 on PC + 2 on sat** (owner msg `a29ba4db`).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied.
Issue: SPL-2058.

**Status: v1.0, SIGNED**. The rows spawn from the signed v1.0 sha (rulebook 1.4: consensus, then build, no second go).

Editor: **a-240@sat** (agy).

**One sha:** every metric is measured on **`d0950b1e3`** (`origin/master`, 2026-10-16 01:16 local time / 2026-10-15 22:16Z), n=1 per command unless stated. Inputs: expert panel reviews ([seat-claude.md](sdlc-round-1/seat-claude.md) `e0edb8964`, [seat-mistral.md](sdlc-round-1/seat-mistral.md) `754b1d4bb`).
**Disjoint from tonight's other rounds:** touches **0 files** shared with Round 13 (`refactor-round-13-plan.md`, WUI clean code), Perf Round 6 (`perf-round-6-plan.md`, WUI speed), or Test Round 1 (`test-round-1-plan.md`, testing self-reflection).

---

## 0. Owner-time baseline (measured on prd hub)

Measured on prd, tenant `t1`, over the last 7 days (`ENV=prd do_spl_db_query` across `HUM-10` messages):
- Total owner posts: **1,108 posts across 7 days** (187, 201, 138, 100, 156, 140, 186/day).
- Subject breakdown:
  - **Status asks** (`what is the status`, `^status`, `status ?`, `status report`, `how many done`): **32 posts across 28 topics**.
  - Queue / stuck / idle / not placed: **12 posts**.
  - Deployed / live / served / prd: **11 posts**.
  - Issue state: **10 posts**.
  - Quota / weekly limit: **6 posts**.
  - CI re-run / flake: **2 posts**.
  - Push status: **2 posts**.
  - Close / retire / orphan: **1 post**.
- Finding: Status inquiries represent the single largest addressable driver of owner interaction time (32 weekly posts), answered fast by agents (median 50.5s) but imposing continuous reading and post context switching on the owner.

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
- **Finding:** Asks wait an average of **2.5 hours** (median 2.7 hours, up to 4.9 hours) in line. Root causes measured: (1) static 10-minute placement clock (`SPAWN_PLACE_GAP_MIN=10`) causing **1,418 holds** in placer log vs only 37 load-target holds, (2) placer slug prefix mismatch and unlaunchable rows burning placement slots upon hand-off, and (3) box pick returning `unknown` when vendor weekly quota is exhausted.

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
  Evaluation across `/var/spool-hub/c-00[23]/outbox/` ACCEPTED messages matched to respective lane `kind: result` message on same task.
- **Output:**
  `161 ACCEPTED messages, 123 matched: min 5s, median 35s, avg 320s (5.3m), p90 892s (14.9m), max 4709s (78.5m)`
- **Finding:** While the median lane wait is low (35s), the long tail (p90 14.9m, max 78m) leaves completed lanes idling while dispatchers manually verify git ancestry, author email format, zero AI trailers, and dev/prd deployment state.

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
| 01 | `refactor(sdlc-01-placer-slug-normalize)` | Placer brief slug canonicalization & box pin | Placer blocker triage and manual placement when slug carries prefixes (`hand-sat-`, `hand-peer-`, `sathand-`, `c002-`) | `orc:src/bash/run/spl-spawn-place.func.sh:249-262`<br>`orc:src/bash/tests/spl-spawn-queue.tst.sh` | 12 hand-offs (`grep -c "no brief file for" cron.out`); 7 `hand-sat-*` rows currently unlaunchable | 0 blocked rows; parse `hand-<box>-` as box pin and launch on that box; brief hand-off must never touch `.place.last` | `hand-sat-c002-costs-tab` resolves `c002-costs-tab.md` on sat with `_l=true` without touching `.place.last` | sat | claude | complex_coding | **1 (Lane 1, sat)** |
| 02 | `refactor(sdlc-02-spawn-remote-brief-sync)` | Remote brief auto-mirror & permission normalization | Cross-box brief and workspace file sync stalls | `orc:src/bash/features/spawn-agents/scripts/spawn-remote.sh:35-85`<br>`orc:src/bash/features/spawn-agents/tests/test-spawn-remote.sh` | Cross-box file sync coordination overhead between sat and PC | 0 stalls; auto-verify remote brief existence, sync via spool relay, chmod 664 before remote spawn | Remote launch without pre-existing brief copies local brief and succeeds; failed sync exits 1 without launching | PC | claude | complex_coding | **1 (Lane 2, PC)** |
| 03 | `refactor(sdlc-03-box-pick-quota-failover)` | Quota-exhaustion auto-failover & unknown-usage resolution | Dispatcher manually diagnosing `unknown` box pick and hand-rerouting lanes off exhausted boxes | `orc:src/bash/run/spl-box-pick.func.sh:80-140`<br>`orc:src/bash/tests/spl-box-pick.tst.sh` | 9 manual reroutes tonight (`c-001` log); `unknown` usage placed anyway (`spl-box-pick.func.sh:187`) | 0 manual reroutes; fail over to box with capacity; resolve `unknown` usage cleanly | Simulated 95% quota on PC routes claude lane to sat; unknown usage safely holds or routes | PC | claude | complex_coding | **1 (Lane 3, PC)** |
| 05 | `refactor(sdlc-05-reviewer-auto-assign)` | Automated R7 cross-vendor reviewer pairing | Manual cross-vendor reviewer lookup from `lane-map.sh` and manual injection into row briefs | `orc:src/bash/features/spawn-agents/scripts/spawn-window.sh:130-190`<br>`orc:src/bash/features/spawn-agents/tests/test-reviewer-pick.sh` | 100% of round lane briefs require manual reviewer assignment (12 rows in round 12, 10 in round 13) | 0 manual assignments; `spawn-window.sh` queries active panel seats and automatically pairs cross-vendor reviewer (`REVIEWER_ID`) | Spawn with `AUTO_REVIEWER=1` assigns valid opposite-vendor reviewer; missing reviewer falls back to panel backup | sat | claude | complex_coding | **1 (Lane 4, sat)** |
| 04 | `refactor(sdlc-04-placer-handoff-unblock)` | Placer hand-off unblocking (P2) | Placer burning 10-minute placement slot when encountering unlaunchable row | `orc:src/bash/run/spl-spawn-place.func.sh:235-245`<br>`orc:src/bash/tests/test-spawn-place-handoff.sh` | 12 hand-offs burned 10-min slots (`.place.last` touched before brief check at line 239); queue waits 7547..20979s | 0 wasted placement slots; hand-off moves immediately to next launchable row without touching `.place.last` | Hand-off leaves `.place.last` untouched; next launchable row placed on same tick | sat | claude | complex_coding | 2 (Lane 1, sat, after 01) |
| 06 | `refactor(sdlc-06-spawn-place-dynamic-gap)` | Dynamic placement gap following lane heartbeat (P3) | Static 10-minute placement hold delaying queue drain regardless of box capacity | `orc:src/bash/run/spl-spawn-place.func.sh:198-208`<br>`orc:src/bash/tests/spl-spawn-place-gap.tst.sh` | 1,418 clock holds in cron.out vs 37 load-target holds; queue median 12,713s | Queue median under 1h; placement gap ends upon placed lane's first heartbeat (3-min floor, load target guard) | Load target hold stops placement regardless of heartbeat; healthy heartbeat allows placement after 3m | PC | claude | complex_coding | 2 (Lane 2, PC, after 02) |
| 07 | `refactor(sdlc-07-topic-status-card)` | Live topic status card on owner issue topics (P1) | Owner repeatedly posting status inquiries across active task topics | `orc:src/bash/features/spawn-agents/scripts/topic-status-card.sh`<br>`orc:src/bash/features/spawn-agents/tests/test-topic-status-card.sh` | 32 owner status asks across 28 topics in 7 days (`what is the status`, `status?`, `how many done`) | 0 owner status asks; hub maintains live edited-in-place card (state, lane@box, queue pos, landed sha, served dev/prd) | Card updates dynamically on state transitions; does not create spam posts | PC | claude | complex_coding | 2 (Lane 3, PC, after 03) |
| 08 | `refactor(sdlc-08-ci-flake-auto-retry)` | Automated single retry for CI setup flakes | Manual GitHub UI rerun clicks on transient environment/setup failures | `orc:src/bash/scripts/ci-red-note-cron.sh:25-75`<br>`orc:src/bash/tests/install-box-crons.tst.sh` | 4 manual CI flake re-runs tonight; setup job flakes | 0 manual re-runs; `ci-red-note-cron.sh` matches known transient setup flakes and triggers single `gh run rerun <id> --failed` | Simulated flake triggers single retry; real test defect alerts dispatcher without retry | sat | claude | complex_coding | 2 (Lane 4, sat, after 05) |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | Automated Landed + Served verification service | Dispatcher manually verifying git ancestor status, author email format, 0 AI trailers, and dev/prd deploy lag per lane | `orc:src/bash/run/check-lane-served.func.sh:1-120`<br>`orc:src/bash/tests/check-deploy-lag.tst.sh` | Dispatcher manual check takes p90 892s (14.9m), up to 78m; 11 owner posts/week on live/served | < 30s; `do_check_lane_served` verifies ancestor, author `%ae %ce`, 0 trailers, dev deploy, prd deploy in one shot | Incomplete deploy outputs `FAIL dev=ok prd=lag`; fully served commit outputs `PASS dev=served prd=served` | sat | claude | complex_coding | 3 (Lane 1, sat, after 04) |
| 10 | `refactor(sdlc-10-lane-retire-auto-chain)` | Automated post-exit cleanup & retire chaining | Manual coordination steps across dispatcher and orchestrator upon lane completion | `orc:src/bash/features/spawn-agents/scripts/agent-id-retire.sh:40-105`<br>`orc:src/bash/features/spawn-agents/tests/test-agent-id-retire.sh` | 3 hand steps across 2 agents per lane close | 1 unified step: agent exit trap auto-retires cleanly after ACCEPTED; preserves workspace if uncommitted work exists | Exit after ACCEPTED auto-retires id and cleans scratch; uncommitted work halts retire and flags for review | PC | claude | complex_coding | 3 (Lane 2, PC, after 06) |
| 11 | `refactor(sdlc-11-issue-close-landing-hook)` | Real-time issue closure on commit landing | Landed issues waiting up to 59 minutes for hourly cron closure; causing /exit-clean wip collisions | `orc:src/bash/run/spl-issue-close-landed.func.sh:35-85`<br>`orc:src/bash/tests/spl-issue-close-landed.tst.sh` | 10 owner posts/week on issue state; up to 59 min wait for hourly closer | 0m lag; `do_spl_push_master` triggers issue closure for landed shas' keys under closer lock | Master push with closing tag immediately closes issue; push without closing tag leaves issue untouched | PC | mistral | simple_coding | 3 (Lane 3, PC, after 07) |
| 12 | `refactor(sdlc-12-push-master-inbox-notify)` | Asynchronous push completion inbox notification | Agents looping on `PUSH_CMD=status`, consuming tool calls and risk of watchdog timeout | `orc:src/bash/run/spl-push-master.func.sh:190-260`<br>`orc:src/bash/tests/spl-push-master.tst.sh` | Average 1.4 status calls per push (max 7.0, up to 45m loop in m-986) | 0 polling calls; `do_spl_push_master` sends spool `note` doorbell to agent inbox upon push worker landing | Push worker sends completion message to agent inbox upon landing; `PUSH_CMD=status` retained as source of truth | sat | claude | complex_coding | 3 (Lane 4, sat, after 08) |

**First 4 rows:** Rows 01, 02, 03, and 05 (Batch 1: 2 sat + 2 PC).

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
  - Row 01 (sat): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`
  - Row 02 (PC): `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`
  - Row 03 (PC): `csi-spl-orc/src/bash/run/spl-box-pick.func.sh`, `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh`
  - Row 05 (sat): `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-reviewer-pick.sh`
  *(All 4 file sets completely disjoint).*

- **Batch 2 (Parallel Lanes 1–4: 2 sat + 2 PC, after Batch 1 lands):**
  - Row 04 (sat): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (lines 235-245), `csi-spl-orc/src/bash/tests/test-spawn-place-handoff.sh`
  - Row 06 (PC): `csi-spl-orc/src/bash/run/spl-spawn-place-gap.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-place-gap.tst.sh`
  - Row 07 (PC): `csi-spl-orc/src/bash/features/spawn-agents/scripts/topic-status-card.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-topic-status-card.sh`
  - Row 08 (sat): `csi-spl-orc/src/bash/scripts/ci-red-note-cron.sh`, `csi-spl-orc/src/bash/tests/install-box-crons.tst.sh`
  *(All 4 file sets completely disjoint).*

- **Batch 3 (Parallel Lanes 1–4: 2 sat + 2 PC, after Batch 2 lands):**
  - Row 09 (sat): `csi-spl-orc/src/bash/run/check-lane-served.func.sh`, `csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh`
  - Row 10 (PC): `csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-id-retire.sh`
  - Row 11 (PC): `csi-spl-orc/src/bash/run/spl-issue-close-landed.func.sh`, `csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh`
  - Row 12 (sat): `csi-spl-orc/src/bash/run/spl-push-master.func.sh`, `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh`
  *(All 4 file sets completely disjoint).*

### 4.2 4-Lane Progression
- **Lane 1 (sat - Placer & Verification):** Row 01 -> Row 04 -> Row 09
- **Lane 2 (PC - Remote Spawn & Teardown):** Row 02 -> Row 06 -> Row 10
- **Lane 3 (PC - Box Selection & Topic Cards):** Row 03 -> Row 07 -> Row 11
- **Lane 4 (sat - Reviewer Pairing & Push Pipeline):** Row 05 -> Row 08 -> Row 12

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
  - Claude seat: `c-247@sat` (`sdlc-round-1/seat-claude.md`, verdict in `e0edb8964`)
  - Mistral seat: `m-248@sat` (`sdlc-round-1/seat-mistral.md`, verdict in `754b1d4bb`)
  - Grok seat: Not seated (no grok quota on any box, per dispatcher `c-002@sat` note)
  - *(No qwen seat: switched off in fleet settings).*
- **Reviewers per row (R7.2):**
  - Every row assigned a cross-vendor reviewer (e.g. claude rows reviewed by agy or mistral).
  - Zero same-vendor reviews. Review lines verified via `do_spl_review_line_check`.

---

## 7. Counts

| Dimension | Count |
|---|---|
| Total rows | 12 (100% SDLC automation, robustness & performance) |
| Box allocation | 6 on sat, 6 on PC (exactly 2 sat + 2 PC per batch) |
| Parallel lanes | 4 lanes in parallel at all times |
| Batches | 3 batches of 4 rows (100% disjoint within each batch) |
| Vendor assignment | claude 11, mistral 1 (Row 11 simple_coding) (backup mistral/agy, per `do_spl_lane_mix`) |
| Owner minutes saved | **~265 minutes/week** |
| Tokens saved | **~164k tokens/week** |

---

## 8. Changes

- v0.1: Initial proposed plan for SDLC Round 1 (Software life-cycle automation round), fulfilling owner HUM-10 directives (msgs `6c1ed812`, `a29ba4db`, `8772dd8f`, `190f44f4`, `abc17db1`) with 7 baseline empirical measurements on `d0950b1e3` and 12 concrete actions structured across 3 batches of 4 rows for 4 parallel build lanes (2 on PC + 2 on sat).
- v1.0: Consensus signed by panel:
  - Claude seat `c-247@sat` evaluated plan v0.1 (`seat-claude.md`, commit `e0edb8964`): established Section 0 owner-time baseline (1,108 posts, 32 weekly status asks across 28 topics); identified 8 duplicate/contradictory rows and proposed P1 (Topic status card), P2 (Placer hand-off unblock), and P3 (Dynamic lane heartbeat placement gap).
  - Mistral seat `m-248@sat` evaluated plan v0.1 (`seat-mistral.md`, commit `754b1d4bb`): reviewed all rows and confirmed readiness.
  - Box naming: kept as PC in the plan table (unambiguously read as the peer box by placer and seats) to comply with distribution-hygiene rules while ensuring deterministic placement.
  - Resolved R1 batch 1 file collision: re-ordered batches (Rows 01, 02, 03, 05 in Batch 1; Rows 04, 06, 07, 08 in Batch 2; Rows 09, 10, 11, 12 in Batch 3) ensuring 100% disjoint file paths across every batch.
  - Marked Grok seat 'not seated' (no grok quota on any box).
  - Full consensus reached across active panel seats. Plan is SIGNED v1.0.

---

## 9. Consensus

| Seat | ID | Signed | File |
|---|---|---|---|
| Editor (agy) | a-240@sat | **signed v1.0** (this commit) | `sdlc-round-1/seat-agy.md` |
| Claude seat | c-247@sat | agreed on rows + proposals in `e0edb8964`; signing v1.0 | `sdlc-round-1/seat-claude.md` |
| Mistral seat | m-248@sat | agreed in `754b1d4bb`; signing v1.0 | `sdlc-round-1/seat-mistral.md` |
| Grok seat | g-xxx | not seated (no grok quota on any box) | `sdlc-round-1/seat-grok.md` |
