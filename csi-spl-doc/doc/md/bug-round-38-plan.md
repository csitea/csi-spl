# Bug-fix round 38 - plan (0 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6232 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `eb80ad17-a6c4-4ce4-80ce-8061c013695a` ("Bug round 38", opened by c-002@sat 04:42Z). Round 37 ([bug-round-37-plan.md](bug-round-37-plan.md)) is closed with 0 rows (`09bf72086`, Closes: SPL-6228).  
Round focus: none. Every input of section 2 was re-measured. The new inputs since round 37 are the R7 notes of three lanes (16 notes, no W); none is a defect with a red control that a narrow fix turns green, and two of the three lanes are still live (R3).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. 0 rows is a valid verdict when every input is accounted for (planner brief, step 3).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-37-plan.md](bug-round-37-plan.md).

**Status: v1.0, signed: the panel passed v0.1 `3f6c4c407` (m-289, mistral, msg f97fdd1b) and v1.0 `1740cc172` (msg 55cc7384; section 7). v1.0 changes no verdict: it records the PASS and its notes N1-N6, corrects the worktree line of the slug proof (N6) and folds in the seat file [bug-round-38/seat-mistral.md](bug-round-38/seat-mistral.md) (at `45d14afe9`, its v1.0 signature section).** **Closed on land**: 0 rows, so the round is served when this plan lands (holder GO msg e18c6ee0).

Editor: **c-279@`<box2>`** (claude, `specs_and_docs`).  
Panel: m-289@`<box2>` (mistral): **PASS** on v0.1 `3f6c4c407` (msg f97fdd1b), seat file `6425c1f55` on `review/c002-bug-round-38-mistral-seat`; **PASS** on v1.0 `1740cc172` (msg 55cc7384), seat file `45d14afe9`, folded here. No row has a WUI file (there is no row), so a mistral seat may sit (developer guide 5.1).

**One sha:** every count below is measured on **`a42fff43c`** (`origin/master` at this seat's fetch), on `<box2>`, 04:56Z..05:10Z on 2026-11-22, unless a line says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b37-plan')` -> `Window: W=2026-11-22T05:37:58+01:00` (commit `09bf72086`).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 37. The public repo does not name it.

---

## 1. How to read this

- Round 37 measured on `e46621014`. Since then `origin/master` moved by 4 commits: the three b37 plan commits and r87-02 (`a42fff43c`). This plan reads round 37's first inputs for round 38 (its section 6), the R7 notes the brief names, the holders' inboxes, the CI report and the other workflows. For each one it says why it is not a row (sections 2 to 5).
- **Paths** are repo-relative. Line numbers are as of `a42fff43c`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where rows could come from (measured on `a42fff43c`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner, member and lane reports since round 37** | the brief's inputs; the inboxes and archives of the holder, the orchestrator and the standby on `<box2>` since W (`find c-001 c-002 c-003 -maxdepth 2 -name '20261122T0[45]*' -newermt '2026-11-22 04:37:00Z'`, rotation, lease, relay, standby and spawn-request files left out), 05:00Z | 2 files: c-248's b37 close note and m-261's b37 PASS; no owner word | **0 rows.** No report of a defect. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (04:56Z..05:06Z) | wf 10: 100 runs (2026-11-21T09:25Z..2026-11-22T04:55Z): 53 success, 30 cancelled, 15 failure, 2 running. First red per job over the 15 failures: `wui: browser e2e 3/8` x8, `1/8` x6, `6/8` x6, `orc: hermetic 4/4` x2, `wui 4/8` x1, the newest at 23:02Z (`61977111`). The last green of every failed job: run 44982077734 on `e4662101` (03:45Z). Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4 and 3/4, 57 %) | **0 rows.** The same 15 failures round 37 read (its source 2), each with its landed fix: `75acaab9f` (SPL-6205, the 21:17Z..23:02Z `1/8`, `3/8`, `6/8` reds), `acf2b4555` (SPL-6143, the 12:xxZ `3/8` and `4/8` red), `c7c2247b6` (the 11:xxZ hermetic 4/4 `hub_self_sign` red). No failure after 23:02Z. |
| **3. Other workflows** | `gh run list -R csitea/csi-spl -L 150 --json name,conclusion,createdAt,headSha,databaseId`, runs created after 02:30Z that are not `success` or `skipped` (05:00Z) | 2: wf 10 on `09bf72086` and on `a42fff43c`, both still running | **0 rows.** No red in any workflow since 02:30Z. |
| **4. Skipped or disabled tests** | `git diff e46621014 a42fff43c -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | empty | **0 rows.** |
| **5. New R7 notes** | g-251 (SPL-6212, PASS on `79ed989d3`, N1-N5) and g-263 (SPL-6226, PASS on `2acddb381`, N1-N3), read in their outboxes on `<box2>`; g-080 (SPL-6224, PASS on `cdf8f5074`, N1-N8), relayed verbatim by the holder (c-002@sat, msg d7c203fd, from its archive on sat) | 16 notes, no W | **0 rows**: section 3. |
| **6. Round 37's first inputs** | round 37 section 6, re-run | 4 items | **0 rows**: section 4. |

---

## 3. The new R7 notes, re-read

SPL-6212 (c-063@`<box2>`, t1 issue backlog, migration 0310) and SPL-6226 (c-054@sat, spec 154 B7, the contacts scope) are live lanes, landing: `git log origin/master --format='%h %s' --grep='SPL-6212'` -> 0 and `--grep='SPL-6226'` -> 0 at 04:58Z. A note on their own change is theirs (R3). SPL-6224 landed (`316422e7c`..`cdf8f5074`, docs `e46621014`); the event-log area it touched is the area of SPL-5882's live and queued rows (T4 c-107@sat, the routes; T6, queued, ask 78986553, the frame and CLI).

| note | text (short) | why not a row |
|---|---|---|
| SPL-6212 g-251 N1 | `lane-issue-and-docs.md:83` and `specs/172-work-chain-enforcement/spec.md:66` still name `fcf09921` as t1's default backlog topic | **Owned**: docs of the change c-063 is landing (`git grep -n fcf09921 origin/master -- <the 2 files>` -> both lines, as the note says). Not wrong on master until 0310 lands. |
| SPL-6212 g-251 N2 | the 0310 test covers wip, todo, eval, done, diss, not blocked, onhold, qas | **Owned, test-shaped**: the predicate is `NOT IN ('done','diss')`, the same as `store.IssueClosed`; nothing wrong. |
| SPL-6212 g-251 N3 | a concurrent insert on `fcf09921` that commits after 0310's UPDATE snapshot can stay there | **Owned**, one-shot at migrate time; the issue still has one link. No red control a lane can run on master. |
| SPL-6212 g-251 N4, N5 | the default is pinned by three tests, none runs bash, Go and SQL together; the commit comment's status list omits blocked and qas | **Owned**, test-shaped and a comment. |
| SPL-6226 g-263 N1 | `want=calendar,calendar` is 400, `want=contacts,contacts` is accepted (`gcal_connect.go:209-217` on the review sha) | **Owned** by c-054 (not on master). Both answers are inside the spec's enum (calendar, contacts, calendar,contacts): a hand-made duplicate is refused or deduped, never widened. |
| SPL-6226 g-263 N2 | the authorize URL's scope query is not signed; a wider grant the user consents to is stored | **Not a bug**: consent, not a forged State (the note's own verdict). |
| SPL-6226 g-263 N3 | the refresh path does not write `GrantedScopes` | **Not a bug**: a refresh does not change the granted scopes. |
| SPL-6224 g-080 N1, N2, N3 | the cnf key is `hub.env.SPOOL_HUB_EVLOG_FLUSH_S`, not `hub.evlog.flush_s`; the example env lists both keys; the T3 row had no landed sha | **Accepted** by the reviewer; N3 is closed by `e46621014` (the T3 row records the landed shas). |
| SPL-6224 g-080 N4 | `server.go:980` logs the literal `"http 5xx"`; a later edit of only the literal would count that line twice | **Not a defect today**: latent on a future edit. The comment at `server.go:978-979` says why it stays a literal. |
| SPL-6224 g-080 N5 | a listen or Serve error returns before `FlushEvlog` | **Per spec**: 10.4.2 accepts losing up to one interval on a crash. |
| SPL-6224 g-080 N6 | the unwritten line adds a redacted error field | **Not a bug**: C33 proves the planted secret absent. |
| SPL-6224 g-080 N7 | Mine pairs past 1000 fold into the `evlog.overflow` row, whose message says "error groups not kept" | **Per spec**: `specs/162-event-log/spec.md:649-650` puts the pairs into "the same `evlog.overflow` row" and `:752` fixes its message (`<n> error groups not kept (cap 1000)`); `internal/hub/evlog.go:204-228` and `internal/evlog/evlog.go:268-278` do that. A wording change is spec work, and the area is SPL-5882's. |
| SPL-6224 g-080 N8 | an unmatched route's log line uses `r.URL.Path`; a panic's raw value is on the Error line | **Not new**: every 5xx line carries `path` (`server.go:965`); the stored row is the redacted sighting. No red control. |

---

## 4. Round 37's first inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The pre-push e2e selector's composed testids (round 37 section 4.1) | `rc01.sh` extracted from round 37's plan (sha256 first 12 hex `a76d454d20ea`, 2706 B, the same file), `bash rc01.sh origin/master` (05:00Z, 31 s) | `rc01 keys: got=exact-only want=has-prefix` / `rc01 sel: got=cut 37 want=selected` / `rc01 ctrl: got=selected want=selected` / `rc01 sha=a42fff43c keys=[msg-menu] wrong=2`, exit 1: the same as on `e46621014` | **Not a row**, as round 37 measured: no narrow fix turns `sel` green. `git log --oneline e46621014..origin/master -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh csi-spl-wui/src/components/UiPointMenu.vue csi-spl-wui/src/components/MessageMenu.vue` -> 0 lines: nothing changed. Still a gate-design input with the holder. |
| SPL-6174's link to the relay hash `3e2c61b1` | `git log origin/master --since=2026-11-21T20:00Z --format='%h %s' \| grep -iE 'SPL-6174\|relay'` -> 0 | the writer is still not named | **Not a row**: no writer, no red control. Carried. |
| b34-01 R7 c-855 N2 (`TestDocAssetHeldDoorCatalogue` passes on a NULL `proacl`) | round 37 section 4 | nothing is wrong on the tree | **Test-shaped**: a test or refactor round input. Carried. |
| The items round 37 carried (its section 4, last row) | no new report (source 1), no sighting in the 100 runs (source 2) | - | **As round 37 read them.** Carried. This seat did not re-run the sat-only reads. |

---

## 5. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | 0 rows, so no row file can collide. This plan's file and the two candidate sites: `lane-map.sh --check csi-spl-doc/doc/md/bug-round-38-plan.md,csi-spl-api/src/go/spool-hub-api/internal/hub/evlog.go,csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh --agent c-279` (05:00:09Z) -> `WARN no live lane lists` them, exit 4: 4 sat lanes record no files (c-054 s154 B7, c-101 r87-01 hub move frame, c-107 SPL-5882 T4 evlog routes, c-894 s184 H1 hub agent model). c-107 is the event-log area, so `evlog.go` is not free. The queue: `do_spl_spawn_queue` (04:58:17Z) -> `1 queued, 0 placing`: ask 78986553, SPL-5882 T6 (evlog frame and CLI). |
| The notes of SPL-6212 and SPL-6226 | c-063@`<box2>`, c-054@sat | their lanes, landing (section 3). |
| The event-log notes of SPL-6224 | SPL-5882 (T4 live, T6 queued) | none is a defect (section 3). |
| The e2e selector's composed testids | the holder, as a gate input | unchanged since round 37 (section 4). |

---

## 6. Counts

| item | count |
|---|---|
| rows | 0 |
| inputs re-measured | 6 sources; 100 wf 10 runs (15 failures, each first-red job with its landed fix) and the other workflows since 02:30Z (0 red); 16 R7 notes of 3 lanes (0 W); round 37's first inputs (4); `rc01.sh` n=1 on `a42fff43c` |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b38-'` -> 0; `git ls-remote origin 'refs/heads/review/b38-*' 'refs/heads/wip/*b38*' 'refs/heads/*-b38-*'` -> nothing (rc 0); `<box2>`: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b38\|bug-round-38'` -> one hit, `20261009-b38743cb-agy-bg-review.md` (a hex id, not a round brief); `git worktree list \| grep -E 'b38\|bug-round-38'` -> this planner's, and `/tmp/g263-s154-b7` (its sha `2acddb381` holds the letters `b38`: a hex match, the SPL-6226 R7 scratch, not a b38 worktree; panel N6) |
| R7 seat if a row comes | `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (05:00:24Z) -> picks `<box2>`: a grok seat |
| first inputs for round 39 | the selector's composed testids (if no gate round takes it); SPL-6174's relay-hash link, once its writer is named; b34-01 N2 and SPL-6212 N2 (test-shaped); the SPL-6212 and SPL-6226 notes if their lanes end without landing; every item carried in section 4 |

---

## 7. Panel and reviewer (rulebook 3.2)

- **Editor:** c-279@`<box2>` (claude, `specs_and_docs`).
- **Panel:** m-289@`<box2>` (mistral), placed by the holder (c-002@sat). It reviewed the plan only and wrote no code; it pushed its seat file with `PUSH_BRANCH=review/c002-bug-round-38-mistral-seat`.
- **Row reviewer (R7):** none; no row.
- **Review history:**
  - 2026-11-22 05:03Z: v0.1 `3f6c4c407`, pushed to `review/c002-bug-round-38-planner`: 0 rows.
  - 2026-11-22 05:2xZ: m-289 (mistral) **PASS** on v0.1 `3f6c4c40758b9967d3bd14b2e32e8f56d20e4d08`, no W (msg f97fdd1b). It re-ran the slug proof, the CI report, the other workflows, the fixes' `merge-base --is-ancestor` (`75acaab9f`, `acf2b4555`, `c7c2247b6`, `cdf8f5074`), `rc01.sh` extracted from round 37's plan on `a42fff43c`, every cited file:line, the lane map, `do_check_dist_hygiene` and `do_check_pre_push`. Seat file `6425c1f55`, folded as [bug-round-38/seat-mistral.md](bug-round-38/seat-mistral.md).
    - **N1**: origin/master moved after the editor's fetch (`a42fff43c` -> `964e12e4a`, two SPL-6199 api commits); every count re-run still matches.
    - **N2**: the 100-run window now reads 54 success / 30 cancelled / 15 failure / 1 running (09:32Z..05:05Z); the newest failure is still 23:02Z (`61977111`), and the three fixes are ancestors of origin/master.
    - **N3**: the other workflows since 02:30Z: 0 red; the 2 not green are still running on `964e12e4a` (wf 10 and wf 20).
    - **N4**: the queue now holds ask 32816dc0 (this plan read 78986553 at 04:58Z); the lane map lists 3 no-file sat lanes (c-894 ended); none b38-shaped.
    - **N5**: the holder's candidates file is on sat only; the seat did not read it. This plan did not either: its sources are section 2's.
    - **N6** (fixed in v1.0): the slug proof's `git worktree list` grep also matches `/tmp/g263-s154-b7` (sha `2acddb381`); a hex false positive, not a b38 worktree. Section 6 now says so.
  - 2026-11-22 05:3xZ: v1.0 `1740cc172`, pushed to a new branch, `review/c002-bug-round-38-planner-v1`: the rebase onto `964e12e4a` rewrote v0.1 to `463e08773` (the same plan blob), so the old branch could not fast-forward, and no branch was force-pushed.
  - 2026-11-22 05:4xZ: m-289 **PASS** on v1.0 `1740cc17225607f8b931ab0978bf5dd3aeaead49`, no W (msg 55cc7384). It re-checked the diff to master (only the 2 b38 files, +359, a fast-forward), the seat file blob-identical to `6425c1f55`, the 0 rows, N6, the slug proof, hygiene and the pre-push gate. Seat file `45d14afe9` (its v1.0 section), folded here. The holder's line check: `do_spl_review_line_check` rc 0 on `<box2>` for both PASS lines (docs-only path).
  - 2026-11-22 05:4xZ: the holder's GO on v1.0 (c-002@sat, msg e18c6ee0). With 0 rows the round closes when this plan lands.

---

## 8. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-279@`<box2>` | v1.0 |
| Panel | m-289@`<box2>` (mistral) | **PASS** on v0.1 `3f6c4c407` (msg f97fdd1b) and on v1.0 `1740cc172` (msg 55cc7384); no W; N6 fixed in v1.0 |
| Holder | c-002@sat | GO on v1.0 (msg e18c6ee0); 0 rows, the round closes on land |
