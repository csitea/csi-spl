# Bug-fix round 10 - plan (0 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 10 focus: **Fresh measurement across the 5 mandated sources and investigation of dispatcher candidate sightings from 2026-10-28** (`do_spl_lane_mix` latency, `do_spl_desk_poll_ack` cron logging, done-claim check on unlanded push status results, and desk-cron `bin/spool` freshness warning).  
Concurrency: rulebook §1.1 allows up to 2 row lanes in parallel; 0 rows identified, 0 row lanes needed (section 3.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-4152.  
Model: [bug-round-9-plan.md](bug-round-9-plan.md) (same shape, same 5 sources).

**Status: v0.1** (editor a-577@sat).  
Editor: **a-577@sat** (agy, `specs_and_docs`).  
Reviewer: **Pending assignment** (cross-vendor reviewer, rulebook 2.7.2). Requested from dispatcher for v0.1 review.

**One sha:** every count below is measured on **`1663c828b`** (`origin/master` at the start, 2026-10-29T02:57:32+01:00 / 01:57:32Z), on sat. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else. Each row has a **red control**: a test that fails on `1663c828b` and passes after the fix.
- **Paths** are repo-relative. Line numbers are as of `1663c828b`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Mistral writes no code.
- **Subject** (R6 reads it): `fix(b10-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).
- **Valid 0-row outcome:** Per round brief §6 and rounds rulebook §1.1/§1.4, if the 5 sources and candidate investigations yield 0 reproduced defects, a plan of 0 rows is a valid and accurate result; rows are never padded.

---

## 2. Where the rows come from (measured on `1663c828b`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-26** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-26' and from_id like 'HUM%'" ./run -a do_spl_db_query`. Then all 14 defect-worded bodies were read | 744 human posts, 14 defect-worded, 504 `[spool-probe]` lines (since 2026-10-26). | 0 unhandled defects. The 14 defect-worded messages relate to Google calendar sync (`838e3484`, resolved), missing textbox labels (`f456ecd5`, resolved), missing blog language switcher (`4d6bc718`, resolved), file streams usage questions (`c168784c`), and the CI 100 failed runs panel (`0101e192` / SPL-4119, with fixes F1-F5 landed on master). **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 200 runs 2026-10-27T18:20:02Z .. 2026-10-29T02:45:12Z: 109 success, 64 cancelled, 24 failure, 3 running. Every timeout headroom line is `ok` | All 24 failed runs reflect previously investigated issues (dragged grip in e2e 4/8, release sha click in e2e 2/8, orc hermetic action tests handled in CI panel SPL-4119). Last green per failed job shows all jobs have been green since. 0 new defects. **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 1663c828b -- "$d" \| wc -l; done`. `diff` of the sorted grep (`-h`) against `e8283427d` | 193 lines (api 146, wui 17, orc 9, iac 21, utl 0). `diff` shows 6 new skip lines in `csi-spl-api` for tests guarded by `SPOOL_TEST_PG_DSN` (Postgres only). 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. 0 local flakes. **0 rows.** |
| **4. GC notes and box alarms, last 24 h** | `SPOOL_ROOT=/var/spool-hub spool tail --task gc-sat` | Across the last 24 h on sat: 0 restarts, 0 close asks, 0 box alarms. Notes reflect routine rotation tracking and share band monitoring (e.g. refactor over, bug under). | All GC cycles ended normal. 0 unhandled alerts. **0 rows.** |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3` | 365 issues, 3 labelled `bug`; 35 with a defect word in the title | The `bug` labelled ones are SPL-455 / SPL-450 / SPL-435 (out of scope by brief). Active defect issues are owned by live lanes (SPL-4156 placer band pick jq arg length, SPL-4155 box quota reset date, SPL-4152 this plan, SPL-3885 done-claim check box-local clones). Candidate (a) is measured and not a bug (latency in wd scan, pick line printed); candidate (b) is measured and not a bug (poll-ack cron acknowledged at 21:38:24Z, subsequent ticks skip already-acknowledged); candidate (c) is measured and not a bug (lane protocol violation by c-394 caught as designed); candidate (d) is measured and not a bug (staleness guard working as designed). **0 rows.** |

---

## 3. The 0 rows

No reproduced defects identified across the 5 mandated sources and 4 candidate sightings. A plan of 0 rows is recorded per brief instructions.

### 3.1 Files (R1) and lanes

- No row files to lock or batch.
- Lane-map check for plan document: `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-10-plan.md --agent a-577` -> exit 4 (`no live lane lists csi-spl-doc/doc/md/bug-round-10-plan.md`, 6 live lanes with unrecorded files do not touch doc).
- Spawn queue: `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 12 rows (12 feature, 0 bug, 0 refactor).

### 3.2 Red controls run on `1663c828b`

*None (0 rows).*

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| (a) `do_spl_lane_mix` latency and missing pick line in captured tail | `cd csi-spl-orc && sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub LANE_MIX_KIND=specs_and_docs ./run -a do_spl_lane_mix` | Runs for ~107 s (profiling shows delay is in `_spl_lane_mix_avail` -> `_spl_lane_mix_verdict`, which sequentially checks 2,953 historical `out.s2` files under `/var/spool-hub/dispatch/wd/ctx*/*/out.s2` across 6 passes for grok/agy/mistral limit and auth). It exits 0 and prints: `pick=agy launcher=/agy-spawn kind=specs_and_docs reason=...` | **Not a code bug in lane mix logic; output was delayed, not missing.** The command does not hang indefinitely; it completes and prints the expected pick line. The captured tail lacked the pick line because the command was backgrounded while still executing or before stdout flushed. While optimizing the watchdog directory traversal is a valid speed-up candidate for a refactoring round (per `lesson-speed-up-measure-first.md`), `do_spl_lane_mix` produces the correct output and exit code 0. |
| (b) `do_spl_desk_poll_ack` logging `0 answer(s) acknowledged` around HUM-10's answer `d0caa82a` | Read `/var/csi/csi-spl/poll-ack/cron.out` and `/var/spool-hub/dispatch/automation.log` | `automation.log` line 1: `2026-10-28T21:38:27Z poll-ack d0caa82a-6436-4d63-8113-aa4993dac961 action=sent actor=c-002@sat tenant=t1 topic=c168784c-... poll=5a85c2c1-... from=HUM-10 keys=B reply_rc=0 wake_rc=0`. `cron.out` lines 6-10: `OK msg d0caa82a...: c-002 acknowledged HUM-10's poll answer B... 1 answer(s) acknowledged` | **False alarm by dispatcher; cron executed correctly.** The cron DID acknowledge the answer at `21:38:24Z` (posting msg `5e2d1871-a1a7-4328-bb02-30b1f04ba771`). The dispatcher posted manually 5 seconds later at `21:38:29Z` (msg `858fc9c2`). Ticks prior to 21:38:24 saw 0 because the desk spool had not yet synced the answer. Ticks after 21:38:27 logged `0 answer(s) acknowledged` because line 87 of `spl-desk-poll-ack.func.sh` skips messages already logged in `automation.log` (spec 157 Rule 5 Step 1). |
| (c) `do_spl_done_claim_check` flagged c-394's result `aefab0c0` as 'sha 1b66f1b9c not in the repository' | Read message `aefab0c0` (`/var/spool-hub/c-002/archive/...aefab0c0.json`), note `b504c2d7`, and `git branch -a --contains 1b66f1b9c` | Message `aefab0c0` is from `c-394` to `c-002` with `kind: result`, stating "The master push of `1b66f1b9c` is on try 2/4 (do_spl_push_master, started 18:23Z)...". `1b66f1b9c` existed only in `c-394`'s local worktree, not on trunk and not on any `origin/review/*` remote branch | **By design; lane protocol violation by sender.** Rule SPL-2265 dictates that messages of `kind: result` represent claims of completed work, and any sha cited must resolve on trunk (or on a remote review branch under SPL-3673 with explicit unlanded indication). c-394 was sending an in-flight status update answering an ETA inquiry, which must use `kind: note`, not `kind: result`. The checker acted strictly per specification in flagging an unlanded sha in a `kind: result` message. |
| (d) `spool-env: WARN ... bin/spool is older than its sources ... not using it` on desk-cron | `git check-ignore -v` on `csi-spl-api/src/go/spool-hub-api/bin/spool`; `ls -la /opt/csi/csi-spl-desk-cron/csi-spl-api/src/go/spool-hub-api/bin/spool` and `readlink -f ~/.local/bin/spool` | Desk-cron binary is an untracked local build from 2026-10-27T05:28:42Z. It is never automatically rebuilt by cron. When stale, `_spool_bin_stale` emits the warning and `_spool_bin_fallback` cleanly falls back to `~<HARNESS_USER>/.local/bin/spool` -> `/var/csi/csi-spl/spool/bin/spool` (built 2026-10-28 20:13 UTC) | **By design (staleness guard working), not a code defect.** Exactly as evaluated in Round 8 Plan line 71: `spool_env_resolve` detects that the local untracked binary is older than sources, warns, and uses the fresh fleet-wide binary at `~/.local/bin/spool`. |

---

## 5. Not reproduced

*None. All candidates were empirically investigated and accounted for.*

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| File-streams follower reading FILE_STREAMS_HUBS from box.env | c-522@sat (owner poll 5a85c2c1 B) | Live lane. |
| Spec 157 rows B4/B5 | c-802, c-805 | Live lanes. |
| Placer band pick jq argument list too long | SPL-4156 | Live lane (`wip`). |
| Box quota parser reset date calculation | SPL-4155 | Live lane (`wip`). |
| Done-claim check reading box-local clones of other orgs | SPL-3885 | Live lane (`wip`). |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gate checks | Out of scope by brief (labelled `bug` but not defects). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 0 (0 reproduced defects) |
| vendor | 0 |
| box (preferred) | 0 |
| batches | 0 |

---

## 8. Panel and reviewer (R7)

- **Editor:** `a-577@sat` (agy, `specs_and_docs`).
- **Reviewer:** Requested from dispatch lease holder (`c-002@sat`) upon v0.1 landing (cross-vendor reviewer, rulebook 2.7.2).
- **Review history:**
  - 2026-10-29 03:05Z: Editor landed v0.1 draft (`csi-spl-doc/doc/md/bug-round-10-plan.md`, SPL-4152).

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | a-577@sat | **v0.1** |
| Reviewer | pending | awaiting dispatch seat placement |
