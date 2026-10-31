# Refactoring round 17 - retrospective

Measured 2026-10-31 on trunk **`7ef011cd8`** (`origin/master`
7ef011cd812b2028c7a4af58e350bc0c2c515056) only. Each count names the command
that produced it; n=1 per command unless stated. Rows 09 and 10 landed
**after** that sha: their landing, review, CI and served facts are read on
`origin/master` `e3f795f5e` (2026-10-31 ~11:40Z) and say so. This is R8 of
[rounds-rulebook.md](rounds-rulebook.md); section 7 is the input list for
[round 18](refactor-round-18-plan.md). Times are UTC. Epic: SPL-2402 (lane
issue SPL-4489).

Plan: [refactor-round-17-plan.md](refactor-round-17-plan.md), v1.0
`d8bd342fd`, editor c-910 (claude), claude panel seat c-955 (PASS on
`c19b76232`). Slug series `r42`.

## 1. What landed

`git log 7ef011cd8 -E --grep='r42-[0-9]{2}' --format='%h %cI %s'` -> **8**
commits, rows 01-08, one commit each. On `e3f795f5e` the same grep -> **10**:
rows 09 (`bd893cc8a`) and 10 (`7544ccfb0`) landed 10-31 10:17Z and 10:51Z.
All **10 of 10** rows landed; each is one commit on master.

`git merge-base --is-ancestor <sha> origin/master` -> rc 0 for all 10 shas.
`git log origin/master --grep='Revert' --format=%s | grep -c r42-` -> **0**.

| row | landed sha | landed (UTC) | first release tag holding it | what it reduced (the plan's claim), and on `7ef011cd8` |
|---|---|---|---|---|
| 01 `refactor(r42-01-wui-ratchet-unused-exports)` | `20e546410` | 10-30 19:04Z | `v7.0.0-c3` | `ALLOW_CAP` 34 -> 33. On `7ef011cd8`: 33 unused, cap **33**, no `NOTE`. |
| 02 `refactor(r42-02-wui-ts-convert-event-delete)` | `3ace86893` | 10-31 00:21Z | `v7.1.1-c3` | shims 103 -> 102. On `7ef011cd8`: **102**, 0 leaves. |
| 03 `refactor(r42-03-wui-bidi-regex-escapes)` | `2586d1327` | 10-30 20:13Z | `v7.0.4-c3` | eslint-security baseline 7 bidi findings -> 0. On `7ef011cd8`: baseline **0** rows. |
| 04 `refactor(r42-04-api-gosec-g115-bounds)` | `676ad7862` | 10-30 22:24Z | `v7.0.7-c3` | gosec G115 x4 -> 0. On `7ef011cd8`: gosec baseline holds only G101 x4. |
| 05 `refactor(r42-05-orc-shellcheck-sc2010-tests)` | `d1bad7448` | 10-31 02:13Z | `v7.1.3-c3` | 4 SC2010 baseline rows deleted. |
| 06 `test(r42-06-api-coverage-floor-new-packages)` | `370cea46c` | 10-30 23:25Z | `v7.1.0-c3` | 10 floor lines; `channelmove` written **83.3** (the plan said 81.1: the lane re-measured, as section 1 of the plan asks). |
| 07 `refactor(r42-07-orc-shellcheck-sc2155-test-libs)` | `14d12980e` | 10-31 04:32Z | `v7.1.7-c3` | 2 SC2155 baseline rows deleted. Baseline 109 -> **103** rows with row 05. |
| 08 `test(r42-08-api-coverage-keyd)` | `921ea34d5` | 10-31 06:08Z | `v7.1.9-c3` | `internal/keyd` 75.6% -> **82.2**, floor written (target >= 80.0 reached). |
| 09 `test(r42-09-wui-shims-cap)` | `bd893cc8a` | 10-31 10:17Z | `v7.2.3-c3` | `SHIMS_CAP` 102 in `mjs-shims-exist.test.mjs`. Not on `7ef011cd8`. |
| 10 `test(r42-10-api-coverage-cmd-spool-key)` | `7544ccfb0` | 10-31 10:51Z | none yet (test-only) | `cmd/spool` floor 77.1 -> **77.8**; the plan's target >= 78.0 was **not** reached (the floor file's own comment on `e3f795f5e` says so). Not on `7ef011cd8`. |

Commands: `git tag --contains <sha> --sort=v:refname -l 'v*' | head -1`;
`git show --stat --format= <sha>` (one commit per row);
`grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts`;
`cd csi-spl-wui && node src/node/generate-mjs-shims.mjs --leaves`;
`node csi-spl-wui/tests/unit/unused-exports.test.mjs`;
`grep -v '^#' .shellcheck-warning-baseline.txt | grep -c .`.

**Served (R5).** `cd csi-spl-orc && SHA=3ace86893 ENV=<dev|prd> ./run -a do_check_deploy_lag`
-> hub `current served=9991389a`, wui `current served=4c95266d`, both envs;
`SHA=676ad7862` -> hub current on dev and prd. Row 09:
`SHA=bd893cc8a ENV=<dev|prd>` -> `wui current served=bd893cc8` and `hub
current served=7ef011cd ... n=0 (no hub build input changed)` on both envs.
Row 10 is `_test.go` + the floor file only: no deploy is due.

## 2. Review lines (R7)

`git log origin/master -E --grep='r42-[0-9]{2}' --format=%B | grep -c '^review: '`
-> **10**, one per row. `... | grep -c 'same vendor'` -> **0**.

| row | reviewer | reviewed sha | C7: `git diff <reviewed> <landed> -- <landed files> \| wc -l` |
|---|---|---|---|
| 01 | c-006@`<box>` (claude) | `338963ff4` | 0 |
| 02 | c-088@`<box>` (claude) | `809596035` | 0 |
| 03 | c-027@`<box>` (claude) | `a61985085` | 0 |
| 04 | c-112@`<box>` (claude) | `f7e18cac3` | 0 |
| 05 | c-232@`<box>` (claude) | `675876b24` | 0 |
| 06 | c-128@`<box>` (claude) | `368f2ba6f` | 0 |
| 07 | c-290@`<box>` (claude) | `b3639ae60` | 0 |
| 08 | c-342@`<box>` (claude) | `4409f9089` | 0 |
| 09 | c-422@`<box>` (claude) | `9a6cc552c` | 0 |
| 10 | c-770@sat (claude) | `8753be5a0` | 0 |

- **C7 holds on 10 of 10.**
- **Every reviewer is claude, like every author.** The plan (section 1,
  section 5) asked for an agy reviewer per row. The rows were reviewed under
  the claude-only review waiver (c-001 ruling 1a7c70da, as cited in
  `csi-spl-doc/specs/167-channel-box-move/reviews/c-519-claude-review.md:5`;
  the owner message behind it is not re-read here). `grep -c 'same vendor'`
  is 0 only because no line writes those words: the check cannot see a
  same-vendor review. Section 4.1.
- The lines were not re-run with `do_spl_review_line_check` for this retro.
- Review branches: `do_git_prune_round_branches` was **not** run for this
  retro (not checked whether `review/r42-*` branches remain).

## 3. CI verdict per row (R11)

The first completed, not cancelled workflow 10 run on master whose head
contains the row (`gh run list --workflow 10_ci-quality.yml --branch master`,
then `git merge-base --is-ancestor <row> <head>`; rows 01-08 on 178 runs of
10-30..10-31, 120 completed and not cancelled):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 41112267069 (`20e546410`) | success | **pass** |
| 02 | 41151030631 (`3ace86893`) | success | **pass** |
| 03 | 41124246394 (`2586d1327`) | success | **pass** |
| 04 | 41138359943 (`676ad7862`) | success | **pass** |
| 05 | 41160382568 (`d1bad7448`) | success | **pass** |
| 06 | 41146284072 (`370cea46c`) | success | **pass** |
| 07 | 41169446261 (`14d12980e`) | success | **pass** |
| 08 | 41175642223 (`921ea34d5`) | success | **pass** |
| 09 | 41192245061 (`bd893cc8a`) | failure: `orc: hermetic action tests 2/3` (`FAIL: 10. the box-side SPOOL_LANDED_REPOS_FILE's GitHub-only row ...`, `FAILED: desk-live-proof.tst.sh`); the hub job stopped by gate fail-fast | **pass**: `wui: unit tests + typecheck` and all 8 e2e shards success; the red is SPL-4471's test (`4a50ffdb7`), fixed by `c6fce8dd5`; the row touched no `desk-live` file (`git show --name-only --format= bd893cc8a 7544ccfb0 \| grep -c desk-live` -> 0) |
| 10 | 41194669862 (`7544ccfb0`) | failure: the same `desk-live-proof.tst.sh` case 10; `hub: gofmt, go vet, go test` stopped by fail-fast | **pass**: the job that runs the row's own tests did not finish here; the next run, 41196575380 (`c6fce8dd5`, which holds the row and the SPL-4471 fix), is success, its `hub: gofmt, go vet, go test` job reads `ok ... cmd/spool ... coverage: 77.8%` and `ok   - cmd/spool 77.8% (floor 77.8)` |

## 4. What went wrong and what we learned

### 4.1 The cross-vendor review rule was waived, and the check cannot tell

All 10 reviews are claude on claude. The plan said agy; after it was signed
the reviews moved to fresh-session claude seats under a waiver. The R7 check
`grep -c 'same vendor'` reads 0 because it greps for words a line never
writes, not for the reviewer's vendor against the author's.
*Lesson:* the round 18 plan says "fresh-session claude reviewer" up front,
so plan and practice agree, and the retro states the author/reviewer vendor
pair instead of quoting a grep that cannot fail.

### 4.2 A coverage target is a guess until the lane measures

Row 10 aimed at >= 78.0 and wrote 77.8 (the reachable cases without starting
a process); row 08 aimed at >= 80.0 and wrote 82.2; row 06's `channelmove`
floor came out 83.3, not the plan's 81.1. Each lane re-measured on its own
`origin/master` and wrote what it read, which is the rule working.
*Lesson:* round 18's Go rows name the functions and ask for the n=3
reading, with no fixed target.

### 4.3 Another lane's red sat under the last two rows

The first runs holding rows 09 and 10 are red from one test of SPL-4471
(`desk-live-proof.tst.sh` case 10) that landed with `4a50ffdb7` /
`5a5819f08`. The 8 master runs `41182926135` (`4a50ffdb7`) ..
`41194669862` (`7544ccfb0`) all concluded failure; the failing test is read
from the logs of the two row runs only. Gate fail-fast then stopped the hub
job, so row 10's own Go tests got their verdict only on the next run
(41196575380, `c6fce8dd5`: success, `cmd/spool 77.8% (floor 77.8)`).
*Lesson:* under fail-fast a foreign red hides a row's own result; the R11
verdict waits for the first green run, it is not read off the red one.

### 4.4 Rows 01-10 in 16 hours

The 10 rows landed between 10-30 19:04Z and 10-31 10:51Z on two lanes, 10
pushes, 0 reverts. The cap rows now hold: shims 102 with 0 leaves,
unused-exports 33 at cap 33, eslint-security baseline empty, gosec baseline
only the 4 G101 false positives.

### 4.5 What worked

- 10 of 10 rows landed, one commit each, C7 held, 0 reverts.
- 10 of 10 R11 verdicts pass (8 green first runs; row 09 on its own
  parts; row 10 on the next run, 4.3).
- Served on dev and prd where a deploy is due (section 1).

## 5. Branches and seats (R8)

Not pruned by this retro (section 2). The round 17 panel seats c-910 and
c-955 are not checked here.

## 6. Counts

| metric | n |
|---|---|
| rows planned | 10 |
| rows landed | 10 (8 on `7ef011cd8`, 10 on `e3f795f5e`) |
| commits on master per row | 1 |
| review lines | 10, all claude reviewer on a claude author (4.1) |
| C7 | 10 of 10 hold |
| R11 verdict | 10 pass (row 10 on the run after the SPL-4471 fix) |
| served dev + prd | all rows that deploy (section 1) |

## 7. Round 18 inputs (measured on `7ef011cd8`)

1. **shellcheck WARNING baseline:** `grep -v '^#' .shellcheck-warning-baseline.txt | grep -c .`
   -> **103** rows; the full plain scan of the 2082 git `.sh` files
   (`shellcheck -S warning -f gcc`, 0.10.0, 6 min 28 s) -> **198** findings,
   the baseline's sum. The largest group: **SC2034 x62** in the 9 spawn and
   restore adapters (`spawn-{claude,agy,grok,qwen}.sh` 8 each,
   `restore-{claude,claude-plain,agy,grok,qwen}.sh` 6 each): the `SPAWN_*` /
   `RESTORE_*` declarations are read by the sourced `*-core.inc.sh`.
   `restore-mistral.sh:37` and `spawn-mistral.sh:31` already carry a
   file-wide `# shellcheck disable=SC2034` above `set -uo pipefail` and have
   no baseline row; `restore-claude.sh:16` and `restore-grok.sh:16` carry it
   after the first assignments, where it covers one line only (lines 11-15
   and 19 still warn). On a scratch copy, one directive moved above `set`
   takes `restore-claude.sh` 6 -> 0 and `spawn-claude.sh` 8 -> 0.
2. **shellcheck literal words and unguarded expansions:** SC2100
   `orc:src/bash/tests/dispatch-inbound-pg.tst.sh:71` (`box=box-wui` read as
   arithmetic), SC2209 `orc:lib/bash/funcs/spl-stripe.func.sh:71`
   (`SPL_STRIPE_MODE=test`), SC1010 `orc:src/bash/tests/lane-map.tst.sh:249`
   and `orc:src/bash/tests/spec-import-issues.tst.sh:506` (`== done` inside
   `[[ ]]`), SC2115 `orc:src/bash/tests/repair-spool-keys.tst.sh:26`
   (`rm -rf "$T/root"`), SC2206
   `orc:src/bash/features/spawn-agents/scripts/spool-agent.sh:135`
   (`ENVS=(${ENVN//,/ })`), SC1007
   `iac:src/bash/run/install-lint-tools.func.sh:194` (`GOFLAGS=`) and
   `iac:src/bash/tests/sec-scan.tst.sh:53,57` (`SEC_SCAN=`).
3. **`internal/lockkey` 76.7%** (floor 76.4;
   `go test -count=1 -cover ./internal/lockkey/`, go1.26, n=2 across two
   sessions): `HolderAlive` (`daemon.go:329`) 0.0, `readPID` (`:333`) 42.9,
   `pidAlive` (`:345`) 50.0, `writeFile` (`store.go:282`) 44.4.
4. **`internal/keydesk` 79.1%** (floor 79.1, n=2): `Run` (`keydesk.go:374`)
   0.0, `(*Refused).Error` (`:102`) 0.0, `logf` (`:164`) 50.0,
   `DefaultPeerOK` (`peer_linux.go:44`) 0.0, `procGroups` (`:82`) 0.0,
   `IdentityPath` (`seal.go:86`) 0.0.
5. **`cmd/spool` 77.8 against the 78.0 target (4.2):** the floor file is free
   again now that row 10 landed; `hub.go` is named by a queued row
   (`c002-api-err-r45-shutdown-drain`), so `cmd/spool` waits.
6. **Ratchets with nothing to do:** shims 102, `--leaves` -> 0 (no leaf to
   convert; the next conversion needs a non-leaf plan); unused-exports 33 at
   cap 33, no `NOTE`; `sfc-script-size` 0 over 500; tmp-path and
   eslint-security baselines 0.
7. **Left out, re-measured:** `run.sh` (SC2155/2164/2046/2319; iac, orc and
   utl copies one md5 `38f8b97c`): the baseline header says it is vendored
   from upstream unchanged. gosec G101 x4 and semgrep math/rand jitter x1:
   triaged false positives. Clean-code `LONG` / `wideFuncs`:
   `node tests/unit/cleancode.test.mjs` -> `19 listed long, 17 listed wide`
   (was 20/17); rows r40-01..03 landed (`4c95266d2`, `e7734d408`,
   `e7c655f27`), rows r41-01..03 are briefed (`c003-r41-*`) but neither on
   master nor queued, so the ratchet files stay theirs. `internal/blob`
   71.9%: the uncovered part is the GCS backend, which needs a fake.
   shellcheck `-x -P SCRIPTDIR` (following sourced files) over the whole
   tree: still running after 15 minutes against 6.5 for the plain scan, then
   stopped for low box memory, no result: too slow for a gate.

## 8. Commands

```bash
git log 7ef011cd8 -E --grep='r42-[0-9]{2}' --format='%h %cI %s'
git log origin/master -E --grep='r42-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master -L 200 --json databaseId,headSha,conclusion,status,createdAt
gh api repos/csitea/csi-spl/actions/jobs/<job>/logs
cd csi-spl-orc && SHA=bd893cc8a ENV=prd ./run -a do_check_deploy_lag
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./...
shellcheck -S warning -f gcc <file>
grep -v '^#' .shellcheck-warning-baseline.txt | grep -c .
grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts
node csi-spl-wui/tests/unit/unused-exports.test.mjs
```
