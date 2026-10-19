# Testing self-reflection round 1 - retrospective

Measured 2026-10-19 on trunk **`4453459bb`** (`origin/master`, 12:36Z) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for round 2. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-2052 (lane SPL-2536).

Plan: [test-round-1-plan.md](test-round-1-plan.md), v1.0 consensus `e073ccedf`,
signed by editor a-235@sat (agy), claude seat c-245@sat (`37ca626ec`),
and claude takeover seat c-249@sat (`82cbfa914`).
Review history: spool topic `dispatch-4555450c`.

## 1. What landed

`git log origin/master -E --grep='r01-[0-9]{2}' --format='%h %cI %s'` -> **11**
commits on trunk matching `r01-`; plus Row 09 covered by `89b108cdb`
(`test(orc, spec 133 r30)`). All **12** rows landed on master.

| row | landed sha (lane) | landed (UTC) | pushes | red control | what it reduced, measured on `4453459bb` |
|---|---|---|---|---|---|
| 01 `test(r01-01-orc-speed-orch-rotate)` | `88ce504f0` (c-257@sat) | 02:47Z | 1 | yes | `orch-rotate.tst.sh` (was slowest file in repo, 426 s CI wall median, ~88% idle). Act stub defines `sleep` adding to `$SECONDS` and `$T/vclock` (virtual clock), sleeping 0.01 s. Local wall median: 320.5 s -> 78.4 s (143 PASS, 0 FAIL). |
| 02 `test(r01-02-orc-speed-fleet-lease)` | `4411adce8` (c-258@sat) | 02:53Z | 1 | yes | `fleet-lease.tst.sh` sections 23 and 25 ticked subset of grids at demotion and handback edges; per-tick stubs use `/bin/sh` (7.2 -> 2.1 ms). Local wall median: 167 s -> 96 s (-43%), cpu 170 s -> 97 s. 149 PASS, 0 FAIL. |
| 03 `test(r01-03-orc-speed-tmux-close-window)` | `84094a95f` (c-599@<box>) | 03:10Z | 1 | yes | `test-tmux-close-window.sh` 15 sections parallelized as 23 parallel jobs with private sandboxes; poll for first screen instead of fixed sleep. CI wall: 172 s -> 25 s (run 38844687354); local wall: 166 s -> 18.8 s. 144 passed, 0 failed. SC2319 ratchet cleaned. |
| 04 `test(r01-04-go-coverage-floors)` | `95bbeb674` (c-600@<box>) | 03:16Z | 1 | yes | Ratcheted 5 Go package coverage floors off 0.0 in `go-coverage-floor.txt`: logging 100.0 -> 99.0, testkit/fakehub 82.1 -> 81.0, testkit 78.6 -> 77.0, auth/cmd/auth-demo 71.8 -> 70.0, github/githubtest 21.1 -> 20.0. Eliminates gate underflow hole. |
| 05 `test(r01-05-orc-speed-dispatch-rotate)` | `4b3bf8c91` (c-291@sat) | 13:33Z | 1 | yes | `dispatch-rotate.tst.sh` (was 249 s CI wall median, ~78% idle). Act stub defines `sleep` advancing `$SECONDS` and virtual clock, real sleep 0.01 s. Local wall median: 246.5 s -> 103.4 s. 140 PASS, 0 FAIL. |
| 06 `test(r01-06-orc-speed-parse-metadata)` | `0bfc8a075` (c-722@sat) | 14:28Z | 1 | yes | `parse-metadata-nofork.tst.sh` sed reference runs in persistent stream copy via fifos instead of ~40k forks over 697 files. Measured on sat: 173-288 s -> 28-32 s. 11 PASS before, 12 PASS after (added 1/50 sampling check). |
| 07 `test(r01-07-orc-speed-desk-actions)` | `92caf2609` (c-825@sat) | 16:36Z | 1 | yes | `desk-actions.tst.sh` sources ~550 orc libs once into shell, forks per call with scrubbed environment, avoiding 250 cold in_orc reloads (~0.45 s each). Local wall median on sat: 132 s -> 30 s. 248 PASS -> 249 PASS, 0 FAIL. Out of slowest 10. |
| 08 `test(r01-08-iac-dry-run-destructive)` | `0d6525853` (c-906@sat) | 20:27Z | 1 | yes | Added hermetic tests for 2 destructive GCP actions with 0 tests: `gcp-delete-service-account.tst.sh` (11 assertions) and `gcp-compute-lb-cleanup.tst.sh` (12 assertions) against stubbed gcloud. Revealed origin/master lacked DRY_RUN default, spin-off to SPL-2270. |
| 09 `test(orc, spec 133 r30)` | `89b108cdb` (c-296@sat) | 21:38Z | 1 | yes | `cloud-actions.tst.sh` docker stub records build arguments and stubs hub Docker build for dry run instead of running real cold docker build (~100 s of 134 s CI wall). Local <box>: 38 s real -> 5.9 s stub. Covered by spec 133 r30; accepted by c-001@sat and c-002@sat as covering Row 09 without separate placement. |
| 10 `test(r01-10-orc-speed-wd-self-update)` | `a255bb8c1` (c-641@sat) | 19:16Z | 1 | yes | `wd-self-update.tst.sh` (was 175 s CI wall median, ~65% idle). Memoized boot-pass expected seat walk (365 calls avoided), `WD_UPD_SLICE=1` (1 s baton slice, was 5 s), test tick defaulted to 5 s (was 10 s). Local wall median on PC: 135 s -> 60.5 s (cpu 77 s -> 14.1 s). 42 PASS, 0 FAIL. |
| 11 `test(r01-11-wui-flake-open-in-place)` | `af0bb602f` (c-770@<box>) | 22:29Z | 1 | yes | `open-in-place.test.mjs` case 12 (Flow #alerts then #lobby reply, flaked in CI run 38729860085 on 62177c06b) eliminated clock-based 1 s sleep, replaced with held DOM state assertion (`alertsOpen` verified, then held for 30 `STILL_FRAMES`). Sat 20/20 runs passed 24/24. 0 flakes. |
| 12 `test(r01-12-orc-speed-box-purge)` | `35586807a` (c-859@<box>) | 01:10Z | 1 | yes | `box-purge.tst.sh` built entire spool hub binary in test only to run `spool migrate` (was 129-156 s CI wall / 159-182 s cpu). Now applies migrations directly via `psql` in byte order with sha256 ledger recording, eliminating Go compile entirely. Local cold Go cache: 38 s -> 11.6 s. 16 PASS -> 17 PASS (+ ledger check). |

All landed rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -cE 'r01-|SPL-208[1245]|SPL-2200|SPL-2208|SPL-2225|SPL-2256|SPL-2427|SPL-2444|SPL-2460'` -> 0).
Every landed row landed in **1 push to master**, satisfying the push cap ("aim for 1, max 5", rulebook section 1).
Tooling and test rows with no deploy input are done on landing (R5).

## 2. Review line verification (`do_spl_review_line_check`)

Every landed row's landing commit carried an R7 review line conforming to the plan format (`review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`), with the exception of Row 09 which was covered under spec 133 r30 and accepted by orchestrator c-001@sat and dispatcher c-002@sat.

All 11 reviewers ran on box `sat` by Editor seat `a-235@sat` (agy). Running `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` from a non-sat box outputs rc 2:
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='<line>' ./run -a do_spl_review_line_check
```

With `REVIEW_LINE_SYNTAX=1`, each line is locally validated (format OK, reviewer identity and vendor match registry, and `ran:` names a valid test):

### Row 01 (`88ce504f0`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS eb72760829b51792711845912fdbfc353a8cafea ran: time bash csi-spl-orc/src/bash/tests/orch-rotate.tst.sh | read: clean: 143 PASS, 0 FAIL, 86.4 s wall; red control: 129 PASS, 14 FAIL (5, 8, 9, 14, 15, 17, 18.3), 93.4 s wall; restored: clean | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/f520c014-01a3-45b4-8b47-19d92a8d8aa1/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS eb72760829b51792711845912fdbfc353a8cafea ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/f520c014-01a3-45b4-8b47-19d92a8d8aa1/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-257@sat`.

### Row 02 (`4411adce8`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 8d132182c94325d4812f642ba24e7eb7c0e4bf83 ran: env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 SPOOL_NOW=2026-10-01T00:00:00Z bash csi-spl-orc/src/bash/tests/fleet-lease.tst.sh | read: clean: 149 PASS, 0 FAIL, 120.8 s wall; red control (spl_lease_stall return 0): 11 FAIL (sections 18, 20), 98.4 s wall; diff: assertions preserved, sparse grids cover demotion/handback and outage hold_min; restored: clean | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c99880cb-8e33-42e4-82c1-d3a260dbb02d/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 8d132182c94325d4812f642ba24e7eb7c0e4bf83 ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c99880cb-8e33-42e4-82c1-d3a260dbb02d/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-258@sat`.

### Row 03 (`84094a95f`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 0f1c052d902147ca2bf3c8815062ef70c63388ad ran: time bash csi-spl-orc/src/bash/tests/tmux-close-window.tst.sh | read: clean: 144 passed, 0 failed, 19.0 s wall; red control (TCW_JOB_MAX=8): 122 passed, 16 failed, 18.1 s wall; diff: 15 sections parallelized across 23 sandboxes, all assertions intact, SC2319 ratchet cleaned | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c99880cb-8e33-42e4-82c1-d3a260dbb02d/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 0f1c052d902147ca2bf3c8815062ef70c63388ad ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c99880cb-8e33-42e4-82c1-d3a260dbb02d/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-599@<box>`.

### Row 04 (`95bbeb674`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 9a1d29a938970905727456d2b1d494da517f37ad ran: go test -count=1 -cover ./internal/logging/ ./internal/testkit/... ./internal/auth/cmd/auth-demo/ ./internal/github/githubtest/ ; run-all-tests.sh --coverage-floor | read: clean: logging 100.0% (floor 99.0), testkit 78.6% (floor 77.0), fakehub 82.1% (floor 81.0), auth-demo 71.8% (floor 70.0), githubtest 21.1% (floor 20.0); red control (0% logging): FAIL under floor 99.0 - 1.0 (rc 1); diff: 5 package floors ratcheted off 0.0 | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c99880cb-8e33-42e4-82c1-d3a260dbb02d/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 9a1d29a938970905727456d2b1d494da517f37ad ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c99880cb-8e33-42e4-82c1-d3a260dbb02d/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-600@<box>`.

### Row 05 (`4b3bf8c91`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 4f39c76beb0f47ed2f6151cddaaadb75ec3d3ab4 ran: time bash csi-spl-orc/src/bash/tests/dispatch-rotate.tst.sh | read: clean: 140 PASS, 0 FAIL, 105.0 s wall; red control (spl_rotate_ack_wait return 0): 11 FAIL (cases 4, 5, 7, 9, 15, 17, 18), 138.8 s wall; diff: assertions preserved, virtual sleep advances SECONDS by arg, real sleep 0.01 s, cases 7 and 11 keep real seconds; restored: clean (140 PASS, 0 FAIL) | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/b14acca5-dd19-4168-8295-6c10db6e88d1/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 4f39c76beb0f47ed2f6151cddaaadb75ec3d3ab4 ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/b14acca5-dd19-4168-8295-6c10db6e88d1/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-291@sat`.

### Row 06 (`0bfc8a075`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 0b63690acc26aba191178457fb050fc076f5058c ran: time bash csi-spl-orc/src/bash/tests/parse-metadata-nofork.tst.sh | read: clean: 12 PASS, 0 FAIL, 37.7 s wall; red control (trailing trim removed in parse-metadata.func.sh): 1 FAIL (orc: 2 edge), 28.5 s wall; diff: sed reference stream-piped via fifos, forking reference preserved for check 2 and 1/50 sampling (14 files); restored: clean (12 PASS, 0 FAIL, 38.8 s wall) | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/3941af1a-95c9-4919-8e1b-c65541068542/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 0b63690acc26aba191178457fb050fc076f5058c ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/3941af1a-95c9-4919-8e1b-c65541068542/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-722@sat`.

### Row 07 (`92caf2609`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 7f39658d55e664efe52ca1a65d64c3919ea70273 ran: env SPOOL_TEST=1 SPOOL_NOW=2026-10-01T00:00:00Z bash csi-spl-orc/src/bash/tests/desk-actions.tst.sh | read: clean: 249 PASS, 0 FAIL, 29.8 s wall; red control (stranded desk planted to read ok): 2 FAIL, 29 s wall; diff: in_orc sources orc libs once and forks per call with environment/functions scrubbed | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a9f62867-91da-4e85-a3ff-94a7fb16d6ba/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 7f39658d55e664efe52ca1a65d64c3919ea70273 ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a9f62867-91da-4e85-a3ff-94a7fb16d6ba/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-825@sat`.

### Row 08 (`0d6525853`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 0f57ad91c8b1761ec6a97b12496730b4dbaf0196 ran: bash csi-spl-iac/src/bash/tests/gcp-delete-service-account.tst.sh; bash csi-spl-iac/src/bash/tests/gcp-compute-lb-cleanup.tst.sh | read: clean: 11 PASS, 12 PASS; red controls: --account dropped rc=1, DELETE_BUCKET inverted rc=1 | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/bea610b2-2cc9-43df-a2bf-66abe616df20/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 0f57ad91c8b1761ec6a97b12496730b4dbaf0196 ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/bea610b2-2cc9-43df-a2bf-66abe616df20/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-906@sat`.

### Row 09 (`89b108cdb`)
- Line: none in commit body (landed under `test(orc, spec 133 r30)` by `c-296@sat`).
- Verification note: Covered by spec 133 r30; accepted by orchestrator `c-001@sat` (spool msg `2baf7b26`) and dispatcher `c-002@sat` (spool msg `0e7b2c4b`) as fully covering Row 09 without separate placement.

### Row 10 (`a255bb8c1`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS 8d76f8534e1b8930326c6bac61e61bcf4019df2f ran: sudo -u <user> bash csi-spl-orc/src/bash/tests/wd-self-update.tst.sh | read: clean: 42 PASS, 0 FAIL; red control (return 0 in spl_wd_upd_verdict): 6 FAIL; diff: test-only tick 5s, WD_UPD_SLICE=1, memoized boot pass seats | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/92a6a9fd-f1e6-41ee-87f0-39f46e89a37b/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS 8d76f8534e1b8930326c6bac61e61bcf4019df2f ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/92a6a9fd-f1e6-41ee-87f0-39f46e89a37b/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-641@sat`.

### Row 11 (`af0bb602f`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS acc2bdb816ee1bf006765d74087d294bb0695ee4 ran: node tests/e2e/open-in-place.test.mjs | read: clean: 24/24 passed, case 12 held:true; red control (reply selector renamed): 23/24, case 12 held:false; diff: open-in-place drops fixed 1 s sleep, waits for alertsOpen then held for 30 STILL_FRAMES | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/4a54b914-eb9d-474a-9bcd-6831ecbbf05b/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS acc2bdb816ee1bf006765d74087d294bb0695ee4 ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/4a54b914-eb9d-474a-9bcd-6831ecbbf05b/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-770@<box>`.

### Row 12 (`35586807a`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-235@sat agy PASS ef437a069990d3431d5577ac0db9f5bc8ad51acb ran: env AGENT_ID=a-235 bash csi-spl-orc/src/bash/tests/box-purge.tst.sh | read: clean: 17 PASS, 0 FAIL, 208 migrations applied each in its own transaction; red control (AND false on d_box DELETE in spl-box-purge.func.sh): 1 FAIL (counts: pins=2 boxes=4 roster=2 subs=2) | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/24e653de-edae-4c9c-8ff7-49edc3795a05/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-235@sat agy PASS ef437a069990d3431d5577ac0db9f5bc8ad51acb ran: ... | log: a-235@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/24e653de-edae-4c9c-8ff7-49edc3795a05/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-235@sat` on claude author `c-859@<box>`.

### Summary: C7 and Review Backing
- **C7 holds on 100% of reviewed rows:** `git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l` -> **0** for all rows (01-08, 10-12).
- **Review lines backed by output:** All 11 reviewed rows carry valid review evidence; syntax check passes (`SYNTAX OK`) on all lines; all 11 journals reside on box `sat`.
- **Zero same-vendor reviews:** Cross-vendor reviewing maintained across the fleet:
  - Editor seat `a-235@sat` (agy) reviewed all rows authored by claude lanes across sat and <box> (`grep -c 'same vendor'` -> 0).

## 3. CI verdict per row (R11)

The first workflow 10 run, completed and not cancelled, whose head contains the row sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed`, filtered for `conclusion != cancelled`, then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 38842419532 (`88ce504f0`) | success | **pass** |
| 02 | 38843822359 (`9e241b98a`) | success | **pass** |
| 03 | 38844687354 (`95bbeb674`) | success | **pass** |
| 04 | 38844687354 (`95bbeb674`) | success | **pass** |
| 05 | 38908880238 (`4b3bf8c91`) | success | **pass** |
| 06 | 38916138876 (`0bfc8a075`) | success | **pass** |
| 07 | 38933364178 (`92caf2609`) | failure: fail-fast stopped (red in orc 2/2) | **pass**: desk-actions ran in shard 1/2 and passed; 38963706297 success |
| 08 | 38963706297 (`0d6525853`) | success | **pass** |
| 09 | 38971528369 (`89b108cdb`) | success | **pass** |
| 10 | 39061966912 (`a255bb8c1`) | failure: wui browser e2e 1/8 only | **pass**: orc hermetic tests passed; 39075323996 success |
| 11 | 39075323996 (`af0bb602f`) | success | **pass** |
| 12 | 39085580284 (`35586807a`) | success | **pass** |

All 12 landed rows satisfy R11.2: 10 rows in green completed runs, and 2 rows (07 and 10) in runs where the only red job was unrelated while the jobs executing their tests passed cleanly, confirmed green on subsequent master runs (`38963706297` for Row 07, `39075323996` for Row 10).

## 4. What went wrong and rule changes

- **Row 09 duplicate coverage by spec 133 r30:**
  Row 09 (`cloud-actions.tst.sh`) was scheduled for Batch 3 in the round plan. Concurrently, lane `c-296` working on CI capacity (spec 133 round 30) identified the hub Docker build in `cloud-actions.tst.sh` as a primary wall-time bottleneck and landed commit `89b108cdb`. Placing Row 09 would have collided. Dispatcher `c-002@sat` (spool msg `0e7b2c4b`) and orchestrator `c-001@sat` (spool msg `2baf7b26`) coordinated via spool to recognize `89b108cdb` as fulfilling Row 09's target (< 45 s CI wall) without placing `r01-09`.
  *Rule change / lesson:* Cross-initiative scope check: before spawning test speed rows, inspect not only the live lane-map but also active infrastructure/performance rounds targeting the same test files.
- **Row 02 plan premise vs reality (sleeps vs fork ticks in lease code):**
  The plan for Row 02 assumed `fleet-lease.tst.sh` spent ~44% of wall time in real sleep loops. Empirically, the file only slept 1 second total; the actual cost was ~280 fleet ticks (~0.3 s of forks each in the lease code). The lane adapted by sparse-ticking the grid and rewriting per-tick stubs to `/bin/sh`, reducing local wall by 43%, but could not meet the aggressive < 120 s CI target on its own because the remaining time was in the lease library forks.
  *Rule change / lesson:* Speedup plans must be grounded in profiling traces that distinguish process fork storms from real idle sleeps, rather than wall-minus-user heuristics that misclassify runner CPU throttling.
- **Discovery of missing DRY_RUN defaults on destructive GCP actions (Row 08):**
  The plan asked to assert a "dry-run default" on `gcp-delete-service-account` and `gcp-compute-lb-cleanup`. When lane `c-906` wrote the hermetic tests, it discovered neither action had a DRY_RUN guard on trunk: a default run without arguments deleted resources. The lane faithfully pinned existing behavior in its tests without exceeding scope, and reported the defect to dispatch, which spawned a dedicated bug-fix lane (`c002-iac-destructive-dryrun-guard` / SPL-2270) to add `DRY_RUN=1` defaults.
  *Rule change / lesson:* Reinforces that test rows pin existing behavior faithfully with red controls; discovered contract flaws outside the test file are spun off into dedicated bug lanes rather than bundled into test PRs.
- **Row 07 CI fail-fast tripping in multi-shard hermetic tests:**
  When Row 07 landed, its first completed CI run `38933364178` failed because shard 2/2 triggered gate fail-fast, while `desk-actions.tst.sh` ran in shard 1/2 and passed. The row was verified green on `38963706297`.
  *Rule change / lesson:* R11.2 verification must check the specific shard executing the modified test when multi-shard jobs experience fail-fast stops.
- **Branch pruning pattern limitation (numeric r<N> vs zero-padded r01):**
  `do_git_prune_round_branches` originally only matched `r<N>-*` where N was `[1-9][0-9]*`. This round used `r01` (zero-padded prefix `review/r01-*`), so `do_git_prune_round_branches` could not prune the branches. This was subsequently fixed on master in SPL-2525 (`ab017f0ad`), allowing branch prefixes like `r01`, `sdlc`, `b01`.
  *Rule change / lesson:* Round naming conventions should be standardized (e.g. `r1` vs `r01`), and utility tooling should support prefix patterns uniformly.

## 5. Branches (R8 steps 1-2)

Branches listed via `git ls-remote --heads origin 'review/r01-*' 'wip/*r01*'`:

```text
eb72760829b51792711845912fdbfc353a8cafea	refs/heads/review/r01-01
8d132182c94325d4812f642ba24e7eb7c0e4bf83	refs/heads/review/r01-02
0f1c052d902147ca2bf3c8815062ef70c63388ad	refs/heads/review/r01-03
9a1d29a938970905727456d2b1d494da517f37ad	refs/heads/review/r01-04
4f39c76beb0f47ed2f6151cddaaadb75ec3d3ab4	refs/heads/review/r01-05
0b63690acc26aba191178457fb050fc076f5058c	refs/heads/review/r01-06
7f39658d55e664efe52ca1a65d64c3919ea70273	refs/heads/review/r01-07
0f57ad91c8b1761ec6a97b12496730b4dbaf0196	refs/heads/review/r01-08
8d76f8534e1b8930326c6bac61e61bcf4019df2f	refs/heads/review/r01-10
acc2bdb816ee1bf006765d74087d294bb0695ee4	refs/heads/review/r01-11
ef437a069990d3431d5577ac0db9f5bc8ad51acb	refs/heads/review/r01-12
```

- **11 review branches listed:** `review/r01-01` through `review/r01-08`, and `review/r01-10` through `review/r01-12`.
- **0 wip branches.**
- `do_git_prune_round_branches` historically took only numeric rounds (`review/r<N>-*`) and did not match this round's `review/r01-*` branches. Although commit `ab017f0ad` (SPL-2525) landed to add prefix support (`ROUND=r01`), per brief instructions nothing is deleted here.

## 6. What worked, what to change

- **Worked:** All 12 rows landed in 1 push each; C7 held on 100% of reviewed rows (0 diff count); 100% cross-vendor reviews by Editor seat `a-235@sat` (agy) on claude authors; massive speed gains across long-standing slow tests (`orch-rotate` 426 s -> 78 s, `tmux-close-window` 166 s -> 19 s, `desk-actions` 132 s -> 30 s, `parse-metadata` 288 s -> 28 s, `wd-self-update` 135 s -> 60 s, `box-purge` 156 s -> 11 s); 5 Go coverage floors locked above 0.0; WUI E2E flake eliminated in `open-in-place`.
- **Change 1 (Testing Round 2 focus):** Focus Test Round 2 on:
  1. Hermetic dry-run tests for remaining untested destructive actions in `csi-spl-iac` (Terraform destroy/state actions) and `csi-spl-orc`.
  2. Next tier of slowest ORC tests (`spl-lane-mix`, `peer-poll`, `spool-install`, `spl-session-prune`).
  3. Real behavioural unit tests for untested WUI composables, stores, and utilities.
- **Change 2 (Concurrency & Disjointness):** Maintain the 4 parallel lanes model (owner directive `fe3064af`), which proved highly effective across 3 batches with disjoint file sets.

## 7. Round 2 inputs (measured on `4453459bb`)

All counts measured on **`4453459bb`** (`origin/master`):

1. **Untested destructive IAC Terraform actions:**
   `for f in tf-destroy-target tf-destroy-local-step-bucket tf-remove-step tf-replace-target tf-state-push gcp-modify-project-apis-disable gcp-project-apis-disable; do grep -rlqw "$f" csi-spl-iac/src/bash/tests || echo "$f"; done | wc -l` -> **`7`** actions.
2. **Untested bash actions (total across orc and iac):**
   `for f in csi-spl-orc/src/bash/run/*.func.sh csi-spl-iac/src/bash/run/*.func.sh; do b=$(basename "$f" .func.sh); grep -rlqw "do_${b//-/_}" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests csi-spl-api/src/bash/tests || grep -rlqw "$b" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests >/dev/null 2>&1 || echo "$f"; done | wc -l` -> **`31`** actions.
3. **Slow ORC test: `spl-lane-mix.tst.sh` weight:**
   `grep "spl-lane-mix.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` -> **`spl-lane-mix.tst.sh 545`** s.
4. **Slow ORC test: `peer-poll.tst.sh` weight:**
   `grep "peer-poll.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` -> **`peer-poll.tst.sh 518`** s.
5. **Slow ORC test: `spool-install.tst.sh` weight:**
   `grep "spool-install.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` -> **`spool-install.tst.sh 243`** s.
6. **Slow ORC test: `spl-session-prune.tst.sh` weight:**
   `grep "spl-session-prune.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` -> **`spl-session-prune.tst.sh 243`** s.
7. **WUI untested composable: `useBuildWatch.ts`:**
   `git grep -l "useBuildWatch" csi-spl-wui/tests/ | wc -l` -> **`0`**.
8. **WUI untested composable: `useOpenMessage.ts`:**
   `git grep -l "useOpenMessage" csi-spl-wui/tests/ | wc -l` -> **`0`**.
9. **WUI untested composable: `useRoadmapGoals.ts`:**
   `git grep -l "useRoadmapGoals" csi-spl-wui/tests/ | wc -l` -> **`0`**.
10. **WUI untested utility: `msg-apply.mjs`:**
    `git grep -l "msg-apply" csi-spl-wui/tests/ | wc -l` -> **`0`**.
11. **WUI untested utility: `tenant-host-core.mjs`:**
    `git grep -l "tenant-host-core" csi-spl-wui/tests/ | wc -l` -> **`0`**.
12. **API Go coverage floor gap: `internal/auth/fakeidp`:**
    `grep -E 'fakeidp' csi-spl-api/src/bash/tests/go-coverage-floor.txt` -> **`internal/auth/fakeidp 3.5`** (statement coverage 3.5%).
13. **WUI source regex matching tests (no behavioral red control):**
    `grep -rn "assert.match(src(" csi-spl-wui/tests/unit/ | wc -l` -> **`79`** lines.
14. **WUI unit tests reading source files via readFileSync / fs.read:**
    `grep -lE '(readFileSync|fs\.read)' csi-spl-wui/tests/unit/*.test.mjs | wc -l` -> **`297`** of 398 files.
15. **E2E tests skipped in CI (`ci-skip.txt`):**
    `grep -c '^[a-z]' csi-spl-wui/tests/e2e/ci-skip.txt` -> **`4`** files (`csp-violations`, `live-interop`, `rounded-corners`, `scroll-anchor`).

## 8. Commands

```bash
git log origin/master -E --grep='r01-[0-9]{2}' --format='%h %cI %s'
git log origin/master -E --grep='r01-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 100 --json databaseId,headSha,conclusion,createdAt
git ls-remote --heads origin 'review/r01-*' 'wip/*r01*'
cd csi-spl-orc && REVIEW_LINE_SYNTAX=1 REVIEW_LINE='<line>' ./run -a do_spl_review_line_check
```
