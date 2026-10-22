# Bug-fix round 3 - plan (3 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 3 focus: **freshly measured defects: the work-class share counts dead lanes, the lane rotation log splits a command over lines, and a channel's side-list number misses lines its topic cards count**.  
Concurrency: **build 2 row lanes in parallel at all times** (rounds-rulebook.md §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), by pointer, not copied. Issue: SPL-2827.  
Model: [bug-round-2-plan.md](bug-round-2-plan.md) (same shape, same 5 sources).

**Status: v1.0, folded the reviewer verdict** ([seat-claude.md](bug-round-3/seat-claude.md), `a45a65aa3`: 1 agree / 2 agree with changes / 0 disagree). Awaiting the reviewer's signing commit.

Editor: **c-738@sat** (claude, the backup vendor for `specs_and_docs`).  
Reviewer: **c-084@<box2>** (claude; verdict `a45a65aa3` at `csi-spl-doc/doc/md/bug-round-3/seat-claude.md`, measured on `76d5b4889`, whose row files equal `396343618`).

**One sha:** every count is measured on **`396343618`** (`origin/master`, 2026-10-22T05:38Z), n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else, with a **red control**: a test that fails on `396343618` and passes after the fix. Each red control below was run on `396343618` (section 3.2).
- **Paths:** repo-relative. Lines as of `396343618`.
- **Box:** the preferred box; the placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules: WUI or hub work goes to claude, Mistral writes no code.
- **Subject** (R6 reads it): `fix(b03-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>`.

---

## 2. Where the rows come from (measured on `396343618`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-20** | `cd csi-spl-orc && ENV=prd SQL="select count(*) ... from messages where tenant_id='t1' and ts >= '2026-10-20' and from_id like 'HUM%'" ./run -a do_spl_db_query`, then the same with `body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'` | 500 human posts, 4 defect-worded (n=1) | 1 reproduced (Row 03: t1 b288e5be, 2026-10-21 13:55Z, "still shows ... wrongly on the channel level"); 3 resolved or not reproduced (sections 4, 5). |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 200 runs 2026-10-20T07:42Z..2026-10-22T05:49Z: 120 success, 57 cancelled, 23 failure | Every failed job's last green is run `39730238847` on `396343618` (2026-10-22T05:49Z). Active trunk defects: **0**. Repeated signatures in section 4. |
| **3. Skipped or disabled tests, local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 396343618 -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl \| wc -l` | 175 lines: 128 in Go, 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects: every Go skip is conditional on its environment (no Postgres DSN, no GCS emulator, no node, not linux, perf opt-in); the 4 e2e entries carry their reason; the one WUI unit skip (`agent-id.test.mjs:78`) fires only when `agentid.go` is absent, and it is present. Local flake runs in section 5. |
| **4. GC notes and box alarms, last 24 h** | `spool tail --task gc-sat`, rows from 2026-10-21T08Z (41 notes); `/var/spool-hub/dispatch/rotate.log`, `lease.log` | 41 GC notes; every one repeats 194..198 "unknown" lanes with no class | 2 reproduced (Row 01: the share counts dead lanes; Row 02, found while checking the rotation alarms: rotate.log carries command fragments as lines). |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list` | 272 issues (total 272), 4 labelled `bug` | SPL-1945 (blocked, needs owner); SPL-455 / SPL-450 / SPL-435 out of scope by the brief (spec 011 regression-gate checks, not defects). 0 rows. |

---

## 3. The 3 rows

| # | defect | evidence | sites file:line | red control (fails on `396343618`) | fix scope | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b03-01-orc-spawn-share-live-lanes)` | `do_spl_spawn_share` counts lane rows that are only nominally live: hub rows nobody refreshed for days, and leftover worktrees. The band verdicts it feeds (the GC summary, the placer's band pick `spl-spawn-place.func.sh:182,215`, the filler `spl-spawn-fill.func.sh:72`) are computed over dead lanes. | `LANE_FORMAT=json LANE_ALL=1 ./run -a do_spl_lane_map` -> 210 rows `state=live`; 180 of them are hub rows older than 24 h (oldest 2026-10-02), 12 are `src=local` leftover worktrees; tmux on sat shows 7 agent windows. `SPAWN_SHARE_FORMAT=json ./run -a do_spl_spawn_share` -> `known 12, unknown 198`; 7 of the 12 known lanes are 55..91 h old (`a-313`, `a-321`, `a-417`, `a-434`, `a-271`, `a-468` @sat: no window, not in `registry.retired.tsv`; `a-330@<box2>`), so bug read 2/12 = 16 % UNDER. Re-measured 2026-10-22T06:35Z, after c-001 retired those 6 agy lanes (06:33:51Z..06:34:07Z): 207 rows `state=live`, 174 older than 24 h, 12 `src=local`; the share reads `known 9, unknown 198`, 1 of the 9 (`a-330@<box2>`) 55 h old. The defect stands; only its size moved. | `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh:80-89` (`spl_spawn_share_lanes`, the jq at :88); new test `csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh` | With `SPAWN_SHARE_LANES_CMD` printing one row `age_s 600` and one `age_s 330000`, `spl_spawn_share_lanes` returns both today (run on `396343618`); it must return only the first. (b) With a stub `{"hub":"ok","lanes":[<row age_s 600 src hub>, <row c-102 age_s -1 src local>]}` both rows come back today (reviewer run, red); the local row must be left out while the hub answered. | Apply the lane map's own recent rule (`spl-lane-map.func.sh:211-215,307`) in `spl_spawn_share_lanes` (the jq at :88): keep a live row when `age_s` is 0..`LANE_RECENT_S` (7200), or it is a role seat (`$seat`, :213; it adds to `unknown` only, no `Class:` brief), or it has no age (`age_s < 0`) and the input's `.hub` is not `ok`. **A missing `.hub` reads as not ok**, so the existing stubs (`spl-spawn-queue.tst.sh:403,436`, `spl-spawn-fill.tst.sh:111,170`: rows with neither `age_s` nor `hub`) keep their rows and stay green; the row runs both suites in its gate, and if either stub must change it names that file (R1). Consumers (`spl-spawn-place.func.sh`, `spl-spawn-fill.func.sh`) need no change. **Expected reading on today's map** (2026-10-22T07:00Z, rule applied by hand to `do_spl_lane_map` JSON): today `known 13, unknown 198`; after `known 12, unknown 15` (bug 4, feature 4, refactor 4); the R7 reviewer re-measures it at the fix. | sat | claude | simple_coding | 1 (lane B) |
| 02 `fix(b03-02-orc-lane-rotate-busy-one-line)` | `spl_lane_rotate_busy_child` turns a busy child's NUL-separated cmdline into text but keeps its newlines; `cut -c1-120` then cuts each line, so a multi-line command (a heredoc, a `bash -c` script) lands in `rotate.log` as several lines with no timestamp, after the `GATE OK ... in flight: running '...` line. | `rotate.log` lines that do not start with a UTC stamp, grouped by the day of the stamped line before them: 17, 16, 27, 14, 23, 17, 45, 7 (2026-10-12..10-22), 166 in all (`grep -vcE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T' rotate.log`). | `csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh:315-316` (the `tr` and the `cut`), shown at :295, :413, :415, :460; test `csi-spl-orc/src/bash/tests/lane-rotate.tst.sh` | A `LEASE_PROC_ROOT` fake: pid 100 (`claude`), child 200 with cmdline `/bin/bash\0-c\0git push origin HEAD:master\necho two\necho three`, `ROTATE_LANE_BUSY_RE="git push"`: `spl_lane_rotate_busy_child 100` prints 3 lines today (run on `396343618`); it must print 1 line of at most 120 characters. | Fold `\n` and `\r` to spaces along with the NULs (`tr '\0\n\r' '   '`) before the match and the cut. No other change. | sat | claude | simple_coding | 2 (lane B, after Row 01) |
| 03 `fix(b03-03-api-channel-row-counts-every-line)` | The side-list channel number reads the hub Flow key `ch:<id>` (`ChannelSidebar.vue:332` -> `rowUnread`, `utils/flow-keys.mjs:36-37`), which `flowCountsSQL` counts from `flow_events` only. A `flow_events` row is written only for a member who is mentioned, addressed, or watching the topic (`flowInsertCTE`). So a new topic that names nobody, or replies in a topic the member opened but does not watch, show on the topic cards and in the channel view but not on the channel row. Spec 062 section 1 says the channel unread is the channels stats count (lines after the later of the cursor and the `ch:` mark). SPL-2124 (`85225b513`) fixed which mark covers a line, not which lines are counted. | Test in a scratch copy of the module at `396343618`, red on memory (editor) AND Postgres (reviewer, local postgres:16-alpine) (`go test -count=1 -run TestZZChannelRowVsCards ./internal/store`): `new opener, no mention: MISMATCH channel view 1 vs side-row key 0`; `2 replies in a read-but-unwatched topic: MISMATCH channel view 3 vs side-row key 0`; FAIL. prd t1, read-only, the 24 h before the report: 6 channel openers from others (spool-hub-ops 3, spool-hub-devel 1, alerts 2) had no `flow_events` row for the reporting member. At 2026-10-22 06:24Z no mismatch was live (every `ch:` key equalled its topics' `t:` sum), so the defect is structural, not a standing number. | `csi-spl-api/src/go/spool-hub-api/internal/store/flow_postgres.go:41-66` (`flowInsertCTE`), `:166` (`flowCountsSQL`) and its memory twin; test `internal/store/channels_thread_unread_test.go`; read path (no change) `csi-spl-wui/src/utils/flow-keys.mjs:36-37`, `csi-spl-wui/src/components/ChannelSidebar.vue:332` | The scratch test above, adopted into `channels_thread_unread_test.go` for memory AND Postgres: `ViewChannelStats` unread for the member equals `FlowRead` `ch:<id>` after (a) an unmentioned opener and (b) 2 replies in a topic with a `t:` mark and no watch. Fails today in 2 of 2 cases on both drivers. The same test asserts that `FlowRead`'s mention / reply / dm / unread counts stay 0 in both cases. | **Hub side** (reviewer: the WUI max() cannot fix an unopened channel, since cards are seeded only on channel open, `pages/channel/[name].vue:86,94`, and the owner's report is that case). Add every channel line that passes the door and read-mark rules, as `ViewChannelStats` counts it, to the `ch:` and `t:` **keys only**, never to the Flow badge counts that share the same `fc` rows (`flow_postgres.go:166-205`; spec 062 "only what concerns me"). State in the commit that the Channels rail number (`sectionTotal` over the `ch:` keys, `utils/flow-keys.mjs:22`) rises: intended, it equals the rows under it. **Cost budget**: `flow_counts` p50 today 26.2 ms (reviewer, prd t1 HUM-10, read-only `do_spl_db_hot_measure`, n=20); after the fix at most 52 ms p50, n=20, same command. Over it, reuse the channel-count statement's result instead of a second walk, and report to the editor before pushing. | sat | claude | complex_coding | 1 (lane A) |

### 3.1 Disjoint files (R1) and 2 parallel lanes

- **Lane A:** Row 03 (`csi-spl-api/.../store/flow*.go`, `channels_thread_unread_test.go`; no WUI file).
- **Lane B:** Row 01 (`spl-spawn-share.func.sh`, new `spl-spawn-share.tst.sh`; `spl-spawn-queue.tst.sh` / `spl-spawn-fill.tst.sh` only if a stub must change) -> Row 02 (`spl-lane-rotate.func.sh`, `lane-rotate.tst.sh`). Row 02 behind Row 01 is a capacity choice, not a file conflict.
- Batch 1 = Row 03 + Row 01, no shared file. Batch 2 = Row 02, no file of batch 1.
- `lane-map.sh --check <row files> --agent c-738` -> exit 4 for each row: the 5 live lanes with no files recorded are c-296@<box2> (CI editor seat, doc only), c-380@<box2> and c-387@<box2> (Cloud Run radar plans), c-423@<box2> (a single-channel seat), c-499@sat (desk seat). None of their scopes touches these files. Re-check at spawn.

### 3.2 Red controls run on `396343618`

Inputs, to rebuild in any scratch dir (also on sat at `/var/spool-hub/c-738/b03-red-controls/`, readable by the box user only):

- Row 01 (a) stub `lanes.sh`: `echo '{"lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":600},{"agent_id":"a-313","agent_box":"sat","state":"live","age_s":330000}]}'`
- Row 01 (b) stub: `echo '{"hub":"ok","lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":600,"src":"hub"},{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":-1,"src":"local"}]}'`
- Row 02 fake proc: `mkdir -p P/100 P/200; echo '100 (claude) S 1 1' > P/100/stat; printf 'claude\0' > P/100/cmdline; echo '200 (bash) S 100 1' > P/200/stat; printf '/bin/bash\0-c\0git push origin HEAD:master\necho two\necho three\0' > P/200/cmdline`
- Row 03: `zz_mismatch_test.go` (in the sat dir above; the editor's msg 3d725c4f to the reviewer carries it inline).

| row | command (scratch, repo untouched) | output | who |
|---|---|---|---|
| 01 (a) | `source csi-spl-orc/src/bash/run/spl-spawn-share.func.sh; SPAWN_SHARE_LANES_CMD=<stub a> spl_spawn_share_lanes` | both rows returned | editor + reviewer |
| 01 (b) | the same with stub (b) | both rows returned | reviewer |
| 02 | `source csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh; ROTATE_LANE_BUSY_RE="git push" LEASE_PROC_ROOT=P spl_lane_rotate_busy_child 100 \| wc -l` | 3 | editor + reviewer |
| 03 | `go test -count=1 -run TestZZChannelRowVsCards ./internal/store` in a scratch copy of `csi-spl-api/src/go/spool-hub-api` (Postgres: `SPOOL_TEST_PG_DSN=<local postgres>`, `csi-spl-rdb` beside it) | `FAIL`, 2 mismatches, memory and Postgres | editor (memory) + reviewer (both) |

Baseline of the tests the rows touch, on `396343618`: `lane-rotate.tst.sh` 0 failure(s), `spl-spawn-queue.tst.sh` PASS, `spl-spawn-fill.tst.sh` PASS.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| CI: 23 failed runs in 200 | `do_report_ci_gate` (section 2) | first reds: e2e 8/8 (6, "K4 1440", 2026-10-21 23:33Z..10-22 00:32Z), e2e 7/8 (5), hub Postgres gate (5, `TestMentionGrammarPinnedToWUI` 3x), e2e 5/8 (4), e2e 2/8 (4) | Each job's last green is run `39730238847` on `396343618`; K4 fixed by `af62f0e53` (SPL-2784), the mention pin by `36717a7f5` (SPL-2759), the proxy-port red (`35f30c26`, 1 run) by `21db6dcbf`. |
| Skipped tests | `git grep` (section 2) | 175 lines, 0 unconditional | Environment-gated skips, each with its reason. |
| Go toolchain on <box2> (t1 d8ca583e, 2026-10-20) | topic read, `do_spl_db_query` | posted Live 2026-10-20 13:36Z (SPL-2717) | Box setup, done. |
| Rotation fails with grok as orch (t1 5471b31d, 2026-10-20) | `awk '$1>="2026-10-21T06" && $4 ~ /FAIL\|ABORT\|ROLLBACK\|TIMEOUT/' rotate.log \| wc -l`; `ENV=prd SQL="select count(*) ... body like '%ROTATION FAILED%' and ts > now() - interval '24 hours'"` | 0 and 0 (sat log, n=1) | The memory gap the owner named is SPL-2738, done (`b269402ed`). <box2>'s rotate.log was not read from sat. |
| Main checkout ahead of origin (GC note 2026-10-22 04Z) | `git -C /opt/csi/csi-spl log --oneline origin/master..HEAD` | 0 commits, on `master` | Resolved. |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| Orch lease age read as the Unix time (t1 d9945f1d, 2026-10-20; the guard SPL-2654 `a21cc06b1` landed, the writer was not found) | `grep -c AGE-UNKNOWN /var/spool-hub/dispatch/lease.log` on sat (the guard logs one line per bad read) | 0 since the guard; <box2>'s lease.log not read. |
| CI `run-log.tst.sh` "blocked log dirs: rc=0" (runs `39535497381`, `39587366277`) | `bash csi-spl-orc/src/bash/tests/run-log.tst.sh` x3 as the agent user, x3 as the box user | 6 of 6 `0 failure(s)`. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| Done-claim check reads a git tree id as an unlanded commit | queued ask `af9a18a6`, `claude:c002-done-claim-tree-id` | Bug row in the queue; files `spl-done-claim-check.func.sh` + its test, disjoint from every row here. |
| 6 agy lanes on sat with no window and no retire (`a-313`, `a-321`, `a-417`, `a-434`, `a-271`, `a-468`) | the orchestrator (close, then `do_spl_agent_id_retire`) | Operational, not code; Row 01 stops such lanes skewing the share either way. Reported to the dispatcher with this plan. |
| SPL-1945 secret rotation plan | blocked, needs owner | Not this round's to place. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all defect fixes, each with a red control run on `396343618`) |
| vendor | claude 3 |
| box (preferred) | sat 3 |
| batches | 2 (batch 1: 2 parallel lanes; batch 2: 1 lane) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `c-738@sat` (claude).
- **Reviewer:** `c-084@<box2>` (claude), verdict `a45a65aa3` ([seat-claude.md](bug-round-3/seat-claude.md)); it signs v1.0 in its own commit.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-738@sat | **v1.0** (folded: row 01 (b) control, hub-read rule, role seats, stub suites, expected reading; row 03 hub side, keys only, rail note, Postgres red, cost budget 52 ms; 3.2 inputs inline) |
| Reviewer | c-084@<box2> | verdict `a45a65aa3` (1 agree / 2 agree with changes); signature pending |
