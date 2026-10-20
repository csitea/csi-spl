# Refactoring round 15 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Issue: SPL-2722  

Owner HUM-10 directives:
- t1 topic `dc15ad65-a5c8-495c-b244-030b6f4d768d` msg 686bc1a3: **"keep 2 row lanes in parallel"**.
- msg b8e22a15: **"do not ask me for input - just reach consensus between all of the members of the panel and start implementation"**.
- msg 7f664194: 20-30% allocation of resources for refactoring.
- owner 10-17 (t1 b61851fb): **no mistral coding rows** (docs and review only).
- owner HUM-10 directive for Round 15 (`SPL-2170`): retiring WUI `.mjs` layer to pure TypeScript (122 `declare module` blocks remaining in `mjs-shims.d.ts`, 290 `.mjs` files in `src/`).

Round 15 focus: **WUI TypeScript migration (retiring mjs-shims.d.ts), final SFC decomposition (eliminating the BIG map in sfc-script-size), errorJournal decomposition, unused exports ratchet, backend Go coverage floors (blob, cmd/spool, action, config), and central runner script byte-parity**.  
Concurrency: **build 2 row lanes in parallel at all times**.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps 1..1 up to 3 max 5, bands, R1-R16), by pointer.  

**Status: v0.1, Proposed by Editor a-607@PC (agy)**.

Editor: **a-607@PC** (agy).  
Panel reviewers: **c-xxx@<box>** (claude), **m-xxx@<box>** (mistral - docs/review only), **g-xxx@<box>** (grok - quota checked/conditional).  

**One sha:** every count is measured on **`673004efa`** (`origin/master`, 2026-10-20), n=1 per command unless stated. Inputs: [refactor-round-14-retro.md](refactor-round-14-retro.md) section 7.

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else, with a test that shows behaviour kept, or for a gate / test addition a **red control**: the check fails on the bad input before the change and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `utl:` = `csi-spl-utl/`, `api:` = `csi-spl-api/`. Lines as of `673004efa`.
- **Box:** the preferred box (`sat` or `PC`); the spawner's box pick may move a row (no pin).
- **Vendor:** owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`), restricted by owner 10-17 (no mistral coding rows; coding assigned to claude).
- **Subject** (R6 reads it): `<type>(r15-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`. The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands in the reviewer's `log:` file.

## 2. Where the rows come from (measured on `673004efa`)

| source | command | n | row |
|---|---|---|---|
| retro 7.2 | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/pages/issues.vue \| wc -l` | 876 script lines (ceiling 876 in `sfc-script-size.test.mjs:29`) | 01 |
| retro 7.7 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/blob/` | 67.6% statement coverage (floor 66.9% in `go-coverage-floor.txt:32`) | 02 |
| retro 7.1 / SPL-2170 | `grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts` | 122 shim blocks remaining; Group C: 8 leaf utils with 0 .mjs imports | 03 |
| retro 7.7 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./cmd/spool/` | 75.1% statement coverage (floor 75.6% in `go-coverage-floor.txt:13`) | 04 |
| retro 7.1 / SPL-2170 | `find csi-spl-wui/src -name "*.mjs" \| wc -l` | 290 .mjs files in src/; Group D: 8 leaf utils with 0 .mjs imports | 05 |
| retro 7.7 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/action/` | 75.6% statement coverage (floor 71.1% in `go-coverage-floor.txt:17`) | 06 |
| retro 7.5 | `wc -l csi-spl-wui/src/composables/errorJournal.mjs \| awk '{print $1}'` | 731 lines (largest composable in WUI) | 07 |
| r14-09 follow-up | `diff -u <(sed -n '320,400p' csi-spl-iac/src/bash/run/run.sh) <(sed -n '320,400p' csi-spl-utl/src/bash/run/run.sh)` | `csi-spl-utl` runner still has unsplit `do_log` (131 lines); `iac` and `orc` split in r14-09 | 08 |
| retro 7.3 | `node csi-spl-wui/tests/unit/unused-exports.test.mjs` | 54 unused exports in ALLOW (cap 54) | 09 |
| retro 7.7 | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/config/` | 78.1% statement coverage (floor 76.8% in `go-coverage-floor.txt:37`) | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2 bold: source-text tests) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r15-01-wui-decompose-issues-page)` | component decomposition, eliminate BIG map | `src/pages/issues.vue` `<script>` tag is 876 lines (ceiling 876 in `sfc-script-size.test.mjs:29`); final SFC in `BIG` map; filter state and detail form logic mixed in page script | `wui:src/pages/issues.vue:1185-2060`<br>`wui:tests/unit/sfc-script-size.test.mjs:28-30` | 876 script lines | Decompose issue filter state into `useIssueFilters.ts` and detail form inputs into `useIssueDetailForm.ts`; shrink script under 500 lines; delete `src/pages/issues.vue` from `BIG` map in `sfc-script-size.test.mjs` (eliminates `BIG` map). Tests: `tests/e2e/issues.test.mjs`, `tests/unit/sfc-script-size.test.mjs`, unit runner, typecheck. **Red control:** delete `src/pages/issues.vue` from `BIG` while script > 500 lines fails test; passes after shrink. | sat | claude | complex_coding | 1 (Lane 1 start) |
| 02 `test(r15-02-go-coverage-blob-store)` | unit test coverage, storage testability | `internal/blob` statement coverage is 67.6% (floor 66.9% in `go-coverage-floor.txt:32`); S3 and cached blob operations have uncovered error/branch paths (`s3.go:201-385`, `cached.go:61-108`) | `api:src/go/spool-hub-api/internal/blob/s3.go:201-385`<br>`api:src/go/spool-hub-api/internal/blob/cached.go:61-108`<br>`api:src/bash/tests/go-coverage-floor.txt:32` | 67.6% statement coverage | Add table and mock unit tests in `internal/blob/s3_test.go` and `internal/blob/cached_test.go` covering S3 error handling, precondition checks, and cache retention; raise statement coverage floor in `go-coverage-floor.txt` from 66.9% to >= 70.0%. Tests: `go test -count=1 -cover ./internal/blob/`. **Red control:** mutate S3 error handling or cache retention condition to trip unit test assertion. | PC | claude | tests | 1 (Lane 2 start) |
| 03 `refactor(r15-03-wui-ts-convert-leaf-utils-group-c)` | TypeScript migration, drop shim blocks | Retiring generated `mjs-shims.d.ts` (`SPL-2170`); 8 leaf utils import nothing from `.mjs` and can be converted to `.ts` directly | `wui:src/utils/plain-text.mjs`<br>`wui:src/utils/bidi.mjs`<br>`wui:src/utils/pane-scroll.mjs`<br>`wui:src/utils/channel-order.mjs`<br>`wui:src/types/mjs-shims.d.ts` | 8 leaf utils (122 -> 114 shims) | Convert 8 leaf utils (`plain-text`, `bidi`, `pane-scroll`, `channel-order`, `doc-path-hook`, `commit-link-hook`, `msg-apply`, `code-langs`) to `.ts` with exact exported types; update import references; drop 8 `declare module` blocks from `mjs-shims.d.ts`. Tests: `pnpm run typecheck`, `node tests/unit/unused-exports.test.mjs`, unit runner. **Red control:** a planted stale block for any converted module in `mjs-shims.d.ts` trips `pnpm run shims:check` (or node check). | sat | claude | simple_coding | 2 (Lane 1, after 01) |
| 04 `test(r15-04-go-coverage-cmd-spool)` | CLI unit test coverage, testability | `cmd/spool` statement coverage is 75.1% (floor 75.6% in `go-coverage-floor.txt:13`); `caps.go:22-64` (`cmdCaps`, `readCaps`, `capsCheck`) has 0.0% coverage; flags in `doc.go:158-196` have branch gaps | `api:src/go/spool-hub-api/cmd/spool/caps.go:22-64`<br>`api:src/go/spool-hub-api/cmd/spool/doc.go:158-196`<br>`api:src/bash/tests/go-coverage-floor.txt:13` | 75.1% statement coverage | Add `cmd/spool/caps_test.go` covering capability listing, capability verification, and invalid flag handling; raise coverage floor in `go-coverage-floor.txt` from 75.6% to >= 78.0%. Tests: `go test -count=1 -cover ./cmd/spool/`. **Red control:** alter `capsCheck` capability format or return code to trip unit test assertion. | PC | claude | tests | 2 (Lane 2, after 02) |
| 05 `refactor(r15-05-wui-ts-convert-leaf-utils-group-d)` | TypeScript migration, drop shim blocks | Retiring generated `mjs-shims.d.ts` (`SPL-2170`); next slice of 8 leaf utils with 0 `.mjs` dependencies | `wui:src/utils/tenant.mjs`<br>`wui:src/utils/tenant-settings-nav.mjs`<br>`wui:src/utils/msg-jump.mjs`<br>`wui:src/utils/touch-ui.mjs`<br>`wui:src/types/mjs-shims.d.ts` | 8 leaf utils (114 -> 106 shims) | Convert 8 leaf utils (`tenant`, `tenant-settings-nav`, `msg-jump`, `touch-ui`, `feed`, `place-popover`, `user-menu`, `takeover-ladder`) to `.ts` with typed exports; update import references; drop 8 `declare module` blocks from `mjs-shims.d.ts`. Tests: **`tests/unit/touch-ui.test.mjs`**, `pnpm run typecheck`, unit runner. **Red control:** invert boolean condition in `touch-ui.ts` trips `tests/unit/touch-ui.test.mjs`. | sat | claude | simple_coding | 3 (Lane 1, after 03) |
| 06 `test(r15-06-go-coverage-action-runner)` | unit test coverage, action testability | `internal/action` coverage is 75.6% (floor 71.1% in `go-coverage-floor.txt:17`); `edit.go:27-78` (`check`, `Edit`, `Delete`, `AttachRename`) and `issue.go:26` have 0.0% coverage | `api:src/go/spool-hub-api/internal/action/edit.go:27-78`<br>`api:src/go/spool-hub-api/internal/action/issue.go:26-80`<br>`api:src/bash/tests/go-coverage-floor.txt:17` | 75.6% statement coverage | Add table tests in `internal/action/edit_test.go` and `internal/action/issue_test.go` covering edit checks, message deletion, attachment rename, and issue payload validation; raise statement coverage floor in `go-coverage-floor.txt` from 71.1% to >= 76.0%. Tests: `go test -count=1 -cover ./internal/action/`. **Red control:** modify `edit.go check` permission logic to trip unit test assertion. | PC | claude | tests | 3 (Lane 2, after 04) |
| 07 `refactor(r15-07-wui-small-composable-error-journal)` | composable decomposition, testability | `src/composables/errorJournal.mjs` is 731 lines (largest composable in WUI); mixes error capture, log formatting, storage persistence, and telemetry dispatch | `wui:src/composables/errorJournal.mjs:1-731`<br>`wui:tests/unit/error-journal.test.mjs` | 731 lines | Extract pure log formatters and storage serialization into `src/utils/error-journal-format.ts` and `src/utils/error-journal-store.ts`; shrink `errorJournal.mjs` to <= 400 lines; add unit tests covering formatters. Tests: `tests/unit/error-journal.test.mjs`, `pnpm run typecheck`, unit runner. **Red control:** corrupt error entry serialization in `error-journal-format.ts` trips unit test. | sat | claude | complex_coding | 4 (Lane 1, after 05) |
| 08 `refactor(r15-08-utl-sync-runner-do-log)` | small functions, central runner parity | `csi-spl-utl/src/bash/run/run.sh:320-450` has unsplit `do_log` (131 lines); `iac` and `orc` runners were decomposed into 6 named steps in r14-09; all three runner copies must remain byte-identical | `utl:src/bash/run/run.sh:320-450`<br>`iac:src/bash/run/run.sh:320-462` | 131 lines (utl run.sh) | Apply the 6-step decomposition (`_do_log_split_words`, `_do_log_format_line`, `_do_log_resolve_dir`, `_do_log_resolve_file`, `_do_log_emit_compact`, `_do_log_emit_full`) to `csi-spl-utl/src/bash/run/run.sh`, making all three `run.sh` files byte-identical (`diff` empty). Tests: `cd csi-spl-utl && ./run -a do_check_dist_hygiene`, `csi-spl-iac/src/bash/tests/run-log-compact.tst.sh`, `run-log-nofork.tst.sh`. **Red control:** `diff csi-spl-iac/src/bash/run/run.sh csi-spl-utl/src/bash/run/run.sh` non-empty fails test; passes when byte-identical. | PC | claude | simple_coding | 4 (Lane 2, after 06) |
| 09 `refactor(r15-09-wui-ratchet-unused-exports)` | dead code elimination, testability ratchet | `unused-exports.test.mjs` has 54 unused exports in `ALLOW` (cap 54); remaining unused exports include `agent-id.mjs` (2), `calendar-phone-nav.mjs` (2), `card-clip.mjs` (2), `hours-calendar-mock.mjs` (2), `hours-mine.mjs` (2) | `wui:tests/unit/unused-exports.test.mjs`<br>`wui:src/utils/agent-id.mjs`<br>`wui:src/utils/calendar-phone-nav.mjs`<br>`wui:src/utils/card-clip.mjs`<br>`wui:src/utils/hours-calendar-mock.mjs`<br>`wui:src/utils/hours-mine.mjs` | 54 unused exports in ALLOW | Unexport ~14 dead declarations across these 5 utils; delete their entries from `ALLOW`; ratchet `ALLOW_CAP` down from 54 to <= 40 in `unused-exports.test.mjs`. Tests: `node tests/unit/unused-exports.test.mjs`, unit runner. **Red control:** adding an unused `export const` in a `src/utils/*.mjs` file trips `unused-exports.test.mjs` failure. | sat | claude | simple_coding | 5 (Lane 1, after 07) |
| 10 `test(r15-10-go-coverage-config-loader)` | unit test coverage, configuration testability | `internal/config` statement coverage is 78.1% (floor 76.8% in `go-coverage-floor.txt:37`); getters `IDQuarantine`, `NotifyTimeoutOr`, `ChannelList`, `HubDir`, `SubmitOff`, `SubmitPath`, `FilesDir` have 0.0% coverage (`config.go:132-262, 862`) | `api:src/go/spool-hub-api/internal/config/config.go:132-262, 862`<br>`api:src/bash/tests/go-coverage-floor.txt:37` | 78.1% statement coverage | Add table unit tests in `internal/config/config_test.go` covering uncalled getters, environment overrides, and directory resolvers; raise statement coverage floor in `go-coverage-floor.txt` from 76.8% to >= 80.0%. Tests: `go test -count=1 -cover ./internal/config/`. **Red control:** mutate `NotifyTimeoutOr` default fallback to trip unit test assertion. | PC | claude | tests | 5 (Lane 2, after 08) |

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 10 rows touch strictly disjoint files across `csi-spl-wui/`, `csi-spl-orc/`, `csi-spl-iac/`, `csi-spl-utl/`, and `csi-spl-api/`:
- **Lane 1 (odd rows, WUI stream):** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09
- **Lane 2 (even rows, Backend Go & Central Tooling stream):** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 10
- **Starting rows (Batch 1):** Row 01 (`issues.vue`) and Row 02 (`internal/blob/`) spawn in parallel as Batch 1.
- **Asynchronous lane independence:** Every batch pair is completely disjoint:
  - Row 01 (`issues.vue`, `sfc-script-size.test.mjs`) vs Row 02 (`internal/blob/`): disjoint.
  - Row 03 (leaf utils Group C) vs Row 04 (`cmd/spool/`): disjoint.
  - Row 05 (leaf utils Group D) vs Row 06 (`internal/action/`): disjoint.
  - Row 07 (`errorJournal.mjs`) vs Row 08 (`csi-spl-utl/src/bash/run/run.sh`): disjoint.
  - Row 09 (`unused-exports.test.mjs`, top ALLOW utils) vs Row 10 (`internal/config/`): disjoint.
- **Shared test suites strictly serialised per lane:**
  - `sfc-script-size.test.mjs` and `mjs-shims.d.ts`: serialized in Lane 1 (01, 03, 05, 09).
  - `go-coverage-floor.txt`: serialized in Lane 2 (02, 04, 06, 10).

### 3.2 Off every live lane (R3)

`lane-map.sh --check` verifies that none of these paths are owned by any live lane on any box. Spawners re-run `--check` per row prior to placement.

## 4. Per row: what the lane does

- **01:** decompose `src/pages/issues.vue` `<script>` tag (`1185-2060`, 876 lines) by extracting filter/sort state into `useIssueFilters.ts` and detail form inputs into `useIssueDetailForm.ts`; shrink `<script>` under 500 lines; delete `src/pages/issues.vue` from `BIG` map in `sfc-script-size.test.mjs`, eliminating the `BIG` map entirely.
- **02:** add table and mock unit tests in `internal/blob/s3_test.go` and `internal/blob/cached_test.go` covering S3 error handling, precondition checks, and cache retention; raise statement coverage floor in `go-coverage-floor.txt` from 66.9% to >= 70.0%.
- **03:** convert 8 leaf utils (`plain-text`, `bidi`, `pane-scroll`, `channel-order`, `doc-path-hook`, `commit-link-hook`, `msg-apply`, `code-langs`) from `.mjs` to `.ts`; update import call sites; drop their 8 `declare module` blocks in `mjs-shims.d.ts` (122 -> 114).
- **04:** add `cmd/spool/caps_test.go` covering capability listing, capability verification, and invalid flag handling; cover `doc.go` flag parsing branches; raise statement coverage floor in `go-coverage-floor.txt` from 75.6% to >= 78.0%.
- **05:** convert 8 leaf utils (`tenant`, `tenant-settings-nav`, `msg-jump`, `touch-ui`, `feed`, `place-popover`, `user-menu`, `takeover-ladder`) from `.mjs` to `.ts`; update import call sites; drop their 8 `declare module` blocks in `mjs-shims.d.ts` (114 -> 106). Keep **`tests/unit/touch-ui.test.mjs`** green.
- **06:** add unit tests in `internal/action/edit_test.go` and `internal/action/issue_test.go` covering message editing, deletion, attachment rename, and issue payload validation; raise statement coverage floor in `go-coverage-floor.txt` from 71.1% to >= 76.0%.
- **07:** decompose `src/composables/errorJournal.mjs` (731 lines) by extracting log formatters into `src/utils/error-journal-format.ts` and storage persistence into `src/utils/error-journal-store.ts`; shrink `errorJournal.mjs` to <= 400 lines; keep `tests/unit/error-journal.test.mjs` green.
- **08:** sync the 6-step `do_log` decomposition from `iac` and `orc` into `csi-spl-utl/src/bash/run/run.sh:320-450` (131 lines -> named steps <= 33 lines) so all three runner copies remain byte-identical (`diff` empty).
- **09:** unexport ~14 dead declarations across `agent-id.mjs`, `calendar-phone-nav.mjs`, `card-clip.mjs`, `hours-calendar-mock.mjs`, and `hours-mine.mjs`; delete their entries from `ALLOW`; ratchet `ALLOW_CAP` down from 54 to <= 40 in `unused-exports.test.mjs`.
- **10:** add table unit tests in `internal/config/config_test.go` covering uncalled getters (`IDQuarantine`, `NotifyTimeoutOr`, `ChannelList`, `HubDir`, `SubmitOff`, `SubmitPath`, `FilesDir`); raise statement coverage floor in `go-coverage-floor.txt` from 76.8% to >= 80.0%.

## 5. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-607@PC` (`seat-agy.md`)
  - Claude seat: `c-xxx@<box>` (`seat-claude.md`)
  - Mistral seat: `m-xxx@<box>` (`seat-mistral.md` - docs and review only per owner rule: no mistral coding rows)
  - Grok seat: `g-xxx@<box>` (`seat-grok.md` - conditional subject to vendor quota availability)
- **Reviewers per row (R7.2):**
  - All coding rows are assigned to Claude per owner directive (no mistral coding rows, owner 10-17).
  - Cross-vendor review enforced: editor seat `a-607@PC` (agy) and mistral seat provide 100% cross-vendor review (`grep -c 'same vendor'` -> 0).
  - Review lines verified via `do_spl_review_line_check`.

## 6. Left out, measured (carried to future rounds by pointer)

| what | why | measured by |
|---|---|---|
| `src/stores/notification.ts` | Setup body is 72 lines; no toast code; 11 source-reading tests | `sed -n '498,$p' \| wc -l` (72 lines) |
| `bash-cleancode.tst.sh` LONG functions (`gcp-001`, `gcp-002`, `gcp-import-to-cloudsql`, `gcp-project-delete`, `provision-firebase-dns`) | GCP infra scripts require live GCP credentials/state; `provision-firebase-dns` is sha256-pinned to csi-rel (`wui-hosting-019-031.tst.sh:26-30`) | `bash-cleancode.tst.sh` (6 remaining) |
| Remaining 106 `mjs-shims.d.ts` modules | Staged in subsequent refactoring rounds after Group C and Group D conversion | `grep -c 'declare module' mjs-shims.d.ts` |
| `usePaneWidths.ts` composable | Ratio math already in `utils/pane-widths.mjs` (307 lines); composable functions <= 80 lines | `wc -l` (314 lines) |

## 7. Counts

| | n |
|---|---|
| rows | 10 (refactor 6, test 4; WUI 5, Go 4, Central Tooling 1) |
| vendor | claude 10 (all coding rows per owner 10-17); agy / mistral cross-vendor reviewers |
| box (preferred) | sat / PC |
| batches | 5 batches (2 parallel lanes at all times) |

## 8. Changes

- v0.1: Initial proposed plan for Round 15:
  - WUI focus: final SFC decomposition of `issues.vue` to eliminate the `BIG` map in `sfc-script-size.test.mjs`, TypeScript migration of 16 leaf utils across Groups C and D dropping 16 shim blocks (`SPL-2170`), `errorJournal.mjs` composable decomposition, and unused-exports ratchet down to <= 40.
  - Backend/Tooling focus: Go statement coverage floors raised for `internal/blob`, `cmd/spool`, `internal/action`, and `internal/config`; central runner logging byte-parity for `csi-spl-utl/src/bash/run/run.sh`.
  - Balanced across 2 parallel lanes (5 batches, strictly disjoint file sets).

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-607@PC | v0.1 proposed | `refactor-round-15/seat-agy.md` |
| Claude seat | claude | c-xxx@<box> | pending v0.1 review | `refactor-round-15/seat-claude.md` |
| Mistral seat | mistral | m-xxx@<box> | pending v0.1 review | `refactor-round-15/seat-mistral.md` |
| Grok seat | grok | g-xxx@<box> | conditional / quota checked | `refactor-round-15/seat-grok.md` |
