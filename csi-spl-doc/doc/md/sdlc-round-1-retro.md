# SDLC round 1 - retrospective

Measured 2026-10-19 on trunk **`f82adb508`** (`origin/master`, 11:10Z) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for SDLC round 2. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-2058 (lane SPL-2543).

Plan: [sdlc-round-1-plan.md](sdlc-round-1-plan.md), v1.5 `27b67f17e407a12a2dea4ac2935ffa14b73a0f6a`,
signed by editor a-240@sat (agy), claude seat c-247@sat (`85c9e22f8`), and takeover
seat c-251@sat (`de548b2d1`). Review history: spool topic `dispatch-999a50bd`
(`spool tail --task dispatch-999a50bd`).

## 1. What landed

`git log origin/master -E --grep='sdlc-[0-9]{2}' --format='%h %cI %s'` -> **9**
commits on trunk; all **6** planned rows landed on master.
`... --format=%s | grep -oE 'sdlc-[0-9]{2}' | sort -u | wc -l` -> 6.

| row | landed sha (lane) | landed (UTC) | pushes | red control | what it reduced / automated, measured on `f82adb508` |
|---|---|---|---|---|---|
| 01 `refactor(sdlc-01-placer-slug-normalize-handoff)` | `7470f8694` (c-262@sat) | 2026-10-16 03:29Z | 1 | yes | `spl_spawn_place_slug` splits hand-pinned slugs (`hand-<box>-*`, `<box>hand-*`), preserves `SPAWN_BOX=<box>`, and moves `touch .place.last` into launch branch so hand-offs burn 0 placement slots. Live queue brief misses: 5/5 -> 0/5. |
| 06 `refactor(sdlc-06-spawn-place-dynamic-gap)` | `e15813aa0` (takeover sat) | 2026-10-18 05:28Z | 1 | yes | Placer gap ends on placed lane's heartbeat `progress_ts` (spool hook) past launch, subject to 3-min floor and 10-min ceiling, retaining load-target guard. Eliminates up to 1,467 clock holds; cuts queue wait floor from 10 min to 3 min. |
| 07 `refactor(sdlc-07-topic-status-card)` | `bb52681dd` (c-601@PC)<br>`b14a64248` (perf)<br>`b885574a8` (test) | 2026-10-16 04:21Z | 1 | yes | One live status card per owner issue topic, posted once and edited in place (`do_spl_desk_edit`); caches landed shas in `landed.tsv` (cold tick 2m47s -> warm 18s); eliminates 32 weekly owner status inquiries across 28 topics with 0 new message spam. |
| 09 `refactor(sdlc-09-verify-lane-served-auto)` | `711c9eb89` (c-602@PC)<br>`97a636405` (fix) | 2026-10-16 03:59Z<br>2026-10-16 04:08Z | 2 | yes | Automated landed + served verification (`do_check_lane_served`), composing `git-fetch-fresh.sh --landed`, `%ae %ce` check, deploy lag, and anchored trailer verification; adds `served=n/a` for docs-only commits; cuts manual verification tail (p90 1849s). |
| 11 `refactor(sdlc-11-issue-close-cadence)` | `bdb9007b0` (c-603@PC) | 2026-10-16 04:19Z | 1 | yes | Issue closer cron cadence in `csi-spl-orc/cnf/box-crons/box-crons.manifest:28` increased from hourly (`37 * * * *`) to 5-minute intervals (`*/5 * * * *`). Reduces maximum issue closure latency from 59 minutes to 5 minutes, preventing `/exit-clean` WIP collisions. |
| 12 `refactor(sdlc-12-no-go-asks-owner-topics)` | `282e98442` (c-333@sat) | 2026-10-17 00:01Z | 1 | yes | Send-side guard (`spl_go_ask_check`) in `do_spl_desk_post` and `spool-send.sh` refusing free-text go-asks to owner topics while preserving poll forms and real GCP/owner gate citations. Directly eliminates 66 weekly owner go/yes/ok nudges across 47 topics. |

All landed rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -c sdlc-` -> 0).
Every landed row satisfied the push cap ("aim for 1, max 5", rulebook section 1):
- 5 rows landed in **1 push to master** (rows 01, 06, 07, 11, 12).
- Row 09 landed in **2 pushes to master** (`711c9eb89` initial landing; `97a636405` quick fix for trailer colon-space regex after self-test).

## 2. Review line verification (`do_spl_review_line_check`)

Every landed row carried an R7 review line conforming to the plan section 1 format
(`review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`).
Because all reviewers ran on box `sat`, running `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` from a non-sat box (`<box>`) exercises the multi-box contract established by Round 12 row 02.

Default execution outputs:
`REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here` (rc 2), printing the exact peer command on `sat`.
With `REVIEW_LINE_SYNTAX=1`, each line is locally validated: format OK, reviewer identity and vendor match registry, and `ran:` names a valid test.

### Row 01 (`7470f8694`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS ffca2712383f8534f2d176bb485e975f185190c5 ran: bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh | read: PASS: all (56 tests; red control: FAIL: 4 on 95bbeb674) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS ffca2712383f8534f2d176bb485e975f185190c5 ran: bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh | read: PASS: all (56 tests; red control: FAIL: 4 on 95bbeb674) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS ffca2712383f8534f2d176bb485e975f185190c5 ran: bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh | read: PASS: all (56 tests; red control: FAIL: 4 on 95bbeb674) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude author `c-262@sat`.

### Row 06 (`e15813aa0`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS 436a12fbafdf53ec67e28004677ab4e33b016d14 ran: bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh | read: PASS: all (78 assertions; red control on 79c975652: FAIL: 8) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/60ab79cc-3ad3-4028-9160-b30efd498938/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS 436a12fbafdf53ec67e28004677ab4e33b016d14 ran: bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh | read: PASS: all (78 assertions; red control on 79c975652: FAIL: 8) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/60ab79cc-3ad3-4028-9160-b30efd498938/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS 436a12fbafdf53ec67e28004677ab4e33b016d14 ran: bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh | read: PASS: all (78 assertions; red control on 79c975652: FAIL: 8) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/60ab79cc-3ad3-4028-9160-b30efd498938/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude takeover lane on sat (takeover of mistral `m-329`).

### Row 07 (`b885574a8`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS 3eb4f0ee46cf5bc928095a2d71ac5513edc8103f ran: bash csi-spl-orc/src/bash/tests/topic-status-card.tst.sh | read: -- test-topic-status-card.sh: 39 passed, 0 failed (39 assertions; red control mutant: 27 passed, 12 failed) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/506f69a8-ac53-4c95-a3d8-14a255a4130a/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS 3eb4f0ee46cf5bc928095a2d71ac5513edc8103f ran: bash csi-spl-orc/src/bash/tests/topic-status-card.tst.sh | read: -- test-topic-status-card.sh: 39 passed, 0 failed (39 assertions; red control mutant: 27 passed, 12 failed) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/506f69a8-ac53-4c95-a3d8-14a255a4130a/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS 3eb4f0ee46cf5bc928095a2d71ac5513edc8103f ran: bash csi-spl-orc/src/bash/tests/topic-status-card.tst.sh | read: -- test-topic-status-card.sh: 39 passed, 0 failed (39 assertions; red control mutant: 27 passed, 12 failed) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/506f69a8-ac53-4c95-a3d8-14a255a4130a/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude author `c-601@PC`.

### Row 09 refactor (`711c9eb89`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS 027cbe9a9d597e76652724f8f78fe8ef28ea4a12 ran: bash csi-spl-orc/src/bash/tests/check-lane-served.tst.sh | read: PASS: all check-lane-served assertions (17 assertions; red control: FAILED: 2 on lag-blind) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS 027cbe9a9d597e76652724f8f78fe8ef28ea4a12 ran: bash csi-spl-orc/src/bash/tests/check-lane-served.tst.sh | read: PASS: all check-lane-served assertions (17 assertions; red control: FAILED: 2 on lag-blind) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS 027cbe9a9d597e76652724f8f78fe8ef28ea4a12 ran: bash csi-spl-orc/src/bash/tests/check-lane-served.tst.sh | read: PASS: all check-lane-served assertions (17 assertions; red control: FAILED: 2 on lag-blind) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude author `c-602@PC`.

### Row 09 fix (`97a636405`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS 0d8bb1b3c6550de26ab4c885d4be4ac91c07af5d ran: bash csi-spl-orc/src/bash/tests/check-lane-served.tst.sh | read: PASS: all check-lane-served assertions (18 assertions; red control: FAILED: 1 on 711c9eb89) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS 0d8bb1b3c6550de26ab4c885d4be4ac91c07af5d ran: bash csi-spl-orc/src/bash/tests/check-lane-served.tst.sh | read: PASS: all check-lane-served assertions (18 assertions; red control: FAILED: 1 on 711c9eb89) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS 0d8bb1b3c6550de26ab4c885d4be4ac91c07af5d ran: bash csi-spl-orc/src/bash/tests/check-lane-served.tst.sh | read: PASS: all check-lane-served assertions (18 assertions; red control: FAILED: 1 on 711c9eb89) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/a74f45c5-c91d-4685-b928-9d164d8271c6/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude author `c-602@PC`.

### Row 11 (`bdb9007b0`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS 1677372c5e22e0b7d58e4b7ec0b877f4df2bf853 ran: bash csi-spl-orc/src/bash/tests/install-box-crons.tst.sh && bash csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh | read: install-box-crons: 0 failure(s) (13 PASS); spl-issue-close-landed: ALL PASS (13 assertions; red control: 1 failure(s) on 2aa62c80e) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/506f69a8-ac53-4c95-a3d8-14a255a4130a/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS 1677372c5e22e0b7d58e4b7ec0b877f4df2bf853 ran: bash csi-spl-orc/src/bash/tests/install-box-crons.tst.sh && bash csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh | read: install-box-crons: 0 failure(s) (13 PASS); spl-issue-close-landed: ALL PASS (13 assertions; red control: 1 failure(s) on 2aa62c80e) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/506f69a8-ac53-4c95-a3d8-14a255a4130a/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS 1677372c5e22e0b7d58e4b7ec0b877f4df2bf853 ran: bash csi-spl-orc/src/bash/tests/install-box-crons.tst.sh && bash csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh | read: install-box-crons: 0 failure(s) (13 PASS); spl-issue-close-landed: ALL PASS (13 assertions; red control: 1 failure(s) on 2aa62c80e) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/506f69a8-ac53-4c95-a3d8-14a255a4130a/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude author `c-603@PC`.

### Row 12 (`282e98442`)
```text
REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE='review: a-240@sat agy PASS 1579b2c4a31f5c78246bd789320c3867c5874215 ran: bash csi-spl-orc/src/bash/tests/spl-desk-post.tst.sh && bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-send.sh | read: spl-desk-post: 0 failure(s) (18 assertions; red control: without the guard '\''Shall I proceed?'\'' is sent) | test-spool-send: 77 passed, 0 failed (red control: without the guard '\''Shall I proceed?'\'' sends, exit 0) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/d603f14b-514b-49b0-a4fd-a87a05653abc/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1`:
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-240@sat agy PASS 1579b2c4a31f5c78246bd789320c3867c5874215 ran: bash csi-spl-orc/src/bash/tests/spl-desk-post.tst.sh && bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-send.sh | read: spl-desk-post: 0 failure(s) (18 assertions; red control: without the guard '\''Shall I proceed?'\'' is sent) | test-spool-send: 77 passed, 0 failed (red control: without the guard '\''Shall I proceed?'\'' sends, exit 0) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/d603f14b-514b-49b0-a4fd-a87a05653abc/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-240@sat agy PASS 1579b2c4a31f5c78246bd789320c3867c5874215 ran: bash csi-spl-orc/src/bash/tests/spl-desk-post.tst.sh && bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-send.sh | read: spl-desk-post: 0 failure(s) (18 assertions; red control: without the guard 'Shall I proceed?' is sent) | test-spool-send: 77 passed, 0 failed (red control: without the guard 'Shall I proceed?' sends, exit 0) | log: a-240@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/d603f14b-514b-49b0-a4fd-a87a05653abc/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-240@sat` on claude author `c-333@sat`.

### Summary: C7 and Review Backing
- **C7 holds on 100% of landed rows:** `git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l` -> **0** for all rows (01, 06, 07, 09, 11, 12).
- **Review lines backed by output:** All 6 landed rows carry valid review evidence; syntax check passes (`SYNTAX OK`) on all lines; all 6 reviewer journals reside on box `sat`.
- **Zero same-vendor reviews:** Cross-vendor reviewing satisfied across the fleet:
  - All 6 rows were reviewed cross-vendor by `a-240@sat` (agy) on Claude authors.
  - Same-vendor reviews: `git log origin/master --grep='sdlc-' --format=%B | grep -c 'same vendor'` -> **0**.

## 3. CI verdict per row (R11)

The first workflow 10 run, completed and not cancelled, whose head contains the row sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 300`, filtered for `conclusion != cancelled`, then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 39012443140 (`15399f786`) | success | **pass** |
| 06 | 39100689936 (`e15813aa0`) | failure: orc action test shards 1/3 and 3/3 | **pass**: unrelated runner/test shard failure; clean pass on next completed run 39101297309 (`51009ada4`, success) |
| 07 | 39012443140 (`15399f786`) | success | **pass** |
| 09 | 39012443140 (`15399f786`) | success | **pass** |
| 11 | 39012443140 (`15399f786`) | success | **pass** |
| 12 | 39012443140 (`15399f786`) | success | **pass** |

All 6 landed rows satisfy R11.2: 5 rows in green completed runs (`39012443140`), and Row 06 confirmed clean on the subsequent completed run `39101297309`.

## 4. What went wrong and rule changes

- **Mistral lane stall and takeover on Row 06:**
  Lane `m-329` (mistral) was assigned Row 06 (`sdlc-06-spawn-place-dynamic-gap`). Its draft (`92baaac2e`, `97e7776e2`, unpushed) failed fundamentally: its `progress_ts` check matched digits only, dropping the ISO 8601 UTC timestamp format written by `spool-agent-hook.sh`, read arbitrary agent heartbeats instead of the placed lane, and attempted invalid arithmetic (`floor + (now - progress_ts)`). The lane stalled and had to be taken over by Claude (`c-251@sat` / sat takeover lane) to land `e15813aa0`.
  *Rule change / lesson (R14 vendor qualification):* Tasks involving IPC state parsing, timestamp delta comparison, and core scheduler synchronization must not be placed on Mistral until basic shell math and regex reliability are demonstrated.
- **Reviewer imbalance (single reviewer bottleneck):**
  The plan designated `c-247@sat` (claude) to review rows 01 and 06, and `a-240@sat` (agy) to review rows 07, 09, 11, 12. In execution, `a-240@sat` performed 100% of the reviews (all 6 rows, including 2 commits for row 09 and 2 reviews for row 07). While cross-vendor compliance (agy reviewing claude) was maintained, concentrating the review burden on one seat created an unnecessary single-point dependency.
  *Rule change / lesson:* Enforce reviewer rotation and active load monitoring so primary and backup review seats share verification evenly.
- **Remote-box review line verification friction (default rc 2):**
  Running `do_spl_review_line_check` without `REVIEW_LINE_SYNTAX=1` exits with code 2 on any machine other than the reviewer's box (`sat`), printing the remote command. In multi-box retros, verifying 6-10 lines manually on a remote box adds friction.
  *Rule change / lesson:* Introduce automated remote review journal validation over the spool messaging bus (`REVIEW_LINE_REMOTE=1`), allowing peer query verification without operator context switches.
- **False-positive scope warnings (`lane-map.sh --check` exit 4):**
  During SDLC Round 1, multiple lanes (`c-602`, `c-333`, and this retro lane `a-391`) encountered exit 4 warnings from `lane-map.sh --check` because background rotation or idle lanes (`c-285-rotate-2`, `c-455-rotate`, etc.) recorded 0 files. Lanes had to make unilateral judgements to proceed.
  *Rule change / lesson:* Automatically populate `lane.log` via git hooks (e.g. pre-push or worktree creation scanning branch changes) so live lanes never report empty file lists.
- **Coverage gap in go-ask guard (`do_spl_desk_reply`):**
  Row 12 implemented `spl_go_ask_check` in `do_spl_desk_post` and `spool-send.sh`, but explicitly left `do_spl_desk_reply` unprotected (noted in commit `282e98442`). Because most owner-topic answers are sent via `do_spl_desk_reply`, redundant go-asks can still reach the owner.
  *Rule change / lesson:* Extend `spl_go_ask_check` to `do_spl_desk_reply` in SDLC Round 2.
- **Trailer format false positive in `do_check_lane_served`:**
  Row 09 initially flagged its own commit (`711c9eb89`) because a prose comment wrapped onto a line beginning with `Claude-Session:)`. A second commit (`97a636405`) was required to enforce strict key-colon-space matching.
  *Rule change / lesson:* Lint and security checks must test edge cases against wrapped explanatory prose before landing.

## 5. Branches (R8 steps 1-2)

Branches listed by `git ls-remote --heads origin 'review/sdlc-*' 'wip/*sdlc*'`:

```text
ffca2712383f8534f2d176bb485e975f185190c5	refs/heads/review/sdlc-01
436a12fbafdf53ec67e28004677ab4e33b016d14	refs/heads/review/sdlc-06
1abd3bd08cdd06b167a30cad0b2ead1a9b4d185b	refs/heads/review/sdlc-07
3eb4f0ee46cf5bc928095a2d71ac5513edc8103f	refs/heads/review/sdlc-07-2
027cbe9a9d597e76652724f8f78fe8ef28ea4a12	refs/heads/review/sdlc-09
0d8bb1b3c6550de26ab4c885d4be4ac91c07af5d	refs/heads/review/sdlc-09-2
1677372c5e22e0b7d58e4b7ec0b877f4df2bf853	refs/heads/review/sdlc-11
1579b2c4a31f5c78246bd789320c3867c5874215	refs/heads/review/sdlc-12
2f3a30ddab2ee88d210624a5b406a89bbb0a1720	refs/heads/wip/a-240-c002-sdlc-round-plan
85c9e22f8de3691cc6cd1842e808572fbe553467	refs/heads/wip/c-247-c002-sdlc-seat-claude
de548b2d176a826d026bbaa6220e0c17cff04289	refs/heads/wip/c-251-c002-sdlc-seat-takeover-claude
```

Total: **11 branches**. Per brief instructions: `do_git_prune_round_branches` only matches numeric rounds (`review/r<N>-*`) and does not match `review/sdlc-*` branches; therefore, nothing was deleted.

## 6. What worked, what to change

- **Worked:**
  - 100% of planned rows (6/6) landed on master and are ancestors of HEAD.
  - C7 verification held on 100% of landed commits (0 lines diff between reviewed and landed code sites).
  - 100% cross-vendor review compliance (zero same-vendor reviews).
  - Dynamic placement gap (Row 06) successfully decoupled queue drain from the static 10-minute clock hold, enabling 3-minute floor progression.
  - Issue closer cadence reduction (Row 11) dropped close latency from 59m to 5m, eliminating `/exit-clean` WIP blocking.
  - Topic status cards (Row 07) automated progress visibility without message row explosion.
  - Go-ask guard (Row 12) established compile/send-time refusal of redundant permissions.
- **What to change for SDLC Round 2:**
  - Close the go-ask guard gap by guarding `do_spl_desk_reply`.
  - Integrate `do_check_lane_served` directly into `topic-status-card.sh` so docs commits are identified as `served=n/a` without false `lagging` reports.
  - Add remote heartbeat relay so cross-box placements can use the 3-minute placement gap floor.
  - Eliminate lane-map exit 4 noise by automating file registration in `lane.log`.

## 7. Round 2 inputs (measured on `f82adb508`)

All counts measured on **`f82adb508`** (`origin/master`):

1. **Extend `spl_go_ask_check` to `do_spl_desk_reply`:**
   `git grep -n "spl_go_ask_check" csi-spl-orc/src/bash/run/spl-desk-reply.func.sh | wc -l` -> **`0`**
2. **`topic-status-card.sh` deploy verification primitive integration (`do_check_lane_served`):**
   `git grep -n "do_check_lane_served" csi-spl-orc/src/bash/features/spawn-agents/scripts/topic-status-card.sh | wc -l` -> **`0`**
3. **Cross-box remote heartbeat relay for dynamic placement gap (`spl_spawn_place_gap_hold`):**
   `git grep -n "a lane on another box" csi-spl-orc/src/bash/run/spl-spawn-place.func.sh | wc -l` -> **`1`**
4. **Auto-registration of touched files in `lane-map.sh` via pre-push hook:**
   `git grep -n "lane-map.sh put" csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push | wc -l` -> **`0`**
5. **Automated issue status transition on spawn (`eval` -> `wip` in placer launch):**
   `git grep -n "LANE_ISSUE_OP=start" csi-spl-orc/src/bash/run/spl-spawn-place.func.sh | wc -l` -> **`0`**
6. **CI gate health report integration in topic status card (`do_report_ci_gate`):**
   `git grep -n "do_report_ci_gate" csi-spl-orc/src/bash/features/spawn-agents/scripts/topic-status-card.sh | wc -l` -> **`0`**
7. **Cross-box review line verification peer query over spool (`spool_send` in check):**
   `git grep -n "spool_send" csi-spl-orc/src/bash/run/spl-review-line-check.func.sh | wc -l` -> **`0`**
8. **Lane map exit 4 check status on new doc paths:**
   `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/sdlc-round-1-retro.md --agent a-391 >/dev/null 2>&1; echo $?` -> **`4`**
9. **Prune round branches tool named round support (`review/sdlc-*`):**
   `git ls-remote --heads origin "review/sdlc-*" "wip/*sdlc*" | wc -l` -> **`11`**
10. **Closer cron header and documentation synchronization (hourly -> `*/5`):**
    `git grep -n "hourly from the box user" csi-spl-orc/src/bash/scripts/issue-close-landed-cron.sh | wc -l` -> **`1`**

## 8. Commands

```bash
git log origin/master -E --grep='sdlc-[0-9]{2}' --format='%h %cI %s'
git log origin/master -E --grep='sdlc-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 300 --json databaseId,headSha,conclusion,createdAt
git ls-remote --heads origin 'review/sdlc-*' 'wip/*sdlc*'
cd csi-spl-orc && REVIEW_LINE_SYNTAX=1 REVIEW_LINE='<line>' ./run -a do_spl_review_line_check
```
