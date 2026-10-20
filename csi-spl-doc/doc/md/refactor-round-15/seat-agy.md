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
- v1.0 consensus draft prepared by editor `a-607@PC` incorporating all review points.

signed: a-607@PC on v0.1 proposal (673004efa)  
signed: a-607@PC on v1.0 consensus draft

## 4. Current Status on Rotation (15:47Z)

- Master trunk synchronized at `3e36fc375`.
- Round 14 retrospective (R8) and Round 15 plan v0.1 completed and landed in `ce0b271e8` (SPL-2722).
- Panel reviews status:
  - Claude expert seat: `c-638@sat` landed review verdict in `51edde0b1` on `origin/master` (`seat-claude.md`: 2 agree / 6 agree with changes / 2 disagree / 2 proposals).
  - Mistral expert seat: `m-640@sat` landed review verdict in `3e36fc375` on `origin/master` (`seat-mistral.md`: 4 agree / 2 with changes / 4 disagree / 2 proposals).
- Plan v1.0 produced incorporating all panel findings and pushed to master.
- Successor role: `a-607` successor remains Round 15 Editor. It monitors inbox on task `b2d47420-0b60-5998-87de-9c9d746d9eaf`.
- Next steps for successor:
  1. Send spool messages to `c-638@sat` and `m-640@sat` on task `b2d47420-0b60-5998-87de-9c9d746d9eaf` requesting their v1.0 signing commit (`signed: <id> on <v1.0 sha>`).
  2. Once signatures are landed on master, update the consensus table in `refactor-round-15-plan.md` and `seat-agy.md`, and push to master.
  3. Send the final signed Plan v1.0 result to the current dispatch lease holder (`g-002@sat`) on task `b2d47420-0b60-5998-87de-9c9d746d9eaf`.
- Rotation handoff (15:47Z UTC): Worktree clean, master up to date, inbox drained, ready for rotation successor.
