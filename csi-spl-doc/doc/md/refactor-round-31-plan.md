# Refactoring round 31 - plan (6 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5221  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row**; `do_spl_lane_mix` picks claude for `tests` and `simple_coding`.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now.** The dispatch holder's brief (c-002) names the trigger: c-001's SPAWN
SHARE note b2aa51f8, refactor under its band. Re-read here (2026-11-10T15:43Z, n=1):
`./run -a do_spl_spawn_queue` -> `last 24 h (52 sample(s)): refactor 14% (band
20-30%: UNDER)`, and no refactor row queued (its 40 rows grepped for
`r55|r56|r57|refactor` -> 0 rows). Round 30 ([plan](refactor-round-30-plan.md), slug
`r56`) is **not served**: on `35927a0d8`,
`git log 35927a0d8 --format='%h %s' -E --grep='r56-'` -> 7 commits, rows 01-07.
**Row 08 has no commit** on `35927a0d8`; it edits the two gate lists, so only row
06 here touches them, after it (section 3.2). Since then (panel a-165, 17:4xZ,
quoted, not re-run here) r56-08 is **live as `c-495@sat`**, 0 commits on
`078c9a72c`. No round 30 retro is on `35927a0d8`
(`ls csi-spl-doc/doc/md/ | grep -c refactor-round-30-retro` -> 0), so section 2
re-measures round 30's own carry-over list (its section 6).

Round 31 focus: **the `WIDE` / `wideFuncs` functions round 30 left that have one
caller each.** Three Go rows (`RecordAuthEvent`, `mergePair` + `fanoutMerged`,
`inlineMessages`) and two WUI rows (the card actions and `useCardMove`, round 29's
never-placed r55-04 and r55-03) pass their inputs as one struct or object; the two rows
whose rules no test drives pin them first, and row 05 adds the drop case its test
lacks (v0.4). Row 06 drops the 7 lines they leave.

**Status: v1.0 SIGNED** by the editor seat and the panel seat on `809788f13`
(section 9). Rows are queued by the holder once the plan is on origin/master.

Editor: **c-029** (claude). Panel seat: requested, section 5.

**One sha:** every count is measured on **`35927a0d8`** (`origin/master`
35927a0d81654ae6117f25069907fb2fd8cc1e3c, 2026-11-10T10:34:18Z), n=1 per command
unless stated. Re-checked at v0.4 on `origin/master` `078c9a72c`: `git diff --stat
35927a0d8 078c9a72c -- <the 13 existing written paths>` -> empty, so every line here
still holds. Go: go1.26.10. Go reads are in this lane's worktree at that sha, clean;
the WUI gate ran on a `git archive 35927a0d8` copy with the main checkout's
`node_modules` linked in, read only; row 01's survival probe ran on two
`git archive 35927a0d8 csi-spl-api csi-spl-rdb` copies (one planted, one clean). Queue
and lane readings are live state, so they carry their own time, not this sha.

## 1. How to read this

- **Slug prefix `r57`.** On `35927a0d8`:
  `git log 35927a0d8 --oneline -E --grep='r57-' | wc -l` -> 0;
  `git branch -r | grep -c 'r57-'` -> 0;
  `git ls-remote origin 'refs/heads/*r57*' | wc -l` -> 0;
  `grep -rl 'r57-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box. The last slug is taken: `r56` has 7 commits on `35927a0d8`.
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for a test row, a **red control**: the new case fails
  on a planted defect and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`, `api:` = `csi-spl-api/`, `go:` =
  `csi-spl-api/src/go/spool-hub-api/internal/`. Lines as of `35927a0d8`; a function's
  site is its first line. A break is named by its code, not its line (R15).
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** see section 5; no seat is named
  before a row is queued.
- **Subject** (R6 reads it): `<type>(r57-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if the number
  moved.
- **Tests per row (R2):** WUI: `grep -rlE <name> wui:tests/unit`, listed per row;
  **bold** = reads the site's source text (`src(` / `readFileSync`), not checked file
  by file: the row lane corrects the marks. Go: the package's tests plus
  `bash api:src/bash/tests/run-all-tests.sh`; an auth or store row adds
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres). WUI also runs the e2e
  files the pre-push map selects
  (`cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`).
- **What was and was not run:** row 01's survival probe (section 2), n=1. **No other
  red control or break named here has been planted by this lane, and no case has been
  written.** The panel (a-165, on v0.3, quoted, n=1 each) planted row 02's, row
  03's, row 05's and row 06's controls and row 04's three breaks: section 3 states
  their results.

## 2. Where the rows come from (measured on `35927a0d8`)

**Taken:**

| source | input | command on `35927a0d8` | n | row |
|---|---|---|---|---|
| round 30 6 | `RecordAuthEvent` `wideFuncs` | `grep -rnE '\bRecordAuthEvent\(' go:`; the same on `api:src/go/spool-hub-api/cmd` | 8 params. Four hits: the interface `auth.ActivityRecorder` (`auth/audit.go:21`), its one call (`audit.go:43`, in `recordAuth`), the one implementation `authActivityAdapter` (`hub/memberactivity.go:40`), a test fake (`auth/audit_test.go:54`); `cmd` -> 0. The adapter's line: `cleancode_test.go:47` | **Row 01** |
| round 30 6 | is the adapter's field mapping under test? | archive copy, `hub/memberactivity.go:46` `IP: ip, UA: ua` planted as `IP: ua, UA: ip`; `go test -count=1 ./internal/hub/` on it and on a clean copy; `go test -count=1 ./internal/auth/` on it | hub: the same 3 `--- FAIL` on both copies (`TestEmojiChoicesMatchWUI`, `TestDMCountsMatchWUIFixture`, `TestChannelMovePlanRetentionLines`: they read `csi-spl-wui/` and `csi-spl-orc/` files the api-only archive lacks, their logs say so); auth `ok`. **The swap survives every hub and auth test**, n=1. `memberactivity_recorder_test.go` checks only that the memory store yields nil | **Row 01** pins first |
| round 30 6 | `mergePair`, `fanoutMerged` `wideFuncs` | `grep -rnE '\b(mergePair\|fanoutMerged)\(' go:` | `mergePair` (`hub/merge.go:151`, 8 params, one caller `:77`); `fanoutMerged` (`:249`, 8 params, one caller `:117`, one bench caller `hub/fanout_encode_e16_bench_test.go:61`). Lines `cleancode_test.go:48`, `:49`. `merge_test.go:75-76` reads the merged frame's `msg_id`, `merged_from`, `task_id`; `:62` the answer's `merged_from`, `edited_by`, `revision` | **Row 02** |
| round 30 6 | `inlineMessages` `wideFuncs` | `grep -rnE '\binlineMessages\(' go:`; `ls go:hub/*_test.go \| xargs grep -l per_topic \| wc -l` | `hub/view.go:990`, 8 params, one caller `:788`; line `cleancode_test.go:51`. 9 test files send `per_topic` (among them `view_per_topic_test.go`, `demo_moderation_test.go:236`) | **Row 03** |
| round 30 6 (round 29 r55-04, never placed) | `useCardTopicActions`, `useCardMessageActions` `WIDE` | `grep -rnE '\b(useCardTopicActions\|useCardMessageActions)\(' wui:src wui:tests`; `git log 35927a0d8 --format='%h %s' \| grep -cE 'r55-0[34]'` (subjects only); `git ls-remote origin '*r55-0[34]*'` | 6 params each (`useCardTopicActions.ts:42`, `:193`); one caller each, `MessageCard.vue:725`, `:726`; `useCardMessageActions` has one test caller (`card-message-actions.test.mjs:27`, its rules pinned by SPL-4998 `07f53e6d1`); **no test calls `useCardTopicActions`**. r55-04: 0 row commits (`--grep='r55-04'` also matches bodies: 1 plan-doc hit, `745520383`, the round 30 plan), 0 branches, not queued | **Row 04** |
| round 30 6 (round 29 r55-03, never placed) | `useCardMove` `WIDE` | `grep -rnE '\buseCardMove\(' wui:src wui:tests`; the subject grep of row 04 | 6 params (`useCardMove.ts:68`); one caller `MessageCard.vue:756`; one test caller `card-move-steps.test.mjs:67`. r55-03: 0 row commits (`--grep` 1 plan-doc hit, `745520383`), 0 branches, not queued. `card-move-steps.test.mjs:42` stubs `land: () => {}` and none of its 3 cases drops a card; `title` (`useCardMove.ts:127`) and `pickerOpen` (`:88`) are not asserted | **Row 05** pins first |
| WUI gate | the list now | `node tests/unit/cleancode.test.mjs` (archive copy) | `13297 functions, 0 listed long, 6 listed wide, none deeper than 4 or wider than 5` (`13337 functions` on `078c9a72c` after SPL-5194 `8ad692de1`, panel a-165, not re-run here; the list unchanged); 2 `NOTE WIDE` (`sendLive`, `perfFeedPair`): **r56-08's** lines | rows 04, 05 leave 3 lines |
| Go gate | the list now | `go test -count=1 -v -run TestCleanCode ./internal/cleancode/` | `ok`; 2 `no longer takes more than 7` logs (`searchSections`, `scanMove`): **r56-08's** lines. 14 `wideFuncs` lines | rows 01-03 leave 4 lines |
| rows 01-05 here | the 7 lines they leave | as the two gate rows above | 7 (3 WUI, 4 Go) | **Row 06**, batch 3 |

**Deferred or dropped:**

| source | input | command on `35927a0d8` | n | disposition |
|---|---|---|---|---|
| round 30 6 | `send` `WIDE` (`wui:src/stores/channel.ts:541`) | `git grep -nE '\.send\(\|send:' 35927a0d8 -- csi-spl-wui/src`, read one by one | 7 call sites of the store action: `PollForm.vue:168`, `lobby.vue:268`, `:284`, `channel/[name].vue:166`, `t/[task_id].vue:172`, `useDmLineTarget.ts:72`, `msg-ai-run.ts:48` (`deps.send`, typed `AiRunDeps.send` at `:31`); plus 2 wirings by reference, `MessageMenu.vue:118` and `useAiListRun.ts:23` (`send: ... .send`). Not `TopBar.vue:254`: that is `OmniboxTarget.send` (`omnibox.ts:14`, 2nd arg `files`). Over the 5-site cap | **Left out**: a store's public action, needs its own split over two rows; **input for round 32** |
| round 30 6 | a live-store pin of `send` | `git grep -n useChannelStore 35927a0d8 -- csi-spl-wui/tests/unit \| wc -l` | 0: no unit test loads the channel store | **Left out**: a harness is wider than a row; round 32 input with `send` |
| round 30 2, 6 | `hubclient` `writeAtomic`, `hold` | not re-measured | none | **Left out**, as round 30: no small case found |
| Go `wideFuncs` | `IssueToken` (2), `CASFleetLease` (2), `MoveMessage` (2), `MergeTopic` (2) | gate comment `cleancode_test.go:41-43` | implement one interface each, leave together | **Left out**: interface pairs, wider than a row |
| Go `longFuncs` | `(*Server).Handler`, `ProvisionMember` | `sed -n 33,36p go:cleancode/cleancode_test.go` | 2 lines | **Left out**, as round 30 |
| round 30 6 | `provision-firebase-dns` `[long-example]` | not re-measured | byte-pinned to csi-rel (round 30 W1) | **Dropped**, as round 30 |
| round 30 6 | the 9 `(required)` header files; fleet-critical long Bash functions, low packages, raw text, slow scanners | **NOT re-measured** | none | **Left out**, as round 30 |

## 3. The 6 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r57-01-api-pin-auth-event-struct)` | pin first, then pass the struct instead (`cleancode_test.go:20`) | `RecordAuthEvent` takes 8 parameters, 6 of them strings in a row; the adapter's field mapping survives a swap (section 2) | `go:auth/audit.go:21` (`ActivityRecorder`)<br>`go:auth/audit.go:43` (its one call)<br>`go:hub/memberactivity.go:40` (the adapter)<br>`go:auth/audit_test.go:54` (`fakeRecorder`)<br>`go:hub/memberactivity_adapter_pin_test.go` (new) | 1 interface, 1 call, 2 implementations, 1 pin | **Pin first:** a fake store that embeds `store.NewMemory()` and records `AppendMemberActivity`; `authActivityAdapter{store: fake}.RecordAuthEvent(...)` with seven distinct values -> each lands in its own `store.MemberActivity` field (`TenantID`, `SubjectHum`, `Kind`, `Detail`, `IP`, `UA`, `CreatedAt`). **Red control:** the probe's swap `IP: ua, UA: ip` -> the new case fails (green over every hub and auth test today, section 2), restored. **Then** `RecordAuthEvent(ctx, ev auth.Event)` with `auth.Event{Tenant, HumanID, Kind, Method, IP, UA string; At time.Time}` defined in `auth`, so the seam stays primitives-only (no `store` import in `auth`; the comment above `ActivityRecorder` follows). Leave the `wideFuncs` line (row 06). Helpers prefixed `ap`. Tests: the new file; `go test -count=1 ./internal/auth/ ./internal/hub/`; `run-all-tests.sh`; auth: `PRE_PUSH_TIER=full ./run -a do_check_pre_push`; `go test ./internal/cleancode/ -v -run TestCleanCode` (a `no longer takes more than` log after). | either | claude | simple_coding | 1 |
| 02 `refactor(r57-02-api-merge-pair-fanout-structs)` | as row 01, no new pin | `mergePair` and `fanoutMerged` take 8 parameters each; `merge_test.go` drives both through `POST /v1/messages/{id}/merge` | `go:hub/merge.go:151` (`mergePair`)<br>`go:hub/merge.go:77` (its one caller)<br>`go:hub/merge.go:249` (`fanoutMerged`)<br>`go:hub/merge.go:117` (its one caller)<br>`go:hub/fanout_encode_e16_bench_test.go:61` (bench caller) | 2 functions, 2 callers, 1 bench | `mergePair`'s request inputs (`hum, from, srcID, keepID, now`) as one unexported struct, and `fanoutMerged`'s edit stamp (`canon, at, by, rev`) as another, so each takes at most 7. Results, frames and errors unchanged. **Placed only after SPL-4993's `merge.go` change is on master** (section 3.2): it adds a guard inside `mergePair`'s body. Leave the two `wideFuncs` lines (row 06). Tests: `go test -count=1 ./internal/hub/` (with `merge_test.go`, `merge_pin_test.go`, `topic_merge_test.go`); `go test -run XXX -bench Merged ./internal/hub/` builds the bench; `run-all-tests.sh`; the Go gate as row 01. **Control:** swap `srcID` and `keepID` in the `:77` struct literal -> `TestMergeMessageIntoPrevious` fails at `merge_test.go:77` (the watcher frame's `msg_id` / `merged_from`; the answer's `merged_from` at `:62` comes from `handleMerge`'s own `srcID`, `merge.go:119`), restored. Run by the panel on v0.3 (exit 1, n=1), not here. | either | claude | simple_coding | 1, after SPL-4993 |
| 03 `refactor(r57-03-api-inline-messages-page)` | as row 02 | `inlineMessages` takes 8 parameters | `go:hub/view.go:990` (`inlineMessages`)<br>`go:hub/view.go:788` (its one caller) | 1 function, 1 caller | Its page inputs (`per, out`) and filters (`mod, lv`) as one unexported struct, so it takes at most 7 (5 here). Results, error answers and the read count unchanged (`roundtrips_perf_test.go` counts the round trips). Leave the `wideFuncs` line (row 06). Tests: `go test -count=1 ./internal/hub/` (the 9 `per_topic` files among them); `run-all-tests.sh`; the Go gate as row 01. **Control:** pass a zero `modView` in the `:788` struct -> a `per_topic` case of `demo_moderation_test.go` (a hidden message inlined) fails, restored; the lane names it; not run here. | either | claude | simple_coding | 1 |
| 04 `refactor(r57-04-wui-pin-card-topic-actions-object)` | pin first, then one object (round 29 r55-04, re-measured) | both functions take 6 parameters; no test calls `useCardTopicActions` (section 2) | `wui:src/composables/useCardTopicActions.ts:42` (6 params)<br>`wui:src/composables/useCardTopicActions.ts:193` (6 params)<br>`wui:src/components/MessageCard.vue:725-726` (their callers)<br>`wui:tests/unit/card-message-actions.test.mjs:27` (its one test caller)<br>`wui:tests/unit/card-topic-actions.test.mjs` (new) | 2 functions, 2 callers, 3 pins | **Pin first**, on `onMenuArchive` (`:63`): **(R)** a second archive while one runs does nothing (break: delete `if (removing.value) return false`, `:65`); **(D)** an archived topic leaves every feed (break: delete `dropEverywhere(id)`, `:72`); **(E)** a failed archive shows its error and clears `removing` (break: delete `removing.value = false` in `finally`, `:82`). Each red only under its own break, restored. **Then** `useCardTopicActions({ props, emit, rowEl }, busy, menu, msgEdit)` and `useCardMessageActions({ props, emit, editing }, busy, menu, msgEdit)`; returned keys unchanged. Leave the `WIDE` lines (row 06). Tests: the new file; `card-message-actions.test.mjs`; **`msg-make-task.test.mjs`** (`:79` reads the file); the readers of **`lib/message-card-src.mjs`** (`grep -rl message-card-src wui:tests/unit \| wc -l` -> 17); `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. | either | claude | simple_coding | 1 |
| 05 `refactor(r57-05-wui-pin-card-move-object)` | pin first, then one object (round 29 r55-03, re-measured) | `useCardMove` takes 6 parameters; `card-move-steps.test.mjs` (`r52-01`) runs its lift and track steps but never a drop: its stub `land` is a no-op (`:42`), so deleting `move.land(true)` stays green (panel a-165 on v0.3: 3 pass, 0 fail, n=1) | `wui:src/composables/useCardMove.ts:68` (6 params)<br>`wui:src/components/MessageCard.vue:756` (its one caller)<br>`wui:tests/unit/card-move-steps.test.mjs:42` (the `useMoveStore` stub), `:67` (its one test caller), new cases | 1 function, 1 caller, 1 test file | **Pin first, in `card-move-steps.test.mjs`:** the stub records `land` calls; on start, `lifts[0].title` is the title passed in and `pickerOpen.value === false`; a new drop step (`onDrop`) -> `land(true)` called once and the drag ended (`endDrag`). **Red control:** delete `move.land(true)` (`useCardMove.ts:95`) -> the drop case fails, restored; delete `pickerOpen.value = false` (`:88`) -> the start case fails, restored. **Then** `useCardMove({ props, flags, title, pickerOpen }, menu, peer)`; `peer` and the returned keys unchanged; only the call at `:67` changes beside the new cases. Leave the `WIDE` line (row 06). Tests: `card-move-steps.test.mjs`; the readers of **`lib/message-card-src.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. | either | claude | simple_coding | 2 (after 04) |
| 06 `test(r57-06-drop-wide-lines-of-r57)` | a gate's list holds no stale line (`r56-08`) | rows 01-05 leave 7 stale lines | `wui:tests/unit/cleancode.test.mjs:48-50` (`useCardMove`, `useCardMessageActions`, `useCardTopicActions`)<br>`go:cleancode/cleancode_test.go:47-49` (`RecordAuthEvent`, `fanoutMerged`, `mergePair`), `:51` (`inlineMessages`); lines as of `35927a0d8`, they move when r56-08 lands | 7 lines | Placed only after **r56-08** and rows 01-05 are on trunk (R16); a row not landed keeps its line, and the lane says which. Delete exactly the lines the gates note. Tests: `node tests/unit/cleancode.test.mjs` (no `NOTE WIDE`; `1 listed wide`, `send`, once r56-08 and rows 04, 05 landed); `go test -count=1 -v ./internal/cleancode/` (no `no longer` log; 8 `wideFuncs` lines once r56-08 and rows 01-03 landed); `pnpm run test:unit`; `run-all-tests.sh`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** delete a still-wide line (`send`) -> the WUI gate fails naming it; delete `(*MemoryCredStore).IssueToken` -> the Go gate fails; both restored. | either | claude | tests | 3 (after r56-08, 01-05) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-04, no file in two rows.** Row 01 owns `auth/audit.go`,
  `auth/audit_test.go`, `hub/memberactivity.go` and one new test file; row 02
  `hub/merge.go`, `hub/fanout_encode_e16_bench_test.go`; row 03 `hub/view.go`; row 04
  `useCardTopicActions.ts`, `MessageCard.vue`, `card-message-actions.test.mjs` and one
  new test file. All four change code that runs. No row edits a migration,
  `csi-spl-cnf/`, a workflow or terraform.
- **Row 02 also waits for SPL-4993** (section 3.2), not for another row here.
- **Batch 2: row 05** shares `MessageCard.vue` with row 04; it alone writes
  `card-move-steps.test.mjs`. Placed within 30 minutes
  of row 04 landing (R16).
- **Batch 3: row 06** edits both gate lists, which r56-08 edits too. Placed within 30
  minutes of the last of r56-08 and rows 01-05 landing (R16).
- Rows 01-05 run the gates but do not edit them, so they collide neither with r56-08
  nor with row 06.

### 3.2 Off every live lane and every queued row (R3)

- **Round 30's open row r56-08** (`cleancode.test.mjs`, `cleancode_test.go`): only row
  06 names them, and it is placed after r56-08 lands. r56-07's files
  (`message_move_postgres.go`, `view_postgres.go`, `message_edit_postgres.go`) are on
  master (`b3ddc72b2`, 2026-11-10T08:26:41Z) and no row here names them
  (`grep -E '^\| 0[1-6] ' <this file> | grep -cE 'message_move_postgres|view_postgres|message_edit_postgres'`
  -> 0). r56-08 was **not queued** at 15:43Z (`do_spl_spawn_queue`: no `r56` slug); since then
  it is **live as `c-495@sat`** (`c-495-c002-r56-08-drop-wide-lines-of-r56`, panel
  a-165, quoted; `git log origin/master --format='%h %s' | grep -c r56-08` -> 0 at
  2026-11-10T17:42Z here), so row 06 still waits for it.
- **SPL-4993 (queued land takeover `7c6ed543`, `c002-spl4993-land-takeover`, queued on
  sat):** its 3 commits are in c-306's worktree on this box
  (`git log --oneline origin/master..<c-306 HEAD>` -> 3, not on master) and change 19
  files; `git diff --name-only origin/master...<c-306 HEAD>` shares exactly one with
  this plan, `hub/merge.go` (a `topicOpenDoor` guard inside `mergePair`). So row 02 is
  placed after it lands.
- **Live lanes: NOT proven free.** `lane-map.sh --check <the 15 written paths of the 6
  rows, the new files and both gate files included, comma separated> --agent c-029` ->
  `free`, exit 0 at 2026-11-10T15:57:48Z; **exit 4 at 16:11:32Z** on the same paths
  (`unknown: c-491@sat c-491-c002-bug-identity-restore-test-concurrent-runs has no files
  recorded`), exit code read via `PIPESTATUS`, n=1 each. The holder's read on sat
  (c-002@sat b779f524, 16:1xZ, n=1, quoted, not re-run here): exit 4 on the 7 existing
  paths, no path owned, 13 live lanes with no files recorded (c-721, c-730, c-734,
  c-981 among them). Lanes were placed after the 15:57Z run. **Exit 4 is not free, and
  this plan did not clear it**; the holder re-runs the check before each row's spawn
  (R3).
- **Worktrees on this box** (274 in `git worktree list`): each one's
  `git diff --name-only origin/master...HEAD` plus `git status --porcelain`, grepped for
  the rows' files -> 4 hits. `c-306` (SPL-4993, above); `CLE-001-land-77930`
  (`hub/view.go`, last commit 2026-10-02), `m-890-review-review-c-677-s150-b3`
  (`hub/view.go`, 2026-10-29) and `g-297-s150-b8-scratch` (`MessageCard.vue`,
  2026-11-02): none of the four has a tmux window (`list-windows -a | grep -E
  'c-306|CLE-001|g-297|m-890'` -> 0); the last three are stale scratch, not live lanes.
- **Spawn queue (2026-11-10T15:43:43Z):** `./run -a do_spl_spawn_queue` -> `40 queued,
  0 placing`. **18 briefs on this box**, grepped for the rows' files and function
  names -> 1 hit, `c002-feat-prio-two-way-sync` naming `fleet_lanes_view.go`, a false
  match of `view\.go` (not `hub/view.go`). **22 are on sat only** (`WAIT ... not under
  /var/spool-hub/dispatch/briefs here`), not grepped here. The holder grepped them on
  sat (c-002@sat b779f524, 16:1xZ, n=1, quoted, not re-run here): **0 hits** for any
  section 3.1 file. `c002-spl4993-land-takeover` names `merge.go` by its subject, SPL-4993
  (above), not by a path.
- **Briefs placed before** (`/var/spool-hub/spawn-remote/briefs`, 2498 files, grepped
  the same way): hits only in briefs of landed or closed work (rounds 25-30, SPL-4998,
  spec 150 rows) and the SPL-4993 bug (above).
- **Written paths only** (round 30 N1): the holder's `--check` at each spawn takes the
  row's written paths, **all 15**, and its sat brief grep takes every written basename,
  `card-move-steps.test.mjs`, `cleancode.test.mjs` and `cleancode_test.go` included
  (panel N3: the v0.2 sat read covered 7 paths and omitted those three).
- **Panel's read on this box (a-165, on v0.3, quoted, not re-run here):** `--check` on all 15
  paths -> exit 4, 0 owned; 3 `unknown:` lanes, all on sat (`c-490-rotate`, `c-495`
  r56-08, `c-497-c002-review-spl5198-r3-reviewer`). c-730 and c-981 are clean rotate
  trees, c-734 has 0 overlap, c-721 (SPL-5194) landed. 0 hits in the 15 briefs on this box.
  Still unproven: the 22 sat-only briefs for those three basenames and unrecorded sat
  edits; the holder re-checks at each spawn.

## 4. Per row: what the lane does

- **01:** Pin the auth adapter's field mapping; `RecordAuthEvent` takes one `auth.Event`.
- **02:** After SPL-4993: `mergePair`'s request inputs and `fanoutMerged`'s edit stamp
  as structs.
- **03:** Pass `inlineMessages`' page inputs and filters as one struct.
- **04:** Pin three archive rules; both card action composables take one object.
- **05:** After 04: pin the drop and start steps; `useCardMove` takes one object.
- **06:** After r56-08 and 01-05: delete the seven lines they leave.

## 5. Panel and reviewers (R7)

- Editor: c-029 (claude). Both seats sign the plan sha (rulebook 3.2).
- **Panel seat:** an agy seat, cross-vendor as rulebook 3.2 asks; queued by the holder
  (ask dd34c093, re-put as 1558bc1c), placed as **a-165** (SPL-5230): FAIL on v0.3
  `9b2b46aeb` (be6f15dc; holder send-back 6bdc7cc3), 3 defects W1-W3 and 3 notes,
  folded in v0.4; it re-reviews v0.4. agy reviews this plan only, never a
  row.
- **Row reviewers: same-vendor R7 under waiver 1a7c70da, never cross-vendor.** c-001
  ruling 24802acd (16:1xZ), relayed by the holder in a50aca31: the waiver stands for
  round 31's claude R7 seats on claude authors. It **lapses on the first owner post
  that says grok is back**. Its stated basis, quoted, not re-run here except the first:
  prd agent kinds off [grok, qwen] (re-read here: `ENV=prd ./run -a
  do_spl_hub_agent_kinds` -> `prd instance agent kinds: off [grok,qwen], paused []`,
  2026-11-10T16:00Z, n=1); mistral reviews paused (cf7a7ee5); agy takes no code R7;
  0 HUM-10 posts since 11-07 14:00Z say grok is back (this lane's prd hub tools did
  not connect, so not re-searched here).
- **Conditions per row:** the reviewer is a FRESH claude session, never
  the author and never a seat already in the work; it reads only the tree; its brief
  names waiver 1a7c70da. Its review line says same-vendor under the waiver, in the `read:`
  field. Mistral reviews stay paused (cf7a7ee5).
- The waiver does not make a row compliant: rulebook 2.7.5 fails an equal vendor pair,
  and the retro names each such row.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `send` `WIDE` (`channel.ts:541`) | 7 call sites plus 2 wirings, over the 5-site cap; **input for round 32** (two rows) | section 2 |
| a live-store pin of `send` | no unit test loads the channel store (0); a harness is wider than a row; **input for round 32** | section 2 |
| `hubclient` `writeAtomic`, `hold` | no small case found | round 30 section 2 |
| Go `wideFuncs` interface pairs | an interface change over two stores | section 2 |
| Go `longFuncs` | not split here | section 2 |
| `provision-firebase-dns` long example | byte-pinned to csi-rel | round 30 section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | round 29 section 2 |
| fleet-critical long Bash functions, low packages, raw text, slow scanners | not re-measured | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 6 (refactor 5, test 1; Go 3, WUI 2, both gates 1) |
| vendor | claude 6 |
| kind | simple_coding 5, tests 1 |
| batches | batch 1: 4 rows (row 02 also after SPL-4993); batch 2: 1; batch 3: 1 |
| WUI `WIDE` lines | 6 -> 4 (r56-08) -> 1 (row 06, `send`) |
| Go `wideFuncs` lines | 14 -> 12 (r56-08) -> 8 (row 06) |
| new pins | 2 new files (rows 01, 04); 1 file extended (row 05) |
| measured on | `35927a0d8`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-029): 6 rows, slug `r57`, measured on `35927a0d8`. Carries
  round 30's section 6: `RecordAuthEvent`, `mergePair`, `fanoutMerged`,
  `inlineMessages` -> rows 01-03; the three card composables (round 29's r55-03 /
  r55-04, never placed) -> rows 04, 05; `send` and its live-store pin -> round 32.
- v0.2: the holder's reads folded (c-002@sat b779f524): the sat queue's 22 briefs 0
  hits; lane-map now exits 4 (16:11:32Z here, and the holder's 16:1xZ read with 13
  lanes recording no files), so section 3.2 says live lanes are NOT proven free; R7
  row vendor stated as not ruled (sections 5, 9); the panel seat queued (dd34c093).
  r56-08 asked to be queued (19c0436d). No row changed.
- v0.3: c-001's R7 ruling 24802acd (via a50aca31) folded: same-vendor R7 under waiver
  1a7c70da for round 31, never cross-vendor, lapsing on an owner post that grok is
  back (sections 5, 9). No row changed.
- v0.4: the agy panel's FAIL (a-165 be6f15dc, holder send-back 6bdc7cc3) folded.
  W1: row 05's control was green, so row 05 pins first in `card-move-steps.test.mjs`
  (drop and start cases) and is renamed `r57-05-wui-pin-card-move-object`. W2: `send`
  has 7 store call sites, not 8 (`TopBar.vue:254` is the omnibox target's `send`).
  W3: the r55 commit count matches subjects; `--grep` finds 1 plan-doc body. N1: row
  02's control fails at `merge_test.go:77`. N2: r56-08 live as c-495@sat; SPL-5194
  landed; the panel seat placed. N3: the spawn re-check takes all 15 paths. Lines
  re-checked on `078c9a72c` (unchanged). Rows 01-04 and 06 unchanged.
- v1.0: a-165's PASS on v0.4 `3bb81fe8e` (verdict 7a9be124; the holder's copy
  45e4b806; 0 defects, 0 notes), per the holder's 266b3bd7. Status, section 8 and
  section 9 only.
- v1.0 signed: a-165's signature on `809788f13` (a034472f) recorded. Status and section
  9 only.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-029 (claude): drafted v0.1 to v0.4 and v1.0. **Signed v1.0.**
- Panel reviewer seat: agy, a-165: FAIL on v0.3 `9b2b46aeb` (be6f15dc, 3 defects, 3
  notes, folded in v0.4); **PASS on v0.4 `3bb81fe8e`** (7a9be124): 0 defects, 0 notes;
  W1-W3 and N1-N3 resolved; rows 01, 04, 05 pin-first gaps and rows 02, 03, 06
  controls planted on `078c9a72c` and re-checked; dist hygiene clean, fleet rules 0
  drift; `r57-` 0 on `origin/master` `8edd245f0`. v1.0 differs from v0.4 by the
  status line, section 8 and this section only. **SIGNED v1.0 `809788f13`**
  (a034472f, its own message): diff from v0.4 checked by it (1 file, status, sections
  8 and 9 only), dist hygiene clean. This later commit adds only that record.
- Row R7 seats: fresh **claude** sessions, **same-vendor R7 under waiver 1a7c70da**
  (c-001 24802acd), round 31, never cross-vendor; lapses on the first owner post that
  says grok is back.
