# Perf round 13 (p13) - plan (1 row, v0.1)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5774  
Topic: 2776cdb8-83f9-4d3e-b950-995daf5c1ca7  

This is the seventh round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
(perf rounds). The plan points to the rules and does not copy them:

- Sections 1 to 3: at most 10 rows; per row, aim for 1 push, up to 3, never
  more than 5; R1-R16.
- Sections 4.1 to 4.5: every row is measured first and lands with a counting or
  timing test and its red control. A candidate with no measured gain is
  dropped.

Owner orders that bind this round:

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor, the holder requests the
  next perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Every row's
  vendor is claude.**

**Status: v0.1, draft, not signed.** Editor: c-882 (claude).

**Why now.** The holder's request (c-002@sat, 118f70aa, 2026-11-17 06:00Z;
brief by c-001@sat):

- Perf round 12 is served: p12-01 `d5f6f6887`, p12-02 `a68a97b96` are on
  `origin/master`.
- The 4.4 check, re-run here at 06:23:50Z on `9310612f3`, printed
  `perf 18 refactor 101 perf-share 15.1% under-20` (the brief read the same
  line on `b45e54ddc`).

The slug, read at 06:23:50Z on `9310612f3`:

- `git log origin/master --oneline -E --grep='\(p13-'` -> 0 lines.
- `git ls-tree -r --name-only origin/master | grep -c perf-round-13` -> 0.

**One sha.** Every row baseline below is measured on **`9310612f3`**
(`origin/master` at 06:2xZ, 2026-11-17), on the desk box (16 cpus, 1-minute
load 26..62 while measuring). Raw commands and outputs:
[perf-round-13/editor.md](perf-round-13/editor.md).

**Retro.** There is no `perf-round-12-retro.md` on `origin/master`
(`git ls-tree -r --name-only origin/master | grep -cE 'perf-round-12-retro'`
-> 0; at `457116142` the tree had only `perf-round-12-plan.md` and
`perf-round-12/editor.md`). This plan does not stand in for it and does not
guess its content. It reads `perf-round-12-plan.md` (its section 6 first),
`perf-round-12/editor.md`, `perf-round-11-plan.md`, `perf-round-5-retro.md`
and `lesson-speed-up-measure-first.md`.

<a id="p13-how-to-read"></a>
## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p13-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p13-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `9310612f3`.
- **After** = what the change leaves of that number, and how it is known.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `iac/` = `csi-spl-iac/`. `cpp` =
  `iac/src/bash/run/check-pre-push.func.sh`.
- **Where the rows come from.** The pre-push log of the desk box (editor 2.1)
  over 7 days and since SPL-5588 (`1d7bae644`, 2026-11-15T12:45Z). p12's
  carried input, the narrowed re-check for `wui` and `orc-features`, has
  **no red run left to narrow**: since `1d7bae644`, `wui` read 0
  WARN-pre-existing and `orc-features` 0 WARN-pre-existing and 0 FAIL; the
  177 `wui` WARN-pre-existing runs of the 7 days were all timeouts, which a
  narrowed re-check does not narrow (`cpp:1120`). What a timed-out run still
  costs is row 01.

<a id="p13-inputs"></a>
## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`9310612f3`:

| input | finding | on the tree | here |
|---|---|---|---|
| `perf-round-12-plan.md` section 6: the narrowed re-check for `wui` (27 WARN-pre-existing in 7 days) and `orc-features` (11) | input for round 13 | re-counted (editor 2.1): `wui` 177 WARN-pre-existing in 7 days, all `TIMED OUT after 420s`, 0 since `1d7bae644`; `orc-features` 31, the last on 11-13, 0 since | section 6, dropped: no red run to narrow since `1d7bae644` |
| new, this seat: the timed-out runs | a TIMED OUT tree run still re-runs the whole part on trunk, though since SPL-5588 the verdict is FAIL whatever trunk does (`cpp:1112-1131`, `:1149-1159`) | n=2 since `1d7bae644`: 1,011 s and 2,708 s of re-check, verdict FAIL both (editor 2.2) | **row 01** |
| new, this seat: the full tier | `lint-gosec` runs on every full-tier push, n=44 since `1d7bae644`, 628..1,696 s, PASS every time | probe running (editor 2.3): whole module vs one package on `9310612f3`; the first `./...` run passed 15 min under load ~40..60 | v0.2: a row or dropped, by the probe |
| `perf-round-12-plan.md` section 6: CI shard rebalance; per-case wait audit; `commit-links`' prd key; `iac-cross`; a-827's 3 and 5; `fsync=off`; p5 inputs; p6-08/09 | carried | not re-measured, for p12's reasons (no key, no container, no lab) | section 6, carried |
| brief carried input 2 (c-873, msg 63de2ba8): WUI AC-02 initial download 154.3 of 155 KB gzip | headroom 0.7 KB | CI wf 10 run 44026337999 on `b4b9c4f1b`, job 133847535842: `PASS ci_initial_gzip_kb 154.3 <= 155`, n=1; job 133848327552: `OK AC-02: the initial download is <= 155 KB gzip 154.3` | section 6, not a row: a ceiling's headroom is not a measured wait; no trim was probed (needs a `nuxt generate` with the CI node, and this seat installs nothing) |
| brief carried input 1: SPL-5734 N1, N3, N4; SPL-5736 N2; SPL-5750 N1, N2 | bugs and tests | two checked here (editor 4): `jq fromdate` refuses `2026-11-17T06:00:00.123Z`; `LiveTopicPane.vue` has 0 `:error`/`@error` | not perf work: sent to c-001 as their own asks (task `dispatch-perf-r13`) |
| `perf-round-12/editor.md` | p12's measurements | read; its numbers are on `a8a54cf44` and not reused | - |
| `perf-round-11-plan.md`, `perf-round-5-retro.md` | read through p12 section 6 | - | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the log first (editor 2.1), then the code path, then a probe (editor 2.3) | - |

<a id="p13-rows"></a>
## 3. The rows

| # | id | practice | baseline on `9310612f3` (command, number, n) | after | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p13-01-timeout-skips-base-recheck)` | a part that TIMED OUT on the tree (rc 124 or 137) builds no base worktree and runs nothing on trunk: since SPL-5588 its verdict is FAIL whatever trunk does, so the re-check changes no verdict. The verdict field reads `trunk=not-checked timed-out-not-compared` | editor 2.2: `sudo awk '$1>="2026-11-15T12:45:06Z" && /TIMED OUT after/' ~/.cache/csi-spl/pre-push.log` -> **n=2**, the trunk re-check after the timeout **1,011 s** (`wui-e2e`, budget 1,870 s, total 2,881 s) and **2,708 s** (`api`, budget 2,700 s, total 5,408 s); verdict FAIL in both | by construction, 0 s of re-check and no base worktree per timed-out part; the same FAIL verdict. Not probed: the saving is the whole re-check, which the counting test proves is gone | `cpp:1112-1131` (`_pp_run`: return to `_pp_timed_out` before `_pp_baseline_tree` when rc is 124 or 137) and `cpp:1142-1159` (`_pp_timed_out` and its comment: no base state); `csi-spl-doc/doc/md/pre-push-gate.md:255-262` (the verdict field); 3 edit ranges | a new case in **`iac/src/bash/tests/check-pre-push-timeout-red-trunk.tst.sh`** (its header lists cases a-e): a stub part that counts its calls and exits 124 -> called **once** (today **twice**: tree, then trunk), no base worktree built, verdict FAIL with `trunk=not-checked timed-out-not-compared`. Red: today's `_pp_run` -> 2 calls, FAIL. Cases a, d and e change their `trunk=` expectation to `not-checked` in the same commit. Also run and green: **`check-pre-push-recheck-narrow.tst.sh`**, **`check-pre-push-verdict-forks.tst.sh`**, **`check-pre-push-baseline.tst.sh`**, `check-pre-push-api-timeout.tst.sh`, `check-pre-push-part-timeout.tst.sh`, `check-pre-push-timeout-label.tst.sh`, `check-pre-push-lint-timeout.tst.sh`, `check-pre-push-orphan-pipe.tst.sh`, `check-pre-push-scope.tst.sh`, `check-pre-push-features.tst.sh`, `check-pre-push.tst.sh`, `report-pre-push-part-times.tst.sh`, `bash-cleancode.tst.sh` | either fleet box | claude / simple_coding (R9: a gate, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1 |

Every row is claude: rulebook R14 (an established vendor) and the owner's
10-17 rule (no mistral coding or testing).

<a id="p13-batches"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: row 01. Files: `cpp`, `check-pre-push-timeout-red-trunk.tst.sh`, `pre-push-gate.md`.
- No row file is a file of an unlanded round row (3.2).

<a id="p13-r3"></a>
### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-17, each with its time:

- **Lane map, every machine** (06:21:44Z, one call): `lane-map.sh --check
  <cpp, check-pre-push-lint.func.sh, sec-gosec.func.sh, pre-push-gate.md, this
  plan, its seat file> --agent c-882` -> exit 4: `0` lines `owned by`, `17`
  lines `unknown:`, all lanes on the second box that record no files (8
  rotation seats; 9 lanes whose slugs name a price, a blog draft, the
  transport drop and socket close, cost allocation, issue notes, an agy
  memory gap and release projects). None names the pre-push gate or gosec.
  Exit 4 is not free: the R3 check before each spawn re-reads the map and
  asks any lane still unknown.
- **Spawn queue** (06:21:53Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`) -> `3 queued, 0 placing`:
  `c001-spl5735-doc-announce-refusal-followup` (docs) and two agy i18n reviews
  (`spl5706-inactive-member`, `spl5707-member-phone`). Their summaries name no
  pre-push file; briefs not read here, so the R3 check before each spawn
  re-reads the queue.
- **Unlanded round rows** (06:2xZ, on `9310612f3`): p12-01, p12-02 landed;
  `git log origin/master --format=%s -E --grep='\(<r>-[0-9]{2}-'` -> r59 6
  lines, r60 0, r61 0, r62 0. No r-round plan on the tree names `cpp`.

<a id="p13-per-row"></a>
## 4. Per row: what the lane does

- **01**:
  - In `_pp_run`, when `rc` is 124 or 137, the lane calls `_pp_timed_out`
    before `_pp_baseline_tree`: no base worktree, no `_pp_capture` on it.
    The `rc 127` branch above it is unchanged.
  - `_pp_timed_out` keeps its FAIL and its log line's advice (re-run it, or
    raise its budget); `trunk=` reads `not-checked` and the log no longer
    says what trunk did. The comment above it (`cpp:1142-1148`) and the one
    above the narrowed hand-over (`cpp:1120`, now unreachable for a timeout)
    change with the code (C5).
  - `pre-push-gate.md:255-262` says the timed-out verdict is
    `trunk=not-checked timed-out-not-compared`, and why: the verdict never
    depended on it (SPL-5588), so the re-check was time with no effect.
  - What it gives up, said in the commit body: the `trunk=<sha>-red` hint
    that trunk is red too. A lane that wants it runs the part on trunk by
    hand; the verdict was FAIL either way.
  - The lane states the counting test's RED and GREEN output; no timing
    probe is needed, the call count is the gain.

<a id="p13-panel"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-17 06:22:24Z:

- `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold`, grok weekly
  99% on both boxes.
- agy: at its quota limit until 2026-11-20T23:04:08Z (the spawn queue's WAIT
  lines, account-wide); the desk box has no agy.
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Mistral: docs and reviews only (owner 10-17); its code reviews paused
  (owner 10-30, cf7a7ee5), but for p12 the owner's ruling e895dea6 (poll
  8ede28e3, answer C) had mistral review each claude row.

So the only vendors that can sit now are claude and mistral.

- **Plan panel (rulebook 3.2)**: editor c-882 (claude). I asked the dispatch
  holder (c-002@sat, msg ad164a03, 06:23:11Z) for one **mistral** seat,
  either box, seat file `perf-round-13/seat-mistral.md`, branch
  `review/c002-perf-round-13-mistral-seat`. A plan review is a docs review.
  c-001 ruled that e895dea6 carries to p13 (below).
- **Row reviewers (2.7.2)**: every row's author is claude. The reviewer is a
  non-claude seat named in each row brief by the holder when the rows spawn:
  the mistral seat while the ruling below holds, grok once a grok pick lands
  on either box. A row never pushes without a cross-vendor PASS.

**Ruling (c-001 cbada223, relayed by c-002@sat msg c91e9816, 2026-11-17 06:3xZ)**: owner ruling e895dea6 (p12 poll 8ede28e3, C: claude + mistral sign, no agy) **carries to p13 while its conditions hold**: grok `pick=hold` on both boxes and agy at its quota limit. It lapses on the first grok pick on either box or agy's reset; then the panel is per rulebook again. So the panel is **c-882 (claude, editor) + the mistral seat** (ask 9c0a6cef, `mistral:c002-perf-round-13-mistral-panel-seat`, queued 1 of 6 at 06:3xZ), and the mistral seat reviews each claude row under the same ruling. The seat signs only a sha this editor names.

<a id="p13-left-out"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| the narrowed re-check for `wui` and `orc-features` (p12 section 6) | **dropped: no red run left to narrow** | since `1d7bae644`: `wui` WARN-pre-existing 0, FAIL 2; `orc-features` WARN-pre-existing 0, FAIL 0, PASS 73. The 7-day 177 `wui` WARN-pre-existing were timeouts, which are not narrowed (`cpp:1120`). Editor 2.1 |
| WUI AC-02 initial download 154.3 of 155 KB gzip (c-873) | **not a row**: headroom under a ceiling is not a measured wait, and no trim was probed | CI `b4b9c4f1b`, n=1 (section 2). Input for a later round, with a probe on the CI node (memory of the fleet: box node reads ~0.3..0.7 KB low) |
| `api` on the full tier, 2,355..3,419 s per push (n=14 since `1d7bae644`) | **not probed here**: the Postgres run needs a container; this seat starts none | editor 2.1; input for round 14 |
| `lint-gosec` on the full tier (n=44 since `1d7bae644`, 628..1,696 s, every one PASS) | **probe running** (editor 2.3); v0.2 makes it a row or drops it here with its numbers. A narrowed scan must also narrow the baseline: `.gosec-baseline.txt` fails a count BELOW its line (r5-05), so an unscanned file would read as fixed | editor 2.1, 2.3 |
| rebalancing CI wf 10 shards; per-case wait audit | dropped in p12, not re-measured | p12 editor 2.4 |
| `commit-links`' prd key lookup; `iac-cross`; a-827's 3 and 5; `fsync=off`; p5 inputs 1 and 3; p6-08/09 | not here: a key, a container, a lab or a built bundle | carried from p12 |
| SPL-5734 N1, N3, N4; SPL-5736 N2; SPL-5750 N1, N2 | not perf work | sent to c-001 as their own asks, task `dispatch-perf-r13` |

<a id="p13-counts"></a>
## 7. Counts

- Rows: 1 (rulebook 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p13-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p13-' --format=%B | grep -c '^review: '` must reach 1.

<a id="p13-changes"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 12. From then on the Qto doc is the primary copy.

- v0.1 (c-882, 2026-11-17): first draft on `9310612f3`.

<a id="p13-consensus"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-882 (editor) | claude | v0.1 | author |
| mistral seat (ask 9c0a6cef) | mistral | - | queued, not placed yet |
