# Bug-fix round 9 - plan (1 action)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 9 focus: **`do_spl_done_claim_check` false alarm on unlanded review branch shas from retired reviewers**; plus candidate measurements from the dispatcher's 2026-10-24 list (e2e shard pack unit test, test-agent-winch under full pre-push, ask close/ack exit 3, and spawn bypass class restriction).  
Concurrency: rulebook §1.1 asks for 2 row lanes in parallel: batch 1 is lane A (Row 01) (section 3.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-3150.  
Model: [bug-round-8-plan.md](bug-round-8-plan.md) (same shape, same 5 sources).

**Status: v0.1, draft** (editor a-304@<box2>).  
Editor: **a-304@<box2>** (agy, `specs_and_docs`).  
Reviewer: one cross-vendor seat (rulebook 2.7.2), asked of the dispatcher: claude (or mistral). The reviewer signs v1.0 in its own commit.

**One sha:** every count below is measured on **`e8283427d`** (`origin/master` at the start, 2026-10-24T01:26:18Z / 03:26:18 CEST), on <box2> unless a row says sat. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else. Each row has a **red control**: a test that fails on `e8283427d` and passes after the fix. Section 3.2 shows each red control's run on `e8283427d`.
- **Paths** are repo-relative. Line numbers are as of `e8283427d`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Mistral writes no code. `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` -> `pick=grok`, but grok is at its weekly limit (<box2> `gc.log`: `FALLBACK ... grok -> claude: grok weekly limit`). So the coding vendor is claude.
- **Subject** (R6 reads it): `fix(b09-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).

---

## 2. Where the rows come from (measured on `e8283427d`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-22** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-22' and from_id like 'HUM%'" ./run -a do_spl_db_query`. Then non-probe bodies since round 8's read (`ts >= '2026-10-24T00:06Z'`) were read | 449 human posts, 2 defect-worded, 370 `[spool-probe]` lines (since 2026-10-22). Round 8 counted 425 posts and 2 defect-worded | 0 non-probe posts since 00:06Z. None of the posts describes a new defect. **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env GH_TOKEN="$(gh auth token)" CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 200 runs 2026-10-22T19:08:16Z .. 2026-10-24T01:35:50Z: 132 success, 48 cancelled, 18 failure, 2 running. Every timeout headroom line is `ok` | All 18 failure runs exhibit the known flake in `check-pre-push-baseline.tst.sh` case 9e (SPL-3128, Go module index cache miss under slow runners), owned by standing CI seat `c-296` and fixed in `cf4872297`. 0 new defects. **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" e8283427d -- "$d" \| wc -l; done`. `diff` of the sorted grep (`-h`) against `b9a9aea12` | 187 lines (api 140, wui 17, orc 9, iac 21, utl 0), identical to round 8. `diff` -> empty (rc 0): 0 new skip lines. 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. 0 local flakes. |
| **4. GC notes and box alarms, last 24 h** | `awk '$1 >= "2026-10-23T03:00"' /var/spool-hub/dispatch/gc/gc.log \| awk '{print $2}' \| sort \| uniq -c` on <box2> | <box2>: 48 START, 44 DONE, 5 END-STALE, 21 FALLBACK, 10 POKE, 4 REFUSED. `spool tail --task gc-sat` from <box2> -> `no messages visible to this box`. `spool tail --task gc-<box2>` -> latest post 2026-10-22T11:01Z | Every END-STALE was earlier on 2026-10-23 (last one 16:00:04Z). Since 16:00Z, 0 END-STALE passes: all passes ended DONE. The FALLBACK lines are the hourly grok weekly limit fallback to claude. The REFUSED lines are the GC refusing a wrong `begin`, as designed. **0 rows.** |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3 -I` | 346 issues, 4 labelled `bug`; 31 with a defect word in the title | The `bug` ones are SPL-1945 (blocked, needs owner) and SPL-455 / SPL-450 / SPL-435 (out of scope by brief). The only new issues created since 00:00Z are SPL-3144 (round 8 reviewer), SPL-3150 (this plan), SPL-3151 (round 8 row 01). Candidate (e) from the dispatcher **reproduces** (Row 01); candidates (a) Part 2, (b), (c), and (d) are measured and not a bug (section 4); candidate (a) Part 1 is measured and not reproduced (section 5). |

---

## 3. The 1 row

| # | defect | evidence | sites file:line | red control (fails on `e8283427d`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b09-01-orc-done-claim-review-result)` | An R7 review summary result from an agent claiming a review PASS (not a landing) on an unlanded review branch (`origin/review/*`) is falsely flagged by `do_spl_done_claim_check` as `sha <sha> not in the repository` if the reviewer retires before the check and the reviewed branch has not yet landed on master. | (1) Dispatcher note: `a-709`'s R7 review result `4c4de307` (task `6b9d6c38`, 01:16:48Z) was flagged with "sha eb247d11c not in the repository" on `origin/master` of csi-spl and csi-rel (note `68215ba2`). `eb247d11c` was the reviewed sha on `origin/review/r19-04-wui-decompose-message-card-pointer` (authored by live lane `c-906`), and `a-709` claimed a review PASS, not a landing. (2) `a-709` retired immediately. `spl_done_claim_seats` missed `a-709` because its latest branch was `a-709-rotate`; `seat()` in `spl-done-claim-check.func.sh:328` strips `-[a-z0-9]{8,}` and other suffixes, but does not strip `-rotate(-[0-9]+)?`. (3) `spl_done_claim_r7` (:466-480) parses only the first non-blank line (`head -n 1`). Multi-row summary results whose line 1 is `R7 reviews for round <N> completed:` are rejected (rc 1), missing the review lines that follow. (4) `spl_done_claim_unparked` (:560-575) checks whether a review branch without an `<id>-` prefix belongs to a live seat by matching sender `${4:-}` against `$ids` (`$2`, live seats file). When the reviewer has retired, it fails `grep -qxFf "$2" <<<"$ids"` even though the branch is an active `origin/review/*` branch and its author is active. (5) Empirical test on `e8283427d`: message `4c4de307` outputs `would-alert 4c4de307-a8bd-4775-bebb-4f40f0980556 a-709 eb247d11c` and triggers note `sha eb247d11c not in the repository`. | `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh:317,325-335,466-480,560-575`; test `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh` | In `spl-done-claim-check.tst.sh`: Create a fixture where a reviewer agent has retired (leaving `<id>-rotate`), and its review result message names a commit on an active `origin/review/<topic>` branch whose author is live in `registry.tsv`. Today on `e8283427d`: `spl_done_claim_body` outputs `would-alert ... <sha>` and sends note `sha <sha> not in the repository`. PASS requires: recognized as `seat` / `pending`, no alert note sent. | In `spl-done-claim-check.func.sh`: (a) In `seat()`, strip `-rotate(-[0-9]+)?` suffix from branch names alongside other suffixes (`-[a-z0-9]{8,}`, etc.) so retired reviewer branches map to their base role/seat. (b) In `spl_done_claim_r7`, search all non-blank lines for `^review: [acgmq]-[0-9]{3,}` instead of checking only line 1 (`head -n 1`), so multi-line review summaries are recognized as R7 review results. (c) In `spl_done_claim_unparked`, resolve the author from `origin/review/<author>-*` or look up active review lanes in `registry.tsv` / `lane-map` before falling back to sender; treat an active `origin/review/*` branch as parked/in-flight rather than checking only whether the reviewer is in `$2` (live seats). Add test case to `spl-done-claim-check.tst.sh`. Docs: `Docs: none (done-claim verification hardening)`. | <box2> | claude | agy (cross-vendor, rulebook 2.7.2) | simple_coding | 1 (lane A) |

### 3.1 Files (R1) and lanes

- **Batch 1, lane A:** Row 01. Changes `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh` and `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh` only.
- `lane-map.sh --check csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh,csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh,csi-spl-doc/doc/md/bug-round-9-plan.md --agent a-304` -> exit 4: `no live lane lists` any of them, and 10 live lanes record no files (rotation seats, s107-v2, wui-decompose; none touches these files).
- `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 7 rows: 2 refactor, 5 feature, 0 bug. None names `spl-done-claim-check`.
- Box: `sudo -u <DEV_USER> env BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `pick=<box2>` (least past its band).

### 3.2 Red controls run on `e8283427d`

Inputs: message `4c4de307-a8bd-4775-bebb-4f40f0980556` from reviewer `a-709` citing reviewed sha `eb247d11c` on `origin/review/r19-04-wui-decompose-message-card-pointer`.

| row | command (scratch, repo untouched) | output on `e8283427d` | output with the fix (scratch copy of `spl-done-claim-check.func.sh`) | who |
|---|---|---|---|---|
| 01 | `cd csi-spl-orc && sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub MSG_ID=4c4de307-a8bd-4775-bebb-4f40f0980556 ./run -a do_spl_done_claim_check` | `would-alert 4c4de307-a8bd-4775-bebb-4f40f0980556 a-709 eb247d11c`, note `sha eb247d11c not in the repository` sent (false alarm on unlanded review branch) | `pending 4c4de307-a8bd-4775-bebb-4f40f0980556 a-709 eb247d11c (branch origin/review/r19-04-wui-decompose-message-card-pointer)`, 0 notes sent, rc 0 | editor |

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| (a) Part 2: `csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs` failure in a-709 | `cd csi-spl-wui && node tests/unit/e2e-shard-pack.test.mjs` (run 10 times across sat and <box2>, as `<HARNESS_USER>` and `<DEV_USER>`) | `e2e-shard-pack: all passed`, rc 0 in every run | **Not a persistent bug.** In a-709's session (step 184), `e2e-shard-weights.txt` was temporarily empty or being written during background mock-serve / checkout, causing `RUNNER --list` to fall back to round-robin allocation. When re-run isolated (steps 189, 199), it passed immediately, and full unit test suite passed (427/427). |
| (b) `test-agent-winch.sh` on master & why rdb/api runs orc feature tests | `cd csi-spl-orc && ./src/bash/features/spawn-agents/tests/test-agent-winch.sh` on `origin/master` | 6 passed, rc 0 | **By design and environment-specific.** (1) `test-agent-winch.sh` passes on `origin/master` (skipped cleanly when run as `<DEV_USER>` due to no distinct agent user). (2) `PRE_PUSH_TIER=full` (mandated for store/migration touches per rulebook) selects `_ppf_all` in `_ppf_parts` (`check-pre-push.func.sh:317`), which runs `_pp_part_orc_features` across all feature directories by design. (3) The failure in a-433 occurred because `_pp_part_orc_features` created `TMPDIR` with `mktemp -d` (mode 0700 owned by `<HARNESS_USER>`), preventing `su - <DEV_USER>` inside `test-agent-winch.sh` from writing to the probe log. Not a bug in `test-agent-winch.sh` or master. |
| (c) `do_spl_ask_close` and `do_spl_ask_ack` exit 3 | `spl-ask-close.func.sh:6-7` and `spl-ask-ack.func.sh:29` | `spl-ask-close.func.sh:6-7` documents `rc 3: ask already closed`; `spl-ask-ack.func.sh:29` prints `WARN ask <id> is already done by <closed_by>: <reason>` and exits 3 | **By design.** Exit 3 is the explicitly documented return code for an ask that is already completed/closed in the journal. Both asks `5bf4a841` and `02eb8f4e` were already completed when called; the tool logged the warning explaining that the ask was already done. The exit code communicates state with an explicit line, not an undocumented failure. |
| (d) `do_spl_spawn_enqueue` refuses `SPAWN_BYPASS` unless `SPAWN_CLASS=feature` | `fleet-rules-index.md:52` and `spl-spawn-enqueue.func.sh:78` | Line 78 enforces `[[ "$SPAWN_CLASS" == "feature" ]] \|\| { do_log "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only"; return 1; }` | **By design.** Rule text `fleet-rules-index.md:52` explicitly states: "Bypass applies only to new features outside feature bands. Review seats and bug fixes run under their own bands." Review seats for bug rounds run with `SPAWN_CLASS=bug`, which has queue priority over features in `askClassRank` and is currently under band (12-13% < 20-30%). Both the action and rule text agree; passing `SPAWN_BYPASS=994f2257` to a bug row was operator error, not a defect in code or rules. |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| `e2e-shard-pack.test.mjs` failure (exit 1) in a-709 | Ran `node tests/unit/e2e-shard-pack.test.mjs` repeatedly on sat and <box2> under varying user accounts (`<HARNESS_USER>`, `<DEV_USER>`), with and without background load | Cannot reproduce failure: `e2e-shard-pack: all passed` (rc 0) in all attempts. Root cause identified in a-709 transcript as transient missing `e2e-shard-weights.txt` during concurrent checkout. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| SPL-3128: Pre-push base tree Go cache case 9e | c-296@<box2> (standing CI seat) | Fixed on trunk in `cf4872297`. |
| Bug round 8 row b08-01: review-line session ownership | c-565 / a-819@<box2> (SPL-3151) | Fixed on trunk in `4cfff5c58`. |
| SPL-1945: secret rotation plan | blocked, needs owner | Out of scope for bug round. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gate checks | Out of scope by brief (label `bug` but not defects). |
| `do_spl_lane_mix` picks grok for `simple_coding` while grok is at weekly limit | the dispatcher / orchestrator | Handled via fallback to claude in placement. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 (defect fix with red control run on `e8283427d`) |
| vendor | claude 1 |
| box (preferred) | <box2> 1 |
| batches | 1 (batch 1: Row 01) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `a-304@<box2>` (agy, `specs_and_docs`).
- **Reviewer:** one cross-vendor seat (claude seat, rulebook 2.7.2, asked of dispatcher `c-002@sat`). The reviewer signs v1.0 in its own commit after this landing.
- **Review history:**
  - 2026-10-24 01:45Z: Editor landed v0.1 draft (`csi-spl-doc/doc/md/bug-round-9-plan.md`, SPL-3150).

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | a-304@<box2> | **v0.1 draft** |
| Reviewer | pending assignment | pending review |
