# Bug-fix, refactoring and performance rounds rulebook

> Generated from qto doc `e621cc32-df7f-49e9-a33c-6d1f872e985c`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The one home doc for creating bug-fix rounds, refactoring rounds and performance rounds across the fleet. Every other document points here.

Owner HUM-10, t1 topic `49b8babb-8ce2-42c6-8d89-270bd72210f4`:
- msg f477d3ea: *"change the internal rules book / guidelines for the bugs and refactoring rounds creation"*
- msg 9b8fe16f: *"each round should be no more than 10 items"*
- msg 2f994cf6: *"items means 10 logical items ... No more than git pushes per item , preferably 1..1"*
- msg 0c3c223e: *"5 pushes ( aim for 1 , if complexity 3 )"*
- msg 7f664194: *"As discussed in the previous topics 20-30 percent for bugs fixing and 20-30 percent allocation of resources for refactoring"*
- msg 3d22fcea: rounds run continuously, embedded in core operation, no owner go needed.

Owner HUM-10, t1 #refactoring topic `8ebbed0e-d775-448e-9b50-c42e45b6e126` (2026-11-12), performance rounds: section 4.

<a id="ws-doc-435509f3-2699-495c-8394-8a84b4ed17e1"></a>
## 1. Round creation principles

<a id="ws-doc-2b7dacf0-27bf-4553-94ed-92f806928a3c"></a>
### 1.1 Round size: at most 10 logical items

Each round consists of at most **10 logical items**.
An item is one logical change, corresponding to one row of the plan table. A round must never exceed 10 rows.

<a id="ws-doc-91219413-1ce2-45cb-9bba-8b802389630c"></a>
### 1.2 Pushes per item: aim for 1, up to 3, never more than 5

Pushes per item (owner HUM-10 msg 0c3c223e, verbatim: *"5 pushes ( aim for 1 , if complexity 3 )"*):
- Aim for **1** push per item (`1..1`).
- Up to **3** pushes for an item of higher complexity.
- **Never more than 5** pushes for any item.

Lanes working on an item must structure their implementation, testing, and pre-push hygiene to land within this limit.

<a id="ws-doc-afd929c0-cb1b-4f35-a3c5-f0e5905d6551"></a>
### 1.3 Resource allocation bands (by pointer only)

Resource allocation between bug-fixing rounds and refactoring rounds follows the fleet work classes and bands:
- See the [fleet rules index](fleet-rules-index.md) (SPL-1817 row) for the binding allocation percentages and queue priority rules.
- To prevent drift, the band numbers and percentages are defined solely in that row and are never restated here.

<a id="ws-doc-aeca3b78-c4e3-45c9-b155-dea9fee7c686"></a>
### 1.4 Continuous execution: rounds need no owner go

Carried over from [SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md) section 1.2:
- Rounds run continuously as part of core system operations (owner HUM-10 msg 3d22fcea).
- No owner go-ahead is needed for a round, its panel, or its row lanes.
- When round `<N>`'s actions are served (R5), the dispatcher holding the lease requests round `<N+1>`'s planner at once (`c-001` places it).
  - Exception, the perf floor (4.4, owner HUM-10 msg 98dedfc4): while the perf share is under 20%, the holder requests the next perf round's planner instead of refactor round `<N+1>`'s; refactor round `<N+1>` waits until the share is back at 20%.
- The planner drafts the plan, places panel seats across vendors, and once the panel signs the plan sha, row lanes follow without waiting for owner approval.
- Planner by day, rows by night ([spec 166](../../specs/166-orchestrator-daily-rhythm/spec.md) section 3.1, row B3; owner HUM-10, t1 c0b0d572 msg 421e479a): the round's planner and its panel run by day, its row lanes, reviewer seats and retro at night (20:00 to 07:00 CET/CEST, `do_spl_rhythm_phase`). From `SPAWN_SUPPLY_LEAD_MIN` (120) minutes before the night, while fewer than twice the night's refactor lanes (the night band's 40% floor of the live lanes) are queued, the placer sends the dispatch lease holder one `SPAWN SUPPLY LEAD` blocker naming the night (once per night, in place of that hour's refactor supply blocker); the holder requests the planner's rows at once, so they are queued when the night starts.
- An individual row action that requires a production mutation, a `terraform apply`, or GCP secret access still requires the owner's explicit go for that specific call (repo [CLAUDE.md](../../../CLAUDE.md)); the round itself does not.


<a id="ws-doc-dd1932e6-d7d8-4314-a081-f1216334ca1a"></a>
## 2. Standing round rules (R1–R16)

Carried over from `refactor-round-9-plan.md` section 5 (and rounds 7–8):

<a id="ws-doc-e5f11a3d-9213-4f04-bdb0-68f873ca68f5"></a>
### 2.1 R1: Disjoint files per batch

No file path may appear in two actions of the same batch. Shared files between actions are strictly serialised across batches (Batch 1, then Batch 2 after Batch 1 lands, then Batch 3).

<a id="ws-doc-681cef32-2782-4c7d-9f0c-9c4d05c77fab"></a>
### 2.2 R2: Test column and rebase onto latest master

Before every push, fetch and rebase onto `origin/master`. The test column for an action includes:
- Every test file that names the site's basename, a function it defines, or (for WUI) its import path.
- Every test that holds a 30-character string from a comment within the site (+/- 3 lines).
- Every package or file that references an exported symbol the action moves or deletes.
- Bold formatting denotes a test that inspects source text directly.

<a id="ws-doc-4628c56f-0fe8-40e9-be84-2af17535760a"></a>
### 2.3 R3: Scope check before the wave

The orchestrator runs `lane-map.sh --check <action paths> --agent <orchestrator-id>` per action before spawning. An owned path must wait for that lane; never spawn an action on top of a path owned by another live lane.

<a id="ws-doc-9b1796bb-ad89-493e-a584-724f74b3bec0"></a>
### 2.4 R4: Spawning across boxes and one spawn per slug

Actions are distributed across available fleet boxes (e.g. `sat`, `PC`, and other configured nodes).
Before spawning:
- Verify that `git log origin/master --grep='<round>-NN-' --oneline` is empty and no live lane on any box carries the slug.
- The brief carries the plan row verbatim (its plan table row and per-action bullet) and names the row's assigned cross-vendor reviewer seat (R7).
- The spawner inspects the new lane's pane 2 minutes after spawn to confirm it launched cleanly.

<a id="ws-doc-b89abd9c-02c9-42ce-9b5f-62f487463f47"></a>
### 2.5 R5: Done = served

An action is done only when its changes are verified served or landed:
- Web UI (WUI) changes: verified via `cd csi-spl-orc && SHA=<sha> ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd`.
- Unit tests (e.g. Go tests): test execution passes without requiring runtime deployment.
- Bash, CI, and tooling changes: landed on `origin/master` and verified in the box checkout (`git -C <box checkout> merge-base --is-ancestor <sha> HEAD`), with red control proof recorded in the commit body.
- Every row must also satisfy R11's CI verdict requirements.

<a id="ws-doc-6ec0dfab-c9b1-4f6a-8ddc-e2698ae69d65"></a>
### 2.6 R6: No hand-kept status

Trunk status is determined strictly by reading git history:
`git fetch origin master && git log origin/master --grep='<round>-' --format='%h %cI %s'`
followed by running the R5 verification commands per commit sha.

<a id="ws-doc-48945c06-ec32-44f5-96a1-234aadaa70f9"></a>
### 2.7 R7: Peer review across vendors by seats that outlive the round

- **2.7.1 Reviewer seats outlive the round:** The panel reviewer seats stay active after plan signing until R6 shows all 10 rows on trunk. They are not closed at signing.
- **2.7.2 Cross-vendor assignment:** The reviewer is assigned per row before spawn in the row brief. Review lines must be cross-vendor (e.g. agy reviews claude; mistral reviews agy/grok; claude reviews mistral). A non-author panel seat acts as primary reviewer, with another non-author seat as backup.
- **2.7.3 Seat replacement:** If the assigned reviewer seat and its backup are absent or unresponsive for 15 minutes, the lane reports a blocker to the orchestrator, which spawns a replacement reviewer of an eligible vendor within the hour (R10). A row never pushes to master without a cross-vendor review PASS; the one exception is a trunk-red fix (2.11.3).
- **2.7.4 Review evidence format:** Before pushing, the lane pushes a review branch `review/<round>-NN` and requests review. The reviewer verifies the diff against criteria C1–C7 and emits:
  `review: <reviewer-id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <reviewer-id>@<box>:<path>`
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands that are in the `log:` file, the reviewer's own session journal. A line without `log:` or with a sha that does not resolve is void. If no test was executed directly, it must say `ran: none` and cite the command output read. The review branch `review/<round>-NN` remains on origin until the retro runs C7. The line is checked with `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` (csi-spl-orc) on the reviewer's box, where the `log:` is read, as any user that may `sudo -n -u` the log's owner; the `log:` names one session (a vibe session dir, never the store holding several), and the reviewer = `log:` owner and the vendor of the id are checked there too; on another box it exits 2 and prints that command, and `REVIEW_LINE_SYNTAX=1` checks there only the format, the reviewer = `log:` owner, the vendor of the id and of its `registry.tsv` row, and that `ran:` names a test (the run itself stays unchecked). A WUI commit (SPL-3438): when the line's sha touches `csi-spl-wui/`, the check also prints the e2e files the pre-push map selects for it (`E2E <sha> selects: ...`, read on the commit's own tree) and fails with `MISSING e2e <file>` (exit 3; `SYNTAX FAIL` when `REVIEW_LINE_SYNTAX=1` checks a log on another box) for each one `ran:` does not name, and a sha that is no commit in the repo is void (FATAL, exit 1): the reviewer runs those files, not only the ones the author picked. List them before the review with `cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`.
- **2.7.5 Review count verification:** `git log origin/master --grep='<round>-' --format=%B | grep -c '^review: '` must reach the total row count (10). The vendor pair is checked per row: a line names only the reviewer's vendor (its third field), so for each row `git log origin/master --grep='<round>-NN' --format=%B | grep '^review: ' | cut -d' ' -f3` must differ from the row's author vendor, the plan action table's vendor column, or, for a row re-placed on another vendor, the vendor letter of the id of the lane that pushed it. An equal pair fails 2.7.2, and the retro names the row. This replaces `grep -c 'same vendor'`, which could not fail: no line carries those words (refactor round 21 retro, section 4.3).
- **2.7.6 Review seats never commit code:** A review seat's lane-map scope is limited strictly to its seat file. Any code commit or branch push outside its seat file causes the seat to be stopped and re-placed.
- **2.7.7 Review Criteria C1–C7:**
  - **C1:** Diff touches only the action's sites and its tests (`git diff --stat`).
  - **C2:** Behaviour preserved (for code refactors), or the red control was verified RED then GREEN (for gates/tests), with commands and outputs in the commit body.
  - **C3:** No file shrank by more than the lines the action removes (`wc -l` before and after).
  - **C4:** Every test in the action's test column ran and passed, recorded in the `ran:` field. A column test the reviewer did not run is named in `read:` as `NOT RUN <test>: <why>`; a column test in neither `ran:` nor such an entry means the row does not pass, and the retro lists every `NOT RUN` entry. CI on the sha does not stand in for it: CI runs on master after the push, and the PASS comes before the push (2.7.3).
  - **C5:** No comment describes behaviour the code does not perform.
  - **C6:** Distribution hygiene and pre-push checks passed without override.
  - **C7:** The pushed sha matches the reviewed sha (`git diff <reviewed> <pushed> --stat` shows only trunk rebase commits; no action site changed after review).

<a id="ws-doc-c686c4ce-1bd6-4fff-bd8f-d8fa5088c44c"></a>
### 2.8 R8: Retrospective and seat teardown order

After all 10 actions are served:
- One lane writes the round retrospective (`refactor-round-<N>-retro.md` or bug round retro).
- The retro's final section compiles the measured input list for round `<N+1>`, and the dispatcher immediately requests the round `<N+1>` planner.
- Execution order:
  1. The retro lane verifies the review lines and executes C7 checks. It checks each line with `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` (csi-spl-orc). A line whose `log:` is on another box exits 2 and prints the command to run there: the retro lane runs the same line with `REVIEW_LINE_SYNTAX=1` on its own box, then sends that printed command (`spool-send.sh`, kind task) to the line's reviewer seat, which is on the log's box and still open (step 3 closes it). The seat runs it and sends back the command and its full output, which the retro quotes. A line with no such output is listed in the retro as not verified, never as OK.
  2. The retro lane prunes the round's remote branches (`ROUND=<N> DRY_RUN=0 ./run -a do_git_prune_round_branches`).
  3. The planner (editor seat) closes the reviewer seats. Any seat that performed zero reviews is closed upon the landing of the final row.

<a id="ws-doc-44530a78-281a-48ce-920b-659ac18cc5ba"></a>
### 2.9 R9: Gate lanes

Rows that modify gates, test runners, or CI checks must run their tests under `PRE_PUSH_TIER=full` and once with all `PRE_PUSH_*` environment variables unset before making their first push.

<a id="ws-doc-c0329da7-5d1c-4a9e-9231-e2a45133318c"></a>
### 2.10 R10: Hourly placement and progress checks

From plan signing until every row is landed:
- The orchestrator checks hourly for unplaced rows and missing reviewer seats via `git log` and `lane-map.sh`.
- Progress check: A live row lane with no branch commits and no outbox message for 30 minutes is marked as stalled (checked via `git log <lane-branch> -1 --format=%cI` and the latest outbox file timestamp).
- A stalled lane is pinged once; if no response is received within 15 minutes, it is re-placed.

<a id="ws-doc-33604b39-aef4-428c-a577-9730ed4d97ed"></a>
### 2.11 R11: CI verdict per row surviving master churn

- **2.11.1** A row's CI verdict is taken from the first COMPLETED workflow 10 run whose head commit contains the row's sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed`, checked with `git merge-base --is-ancestor <row-sha> <head>`), rather than a run on the row's individual sha.
- **2.11.2** That run must be green, or its first red job must not execute any of the row's tests, and the job running the row's tests must have reached and passed them (confirmed by test file name in the log).
- **2.11.3 Trunk-red watch:** In the hourly check, run `CI_GATE_RUNS=40 ./run -a do_report_ci_gate`. A first-red job observed in 2 consecutive completed runs is assigned an owning lane that hour. Flakes are assigned a fixing lane on their 3rd sighting. A trunk-red fix lands at once under a non-row subject, `fix(<area>, SPL-<n>)`, with `Refs: r<NN>-<row>` in its body (a row subject is refused by `do_spl_push_master` until a `review:` line exists); its R7 review (2.7.4) follows on the landed sha.
- **2.11.4** Workflow concurrency is preserved unless supported by prior measurement and a dedicated plan row.

<a id="ws-doc-392efae9-39d4-42e5-a155-abdc2738c160"></a>
### 2.12 R12: Verification command included with reported counts

Any count sent to an owner discussion regarding round progress ("N of 10...") must quote the exact R6 or R7.5 command and its output on that commit sha.

<a id="ws-doc-01fb7921-17be-441c-90b5-9caf6ca37c37"></a>
### 2.13 R13: Agent identities include box qualifier

All spawn replies, review lines, and placement reports must specify `<id>@<box>` (e.g. `<id>@<box> PASS`) whenever the identity is active or ambiguous across machines. Review lines must always include the box name.

<a id="ws-doc-c91af8a4-e654-45be-aa62-2cf2c40c3d18"></a>
### 2.14 R14: Vendor mix and early replacement

The planner assigns row vendors according to the fleet lane mix. If a vendor has not yet demonstrated reliability on a specific category of refactoring or bug fix, those rows are assigned to an established vendor (e.g. Claude) until reliability is proven. A lane is replaced on Claude at its first `SPL_PREPUSH_OVERRIDE` request or first repeated blocker.

<a id="ws-doc-804a3291-db11-4d46-bdd3-7a1090d30422"></a>
### 2.15 R15: History rewrite resilience

In the event of a trunk history rewrite, branches are rebased using `git rebase --onto`. Shas in plan documents are resolved by commit subject matching (`git log origin/master --format='%h %s' --grep='<subject words>'`). Plan rows depend on paths and symbols, never hardcoded commit shas.

<a id="ws-doc-32a00e29-7d99-4fc8-8d9a-5442ec3ec2e8"></a>
### 2.16 R16: Dependent batch placement SLA

Dependent Batch 2 and Batch 3 rows must be spawned within 30 minutes of their prerequisite row landing on trunk.

<a id="ws-doc-8fce2fb9-77a6-49f2-a941-2843f28827e5"></a>
## 3. Plan and panel structure

<a id="ws-doc-e9214908-8f39-4165-aedb-f1c73f2cafd7"></a>
### 3.1 Plan document requirements

Every round plan document (`refactor-round-<N>-plan.md` or `bug-round-<N>-plan.md`) must specify:
- **Baseline measurement:** Every site measured on a single `origin/master` commit sha, with commands and counts ($n$).
- **Action table:** At most 10 rows, detailing practice, rationale, file:line sites (at most 5), measurement command, test/red control, target box, vendor, agent kind, and batch.
- **Batch ordering:** Disjoint file sets in Batch 1; dependent actions in Batch 2 or 3.
- **Consensus table:** Record of panel signatures across vendors on the plan sha before row execution commences.

<a id="ws-doc-71fc4dca-f04b-47c6-a390-7d6591d16398"></a>
### 3.2 Panel review and signing

The planner submits the draft plan to a cross-vendor panel. All panel seats must sign the plan sha. Objections are folded into the final v1.0 plan commit before row spawning begins.

<a id="ws-doc-410e8643-573f-4718-bd1a-0f96a4f21ad2"></a>
## 4. Performance rounds: a permanent round kind

A performance round (perf round) is a round whose rows each make a measured part of the system faster or lighter: a page's load, a payload, a bundle, a query, a gate's or a lane's waiting time. It is a permanent round kind beside the bug-fix and the refactoring round, and it recurs like them.

Owner HUM-10, t1 #refactoring topic `8ebbed0e-d775-448e-9b50-c42e45b6e126`, 2026-11-12:
- msg afbbbcd2: *"Do we have a separate round for performance in the refactoring rounds?"*
- msg 271a4a68: *"If we do not have one, we should create a permanent one. Each round, when it starts, it should create a new discussion. When it has the discussions, then for each discussion, it should create a new discussion and do the improvements after each round."*
- 17:50:34Z: *"let's create the permanent capapicity for those to be at lest 20% of the refactoring overall on average"*

Before this section, perf rounds ran ad hoc: rounds 3 to 6 (`perf-audit-round3-2026-10-02.md`, `perf-round-4-plan.md`, `perf-round-5-plan.md` and its retro, `perf-round-6-plan.md`); the last p6 row landed 2026-10-20 and nothing made them recur.

<a id="ws-doc-d6aedaff-e492-4439-ae98-a6d4a7e10cf1"></a>
### 4.1 Same rules as a refactor round, measured first

A perf round follows every rule of sections 1 to 3 as a refactor round does: at most 10 rows (1.1), the pushes per row (1.2), R1 to R16, the plan and its cross-vendor panel (3.1, 3.2). Its rows are measured first ([lesson: measure first](lesson-speed-up-measure-first.md)):
- Each row's plan cell names its baseline: the command, the number and n, measured on one `origin/master` sha.
- Each row lands with a counting or timing test that guards the gain, and its red control (C2): the test fails on the slow code, passes on the fast one.
- A row whose measurement shows no gain is dropped from the round with that measurement, never landed as a guess.

<a id="ws-doc-b307b111-4f63-478e-97d1-1e8f6b03f19c"></a>
### 4.2 Continuous: round N served, round N+1 planned

Perf rounds run continuously, as 1.4 says for refactor rounds, and need no owner go:
- When perf round `<N>`'s rows are served (R5), the dispatcher holding the lease requests perf round `<N+1>`'s planner at once (`c-001` places it).
- Planner by day, rows by night, as in 1.4 ([spec 166](../../specs/166-orchestrator-daily-rhythm/spec.md) section 3.1): the planner and its panel run by day; the row lanes, their reviewer seats and the retro at night.
- A perf round runs beside the open refactor round. Under the 20% floor a perf round also takes the place of the next refactor round (4.4, the owner's rule). R1 (disjoint files) and R3 (the `lane-map.sh --check` before a spawn) hold across both: a perf row never spawns on a path a refactor row holds, nor the reverse.

<a id="ws-doc-86f37c03-f1bb-4be8-afde-a5ae2cb65534"></a>
### 4.3 One discussion per round, one per row

- **The round's discussion.** When the holder requests a perf round's planner (4.2), it opens ONE new discussion for the round: a new topic in the t1 #refactoring channel (`cd csi-spl-orc && ./run -a do_spl_desk_post`), titled `Perf round <N>`, with its issue filed from the first answer (`LANE_ISSUE_OP=discussion ./run -a do_spl_lane_issue`). The planner brief's `Ask-Topic:` names it. The plan sha, the panel's signatures, the progress counts (R12) and the retro are posted there.
- **A discussion per row.** Each row (each finding) of the signed plan gets its OWN discussion: the holder opens a topic for it in the same channel when it queues the row, links it from the round's discussion, and the row brief's `Ask-Topic:` names it. The row lane carries its own issue ([lane issue and docs](lane-issue-and-docs.md)). Talk about one row stays in that row's topic.
- **Each round improves the next.** The retro (R8, `perf-round-<N>-retro.md`) names what the round improved, with its numbers, and what it found but did not fix. Its last section is the measured input list for round `<N+1>`, and the round `<N+1>` planner starts from it. A finding that is not perf work goes to the orchestrator as its own ask.

The holder opens these topics by hand today; no action opens them yet: follow-up row F2 (4.6).

<a id="ws-doc-7b63b964-ff47-42db-965c-82550491b5eb"></a>
### 4.4 Share: at least 20% of the refactor capacity over 14 days

The owner's decision (17:50:34Z, section 4): perf rounds take **at least 20% of the refactor capacity, on average**.

- Perf rows are queued as `SPAWN_CLASS=refactor`: they take their lanes from the refactor class. The class bands (the [fleet rules index](fleet-rules-index.md), SPL-1817 row) do not change; this rule splits the refactor class.
- **What is measured:** the round rows landed on `origin/master`. A row counts once, by its id in a landed commit subject of type `test`, `refactor`, `ci`, `fix`, `feat` or `perf` (the types `do_spl_push_master` checks as round rows; a `revert(...)` is not counted): `p<N>-<NN>` perf, `r<N>-<NN>` refactor, whatever its number of pushes. The share is perf rows / (perf rows + refactor rows).
- **The window:** the last 14 days, rolling. A round of 10 rows lands over several nights, so a shorter window swings with whichever round happens to be open; 14 days spans several rounds of each kind.
- **How the holder checks it:** at every round boundary (each time it requests a planner, 1.4 or 4.2), from any checkout of this repository on a fresh fetch. The verdict compares the exact counts (5 × perf ≥ perf + refactor), never the rounded percentage:

```bash
git fetch -q origin master && git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '/^p/{p++} /^r/{r++} END{t=p+r; printf "perf %d refactor %d perf-share %s %s\n", p, r, (t ? sprintf("%.1f%%", 100*p/t) : "n/a"), (t == 0 ? "no-rows" : (5*p >= t ? "floor-met" : "under-20"))}'
```

- **Under 20%, a perf round replaces a refactor round** (owner HUM-10, poll 81980f01, msg 98dedfc4): once the open refactor round is served (R5), the holder requests the next perf round's planner instead of refactor round `<N+1>`'s. Refactor rounds wait until the check prints `floor-met` again. The open refactor round is never stopped; 1.4 carries the matching exception.
- Measured on `origin/master` 4061ee214 (the count moves with every land, so re-run it rather than quote it), the command above printed `perf 0 refactor 135 perf-share 0.0% under-20`. The first rounds under this rule start below the floor, so the refactor round after the open one is a perf round.

Enforced by: the holder's check at each boundary (review only). The placer does not enforce it yet: follow-up row F1 (4.6).

<a id="ws-doc-a9a1e495-1084-405b-aaf4-58358ff1984b"></a>
### 4.5 Ids and where the plans live

- **Round id** `p<N>`, numbered on from the ad hoc rounds: the first round under this section is `p7` (the newest perf row on `origin/master` is a `p6` one). **Row id** `p<N>-<NN>`, two digits, 01 to 10 (1.1).
- **Commit subject:** `<type>(p<N>-<NN>-<slug>, SPL-<n>): ...`, usually `perf`. `do_spl_push_master` already treats it as a round row: it refuses a `pN-NN` row with no R7 `review:` line (`csi-spl-orc/src/bash/run/spl-push-master.func.sh`, the `[rbp]` subject match). The review branch is `review/p<N>-<NN>`.
- **Status (R6):** `git fetch origin master && git log origin/master --grep='(p<N>-' --format='%h %cI %s'`; the slug check before a spawn (R4) greps `p<N>-<NN>-`.
- **Where the plans live:** a Qto `system` doc exported to `csi-spl-doc/doc/md/perf-round-<N>-plan.md` (imported once with `do_spl_doctree_import_md`, `QTO_FS=repo`, then edited in Qto), its panel's seat files under `csi-spl-doc/doc/md/perf-round-<N>/`, and the retro in `csi-spl-doc/doc/md/perf-round-<N>-retro.md`. Round 5 is the one complete example (plan, seat dir, retro); round 4 left a plan only, round 6 a plan and seat files with no retro. From p7 every round has all three.

<a id="ws-doc-b643a963-080c-47f1-8182-35139654bf00"></a>
### 4.6 Not built yet: follow-up rows

Two parts of this section are kept by the holder by hand; each is a follow-up row, not built here:

- **F1, the placer enforces the 20% floor.** The placer reads the perf share of the refactor class and, under 20%, refuses the next refactor round's planner (the open refactor round's rows still place) and names the next perf planner to the holder, as 4.4 says. Files: `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh` (`SPL_SPAWN_BANDS`, the share read), `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (`spl_spawn_place_band`), `csi-spl-orc/src/bash/run/spl-spawn-queue.func.sh` (the queue's order), their tests `csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh` and `spl-spawn-place-argmax.tst.sh`, and the SPL-1817 row of the [fleet rules index](fleet-rules-index.md). The class bands stay as they are.
- **F2, an action opens the round's discussions.** A named action (`do_spl_round_open`, new: `csi-spl-orc/src/bash/run/spl-round-open.func.sh` and its test `csi-spl-orc/src/bash/tests/spl-round-open.tst.sh`) opens the round's topic when its planner is requested and one topic and issue per row when the row is queued (4.3), through `do_spl_desk_post` and `do_spl_lane_issue`.
