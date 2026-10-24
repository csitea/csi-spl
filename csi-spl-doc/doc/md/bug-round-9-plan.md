# Bug-fix round 9 - plan (2 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 9 focus: **`do_spl_done_claim_check` false alarm on unlanded review branch shas from retired reviewers and range-diffs (Row 01)**, and **`do_spl_review_line_check` accepting whole vibe store root (Row 02)**; plus candidate measurements from the dispatcher's 2026-10-24 list (e2e shard pack unit test, test-agent-winch under full pre-push, ask close/ack exit 3, and spawn bypass class restriction).  
Concurrency: rulebook §1.1 asks for 2 row lanes: batch 1 is lane A (Row 01), batch 2 is lane B (Row 02) (section 3.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-3150.  
Model: [bug-round-8-plan.md](bug-round-8-plan.md) (same shape, same 5 sources).

**Status: v1.0** (editor a-304@<box2>).  
Editor: **a-304@<box2>** (agy, `specs_and_docs`).  
Reviewer: **c-962@sat** (claude, cross-vendor reviewer, rulebook 2.7.2, SPL-3168). Reviewer re-review verdict on v0.3 landed on origin/master in `5e161ac45` (`seat-claude.md`): **Verdict: agree** on all rows and items; v1.0 folds all 4 minor text clarifications; reviewer signs v1.0 in its own commit after this landing.

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
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3 -I` | 346 issues, 4 labelled `bug`; 31 with a defect word in the title | The `bug` ones are SPL-1945 (blocked, needs owner) and SPL-455 / SPL-450 / SPL-435 (out of scope by brief). The only new issues created since 00:00Z are SPL-3144 (round 8 reviewer), SPL-3150 (this plan), SPL-3151 (round 8 row 01). Candidate (e) (n=2 sightings) **reproduces** (Row 01); candidate (f) (found during b08-01) **reproduces** (Row 02); candidate (b) reproduces as a gate defect (Section 6); candidates (a) Part 2, (c), and (d) are measured and not a bug (section 4); candidate (a) Part 1 is measured and not reproduced (section 5). |

---

## 3. The 2 rows

| # | defect | evidence | sites file:line | red control (fails on `e8283427d`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b09-01-orc-done-claim-review-result)` | An R7 review result from an agent claiming a review PASS (not a landing) on an unlanded review branch (`origin/review/*`), or a landing report citing a reviewed sha in its range-diff alongside the landed sha, is falsely flagged by `do_spl_done_claim_check` as `sha <sha> not in the repository`. | (1) Dispatcher note (case 1, n=2): `a-709`'s R7 review result `4c4de307` (task `6b9d6c38`, 01:16:48Z) was flagged with "sha eb247d11c not in the repository" on `origin/master` of csi-spl and csi-rel (note `68215ba2`). `eb247d11c` was the reviewed sha on `origin/review/r19-04-wui-decompose-message-card-pointer` (authored by live lane `c-906`), and `a-709` claimed a review PASS, not a landing. (2) Dispatcher note (case 2, n=2): `c-913`'s Live report `12472906` (01:20:41Z) was flagged with "sha 5dd951765 not in the repository" (note `d72ab6e0`). The report names landed sha `57b9da6cf` on master, and in its range-diff names reviewed sha `5dd951765` (`origin/review/s107-v2-t021`). `5dd951765` is on `c-913`'s own review branch; `c-913` retired at 01:22:24Z (2 min after its result). (3) `a-709` retired immediately after review; `spl_done_claim_seats` missed `a-709` because `seat()` (:537-540) does not cover `<id>-rotate[-N]`. (4) `spl_done_claim_r7` (:505-509) checks only line 1 via `awk 'NF { print; exit }'`. (5) `spl_done_claim_shas` (:220-224) extracts all hex tokens without prioritizing explicit landed lines over range-diffs. (6) `spl_done_claim_unparked` (:559-572) does not check live authors for review branches without an `<id>-` prefix when the reviewer has retired. | `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh:220-224,505-509,537-540,559-572`; test `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh` | In `spl-done-claim-check.tst.sh` (scratch fixtures A, A0, R, R2, B, B2, B3, C, and replay of real message `12472906` with `DONE_CLAIM_FETCH=0` / scratch spool). Today on `e8283427d`: replaying `12472906` yields `would-alert ... 5dd951765` (rc 0); fixture table gives `0 landed, 1 seat, 0 pending, 7 would alert`. PASS requires: recognized as `landed` or `pending` / `seat`, 0 alert notes sent, existing test suite green (36 PASS / 0 FAIL). | In `spl-done-claim-check.func.sh`: (a') In `spl_done_claim_seats` (523-552), filter out rows whose branch is `<id>-rotate[-N]` before the slug pick, so a rotated lane keeps its previous slug, and enable the local branch fallback (B rows) for retired ids whose only row is a rotate row. Keep first-line rule in `spl_done_claim_r7` (:505-509) (searching all lines breaks suite case 15 `r7later` and masks false claims). (c') In `spl_done_claim_shas` (:220-224), prioritize explicit landing claims matching `^[list marks]*(landed\|landed sha\|trunk sha)[*_`]*:` before generic `sha:` lines; leave out generic `commit:`, and do not drop range-diff lines (a `Landed:` line hides the body's other shas, which is case B3 — the same risk `sha:` lines already carry since SPL-2338; note this in the fix comment). (d) In `spl_done_claim_unparked` (:559-572), match active review branches against live authors in `registry.tsv` whose worktree branch ends in `-<topic>`. Add test fixtures to `spl-done-claim-check.tst.sh`. Docs: `Docs: none (done-claim verification hardening)`. | <box2> | claude | agy (cross-vendor, rulebook 2.7.2) | simple_coding | 1 (lane A) |
| 02 `fix(b09-02-orc-review-line-vibe-store-root)` | `do_spl_review_line_check` accepts a `log:` path that points to the entire vibe session store root (e.g. `~<HARNESS_USER>/.vibe/logs/session`), reading hundreds of thousands of commands across all sessions of all agents and passing review verification even when the reviewer ID does not match any session owner. | (1) Dispatcher candidate (f) (msg `4518fd10`, found by c-565 msg `02bd2d2e`): `log: m-870@<box2>:~<HARNESS_USER>/.vibe/logs/session` passes with `OK 1 of 1 (251574 commands read)` on master and with b08-01 fix, and passes even with reviewer ID swapped to `m-999`. (2) Spool archive records: message `f325c5d8` (`review: m-870@<box2> mistral PASS f51e54ca8... log: m-870@<box2>:~<HARNESS_USER>/.vibe/logs/session`). (3) Store-root check at lines 213-218 checks direct child directories for `CURRENT` or `journal/`, but vibe sessions live under `session/unified/<uuid>/` (one level deeper). (4) The b08-01 session ownership check (`f2cc74761` on `origin/review/b08-01`, landed on master in `09f5514a5`) looks for `meta.json` in the session dir, but the top-level store root `/session` has no `meta.json`, falling back to command matching. (5) Empirical test on sat (reviewer c-962): `review: m-999@sat mistral PASS ... ran: go test ... \| log: m-999@sat:~<HARNESS_USER>/.vibe/logs/session` reads the whole store (235,296 commands read, 43.9 s, rc 3 `FAIL 0 of 1`: no command matched, but the store root was not refused). | `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:15-17,213-218`; test `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` | In `spl-review-line-check.tst.sh` / reviewer fixture S1-S7: Pass a `log:` path pointing to a vibe session root containing `unified/<uuid>/{CURRENT,meta.json,chunks/,journal/}`. Today on `e8283427d`: exits 0 with `OK 1 of 1` (or reads 235k commands across sessions in 43.9 s). PASS requires: exits 1 with `FATAL log <path> is a session store root (N sessions under it), not a single session directory` (in < 4 s), while single sessions (S3), live journals (S4), compacted journals (S5), and existing suite (33 PASS / 0 FAIL) remain green. | In `spl-review-line-check.func.sh`: (a) Update doc lines 15-17 and store-root detection at lines 213-218 (`_SPL_REVIEW_LINE_PY` in lines 182-250) to inspect child structure for `unified/` or session UUID subdirectories. (b) When a store root is detected, emit `FATAL log <path> is a session store root (N sessions under it), not a single session directory` (accommodating N=1 without saying "multiple sessions"). (c) Ensure leaf session directory or valid single journal/session path is required. Add test case to `spl-review-line-check.tst.sh`. Docs: `Docs: none (review-line verification hardening)`. | <box2> | claude | mistral (cross-vendor, rulebook 2.7.2) | simple_coding | 2 (lane B) |

### 3.1 Files (R1) and lanes

- **Batch 1, lane A:** Row 01. Changes `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh` and `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh` only.
  - `lane-map.sh --check csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh,csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh,csi-spl-doc/doc/md/bug-round-9-plan.md --agent a-304` -> exit 4: `no live lane lists` any of them, and live lanes recording no files do not touch these files.
  - `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 7 rows: 2 refactor, 5 feature, 0 bug. None names `spl-done-claim-check`.
  - Box: `sudo -u <DEV_USER> env BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `pick=<box2>` (least past its band).
- **Batch 2, lane B:** Row 02. Changes `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` and `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` only.
  - Strictly serialised after Batch 1 (R1). Spawns after Row 01 lands and after b08-01 (landed on trunk in `09f5514a5`, SPL-3151) exits clean; Batch 2 rebases onto `09f5514a5`.

### 3.2 Red controls run on `e8283427d`

| row | command (scratch, repo untouched) | output on `e8283427d` | output with the fix (scratch copy of target func) | who |
|---|---|---|---|---|
| 01 | Scratch fixture harness (DRY_RUN=1, DONE_CLAIM_FETCH=0, scratch SPOOL_ROOT, stub sender) replaying real c-913 message `12472906` and fixture cases A, A0, R, R2, B, B2, B3, C | Replaying real message `12472906`: `would-alert 57b9da6cf ff34fdde5 8366ad373 57b9da6cf12130b... 2a7dce85f 5dd951765` (rc 0); fixture table: `0 landed, 1 seat, 0 pending, 7 would alert` | Replaying real message `12472906`: `landed 57b9da6cf ff34fdde5 8366ad373` (rc 0); fixture table: `3 landed, 1 seat, 4 pending, 0 would alert`. Suite: 36 PASS / 0 FAIL | reviewer c-962 / editor a-304 |
| 02 | `cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE_BOX=sat REVIEW_LINE="review: m-999@sat mistral PASS f51e54ca849afb322ff50b1c07fc77b5544f642a ran: go test ... \| log: m-999@sat:~<HARNESS_USER>/.vibe/logs/session" ./run -a do_spl_review_line_check` and scratch fixture S1-S7 | On store root with matching commands rc 0 `OK 1 of 1`; on sat reads whole store (235,296 commands read, 43.9 s, rc 3 `FAIL 0 of 1`: command aged out, but store root accepted). Scratch fixture S1/S2 exit 0 `OK 1 of 1` | `FATAL log <path> is a session store root (N sessions under it), not a single session directory`, rc 1 (3.8 s). S3-S5 green; suite: 33 PASS / 0 FAIL | reviewer c-962 / editor a-304 |

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| (a) Part 2: `csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs` failure in a-709 | `cd csi-spl-wui && node tests/unit/e2e-shard-pack.test.mjs` (run 10 times across sat and <box2>, as `<HARNESS_USER>` and `<DEV_USER>`) | `e2e-shard-pack: all passed`, rc 0 in every run | **Not a persistent bug.** In a-709's session (step 184), `e2e-shard-weights.txt` was temporarily empty or being written during background mock-serve / checkout, causing `RUNNER --list` to fall back to round-robin allocation. When re-run isolated (steps 189, 199), it passed immediately, and full unit test suite passed (427/427). |
| (c) `do_spl_ask_close` and `do_spl_ask_ack` exit 3 | `spl-ask-close.func.sh:5-7` and `spl-ask-ack.func.sh:29-30` | `spl-ask-close.func.sh:5-7` documents `Closing an ask another holder already closed is exit 3 and prints who closed it and why`; `spl-ask-ack.func.sh:29-30` logs `WARN ask <id> is already <state> by <closed_by>: <reason>` and returns 3 | **By design.** Exit 3 is the explicitly documented return code for an ask that is already completed/closed in the journal. Both asks `5bf4a841` and `02eb8f4e` were already completed when called; the tool logged the warning explaining that the ask was already done. The exit code communicates state with an explicit line, not an undocumented failure. (`spl-ask-ack.func.sh` header doc currently omits documenting exit 3, a minor doc omission). |
| (d) `do_spl_spawn_enqueue` refuses `SPAWN_BYPASS` unless `SPAWN_CLASS=feature` | `fleet-rules-index.md:52` and `spl-spawn-enqueue.func.sh:68` | Line 68 enforces `[[ "$flag" != bypass \|\| "$class" == feature ]] \|\| { do_log "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" >&2; return 1; }` | **By design.** Rule text `fleet-rules-index.md:52` states: `SPAWN_BYPASS=<owner msg id>`: a feature outside the bands, ONLY on the owner's explicit ask. Review seats for bug rounds run under `SPAWN_CLASS=bug`, which has queue priority over features in `askClassRank` and operates within its own bands. Both the action and rule text agree; passing `SPAWN_BYPASS` to a bug-class seat is rejected by design under current rules. Per dispatcher decision (c-003@sat msg `455109d9`), owner GO `994f2257` (`994f2257-8ad1-4010-88c8-4f0a16230937`, 2026-10-16: enqueue review seats with `SPAWN_BYPASS=<that id>`) holds for review seats to enqueue with `SPAWN_BYPASS`, while `spl-spawn-enqueue.func.sh:68` applies to every other row; this is documented practice rather than a code defect. |

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
| Bug round 8 row b08-01: review-line session ownership | c-565 / a-819@<box2> (SPL-3151) | Fixed on trunk in `09f5514a5`. Batch 2 rebases onto `09f5514a5`. |
| Pre-push features gate TMPDIR permissions (candidate b) | Standing CI seat / CI gate upkeep (`c-296`) | Reproducible gate defect confirmed by reviewer c-962 and editor: `check-pre-push-features.func.sh:95` creates `TMPDIR=$(mktemp -d /tmp/ppf.XXXXXX)` with mode 0700 owned by `<HARNESS_USER>`, which prevents `test-agent-winch.sh:35` from being traversed by `<DEV_USER>` (`su - dash` / `sudo -i`), causing `2 passed, 2 failed, 0 skipped` (rc 1) under `PRE_PUSH_TIER=full`. Handed to CI seat `c-296` in msg `7ca3b701`; tracked for standing CI gate upkeep rather than a bug round row. |
| SPL-1945: secret rotation plan | blocked, needs owner | Out of scope for bug round. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gate checks | Out of scope by brief (label `bug` but not defects). |
| `do_spl_lane_mix` picks grok for `simple_coding` while grok is at weekly limit | the dispatcher / orchestrator | Handled via fallback to claude in placement. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (defect fixes with red controls run on `e8283427d`) |
| vendor | claude 2 |
| box (preferred) | <box2> 2 |
| batches | 2 (batch 1: Row 01; batch 2: Row 02) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `a-304@<box2>` (agy, `specs_and_docs`).
- **Reviewer:** `c-962@sat` (claude, cross-vendor reviewer, rulebook 2.7.2, SPL-3168). The reviewer signs v1.0 in its own commit after this landing.
- **Review history:**
  - 2026-10-24 01:45Z: Editor landed v0.1 draft (`540f6fd9a`, `csi-spl-doc/doc/md/bug-round-9-plan.md`, SPL-3150).
  - 2026-10-24 01:48Z: Editor landed v0.2 draft (`dbca02ece`, `csi-spl-doc/doc/md/bug-round-9-plan.md`, SPL-3150): expanded Row 01 with second sighting case (author range-diff shas); added Row 02 (Candidate f, vibe store root acceptance) in Batch 2 strictly after Batch 1 and b08-01 exit-clean.
  - 2026-10-24 05:07Z: Reviewer `c-962@sat` verdict on v0.2 landed on origin/master in `6521ca872`, file `csi-spl-doc/doc/md/bug-round-9/seat-claude.md` (SPL-3168).
  - 2026-10-24 10:15Z: Editor landed v0.3 draft (`01f68c6fa`, SPL-3150) folding reviewer findings.
  - 2026-10-24 10:20Z: Reviewer `c-962@sat` re-review verdict landed on origin/master in `5e161ac45` (`seat-claude.md`, SPL-3168): **Verdict: agree** on all rows and items.
  - 2026-10-24 10:28Z: Editor landed v1.0 (`csi-spl-doc/doc/md/bug-round-9-plan.md`, SPL-3150) folding the 4 minor text clarifications (sat store root run, candidate b handed to c-296 in msg 7ca3b701, range-diff line retention for c', and owner go 994f2257 review-seat bypass documented).

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | a-304@<box2> | **v1.0** |
| Reviewer | c-962@sat | **agree** (`5e161ac45`); signing v1.0 |
