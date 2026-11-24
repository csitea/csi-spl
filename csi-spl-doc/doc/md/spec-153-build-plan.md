# Spec 153 build round: the Queue tab, rows Q1-Q12 (plan)

Epic: SPL-2403  
Spec: csi-spl-doc/specs/153-monitoring-lanes-tab (section 3.22, rows 3.22.11)  
Issue: SPL-6372 (this plan). Each row gets its own issue when it is placed.  
Discussion: t1 `906c1b28-4d23-4fd0-ad3b-7a9422238f04`. The dispatch holder owns it. The owner's go is poll `c6a6e020` answer A (msg `138ee818`, 2026-11-24 07:06Z): "Plan it as a build round now: a planner orders Q1-Q12, a panel signs it, the rows are queued".  
Owner addendum: msg `ae2caeb2` (08:34Z). The topic multi-select of spec 186 v0.6 is ONE shared select phase. Spec 153 reuses it and builds no second one (section 6, H2).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) sections 2 (R1-R16), 3.1, 3.2 and 5, linked here and not copied.

**Status: v1.0, signed.** v0.1 `7bef22db8`. v0.2 records the owner's answers to H1-H7 (section 6.1): all A. The panel seat m-072 (mistral) signed v0.2 PASS on `b2b8e4bae`, and the holder c-002 gave the GO. v0.2 landed on master as `6b6413c30`. v1.0 adds the signature, the findings N1-N4 and the holder's ruling on N1 (sections 3, 8 and 9). The rows are not changed.

Editor: **c-057** (claude, `specs_and_docs`, the backup vendor: agy is on its usage limit, per the brief).  
Panel: one cross-vendor seat (mistral or grok), placed by the holder (rulebook 3.2).

**One sha.** Every count and every file:line below was measured on **`dbd127c96`** (`origin/master` at this seat's fetch, 2026-11-24 ~10:10Z), n = 1 per command, unless a line says otherwise. The spec's own line numbers are from `fe0455e48` (2026-11-07). Where a line moved, section 2 gives both.

---

## 1. How to read this

- Paths are repo-relative. `<api>` = `csi-spl-api/src/go/spool-hub-api/internal`, `<orc>` = `csi-spl-orc/src/bash`, `<wui>` = `csi-spl-wui/src`. The spec writes `wui/...` for `csi-spl-wui/src/...` and `orc/...` for `csi-spl-orc/src/bash/...`.
- "Built" means a grep on `dbd127c96` finds the behaviour. Every grep is quoted with its result.
- Boxes have no names here: the repo is public. `<box-a>` is the box the holder runs on and `<box-b>` is the other fleet box.
- This plan adds no design. Where the spec and the code disagree, or the spec leaves something open, section 6 asks the holder. The holder asked the owner with one form, and section 6.1 records the answers. Where an answer changes a row, the row says so.

---

## 2. What is already built (re-measured on `dbd127c96`)

| check | command | result | what it means for the rows |
|---|---|---|---|
| a Queue route, tab or page | `git grep -n -E 'fleet-queue\|fleet-asks/\|fleet_place_state\|fleet_flow_daily\|prio_helpers\|SPAWN_PARENT_LANE\|SPEC_IMPORT_PLAN' dbd127c96 -- csi-spl-api csi-spl-orc csi-spl-wui csi-spl-rdb csi-spl-cnf` | 0 lines | nothing in Q2-Q12 is built |
| new files the rows create | `git cat-file -e dbd127c96:<path>` for `<api>/hub/fleet_ask_order.go`, `fleet_queue_view.go`, `fleet_lane_priority.go`, `fleet_queue_plans.go`, `workspace_queue_view.go`, `fleet_flow.go`, `<orc>/run/spl-flow-daily.func.sh`, `<wui>/pages/monitoring/queue/index.vue`, `<wui>/utils/monitoring-queue.mjs` | all 9 MISSING | as planned |
| **Q1's priority 1 early return** | `git show dbd127c96:<orc>/run/spl-spawn-place.func.sh \| sed -n 456,459p` | `if jq -e '(.priority // 3) == 1' ... "is placed first, ahead of the bands (SPL-5524)"` | **built** by `2357968fd` (`feat(api, SPL-5524)`, 2026-11-15). Its test is `<orc>/tests/spl-spawn-place-owner-prio.tst.sh`: case 1 is "a priority 1 feature head is placed first: ahead of the bug under its band", and cases 2-3 are its controls. That is C119's pick. Q1 keeps the `bypass.tsv` record, the dragged head and the rules row (section 3, Q1) |
| Q1's `bypass.tsv` line for a priority 1 pick | `sed -n 447,476p` of the same file | the priority 1 branch only calls `do_log` (`:457`). It writes no `bypass.tsv` line | not built (C119's last sentence) |
| ci row first in the placer | same file `:449-453` | a queued `ci` row is taken before the priority 1 check | the placer already does what C121 asks. The hub's `askPositions` (`<api>/store/fleet_ask.go:293-317`) still orders by `askPrio` first, so C121 is still red in the hub (Q2) |
| the band sort | same file `:474` | `sort_by(._t, -._s, ._o, .position)` | moved from the spec's `:366` |
| request rank columns | `git grep -n -E 'queue_rank\|priority_source\|hold_reason\|rank_by' dbd127c96 -- <api> csi-spl-rdb` | 0 lines | Q2 not built. `askQueueRank` (`fleet_ask.go:166-168`) is the **class** rank (rdb 0195), not a drag rank. Q2 must not reuse that name for `queue_rank` |
| the cross-workspace discussion | `<api>/hub/box_ask.go:292-307` (`askDiscussion`) | looks up only `tenant` (`TopicsByPrefix(ctx, tenant, m[1], 2)`) | C113's read side is not built. **But** `d3dc6f544` (`fix(api, SPL-5905)`, 2026-11-18) chose to copy an operator owner's set **into the operator workspace** instead. Its message says the read side "reads any workspace's row, so a non-operator owner's set moves op's queue", and that change turned `TestOwnerPrioWordOperatorQueue` red. That conflicts with 3.22.6 "Across workspaces": **H1** |
| an ask's discussion by hand | `<orc>/run/spl-spawn-enqueue.func.sh:54` | `@param ASK_DISCUSSION` (spec 150 row B10b) | exists. Fewer rows should have `discussion` NULL than the 93 of 122 the spec counted on 11-07. Not re-counted on prd here |
| the filler's gate | `<orc>/run/spl-spawn-fill.func.sh:79-80` | `jq -e 'length == 0'` on the queue rows, else "the spawn queue is not empty" | moved from the spec's `:72`. The skip filter is at `:249` (spec `:184`) |
| the filler switch | `csi-spl-cnf/csi-spl/all.env.yaml:1370-1371` | `spawn_fill: enabled: true` | on (spec `:1190`) |
| spec import | `git grep -o 'SPEC_IMPORT_[A-Z_]*' dbd127c96 -- <orc>/run/spl-spec-import-issues.func.sh \| sort -u` | `CREATE_EPIC DOCS INTERVAL LABELS LIMIT OFFLINE OUT REDACT SPECS` | there is no `SPEC_IMPORT_PLAN` and no `SPEC_IMPORT_PLAN_TABLE`, so Q12 is not built |
| the Lanes tab's Prio cell | `<wui>/pages/monitoring/lanes/index.vue:130-131` | a read-only `<span class="ln-prio">` | Q5's chooser is not built |
| the tab list | `<wui>/utils/monitoring-tabs.mjs:30,33` | `lanes`, then `topics` | Q4 puts `queue` right after `lanes` (C105) |
| the lanes mock | `<wui>/utils/monitoring-lanes.mjs:28,463` | the mock lives in the util (`LANES_MOCK_KEY`), not in `spool-client-mock.mjs` | Q4's mock goes into `monitoring-queue.mjs` the same way |
| a route registers in `server.go` | `<api>/hub/server.go:598-614` | one `s.routeX(mux)` line per operator route, e.g. `:599 routeFleetLanes` | every new route is one `server.go` line plus `openapi.json`. Q7, Q8b and Q10 add routes, but the spec's file lists leave out `server.go` (section 4) |
| the placer's hold, readable by the hub | `git grep -n -E 'ASK_REASON\|--reason' dbd127c96 -- <orc>/run/spl-spawn-place.func.sh` | 0 | Q3's `ask_op holds` is not built. `lanes_queued.go:62` still reads `Wait: a.Reason` |
| the rdb head | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -1`; `git ls-remote origin 'refs/rdb-claims/*' \| tail -1` | `0319_workspace_cancellations.sql`; claim `0320` | Q2 and Q10 each claim their number with `do_rdb_migration_next` at build time, never one written here |
| spec 186's select phase | `csi-spl-doc/specs/186-multicast-prompt/spec.md` 8.3 and row M3 (v0.6, `09a147c24`) | "Spec 153's Q1-Q12 plan reuses M3 and adds no second topic multi-select; its row that needs it waits on M3. ... the priority action, its route and its tests are 153's" | no Q row builds the bulk **Set priority** action, and spec 153 has no section for it: **H2** |

---

## 3. The rows

Kind and vendor come from `do_spl_lane_mix`, read at 10:13:58Z-10:14:05Z on `<box-a>`:

- `simple_coding` -> `pick=agy` (main claude, backup agy, "agy has 2 of the last 10"). agy is on its usage limit until 2026-11-30T21:31Z (the brief, the holder's watchdog). The holder re-runs the mix at queue time, and with agy still out the row goes to the backup, **claude**.
- `complex_coding` -> `pick=claude`.
- `tests` -> `pick=claude`. No row is of this kind.

R7 for a claude-authored row is **grok**. `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 10:14:09Z gave `pick=<box-b>` (grok weekly 93% on both boxes, load at or over the high mark on both). That is a pick, not a hold. If grok goes on hold on both boxes before a row's review, the holder rules on the reviewer then. This plan does not set a fallback. The backup seat is mistral if the owner's mistral-review pause no longer applies, which is the holder's call.

**The holder's ruling on N1 (v1.0).** At the panel's re-read, `do_spl_box_pick` gave `pick=hold` for grok: weekly 95% on both boxes, held until 2026-11-28. The holder c-002 ruled (GO msg `a8956e9f`): while box_pick holds grok, each row's R7 seat goes to the claude waiver seat (`1a7c70da`), cross-vendor to the author where possible. An agy-written row is reviewed by claude. A claude-written row is reviewed by the claude waiver seat, per `1a7c70da`. Where the table below says "(grok)", read it as this seat for as long as the hold lasts. The holder re-reads box_pick at each placement.

| row | what is left to build | kind | vendor (R7) | after | cases |
|---|---|---|---|---|---|
| Q1 | the `bypass.tsv` line (`prio1:<priority_by>` / `drag:<rank_by>`) and the dragged-head early return, both in `spl_spawn_place_band`; the fleet-rules spawn-queue row. The priority 1 return is built (section 2) | `simple_coding`, class bug | claude (grok) | Q2 (the row carries `priority_by`, `rank_by`), Q3 (same placer file), Q8 (same rules file) | C119 (the bypass line), C120 |
| Q2 | the rank columns, the effective priority, both PUTs, `ask_op position`, C121 in `askPositions` | `complex_coding` | claude (grok) | c-918's spec 181 B11 lands (R3, section 5) | C111-C113, C115-C118, C121 (C113 as H1 A: the copy) |
| Q3 | `GET /v1/operator/fleet-queue`, the `lane` field, `ask_op holds` | `complex_coding` | claude (grok) | Q2; Q9 (the shared test file) | C102-C104, C122 |
| Q4 | the read-only Queue tab | `complex_coding` | claude (grok) + language check | Q3; c-918's B11 (`spool-client-lazy.mjs`) | C105-C107 |
| Q5 | the 1..5 chooser on a request and in the Lanes Prio cell, `PUT .../fleet-lanes/{id}@{box}/priority` | `complex_coding` | claude (grok) + language check | Q4 | C114 |
| Q6 | drag, Move up / down / to position | `complex_coding` | claude (grok) + language check | Q5 | C115 through the page |
| Q7 | the Plans table and its route | `complex_coding` | claude (grok) + language check | Q6 (the page) | C108-C110 |
| Q8 | an issue at priority 1 or 2 passes the filler's "queue empty" gate | `simple_coding` | claude (grok) | Q9 (the rules file); H4 A: a person-set priority only | - (the spec names no case; its test is in the spec's row) |
| Q8b | the workspace readers' route and tab rule | `complex_coding` | claude (grok) | Q7 (the page) | - (as C25/C26) |
| Q9 | helpers by priority in `do_spl_spawn_enqueue` | `complex_coding` | claude (grok) | - | C125 |
| Q10 | the flow record and the daily rollup | `complex_coding` | claude (grok) | Q1 and Q3 (the placer file); H5 A: PUT + GET | C123 |
| Q11 | the flow table on the page | `simple_coding` | claude, agy if back (grok, or claude if agy wrote it) + language check | Q10, Q8b (the page) | C124 |
| Q12 | `SPEC_IMPORT_PLAN` files a signed plan's rows as issues | `simple_coding` | claude, agy if back (grok, or claude if agy wrote it) | - | C126 |
| Q13 (proposed) | the bulk **Set priority** action on spec 186's select phase | - | - | spec 186 M3 and M4, Q5, and spec 153 section 3.30 (H2 A) | none until 3.30 exists |

**Language check (the WUI text rows Q4, Q5, Q6, Q7, Q11).** The spec's rows say "agy language review BEFORE land: push `review/<slug>`, ask the dispatch holder for the agy reviewer, land only after its PASS". The repo `CLAUDE.md` makes `do_spl_lang_review_gct` (Google Cloud Translation) the language check and agy optional (owner msg `36b3ff7f`). The owner answered H6 A ("Google Cloud Translation check, agy optional"): each brief names `do_spl_lang_review_gct` on the new keys before the land. An agy review is optional and no row waits for one. Q8b adds no text key. Q1-Q3, Q8-Q10 and Q12 have no UI text.

---

## 4. Files per row (re-measured), done test and red control

The file lists are the spec's 3.22.11, re-pointed to the lines on `dbd127c96`. **Bold** marks an addition this plan makes, each with the reason.

- **Q1.** Files: `<orc>/run/spl-spawn-place.func.sh` (`spl_spawn_place_band` `:447-476`, the priority 1 branch `:456-459`); **`<orc>/tests/spl-spawn-place-owner-prio.tst.sh`** (C119 lives there now, not in the argmax test); `<orc>/tests/spl-spawn-place-argmax.tst.sh` (C120); `csi-spl-doc/doc/md/fleet-rules-index.md:55` (the spawn queue row).
  - Done: the priority 1 pick writes one `bypass.tsv` line (time, ask id, `prio1:<priority_by>`, the holder). A head with `rank_by` is taken past the bands, and a dragged row at position 3 under a plain head does not stop the band pick. Until Q2 lands, the test stubs `priority_by` and `rank_by` on the row JSON. Q2 first is the order proposed here.
  - Red controls: no `bypass.tsv` line on `dbd127c96`; the `rank_by` early return taken out (C120).
  - Why Q1 no longer goes "at once and alone": its urgent half landed on 11-15. What is left reads Q2's fields, and it shares the placer with Q3 and Q10.
- **Q2.** Files: a new `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_fleet_ask_queue_order.sql` (`do_rdb_migration_next`, not 0320 written by hand); `<api>/store/fleet_ask.go` (`askPrio :253`, `askFillPriorities :263`, `askPositions :293`; the memory store's `ListFleetAsks :483` is in the same file); `<api>/store/fleet_ask_postgres.go` (`ListFleetAsks :138`, `askListPriorities :168`); `<api>/hub/box_ask.go` (`askDiscussion :292` stays as it is, H1 A, the `ask_op position` case in the switch `:229-245`); a new `<api>/hub/fleet_ask_order.go` + `_test.go`; one line in `<api>/hub/server.go` (beside `:599`); `<api>/hub/openapi.json`. Run with `PRE_PUSH_TIER=full`.
  - Done: C111-C118 and C121 on memory and Postgres.
  - Red controls: as the spec states them, except C113. H1 A keeps SPL-5905's copy and drops the cross-workspace read, so C113 tests the copy: an ask on another workspace's discussion that the operator owner set reads that priority from the operator workspace. Red control: `priorityToOperator` taken out. C121 ranks a ci row first (H3 A).
  - Name `queue_rank`'s Go accessor something other than `askQueueRank`, which already exists as the class rank.
- **Q3.** Files: a new `<api>/hub/fleet_queue_view.go` + `_test.go`; one line in `server.go`; `openapi.json`; `box_ask.go` (`ask_op holds`); `<orc>/run/spl-spawn-place.func.sh` (the holds send only); `<orc>/tests/spl-spawn-queue.tst.sh` (C103 against `spl_spawn_q_rows`, `<orc>/run/spl-spawn-queue.func.sh:123`).
  - Done: C102-C104 and C122.
  - Red controls: no route; C103's planted `class` filter.
- **Q4.** Files: `<wui>/utils/monitoring-tabs.mjs` (after `:30`); a new `<wui>/pages/monitoring/queue/index.vue`; a new `<wui>/utils/monitoring-queue.mjs` (with its mock, as `monitoring-lanes.mjs:28` does); the client call in `<wui>/utils/spool-client-lazy.mjs` (beside `:2073-2086`); `csi-spl-wui/i18n/locales/*.json` (19 files, new keys only); `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs`; a new `csi-spl-wui/tests/unit/monitoring-queue.test.mjs`; `csi-spl-wui/tests/e2e/monitoring-costs.test.mjs`.
  - Done: C105-C107 at 1440 and 390 px, plus the e2e files the pre-push map selects (`WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`), which the R7 runs too (rulebook 2.7.4).
  - Red controls: the page absent; C107's planted static import.
- **Q5.** Files: the Queue page; `<wui>/pages/monitoring/lanes/index.vue` (the Prio cell `:130-131`); `monitoring-queue.mjs`; the client call; a new `<api>/hub/fleet_lane_priority.go` + `_test.go`; one line in `server.go`; `openapi.json`; locale keys.
  - Done: C114 in Go and e2e.
  - Red controls: no route; no chooser.
- **Q6.** Files: the Queue page; `monitoring-queue.mjs` (the two neighbours, `stale_position`); locale keys; `monitoring-costs.test.mjs`.
  - Done: the mouse and Move to position, at 1440 and 390 px.
  - Red control: no handle.
- **Q7.** Files: a new `<api>/hub/fleet_queue_plans.go` + `_test.go`; **one line in `server.go` and `openapi.json`** (a new route needs both, section 2); the Queue page; locale keys.
  - Done: C108-C110.
  - Red control: C109's filter taken out.
- **Q8.** Files: `<orc>/run/spl-spawn-fill.func.sh` (the gate `:79-80`); `<orc>/tests/spl-spawn-fill.tst.sh`; `csi-spl-doc/doc/md/fleet-rules-index.md:56` (the filler row).
  - Done: a priority 2 issue with a non-empty queue queues one; a priority 3 issue queues none.
  - Red control: on master, none is queued.
  - H4 A ("Only a priority a person set"): the gate passes an issue at 1 or 2 only when a person set that priority. A bug's class default of 2 (`issue_prio_default.go`) does not pass. A second case pins this: a bug issue at its default 2 with a non-empty queue queues none.
- **Q8b.** Files: a new `<api>/hub/workspace_queue_view.go` + `_test.go`; **one line in `server.go` and `openapi.json`**; `monitoring-tabs.mjs`; the Queue page. No new text key.
  - Done: as C25/C26.
  - Red control: a member of w2 reads w1's row.
- **Q9.** Files: `<orc>/run/spl-spawn-enqueue.func.sh` (a new `@param SPAWN_PARENT_LANE` beside `:48-58`); `<orc>/tests/spl-spawn-queue.tst.sh`; `csi-spl-cnf/csi-spl/all.env.yaml` (`env.box.prio_helpers`; then `ENV=<env> ./run -a do_tpl_gen` and `git diff --exit-code`, as the repo CLAUDE.md requires for a cnf change); `fleet-rules-index.md`. No UI text.
  - Done: C125.
  - Red control: no check.
- **Q10.** Files: `<orc>/run/spl-spawn-place.func.sh` (one line per tick, `fleet_place_state`); `<orc>/run/spl-push-master.func.sh` (one line per push); a new `<orc>/run/spl-flow-daily.func.sh` + `<orc>/tests/spl-flow-daily.tst.sh`; a new `<next>_fleet_flow_daily.sql`; a new `<api>/hub/fleet_flow.go` + `_test.go`; **`server.go` + `openapi.json`** for its write and read routes (H5 A: an operator `PUT` for the rollup and a `GET` for Q11, both in `fleet_flow.go`); `csi-spl-orc/cnf/box-crons/box-crons.manifest`. Run with `PRE_PUSH_TIER=full`.
  - Done: C123.
  - Red control: a tick counted twice.
- **Q11.** Files: the Queue page or a new child component; `monitoring-queue.mjs`; locale keys.
  - Done: C124.
  - Red control: no table.
- **Q12.** Files: `<orc>/run/spl-spec-import-issues.func.sh`; `<orc>/scripts/spec-import-issues.py`; `<orc>/tests/spec-import-issues.tst.sh`; `csi-spl-doc/doc/md/lane-issue-and-docs.md` (the signing step). No UI text.
  - Done: C126.
  - Red control: the plan's rows are not read.
  - Once Q12 lands, the planner of this round files the rows of section 3 with it (the step it adds).

---

## 5. Batches (R1 disjoint per batch, R3, R16)

| batch | rows | shared file that orders them | starts when |
|---|---|---|---|
| 1 | **Q2, Q9, Q12** | - (disjoint: api/rdb; orc enqueue + cnf + rules row; orc import + lane doc) | at the GO. Q2 also waits on R3: c-918's B11 holds `server.go` and `openapi.json` |
| 2 | **Q3, Q8** | Q3 after Q2 (`box_ask.go`, `server.go`, `openapi.json`) and after Q9 (`spl-spawn-queue.tst.sh`); Q8 after Q9 (`fleet-rules-index.md`) | within 30 min of the last prerequisite landing (R16) |
| 3 | **Q1, Q4** | Q1 after Q3 (the placer) and Q8 (the rules file); Q4 after Q3 (the route) | as above |
| 4 | **Q5** | after Q4 (the page, the client, `server.go`) | as above |
| 5 | **Q6, Q10** | Q6 after Q5 (the page; no hub file); Q10 after Q1 (the placer) and Q5 (`server.go`) | as above |
| 6 | **Q7** | after Q6 (the page) and Q10 (`server.go`) | as above |
| 7 | **Q8b** | after Q7 (the page, `server.go`) | as above |
| 8 | **Q11** | after Q8b (the page) and Q10 (its data) | as above |
| - | Q13 | after spec 186 M3 + M4, Q5, and its spec 153 section (H2) | not placed by this plan |

The page rows Q4 -> Q5 -> Q6 -> Q7 -> Q8b -> Q11 run in a serial chain. The spec says so ("touch one page and the locale files, so they land one after another"), and each one also adds locale keys.

**R3 on `dbd127c96`, read 2026-11-24 ~10:11Z.**

- `lane-map.sh --check <every path of section 4 that exists> --agent c-057` exited **3**. That means a live lane holds at least one of those paths. The answer came from the hub, with no `LOCAL-ONLY`. Every other path is free. The three held paths:
  - `<api>/hub/openapi.json`, `<api>/hub/server.go` and `<wui>/utils/spool-client-lazy.mjs` are owned by **c-918** (`c-918-c002-s181-b11-signin-relay`, spec 181 B11, "changed in its worktree").
  - Q2, Q3, Q4, Q5, Q7, Q8b and Q10 touch them, so each one waits for B11 to land or re-checks at placement.
- The queue, from `do_spl_spawn_queue` at ~10:12Z: 8 queued, 0 placing.
  - `c002-r96-02-iac-gh-wire-repo-parse` touches `csi-spl-iac`, which is disjoint from every row here.
  - The other 7 are spec and planner lanes (`c002-agent-login-from-wui-spec`, `c002-perf-round-19-planner`, `hand-sat-c002-s187-build-planner`, `c002-msg-card-revoke-spec`, `c002-perf-round-20-planner`, `hand-sat-c003-s149-delete-synced-in-google-spec`, `c002-s154-contacts-switch-synced-elsewhere`). Their scope is docs. Their briefs were not read here.
- Spec 186's M1-M11 are not in the queue. The holder re-checks the lane map at each placement, because these numbers move.

**Round size.** Rulebook 5.1 aims at 2-3 rows a round for bug and refactor rounds. This is a spec build round under one plan, as the brief asks, and 1.1's cap of 10 rows is exceeded by 13 rows (Q1-Q12 with Q8b). The batch table keeps at most 2 rows live at once. If the holder wants the round split, the cut is after batch 3 (Q1-Q4, Q8, Q9, Q12 = 7 rows), with Q5-Q11 as a second plan. The owner answered H7 A: one plan, 13 rows in 8 batches.

---

## 6. Questions for the holder (to the owner as a form, where they need the owner)

- **H1 (Q2, C113): the cross-workspace priority.** Spec 3.22.6 says `askDiscussion` and `askListPriorities` read other workspaces' topics. `d3dc6f544` (SPL-5905, 11-18) rejected that read side: a non-operator owner's set would move the operator queue (its R7 W1), and it copies the operator owner's set into the operator workspace instead. Options:
  - (A) Drop the read side from Q2. C113 then tests the copy: an ask on another workspace's discussion gets the priority the operator owner set.
  - (B) Keep the spec and the read side, with SPL-5905's guard re-stated.
  - The planner recommends (A): it is what master does, and it keeps that guard.
- **H2 (Q13): bulk Set priority on spec 186's select phase.** Spec 186 8.3 hands spec 153 the action, its route, its `topic_select` action value and its permission. Spec 153 has none of these, and no Q row builds it.
  - Proposed: a spec 153 v-next section (3.30, written by a `specs_and_docs` lane) that defines it, then a row Q13 after M3, M4 and Q5. Answered A: section 3.30 first, then Q13.
  - Q1-Q12 do not need it: the per-row chooser of Q5 is a single-row action.
  - Until that section exists, no Q row waits on M3.
- **H3 (Q2, C121): a `ci` row ranks as priority 1 in `askPrio`.** The spec (3.22.8) calls this "a choice this spec adds; the holder may ask the owner". The placer already takes a ci row first (`:449-453`). Q2 makes the hub's order agree with it. The question is whether to ask the owner before Q2 lands.
- **H4 (Q8): bugs are priority 2 now.** Q8 lets "an issue the owner set to priority 1 or 2" pass the filler's queue-empty gate. Since rulebook 5.4 and F4 (SPL-5930, 11-18), every bug issue defaults to 2 (`<api>/hub/issue_prio_default.go`, `"bug": 2`). As written, Q8 would therefore pass every open bug issue, one per tick, whatever the queue holds. The spec (11-07) predates that rule. Options:
  - (A) Pass only an issue whose priority was set by a person (`priority_by` not the default).
  - (B) Pass priority 1 only.
  - (C) As written.
  - Bug round 44 counted 7 open bug issues in t1 (its source 3, 08:58Z). Not re-counted here.
- **H5 (Q10): the rollup's write and read path.** The spec names `hub/fleet_flow.go` but no route or `ask_op`. Proposed: an operator `PUT` for the rollup and a `GET` for Q11, both in `fleet_flow.go`, registered in `server.go` (as section 4 lists).
- **H6 (Q4-Q7, Q11): agy or gct.** These rows say "agy language review BEFORE land". The repo `CLAUDE.md` makes `do_spl_lang_review_gct` the check and agy optional (msg `36b3ff7f`). agy is out until 2026-11-30T21:31Z. The question is whether these rows land on the gct check or wait for agy.
- **H7: the round size.** Is one plan of 13 rows in 8 batches right, or should it split after batch 3?

### 6.1 The owner's answers

Owner HUM-10, t1 `906c1b28`, msg `5e11eca7`, answering form `ced5bc93`. The dispatch holder c-002 forwarded it in msg `7a57a706`. Verbatim:

> "Answer 1: A — Keep the copy, drop the cross-workspace read Answer 2: A — Spec 153 section 3.30 first, then row Q13 Answer 3: A — Yes, as the placer already does Answer 4: A — Only a priority a person set Answer 5: A — Operator PUT plus GET in fleet_flow.go Answer 6: A — Google Cloud Translation check, agy optional Answer 7: A — One plan, 13 rows in 8 batches"

| question | answer | where it lands |
|---|---|---|
| H1 | A: keep SPL-5905's copy, drop the cross-workspace read | Q2; C113 tests the copy |
| H2 | A: spec 153 section 3.30 first, then Q13 | a `specs_and_docs` lane writes 3.30; Q13 is planned after it |
| H3 | A: a ci row ranks first, as the placer already does | Q2, C121 |
| H4 | A: only a priority a person set passes the filler | Q8 |
| H5 | A: an operator PUT and a GET in `fleet_flow.go` | Q10, Q11 |
| H6 | A: the gct check, agy optional | Q4-Q7, Q11 |
| H7 | A: one plan, 13 rows in 8 batches | section 5 |

The spec's own text still reads as v1.x: 3.22.6 "Across workspaces", Q8's gate and the language line of 3.22.11 do not yet carry these answers. A spec addendum that records them is the 3.30 lane's to write, together with 3.30 itself. This plan does not edit the spec.

---

## 7. Proposed row briefs

Every brief carries the same header lines:

- `Epic: SPL-2403`
- `Spec: csi-spl-doc/specs/153-monitoring-lanes-tab`
- `Topic: 906c1b28-4d23-4fd0-ad3b-7a9422238f04`
- `Class: feature`, except Q1, which is `bug`
- its `Kind:` from section 3
- its own `Issue:`, filed at placement
- its R7 seat
- its row text from sections 3 and 4, verbatim (R4)
- "files (only these)", naming the files it must NOT touch: the other rows' files of its batch

The steps of each row are the spec's 3.22 text for that row. The brief cites the subsection, never a copy of it.

- **Q1 prio 1 / dragged head and the bypass record** (`simple_coding`, bug, after Q2, Q3, Q8). Read 3.22.8 "An owner's top priority beats the band pick" and C119, C120.
  - The priority 1 return already exists (`spl-spawn-place.func.sh:456-459`, SPL-5524). Add the `bypass.tsv` line beside it, and the same early return for a head with `rank_by`.
  - Update the spawn queue row of `fleet-rules-index.md`.
  - Tests: `spl-spawn-place-owner-prio.tst.sh` and `spl-spawn-place-argmax.tst.sh`, each with its red control in the commit body.
- **Q2 store: priority and rank** (`complex_coding`). Read 3.22.6, 3.22.7, C111-C118 and C121, plus H1's answer.
  - Claim the migration number with `do_rdb_migration_next`.
  - Memory and Postgres stores; `PRE_PUSH_TIER=full`.
  - Wait for c-918's B11 on `server.go` and `openapi.json`.
- **Q3 the queue route and holds** (`complex_coding`, after Q2, Q9). Read 3.22.3, 3.22.4, the hold part of 3.22.8, and C102-C104 and C122.
  - C103 compares the route with `spl_spawn_q_rows` on one seeded queue.
- **Q4 the tab, read only** (`complex_coding`, after Q3). Read 3.22.3 and C105-C107.
  - Own chunk: C107's `perf-budget.py` check.
  - Language check (H6 A: gct, agy optional): push `review/<slug>`, then land only after the check passes.
- **Q5 the chooser** (`complex_coding`, after Q4). Read 3.22.6 "On a lane" and C114.
  - The Lanes Prio cell becomes the chooser for whoever may set it.
  - Language check (H6 A: gct, agy optional).
- **Q6 drag** (`complex_coding`, after Q5). Read 3.22.7 "Not only a mouse" and C115 through the page, at 1440 and 390 px.
  - Language check (H6 A: gct, agy optional).
- **Q7 Plans** (`complex_coding`, after Q6). Read 3.22.5 "How it shows" and C108-C110.
  - The route needs a `server.go` line.
  - Language check (H6 A: gct, agy optional).
- **Q8 a set plan passes the filler** (`simple_coding`, after Q9). Read 3.22.5 "How a plan becomes a request".
  - The gate as H4 A: a person-set priority only.
- **Q8b workspace readers** (`complex_coding`, after Q7). Read 3.22.3 "Who reads it" and C25/C26's shape. No text key.
- **Q9 helpers by priority** (`complex_coding`). Read 3.22.9 and C125.
  - cnf `env.box.prio_helpers`, then `do_tpl_gen` with `git diff --exit-code`.
- **Q10 flow record** (`complex_coding`, after Q1 and Q5). Read 3.22.8 "The last tick" and "The view", plus C123.
  - Claim the migration number. `PRE_PUSH_TIER=full`. Add the cron row.
  - Its routes per H5.
- **Q11 flow view** (`simple_coding`, after Q8b and Q10). Read 3.22.8 "The view" and C124: no sentence of cause.
  - Language check (H6 A: gct, agy optional).
- **Q12 a signed plan files its issues** (`simple_coding`). Read 3.22.5 "Filing a signed plan" and C126.
  - The plan form it parses is this file's section 3 table.

---

## 8. Panel record

| when (UTC) | who | what |
|---|---|---|
| 2026-11-24 | c-057 (claude) | v0.1 on `review/c002-s153-queue-tab-build-planner`, `7bef22db8`, measured on `dbd127c96` |
| 2026-11-24 | c-057 (claude) | v0.2 records the owner's answers H1-H7, all A (msg `5e11eca7`, forwarded in `7a57a706`); no re-measure |
| 2026-11-24 11:12Z | m-072 (mistral) | **PASS** on v0.2 `b2b8e4bae` (msg `1597fe5f`), W none, findings N1-N4 below; `do_spl_review_line_check` rc 0 on its log |
| 2026-11-24 | c-002 (holder) | GO on `b2b8e4bae` (msgs `a8956e9f`, `84609ce2`); ruling on N1 (section 3) |
| 2026-11-24 11:13Z | c-057 (claude) | v0.2 landed as `6b6413c30` (rebased onto master, no content change: `git diff b2b8e4bae 6b6413c30 -- <this file>` is empty) |
| 2026-11-24 | c-057 (claude) | v1.0: the signature, N1-N4 and the N1 ruling; the rows are not changed |
| 2026-11-24 11:34Z | c-002 (holder) | ACCEPTED (msg `a4667b5e`): `6b6413c30` and `7e31ade12` on master, quality gate run on `7e31ade12` green; the planner seat is done |

The panel's findings, as m-072 stated them, with what v1.0 does about each:

- **N1**: the R7 seat drifted. `BOX_PICK_KIND=grok` gives `pick=hold` now (95% on both boxes), where the plan recorded `pick=<box-b>` at 93%. v1.0 writes the holder's ruling into section 3.
- **N2**: the queue drifted. ~10:12Z read 8 queued and 0 placing; at the panel's read it was 5 queued and 1 placing. Section 5 already says the holder re-checks at each placement. No change.
- **N3**: section 7 does not state the per-brief "re-measure first" line. Sections 2 and 4 are pinned to `dbd127c96` by the "One sha" note. Minor. The holder's GO asked for no change, so v1.0 leaves the line out.
- **N4**: the forward msg `7a57a706` was not found in prd `messages` from the panel's box. The answers themselves (msg `5e11eca7`) were verified on prd, so only the citation of the forward is unverified. No change.

## 9. Signatures

| seat | on | verdict |
|---|---|---|
| editor c-057 (claude) | v0.1, v0.2, v1.0 | the plan commits |
| cross-vendor seat m-072 (mistral) | v0.2 `b2b8e4bae` | **PASS**, W none, N1-N4 (msg `1597fe5f`) |
| holder c-002 | v0.2 `b2b8e4bae` | **GO** (msg `a8956e9f`) |
