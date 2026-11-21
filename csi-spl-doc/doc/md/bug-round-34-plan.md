# Bug-fix round 34 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6179 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `b19ef63d-b752-4723-8aa2-249fc31c42c4` ("Bug round 34", opener msg 25d0bce2, opened by c-002@sat 09:55Z). Round 33 ([bug-round-33-plan.md](bug-round-33-plan.md)) is closed: its close record `eb7c8cc54` is on master, both rows landed (b33-01 `d42ec95e8`, b33-02 `22f50f64f`). Round 32's rows are both on master (b32-01 `b7b10a2fd`, b32-02 `1fadfb77b`); its close record is not, and this round stays off its files.  
Round focus: a hub store defect that loses data, and an orc defect. Row 01, the holder's pick (msg 0a22e4ec, from c-001 8bd74383, re c-745@`<box2>` 65e888af): the orphan sweep deletes the pictures of a Qto doc locked to a human, because the store's "is this picture named by a doc" read cannot see a locked doc. Row 02, from the R7 of b33-01 (c-763, N3): the enqueue's `Issue-Role: shared` line is glued to the brief's last line when the brief does not end in a newline, so the exit gate never sees it.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Sections 4 and 5 account for every other input.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-33-plan.md](bug-round-33-plan.md) (same shape, same 5 sources).

**Status: v0.3, for the panel.** v0.1 `05e6be867` (10:08Z) had row 02 only, as row 01; the holder's pick arrived after it and is row 01 since v0.2 `1bd6972bf` (sent to the panel m-785@sat). v0.3 changes row 01 only: its route is b, from c-745's answer (section 8); no red control changed.

Editor: **c-782@sat** (claude, `specs_and_docs`; agy, the kind's main, is out on its limit until 11-24).  
Panel: the mistral seat queued with this planner (ask `c002-bug-round-34-mistral-panel-seat`). Neither row has a WUI file (row 01 is Go store code, row 02 orc bash), so a mistral seat may sit on the plan (developer guide 5.1); it writes no row code.

**One sha:** every count below is measured on **`31a976ffb`** (`origin/master` at this seat's fetch, 09:59:47Z), on sat, between 09:59Z and 10:17Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b33-plan')` -> `Window: W=2026-11-21T11:45:44+02:00` (commit `eb7c8cc54`, the b33 close record), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 33. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, and `<AGENT_USER>` is the OS user the agents run as. The public repo names neither.

---

## 1. How to read this

- Round 33 measured on `5083f4cf9`. This plan reads round 33's first inputs for round 34 (its section 7), the R7 notes of b33-01 (c-763) and b33-02 (c-761), the holder's candidates file and the CI report. For each it says why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `31a976ffb`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `31a976ffb`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner, member and lane reports since round 33** | the brief's inputs; the holder's pick (msg 0a22e4ec, 10:0xZ), the claim of c-745@`<box2>` (65e888af) relayed by c-001 (8bd74383); the holder's note on prd (msg 16eddf04, c-001 6ca4f0bf) | 1 lane report; no owner word | **Row 01**, re-measured on a Postgres fixture (section 3). Prd, as c-001 read it (10:1xZ, read only, n=1, not re-read here): 0 human-locked Qto docs, so no picture has been lost yet; the loss starts 24 h after the first locked doc with a picture. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (09:59Z..10:03Z) | wf 10: 100 runs (2026-11-20T20:24Z..2026-11-21T09:47Z): 52 success, 42 cancelled, 4 failure, 2 running. First red per job: `orc: hermetic action tests 2/4` x2 (`hub_cloudtranslate_user` not covered, 75da57eb, ad950c0e, 03:28Z..03:45Z); `wui: browser e2e 6/8` x1 (`workspace-doc-preamble.test.mjs`, 44832401773, 2026-11-20 22:51Z). Last green of both jobs: 44889519165 on `d42ec95e`, 09:25Z. Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4, 58 %) | **0 rows** from a red: the same reds round 33 read, green since, no new sighting. |
| **3. Skipped or disabled tests** | `git diff 5083f4cf9 31a976ffb -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 2 files: the round 33 plan (its text quotes `t.Skip`) and `csi-spl-api/.../store/cost_labels_test.go` (new in `cb64560e0`, SPL-6141): `t.Skip("SPOOL_TEST_PG_DSN unset")`, the store's usual Postgres gate, run by the `hub-pg` job | **0 rows.** |
| **4. The R7 notes of round 33** | the two review messages on sat (c-763 msg 3a997fe1 on b33-01 `9158e74de`; c-761 msg 9fbb61a6 on b33-02 `5c383ed40`), read whole; the commit bodies of `d42ec95e8` and `22f50f64f` | c-763 N1-N4, c-761 N1-N3 | **Row 02**: c-763 N3, re-measured on `31a976ffb` (section 3). The other six: section 4. |
| **5. Round 33's first inputs, the holder's candidates** | round 33 section 7 (13 inputs); the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 101 lines, its "next BUG round" and "Bug-shaped" entries) | 13 + the file's bug-shaped entries | **0 rows**: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `31a976ffb`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b34-01-store-doc-asset-held-locked-doc)` | **The hub's orphan sweep deletes the pictures of a Qto doc locked to a human (spec 125 B8): data loss 24 h after the upload.** `sweepOwnAssets` (`hub/file_retention.go:111`) and `orphanDelete` (`:195`) keep a blob only when `fileKept` (`:151`, `:200`; `hub/wsdoc_assets.go:310-316`) says a doc names it, and `fileKept` is `DocAssetHeld` (`store/workspace_docs_assets.go:63-73`). That read runs in the tenant scope with no human (`queryRowTenant`, `:68`): the sweep's context carries no `WithHuman` (`store/rls.go:86`), so `app.doc_human_id` is unset (`humanScope`, `rls.go:102-107`). rdb 0256's `human_lock` on `workspace_doc_item` passes an item only when its doc is visible (`0256_workspace_doc_restricted_to_human.sql:59-62`), and a locked doc is visible only to its human (`:52-57`, "fail closed"). So a locked doc's root item, with its `attrs.assets`, is not seen, the picture reads as unnamed, and once it is older than `FileOrphanGrace` (24 h, `file_retention.go:30`) it is deleted. | c-745@`<box2>` (65e888af, relayed by c-001 8bd74383 and the holder 0a22e4ec, n=1: a throwaway test on `b383c7a86`, Postgres 16, a restricted doc, its asset aged 48 h, `SweepFiles`, a GET by the doc's human -> 404, want 200; not re-run by c-001, the holder or me). **Re-measured here** on `31a976ffb` with a Postgres store fixture (rc01pg below, RED 3 of 3): the store half of the claim holds; the hub half (the sweep deleting it) follows from the code above, read, not run. Prd (c-001 6ca4f0bf, 10:1xZ, read only, n=1): 0 human-locked Qto docs, so 0 pictures lost so far. | `csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs_assets.go:63-73` (`DocAssetHeld`); a new migration in `csi-spl-rdb/src/sql/postgres/spool-hub/` (the claimed number); read only, and not to be edited (c-745's lane changes them): `hub/file_retention.go:111-170` (the sweep), `hub/wsdoc_assets.go:310-316` (`fileKept`), `store/rls.go:80-107`, rdb `0256_...:52-67`. Other `DocAssetHeld` callers that the fix also changes (to "keep"): `channelmove/objects.go`, `hub/attachment_remove.go`. Tests: a new Postgres store case (for example a new `store/workspace_docs_assets_test.go`), and one hub sweep case in `hub/wsdoc_assets_orphan_sweep_test.go` (c-745's branch does not touch it) | `bash /var/spool-hub/dispatch/b34-red-controls/rc01-pg/rc01pg.sh 31a976ffb` (section 3.2) -> `rcpg open: held=true want=true` / `rcpg lockedhuman: held=true want=true` / `rcpg lockedsweep: held=false want=true` / `rcpg unnamed: held=false want=false` / `rcpg wrong=1`, exit 1, n=3 (10:10Z..10:14Z) | `DocAssetHeld` (and only what it needs) plus its tests. A picture named by the root item of ANY doc of the tenant is held, whether or not the reading context may see that doc (`lockedsweep`), and only a boolean leaves the store: no title, item or attrs of a locked doc reaches the sweep, a log or an answer (spec 125 B8, C7-C9: never read past a human lock to show it). `open`, `lockedhuman` and `unnamed` stay as they are. **Route b** (c-745's answer, msg dd6a4255 via the holder 51d671a2): a lock-blind boolean in a new migration, its number from `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (0306 is c-745's): a function that answers only `EXISTS` for (tenant, sha256) over the root items' `attrs.assets`, called by `DocAssetHeld`, on 0143's pattern (`0143_messages_search_index.sql`: a NOLOGIN role owns a `SECURITY DEFINER` function). **Measured caveat for the lane:** `human_lock` is `AS RESTRICTIVE` with no `TO` clause (`0256_...:53`, `:60`), so it narrows every role, a NOBYPASSRLS function owner too; the lane must prove the function sees a locked doc's item (rc01pg's `lockedsweep` does) and that it returns nothing but the boolean. Route a (rdb 0306 `workspace_doc_gone`) is dropped: `qto-assets/<sha256>` carries no doc id, and the tombstone cannot say whether a locked doc names a sha (c-745). So row 01 does **not** wait for c-745's lane: c-745's branch (head `e71fea246`, on `31a976ffb`) does not touch `store/workspace_docs_assets.go`; it changes `hub/file_retention.go` (`SweepFiles`'s return line `:94`, a new `sweepOwnMedia` after `parseFileKey`) and `hub/wsdoc_assets.go` (`docAssetBytes` only). Row 01 therefore keeps both hub files **read only**: it changes neither `SweepFiles` nor `fileKept`. The suite: rc01pg's four cases as a real store test (Postgres; `PRE_PUSH_TIER=full`), `lockedsweep` red on `31a976ffb`; one hub sweep case: a locked doc's picture aged 48 h survives `SweepFiles` and its human still reads it (c-745's repro). Commit body: the store case on the fix -> pass, on `31a976ffb` -> fail. The suite runs under `PRE_PUSH_TIER=full` (a migration). Docs: the `DocAssetHeld` comment and the migration's header, and spec 125's B8 text if it lists the sweep; or `Docs: none (<why>)`. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `complex_coding` | 1 |
| 02 `fix(b34-02-orc-enqueue-shared-line-own-line)` | **On a placed `Kind: specs_and_docs` brief whose last line has no newline, the enqueue's `Issue-Role: shared` is glued to that line, so the exit gate does not see it and the lane cannot `/exit-clean`.** `spl_spawn_q_enqueue_shared` appends with `printf 'Issue-Role: shared\n' >>"$brief"` (`spl-spawn-enqueue.func.sh:190`), with no newline first. `li_review_lane` reads the line with a `^`-anchored grep (`lane-issue.inc.sh:547`), so `...no code.Issue-Role: shared` does not match, and `li_gate` refuses the wip key (exit 3), as for c-655 before b33-01. The enqueue's own guard (`:185`, also `^`-anchored) misses the glued line too, so a re-queue of the same ask appends a second line. The placer's twin append writes its newline first (`spl-lane-issue.func.sh:353`, `printf '\nIssue: %s\n'`). | b33-01 R7 N3 (c-763, msg 3a997fe1, on `9158e74de`, n=1 read): "If a brief has no trailing newline, the line sticks to its last line and the `^`-anchored grep in `li_review_lane` misses it". The holder landed b33-01 as is (`d42ec95e8` body: "N3 not folded (the holder: land as is)"). Re-measured on `31a976ffb`: rc02 below, RED 3 of 3. **Live exposure, measured on sat 10:02Z:** of 6401 briefs in `/var/spool-hub/dispatch/briefs`, 26 end without a newline (`tail -c1` not empty), 0 of them `Kind: specs_and_docs` with an `Issue: SPL-` line, 0 written in the last 48 h. So no lane is caught today: the defect is in the code for every such brief, and none has been queued yet. | `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh:178-193` (`spl_spawn_q_enqueue_shared`: the guard `:185`, the append `:190`), `:166-177` (its comment); the test `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (2345 lines; the SPL-6167 cases from `:2291`; new cases at its end); read only: `lane-issue.inc.sh:543-554` (`li_review_lane`) | `bash /var/spool-hub/dispatch/b34-red-controls/rc02.sh 31a976ffb` (section 3.2) -> `rc02 nl: got=shared/0 want=shared/0` / `rc02 nonl: got=none/3 want=shared/0` / `rc02 lastln: got=0 want=1` / `rc02 twice: got=2 want=1` / `rc02 sha=31a976ffb wrong=3`, exit 1, n=3 (10:16Z). `RC02_PLANT=1` (a sketch of the append, not the fix) -> `wrong=0`, exit 0. | `spl-spawn-enqueue.func.sh` and `spl-spawn-queue.tst.sh` only. The append puts `Issue-Role: shared` on a line of its own: when the brief's last byte is not a newline, a newline goes first (`nonl`, `lastln`); a brief that ends in one gets no blank line (`nl`). One append per brief, also on a re-queue (`twice`). The guard at `:185` and the gate's grep are unchanged; no change to `li_gate`, `li_review_lane`, the card read or the placer. The suite: rc02's four cases, `nonl`, `lastln` and `twice` red on `31a976ffb`. Commit body: rc02 on the fix -> exit 0, on `31a976ffb` -> exit 1. Docs: the function's comment says the line is written on a line of its own; `lane-issue-and-docs.md` row 1.6 does not describe the append's bytes, so a `Docs: none (<why>)` line is enough when the comment is the only text changed. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `csi-spl-api/.../store/workspace_docs_assets.go`, its new store test, a new migration, `hub/wsdoc_assets_orphan_sweep_test.go`. Row 02: `spl-spawn-enqueue.func.sh`, `spl-spawn-queue.tst.sh`. Go and bash: neither reads the other. Row 01 does not wait on c-745's spec 190 lane (route b, section 8); it stays off the two hub files that lane edits.
- **Test column (R2), row 01:** `git grep -l -E 'DocAssetHeld\|fileKept\|SweepFiles\|sweepOwnAssets' 31a976ffb -- csi-spl-api` -> the tests `hub/file_retention_test.go`, `hub/wsdoc_assets_orphan_sweep_test.go`, `hub/wsdoc_assets_test.go`, `channelmove/asset_locs_test.go`, `channelmove/objects_test.go` (and 6 files that are not tests: `channelmove/objects.go`, `hub/attachment_remove.go`, `hub/file_retention.go`, `hub/server.go`, `hub/wsdoc_assets.go`, `store/workspace_docs_assets.go`). No Postgres store test reads `DocAssetHeld` today (`git grep -l DocAssetHeld 31a976ffb -- '*/store/*_test.go'` -> none). The store and hub Postgres suites run under `PRE_PUSH_TIER=full` (rulebook R9 does not apply: no gate is changed). Also `rc01pg.sh`.
- **Test column (R2), row 02:** `git grep -l -E 'spl-spawn-enqueue\|do_spl_spawn_enqueue\|spl_spawn_q_enqueue' 31a976ffb -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests` -> the tests `spl-spawn-queue.tst.sh`, `spl-spawn-after.tst.sh`, `spl-spawn-fill.tst.sh`, `spl-spawn-group.tst.sh`, `spl-security-round-queue.tst.sh`, `spl-epic-stall-check.tst.sh`, `spl-reflection-gather.tst.sh`, `alert-issue-tick.tst.sh` (orc `src/bash/tests`), plus 4 files that are not tests (`action-header-tags-baseline.txt`, `brief-reflection.tpl.md`, `spawn-an-agent.md`, `lane-issue.inc.sh`). The gate side it feeds, as b33-01 ran it: `test-lane-issue.sh`, `test-lane-issue-remote-desk.sh` (`spawn-agents/tests`), `spl-lane-issue.tst.sh`. Also `rc02.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); `lane-issue.inc.sh` and `spl-lane-issue.func.sh` (read only); the placer `spl-spawn-place.func.sh`; the hub.
- **How the files were checked (2026-11-21, sat):**
  - Row 01, 10:15:51Z `lane-map.sh --check <the five row 01 paths: store/workspace_docs_assets.go, store/workspace_docs_assets_test.go, hub/file_retention.go, hub/wsdoc_assets.go, hub/wsdoc_assets_orphan_sweep_test.go> --agent c-782` -> `WARN no live lane lists` them, exit 4, 18 `<box2>` lanes with no files. sat's worktrees, the same diff + status scan matched against `workspace_docs_assets\|file_retention\|wsdoc_assets` -> 0 hits. **c-745@`<box2>` (spec 190 D1/H1/H3, "media store upload sweep") is live on the sweep's family and holds rdb 0306**; its branch touches `hub/file_retention.go` and `hub/wsdoc_assets.go`, not `store/workspace_docs_assets.go` (c-745 msg dd6a4255, head `e71fea246`, 10:2xZ): row 01 keeps those two read only (section 8).
  - 10:02:53Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-doc/doc/md/bug-round-34-plan.md,csi-spl-doc/doc/md/lane-issue-and-docs.md --agent c-782` -> `WARN no live lane lists` them, exit 4 for 18 lanes that record no files, all 18 on `<box2>` (among them c-749, c-751, c-752, c-812, c-924, c-927). The `<box2>` half is asked of the holder (section 8).
  - sat's worktrees (`git worktree list`, every one): `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths, matched against `spl-spawn-enqueue.func.sh` and `spl-spawn-queue.tst.sh` -> 2 hits, both stale: `g-962-r4620` (HEAD `a6078ea15`, 2026-11-02, SPL-4620; g-962 is not in `registry.tsv`) and `/tmp/g-418-red-master` (HEAD `9499333c1`, 2026-11-16; g-418's rows in `registry.retired.tsv` end 2026-11-16T04:10Z). No live sat lane touches either file.
  - 10:04:45Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `15 queued, 0 placing`. The 11 queued briefs that name files (spec 184 M0/C1/I1/L1/A1/H1, spec 033 T026, spec 123 L4-L7): `grep -lE 'spl-spawn-enqueue\|spl-spawn-queue\.tst\|lane-issue-and-docs'` -> none. The other 4 are agy language reviews of WUI text. The holder's R3 check (rulebook 2.3) reads the queued briefs again when the row is queued.
- **Slug b34 is unused as a round id** (sat, 09:59:47Z, on `31a976ffb`): `git log origin/master --since="$W" --oneline -E --grep='\(b34-'` -> 0. `git ls-remote origin 'refs/heads/review/b34-*' 'refs/heads/wip/*b34*' 'refs/heads/*-b34-*'` -> nothing. `ls /var/spool-hub/dispatch/briefs \| grep -E 'b34\|bug-round-34'` -> the planner's and the panel seat's briefs, 0 row briefs. `git worktree list \| grep -E 'b34-[0-9]{2}\|bug-round-34'` -> this planner's only (`c-782-c002-bug-round-34-planner`). The `<box2>` half is asked of the holder (section 8).

### 3.2 Red controls run on `31a976ffb`

**Row 01** is two files in `/var/spool-hub/dispatch/b34-red-controls/rc01-pg/` on sat: `rc01pg.sh` (1964 B, `sha256sum` 12 hex `17f39bc880ad`) and the throwaway store test `b34_rc_asset_held_test.go` (1839 B, `fe0adcc73aa5`). Both are printed below. rc01pg exports `csi-spl-api` and `csi-spl-rdb` of the sha with `git archive`, drops the test into `internal/store/`, and runs it under the repo's own `csi-spl-api/src/bash/hub-live-stack.sh`, which migrates a throwaway Postgres 16 (local `initdb`, else the cached `postgres:16-alpine` image, never pulled) and exports `SPOOL_TEST_PG_DSN`. The data is a fixture: a new tenant, an open doc and a doc locked to `HUM-1` (`DocCreateRestricted`), each root item naming one picture in `attrs.assets`. No live database is read and no human lock is read past outside the fixture (the holder's note 16eddf04). Needs bash, git, tar, go and Postgres 16 or docker.

| row | command | output | who |
|---|---|---|---|
| 01 | `bash rc01pg.sh 31a976ffb`, from a checkout, n=3 (10:10Z..10:14Z; each about 40 s) | RED in 3 of 3, the same output each time: `rcpg open: held=true want=true` / `rcpg lockedhuman: held=true want=true` / `rcpg lockedsweep: held=false want=true` / `rcpg unnamed: held=false want=false` / `rcpg wrong=1` / `rc01pg sha=31a976ffb exit=1`. What it shows: the read sees an open doc's picture, and a locked doc's picture when its human reads; with no human, as the sweep reads, the locked doc's picture is "not held". | editor c-782 |

There is no green half for row 01: its fix has two routes (row 01), and either is the lane's. `lockedsweep` must turn true and the three controls must stay.

`rc01pg.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01pg.sh <sha>: b34-01 red control (Postgres). Exports csi-spl-api and
# csi-spl-rdb of <sha> (git archive, no worktree of the repo) into a temp dir,
# drops in the throwaway store test b34_rc_asset_held_test.go (next to this
# script), and runs it under the repo's csi-spl-api/src/bash/hub-live-stack.sh,
# which migrates a throwaway Postgres 16 (local initdb, else the cached
# postgres:16-alpine image, never pulled) and exports SPOOL_TEST_PG_DSN.
# Fixture data only: a new tenant, one open doc and one doc locked to HUM-1
# (DocCreateRestricted), each root item naming one picture sha256 in
# attrs.assets. No live database, no hub of the fleet, no network.
#   open       : the open doc's picture, read with no human -> held (control)
#   lockedhuman: the locked doc's picture, read as HUM-1 -> held (control)
#   lockedsweep: the locked doc's picture, read with no human, as the orphan
#                sweep (fileKept -> DocAssetHeld) does -> held
#                (RED: false: rdb 0256 human_lock hides the root item)
#   unnamed    : a sha no doc names -> not held (control)
set -uo pipefail
sha="${1:?usage: rc01pg.sh <sha>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
full="$(git rev-parse "$sha^{commit}")" || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$T" || exit 2
cp "$here/b34_rc_asset_held_test.go" "$T/csi-spl-api/src/go/spool-hub-api/internal/store/" || exit 2
(cd "$T" && timeout 900 bash csi-spl-api/src/bash/hub-live-stack.sh bash -c \
  'cd csi-spl-api/src/go/spool-hub-api && go test -trimpath -count=1 -run TestB34RCDocAssetHeldLocked -v ./internal/store/') >"$T/run.log" 2>&1
rc=$?
grep -oE 'rcpg [a-z]+: held=[a-z]+ want=[a-z]+|rcpg wrong=[0-9]+|SKIP.*' "$T/run.log"
grep -q 'rcpg wrong=' "$T/run.log" || { echo "rc01pg: the test did not run (exit $rc)"; tail -5 "$T/run.log"; exit 2; }
echo "rc01pg sha=${full:0:9} exit=$rc"
exit "$rc"
```

`b34_rc_asset_held_test.go`, as run:

```go
package store

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// b34 red control (throwaway, not in the repo): a picture named by a doc
// locked to a human (spec 125 B8, rdb 0256) must stay held for the orphan
// sweep, which reads DocAssetHeld with no human on its context.
func TestB34RCDocAssetHeldLocked(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	tid := newTenant(t, pg)
	hctx := WithHuman(ctx, "HUM-1")
	set := func(c context.Context, root, sha string) {
		t.Helper()
		err := pg.inTenant(c, tid, func(tx pgx.Tx) error {
			_, err := tx.Exec(c, `UPDATE workspace_doc_item SET attrs = jsonb_build_object('assets', jsonb_build_object('d.assets/01-a.png', $2::text)) WHERE id = $1`, root, sha)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	shaOpen := strings.Repeat("a", 64)
	shaLock := strings.Repeat("b", 64)
	_, rootOpen, err := pg.DocCreateIn(ctx, tid, "", "open doc", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	set(ctx, rootOpen, shaOpen)
	_, rootLock, err := pg.DocCreateRestricted(hctx, tid, "", "locked doc", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	set(hctx, rootLock, shaLock)
	got := func(c context.Context, sha string) bool {
		h, err := pg.DocAssetHeld(c, tid, sha)
		if err != nil {
			t.Fatal(err)
		}
		return h
	}
	bad := 0
	for _, c := range []struct {
		name string
		ctx  context.Context
		sha  string
		want bool
	}{
		{"open", ctx, shaOpen, true},
		{"lockedhuman", hctx, shaLock, true},
		{"lockedsweep", ctx, shaLock, true},
		{"unnamed", ctx, strings.Repeat("c", 64), false},
	} {
		g := got(c.ctx, c.sha)
		t.Logf("rcpg %s: held=%v want=%v", c.name, g, c.want)
		if g != c.want {
			bad++
		}
	}
	t.Logf("rcpg wrong=%d", bad)
	if bad != 0 {
		t.Fail()
	}
}
```

**Row 02** is in `/var/spool-hub/dispatch/b34-red-controls/rc02.sh` (4871 B, `sha256sum` first 12 hex `15e47f56c771`). It is printed below so a seat on `<box2>` can rebuild it. It exports `csi-spl-orc` of the sha with `git archive` (no worktree of the repo, nothing installed) and needs bash, git, tar and jq. It is b33's rc01 cut down to one card shape (c-655's, `scope: the brief of lane c-259`): it stubs the enqueue's hub calls and runs the real `do_spl_spawn_enqueue` and `li_gate` on a temp `SPOOL_ROOT`. It reads no live queue, worktree, spool, state file or credential, and calls neither the hub nor the network.

| row | command | output | who |
|---|---|---|---|
| 02 | `bash rc02.sh 31a976ffb`, from a checkout, n=3 (10:16Z; the same script as v0.1's `rc01.sh` at 10:00Z, n=3, renamed with its labels) | RED in 3 of 3, the same output each time: `rc02 nl: got=shared/0 want=shared/0` / `rc02 nonl: got=none/3 want=shared/0` / `rc02 lastln: got=0 want=1` / `rc02 twice: got=2 want=1` / `rc02 sha=31a976ffb wrong=3`, exit 1. With `RC02_PLANT=1` (the exported tree's append patched to write a newline first when the last byte is not one): `wrong=0`, exit 0 (n=1, 10:16Z). What it shows: a brief that ends in a newline is shared and passes the gate (b33-01 holds); the same brief without the newline is not shared, the gate refuses it, its last line is changed, and a re-queue writes the line twice. | editor c-782 |

No fix was written in the repo: each change belongs to its row lane, with its own tests. `RC02_PLANT=1` shows only that the four checks can go green; it is not the fix. The lane may write the append another way; `nl`, `nonl`, `lastln` and `twice` are what must hold.

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b34-02 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree of the repo), runs its do_spl_spawn_enqueue on a fixture brief
# (the hub queue op, the reply and the ask reads stubbed; the card read through
# the LI_HUB_CARD_CMD seam; no hub, no network), then copies the queued brief
# into a fake lane's lifetime/ and runs the exit gate li_gate on it, as
# /exit-clean does. b33-01 R7 N3 (c-763, msg 3a997fe1): spl_spawn_q_enqueue_shared
# appends "Issue-Role: shared" with no leading newline, so on a brief whose
# last line has no newline the line is glued to it and li_review_lane's
# ^-anchored grep misses it.
#   nl    : c-655's brief shape, ends in a newline -> shared, gate 0 (control)
#   nonl  : the same brief, no trailing newline -> shared, gate 0
#           (RED: role=none, gate 3, the line glued to the last line)
#   twice : nonl enqueued twice (a re-queue of the same ask) -> exactly one
#           Issue-Role line (RED: 2, the glued one and a second append)
#   lastln: nonl -> the brief's original last line is unchanged
#           (RED: it carries the glued "Issue-Role: shared")
# RC02_PLANT=1 patches the exported tree's append to write a newline first
# when the brief does not end in one (a sketch of a fix, not the row's fix):
# proves the four checks can go green.
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$T" || exit 2
if [[ "${RC02_PLANT:-0}" == 1 ]]; then
  ef="$T/csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh"
  IFS= read -r old <<'EOF_OLD'
printf 'Issue-Role: shared\n' >>"$brief"
EOF_OLD
  IFS= read -r new <<'EOF_NEW'
{ [[ -z "$(tail -c1 "$brief")" ]] || printf '\n'; printf 'Issue-Role: shared\n'; } >>"$brief"
EOF_NEW
  src="$(cat "$ef"; echo x)"; src="${src%x}"
  [[ "$src" == *"$old"* ]] || { echo "rc02: plant did not apply"; exit 2; }
  printf '%s' "${src/"$old"/"$new"}" >"$ef"
fi
mkdir -p "$T/spool/c-901/lifetime" "$T/briefs"
git -c init.defaultBranch=master init -q "$T/wd"
printf '#!/bin/sh\nprintf "issue-status\\t%%s\\twip\\n" "$1"\n' >"$T/status"; chmod +x "$T/status"
printf '#!/bin/sh\nprintf -- "## Restart\\n- key: %%s\\n- scope: the brief of lane c-259\\n" "$1"\n' >"$T/card"; chmod +x "$T/card"
B="$T/briefs/c002-rc02-x.md"
LAST='You write a SPEC change, no code.'
brief() {  # NL(1|0) -> c-655's brief shape; NL=0 drops the final newline
  printf '# Lane brief: spec 143 v0.2, the owner answers (spec lane, docs only)\n\nEpic: SPL-2373\nSpec: csi-spl-doc/specs/143-reporting-section\nIssue: SPL-6086\nClass: feature\nKind: specs_and_docs\n\n%s' "$LAST" >"$B"
  [[ "$1" == 0 ]] || printf '\n' >>"$B"
}
enq() {
  (cd "$T/csi-spl-orc" && env PROJ_PATH="$PWD" APP_PATH="$T" SPOOL_ROOT="$T/spool" ASK_ID=aaaaaaaa SPAWN_CLASS=bug \
    SPAWN_PLACE=claude:c002-rc02-x LI_HUB_CARD_CMD="$T/card" LI_HUB_STATUS_CMD="$T/status" RC_B="$B" \
    bash -c 'set -uo pipefail
      do_log() { echo "$*" >&2; }
      for f in lib/bash/funcs/*.func.sh; do source "$f"; done 2>/dev/null
      source src/bash/run/spl-spawn-queue.func.sh 2>/dev/null; source src/bash/run/spl-spawn-enqueue.func.sh
      spl_spawn_q_init() { return 0; }; spl_asks_discussion_ok() { return 0; }; spl_asks_by() { echo c-002@sat; }
      spl_spawn_q_resolve() { echo aaaaaaaa-0000-4000-8000-000000000000; }; spl_spawn_q_enqueue_archived() { return 0; }
      spl_spawn_q_discussion() { return 0; }; spl_spawn_q_enqueue_links() { return 0; }
      spl_spawn_after_enqueue() { return 0; }; spl_spawn_place_brief() { echo "$RC_B"; }
      spl_spawn_q_op() { echo "{\"position\":1,\"queue_len\":1}"; }; spl_spawn_q_reply() { return 0; }
      do_spl_spawn_enqueue' >"$T/enq.log" 2>&1)
  grep -q '^OK ask' "$T/enq.log" || echo "rc02: enqueue did not finish: $(tail -1 "$T/enq.log")"
}
gate() {
  cp "$B" "$T/spool/c-901/lifetime/brief.md"
  printf 'SPL-6086\n' >"$T/spool/c-901/lifetime/issue"; printf 'SPL-6086\n' >"$T/spool/c-901/lifetime/origin-issue"
  (cd "$T/csi-spl-orc" && env SPOOL_ROOT="$T/spool" LI_HUB_STATUS_CMD="$T/status" bash -c 'set -uo pipefail
    do_log() { :; }; for f in lib/bash/funcs/*.func.sh; do source "$f"; done 2>/dev/null
    . src/bash/features/spawn-agents/lib/lane-issue.inc.sh; li_gate "$SPOOL_ROOT" c-901 "$1"' _ "$T/wd" >/dev/null 2>&1)
  echo $?
}
role() { grep -qiE '^[-*_ >]*Issue[- ]Role[*_ ]*:[*_` ]*shared([^A-Za-z]|$)' "$B" && echo shared || echo none; }
bad=0
chk() {  # NAME GOT WANT
  echo "rc02 $1: got=$2 want=$3"
  [[ "$2" == "$3" ]] || bad=$((bad + 1))
}
brief 1; enq; chk nl "$(role)/$(gate)" shared/0
brief 0; enq; chk nonl "$(role)/$(gate)" shared/0
chk lastln "$(grep -cxF -- "$LAST" "$B")" 1
enq; chk twice "$(grep -ciE 'Issue[- ]Role' "$B")" 1
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

---

## 4. Round 33's inputs and R7 notes, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b33-01, b33-02 | `git log origin/master --oneline -E --grep='\(b33-0[12]-'` | `d42ec95e8`, `22f50f64f` | **Served**, both (close record `eb7c8cc54`). |
| b33-01 N3 (c-763): the glued `Issue-Role: shared` line | section 3 | rc02 RED 3 of 3 | **Row 02.** |
| b33-01 N1 (c-763): the card's text is read but never compared | `spl-spawn-enqueue.func.sh:186` | as measured in round 33: at the enqueue no lane exists that a card could name | **Not a bug on this tree**; the holder ruled to keep the read (round 33, msg 08e9399f). It becomes one only if a placer writes a filed key into `dispatch/briefs/<slug>.md` before the enqueue. Carried. |
| b33-01 N2 (c-763): the line is written before the hub queue op | `:152` before `:154` | the line is right either way, and a retry is guarded by `:185` (once row 02 keeps the line on its own line) | **Not a bug**: no wrong state. |
| b33-01 N4 (c-763): the real hub path of the card read has no test | `:205-211` | only the seam is tested | **Test-shaped**, for a refactor or test round. |
| b33-02 N1 (c-761): `rc02.sh:46,49` print two lines when grep counts 0 | round 33's close (its section 8) records it; `22f50f64f`'s body carries the fixed copy | a red-control file under `/var/spool-hub/dispatch`, not repo code | **Not a row**: no product code, and round 33's close already says it. |
| b33-02 N2 (c-761): rc02's stub ignores stdin | section 23 of `spl-box-pick.tst.sh` covers the stdin | "no change needed" (the reviewer) | **Not a row.** |
| b33-02 N3 (c-761): an empty kept key reaches the fetcher as `-` | `spl-box-quota.func.sh:307,394` | a computed key is always `a<12 hex>`, never `-` | **Not a bug** ("harmless", the reviewer). |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | sat `/var/csi/csi-spl/done-claim-check/cron.log` (46856 lines): `grep -ciE 'job [0-9a-f]{7}'` -> 0 | 0 alerts | **Not a row**: the condition did not occur. Carried. |
| The AltGr picker; the blog switcher's Enter | source 1 | no owner word | **No rule it breaks and no owner word.** Carried. |
| `blog.test.mjs:329` alone | not re-run: a WUI e2e needs the generated bundle and Chrome, and a WUI row could not take the mistral seat | - | **Not a row this round.** Carried. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | not among the report's reds | **Not a row**: not seen red. |
| The orc/iac suites as the agent OS user, if seen red | not re-run this round: round 33 ran `unanswered-sweep.tst.sh`, `watcher-read-only.tst.sh` and `check-commit-msg-hygiene.tst.sh` as both users on `5083f4cf9` (green), and none of the three changed since (`git diff --name-only 5083f4cf9 31a976ffb -- <the three>` -> none) | no new report | **Not reproduced**, as in rounds 27 to 33. Carried. |
| `gcp-billing-invoices.tst.sh` `download iframe`; `workspace-doc-preamble.test.mjs` at their 3rd sightings | source 2 | 0, and 1 (the same run 44832401773 rounds 32 and 33 counted) in 100 runs | **Not a row**: no new sighting. |
| The `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms | not re-queried | no report since round 33 | **Not a row.** Carried. |
| b29-01 N1 on `<box2>` (the profile account across a renewal) | not read here: `<box2>` | no `differs` reported | **Not a row.** Carried. |
| The overlay mount that outlives its `/tmp` worktree | its red control needs a mount, which needs root | - | **Not a row this round.** Carried. |
| `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on | `WT_SWEEP_TMP_ROOT` still off | not observable | **Not a row.** Carried. |
| The lease vendor order writer once named | sat, 10:01Z: `grep -n LEASE_VENDOR_ORDER /var/spool-hub/dispatch/lease.conf` -> `12:LEASE_VENDOR_ORDER=claude,agy,claude2` (no grok); last write 04:35Z | not reverted on sat since | **Not a row.** No writer named. Carried. |
| The topic loop's `!inserted` branch | round 33 section 5 | untested | **Test-shaped.** Carried. |

---

## 5. The holder's candidates, re-measured; not a row this round

Every bug-shaped entry of the candidates file was read against round 33's section 5 and `git log origin/master` on `31a976ffb`. The file has 101 lines, as when round 33 read it; its newest entry (04:5xZ, c-655) is b33-01, served. Round 33's verdicts stand, one line each:

| candidate | result |
|---|---|
| The topic loop's hourly cap race (SPL-6032 R7 N2) | **Not a race on this tree** (one `UPDATE ... WHERE fires_in_hour < $4 ... RETURNING`, round 33 section 5). |
| The placer `After:` hold, the bare `Author:` box, the review-go retries and re-PASS loop, the never-clause `Author:`, the panel-seat UI swap, the kept weekly reading, the CI-first rule, the done-claim sha256 prefix, the review notice's `wip/` branch, the spec-version lane's exit | **Served**: b30-03, b31-01, b20-01 and b27-01, b22-02, b27-02 / b28-01 / b29-02, b29-01, b30-01, b31-02, b32-02 (`1fadfb77b`), b33-01 (`d42ec95e8`). |
| The customer box role check's ban-list limits (spec 181 B6, c-502 N1-N4) | **Not a row this round**: spec 181's lanes own the file (R3). |
| The blog switcher e2e alone; test, refactor and doc notes | as section 4 and round 33 section 5. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row file on sat (lane map 10:02:53Z and 10:15:51Z, worktrees, queue 10:04:45Z). The `<box2>` half: asked (section 8). |
| `hub/file_retention.go`, `hub/wsdoc_assets.go` (and rdb 0306) | c-745@`<box2>` (spec 190 D1/H1/H3) | Its branch edits both; row 01 reads them only and takes its own migration (route b). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; the holder's pick (row 01) on a Postgres fixture (n=3); 7 R7 notes of round 33 (c-763 N1-N4, c-761 N1-N3); 13 round 33 inputs; 100 CI runs; the candidates file's bug-shaped entries (all served or carried, none new since round 33); 2 red controls (n=3 each, plus 1 planted run of rc02); 6401 briefs for the trailing-newline exposure; sat's `lease.conf` and the done-claim log |
| first inputs for round 35 | b33-01 N1 (the card text never compared) if a placer ever writes a filed key into `dispatch/briefs/<slug>.md` before the enqueue; the done-claim `job` label if it alerts alone; the AltGr picker and the blog switcher's Enter if a rule or the owner says how they must pick; `blog.test.mjs:329` alone, re-run on a bundle; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` and `workspace-doc-preamble.test.mjs` at their 3rd sightings; the `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms if printed again; b29-01 N1 on `<box2>` if it reads `differs`; the overlay mount that outlives its `/tmp` worktree; `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on; the lease vendor order writer once named; the topic loop's `!inserted` branch and the card read's hub path (test-shaped) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-782@sat (claude, `specs_and_docs`).
- **Panel:** the mistral seat (ask `c002-bug-round-34-mistral-panel-seat`). Neither row has a WUI file, so a mistral seat may sit (developer guide 5.1). It reviews the plan only; it writes no row code, and pushes with `PUSH_BRANCH=review/c002-bug-round-34-mistral-seat`.
- **Asked of the holder:**
  1. (answered, msg 42c66c91) origin's 93 review/wip refs with a commit in 24 h, diffed against the 5 paths: 1 hit, `review/b33-01`, landed (stale). Unpushed `<box2>` work is not readable from sat, so this is not proof of absence. The ask was: the `<box2>` half of R3: in each live `<box2>` worktree, `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths, matched against `spl-spawn-enqueue.func.sh`, `spl-spawn-queue.tst.sh`, `workspace_docs_assets.go`, `file_retention.go` and `wsdoc_assets.go`.
  2. Row 01's route (answered): c-745@`<box2>` (msg dd6a4255, relayed 51d671a2): its branch touches `hub/file_retention.go` and `hub/wsdoc_assets.go` but not `store/workspace_docs_assets.go`; `workspace_doc_gone` cannot serve a sha shared by docs with no doc id in its key: **route b**, no `After:`.
  3. (answered, msg 42c66c91: origin refs, briefs and sat worktrees show only this planner's and m-785's; `<box2>` worktrees not read) The `<box2>` half of the slug proof: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b34-[0-9]{2}\|bug-round-34'` and `git worktree list \| grep -cE 'b34-[0-9]{2}\|bug-round-34'`.
- **Row reviewer (R7):** rows 01 and 02: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (10:04:45Z) -> `pick=hold reason=waiting: grok weekly >= 95% or unknown on sat, <box2> [sat unknown (no reading); <box2> unknown (no reading)]: queue the lane, spawn nothing`. No mistral backup: row 01 is `complex_coding` and row 02 `simple_coding`, coding kinds mistral does not take, as main or backup. An absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 10:08Z: v0.1 `05e6be867`, pushed to `review/c002-bug-round-34-planner`: one row (now row 02).
  - 2026-11-21 10:0xZ..10:1xZ: the holder's pick (msg 0a22e4ec) and its prd note (msg 16eddf04): re-measured on a Postgres fixture, RED 3 of 3; now row 01.
  - 2026-11-21 10:19Z: v0.2 `1bd6972bf`, one commit on v0.1 (a fast-forward of the review branch); the holder sent it to m-785@sat.
  - 2026-11-21 10:3xZ: v0.3, one commit on v0.2: row 01's route b and its file set from c-745's answer; section 8's asks answered. No red control or row 02 text changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-782@sat | v0.3 |
| Panel | m-785@sat (mistral) | pending (has v0.2 `1bd6972bf`; v0.3 sent) |
