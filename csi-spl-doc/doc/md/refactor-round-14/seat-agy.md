# Round 14 - agy editor seat proposal (a-615@<box>)

Measured on `e9fa87f74` (`origin/master`, 2026-10-19).

A proposal for round 14: balanced refactoring across WUI (components, stores, composables, unused exports), Bash tooling/orchestration (`spawn_main`, `do_check_pre_push`, `do_provision_firebase_dns`), and Go API coverage (`internal/payments`).
The editor (this seat) merges the expert panel seats into `../refactor-round-14-plan.md`.
The expert panel seats (claude, mistral, grok) write their seat files beside this file, verify the empirical measurements on current trunk, give verdicts per row, and reach consensus per `rounds-rulebook.md`.

## 1. The 10 actions (v0.1 proposed)

| # | slug | sites | n (measured on `e9fa87f74`) | target | kind |
|---|---|---|---|---|---|
| 01 | `refactor(r14-01-wui-decompose-doc-view)` | `wui:src/components/workspace-docs/WorkspaceDocView.vue:242-918` | 677 script lines | < 500 lines | complex_coding |
| 02 | `refactor(r14-02-orc-small-spawn-main)` | `orc:src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:75-258` | 184 lines | steps <= 80 lines | simple_coding |
| 03 | `refactor(r14-03-wui-decompose-qto-tree)` | `wui:src/components/workspace-docs/QtoFileTree.vue:240-893` | 654 script lines | < 500 lines | complex_coding |
| 04 | `refactor(r14-04-iac-small-check-pre-push)` | `iac:src/bash/run/check-pre-push.func.sh:30-166` | 137 lines | steps <= 80 lines | simple_coding |
| 05 | `refactor(r14-05-wui-decompose-calendar-main)` | `wui:src/components/CalendarMainView.vue:326-937` | 612 script lines | < 500 lines | complex_coding |
| 06 | `test(r14-06-go-coverage-payments-paypal)` | `api:src/go/spool-hub-api/internal/payments/paypal_payments.go:338-390` | 72.4% statement coverage | floor >= 74.0 | tests |
| 07 | `refactor(r14-07-wui-small-composable-mobile-stack)` | `wui:src/composables/useMobileStack.ts:1-531` | 531 lines | <= 250 lines | simple_coding |
| 08 | `refactor(r14-08-wui-ratchet-unused-exports)` | `wui:tests/unit/unused-exports.test.mjs` | 75 unused exports in ALLOW | cap <= 60 | simple_coding |
| 09 | `refactor(r14-09-wui-decompose-notification-store)` | `wui:src/stores/notification.ts:1-569` | 569 lines | <= 250 lines | complex_coding |
| 10 | `refactor(r14-10-iac-small-provision-firebase-dns)` | `iac:src/bash/run/provision-firebase-dns.func.sh:35-203` | 169 lines | steps <= 80 lines | simple_coding |

## 2. Parallel Lanes

- Lane 1: Rows 01, 03, 05, 07, 09
- Lane 2: Rows 02, 04, 06, 08, 10
- Starts with: Row 01 (`WorkspaceDocView.vue`) and Row 02 (`spawn-core.inc.sh`) in parallel (Batch 1).

## 3. Proposal Status

Proposed v0.1 by editor `a-615@<box>` on `e9fa87f74` (2026-10-19).
