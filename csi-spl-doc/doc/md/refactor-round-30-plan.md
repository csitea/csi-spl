# Refactoring round 30 - plan (9 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5190  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row**; `do_spl_lane_mix` picks claude for `tests` and `simple_coding`.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now.** The dispatch holder's brief (c-002@sat) names the trigger: SPAWN SUPPLY
LEAD d7b1f38c (c-001, task `spawn-share`), rulebook 1.4. Round 29
([plan](refactor-round-29-plan.md), slug `r55`) is **not served**: on `3c473d8f8`,
`git log 3c473d8f8 --format='%h %s' -E --grep='r55-'` -> 7 commits, rows 01, 02, 05,
06, 07, 08, 09. Rows **03 and 04 have no commit**; they edit `MessageCard.vue` and the
card composables, so no row here touches those files (section 3.2). No round 29 retro
is on `3c473d8f8` (`ls csi-spl-doc/doc/md/ | grep -c refactor-round-29-retro` -> 0),
so section 2 re-measures round 29's own carry-over list (its sections 5 P1 and 6).

Round 30 focus: **8 of the 9 rows run at once in batch 1.** One row drops the 3 `WIDE`
lines round 29 left stale; two take the last single-caller WUI functions over the
parameter cap (`perfFeedPair`, `sendLive`); two do the same for Go (`searchSections`,
`scanMove`); one pins the client outputs no test reads; one tests `hubclient`'s
`revive` on resend and raises its floor; one shortens the last over-long action
example. Row 09 (batch 2) drops the 4 `WIDE` lines rows 02, 03, 07, 08 leave.

**Status: v0.1 DRAFT**, not signed (section 9). No row lane starts before the panel
signs the plan sha.

Editor: **c-716** (claude). Panel seat: asked of the dispatch holder (section 5).

**One sha:** every count is measured on **`3c473d8f8`** (`origin/master`
3c473d8f87b7fd5a9ef247a69e1fcf0b924194de, 2026-11-09T23:20:28Z), n=1 per command
unless stated. Go: go1.26.10. Go and Bash reads are in this lane's worktree at that
sha, clean. The WUI gate ran on a `git archive 3c473d8f8` copy with the main
checkout's `node_modules` linked in, read only; row 05's mutation probe ran on a
second archive copy. Queue and lane readings are live state, so they carry their own
time, not this sha.

## 1. How to read this

- **Slug prefix `r56`.** On `3c473d8f8`:
  `git log 3c473d8f8 --oneline -E --grep='r56-' | wc -l` -> 0;
  `git branch -r | grep -c 'r56-'` -> 0;
  `git ls-remote origin 'refs/heads/*r56*' | wc -l` -> 0;
  `grep -rl 'r56-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box. The last slug is taken: `r55` has 7 commits and 4 remote
  `review/r55-*` branches.
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for a test row, a **red control**: the new case fails
  on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `wui:` = `csi-spl-wui/`, `api:` =
  `csi-spl-api/`, `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` =
  `src/bash/run/`, `t/` = `src/bash/tests/` of the sub-project named. Lines as of
  `3c473d8f8`; a function's site is its first line. A break is named by its code, not
  its line (R15).
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** see section 5; no seat is named
  before a row is queued.
- **Subject** (R6 reads it): `<type>(r56-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if the number
  moved.
- **Tests per row (R2):** WUI: `grep -rlE <name> wui:tests/unit`, listed per row;
  **bold** = reads the site's source text (`src(` / `readFileSync`), not checked file
  by file: the row lane corrects the marks. Go: the package's tests plus
  `bash api:src/bash/tests/run-all-tests.sh`; a store row adds
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres). WUI also runs the e2e
  files the pre-push map selects
  (`cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`).
- **What was and was not run:** row 05's survival probe (section 2), n=1, and the
  `hubclient` coverage, n=3. **No other red control or break named here has been
  planted, and no case has been written.**

## 2. Where the rows come from (measured on `3c473d8f8`)

**Taken:**

| source | input | command on `3c473d8f8` | n | row |
|---|---|---|---|---|
| round 29 5 P1, 6 | the `WIDE` lines rows r55-02 and r55-05 left | `node tests/unit/cleancode.test.mjs` (archive copy) | `13274 functions, 0 listed long, 9 listed wide, none deeper than 4 or wider than 5`; 3 `NOTE WIDE`: `useCardEdit`, `liveReader`, `sessionMethods` | **Row 01** |
| round 29 2, 6 | `perfFeedPair` `WIDE`, its caller | `grep -rn 'perfFeedPair\|sink.feed' wui:src` | 6 params (`perf-rum.mjs:552`); handed as the sink's `feed` at `perf-rum.mjs:392` (`perfAttach({ ..., feed: perfFeedPair })`) and called once, `perf-mark.mjs:75` `sink.feed(st, f, rows, fresh, shown, o)`. `perf-mark.test.mjs:22` passes it as a sink by reference. Caller now established | **Row 02** |
| round 29 2, 6 | `send`, `sendLive` (`channel.ts`) `WIDE` | `grep -nE 'sendLive' wui:src/stores/channel.ts`; `grep -rnE 'channel\.send\(\|store\.send\(\|\.send\(text' wui:src \| wc -l` | `sendLive` (`:637`, 6 params) is a private step: one caller, `send` at `:542`; its arguments already have a type, `LiveSendArgs` (`:599`), which `liveSendFrame` takes. `send` (`:541`) has 9 caller lines in pages and components | **Row 03** takes `sendLive` only |
| round 29 6; c-002 550e84b1 (W1 of c-690's R7 be4e21c7 on r55-05) | `sessionMethods` outputs no test reads | `grep -rnE 'client\.(tenant\|base\|configError)\|api\.(tenant\|configError)\b' wui:tests/unit` | 0 lines. `sessionMethods` at `spool-client.mjs:503`, its call `:330`. c-690's 5 planted wirings green over the 50 client-naming files, n=1 each: quoted, not re-run here | **Row 04** |
| round 29 6; c-002 b14413f1 (N1 of c-471's review of r55-06) | `hubclient.go:783` `s.c.revive(m.From)` survives removal | on an archive copy, `:783` replaced by `_ = 0`, `go test -count=1 ./internal/hubclient/` | `ok`, n=1: **confirmed, no test fails**. `revive` itself has a unit case (`agent_drop_test.go:58`); its call in `sendFrame` has none | **Row 05** |
| round 29 6 (v1.1 ruling) | `internal/hubclient` floor | `go test -count=1 -race -cover ./internal/hubclient/`, n=3; `grep -n hubclient api:src/bash/tests/go-coverage-floor.txt` | 90.1, 90.1, 90.1 against floor `89.6` (`:101`). r55-06 is on trunk (`5c0a4b600`) | **Row 05** raises it |
| round 29 6 | `hubclient` `now`, `timeout` | `go tool cover -func=<f>`, the profile's zero-count blocks | `now` 66.7 (`hubclient.go:195-197`, `c.Now == nil`), `timeout` 66.7 (`:223-225`, `ReadyTimeout <= 0`) | **Row 05** |
| Go clean code gate | `wideFuncs` with one private caller | `grep -rnE '\b<name>\(' go:internal` per entry | `searchSections` (`hub/search.go:234`, 8 params, one caller `:167`); `scanMove` (`store/message_move_postgres.go:191`, 8 params, two callers `view_postgres.go:554`, `message_edit_postgres.go:63`) | **Rows 07, 08** |
| round 29 6 | `provision-firebase-dns` `[long-example]` | `do_parse_metadata iac:run/provision-firebase-dns.func.sh \| grep '^example='`, length less 8 | **227** characters: the parser joins the 4 comment lines (`:15-18`, two `\` continuations) into one `example=`. `bash iac:t/action-header-tags.tst.sh` -> `measured 802 files: 20 missing, 1 long-example` | **Row 06** |
| rows 02, 03, 07, 08 here | the 4 `WIDE` / `wideFuncs` lines they leave | as row 01; the Go gate `t.Logf`s `no longer takes more than` (`cleancode_test.go:112`) and does not fail | 4 | **Row 09**, batch 2 |

**Deferred or dropped:**

| source | input | command on `3c473d8f8` | n | disposition |
|---|---|---|---|---|
| round 29 5 P1 | the `WIDE` lines of `useCardMove`, `useCardMessageActions`, `useCardTopicActions` | `git log 3c473d8f8 --oneline --grep='r55-03'`, `--grep='r55-04'` | 0 commits each: rows r55-03, r55-04 not landed, the functions still wide | **Round 31**: only after r55-03 / r55-04 land; their files are those lanes' |
| round 29 2, 6 | `send` `WIDE` (`channel.ts:541`) | as row 03 | 9 caller lines across pages, components and `msg-ai-run.ts`; more than the 5-site cap | **Left out**: a store's public action, needs its own split |
| round 29 2 | `hubclient` `writeAtomic` (61.5), `hold` (70.5) | the profile's zero blocks | `writeAtomic` `:1297-1305`: the `Write` and `Close` failures of a temp file, not reachable without a fault-injecting file; `hold` `flush.go:571-573` (the `Flush` warning), `:597-599` (`SessionProbe == 0` default) inside a long-running loop | **Left out**: no small case found |
| Go `wideFuncs` | `IssueToken` (2), `CASFleetLease` (2), `MoveMessage` (2), `MergeTopic` (2) | gate comment `cleancode_test.go:41-43` | implement one interface each, leave together | **Left out**: interface change, wider than a row |
| Go `wideFuncs` | `fanoutMerged`, `mergePair`, `inlineMessages`, `RecordAuthEvent` | `grep -rnE '\b<name>\('` | callers not read one by one; `RecordAuthEvent` is an adapter of an `auth` interface | **Round 31** input, not measured further |
| Go `longFuncs` | `(*Server).Handler`, `ProvisionMember` | not re-measured | none | **Left out**, as round 29 |
| round 29 2 | the 9 `(required)` header files | not re-measured | none | **Left out**: a behaviour change, bug-round input, as rounds 20-29 |
| round 29 2 | the fleet-critical long Bash functions, low store / hub / auth packages, raw text, slow scanners | **NOT re-measured** | none | **Left out**, as round 29 |

## 3. The 9 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `test(r56-01-wui-drop-stale-wide-lines)` | a gate's list holds no stale line (`r55-01`) | three functions came under the cap and left their lines | `wui:tests/unit/cleancode.test.mjs:48` (`useCardEdit`)<br>`:55` (`liveReader`)<br>`:56` (`sessionMethods`) | 3 lines | Delete exactly the lines the gate NOTEs. Tests: `node tests/unit/cleancode.test.mjs` (`9 listed wide` -> `6`, no `NOTE WIDE`); `pnpm run test:unit`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** delete a still-wide line instead (`perfFeedPair`) -> the gate fails naming it, restored. | either | claude | tests | 1 |
| 02 `refactor(r56-02-wui-perf-feed-pair-object)` | a function takes its per-call inputs as one object | `perfFeedPair` takes 6 parameters; its one call passes them positionally | `wui:src/utils/perf-rum.mjs:552` (`perfFeedPair`)<br>`wui:src/utils/perf-mark.mjs:75` (its one call, `sink.feed`) | 1 function, 1 call | `perfFeedPair(st, f, { rows, fresh, shown }, o)` and `sink.feed(st, f, { rows, fresh, shown }, o)`; the jsdoc of both follows. `perf-rum.mjs:392` and `perf-mark.test.mjs:22` pass it by reference and stay. Leave the `WIDE` line (row 09). Tests: `perf-mark.test.mjs`, `perf-rum.test.mjs`, `perf-idle.test.mjs`, **`unused-exports.test.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs` (a `NOTE WIDE:` after); the e2e files the map selects. **Control:** at `perf-mark.mjs:75` swap `fresh` and `shown` -> a switch-view case of `perf-mark.test.mjs` fails, restored; not run here. | either | claude | simple_coding | 1 |
| 03 `refactor(r56-03-wui-send-live-args-object)` | as row 02, with the type that already exists | `sendLive` takes 6 parameters and spreads them into `LiveSendArgs` for `liveSendFrame` | `wui:src/stores/channel.ts:637` (`sendLive`)<br>`:542` (its one caller, in `send`)<br>`:641` (its `liveSendFrame` call) | 1 function, 1 caller | `sendLive(a: LiveSendArgs)`, called `sendLive({ text, parentTaskId, files, channelId, isParent, dmPeer })`; its body destructures `a`. `send`'s signature unchanged. Keep the text `async function sendLive` (sliced by **`send-failure.test.mjs:93`, `:134`** and **`pane-send-lost.test.mjs:93`**) and the patterns **`offline-queue.test.mjs:113-116`** match. Leave the `WIDE` line (row 09). Tests: those three, `omnibox-topic.test.mjs`, the 25 files `grep -rlE 'sendLive\|stores/channel' wui:tests/unit` lists, through `pnpm run test:unit`; `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. **Control:** drop `parentTaskId` from the call object -> `omnibox-topic.test.mjs` (`task_id: parentTaskId \|\| newId()`) or a reply case fails, restored; the lane names the case; not run here. | either | claude | simple_coding | 1 |
| 04 `test(r56-04-wui-pin-session-outputs)` | a client's public fields under test | no unit test reads `.tenant`, `.base` or `.configError` of a client (section 2) | `wui:src/utils/spool-client.mjs:503` (`sessionMethods`, read only)<br>`:330` (its call, read only)<br>`wui:tests/unit/spool-client-session-outputs.test.mjs` (new) | 3 fields | `createSpoolClient({ base: '<url>/', tenant: 't1', configError: 'e', mock: false })` -> `.base` is the url with the trailing `/` gone, `.tenant` `'t1'`, `.configError` `'e'`, `.mock` `false`; the defaults (`{}`) -> `''`, `''`, `''`, `true`. Non-test code unchanged. Tests: the new file; `pnpm run test:unit`. **Red control:** swap `tenant` and `root` in `sessionMethods`' return -> the new case fails, restored (c-690 found this swap green over today's 50 files). | either | claude | tests | 1 |
| 05 `test(r56-05-api-hubclient-revive-defaults)` | a call that survives removal gets a case; a floor follows its tests (`r55-06`, `r55-07`) | `s.c.revive(m.From)` can be deleted with every test green; `now` and `timeout` defaults unrun; floor 0.5 under the read | `go:internal/hubclient/hubclient.go:783` (`revive` in `sendFrame`, read only)<br>`go:internal/hubclient/hubclient.go:194` (`now`), `:222` (`timeout`), read only<br>`go:internal/hubclient/revive_defaults_test.go` (new)<br>`api:src/bash/tests/go-coverage-floor.txt:101` | 1 call, 2 defaults, 1 floor | `t.TempDir()` only. **revive:** an agent marked not running (its `stopSince` set, as `agent_drop_test.go` does) whose first send the hub refuses `from_not_announced` -> after `sendFrame` its `stopSince` entry is gone; reuse r55-06's `ub` helpers where they fit. **Defaults:** `Client{}.now()` within a second of `time.Now()`; `Client{}.timeout()` == `defaultReadyTimeout`. Then the floor line to the lowest of n=3 `go test -count=1 -race -cover ./internal/hubclient/`, in the file's comment format. Non-test code unchanged. Helpers prefixed `rd`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. R9 (a floor): as row 01. **Red control:** `:783` removed -> the revive case fails (it is green today, section 2), restored. | either | claude | tests | 1 |
| 06 `refactor(r56-06-iac-firebase-dns-example-short)` | a header's example fits the gate's 200 characters (`r55-09`) | the parser joins the 4 example lines into one of 227 characters | `iac:run/provision-firebase-dns.func.sh:15-18`<br>`iac:t/action-header-tags-baseline.txt` (its `[long-example]` line) | 4 comment lines, 1 baseline line | Shorten to at most 200 characters joined: `<placeholders>` for the long values (the project, the zone, the FQDN), or one example only; comment lines only; the baseline line deleted in the same commit. The lane re-measures with `do_parse_metadata <f> \| grep '^example='`. Tests: **`action-header-tags.tst.sh`** (`1 long-example` -> `0`), `wui-hosting-019-031.tst.sh`, `gcp-sa-key-email.tst.sh`, **`bash-cleancode.tst.sh`**; `./run -a do_check_pre_push_lint`. R9 as row 01. **Red control:** delete the baseline line before shortening -> the gate fails naming the file, restored. | either | claude | simple_coding | 1 |
| 07 `refactor(r56-07-api-search-sections-page)` | pass the struct instead (`cleancode_test.go:20`) | `searchSections` takes 8 parameters, at the listed maximum | `go:internal/hub/search.go:234` (`searchSections`)<br>`:167` (its one caller) | 1 function, 1 caller | The page inputs `types, cur, hash, limit` as one unexported struct (e.g. `searchPage`), so it takes at most 7 (5 here). Results and error unchanged. Leave the `wideFuncs` line (row 09). Tests: `go test -count=1 ./internal/hub/` (the 19 `search*_test.go` files among them); `run-all-tests.sh`; `go test ./internal/cleancode/ -v -run TestCleanCode` (a `no longer takes more than` log after). **Control:** swap `hash` and the cursor's use in the new struct -> `search_paging_pin_test.go` fails, restored; the lane names the case; not run here. | either | claude | simple_coding | 1 |
| 08 `refactor(r56-08-api-scan-move-struct)` | as row 07 | `scanMove` takes 8 parameters, 7 of them scan targets | `go:internal/store/message_move_postgres.go:191` (`scanMove`)<br>`go:internal/store/view_postgres.go:554` (caller)<br>`go:internal/store/message_edit_postgres.go:63` (caller) | 1 function, 2 callers | `scanMove(v *MoveMark, c moveScan)` with `moveScan{At *time.Time; By, FromChannel, FromTask, Channel, Task, Parent *string}`; `moveCols` and the column order unchanged. Leave the `wideFuncs` line (row 09). A store change: **Postgres** (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`). Tests: `go test -count=1 ./internal/store/ ./internal/hub/` with `message_move_test.go`, `topic_merge_test.go`, `topic_promote_test.go` and the hub's `*move*_test.go` on Postgres; `run-all-tests.sh`. **Control:** swap `Channel` and `FromChannel` in `scanMove` -> a move case on Postgres fails, restored; the lane names it; not run here. | either | claude | simple_coding | 1 |
| 09 `test(r56-09-drop-wide-lines-of-r56)` | as row 01, both gates | rows 02, 03, 07, 08 leave 4 stale lines | `wui:tests/unit/cleancode.test.mjs` (`perfFeedPair`, `sendLive` lines)<br>`go:internal/cleancode/cleancode_test.go` (`searchSections`, `scanMove` lines) | 4 lines | Placed only after rows 01, 02, 03, 07, 08 are on trunk (R16); a row not landed keeps its line, and the lane says which. Delete exactly the lines the gates note. Tests: `node tests/unit/cleancode.test.mjs` (no `NOTE WIDE`); `go test -count=1 -v ./internal/cleancode/` (no `no longer` log); `pnpm run test:unit`; `run-all-tests.sh`. R9 as row 01. **Red control:** delete a still-wide line (`send`) -> the WUI gate fails naming it; delete `mergePair` -> the Go gate fails; both restored. | either | claude | tests | 2 (after 01, 02, 03, 07, 08) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-08, no file in two rows.** Row 01 owns `cleancode.test.mjs`; row 02
  `perf-rum.mjs`, `perf-mark.mjs`; row 03 `channel.ts`; row 04 one new test file; row 05
  one new test file and `go-coverage-floor.txt`; row 06 its action and
  `action-header-tags-baseline.txt`; row 07 `search.go`; row 08 its three store files.
  Rows 02, 03, 07, 08 change code that runs; row 06 changes comment lines. No row edits a
  migration, `csi-spl-cnf/`, a workflow or terraform.
- **Batch 2: row 09** shares `cleancode.test.mjs` with row 01 and deletes the lines of
  rows 02, 03, 07, 08. Placed within 30 minutes of the last of them landing (R16).
- Rows 02, 03 run `cleancode.test.mjs` and rows 07, 08 the Go gate, but do not edit
  them, so they do not collide with row 01.
- Row 05 raises the floor last, after its cases, in the same commit.

### 3.2 Off every live lane and every queued row (R3)

- **Round 29's unlanded rows:** r55-03 (`useCardMove.ts`, `MessageCard.vue`,
  `card-move-steps.test.mjs`) and r55-04 (`useCardTopicActions.ts`, `MessageCard.vue`,
  `card-message-actions.test.mjs`, a new `card-topic-actions.test.mjs`). No row here
  names any of them (`grep` of section 3 for `MessageCard\|useCardMove\|useCardTopicActions\|card-` -> 0).
  Their `WIDE` lines stay in the gate, row 01 and row 09 keep them.
- **Live lanes:** `lane-map.sh --check <the 14 paths of the 9 rows, the new files included, comma separated> --agent c-716`
  -> **exit 4** (2026-11-09T23:29:29Z, exit code read directly). No path is printed as
  owned. Eight live lanes on sat record no files: `c-308`, `c-415`, `c-427`, `c-443`,
  `c-461`, `c-462`, `c-467`, `c-473`. **Exit 4 is not free, and this plan did not clear
  it.** Of their briefs, one is on this box (`c-461`, `fd9e5566`): `grep -oE <the rows'
  paths and names>` -> 0 hits. `c-467`'s fix is on trunk (`0bb9d4773`). `c-462`
  (archive a topic from any message menu) is the likeliest to touch `channel.ts`
  (row 03); its brief is not here. The three `-rotate` seats are not row lanes. The
  dispatch holder re-runs the check before each row's spawn (R3).
- **Spawn queue (2026-11-09T23:30:36Z):** `./run -a do_spl_spawn_queue` -> `33 queued, 0
  placing`; 33 slugs parsed; **1 brief on this box** (0 hits), **32 are on sat only**
  (`WAIT ... not under /var/spool-hub/dispatch/briefs here`), so not grepped here. By
  their slugs and summaries none names a WUI composable, `perf-*`, `spool-client`,
  `hubclient`, `search`, `scanMove` or the firebase DNS action; `c002-bug-hub-prio-sync-flake-under-load`
  touches the hub's Postgres tests, not a file of row 07 or 08 by its summary. A slug is
  not a brief: the holder greps them on sat.

## 4. Per row: what the lane does

- **01:** Delete the three stale `WIDE` lines.
- **02:** Pass `perfFeedPair`'s per-call inputs as one object.
- **03:** `sendLive` takes its `LiveSendArgs`.
- **04:** Pin the client's `base`, `tenant`, `configError`, `mock` outputs.
- **05:** A case for `revive` on resend and the two defaults; raise the `hubclient` floor.
- **06:** Shorten `provision-firebase-dns`' joined example.
- **07:** Pass `searchSections`' page inputs as one struct.
- **08:** Pass `scanMove`'s scan targets as one struct.
- **09:** After 01-03, 07, 08: delete the four lines they leave.

## 5. Panel and reviewers (R7)

- Editor: c-716 (claude). Both seats sign the plan sha (rulebook 3.2).
- **Panel seat:** an agy seat, cross-vendor as rulebook 3.2 asks; **asked of the
  dispatch holder c-002@sat** with this draft (section 9).
- **Row reviewers:** round 29 ran them same-vendor under waiver 1a7c70da, ruled valid
  for round 29 only (its section 5). **This plan does not assume it holds for round
  30.** This lane could not read the owner's posts (its prd hub tools did not connect),
  so it asks the holder to confirm the R7 vendor before the first row is queued. Until
  then: a fresh claude session per row under waiver 1a7c70da if confirmed, never the
  author, never a seat already in the work, reading only the tree; mistral reviews stay
  paused (cf7a7ee5); agy gets no code R7.
- The waiver does not make a row compliant: rulebook 2.7.5 fails an equal vendor pair,
  and the retro names each such row.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `useCardMove`, `useCardMessageActions`, `useCardTopicActions` `WIDE` lines | r55-03, r55-04 not landed; **input for round 31** | section 2 |
| `send` `WIDE` (`channel.ts:541`) | 9 caller lines, over the site cap; **input for round 31** | section 2 |
| `hubclient` `writeAtomic`, `hold` | no small case found | section 2 |
| Go `wideFuncs` interface pairs | an interface change | section 2 |
| `fanoutMerged`, `mergePair`, `inlineMessages`, `RecordAuthEvent` | not measured further; **input for round 31** | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | round 29 section 2 |
| Go `longFuncs`, fleet-critical long Bash functions, low packages, raw text, slow scanners | not re-measured | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 9 (refactor 5, test 4; WUI 4, Go 3, iac 1, both gates 1) |
| vendor | claude 9 |
| kind | simple_coding 5, tests 4 |
| batches | batch 1: 8 rows; batch 2: 1 row |
| WUI `WIDE` lines | 9 -> 6 (row 01) -> 4 (row 09) |
| Go `wideFuncs` lines | 14 -> 12 (row 09) |
| `[long-example]` lines | 1 -> 0 |
| floors raised | 1 (`hubclient`, 89.6 -> the lowest of n=3; read 90.1 n=3 here) |
| measured on | `3c473d8f8`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-716): 9 rows, slug `r56`, measured on `3c473d8f8`. Carries
  round 29's section 6 and P1: of its 6 `WIDE` lines, the 3 whose rows landed go to
  row 01, the 3 of r55-03 / r55-04 to round 31. c-002's two candidates (msg 8ea902d7):
  b14413f1 -> row 05, 550e84b1 -> row 04.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-716 (claude): drafted v0.1. **Not signed yet.**
- Panel reviewer seat: **not placed yet**; asked of the dispatch holder.
