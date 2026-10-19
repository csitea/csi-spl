# Round 14 - Mistral Seat Verdict (Docs & Review Only)

**Agent:** `m-490@sat`
**Epic:** SPL-2402  
**Issue:** SPL-2557  
**Plan:** [refactor-round-14-plan.md](/doc/md/refactor-round-14/refactor-round-14-plan.md) v1.0 (`b8e6ad94c`)
**Measured on:** `ab685ef25` (current `origin/master`) and `b8e6ad94c` (plan v1.0 commit)

## Status

**Role:** Docs and peer review only (owner HUM-10 rule 10-17: no mistral coding rows).
**Verdict:** 8/9 rows **agree**, 1 row **agree with changes** (Row 08).
**Proposals:** 1 (remove `flowTopicUnread` from `ALLOW` in `unused-exports.test.mjs`).

---

## Verdict per Row

| Row | Slug | Practice | Verdict | Notes |
|---|---|---|---|---|
| 01 | `refactor(r14-01-wui-decompose-doc-view)` | Component decomposition | **Agree** | 677 lines, ceiling 677. Decompose picture handling and insert operations into `useDocPictures.ts` and `useDocInsert.ts`. |
| 02 | `refactor(r14-02-orc-small-spawn-main)` | Small functions, cleaner orchestration | **Agree** | 184 lines, ceiling 185. Split into `spawn_guards_env`, `spawn_init_dirs`, `spawn_register_agent`, `spawn_launch_session`. |
| 03 | `refactor(r14-03-wui-decompose-qto-tree)` | Component decomposition | **Agree** | 654 lines, ceiling 654. Extract folder expansion and drag-and-drop into `useQtoTreeFolders.ts` and `useQtoTreeDrop.ts`. |
| 04 | `refactor(r14-04-iac-small-check-pre-push)` | Small functions, cleaner tooling | **Agree** | 137 lines, ceiling 137. Split into `_pp_plan_parts` and `_pp_run_parts`. |
| 05 | `refactor(r14-05-wui-decompose-calendar-main)` | Component decomposition | **Agree** | 612 lines, ceiling 612. Extract drag/resize into `useCalendarDrag.ts`. |
| 06 | `test(r14-06-go-coverage-payments-paypal)` | Unit test coverage, testability | **Agree** | 72.4% coverage. Add `paypal_payments_test.go` with `httptest` server. |
| 07 | `refactor(r14-07-wui-small-composable-mobile-stack)` | Small composables, testability | **Agree** | 531 lines. Extract pure stack decisions into `src/utils/mobile-stack.mjs`. |
| 08 | `refactor(r14-08-wui-ratchet-unused-exports)` | Dead code elimination | **Agree with changes** | 75 unused exports (cap 76). Remove `flowTopicUnread` from `ALLOW` to lower cap to 75. |
| 09 | `refactor(r14-09-bash-small-run-do-log)` | Small functions, central runner logging | **Agree** | 143 lines in both IAC and ORC. Split into named helper steps. |

---

## Proposals

1. **Remove `flowTopicUnread` from `ALLOW` in `unused-exports.test.mjs`** (Row 08).
   - **Why:** It is unused and can lower the cap from 76 to 75.
   - **Command:** `grep -c flowTopicUnread csi-spl-wui/tests/unit/unused-exports.test.mjs` -> `1`.

---

## Summary

- **8/9 rows agree** with the plan's baseline claims.
- **1 row (08) agrees with changes** (remove `flowTopicUnread` from `ALLOW`).
- **1 proposal** to address unused exports.
- **No additional proposals**: All other claims are accurate, and no further decompositions or tests are needed beyond the 9 rows in the plan.

---

## Next Steps

- **Editor (a-615@PC)** to fold this verdict into v1.0 of the plan.
- **Await signoff** on v1.0 plan sha.

---

## Commands Used

```bash
# Row 01
sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue | wc -l

# Row 02
sed -n '/^spawn_main() {/,/^}/p' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh | wc -l

# Row 03
sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/workspace-docs/QtoFileTree.vue | wc -l

# Row 04
sed -n '/^do_check_pre_push() {/,/^}/p' csi-spl-iac/src/bash/run/check-pre-push.func.sh | wc -l

# Row 05
sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/CalendarMainView.vue | wc -l

# Row 06
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/ | grep -oP 'coverage: \K[0-9.]+'

# Row 07
wc -l csi-spl-wui/src/composables/useMobileStack.ts | awk '{print $1}'

# Row 08
node csi-spl-wui/tests/unit/unused-exports.test.mjs 2>&1 | grep -oP 'Found \K[0-9]+' | head -1

# Row 09 (IAC)
sed -n '/^do_log() {/,/^}/p' csi-spl-iac/src/bash/run/run.sh | wc -l
# Row 09 (ORC)
sed -n '/^do_log() {/,/^}/p' csi-spl-orc/src/bash/run/run.sh | wc -l
```