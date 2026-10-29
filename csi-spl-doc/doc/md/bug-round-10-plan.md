# Bug-fix round 10 - plan (2 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 10 focus: **`do_spl_lane_mix` latency causing caller timeout 124 in `spl-spawn-fill` and skipping issue placement (Row 01)**, and **`do_spl_security_round_queue` crash on unbound `SPOOL_ROOT` in Friday cron (Row 02)**; plus investigation of candidate sightings from 2026-10-28 (`do_spl_desk_poll_ack` cron logging, done-claim check on unlanded push status results, and desk-cron `bin/spool` freshness warning).  
Concurrency: batch 1 has 2 row lanes (Row 01 and Row 02) running in parallel across disjoint files by planner's choice (section 3.1). Round size cap: at most 10 items (rulebook §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-4152.  
Model: [bug-round-9-plan.md](bug-round-9-plan.md) (same shape, same 5 sources).

**Status: v1.0** (signed consensus, editor a-577@sat, reviewer c-408@<box2>).  
Editor: **a-577@sat** (agy, `specs_and_docs`).  
Reviewer: **c-408@<box2>** (claude, cross-vendor reviewer, rulebook 2.7.2, brief `c002-bug-round-10-claude-reviewer`). Signed v1.0 consensus (PASS on b4ad49dc6).

**One sha:** every count below is measured on **`1663c828b`** (`origin/master` at the start, 2026-10-29T02:57:32+01:00 / 01:57:32Z), on sat. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else. Each row has a **red control**: a test that fails on `1663c828b` and passes after the fix. Section 3.2 shows each red control's run on `1663c828b`.
- **Paths** are repo-relative. Line numbers are as of `1663c828b`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Mistral writes no code. Both rows are bash tooling in `csi-spl-orc` (`simple_coding`), coding vendor claude.
- **Subject** (R6 reads it): `fix(b10-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).

---

## 2. Where the rows come from (measured on `1663c828b`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-26** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-26' and ts <= '2026-10-29T01:57:32Z' and from_id like 'HUM%'" ./run -a do_spl_db_query`. Then all 14 defect-worded bodies were read | 732 human posts, 14 defect-worded, 492 `[spool-probe]` lines (since 2026-10-26 up to 01:57:32Z; 744/14/504 without end time cap). | 0 unhandled defects. The 14 defect-worded messages relate to Google calendar sync (`838e3484`, resolved), missing textbox labels (`f456ecd5`, resolved), missing blog language switcher (`4d6bc718`, resolved), file streams usage questions (`c168784c`), and the CI 100 failed runs panel (`0101e192` / SPL-4119, with fixes F1-F5 landed on master). **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 200 runs 2026-10-27T18:20:02Z .. 2026-10-29T02:45:12Z: 109 success, 64 cancelled, 24 failure, 3 running (window drift to 03:19Z saw 112/65/21). Every timeout headroom line is `ok` | All failure families have existing fixes on master: 16e `reset passed` flake was fixed in `c6463e496` (SPL-4135); `action no SPOOL_ROOT` fixed in `372d72579`; C5 fixed in `91f6ee584`; S4 fixed in `4f861e051`; 390px sha click in `865a0cfd8`; `orc check skipped` in `4b7f554ca`; Go modules in `d78fd66a2`; Caddy image in `709d1f32e`; iac tmux-health-guard in `273becaba`; grip in `687b0e50d`; single TestHubRunTwoDaemonsOneLeaves not reproduced (20 of 20 green). 0 new defects. **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 1663c828b -- "$d" \| wc -l; done`. `diff` of the sorted grep (`-h`) against `e8283427d` | 193 lines (api 146, wui 17, orc 9, iac 21, utl 0). `diff` shows 6 new skip lines in `csi-spl-api` for tests guarded by `SPOOL_TEST_PG_DSN` (Postgres only). 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. 0 local flakes. **0 rows.** |
| **4. GC notes and box alarms, last 24 h** | `SPOOL_ROOT=/var/spool-hub spool tail --task gc-sat` | Across the last 24 h on sat: 0 restarts, 0 close asks, 0 box alarms. Notes reflect routine rotation tracking and share band monitoring (e.g. refactor over, bug under). | All GC cycles ended normal. 0 unhandled alerts. **0 rows.** |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3` | 365 issues (368 with live lanes), 3 labelled `bug`; 35 with a defect word in the title | The `bug` labelled ones are SPL-455 / SPL-450 / SPL-435 (out of scope by brief). Active defect issues are owned by live lanes (SPL-4156 placer band pick jq arg length, SPL-4155 box quota reset date, SPL-4152 this plan, SPL-3885 done-claim check box-local clones). Candidate (a) **reproduces as a defect** (Row 01); candidate (W2) **reproduces as a defect** (Row 02); candidate (b) is measured and not a bug (poll-ack cron acknowledged HUM-10 answer at 21:38:24Z); candidate (c) is measured and not a bug (lane protocol violation by c-394 caught as designed); candidate (d) is measured and not a bug (staleness guard working as designed). **2 rows.** |

---

## 3. The 2 rows

| # | defect | evidence | sites file:line | red control (fails on `1663c828b`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b10-01-orc-lane-mix-wd-timeout)` | `do_spl_lane_mix` latency (>60 s) causes caller timeouts in `spl-spawn-fill` and `spl-security-round-queue` (wrapped in `timeout ${SPAWN_FILL_TIMEOUT:-60}` and `timeout ${SECURITY_ROUND_TIMEOUT:-60}`), exiting 124 without a `pick=` line. In `spl-spawn-fill.func.sh:221`, `spl_spawn_fill_vendor` receives empty output and logs `"no vendor (the lane mix says hold)"`, skipping issues rather than spawning seats. | (1) Re-measured on sat on `1663c828b`: `LANE_MIX_KIND=complex_coding timeout 60 ./run -a do_spl_lane_mix` exits 124 after 60 s with 0 output; without timeout it takes 107.5 s on sat (86 s on <box2>). (2) Latency profiling shows delay is in `_spl_lane_mix_verdict` (`csi-spl-orc/src/bash/run/spl-lane-mix.func.sh:612-627`), which iterates sequentially over 2,953 `out.s2` files across 6 passes under `/var/spool-hub/dispatch/wd/ctx*/*/out.s2`, spawning ~4 processes per file (grep, stat, basename/dirname, awk). (3) `/var/csi/csi-spl/spawn-fill/cron.out` on sat records 184 lines of `"no vendor (the lane mix says hold)"`, skipping issue placement. (4) `spl-spawn-fill.tst.sh` stubs `SPAWN_FILL_MIX_CMD`, leaving the 60 s execution timeout path untested. | `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh:612-627`; test `csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh` | `LANE_MIX_KIND=complex_coding timeout 60 bash csi-spl-orc/run -a do_spl_lane_mix`. Today on `1663c828b`: exits 124 in 60 s with no `pick=` line. PASS requires: exits 0 printing valid `pick=<vendor> ...` line well inside 60 s (< 15 s on loaded box, < 5 s idle), existing `spl-lane-mix.tst.sh` passes (all 114 PASS lines green), plus a counting test verifying constant O(1) process invocations regardless of `out.s2` file count. Keep caller 60 s / 120 s timeout bounds. | In `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh:612-627`: optimize watchdog `out.s2` scanning in `_spl_lane_mix_verdict`. Avoid spawning ~4 processes per file over 2,953+ `out.s2` files. Use a single `grep -l '^HIT S2 kind=limit'` and auth pass over all files (takes ~0.064 s), then stat and look up only the matching files it lists, keeping both freshness windows (`LANE_MIX_LIMIT_FRESH` 21600 s / 6 h and `LANE_MIX_AUTH_FRESH` 604800 s / 7 days) unchanged. Add regression and counting tests in `spl-lane-mix.tst.sh`. Docs: `Docs: none (lane mix latency fix)`. | sat | claude | mistral (cross-vendor, rulebook 2.7.2) | simple_coding | 1 (lane A) |
| 02 `fix(b10-02-orc-security-round-unbound-spool-root)` | Security-round cron dies every Friday with `spl-security-round-queue.func.sh: line 49: SPOOL_ROOT: unbound variable`. | (1) Re-measured on sat on `1663c828b`: `env -u SPOOL_ROOT bash csi-spl-orc/run -a do_spl_security_round_queue` exits 1 with `spl-security-round-queue.func.sh: line 49: SPOOL_ROOT: unbound variable`. (2) `/var/csi/csi-spl/security-round/cron.out` on sat has 2 lines: `spl-security-round-queue.func.sh: line 49: SPOOL_ROOT: unbound variable`. (3) The cron entry does not export `SPOOL_ROOT`, and line 49 evaluates `tpl="${SECURITY_ROUND_TEMPLATE:-$SPOOL_ROOT/dispatch/briefs/c002-security-round-seat.md}"` directly under `set -u` before line 56 calls `spl_spawn_q_init`. The default `SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"` is set in `spl_asks_init` (`spl-asks-open.func.sh:54`), which `spl_spawn_q_init` calls. | `csi-spl-orc/src/bash/run/spl-security-round-queue.func.sh:46-56`; test `csi-spl-orc/src/bash/tests/spl-security-round-queue.tst.sh` | `env -u SPOOL_ROOT bash csi-spl-orc/run -a do_spl_security_round_queue`. Today on `1663c828b`: exits 1 with `spl-security-round-queue.func.sh: line 49: SPOOL_ROOT: unbound variable`. PASS requires: exits 0 (or exits cleanly printing off/queued status without unbound variable error), and existing `spl-security-round-queue.tst.sh` passes (all 23 PASS lines green). | In `csi-spl-orc/src/bash/run/spl-security-round-queue.func.sh:46-56`: initialize `SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"` before line 49 where `$SPOOL_ROOT` is first referenced, or ensure `spl_spawn_q_init` is called before accessing `$SPOOL_ROOT`. Add regression test case in `spl-security-round-queue.tst.sh` running with `env -u SPOOL_ROOT`. Docs: `Docs: none (security round queue env fix)`. | sat | claude | agy (cross-vendor, rulebook 2.7.2) | simple_coding | 1 (lane B) |

### 3.1 Files (R1) and lanes

- **Batch 1, lane A:** Row 01. Changes `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh` and `csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh` only.
- **Batch 1, lane B:** Row 02. Changes `csi-spl-orc/src/bash/run/spl-security-round-queue.func.sh` and `csi-spl-orc/src/bash/tests/spl-security-round-queue.tst.sh` only.
- **Concurrency (R1):** The files touched by Lane A and Lane B are completely disjoint. Up to 2 row lanes run in parallel in Batch 1 by planner's choice over disjoint files.
- Lane-map check: `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-lane-mix.func.sh,csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh,csi-spl-orc/src/bash/run/spl-security-round-queue.func.sh,csi-spl-orc/src/bash/tests/spl-security-round-queue.tst.sh,csi-spl-doc/doc/md/bug-round-10-plan.md --agent a-577` -> exit 4 (`no live lane lists` any of these files; live lanes recording no files do not touch them).
- Spawn queue: `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 6 rows (all feature/feature+bypass, 0 bug, 0 refactor). Bug lane share is 4 of 15 (26%, within target band 20-30%).
- Box pick: `sudo -u <DEV_USER> env BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> sat preferred for both rows.

### 3.2 Red controls run on `1663c828b`

| row | command (repo untouched) | output on `1663c828b` | output with the fix | who |
|---|---|---|---|---|
| 01 | `cd csi-spl-orc && sudo -u <DEV_USER> env LANE_MIX_KIND=complex_coding timeout 60 ./run -a do_spl_lane_mix` | Exits 124 after 60 s with no `pick=` line. (`time` without timeout takes 107.5 s on sat, 86 s on <box2>, reading 2,953 `out.s2` files across 6 passes) | Exits 0 printing `pick=<vendor> launcher=... kind=complex_coding reason=...` well inside 60 s (< 15 s loaded, < 5 s idle). Suite: 114 PASS / 0 FAIL. Counting test verifies O(1) process spawns across N vs 10×N files | reviewer c-408 / editor a-577 |
| 02 | `cd csi-spl-orc && sudo -u <DEV_USER> env -u SPOOL_ROOT ./run -a do_spl_security_round_queue` | `spl-security-round-queue.func.sh: line 49: SPOOL_ROOT: unbound variable`, rc 1 | Exits 0 printing `switch: unset (no cnf key) ... -> off, no ask, no calendar event` (or queues cleanly if enabled). Suite: 23 PASS / 0 FAIL | reviewer c-408 / editor a-577 |

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
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
| Placer band pick jq argument list too long | SPL-4156 | Fixed on trunk in `94fb1d64f`. |
| Box quota parser reset date calculation | SPL-4155 | Live lane (`wip`). |
| Done-claim check reading box-local clones of other orgs | SPL-3885 | Live lane (`wip`). |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gate checks | Out of scope by brief (labelled `bug` but not defects). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (defect fixes with red controls run on `1663c828b`) |
| vendor | claude 2 |
| box (preferred) | sat 2 |
| batches | 1 (batch 1 has 2 parallel lanes: lane A Row 01, lane B Row 02) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `a-577@sat` (agy, `specs_and_docs`).
- **Reviewer:** `c-408@<box2>` (claude, cross-vendor reviewer, rulebook 2.7.2, brief `c002-bug-round-10-claude-reviewer`).
- **Review history:**
  - 2026-10-29 03:05Z: Editor landed v0.1 draft (`2780cc6e8`, `csi-spl-doc/doc/md/bug-round-10-plan.md`, SPL-4152).
  - 2026-10-29 03:32Z: Reviewer `c-408@<box2>` verdict `FAIL` on v0.1 (msg `a02cf000`, findings W1, W2, W3).
  - 2026-10-29 03:33Z: Dispatcher `c-002@sat` requested v0.2 addressing W1, W2, W3 (msg `71099207`).
  - 2026-10-29 03:45Z: Editor landed v0.2 draft (`4eabb2da0`, `csi-spl-doc/doc/md/bug-round-10-plan.md`, SPL-4152) folding reviewer findings: Row 01 (`do_spl_lane_mix` latency timeout in spawn-fill), Row 02 (`do_spl_security_round_queue` unbound SPOOL_ROOT in Friday cron), 16e flake attribution to `c6463e496` (SPL-4135), and t1 measurement end time `2026-10-29T01:57:32Z`.
  - 2026-10-29 03:59Z: Reviewer `c-408@<box2>` verdict `FAIL` on v0.2 (msg `f237e0db`, findings W4, W5, W6, W7, and minor row 02 line 49 evidence correction).
  - 2026-10-29 04:00Z: Dispatcher `c-002@sat` requested v0.3 addressing W4-W7 (msg `2e7a7eba`).
  - 2026-10-29 04:05Z: Editor landed v0.3 draft (`b4ad49dc6`, `csi-spl-doc/doc/md/bug-round-10-plan.md`, SPL-4152) folding reviewer findings: Row 01 fix scope updated to single grep -l pass preserving 6h/7d windows; target set to exit 0 well inside 60 s (< 15 s loaded, < 5 s idle) + process counting test; suite counts corrected to 114 PASS lane-mix and 23 PASS security-round; rulebook 2.11.4 citation removed (2 parallel lanes by planner choice over disjoint files); row 02 line 49 template path and spl_asks_init evidence corrected.
  - 2026-10-29 04:10Z: Reviewer `c-408@<box2>` re-review verdict `PASS` on v0.3 `b4ad49dc6` (msg `b4a23bd4`, `1e8382a8`).
  - 2026-10-29 04:12Z: Dispatcher `c-002@sat` accepted bug round 10 plan v1.0 (msg `eca3d0b4`) and queued Row 01 (`claude:c002-b10-01-lane-mix-wd-timeout`, ask `b0311e2a`) and Row 02 (`claude:c002-b10-02-security-round-spool-root`, ask `36b0b0d5`), class bug.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | a-577@sat | **v1.0** (accepted) |
| Reviewer | c-408@<box2> | **PASS** (signed v1.0 consensus on `b4ad49dc6`) |
