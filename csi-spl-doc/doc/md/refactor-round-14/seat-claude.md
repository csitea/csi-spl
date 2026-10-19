# Round 14 - Claude Seat Verdict

Measured on `e9fa87f74` (`origin/master`, 2026-10-19).

## Status

Pending review of v0.1 plan (`refactor-round-14-plan.md`).

| Row | Slug | Practice | Verdict | Command | Output |
|---|---|---|---|---|---|
| 01 | `refactor(r14-01-wui-decompose-doc-view)` | component decomposition | Pending | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue \| wc -l` | `677` |
| 02 | `refactor(r14-02-orc-small-spawn-main)` | small functions, cleaner orchestration | Pending | `sed -n '/^spawn_main() {/,/^}/p' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh \| wc -l` | `184` |
| 03 | `refactor(r14-03-wui-decompose-qto-tree)` | component decomposition | Pending | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/QtoFileTree.vue \| wc -l` | `654` |
| 04 | `refactor(r14-04-iac-small-check-pre-push)` | small functions, cleaner tooling | Pending | `sed -n '/^do_check_pre_push() {/,/^}/p' csi-spl-iac/src/bash/run/check-pre-push.func.sh \| wc -l` | `137` |
| 05 | `refactor(r14-05-wui-decompose-calendar-main)` | component decomposition | Pending | `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/CalendarMainView.vue \| wc -l` | `612` |
| 06 | `test(r14-06-go-coverage-payments-paypal)` | unit test coverage, testability | Pending | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/` | `72.4%` |
| 07 | `refactor(r14-07-wui-small-composable-mobile-stack)` | small composables, testability | Pending | `wc -l csi-spl-wui/src/composables/useMobileStack.ts \| awk '{print $1}'` | `531` |
| 08 | `refactor(r14-08-wui-ratchet-unused-exports)` | dead code elimination | Pending | `node csi-spl-wui/tests/unit/unused-exports.test.mjs` | `75 unused (cap 76)` |
| 09 | `refactor(r14-09-wui-decompose-notification-store)` | store decomposition, cleaner state | Pending | `wc -l csi-spl-wui/src/stores/notification.ts \| awk '{print $1}'` | `569` |
| 10 | `refactor(r14-10-iac-small-provision-firebase-dns)` | small functions, cleaner infra scripting | Pending | `sed -n '/^do_provision_firebase_dns() {/,/^}/p' csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh \| wc -l` | `169` |
