# Round 14 - agy editor seat proposal & consensus (a-615@PC)

Measured on `e9fa87f74` (`origin/master`, 2026-10-19) and re-verified on `ab685ef25` / `b8e6ad94c`.

Balanced refactoring across WUI (component/composable decomposition, unused exports ratchet), Bash tooling/orchestration (`spawn_main`, `do_check_pre_push`, `do_log`), and Go API coverage (`internal/payments`).
The editor (this seat) manages `../refactor-round-14-plan.md` and coordinates consensus across expert panel seats.

## 1. The 9 actions (v1.0 consensus)

| # | slug | sites | n (measured on `ab685ef25`) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `refactor(r14-01-wui-decompose-doc-view)` | `wui:src/components/workspace-docs/WorkspaceDocView.vue:339-1015` | 677 script lines | < 500 lines | complex_coding | 1 | Lane 1 |
| 02 | `refactor(r14-02-orc-small-spawn-main)` | `orc:src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:439-622` | 184 lines | steps <= 80 lines | complex_coding | 1 | Lane 2 |
| 03 | `refactor(r14-03-wui-decompose-qto-tree)` | `wui:src/components/workspace-docs/QtoFileTree.vue:139-792` | 654 script lines | < 500 lines | complex_coding | 2 | Lane 1 |
| 04 | `refactor(r14-04-iac-small-check-pre-push)` | `iac:src/bash/run/check-pre-push.func.sh:914-1050` | 137 lines | steps <= 80 lines | simple_coding | 2 | Lane 2 |
| 05 | `refactor(r14-05-wui-decompose-calendar-main)` | `wui:src/components/CalendarMainView.vue:206-817` | 612 script lines | < 500 lines | complex_coding | 3 | Lane 1 |
| 06 | `test(r14-06-go-coverage-payments-paypal)` | `api:src/go/spool-hub-api/internal/payments/paypal_payments.go:338-390` | 72.4% statement coverage | floor >= 74.0 | tests | 3 | Lane 2 |
| 07 | `refactor(r14-07-wui-small-composable-mobile-stack)` | `wui:src/composables/useMobileStack.ts:1-531` | 531 lines | <= 420 lines | simple_coding | 4 | Lane 1 |
| 08 | `refactor(r14-08-wui-ratchet-unused-exports)` | `wui:tests/unit/unused-exports.test.mjs` | 75 unused exports in ALLOW | cap <= 60 | simple_coding | 4 | Lane 2 |
| 09 | `refactor(r14-09-bash-small-run-do-log)` | `iac:src/bash/run/run.sh:320-462`, `orc:src/bash/run/run.sh:320-462` | 143 lines in 2 files | steps <= 80 lines | complex_coding | 5 | Lane 2 |

## 2. 2 Parallel Lanes

- Lane 1 (WUI): Rows 01 -> 03 -> 05 -> 07
- Lane 2 (Bash / API / Gate / Logging): Rows 02 -> 04 -> 06 -> 08 -> 09
- Starts with: Row 01 (`WorkspaceDocView.vue`) and Row 02 (`spawn-core.inc.sh`) in parallel (Batch 1).

## 3. Status and Signatures

- v0.1 proposed: landed on origin/master in `b7fad2def`.
- Claude expert seat review received from `c-666@PC` in `b8e6ad94c`: 1 agree, 6 agree with changes, 3 disagree (08 site corrections, 09 target already met, 10 file hash-pinned to csi-rel), 2 proposals (7.1 `do_log` split across iac+orc `run.sh`, 7.2 R2 bold source-text test column).
- v1.0 consensus drafted folding all Claude expert panel findings and proposals into 9 clean actions across 2 parallel lanes.
- Editor signed on v1.0 consensus (`c9b3225b0`).
- Claude panel seat `c-666@PC` signed on v1.0 consensus in `7ce70cc59`.
- Mistral panel seat `m-490@sat` signed on v1.0 consensus in `adfe1a321`.

signed: a-615@PC on v1.0 consensus (c9b3225b0)
consensus reached: full 3-seat consensus across editor (agy), claude seat, and mistral seat

## 4. Current Status on Rotation (21:53Z)

- Full 3-seat signature consensus on v1.0 landed on origin/master in `fc0e04619`.
- Mistral seat `m-490@sat` re-measured on `938a31f67` and updated `seat-mistral.md` in `e973768a7`; acknowledged by editor `a-615` (msg `3518c0a5`).
- Batch 1 completed and landed on origin/master:
  - Row 01 (`refactor(r14-01-wui-decompose-doc-view)`, SPL-2575): R7 review completed by `a-615` (PASS), landed on origin/master in `aa1345a1d`.
  - Row 02 (`refactor(r14-02-orc-small-spawn-main)`, SPL-2576): R7 review completed by `a-615` (PASS on `5dd714f2eb02fe0b8d0cce1ce86fd1e1849be9ff`), landed on origin/master in `278f72c9d`.
- Batch 2 ready for dispatch: Row 03 (`refactor(r14-03-wui-decompose-qto-tree)`, Lane 1) and Row 04 (`refactor(r14-04-iac-small-check-pre-push)`, Lane 2). Current dispatch lease holder is `g-003@sat`.
- Standing role: `a-615` is standing by as designated R7 cross-vendor reviewer for incoming Round 14 rows per plan §5.
- Next round input: Owner HUM-10 directive for Round 15 (SPL-2170, retiring WUI `.mjs` layer to pure TypeScript, 306 files) received and recorded for inclusion in Section 7 of Round 14 Retrospective (R8).
- Hourly rotation at 21:53Z UTC: Worktree clean and synchronized with origin/master, standing by for incoming R7 review requests or Batch 2 dispatch updates.
