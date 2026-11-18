# Bug-fix round 18 - plan (0 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5900 (this plan, the round's discussion issue).  
Discussion: t1 #spool-hub-bugs `da398927-00f9-45c7-8337-0c7ff5431647` ("Bug round 18", opener msg 824280c4, opened by c-002@sat 2026-11-18T14:34Z). Requested because the bug share was under its band over 24 h (17%, band 20-30%). Round 17 ([bug-round-17-plan.md](bug-round-17-plan.md) v1.0.1, 1 row) is served: b17-01 `e1c6f870e` on `origin/master`, quality gate 44322111931 success, SPL-5896 and SPL-5880 done.  
Round focus: none. Every input was re-measured on one sha, and none gives a defect that is live on `origin/master`, unowned and has a red control. Each one is fixed, not code, a real outage, owned by a live or queued lane, or a watch item with no reproduction (sections 4 to 6). Rulebook 5.2 says 1 row is a round; it does not make up a row when there is none. This plan records the measurement so that round 19 starts from it.  
Round size: owner order 2026-11-18 (HUM-10, t1 10f8c08e msg a1474f69; e1139a1e msgs 44445433, 4e1adcfa): bug rounds take the perf cadence, 1 to 3 rows; bugs are priority 2.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-17-plan.md](bug-round-17-plan.md) (same shape, same 5 sources).

**Status: v1.0**, panel PASS (m-557@sat, mistral, on v0.1 `bc559b2f6`); rows unchanged.  
Editor: **c-871@<box2>** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count below is measured on **`8de1d37b1`** (`origin/master`, committed 2026-11-18T15:31:34Z), on <box2>, between 15:46Z and 16:00Z on 2026-11-18, unless a row says sat. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b17-plan')` -> `W=2026-11-18T13:20:28+02:00`.

---

## 1. How to read this

- A candidate becomes a row only with a red control that fails on `8de1d37b1` (rulebook 3.1). None here has one, so the action table (section 3) is empty.
- **Paths** are repo-relative. Line numbers are as of `8de1d37b1`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `8de1d37b1`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 and the other workspaces since round 17 was planned** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-18T10:10:38Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query`, then every non-probe post read whole (t1 41, the others 74) | t1 65 (24 `[spool-probe]`, 11 regex hits), csitea 67, three other workspaces 7 (0 regex hits each) | **0 rows.** The t1 posts are the rounds-cadence order, poll answers, feature requests (event-log errors SPL-5882, calendar tags, card kinds SPL-5884, PDF export, pricing) and questions. Two read like defects and are not: t1 `035cb09e` msg 79b3ed44 (12:15:50Z, "I dd not see any go button") is a Go form on the dev site, answered by c-003 (msg ca2e11bd) and done at 12:18:23Z; t1 `0c817694` msg e78b2088 (13:38:55Z, loads under two OS users) is by design, answered by c-002 (msg 432327cb). csitea `12ccd587` msg ba033650 (11:37Z, a human's label shows the id) is fixed by `8de1d37b1` (SPL-5889). The other csitea posts are work on a customer project on a remote box, not this tree. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (15:47Z..15:55Z), then `gh run list --workflow 10_ci-quality.yml --branch master -L 15` and the failed jobs' logs | 100 runs 2026-11-17T22:53:03Z .. 2026-11-18T15:45:31Z: 57 success, 34 cancelled, 6 failure, 3 running. Every timeout headroom line `ok` (highest p90: 56 %) | Two signatures. (a) `orc: hermetic action tests 3/4`, `FAIL: 11. no hook after spl_spawn_placed_close in spl_spawn_place_launch`, runs 44287478217, 44288340441, 44289475051 (10:39Z..10:52Z): green since (last green 44330856293 on `897e67e13`). (b) `orc: hermetic action tests 1/4`, `FAIL: 1. real manifest (rc 0: PLAN cron: the crontab before -> after` of `install-box-crons.tst.sh`, runs 44329803276 (`b36b20577`), 44330856293 (`897e67e13`) and 44335971661 (`04772cfe5`, job 134918724305): red since `b36b20577`, r62-01 (SPL-5898). Its lane c-835@<box2> owns the fix: c-843's note to it (15:41:49Z), its answer "yes it is mine, the fix is 477df2" (15:41:57Z), c-845's R7 PASS on 477df2 (15:47:42Z) and the holder's GO (15:48:38Z). **0 rows** (R3; section 6). |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 8de1d37b1 -- "$d" \| wc -l; done`; then `git diff 43d8e1325 8de1d37b1 -G '<the same pattern>' --stat` | api 199, wui 18, orc 10, iac 21, utl 0 (round 17: wui 17, the rest the same) | The diff names only `csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs` (p17-01, `b97a764ff`): a comment that names `ci-skip.txt`, no new skip. **0 rows.** |
| **4. Box cron logs and GC notes, last 24 h** | <box2>: an awk over the 40 `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h, for `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|No such file or directory\|operand expected\|Permission denied\|FATAL\|ERROR\|unknown_discussion`, keyed by the last ISO timestamp above each line (`spool-env` WARN lines skipped), counted per distinct line; each hit read in its file | 79 distinct lines in 24 files | **0 rows.** Every hit is one of: (a) the disk-full event of 2026-11-17T21:36Z..22:00Z on <box2> (`No space left on device` in `token-burn`, `spawn-place`; `box-link-watch.py` `OSError: [Errno 28]` in `write_state`; the `tee >(do_mask_private_keys ...)` status 141 lines of 14 crons in the same half hour); (b) the network drop of 2026-11-18T10:15Z..10:22Z (`hub unreachable`, `git fetch origin/master failed`, `gcloud could not activate the SA key`, `could not read the archived topics of prd`, `the runs or jobs query failed`); (c) the GitHub rate limit at 08:00Z..08:23Z (`ci-red-note`, `qas-ci-accept`, `ci-overflow`), as rounds 16 and 17 read it; (d) already fixed: `lane-rotate` `/proc/<pid>/cmdline: No such file or directory` (543 in the file, the last at line 126106 of 127997, 04:15:16Z, before b14-02 `0a5a8fbb3` landed at 05:04Z; the box checkout holds it, `merge-base --is-ancestor` -> yes) and its `line 174 ... operand expected` (2026-11-17T16:11Z; the line is guarded on `8de1d37b1`); `agent-steps-log` `c-141: no claude session jsonl` (10309 lines from 2026-11-06, the last at 00:28:05Z, then `GAP ... quiet until one appears` at 00:29:04Z and nothing since); (e) real events, not code: `box-update` (SPL-5847, owned), `outlook-import` 15:30Z `no result for run 17bb9de1a8a3 after 600s (Outlook box offline?)` and `box-link-watch` `LINK STUCK` since 15:25:56Z, both the remote link being down (condition d `the relay link/session is down`, 27 ticks; condition a, 4 commands and 2 bundles sent with no receipt). |
| **5. Open defect issues, round 17's leftovers, the holder's candidate list, refactor round 35's left-out bug items** | prd `issues` (t1, open, `bug` label or a defect word in the title, 40 newest); the R7 report of b17-01 (c-824's report, msg to c-001 at 14:32:59Z); refactor-round-35-plan.md section 2 "Left out"; the holder's list (read on sat by c-003, msg 5eae3157, from `c002-next-round-candidates.md`, 2967 B, mtime 2026-11-18 03:57); `git diff --stat 43d8e1325 8de1d37b1 -- <their files>`; prd `human_events` (the WUI error log), last 24 h and 30 days | 40 issues (4 new since round 17); 1 R7 report (W1 kept, N1 skipped, N2); 7 candidate rows on the list; 1 WUI error burst since round 17 | **0 rows.** The new issues are live lanes or features (section 6). b17-01's N1 does not fail (section 4). The list's items are fixed or were judged in rounds 14 to 17 with no failing behaviour; of their files only `spl-watchdog.func.sh` and `spl-lane-rotate.func.sh` changed since `43d8e1325` (the fixes in section 4). The WUI burst is the F9 Vue crash family again, with no red control yet (section 5). |

---

## 3. The rows

None. No candidate has a red control that fails on `8de1d37b1` and is not already owned (sections 4 to 6).

### 3.1 Files (R1) and batches

- **Batches:** none.
- **Off limits** for the next planner, as read here: every live lane's files; refactor round 62's rows (`refactor-round-62-plan.md` section 3.2, the 5 written paths: `csi-spl-orc/src/bash/run/install-box-crons.func.sh`, `csi-spl-orc/src/bash/run/spl-box-state-backup.func.sh`, `csi-spl-utl/src/bash/run/external-api-health.func.sh`, `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`, `csi-spl-orc/src/bash/tests/no-literal-paths.baseline`); SPL-5874's follow-up row (c-832@<box2>, ask 1801656f); perf round 18 row 01 (queued, `c002-p18-01-ci-hub-suite-go-build-cache`).
- **How the files were checked (2026-11-18, <box2>):**
  - 15:56:57Z `lane-map.sh --check csi-spl-doc/doc/md/bug-round-18-plan.md --agent c-871` -> `free`, exit 0. This plan writes no other file.
  - 15:57:14Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 9 queued: 1 bug (ask 8080ca91, a bug of the box link relay), 1 refactor (p18-01), 7 features. None names this plan.
- **Slug b18 is unused as a round id** (15:46Z, <box2>; sat by c-003, msg 5eae3157):
  - `git log origin/master --grep='(b18-'` -> 0; `git log origin/master -E --grep='\bb18-[0-9]{2}-'` -> 0; `git log origin/master --since="$W" --oneline -E --grep='\(b18-'` -> 0;
  - `git ls-remote origin | grep -cE 'b18-[0-9]{2}|bug-round-18'` -> 0 (sat: 0);
  - `grep -rlE '(^|[^0-9a-f])b18-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> 0 files (sat: 0); `bug-round-18` -> 2 files, this planner's ask and brief;
  - sat: `git branch -a | grep -cE 'b18-[0-9]{2}'` -> 0.

  After this plan's pushes, `--grep='(b18-'` matches the plan's commits (`docs(b18-plan, ...)`) and `ls-remote` the planner's review branch.

### 3.2 Red controls

None (no row).

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| b17-01 R7 N1 (c-824): `EXPIRED` (`box-link-watch.py:74`, `\bexpired\b.*\bnothing ran\b`) is unanchored, so a genuine refusal whose text holds both words would be skipped (`:151`, `:216`) | every `box: exec: REFUSED` line in <box2>'s relay logs (the `*.out.log` files under `BOX_LINK_WATCH_LOG_DIR`), ids and counts normalised, `sort \| uniq -c` | One form only: `box: exec: REFUSED request <id> (gr-cmd-<id>.zip): expired <n>s ago; nothing ran; result queued (exit 4)` | No real line misfires; the relay that prints these lines is not in this tree (`box-link-watch.py:4-5`). Hardening, not a defect. |
| b17-01 after the land: does the watch still raise condition b on expired requests? | `box-link-watch/cron.log` after 14:14Z, the `INFO box <c>:` lines | 0 `b:` lines; the 15:25:56Z incident is conditions a, c and d | Row 01 holds. Its R5 live proof on the next drain of expired requests is still to come. |
| Holder's list: r34-05 R7 c-331 N3, literal `/var` paths in `spl-watchdog.func.sh:72,1311` and `spl-lane-rotate.func.sh:112` | `grep -n LOGIN_STATE_DIR csi-spl-orc/src/bash/run/spl-watchdog.func.sh`; `grep -n '/var/' csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh` | `:72` and `:1318` read `spl_claude_login_state_dir`; `spl-lane-rotate.func.sh` has no `/var/` line | Fixed by r61-02 (`61bdcbd1c`, SPL-5870). |
| Holder's list: b12-02 R7 c-126 N1-N4 (terraform `-input=false`, `${1:?}`, dropped rc, a duplicate test case) | `git diff --stat 43d8e1325 8de1d37b1 -- 'csi-spl-iac/src/bash/run/tf-*.func.sh' csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh` -> empty | Unchanged | As round 16 section 4: N4 not reproduced (terraform's status reaches the run), N2/N3 no failing run. |
| Holder's list: SPL-5825 R7 c-386 W1, W2, N1-N4 (reflection gather) | `git log origin/master --grep='(b14-01'` -> `ce765392c`; `git diff --stat 43d8e1325 8de1d37b1 -- csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh` -> empty | W2 and N1 fixed by b14-01; the rest unchanged | As round 14 section 4: W1 needs a new source (a feature), N2-N4 no failure. |
| Holder's list: SPL-5824 R7 c-381 W1, N1, N2 (env vars the desk hop drops); SPL-5828 N1, N2; SPL-5850 N1 (AltGr); r34-01 R7 c-321 N1, N2 | `git diff --stat 43d8e1325 8de1d37b1 -- <their files>` -> empty | Unchanged | As round 14 section 4. r34-01 N1/N2 are test-coverage gaps with no failing behaviour: input for a test round, not a bug row. |
| desk-cron `bin/spool` older than its sources | every orc cron line (`spool-env: WARN ... built 2026-10-31T02:29:14Z, last source commit 2026-11-18T11:54:25Z`) | As in rounds 12 to 17 | As before. |

---

## 5. Not reproduced, or not code

| candidate | command | result |
|---|---|---|
| **Watch: the F9 Vue crash family again** (SPL-5751; F9 of the owner's event log, t1 955ab0bd; guarded by SPL-5738 `02386fae6`, "Guard, then watch") | prd `human_events`, `kind='error' and source='vue'`, last 30 days, grouped by minute and human | 2026-11-18T11:17:20Z, HUM-10, a channel route of the customer project: 22 `TypeError: Cannot read properties of null (reading 'emitsOptions')` and 1 `NotFoundError: Failed to execute 'insertBefore' on 'Node'`, all in `TopicPane/LiveFeed/TransitionGroup`, within 12 s. Earlier bursts of the family: 2026-10-26T13:21Z (15), 2026-10-27T08:01Z..08:03Z (72), 2026-11-17T14:47Z (12). The 11:17:20Z burst came 34 s after the prd WUI release of `07102fb7e` (run 44292290079, `release complete` 11:16:46Z); 2026-10-26T13:21Z falls inside run 40329116513 (13:16Z..13:24Z, its release time not read); 2026-11-17T14:47Z has no release in the 30 min before it (run 44098957255 ended 14:16:21Z). So 1 burst of 3 suggests a link to a deploy; none shows it. A lead, unchecked: `LiveFeed.vue:47` keys each row by `msg_id` (`feedRows`, `:353-366`), and `shown` (`:304`) does not drop a duplicate id, so two rows with one `msg_id` in `props.rows` would give a duplicate key in the `TransitionGroup`, which can produce these two errors. Whether the stores can hand LiveFeed a duplicate was not read. **No red control, so no row.** Input for SPL-5751's owner, and for round 19 if it recurs or a duplicate is shown. |
| The remote link down since 15:25:56Z (`LINK STUCK` blocker to c-002@sat; `outlook-import` 15:30Z) | source 4 (e) | A real outage on the remote side, alerted as designed. |
| Disk full on <box2>, 2026-11-17T21:36Z..22:00Z | source 4 (a); `df -h /` now 41 % used | One event; the crons have run clean since. What filled the disk was not read here. |
| Network drop 10:15Z..10:22Z; GitHub rate limit 08:00Z..08:23Z | source 4 (b), (c) | As rounds 16 and 17. |
| CI 3/4 `FAIL: 11. no hook after spl_spawn_placed_close` (3 runs, 10:39Z..10:52Z) | source 2 (a) | Green since. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| CI orc 1/4 `install-box-crons.tst.sh` case 1, red since `b36b20577` | c-835@<box2>, r62-01 (SPL-5898) | Fix `477df2` reviewed (c-845 PASS) and GO'd by the holder at 15:48:38Z. |
| SPL-5905 (a queued ask of another workspace's topic shows priority 3) and SPL-5904 (spec 170 B3 phone To-do follow-up) | lanes placed by c-002, `wip` | New since round 17; in flight. |
| box link relay launch race (ask 8080ca91) | queued bug lane | In the queue. |
| SPL-5874 W1/N1/N2: a held queue row never ends or alarms | c-832@<box2> (ask 1801656f), the holder's follow-up row | Left out (brief, R3); `6de08753e` (SPL-5897) landed part of it. |
| SPL-5847 `box-update` FATAL | c-002, `wip` | As rounds 14 to 17. |
| SPL-5751 (`vue: insertBefore`) and the F9 family | the owner's event-log program (t1 955ab0bd); SPL-5882 (backend errors into the event log) | Watch (section 5). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 0 |
| inputs re-measured | 5 sources; 7 holder candidates; 3 R7 notes of b17-01; 79 cron error lines; 2 CI signatures |
| watch items | 1 (the F9 Vue crash family, section 5) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-871@<box2> (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-bug-r18`, with at least one non-claude seat (rounds 14 to 17 had a mistral doc seat). With 0 rows, the panel checks that each input in sections 2, 4, 5 and 6 is measured as written and that none of them should be a row.
- **Review history:**
  - 2026-11-18 15:56Z: the editor asked the holder for the candidate list and the sat slug check (msg 31f29039); c-003@sat answered (msg 5eae3157), folded into sections 2, 3.1 and 4.
  - 2026-11-18: the editor pushed v0.1 to `review/c002-bug-round-18-planner`.
  - 2026-11-18: the holder c-002@sat ruled that a 0-row round still gets its panel (msg 2223f7f7) and queued a mistral seat (ask e15b1f63, `c002-bug-round-18-mistral-panel-seat`), asked to test the 0-row verdict and whether the F9 watch item can be a row with a red control.
  - 2026-11-18: panel m-557@sat (mistral) PASS on v0.1 `bc559b2f6` (msg ca5ae291), no W items. It re-ran the b18 slug check, the five sources, every cited file:line and sha (`git show`, `merge-base`), `lane-map.sh --check` (exit 4) and `do_check_dist_hygiene` (clean). On the F9 item: `LiveFeed.vue` itself does not dedupe, as section 5 says, but every store path into its rows merges by msg_id first (`mergeById`, `csi-spl-wui/src/utils/feed.mjs:39-62`, used by `rowsForRightPane` in `channel-feed.mjs:317-329`, the non-mock `paneRows` of `TopicPane.vue:120-124`, and `stores/live.ts:96`; the channel store filters pages through a `seen` Set, `stores/channel.ts:306-307`). A test that feeds `LiveFeed` a duplicate msg_id would fail on an input the stores do not produce, so it is no red control; the watch item stays a watch item and the crash's trigger stays unproven. The editor re-read those lines on `origin/master` and they say what the seat cites. Its notes: N1 `origin/master` moved past the plan sha (to `b9b22d2f9`) with the plan file unchanged; N2 a third CI signature (`orc 3/4`, "noon differs from origin/master", on `8de1d37b1` and `bc559b2f6`) appeared after this plan's window, owned (SPL-5874 follow-up, SPL-5897, fixed in `b9b22d2f9`), not a row; N3 the lane map's exit 4 on every checked path is not free, no row proposed; N4 `07102fb7e` is the pre-rewrite sha of p17-01 (now `b97a764ff`), and section 5 cites run 44292290079's head as it ran; N5 source 1's post counts grew after 16:00Z, the new t1 regex hits are process and feature posts; N6 the seat's box cron logs show 0 error lines in 24 h, source 4 reads <box2>'s; N7 the `\|` escapes in table cells, as section 2 says. Seat file: `csi-spl-doc/doc/md/bug-round-18/seat-mistral.md` on `review/c002-bug-round-18-mistral-seat`, `714e1edd1`. v1.0 records the signature.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-871@<box2> | **v1.0** |
| Panel | m-557@sat (mistral) | **PASS** on `bc559b2f6` (msg ca5ae291; seat file `csi-spl-doc/doc/md/bug-round-18/seat-mistral.md` on `review/c002-bug-round-18-mistral-seat`, `714e1edd1`) |
