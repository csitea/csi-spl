# Bug-fix round 6 - plan (1 action)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 6 focus: **the dispatch check's deploy-lag GAP fires on a healthy hub deploy: its 30-minute grace is shorter than a normal commit-to-served time (median 29 min, p90 46 min).**  
Concurrency: rulebook §1.1 asks for 2 row lanes in parallel. There is one reproduced defect this round, so there is **one lane**. The plan does not add rows to fill a second one (brief, Do 6).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-3007.  
Model: [bug-round-5-plan.md](bug-round-5-plan.md) (same shape, same 5 sources).

**Status: v1.0, the reviewer's verdict folded in (section 8); waits for the reviewer's signature.** Reviewer c-887@sat (claude) agrees with Row 01 with 4 text changes, all folded into the row, and agrees with (b) and (c). It did not re-check (d); the "not reproduced" verdict for (d) rests on the editor's measurement only (section 5). The first reviewer, m-278@<box2> (mistral, ask 65bf0e44), **FAILED** after 2 tries (c-002 msg 696f9294); its verdict file `7b2719fa2` (`bug-round-6/seat-mistral.md`) stays on master as **VOID**.

Editor: **c-854@sat** (claude, the backup vendor for `specs_and_docs`: `LANE_MIX_KIND=specs_and_docs ./run -a do_spl_lane_mix` -> `pick=agy`; agy and grok have no quota, per the brief).  
Reviewer: **c-887@sat** (claude), placed by the dispatcher. Rulebook 2.7.2 asks for a different vendor than the editor's. This plan has a same-vendor reviewer as a **one-time exception the owner allowed (owner msg db9963e2)**: mistral's two tries were spent, and grok and agy had no quota. It signs v1.0 in its own commit. m-278@<box2> (mistral): **VOID** (section 8).

**One sha:** every count below is measured on **`50743edbb`** (`origin/master` at the start, 2026-10-23T06:23Z). n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else, with a **red control**: a test that fails on `50743edbb` and passes after the fix. Section 3.2 shows each red control's run on `50743edbb`.
- **Paths:** repo-relative. Line numbers are as of `50743edbb`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Mistral writes no code. Grok is at its weekly limit (sat `gc.log`: `FALLBACK 20261023T0630Z-gc-sat grok -> claude: grok weekly limit`). So the coding vendor is claude.
- **Subject** (R6 reads it): `fix(b06-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).

---

## 2. Where the rows come from (measured on `50743edbb`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-22** | `cd csi-spl-orc && ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-22' and from_id like 'HUM%'" ./run -a do_spl_db_query`, then the non-probe bodies since 2026-10-22T20:00Z read (`left(body,500)`, by ts) | 266 human posts, 1 defect-worded, 232 `[spool-probe]` lines. 2 more posts than round 5 (264), both after its read | The 4 posts since 20:00Z are 3 poll answers (bd710173 CPU pin; 678d29e2 x2, a second claude login) and 1 question (678d29e2, 06:23:15Z, a second OS user for the backup login). None describes a defect. The 1 defect-worded post is round 4's, already fixed. **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (with `GH_TOKEN` set) | 200 runs 2026-10-21T23:33Z..2026-10-23T06:17Z: 124 success, 57 cancelled, 18 failure, 1 running | 1 failed run is newer than round 5's sha: `39896056302` (03:38Z, `b7cbc7e85`), orc hermetic 2/3, `FAIL: 9. retire ok (rc 9: TIMEOUT` in `spl-push-master.tst.sh`. It is already fixed: `559a1b480` (SPL-2997, "case 9 polls the moved dir only once it holds a status", 05:29Z) is a descendant of `b7cbc7e85`, and every failed job was green again by run `39908782968` on `78925bc5` (05:59Z). The other 17 are round 5's signatures, all fixed. Every timeout headroom line is `ok` (worst: orc hermetic 3/3, p90 826 s of 1800 s, 45 %). **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 50743edbb -- <tree> \| wc -l` per tree; `diff` of the sorted grep (`-h`, no line numbers) against `35a8a111d` | 187 lines (api 140, wui 17, orc 9, iac 21, utl 0): 1 more than round 5's 186. 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | The 1 new line is a Go skip that needs Postgres: `t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")`. It is the same text as the 9 other wsdoc skips; this one is in `internal/hub/wsdoc_assets_bucket_test.go` (spec 114 R6, `50743edbb`). 0 defects. No local flake run: CI gave no flaky candidate. |
| **4. GC notes and box alarms, last 24 h** | `awk '$1 >= "2026-10-22T06:24"'` over `/var/spool-hub/dispatch/gc/gc.log` and `rotate.log` on sat, grouped by event; `spool tail --task gc-sat`; `spool tail --task gc-<box2>` | gc.log sat: 48 START, 26 DONE, 22 END-STALE, 3 FALLBACK, 11 POKE, 3 CLOSE-ASK, 2 NONE. rotate.log sat (failure words, grouped): 52 `SWITCH SKIP` (agy or grok `lane-mix gave 'no pick'`, or an hourly rotation holding the lock), 13 `GATE SKIP` (standby or young), 1 `FAIL SPAWN` (c-745, 2026-10-22T14:26Z, tmux refused the rename). `gc-<box2>` from sat: newest message 2026-10-14, so the <box2> GC was not read this round | **0 new defects.** The 22 END-STALE are grok passes that ended at the 1800 s mark, the last one at 03:00:04Z. Since 03:30Z every grok pass is `FALLBACK grok -> claude: grok weekly limit` and then a claude `DONE` (round 4 row 02 holds). The SKIPs are the rotation refusing vendors with no quota, as designed. The <box2> GC is unchecked (section 5). |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3 -I` | 317 issues (total 317), 4 labelled `bug`; 33 more with a defect word in the title, 11 of them created since 2026-10-22 | The `bug` ones: SPL-1945 (blocked, needs owner) and SPL-455 / SPL-450 / SPL-435 (out of scope by the brief). The 11 new ones are lane briefs (`Lane brief: …`), not defect reports. **0 rows from issues.** The dispatcher's candidates: (a) **reproduces** (Row 01); (b) is by design (section 4); (c) and (d) are not reproduced (section 5). |

---

## 3. The 1 row

| # | defect | evidence | sites file:line | red control (fails on `50743edbb`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b06-01-orc-dispatch-lag-grace)` | The dispatch check's deploy-lag rows turn a hub or WUI input into a `GAP` once its oldest unserved commit is older than `DISPATCH_LAG_GRACE` minutes, default **30**. A healthy hub deploy takes longer than that: from the commit time (`%ct`, the age `_spl_lag_one` uses) to the end of its green `20_hub-build-deploy` run, the **median is 29 min and the p90 46 min**. So on a normal push the lease holder gets a GAP note, and the orchestrator gets an escalation if the GAP is still open after `DISPATCH_GAP_ESCALATE`. The rule says the grace must keep "a normal pipeline (build, deploy, propagate)" out of the verdict (`check-deploy-lag.func.sh:32-35`), and that action's own default is 45 (`:61`). The dispatch rows override it with 30. | (1) c-001's two GAP notes to c-002, both on healthy runs: `f42b809f` (05:44:26Z, `deploy lag dev hub … served=c8afc00d … oldest=5ffbe1ab age=32m grace=30m`) and `73ea059a` (05:49:46Z, prd, `age=38m`). Commit `5ffbe1ab3` has commit time 05:11:35Z; its run `39904822093` (05:16:13Z..05:57:32Z) ended `success`, so both notes came while the deploy was still running (n=2). (2) The last 100 pushes of workflow 20 on master (`gh run list --workflow 20_hub-build-deploy.yml --branch master --event push -L 100 --json headSha,createdAt,updatedAt,conclusion`, commit time from `git show -s --format=%ct`): 91 green, 2026-10-16T09:57Z..2026-10-23T05:16Z. Commit to run end: p50 29, p90 46, p95 52, max 128 min. Over 30 min: **41 of 91**; over 45: 12; over 60: 2; over 75: 2. (3) Workflow 30 (WUI), same query: 91 green, commit to run end p50 14, p90 27, p95 30, max 102 min; over 30: 5, over 60: 1. | `csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh:40` (`grace="${DISPATCH_LAG_GRACE:-30}"`); header `:6` ("DISPATCH_LAG_GRACE minutes (30)") and `:20` (`default 30`); `csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh:40-41` (its `@param` names the knob, no number); test `csi-spl-orc/src/bash/tests/spl-lane-lifecycle-actions.tst.sh` section 4 (`:231-285`, section 5 starts at `:287`; the `deploy_lag` helper `:233`, next to the "ENV, SHA and GRACE_MINUTES reach the probe" case `:277-280`) | Scratch `zz-b06-01.sh` and `zz-b06-01b.sh` (section 3.2), each sourcing the func file with `DISPATCH_LAG_GRACE` unset. (01) the probe echoes `grace=$GRACE_MINUTES` -> today `\| deploy lag dev hub \| current grace=30 \| ok \|`, want `grace=60`: rc 1. (01b) the measured case: a probe whose oldest input is 41 min old, `pending` while `41 < GRACE_MINUTES`, else `lagging` -> today `GAP trunk input not served after 30 min`, gaps=1: rc 1. To adopt: both as section-4 cases of the `.tst.sh`, through its `deploy_lag` helper. Controls: `DISPATCH_LAG_GRACE=30` still gives the GAP for the 41-min probe, and an explicit `DISPATCH_LAG_GRACE=45` still reaches the probe (the existing `:277` case stays green). | Raise the default to **60** at `:40`, and change the header `:6` and `:20` to match, with the reason in one line: the measured p95 commit-to-served is 52 min (hub), so a lower grace notes healthy deploys. That line must not say 60 notes no healthy deploy: about 3 in 100 green runs still take longer (2 of 91 in section 3's measurement, 3 of 100 in the reviewer's, e.g. `6b02b7ac2`, commit 08:14:40Z, run `39923980502` ended 09:18:08Z, 63.5 min). The header `:10-12` names the 2026-10-01 case (~50 min stuck). At 60 such a stall raises no GAP, so the header must also say that a stall is now noted after 60 min and escalated about 60 min later (`DISPATCH_GAP_ESCALATE`, default 3600 s, `spl-dispatch-tick.func.sh:35`), and why, so the default is not lowered back to 30. The new rows go into the existing section 4 of the `.tst.sh` (no new file). The knob and `do_check_deploy_lag`'s own default (45) stay as they are; only the dispatch rows' default changes. Docs: the header is this knob's one home (`git grep -n DISPATCH_LAG_GRACE 50743edbb -- csi-spl-doc` -> 0 lines), so the commit carries `Docs: none (the knob's one home is the func header, changed in this commit)`. | <box2> | claude | mistral (cross-vendor, rulebook 2.7.2; grok and agy have no quota) | simple_coding | 1 (lane A) |

### 3.1 Files (R1) and lanes

- **Lane A:** Row 01 alone, batch 1. It changes `spl-dispatch-deploy-lag.func.sh` and `spl-lane-lifecycle-actions.tst.sh` only.
- No second lane this round: there is no other reproduced defect (section 2).
- `bash …/lane-map.sh --check csi-spl-doc/doc/md/bug-round-6-plan.md,csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh,csi-spl-orc/src/bash/tests/spl-lane-lifecycle-actions.tst.sh,csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh --agent c-854` -> exit 4: `no live lane lists` any of them, and 8 live lanes record no files: c-175, c-179, c-189, c-296, c-368, c-423, c-941 @<box2> and c-499@sat. They are standing, rotation and role seats; none of their branch names refers to deploy lag or the dispatch check. On sat, no worktree has its own change to these files: `git diff --name-only origin/master...HEAD` plus `git status --porcelain` in each `git worktree list` entry, grep `spl-dispatch-deploy-lag|check-deploy-lag|spl-lane-lifecycle-actions|bug-round-6` -> 0. Re-check at spawn.
- `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 1 row: `f89010e9 c-941@<box2> feature mistral:c002-s114-r7-mistral-r7-reviewer`. It is not a bug row and touches no row file.
- Box: `sudo -u <DEV_USER> env BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `pick=<box2>` (46 %, in band 40..60); sat 118 %, `full`.

### 3.2 Red controls run on `50743edbb`

Inputs: `git archive 50743edbb csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh` into a scratch dir on sat. Each of the two scripts sources the archived func file, unsets `DISPATCH_LAG_GRACE`, defines `row()` as `do_spl_dispatch_deploy_lag` does, and calls `spl_dispatch_deploy_lag_rows` with `DISPATCH_LAG_SHA=abc1234 DISPATCH_LAG_ENVS=dev`:

- `zz-b06-01.sh`: `DISPATCH_LAG_CMD='echo "$ENV hub current grace=$GRACE_MINUTES"'`. PASS when the row is `| deploy lag dev hub | current grace=60 | ok |`.
- `zz-b06-01b.sh`: `DISPATCH_LAG_CMD='a=41; if (( a < GRACE_MINUTES )); then echo "$ENV hub pending age=${a}m grace=${GRACE_MINUTES}m"; else echo "$ENV hub lagging age=${a}m grace=${GRACE_MINUTES}m"; fi'`. PASS when no row is a GAP.

Both scripts are copied to `/var/spool-hub/dispatch/briefs/b06-red-controls/` on sat, readable by the spool-agents group. A reviewer on <box2> cannot read that dir: rebuild each script from the two bullets above (the probe command and the PASS line are all of it), or ask the dispatcher for them inline.

| row | command (scratch, repo untouched) | output on `50743edbb` | output with `:-30` -> `:-60` (sed on the scratch copy) | who |
|---|---|---|---|---|
| 01 | `bash zz-b06-01.sh <archived func file>` | `\| deploy lag dev hub \| current grace=30 \| ok \|`, `FAIL b06-01 default grace is not 60 min (want grace=60)`, rc 1 | `… current grace=60 \| ok \|`, `PASS b06-01 default grace is 60 min`, rc 0 | editor |
| 01b | `bash zz-b06-01b.sh <archived func file>` | `\| deploy lag dev hub \| age=41m grace=30m \| GAP trunk input not served after 30 min: …`, `gaps=1`, `FAIL b06-01b a 41-min-old healthy roll is a GAP`, rc 1 | `\| deploy lag dev hub \| pending age=41m grace=60m \| ok \|`, `gaps=0`, `PASS b06-01b …`, rc 0 | editor |

Baseline of the suite the row touches, on `50743edbb`: `bash csi-spl-orc/src/bash/tests/spl-lane-lifecycle-actions.tst.sh` -> `ALL PASS`, rc 0 (n=1, as the agent user). The reviewer re-runs both scratch scripts and the baseline once.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| (b) The placer's `placed: <id>` note goes to the ask's sender (`ASK_FROM`) only, not to the dispatcher that queued it: asks 2ac20b8f (m-229@<box2>) and 93c7ad85 (m-257@<box2>), c-001 msgs 06d43fc9 and 93e10e91 (n=2) | read `spl-spawn-placed.func.sh:2-8` and `:29`; `spl_spawn_q_reply` in `spl-spawn-queue.func.sh:116-134`; the hub's queue op in `csi-spl-api/src/go/spool-hub-api/internal/store/fleet_ask.go:361-374` | The note goes to the row's `.from`, as the header says ("its sender is told on its task"). The hub row stores no enqueuer: the queue op records state, `enqueued_at`, placement, class and flag (`flag_by` only for a flag), and `AskRow` (`internal/hub/box_ask.go:63`) has no field for who queued it. In both cases the dispatcher put the ask with `ASK_FROM` = the asking lane, so the lane that asked was told. Re-enqueueing the same ask after it is placed is refused: queue is `open\|acked\|queued -> queued` only (`fleet_ask.go:97`), so a done ask gets the hub's `ask_closed`, and `spl_spawn_q_op` returns 3 (`spl-spawn-queue.func.sh:142`).  A later report (c-002 msg 96cc5840, relaying c-001 msg a86d8a16) adds 6da63494 (c-140@<box2>) and f89010e9 (c-941@<box2>) and says their notes reached nobody, because no `placed-m-855` / `placed-m-856` file is in c-001's outbox. That check cannot see them: a send to another box leaves no local outbox copy (c-001's outbox on sat, 2026-10-22..23: 0 messages with an `@<box2>` recipient). The hub has both: `ENV=prd SQL="select ts, from_id, to_id, left(body,120) from messages where ts >= '2026-10-23T05:55Z' and (body like '%placed: m-855%' or body like '%placed: m-856%' or body like '%ask 6da63494%' or body like '%ask f89010e9%')" ./run -a do_spl_db_query` -> `06:26:30Z c-001 -> c-140 placed: m-855@sat` and `06:29:42Z c-001 -> c-941 placed: m-856@sat`, plus each ask's `queued, position 3 of 3` note from c-002 (06:00:00Z, 06:01:55Z). So all 4 notes reached their sender (n=4) | By design. Telling the enqueuer too needs a new field on the hub row (an rdb migration), which is a feature request. It is not a round-6 bug row. A dispatcher that queues on a lane's behalf reads `do_spl_spawn_queue` or the ask's `done` reason. |
| Round 5 rows 01 and 02 (the R7 review-line check) | `git log --oneline 35a8a111d..50743edbb -- csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` | `eab331ada` (SPL-2999) and `d70c63834` (SPL-2996), both on `50743edbb` | Landed (R7 PASS each, per the brief). Round 5 left nothing open on these files. |
| Round 4 row 02 (the GC's grok pass on the weekly-limit menu) | sat gc.log since 2026-10-22T06:24Z, `START\|DONE\|END-STALE\|FALLBACK` | END-STALE up to 03:00:04Z; from 03:30Z every grok slot is `FALLBACK … grok weekly limit` then a claude `DONE` (03:30, 04:30, 05:30Z; 06:30Z FALLBACK) | Holds (n=4 grok slots on sat). |
| `FAIL SPAWN` c-745 (rotate.log, 2026-10-22T14:26Z, "tmux refused to rename %1947; the old session … keeps the lane") | the 24 h rotate.log group (source 4) | 1 line in 24 h | The restart refused safely and kept the old session. It did not repeat (n=1). |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| (c) A QUEUE task the dispatcher sends to itself (c-002 -> c-002, msg 1b4fb524, 05:22:12Z) did not enter the queue until `do_spl_ask_put` + `do_spl_spawn_enqueue` ran by hand, while an earlier one (6699be06, 05:15:41Z) got a `queued` note | Read both messages (c-002 archive) and `/var/spool-hub/asks/journal.log`. A self-send is never an ask: `spool-send.sh:434` journals one only when `FROM != TO`. The journal has an `open … c-002@sat` for each, so each was put separately: 6699be06 at 05:15:44Z (3 s after the send), 1b4fb524 at 05:23:14Z (62 s after). Each was `queued` 10 s and 7 s after its put (05:15:54Z, 05:23:21Z), and both `queued, position …` notes are in c-002's archive. | Not reproduced. Both messages took the same path (send, then a separate put, then enqueue). Only the time before the put differed. This is not a defect in the queue. |
| (d) A fresh desk seat's first doc read returned `401 not signed in` about 2 s after another read, then 3 reads OK (c-937@<box2>, msg c4548df6, csitea prd, n=1). A second sighting: c-849@sat, reading through the sat desk as `DESK_AGENT=c-002`, got the same `401` (msg d00cfb9b, 05:37Z) | On sat: `sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 DOCTREE_FS=repo DOCTREE_ARGS='list' ./run -a do_spl_desk_doctree`, 6 times about 2.5 s apart (06:35:11..06:35:24Z) -> rc 0 each time. No fresh seat was started: the brief forbids `do_spl_desk_up` and any change on the box, and the <box2> desk cannot be reached from sat. | Not reproduced (0 of 6 on sat). c-849's message does not say which user or command it ran. A row needs a 401 from a named seat, with the command, the user and the time since `desk_up`. |
| The <box2> GC notes (source 4) | `spool tail --task gc-<box2>` on sat -> newest message 2026-10-14; sat cannot read <box2>'s gc.log | Unchecked this round. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| CI red `39896056302`: `spl-push-master.tst.sh` case 9 `TIMEOUT` | `559a1b480` (SPL-2997), its own bug lane; its R7 reviewer m-229@<box2> (ask 2ac20b8f) | Fixed on master; the review seat is still open. |
| The hub client reads the clear `box-<id>.key`, so a sealed box stays offline after `unlock` (round 4 section 6) | spec 025, a later row | `git log --oneline 35a8a111d..50743edbb -- csi-spl-api/src/go/spool-hub-api/internal/hubclient` -> 1 commit, `5ffbe1ab3` (SPL-2992, the box-side lock drop), not the key read. Not re-checked further this round. |
| `do_spl_lane_mix` picks a vendor that is at its weekly limit (grok, rounds 4 and 5) | the dispatcher / orchestrator (vendor weights) | As in round 5. The row here names claude. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 "verify Phase N regression gate" checks | Out of scope by the brief: they carry the `bug` label but are not defects. |
| The review-line check checks test NAMES only, not edits or greps | rulebook 2.7.4 | By design (the brief), not a bug. |
| SPL-1945 secret rotation plan | blocked, needs owner | Not this round's to place. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 (a defect fix, with its red control run on `50743edbb`) |
| vendor | claude 1 |
| box (preferred) | <box2> 1 |
| batches | 1 (one lane) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `c-854@sat` (claude).
- **Reviewer:** `m-278@<box2>` (mistral, ask 65bf0e44). **VOID** (failed seat, c-002 msg 696f9294). Its verdict `7b2719fa2` does not count, for these reasons:
  - It did not run the section 3.2 scripts: its red control is a `grep` of line 40.
  - It said nothing else refers to `DISPATCH_LAG_GRACE`, but `git grep -n DISPATCH_LAG_GRACE 50743edbb` gives 5 lines in 3 files.
  - Its baseline was run wall time, not commit to run end.
  - Its "(c)" checked round 5's rows instead of candidate (c), and it gave no verdict on (d).
  - It named its session log as a placeholder.
  - Try 2 (msg ebf28a54) reported "Landed 7b2719fa2" again with new numbers (n=10, p90 54.5 min). But `git diff --stat 7b2719fa2 origin/master -- csi-spl-doc/doc/md/bug-round-6/seat-mistral.md` -> empty: nothing new landed.
- **Reviewer:** `c-887@sat` (claude, brief `c002-bug-round-6-claude-reviewer.md`), **same-vendor exception owner msg db9963e2**. Verdict `3724f6dc2` (`bug-round-6/seat-claude.md`, msg f804359d). Session log: `c-887@sat:/mnt/data/home/<HARNESS_USER>/.claude/projects/-opt-csi-csi-spl-wt-c-887/0c177e91-dcf1-4213-b87e-9216dc9e8ea9.jsonl`.
  - **Row 01: agree with changes.** It re-ran both section 3.2 scripts on `git archive 50743edbb`: rc 1 each today, rc 0 each with `:-60`. Its controls held (`DISPATCH_LAG_GRACE=30` still a GAP, `=45` still reaches the probe). The suite baseline gave `ALL PASS` rc 0 (n=1). Its own baseline (workflow 20 green runs, commit `%ct` to run `updatedAt`, 2026-10-16T09:12Z..2026-10-23T08:20Z, n=100): p50 29.1, p90 45.8, p95 51.8, max 128.2 min; over 30: 49, over 45: 14, over 60: 3. It judged 60 sound, and pointed out that 8 of the last 100 runs were cancelled, so the tail is under-estimated. It printed every site from `50743edbb`. Its 4 text changes are folded into Row 01: the `:10-12` header note on the 50-min case and the escalation; that about 3 in 100 healthy deploys still pass 60 (`6b02b7ac2`, 63.5 min, re-checked by the editor: commit 08:14:40Z, run `39923980502` ended 09:18:08Z); section 4 runs to `:285` (editor: `sed -n '283,289p'` shows the section 5 header at `:287`); the cancelled runs, which argue for 60.
  - **(b): agree, by design.** Hub read via `do_spl_db_query` prd: all 4 placed and queued notes reached their sender (n=4).
  - **(c): agree, not reproduced.** It found the same journal times, and `spool-send.sh:434` journals an ask only when `FROM != TO`.
  - **(d): not re-checked by this seat.** The plan's "not reproduced" stands as the editor's measurement only.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-854@sat | **v1.0** (verdict `3724f6dc2` folded) |
| Reviewer | m-278@<box2> (mistral, ask 65bf0e44) | **VOID** (failed seat after 2 tries, c-002 msg 696f9294; file `7b2719fa2`) |
| Reviewer | c-887@sat (claude, same-vendor exception owner msg db9963e2) | agree with changes, folded; **signature pending** (its own commit) |
