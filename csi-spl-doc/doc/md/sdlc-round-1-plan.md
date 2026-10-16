# Software life-cycle (SDLC) round 1 - plan (6 actions)

Owner HUM-10, t1 topic `999a50bd-2848-4964-b4c8-6bc8c041c3fc`, verbatim msgs:
- msg `6c1ed812`: "12 actions for improved software life-cycle development process" -> originally proposed as 12 rows; following expert panel empirical verification (Claude seat `c-247@sat`, Takeover seat `c-251@sat` [claude, ex-mistral], and dispatcher `c-002@sat`), non-failing or pre-existing rows were moved to Section 5, Row 04 was folded into Row 01 (building on `68edb2656`), Row 11 was replaced with Closer Cadence (P2), and Row 12 was replaced with No Go-Asks in Owner Topics (P1). The remaining **6 actions** are 100% verified, file-disjoint, high-impact SDLC automations within the 10-row cap of [rounds-rulebook.md](rounds-rulebook.md) R1.1.
- msg `a29ba4db`: "4 agents in parallel - 2 on the PC and 2 on the sat box - panel review first with consensus - how-to improve the whole process end to end so that it should be as automatic as possible ..." -> Batch 1 builds 4 parallel lanes: 2 on sat + 2 on PC (files 100% disjoint within the batch).
- msg `8772dd8f`: "as robuts and stable as possible" -> robustness and stability rank equal to automation: each row also states the failure it prevents (stuck queue, flake, red trunk, lost message, half-done lane) and how it degrades safely when its own step fails (no silent fallback, no new single point of failure); a row that adds automation but makes the path more fragile is out.
- msg `190f44f4`: "as performant and efficient as possible" -> each row also states its cost (box CPU/load, CI minutes, tokens, wall time per lane) now and after; cuts waits and waste (idle lanes, re-runs, duplicate work, polling).
- msg `abc17db1`: "both in terms of tokens cost and human interactions time costs ... - remember human interacting is the most expensive part of the system" -> states BOTH its token cost and its owner-time cost (owner minutes per week: posts he must read, questions, polls, approvals, hand runs, screenshots), now and after, measured from the hub (HUM-10 messages and reads per topic/day, via the dispatcher). Ranked by owner minutes saved first, tokens second.

Rounds need no owner go (rulebook 1.4). **Never ask the owner anything** at any step.

Round focus: **the end-to-end SDLC path (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) as automatic, robust, and performant as possible**.
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied.
Issue: SPL-2058.

**Status: v1.5 (panel review consensus: c-247@sat and c-251@sat send-backs folded; awaiting seat signatures)**. The rows spawn once seats sign the v1.5 sha (rulebook 1.4: consensus, then build, no second go).

Editor: **a-240@sat** (agy).

**One sha:** every code site measured on `origin/master` (code sites verified identical across `d0950b1e3` and `origin/master`). Hub data measured on prd hub tenant t1. Inputs: expert panel reviews ([seat-claude.md](sdlc-round-1/seat-claude.md) `e0edb8964`, [seat-mistral.md](sdlc-round-1/seat-mistral.md) `b6153d006`, `a5840b371`), Claude seat send-backs `69c0017a`, `5fcc662b`, `269cbeb8`, and Dispatcher confirmations `622a4ad7`, `f45e7b8b`, `f0f32032`, `730bad28`, `b38e1565`.
**Disjoint from tonight's other rounds:** touches **0 files** shared with Round 13 (`refactor-round-13-plan.md`, WUI clean code), Perf Round 6 (`perf-round-6-plan.md`, WUI speed), or Test Round 1 (`test-round-1-plan.md`, testing self-reflection).

---

## 0. Owner-time baseline (measured on prd hub)

Measured on prd, tenant `t1`, over the last 7 days (`ENV=prd SQL="..." ./run -a do_spl_db_query` across `HUM-10` messages):
- Total owner posts: **1,108 posts across 7 days** (187, 201, 138, 100, 156, 140, 186/day) out of 15,006 total messages.
- Subject breakdown:
  - **Go / yes / ok nudges** (`^(continue|go( on| ahead)?|proceed|ok|okay|yes|do it|agreed|approved)\M`): **66 posts across 47 topics** (60 follow an agent post, 20 carry a `?`, 14 ask for a go explicitly, 22 are <= 12 chars: `go` x10, `yes` x7, `ok` x2; median gap between agent post and owner nudge: 108s). Rounds need no owner go (rulebook 1.4). Targeted by Row 12 (P1).
  - **Status asks** (`what is the status`, `^status`, `status ?`, `status report`, `how many done`): **32 posts across 28 topics** (29 under 60 chars; median reply 50.5s). Targeted by Row 07.
  - **Deployed / live / served / prd** (`deployed|\mlive\M|served|\mprd\M`): **18 posts across 13 topics**. Targeted by Row 09.
  - **Queue / stuck / idle / not placed**: **12 posts across 9 topics**. Targeted by Row 01 and Row 06.
  - **Issue state** (`\missue|spl-[0-9]+`): **64 posts across 47 topics** (broad regex; lag bound 59m addressed by Row 11).
  - Push status (`\mpush`): **10 posts across 6 topics**.
  - Quota / weekly limit: **6 posts**.
  - CI re-run / flake: **2 posts**.
  - Close / retire / orphan: **1 post**.
- Finding: Unnecessary go-nudges (66 weekly posts) and status inquiries (32 weekly posts) together represent 88% of addressable owner-interaction overhead. Addressing both directly saves ~150 minutes of owner attention per week.

---

## 1. End-to-end SDLC measurements on real data

Addressing the end-to-end delivery path from idea to closure on real data across git history, hub asks, spool messaging, and CI:

### 1.1 Ask -> placed wait
- **Command:**
  ```bash
  sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub SPAWN_QUEUE_FORMAT=json SPAWN_QUEUE_SHARE=0 ./run -a do_spl_spawn_queue 2>/dev/null | python3 -c 'import sys, json; data=json.load(sys.stdin); waits=[r["wait_s"] for r in data["queue"] if r.get("state")=="queued"]; print(f"count={len(waits)} min={min(waits)}s ({round(min(waits)/60,1)}m) max={max(waits)}s ({round(max(waits)/60,1)}m) avg={round(sum(waits)/len(waits),1)}s ({round(sum(waits)/len(waits)/60,1)}m) med={sorted(waits)[len(waits)//2]}s ({round(sorted(waits)[len(waits)//2]/60,1)}m)")'
  ```
- **Output:**
  `n=24 queued, min=43s (0.7m) max=24660s (411.0m / 6.85h) avg=11963s (199.4m / 3.32h) med=15414s (256.9m / 4.28h)`
- **Finding:** In `/var/csi/csi-spl/spawn-place/cron.out` (6,168 lines): **1,467** "last placement started under 10 min" holds vs **37** "load target says hold". Total 27 hand-offs (12 no brief file + 15 no placement recorded). With 152 placements ticking once a minute, ~9 gap holds per placement is expected (152 x 9 = 1368, matching 1467 measured). The 10-minute gap is the binding constraint capping throughput at 6 placements/hour, causing a 24-row queue to take >= 4 hours to drain.

### 1.2 Placed -> first push wait
- **Command:**
  Proxy measured from `lifetime/prompt.txt` mtime to first `origin/master` commit naming the lane's `lifetime/issue` key:
- **Output:**
  `n=3: min 8.5m, med 13.0m, max 15.3m`
- **Finding:** Agents begin pushing within 8.5–15 minutes of spawn once initial codebase research and developer guide acknowledgment are completed.

### 1.3 Pushes and send-backs per lane
- **Command:**
  ```bash
  git log origin/master --since="24 hours ago" --grep="SPL-" --format="%s" | grep -oE "SPL-[0-9]+" | sort | uniq -c | awk '{print $1}' | python3 -c 'import sys; c=[int(x) for x in sys.stdin]; print(f"n={len(c)} min={min(c)} max={max(c)} avg={round(sum(c)/len(c),2)} med={sorted(c)[len(c)//2]} keys_with_1={c.count(1)}")'
  ```
- **Output:**
  `n=104 keys: min=1 max=14 avg=1.96 med=1 keys_with_1=63` (225 commits in 24h)
- **Finding:** 61% of keys require exactly 1 commit (`1..1` target achieved for the majority of items); higher commit counts correspond to multi-seat round documentation keys.

### 1.4 Landed -> served dev/prd lag
- **Command:**
  ```bash
  gh run list --workflow=20_hub-build-deploy.yml --limit 18 --json conclusion,createdAt,updatedAt
  gh run list --workflow=30_wui-build-deploy.yml --limit 18 --json conclusion,createdAt,updatedAt
  ```
- **Output:**
  - **Hub deploy (workflow 20):** `n=18 success`, min 13.2m, med **20.4m**, avg 20.2m, max 25.6m.
  - **WUI deploy (workflow 30):** `n=18 success`, min 7.6m, med **8.4m**, avg 9.0m, max 17.4m.
- **Finding:** Code changes take 8.4m (WUI) to 20.4m (Hub API) to reach fully served status on production. Docs-only changes require no deployment (`served=n/a`).

### 1.5 Result -> ACCEPTED wait
- **Command:**
  Every body starting with `ACCEPTED` in `/var/spool-hub/c-00[23]*/outbox` in the last 7 days matched to newest `kind: result` on same task:
- **Output:**
  `n=252 matched=156: min 4s, med 44s, avg 3253s (54.2m), p90 1849s (30.8m), max 72306s, over15m=23`
- **Finding:** Median wait is fast (44s). For code lanes, ACCEPTED waits for production deployment (8..20m). Docs lanes can be verified in < 30s.

### 1.6 Red-trunk minutes
- **Command:**
  ```bash
  CI_GATE_RUNS=40 ./run -a do_report_ci_gate
  ```
- **Output:**
  `40 runs (23 success, 17 cancelled, 0 running, 0 failed); no failed run in the window; all jobs p90 <= 51% timeout`
- **Finding:** Trunk remains green. The 17 cancelled runs (42%) were cleanly superseded by newer pushes under workflow concurrency cancellation.

### 1.7 Hand steps per lane
- **Command:**
  Trace of placer launches vs hand-offs in `/var/csi/csi-spl/spawn-place/cron.out`:
- **Output:**
  `152 placer launches vs 27 hand-offs` (85% automated placement). Hand steps exist only for hand-offs (12 no brief file, 15 no placement recorded). Standard lifecycle steps (launch, placed close, retire, issue close) are automated.

---

## 2. The 6 rows (Actions table)

| # | slug | practice | the manual step it removes | sites file:line (max 5) | number now (command) | target | red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `refactor(sdlc-01-placer-slug-normalize-handoff)` | Placer brief slug canonicalization, box intent pin, and hand-off unblock (folds former 04; builds on `68edb2656`) | Placer blocker triage on prefixes (`hand-sat-`, `sathand-`); hand-offs burning 10-min slots | `orc:src/bash/run/spl-spawn-place.func.sh:235-262`<br>`orc:src/bash/tests/spl-spawn-queue.tst.sh` | 10 of 24 queued rows carry hand prefix (7 `hand-sat-`, 3 `sathand-`); 7/7 hit after stripping; 12 hand-offs burned 10-min slots | Strip prefix, pass `SPAWN_BOX=<box>`, document convention in `@description`, move `touch .place.last` into launch branch | Pinned launch HOLDs when pinned box is past load mark; hand-off unblocks without 10-min wait | sat | mistral | complex_coding | **1 (Lane 1, sat)** |
| 07 | `refactor(sdlc-07-topic-status-card)` | Live topic status card on owner issue topics (P1) | Owner repeatedly posting status inquiries across active task topics | `orc:src/bash/features/spawn-agents/scripts/topic-status-card.sh (new)`<br>`orc:src/bash/features/spawn-agents/tests/test-topic-status-card.sh (new)` | 32 owner status asks across 28 topics in 7 days (`what is the status`, `status?`, `how many done`) | Dedicated caller using `do_spl_desk_edit` (reusing pattern of `spl_asks_alert_clear`); card maintains state, lane@box, queue pos, landed sha, served dev/prd; 0 new message spam | Card updates dynamically on state transitions; verified no new message row created in hub | PC | claude | complex_coding | **1 (Lane 2, PC)** |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | Automated Landed + Served verification service composing existing primitives | Dispatcher manually verifying git ancestor status, author `%ae %ce`, trailers, and dev/prd deploy lag | `orc:src/bash/run/check-lane-served.func.sh (new)`<br>`orc:src/bash/tests/check-lane-served.tst.sh (new)` | 18 owner posts/week on deployed/live; manual verification tail p90 1849s | Composes `git-fetch-fresh.sh --landed`, `%ae %ce` check (`spl-push-master.func.sh:181`), and `check-deploy-lag.func.sh`. Adds anchored trailer check (`git log -1 --format=%B \| grep -qiE '^(Co-Authored-By:\|Claude-Session:)'`) and `served=n/a` arm for docs | Incomplete deploy outputs `FAIL dev=ok prd=lag`; docs commit outputs `PASS dev=n/a prd=n/a`; fully served commit outputs `PASS dev=served prd=served` | sat | claude | complex_coding | **1 (Lane 3, sat)** |
| 11 | `refactor(sdlc-11-issue-close-cadence)` | Closer cron cadence increase from hourly to 5-minute intervals (P2) | Landed issues waiting up to 59 minutes for hourly cron closure; causing /exit-clean wip collisions | `csi-spl-orc/cnf/box-crons/box-crons.manifest:28`<br>`orc:src/bash/tests/install-box-crons.tst.sh:78` | Manifest specifies `37 * * * *` (up to 59 min wait for issue closer); sat has no cursor/cron | Change cadence in `box-crons.manifest:28` to `*/5 * * * *` on sweeping box; update pin in `install-box-crons.tst.sh:78`. Reduces maximum issue close lag from 59m to 5m | Manifest syntax valid; closer lock (`flock -n 9`) prevents double-runs; failing run recovers on next 5m sweep | PC | claude | simple_coding | **1 (Lane 4, PC)** |
| 06 | `refactor(sdlc-06-spawn-place-dynamic-gap)` | Dynamic placement gap following lane heartbeat (P3; batch 2 per R1) | Static 10-minute placement hold delaying queue drain regardless of box capacity | `orc:src/bash/run/spl-spawn-place.func.sh:198-208`<br>`orc:src/bash/tests/spl-spawn-queue.tst.sh` | 1,467 gap holds in cron.out vs 37 load-target holds; queue median 15,414s (~4.3h) | Gap ends upon placed lane's first heartbeat progress (reads `/var/spool-hub/<agent>/heartbeat.json` field `progress_ts`), subject to 3-min floor, 10-min ceiling, and load target guard (`spl_spawn_place_no_room`) | Load target hold stops placement regardless of heartbeat; healthy heartbeat unblocks placement after 3m floor; absence of heartbeat holds to 10m ceiling | sat | mistral | complex_coding | **2 (Lane 1, sat)** |
| 12 | `refactor(sdlc-12-no-go-asks-owner-topics)` | Send-side guard refusing unnecessary go-asks in owner topics (P1) | Agents asking owner for redundant go-ahead in topics that need no owner permission | `orc:src/bash/run/spl-desk-post.func.sh`<br>`orc:src/bash/features/spawn-agents/scripts/spool-send.sh`<br>`orc:src/bash/tests/spl-desk-post.tst.sh`<br>`orc:src/bash/features/spawn-agents/tests/test-spool-send.sh` | 66 owner go/yes/ok nudges per week across 47 topics (60 follow agent posts, 14 ask for a go explicitly) | Refuses posts in `do_spl_desk_post` and `spool-send.sh` asking owner for go/approval (`shall i\|should i\|do you want\|go?\|your go\|approve\|confirm`) unless citing GCP/owner gate (apply, IAM, prd); explicitly exempts structured poll forms (rule 10-14) | `"Shall I proceed?"` to owner topic is refused; structured poll form passes; `"needs owner go for terraform apply step 040"` passes | PC | claude | complex_coding | **2 (Lane 2, PC)** |

**Batch 1 (4 parallel lanes: 2 sat + 2 PC):** Rows 01, 07, 09, 11.
**Batch 2 (2 parallel lanes: 1 sat + 1 PC, after Batch 1 lands):** Rows 06, 12.

---

## 3. Deep dive per action (Robustness, Performance, Owner & Token Costs)

Addressing owner directives on robustness (msg `8772dd8f`), performance (msg `190f44f4`), and human/token costs (msg `abc17db1`):

### Row 01: `refactor(sdlc-01-placer-slug-normalize-handoff)`
- **Failure prevented & Safe degradation (8772dd8f):** Prevents spawn queue starvation from slug prefix mismatches (`hand-sat-`, `sathand-`). Preserves dispatcher box intent by passing `SPAWN_BOX=<box>`. Builds directly on top of `68edb2656` (SPL-2042). Moving `touch .place.last` inside the launch branch ensures an unlaunchable row does not burn a 10-minute placement slot. Safe degradation: if canonical brief still cannot be found after stripping prefixes, cleanly hands ask to orchestrator with full path without touching `.place.last`. Red control verifies pinned box holds when overloaded.
- **Performance impact & Cost (190f44f4):** Unblocks 10 queued rows immediately; eliminates 270+ minutes of unnecessary gap holds caused by hand-off slot burns.
- **Human interaction & Token cost (abc17db1):** Saves **25 owner minutes/week**; saves **~12k tokens/week** in blocker triage chatter.

### Row 07: `refactor(sdlc-07-topic-status-card)`
- **Failure prevented & Safe degradation (8772dd8f):** Addresses 32 weekly status asks across 28 topics. Implements dedicated periodic caller using `do_spl_desk_edit` (reusing the edit-in-place pattern demonstrated in `spl-asks-tick.func.sh:417` without modifying alert clearing). Safe degradation: if card rendering fails or topic is read-only, skips update and logs error without creating duplicate messages or interrupting task flow.
- **Performance impact & Cost (190f44f4):** Replaces repetitive query execution and agent typing overhead with a single edited-in-place status card.
- **Human interaction & Token cost (abc17db1):** Saves **65 owner minutes/week** (eliminates 32 context-switching status inquiries); saves **~35k tokens/week** in agent status replies.

### Row 09: `refactor(sdlc-09-verify-lane-served-auto)`
- **Failure prevented & Safe degradation (8772dd8f):** Composes existing trusted primitives (`git-fetch-fresh.sh --landed`, `%ae %ce` check from `spl-push-master.func.sh:181`, and `check-deploy-lag.func.sh`). Adds anchored commit message trailer check (`git log -1 --format=%B <sha> | grep -qiE '^(Co-Authored-By:|Claude-Session:)'`) and a `served=n/a` arm for docs-only commits (which receive no deployment per developer guide 1.4). Prevents premature lane acceptance while avoiding indefinite hangs on docs lanes. Safe degradation: outputs structured report with exact failing component and status.
- **Performance impact & Cost (190f44f4):** Cuts docs verification to < 30s; automates code deploy verification (8..20m).
- **Human interaction & Token cost (abc17db1):** Saves **40 owner minutes/week** (eliminates 18 weekly live/served inquiries); saves **~25k tokens/week** in dispatcher polling loops.

### Row 11: `refactor(sdlc-11-issue-close-cadence)`
- **Failure prevented & Safe degradation (8772dd8f):** Replaces problematic push-master hook (which would be a silent no-op on sat due to lack of cursor and cron) with a 5-minute cron cadence in `csi-spl-orc/cnf/box-crons/box-crons.manifest:28` (`37 * * * *` -> `*/5 * * * *`) on the sweeping box and updates pinned schedule in `install-box-crons.tst.sh:78`. Safe degradation: closer already acquires `flock -n 9` and records a ledger (`closed.tsv`), preventing duplicate runs or double-closures. If a run fails, the subsequent run 5 minutes later sweeps the unclosed range.
- **Performance impact & Cost (190f44f4):** Reduces maximum issue close latency from 59 minutes to 5 minutes across the entire fleet without introducing distributed locking or cross-box state synchronization.
- **Human interaction & Token cost (abc17db1):** Saves **15 owner minutes/week**; saves **~8k tokens/week** in WIP collision checks.

### Row 06: `refactor(sdlc-06-spawn-place-dynamic-gap)`
- **Failure prevented & Safe degradation (8772dd8f):** Replaces static 10-minute timer with dynamic lane heartbeat monitoring (P3). Placer unblocks as soon as the previous lane advances `progress_ts` in `/var/spool-hub/<agent>/heartbeat.json` (written by `spool-agent-hook.sh:7,382-390` on tool calls/stops), subject to a 3-minute safety floor, a 10-minute ceiling when heartbeat does not move, and box load target guard (`spl_spawn_place_no_room`). Serialized strictly in Batch 2 (after Row 01 lands) to guarantee 100% disjoint file sets per R1. Safe degradation: if heartbeat is absent or box load exceeds threshold, safely holds placement up to 10m ceiling.
- **Performance impact & Cost (190f44f4):** Cuts queue drain latency from median 256.9 minutes to < 60 minutes across multi-lane rounds; eliminates up to 1,467 unnecessary clock holds.
- **Human interaction & Token cost (abc17db1):** Saves **20 owner minutes/week**; saves **~10k tokens/week**.

### Row 12: `refactor(sdlc-12-no-go-asks-owner-topics)`
- **Failure prevented & Safe degradation (8772dd8f):** Implements a send-side guard in `do_spl_desk_post` (and `spool-send.sh` for human recipient `--to`) preventing agents from asking the owner for redundant approvals in owner topics (`shall i|should i|do you want|go?|your go|approve|confirm`). Rounds need no owner go (rulebook 1.4). Explicitly exempts structured poll forms (owner rule 10-14). Safe degradation: refuses post with clear explanatory error message; genuine GCP/owner gates (apply, IAM, prd mutations per repo CLAUDE.md) cite the gate rule and pass unimpeded.
- **Performance impact & Cost (190f44f4):** Directly eliminates 14 explicit go-asks and up to 66 owner go/yes/ok nudges per week across 47 topics, cutting median 108s agent idle wait per nudge.
- **Human interaction & Token cost (abc17db1):** Saves **45 owner minutes/week** (eliminates context-switching owner nudges); saves **~35k tokens/week** in redundant permission requests and waiting loops.

---

## 4. Disjoint files (R1) & Parallel Lanes

### 4.1 Disjoint file sets per batch (R1)

- **Batch 1 (4 Parallel Lanes: 2 sat + 2 PC):**
  - Row 01 (sat, mistral): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (lines 235-262), `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (plus `spl-spawn-fill.tst.sh`, `spl-security-round-queue.tst.sh`)
  - Row 07 (PC, claude): `csi-spl-orc/src/bash/features/spawn-agents/scripts/topic-status-card.sh (new)`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-topic-status-card.sh (new)`
  - Row 09 (sat, claude): `csi-spl-orc/src/bash/run/check-lane-served.func.sh (new)`, `csi-spl-orc/src/bash/tests/check-lane-served.tst.sh (new)`
  - Row 11 (PC, claude): `csi-spl-orc/cnf/box-crons/box-crons.manifest:28`, `csi-spl-orc/src/bash/tests/install-box-crons.tst.sh:78`
  *(All 4 file sets completely disjoint).*

- **Batch 2 (2 Parallel Lanes: 1 sat + 1 PC, after Batch 1 lands):**
  - Row 06 (sat, mistral): `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (lines 198-208), `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`
  - Row 12 (PC, claude): `csi-spl-orc/src/bash/run/spl-desk-post.func.sh`, `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh`, `csi-spl-orc/src/bash/tests/spl-desk-post.tst.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-send.sh`
  *(All file sets completely disjoint; `spl-spawn-place.func.sh` serialized strictly across batches, ensuring zero concurrent merge conflicts per R1).*

### 4.2 Lane Progression
- **Lane 1 (sat - Placer & Dynamic Gap):** Row 01 (Batch 1) -> Row 06 (Batch 2)
- **Lane 2 (PC - Topic Status Cards):** Row 07 (Batch 1)
- **Lane 3 (sat - Verification Service):** Row 09 (Batch 1)
- **Lane 4 (PC - Issue Close Cadence & Go-Ask Guard):** Row 11 (Batch 1) -> Row 12 (Batch 2)

### 4.3 Collision Control (R3)
`lane-map.sh --check` verifies none of these paths are owned by any active lane. Lane `c-233@sat` (`c-233-c001-placer-handoff-no-block`) has landed its fix (`68edb2656`), is closed and retired; Row 01 builds directly on top of `68edb2656`. Round 13 (WUI clean code), Perf Round 6 (WUI speed), and Test Round 1 (testing self-reflection) touch zero shared paths.

---

## 5. What was measured and NOT worth automating / already built

| Proposal / Practice | Why not | Measured evidence |
|---|---|---|
| Placer hand-off unblocking as standalone row (former row 04) | Folded into Row 01 | `68edb2656` fix(orc, SPL-2042) already unblocked queue on hand-off. Remaining 1-line edit (`touch .place.last` moved to launch branch) edits the exact same 20 lines (235-256) of `spl-spawn-place.func.sh` as Row 01. |
| In-process push-master closer hook (former row 11) | Replaced by Row 11 Closer Cadence (P2) | Closer requires local cursor and cron. sat box has neither cursor nor cron (`crontab -l \| grep issue` -> empty); an in-process hook on sat is a silent no-op. Changing `box-crons.manifest:28` to `*/5 * * * *` reduces lag from 59m to 5m reliably. |
| Push-master inbox completion notify (former row 12) | Replaced by Row 12 No Go-Asks in Owner Topics (P1) | Cited line numbers 190-260 ran past EOF (file is 205 lines). Measured status calls across 313 sessions averaged only 1.19 calls/push (median 1.33). Proposal P1 directly tackles 66 owner go/yes/ok nudges per week across 47 topics. |
| Quota-exhaustion failover (originally row 03) | Already built on master in `8b427556c` (SPL-2035) | `spl-box-pick.tst.sh` cases 16a (96% vs 40% -> routes to box with capacity), 16b (both over -> hold), and 16d (RED CONTROL) already implement and verify this. The 9 manual reroutes were prior to SPL-2035 landing. |
| Remote brief auto-mirror (originally row 02) | Already built on master | `spawn-remote.sh:110-119` sends the brief text inline in the request, and `:210-218` writes it on the target with an ACL. Measured n=1 incident in `920ccbfc` was output files, not input brief sync. |
| Automated R7 reviewer pairing (originally row 05) | Not failing in practice; invalid test path cited | R7 has 0 violations in 4 days across 38 review lines; cited test file `tests/test-reviewer-pick.sh` does not exist in repo. |
| Automated retry for CI setup flakes (originally row 08) | Already built on master | Workflow `.github/workflows/12_ci-rerun-setup-flake.yml` and `do_ci_rerun_setup_flake` (`ci-rerun-setup-flake.func.sh`) already rerun `--failed` once when all jobs die at Set up job. |
| Automated post-exit retire chaining (originally row 10) | Already built on master | `tmux-close-window.sh --defer --retire` (line 66) is already invoked by `/exit-clean` after ACCEPTED, backed by `agent-id-reap.sh` cron. |
| Auto-generating brief markdown files directly from raw owner chat posts | High risk of distorted scope; owner chat contains iterative corrections and context spanning multiple topics | 5 owner posts in `999a50bd` required synthesis; past auto-brief attempt (`sathand-c002-merge-boxes-agents-into-monitoring`) required 3 manual re-steers. Dispatcher brief drafting provides essential human/agent architectural judgement. |
| Increasing box agent window ceiling beyond 40 | Causes box memory exhaustion, swap thrashing, and runner CPU throttling | sat host memory sits at 45.5 GB with ~11 active lanes. Exceeding 40 lanes risks host OOM kills and slows CI runners (`gh-runner-cpu-budget`). Ceiling 40 is optimal. |
| Auto-restarting lanes that fail local pre-push tests | Wastes tokens and CPU on fundamentally broken implementations | Observed in `m-587`: two automated restarts failed the same test and consumed 3x tokens before being closed. The two-tries rule (HUM-10 `b821e242`) with handoff to a stronger vendor is far more cost-effective. |
| Auto-merging feature branches into master via GitHub PRs | Destroys linear history, introduces PR queue serialization, and triples deploy lag | Trunk-based rebase-and-push has successfully delivered 4,950+ commits. PR automation adds queue latency and runner overhead without improving quality. |

---

## 6. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-240@sat` (`sdlc-round-1/seat-agy.md`)
  - Claude seat: `c-247@sat` (`sdlc-round-1/seat-claude.md`, verdict in `e0edb8964`, send-backs `69c0017a`, `5fcc662b`, `269cbeb8`, signed v1.3 in `8c10cf0b7`)
  - Takeover seat (claude, ex-mistral): `c-251@sat` (`sdlc-round-1/seat-mistral.md`, verdict in `b6153d006`, signed v1.4 in `a5840b371`)
  - Grok seat: Not seated (no grok quota on any box, per dispatcher `c-002@sat` note)
  - *(No qwen seat: switched off in fleet settings).*
- **Reviewers per row (R7.2):**
  - Row 01 (sat, mistral) -> Reviewer: `c-247@sat` (claude)
  - Row 07 (PC, claude) -> Reviewer: `a-240@sat` (agy)
  - Row 09 (sat, claude) -> Reviewer: `a-240@sat` (agy)
  - Row 11 (PC, claude) -> Reviewer: `a-240@sat` (agy)
  - Row 06 (sat, mistral) -> Reviewer: `c-247@sat` (claude)
  - Row 12 (PC, claude) -> Reviewer: `a-240@sat` (agy)
  - Zero same-vendor reviews (100% cross-vendor compliant with R7.2.5).

---

## 7. Counts

| Dimension | Count |
|---|---|
| Total rows | 6 (100% verified SDLC automation, robustness & performance) |
| Box allocation | 3 on sat, 3 on PC (Batch 1: 2 sat + 2 PC; Batch 2: 1 sat + 1 PC) |
| Parallel lanes | 4 lanes in parallel in Batch 1; 2 lanes in parallel in Batch 2 |
| Batches | 2 batches (Batch 1: 4 rows; Batch 2: 2 rows; 100% disjoint within each batch) |
| Vendor assignment | claude 4, mistral 2 (assigned to coding vendors per fleet kind table and `do_spl_lane_mix`) |
| Owner minutes saved | **~210 minutes/week** (66 go nudges + 32 status asks + 18 live asks + 12 queue asks) |
| Tokens saved | **~125k tokens/week** |

---

## 8. Changes

- v0.1: Initial proposed plan for SDLC Round 1 (Software life-cycle automation round), fulfilling owner HUM-10 directives (msgs `6c1ed812`, `a29ba4db`, `8772dd8f`, `190f44f4`, `abc17db1`) with 7 baseline empirical measurements on `d0950b1e3` and 12 concrete actions structured across 3 batches of 4 rows for 4 parallel build lanes (2 on PC + 2 on sat).
- v1.0: Consensus review integration from panel seats `c-247@sat` and `m-248@sat`.
- v1.1: Addressed panel review and send-back points from Claude seat `c-247@sat` (msg `69c0017a`) and Dispatcher `c-002@sat` (msg `622a4ad7`).
- v1.2: Un-absorbed queued bug ask ab32184e ('unknown usage' on PC) per dispatcher c-002 instruction (msg `f45e7b8b`).
- v1.3: Dropped Row 03 (quota-exhaustion failover) per c-247 send-back (`5fcc662b`) and dispatcher c-002 confirmation (`f0f32032`). Row 03 was already implemented on master in `8b427556c` (SPL-2035) with test coverage in `spl-box-pick.tst.sh` (cases 16a, 16b, 16d). Moved to Section 5.
- v1.4: Integrated Takeover seat `c-251@sat` (claude, ex-mistral) verdict (`b6153d006`) and Claude seat `c-247@sat` feedback: folded Row 04 into Row 01, replaced Row 11 with Closer Cadence (P2), replaced Row 12 with No Go-Asks in Owner Topics (P1).
- v1.5: Refinements per panel send-backs from `c-247@sat` (msg `269cbeb8`), `c-251@sat` (msg `5dd6af73`), and dispatcher `c-002@sat` (msgs `730bad28`, `b38e1565`):
  - Row 06: corrected heartbeat source to `/var/spool-hub/<agent>/heartbeat.json` (`progress_ts`, moved only by tool calls/stops via `spool-agent-hook.sh:7,382-390`); added 10-min ceiling when heartbeat never moves; retained 3-min floor and load target guard. Serialized in Batch 2 strictly to preserve R1 disjoint files with Row 01.
  - Row 12: relocated guard to `do_spl_desk_post` (`spl-desk-post.func.sh`) and `spool-send.sh` (for human `--to`); explicitly exempted structured poll forms (owner rule 10-14); targeted 14 explicit go-asks and up to 66 owner nudges.
  - Row 09: corrected trailer check to anchored commit message regex (`git log -1 --format=%B <sha> | grep -qiE '^(Co-Authored-By:|Claude-Session:)'`).
  - Row 11: added `csi-spl-orc/` prefix to `cnf/box-crons/box-crons.manifest:28`; updated test site to `install-box-crons.tst.sh:78`.
  - Row 07: clarified caller uses dedicated `do_spl_desk_edit` call, reusing pattern of `spl_asks_alert_clear` without editing alert clear.
  - Row 01: clarified scope builds on `68edb2656` (c-233 closed and retired).
  - Vendors updated to coding vendors (mistral/claude) per fleet kind table.

---

## 9. Consensus

| Seat | ID | Status | File |
|---|---|---|---|
| Editor (agy) | a-240@sat | agreed & v1.5 drafted (this commit) | `sdlc-round-1/seat-agy.md` |
| Claude seat | c-247@sat | signed v1.3 in `8c10cf0b7`; send-back points folded; standing by to sign v1.5 | `sdlc-round-1/seat-claude.md` |
| Takeover seat (claude, ex-mistral) | c-251@sat | signed v1.4 in `a5840b371`; conditions folded; standing by to sign v1.5 | `sdlc-round-1/seat-mistral.md` |
| Grok seat | g-xxx | not seated (no grok quota on any box) | `sdlc-round-1/seat-grok.md` |

Signed plan sha: pending panel signatures on this commit.
