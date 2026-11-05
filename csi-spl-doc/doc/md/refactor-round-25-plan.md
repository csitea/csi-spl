# Refactoring round 25 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4886  

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

**Why now.** c-001@sat's `SPAWN SUPPLY LEAD` blocker 20a33252 (task
spawn-share, 2026-11-05 ~17:0xZ): the night starts within 120 min and only 4
refactor rows are queued (floor 2 x 9). `./run -a do_spl_spawn_queue`
(2026-11-05T20:5xZ, <box>, this session) prints
`116 queued, 0 placing (fleet main)` and
`share of 21 known live lanes (14 unknown, left out): refactor 8 38% (band 40-60%: UNDER), bug 4 19% (band 30-40%: UNDER, 24 h top reached), feature 9 42% (band 0-%: ok); 328 bypass(es); phase night; last 24 h (47 sample(s)): refactor 9% (band 20-30%: UNDER), bug 31% (band 20-30%: OVER), feature 58% (band 40-%: ok)`.
Round 24 ([plan](refactor-round-24-plan.md), v1.0, slug `r50`) has rows 01-08
on `49af01917`:
`git log 49af01917 --oneline -E --grep='r50-0[1-8]' | wc -l` -> 8 (one commit
each, `adeec8faf` r50-01 through `00b8122ef` r50-08);
`git log 49af01917 --oneline -E --grep='r50-(09|10)' | wc -l` -> 0. Its batch 2
rows 09 (`go-coverage-floor.txt`) and 10 (`cleancode.test.mjs`) are placed
(asks `c87f1f88`, `6847a740`: state `done` at 20:11Z and 20:16Z), so **this
round touches neither file**. No round 22, 23 or 24 retro is on `49af01917`
(`ls csi-spl-doc/doc/md/refactor-round-*-retro.md` ends at
[refactor-round-21-retro.md](refactor-round-21-retro.md)); section 2
re-measures round 24's section 6 inputs instead.

Round 25 focus: **9 of the 10 rows run at once in batch 1**. Three rows take
back round 41's three cut rows (`r41-01..03`, declined on 2026-10-30 only for
reporting on an archived topic, see section 2), each pinning three untested
rules before it splits or narrows a grandfathered function; one row moves five
iac action headers above their `declare` line (round 20's unplaced `r46-04`
set); five rows put fifteen under-tested Go functions in five packages under
unit test. Batch 2 holds round 20's other unplaced header set (`r46-05`), which
shares the header baseline with row 04.

**Status: v0.1 DRAFT** (editor c-086; panel reviewer: a cross-vendor seat
named by the dispatch lease holder).

Editor: **c-086** (claude). Panel reviewer: named by the dispatch lease holder
(another vendor than claude). Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`49af01917`** (`origin/master`
49af01917e2841bffe0a3262c3aefb7ee8d84e30, 2026-11-05T21:39:32+01:00 /
20:39:32Z), n=1 per command unless stated. Go: go1.26.10. Node: v20.20.2.
Bash and Go runs are in the worktree at `49af01917` (clean); WUI runs are on a
`git archive 49af01917 csi-spl-wui` copy borrowing another checkout's
`node_modules`, read only. Go coverage is one
`go test -count=1 -coverprofile=<f> ./...` on <box> without Postgres (the store
and hub Postgres tests skip), read with `go tool cover -func=<f>`.

## 1. How to read this

- **Slug prefix `r51`.** `git log 49af01917 --oneline -E --grep='r51-' | wc -l`
  -> 0; `grep -rl 'r51-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0; `git branch -r | grep -c 'r51-'` -> 0. No `r51` lane. `r50` is taken
  (8 row commits, rows 09-10 placed). The next planner proves its prefix free
  the same way, and discounts briefs that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `api:` = `csi-spl-api/`, `wui:` = `csi-spl-wui/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/`,
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of
  `49af01917`; a bash or WUI site's line is the function's first line.
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat per
  row, named by the dispatch holder at placement. Each review line names the
  reviewer's vendor (rulebook 2.7.5).
- **Subject** (R6 reads it): `<type>(r51-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> -e <function> 49af01917 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; for Go, the package's tests plus
  `bash api:src/bash/tests/run-all-tests.sh`; for WUI, the unit test that
  loads the file and the e2e files the pre-push map selects.
- **Pin first, then change (rows 01-03).** Each of these rows first adds three
  cases for rules no test holds today, proves each red under its own planted
  break and green on the real code, and only then changes the function. The
  breaks are round 41's (its cutter, c-493@<box>, found them on 2026-10-30);
  section 2 re-checks that every line they name is unchanged.
- **Two gate files are off limits this round:**
  `api:src/bash/tests/go-coverage-floor.txt` (`r50-09`) and
  `wui:tests/unit/cleancode.test.mjs` (`r50-10`). So row 01 leaves its `LONG`
  line stale (the gate only NOTEs it: `checkLong`), and rows 05-09 leave their
  floor lines for round 26 (a deliberate deviation from the floor file's own
  `:4-5` rule, as in round 24). Row 02 deletes its line in
  `iac:t/bash-cleancode.tst.sh` and row 03 its line in
  `go:internal/cleancode/cleancode_test.go`: no other row touches either file.

## 2. Where the rows come from (measured on `49af01917`)

| source | input | command on `49af01917` | n | row / disposition |
|---|---|---|---|---|
| round 24 6 | the 3 WUI `LONG` functions | `node tests/unit/cleancode.test.mjs` (archive copy) | `cleancode: 13081 functions, 3 listed long, 17 listed wide, none deeper than 4 or wider than 5`; 6 `NOTE LONG:` lines (the r50-01..03 splits; `r50-10` deletes them) | `useCalendarDeepLinks` (78) -> **row 01**: round 24 held it for `r41-01`, whose ask was declined (below). `useCardMove` (80) and `useCardMessageActions` (80) **left out**: `dda94828` (`c003-move-to-topic-all-channels`) is still `queued` |
| round 24 6 | `r41-01..03` "briefed" | `git log 49af01917 -E --grep='r41-0[1-3]' --oneline \| wc -l`; the asks' state | 0 commits; asks `977a6301`, `946b6b31`, `a1094444` `declined` 2026-10-30T05:16Z, reason: c-001@sat ruling on `e22de82c`, the rows reported on archived topic `ad2cd4f0` (owner `0f58a0bc`). No branch: `git branch -r \| grep -c r41-` -> 0 | The sites are free: **rows 01, 02, 03** take them back under this round's task. Each row's pin lines re-read: `useCalendarDeepLinks.ts:45,81,101`, `spl-tenant-create.func.sh:53,104,110` and `box_lock_routes.go:240` unchanged (last commits `376600f83` 10-22, `d4c1478af` 10-15); `lockStatementOK` moved `533` -> `530` (`884c6b279`, 11-01), so its pin lines are now `:531` and `:542` |
| round 24 6 | the 7 bash `LONG` functions | `bash iac:t/bash-cleancode.tst.sh` | `PASS: the walk measured 6388 functions in 1143 files`, `PASS: no function over 75 lines outside LONG or over its ceiling (7 listed)`, 0 `NOTE LONG:` | `do_spl_tenant_create` (76) -> **row 02** (was `r41-03`). **Left out:** `spl_desk_pick` (80, `881adc37` still `queued`), `do_provision_firebase_dns` (169) and `spl_secret_unused_table` (76, header files; round 26 once rows 04 and 10 land), `spl_fleet_role_tick` (78), `_spawn_worktree` (79), `do_spl_agent_identity_restore` (80) (fleet-critical, as rounds 22-24) |
| round 24 6 | Go `wideFuncs` | `go test -count=1 ./internal/cleancode/` | ok; 15 `wideFuncs`, 2 `longFuncs`, 0 stale | `(*Server).lockStatementOK` (8 params) -> **row 03** (was `r41-02`); base `go test -count=1 -run 'BoxLock\|LockedHello' -v ./internal/hub/` -> 10 `--- PASS`, ok (was 8 at the r41 cut). The other 14 **left out**: `store` (Postgres twins) and `hub` merge/search/view, as rounds 22-24 |
| round 24 2 & 6 | round 20's declare-first iac files | `awk 'FNR==1{h=0;d=0} /^# *@(description\|param\|example)/{if(d){print FILENAME;nextfile};h=1} /^declare /{if(!h)d=1}' iac:run/*.func.sh orc:run/*.func.sh utl:run/*.func.sh \| wc -l`; `bash iac:t/action-header-tags.tst.sh`; asks, briefs and branches naming `r46-04` / `r46-05` | **30** files; `measured 784 files: 48 missing, 4 long-example`, `ALL PASS`; `r46-04`/`r46-05`: 0 commits, 0 asks, 0 briefs, 0 branches | Round 24 held these for `r46-04` and `r46-05`, which were never placed: **row 04** takes `r46-04`'s five files, **row 10** `r46-05`'s five. Each set is in `[missing]` (5 of 5 per set) with the same lines above the first `#---` and 0 `(required)` tokens. A stale `[missing]` line FAILS the tags test (its rule 3), so each row edits the baseline in its own commit: rows 04 and 10 are serial |
| round 24 6 | the 9 `(required)` header files | as round 24 | not re-measured | **Left out**: a behaviour change (bug-round input), as rounds 20-24 |
| round 24 6 | `keyexec` (5 functions), `keydesk` (3) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/keyexec ./internal/keydesk && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | reproduce: `keyexec` 5 at 66.7 (package 81.8), `keydesk` `peerOf` 71.4, `Seal` 66.7, `LoadOrCreateIdentity` 72.2 (88.8). `c-079@sat` is no longer a live lane (not in `lane-map.sh`) | **Left out**: queued `81ac0fa0` (`c002-bug-key-types-print-hardening`, state `queued`) names `internal/{keyexec,keydesk,store,vendorkey,marketing}` (round 24 section 3.2, read on sat by c-110; its brief is on sat, **unchecked** here) |
| round 24 6 | `files` `PutDir` (74.1) | `go tool cover -func` | reproduces (`files.go:57` 74.1, package 87.1) | **Left out**: a 1-function row; round 26 input with the floor raise |
| fresh | `action`: `who` 40.0, `pinRequest` 44.4, `Recv` 66.7 | `cd go: && go tool cover -func=all.out \| awk '$NF+0 < 75.0'` | `link.go:354`, `pin.go:184`, `action.go:347` (package 90.8, floor 90.8) | **Row 05**. `React` (64.7) left out: its uncovered part is the hub WebSocket call |
| fresh | `hubclient`: `writeAtomic` 46.2, `deskOutbox` 50.0, `saveRoster` 71.4 | as above | `hubclient.go:1276`, `reroute.go:187`, `hubclient.go:1214` (package 85.9, floor 85.9) | **Row 06** |
| fresh | `lockkey`: `ReadMeta` 66.7, `openKey` 71.4, `shred` 68.8 | as above | `store.go:74`, `store.go:218`, `store.go:328` (package 79.3, floor 78.7) | **Row 07**. `writeFile` (55.6) left out: its gaps are Write / Sync / Close failures |
| fresh | `channelmove`: `assetLocs` 63.6, `now` 66.7, `Open` 71.4 | as above | `objects.go:90`, `objects.go:76`, `objects.go:295` (package 94.5, floor 83.3) | **Row 08** |
| fresh | `payments`: `paypalKind` 50.0, `hostStatus` 62.5, `tenantURL` 71.4 | as above | `handler.go:736`, `handler.go:184`, `handler.go:164` (package 83.6, floor 83.6) | **Row 09** |
| fresh | other `< 75%` functions: `hubclient` (`agentProbe` 9.1, `WaitQueueEnd` 40.0, `serveSubmit` 45.5, `host*` 60-71), `keyd` (12), `lockkey` daemon (4), `payments` handlers (`paypalCapture` 45.0 and more), `gcpalerts.Run` 0.0, `mcp.Run` 0.0, `cloud.OSEnv` 0.0, `config.checkStorage` 70.6 | as above | 84 functions outside `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool` and the held packages | **Round 26 input**: the round is full |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r51-01-wui-pin-split-calendar-links)` | pin the untested rules of a long function, then split it into named steps | `useCalendarDeepLinks` (78) is listed over the 75-line cap, and no test loads it (`git grep -l useCalendarDeepLinks 49af01917 -- csi-spl-wui/tests` -> `tests/unit/cleancode.test.mjs` only) | `wui:src/composables/useCalendarDeepLinks.ts:31` (`useCalendarDeepLinks`, 78)<br>`wui:tests/unit/issue-calendar-link.test.mjs` (a new `describe`) | 1 function, 3 pins | **Pin first**, in a new `describe('the deep links (useCalendarDeepLinks)')` in `issue-calendar-link.test.mjs` (base `# tests 16`, `# pass 16`), stubbing the Nuxt auto-imports before `importTs('src/composables/useCalendarDeepLinks.ts')` as `/var/spool-hub/dispatch/briefs/c003-r41-01-wui-pin-calendar-links.md` row 01 spells out: **(A)** an event link opens its event once, not again on the next load of the week (break: `:45` `askedEvent = id` deleted -> peeks `['e1','e1']`); **(C)** closing the pop-over drops `issue=` by `router.replace` (break: `:81` -> `if (true) return` -> no replace); **(D)** a deadline outside the shown week moves the view to its day (break: `:101` `if (miss.moveTo) {` -> `if (false) {` -> moves `[]`). Each break turns only its own case red (paste the `not ok`), restored (`git diff --exit-code` on the `.ts`). **Then split** into file-local named steps (each at most 75 lines and 5 parameters); same name, input and returned object; `CalendarMainView.vue` not edited; no new text. Do **not** edit `cleancode.test.mjs` (`r50-10`'s file; the stale line is round 26 input). Tests: `node tests/unit/issue-calendar-link.test.mjs` (16 + 3); `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs` (FAIL 0, `NOTE LONG:` for it after); the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, on a mock bundle. **Control:** the three pins red under their breaks, green before and after the split. | either | claude | complex_coding | 1 |
| 02 `refactor(r51-02-orc-pin-split-tenant-create)` | as row 01, and drop its `LONG` line | `do_spl_tenant_create` (76) is listed over the cap; 8 of 9 planted breaks stay green against its two tests (round 41 cutter) | `orc:run/spl-tenant-create.func.sh:44` (`do_spl_tenant_create`, 76)<br>`orc:t/tenant-create.tst.sh` (a new section `# --- 6.`)<br>`iac:t/bash-cleancode.tst.sh` (its one `LONG` line) | 1 function, 3 pins, 1 list line | **Pin first** in `tenant-create.tst.sh` (base: 9 `PASS:` lines, rc 0), with the stub CLI `/var/spool-hub/dispatch/briefs/c003-r41-03-orc-pin-tenant-create.md` row 03 spells out: **(D)** a `DRY_RUN` other than 0 or 1 is refused before anything runs (break: `:53` -> `:`; `DRY_RUN=yes` creates, rc 0); **(K)** a `hub-tenant` refusal never prints the private key (break: the `return 1` at `:104` -> `:`); **(L)** an lde create returns 0 after the JSON and pins nothing (break: `:110` -> `:`; exits 4). Each red only under its own break (paste the `FAIL:`), restored. **Then split** into `_spl_tenant_create_*` steps beside the existing ones; keep the private temp dir, its `chmod 700` and its `RETURN` trap in `do_spl_tenant_create` itself (a helper's `RETURN` trap fires when the helper returns); same env contract, log lines, JSON printed once, return codes 1-4 and step order; callers not edited. Delete `csi-spl-orc/src/bash/run/spl-tenant-create.func.sh do_spl_tenant_create 76` from `LONG`. Tests: `tenant-create.tst.sh`, `tenant-create-pin-wui.tst.sh`, `tenant-host.tst.sh`, `run-log-no-key.tst.sh`, `demo-workspace-create.tst.sh`, `bash-cleancode.tst.sh` (the 6 test files that name it). R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** as row 01; `bash-cleancode.tst.sh` `(6 listed)` after. | either | claude | complex_coding | 1 |
| 03 `refactor(r51-03-api-pin-lock-statement-struct)` | pin the untested refusals of a wide function, then pass its inputs as one struct | `(*Server).lockStatementOK` takes 8 parameters and is listed in `wideFuncs` | `go:internal/hub/box_lock_routes.go:530` (`lockStatementOK`, 8 params)<br>`go:internal/hub/box_lock_routes_test.go` (3 subtests)<br>`go:internal/cleancode/cleancode_test.go:47` (its `wideFuncs` line) | 1 function, 3 pins, 1 list line | **Pin first** in `box_lock_routes_test.go` (give `newLockRig` a `mut ...func(*hub.Options)` passed to `rbacEnv`, every existing caller unchanged), as `/var/spool-hub/dispatch/briefs/c003-r41-02-api-lock-statement-struct.md` spells out, with this sha's lines: **(N)** a hub with no box-wui key answers 501 `unsupported` and writes no refused row (break: `:531` -> `if false {`); **(L)** a lift refused for a bad signature is audited on the lift path (break: the `refuseLock` at `:542` given `boxLockPathChange`); **(T)** a nonce older than 300 s is refused 400 `stale_nonce` (break: `:240` drops `&& age <= boxLockNonceTTL`). Each red only under its own break (paste the `--- FAIL:`), restored. **Then** one unexported struct for the statement (e.g. `lockStatement{nonce, sig, text, path string}`) built by `handleChangeBoxLock` (`:459`) and `handleLiftBoxLock` (`:502`); refusal order (501, nonce, signature), codes, tokens and audit rows unchanged; `BoxLockChangeStatement` / `BoxLockLiftStatement`, `boxLockNonceOK`, `refuseLock`, `ownedLock` not touched. Delete the `wideFuncs` line, gofmt-clean. Tests: `go test -count=1 -run 'BoxLock\|LockedHello' -v ./internal/hub/` (10 + 3 `--- PASS`); `go test -count=1 ./internal/hub/ ./internal/cleancode/`; `run-all-tests.sh`; a hub handler: `PRE_PUSH_TIER=full` (Postgres), naming the box lock tests that ran there. **Control:** as row 01. | either | claude | complex_coding | 1 |
| 04 `refactor(r51-04-iac-header-declare-below-gcp-data)` | an action opens with its header, its `declare` line below it (round 20's `r46-03` practice) | the loader stops at the first command, so a `declare` line above the header leaves `./run` help blank for the action; round 20's `r46-04` set was never placed | `iac:run/gcp-copy-secret.func.sh:2`<br>`iac:run/gcp-fetch-secrets.func.sh:2`<br>`iac:run/gcp-export-dns.func.sh:2`<br>`iac:run/gcp-import-to-cloudsql.func.sh:2`<br>`iac:run/gcp-backup-env.func.sh:2` (+ their 5 `[missing]` lines in `iac:t/action-header-tags-baseline.txt`) | 5 files | As `15789e9ea` (`r46-03`): the lines above the first `#---` after the shebang (the `# shellcheck source=` directive, the `declare -F spl_gcp_temp_sdk_config ... \|\| source ...` line and, where present, the blank line) move unchanged to just below the header's closing `#---`; nothing else moves; the 5 `[missing]` lines are deleted in the same commit (the tags test FAILS a stale one). Tests: `action-header-tags.tst.sh` (`48 missing` -> `43`), `gcp-exit-status-checks.tst.sh`, `return-not-exit-gcp.tst.sh`, `gcp-misc-actions.tst.sh`, `adhoc-harvest-gcp-actions.tst.sh`, `gcp-temp-sdk-config.tst.sh`, `parse-metadata-nofork.tst.sh`; `./run -a do_check_pre_push_lint` (shellcheck). **Red control:** on the parent sha `do_parse_metadata <f> \| grep -c '^description='` -> 0 per file; after -> at least 1 per file; `grep -ciE '^# *@param .*\(required\)'` -> 0 per file (no new refusal). | either | claude | simple_coding | 1 |
| 05 `test(r51-05-api-action-who-pin-recv)` | three CLI action helpers under test | `who` (40.0), `pinRequest` (44.4: its revoke branch) and `Recv` (66.7: its nil-result and empty-inbox branches) | `go:internal/action/link.go:354` (`Desks.who`, 40.0)<br>`go:internal/action/pin.go:184` (`pinRequest`, 44.4)<br>`go:internal/action/action.go:347` (`Recv`, 66.7)<br>`go:internal/action/who_pin_recv_test.go` (new) | 3 functions at 40.0-66.7 | In `package action`, `t.TempDir()` only. `who`: a non-empty `who` -> itself; `Desks{Box: "b1"}` -> `"box b1"`; `Desks{Base: <config with BoxID "b2">}` -> `"box b2"`; neither -> `"this box"`. `pinRequest(PinArgs{Revoke: true, Box: "b1"}, priv, ts)` -> `DELETE`, `/v1/pins/b1`, a `wire.RevokeRequest` whose `Sig` verifies (`ed25519.Verify`) over `wire.RevokePayload("b1", ts)`; without `Revoke` -> `POST`, `/v1/pins`, a `wire.PinRequest` verifying over `wire.PinPayload`. `Recv(cfg, as, false)` with the spool root in `t.TempDir()`: an invalid agent id -> `nil` slice and an error; a valid id with an empty inbox -> a non-nil empty slice and `nil`. The payload error branches (`pin.go:187,193`) stay uncovered: `wire.Canonical` cannot fail on strings. Non-test code unchanged; do **not** edit `go-coverage-floor.txt` (round 26). Helpers prefixed `wp`. Tests: `go test -count=1 -race -cover ./internal/action/`; `run-all-tests.sh`. **Red control:** `who` returning `"this box"` before the `d.Box` case -> the `"box b1"` case fails. | either | claude | tests | 1 |
| 06 `test(r51-06-api-hubclient-write-atomic-roster)` | the hub client's atomic writer and its two log-only callers under test | `writeAtomic` (46.2) has its `MkdirAll` and `CreateTemp` error branches untested; `saveRoster` (71.4) and `deskOutbox` (50.0) their failure logs | `go:internal/hubclient/hubclient.go:1276` (`writeAtomic`, 46.2)<br>`go:internal/hubclient/hubclient.go:1214` (`Client.saveRoster`, 71.4)<br>`go:internal/hubclient/reroute.go:187` (`Client.deskOutbox`, 50.0)<br>`go:internal/hubclient/write_atomic_test.go` (new) | 3 functions at 46.2-71.4 | In `t.TempDir()` only. `writeAtomic`: parent path an existing regular file -> error; parent an existing `0500` directory (restored by `t.Cleanup`, skipped when `os.Geteuid() == 0`) -> error; a valid path -> the bytes written and no `.tmp-*` left in the directory. `saveRoster(nil)` -> `roster.json` holds `{}`; with the hub dir an existing regular file -> no panic, and the client's logger (a `zerolog` to a buffer) holds `roster cache not written`. `deskOutbox(m)` on a spool root it cannot write -> the buffer holds `re-route: no outbox copy on the desk` and the message id. The write and close error branches (`:1284-1292`) stay uncovered. Non-test code unchanged; floor file not edited. Helpers prefixed `wr`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Red control:** `saveRoster` dropping its `r == nil` default -> the `{}` case reads `null` and fails. | either | claude | tests | 1 |
| 07 `test(r51-07-api-lockkey-meta-open-shred)` | the lock key store's meta reader, key opener and shredder under test | `ReadMeta` (66.7) has its not-sealed, read-error and malformed branches untested (`store.go:76-85`); `openKey` (71.4) its read-error and wrong-key branches; `shred` (68.8) its stat-error branch | `go:internal/lockkey/store.go:74` (`ReadMeta`, 66.7)<br>`go:internal/lockkey/store.go:218` (`openKey`, 71.4)<br>`go:internal/lockkey/store.go:328` (`shred`, 68.8)<br>`go:internal/lockkey/meta_open_test.go` (new) | 3 functions at 66.7-71.4 | In `t.TempDir()` only, keys generated in the test. `ReadMeta`: no `lock.json` -> `ErrNotSealed`; `lock.json` a directory -> an error that is not `ErrNotSealed`; invalid JSON, `"v": 2`, or a bad tenant / box id -> `lock.json is malformed`. `openKey`: a missing path -> error starting `read <basename>:`; a key that opens but whose public key differs from `wantPub` -> `the opened key does not match lock.json`; the matching key -> the private key. `shred`: a path under a regular file (stat `ENOTDIR`) -> error; a missing path -> `nil`; a file -> gone. Write / Sync failures (`:340-347`) stay uncovered. Non-test code unchanged; floor file not edited. Helpers prefixed `mo`. Tests: `go test -count=1 -race -cover ./internal/lockkey/`; `run-all-tests.sh`. **Red control:** `ReadMeta` dropping `m.V != 1` -> the `"v": 2` case fails. | either | claude | tests | 1 |
| 08 `test(r51-08-api-channelmove-asset-locs-open)` | the channel move's picture locations, clock and attachment read under test | `assetLocs` (63.6) has its bad-id, docs-error and nil-store branches untested; `now` (66.7) its injected clock; `Open` (71.4) its bad-id and holder-error branches | `go:internal/channelmove/objects.go:90` (`Objects.assetLocs`, 63.6)<br>`go:internal/channelmove/objects.go:76` (`Objects.now`, 66.7)<br>`go:internal/channelmove/objects.go:295` (`Objects.Open`, 71.4)<br>`go:internal/channelmove/asset_locs_test.go` (new) | 3 functions at 63.6-71.4 | In-memory stores and a stub `Holder` only. `assetLocs`: an id that is not a sha256 hex -> error; `Docs == nil` -> one place (the files key `t/<tenant>/files/<id>`); `Docs` returning an error -> error prefixed `docs store of <tenant>:`; `Docs` returning a nil store -> one place; a store -> two places, the docs one first. `now`: `Now` set -> its time; unset -> within a second of `time.Now()`. `Open`: a bad id -> `blob.ErrNotFound`; a `Holder` whose `FileAttached` errors -> that error; not held -> `blob.ErrNotFound`. Non-test code unchanged; floor file not edited. Helpers prefixed `al`. Tests: `go test -count=1 -race -cover ./internal/channelmove/`; `run-all-tests.sh`. **Red control:** `assetLocs` returning `[]loc{f}` when `st != nil` -> the two-places case fails. | either | claude | tests | 1 |
| 09 `test(r51-09-api-payments-kind-url-host-status)` | three payment helpers' untested branches under test | `paypalKind` (50.0) has its refund and ignore branches untested; `tenantURL` (71.4) its bad-claim-URL branch; `hostStatus` (62.5) its read-error branch | `go:internal/payments/handler.go:736` (`paypalKind`, 50.0)<br>`go:internal/payments/handler.go:164` (`Handler.tenantURL`, 71.4)<br>`go:internal/payments/handler.go:184` (`Handler.hostStatus`, 62.5)<br>`go:internal/payments/kind_url_status_test.go` (new) | 3 functions at 50.0-71.4 | In `package payments`, no network, no key on disk. `paypalKind`: `PAYMENT.CAPTURE.COMPLETED` -> `store.PayEventPaid`; `PAYMENT.CAPTURE.REFUNDED` and `PAYMENT.CAPTURE.REVERSED` -> `store.PayEventRefund`; `CHECKOUT.ORDER.APPROVED` and `""` -> `store.PayEventIgnore`. `tenantURL`: `ClaimURL` `""`, `"not a url"` (no host) or `"%zz"` (parse error) -> `""`; `https://app.example.com/claim` -> the `invitemail.SignInURL` link for the tenant. `hostStatus`, with a `Store` stub embedding the `payments.Store` interface and overriding `TenantHost`: an error other than `store.ErrNotFound` -> `"unknown"` and a `checkout: tenant host status read` warn in the logger's buffer; `store.ErrNotFound` -> `"unknown"` and no warn (`host_status_test.go` covers the status rows). Non-test code unchanged; floor file not edited. Helpers prefixed `ku`. Tests: `go test -count=1 -race -cover ./internal/payments/`; `run-all-tests.sh`. **Red control:** `paypalKind` dropping `"PAYMENT.CAPTURE.REVERSED"` -> the reversed case returns ignore and fails. | either | claude | tests | 1 |
| 10 `refactor(r51-10-iac-header-declare-below-spl-secret)` | as row 04 | as row 04, round 20's `r46-05` set | `iac:run/spl-secret-age-report.func.sh:2`<br>`iac:run/spl-secret-rotate.func.sh:2`<br>`iac:run/spl-secret-scan-alert-triage.func.sh:2`<br>`iac:run/spl-secret-version-disable-old.func.sh:2`<br>`iac:run/spl-kms-check.func.sh:2` (+ their 5 `[missing]` lines) | 5 files | As row 04, on the start sha after row 04 lands (`43 missing` -> `38`). Tests: `action-header-tags.tst.sh`, `spl-secret-age-report.tst.sh`, `spl-secret-unused-list.tst.sh`, `spl-secret-rotate.tst.sh`, `spl-secret-scan-alert-triage.tst.sh`, `spl-secret-version-disable-old.tst.sh`, `spl-kms-check.tst.sh`, `gcp-temp-sdk-config.tst.sh`, `parse-metadata-nofork.tst.sh`; `./run -a do_check_pre_push_lint`. **Red control:** as row 04. | either | claude | simple_coding | 2 (after 04) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-09, no file in two rows.** Row 01 owns
  `useCalendarDeepLinks.ts` and `issue-calendar-link.test.mjs`; row 02
  `spl-tenant-create.func.sh`, `tenant-create.tst.sh` and
  `bash-cleancode.tst.sh`; row 03 `box_lock_routes.go`,
  `box_lock_routes_test.go` and `cleancode_test.go`; row 04 its five iac
  actions and `action-header-tags-baseline.txt`; rows 05-09 one Go package
  each (`action`, `hubclient`, `lockkey`, `channelmove`, `payments`) plus one
  new `*_test.go` each, and change no non-test code. None edits
  `go-coverage-floor.txt`, `cleancode.test.mjs`, a migration, `csi-spl-cnf/`,
  a workflow or terraform.
- **Batch 2: row 10** shares `action-header-tags-baseline.txt` with row 04 and
  is placed within 30 minutes of row 04 landing (R16).
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder places
  any two batch 1 rows, then the next as each lands. Suggested order: one Go
  test row with one of rows 01-04, so the two lanes run different suites.

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 25 site and gate files of rows 01-04 and 10, plus the keyexec / keydesk / files sites, comma separated> --agent c-086`
  -> **exit 4** (<box>, 2026-11-05T20:54:44Z, exit code read directly), and the
  same for the 8 Go site files of rows 05-09 a few minutes later. No path is
  printed as owned. Six live lanes on `sat` record no files: `c-100`
  (`c002-bug-lanes-not-null-discussion-issue`), `c-191`
  (`c002-s164-b2-channel-box-pins-routes`), `c-198` and `c-199` (`-rotate`),
  `c-201` (`c002-spl4806-marketing-howto-fix`), `c-613` (`-rotate-2`). Exit 4
  is not free: **`c-191`'s box pin routes may touch `internal/hub/`**, so the
  dispatch holder asks it before placing row 03, and re-runs the check before
  each row's spawn.
- **Spawn queue (2026-11-05T20:5xZ):** `./run -a do_spl_spawn_queue` -> 116
  queued, 0 placing; their `.md` briefs are on `sat`, **unchecked** here. Every
  `/var/spool-hub/asks/*.json` with `"state": "queued"` (116) grepped for the
  row site basenames, function names and package paths (`useCalendarDeepLinks`,
  `issue-calendar-link`, `spl-tenant-create`, `tenant-create.tst`,
  `bash-cleancode`, `box_lock`, `lockStatementOK`, `cleancode_test`,
  `action-header-tags`, the ten iac basenames, `internal/action`,
  `hubclient`, `lockkey`, `channelmove`, `payments`, `paypalKind`,
  `hostStatus`, `tenantURL`, `writeAtomic`, `saveRoster`, `deskOutbox`,
  `ReadMeta`, `assetLocs`) -> **0** matches. `keyexec` / `keydesk` stay out
  for `81ac0fa0`; `useCardMove` / `useCardMessageActions` for `dda94828`.
- **Open rows from earlier rounds:** `r50-09` holds `go-coverage-floor.txt`,
  `r50-10` holds `cleancode.test.mjs`; no row here touches either.

## 4. Per row: what the lane does

- **01:** Pin three deep-link rules, then split `useCalendarDeepLinks` into named steps.
- **02:** Pin three tenant-create rules, split `do_spl_tenant_create`, delete its bash `LONG` line.
- **03:** Pin three box lock refusals, pass `lockStatementOK`'s statement as a struct, delete its `wideFuncs` line.
- **04:** Move the `declare` line below the header in five gcp data actions; drop their 5 baseline lines.
- **05:** Unit tests for `action` `who`, `pinRequest` and `Recv`.
- **06:** Unit tests for `hubclient` `writeAtomic`, `saveRoster` and `deskOutbox`.
- **07:** Unit tests for `lockkey` `ReadMeta`, `openKey` and `shred`.
- **08:** Unit tests for `channelmove` `assetLocs`, `now` and `Open`.
- **09:** Unit tests for `payments` `paypalKind`, `tenantURL` and `hostStatus`.
- **10:** As 04 for five spl secret and kms actions, after 04.

## 5. Panel and reviewers (R7)

- Editor: c-086 (claude). Panel reviewer: a cross-vendor seat named by the
  dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked with
  `do_spl_review_line_check`. A row with no reviewer for 15 minutes reports a
  blocker (2.7.3).
- **P1, for the panel:** rows 01-03 take back `r41-01..03`. Their asks were
  declined because they reported on archived topic `ad2cd4f0`, not for their
  content; this round reports on its own task (`dispatch-refactor-r25`). Rows
  01-03 point at the round 41 cutter's planted breaks and stub setups by brief
  path rather than restating them; the briefs are on <box>
  (`/var/spool-hub/dispatch/briefs/`). The dispatch holder copies the named
  row of that brief into the row brief when it places the row on another box.
- **P2, for the panel:** rows 05-09 leave `go-coverage-floor.txt` to round 26
  (`r50-09` holds it), and row 01 leaves its stale `LONG` line to round 26
  (`r50-10` holds `cleancode.test.mjs`).
- **P3, for the panel:** rows 04 and 10 are serial on the header baseline, so
  only row 04 is in batch 1.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `useCardMove` (80), `useCardMessageActions` (80) | queued `dda94828` | section 2 |
| row 01's stale `LONG` line; rows 05-09's floor raises (`action`, `hubclient`, `lockkey`, `channelmove`, `payments`) and round 24's | `cleancode.test.mjs` and `go-coverage-floor.txt` are `r50-10`'s and `r50-09`'s; **input for round 26** | section 1 |
| bash `LONG`: `spl_desk_pick` (80) | queued `881adc37` | section 2 |
| bash `LONG`: `do_provision_firebase_dns` (169), `spl_secret_unused_table` (76) and the other 20 declare-first files | header files; **input for round 26** once rows 04 and 10 land | section 2 |
| bash `LONG`: `spl_fleet_role_tick` (78), `_spawn_worktree` (79), `do_spl_agent_identity_restore` (80) | fleet-critical, as rounds 22-24 | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| `keyexec` (5), `keydesk` (3) | queued `81ac0fa0` | section 2 |
| `files` `PutDir` (74.1), `action` `React` (64.7), `lockkey` `writeFile` (55.6), the 84 other `< 75%` functions of section 2 | round full, or only I/O-failure gaps; **input for round 26** | `go tool cover -func` on `49af01917` |
| Go `longFuncs` and the other 14 `wideFuncs`, `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool`, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | as rounds 22-24 section 2 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 5, test 5; wui 1, orc 1, Go 6, iac 2) |
| vendor | claude 10 |
| kind | complex_coding 3, simple_coding 2, tests 5 |
| batches | batch 1: rows 01-09 (9 at once); batch 2: row 10 |
| pins added | 9 (rows 01-03) |
| WUI functions over 75 | 3 -> 2 after row 01 |
| bash functions over 75 | 7 -> 6 after row 02 |
| Go `wideFuncs` | 15 -> 14 after row 03 |
| header-tags `[missing]` | 48 -> 43 after row 04 -> 38 after row 10 |
| Go functions taken | 15 at 40.0-71.4 |
| measured on | `49af01917`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-086): 10 rows, slug `r51`, measured on `49af01917`.

## 9. Consensus

- Editor seat: c-086 (claude): drafted v0.1.
- Panel reviewer seat: to be named by the dispatch lease holder.
