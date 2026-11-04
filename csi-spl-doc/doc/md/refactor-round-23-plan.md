# Refactoring round 23 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4747  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: rows 01-09
  share no file (section 3.1), so any two of them can run at once.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows: **vendor
  claude for every row**. Code reviews grok or claude only (msg cf7a7ee5).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** The fleet's refactor share is under its band:
`./run -a do_spl_spawn_queue` (2026-11-03T23:33Z, this session) prints
`refactor 3 12% (band 40-60%: UNDER), bug 3 12% (band 30-40%: UNDER), feature 19 76% (band 0-%: ok); 348 bypass(es); phase night; last 24 h (53 sample(s)): refactor 8% (band 20-30%: UNDER)`
of 25 known live lanes (15 unknown left out), and 0 refactor rows in the 92
queued asks. Round 22 ([plan](refactor-round-22-plan.md), v1.0, slug `r48`) has
landed all 8 of its batch 1 rows on `origin/master`:
`git log 2149f6423 -E --grep='r48-[0-9]{2}' --format=%s | grep -c '^[a-z]*(r48-'` -> 8
(`b25f385a7` r48-01 through `6237eba2d` r48-08; note `git log 2149f6423 -E --grep='r48-[0-9]{2}' --format='%h %s' | wc -l` prints 9 because `f54a5e1b2 test(orc, SPL-4664)` mentions `r48-01` in its body; row 08 landed at 22:08Z after
this planner brief was written). Its two batch 2 closing rows (`r48-09` coverage
floors and `r48-10` stale clean-code list lines) are still open (`git log
2149f6423 -E --grep='r48-(09|10)' --oneline | wc -l` -> 0), so the round 22
retro is not due yet (rulebook 2.8). Round 21's retro
([refactor-round-21-retro.md](refactor-round-21-retro.md)) landed in `400991243`.
Section 2 re-measures both round 22's section 6 and round 21's retro section 7
on `2149f6423`.

Round 23 focus: **9 of the 10 rows can run at once in batch 1**. One row splits
two orc bash functions over the 75-line cap whose blockers from round 22 have
cleared, three rows split six WUI functions over the 75-line cap across five
composables and stores, five rows put fourteen untested or under-tested Go
functions across `internal/search`, `internal/lockkey`, `internal/marketing`,
`internal/spool` and `internal/wire` under unit test, and one batch 2 closing
row deletes the clean-code `LONG` list lines that rows 01-04 leave stale.

**Status: v1.0 SIGNED** (editor a-622, claude panel reviewer c-646; section 9).

Editor: **a-622** (agy). Panel reviewer: **c-646** (claude, cross-vendor to agy).
Dispatch lease holder: the current holder of `lease.dispatch`.

**One sha:** every count is measured on **`2149f6423`** (`origin/master`
2149f64237e4cd4a7dc096075ad42ba8cf9d2a72, 2026-11-04T00:47:02+02:00 /
2026-11-03T22:47:02Z), n=1 per command unless stated (also verified unchanged
on `8c27cd92e` by c-646). Go: go1.26.10. Node: v20.20.2. Bash, Go and WUI runs
are on `2149f6423` (WUI runs on a `git archive 2149f6423` copy borrowing another
checkout's `node_modules`, read only).

## 1. How to read this

- **Slug prefix `r49`.** `git log 2149f6423 --oneline -E --grep='r49-' | wc -l`
  -> 0; `grep -rl 'r49-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0; `git branch -r | grep -c 'r49-'` -> 0. No `r49` lane. `r48` is taken:
  8 row commits on `2149f6423` (`r48-01..08`). The next planner proves its prefix
  free the same way, and discounts briefs that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `utl:` = `csi-spl-utl/`, `api:` = `csi-spl-api/`, `wui:` = `csi-spl-wui/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/`,
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of
  `2149f6423`; a bash or WUI site's line is the function's first line.
- **Box:** `either` for every row (no pin); the spawner's pick may place a row
  on either box.
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat
  per row (grok on a claude author while grok has quota), named by the
  dispatch holder at placement. Each review line names the author's vendor.
- **Subject** (R6 reads it): `<type>(r49-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> -e <function> 2149f6423 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; for Go, the package's tests; for WUI, the unit tests
  that read the file's source and the e2e files the pre-push map selects.
- **The clean-code lists only NOTE a stale line**, as rounds 21 and 22 section 1
  say (`check_long` in `iac:t/bash-cleancode.tst.sh`, `checkLong` in
  `wui:tests/unit/cleancode.test.mjs`). So a split row does **not** edit the
  gate file: row 10 deletes every stale line in one commit, after them.
- **The floor file is held by open round 22 row `r48-09`.** Now that `r48-08`
  (`6237eba2d`) has landed, `r48-09` is live (`c-634`) to raise the 14 lines of
  round 22 section 3.3 (reading live coverage on its start sha). To keep batch 1
  disjoint and avoid a two-round collision on `api:src/bash/tests/go-coverage-floor.txt`
  (matching round 21's deferral while `r44-09` was open), rows 05-09 leave
  `go-coverage-floor.txt` untouched (a deliberate deviation from its `:4-5`
  same-commit rule) and defer their floor raises to round 24.

## 2. Where the rows come from (measured on `2149f6423`)

| source | input | command on `2149f6423` | n | row / disposition |
|---|---|---|---|---|
| round 22 6 / retro 21 7.4 | round 20's declare-first iac files, the 4 long-example files, `spl_secret_unused_table`, `do_provision_firebase_dns` | the `awk` of round 21 section 2 over `iac:run/`, `orc:run/`, `utl:run/`; `bash iac:t/action-header-tags.tst.sh`; `git log 2149f6423 -E --grep='r46-0[45]' --format=%s \| grep -vc '^docs'` | **30** declare-first files (was 35 on `7f3da5f69`; `15789e9ea` landed `r46-03`, moving 5 files); `measured 768 files: 48 missing, 4 long-example` (was 53, 4); `r46-04` and `r46-05` commits: **0** | **Deferred**: waits on `r46-04` and `r46-05` and the shared baseline `iac:t/action-header-tags-baseline.txt` |
| round 22 6 | the 9 `(required)` header files | `grep -E '^\[missing\]' iac:t/action-header-tags-baseline.txt \| awk '{print $2}' \| xargs grep -l '(required)' \| wc -l` | **9**: reproduces | **Left out**: a behaviour change (bug-round input), as rounds 20-22 said |
| round 22 3.3 / retro 21 7.1 | coverage floor raises (`api:src/bash/tests/go-coverage-floor.txt`) | `cd go: && go test -count=1 -cover ./internal/{mail,wire,github,payments}/` | `mail` 91.2 (floor 85.0), `wire` 90.1 (81.7), `github` 86.7 (82.9), `payments` 83.6 (80.9); `git log 2149f6423 --grep='r48-09' --oneline \| wc -l` -> 0 | **Deferred**: held by open round 22 row `r48-09` (live `c-634`); round 23's floor raises (`search`, `lockkey`, `marketing`, `spool`, `wire`) go to round 24 after `r48-09` lands |
| round 22 6 / retro 21 7.2 | the 9 bash `LONG` functions over 75 lines | `bash iac:t/bash-cleancode.tst.sh` | `PASS: no function over 75 lines outside LONG or over its ceiling (9 listed)` plus 6 `NOTE LONG:` lines from `r48-01..03` | **Row 01** takes 2 (`do_secrets_seed_gcp` 77, `spl_disp_rotate_auto` 78); the other 7 below |
| round 22 2 & 6 | `do_secrets_seed_gcp` (77) in `orc:run/spl-secrets-seed-all.func.sh:42` | `git grep -l -F -e spl-secrets-seed-all -e do_secrets_seed_gcp -e do_spl_secrets_seed_all 2149f6423 -- '*tst.sh' '*/tests/*' '*test*.sh'` | **4** test files (`bash-cleancode.tst.sh`, `run-loader-convention.tst.sh`, `secrets-check-seed-all.tst.sh`, `secrets-none.tst.sh`): Round 22 grepped only the helper name, missing that entry point `do_spl_secrets_seed_all` (which calls `do_secrets_seed_gcp` at `:36`) is directly tested by `orc:t/secrets-check-seed-all.tst.sh` (`:70-139`) and `orc:t/secrets-none.tst.sh` | **Row 01** (paired with `spl_disp_rotate_auto`) |
| round 22 2 & 6 | `spl_disp_rotate_auto` (78) in `orc:run/spl-dispatch-rotate.func.sh:109` | `git log 2149f6423 -1 --oneline -- orc:run/spl-dispatch-rotate.func.sh` | `a91b409e4 fix(orc, SPL-4728): rotate-auto skips vendors with stale quota snapshot`: the queued brief that blocked it in round 22 has landed | **Row 01** (paired with `do_secrets_seed_gcp`) |
| round 22 6 | the other 7 bash `LONG` functions (`do_provision_firebase_dns` 169, `spl_secret_unused_table` 76, `spl_desk_pick` 80, `do_spl_tenant_create` 76, `spl_fleet_role_tick` 78, `_spawn_worktree` 79, `do_spl_agent_identity_restore` 80) | `bash iac:t/bash-cleancode.tst.sh`; queue check | 2 header inputs (`r46`), 1 queued (`881adc37` `c002-bug-dispatch-desk-hop-desk-roots`), 1 briefed (`r41-03`), 3 fleet-critical | **Left out / deferred**: owned, header-blocked, or fleet-critical |
| round 22 6 / retro 21 7.3 | the 15 WUI `LONG` functions (76-80) | `node wui:tests/unit/cleancode.test.mjs` | `12845 functions, 15 listed long, 17 listed wide`, plus 2 `NOTE LONG:` lines (`useTenantSwitch`, `search.ts <anon>#4`) from `r48-04` | **Rows 02, 03, 04** take 6 (the 6 with dedicated unit tests in `wui:tests/unit/`); `useCalendarDeepLinks` is `r41-01`'s; `useCardMove` and `useCardMessageActions` are held back while queued `dda94828` (`c003-move-to-topic-all-channels`) and live card-menu lanes `c-045`/`c-050` run; the remaining 6 are input for round 24 |
| round 22 6 | `search` `StatusDoc` (0.0), `Query.Rank` (0.0) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/search && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | `StatusDoc` 0.0 (`grammar.go:789`), `Query.Rank` 0.0 (`match.go:308`), plus `Type.Group` 66.7 (`grammar.go:80`); package `96.6` (floor `95.6`) | **Row 05** takes all 3 in `internal/search` |
| round 22 6 | `lockkey` `checkIDs` (60.0), `writeFile` (55.6), `shred` (62.5) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/lockkey && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | all 3 reproduce (`lockkey.go:95` 60.0, `store.go:282` 55.6, `store.go:328` 62.5); package `78.7` (sits on its floor `78.7`) | **Row 06** takes all 3 in `internal/lockkey` |
| round 22 6 | `marketing` `ContainerStateError.Error` (0.0), `Meta.Permalink` (0.0) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/marketing && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | `Error` 0.0 (`meta_publish.go:204`), `Permalink` 0.0 (`meta_publish.go:291`), plus `PublishInstagramContainer` 71.4 (`meta_publish.go:229`); package `84.2` (floor `63.6`, to be raised by `r48-09`) | **Row 07** takes all 3 in `internal/marketing` |
| fresh | `spool` functions under 75% (`SendKnownAccepting` 66.7, `atomicMove` 60.0, `fileTimeOrNow` 66.7, `BounceRetired` 73.3) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/spool && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 6 functions under 75%; package `90.2` (floor `86.4`) | **Row 08** takes 4 (`SendKnownAccepting`, `atomicMove`, `fileTimeOrNow`, `BounceRetired`); `warnOut` 66.7 and `writeFileAtomic` 64.7 are input for round 24 |
| fresh | `wire` functions under 75% (`FleetTokenSample.ModelName` 66.7, `skipWS` 66.7, `Envelope.Inner` 66.7) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/wire && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 3 functions at 66.7% (the only `< 75%` functions left in `internal/wire`); package `90.1` (floor `81.7`, to be raised by `r48-09`) | **Row 09** takes all 3 in `internal/wire` |
| fresh | `github` (`messageOf` 66.7, `Blob` 66.7) and `hours` (`minTime` 66.7, `DefaultCategoryRules` 71.4) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/github ./internal/hours && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 4 functions under 75% (`github` package `86.7` / floor `82.9`; `hours` package `98.5` / floor `98.0`) | **Left out**: real, but the round is full; **input for round 24** |
| round 22 6 | Go `longFuncs` and `wideFuncs`, `blob` GCS backend, `gcal` `ListCalendars`, `cmd/spool`, `store`, `repodocs`, `auth`, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | `cleancode_test.go`, `go tool cover`, `i18n-gates.mjs raw`, baselines | reproduce (`r41-01..03` and `r43-04..05` still not landed: `git log 2149f6423 -E --grep='r41-0[1-3]\|r43-0[45]' --oneline \| wc -l` -> 0) | **Left out**: same reasons as round 22 section 2 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r49-01-orc-split-long-secrets-and-rotate)` | a function over the 75-line cap is split into named steps | the GCP secret seed helper (77) and the automatic vendor rotation step (78) are listed over the cap; both blockers from round 22 have cleared | `orc:run/spl-secrets-seed-all.func.sh:42` (`do_secrets_seed_gcp`, 77)<br>`orc:run/spl-dispatch-rotate.func.sh:109` (`spl_disp_rotate_auto`, 78) | 2 functions, 77-78 -> at most 75 | Per function: move whole steps into named helpers in the same file, each defined before its first caller; same arguments, same output lines, same return codes; no renamed env var. Do **not** edit `iac:t/bash-cleancode.tst.sh` (row 10 deletes the lines). No live GCP or desk call: both run with their tests' fakes only. Tests: `orc:t/secrets-check-seed-all.tst.sh`, `orc:t/secrets-none.tst.sh`, `orc:t/dispatch-rotate.tst.sh`, `orc:t/agent-id-lock.tst.sh`, `orc:t/lane-rotate-role-seats.tst.sh`, `orc:t/run-loader-convention.tst.sh`, `orc:t/spl-box-deploy.tst.sh`, `iac:t/satellite-ansible.tst.sh`, `iac:t/action-header-tags.tst.sh`, `iac:t/bash-cleancode.tst.sh` (must print `NOTE LONG: ... is no longer over 75 lines` for both), `do_check_pre_push_lint`. **Control:** every named test passes on the parent sha and after (behaviour kept, C2), and the gate's NOTE appears for both only after. | either | claude | simple_coding | 1 |
| 02 `refactor(r49-02-wui-split-long-drag-and-sidebar-drag)` | as row 01, in the WUI | the list drag-reorder composable (80) and the channel sidebar row-drag composable (78) are listed over the cap | `wui:src/composables/useDragReorder.ts:25` (`useDragReorder`, 80)<br>`wui:src/composables/useSidebarRowDrag.ts:8` (`useSidebarRowDrag`, 78) | 2 functions, 78-80 -> at most 75 | Extract named steps **in the same file** (the source-reading unit tests read these files through `tests/unit/rail-order.test.mjs` and `tests/unit/lib/channel-sidebar-src.mjs`). Same returned object, same refs, no new import, no new text (i18n gates unchanged). Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both); `tests/unit/rail-order.test.mjs` and the unit tests that import `tests/unit/lib/channel-sidebar-src.mjs`; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 01, plus the selected e2e set green before and after. | either | claude | complex_coding | 1 |
| 03 `refactor(r49-03-wui-split-long-repo-edit-store)` | as row 01, in the WUI | both `editLists` (78) and the `defineStore` callback `<anon>#6` (77) in `stores/repoEdit.ts` are listed over the cap | `wui:src/stores/repoEdit.ts:82` (`editLists`, 78)<br>`wui:src/stores/repoEdit.ts:170` (the `defineStore` callback, `<anon>#6`, 77) | 2 functions, 77-78 -> at most 75 | Extract named steps **in the same file**: `tests/unit/repo-edit.test.mjs` and `tests/unit/repo-edit-status.test.mjs` read and exercise `src/stores/repoEdit.ts`. Same returned store surface, same refs, no new import, no new text. Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both `src/stores/repoEdit.ts` entries); `tests/unit/repo-edit.test.mjs`, `tests/unit/repo-edit-status.test.mjs`; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 02. | either | claude | complex_coding | 1 |
| 04 `refactor(r49-04-wui-split-long-spool-events-and-roster)` | as row 01, in the WUI | the live feed tail composable `useSpoolEvents` (80) and the roster store `defineStore` callback `<anon>` (77) are listed over the cap | `wui:src/composables/useSpoolEvents.ts:24` (`useSpoolEvents`, 80)<br>`wui:src/stores/roster.ts:8` (the `defineStore` callback, `<anon>`, 77) | 2 functions, 77-80 -> at most 75 | Extract named steps **in the same file**: `channel-feed.test.mjs`, `newest-live.test.mjs`, `page-session-gates.test.mjs`, `signed-out-socket.test.mjs`, `signed-out-socket-close.test.mjs`, `channel-door.test.mjs`, `human-status.test.mjs` and `live-follow.test.mjs` read these files directly. Same returned object, same refs, no new import, no new text. Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both); the 8 unit test files above; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 02. | either | claude | complex_coding | 1 |
| 05 `test(r49-05-api-search-status-and-rank)` | the search grammar's status doc, type group and rank scorer under test | `StatusDoc` (0.0) returns the `status:` operator's doc string, `Query.Rank` (0.0) counts how many positive lexemes a body string has, and `Type.Group` (66.7) has its `TypeBox` (`"boxes"`) branch uncovered; round 22 named `StatusDoc` and `Query.Rank` as round 23 input | `go:internal/search/grammar.go:80` (`Type.Group`, 66.7)<br>`go:internal/search/grammar.go:789` (`StatusDoc`, 0.0)<br>`go:internal/search/match.go:308` (`Query.Rank`, 0.0)<br>`go:internal/search/status_rank_test.go` (new) | 2 functions at 0.0, 1 at 66.7 | `Type.Group`: `TypeBox` -> `"boxes"` (the uncovered branch) and non-box types (`TypeMessage`, `Type("other")`) -> `string(t) + "s"` (`"messages"`, `"others"`). `StatusDoc`: when `IssueStatuses` is empty -> `opByName[OpStatus].Doc`; when `IssueStatuses` is set to a slice (e.g. `[]string{"open", "blocked"}`, restored via `defer`/`t.Cleanup`) -> `"issue status: open, blocked (older names such as in_progress still work)"`. `Query.Rank(body string)`: empty query -> `0`; query with positive `OpText`/`OpTitle` lexemes against a `body` string containing 0, 1 and multiple matching words -> exact match count `n`. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (r48-09's; deliberate deviation from its `:4-5` same-commit rule). Helper names prefixed `sr`. Tests: `go test -count=1 -race -cover ./internal/search/`; `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`). **Red control:** `Query.Rank` returning `0` on a matching `body` string -> the positive-rank case fails. | either | claude | tests | 1 |
| 06 `test(r49-06-api-lockkey-store-io-and-ids)` | the lock-key ID validator and store file helpers under test | `checkIDs` (60.0) guards tenant and box identifiers before disk access, `writeFile` (55.6) writes `0600` key material atomically, and `shred` (62.5) zeroes and unlinks a key file; round 22 named all three as round 23 input, and `lockkey` (`78.7`) sits on its floor `78.7` | `go:internal/lockkey/lockkey.go:95` (`checkIDs`, 60.0)<br>`go:internal/lockkey/store.go:282` (`writeFile`, 55.6)<br>`go:internal/lockkey/store.go:328` (`shred`, 62.5)<br>`go:internal/lockkey/store_io_test.go` (new) | 3 functions at 55.6-62.5 | In `t.TempDir()` only: `checkIDs(tenant, box)`: invalid tenant -> error naming tenant, valid tenant + invalid box -> error naming box, both valid -> `nil`; `writeFile(path, b)`: into a path whose parent is a regular file -> error, into a temp dir -> writes `b` with mode `0600`; `shred(path)`: missing path -> `nil`, existing file -> overwrites and removes it, directory path -> non-nil error. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (r48-09's; deliberate deviation from its `:4-5` same-commit rule). Helper names prefixed `si`. Tests: `go test -count=1 -race -cover ./internal/lockkey/`; `run-all-tests.sh`. **Red control:** `checkIDs` skipping the box-id check -> the invalid-box case fails. | either | claude | tests | 1 |
| 07 `test(r49-07-api-marketing-meta-permalink-and-error)` | the Instagram container error formatter, permalink fetch and publish error branches under test | `ContainerStateError.Error` (0.0) formats Meta container failures, `Meta.Permalink` (0.0) reads the published post URL, and `Meta.PublishInstagramContainer` (71.4) has untested error branches; round 22 named `Error` and `Permalink` as round 23 input (`marketing` reads `84.2`, floor `63.6`) | `go:internal/marketing/meta_publish.go:204` (`ContainerStateError.Error`, 0.0)<br>`go:internal/marketing/meta_publish.go:229` (`Meta.PublishInstagramContainer`, 71.4)<br>`go:internal/marketing/meta_publish.go:291` (`Meta.Permalink`, 0.0)<br>`go:internal/marketing/meta_permalink_test.go` (new) | 2 functions at 0.0, 1 at 71.4 | Against `httptest.NewServer` only (no live network): `ContainerStateError.Error` formats `cause`, `ContainerID`, `Status.Code` and `Status.Detail`; `Permalink`: bad `id` (e.g. `""` or `"a/b"`) -> error, unknown `field` (not `PermalinkFacebook` or `PermalinkInstagram`, with the `httptest` server answering 200 so a dropped check is observed) -> error, 200 with permalink JSON -> `(link, nil)`, 200 with empty/absent permalink -> `("", nil)` (as `:290` specifies), HTTP error (with `Meta.Attempts = 1` or a tiny `BackoffBase` so `safe: true` retries do not add waits) -> error; `PublishInstagramContainer` bad `igUserID` / empty media `id` answer -> error. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (r48-09's; deliberate deviation from its `:4-5` same-commit rule). Helper names prefixed `mp`. Tests: `go test -count=1 -race -cover ./internal/marketing/`; `run-all-tests.sh`. **Red control:** drop the `field != PermalinkFacebook && field != PermalinkInstagram` check in `Permalink` -> the unknown-field case fails. | either | claude | tests | 1 |
| 08 `test(r49-08-api-spool-send-accepting-and-move)` | the on-box spool's `accepts` send, retired bounce, cross-dir move and mtime fallback under test | `SendKnownAccepting` (66.7), `atomicMove` (60.0), `fileTimeOrNow` (66.7) and `BounceRetired` (73.3) have untested error and fallback branches (`spool` reads `90.2`, floor `86.4`) | `go:internal/spool/spool.go:190` (`Store.SendKnownAccepting`, 66.7)<br>`go:internal/spool/spool.go:656` (`atomicMove`, 60.0)<br>`go:internal/spool/spool.go:822` (`fileTimeOrNow`, 66.7)<br>`go:internal/spool/retired.go:62` (`Store.BounceRetired`, 73.3)<br>`go:internal/spool/send_move_test.go` (new) | 4 functions at 60.0-73.3 | In `t.TempDir()` only: `SendKnownAccepting` with invalid `accepts` value -> validation error, with invalid `kind` to a retired-in-quarantine recipient -> compose error; `atomicMove` when `src` is missing -> error wrapping `fs.ErrNotExist`, when rename fails across a blocked target or fallback path -> covered; `fileTimeOrNow` on a non-existent path -> RFC3339 timestamp near now; `BounceRetired` on a known local recipient or invalid id -> nil. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (r48-09's; deliberate deviation from its `:4-5` same-commit rule). Helper names prefixed `sm`. Tests: `go test -count=1 -race -cover ./internal/spool/`; `run-all-tests.sh`. **Red control:** `SendKnownAccepting` skipping `m.Validate()` after setting `m.Accepts` -> the invalid-accepts case fails. | either | claude | tests | 1 |
| 09 `test(r49-09-api-wire-inner-and-model-name)` | the wire package's remaining three `< 75%` functions under test | `FleetTokenSample.ModelName` (66.7), `skipWS` (66.7) and `Envelope.Inner` (66.7) are the only functions under 75% left in `internal/wire` (`wire` reads `90.1`, floor `81.7`) | `go:internal/wire/fleet_tokens.go:71` (`FleetTokenSample.ModelName`, 66.7)<br>`go:internal/wire/wire.go:883` (`skipWS`, 66.7)<br>`go:internal/wire/wire.go:1039` (`Envelope.Inner`, 66.7)<br>`go:internal/wire/inner_model_test.go` (new) | 3 functions at 66.7 | `ModelName`: `Model == nil` -> `""`, non-nil `"claude-opus-4-7"` -> `"claude-opus-4-7"`. `skipWS`: inputs with spaces, `\t`, `\n`, `\r` and all-whitespace slices -> expected index. `Envelope.Inner`: malformed JSON `Msg` -> parse error, structurally valid JSON `Msg` that fails `m.Validate()` (e.g. missing `task_id`) -> validation error, valid `Msg` -> `*msg.Message`. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (r48-09's; deliberate deviation from its `:4-5` same-commit rule). Helper names prefixed `im`. Tests: `go test -count=1 -race -cover ./internal/wire/`; `run-all-tests.sh`. **Red control:** `Envelope.Inner` skipping `m.Validate()` -> the invalid-inner-message case fails. | either | claude | tests | 1 |
| 10 `test(r49-10-gates-drop-stale-long-lines)` | a clean-code list holds only what is still over the cap | the lists "may only shrink", but a stale line lets a function grow back up to its old ceiling unnoticed; rows 01-04 leave 8 stale lines (and `r48-01..04` left 8 if `r48-10` has not run first) | `iac:t/bash-cleancode.tst.sh` (the `LONG` list)<br>`wui:tests/unit/cleancode.test.mjs` (the `LONG` list and its count comment) | 8 lines from `r49-01..04` (plus 8 from `r48-01..04` if `r48-10` has not landed first) | The lines rows 01-04 leave stale, named here by line number on `2149f6423` and `LONG` key (`<file> <function>`): in `bash-cleancode.tst.sh`, `37` (`csi-spl-orc/src/bash/run/spl-dispatch-rotate.func.sh spl_disp_rotate_auto`) and `38` (`csi-spl-orc/src/bash/run/spl-secrets-seed-all.func.sh do_secrets_seed_gcp`) — plus, if `r48-10` has not landed before this row starts, `28` (`csi-spl-orc/lib/bash/funcs/lde-cnf.func.sh do_lde_cnf`), `31` (`csi-spl-orc/src/bash/run/spl-agent-mcp-install.func.sh do_spl_agent_mcp_install`), `32` (`csi-spl-orc/src/bash/run/spl-auth-idp-secret-seed.func.sh do_spl_auth_idp_secret_seed`), `33` (`csi-spl-orc/src/bash/run/spl-desk-pin.func.sh do_spl_desk_pin`), `35` (`csi-spl-orc/src/bash/run/spl-desk-welcome.func.sh do_spl_desk_welcome`) and `40` (`csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh do_tf_030_import_existing_cloud_run`). In `cleancode.test.mjs`, `46` (`src/composables/useDragReorder.ts useDragReorder`), `49` (`src/composables/useSidebarRowDrag.ts useSidebarRowDrag`), `50` (`src/composables/useSpoolEvents.ts useSpoolEvents`), `54` (`src/stores/repoEdit.ts <anon>#6`), `55` (`src/stores/repoEdit.ts editLists`) and `56` (`src/stores/roster.ts <anon>`) — plus, if `r48-10` has not landed first, `51` (`src/composables/useTenantSwitch.ts useTenantSwitch`) and `57` (`src/stores/search.ts <anon>#4`), and recompute the count comment at `38` on the lane's start sha (`r48-10` also edits `:38`). Delete only the lines whose `NOTE LONG:` the gates print on the start sha; if `r49-10` absorbs `r48-10`'s lines, `r48-10`'s issue is ended (`LANE_ISSUE_OP=end`). Tests: `bash iac:t/bash-cleancode.tst.sh` and `node wui:tests/unit/cleancode.test.mjs` print no `NOTE LONG:` after; `bash iac:t/run-all-tests.sh`; `cd wui: && pnpm run test:unit`. R9: `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** the NOTE lines before (quoted), none after; FAIL count 0 both times. | either | claude | tests | 2 (after 01-04 and r48-10) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-09, no file in two rows.** Row 01 owns two bash files in
  `orc:run/`, rows 02-04 own five WUI `.ts` files across `wui:src/composables/`
  and `wui:src/stores/` (`useDragReorder.ts` + `useSidebarRowDrag.ts` in row 02,
  `repoEdit.ts` in row 03, `useSpoolEvents.ts` + `roster.ts` in row 04), and
  rows 05-09 own one Go package each (`search`, `lockkey`, `marketing`, `spool`,
  `wire`) plus one new `*_test.go` file each. None edits a clean-code list, a
  coverage floor, a baseline, a migration, `csi-spl-cnf/`, a workflow or
  terraform. Rows 05-09 change no non-test code.
- **Batch 2: row 10**, placed within 30 minutes of the last of rows 01-04 (and
  round 22's `r48-10`) landing (R16), or once the round's other rows are done if
  one is dropped; if `r48-10` has not been placed by the time `r49-01..04` all
  land, `r49-10` deletes both rounds' stale `NOTE LONG:` lines in one commit and
  the dispatch holder ends `r48-10`'s issue (`LANE_ISSUE_OP=end`) so two lanes
  never hold the same gate files.
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder
  places any two batch 1 rows, then the next as each lands. Suggested
  order: one bash or WUI row with one Go row, so the two lanes run
  different suites.

### 3.2 Off every live lane and every queued row (R3)

- **Excluded by the brief:** `go:internal/payments/paypal_cert_url_test.go`,
  `go:internal/hub/issues.go`, `orc:run/spl-lane-issue.func.sh`, and every
  spec 169 file. No row names any of them.
- **Live lanes:** `lane-map.sh --check <the 23 site, new-test and gate files of
  rows 01-10, comma separated> --agent a-622` -> **exit 4** (`<box>`,
  2026-11-03T23:51:06Z on v0.1, 9 `unknown:` lanes on `sat`; re-read by `c-646`
  at 2026-11-04T00:10Z -> **exit 4**, 8 `unknown:` lanes on `sat`, `c-059` gone:
  `c-042` `c002-issue-prio-by-class`, `c-044` `c002-monitoring-refresh-tabs-row`,
  `c-045` `c002-wui-msg-menu-no-wrap`, `c-050` `c003-mobile-message-menu-3-dots`,
  `c-053` `c002-s161-b2-agentid-cursor-codex`, `c-054`
  `c001-bug-desk-box-key-pin-conflict`, `c-055`
  `c002-s161-b3-codex-install-actions`, and `c-613` `c002-s166-b7-queue-refill`).
  Their `.md` briefs are on `sat` (`/var/spool-hub/dispatch/briefs` on this box
  has none of the 8 slugs, **unread** here); by their task slugs none targets
  the 23 paths (card-message-menu composables `useCardMove` and
  `useCardMessageActions` were specifically left out for `c-045`/`c-050`). Exit 4
  is not free: the dispatch holder re-runs the check before each row's spawn and
  asks any `unknown:` lane it cannot place this way.
- **Spawn queue (2026-11-03T23:44Z):** `./run -a do_spl_spawn_queue` -> 92
  queued, 0 placing (all 92 queued on `sat`, so their `.md` brief files are on
  `sat`, **unchecked** here; every queued ask's `/var/spool-hub/asks/<id>.json`
  record is synced here). Grepping all `/var/spool-hub/asks/*.json` with
  `"state":"queued"` for the site basenames, function names and package paths of
  rows 01-10 returned **0** matches. Note queued ask `64b20bb7`
  (`c001-bug-rotation-loses-gate-verdict`: `"bug lane: rotation during a
  background full pre-push run loses the api verdict"`) targets worker rotation
  and pre-push verdict scripts, not dispatcher vendor quota rotation
  (`spl-dispatch-rotate.func.sh`).
- **Open rows from earlier rounds:** `r46-04` and `r46-05` hold
  `iac:t/action-header-tags-baseline.txt` (row 01 only runs
  `iac:t/action-header-tags.tst.sh` and must not edit that baseline); `r48-09`
  (live `c-634`) holds `api:src/bash/tests/go-coverage-floor.txt` (no row here
  touches it); `r48-10` (queued) holds `iac:t/bash-cleancode.tst.sh` and
  `wui:tests/unit/cleancode.test.mjs` (row 10 is in batch 2 after `01-04` and
  `r48-10`).

## 4. Per row: what the lane does

- **01:** Split `do_secrets_seed_gcp` and `spl_disp_rotate_auto` into named steps.
- **02:** Split `useDragReorder` and `useSidebarRowDrag` into named steps in the same files.
- **03:** Split `editLists` and the `defineStore` callback in `stores/repoEdit.ts` into named steps.
- **04:** Split `useSpoolEvents` and the `defineStore` callback in `stores/roster.ts` into named steps.
- **05:** Unit tests for `search.StatusDoc`, `Query.Rank` and `Type.Group`.
- **06:** Unit tests for `lockkey.checkIDs`, `writeFile` and `shred`.
- **07:** Unit tests for `marketing.ContainerStateError.Error`, `Meta.Permalink` and `Meta.PublishInstagramContainer`.
- **08:** Unit tests for `spool.SendKnownAccepting`, `atomicMove`, `fileTimeOrNow` and `BounceRetired`.
- **09:** Unit tests for `wire.FleetTokenSample.ModelName`, `skipWS` and `Envelope.Inner`.
- **10:** Delete the clean-code `LONG` list lines that the bash and WUI gates print as stale.

## 5. Panel and reviewers (R7)

- Editor: a-622 (agy). Panel reviewer: c-646 (claude, cross-vendor to agy). Both
  sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked
  with `do_spl_review_line_check`. A row with no reviewer for 15 minutes
  reports a blocker (2.7.3).
- **P1 (ordering of `r49-10` vs `r48-10`), closed (`rounds-rulebook.md:60` R1, `:176` R16):**
  `r49-10` is batch 2 after `01-04` and `r48-10`. Every line in row 10 is named
  by both its `2149f6423` line number and its `LONG` key (`<file> <function>`),
  and the count comment at `cleancode.test.mjs:38` is recomputed on the lane's
  start sha. If `r49-10` absorbs `r48-10`'s lines because `r48-10` was not
  placed first, `r48-10`'s issue is ended (`LANE_ISSUE_OP=end`).
- **P2 (rows 05-09 vs live `r48-09` floor raise `c-634`), closed (`rounds-rulebook.md:60` R1, `go-coverage-floor.txt:4-5`):**
  rows 05-09 are test-only rows (they only add covered statements to an
  unchanged denominator) and explicitly do not edit `go-coverage-floor.txt`
  (deliberate deviation from `:4-5`).
- **P3 (re-measure on `origin/master` past `2149f6423`), closed (`rounds-rulebook.md:185` 3.1):**
  `c-646` verified on `origin/master` `8c27cd92e` that no `r48` row landed after
  `2149f6423`, none of the 23 row paths changed, and every Go function, bash
  `LONG` count and WUI `LONG` count reproduces identically.
- Process lessons from round 21 retro ([refactor-round-21-retro.md](refactor-round-21-retro.md)
  4.2, 4.3, 4.4): every row reviewer's `ran:` field must match the row's test
  column (including `run-all-tests.sh` on Go rows 05-09 and `iac:t/run-all-tests.sh`
  on row 10) and name the author's vendor.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| coverage floor raises for `search`, `lockkey`, `marketing`, `spool`, `wire` (`api:src/bash/tests/go-coverage-floor.txt`) | `go-coverage-floor.txt` is held by open round 22 row `r48-09`; **input for round 24** once `r48-09` and `r49-05..09` land | section 2 |
| round 20's 30 remaining declare-first iac files, the 4 long-example files, `spl_secret_unused_table` (76), `do_provision_firebase_dns` (169) | wait on `r46-04` and `r46-05` and the shared header baseline; **input for round 24** once `r46-05` lands | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| 7 bash `LONG` functions | 2 header inputs (`do_provision_firebase_dns` 169, `spl_secret_unused_table` 76), 1 queued (`881adc37`: `spl_desk_pick` 80), 1 briefed (`r41-03`: `do_spl_tenant_create` 76), 3 fleet-critical (`spl_fleet_role_tick` 78, `_spawn_worktree` 79, `do_spl_agent_identity_restore` 80) | `bash iac:t/bash-cleancode.tst.sh` |
| 9 WUI `LONG` functions, 17 `WIDE` | `useCalendarDeepLinks` (78) is `r41-01`'s; `useCardMove` (80) and `useCardMessageActions` (80) wait on queued `dda94828` and live `c-045`/`c-050`; the other 6 (`-doctree-api.ts useDocTree` 79, `useDocPictures` 79, `useFileTreeDrag` 80, `useOmniboxGripSize` 79, `stores/channel.ts liveSendSteps` 77 and `sidebarSteps` 79) are **input for round 24** | `node wui:tests/unit/cleancode.test.mjs` |
| `github` `messageOf` (66.7), `Client.Blob` (66.7); `hours` `minTime` (66.7), `DefaultCategoryRules` (71.4); `spool` `warnOut` (66.7), `writeFileAtomic` (64.7) | the round is full; **input for round 24** | `go tool cover -func` on `2149f6423` |
| Go `longFuncs` and `wideFuncs`, `blob` GCS backend, `gcal` `ListCalendars`, `cmd/spool`, `store`, `repodocs`, `auth`, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | section 2 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 4, test 6; orc 1, wui 3, Go 5, gate lists 1) |
| vendor | claude 10 |
| kind | simple_coding 1, complex_coding 3, tests 6 |
| batches | batch 1: rows 01-09 (9 at once); batch 2: row 10 |
| bash functions over 75 | 9 -> 7 after row 01 |
| WUI functions over 75 | 15 -> 9 after rows 02-04 |
| stale clean-code list lines | 8 today (from `r48-01..04`), +8 after `r49-01..04`, 0 after `r48-10` and `r49-10` |
| Go functions taken | 4 at 0.0, 10 at 55.6-73.3 |
| measured on | `2149f6423`, n=1 per command unless stated (reproduced on `8c27cd92e`) |

## 8. Changes

- v0.1: first draft (a-622): 10 rows, slug `r49`, measured on `2149f6423`.
- v0.2 (a-622): folds `c-646` FAIL on `2b64b0f46` (msg `eecbc70c` / `6db28cdc`).
  - W1: corrected per-package `go test -count=1 -cover` readings and floors in
    section 2 and rows 06-08 (`search` `96.6` / floor `95.6`; `lockkey` `78.7` /
    floor `78.7`; `marketing` `84.2` / floor `63.6`; `spool` `90.2` / floor
    `86.4`; `wire` `90.1` / floor `81.7`).
  - W2: row 05 describes `Type.Group` (`TypeBox` -> `"boxes"` is the uncovered
    branch; `Type("other")` -> `"others"`), `StatusDoc` (empty vs non-empty
    global `IssueStatuses`, restored afterwards), and `Query.Rank(body string)`
    (counts positive lexemes in one `body` string) accurately.
  - W3: row 07 tests `Permalink` returning `("", nil)` on an empty/absent
    permalink field, plus unknown `field` -> error and bad `id` -> error, with
    red control dropping the `field` check.
  - W4: row 06 describes `checkIDs(tenant, box string)` (2 args, no key id) and
    `writeFile(path, b)` (always writes mode `0600`).
  - W5: fixed the row 01 test-file grep count (`4`, not `5`) and clarified the
    `r48` commit count (`8` row subjects, `9` with `--grep='r48-[0-9]{2}'` due
    to `f54a5e1b2`'s body).
  - N1-N5: named each `LONG` key (`<file> <function>`) in row 10, noted
    recomputing `:38` on the start sha and ending `r48-10`'s issue if absorbed,
    added the explicit `go-coverage-floor.txt` note in rows 05-09, updated the
    `unknown:` live-lane list to 8 (`c-059` gone, briefs on `sat` unread here),
    and ran `do_check_dist_hygiene` and `do_check_fleet_rules_drift` on the v0.2
    head.
- v1.0 (a-622): `c-646` PASS on v0.2 `e6a6933e6` (msg `0d3a791b` / `cb6757d0`). Row table
  unchanged from v0.2 except folding N6 (`httptest` 200 on the unknown-field red
  control and `Meta.Attempts = 1` on the HTTP-error case in row 07) and N7
  (recording the PASS and signatures in section 9). SIGNED.

## 9. Consensus

- Editor seat: a-622 (agy): drafted v0.1, folded v0.2, marked v1.0. **Signed v1.0.**
- Claude panel reviewer seat: c-646 (claude): FAIL on v0.1 `2b64b0f46` (W1-W5, N1-N5; msg `6db28cdc` / `eecbc70c`), PASS on v0.2 `e6a6933e6` (msg `0d3a791b` / `cb6757d0`), **Signed v1.0** on `2d442092a` (msg `fcae6fbd` / `4bd71d01`).
