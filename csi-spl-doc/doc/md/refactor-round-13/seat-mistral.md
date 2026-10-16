# Refactoring Round 13 - Mistral Seat Verdict

**Agent:** `m-244@sat`
**Baseline:** `f949bd930` (`origin/master`, 2026-10-16)
**Issue:** SPL-2045

## Verdict Summary
- **Agree:** 7 rows (03, 04, 05, 06, 07, 09, 10)
- **Agree with changes:** 1 row (02)
- **Disagree:** 2 rows (01, 08)
- **Proposals:** 1 (P1, replaces Row 01)

## Per-Row Verdicts

| #  | Practice | Measuring Command | Plan Baseline (`e95587ea2`) | Current (`f949bd930`) | Verdict | Notes |
|----|----------|-------------------|-----------------------------|-----------------------|------------|-------|
| 01 | Decompose `MessageCard.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/MessageCard.vue \| wc -l` | 1416 | 436 | **Disagree** | Already decomposed. No action needed. |
| 02 | SFC script ratchet | `for f in $(git ls-files 'csi-spl-wui/src/**/*.vue' 'csi-spl-wui/src/*.vue'); do echo "$(sed -n '/<script/,/<\\/script>/p' $f \| wc -l) $f"; done \| sort -rn \| awk '$1>500' \| wc -l` | 7 | 6 | **Agree with changes** | `MessageCard.vue` no longer > 500 lines. Ceiling map must be updated. |
| 03 | Decompose `MessageComposer.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/MessageComposer.vue \| wc -l` | 1135 | 1136 | **Agree** | No change. Still > 500 lines. |
| 04 | Decompose `ChannelSidebar.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/ChannelSidebar.vue \| wc -l` | 1007 | 984 | **Agree** | Slightly smaller, but still > 500 lines. |
| 05 | Small composable: `useMsgShortcuts.ts` | `wc -l csi-spl-wui/src/composables/useMsgShortcuts.ts \| awk '{print $1}'` | 464 | 464 | **Agree** | No change. Still > 250 lines. |
| 06 | Decompose `pages/issues.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/pages/issues.vue \| wc -l` | 2084 | 2084 | **Agree** | No change. Still > 1200 lines. |
| 07 | Small composable: `useScrollAnchor.ts` | `wc -l csi-spl-wui/src/composables/useScrollAnchor.ts \| awk '{print $1}'` | 293 | 293 | **Agree** | No change. Still > 250 lines. |
| 08 | Gate unused exports | Symbol-level scan for unused exports | 87 | 0 | **Disagree** | No unused exports found. Likely cleaned up already. |
| 09 | Test `poll-fence.mjs` | `git grep -l "poll-fence" csi-spl-wui/tests/unit/ \| wc -l` | 0 | 0 | **Agree** | No direct test files. Still untested. |
| 10 | Test `useSubmitKey.ts` | `wc -l csi-spl-wui/src/composables/useSubmitKey.ts \| awk '{print $1}'` | 42 | 42 | **Agree** | No change. `hintFor` still untested. |

## Proposals

### Proposal P1 (Replaces Row 01)
**Action:** Add a unit test for `useSubmitKey.ts`'s `hintFor` logic.
**Why:** The composable's `hintFor` logic (3 lines) is untested and cannot be imported directly in node unit tests due to Nuxt/Vue imports. Moving it to `utils/submit-key.mjs` as a pure function and adding unit tests would improve testability.
**Measuring Command:**
```bash
git grep -l "hintFor" csi-spl-wui/tests/unit/ | wc -l
```
**Current Output:** `0` (no direct tests).
**Target:** Add `submit-key.test.mjs` covering `hintFor` edge cases (e.g., empty mode, unknown base).

## Batch Validation (R1)
- **No path appears in two rows of the same batch.**
- **Every batch has >= 2 rows.**
- **Lanes:**
  - **Lane 1 (odd rows):** 03, 05, 07, 09, P1 (replaces 01)
  - **Lane 2 (even rows):** 02, 04, 06, 08, 10

## Evidence Rule
Every number and verdict is measured on `f949bd930` (`origin/master`, 2026-10-16) in this session. No numbers are copied from the plan or another seat.