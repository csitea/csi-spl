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
`git log 2149f6423 -E --grep='r48-[0-9]{2}' --format='%h %s' | wc -l` -> 8
(`b25f385a7` r48-01 through `6237eba2d` r48-08; row 08 landed at 22:08Z after
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

**Status: v0.1 DRAFT** (editor a-622, pending cross-vendor panel review; section 9).

Editor: **a-622** (agy). Panel reviewer: a cross-vendor seat placed by the
dispatch lease holder. Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`2149f6423`** (`origin/master`
2149f64237e4cd4a7dc096075ad42ba8cf9d2a72, 2026-11-04T00:47:02+02:00 /
2026-11-03T22:47:02Z), n=1 per command unless stated. Go: go1.26.10. Node:
v20.20.2. Bash, Go and WUI runs are on `2149f6423` (WUI runs on a `git archive
2149f6423` copy borrowing another checkout's `node_modules`, read only).

## 1. How to read this

- **Slug prefix `r49`.** `git log 2149f6423 --oneline -E --grep='r49-' | wc -l`
  -> 0; `grep -rl 'r49-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0; `git branch -r | grep -c 'r49-'` -> 0. No `r49` lane. `r48` is taken:
  8 commits on `2149f6423` (`r48-01..08`). The next planner proves its prefix
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
  (`6237eba2d`) has landed, `r48-09` is unblocked to raise the 14 lines of
  round 22 section 3.3 (reading live coverage on its start sha). To keep batch 1
  disjoint and avoid a two-round collision on `api:src/bash/tests/go-coverage-floor.txt`
  (matching round 21's deferral while `r44-09` was open), rows 05-09 leave
  `go-coverage-floor.txt` untouched and defer their floor raises to round 24.

## 2. Where the rows come from (measured on `2149f6423`)

| source | input | command on `2149f6423` | n | row / disposition |
|---|---|---|---|---|
| round 22 6 / retro 21 7.4 | round 20's declare-first iac files, the 4 long-example files, `spl_secret_unused_table`, `do_provision_firebase_dns` | the `awk` of round 21 section 2 over `iac:run/`, `orc:run/`, `utl:run/`; `bash iac:t/action-header-tags.tst.sh`; `git log 2149f6423 -E --grep='r46-0[45]' --format=%s \| grep -vc '^docs'` | **30** declare-first files (was 35 on `7f3da5f69`; `15789e9ea` landed `r46-03`, moving 5 files); `measured 768 files: 48 missing, 4 long-example` (was 53, 4); `r46-04` and `r46-05` commits: **0** | **Deferred**: waits on `r46-04` and `r46-05` and the shared baseline `iac:t/action-header-tags-baseline.txt` |
| round 22 6 | the 9 `(required)` header files | `grep -E '^\[missing\]' iac:t/action-header-tags-baseline.txt \| awk '{print $2}' \| xargs grep -l '(required)' \| wc -l` | **9**: reproduces | **Left out**: a behaviour change (bug-round input), as rounds 20-22 said |
| round 22 3.3 / retro 21 7.1 | coverage floor raises (`api:src/bash/tests/go-coverage-floor.txt`) | `cd go: && go test -count=1 -cover ./internal/{mail,wire,github,payments}/` | `mail` 91.2 (floor 85.0), `wire` 90.1 (81.7), `github` 86.7 (82.9), `payments` 83.6 (80.9); `git log 2149f6423 --grep='r48-09' --oneline \| wc -l` -> 0 | **Deferred**: held by open round 22 row `r48-09` (now unblocked by `6237eba2d` `r48-08`); round 23's floor raises (`search`, `lockkey`, `marketing`, `spool`, `wire`) go to round 24 after `r48-09` lands |
| round 22 6 / retro 21 7.2 | the 9 bash `LONG` functions over 75 lines | `bash iac:t/bash-cleancode.tst.sh` | `PASS: no function over 75 lines outside LONG or over its ceiling (9 listed)` plus 6 `NOTE LONG:` lines from `r48-01..03` | **Row 01** takes 2 (`do_secrets_seed_gcp` 77, `spl_disp_rotate_auto` 78); the other 7 below |
| round 22 2 & 6 | `do_secrets_seed_gcp` (77) in `orc:run/spl-secrets-seed-all.func.sh:42` | `git grep -l -F -e spl-secrets-seed-all -e do_secrets_seed_gcp -e do_spl_secrets_seed_all 2149f6423 -- '*tst.sh' '*/tests/*' '*test*.sh'` | **5** test files: Round 22 grepped only the helper name, missing that entry point `do_spl_secrets_seed_all` (which calls `do_secrets_seed_gcp` at `:36`) is directly tested by `orc:t/secrets-check-seed-all.tst.sh` (`:70-139`) and `orc:t/secrets-none.tst.sh` | **Row 01** (paired with `spl_disp_rotate_auto`) |
| round 22 2 & 6 | `spl_disp_rotate_auto` (78) in `orc:run/spl-dispatch-rotate.func.sh:109` | `git log 2149f6423 -1 --oneline -- orc:run/spl-dispatch-rotate.func.sh` | `a91b409e4 fix(orc, SPL-4728): rotate-auto skips vendors with stale quota snapshot`: the queued brief that blocked it in round 22 has landed | **Row 01** (paired with `do_secrets_seed_gcp`) |
| round 22 6 | the other 7 bash `LONG` functions (`do_provision_firebase_dns` 169, `spl_secret_unused_table` 76, `spl_desk_pick` 80, `do_spl_tenant_create` 76, `spl_fleet_role_tick` 78, `_spawn_worktree` 79, `do_spl_agent_identity_restore` 80) | `bash iac:t/bash-cleancode.tst.sh`; queue check | 2 header inputs (`r46`), 1 queued (`881adc37` `c002-bug-dispatch-desk-hop-desk-roots`), 1 briefed (`r41-03`), 3 fleet-critical | **Left out / deferred**: owned, header-blocked, or fleet-critical |
| round 22 6 / retro 21 7.3 | the 15 WUI `LONG` functions (76-80) | `node wui:tests/unit/cleancode.test.mjs` | `12845 functions, 15 listed long, 17 listed wide`, plus 2 `NOTE LONG:` lines (`useTenantSwitch`, `search.ts <anon>#4`) from `r48-04` | **Rows 02, 03, 04** take 6 (the 6 with dedicated unit tests in `wui:tests/unit/`); `useCalendarDeepLinks` is `r41-01`'s; `useCardMove` and `useCardMessageActions` are held back while queued `dda94828` (`c003-move-to-topic-all-channels`) and live card-menu lanes `c-045`/`c-050` run; the remaining 6 are input for round 24 |
| round 22 6 | `search` `StatusDoc` (0.0), `Query.Rank` (0.0) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/search && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | `StatusDoc` 0.0 (`grammar.go:789`), `Query.Rank` 0.0 (`match.go:308`), plus `Type.Group` 66.7 (`grammar.go:80`); package 90.0 (floor 89.3) | **Row 05** takes all 3 in `internal/search` |
| round 22 6 | `lockkey` `checkIDs` (60.0), `writeFile` (55.6), `shred` (62.5) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/lockkey && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | all 3 reproduce (`lockkey.go:95` 60.0, `store.go:282` 55.6, `store.go:328` 62.5); package 86.2 (sits on its floor 86.2) | **Row 06** takes all 3 in `internal/lockkey` |
| round 22 6 | `marketing` `ContainerStateError.Error` (0.0), `Meta.Permalink` (0.0) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/marketing && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | `Error` 0.0 (`meta_publish.go:204`), `Permalink` 0.0 (`meta_publish.go:291`), plus `PublishInstagramContainer` 71.4 (`meta_publish.go:229`); package 88.2 (sits on its floor 88.2) | **Row 07** takes all 3 in `internal/marketing` |
| fresh | `spool` functions under 75% (`SendKnownAccepting` 66.7, `atomicMove` 60.0, `fileTimeOrNow` 66.7, `BounceRetired` 73.3) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/spool && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 6 functions under 75%; package 89.2 (sits on its floor 89.2) | **Row 08** takes 4 (`SendKnownAccepting`, `atomicMove`, `fileTimeOrNow`, `BounceRetired`); `warnOut` 66.7 and `writeFileAtomic` 64.7 are input for round 24 |
| fresh | `wire` functions under 75% (`FleetTokenSample.ModelName` 66.7, `skipWS` 66.7, `Envelope.Inner` 66.7) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/wire && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 3 functions at 66.7% (the only `< 75%` functions left in `internal/wire`); package 90.1 (floor 81.7) | **Row 09** takes all 3 in `internal/wire` |
| fresh | `github` (`messageOf` 66.7, `Blob` 66.7) and `hours` (`minTime` 66.7, `DefaultCategoryRules` 71.4) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/github ./internal/hours && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 4 functions under 75% | **Left out**: real, but the round is full; **input for round 24** |
| round 22 6 | Go `longFuncs` and `wideFuncs`, `blob` GCS backend, `gcal` `ListCalendars`, `cmd/spool`, `store`, `repodocs`, `auth`, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | `cleancode_test.go`, `go tool cover`, `i18n-gates.mjs raw`, baselines | reproduce (`r41-01..03` and `r43-04..05` still not landed: `git log 2149f6423 -E --grep='r41-0[1-3]\|r43-0[45]' --oneline \| wc -l` -> 0) | **Left out**: same reasons as round 22 section 2 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r49-01-orc-split-long-secrets-and-rotate)` | a function over the 75-line cap is split into named steps | the GCP secret seed helper (77) and the automatic vendor rotation step (78) are listed over the cap; both blockers from round 22 have cleared | `orc:run/spl-secrets-seed-all.func.sh:42` (`do_secrets_seed_gcp`, 77)<br>`orc:run/spl-dispatch-rotate.func.sh:109` (`spl_disp_rotate_auto`, 78) | 2 functions, 77-78 -> at most 75 | Per function: move whole steps into named helpers in the same file, each defined before its first caller; same arguments, same output lines, same return codes; no renamed env var. Do **not** edit `iac:t/bash-cleancode.tst.sh` (row 10 deletes the lines). No live GCP or desk call: both run with their tests' fakes only. Tests: `orc:t/secrets-check-seed-all.tst.sh`, `orc:t/secrets-none.tst.sh`, `orc:t/dispatch-rotate.tst.sh`, `orc:t/agent-id-lock.tst.sh`, `orc:t/lane-rotate-role-seats.tst.sh`, `orc:t/run-loader-convention.tst.sh`, `orc:t/spl-box-deploy.tst.sh`, `iac:t/satellite-ansible.tst.sh`, `iac:t/action-header-tags.tst.sh`, `iac:t/bash-cleancode.tst.sh` (must print `NOTE LONG: ... is no longer over 75 lines` for both), `do_check_pre_push_lint`. **Control:** every named test passes on the parent sha and after (behaviour kept, C2), and the gate's NOTE appears for both only after. | either | claude | simple_coding | 1 |
| 02 `refactor(r49-02-wui-split-long-drag-and-sidebar-drag)` | as row 01, in the WUI | the list drag-reorder composable (80) and the channel sidebar row-drag composable (78) are listed over the cap | `wui:src/composables/useDragReorder.ts:25` (`useDragReorder`, 80)<br>`wui:src/composables/useSidebarRowDrag.ts:8` (`useSidebarRowDrag`, 78) | 2 functions, 78-80 -> at most 75 | Extract named steps **in the same file** (the source-reading unit tests read these files through `tests/unit/rail-order.test.mjs` and `tests/unit/lib/channel-sidebar-src.mjs`). Same returned object, same refs, no new import, no new text (i18n gates unchanged). Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both); `tests/unit/rail-order.test.mjs` and the unit tests that import `tests/unit/lib/channel-sidebar-src.mjs`; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 01, plus the selected e2e set green before and after. | either | claude | complex_coding | 1 |
| 03 `refactor(r49-03-wui-split-long-repo-edit-store)` | as row 01, in the WUI | both `editLists` (78) and the `defineStore` callback `<anon>#6` (77) in `stores/repoEdit.ts` are listed over the cap | `wui:src/stores/repoEdit.ts:82` (`editLists`, 78)<br>`wui:src/stores/repoEdit.ts:170` (the `defineStore` callback, `<anon>#6`, 77) | 2 functions, 77-78 -> at most 75 | Extract named steps **in the same file**: `tests/unit/repo-edit.test.mjs` and `tests/unit/repo-edit-status.test.mjs` read and exercise `src/stores/repoEdit.ts`. Same returned store surface, same refs, no new import, no new text. Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both `src/stores/repoEdit.ts` entries); `tests/unit/repo-edit.test.mjs`, `tests/unit/repo-edit-status.test.mjs`; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 02. | either | claude | complex_coding | 1 |
| 04 `refactor(r49-04-wui-split-long-spool-events-and-roster)` | as row 01, in the WUI | the live feed tail composable `useSpoolEvents` (80) and the roster store `defineStore` callback `<anon>` (77) are listed over the cap | `wui:src/composables/useSpoolEvents.ts:24` (`useSpoolEvents`, 80)<br>`wui:src/stores/roster.ts:8` (the `defineStore` callback, `<anon>`, 77) | 2 functions, 77-80 -> at most 75 | Extract named steps **in the same file**: `channel-feed.test.mjs`, `newest-live.test.mjs`, `page-session-gates.test.mjs`, `signed-out-socket.test.mjs`, `signed-out-socket-close.test.mjs`, `channel-door.test.mjs`, `human-status.test.mjs` and `live-follow.test.mjs` read these files directly. Same returned object, same refs, no new import, no new text. Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both); the 8 unit test files above; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 02. | either | claude | complex_coding | 1 |
| 05 `test(r49-05-api-search-status-and-rank)` | the search grammar's status doc, type group and rank scorer under test | `StatusDoc` (0.0) documents the accepted `status:` values, `Query.Rank` (0.0) scores a matched document, and `Type.Group` (66.7) maps a result type to its group; round 22 named `StatusDoc` and `Query.Rank` as round 23 input | `go:internal/search/grammar.go:80` (`Type.Group`, 66.7)<br>`go:internal/search/grammar.go:789` (`StatusDoc`, 0.0)<br>`go:internal/search/match.go:308` (`Query.Rank`, 0.0)<br>`go:internal/search/status_rank_test.go` (new) | 2 functions at 0.0, 1 at 66.7 | `StatusDoc`: non-empty, contains every canonical status value and its aliases. `Type.Group`: every `Type` constant plus an unknown `Type("other")` -> `""` (covering the default branch). `Query.Rank`: empty query -> 0, matched terms across title/body/tag fields -> positive rank with title weighting above body, unmatched doc -> 0. Non-test code unchanged. Helper names prefixed `sr`. Tests: `go test -count=1 -race -cover ./internal/search/`; `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`, floors unchanged). **Red control:** `Query.Rank` returning `0` on a title hit -> the rank ordering case fails. | either | claude | tests | 1 |
| 06 `test(r49-06-api-lockkey-store-io-and-ids)` | the lock-key ID validator and store file helpers under test | `checkIDs` (60.0) guards key/tenant/box identifiers before disk access, `writeFile` (55.6) writes key material atomically, and `shred` (62.5) zeroes and unlinks a key file; round 22 named all three as round 23 input, and `lockkey` sits on its floor 86.2 | `go:internal/lockkey/lockkey.go:95` (`checkIDs`, 60.0)<br>`go:internal/lockkey/store.go:282` (`writeFile`, 55.6)<br>`go:internal/lockkey/store.go:328` (`shred`, 62.5)<br>`go:internal/lockkey/store_io_test.go` (new) | 3 functions at 55.6-62.5 | In `t.TempDir()` only: `checkIDs` with empty/invalid tenant, box or key id -> error naming the bad field, valid -> nil; `writeFile` into a path whose parent is a regular file -> error, into a temp dir -> writes with the requested mode; `shred` on a missing path -> nil, on an existing file -> removes it, on a directory path -> non-nil error. Non-test code unchanged. Helper names prefixed `si`. Tests: `go test -count=1 -race -cover ./internal/lockkey/`; `run-all-tests.sh`. **Red control:** `checkIDs` skipping the box-id check -> the invalid-box case fails. | either | claude | tests | 1 |
| 07 `test(r49-07-api-marketing-meta-permalink-and-error)` | the Instagram container error formatter, permalink fetch and publish error branches under test | `ContainerStateError.Error` (0.0) formats Meta container failures, `Meta.Permalink` (0.0) reads the published post URL, and `Meta.PublishInstagramContainer` (71.4) has untested error branches; round 22 named `Error` and `Permalink` as round 23 input, and `marketing` sits on its floor 88.2 | `go:internal/marketing/meta_publish.go:204` (`ContainerStateError.Error`, 0.0)<br>`go:internal/marketing/meta_publish.go:229` (`Meta.PublishInstagramContainer`, 71.4)<br>`go:internal/marketing/meta_publish.go:291` (`Meta.Permalink`, 0.0)<br>`go:internal/marketing/meta_permalink_test.go` (new) | 2 functions at 0.0, 1 at 71.4 | Against `httptest.NewServer` only (no live network): `ContainerStateError.Error` with and without a status message -> expected text; `Permalink` on 200 with permalink JSON -> URL, on 200 with empty permalink -> error, on HTTP error -> error; `PublishInstagramContainer` empty container ID / error branches -> error. Non-test code unchanged. Helper names prefixed `mp`. Tests: `go test -count=1 -race -cover ./internal/marketing/`; `run-all-tests.sh`. **Red control:** `Permalink` returning `"", nil` on an empty permalink field -> the empty-permalink case fails. | either | claude | tests | 1 |
| 08 `test(r49-08-api-spool-send-accepting-and-move)` | the on-box spool's `accepts` send, retired bounce, cross-dir move and mtime fallback under test | `SendKnownAccepting` (66.7), `atomicMove` (60.0), `fileTimeOrNow` (66.7) and `BounceRetired` (73.3) have untested error and fallback branches, and `spool` sits on its floor 89.2 | `go:internal/spool/spool.go:190` (`Store.SendKnownAccepting`, 66.7)<br>`go:internal/spool/spool.go:656` (`atomicMove`, 60.0)<br>`go:internal/spool/spool.go:822` (`fileTimeOrNow`, 66.7)<br>`go:internal/spool/retired.go:62` (`Store.BounceRetired`, 73.3)<br>`go:internal/spool/send_move_test.go` (new) | 4 functions at 60.0-73.3 | In `t.TempDir()` only: `SendKnownAccepting` with invalid `accepts` value -> validation error, with invalid `kind` to a retired-in-quarantine recipient -> compose error; `atomicMove` when `src` is missing -> error wrapping `fs.ErrNotExist`, when rename fails across a blocked target or fallback path -> covered; `fileTimeOrNow` on a non-existent path -> RFC3339 timestamp near now; `BounceRetired` on a known local recipient or invalid id -> nil. Non-test code unchanged. Helper names prefixed `sm`. Tests: `go test -count=1 -race -cover ./internal/spool/`; `run-all-tests.sh`. **Red control:** `SendKnownAccepting` skipping `m.Validate()` after setting `m.Accepts` -> the invalid-accepts case fails. | either | claude | tests | 1 |
| 09 `test(r49-09-api-wire-inner-and-model-name)` | the wire package's remaining three `< 75%` functions under test | `FleetTokenSample.ModelName` (66.7), `skipWS` (66.7) and `Envelope.Inner` (66.7) are the only functions under 75% left in `internal/wire` | `go:internal/wire/fleet_tokens.go:71` (`FleetTokenSample.ModelName`, 66.7)<br>`go:internal/wire/wire.go:883` (`skipWS`, 66.7)<br>`go:internal/wire/wire.go:1039` (`Envelope.Inner`, 66.7)<br>`go:internal/wire/inner_model_test.go` (new) | 3 functions at 66.7 | `ModelName`: `Model == nil` -> `""`, non-nil `"claude-opus-4-7"` -> `"claude-opus-4-7"`. `skipWS`: inputs with spaces, `\t`, `\n`, `\r` and all-whitespace slices -> expected index. `Envelope.Inner`: malformed JSON `Msg` -> parse error, structurally valid JSON `Msg` that fails `m.Validate()` (e.g. missing `task_id`) -> validation error, valid `Msg` -> `*msg.Message`. Non-test code unchanged. Helper names prefixed `im`. Tests: `go test -count=1 -race -cover ./internal/wire/`; `run-all-tests.sh`. **Red control:** `Envelope.Inner` skipping `m.Validate()` -> the invalid-inner-message case fails. | either | claude | tests | 1 |
| 10 `test(r49-10-gates-drop-stale-long-lines)` | a clean-code list holds only what is still over the cap | the lists "may only shrink", but a stale line lets a function grow back up to its old ceiling unnoticed; rows 01-04 leave 8 stale lines (and `r48-01..04` left 8 if `r48-10` has not run first) | `iac:t/bash-cleancode.tst.sh` (the `LONG` list)<br>`wui:tests/unit/cleancode.test.mjs` (the `LONG` list and its count comment) | 8 lines from `r49-01..04` (plus 8 from `r48-01..04` if `r48-10` has not landed first) | The lines rows 01-04 leave stale, named here, not as sites (as round 22 v0.2 row 10), lines as of `2149f6423`: `bash-cleancode.tst.sh` 37, 38 (and 28, 31, 32, 33, 35, 40 if `r48-10` has not landed before this row starts); `cleancode.test.mjs` 46, 49, 50, 54, 55, 56 (and 51, 57 if `r48-10` has not landed first), and its count comment at 38. Delete exactly the lines whose `NOTE LONG:` the gates print on the lane's start sha, no other line; a row of 01-04 not landed yet leaves its lines for the next round. Tests: `bash iac:t/bash-cleancode.tst.sh` and `node wui:tests/unit/cleancode.test.mjs` print no `NOTE LONG:` after; `bash iac:t/run-all-tests.sh`; `cd wui: && pnpm run test:unit`. R9: `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** the NOTE lines before (quoted), none after; FAIL count 0 both times. | either | claude | tests | 2 (after 01-04 and r48-10) |

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
  land, `r49-10` deletes both rounds' stale `NOTE LONG:` lines in one commit.
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
  2026-11-03T23:51:06Z, the exit code read directly from the command, never
  through a pipe). No path is printed as owned; 9 live lanes on `sat` record no
  files: `c-042` (`c002-issue-prio-by-class`), `c-044`
  (`c002-monitoring-refresh-tabs-row`), `c-045` (`c002-wui-msg-menu-no-wrap`),
  `c-050` (`c003-mobile-message-menu-3-dots`), `c-053`
  (`c002-s161-b2-agentid-cursor-codex`), `c-054`
  (`c001-bug-desk-box-key-pin-conflict`), `c-055`
  (`c002-s161-b3-codex-install-actions`), `c-059`
  (`c002-s119-t002a-app-channel-send`), and `c-613`
  (`c002-s166-b7-queue-refill`). None of their topics touch any of the 23 paths
  (card-message-menu composables `useCardMove` and `useCardMessageActions` were
  specifically left out for `c-045`/`c-050`). Exit 4 is not free: the dispatch
  holder re-runs the check before each row's spawn and asks any `unknown:` lane
  it cannot place this way.
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
  holds `api:src/bash/tests/go-coverage-floor.txt` (no row here touches it);
  `r48-10` holds `iac:t/bash-cleancode.tst.sh` and
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

- Editor: a-622 (agy). Panel reviewer: a cross-vendor seat named by the dispatch
  lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked
  with `do_spl_review_line_check`. A row with no reviewer for 15 minutes
  reports a blocker (2.7.3).
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
| measured on | `2149f6423`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (a-622): 10 rows, slug `r49`, measured on `2149f6423`.

## 9. Consensus

- Editor seat: a-622 (agy): drafted v0.1.
- Panel reviewer seat: pending placement by dispatch lease holder.
