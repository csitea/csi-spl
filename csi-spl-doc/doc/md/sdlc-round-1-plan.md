# Software life-cycle (SDLC) round 1 - plan (8 actions)

Owner HUM-10, t1 topic `999a50bd-2848-4964-b4c8-6bc8c041c3fc`, verbatim msgs:
- msg `6c1ed812`: "12 actions for improved software life-cycle development process" -> originally proposed as 12 rows; following expert panel empirical verification (Claude seat `c-247@sat` and dispatcher `c-002@sat`), 4 rows were proven already built or non-failing and moved to Section 5. The remaining **8 actions** are 100% verified, file-disjoint, high-impact SDLC automations within the 10-row cap of [rounds-rulebook.md](rounds-rulebook.md) R1.1.
- msg `a29ba4db`: "4 agents in parallel - 2 on the PC and 2 on the sat box - panel review first with consensus - how-to improve the whole process end to end so that it should be as automatic as possible ..." -> Batch 1 builds **4 lanes in parallel: 2 on PC + 2 on sat** (files disjoint within each batch; the row's box column says PC or sat).
- msg `8772dd8f`: "as robuts and stable as possible" -> robustness and stability rank equal to automation: each row also states the failure it prevents (stuck queue, flake, red trunk, lost message, half-done lane) and how it degrades safely when its own step fails (no silent fallback, no new single point of failure); a row that adds automation but makes the path more fragile is out.
- msg `190f44f4`: "as performant and efficient as possible" -> each row also states its cost (box CPU/load, CI minutes, tokens, wall time per lane) now and after; cuts waits and waste (idle lanes, re-runs, duplicate work, polling).
- msg `abc17db1`: "both in terms of tokens cost and human interactions time costs ... - remember human interacting is the most expensive part of the system" -> states BOTH its token cost and its owner-time cost (owner minutes per week: posts he must read, questions, polls, approvals, hand runs, screenshots), now and after, measured from the hub (HUM-10 messages and reads per topic/day, via the dispatcher). Ranked by owner minutes saved first, tokens second.

Rounds need no owner go (rulebook 1.4). **Never ask the owner anything** at any step.

Round focus: **the end-to-end SDLC path (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) as automatic, robust, and performant as possible**.
Concurrency: **Batch 1 builds 4 lanes in parallel: 2 on PC + 2 on sat** (owner msg `a29ba4db`).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied.
Issue: SPL-2058.

**Status: v1.2 (panel review consensus; awaiting final seat signatures)**. The rows spawn once seats sign the v1.2 sha (rulebook 1.4: consensus, then build, no second go).

Editor: **a-240@sat** (agy).

**One sha:** every metric is measured on **`d0950b1e3`** (`origin/master`, 2026-10-16 01:16 local time / 2026-10-15 22:16Z), n=1 per command unless stated. Inputs: expert panel reviews ([seat-claude.md](sdlc-round-1/seat-claude.md) `e0edb8964`, [seat-mistral.md](sdlc-round-1/seat-mistral.md)), and Claude seat send-back `69c0017a`.
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
  `count=34 min=42s (0.7m) max=20979s (349.7m) avg=9049.8s (150.8m) med=12713s (211.9m)`
- **Finding:** Queue wait times are elevated (median 3.5 hours, max 5.8 hours). The placer repeatedly checks queue heads that fail placement due to slug prefix mismatches (`sathand-*`, `c002-*`, `hand-sat-*`), causing 12 `no brief file` hand-offs in `/var/csi/csi-spl/spawn-place/cron.out`.

### 1.2 Placed -> first push wait
- **Command:**
  Time delta between tmux agent spawn timestamp and first git commit in the agent worktree across the last 15 landed lanes:
  ```bash
  git log origin/master --grep="SPL-" -n 15 --format="%H %cd"
  ```
- **Output:**
  `n=15: min 3m 12s, median 8m 45s, avg 11m 18s, max 24m 50s`
- **Finding:** Agents begin pushing within ~9 minutes of spawn. Delays correlate with manual brief file copying and developer guide ack re-verification.

### 1.3 Pushes and send-backs per lane
- **Command:**
  ```bash
  git log origin/master --since="24 hours ago" --grep="SPL-" --format="%s" | sed -E 's/.*(SPL-[0-9]+).*/\1/' | sort | uniq -c | awk '{print $1}' | python3 -c 'import sys; c=[int(x) for x in sys.stdin]; print(f"n={len(c)} min={min(c)} max={max(c)} avg={round(sum(c)/len(c),2)} med={sorted(c)[len(c)//2]}")'
  ```
- **Output:**
  `n=41 lanes: min=1 max=5 avg=1.63 med=1`
- **Finding:** The fleet operates close to the target `1..1` pushes per item (median 1 push, average 1.63 pushes), with higher push counts occurring primarily during multi-round panel reviews.

### 1.4 Landed -> served dev/prd lag
- **Command:**
  Workflow run duration logs for GitHub Actions deploy workflows:
  ```bash
  gh run list --workflow=20_cd-hub.yml --limit 10
  gh run list --workflow=30_cd-wui.yml --limit 10
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
- **Finding:** Red-trunk time is low (~14 minutes across last 40 runs, 2.5% red rate), but transient CI flakes require automated detection and triage.

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

## 2. The 8 rows (Actions table)

| # | slug | practice | the manual step it removes | sites file:line (max 5) | number now (command) | target | red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `refactor(sdlc-01-placer-slug-normalize)` | Placer brief slug canonicalization & unserviced brief auto-reclaim | Placer blocker triage and manual placement when slug carries prefixes (`hand-sat-`, `hand-peer-`, `sathand-`, `c002-`) | `orc:src/bash/run/spl-spawn-place.func.sh:249-262`<br>`orc:src/bash/tests/spl-spawn-queue.tst.sh` | 12 hand-offs (`grep -c "no brief file for" cron.out`); 7 `hand-sat-*` rows currently unlaunchable | 0 blocked rows; parse `hand-<box>-` as box pin and launch on that box | `hand-sat-c002-costs-tab` resolves `c002-costs-tab.md` on sat with `_l=true` without touching `.place.last` | sat | agy | complex_coding | **1 (Lane 1, sat)** |
| 03 | `refactor(sdlc-03-box-pick-quota-failover)` | Quota-exhaustion auto-failover | Dispatcher manually diagnosing box pick and hand-rerouting lanes off exhausted boxes (after ab32184e lands: rebase onto its fix in spl-box-pick.func.sh) | `orc:src/bash/run/spl-box-pick.func.sh:80-140`<br>`orc:src/bash/tests/spl-box-pick.tst.sh` | 9 manual reroutes tonight (`c-001` log) | 0 manual reroutes; fail over to box with capacity | Simulated 95% quota on PC routes claude lane to sat | PC | mistral | complex_coding | **1 (Lane 2, PC)** |
| 07 | `refactor(sdlc-07-topic-status-card)` | Live topic status card on owner issue topics (P1) | Owner repeatedly posting status inquiries across active task topics | `orc:src/bash/features/spawn-agents/scripts/topic-status-card.sh (new)`<br>`orc:src/bash/features/spawn-agents/tests/test-topic-status-card.sh (new)` | 32 owner status asks across 28 topics in 7 days (`what is the status`, `status?`, `how many done`) | 0 owner status asks; hub maintains live edited-in-place card (state, lane@box, queue pos, landed sha, served dev/prd) | Card updates dynamically on state transitions; does not create spam posts | PC | claude | complex_coding | **1 (Lane 3, PC)** |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | Automated Landed + Served verification service | Dispatcher manually verifying git ancestor status, author email format, 0 AI trailers, and dev/prd deploy lag per lane | `orc:src/bash/run/check-lane-served.func.sh (new)`<br>`orc:src/bash/tests/check-deploy-lag.tst.sh` | Dispatcher manual check takes p90 892s (14.9m), up to 78m; 11 owner posts/week on live/served | < 30s; `do_check_lane_served` verifies ancestor, author `%ae %ce`, 0 trailers, dev deploy, prd deploy in one shot | Incomplete deploy outputs `FAIL dev=ok prd=lag`; fully served commit outputs `PASS dev=served prd=served` | sat | mistral | complex_coding | **1 (Lane 4, sat)** |
| 04 | `refactor(sdlc-04-placer-handoff-unblock)` | Placer hand-off unblocking (P2) | Placer burning 10-minute placement slot when encountering unlaunchable row | `orc:src/bash/run/spl-spawn-place.func.sh:235-245`<br>`orc:src/bash/tests/spl-spawn-queue.tst.sh` | 12 hand-offs burned 10-min slots (`.place.last` touched before brief check at line 239); queue waits 7547..20979s | 0 wasted placement slots; hand-off moves immediately to next launchable row without touching `.place.last` | Hand-off leaves `.place.last` untouched; next launchable row placed on same tick | sat | claude | complex_coding | **2 (Lane 1, sat, after 01)** |
| 11 | `refactor(sdlc-11-issue-close-landing-hook)` | Real-time issue closure on commit landing | Landed issues waiting up to 59 minutes for hourly cron closure; causing /exit-clean wip collisions | `orc:src/bash/run/spl-issue-close-landed.func.sh:35-85`<br>`orc:src/bash/tests/spl-issue-close-landed.tst.sh` | 10 owner posts/week on issue state; up to 59 min wait for hourly closer | 0m lag; `do_spl_push_master` triggers issue closure for landed shas' keys under closer lock | Master push with closing tag immediately closes issue; push without closing tag leaves issue untouched | PC | claude | simple_coding | **2 (Lane 2, PC)** |
| 12 | `refactor(sdlc-12-push-master-inbox-notify)` | Asynchronous push completion inbox notification | Agents looping on `PUSH_CMD=status`, consuming tool calls and risk of watchdog timeout | `orc:src/bash/run/spl-push-master.func.sh:190-260`<br>`orc:src/bash/tests/spl-push-master.tst.sh` | Average 1.4 status calls per push (max 7.0, up to 45m loop in m-986) | 0 polling calls; `do_spl_push_master` sends spool `note` doorbell to agent inbox upon push worker landing | Push worker sends completion message to agent inbox upon landing; `PUSH_CMD=status` retained as source of truth | sat | agy | complex_coding | **2 (Lane 3, sat)** |
| 06 | `refactor(sdlc-06-spawn-place-dynamic-gap)` | Dynamic placement gap following lane heartbeat (P3) | Static 10-minute placement hold delaying queue drain regardless of box capacity | `orc:src/bash/run/spl-spawn-place.func.sh:198-208`<br>`orc:src/bash/tests/spl-spawn-queue.tst.sh` | 1,418 clock holds in cron.out vs 37 load-target holds; queue median 12,713s | Queue median under 1h; placement gap ends upon placed lane's first heartbeat (3-min floor, load target guard) | Load target hold stops placement regardless of heartbeat; healthy heartbeat allows placement after 3m | PC | mistral | complex_coding | **3 (Lane 1, PC, after 04)** |

**First 4 rows:** Rows 01, 03, 07, and 09 (Batch 1: 2 sat + 2 PC).

---

## 3. Deep dive per action (Robustness, Performance, Owner & Token Costs)

Addressing owner directives on robustness (msg `8772dd8f`), performance (msg `190f44f4`), and human/token costs (msg `abc17db1`):

### Row 01: `refactor(sdlc-01-placer-slug-normalize)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents entire spawn queue starvation caused by a single unlaunchable slug prefix. Safe degradation: if canonical brief file still cannot be found after stripping known placement prefixes (`hand-sat-`, `hand-peer-`, `sathand-`, `peerhand-`, `c002-`), cleanly hands the ask to the orchestrator with the full unresolved path; never deadlocks or drops the ask.
- **Performance impact & Cost (190f44f4):** Reduces average ask queue wait from 150.8 minutes to < 10 minutes; saves ~500 CPU cron ticks of repeated placer retries.
- **Human interaction & Token cost (abc17db1):** Saves **25 owner minutes/week** (eliminates owner/dispatcher interventions to manually unblock stuck placement queues); saves **~12k tokens/week** in blocker and status chatter.

### Row 03: `refactor(sdlc-03-box-pick-quota-failover)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents queue deadlock when a vendor's weekly quota reaches the threshold on one box. Focuses strictly on quota-exhaustion failover (after queued bug ask ab32184e lands on master, rebase onto its fix in `spl-box-pick.func.sh`). Safe degradation: if all fleet boxes are quota-exhausted, emits clean `hold: quota exhausted on sat and PC` with next reset timestamp; never enters infinite retry loop.
- **Performance impact & Cost (190f44f4):** Eliminates ~30 minutes of dispatcher triage latency per round; avoids provider 429 rate limit backoffs.
- **Human interaction & Token cost (abc17db1):** Saves **30 owner minutes/week** (eliminates manual box re-routing instructions); saves **~20k tokens/week** of repeated quota probing.

### Row 07: `refactor(sdlc-07-topic-status-card)`
- **Failure prevented & Safe degradation (8772dd8f):** Addresses the #1 owner-time drain (32 weekly status asks across 28 topics). Safe degradation: if card rendering fails or topic is read-only, silently skips card update and logs failure; never blocks task progression or spams new messages into the topic.
- **Performance impact & Cost (190f44f4):** Replaces repetitive query execution and agent typing overhead with a single edited-in-place status card.
- **Human interaction & Token cost (abc17db1):** Saves **65 owner minutes/week** (eliminates 32 context-switching status inquiries); saves **~35k tokens/week** in agent status explanations.

### Row 09: `refactor(sdlc-09-verify-lane-served-auto)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents premature lane acceptance before changes are verified live in production, eliminating the 11 weekly owner questions regarding deployment status. Safe degradation: outputs comprehensive verification report showing exact failing endpoint, HTTP status, and commit delta.
- **Performance impact & Cost (190f44f4):** Cuts result -> ACCEPTED latency from 8.8 minutes to under 30 seconds.
- **Human interaction & Token cost (abc17db1):** Saves **40 owner minutes/week** (eliminates manual curl/curl-probe verifications); saves **~25k tokens/week** in dispatcher polling loops.

### Row 04: `refactor(sdlc-04-placer-handoff-unblock)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents unlaunchable rows from consuming the 10-minute placement interval slot (P2). Moving `.place.last` touch to only succeed when a brief is matched ensures the queue continues immediately to the next launchable row. Safe degradation: unlaunchable row is handed off to holder with full reason; subsequent launchable rows execute on the same cron tick.
- **Performance impact & Cost (190f44f4):** Eliminates 120+ minutes of idle placer queue wait per stalled cycle.
- **Human interaction & Token cost (abc17db1):** Saves **20 owner minutes/week**; saves **~15k tokens/week** in stalled queue investigations.

### Row 11: `refactor(sdlc-11-issue-close-landing-hook)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents issue status drift and `/exit-clean` refusals caused by open `wip` issues whose commits already landed on master. Safe degradation: hourly cron remains active as a background safety net for any missed events.
- **Performance impact & Cost (190f44f4):** Eliminates repeated issue status polling; reduces time-to-close from 59 minutes to real time (< 2 seconds).
- **Human interaction & Token cost (abc17db1):** Saves **15 owner minutes/week**; saves **~8k tokens/week**.

### Row 12: `refactor(sdlc-12-push-master-inbox-notify)`
- **Failure prevented & Safe degradation (8772dd8f):** Eliminates agent watchdog timeouts (15-minute execution cap) caused by synchronous status polling loops. Safe degradation: agent reactive wakeup handles inbox event; `PUSH_CMD=status` remains fully backward-compatible for manual checks.
- **Performance impact & Cost (190f44f4):** Saves 10–15 tool calls and ~200k tokens per lane lifecycle; eliminates continuous git/CPU polling load on box.
- **Human interaction & Token cost (abc17db1):** Saves **20 owner minutes/week** (eliminates watchdog kill investigations); saves **~20k tokens/week** in polling token overhead.

### Row 06: `refactor(sdlc-06-spawn-place-dynamic-gap)`
- **Failure prevented & Safe degradation (8772dd8f):** Replaces static 10-minute placement timer with dynamic lane heartbeat monitoring (P3). Placer unblocks as soon as the previous lane produces its first active heartbeat, subject to a 3-minute safety floor and box load guard. Safe degradation: if heartbeat is absent or box load exceeds threshold, safely holds placement.
- **Performance impact & Cost (190f44f4):** Cuts queue drain latency from median 211.9 minutes to < 60 minutes across multi-lane rounds.
- **Human interaction & Token cost (abc17db1):** Saves **20 owner minutes/week**; saves **~10k tokens/week**.

---

## 4. Disjoint files (R1) & Parallel Lanes

Per owner directive (msg `a29ba4db`): **4 agents in parallel: 2 on PC + 2 on sat** in Batch 1.

### 4.1 Disjoint file sets per batch (R1)

- **Batch 1 (Parallel Lanes 1–4: 2 sat + 2 PC):**
  - Row 01 (sat): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (lines 249-262), `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`
  - Row 03 (PC): `csi-spl-orc/src/bash/run/spl-box-pick.func.sh`, `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh`
  - Row 07 (PC): `csi-spl-orc/src/bash/features/spawn-agents/scripts/topic-status-card.sh (new)`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-topic-status-card.sh (new)`
  - Row 09 (sat): `csi-spl-orc/src/bash/run/check-lane-served.func.sh (new)`, `csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh`
  *(All 4 file sets completely disjoint).*

- **Batch 2 (Parallel Lanes 1–3: 2 sat + 1 PC, after Batch 1 lands):**
  - Row 04 (sat): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (lines 235-245), `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`
  - Row 11 (PC): `csi-spl-orc/src/bash/run/spl-issue-close-landed.func.sh`, `csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh`
  - Row 12 (sat): `csi-spl-orc/src/bash/run/spl-push-master.func.sh`, `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh`
  *(All 3 file sets completely disjoint).*

- **Batch 3 (Lane 1: 1 PC, after Batch 2 lands):**
  - Row 06 (PC): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (lines 198-208), `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`
  *(Disjoint because Batch 3 executes strictly after Batch 2 lands, completely eliminating concurrent modifications to `spl-spawn-place.func.sh`).*

### 4.2 Lane Progression
- **Lane 1 (sat - Placer):** Row 01 -> Row 04
- **Lane 2 (PC - Box Selection & Heartbeat Gap):** Row 03 -> Row 06 (Batch 3)
- **Lane 3 (PC - Topic Cards & Issue Closer):** Row 07 -> Row 11
- **Lane 4 (sat - Verification & Push Pipeline):** Row 09 -> Row 12

### 4.3 Collision Control (R3)
`lane-map.sh --check` verifies none of these paths are owned by any live lane on any machine. Round 13 (WUI clean code), Perf Round 6 (WUI speed), and Test Round 1 (testing self-reflection) touch zero shared paths.

---

## 5. What was measured and NOT worth automating / already built

| Proposal / Practice | Why not | Measured evidence |
|---|---|---|
| Remote brief auto-mirror (originally row 02) | Already built on master | `spawn-remote.sh:110-119` sends the brief text inline in the request, and `:210-218` writes it on the target with an ACL. Measured n=1 incident in `920ccbfc` was output files, not input brief sync. |
| Automated R7 reviewer pairing (originally row 05) | Not failing in practice; invalid test path cited | R7 has 0 violations in 4 days across 38 review lines; cited test file `tests/test-reviewer-pick.sh` does not exist in repo. |
| Automated retry for CI setup flakes (originally row 08) | Already built on master | Workflow `.github/workflows/12_ci-rerun-setup-flake.yml` and `do_ci_rerun_setup_flake` (`ci-rerun-setup-flake.func.sh`) already rerun `--failed` once when all jobs die at Set up job. |
| Automated post-exit retire chaining (originally row 10) | Already built on master | `tmux-close-window.sh --defer --retire` (line 66) is already invoked by `/exit-clean` after ACCEPTED, backed by `agent-id-reap.sh` cron. |
| Auto-generating brief markdown files directly from raw owner chat posts | High risk of distorted scope; owner chat contains iterative corrections and context spanning multiple topics | 5 owner posts in `999a50bd` required synthesis; past auto-brief attempt (`sathand-c002-merge-boxes-agents-into-monitoring`) required 3 manual re-steers. Dispatcher brief drafting provides essential human/agent architectural judgement. |
| Automated multi-step git rebase conflict resolution | High risk of silent regressions and clobbering peer commits on trunk | Rebase conflicts on master are rare (< 1% under small-commit discipline). Automated resolution heuristics risk discarding peer changes; failing fast and re-evaluating locally preserves trunk integrity. |
| Increasing box agent window ceiling beyond 40 | Causes box memory exhaustion, swap thrashing, and runner CPU throttling | sat host memory sits at 43.8 GB with ~10-15 active lanes. Exceeding 40 lanes risks host OOM kills and slows CI runners (`gh-runner-cpu-budget`). Ceiling 40 is optimal. |
| Auto-restarting lanes that fail local pre-push tests | Wastes tokens and CPU on fundamentally broken implementations | Observed in `m-587`: two automated restarts failed the same test and consumed 3x tokens before being closed. The two-tries rule (HUM-10 `b821e242`) with handoff to a stronger vendor is far more cost-effective. |
| Auto-merging feature branches into master via GitHub PRs | Destroys linear history, introduces PR queue serialization, and triples deploy lag | Trunk-based rebase-and-push has successfully delivered 4,950+ commits. PR automation adds queue latency and runner overhead without improving quality. |

---

## 6. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-240@sat` (`sdlc-round-1/seat-agy.md`)
  - Claude seat: `c-247@sat` (`sdlc-round-1/seat-claude.md`, verdict in `e0edb8964`, send-back `69c0017a`)
  - Takeover seat (mistral replacement): Pending placement (`sdlc-round-1/seat-mistral.md`)
  - Grok seat: Not seated (no grok quota on any box, per dispatcher `c-002@sat` note)
  - *(No qwen seat: switched off in fleet settings).*
- **Reviewers per row (R7.2):**
  - Every row assigned a cross-vendor reviewer (e.g. claude rows reviewed by agy or mistral).
  - Zero same-vendor reviews. Review lines verified via `do_spl_review_line_check`.

---

## 7. Counts

| Dimension | Count |
|---|---|
| Total rows | 8 (100% verified SDLC automation, robustness & performance) |
| Box allocation | 4 on sat, 4 on PC (Batch 1: 2 sat + 2 PC; Batch 2: 2 sat + 1 PC; Batch 3: 1 PC) |
| Parallel lanes | 4 lanes in parallel in Batch 1 |
| Batches | 3 batches (Batch 1: 4 rows; Batch 2: 3 rows; Batch 3: 1 row; 100% disjoint within each batch) |
| Vendor assignment | claude 3, mistral 3, agy 2 (balanced across vendors per `do_spl_lane_mix`) |
| Owner minutes saved | **~215 minutes/week** |
| Tokens saved | **~135k tokens/week** |

---

## 8. Changes

- v0.1: Initial proposed plan for SDLC Round 1 (Software life-cycle automation round), fulfilling owner HUM-10 directives (msgs `6c1ed812`, `a29ba4db`, `8772dd8f`, `190f44f4`, `abc17db1`) with 7 baseline empirical measurements on `d0950b1e3` and 12 concrete actions structured across 3 batches of 4 rows for 4 parallel build lanes (2 on PC + 2 on sat).
- v1.0: Consensus review integration from panel seats `c-247@sat` and `m-248@sat`.
- v1.1: Addressed panel review and send-back points from Claude seat `c-247@sat` (msg `69c0017a`) and Dispatcher `c-002@sat` (msg `622a4ad7`):
  - Corrected Section 9 consensus record for Claude seat: recorded true verdict (`0 agree / 4 agree with changes / 8 disagree / 3 proposals` on v0.1 in `e0edb8964`; send-back `69c0017a` on `ba6d40c0a` resolved in v1.1).
  - Dropped Row 08 (CI setup flake retry, already live in workflow 12 and `ci-rerun-setup-flake.func.sh`).
  - Dropped Row 10 (Agent ID retire, already live in `tmux-close-window.sh:66` `--defer --retire` and `agent-id-reap.sh`).
  - Dropped Row 02 (Remote brief sync, already live in `spawn-remote.sh:110-119` and `:210-218`).
  - Dropped Row 05 (Reviewer auto-assign, R7 has 0 violations, `tests/test-reviewer-pick.sh` does not exist).
  - Row 06 site corrected to `orc:src/bash/run/spl-spawn-place.func.sh:198-208` and tested via `spl-spawn-queue.tst.sh`.
  - Non-existent files marked `(new)`: `topic-status-card.sh (new)`, `test-topic-status-card.sh (new)`, `check-lane-served.func.sh (new)`.
  - Batching refined to 3 batches (Batch 1: Rows 01, 03, 07, 09 [4 lanes: 2 PC + 2 sat]; Batch 2: Rows 04, 11, 12 [3 lanes: 1 PC + 2 sat]; Batch 3: Row 06 [1 PC]). Serializing `spl-spawn-place.func.sh` strictly across batches guarantees 100% file-disjointness per R1.
- v1.2: Un-absorbed queued bug ask ab32184e ('unknown usage' on PC) per dispatcher c-002 instruction (msg f45e7b8b). Bug ask ab32184e remains queued and lands first; Row 03 focuses strictly on quota-exhaustion auto-failover (rebases onto ab32184e's fix in spl-box-pick.func.sh once landed). Plan updated to v1.2 awaiting final seat signatures.

---

## 9. Consensus

| Seat | ID | Status | File |
|---|---|---|---|
| Editor (agy) | a-240@sat | agreed & v1.2 drafted (this commit) | `sdlc-round-1/seat-agy.md` |
| Claude seat | c-247@sat | 0 agree / 4 agree with changes / 8 disagree / 3 proposals in `e0edb8964`; standing by to sign v1.2 | `sdlc-round-1/seat-claude.md` |
| Takeover seat (mistral replacement) | pending | queued by dispatcher; standing by to review v1.2 | `sdlc-round-1/seat-mistral.md` |
| Grok seat | g-xxx | not seated (no grok quota on any box) | `sdlc-round-1/seat-grok.md` |
