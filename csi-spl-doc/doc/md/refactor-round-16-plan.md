# Refactoring round 16 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-3618  

Owner HUM-10 directives & fleet rules:
- t1 topic `dc15ad65-a5c8-495c-b244-030b6f4d768d` msg 686bc1a3: **"keep 2 row lanes in parallel"**.
- msg b8e22a15: **"do not ask me for input - just reach consensus between all of the members of the panel and start implementation"**.
- msg 7f664194 / 8cb6cc7d: 20-30% allocation of resources for refactoring ([fleet-rules-index.md](fleet-rules-index.md)).
- msg 3d22fcea: rounds run continuously, embedded in core operation, no owner go needed.
- owner 10-17 (t1 b61851fb): **no mistral coding rows** (docs and review only).
- WUI coding rows assigned to **claude**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps 1..1 up to 3 max 5, bands, R1-R16), by pointer.

Round 16 focus: **WUI TypeScript migration (retiring mjs-shims.d.ts via true leaves and closed pairs), SFC script decomposition under MAX_SCRIPT 500 (LiveFeed, ChannelSidebar, issues, WorkspaceDocView), Backend Go statement coverage floors (cicdlogs scrub, payments refund, cmd/spool recovery), and unused exports ratchet**.  
Concurrency: **build 2 row lanes in parallel at all times**.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  

**Status: v1.0, Consensus Complete (signed by Claude reviewer c-163 and Editor a-866@PC)**.

Editor: **a-866@PC** (agy)\*.  
Panel reviewer: **c-163** (claude).  
Dispatch lease holder: the current dispatch lease holder (tracked via `lease.dispatch`).  

*\*Editor seat representation:* Seated as agent `a-866` on workstation. Formatted as `@PC` per repo distribution hygiene rules (`do_check_dist_hygiene`), which prohibit literal box hostnames in repository files (precedent: `a-607@PC` in `refactor-round-15-plan.md`).

**One sha:** every count is measured on **`f11ed1f7c`** (`origin/master` f11ed1f7ce8a2c9144491ffb23760285ef0f67c3, 2026-10-26), n=1 per command unless stated. Inputs: [refactor-round-15-retro.md](refactor-round-15-retro.md) section 7.

## 1. How to read this and historical context

- **Historical landing sequence (Rows 01–08):** Rows 01–08 were dispatched directly by `c-296` between 2026-10-21 19:34Z and 2026-10-22 01:55Z from brief files without a formal `refactor-round-16-plan.md` committed to master. Specifically, Batch 1 (rows 01–03) was cut and queued prior to the signing of `refactor-round-15-retro.md` (`c-002` ask `7e05fdc0`). The actual landing order on master was: `r16-02` (`058b03225`), `r16-03` (`22d363c9e`), `r16-01` (`6228bf921`), `r16-04` (`f2715da08`), `r16-06` (`0fc8e3629`), `r16-05` (`bc8b0091d`), `r16-07` (`c4884480d`), and `r16-08` (`26e0d8a86`). Furthermore, `r17-01` (`d10fe5d9a`) landed between `r16-07` and `r16-08`, and subsequent rounds (r17 with 10 rows, r18, r21) are already on trunk.
- **Open rows (Rows 09 and 10):** Added post-hoc to formally complete Round 16 to the rulebook standard 10 rows, accounting for all retro 15 candidate inputs. Neither open row touches paths modified in r17–r21.
- **Structure:** One row = one practice = one lane, at the sites named and nowhere else, with a test that shows behaviour kept, or for a gate / test addition a **red control**: the check fails on the bad input before the change and passes after.
- **Paths:** `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `utl:` = `csi-spl-utl/`, `api:` = `csi-spl-api/`. Lines as of `f11ed1f7c`.
- **Box:** the preferred box (`sat` or `PC`); the spawner's box pick may move a row (no pin).
- **Vendor:** owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`), restricted by owner 10-17 (no mistral coding rows; coding assigned to claude).
- **Subject** (R6 reads it): `<type>(r16-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`. The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands in the reviewer's `log:` file.

## 2. Where the rows come from (measured on `f11ed1f7c`)

Re-measurement of the 7 candidate inputs from [refactor-round-15-retro.md](refactor-round-15-retro.md) section 7:

| source | candidate input | command on `f11ed1f7c` | n | row / disposition |
|---|---|---|---|---|
| retro 7.1 | `internal/payments` refund paths | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/` | 80.9% statement coverage (floor 80.9% in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:74`) | Covered on master in `f2715da08` (`test(r16-04-go-coverage-payments-refund, SPL-2781)`). **Shortfall:** retro 7.1 target was >= 82.0%; `r16-04` reached 80.9% (+2.3% over 78.6% baseline). **Row 04 (landed)**. |
| retro 7.2 | TypeScript migration: remaining `mjs-shims.d.ts` modules | `grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts` | 98 shim blocks remaining (down from 103); `generate-mjs-shims.mjs --leaves` yields 0 leaves; `find csi-spl-wui/src -name "*.mjs" \| wc -l` -> 273 `.mjs` files in `src/`. | Group E leaf utils converted in `6228bf921` (`r16-01`, 103 -> 100); closed pairs converted in `bc8b0091d` (`r16-05`, 100 -> 98). **Rows 01 and 05 (landed)**. |
| retro 7.3 | WUI store: `src/stores/channel.ts` | `wc -l csi-spl-wui/src/stores/channel.ts \| awk '{print $1}'` | 754 lines | **Dropped.** Store setup is already decomposed into step functions; 4 tests (`channel-create-dialog`, `newest-live`, `send-fallback-note`, `load-more-30`) assert against its source text. ChannelSidebar rail logic extracted instead (**Row 06**). |
| retro 7.4 | WUI store: `src/stores/notification.ts` | `wc -l csi-spl-wui/src/stores/notification.ts \| awk '{print $1}'` | 569 lines | **Dropped.** Setup body is only 72 lines; no toast code; 11 source-reading tests. Issues unopened display extracted instead (**Row 07**). |
| retro 7.5 | WUI composable: `src/composables/usePaneWidths.ts` | `wc -l csi-spl-wui/src/composables/usePaneWidths.ts \| awk '{print $1}'` | 314 lines | **Dropped.** Ratio math already in `utils/pane-widths.mjs` (307 lines); composable functions <= 80 lines. WorkspaceDocView landing extracted instead (**Row 08**). |
| retro 7.6 | Bash cleancode: remaining LONG in `bash-cleancode.tst.sh` | `grep -A 8 "LONG=" csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | 4 remaining functions (down from 6): `gcp-002-create`, `gcp-002-delete`, `gcp-project-delete`, `provision-firebase-dns` (169 lines, sha256-pinned to csi-rel) | **Dropped.** All 4 remaining functions are GCP infra scripts requiring live GCP credentials/state. |
| retro 7.7 | Clean code gates (Go and WUI) | `cleancode_test.go` and `cd csi-spl-wui && node tests/unit/cleancode.test.mjs` | Go `longFuncs` map empty; WUI 11675 functions scanned, 0 listed long | **Dropped.** Both gates clean and completely empty. |
| retro 7 note | `internal/cicdlogs` log scrubber & fetch paths | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/cicdlogs/` | 89.0% statement coverage (floor 89.0% in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:42`) | Covered on master in `058b03225` (`test(r16-02-go-coverage-cicdlogs-scrub, SPL-2776)`). **Row 02 (landed)**. |
| retro 7 note | `LiveFeed.vue` script at MAX_SCRIPT cap | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/LiveFeed.vue \| wc -l` | 284 script lines (shrunk from 500) | Decomposed on master in `22d363c9e` (`refactor(r16-03-wui-decompose-live-feed, SPL-2778)`). **Row 03 (landed)**. |
| r15-09 follow-up | `unused-exports.test.mjs` ALLOW ratchet | `cd csi-spl-wui && node tests/unit/unused-exports.test.mjs` | 34 unused exports in ALLOW (cap 35, ALLOW block has 35 entries across 35 files); `settingsSectionOf` (`src/utils/settings-nav.mjs`) is no longer unused; deleting it leaves 34 unused exports | **Row 09 (open)**. Target: ALLOW entries 35 -> 34, `ALLOW_CAP 35 -> 34`. |
| r15-04 follow-up | `cmd/spool` coverage slide under floor | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./cmd/spool/` | 75.6% statement coverage (floor 76.4% in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:16`). Green under <= 1.0 pt tolerance with 0.2 pt margin before failure (`76.4 - 1.0 = 75.4%`). Package has 2496/3302 covered statements. Untested additions: `gcp_alerts.go` (0% of 26 statements) and `hub_gcal.go` (11.5% of 29 statements, 26 uncovered); 52 uncovered statements across both files gives ceiling 77.17% (2548/3302 statements). Target: add new test files `gcp_alerts_test.go` and `hub_gcal_test.go`, recover package coverage to measured value (n=3, >= 77.0%), and raise floor to measured value (fallback site if short: `lock.go` with 51 uncovered statements). | **Row 10 (open)**. |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2 bold: source-text tests) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r16-01-wui-ts-convert-leaf-utils-group-e)` | TypeScript migration, drop shim blocks (SPL-2170) | Retiring generated `mjs-shims.d.ts`; `pane-focus.mjs` and `rail-order.mjs` are true leaves (0 imports, 0 src .mjs importers); converted to `.ts` directly; drops 3 shim blocks (103 -> 100) | `wui:src/utils/pane-focus.ts`<br>`wui:src/utils/rail-order.ts`<br>`wui:src/types/mjs-shims.d.ts` | 2 leaf utils (103 -> 100 shims) | `pnpm run shims:check`, `pnpm run typecheck`, **`tests/unit/sidebar-tabs.test.mjs:132`**, **`tests/unit/rail-order.test.mjs:29`**, unit runner. **Red control:** planted stale block in `mjs-shims.d.ts` makes `shims:check` rc 1. *(Landed `6228bf921`, SPL-2773)* | sat | claude | complex_coding | 1 (Lane 1) |
| 02 `test(r16-02-go-coverage-cicdlogs-scrub)` | unit test coverage, credential scrub testability | `internal/cicdlogs` coverage was 81.5% (floor 81.6%); token scrubber and `FetchLogs` error handling had 0.0% coverage; raised coverage floor to 89.0% | `api:src/go/spool-hub-api/internal/cicdlogs/github.go:45-80`<br>`api:src/go/spool-hub-api/internal/cicdlogs/github_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt:42` | 81.5% statement coverage | Table tests covering `scrub` token redaction, `FetchLogs` HTTP errors, and run ID validation. Tests: `go test -count=1 -cover ./internal/cicdlogs/`. **Red control:** modify token regex to trip scrub assertion. *(Landed `058b03225`, SPL-2776)* | PC | claude | tests | 1 (Lane 2) |
| 03 `refactor(r16-03-wui-decompose-live-feed)` | component decomposition, sfc-script-size cap | `LiveFeed.vue` `<script>` tag was 500 lines, exactly at the MAX_SCRIPT ceiling (500 lines in `sfc-script-size.test.mjs`); message-link jump and phone thread navigation mixed in page script | `wui:src/components/LiveFeed.vue`<br>`wui:src/composables/useFeedJump.ts`<br>`wui:src/composables/useFeedThreadNav.ts` | 500 script lines (ceiling 500) | Decompose message jump into `useFeedJump.ts` and thread navigation into `useFeedThreadNav.ts`; shrink script from 500 to 284 lines (-216 lines). Tests: `tests/unit/sfc-script-size.test.mjs`, `pnpm run typecheck`, unit runner. **Red control:** adding 1 line to `LiveFeed.vue` at 500 lines fails `sfc-script-size.test.mjs`. *(Landed `22d363c9e`, SPL-2778)* | sat | claude | complex_coding | 2 (Lane 1) |
| 04 `test(r16-04-go-coverage-payments-refund)` | unit test coverage, refund path verification | `internal/payments` statement coverage was 78.6% (floor 78.6%); `Refund` (`stripe_payments.go:158`), `RefundWithKey` (`:166`), and `StubPayments.Refund` (`provider.go:55`) had 0.0% coverage | `api:src/go/spool-hub-api/internal/payments/stripe_payments.go:153-185`<br>`api:src/go/spool-hub-api/internal/payments/provider.go:55`<br>`api:src/bash/tests/go-coverage-floor.txt:74` | 78.6% statement coverage | Add table tests in `internal/payments/stripe_refund_test.go` covering `Idempotency-Key` headers and Stripe error decodes; raised floor to 80.9% (+2.3%). Tests: `go test -count=1 -cover ./internal/payments/`. **Red control:** drop `Idempotency-Key` header in `RefundWithKey` to trip unit test assertion. *(Landed `f2715da08`, SPL-2781)* | PC | claude | tests | 2 (Lane 2) |
| 05 `refactor(r16-05-wui-ts-convert-closed-pairs)` | TypeScript migration, closed-pair module conversion | Zero leaf modules left in `generate-mjs-shims.mjs --leaves`; 2 closed pairs (`save-blob` + `ws-doc-download`, `touch-ui` + `tree-drag`) converted to `.ts` directly; drops 2 shim blocks (100 -> 98) | `wui:src/utils/save-blob.ts`<br>`wui:src/utils/ws-doc-download.ts`<br>`wui:src/utils/touch-ui.ts`<br>`wui:src/utils/tree-drag.ts`<br>`wui:src/types/mjs-shims.d.ts` | 2 closed pairs (100 -> 98 shims) | Convert 4 utils to `.ts` with exact exported types; update import call sites; drop 2 `declare module` blocks from `mjs-shims.d.ts`. Tests: `pnpm run typecheck`, `pnpm run shims:check`, unit runner. **Red control:** planted stale block in `mjs-shims.d.ts` trips `shims:check`. *(Landed `bc8b0091d`, SPL-2798)* | sat | claude | complex_coding | 3 (Lane 1) |
| 06 `refactor(r16-06-wui-decompose-channel-sidebar-rail-tabs)` | component decomposition, sfc-script-size reduction | `ChannelSidebar.vue` `<script>` tag was 670 lines; rail-tab key mapping and rail-only pages logic mixed in sidebar script | `wui:src/components/ChannelSidebar.vue`<br>`wui:src/composables/useSidebarRailKeys.ts`<br>`wui:src/composables/useSidebarRailPages.ts` | 670 script lines | Extract rail-tab keys into `useSidebarRailKeys.ts` and rail-only pages into `useSidebarRailPages.ts`; shrink sidebar script to 363 lines (-307 lines). Tests: **`tests/unit/sidebar-tabs.test.mjs:132`**, **`tests/unit/rail-order.test.mjs:29`**, `pnpm run typecheck`, unit runner. **Red control:** invert rail tab visibility check trips `sidebar-tabs.test.mjs`. *(Landed `0fc8e3629`, SPL-2799)* | PC | claude | complex_coding | 3 (Lane 2) |
| 07 `refactor(r16-07-wui-decompose-issues-unopened)` | component decomposition, sfc-script-size reduction | `issues.vue` had second largest `<script>` tag (492 lines, 8 under MAX_SCRIPT 500); unopened marks (SPL-1559) and display helpers mixed in page script | `wui:src/pages/issues.vue`<br>`wui:src/composables/useIssueUnopened.ts`<br>`wui:src/composables/useIssueDisplay.ts` | 492 script lines (ceiling 500) | Extract unopened state into `useIssueUnopened.ts` and row display helpers into `useIssueDisplay.ts`; shrink script from 492 to 420 lines (-72 lines). Tests: `tests/unit/issues-unopened.test.mjs`, `tests/unit/sfc-script-size.test.mjs`, `pnpm run typecheck`, unit runner. **Red control:** omit `markOpened` in `useIssueUnopened` trips `issues-unopened.test.mjs`. *(Landed `c4884480d`, SPL-2808)* | sat | claude | complex_coding | 4 (Lane 1) |
| 08 `refactor(r16-08-wui-decompose-doc-view-landing)` | component decomposition, sfc-script-size reduction | `WorkspaceDocView.vue` `<script>` tag was 490 lines (10 under MAX_SCRIPT 500); deep-link landing and '#' permalink logic mixed in view script | `wui:src/components/workspace-docs/WorkspaceDocView.vue`<br>`wui:src/composables/useDocLanding.ts`<br>`wui:src/composables/useDocPermalink.ts` | 490 script lines (ceiling 500) | Extract deep-link landing into `useDocLanding.ts` and permalink handling into `useDocPermalink.ts`; shrink script from 490 to 395 lines (-95 lines, measured 334 on `f11ed1f7c`). Tests: `tests/unit/doc-outline.test.mjs`, `pnpm run typecheck`, unit runner. **Red control:** dropping `ResizeObserver` in `useDocLanding` fails `workspace-doctree` e2e test. *(Landed `26e0d8a86`, SPL-2806)* | PC | claude | complex_coding | 4 (Lane 2) |
| 09 `refactor(r16-09-wui-ratchet-unused-exports)` | dead code elimination, testability ratchet | `unused-exports.test.mjs` reports `NOTE ALLOW: 'src/utils/settings-nav.mjs' 'settingsSectionOf' is no longer an unused export - delete it from ALLOW and lower ALLOW_CAP`; ALLOW currently lists 35 entries across 35 files (cap 35, exactly 1 entry per file); 34 are unused; deleting stale `settingsSectionOf` reduces ALLOW to 34; ratchet `ALLOW_CAP` down from 35 to 34 | `wui:tests/unit/unused-exports.test.mjs`<br>`wui:src/utils/settings-nav.mjs` | 34 unused exports in ALLOW (cap 35 -> 34) | Delete stale `settingsSectionOf` from `ALLOW`; lower `ALLOW_CAP` from 35 to 34 in `unused-exports.test.mjs`. Tests: `node tests/unit/unused-exports.test.mjs`, `pnpm run typecheck`, unit runner. **Red control:** setting `ALLOW_CAP = 34` with `settingsSectionOf` still present in ALLOW fails `unused-exports.test.mjs` with `ALLOW lists 35 exports, over ALLOW_CAP 34`. | sat | claude | simple_coding | 5 (Lane 1) |
| 10 `test(r16-10-go-coverage-cmd-spool)` | CLI unit test coverage, coverage floor recovery | `cmd/spool` statement coverage is 75.6% (2496/3302 stmts) on `f11ed1f7c` against floor 76.4% in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:16` (0.8% under floor; green under 1.0 pt tolerance with 0.2 pt margin before failure); `caps.go` and `doc.go` flag parsing are already 100.0% covered; slide is caused by untested code added since `3458ffaf3`: `gcp_alerts.go` (0.0% of 26 stmts) and `hub_gcal.go` (11.5% of 29 stmts, 26 uncovered); 52 uncovered statements across both gives ceiling 77.17% (needs 47 for >= 77.0%); add new test files `gcp_alerts_test.go` and `hub_gcal_test.go` covering them; set floor to measured value (n=3); fallback site if short is `lock.go` (51 uncovered) | `api:src/go/spool-hub-api/cmd/spool/gcp_alerts.go`<br>`api:src/go/spool-hub-api/cmd/spool/gcp_alerts_test.go` (new)<br>`api:src/go/spool-hub-api/cmd/spool/hub_gcal.go`<br>`api:src/go/spool-hub-api/cmd/spool/hub_gcal_test.go` (new)<br>`api:src/bash/tests/go-coverage-floor.txt:16`<br>*(fallback site: `api:src/go/spool-hub-api/cmd/spool/lock.go`)* | 75.6% statement coverage (floor 76.4%, 0.2 pt margin; ceiling 77.17%) | Add unit table tests in new files `cmd/spool/gcp_alerts_test.go` and `cmd/spool/hub_gcal_test.go` covering `cmdMCPGCPAlerts` flag parsing / error paths and `gcalConnect` / `errText` error formatting; recover package coverage (ceiling 77.17%; fallback: `lock.go`); raise floor in `go-coverage-floor.txt:16` from 76.4% to measured n=3 value (>= 77.0%). Tests: `go test -count=1 -cover ./cmd/spool/`. **Red control:** mutate error return in `gcp_alerts.go` or `hub_gcal.go` to trip test assertions. | PC | claude | tests | 5 (Lane 2) |

### 3.1 Concurrency & Lane Schedule (as landed for 01–08; planned for 09–10)

Disjoint between parallel rows, shared files serialised per lane. No row touches `csi-spl-orc/`, `csi-spl-iac/`, or `csi-spl-utl/`.
- **Lane 1:** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09 (WUI stream)
- **Lane 2:** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 10 (Backend Go & Central stream; Row 06 is WUI SFC decomposition but ran in Lane 2)
- **Historical landing sequence on master:**
  - Batch 1: Row 02 (`058b03225`) and Row 03 (`22d363c9e`)
  - Batch 2: Row 01 (`6228bf921`) and Row 04 (`f2715da08`)
  - Batch 3: Row 06 (`0fc8e3629`) and Row 05 (`bc8b0091d`)
  - Batch 4: Row 07 (`c4884480d`), then `r17-01` (`d10fe5d9a`), then Row 08 (`26e0d8a86`)
  - Batch 5 (open for dispatch): Row 09 (`unused-exports.test.mjs`, `settings-nav.mjs`) and Row 10 (`cmd/spool/`, `go-coverage-floor.txt:16`)
- **Shared files serialised per lane:**
  - `mjs-shims.d.ts`: serialized in Lane 1 (Rows 01, 05).
  - `go-coverage-floor.txt`: serialized in Lane 2 (Rows 02, 04, 10).

### 3.2 Off every live lane (R3)

```bash
bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check "csi-spl-wui/tests/unit/unused-exports.test.mjs,csi-spl-wui/src/utils/settings-nav.mjs,csi-spl-api/src/go/spool-hub-api/cmd/spool/gcp_alerts.go,csi-spl-api/src/go/spool-hub-api/cmd/spool/hub_gcal.go,csi-spl-api/src/bash/tests/go-coverage-floor.txt" --agent a-866
```
Exit code: `4`. Output:
`no live lane lists csi-spl-wui/tests/unit/unused-exports.test.mjs,csi-spl-wui/src/utils/settings-nav.mjs,csi-spl-api/src/go/spool-hub-api/cmd/spool/gcp_alerts.go,csi-spl-api/src/go/spool-hub-api/cmd/spool/hub_gcal.go,csi-spl-api/src/bash/tests/go-coverage-floor.txt, but 10 live lane(s) record no files: their scope is unknown, not free`

No live lane owns any of these paths. Per Rulebook R3, because 10 live lanes (e.g. `c-423@<box>`, `c-613@sat`) record no files in their registry row, the spawner must perform the "ask the unknown lanes" step or verify their brief scopes prior to placement.

## 4. Per row: what the lane does

- **01:** Convert `utils/pane-focus.mjs` and `utils/rail-order.mjs` to `.ts` directly; export `RailId` and `F6Pane` types; drop 3 `declare module` blocks from `mjs-shims.d.ts` (103 -> 100). *(Landed `6228bf921`)*
- **02:** Add unit table tests in `internal/cicdlogs/github_test.go` covering `scrub` credential token redaction and `FetchLogs` HTTP error handling; raise coverage floor in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:42` to 89.0%. *(Landed `058b03225`)*
- **03:** Decompose `LiveFeed.vue` `<script>` tag (500 lines) by extracting message jump into `useFeedJump.ts` and thread navigation into `useFeedThreadNav.ts`; shrink `<script>` under 300 lines (measured 284 on `f11ed1f7c`). *(Landed `22d363c9e`)*
- **04:** Add table tests in `internal/payments/stripe_refund_test.go` covering `RefundWithKey` `Idempotency-Key` headers and Stripe error bodies; raise coverage floor in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:74` from 78.6% to 80.9% (shortfall against retro target >= 82.0%). *(Landed `f2715da08`)*
- **05:** Convert 2 closed pairs (`save-blob.mjs` + `ws-doc-download.mjs`, `touch-ui.mjs` + `tree-drag.mjs`) to `.ts` directly; drop 2 `declare module` blocks from `mjs-shims.d.ts` (100 -> 98). *(Landed `bc8b0091d`)*
- **06:** Decompose `ChannelSidebar.vue` `<script>` tag (670 lines) by extracting rail-tab keys into `useSidebarRailKeys.ts` and rail-only pages into `useSidebarRailPages.ts`; shrink sidebar script to 363 lines. *(Landed `0fc8e3629`)*
- **07:** Decompose `pages/issues.vue` `<script>` tag (492 lines) by extracting unopened marks into `useIssueUnopened.ts` and row display helpers into `useIssueDisplay.ts`; shrink script from 492 to 420 lines. *(Landed `c4884480d`)*
- **08:** Decompose `WorkspaceDocView.vue` `<script>` tag (490 lines) by extracting deep-link landing into `useDocLanding.ts` and '#' permalink into `useDocPermalink.ts`; shrink script from 490 to 395 lines (measured 334 on `f11ed1f7c`). *(Landed `26e0d8a86`)*
- **09:** Delete stale `settingsSectionOf` from `ALLOW` in `unused-exports.test.mjs`; ratchet `ALLOW_CAP` down from 35 to 34. *(Open for dispatch)*
- **10:** Add (new files) unit tests in `cmd/spool/gcp_alerts_test.go` and `cmd/spool/hub_gcal_test.go` covering untested CLI additions (`gcp_alerts.go` 0.0% of 26 stmts, `hub_gcal.go` 11.5% of 29 stmts; ceiling 77.17%; fallback: `lock.go`); recover package coverage slide from 75.6% to measured value (n=3, >= 77.0%); raise floor in `csi-spl-api/src/bash/tests/go-coverage-floor.txt:16` to measured value. *(Open for dispatch)*

## 5. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-866@PC` (`seat-agy.md`)
  - Claude reviewer seat: `c-163` (`seat-claude.md`)
  - Mistral reviewer seat: docs and review only per owner rule: no mistral coding rows
  - Dispatch lease holder: the current dispatch lease holder (tracked via `lease.dispatch`)
- **Reviewers per row (R7.2):**
  - All coding rows assigned to Claude per owner directive (no mistral coding rows, owner 10-17).
  - Cross-vendor review enforced: editor seat `a-866@PC` (agy) and panel reviewer provide 100% cross-vendor review (`grep -c 'same vendor'` -> 0).
  - Review lines verified via `do_spl_review_line_check`.

## 6. Left out, measured (carried to future rounds by pointer)

| what | why | measured by |
|---|---|---|
| `src/stores/channel.ts` | 754 lines; setup body broken into step functions; 4 source-reading tests | `wc -l` (754 lines) |
| `src/stores/notification.ts` | Setup body is 72 lines; no toast code; 11 source-reading tests | `sed -n '498,$p' \| wc -l` (72 lines) |
| `usePaneWidths.ts` composable | Ratio math already in `utils/pane-widths.mjs` (307 lines); composable functions <= 80 lines | `wc -l` (314 lines) |
| `bash-cleancode.tst.sh` LONG functions (`gcp-002-create`, `gcp-002-delete`, `gcp-project-delete`, `provision-firebase-dns`) | GCP infra scripts require live GCP credentials/state; `provision-firebase-dns` is sha256-pinned to csi-rel | `bash-cleancode.tst.sh` (4 remaining) |
| Clean code gates (Go and WUI) | Go `longFuncs` map empty; WUI `cleancode.test.mjs` 11675 functions scanned with 0 listed long | `cleancode_test.go` / `cleancode.test.mjs` |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 7, test 3; WUI 6, Go 4) |
| landed rows | 8 (Rows 01-08 landed on trunk on `f11ed1f7c`) |
| open rows | 2 (Rows 09-10 open for immediate dispatch) |
| vendor | claude 10 (all coding rows per owner 10-17); agy / mistral cross-vendor reviewers |
| box (preferred) | sat / PC |
| batches | 5 batches (2 parallel lanes at all times) |

## 8. Changes

- v0.1: Initial proposed plan for Round 16:
  - Formally documents the 10-action structure of Round 16.
  - Re-measures all 7 inputs from `refactor-round-15-retro.md` section 7 on baseline `f11ed1f7c`.
  - Records the 8 landed rows (Rows 01-08) (`6228bf921`, `058b03225`, `22d363c9e`, `f2715da08`, `bc8b0091d`, `0fc8e3629`, `c4884480d`, `26e0d8a86`).
  - Proposes 2 open rows (Rows 09 and 10) across 2 parallel lanes: `r16-09-wui-ratchet-unused-exports` and `r16-10-go-coverage-cmd-spool`.
- v0.2: Addressed Claude reviewer `c-163` findings (W1–W8):
  - **W1 (Row 10 sites):** Replaced already-100% covered `caps.go`/`doc.go` sites with untested files `cmd/spool/gcp_alerts.go` (0% of 26 statements) and `cmd/spool/hub_gcal.go` (11.5% of 29 statements); updated red control to branch mutation in new tests.
  - **W2 (Row 10 green status):** Clarified 75.6% vs floor 76.4% is green under the <= 1.0 pt tolerance rule (`go-coverage-floor.txt:2-3`) with 0.2 pt margin before failure; targets recovery to >= 77.0% and floor raise to 77.0.
  - **W3 (Floor line numbers):** Corrected line numbers and paths in `csi-spl-api/src/bash/tests/go-coverage-floor.txt`: `cmd/spool` line 16, `internal/cicdlogs` line 42, `internal/payments` line 74.
  - **W4 (Row 09 ratchet):** Adjusted `ALLOW_CAP` target from <= 30 to 33, matching single-file ALLOW structure for `settingsSectionOf`; updated red control.
  - **W5 (Landing history):** Fully documented the historical reality of rows 01–08: landed 2026-10-21/22 without a plan on master; Batch 1 cut prior to retro 15; interleaved landing order; subsequent rounds r17–r21 already on trunk; recorded r16-04 80.9% shortfall against retro target >= 82.0%.
  - **W6 (Lane concurrency):** Reworded schedule as "disjoint between parallel rows, shared files serialised per lane"; noted row 06 executed in Lane 2.
  - **W7 (R3 lane check):** Quoted actual `lane-map.sh --check` exit code 4 and message, documenting spawner "ask unknown lanes" requirement.
  - **W8 (Seats accuracy):** Named reviewer `c-163` (claude); clarified editor `@PC` representation requirement under `do_check_dist_hygiene`; generalized dispatch lease holder.
- v0.3: Addressed Claude reviewer `c-163` findings (W9–W12):
  - **W9 (ALLOW block entries & target):** Corrected ALLOW count to 35 entries across 35 files (34 unused); target corrected to `ALLOW_CAP 35 -> 34`; updated red control to fail on `ALLOW lists 35 exports, over ALLOW_CAP 34`.
  - **W10 (Row 10 test files & ceiling):** Changed action to "Add (new files)" for `gcp_alerts_test.go` and `hub_gcal_test.go`; documented package ratio 2496/3302 statements and 77.17% ceiling from 52 uncovered statements; set floor target to measured value (n=3, >= 77.0%) with `lock.go` (51 uncovered) allowed as fallback site.
  - **W11 (Landing timeframe):** Stated exact landing dates in UTC: `2026-10-21 19:34Z to 2026-10-22 01:55Z`.
  - **W12 (Quoted lane-map output):** Formatted quoted live lane as `c-423@<box>` to preserve faithfulness to command output without tripping the literal box distribution hygiene filter.
- v1.0: Consensus signed by Claude reviewer c-163 (msg f6e8189b on commit `c7ddf63fd`) and Editor a-866@PC.

## 9. Consensus

Full cross-vendor panel consensus reached on Plan v1.0:

| Seat | Kind | ID | Signed | Review Line |
|---|---|---|---|---|
| Editor | agy | a-866@PC | signed: a-866@PC on v1.0 | - |
| Claude seat | claude | c-163 | signed: c-163 on c7ddf63fdedac61b142c52dae31bd4e70b0750f3 | `review: c-163 claude PASS c7ddf63fdedac61b142c52dae31bd4e70b0750f3 ran: git diff 46a672349 c7ddf63fd; grep -nE "ALLOW_CAP\|Extend\|CET\|35 -> 33\|cap 33" on the plan file; grep of the hygiene patterns on the plan file \| read: W9 cap 35 -> 34, red control "ALLOW lists 35 exports, over ALLOW_CAP 34" (L58, L73, L111); W10 "Add (new files)", 2496/3302, ceiling 77.17%, floor = measured n=3, lock.go fallback (L59, L74, L112); W11 19:34Z..01:55Z (L34); W12 c-423@<box> (L99); 0 stale 33/Extend/CET left (L158 is only the v0.2 changelog entry); hygiene grep 0 hits. Base measurements from my earlier passes still hold on origin/master 3730c043d: 8 r16 shas on master, unused-exports 34 unused / 35 ALLOW, cmd/spool 75.6%, lane-map exit 4. Claude panel seat c-163 signs v1.0 on this sha.` |
