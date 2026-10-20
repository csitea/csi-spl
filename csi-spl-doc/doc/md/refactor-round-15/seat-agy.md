# Round 15 - agy editor seat proposal & consensus (a-607@PC)

Measured on `673004efa` (`origin/master`, 2026-10-20).

Balanced refactoring across WUI (final SFC decomposition of `issues.vue` to eliminate the `BIG` map, leaf utils TypeScript migration to drop shim blocks per `SPL-2170`, `errorJournal.mjs` composable decomposition, unused exports ratchet), Backend Go coverage floors (`internal/blob`, `cmd/spool`, `internal/action`, `internal/config`), and Central runner logging parity (`csi-spl-utl/src/bash/run/run.sh`).
The editor (this seat) manages `../refactor-round-15-plan.md` and coordinates consensus across expert panel seats.

## 1. The 10 actions (v0.1 proposal)

| # | slug | sites | n (measured on `673004efa`) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `refactor(r15-01-wui-decompose-issues-page)` | `wui:src/pages/issues.vue:1185-2060` | 876 script lines | < 500 lines | complex_coding | 1 | Lane 1 |
| 02 | `test(r15-02-go-coverage-blob-store)` | `api:src/go/spool-hub-api/internal/blob/` | 67.6% statement coverage | floor >= 70.0 | tests | 1 | Lane 2 |
| 03 | `refactor(r15-03-wui-ts-convert-leaf-utils-group-c)` | `wui:src/utils/`, `wui:src/types/mjs-shims.d.ts` | 8 leaf utils (122 shims) | 122 -> 114 shims | simple_coding | 2 | Lane 1 |
| 04 | `test(r15-04-go-coverage-cmd-spool)` | `api:src/go/spool-hub-api/cmd/spool/` | 75.1% statement coverage | floor >= 78.0 | tests | 2 | Lane 2 |
| 05 | `refactor(r15-05-wui-ts-convert-leaf-utils-group-d)` | `wui:src/utils/`, `wui:src/types/mjs-shims.d.ts` | 8 leaf utils (114 shims) | 114 -> 106 shims | simple_coding | 3 | Lane 1 |
| 06 | `test(r15-06-go-coverage-action-runner)` | `api:src/go/spool-hub-api/internal/action/` | 75.6% statement coverage | floor >= 76.0 | tests | 3 | Lane 2 |
| 07 | `refactor(r15-07-wui-small-composable-error-journal)` | `wui:src/composables/errorJournal.mjs:1-731` | 731 lines | <= 400 lines | complex_coding | 4 | Lane 1 |
| 08 | `refactor(r15-08-utl-sync-runner-do-log)` | `utl:src/bash/run/run.sh:320-450` | 131 lines | steps <= 33 lines | simple_coding | 4 | Lane 2 |
| 09 | `refactor(r15-09-wui-ratchet-unused-exports)` | `wui:tests/unit/unused-exports.test.mjs` | 54 unused exports in ALLOW | cap <= 40 | simple_coding | 5 | Lane 1 |
| 10 | `test(r15-10-go-coverage-config-loader)` | `api:src/go/spool-hub-api/internal/config/` | 78.1% statement coverage | floor >= 80.0 | tests | 5 | Lane 2 |

## 2. 2 Parallel Lanes

- Lane 1 (WUI stream): Rows 01 -> 03 -> 05 -> 07 -> 09
- Lane 2 (Backend Go & Central Tooling stream): Rows 02 -> 04 -> 06 -> 08 -> 10
- Starts with: Row 01 (`issues.vue`) and Row 02 (`internal/blob/`) in parallel (Batch 1).
- Strictly disjoint file paths between parallel lanes across all 5 batches.

## 3. Status and Signatures

- v0.1 proposed by editor `a-607@PC` (agy).
- Pending cross-vendor expert review: Claude seat `c-xxx`, Mistral seat `m-xxx` (docs/review only), Grok seat `g-xxx` (quota checked/conditional).

signed: a-607@PC on v0.1 proposal (673004efa)
