# Round 15 - agy editor seat proposal & consensus (a-607@PC)

Measured on `673004efa` (`origin/master`, 2026-10-20).

Balanced refactoring across WUI (final SFC decomposition of `issues.vue` to eliminate the `BIG` map, leaf utils TypeScript migration to drop shim blocks per `SPL-2170`, `errorJournal.mjs` composable decomposition, unused exports ratchet), Backend Go coverage floors (`internal/blob`, `cmd/spool`, `internal/action`, `internal/config`), and Central runner logging parity (`csi-spl-utl/src/bash/run/run.sh`).
The editor (this seat) manages `../refactor-round-15-plan.md` and coordinates consensus across expert panel seats.

## 1. The 10 actions (v1.0 consensus)

| # | slug | sites | n (measured on `673004efa`) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `refactor(r15-01-wui-decompose-issues-page)` | `wui:src/pages/issues.vue:1185-2060` | 876 script lines | < 500 lines | complex_coding | 1 | Lane 1 |
| 02 | `test(r15-02-go-coverage-blob-store)` | `api:src/go/spool-hub-api/internal/blob/` | 67.6% statement coverage | floor >= 70.0 | tests | 1 | Lane 2 |
| 03 | `refactor(r15-03-wui-ts-convert-leaf-utils-group-c)` | `wui:src/utils/`, `wui:src/types/mjs-shims.d.ts` | 6 real leaf utils (122 shims) | 122 -> 116 shims | simple_coding | 2 | Lane 1 |
| 04 | `test(r15-04-go-coverage-cmd-spool)` | `api:src/go/spool-hub-api/cmd/spool/` | 75.1% statement coverage | floor >= 76.0 | tests | 2 | Lane 2 |
| 05 | `refactor(r15-05-wui-ts-convert-leaf-utils-group-d)` | `wui:src/utils/`, `wui:src/types/mjs-shims.d.ts` | 6 real leaf utils (116 shims) | 116 -> 110 shims | simple_coding | 3 | Lane 1 |
| 06 | `test(r15-06-go-coverage-action-runner)` | `api:src/go/spool-hub-api/internal/action/` | 75.6% statement coverage | floor >= 79.0 | tests | 3 | Lane 2 |
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

- v0.1 proposed by editor `a-607@PC` (agy) on `673004efa`.
- Reviews landed:
  - Claude seat `c-638@sat` in `51edde0b1` (`seat-claude.md`).
  - Mistral seat `m-640@sat` in `3e36fc375` (`seat-mistral.md`).
- v1.0 consensus draft prepared by editor `a-607@PC` in `3885b16b0`.
- All panel seats signed on v1.0 (`3885b16b0`):
  - Editor `a-607@PC`: signed on `3885b16b0`.
  - Claude seat `c-638@sat`: signed in `7051e1914`.
  - Mistral seat `m-640@sat`: signed in `ed6a8aae7`.

signed: a-607@PC on v0.1 proposal (673004efa)  
signed: a-607@PC on v1.0 consensus draft (3885b16b0)

## 4. Current Status: Consensus Complete

- Master trunk synchronized with all panel signatures (`7051e1914`).
- Round 14 retrospective (R8) and Round 15 plan v1.0 completed and fully signed.
- Consensus summary:
  - Editor `a-607@PC` (agy): signed on `3885b16b0`.
  - Claude seat `c-638@sat` (claude): signed in `7051e1914`.
  - Mistral seat `m-640@sat` (mistral): signed in `ed6a8aae7`.
- All 10 rows ready for dispatch across 2 parallel lanes (5 batches).
- Ready for Batch 1 dispatch:
  - Lane 1: Row 01 `refactor(r15-01-wui-decompose-issues-page)` (`complex_coding`, claude).
  - Lane 2: Row 02 `test(r15-02-go-coverage-blob-store)` (`tests`, claude).
