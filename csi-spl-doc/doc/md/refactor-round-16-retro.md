# Refactoring round 16 - retrospective

Measured 2026-10-30 on trunk **`7e94dbf54`** (`origin/master`
7e94dbf5479a2fea74c01b4794b1b28c6d43d43c) only. Each count names the command
that produced it; n=1 per command unless stated. This is R8 of
[rounds-rulebook.md](rounds-rulebook.md); section 7 is the input list for
[round 17](refactor-round-17-plan.md). Times are UTC (commit dates are stored
with `+03:00` or `+01:00`; every time below is converted). Epic: SPL-2402
(lane issue SPL-4412).

Plan: [refactor-round-16-plan.md](refactor-round-16-plan.md), v1.0
`db905c015`, editor a-866@PC (agy), claude panel seat c-163 (PASS on
`c7ddf63fd`).

## 1. What landed

`git log 7e94dbf54 -E --grep='r16-[0-9]{2}' --format='%h %cI %s'` -> **11**
commits: the 10 `r16-` row commits plus `d10fe5d9a` (`r17-01`), whose body
names round 16. All **10 of 10** rows landed; each is one commit on master.

`git merge-base --is-ancestor <sha> 7e94dbf54` -> rc 0 for all 10 shas.
`git log 7e94dbf54 --grep='Revert' --format=%s | grep -c r16-` -> **0**: none
was reverted.

| row | landed sha | landed (UTC) | first release tag holding it | what it reduced (the plan's claim), and on `7e94dbf54` |
|---|---|---|---|---|
| 01 `refactor(r16-01-wui-ts-convert-leaf-utils-group-e)` | `6228bf921` | 10-21 20:14Z | `v3.2.8-c3` | shims 103 -> 100. On `7e94dbf54`: **103** again (section 4.1). |
| 02 `test(r16-02-go-coverage-cicdlogs-scrub)` | `058b03225` | 10-21 19:34Z | `v3.2.6-c3` | `internal/cicdlogs` 81.5% -> 89.0%, floor 89.0. |
| 03 `refactor(r16-03-wui-decompose-live-feed)` | `22d363c9e` | 10-21 19:46Z | `v3.2.6-c3` | `LiveFeed.vue` script 500 -> 284. On `7e94dbf54`: **284**. |
| 04 `test(r16-04-go-coverage-payments-refund)` | `f2715da08` | 10-21 22:10Z | `v3.3.4-c3` | `internal/payments` 78.6% -> 80.9% (retro 15 aimed at >= 82.0%). On `7e94dbf54`: **80.9%**. |
| 05 `refactor(r16-05-wui-ts-convert-closed-pairs)` | `bc8b0091d` | 10-21 23:56Z | `v3.4.2-c3` | shims 100 -> 98. |
| 06 `refactor(r16-06-wui-decompose-channel-sidebar-rail-tabs)` | `0fc8e3629` | 10-21 23:37Z | `v3.4.1-c3` | `ChannelSidebar.vue` script to 363. On `7e94dbf54`: **364**. |
| 07 `refactor(r16-07-wui-decompose-issues-unopened)` | `c4884480d` | 10-22 00:59Z | `v3.4.8-c3` | `issues.vue` script 492 -> 420. On `7e94dbf54`: **420**. |
| 08 `refactor(r16-08-wui-decompose-doc-view-landing)` | `26e0d8a86` | 10-22 01:55Z | `v3.5.2-c3` | `WorkspaceDocView.vue` script 490 -> 334 (f11ed1f7c). On `7e94dbf54`: **334**. |
| 09 `refactor(r16-09-wui-ratchet-unused-exports)` | `438c6e906` | 10-26 20:56Z | `v5.3.6-c3` | `ALLOW_CAP` 35 -> 34. On `7e94dbf54`: cap **34**, 33 unused (section 4.3). |
| 10 `test(r16-10-go-coverage-cmd-spool)` | `2d7fffe42` | 10-26 22:26Z | `v5.4.0-c3` | `cmd/spool` floor 76.4 -> 77.1. On `7e94dbf54`: **76.8%** (inside the 1.0 point tolerance). |

Commands for the right-hand columns: `git tag --contains <sha> --sort=v:refname -l 'v*' | head -1`;
`sed -n '/<script/,/<\/script>/p' <file> | wc -l`;
`cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./...` (go1.26,
no DSN; the `pg` packages are not measured here);
`node tests/unit/unused-exports.test.mjs`.

**Served (R5).** The WUI rows (01, 03, 05-09) and the Go rows are served on
both environments: `cd csi-spl-orc && SHA=438c6e906 ENV=<dev|prd> ./run -a do_check_deploy_lag`
-> `dev wui current served=f746d2c9`, `prd wui current served=f746d2c9`,
`dev hub current served=2394b31c`, `prd hub current served=2394b31c`, each
"the env serves this commit or a later one". `438c6e906` is the last WUI row
and every earlier row is its ancestor; row 10 (`2d7fffe42`) is test-only and
needs no deploy.

Pushes: each row is **one** commit on master (`git show --stat` per sha), so
every row kept the push cap ("aim for 1, max 5", rulebook 1.2).

## 2. Review lines (R7)

`git log 7e94dbf54 -E --grep='r16-[0-9]{2}' --format=%B | grep -c '^review: '`
-> **11** (10 row commits, one line each, plus the one in `d10fe5d9a`).
`... | grep -c 'same vendor'` -> **0**.

| row | reviewer | reviewed sha | C7: `git diff <reviewed> <landed> -- <landed files> \| wc -l` |
|---|---|---|---|
| 01 | a-700@sat (agy) | `19a771138` | 0 |
| 02 | a-700@sat (agy) | `68a73964f` | 0 |
| 03 | a-700@sat (agy) | `44309e578` | 0 |
| 04 | a-717@sat (agy) | `376d81d4f` | 0 |
| 05 | a-717@sat (agy) | `8ed016fe4` | 0 |
| 06 | a-717@sat (agy) | `695abba01` | 0 |
| 07 | a-717@sat (agy) | `41bd881f5` | 18 (see below) |
| 08 | a-717@sat (agy) | `266b7cdb1` | 0 |
| 09 | a-223@`<box>` (agy) | `2dd6c023f` | 0 |
| 10 | a-320@sat (agy) | `1ec62a43d` | 0 |

- **C7 holds on 10 of 10.** Row 07's 18 lines are the CSS of `af62f0e53`
  (`fix(wui, SPL-2784)`), another lane's commit that landed between review
  and push: `git log --oneline 41bd881f5..c4884480d -- csi-spl-wui/src/pages/issues.vue`
  lists only `af62f0e53` and the row itself. That is a trunk rebase, which C7
  allows; no row site changed after review.
- Every reviewer is agy; the plan sets vendor claude for every row. The
  author's vendor is **not** recorded in the row commits (`git log -1
  --format=%B <sha>` names only the reviewer), so the cross-vendor claim rests
  on the plan and the placement, unchecked here.
- The review lines were not re-run with `do_spl_review_line_check` for this
  retro (their `log:` files are on sat and on another box).
- Review branches (R8 step 2): `cd csi-spl-orc && ROUND=16 ./run -a do_git_prune_round_branches`
  -> `OK round r16: no review/r16-*, wip/*r16* or [review/]<id>-r16-* branch on origin`.
  Nothing left to prune.

## 3. CI verdict per row (R11)

The first completed, not cancelled workflow 10 run on master whose head
contains the row (`gh run list --workflow 10_ci-quality.yml --branch master --created 2026-10-21..2026-10-27 -L 1000`:
884 runs, 646 completed and not cancelled; then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 39670321826 (`6228bf921`) | success | **pass** |
| 02 | 39662840178 (`058b03225`) | success | **pass** |
| 03 | 39664737482 (`22d363c9e`) | success | **pass** |
| 04 | 39685085551 (`f2715da08`) | success | **pass** |
| 05 | 39697410789 (`a5c08cefc`) | failure: `wui: browser e2e (mock, generated) 8/8` only | **pass**: `wui: unit tests + typecheck` success; the red is K4 of `tests/e2e/issues-crud-modal.test.mjs` (the issue tabs' clip control, SPL-2784), fixed by `af62f0e53`; the row touched no issues file (`git show --name-only --format= bc8b0091d 0fc8e3629 \| grep -c issues` -> 0); the next green run 39702023645 (`4a9b24b19`) holds the fix |
| 06 | 39696071548 (`a6d84caec`) | failure: the same e2e shard only | **pass**: same red, same cause |
| 07 | 39703908786 (`c4884480d`) | success | **pass** |
| 08 | 39709515351 (`26e0d8a86`) | success | **pass** |
| 09 | 40400399447 (`caac5fb1e`) | success | **pass** |
| 10 | 40412456207 (`2d7fffe42`) | success | **pass** |

## 4. What went wrong and what we learned

### 4.1 The TypeScript migration slid back: shims 98 -> 103

Rows 01 and 05 took `src/types/mjs-shims.d.ts` from 103 to 98 blocks. On
`7e94dbf54` it holds **103** again (`grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts`).
The five new blocks come from feature lanes on 10-29 and 10-30
(`git log --diff-filter=A -1 -- <file>`): `channel-feed-core.mjs`,
`auth-client-core.mjs`, `emoji-core.mjs` (`8e0088585`, SPL-4244),
`event-delete.mjs` (`0eab294c8`, SPL-4216), `topic-list-order.mjs`
(`d7e5d1ae8`, SPL-4204). `find csi-spl-wui/src -name '*.mjs' | wc -l` -> **292**
(273 on `f11ed1f7c`, per the round 16 plan).
*Lesson:* a migration with no ratchet is undone by the next feature. The
shims count needs a cap that only falls, like `ALLOW_CAP` (round 17 row 09).

### 4.2 The plan was written after the rows; the round numbers split

Rows 01-08 landed 10-21 19:34Z .. 10-22 01:55Z from briefs, before any
round 16 plan was on master; the plan (v0.1 `3291d9da9` .. v1.0 `db905c015`)
was written on 10-26 and added rows 09 and 10, which landed within 2 hours
of the signing. Meanwhile the CI-refactor seat cut its own rounds under the
slugs `r17` .. `r41`
(`git log 7e94dbf54 --format=%s | grep -oE '\(r[0-9]{2}-' | sort -u | wc -l` -> 32
distinct round prefixes: r01, r02, r10 .. r39; r40 and r41 are cut, not
landed). The two numberings have split: this document series is at 16, the
slug series at 41.
*Lesson:* the round 17 plan cannot use `r17-NN` subjects (R4: that grep is
not empty, `r17-01` .. `r17-10` landed 10-22). Its rows take the next free
slug prefix (plan section 1).

### 4.3 A ratchet entry goes stale by itself

`node csi-spl-wui/tests/unit/unused-exports.test.mjs` on `7e94dbf54` ->
`NOTE ALLOW: 'src/utils/id-links.mjs' 'resolveTyped' is no longer an unused export`,
`33 unused, all listed in ALLOW (34 <= cap 34)`. `resolveTyped` gained a
caller in `5039f423b` (SPL-4330, `NoteLinks.vue:55`). Same shape as r16-09:
the test notes it, nothing lowers the cap.

### 4.4 Coverage holds, but slides

`cmd/spool` reads **76.8%** on `7e94dbf54` against floor 77.1, 0.3 points
under what row 10 measured (n=3) four days earlier; green under the 1.0
point tolerance. `internal/payments` stayed at 80.9% (row 04 never reached
retro 15's >= 82.0%).

### 4.5 What worked

- 10 of 10 rows landed, one commit each, C7 held, 0 same-vendor reviews, 0
  reverts.
- 8 of 10 first-containing CI runs green; the 2 reds were one e2e defect of
  another lane, fixed within the hour.
- Every SFC is under `MAX_SCRIPT` 500 (`node tests/unit/sfc-script-size.test.mjs`
  -> `337 SFCs, 0 listed over 500 script lines`); the largest is `issues.vue`
  at 420.

## 5. Branches and seats (R8)

Nothing to prune (section 2). The round 16 panel seats (c-163, a-866@PC)
are not in the fleet lane map today (`lane-map.sh | grep -cE 'c-163|a-866'`
-> 0), so there is no seat to close.

## 6. Counts

| metric | n |
|---|---|
| rows planned | 10 |
| rows landed | 10 |
| commits on master per row | 1 |
| review lines | 10 on row commits, 0 same vendor |
| C7 | 10 of 10 hold |
| first containing CI run green | 8 of 10 (the 2 reds independent of the rows) |
| served dev + prd | all (`do_check_deploy_lag`, section 1) |

## 7. Round 17 inputs (measured on `7e94dbf54`)

1. **Shims slid back (4.1):** `grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts`
   -> **103**; `cd csi-spl-wui && node src/node/generate-mjs-shims.mjs --leaves`
   -> `~/utils/event-delete.mjs`, `1 declared module(s) are leaves`. No cap
   holds the count.
2. **Stale ALLOW entry (4.3):** `resolveTyped` at `unused-exports.test.mjs:53`;
   cap 34, 33 unused.
3. **Go packages with no coverage floor:** `go test -count=1 -cover ./...`,
   each package looked up in `csi-spl-api/src/bash/tests/go-coverage-floor.txt`
   -> 12 have no line, and `run-all-tests.sh` prints them `NEW` and passes
   them at any value: `internal/channelmove` 81.1, `enc` 83.6, `gcal` 85.8,
   `gcal/fakegcal` 0.0 (a test fake), `gcpalerts` 91.8, `hygiene` 90.0,
   `keyd` 75.6, `keydesk` 79.1, `keyexec` 79.7, `pollform` 100.0,
   `secretfile` 100.0, `vendorkey` 82.4.
4. **`internal/keyd` is the least covered of them:** 75.6%; functions under
   60% (`go tool cover -func`): `StateDir` (`store.go:46`) 0.0, `writeNew`
   (`store.go:516`) 41.2, `readOnce` (`pass.go:128`) 55.6, `listenSock`
   (`keyd.go:145`) 56.2, `ServeBundle` (`keyd.go:70`) 57.1, `InitAgent`
   (`store.go:79`) 57.1, `writeScrypt` (`store.go:272`) 59.1.
5. **gosec G115 x4** (`.gosec-baseline.txt`, triaged as false positives):
   `gosec -include=G115 ./cmd/spool/ ./internal/sign/` (2.22.4) -> 4 issues,
   `cmd/spool/hub.go:702,703`, `internal/sign/pubkey.go:62,84`.
6. **eslint-security bidi x7** (`.eslint-security-baseline.txt`): one regex
   literal at `csi-spl-wui/src/utils/mention-autocomplete.mjs:132` written
   with raw bidi control characters.
7. **shellcheck WARNING baseline in test files** (`shellcheck -S warning`,
   all under `csi-spl-orc/src/bash/`): SC2010 (`ls | grep`) at
   `features/spawn-agents/tests/test-fleet-send.sh:51`,
   `tests/db-owner-split.tst.sh:95`, `tests/host-spool-no-rebuild.tst.sh:82,215`,
   `tests/repair-spool-keys.tst.sh:48`; SC2155 at
   `features/spawn-agents/tests/lib.inc.sh:50` (x2) and
   `features/spawn-agents/tests/test-spool-agent.sh:43`. The baseline holds
   109 rows (`grep -v '^#' .shellcheck-warning-baseline.txt | grep -c .`).
8. **Left out, re-measured:** clean-code `LONG` / `wideFuncs` / bash `LONG`
   entries (`node tests/unit/cleancode.test.mjs` -> `20 listed long, 17
   listed wide`): the slug-series rounds r40 and r41 hold those three files
   (`csi-spl-wui/tests/unit/cleancode.test.mjs`,
   `internal/cleancode/cleancode_test.go`, `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`),
   so round 17 leaves them alone. SFC scripts: none near 500 (largest 420).
   SC2178 at `spl-desk-welcome.func.sh:276` and
   `spl-tenant-test-purge.func.sh:105,108`: shellcheck tracks the names
   `live` / `tables` across functions; neither function reassigns an array,
   so not a defect.

## 8. Commands

```bash
git log 7e94dbf54 -E --grep='r16-[0-9]{2}' --format='%h %cI %s'
git log 7e94dbf54 -E --grep='r16-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master --created 2026-10-21..2026-10-27 -L 1000 --json databaseId,headSha,conclusion,status,createdAt
cd csi-spl-orc && SHA=438c6e906 ENV=prd ./run -a do_check_deploy_lag
cd csi-spl-orc && ROUND=16 ./run -a do_git_prune_round_branches
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./...
grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts
node csi-spl-wui/tests/unit/unused-exports.test.mjs
```
