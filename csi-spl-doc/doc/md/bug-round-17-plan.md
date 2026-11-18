# Bug-fix round 17 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5880 (this plan, the round's discussion issue).  
Discussion: t1 #spool-hub-bugs `4bea7da6-e6ae-4c15-a63f-9e8b2d3e3c1d` ("Bug round 17", opener msg 0b4e4524, opened by c-002@sat 2026-11-18T10:08Z). Requested by c-001 spawn-share: the bug share has been under its band for 24 h (17%). Round 16 ([bug-round-16-plan.md](bug-round-16-plan.md) v1.0, 1 row) is served: b16-01 `b1bf6410d` on `origin/master`, quality gate 44278928457 success, SPL-5869 done.  
Round focus: one defect live on `origin/master` today. The box link watch (`do_spl_box_link_watch`, SPL-4816) counts a command that EXPIRED in the queue before the box took it ("nothing ran; result queued (exit 4)") as a refused command (condition b). A link that is up and returning results, draining requests that expired during an earlier outage, is reported `LINK STUCK` again. The incident cannot clear until some later command exits 0. After 10 min the SPL-5522 restart plans a restart of that link. Seen live on 2026-11-18 (blocker 89af0515, 10:16:28Z). Input from the dispatch holders c-003@sat (msgs 6fd8c278, 2d9a5f7c, forwarding c-001 msg a75b0913) and c-002@sat (msg 3ad3cc22).  
Round size: owner order 2026-11-18 (HUM-10, t1 10f8c08e msg a1474f69; e1139a1e msgs 44445433, 4e1adcfa): bug rounds take the perf cadence, 1 to 3 rows, and the round closes when they are served; bugs are priority 2. This round has 1 row. Every other input was re-measured: each is fixed, not reproduced, not code, or owned (sections 4 to 6).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (round size, push caps, bands, R1-R16), linked here, not copied.  
Model: [bug-round-16-plan.md](bug-round-16-plan.md) (same shape, same 5 sources).

**Status: v0.1** (draft, for the panel).  
Editor: **c-448@sat** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count and every red control below is measured on **`dd983b175`** (`origin/master`, committed 2026-11-18T10:10:38Z), on sat, between 10:16Z and 10:30Z on 2026-11-18. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else. The row has a **red control** that fails on `dd983b175` and passes after the fix (section 3.2).
- **Paths** are repo-relative. Line numbers are as of `dd983b175`.
- **Box:** the preferred box. The placer may move the row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules and R14. The row is Python tooling under csi-spl-orc (`simple_coding`). The lane mix picks claude (10:24:08Z: `pick=claude launcher=/claude-spawn kind=simple_coding reason=kind simple_coding: main claude, backup agy; ...`). The bug rows of rounds 10 to 16 all went to claude, so R14 agrees. Mistral writes no code.
- **Subject** (R6 reads it): `fix(b17-01-<slug>, SPL-<row issue>): ...`.
- **R7 line:** rulebook 2.7.4 (box-free form in the commit body).

---

## 2. Where the rows come from (measured on `dd983b175`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 and csitea since round 16 was planned** | `cd csi-spl-orc && sudo -u <HARNESS_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-18T08:27:09Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (10:1xZ), then the 21 non-probe posts read whole | t1 28 (18 `[spool-probe]`, 4 regex hits), csitea 11 (0 regex hits) | **0 rows of their own.** The t1 posts are poll answers and the round-cadence order (msgs 0306f52d, 71df23ee, a1474f69, 44445433, 4e1adcfa): process, not defects. csitea `40c3f89d`, 10:16:21Z (msg 92f758ae): the owner asks for a check of the link between a remote box and <box2>. 10:18:31Z (msg fc3c25be): "it was stopped, when I wrote the last msg, but now i fixed it". This is the context of row 01 (section 3), not a row of its own: the stop was on the remote box's side and the owner fixed it. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (10:17Z..10:25Z) | 100 runs 2026-11-17T16:59:05Z .. 2026-11-18T10:11:47Z: 68 success, 30 cancelled, 1 failure, 1 running. Every timeout headroom line `ok` (highest p90: 57 %) | 1 failed run: 44144961938 on `68cd3332`, first red `TestDemoPostQuotaPerDay`, the sighting that rounds 14 to 16 already counted; last green of every failed job: 44278928457 on `b1bf6410`. **0 rows** (section 5). |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" dd983b175 -- "$d" \| wc -l; done`; then `git diff 714a4fc82 dd983b175 -G '<the same pattern>' --stat` | api 199, wui 17, orc 10, iac 21, utl 0 (round 16: the same) | The diff names only `perf-round-17-plan.md` and `perf-round-17/editor.md` (they quote the pattern). **0 rows.** |
| **4. Box cron logs and GC notes, last 24 h** | sat: an awk over the 45 `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h, for `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|No such file or directory\|operand expected\|Permission denied\|FATAL\|ERROR\|unknown_discussion`, keyed by the last ISO timestamp above each line (`spool-env` WARN lines skipped), counted per distinct line. The six files with no timestamps (`spawn-fill`, `spawn-place`, `spawn-remote`, `review-go`, `box-stats`, `go-cache-prune`) were read by line number from the end | 49 distinct lines. All but 2 sit at old line numbers: `spawn-place` last error at line 36342 of 125849, `spawn-remote` 38070 of 45387, `box-stats` 11160 of 14338, `go-cache-prune` 1044 of 106228, `review-go` `SPOOL_ROOT: unbound variable` at lines 1-4 of 28920 | **0 rows.** The two live ones: (a) `spawn-fill` `WARN SPL-65: the hub did not link topic abf8b18b-...: unknown_discussion` at lines 46428 and 46491 (of 46541). These are the ticks of 08:40:33Z and 09:30:35Z (the desk's outbox files `20261118T084033Z--c-002--spawn-fill-spl-65-the-discussion-8439e860.json` and `20261118T093035Z--...-e2f7a094.json`), both before b16-01 landed (`b1bf6410d`, 09:43:45Z). The desk-cron checkout holds the fix (`merge-base --is-ancestor` -> yes). No SPL-65 tick has run since: every later tick logs `no box is below its low mark ... nothing to fill`. b16-01's live proof (R5) is still to come; this is not a new defect. (b) `review-go` `REFUSED (rc 2) reviewer c-431 (claude) shares the vendor of author c-422` (and c-434 / c-703): the cron refuses a same-vendor GO by design. Under the claude waiver the holder sends the GO by hand (section 6). |
| **5. Open defect issues, round 16's leftovers, the holder's candidate list, refactor round 35's left-out bug items, the holder's input** | the R7 line in the body of `b1bf6410d`; the panel seat file on `review/c002-bug-round-16-mistral-seat`; `refactor-round-35-plan.md` sections 2 and 6; `/var/spool-hub/dispatch/c002-next-round-candidates.md` (mtime 2026-11-18 01:57Z); `git diff --stat 714a4fc82 dd983b175 -- <their files>`; c-003 msgs 6fd8c278 and 2d9a5f7c, c-002 msg 3ad3cc22 (c-001 msgs a75b0913, 7c5e5b95; c-060 msg 8219ce28; blocker 89af0515) | 1 R7 line; 4 seat notes; 13 candidate notes; 1 holder candidate | **1 row: row 01, the holder's candidate, reproduced** (section 3). The b16-01 R7 line carries no N item, and the seat's N1-N4 confirm its plan. Of the candidate notes' files, only `spl-uplink-probe.func.sh` changed since round 16: r61-01 (`cebfa7004`, `2e55f493d`) fixes the text that SPL-5828 N1 named. The rest are as round 16 section 4 read them. SPL-5874 W1/N1/N2 (a held queue row never ends or alarms) is the holder's planned follow-up row, so it is left out (R3). |

In the commands of this table, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 3. The row

| # | defect | evidence | sites file:line | red control (fails on `dd983b175`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b17-01-orc-box-link-watch-expired-is-no-refusal)` | `refusal_kind` matches every `box: exec:` line with `REFUSED`, `refused` or `timed out` (`box-link-watch.py:208`). For a command that expired in the queue before the box took it, the relay prints `box: exec: REFUSED request <id> (gr-cmd-<id>.zip): expired <n>s ago; nothing ran; result queued (exit 4)`. The link delivered the request and returned its result, so nothing on the link failed. Yet the line becomes condition b, "box command refused or timed out" (`refusals`, `:220-241`), and only a later `exec ... -> exit 0` clears it. While an incident is open, the read reaches back to its start (`conditions`, `:279-283`), so the window never ages the condition out. A condition older than `GW_RESTART_AFTER_S` (600) also plans the SPL-5522 restart of the link (`restart`, `:534-539`): a restart of a link that is draining its queue. | (1) c-001@<box2> blocker 89af0515 (csitea, 2026-11-18T10:16:28Z, to c-002, task c9498337): `LINK STUCK > 7 min on box `box` since 2026-11-18T10:08:52Z`. It lists three `box command refused or timed out` conditions, with evidence `box: exec: REFUSED request 2d33743b4de0 ... expired 14691s ago; nothing ran; result queued (exit 4)` and the same for `643d772590a9` (14741 s) and `b8526cec6988` (399 s), plus `no box log received in the last 6 h`. (2) The outage before it: `LINK CLEARED ... after 712 min (stuck since 2026-11-17T22:09:02Z: the relay link/session is down; ...)` at 10:01:26Z (msg eaf50369). c-927@<box2> (msg 5302ceee, 10:25:18Z): "radiate up since 10:00:59Z (owner restart); 12 expired cmds refused on the box, nothing ran". c-060@<box2> (msg 8219ce28, 10:17:53Z): outbound queue 0 (was 12); 9 results back 10:05Z..10:12Z, about 1/min, all exit 4 "expired, nothing ran". The 12 requests had expired during the 712-min outage, which the watch had already reported and cleared. (3) The owner, csitea `40c3f89d` msg fc3c25be (10:18:31Z): the link "was stopped, when I wrote the last msg [10:16:21Z], but now i fixed it" (c-003 msg 2d9a5f7c; c-002 msg 3ad3cc22 reads the 10:08Z alert as real). The two readings disagree. c-927 says radiate was up from 10:00:59Z, the owner says the link was stopped at 10:16Z, and neither was measured from sat. Either way, the alert's evidence was the expired drain, not a stop. The red control below raises the same alert, and plans the restart, on a link that is up (box log 1 min old, radiate running). The only condition that could show a stop on the remote side is c (box log not advancing), and c had held for over 6 h, outage and recovery alike (msg eaf50369 names it too), so it does not show the stop either. (4) c-001@<box2> msg 7c5e5b95, 10:25:28Z: `LINK CLEARED on box `box` after 16 min (stuck since 2026-11-18T10:08:52Z: box command refused or timed out x3; no box log ...)`. Some later command exited 0 after the owner's fix; which command was not read from sat. (5) Restart: no `LINK RESTARTED` message was on the hub by 10:25:56Z (prd `messages`, body like `%LINK %` since 10:16:29Z -> the clear and three relays, no restart). Whether <box2> sets `BOX_LINK_WATCH_RESTART_ACTION` is box-local (`spl-box-link-watch.func.sh:41`, its env file) and was not read from sat: asked of the holder (section 8). (6) The red control below on `dd983b175`. | `csi-spl-orc/src/bash/scripts/box-link-watch.py:204-217` (`refusal_kind`, the exec match at `:208`) and its docstring `:12-15` (condition b); test `csi-spl-orc/src/bash/tests/box-link-watch.tst.sh` (a new case after case 7, `:133-139`, and its header list `:3-42`); doc `csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md:27` (the condition b row) | The editor's script `rc01.sh <repo root>` (section 3.2). It runs `box-link-watch.py` with `DRY_RUN=1` on a fake hub: a radiating session, a box log received 1 min ago, the radiate process up, and two `box: exec: REFUSED request <id> (gr-cmd-<id>.zip): expired 14691s ago; nothing ran; result queued (exit 4)` lines 11 min old, each with its `results/<id>/result.json`. `GW_RESTART_HOME` and `GW_RESTART_ACTION` are set. On `dd983b175` it prints `INFO box b:exec:3d1970ae84ae: box command refused or timed out, 11 min` (and the same for `c03a833949d6`), `PLAN blocker ... LINK STUCK > 7 min`, `PLAN restart box box: ...` and `RESULT: FAIL`. A prototype fix (on a `git archive dd983b175` copy) returns no kind for a `box: exec:` line that matches `expired .*nothing ran`. With it, rc01 prints `RESULT: PASS`, and the suite `box-link-watch.tst.sh` on that copy prints `ALL PASS` (n=1; on `dd983b175` unchanged it also prints `ALL PASS`, n=1, 64 s). PASS requires no b condition and no restart plan for the expired lines. | An expired request whose result says nothing ran is not a refusal by the link: no condition b, no restart. How to do it is the lane's call, e.g. skip the `expired ... nothing ran` form in `refusal_kind`, or count it as a delivered result. Every other b form stays as it is: a genuine `box: exec: REFUSED` (not expired), `timed out`, `exit 124` and the deploy forms still alert (cases 7 and 22 stay green). The new case also proves that a non-expired `box: exec: REFUSED` line still alerts, so the fix is not a blanket drop. Conditions c and d and the restart logic do not change. The lane says in its commit body whether an expired request should give an INFO line instead. The sender of the command (e.g. c-673's export) learns of the expiry from its own result, not from the watch. Test column: `git grep -lE 'box-link-watch(\.py\|\.tst)?\|do_spl_box_link_watch' -- '*tests/*'` -> `box-link-watch.tst.sh`, `install-box-crons.tst.sh` (orc; `orc-shard-weights.txt` is data). Docs: the condition b row of spec 016 `box-link-7min-watcher.md` names the exception. Live proof after the land (R5): the next drain of expired requests on <box2> raises no `LINK STUCK` (c-001's watch log on <box2>, read there). | sat | claude | a cross-vendor seat if one places (agy or grok); else the claude waiver seat, as for rounds 11 to 16 (waiver 1a7c70da; 10:24Z `BOX_PICK_KIND=grok do_spl_box_pick` -> `pick=hold`, grok weekly 99% on sat and <box2>). The holder decides at placement | simple_coding | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01 alone: `csi-spl-orc/src/bash/scripts/box-link-watch.py`, `csi-spl-orc/src/bash/tests/box-link-watch.tst.sh`, `csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`.
- **Off limits:**
  - every live lane's files;
  - refactor round 35's row files (`refactor-round-35-plan.md` section 3, r61-01..06; the list is in [bug-round-16-plan.md](bug-round-16-plan.md) section 3.1);
  - perf round 17's rows (`perf-round-17-plan.md`; row 02 is queued as `c002-p17-02-orc-lane-mix-cnf-read-once`).
  
  Row 01 edits none of them. It reads `spl-box-link-watch.func.sh` (the action that sets `GW_*`) but does not edit it.
- **Waits (R3):** none known on sat. The last commits on the row's code are SPL-5522's `85f37c63e` and `f81bc4444` (2026-11-14, landed).
- **How the files were checked (2026-11-18, from sat):**
  - 10:22:41Z `lane-map.sh --check csi-spl-orc/src/bash/scripts/box-link-watch.py,csi-spl-orc/src/bash/tests/box-link-watch.tst.sh,csi-spl-doc/doc/md/bug-round-17-plan.md --agent c-448` -> exit 4: no live lane lists these files, but 18 lanes on <box2> record no files: c-054, c-060, c-390, c-468, c-528, c-545, c-570, c-669, c-673, c-700, c-701, c-703, c-705, c-706, c-714, c-924, c-927, c-939 (at 10:22:49Z the two code files gave the same set). **Exit 4 is not free, and this plan did not clear it.** Three of these lanes touch the row's subject: c-060 (the seat of csitea `40c3f89d`, which answered the alert), c-673 (it re-sends the export whose requests expired) and c-927 (it posted the clear line). Their briefs are on <box2>; they are asked of the holder (section 8). The orchestrator re-runs the check before the spawn (R3).
  - R1 against the other rounds: `git grep -c box-link-watch dd983b175 -- perf-round-17-plan.md perf-round-17/editor.md refactor-round-35-plan.md` -> 0 each.
  - 10:22:49Z, every worktree of this checkout (`git worktree list`, 297): `git diff --name-only origin/master...HEAD` plus `git status --porcelain`, matched against `box-link-watch` and `bug-round-17` -> 1 hit, `/tmp/g-015-spl5549-r4`. Its range lists `spl-box-link-watch.func.sh`; its head is `c3d1029d3` (2026-11-15, an iac param-required test), and there is no `/var/spool-hub/g-015` dir. It is not a live lane, and it does not touch the row's files.
  - 10:23:59Z `sudo -u <HARNESS_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 2 queued (the rounds-cadence reviewer `c003-rounds-cadence-claude-waiver-reviewer` and p17-02 `c002-p17-02-orc-lane-mix-cnf-read-once`), 0 placing; neither names the row's files.
  - Briefs under `/var/spool-hub/dispatch/briefs` changed since 2026-11-17T22:00Z that name `box-link-watch` -> 0.
- **Slug b17 is unused as a round id** (10:17Z, sat):
  - `git log origin/master --grep='(b17-'` -> 0;
  - `git log origin/master -E --grep='\bb17-[0-9]{2}-'` -> 0;
  - `git ls-remote origin | grep -cE 'b17-[0-9]{2}|bug-round-17'` -> 0;
  - `grep -rlE '(^|[^0-9a-f])b17-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs` (5937 files), `/var/spool-hub/asks` (8855) and `/var/spool-hub/spawn-remote/briefs` (199) -> 0 files;
  - `bug-round-17` -> 1 file, this planner's own brief.
  
  After this plan's pushes, `--grep='(b17-'` matches the plan's commits (`docs(b17-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b17-[0-9]{2}'` stays 0 until the row lands. The <box2> grep is asked of the holder (section 8).

### 3.2 Red control run on `dd983b175`

| row | command (repo untouched) | output on `dd983b175` | output with a prototype fix (on a `git archive` copy) | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh <repo root>` (a `git archive dd983b175` copy) | `INFO box b:exec:3d1970ae84ae: box command refused or timed out, 11 min` / `INFO box b:exec:c03a833949d6: ...` / `PLAN blocker to c-002 (...) on box-link-watch-abcd1234: LINK STUCK > 7 min on box `box` since ...` / `PLAN restart box box: `run -a kick-now` in the link checkout (stuck since ...: box command refused or timed out; box command refused or timed out)` / `RESULT: FAIL`, rc 1 | `RESULT: PASS`, rc 0; `box-link-watch.tst.sh` `ALL PASS` | editor c-448 |

The script is in `/var/spool-hub/dispatch/b17-red-controls/` on sat and goes to the row lane with its brief; the lane turns it into a suite case. The prototype only shows that PASS is reachable; the lane writes its own fix. The relay's line is copied from the live blocker 89af0515. The relay itself is not in this tree (`box-link-watch.py:4-5`), so the lane does not change what the relay prints.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| b16-01 after the land: `spawn-fill` still logs `unknown_discussion` for SPL-65 | source 4 (a) | The last two such lines are the 08:40:33Z and 09:30:35Z ticks, before `b1bf6410d` (09:43:45Z); no SPL-65 tick since | Not reproduced after the fix; its R5 live proof waits for the next SPL-65 tick. |
| Round 16's seat notes N1-N4 (m-411, `review/c002-bug-round-16-mistral-seat`) and the b16-01 R7 line | read | N1-N4 confirm the plan; the R7 line has no N item | No defect. |
| SPL-5825 W1, W2, N1-N4; SPL-5824 W1, N1, N2; SPL-5828 N2; b12-02 N1-N4; r34 row 01 N1, N2; SPL-5850 N1 | `git diff --stat 714a4fc82 dd983b175 -- <their files>` -> only `spl-uplink-probe.func.sh` (r61-01) | otherwise unchanged | As round 16 section 4 (and round 14 before it). r34 row 01 N1/N2 are test-coverage gaps with no failing behaviour: input for a test round, not a bug row. SPL-5828 N1 is fixed by r61-01 (`cebfa7004`). |
| desk-cron `bin/spool` older than its sources | every orc cron line (`spool-env: WARN ... built ...`) | As in rounds 12 to 16 | As before. |

---

## 5. Not reproduced, or not code

| candidate | command | result |
|---|---|---|
| `TestDemoPostQuotaPerDay` (68cd3332) | `do_report_ci_gate` above | 1 sighting in 100 runs, the one rounds 14 to 16 counted, below the R11 flake bar. Watch. |
| `go-cache-prune` `... is not a Go build cache ...; nothing deleted` (lines 586..1041 of 106228); `box-stats` `bad_frame` / `no private key for sat` (lines 27, 11158 of 14338); `spawn-place` `yq: command not found` / overlay placeholder / `spool build failed` (all before line 36342 of 125849); `spawn-remote` `REFUSED ... not the fleet orch lease holder` (last at line 38070 of 45387); `review-go` `SPOOL_ROOT: unbound variable` (lines 1-4) | source 4 | Old lines: none appears in the last several thousand lines of its file, and the crons have run clean since. |
| The remote box's link stop that the owner fixed (csitea `40c3f89d`, msg fc3c25be) | source 1 | On the remote box's side, not code in this tree; the owner fixed it at 10:18Z. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| SPL-5874 W1/N1/N2: a held queue row never ends or alarms | the dispatch holder's planned follow-up row | Left out (brief, R3). |
| The rounds cadence (owner order a1474f69) in the rulebook | lane c-445, SPL-5879 | In flight; this plan already follows the order. |
| `review-go` refuses a same-vendor GO under the claude waiver (rc 2) | the dispatch holder, by hand (waiver 1a7c70da) | By design: the cron enforces cross-vendor review; the holder sends the GO for a waiver review. |
| The expired export (c-673's requests) and its re-send; the answer to the owner's link posts | c-673, c-060 and c-927, csitea `40c3f89d` (c-060 msg 21d396a6) | In their topic; row 01 changes only how the watch reads the expiry. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 (a defect fix, red control run on `dd983b175`) |
| vendor | claude 1 (the lane mix picks claude; R14) |
| R7 | a cross-vendor seat if one places, else the claude waiver seat |
| box (preferred) | sat 1 |
| batches | 1 (no known wait) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-448@sat (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-bug-r17`, with at least one non-claude seat (rounds 14 to 16 had a mistral doc seat).
- **Asked of the holder with the plan:**
  1. the b17 slug grep on <box2> (briefs, asks, spawn-remote briefs);
  2. whether <box2>'s box link watch sets `BOX_LINK_WATCH_RESTART_ACTION`, and whether its watch log shows a `restarted the link` or `PLAN restart` line for box `box` after 10:18:52Z today;
  3. which command's `-> exit 0` cleared the incident at 10:25Z;
  4. the briefs of c-060, c-673 and c-927 (lane map exit 4): does any of them list `box-link-watch.py` or its test?
- **Review history:**
  - 2026-11-18: the editor pushed v0.1 to `review/c002-bug-round-17-planner` and sent the result to the holder.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-448@sat | **v0.1** |
| Panel | asked of the holder | pending |
