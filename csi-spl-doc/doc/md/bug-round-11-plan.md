# Bug-fix round 11 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5790 (this plan).  
Discussion: t1 #spool-hub-bugs `e1139a1e-51f0-46dc-8077-69a072667513` ("Bug round 11", opener msg 3b135b10). Re-run of the round on owner HUM-10's poll a019438e answer (msg 985c2fb0): a fresh planner and a new issue. The 11-14 run (SPL-5511, SPL-5521) was dissed; nothing of its draft is reused here.  
Round focus: **`do_spl_review_go` holds a valid PASS** in two ways that are still open on `origin/master`: rc 7 when the author lives on another box (row 01), and rc 4 when an owner-go keyword is only part of a longer name, such as a test file named `apply-...` (row 02).  
Round size: at most 10 items (rulebook 1.1); this round has 2.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (round size, push caps, bands, R1-R16), linked here, not copied.  
Model: [bug-round-10-plan.md](bug-round-10-plan.md) (same shape, same 5 sources).

**Status: v0.1 draft** (for the panel; not signed).  
Editor: **c-964@sat** (claude, `specs_and_docs`).  
Panel: requested from the dispatch holder (rulebook 3.2), section 8.

**One sha:** every count below is measured on **`d0137722c`** (`origin/master`, committed 2026-11-17T10:21:58Z), on sat, between 10:41Z and 10:50Z. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else. Each row has a **red control** that fails on `d0137722c` and passes after the fix (section 3.2).
- **Paths** are repo-relative. Line numbers are as of `d0137722c`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Both rows are bash tooling in `csi-spl-orc` (`simple_coding`): coding vendor claude. Mistral writes no code.
- **Subject** (R6 reads it): `fix(b11-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** rulebook 2.7.4 (box-free form in the commit body).

---

## 2. Where the rows come from (measured on `d0137722c`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 and csitea since 2026-10-29** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%') from messages where ts >= '2026-10-29' and ts <= '2026-11-17T10:41:19Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query`, then all 94 defect-worded bodies of t1 and csitea were read, and for each one about the spool hub its topic was read after the post (later messages, SPL keys, the last message) | t1 2747 human posts (39 defect-worded, 1932 `[spool-probe]`); csitea 1415 (55 defect-worded) | 81 of the 94 are polls, orders ("fix the top 10 errors") or customer delivery work in csitea (the release tool, runbooks): not spool hub defects. The 13 about the spool hub are all answered: 11 live on dev and prd or landed (725b45b2 SPL-4731, 3b5c61d9 SPL-4901, 2c930e94 SPL-4925 "it seems to work now", 1966d7e6 SPL-5232/5268, cabd6bb9 SPL-5396, a9b0af6b SPL-5529, 3d660b43 roles live as 9.1.3, e50dde2b SPL-5126, 8c72779d SPL-4728, 042d5a05 a queued alarm row, 8e20513c answered as no blocker); 13772c97 (an agent writes a note for the owner) is a planned feature, SPL-5717; 414056d7 (Google Calendar) is SPL-5726, queued, with SPL-5782 landed on `d0137722c` itself. **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 100 runs 2026-11-16T07:21:48Z .. 2026-11-17T10:22:30Z: 73 success, 18 cancelled, 6 failure, 1 timeout, 2 running. Every timeout headroom line `ok` (highest p90: 56 %) | 7 failed runs, 6 first-red signatures, all single sightings except two: (a) `desk marks != code` twice on the same sha `8ce1c523`, green from the next sha (fixed on trunk); (b) `hygiene-killed-cleanup.tst.sh` "TERMed in its sweep 8 times, 1 did not end clean" twice, see section 5. `TestAgentRunPresenceFrames`, `TestGCS` and a wui e2e 7/8 45 min timeout are seen once each (R11 assigns a flake lane on the 3rd sighting). Every failed job has a later green (05791365, 09:45:29Z). **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" d0137722c -- "$d" \| wc -l; done`, then a `diff` of the sorted lines against `1663c828b` (round 10's sha) | 245 lines (api 197, wui 17, orc 10, iac 21, utl 0). `csi-spl-wui/tests/e2e/ci-skip.txt`: 4 entries (4 on `1663c828b`) | Every new line since `1663c828b` is an environment guard (Postgres only, root, a missing tool), plus one Rust iterator `.skip(1)` in `csi-spl-orc/src/rust/spl-cmd-guard/src/main.rs:108`, not a test. **0 rows.** |
| **4. GC notes and box alarms, last 24 h** | `SPOOL_ROOT=/var/spool-hub spool tail --task gc-sat`, rows from 2026-11-16T10:41Z | 103 notes: 47 GC cycles, each `0 restarted`; 3 cycles with `1 close asked`; 0 box alarms | Routine (role seats scan-only, lanes waiting on owner polls, share lines). **0 rows.** |
| **5. Open defect issues, the two known rows, the review-go log** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select number, status, assignee, labels, title from issues where tenant_id='t1' and deleted_at is null and archived_at is null and status in ('eval','todo','wip','blocked','onhold','qas') and kind='issue' and ('bug' = any(labels) or title ~* '(bug:\|broken\|does not\|not work\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|flake)')" ./run -a do_spl_db_query`; `/var/spool-hub/dispatch/automation.log` (review-go lines from 2026-11-10); the two known rows re-run on `d0137722c` (section 3.2) | 334 open issues; 16 labelled `bug`; 33 rows matched. review-go since 11-10: 736 checks: rc 0 368, rc 1 95, rc 2 92, rc 3 60, rc 4 29, rc 5 11, rc 6 45, rc 7 36 | Open bug issues are owned by lanes or programs (section 6). The four unassigned "Event type" issues (SPL-5746, 5751, 5752, 5763) belong to the owner's event-log order (t1 955ab0bd, fixes F5 and F9; F5 is live lane c-875). **Both known rows reproduce on `d0137722c`: 2 rows.** The rc 2 holds are section 4. |

---

## 3. The 2 rows

| # | defect | evidence | sites file:line | red control (fails on `d0137722c`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b11-01-orc-review-go-author-other-box)` | `do_spl_review_go` holds a valid cross-vendor PASS with rc 7 "author X has no brief on this box" whenever the author lane runs on another box and the reviewer brief names it only as `Author: <id>@<box> (<vendor>)`. The holder then checks the author by hand and sends the GO. | (1) Replayed on `d0137722c`: a copy of review msg d3a83a98 (g-524 PASS 98a31982c, SPL-5507, author c-490 on box 2), new msg id `00b11c01-...`, through `REVIEW_GO_MAX_AGE=99999 REVIEW_GO_MSG=<copy> DRY_RUN=1 ./run -a do_spl_review_go` -> `PLAN HOLD ... (rc 7): author c-490 has no brief on this box sat (author box <box2>; not .../c-490/lifetime/brief.md, an Author brief: line in .../hand-<box2>-c002-spl5507-dochub-client-grok-reviewer.md or the lane map): not verified`, exit 7. (2) The author's placement brief is on this box (`dispatch/briefs/hand-<box2>-c002-dochub-shared-client-v1v2-fold.md`) but names neither the review branch `review/c-490-shared-client` nor the sha (`grep -c -E 'c-490-shared-client\|98a3198'` -> 0), so `_spl_review_go_tied` refuses it. The reviewer brief carries `Author: c-490@<box2> (claude)` (line 9) and no `Author brief:` line. (3) automation.log: 36 rc 7 holds 11-11..11-15 (2, 1, 8, 7, 18 per day), every one "author X has no brief on this box"; 0 on 11-16 and 11-17 so far (fewer cross-box reviews, not a fix: no commit since 11-15 touches `_spl_review_go_abrief`). | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:456-468` (`_spl_review_go_abrief`), `:475-483` (`_spl_review_go_tied`), `:674-677` (the rc 7 hold); test `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` | A new case in `spl-review-go.tst.sh`: author `c-X@boxb`, reviewer brief with `Author: c-X@boxb (claude)` and no `Author brief:` line, a lane-map stub row `c-X@boxb` on branch `c-X-<slug>`, and `dispatch/briefs/<slug>.md` that names neither the review branch nor the sha. On `d0137722c` it ends rc 7 (the replay above is the same path). PASS requires: that case GOes (rc 0 at [7]); a control where the lane-map row is another lane of the same id (a rotated or re-tasked seat, R7 c-972 N1/W1) still ends rc 7; the whole suite green. | Give the author the reach SPL-4427 gave the reviewer (`_spl_review_go_brief`, `:229-246`): when the author box is not this box, accept the author lane's OWN placement brief, `dispatch/briefs/<slug>.md` where the lane map has a row `<author>@<abox>` whose branch is `<author>-<slug>`, as tied to the review, besides the existing branch/sha tie. Never an untied brief of another lane of the same id. Trace first and name in the report which read fails today (file:line). Docs: spec 157 rule 1 (author brief), or `Docs: none (<why>)`. | sat | claude | grok if `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` picks a box at row time; else a claude waiver seat (c-001 ruling 5fb1bdab: grok weekly 99 % on both boxes, measured 10:48Z) | simple_coding | 1 |
| 02 `fix(b11-02-orc-review-go-keyword-inside-a-name)` | The owner-go scan `_spl_review_go_owner_go` matches `\bapply\b` (and the second list) inside a longer name: `apply-gh-runner-cpu-budget`, a test file name in a list of orc tests, reads as the keyword `apply`, and the PASS is held with rc 4. | (1) Run on `d0137722c`: source `spl-review-go.func.sh` and call `_spl_review_go_owner_go <fixture> c-002` on `dispatch/briefs/c002-bug-review-go-fixture-c710-brief.md` (c-710's r58-07 brief; line 19 holds `` `apply-gh-runner-cpu-budget` ``) -> rc 1, `the author brief names owner-go keyword 'apply' and has no Owner-go: line`. The same call with the file before SPL-5670 (`git show 0489c4336^:...`) gives the same rc 1: SPL-5670 and SPL-5696 did not cover this form. (2) The other known cases are fixed or not a defect: the SPL-5432 author brief (`c002-bug-quota-env-knob-pick-hop-5432-followups.md`, "billing") -> rc 0 on `d0137722c`; the SPL-5506 author brief is not on this box (the 9a498cd4 hold), and `hand-sat-c001-tf-002-billing-grants-apply.md` is real terraform apply work (rc 1 is right). (3) automation.log: 29 rc 4 holds 11-11..11-16; last 2026-11-16T07:20:16Z, before SPL-5696 landed (09:35Z). The suite has no case of a keyword inside a hyphenated name (`grep -n -E 'apply-\|-apply' spl-review-go.tst.sh` -> only `do-tf-apply`, line 236). | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:627-628` (`_spl_review_go_owner_go`, the two keyword greps); test `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` | `_spl_review_go_owner_go` on a fixture with line 19 of the c-710 brief (copied into the test, the brief file is swept) under a `## Do` heading. On `d0137722c`: rc 1, keyword `apply`. PASS requires: rc 0 for that fixture; still rc 1 for a `## Do` step "run `terraform apply` for step 016" and for every keyword of test 4 (`DRY_RUN=0`, `PROBE_PRD_GO`, `billing`, `service account key`, `/etc/hosts`, `do-tf-apply`), alone; the whole suite green. | In `:627-628` match a bare word only where it is not part of a longer name: no `-`, `_`, `.` or `/` joined to `apply`, `IAM` or `billing` on either side. Keep `do-tf-apply`, `do-provision`, `DRY_RUN=0`, `ENV=prd`, `PROBE_PRD_GO`, `service account key` and `/etc/` as they are. Docs: spec 157 rule 1 [4] keyword list, or `Docs: none (<why>)`. | sat | claude | as row 01 | simple_coding | 2 (after row 01 lands: same files) |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01. Changes `csi-spl-orc/src/bash/run/spl-review-go.func.sh` and `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` only.
- **Batch 2:** row 02, the same two files, so it starts after row 01 is on trunk (R1, R16: placed within 30 min of that land).
- **How the files were checked (2026-11-17, from sat):**
  - 10:47:19Z `lane-map.sh` (all boxes): 35 live rows, no lane on review-go or the iac hygiene tests.
  - 10:48:43Z `lane-map.sh --check csi-spl-doc/doc/md/bug-round-11-plan.md,csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,... --agent c-964` -> exit 4: no live lane lists these files; 6 lanes on box 2 record no files (c-714 blog post, c-875 event-log F5, c-888 cost allocation, c-924 and c-927 csitea seats, c-966 spec 143 B-5). None of their brief titles names review-go; the orchestrator re-runs the check before each spawn (R3), and an exit 4 lane is asked first.
  - 10:47:29Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 3 rows (two R7 reviewer seats, one agy language review); none touches these files.
  - Origin review branches that touch these files (`git diff --name-only origin/master...<branch>`): `review/c003-bug-review-go-hand-box-brief`, `review/c003-bug-review-go-local-sha-quoted-keyword`, `review/c002-bug-review-go-owner-go-verbatim-section`, `review/c002-bug-hygiene-kill-test-term-grace` (the landed SPL-5645, 5670, 5696 and 5731 lanes), and an old `review/c-364-SPL-4630` (11-08). No open lane.

### 3.2 Red controls run on `d0137722c`

| row | command (repo untouched) | output on `d0137722c` | output with the fix | who |
|---|---|---|---|---|
| 01 | `cd csi-spl-orc && REVIEW_GO_MAX_AGE=99999 REVIEW_GO_MSG=<copy of review msg d3a83a98 with a new msg id> DRY_RUN=1 ./run -a do_spl_review_go` (SPOOL_ROOT=/var/spool-hub, as the agent user, on sat) | `PLAN HOLD msg 00b11c01-... (rc 7): author c-490 has no brief on this box sat (author box <box2>; not /var/spool-hub/c-490/lifetime/brief.md, an Author brief: line in .../hand-<box2>-c002-spl5507-dochub-client-grok-reviewer.md or the lane map): not verified`, exit 7, 2.7 s | the new suite case GOes (rc 0); the rotated-seat control stays rc 7; suite green. The live replay cannot turn green now: c-490 is retired, so its lane-map row is gone. The suite case is the control | editor c-964 |
| 02 | `do_log(){ :; }; source csi-spl-orc/src/bash/run/spl-review-go.func.sh; _spl_review_go_owner_go /var/spool-hub/dispatch/briefs/c002-bug-review-go-fixture-c710-brief.md c-002` | rc 1, `the author brief names owner-go keyword 'apply' and has no Owner-go: line` (the same on `0489c4336^`) | rc 0; the `terraform apply` step and the test 4 keywords stay rc 1; suite green | editor c-964 |

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| review-go rc 2 "reviewer (claude) shares the vendor of author" | `awk '$2=="review-go" && $1>="2026-11-15"' /var/spool-hub/dispatch/automation.log \| grep ' rc=2 '` | 43 holds since 11-15 | Same vendor is refused by design (rulebook 2.7.2). The claude waiver seat (c-001 ruling 5fb1bdab, grok weekly 99 % on both boxes) is a ruling the cron does not read, so the holder sends those GOs by hand. Changing that is a rule change for the orchestrator, not a defect fix; it is reported to c-001 with this plan. |
| review-go rc 3 / rc 6 for a reviewer on another box | same log, rc 3 and rc 6 | rc 3: 8 "reviewer ...@<box2> runs on box <box2>: no brief for it on this box"; rc 6: 19 "the reviewer's log is on box <box2>: run the check there (never fetched)" | By design: a log on another box is never fetched (spec 157, rulebook 2.7.4); the check prints the command for that box. |
| The SPL-5432 "billing" hold (30bbc359) | `_spl_review_go_owner_go` on `c002-bug-quota-env-knob-pick-hop-5432-followups.md` | rc 0 on `d0137722c` | Fixed by SPL-5670 / SPL-5696. |

---

## 5. Not reproduced

| candidate | command | result |
|---|---|---|
| `hygiene-killed-cleanup.tst.sh`: `hygiene-box-users-allow.tst.sh` "round 2: rc=137, KILLed: still running 30 s after the TERM" | `gh api repos/csitea/csi-spl/actions/jobs/133907449322/logs` (run 44043493365, sha 01de192f, which holds the SPL-5731 fix a39d3cd86); then `cd csi-spl-iac/src/bash/tests && KT_ROUNDS=40 bash hygiene-killed-cleanup.tst.sh` on sat, load 20..26 on 16 CPUs | CI: 1 sighting after the SPL-5731 fix (and 1 before it, run 43823538144, the case that fix was for). Local: 120 TERMs of 120 ended clean, rc 0, 2 m 31 s. One sighting after the fix: below the R11 flake threshold (a lane on the 3rd). The trunk-red watch (R11.3) counts it from here. |
| `TestAgentRunPresenceFrames`, `TestGCS`, wui e2e 7/8 timeout | `do_report_ci_gate` above | 1 sighting each in 100 runs; later runs green. Below the R11 threshold. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| The issue closer leaves two `Closes:` keys open (SPL-5783) | c-966@sat, c-945@sat | Live lanes. |
| Event-type issues SPL-5745, 5746, 5751, 5752, 5763 | owner's event-log order, t1 955ab0bd (F5: c-875) | F5 live; the rest in that program. |
| Google Calendar connection (414056d7) | SPL-5726 (queued), SPL-5782 landed on `d0137722c` | In that topic. |
| Box CPU overload (SPL-5698) | c-570 | Live lane. |
| Topic seat's own post missing from its inbox (SPL-5609), pre-push orc-features timeout (SPL-5411), dev-before-prd gate for prd-only steps (SPL-5368), placer duplicate lane (SPL-5104), phone Back (SPL-5232, SPL-5254) | dispatch desk (c-002), `wip` / `onhold` | Placed by the holder; not re-planned here. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gates | Labelled `bug`, not defects (as in round 10). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (defect fixes, red controls run on `d0137722c`) |
| vendor | claude 2 |
| R7 | grok when it picks, else a claude waiver seat (both rows) |
| box (preferred) | sat 2 |
| batches | 2 (row 01, then row 02: same files) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-964@sat (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-e1139a1e`: at least one non-claude seat. agy is limited until 2026-11-20T23:00Z and grok is on hold (weekly 99 % on both boxes), so a mistral doc seat is the cross-vendor one available today (a plan panel is a doc seat; c-001 ruling cbada223).
- **Review history:**
  - 2026-11-17: editor pushed v0.1 to `review/c002-bug-round-11-planner-r2`.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-964@sat | v0.1 draft |
| Panel | (placed by the holder) | pending |
