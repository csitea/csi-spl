# Refactoring round 29 - plan (9 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5149  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row**; `do_spl_lane_mix` picks claude for `tests` and `simple_coding`
  (section 5).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now.** Round 28 ([plan](refactor-round-28-plan.md), slug `r54`) has all 10 rows
on trunk: `git log c9a176a31 --format='%h %s' -E --grep='r54-'` -> 10 commits, one per
row. That they are served is the brief's reading (R5, R11), not re-run here. No round
28 retro is on `c9a176a31`
(`git ls-tree --name-only c9a176a31 csi-spl-doc/doc/md/ | grep -c 'refactor-round-28-retro'`
-> 0), so section 2 re-measures round 28's own carry-over list.

Round 29 focus: **7 of the 9 rows run at once in batch 1.** One row clears the 4
`WIDE` lines the last rounds left stale; three take 4 WUI functions under the
parameter cap, one row per batch, because all three edit `MessageCard.vue`; one does
the same for 2 private functions of the spool client; one tests `hubclient`'s unrun
branches; one raises 5 coverage floors; one ends a test hang; one shortens 3 action
headers' over-long examples.

**Status: v1.0 SIGNED** by the editor seat and the panel seat (section 9). Landing
waits for the holder's GO.

Editor: **c-443** (claude). Panel seat: a-521 (agy), section 5.

**One sha:** every count is measured on **`c9a176a31`** (`origin/master`
c9a176a31c4206c1089762b6dece6c6a72269e3e, 2026-11-09T09:26:33Z), n=1 per command
unless stated. Go: go1.26.10. Go and Bash reads are in this lane's worktree at that
sha, clean. The WUI gate and the stdin probe ran on a `git archive c9a176a31` copy,
the WUI part borrowing another checkout's `node_modules`, read only. Go coverage is
one `go test -count=1 -coverprofile=<f> -cover ./...` without Postgres (rc 0, 0
`^FAIL` lines), read with `go tool cover -func=<f>` and from the profile's zero-count
blocks. Queue and lane readings are live state, so they carry their own time, not
this sha.

## 1. How to read this

- **Slug prefix `r55`.** On `c9a176a31`:
  `git log c9a176a31 --oneline -E --grep='r55-' | wc -l` -> 0;
  `git branch -r | grep -c 'r55-'` -> 0;
  `git ls-remote origin 'refs/heads/*r55*' | wc -l` -> 0;
  `grep -rl 'r55-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box. The last slug is taken: `r54` has 10 commits, 11 branches.
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for a test row, a **red control**: the new case fails
  on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `wui:` = `csi-spl-wui/`, `api:` =
  `csi-spl-api/`, `orc:` = `csi-spl-orc/`, `go:` = `csi-spl-api/src/go/spool-hub-api/`;
  `run/` = `src/bash/run/`, `t/` = `src/bash/tests/` of the sub-project named. Lines as
  of `c9a176a31`; a function's site is its first line. A break is named by its code,
  not its line (R15).
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a fresh claude session per row, same-vendor under waiver 1a7c70da
  (section 5); no seat is named before
  a row is queued.
- **Subject** (R6 reads it): `<type>(r55-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if the number
  moved.
- **Tests per row (R2):** the files found with
  `git grep -l -F -e <name> c9a176a31 -- '*tst.sh' '*/tests/*' '*test*.sh'` for Bash
  and `grep -rlF <name> tests` in the WUI, listed per row. **Bold** = probably reads
  the site's source text, not checked file by file: the row lane corrects the marks.
  For Go, the package's tests plus `bash api:src/bash/tests/run-all-tests.sh`; for WUI,
  the unit tests and the e2e files the pre-push map selects
  (`cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`).
- **What was and was not run:** row 08's fix and its hang were probed, on the scratch
  copy, n=1, and row 05's control on `e8045f690` (section 3, row 05), n=1. **No other
  red control or break named here has been planted, and no case has been written.** The cases of rows 02-06 are read from the source and the
  coverage profile.

## 2. Where the rows come from (measured on `c9a176a31`)

**Taken:**

| source | input | command on `c9a176a31` | n | row |
|---|---|---|---|---|
| round 28 5, P1 | the `WIDE` lines rows 08-10 left, and `alertSteps` | `node tests/unit/cleancode.test.mjs` (archive copy) | `13252 functions, 0 listed long, 13 listed wide, none deeper than 4 or wider than 5`; 4 `NOTE WIDE`: `useCardSwipe`, `useCardSwipeFlags`, `useCardTouchLift`, `alertSteps`. `git log c9a176a31 --oneline --grep='r53-05' \| wc -l` -> 2 | **Row 01** |
| round 28 2, 6 | `useCardEdit` `WIDE` | `sed -n 60,67p wui:src/composables/useCardEdit.ts`; `grep -rnE 'useCardEdit\(' wui:src wui:tests/unit` | 6 params; one caller, `MessageCard.vue:658`; one test calls it, `card-edit-keys.test.mjs:41` | **Row 02** |
| round 28 2, 6 | `useCardMove` `WIDE` | the same on `useCardMove.ts:68` | 6 params; one caller, `MessageCard.vue:752`; one test calls it, `card-move-steps.test.mjs:67` | **Row 03** |
| round 28 2, 6 | `useCardTopicActions`, `useCardMessageActions` `WIDE` | the same on `useCardTopicActions.ts:42`, `:193` | 6 params each; one caller each, `MessageCard.vue:721`, `:722`; `useCardMessageActions` has one test caller (`card-message-actions.test.mjs:27`), `useCardTopicActions` none | **Row 04** |
| round 28 2, 6 | `liveReader`, `sessionMethods` `WIDE` | `grep -nE 'liveReader\|sessionMethods' wui:src/utils/spool-client.mjs` | 6 params each; no `export` on either, one caller each (`:329`, `:330`). Tests naming them: the gate only | **Row 05** |
| round 28 2, 6 | `hubclient` under 75% | `go tool cover -func=<f> \| awk '$NF+0<75.0 && $1!="total:"' \| grep hubclient/` | 7: `WaitQueueEnd` 40.0, `writeAtomic` 61.5, `now` 66.7, `timeout` 66.7, `bootID` 66.7, `sendFrame` 68.8, `hold` 70.5 | **Row 06** takes `WaitQueueEnd`, `sendFrame`, `bootID` |
| round 28 2, 6 | floors with room | package coverage against `api:src/bash/tests/go-coverage-floor.txt`, margin over 1.0 | read / floor: `keyexec` 86.9 / 81.7, `keyd` 84.4 / 82.2, `keydesk` 90.5 / 88.7, `notify` 96.6 / 94.8, `testkit` 78.6 / 77.0 | **Row 07** takes these 5 |
| round 28 5, P3 | `return-not-exit-gcp.tst.sh` hangs on an open stdin | on the archive copy, stdin a FIFO a `sleep` holds open: `timeout 20 bash iac:t/return-not-exit-gcp.tst.sh <fifo` | rc **124**. With `</dev/null` (worktree): `ALL PASS`, 0.22 s. With `:33` as `stub psql 'exit 0'`, the same FIFO: `ALL PASS`, rc 0 | **Row 08** |
| action header gate | `[long-example]` lines | `bash iac:t/action-header-tags.tst.sh`; `grep -n '@example'` on the 4 listed files, `awk length` | `measured 801 files: 20 missing, 4 long-example`. Whole lines over 200 characters (`awk length`, on `e8045f690`): `spl-issue-create` `:41` (270), `:42` (222); `spl-tenant-member-add` `:52` (231); `spl-topic-copy-cross` `:63` (226). On `e8045f690` the gate reads `802 files`, the 4 `long-example` unchanged | **Row 09** takes the 3 files |

**Deferred or dropped:**

| source | input | command on `c9a176a31` | n | disposition |
|---|---|---|---|---|
| round 28 2, 6 | `perfFeedPair` `WIDE` | `grep -n perfFeedPair -r wui:src` | 6 params; passed by value at `perf-rum.mjs:392` (`perfAttach({ ..., feed: perfFeedPair })`); `grep -n 'feed(' perf-mark-core.mjs perf-rum.mjs` finds no call, so its caller is not established here | **Round 30**: find the caller first |
| round 28 2, 6 | `send`, `sendLive` (`channel.ts`) | `grep -rnE '\.send\(' wui:src`, less `client.send` and `ws.send` | 13 lines, not read one by one; 4 unit tests name `sendLive`; `lane-map.sh` not run on `channel.ts` | **Round 30**: the store's public action, wider than any row here |
| rows 02-05 here | their 6 `WIDE` lines | row 01 holds `cleancode.test.mjs` in batch 1 | 6 | **Round 30**, as r54-08..10 did |
| round 28 2 | `hubclient` `writeAtomic`, `now`, `timeout`, `hold` | the profile's zero blocks, `grep -n writeAtomic` on its tests | `writeAtomic` has direct cases in its test file, its uncovered blocks not listed here; `hold`'s one zero block is the `Flush` warning (`flush.go:571`); `now`, `timeout` not read | **Left out**: the row's site cap |
| round 28 2 | `action`, `sign`, `config` floors | as row 07 | `action` 91.5 / 91.6, `sign` 86.2 / 86.2, `config` 90.9 / 90.9: no room | **Dropped** |
| round 28 2 | `internal/auth/cmd/auth-demo` 71.8 / 70.0, `github/githubtest` 21.1 / 20.0 | as row 07 | a demo and a test helper, going by their paths | **Left out** |
| round 28 2 | the `(required)` header files | `awk '/^\[missing\]/{m=1;next} /^\[/{m=0} m && /^csi-spl-/' iac:t/action-header-tags-baseline.txt \| xargs grep -l '(required)' \| wc -l` | **9** of 20 | **Left out**: a move adds `validate-params`' check, a behaviour change (bug-round input), as rounds 20-28 |
| action header gate | `provision-firebase-dns` `[long-example]` | `grep -n '@example'` on the file | its `:15` is 79 characters and ends in a `\` continuation; how the parser joins it was not read | **Left out**: not measured |
| round 28 2 | `spl_desk_pick`, `spl_fleet_role_tick`, `_spawn_worktree`, `do_spl_agent_identity_restore`, Go `longFuncs`, `wideFuncs`, `store`, `hub`, `auth` and the other low packages, WUI raw text, shellcheck baseline, gosec, semgrep | **NOT re-measured** | none | **Left out**, as round 28: no row of this round would take them |

## 3. The 9 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `test(r55-01-wui-drop-stale-wide-lines)` | a gate's list holds no stale line (`r54-04`) | four functions came under the cap and left their lines | `wui:tests/unit/cleancode.test.mjs:50` (`useCardSwipe`)<br>`:51` (`useCardSwipeFlags`)<br>`:54` (`useCardTouchLift`)<br>`:57` (`alertSteps`) | 4 lines | Delete exactly the lines the gate NOTEs. Tests: `node tests/unit/cleancode.test.mjs` (`13 listed wide` -> `9`, no `NOTE WIDE`); `pnpm run test:unit`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** delete a still-wide line instead (`useCardEdit`) -> the gate fails naming it, restored. | either | claude | tests | 1 |
| 02 `refactor(r55-02-wui-pin-card-edit-object)` | pin a wide function's rules, then pass its inputs as one object (`r54-08`) | `useCardEdit` takes 6 parameters | `wui:src/composables/useCardEdit.ts:60` (6 params)<br>`wui:src/components/MessageCard.vue:658` (its one caller)<br>`wui:tests/unit/card-edit-keys.test.mjs:41` (its one test caller)<br>`wui:tests/unit/card-edit-open-close.test.mjs` (new) | 1 function, 1 caller, 3 pins | **Pin first**, with `importTsStubbed` as `card-edit-keys.test.mjs:20`; if a rule is already pinned there the lane says so and drops that pin: **(C)** no edit on a message the viewer may not edit (break: delete `if (!canEdit(props.msg)) return` in `startEdit`); **(M)** another `msg_id` drops the open edit (break: delete `edit.value = null` in the `watch`); **(F)** closing hands focus back to the row (break: delete the `rowEl.value?.focus` `nextTick` in `closeEdit`). Each red only under its own break (paste the `not ok`), restored. **Then** `useCardEdit({ props, emit, rowEl, editEl, editError }, msgEdit)`. Leave the `WIDE` line (round 30). Tests: the new file; `card-edit-keys.test.mjs`; **`msg-edit.test.mjs`**, **`names-not-ids.test.mjs`** and the readers of **`lib/message-card-src.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs` (a `NOTE WIDE:` after); the e2e files the map selects. **Control:** the pins red under their breaks, green before and after. | either | claude | simple_coding | 1 |
| 03 `refactor(r55-03-wui-card-move-object)` | as row 02, its rules run by an existing test (`r52-01`) | `useCardMove` takes 6 parameters; `card-move-steps.test.mjs` runs its drag rules (its line 1), so no new pin | `wui:src/composables/useCardMove.ts:68` (6 params)<br>`wui:src/components/MessageCard.vue:752` (its one caller)<br>`wui:tests/unit/card-move-steps.test.mjs:67` (its one test caller) | 1 function, 1 caller | `useCardMove({ props, flags, title, pickerOpen }, menu, peer)`; `peer` and the returned keys unchanged. Leave the `WIDE` line. Tests: `card-move-steps.test.mjs` (only the call at `:67` changes); the readers of **`lib/message-card-src.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. **Control:** in `onDrop` delete `move.land(true)` -> the lane shows a case of `card-move-steps.test.mjs` fails on the new signature, restored; not run here. | either | claude | simple_coding | 2 (after 02) |
| 04 `refactor(r55-04-wui-pin-card-actions-object)` | as row 02 | both functions take 6 parameters; no test calls `useCardTopicActions` (`grep -n 'useCardTopicActions(' wui:tests/unit/*.mjs` -> none) | `wui:src/composables/useCardTopicActions.ts:42` (6 params)<br>`wui:src/composables/useCardTopicActions.ts:193` (6 params)<br>`wui:src/components/MessageCard.vue:721`, `:722` (their callers)<br>`wui:tests/unit/card-message-actions.test.mjs:27` (its one test caller)<br>`wui:tests/unit/card-topic-actions.test.mjs` (new) | 2 functions, 2 callers, 3 pins | **Pin first**, on `onMenuArchive`: **(R)** a second archive while one runs does nothing (break: delete `if (removing.value) return false`); **(D)** an archived topic leaves every feed (break: delete `dropEverywhere(id)`); **(E)** a failed archive shows its error and clears `removing` (break: delete `removing.value = false` in `finally`). Each red only under its own break, restored. **Then** `useCardTopicActions({ props, emit, rowEl }, busy, menu, msgEdit)` and `useCardMessageActions({ props, emit, editing }, busy, menu, msgEdit)`; returned keys unchanged. Leave the `WIDE` lines. Tests: the new file; `card-message-actions.test.mjs`; **`msg-make-task.test.mjs`**; the readers of **`lib/message-card-src.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. **Control:** as row 02. | either | claude | simple_coding | 3 (after 03) |
| 05 `refactor(r55-05-wui-spool-client-reader-object)` | a private function takes its inputs as one object | `liveReader` and `sessionMethods` take 6 positional parameters, three of them shared, at two adjacent calls | `wui:src/utils/spool-client.mjs:329`, `:330` (the callers)<br>`:442` (`liveReader`)<br>`:503` (`sessionMethods`) | 2 functions, 2 callers | Behaviour held by the unit tests that name the client (`grep -rlE 'spool-client' wui:tests/unit \| wc -l` -> 50, all through `pnpm run test:unit`). `liveReader({ conn, root, configError, hubFetch }, firstScreenMs, now)`, `sessionMethods({ tenant, mock, root, configError }, conn, live)`. Leave the `WIDE` lines. Also `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (two `NOTE WIDE:` after); the e2e files the map selects. No new pin (P3, panel). **Control:** swap `firstScreenMs` and `now` at the `:329` call -> `tests/unit/request-waterfall.test.mjs` goes red, restored. **Probed** on a `git archive e8045f690` copy, `node --test`, n=1: 41 pass, 0 fail before; 18 pass, 23 fail planted; 41 pass, 0 fail restored. | either | claude | simple_coding | 1 |
| 06 `test(r55-06-api-hubclient-unrun-branches)` | a client's refusals under test (`r54-06`) | the profile's zero blocks: `WaitQueueEnd` `hubclient.go:683-688` (socket closed, context cancelled, timeout); `sendFrame` `:778-786` (a new agent's first line: announce and resend); `bootID` `unlock.go:63-66` | `go:internal/hubclient/hubclient.go:679` (`WaitQueueEnd`, 40.0)<br>`go:internal/hubclient/hubclient.go:762` (`sendFrame`, 68.8)<br>`go:internal/hubclient/unlock.go:52` (`bootID`, 66.7)<br>`go:internal/hubclient/unrun_branches_test.go` (new) | 3 functions | `t.TempDir()` only. `WaitQueueEnd`: closed `done` -> `ErrUnreachable`; cancelled context -> `context.Canceled`; a short client timeout -> `ErrUnreachable`. `sendFrame`: the hub refuses the first send as an unannounced sender -> one announce, one resend, the second answer returned; a failing announce -> no resend. `bootID`: `bootIDPath` is a package `var` (`unlock.go:38`): point it at a missing path under `t.TempDir()`, restored in `t.Cleanup` -> the random id of `:63-66`, the same value on a second call. `sendFrame`'s `Marshal` and `Inner` failures (`:764-770`) stay out. Non-test code unchanged; floor file not edited. Helpers prefixed `ub`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Red control:** `case <-s.done:` returning `0, nil` -> the closed-socket case fails. | either | claude | tests | 1 |
| 07 `test(r55-07-api-coverage-floors-raise)` | a coverage floor follows what the tests hold (`r54-05`) | five packages read 1.6 to 5.2 points over their floor, so a lost test goes unnoticed | `api:src/bash/tests/go-coverage-floor.txt:105` (`keyd`)<br>`:110` (`keydesk`)<br>`:111` (`keyexec`)<br>`:122` (`notify`)<br>`:135` (`testkit`) | 5 lines | Each raised to the lowest of n=3 `go test -count=1 -race -cover`, in the file's comment format, as `r54-05` did; the reads in section 2 are n=1, plain. `hubclient`'s line not touched (row 06 moves it). Tests: `run-all-tests.sh`. R9 as row 01. **Red control:** `keyexec` at 99.0 -> the suite fails naming it, restored. | either | claude | tests | 1 |
| 08 `test(r55-08-iac-psql-stub-no-stdin-read)` | a test's stub never blocks on an inherited stdin | the `psql` stub runs `cat`, and `gcp-import-to-cloudsql.func.sh:101` gives `psql` no stdin redirect, so an open stdin hangs the test (round 28 P3) | `iac:t/return-not-exit-gcp.tst.sh:33` | 1 line | `stub psql 'exit 0'`. Non-test code unchanged. Tests: the file with `</dev/null`, and with a stdin held open. **Probed** (section 2): the file passes under an open stdin with this line, n=1. **Red control:** the old line back, stdin a FIFO a `sleep` holds open, `timeout 20` -> rc 124 (run once, section 2); the new line -> `ALL PASS`, rc 0. The lane confirms no assert reads what the stub swallowed. | either | claude | tests | 1 |
| 09 `refactor(r55-09-orc-long-examples-short)` | a header's example fits the gate's 200 characters | the gate lists these three orc actions under `[long-example]` | `orc:run/spl-issue-create.func.sh:41`, `:42`<br>`orc:run/spl-tenant-member-add.func.sh:52`<br>`orc:run/spl-topic-copy-cross.func.sh:63`<br>`iac:t/action-header-tags-baseline.txt:33-35` | 4 lines, 3 files, 3 baseline lines | Shorten each to at most 200 characters, with `<placeholders>` for the long values; comment lines only; the 3 `[long-example]` lines deleted in the same commit. The lane re-measures with `do_parse_metadata <f> \| grep '^example='` and says if another line of these files is over. Tests: **`action-header-tags.tst.sh`** (`4 long-example` -> `1`), `tenant-member-add.tst.sh`, `member-seat-all.tst.sh`, `spl-topic-copy-cross.tst.sh`, `alert-issue-tick.tst.sh`, `desk-actions.tst.sh`, `spec-import-issues.tst.sh`; `./run -a do_check_pre_push_lint`. R9 as row 01. **Red control:** delete one baseline line before shortening -> the gate fails naming the file, restored. | either | claude | simple_coding | 1 |

### 3.1 Lanes and batches

- **Batch 1: rows 01, 02, 05, 06, 07, 08, 09, no file in two rows.** Row 01 owns
  `cleancode.test.mjs`; row 02 `useCardEdit.ts`, `MessageCard.vue`,
  `card-edit-keys.test.mjs` and its new test; row 05 `spool-client.mjs`; row 06 one new
  test file; row 07 `go-coverage-floor.txt`; row 08 one test line; row 09 its 3 actions
  and `action-header-tags-baseline.txt`. In this batch only rows 02 and 05 change code
  that runs; row 09 changes comment lines. No row edits a migration, `csi-spl-cnf/`, a
  workflow or terraform.
- **Batch 2: row 03** shares `MessageCard.vue` with row 02. Placed within 30 minutes of
  row 02 landing (R16).
- **Batch 3: row 04** shares `MessageCard.vue` with row 03.
- Rows 02-05 run `cleancode.test.mjs` but do not edit it, so they do not collide with
  row 01.
- Suggested order: row 02 first, since it opens the later batches.

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 20 paths of the 9 rows, the new files included, comma separated> --agent c-443`
  -> **exit 4** (2026-11-09T10:15:28Z, exit code read directly, not piped). No path is
  printed as owned. Thirteen live lanes on the other box record no files: `a-855`,
  `c-020`, `c-107`, `c-215`, `c-288`, `c-301`, `c-304`, `c-306`, `c-417`, `c-441`,
  `c-447`, `c-488`, `c-923`. **Exit 4 is not free, and this plan did not clear it.** Of
  the briefs reachable on this box, the six with a task slug (`c-020`, `c-288`,
  `c-301`, `c-304`, `c-306`, `c-488`), `grep -oE <the rows' paths and names>` -> 0 hits
  each. That shows what those six briefs name, not what those lanes have edited; the
  six `-rotate` lanes, `a-855` and every worktree of that box were not read. The
  dispatch holder re-runs the check before each row's spawn (R3), **for row 06 only on
  the path it writes, `unrun_branches_test.go`** (N2): its other sites are read-only.
  Panel a-521, quoted, not re-run here: on the other box the 20 paths exit 3 on
  `hubclient.go`, for a stale index in the c-923 worktree. From this box the same path
  reads exit 4 (2026-11-09, about 11:35Z).
- **Spawn queue (2026-11-09T10:16:33Z):** `./run -a do_spl_spawn_queue` -> `24 queued, 1
  placing`; 25 slugs parsed from its output, all 25 briefs read on this box, grepped
  for the rows' paths and names -> 0 hits. An earlier pass (10:09Z, 26 briefs) -> 0
  name `internal/keyd`, `internal/keydesk`, `internal/keyexec`, `internal/notify`,
  `internal/testkit` or `lockkey`. A grep finds only what it was told to look for.
- **Open rows of earlier rounds:** r53-10 has no commit on `c9a176a31`
  (`git log c9a176a31 --oneline --grep='r53-10' | wc -l` -> 0); round 28 lists its
  input with the `action`, `sign` and `config` floor lines, and row 07 edits none of
  those lines.
- **Trunk moved while this was measured:** at `origin/master` `c6dfdf0cf`, 1 commit past
  `c9a176a31`, `git diff --stat c9a176a31 origin/master -- <the existing row paths>`
  printed nothing, so the lines above stand there. The same at `e8045f690`, 14 commits
  past: 0 files, `r55-` still free (0 commits, 0 remote branches).

## 4. Per row: what the lane does

- **01:** Delete the four stale `WIDE` lines.
- **02:** Pin three edit rules, pass `useCardEdit`'s inputs as one object.
- **03:** After 02: pass `useCardMove`'s inputs as one object.
- **04:** After 03: pin three archive rules, pass both action functions' inputs as one object.
- **05:** Pass `liveReader`'s and `sessionMethods`' inputs as one object.
- **06:** Unit tests for `hubclient`'s unrun wait, resend and boot-id branches.
- **07:** Raise five Go coverage floors to the lowest of n=3.
- **08:** The `psql` stub stops reading stdin, so the test cannot hang.
- **09:** Shorten three actions' over-long `@example` lines.

## 5. Panel and reviewers (R7)

- Editor: c-443 (claude). Both seats sign the plan sha (rulebook 3.2).
- **Panel seat:** a-521 (agy), cross-vendor as rulebook 3.2 asks, ask fb87b532. Its
  verdict on `fc3368bb8`: PASS, 0 defects, 4 notes, all folded here (section 8). Its line check on its log: rc 0, 4 of 4 named commands found (c-001, 5699586c, relayed in
  4fbd5e65, n=1; it shows they ran, not what they printed, and does not count its two
  `./run` checks). Its PASS on the v1.0 rc `cd933e0d4`: 0 defects, 0 new notes (section 9).
- **Row reviewers: same-vendor under waiver 1a7c70da, never cross-vendor.** c-001 ruling
  8e5affc4, as of 2026-11-09 10:24Z, relayed by the holder in 18768a4b; this lane did
  not query the owner's posts itself. Valid for **round 29 only**; re-check next round.
  An owner post putting grok back lapses it. Its stated basis: a prd search of the
  owner's posts, 4 rows, none says grok is back, n=1; a body search can miss a garbled
  post.
- **Conditions per row:** the reviewer is a FRESH claude session, never the author and
  never a seat already in the work; it reads only the tree; its brief names waiver
  1a7c70da. Its review line says same-vendor under the waiver, in the `read:` field
  (whether `do_spl_review_line_check` accepts that wording is not tested here).
  Mistral reviews stay paused (cf7a7ee5); agy gets no code R7, so the panel seat
  reviews this plan only, never a row.
- The waiver does not make a row compliant: rulebook 2.7.5 fails an equal vendor pair,
  and the retro names each such row.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).
- **P1, panel ruling:** row 01 stays in batch 1; the 6 `WIDE` lines of rows 02-05 go to
  round 30.
- **P2, panel ruling:** 9 rows; `perfFeedPair` and `send` / `sendLive` go to round 30.
- **P3, panel ruling:** no pin first for row 05; `request-waterfall.test.mjs` holds it.
- **P4, panel ruling:** the holder re-runs `--check` per row at spawn (R3), row 06 as in
  section 3.2. Lanes with no recorded files stay unproven until then.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `perfFeedPair` `WIDE` | caller not established; **input for round 30** | section 2 |
| `send`, `sendLive` `WIDE` | wider than a row; **input for round 30** | section 2 |
| this round's 6 `WIDE` lines | row 01's file; **input for round 30** | section 3 |
| `hubclient` `writeAtomic`, `now`, `timeout`, `hold` | the row's site cap | section 2 |
| `action`, `sign`, `config` floors | no room | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| `provision-firebase-dns` long example | not measured | section 2 |
| the fleet-critical long functions, Go `longFuncs` / `wideFuncs`, low store / hub / auth packages, raw text, slow scanners | as round 28, not re-measured | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 9 (refactor 5, test 4; WUI 5, Go 2, iac 1, orc 1) |
| vendor | claude 9 |
| kind | simple_coding 5, tests 4 |
| batches | batch 1: 7 rows; batch 2: 1 row; batch 3: 1 row |
| pins added | up to 6 (rows 02, 04: 3 each) |
| WUI `WIDE` lines | 13 -> 9 (row 01); 6 more functions under the cap by rows 02-05, their lines in round 30 |
| `[long-example]` lines | 4 -> 1 |
| Go functions taken | 3 at 40.0-68.8 |
| floors raised | 5 |
| measured on | `c9a176a31`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-443): 9 rows, slug `r55`, measured on `c9a176a31`.
- v0.2: section 5 and section 1: c-001's waiver ruling 8e5affc4 and the agy panel ask
  fb87b532 (holder note 18768a4b). No row changed.
- v1.0 rc: a-521's PASS on `fc3368bb8` (verdict f83cf1fb, no defects). Its notes folded, its rulings P1-P4 recorded. N1: row 05 names its
  test (re-probed here). N2: row 06's R3 path (quoted, its exit 3 not re-run here). N3:
  row 06 `bootID` case (`unlock.go:38` read). N4: row 09 line lengths, 802 files
  (re-measured). Row scope unchanged.
- v1.0: a-521's PASS and signature on `cd933e0d4` (verdict 6b6d0d47). Status, section 5
  and section 9 only.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-443 (claude): drafted v0.1, v0.2, the v1.0 rc, v1.0. **Signed v1.0.**
- Panel reviewer seat: a-521 (agy): PASS on `fc3368bb8` (verdict f83cf1fb, line check 5699586c);
  PASS on the v1.0 rc `cd933e0d4` (verdict 6b6d0d47, 0 defects, 0 new notes), a review of
  the 261-line diff. **Signed v1.0, on the diff; gates not shown re-run by the line
  check.** Line check e91d8908, n=1: rc 0, 4 of 4 named commands in its log, but the same
  session as the first check, grown from 27 to 30 commands, so it shows those commands
  are in the log, not that they ran on `cd933e0d4`.
