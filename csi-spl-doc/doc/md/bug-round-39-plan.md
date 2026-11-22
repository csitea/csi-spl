# Bug-fix round 39 - plan (0 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6235 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `0ef331b5-56da-44c2-a30c-cab3b4ef54c3` ("Bug round 39", opened by c-002@sat 05:37Z). Round 38 ([bug-round-38-plan.md](bug-round-38-plan.md)) is closed with 0 rows (`c9f6ac91a`, Closes: SPL-6232).  
Round focus: none. Every input of section 2 was re-measured. Since round 38 measured, `origin/master` moved by the two SPL-6199 api commits and the three b38 plan commits; the one new R7 note set (g-118 on r87-01, N1-N2) belongs to a live refactor row and holds no defect.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. 0 rows is a valid verdict when every input is accounted for (planner brief, step 3).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-38-plan.md](bug-round-38-plan.md).

**Status: v1.0, for the holder's GO: the panel passed v0.1 `9b2609c16` (m-331, mistral, msg 398ce8b4), no W (section 7). v1.0 changes no verdict: it records the PASS and its notes N1-N5, adds the other box's worktree hex match to the slug proof (N4) and folds in the seat file [bug-round-39/seat-mistral.md](bug-round-39/seat-mistral.md) (at `a0d001aeb`).** With 0 rows the round is served when this plan lands.

Editor: **c-125@sat** (claude, `specs_and_docs`).  
Panel: m-331@`<box2>` (mistral): **PASS** on v0.1 `9b2609c16` (msg 398ce8b4), seat file `a0d001aeb` on `review/c002-bug-round-39-mistral-seat`, folded here. No row has a WUI file (there is no row), so a mistral seat may sit (developer guide 5.1).

**One sha:** every count below is measured on **`c9f6ac91a`** (`origin/master` at this seat's fetch), on sat, 05:40Z..05:5xZ on 2026-11-22, unless a line says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b38-plan')` -> `Window: W=2026-11-22T06:35:43+01:00` (commit `c9f6ac91a`).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 38. The public repo does not name it.

---

## 1. How to read this

- Round 38 measured on `a42fff43c`. Since then `origin/master` moved by 5 commits: `5fac25f55` and `964e12e4a` (SPL-6199, spec 184 row H1, the hub agent model tables and routes) and the three b38 plan commits (`463e08773`, `1740cc172`, `c9f6ac91a`). This plan reads round 38's first inputs for round 39 (its section 6), the R7 notes that arrived since, the holders' inboxes, the CI report and the other workflows. For each one it says why it is not a row (sections 2 to 5).
- **Paths** are repo-relative. Line numbers are as of `c9f6ac91a`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where rows could come from (measured on `c9f6ac91a`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner, member and lane reports since round 38** | the brief's inputs; the inboxes, archives and outboxes of the holder, the orchestrator and the standby on sat since round 38's measuring (`find c-001 c-002 c-003 -maxdepth 2 -name '20261122T05*' -newermt '2026-11-22 05:10:00Z'`, rotation, lease, relay, standby, queue and spawn-request files left out), 05:44Z | 53 files, 38 distinct messages (`| xargs -n1 basename | sort -u`): the b38 panel and land messages, r87-02's land and ACCEPTED, r87-01's review and GO, the holder handovers, c-286's T6 file-list note, the GC and share notes; no owner word | **0 rows.** No report of a defect. c-286's note (SPL-5882 T6 needs a `case "evlog"` line in `cmd/spool/main.go`) is a file-list request inside a live lane, for the holder, not a bug. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (05:40Z..05:45Z) | wf 10: 100 runs (2026-11-21T09:33Z..2026-11-22T05:36Z): 56 success, 29 cancelled, 15 failure. First red per job over the 15 failures: `wui: browser e2e 3/8` x8, `1/8` x6, `6/8` x6, `orc: hermetic 4/4` x2, `wui 4/8` x1, the newest at 23:02Z (`61977111`). Last green of every failed job: the e2e shards on `09bf7208` (run 44986423470, 04:45Z), hermetic 4/4 on `964e12e4` (run 44987888837, 05:05Z). Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4 and 3/4, 57 %) | **0 rows.** The same 15 failures rounds 37 and 38 read, each with its landed fix: `75acaab9f` (SPL-6205), `acf2b4555` (SPL-6143), `c7c2247b6` (hermetic `hub_self_sign`); `git merge-base --is-ancestor <fix> origin/master` rc 0 for all three. No failure after 23:02Z. |
| **3. Other workflows** | `gh run list -R csitea/csi-spl -L 150 --json name,conclusion,status,createdAt,headSha,databaseId`, runs created after 04:55Z that are not `success` or `skipped` (05:42Z) | 1: wf 20 (hub build and deploy) on `c9f6ac91a`, run 44990382175, in progress | **0 rows.** No red in any workflow since 04:55Z. |
| **4. Skipped or disabled tests** | `git diff a42fff43c c9f6ac91a -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | empty | **0 rows.** |
| **5. New R7 notes** | g-118@sat (r87-01, SPL-6229, grok PASS on `ea2bf74e2`, N1-N2), read in the holder's archive on sat (msg 6dcd57e5) | 2 notes, no W | **0 rows**: section 3. |
| **6. Round 38's first inputs** | round 38 section 6, re-run | 5 items | **0 rows**: section 4. |

---

## 3. The new R7 notes, re-read

r87-01 (c-101@sat, SPL-6229, the hub's one move frame) is a live refactor row with the holder's GO (msg 7fff17bc) and is not on master: `git log origin/master --format=%h --grep=SPL-6229 | wc -l` -> 0 at 05:42Z. A note on its change is its lane's and its round's (R3).

| note | text (short) | why not a row |
|---|---|---|
| r87-01 g-118 N1 | the author reported 1500 `--- PASS` lines; the seat counted 1502 on parent `964e12e4a` and on head `ea2bf74e2` (top-level 1347 both, 0 failed) | **Not a defect**: a count in the author's report; the two trees match. |
| r87-01 g-118 N2 | the coverage gate prints ok unless `c + 1.0 < floor` (`csi-spl-api/src/bash/tests/run-all-tests.sh:59`): `internal/hub` 82.0 against floor 82.2 (`go-coverage-floor.txt:155`) and `cmd/spool` 76.9 against 77.8 (`:23`) pass | **Per design**: the 1.0 tolerance is the gate's own and neither number is under it. The numbers are the author's, on a review sha not on master; no red control on `c9f6ac91a`. |

---

## 4. Round 38's first inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The pre-push e2e selector's composed testids (round 37 section 4.1) | `rc01.sh` extracted from round 37's plan (sha256 first 12 hex `a76d454d20ea`, 2706 B, the same file), `bash rc01.sh origin/master` (05:40Z, 48 s) | `rc01 keys: got=exact-only want=has-prefix` / `rc01 sel: got=cut 37 want=selected` / `rc01 ctrl: got=selected want=selected` / `rc01 sha=c9f6ac91a keys=[msg-menu] wrong=2`, exit 1: the same as on `a42fff43c` | **Not a row**, as rounds 37 and 38 measured: no narrow fix turns `sel` green. `git log --oneline a42fff43c..origin/master -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh csi-spl-wui/src/components/UiPointMenu.vue csi-spl-wui/src/components/MessageMenu.vue` -> 0 lines: nothing changed. Still a gate-design input with the holder. |
| SPL-6174's link to the relay hash `3e2c61b1` | `git log origin/master --since=2026-11-21T20:00Z --format='%h %s' \| grep -iE 'SPL-6174\|relay'` -> 0 | the writer is still not named | **Not a row**: no writer, no red control. Carried. |
| b34-01 R7 c-855 N2 (`TestDocAssetHeldDoorCatalogue` passes on a NULL `proacl`) and SPL-6212 g-251 N2 (the 0310 test leaves out blocked, onhold, qas) | round 38 sections 3 and 4 | nothing is wrong on the tree | **Test-shaped**: a test or refactor round input. Carried. |
| The SPL-6212 and SPL-6226 R7 notes, if their lanes end without landing | `git log origin/master --format=%h --grep=SPL-6212` and `--grep=SPL-6226` -> 1 each, `463e08773`, whose subject only names them (the b38 plan); the lane map (05:41Z) lists c-063@`<box2>` (SPL-6212) and c-054@sat (SPL-6226) live | both lanes live, neither ended | **Owned** (R3), as round 38 read them. |
| The items round 38 carried (its section 4, last row) | no new report (source 1), no sighting in the 100 runs (source 2) | - | **As round 38 read them.** Carried. This seat did not re-run round 36's sat-only reads (the done-claim log, `lease.conf`). |

---

## 5. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | 0 rows, so no row file can collide. This plan's file and the candidate sites: `lane-map.sh --check csi-spl-doc/doc/md/bug-round-39-plan.md,csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh,csi-spl-api/src/bash/tests/go-coverage-floor.txt --agent c-125` (05:42:32Z) -> `WARN no live lane lists` them, exit 4: 12 `<box2>` lanes record no files (c-063, c-146, c-230, c-286, c-806, c-812, c-924, c-927, g-050, g-079, g-251, g-263). Their briefs (the lane map's scope column, 05:41:12Z) name the t1 issue backlog, four channel seats of another tenant (c-146, c-812, c-924, c-927), r87's planner, SPL-5882 T6, the native auth and R7 seats; none names this plan's file. The sat lanes (c-101 r87-01, c-107 SPL-5882 T4, c-120 the lane-map case 23 flake, c-033 spec 123 L3w, c-054 spec 154 B7, c-894 spec 184 H1, g-118) list none of the three paths. The queue: `do_spl_spawn_queue` (05:41:20Z) -> `0 queued, 0 placing`. |
| r87-01's notes | c-101@sat, refactor round 87 | live, GO'd (section 3). |
| The notes of SPL-6212 and SPL-6226 | c-063@`<box2>`, c-054@sat | their lanes, live (section 4). |
| The e2e selector's composed testids | the holder, as a gate input | unchanged since round 37 (section 4). |
| The lane-map case 23 flake | c-120@sat (bug lane, t1 `eb80ad17`) | live; its file `csi-spl-orc/src/bash/features/spawn-agents/tests/lane-map.tst.sh` stays off this round. |

---

## 6. Counts

| item | count |
|---|---|
| rows | 0 |
| inputs re-measured | 6 sources; 100 wf 10 runs (15 failures, each first-red job with its landed fix); the other workflows since 04:55Z (0 red); 2 R7 notes of 1 lane (0 W); round 38's first inputs (5); `rc01.sh` n=1 on `c9f6ac91a` |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b39-'` -> 0; `git ls-remote origin 'refs/heads/review/b39-*' 'refs/heads/wip/*b39*' 'refs/heads/*-b39-*'` -> nothing (rc 0); sat: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b39\|bug-round-39'` -> this planner's brief only (`c002-bug-round-39-planner.md`); `git worktree list \| grep -E 'b39\|bug-round-39'` -> this planner's only (05:40:03Z; again 07:08:51Z); on `<box2>` the same grep also matches c-906 and c-937 on the sha `15eb398c8` (a hex match, not a b39 worktree; panel N4) |
| R7 seat if a row comes | `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (05:42Z) -> `pick=sat` (every box past its high mark, sat the least): a grok seat |
| first inputs for round 40 | the selector's composed testids (if no gate round takes it); SPL-6174's relay-hash link, once its writer is named; b34-01 N2 and SPL-6212 N2 (test-shaped); the SPL-6212 and SPL-6226 notes if their lanes end without landing; r87-01 N2 if a tier=full run reads a package past its floor's tolerance; every item carried in section 4 |

---

## 7. Panel and reviewer (rulebook 3.2)

- **Editor:** c-125@sat (claude, `specs_and_docs`).
- **Panel:** m-331@`<box2>` (mistral), placed by the holder (c-002@sat, msg 8cc28d7f, ask 9e443795). It reviewed the plan only and wrote no code; it pushed its seat file with `PUSH_BRANCH=review/c002-bug-round-39-mistral-seat`.
- **Row reviewer (R7):** none; no row.
- **Review history:**
  - 2026-11-22 05:5xZ: v0.1 `9b2609c16`, pushed to `review/c002-bug-round-39-planner`: 0 rows.
  - 2026-11-22 07:0xZ: m-331 (mistral) **PASS** on v0.1 `9b2609c16e4de0abab1f7e1e4251ce004a6cb1a7`, no W (msg 398ce8b4). It re-ran the slug proof, the CI report, the other workflows, the fixes' `merge-base --is-ancestor` (`75acaab9f`, `acf2b4555`, `c7c2247b6`), `rc01.sh` extracted from round 37's plan on `c9f6ac91a` (`wrong=2`, exit 1, as this plan reads), the skip-marker diff, the cited file:line sites, the lane map and `do_check_dist_hygiene`. Its review line: `do_spl_review_line_check` with `REVIEW_LINE_SYNTAX=1` on sat -> `DOCS-ONLY`, `SYNTAX OK` (the log is on `<box2>`, so the journal match was not run here). Seat file `a0d001aeb`, folded as [bug-round-39/seat-mistral.md](bug-round-39/seat-mistral.md).
    - **N1**: the 100-run window now reads 56 success / 28 cancelled / 15 failure / 1 running (09:46:41Z..06:45:22Z); the 15 failures, their first-red counts (8/6/6/2/1), the newest at 23:02:14Z (`61977111`) and the three fixes are unchanged; last green per failed job moved to `44990752760` (`c9f6ac91`, 05:45:15Z).
    - **N2**: the lane map answers per box: 6 no-file sat lanes on the seat's box, 12 on sat at this plan's read; both exit 4, neither lists the plan file or the seat file.
    - **N3**: the holder's candidates file and the g-118 message 6dcd57e5 are on sat only; the seat did not read them. This editor checked both exist on sat (07:08Z: `ls` the candidates file, 25510 B; the message in c-002's archive). The g-118 citations on the tree (`run-all-tests.sh:59`, `go-coverage-floor.txt:23` and `:155`) the seat verified on `c9f6ac91a`.
    - **N4** (recorded in v1.0, section 6): on `<box2>` the worktree grep matches c-906 and c-937 on `15eb398c8`, a hex false positive (round 38's N6 class).
    - **N5**: on `<box2>` `/var/spool-hub/dispatch/briefs` holds no b39-named file; this plan's brief is on sat.

---

## 8. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-125@sat | v1.0 |
| Panel | m-331@`<box2>` (mistral) | **PASS** on v0.1 `9b2609c16` (msg 398ce8b4), no W; N4 recorded in v1.0 |
| Holder | c-002@sat | - |
