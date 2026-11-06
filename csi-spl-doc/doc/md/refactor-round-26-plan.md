# Refactoring round 26 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4923  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: the 8 rows of
  batch 1 share no file (section 3.1), so any two of them can run at once.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows: **vendor
  claude for every row**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** c-001's `SPAWN SUPPLY LEAD` blocker 481b4f92 (task spawn-share,
2026-11-06 ~17:0xZ): the night starts within 120 min and 1 refactor row is
queued (floor 2 x 5). `./run -a do_spl_spawn_queue` (2026-11-06T19:5xZ, this
session) prints `130 queued, 0 placing (fleet main)` and
`share of 11 known live lanes (13 unknown, left out): refactor 3 27% (band 40-60%: UNDER), bug 2 18% (band 30-40%: UNDER), feature 6 54% (band 0-%: ok); 1291 bypass(es); phase night; last 24 h (130 sample(s)): refactor 14% (band 20-30%: UNDER), bug 17% (band 20-30%: UNDER), feature 67% (band 40-%: ok)`.
The plan is written after the night started, so its rows are wanted at once.

Round 25 ([plan](refactor-round-25-plan.md), v1.0, slug `r51`) has rows 01-09 on
`4e2b8d70e`:
`git log 4e2b8d70e --oneline -E --grep='^(refactor|test)\(r51-' | wc -l` -> 9.
Its row 10 is not on it (`git log 4e2b8d70e --oneline --grep='r51-10' | wc -l`
-> 0) and is in a live lane: `lane-map.sh` lists c-266, whose branch diff holds
the 5 spl secret and kms actions and `action-header-tags-baseline.txt`. The
brief's "rows 03 and 09 are in lanes" is older than this sha: both landed
(`4e2b8d70e`, `f63c3713c`). **This round still touches no site of r51-03, r51-09
or r51-10**, as the brief says. No round 22-25 retro is on `4e2b8d70e`
(`ls csi-spl-doc/doc/md/refactor-round-*-retro.md | sort -V | tail -1` ->
[refactor-round-21-retro.md](refactor-round-21-retro.md)); section 2 re-measures
round 25's section 6 inputs instead.

Round 26 focus: **8 of the 10 rows run at once in batch 1.** Two rows split the
last two WUI functions over the cap, now that the queued feature that held them
has landed; one splits a bash function; two take WUI functions off the wide list;
one raises the five floors round 25 left; three put ten under-tested Go functions
under unit test. Batch 2 and 3 are the second WUI split, which reuses the first
one's test loader, and the row that deletes the gate lines the others left.

**Status: v0.1 DRAFT**, for the panel (section 9).

Editor: **c-267** (claude). Panel reviewer: named by the dispatch lease holder
(another vendor than claude). Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`4e2b8d70e`** (`origin/master`
4e2b8d70e7b18b4b9f84f7992b454d3ac005d968, 2026-11-06T21:15:33+02:00 /
19:15:33Z), n=1 per command unless stated. Go: go1.26.10. Node: v20.19.2. Bash
and Go runs are in the worktree at `4e2b8d70e` (clean); WUI runs are on a
`git archive 4e2b8d70e csi-spl-wui` copy borrowing another checkout's
`node_modules`, read only. Go coverage is one
`go test -count=1 -coverprofile=<f> ./...` on <box> without Postgres (the store
and hub Postgres tests skip; rc 0, 0 `FAIL` lines), read with
`go tool cover -func=<f>`. Uncovered branches are read from the same profile (the
blocks with count 0).

## 1. How to read this

- **Slug prefix `r52`.** `git log 4e2b8d70e --oneline -E --grep='r52-' | wc -l`
  -> 0; `grep -rl 'r52-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0; `git branch -r | grep -c 'r52-'` -> 0. No `r52` lane. `r51` is taken
  (see above). The next planner proves its prefix free the same way, and
  discounts briefs that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `wui:` = `csi-spl-wui/`,
  `api:` = `csi-spl-api/`, `go:` = `csi-spl-api/src/go/spool-hub-api/`;
  `run/` = `src/bash/run/`, `t/` = `src/bash/tests/` of the sub-project named.
  Lines as of `4e2b8d70e`; a bash or WUI site's line is the function's first
  line.
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat per
  row, named by the dispatch holder at placement. Each review line names the
  reviewer's vendor (rulebook 2.7.5).
- **Subject** (R6 reads it): `<type>(r52-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above; rows report there,
  never on an archived topic.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> 4e2b8d70e -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; **bold** = it reads the site's source text. For Go, the
  package's tests plus `bash api:src/bash/tests/run-all-tests.sh`; for WUI, the
  unit tests and the e2e files the pre-push map selects
  (`cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`).
- **Pin first, then change (rows 01-03).** Each of these rows first adds three
  cases for rules no test holds today, proves each red under its own planted
  break and green on the real code, and only then changes the function.
- **Three gate files are shared this round, so each is one row's:**
  `api:src/bash/tests/go-coverage-floor.txt` is row 06's, `iac:t/bash-cleancode.tst.sh`
  row 03's, `wui:tests/unit/cleancode.test.mjs` row 10's. So rows 01, 02, 04 and
  05 leave their `LONG` / `WIDE` lines stale (the gate only NOTEs a stale line:
  `checkLong`, `checkWide`) for row 10, and rows 07-09 leave their floor lines for
  round 27 (the same deliberate deviation from the floor file's `:4-5` rule as
  rounds 24 and 25).

## 2. Where the rows come from (measured on `4e2b8d70e`)

**Taken:**

| source | input | command on `4e2b8d70e` | n | row |
|---|---|---|---|---|
| round 25 6 | `useCardMove` (80), `useCardMessageActions` (80), held for queued `dda94828` | `node tests/unit/cleancode.test.mjs` (archive copy); `git log 4e2b8d70e -i --grep='move to topic' -1 --format='%h %s'`; `grep -c dda94828` on the queue output | `cleancode: 13099 functions, 2 listed long, 17 listed wide, none deeper than 4 or wider than 5`. The hold is gone: `f738fd9fc` (SPL-4892) landed that feature, 0 queue lines | **Rows 01, 02** |
| round 25 6 | row 01's stale `LONG` line | same run | `NOTE LONG: 'src/composables/useCalendarDeepLinks.ts useCalendarDeepLinks' is no longer over 75 lines - delete its line` (1 NOTE); `r50-10` landed (`11f6b8c03`), so the file is free | **Row 10** |
| round 25 6 | `spl_secret_unused_table` (76) | `bash iac:t/bash-cleancode.tst.sh` | `PASS: the walk measured 6442 functions in 1148 files`, `PASS: no function over 75 lines outside LONG or over its ceiling (6 listed)` | **Row 03**. Round 25 held it "once rows 04 and 10 land" for its `declare` lines. The split leaves those lines and the baseline alone, and c-266's diff does not hold the file, so it need not wait |
| round 25 6 | the floor raises of `action`, `hubclient`, `lockkey`, `channelmove`, `payments` | package coverage above, against `go-coverage-floor.txt` | read / floor: 91.6 / 90.8, 86.1 / 85.9, 80.8 / 79.3, 96.3 / 83.3, 84.3 / 83.6; `r50-09` landed (`c95343db0`), so the file is free | **Row 06**. The `payments` floor line is no site of r51-09 (`handler.go` and its test), which landed |
| round 25 2 | the 84 other `< 75%` functions | `go tool cover -func=<f> \| awk '$NF+0 < 75.0'`, minus `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `keyexec`, `keydesk`, `vendorkey`, `marketing`, `payments`, `cmd/spool` | **57** functions (this list also leaves out `vendorkey`, `marketing` and `payments`, round 25's did not) | **Rows 07, 08, 09** take ten: `hubclient` `agentProbe` 9.1, `serveSubmit` 45.5, `keepRun` 0.0; `keyd` `InitOwner` 63.2, `openScrypt` 64.7, `Status` 64.3; `lockkey` `Seal` 70.0, `Reseal` 71.4, `limited.Read` 71.4, `Sealer.Seal` 70.6 |
| fresh | the 17 WUI `WIDE` functions | `grep -n` on `wui:tests/unit/cleancode.test.mjs:50-68` and each function's callers | 17 listed; the other 15 not read one by one. The two read here are file-local: `send` (`calendar-events-api.mjs:34`, 3 callers) and `mockPart` (`tenant-costs.mjs:360`, 15 callers, mock data only) | **Rows 04, 05** |

**Deferred or dropped:**

| source | input | command on `4e2b8d70e` | n | disposition |
|---|---|---|---|---|
| round 25 6 | `do_provision_firebase_dns` (169) | `sed -n 28,30p iac:t/wui-hosting-019-031.tst.sh` | that test passes only while the file is **byte-identical** to the other project's copy it was ported from (a `sha256sum` against `want_sha`) | **Dropped as an input.** Its size is not the reason: a split would break the port pin, so this is an owner-level port decision and no refactor row. Round 25 carried it as a header file and did not name this |
| round 25 6 | the other 20 declare-first files | `awk 'FNR==1{h=0;d=0} /^# *@(description\|param\|example)/{if(d){print FILENAME;nextfile};h=1} /^declare /{if(!h)d=1}' iac:run/*.func.sh orc:run/*.func.sh utl:run/*.func.sh \| wc -l`; `bash iac:t/action-header-tags.tst.sh` | **25** files, 5 of them r51-10's; `measured 787 files: 43 missing, 4 long-example` | **Round 27.** A stale `[missing]` line FAILS the tags test, so each header row edits `action-header-tags-baseline.txt`, which r51-10 holds in a live lane. **20** files wait for it |
| round 25 6 | `spl_desk_pick` (80) | the queue output | queued `881adc37` still line 8 of 130 | **Left out** |
| round 25 6 | `spl_fleet_role_tick` (78), `_spawn_worktree` (79), `do_spl_agent_identity_restore` (80) | as row 03's | all three still listed | **Left out**: fleet-critical, as rounds 22-25 |
| round 25 6 | the `(required)` header files | `awk '/^\[missing\]/{m=1;next} /^\[/{m=0} m && /^csi-spl-/' iac:t/action-header-tags-baseline.txt \| xargs grep -l '(required)' \| wc -l` | **9**: reproduces | **Left out**: a behaviour change (bug-round input), as rounds 20-25 |
| round 25 6 | `keyexec` (5), `keydesk` (3) | `go tool cover -func` | 5 and 3: reproduce | **Left out**: queued `81ac0fa0` line 69 of 130; its brief on this box, read, names `internal/keyexec/desk.go` and `internal/keydesk/{keydesk,seal}.go`. It also names `store`, `vendorkey` and `marketing`. A grep for `internal/keyd` also hits it, but only through `internal/keydesk`: **`keyd` is free** |
| round 25 6 | `hubclient` `WaitQueueEnd` (40.0) | queued briefs, grep | queued `e8104df3` (`c002-bug-lane-map-hub-read-errors`) edits `internal/hubclient/hubclient.go` | **Left out**, as every other site in that file |
| round 25 6 | `files` `PutDir` (74.1), `action` `React` (64.7), `lockkey` `writeFile` (55.6) | `go tool cover -func` | all three reproduce | **Round 27**: a 1-function row, the hub WebSocket call, or Write / Sync failures only |
| round 25 6 | the 3 floors no row of round 25 raised: `mcp` 90.0 / 88.7, `invitemail` 87.8 / 85.3, `notify` 96.6 / 94.8 | as row 06 | read / floor, over by more than 1 point | **Round 27**: a row holds at most 5 sites |
| round 25 6 | Go `longFuncs` (2) and the other 14 `wideFuncs` | `sed -n 45,58p go:internal/cleancode/cleancode_test.go \| wc -l` -> 14; `go test -count=1 -v ./internal/cleancode/ \| grep -c 'no longer'` -> 0 | 14 wide, 2 long, 0 stale | **Left out**: `store` (Postgres twins), `auth` and `hub` merge / search / view, as rounds 22-25 |
| round 25 6 | `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool`; WUI raw text; gosec / semgrep; shellcheck WARNING baseline | **not re-measured** | none | **Left out**, as rounds 22-25. Named here so the gap is visible: the brief asks to re-measure each input, and these were carried over without it |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r52-01-wui-pin-split-card-move)` | pin the untested rules of a long function, then split it into named steps | `useCardMove` (80) is listed over the 75-line cap, and no test loads it (`git grep -l useCardMove 4e2b8d70e -- csi-spl-wui/tests` -> `cleancode.test.mjs` and **`lib/message-card-src.mjs`**, both source readers) | `wui:src/composables/useCardMove.ts:68` (`useCardMove`, 80)<br>`wui:tests/unit/lib/load-ts-stubbed.mjs` (new)<br>`wui:tests/unit/card-move-steps.test.mjs` (new) | 1 function, 3 pins, 1 loader | `importTs` cannot load this file: a runtime `from 'vue'` fails on a data: URL, and its real imports reach `vue-router` and `pinia` (probed, n=1). So first a new `importTsStubbed(rel, stubs)` in `load-ts-stubbed.mjs`, about 15 lines: transpile, resolve `vue` with `import.meta.resolve`, swap each named specifier for a stub, keep other `~/` imports real, throw on anything else. `load-ts.mjs` not edited: 80 files under `csi-spl-wui/tests` name it (`git grep -c load-ts.mjs 4e2b8d70e -- csi-spl-wui/tests \| wc -l`). Stub `useMove`, `useLive`, `useMobileStack` and `useCardSwipe`, with a `window` that records its `keydown` listener. **Pin first:** **(A)** a topic card lifts `kind: 'topic'`, a thread row `kind: 'message'` with `topicTask` from `moveCtx` (break: `:84` `canMoveTopic.value` -> `true`); **(B)** only Escape cancels: another key leaves `cancelRowDrag` uncalled, Escape calls it once and `preventDefault` (break: `:89` deleted); **(C)** a phone's touch hold opens Move to channel… (break: `:122` -> `return true`; `movePicker` stays `''`). All three behaviours were read in a scratch probe on the real file (n=1); the breaks were not planted. Each break turns only its own case red (paste the `not ok`), restored. **Then split** into file-local named steps (each at most 75 lines and 5 parameters); same name, six parameters and returned object; `MessageCard.vue` not edited; no new text. Leave the `LONG` and `WIDE` lines (row 10). Tests: `node --test tests/unit/card-move-steps.test.mjs`; **`msg-merge.test.mjs`** and the other readers of **`lib/message-card-src.mjs`** (keep every step in `useCardMove.ts`); `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs` (FAIL 0, a `NOTE LONG:` for it after); the e2e files the map selects, on a mock bundle. **Control:** the three pins red under their breaks, green before and after the split. | either | claude | complex_coding | 1 |
| 02 `refactor(r52-02-wui-pin-split-card-message-actions)` | as row 01 | `useCardMessageActions` (80) is listed over the cap; `onMerge` is held only by a source reader (`msg-merge.test.mjs:116-120`), `remove` and `onMakeIssue` by nothing that runs them | `wui:src/composables/useCardTopicActions.ts:107` (`useCardMessageActions`, 80)<br>`wui:tests/unit/card-message-actions.test.mjs` (new) | 1 function, 3 pins | With row 01's `importTsStubbed`, stubbing `useArchiveUndo`, `useSpoolApi` and `errorJournal.mjs`, with `useRouter` and `useLocalePath` as globals. **Pin first:** **(M)** a merge into a row of the same id sends nothing, into another row sends `mergeInto(drop, keep)` once (break: `:140` deleted); **(R)** a refused delete leaves `removing` false and the failure key in `editError` (break: `:165` deleted); **(I)** a refused Make an issue sets `aiError` to `feed.msg_menu.make_issue_failed` (break: `:181` deleted). All three behaviours were read in the same probe (n=1); the breaks were not planted. Each red only under its own break, restored. **Then split** into file-local named steps; same name, six parameters and returned object; keep `async function onMerge` and its body in this file (**`msg-merge.test.mjs`** slices the source by that text; **`msg-edit.test.mjs`** also reads it). Leave the `LONG` and `WIDE` lines (row 10). Tests: the new file; **`msg-merge.test.mjs`** (base `# tests 8`); **`msg-edit.test.mjs`**; `msg-make-task.test.mjs`; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. **Control:** as row 01. | either | claude | complex_coding | 2 (after 01) |
| 03 `refactor(r52-03-iac-pin-split-secret-unused-table)` | as row 01, and drop its `LONG` line | `spl_secret_unused_table` (76) is listed over the cap: one Python heredoc; three of its rules have no case in its test | `iac:run/spl-secret-unused-list.func.sh:59` (`spl_secret_unused_table`, 76)<br>`iac:t/spl-secret-unused-list.tst.sh` (a new section)<br>`iac:t/bash-cleancode.tst.sh` (its one `LONG` line) | 1 function, 3 pins, 1 list line | **Pin first** in `spl-secret-unused-list.tst.sh` (base: 18 `PASS:` lines, rc 0; `grep -nE 'trust-lock\|MISSING\|disabled'` on it finds only the stub's `"disabled":false`): **(D)** a disabled key's row ends `(disabled)` (break: `:87` -> `dis = ""`); **(T)** a backup whose name ends `trust-lock` is not listed (break: the `sfx.endswith("trust-lock")` test at `:117` dropped); **(L)** a backup with no live file reads `live file MISSING` (break: `:125` -> `live_ok = "present"`). Each red only under its own break (paste the `FAIL:`), restored. **Then split**: two `_spl_secret_unused_py_*` functions print the two halves of the program, each with its own `cat <<'PY'`, cut at a top-level line between the scans (`:104` or `:111`), and `spl_secret_unused_table` feeds both to the same `python3 -` with the same arguments; same table, counts line and rc. No line above the header moves and the baseline is not edited (the header set is round 27's). Delete `csi-spl-iac/src/bash/run/spl-secret-unused-list.func.sh spl_secret_unused_table 76` from `LONG`. Tests: `spl-secret-unused-list.tst.sh`; `csi-spl-orc/src/bash/tests/box-name-from-cnf.tst.sh`; `bash-cleancode.tst.sh`; `action-header-tags.tst.sh` (still `43 missing`); `./run -a do_check_pre_push_lint`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** as row 01; `bash-cleancode.tst.sh` `(5 listed)` after. | either | claude | complex_coding | 1 |
| 04 `refactor(r52-04-wui-calendar-send-object)` | pass a wide function's inputs as one object | `send` in `calendar-events-api.mjs` takes 6 parameters and is listed in `WIDE`; `calendarDelete`, one of its 3 callers, has no unit test (`grep -c calendarDelete tests/unit/*.mjs`, total 0) | `wui:src/utils/calendar-events-api.mjs:34` (`send`, 6 params)<br>`wui:tests/unit/calendar-trash.test.mjs` (one case) | 1 function, 3 callers, 1 pin | **Pin first** in `calendar-trash.test.mjs`: `calendarDelete` sends `DELETE` to `/v1/calendar/events/<id>` with no body, and a non-ok answer throws the status (break: `:73` `'DELETE'` -> `'POST'`). **Then** `send(api, { method, path, body, what, ifMatch = '' })`, the 3 callers (`:64`, `:73`, `:82`) passing the object; the `fetch` lines unchanged, because **`fetch-timeouts.test.mjs:146`** matches them by regex. Exports and refusals unchanged. Leave the `WIDE` line (row 10). Tests: `calendar-trash.test.mjs`; `calendar-drag.test.mjs`; **`fetch-timeouts.test.mjs`**; `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (a `NOTE WIDE:` after); the e2e files the map selects. **Red control:** the pin red under its break; the object dropping `ifMatch` -> the `If-Match` case of `calendar-drag.test.mjs` fails. | either | claude | simple_coding | 1 |
| 05 `refactor(r52-05-wui-mock-part-object)` | as row 04 | `mockPart` in `tenant-costs.mjs` takes 6 parameters and is listed in `WIDE` | `wui:src/utils/tenant-costs.mjs:360` (`mockPart`, 6 params) | 1 function, 15 callers | `mockPart(source, pov, kind, origin, { usd, ...extra })`, at most 5 parameters, its 15 callers in this file only; the returned part unchanged; no other function. Leave the `WIDE` line (row 10). Tests: `tenant-costs.test.mjs`; `costs-sections.test.mjs`; `monitoring-paid.test.mjs`; `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (a `NOTE WIDE:` after); `tests/e2e/monitoring-costs.test.mjs` on a mock bundle. **Control:** `sha256sum` of `JSON.stringify(mockTenantCostsBody(<fixed month>, '', <fixed date>))` is the same on the parent sha and after (paste both); a caller given `usd` 0 by mistake -> the hash differs. | either | claude | simple_coding | 1 |
| 06 `test(r52-06-api-coverage-floors-raise)` | raise the floors round 25's test rows earned | the floor file says a lane that adds tests raises its line; rows r51-05..09 left theirs (round 25 section 1), so what those tests earned is not held yet | `api:src/bash/tests/go-coverage-floor.txt:39` (`action` 90.8)<br>`:63` (`channelmove` 83.3)<br>`:88` (`hubclient` 85.9)<br>`:107` (`lockkey` 79.3)<br>`:118` (`payments` 83.6) | 5 lines | Each new floor is the lowest of n=3 of `go test -count=1 -cover ./internal/<pkg>/` on the start sha (this plan's n=1 reads 91.6, 96.3, 86.1, 80.8, 84.3), with a comment block as `r50-09`'s: command, go version, sha, before and after. A floor only rises; a package whose lowest reading is not above its floor keeps its line, and the result says so. Rows 07 and 09 may land first and raise a reading: the row reads what is on its start sha. No other file. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. Tests: `bash api:src/bash/tests/run-all-tests.sh`. **Red control:** one floor planted 2 points over its reading -> the coverage check fails naming that package; restored (`git diff --exit-code` on the plant) before the commit; never pushed. | either | claude | tests | 1 |
| 07 `test(r52-07-api-hubclient-probe-submit-keep)` | three hub client helpers under test | `agentProbe` (9.1): only `""` is tested (`host_test.go:148`); `serveSubmit` (45.5): its error and listening branches; `keepRun` (0.0) | `go:internal/hubclient/host.go:485` (`agentProbe`, 9.1)<br>`go:internal/hubclient/flush.go:642` (`Client.serveSubmit`, 45.5)<br>`go:internal/hubclient/agent_drop.go:61` (`keepRun`, 0.0)<br>`go:internal/hubclient/probe_submit_keep_test.go` (new) | 3 functions at 0.0-45.5 | In `package hubclient`, `t.TempDir()` only, no real sudo. `agentProbe`: the current user -> `nil`; an unknown user -> `nil`; with `t.Setenv("PATH", <temp dir>)` and another user (`user.Lookup("root")`, skipped when it is absent or `os.Geteuid() == 0`): no `sudo` -> `nil`; a stub `sudo` printing `v1\nv2\n` -> the runner returns `v1`; a stub exiting 1 -> an error. `serveSubmit`: `SubmitSocket` under a regular file -> a stop func and `submit listener not opened` in the logger's buffer; a short socket path (a unix path has a length cap; `submit_test.go` shows how) -> `submit listener up`, and after the stop func the socket refuses a dial. `keepRun`: none of the agents in `run` -> `nil`; two of three -> those two with their values. `WaitQueueEnd` stays out: its file is queued `e8104df3`'s. Non-test code unchanged; floor file not edited. Helpers prefixed `pk`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Red control:** `keepRun` returning `run` unfiltered -> the two-of-three case fails. | either | claude | tests | 1 |
| 08 `test(r52-08-api-keyd-owner-scrypt-status)` | the agent key store's owner init, scrypt open and status under test | `InitOwner` (63.2): its refusal branches; `openScrypt` (64.7): empty pass, missing file; `Status` (64.3): a stale socket and each bad answer | `go:internal/keyd/store.go:125` (`InitOwner`, 63.2)<br>`go:internal/keyd/store.go:326` (`openScrypt`, 64.7)<br>`go:internal/keyd/keyd.go:271` (`Status`, 64.3)<br>`go:internal/keyd/owner_scrypt_status_test.go` (new) | 3 functions at 63.2-64.7 | In `package keyd`, `t.TempDir()` only (a short dir for a socket), keys generated in the test. `InitOwner`: `dir` under a regular file -> `could not create the key state`; a second call with another workspace -> `workspace mismatch`; a second call with the same one -> `owner key already exists`; the first -> a public key, and `owner.age` exists. `openScrypt`: an empty pass -> `could not open the agent keys`; a missing file -> `agent keys are not initialised`; a wrong pass -> `could not open the agent keys`; the right pass -> the plain bytes. `Status`, with a stub listener on `keyd.sock`: a closed listener's file (`ECONNREFUSED`) -> `locked` and the socket removed; `{"ok":false}` -> `bad status`; `{"ok":false,"error":"x"}` -> `x`; `{"ok":true,"state":"weird"}` -> `bad status`. `harden`, `listenSock` stay out. Non-test code unchanged; floor file not edited. Helpers prefixed `os`. Tests: `go test -count=1 -race -cover ./internal/keyd/`; `run-all-tests.sh`. **Red control:** `Status` dropping the `state` check -> the `weird` case fails. | either | claude | tests | 1 |
| 09 `test(r52-09-api-lockkey-seal-reseal-read)` | the lock key's seal, reseal and read limit under test | `Seal` (70.0): its bad-id and existing-`lock.json` refusals; `Reseal` (71.4): both refusals; `limited.Read` (71.4): the limit; `Sealer.Seal` (70.6): bad id, unknown kind | `go:internal/lockkey/store.go:100` (`Seal`, 70.0)<br>`go:internal/lockkey/store.go:182` (`Reseal`, 71.4)<br>`go:internal/lockkey/daemon.go:228` (`limited.Read`, 71.4)<br>`go:internal/lockkey/lockkey.go:139` (`Sealer.Seal`, 70.6)<br>`go:internal/lockkey/seal_reseal_test.go` (new) | 4 functions at 70.0-71.4 | In `package lockkey`, `t.TempDir()` only, `fast` params (`lockkey_test.go:19`). `Seal`: a bad tenant or box id -> error; a `lock.json` already there on an unsealed box -> `a lock key already exists`. `Reseal`: a short secret -> `needs at least`; `Keys{Lock: nil}` -> `reseal needs the lock key`. `limited.Read` on a `net.Pipe`: `n` 0 -> `request too large`, no read; a buffer longer than `n` -> at most `n` bytes. `Sealer.Seal`: a bad id -> error; an unknown kind -> error. Key material is generated in the test and never printed. Non-test code unchanged; floor file not edited; `r51-07`'s `meta_open_test.go` not edited. Helpers prefixed `sr`. Tests: `go test -count=1 -race -cover ./internal/lockkey/`; `run-all-tests.sh`. **Red control:** `limited.Read` dropping its `p = p[:l.n]` -> the longer-buffer case fails. | either | claude | tests | 1 |
| 10 `test(r52-10-wui-drop-stale-gate-lines)` | delete the gate lines the splits made stale | the lists may only shrink, and a stale line lets a function grow back to its old ceiling | `wui:tests/unit/cleancode.test.mjs:41` (`useCalendarDeepLinks`)<br>`:42` (`useCardMove`)<br>`:43` (`useCardMessageActions`)<br>`:63` (`calendar-events-api.mjs send`)<br>`:67` (`tenant-costs.mjs mockPart`) | 3 + 2 lines | Delete exactly the lines the gate NOTEs, with the comment's count (`3 left after r50-10`) brought up to date; `useCardMove` and `useCardMessageActions` keep their `WIDE` lines (still 6 parameters). A row of 01, 02, 04, 05 not yet landed keeps its line, and the result says so. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. Tests: `node tests/unit/cleancode.test.mjs`; `pnpm run test:unit`. **Red control:** on its parent sha, with rows 01, 02, 04, 05 landed, `node tests/unit/cleancode.test.mjs \| grep -c NOTE` -> 5 (on `4e2b8d70e`: 1), after -> 0; a `LONG` line kept for a function now under the cap prints the NOTE (the gate's own control), and a 76-line function with its line gone FAILS, shown on a scratch copy, never pushed. | either | claude | simple_coding | 3 (after 01, 02, 04, 05) |

### 3.1 Lanes and batches

- **Batch 1: rows 01, 03, 04, 05, 06, 07, 08, 09, no file in two rows.** Row 01
  owns `useCardMove.ts`, `load-ts-stubbed.mjs` and `card-move-steps.test.mjs`;
  row 03 `spl-secret-unused-list.func.sh`, `spl-secret-unused-list.tst.sh` and
  `bash-cleancode.tst.sh`; row 04 `calendar-events-api.mjs` and
  `calendar-trash.test.mjs`; row 05 `tenant-costs.mjs`; row 06
  `go-coverage-floor.txt`; rows 07-09 one Go package each plus one new
  `*_test.go`, and change no non-test code. None edits `cleancode.test.mjs`, a
  migration, `csi-spl-cnf/`, a workflow or terraform.
- **Batch 2: row 02** reuses row 01's `load-ts-stubbed.mjs` and is placed within
  30 minutes of row 01 landing (R16).
- **Batch 3: row 10** owns `cleancode.test.mjs` and is placed within 30 minutes
  of the last of rows 01, 02, 04, 05 landing (R16).
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder places
  any two batch 1 rows, then the next as each lands. Suggested order: row 01 with
  one Go test row, so the two lanes run different suites and row 02 opens early.

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 24 paths of the 10 rows, the new files included, comma separated> --agent c-267`
  -> **exit 4** (<box>, 2026-11-06T20:05:06Z, exit code read directly, not piped).
  No path is printed as owned. Five live lanes on the other box record no files:
  `c-178`, `c-638`, `c-639`, `c-862` (seat briefs) and `c-522` (a lane brief, another
  repo). Their briefs are **unchecked** here, and exit 4 is not free: the dispatch
  holder asks them, or reads their briefs, before placing a row, and re-runs the
  check before each row's spawn.
- **Live branches on this box:** for each of the 17 live lanes here,
  `git -C <its worktree> diff --name-only origin/master...HEAD` plus its
  `status --short`, grepped for the site basenames and packages -> 0 hits
  (c-266 included: 6 files, none here). A live lane may still start on a site.

- **Spawn queue (2026-11-06T19:5xZ):** `./run -a do_spl_spawn_queue` -> 130
  queued, 0 placing. 128 of their 130 briefs are on this box and were grepped for
  the site basenames, function names and package paths, with `cleancode\.test`,
  `go-coverage-floor` and `MessageCard`. Hits, each read: `e8104df3` edits
  `internal/hubclient/hubclient.go` (no site here is in that file, row 07 leaves
  `WaitQueueEnd` out); `27facf3e` edits `internal/hubclient/lane.go` (no site);
  `6bf127bd` forbids itself `internal/hubclient/` (no edit); `81ac0fa0` hits
  through `internal/keydesk` only; `681aa63f` (`c001-doc-devguide-wui-75-lines`)
  quotes `cleancode.test.mjs:27-28` in a doc lane. 5 briefs name
  `bash-cleancode` only as a gate to run. **Not read: 2 briefs not on this box**
  (asks `6ef7dec0`, `5ca30e73`).
  A grep can only find what it was told to look for, so the dispatch holder
  re-runs the check before each row's spawn.
- **Open rows of earlier rounds:** r51-10 holds `action-header-tags-baseline.txt`
  and 5 actions; no row here touches any of them. `r50-09` and `r50-10` landed.

## 4. Per row: what the lane does

- **01:** Pin three drag rules, add the stubbed loader, split `useCardMove`.
- **02:** After 01: pin three message-action rules, split `useCardMessageActions`.
- **03:** Pin three unused-credential rules, split `spl_secret_unused_table`, delete its bash `LONG` line.
- **04:** Pin `calendarDelete`, pass `send`'s inputs as one object.
- **05:** Pass `mockPart`'s money and extras as one object; the mock's bytes do not change.
- **06:** Raise five coverage floors to the lowest of n=3 readings.
- **07:** Unit tests for `hubclient` `agentProbe`, `serveSubmit` and `keepRun`.
- **08:** Unit tests for `keyd` `InitOwner`, `openScrypt` and `Status`.
- **09:** Unit tests for `lockkey` `Seal`, `Reseal`, `limited.Read` and `Sealer.Seal`.
- **10:** After 01, 02, 04, 05: delete the 5 stale `LONG` and `WIDE` lines.

## 5. Panel and reviewers (R7)

- Editor: c-267 (claude). Panel reviewer: a cross-vendor seat named by the
  dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked with
  `do_spl_review_line_check`. A row with no reviewer for 15 minutes reports a
  blocker (2.7.3).
- **P1, for the panel:** rows 01 and 02 add a test-only loader instead of editing
  `load-ts.mjs`. The probe behind them was n=1 on a scratch copy, in one file
  that was deleted after; no such test is on master yet. If the panel prefers
  extending `load-ts.mjs`, 80 files under `csi-spl-wui/tests` name it, and row 01's scope
  grows.
- **P2, for the panel:** rows 07-09 leave their floor lines to round 27, and row
  06 raises `payments`, whose row r51-09 is named off limits by the brief. The
  floor line is not one of that row's sites, and the row is on `4e2b8d70e`.
- **P3, for the panel:** `do_provision_firebase_dns` is dropped rather than
  deferred (section 2). Rows 01-03 keep every function's name and parameters, so
  `useCardMove` and `useCardMessageActions` stay on `WIDE`.
- **P4, for the panel:** row 05 changes mock data code only. It takes a `WIDE`
  line off the list and removes no production risk, which is why it is
  `simple_coding`; it is the first row to cut if the panel wants fewer.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| every site of r51-03, r51-09, r51-10 | the brief; r51-10 in lane c-266 | section 2 |
| `action-header-tags-baseline.txt` and the 20 other declare-first files | r51-10 holds the baseline; **input for round 27** | section 2 |
| `do_provision_firebase_dns` (169) | byte-identical port pin: dropped as a refactor input | section 2 |
| `spl_desk_pick` (80) | queued `881adc37` | section 2 |
| `spl_fleet_role_tick` (78), `_spawn_worktree` (79), `do_spl_agent_identity_restore` (80) | fleet-critical | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| `keyexec` (5), `keydesk` (3), `vendorkey`, `marketing` | queued `81ac0fa0` | section 2 |
| `hubclient` `WaitQueueEnd` and the rest of `hubclient.go` | queued `e8104df3` | section 3.2 |
| rows 07-09's floor raises; `mcp`, `invitemail`, `notify` floors; `files` `PutDir`, `action` `React`, `lockkey` `writeFile`; 47 other `< 75%` functions (57 less this round's 10) | round full, or only I/O-failure gaps; **input for round 27** | `go tool cover -func` on `4e2b8d70e` |
| the other 15 WUI `WIDE` functions | round full, not read one by one (two of them stay at 6 parameters after rows 01-02); **input for round 27** | section 2 |
| Go `longFuncs` (2), `wideFuncs` (14), `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool` | as rounds 22-25 | section 2 |
| WUI raw text, gosec / semgrep, shellcheck WARNING baseline | as rounds 22-25; **not re-measured** this round | none |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 5, test 5; wui 5, iac 1, Go 4) |
| vendor | claude 10 |
| kind | complex_coding 3, simple_coding 3, tests 4 |
| batches | batch 1: 8 rows at once; batch 2: row 02; batch 3: row 10 |
| pins added | 10 (rows 01-03: 3 each; row 04: 1) |
| WUI `LONG` lines | 3 -> 0 after row 10 |
| WUI `WIDE` lines | 17 -> 15 after row 10 |
| bash functions over 75 | 6 listed -> 5 after row 03 |
| floors raised | up to 5 (row 06) |
| Go functions taken | 10 at 0.0-71.4 |
| measured on | `4e2b8d70e`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-267): 10 rows, slug `r52`, measured on `4e2b8d70e`.

## 9. Consensus

Not signed. The plan is v0.1 until both seats sign its sha (rulebook 3.2).

- Editor seat: c-267 (claude): drafted v0.1.
- Panel reviewer seat: to be named by the dispatch lease holder.
