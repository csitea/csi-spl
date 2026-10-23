# Bug-fix round 5 - plan (2 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 5 focus: **the R7 review-line check, the round's own acceptance gate: it cannot read a vibe journal when run as the dispatcher's user, and on the reviewer's box it accepts a `log:` that is the whole session store and a reviewer that is not the `log:` owner**.  
Concurrency: rulebook §1.1 asks for 2 row lanes in parallel. Both rows touch the same two files, so they run **one after the other in one lane** (section 3.1); there is no other reproduced defect to fill a second lane.  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), by pointer, not copied. Issue: SPL-2987.  
Model: [bug-round-4-plan.md](bug-round-4-plan.md) (same shape, same 5 sources).

**Status: v1.0, NOT signed: waits for a valid cross-vendor verdict.** The first reviewer's verdict ([seat-mistral.md](bug-round-5/seat-mistral.md), `80ed8199b`) and its signature (`f1eb5b05b`) are **void**: the dispatcher had c-001 read m-110's journal (c-001 msg 237341ec, c-002 msg a90069ab), and no run there produced the red-control outputs the verdict cites. The second reviewer, m-845@sat (ask 32415043, [seat-mistral2.md](bug-round-5/seat-mistral2.md), `63955c7da`), is **void** too (c-002 msgs fa8849f4, ba1f8735): its row 02 reports rc 3 where the red control gives rc 0 on `63955c7da` (3 failure(s), control PASS, n=1), and its sections (c) and (d) answer claims the plan does not make. A third mistral reviewer is queued (ask d6af4567) and writes `bug-round-5/seat-mistral3.md`. The rows do not spawn until its verdict is folded and it signs.

Editor: **c-081@<box2>** (claude, the backup vendor for `specs_and_docs`: `LANE_MIX_KIND=specs_and_docs ./run -a do_spl_lane_mix` -> `pick=agy`; agy and grok have no quota, per the brief).  
Reviewer: **m-110@<box2>** (mistral, cross-vendor per rounds-rulebook 2.7.2: agy and grok had no quota; dispatcher ask fb100853); verdict `80ed8199b` **void** (see Status). Second reviewer m-845@sat (ask 32415043): verdict `63955c7da` **void** (see Status). Third: a mistral seat from ask d6af4567; it signs v1.0 in its own commit.

**One sha:** every count is measured on **`35a8a111d`** (`origin/master` at the start, 2026-10-23T03:27Z), n=1 per command unless stated.  
Re-checked on `80ed8199b` (origin/master at the v1.0 fold): `git diff --stat 35a8a111d 80ed8199b -- <every row file> csi-spl-doc/doc/md/rounds-rulebook.md` -> empty.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else, with a **red control**: a test that fails on `35a8a111d` and passes after the fix. Each red control below was run on `35a8a111d` (section 3.2).
- **Paths:** repo-relative. Lines as of `35a8a111d`.
- **Box:** the preferred box; the placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules: Mistral writes no code; grok is at its weekly limit (gc.log `FALLBACK … grok weekly limit` at 03:30Z on both boxes), so the coding vendor is claude.
- **Subject** (R6 reads it): `fix(b05-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).

---

## 2. Where the rows come from (measured on `35a8a111d`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-22** | `cd csi-spl-orc && ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-22' and from_id like 'HUM%'" ./run -a do_spl_db_query`, then the 32 non-probe bodies read (`left(body,240)`, by ts) | 264 human posts, 1 defect-worded, 232 `[spool-probe]` lines; 32 owner posts read by hand, the newest at 2026-10-22T20:34Z | The same 264 as round 4: no human post since its measurement. The 2 defect reports (t1 d8ede89a omnibox, t1 deb3a5ed rotation failures) are fixed (round 4 section 4). **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (with `GH_TOKEN` set; without it: `FATAL gh run list failed`) | 200 runs 2026-10-21T20:03Z..2026-10-23T03:02Z: 121 success, 61 cancelled, 18 failure | Every failed job's last green is run `39892832690` on `35a8a111d` (03:02:21Z). The newest red is 2026-10-22T23:45Z; 0 reds after round 4's sha. Active trunk defects: **0**. Every timeout headroom line is `ok` (worst: orc hermetic 3/3, p90 828 s of 1800 s, 46 %). The 18 are round 4's signatures (its section 4), all fixed. |
| **3. Skipped or disabled tests, local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 35a8a111d -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl \| wc -l`, per tree; diff of the sorted grep (line numbers stripped) against `3f48f3afe` | 186 lines (api 139, wui 17, orc 9, iac 21, utl 0): 3 more than round 4's 183; 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. The 3 new lines are Go skips gated on Postgres: `internal/hub/box_lock_test.go` (1, "Postgres only: SPOOL_TEST_PG_DSN") and `internal/hub/wsdoc_assets_orphan_sweep_test.go` (2, "need Postgres (SPOOL_TEST_PG_DSN)"). No local flake run this round: 0 CI reds since round 4 gave no candidate. |
| **4. GC notes and box alarms, last 24 h** | `awk '$1 >= "<now-24h>"'` over `gc.log` on <box2> and on sat (sat's read over ssh with `sudo -n`; `spool tail --task gc-sat` from <box2> -> "no messages visible to this box"); `rotate.log`, `lease.log` on <box2> | gc.log <box2>: 46 START, 24 DONE, 22 END-STALE, 1 FALLBACK, 10 POKE, 2 REFUSED, 1 CLOSE-ASK, 1 NONE. sat: 48 START, 24 DONE, 25 END-STALE, 1 FALLBACK, 10 POKE, 3 CLOSE-ASK, 2 NONE. rotate.log <box2> (24 h, failure words, grouped): 29 `SWITCH SKIP agy … 'no pick'`, 28 `SWITCH SKIP grok … grok limit`, 10 `IDLOCK REFUSED` (2026-10-22T13:50Z, one burst), 4 `FAIL SPAWN` c-179 | **0 new defects.** Round 4 rows 02 and 03 hold (section 4). The SKIPs are the rotation refusing vendors with no quota, as designed. |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3 -I` | 317 issues (total 317), 4 labelled `bug`; 28 more with a defect word in the title, 9 of them created since 2026-10-22 | SPL-1945 (blocked, needs owner); SPL-455 / SPL-450 / SPL-435 out of scope by the brief. The 9 new ones are lane briefs (`Lane brief: …`), not defect reports. **0 rows from issues.** The dispatcher's candidates (a) and (b) (brief: c-001 msgs ee130122 and 6570df5d, m-841's review; not read here, the messages are not in this box's spool) **reproduce**: Rows 01 and 02. Candidate (c): not reproduced (section 5). |

---

## 3. The 2 rows

| # | defect | evidence | sites file:line | red control (fails on `35a8a111d`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b05-01-orc-review-check-reads-as-log-owner)` | `do_spl_review_line_check`, run as the fleet's shell user (`sudo -u <DEV_USER>`, the global rule for every command), cannot read any mistral reviewer's journal: vibe keeps it under `~<HARNESS_USER>/.vibe/logs/session/unified/<session>`, and every level from `.vibe` down is mode 0700, owner `<HARNESS_USER>`. The check stops at `[[ -r "$path" ]]` with rc 1 and names neither the owner nor a way through, so the dispatcher cannot check a mistral R7 line (rulebook 2.7.4) on the reviewer's own box. `sudo -n -u <HARNESS_USER> true` -> rc 0 for `<DEV_USER>` on <box2> and on sat, so the read is possible; the action never tries it. | `REVIEW_LINE='review: m-999@<box2> mistral PASS 35a8a111dec3beec665691ffb89ac6af1c9fa370 ran: bash gc-agent.tst.sh \| read: ok \| log: m-999@<box2>:~<HARNESS_USER>/.vibe/logs/session/unified/<newest session>' REVIEW_LINE_BOX=<box2>`, the func file sourced, as `<DEV_USER>` -> `FATAL log … is not readable on <box2> as <DEV_USER>`, rc 1 (n=1). `ls -ld` of `.vibe`, `.vibe/logs`, `.vibe/logs/session`, `…/unified` -> `drwx------ <HARNESS_USER>` each; 284 session dirs. On sat that home is not under `/home` (`getent passwd <HARNESS_USER>` -> a `/mnt/…` home), so the owner must come from the passwd home, never from a `/home/<user>/` prefix. | `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:50-52` (the readable test :51, the read :52), `_spl_review_line_match` :122-124; header doc :20-21, :29; test `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` (a new case after case 6, :91-100) | Scratch `zz-b05.tst.sh` case "01" (section 3.2): a session dir under a `chmod 000` parent -> today rc 1 `not readable`, no other read tried. Adopted as a case with two seams the lane adds: the owner lookup (a helper, e.g. `_spl_review_line_owner <path>`, stubbed to print `other-user`) and `sudo` on `PATH` (a stub that records its argv, then reads a readable twin): after the fix the check exits 0 `OK 1 of 1` and the stub log shows `-n -u other-user`. Controls: a readable log never calls `sudo` (stub log empty); a `sudo -n` that fails (stub exits 1) keeps rc 1, and the FATAL now names the owner and the command to run as that user. | When the log is not readable as the current user: find the owner of the nearest existing ancestor by matching `getent passwd` home dirs (works for a `/mnt/…` home), then run only the read (`python3 -I -c "$_SPL_REVIEW_LINE_PY" <path>`, the names on stdin) through `sudo -n -u <owner>`; print one `NOTE read as <owner> (sudo -n)` line. No `sudo` when readable. If `sudo -n` fails: rc 1 as today, and the FATAL adds `run it as <owner>: sudo -u <owner> env REVIEW_LINE=… ./run -a do_spl_review_line_check`. Never a literal user name in the code (hygiene §4). Docs: the header (:20-21) and rulebook 2.7.4's "on the reviewer's box" sentence get "as any user that may `sudo -n -u` the log's owner". | <box2> | claude | mistral (cross-vendor, rulebook 2.7.2; grok and agy have no quota) | simple_coding | 1 (lane A) |
| 02 `fix(b05-02-orc-review-check-one-session-and-owner)` | On the reviewer's box the check proves nothing in two ways. (a) `log:` may name a directory, and a directory is read whole (`os.walk`, every `*.json` / `*.jsonl`, :158). That is meant for ONE vibe session dir (:14-18, case 6), but the store root `…/unified` (284 sessions, every mistral seat that ran as that user) is accepted too, and then any command any agent ran counts as the reviewer's run. (b) The header reviewer is never checked there: `log: ([^[:space:]@]+)@…` (:40) takes any id, and `_spl_review_line_syntax` (reviewer = `log:` owner, `[acgmq]-NNN` id, the id's vendor) runs only for a log on another box (:66). So `review: mistral@<box2> …` and a reviewer that differs from the `log:` owner both pass, though the same line on another box is a `SYNTAX FAIL`. | Real store, run as `<HARNESS_USER>`: `REVIEW_LINE='review: mistral@<box2> mistral PASS 35a8a111d… ran: bash gc-agent.tst.sh \| read: ok \| log: mistral@<box2>:~<HARNESS_USER>/.vibe/logs/session/unified' REVIEW_LINE_BOX=<box2>` -> `OK 1 of 1 named in ran: are commands in …/unified (224522 commands read)`, rc 0 (n=1; m-841's reported run read 211316). Each of the 284 session dirs holds `CURRENT`, `chunks/` and `journal/` (`find … -maxdepth 2 -name CURRENT \| wc -l` -> 284). Scratch cases "02a" and "02b" (section 3.2) give rc 0 where rc 1 is wanted: 3 failures. | `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:40-44` (the `log:` match and the local branch), :50-52, :73-88 (`_spl_review_line_syntax`, to reuse), the Python walk :157-158; header :14-18; test `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` (next to case 6, :91-100, and case 8) | Scratch `zz-b05.tst.sh` cases 02a and 02b, adopted: (02a) `log:` = a dir holding two session dirs (`s1/`, `s2/`, each `CURRENT` + `chunks/c1.json`, the test command only in `s2`) -> rc 1, the message says the dir holds 2 sessions and asks for one; (02b) header `mistral@box-a` -> rc 1; header `m-902@box-a` with `log: m-901@box-a:…` -> rc 1. Controls: `log:` = `s2` alone -> `OK 1 of 1`, rc 0; the existing cases 1-8 stay green (case 3's plain `vibe/journal` dir and case 6's session dir are still accepted). | (a) Before the read: a directory `log:` that has 2 or more child dirs holding `CURRENT` or `journal/` is the session store, not a session: refuse it, rc 1, `FATAL log <path> holds <n> sessions: name the reviewer's own session dir`. A session dir and a plain journal dir read as today. (b) On the local branch, run the header part of `_spl_review_line_syntax` (the `[acgmq]-NNN@<box>` reviewer, reviewer = `log:` owner, the vendor of the id and of its registry row) before the read, as the remote branch does; a failure is rc 1 with its `SYNTAX FAIL` text. Docs: header :14-18 and :26-29 updated (one session dir only; the reviewer is checked on both branches); rulebook 2.7.4 says the same in one clause. | <box2> | claude | mistral (cross-vendor, rulebook 2.7.2) | simple_coding | 2 (lane A, after Row 01) |

### 3.1 Files (R1) and lanes

- **Lane A:** Row 01 -> Row 02, one after the other: both change `spl-review-line-check.func.sh` and its `.tst.sh` (and one sentence of `rounds-rulebook.md` 2.7.4). They cannot run in parallel without sharing a file, so batch 1 = Row 01, batch 2 = Row 02. One claude lane may carry both, landing Row 01 first.
- No second lane this round: no other reproduced defect (section 2). The plan does not pad to fill one (brief, Do 6).
- `lane-map.sh --check <path> --agent c-081` for `spl-review-line-check.func.sh`, its `.tst.sh` and this plan -> exit 4 each: no live lane lists them. The 16 live lanes with no files recorded are the same as in round 4: the r18 WUI decompose rows (c-784, c-785, c-786, c-791, c-795, c-799, c-800 @sat), rotate and role seats (c-189@<box2>; c-613, c-763, c-794, c-813, c-816 @sat) and standing seats (c-175@<box2>, c-423@<box2>, c-499@sat); none of their branch names names the check. On <box2>, no worktree has its own change to the check (`git diff --name-only origin/master...HEAD` plus `git status --porcelain` per worktree, grep `spl-review-line-check` -> 0). Re-check at spawn.
- `do_spl_spawn_queue`: `0 queued, 0 placing`.

### 3.2 Red controls run on `35a8a111d`

Inputs: the scratch suite `zz-b05.tst.sh` (on <box2> at `/var/spool-hub/c-081/b05-red-controls/`, readable by the spool-agents group), run against `git archive 35a8a111d csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`. It sources the func file in a temp dir with `REVIEW_LINE_BOX=box-a`, builds `unified/s1` and `unified/s2` (each `CURRENT` + `chunks/c1.json`, the test command only in `s2`) and a session dir under a `chmod 000` parent.

| row | command (scratch, repo untouched) | output | who |
|---|---|---|---|
| 01 | `bash zz-b05.tst.sh <archived func file>`, case 01 (as the owner of the temp dir, parent `chmod 000`) | `FATAL log …/locked/s3 is not readable on box-a as <HARNESS_USER>`, rc 1, no other read tried | editor |
| 01 | the real journal, as `<DEV_USER>` (Row 01 evidence) | `FATAL log … is not readable on <box2> as <DEV_USER>`, rc 1 | editor |
| 02 | same suite, cases 02a, 02b | `FAIL 02a log: the store root (2 sessions) is refused (rc 0, want 1)`, `PASS 02a control: log: one session dir -> OK (rc 0)`, `FAIL 02b reviewer with no agent id is refused (rc 0 …)`, `FAIL 02b reviewer is not the log: owner (rc 0 …)`, `3 failure(s)` | editor |

Baseline of the suite the rows touch, on `35a8a111d`: `bash csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` -> `spl-review-line-check: 0 failure(s)` (n=1, as `<DEV_USER>`). The reviewer re-runs the scratch suite and the baseline once.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| Round 4 row 01 (keygen on a sealed box): does the fix hold? | `go test -count=1 -run TestKeygen ./cmd/spool/` in `csi-spl-api/src/go/spool-hub-api` | `ok … cmd/spool 0.039s` (`keygen_sealed_test.go` present) | Holds. |
| Round 4 row 02 (the GC's grok pass stops on the weekly-limit menu): does the fix hold? | gc.log on <box2> and sat, `START\|END-STALE\|FALLBACK` since 2026-10-23T00:00Z | both boxes: every grok :30 pass END-STALE up to 03:00Z; at 03:30Z `FALLBACK 20261023T0330Z-gc-<box> grok -> claude: grok weekly limit`, then `START … claude`, and on <box2> `DONE` at 03:31:32Z (`b52244850`, committed 02:39Z) | Holds (n=1 pass per box). Round 4's "sat unchecked" is now checked: sat's grok passes ended stale too (25 END-STALE in 24 h). |
| Round 4 row 03 (grok limit screen gives no quota reading) | `source csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh; printf '  ┃  You hit your weekly limit.\n' \| spl_box_quota_parse grok` | `100`, rc 0 | Holds. |
| The api pre-push part logs `FAIL 1803s … TIMED OUT after 900s` (4 lines in `<DEV_USER>`'s `pre-push.log` on <box2>, 10-21..10-23) | `check-pre-push.func.sh:797-816` read | after a failure the same part re-runs on the base ref, and `el` is taken after that second run (:809) | By design: the wall time is part + trunk re-check. The 900 s budget itself is SPL-2977, landed. |
| c-179 restarts on a git username prompt (4 `FAIL SPAWN`, `rotate.log`) | `grep -a 'no claude carrying' rotate.log` | 10-22 10:00Z..11:21Z only, none since; already in round 4 section 4 | Not repeating. |
| 10 `IDLOCK REFUSED` (rotate.log 2026-10-22T13:50Z) | the 24 h group above | one burst of identity restores, each refused because one restore already held the lock | The lock working as designed; no repeat. |
| `SWITCH SKIP` agy / grok (57 lines) | the 24 h group above | agy: lane-mix `no pick`; grok: on its weekly limit | The rotation correctly refuses a vendor with no quota. |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| (c) The full-tier api budget's 2700 s cap binds above ~1.38 load per cpu now that the base is 1950 s (c-973, SPL-2977 note) | The arithmetic holds: 2700 / 1950 = 1.385, so above that load the budget stops growing (`_pp_api_full_default`, `check-pre-push.func.sh:523-531`). A defect needs a green suite that runs longer than 2700 s: `<DEV_USER>`'s `pre-push.log` on <box2> has 0 full-tier api runs since `3686f4936` (4 api lines since 02:33Z, all `SKIP-untouched`); the measured green walls are 1111 s and 842 s below 1/cpu (the commit) and 858 s at 1.82/cpu (the func comment). Load at the measurement: 3.55 on 16 cpus. Not loaded on purpose (the brief: change nothing on the box). | Not reproduced: no run over 2700 s, n=0 runs above 1.38/cpu since the change. A row needs a measured timeout of a green trunk at that load. |
| How many R7 lines candidate (a) voided | the dispatcher's messages ee130122 and 6570df5d | not in this box's spool (`grep -rl '"msg_id": *"ee130122'` over c-001, c-002 -> none). The defect itself reproduces (Row 01); the count is unchecked. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| (d) The sat go-cache prune cron deletes files from a cache in use | its own bug lane, `c002-orc-go-cache-prune-in-use` (SPL-2986, `wip`) | Left out by the brief. |
| The hub client reads the clear `box-<id>.key`, so a sealed box stays offline after `unlock` (round 4 section 6) | spec 025, a later row | Still open: `git log 3f48f3afe..35a8a111d -- …/internal/hubclient` -> 0 commits. |
| `do_spl_lane_mix` picks grok for `simple_coding` while grok is at its weekly limit (`LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` -> `pick=grok`, "0 of the last 8 simple_coding spawns, under its 41 of 100") | the dispatcher / orchestrator (vendor weights) | As in round 4; the rows here name claude. |
| Round 3 row 03 retro review (SPL-2924) and the round 4 row 02/03 reviewers (SPL-2978, SPL-2982) | their mistral R7 seats | Open `wip` issues; not a defect on the tree. |
| SPL-1945 secret rotation plan | blocked, needs owner | Not this round's to place. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (both defect fixes, each with a red control run on `35a8a111d`) |
| vendor | claude 2 |
| box (preferred) | <box2> 2 (`BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `pick=<box2>`, 26 % `under`; sat 64 % `in band`) |
| batches | 2 (one lane, Row 01 then Row 02: same files) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `c-081@<box2>` (claude).
- **Reviewer:** `m-110@<box2>` (mistral). **VOID** (failed seat, c-002 msg ccc00288): its verdict `80ed8199b` and its signature `f1eb5b05b` ("PASS v1.0, signed on 76c0d5321…") do not count, because its journal holds no run that produced the cited red-control outputs (c-001 msg 237341ec). A replacement seat (ask 32415043) wrote `seat-mistral2.md`.
- **Reviewer:** `m-845@sat` (mistral, ask 32415043). **VOID** (failed seat, c-002 msgs fa8849f4 and ba1f8735): verdict `63955c7da` does not count. Its row 02 says the check refuses every 02a/02b line with rc 3 ("no commands found"); the scratch suite re-run on `63955c7da` (`git archive origin/master csi-spl-orc` into a scratch dir, `bash zz-b05.tst.sh csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`) prints `FAIL 02a … (rc 0, want 1)`, `PASS 02a control … (rc 0)`, two `FAIL 02b … (rc 0 …)` and `3 failure(s)`, n=1. Its "Not reproduced (c)" and "Left out (d)" sections state claims that are not in this plan, and its session log is a bare placeholder. A third seat (ask d6af4567) writes `seat-mistral3.md`.
- The verdict landed on the third try: `3019534c7` was reported landed but the pre-push hygiene part had refused it (12 lines with a literal user, box or home path); `80ed8199b` puts placeholders in those lines. The review content did not change. The verdict names no session id under "Proof of the run", so the dispatcher reads m-110's journal before ACCEPTED.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-081@<box2> | **v1.0** (verdict `80ed8199b` folded: no row change) |
| Reviewer | m-110@<box2> (mistral) | **VOID** (failed seat, c-002 msg ccc00288; verdict `80ed8199b`, signature `f1eb5b05b`: no run in its journal) |
| Reviewer | m-845@sat (mistral, ask 32415043) | **VOID** (failed seat, c-002 msgs fa8849f4 and ba1f8735; verdict `63955c7da`: row 02 rc 3 contradicts the red control's rc 0) |
| Reviewer | third mistral seat (ask d6af4567) | pending |
