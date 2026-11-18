# Bug-fix round 13 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5844 (this plan).  
Discussion: t1 #spool-hub-bugs `2f60e49b-0275-4e32-98ff-6acaeff0e24e` ("Bug round 13", opener msg 6ff90391, opened by c-002@sat 2026-11-18T00:00:06Z; its discussion issue is SPL-5842). Requested by c-001 spawn-share db4a3267: bug 15% of the live lanes (3 of 20, band 20-30%), no bug row queued; c-001 1030cbc3: plan now so the plan is ready when b12-04 lands.  
Round focus: two defects live on `origin/master` today, one from this box's cron logs and one from round 12's review notes. Row 01: when an agent's pid exits mid-scan, the lane rotation feeds an empty age to bash arithmetic. That prints a `syntax error` and drops the id for the tick (180 times since 2026-10-12, 17 on 2026-11-17). Row 02: when the orchestrator blocker of a final archived-followup refusal fails to send, it is lost for good, while the log says "the next run tries again". That is b12-03 reviewer note N2; the row also fixes the spec 041 sentence that the same review's N1 found stale.  
Round size: at most 10 items (rulebook 1.1); this round has 2.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (round size, push caps, bands, R1-R16), linked here, not copied.  
Model: [bug-round-12-plan.md](bug-round-12-plan.md) (same shape, same 5 sources).

**Status: v0.1** (draft, for the panel).  
Editor: **c-466@<box2>** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count below is measured on **`344be1c04`** (`origin/master`, committed 2026-11-17T23:56:10Z), on <box2>, between 00:07Z and 00:20Z on 2026-11-18. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else. Each row has a **red control** that fails on `344be1c04` and passes after the fix (section 3.2).
- **Paths** are repo-relative. Line numbers are as of `344be1c04`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules and R14. Both rows are bash tooling (`simple_coding`). The lane mix picks agy today (`pick=agy ... agy has 0 of the last 18 simple_coding spawns`). The bug rows of rounds 10 to 12 all went to claude (their section 7), so R14 puts both rows on claude until another vendor has landed a bug row. Mistral writes no code.
- **Subject** (R6 reads it): `fix(b13-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** rulebook 2.7.4 (box-free form in the commit body).

---

## 2. Where the rows come from (measured on `344be1c04`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 and csitea since round 12 was planned** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-17T14:52:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (00:10:59Z), then every human body that is not a probe was read (55) | t1 30 (24 `[spool-probe]`, 0 defect-worded); csitea 42 (3 defect-worded); two other workspaces 7 | The defect-worded csitea posts (3384fb4c "which failed with ...", 8d4d5941 "... is not found") are the billing invoice fetch in csitea topic f655b326, held by its live lane c-390@<box2> (the GCP costs fetch). The rest are poll answers, orders and questions. **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (00:07:41Z) | 100 runs 2026-11-17T05:02:33Z .. 2026-11-18T00:03:10Z: 63 success, 30 cancelled, 6 failure, 1 running. Every timeout headroom line `ok` (highest p90: 57 %) | 6 failed runs, 7 first-red sightings over 5 jobs. Round 12 already had `TestAgentRunPresenceFrames` (41d35321), `hygiene-box-users-allow.tst.sh` (01de192f; SPL-5827, its fix is 344be1c04, this sha) and wui e2e 2/8 "no Email row" x2 (fd9e5a27, 013cb71b; SPL-5706, fixed by e9748a03d). New, each seen once: `TestDemoPostQuotaPerDay` (68cd3332, run 44144961938; the holder read it as a ws ack deadline, not the b12-03 diff, msg ecb1710b) and wui e2e 2/8 `4j Shift+O opens the issue` (013cb71b, run 44106557444). Every failed job is green again on 1961ca57 (run 44202112356). **0 rows** (section 5: below the R11 3rd-sighting bar). |
| **3. Skipped or disabled tests** | `for s in e9748a03d 344be1c04; do for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$s $d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" $s -- "$d" \| wc -l; done; done` | api 197, wui 17, orc 10, iac 21, utl 0 on both shas (round 12's sha and this one); `csi-spl-wui/tests/e2e/ci-skip.txt` 4 entries | No new skip since round 12. **0 rows.** |
| **4. Box cron logs and GC notes, last 24 h** | <box2>: the editor's scan of `/var/csi/csi-spl/*/cron.{out,log}` for `unbound variable\|command not found\|syntax error\|Traceback\|FATAL\|panic:\|status 141\|rc=[1-9]` after 2026-11-17T00:10Z. Each line is keyed by the last timestamp above it and counted per distinct line. Then the `STOP <name> rc=` lines per day, and `spool tail --task gc-<box2>` | 30 crons with a hit; the distinct lines of each read one by one | **1 row (01):** `lane-rotate` prints `spl-lane-rotate.func.sh: line 174: ((: -: syntax error: operand expected (error token is "-")` 17 times on 2026-11-17, 180 since 2026-10-12, on 32 of those 37 days. The rest: section 5 (disk full 21:13-21:44Z; network and GitHub answers; transient gcloud and psql reads) and section 6 (b12-04's steps-log FATAL; the box-update pool rows). `issue-close-landed`'s `spl_private_has_tokens: command not found` is still at 180, none since 2026-11-15 (round 12 section 5). gc-<box2> has no note since 2026-11-14 (the GC runs on sat): the holder reads `gc-sat` (section 8). |
| **5. Open defect issues, round 12's leftovers, its review follow-ups** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select number, status, assignee, labels, title from issues where tenant_id='t1' and deleted_at is null and archived_at is null and status in ('eval','todo','wip','blocked','onhold','qas') and kind='issue' and ('bug' = any(labels) or title ~* '(bug:\|broken\|does not\|not work\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|flake)')" ./run -a do_spl_db_query`; round 12 sections 4 to 6; the R7 notes of b12-01 (c-320, in 2288ecf04's body), b12-02 (c-126, in ed8bf9221's body) and b12-03 (c-283: FAIL msg feb41215, PASS msg ca7939d6), each re-checked on `344be1c04` | 30 issues matched | Open defect issues are owned by lanes, programs or the desk (section 6). b12-03's N2 **reproduces (row 02)**. Its N1 (spec 041 still says every later run tries a copy "until it takes") holds on `344be1c04`, so row 02 fixes that sentence too. b12-01's edge note (`plan/apply/e.g.` GOes) is the rule as worded (section 4). **1 row.** |

In the commands of this table, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 3. The 2 rows

| # | defect | evidence | sites file:line | red control (fails on `344be1c04`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b13-01-orc-lane-rotate-age-of-a-gone-pid)` | `spl_lane_rotate_scan` prints one row per agent process: `<id> <kind> <pid> <age> <pane>`. `spl_rotate_age` prints nothing when `<proc>/<pid>/stat` has no start time, which happens when the pid exits between the `/proc` walk and the age read. The row then reads `<id> <kind> <pid>  -`, and `read` shifts every later field: age takes the pane (`-`), pane takes the process count, n is empty. `spl_lane_rotate_consider` runs `(( age >= ROTATE_LANE_WARN_AGE ))` on `-`, and bash prints a `syntax error` to the cron log. The `\|\| return 0` hides it, so that id is skipped for the tick. If the id also has a live process, the awk at `:149` may keep the gone pid's row as the id's one row, and then the live session is not judged that tick. | (1) `<box2>` `/var/csi/csi-spl/lane-rotate/cron.log` has 180 lines `spl-lane-rotate.func.sh: line 174: ((: -: syntax error: operand expected (error token is "-")`. All 180 have the token `-`: the no-pane form a gone pid takes. By day: 17 on 11-17 (1398 ticks that day), 4 on 11-16, 7 on 11-15, 8 on 11-14; 32 of the 37 days since 2026-10-12. In the 14 samples read, the line before is a rotation START or DEFER. (2) `spl-rotate-lib.func.sh:868-869`: with no numeric start time it does `return 0` and prints nothing. (3) The red control below on `344be1c04`: 1 `operand expected` line per tick. | `csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh:333-336` (`spl_lane_rotate_scan`, the row it prints), `:149-153` (the one-row-per-id awk and the `read`), `:174` (the arithmetic); test `csi-spl-orc/src/bash/tests/lane-rotate.tst.sh` (a new case after 32) | Take the `lane-rotate.tst.sh` sandbox up to its case 1 (the `reset`, `lane` and `tick` helpers), then run `reset; lane c-911 10; lane c-913 70; rm -f "$T/proc/2913/stat"; DRY=1 tick` and count `operand expected` in `$T/tick.out`. On `344be1c04` that is 1 line (`line 174: ((: %913: syntax error ...`; the live token is `-` because a gone pid has no pane). PASS requires 0 such lines and no ERRTRAP line. The gone pid has no scan row, c-911 is judged as before, and with a second, live process of c-913 that pid's row is the one judged. The whole suite stays green. | In `spl_lane_rotate_scan`, read the age once per pid and print no row when it is empty: the pid is gone, so there is nothing to rotate. Keep `spl_rotate_age` in `spl-rotate-lib.func.sh` as it is: other rotations read it, and changing it is not this row. Optional, in the same file: `spl_lane_rotate_consider` meets a non-numeric age with one `DEFER` line, not the arithmetic. Docs: `Docs: none (a scan row of a gone pid is dropped, no rule changes)`. | sat | claude | an agy seat (agy reviews claude, cross-vendor); else the claude waiver seat as in rounds 11 and 12 (c-001 ruling 5fb1bdab), GO by hand. The holder decides at placement | simple_coding | 1 |
| 02 `fix(b13-02-orc-archived-followup-blocker-send-lost)` | When `do_spl_archived_followup` reaches a FINAL refusal of a priority copy, the copy leaves `inherit.pending`, and ONE blocker to the orchestrator is the only record left. This happens on a not_found past `ARCHIVED_FOLLOWUP_PRIORITY_RUNS` (`spl_afu_pending_final`, SPL-5818) and on a first-run final answer (`spl_afu_inherit_failed`, "nothing tries again"). If that blocker's `spool-send.sh` fails, `spl_afu_blocker` logs `the blocker to the orchestrator was not sent; the next run tries again`. Nothing tries again: the copy is gone from the file, its key never reaches `failed.keys`, and no later run reaches the send. A refused move (`spl_afu_move_final`) goes through the same send. Spec 041 is also stale since SPL-5818: it says every later run tries a copy again "until it takes", but a not_found copy now ends after 12 runs. | (1) The b12-03 reviewer c-283@<box2>, FAIL msg feb41215 N2: "If the final blocker's send fails, `spl_afu_blocker` logs 'the next run tries again'. That is false: the copy has already left `inherit.pending` ... `spl_afu_inherit_failed`'s final path has the same weakness on master". The PASS (msg ca7939d6) left it: "N2 is unchanged". (2) The red control below on `344be1c04`: 1 send try, 0 `failed.keys`, 1 `next run tries again` line, the copy gone after run 12, and run 13 sends nothing. (3) N1 of the same review: `csi-spl-doc/specs/041-spool-topic-archive-delete/archive-releases-work.md:156` reads "every later run tries it again until it takes" on `344be1c04` (`git log 68cd33322..344be1c04 -- <that dir>` -> empty). | `csi-spl-orc/src/bash/run/spl-archived-followup.func.sh:476-489` (`spl_afu_blocker`, the false WARN at `:487`), `:248-256` (`spl_afu_inherit_failed`, its final branch), `:261-286` (`spl_afu_pending`, the `continue` at `:279`), `:291-296` (`spl_afu_pending_final`), `:455-460` (`spl_afu_move_final`); test `csi-spl-orc/src/bash/tests/spl-archived-followup.tst.sh` (beside cases 14j to 14o, `:405-472`); doc `csi-spl-doc/specs/041-spool-topic-archive-delete/archive-releases-work.md:156` | `bash -c 'do_log(){ echo "$*" >>D/log; }; source csi-spl-orc/src/bash/run/spl-archived-followup.func.sh; spl_afu_desk_seated(){ return 0; }; spl_role_seat(){ echo c-001; }; AFU_AGENT=c-002 AFU_BOX=boxa ARCHIVED_FOLLOWUP_PRIORITY_CMD=<stub: prints the not_found FATAL, exits 1> ARCHIVED_FOLLOWUP_PRIORITY_WAIT=0 ARCHIVED_FOLLOWUP_SEND=<stub: appends its args to send.tries, exits 1>; for run in $(seq 1 13); do spl_afu_pending D 0; echo "run $run rc=$? pending=..."; done'`, with one 3-column copy in `D/inherit.pending`. On `344be1c04`: runs 1..11 `rc=1 pending=1`, run 12 `rc=0 pending=0`, run 13 `rc=0 pending=0`; `send tries: 1  failed.keys: 0  'next run tries again' lines: 1  refused-for-good: 1`. PASS requires: while the send fails, the final record is kept and a later run tries the send again (send tries > 1 by run 13), with no new priority try for that copy. Once a send succeeds there is exactly ONE blocker, its key is in `failed.keys` and nothing is left behind. No log line promises a retry that never comes. The same holds for `spl_afu_inherit_failed`'s first-run final path (a stub that answers `target_not_live`) and for `spl_afu_move_final` if the fix touches it. Cases 14j to 14o stay green, and so does the whole suite. | Keep a final record until its blocker is sent. One way: `spl_afu_blocker` returns non-zero when the send fails, and the final paths journal the record (tenant, topic, key, body) in a small `blocker.pending` that each run's pending pass sends first. Another: the copy stays in `inherit.pending`, marked final, until the send goes. Never a second priority try for a final copy. Either way, the WARN at `:487` says what really happens next. Name any new file in the `@param ARCHIVED_FOLLOWUP_STATE_DIR` line. Do not edit the live state dir on any box by hand. Docs: spec 041 `archive-releases-work.md:156` in the same commit: a not_found copy is tried for `ARCHIVED_FOLLOWUP_PRIORITY_RUNS` later runs (default 12), and a final refusal's blocker is sent again until it goes. | sat | claude | as row 01 | simple_coding | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02. Their file sets are disjoint:
  - row 01: `csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh`, `csi-spl-orc/src/bash/tests/lane-rotate.tst.sh`;
  - row 02: `csi-spl-orc/src/bash/run/spl-archived-followup.func.sh`, `csi-spl-orc/src/bash/tests/spl-archived-followup.tst.sh`, `csi-spl-doc/specs/041-spool-topic-archive-delete/archive-releases-work.md`.
- **Off limits:** b12-04 (c-464@<box2>, SPL-5843, live) owns `spl-agent-steps-log.func.sh`, `agent-steps-log-cron.sh` and `spl-agent-steps-log.tst.sh`; neither row touches them. Row 01 reads `spl-rotate-lib.func.sh` and does not edit it.
- **Waits (R3):** none. The last lanes on these files have landed: 3a11e8c03 (SPL-5728) last changed `spl-lane-rotate.func.sh`, and 68cd33322 (b12-03, lane c-271, ACCEPTED msg ecb1710b) last changed row 02's code. `git diff --stat 344be1c04 origin/master` over the row files was empty at 00:1xZ.
- **How the files were checked (2026-11-18, from <box2>):**
  - 00:13:13Z `lane-map.sh --check csi-spl-doc/doc/md/bug-round-13-plan.md,<the 5 row files above> --agent c-466` -> exit 4. No live lane lists these files. 6 lanes on sat record no files: c-044 (spec 143 B-6, api/orc sync per repo), c-137 (nuxt 4 migration), c-176 (t1 invitee label), c-194 (kind picker letter keys), c-197 and c-762 (topic seats). By their brief titles, none works on the lane rotation or on archived-followup. The orchestrator re-runs the check before each spawn (R3) and asks an exit-4 lane first.
  - 00:1xZ `lane-map.sh` (all boxes): no live lane's brief names lane-rotate, archived-followup or spec 041. The one live bug lane is c-464 (b12-04, above).
  - 00:13:23Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 1 row (ask da2e16d2, spec 169 T15 hub confirm), which does not touch these files.
  - Origin review branches, the newest 60 of 241: `git diff --name-only origin/master...<branch>` over each. Two touch row 02's files: `review/c-541-archived-followup-settle` (e08e62eae, SPL-5259, landed as ee15e494a) and `review/c002-b12-03-orc-archived-followup-dead-copy` (ee5f45afe, b12-03, landed as 68cd33322). Both are landed history, not live work.
- **Slug b13 is unused as a round id** (00:07:43Z, <box2>): `git log origin/master -E --grep='\bb13-[0-9]{2}-'` -> empty; `git log origin/master --grep='(b13-'` -> empty; `git ls-remote origin | grep -E 'b13-[0-9]{2}|bug-round-13'` -> empty (`review/c003-feat-s154-b13-contacts-import-data` is spec 154 row `s154-b13`, another id); `grep -rlE '(^|[^0-9a-f])b13-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> empty. sat's briefs and asks: asked of the holder (section 8).

### 3.2 Red controls run on `344be1c04`

| row | command (repo untouched) | output on `344be1c04` | output with the fix | who |
|---|---|---|---|---|
| 01 | the head of `lane-rotate.tst.sh` (up to its `# --- 1. two healthy ticks` line), then `reset; lane c-911 10; lane c-913 70; rm -f "$T/proc/2913/stat"; DRY=1 tick; grep -c 'operand expected' "$T/tick.out"` | `.../spl-lane-rotate.func.sh: line 174: ((: %913: syntax error: operand expected (error token is "%913")`, `lane-rotate@box-desk: agents=2 in-flight=0 started=0 deferred=0 (DRY_RUN)`, `operand-expected=1` | `operand-expected=0`, no ERRTRAP line, `agents=1` (the gone pid has no row) | editor c-466 |
| 02 | the script of row 02 above (two stubs, one 3-column copy in `inherit.pending`, 13 calls of `spl_afu_pending D 0`) | `run 1 rc=1 pending=1` ... `run 11 rc=1 pending=1`, `run 12 rc=0 pending=0`, `run 13 rc=0 pending=0`; `send tries: 1  failed.keys: 0  'next run tries again' lines: 1  refused-for-good: 1` | send tries > 1 while the send fails; once a send stub succeeds, `failed.keys: 1` and no second blocker; no false WARN | editor c-466 |

Both scripts are in the editor's scratch dir on <box2> and go to each row lane with its brief; the row lane turns them into suite cases.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| b12-01 edge N1 (c-320's review): `plan/apply/e.g.`, `plan/apply/i.e.`, `apply/v2.0` still GO | the R7 line in 2288ecf04's body (its probe of 9 edge phrases) | A `.` in the last segment makes the token a path, as b12-01's fix scope words the rule. | The rule as agreed. Changing it is a rule decision, not a defect. |
| SPL-5827 W1 review notes N1..N3 (the brief names c-452@<box2>) | 344be1c04's subject: `... (R7 c-175 W1, N1, N2)` | The brief calls them notes on a test helper, not defects. The editor did not re-read c-452's message and reproduced no failure on `344be1c04`. | No failure reproduced. |
| `ci-overflow` `FATAL SPOOL_CI_RUNNER does not read: nothing changed`, 4 in 24 h (968 in the whole log) | `grep -c` over `/var/csi/csi-spl/ci-overflow/cron.out`; `route-ci-overflow.func.sh:82` | A failed read of the repo variable fails the tick closed, by design (`route-ci-overflow.tst.sh:93` asserts it). The next tick is green. | Not a defect. |
| desk-cron `bin/spool` older than its sources | every orc cron line | As in round 12 section 4. | As in round 12. |

---

## 5. Not reproduced, or not code

| candidate | command | result |
|---|---|---|
| Disk full on <box2>, 2026-11-17T21:13Z..21:44Z: `No space left on device` (542 lines), then `FATAL Command 'tee >(do_mask_private_keys > "$1")' failed ... status 141` in 17 crons | the cron scan of section 2, source 4; `df -h /` now 56 % | One event. Its fix is landed: b63a9932b (SPL-5837, "the box disk sweep escalates on a fast fall of free space"). No row. |
| `TestDemoPostQuotaPerDay` (68cd3332), wui e2e 2/8 `4j Shift+O opens the issue` (013cb71b) | `do_report_ci_gate` above | 1 sighting each in 100 runs, below the R11 flake bar (a lane on the 3rd). Watch. |
| Network, GitHub and hub answers in the <box2> crons: `hub unreachable: failed to WebSocket dial`, `gh run list failed: error connecting`, `HTTP 403: API rate limit`, `git fetch origin failed`, `psql ... timeout expired`, and `gcloud could not activate the SA key` (4 of 454 desk-reconcile runs on 11-17) | the cron scan of section 2, source 4 | Each a few times in 24 h, each followed by a green run. |
| `issue-close-landed` `spl_private_has_tokens: command not found` (round 12 section 5) | `grep -c spl_private_has_tokens /var/csi/csi-spl/issue-close-landed/cron.log` -> 180 | No new line since 2026-11-15. Still on watch. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| `agent-steps-log` FATAL for c-141 (1406 in 24 h) | b12-04, c-464@<box2>, SPL-5843 | Live lane. |
| `box-update` fails on every run (twice a day; 67 `FAIL step deploy` in its log): `FAIL pool status: not running after start: desk:<tenant>/<box2 alias> ...`. A read-only `do_spl_pool_ctl` status on <box2> (`POOL_CMD=status DRY_RUN=1`) shows 14 desk rows `stopped no live hub-run`; only the `*-desk` rows are marked retired (`rebox-seated.txt` / `rebox-retired`) | Box state, not code: the desks run elsewhere, and the rows under the other aliases were never marked retired. Goes to c-001 (desk placement) with this plan: retire the stale rows with `do_spl_desk_rebox`, or say they should run | Not a code row. If c-001 rules that `box_deploy_drop_retired` (`spl-box-deploy.func.sh:356-366`) should also drop a desk whose tenant is seated on another box, that is a row for round 14. |
| csitea billing invoice fetch (f655b326: 3384fb4c, 8d4d5941) | c-390@<box2> (GCP costs fetch) | Live lane. |
| Event type SPL-5751 (`vue: insertBefore`, n=6) | owner's event-log order, t1 955ab0bd (F9) | As in round 12. |
| SPL-5772 B-5 reviewer notes N1..N5 | spec 143 program, row B-6 (c-044@sat) | As in round 12. |
| SPL-5609, 5411, 5396, 5368, 5254, 5232, 5104, 4994, 4934, 5841 | dispatch desk (c-002), `wip` / `onhold` | Placed by the holder. |
| SPL-4120 | the release transfer tool, another repository | As in round 12. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gates | Labelled `bug`, not defects. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (defect fixes, red controls run on `344be1c04`) |
| vendor | claude 2 (lane mix picks agy; R14) |
| R7 | agy seat (cross-vendor), else the claude waiver seat; both rows |
| box (preferred) | sat 2 |
| batches | 1 (disjoint, no wait) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-466@<box2> (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-2f60e49b`, with at least one non-claude seat. At 00:1xZ, `do_spl_box_pick` gives grok `pick=hold` (weekly 99 % on both boxes), while agy and mistral place on <box2> (their weekly usage is unread). So the available seat is an agy doc seat (the `specs_and_docs` main) or a mistral doc seat.
- **Asked of the holder with the plan:** read `gc-sat` for the last 24 h (source 4 on sat); run the slug check on sat's briefs and asks; take the box-update pool rows (section 6) to c-001.
- **Review history:**
  - 2026-11-18 00:2xZ: the editor pushed v0.1 to `review/c002-bug-round-13-planner` and sent the result to the holder.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-466@<box2> | **v0.1** |
| Panel | asked of the holder | pending |
