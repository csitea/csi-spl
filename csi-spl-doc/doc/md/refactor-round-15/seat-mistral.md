# Refactor Round 15: Mistral Expert Panel Seat

**Task ID**: dispatch-dc15ad65
**Epic**: SPL-2402
**Spec**: csi-spl-doc/specs/011-spool-project-refactor
**Editor**: a-607@PC
**Signed**: 

## Verdict Summary
| Row | Measurement | Current Value (sha: `51edde0b1750e25608606f67b150be0ba12f43bd`) | Target | Verdict | Reason |
|-----|-------------|---------------|--------|---------|--------|
| 01  | `issues.vue` line count | 2950 | < 500 | Disagree | Already exceeds target. |
| 03  | Shim count (`.sh`) | 27 | 114 → 114 | Agree with changes | Baseline is already below target. |
| 05  | Shim count (`.mjs`) | 7 | 114 → 106 | Agree with changes | Baseline is already below target. |
| 07  | `errorJournal.mjs` line count | 731 | ≤ 400 | Disagree | Already exceeds target. |
| 08  | Runners byte-identity | Not byte-identical | Byte-identical | Disagree | Not byte-identical. |
| 09  | ALLOW cap | 6 | ≤ 40 | Agree | Already below target. |

## Detailed Verdicts

### Row 01: `issues.vue` line count
- **Command**: `wc -l /opt/csi/csi-spl/csi-spl-wui/src/pages/issues.vue`
- **Current**: 2950 lines
- **Target**: < 500 lines
- **Verdict**: Disagree
- **Reason**: The current line count is significantly higher than the target. The file may need to be split or refactored into smaller components.
- **Test Coverage**: Tests exist for `issues.vue` (e.g., `issues.test.mjs`, `issue-detail-buttons.test.mjs`).

### Row 03/05: Shim Counts
- **Command**: `find /opt/csi/csi-spl -name "*.sh" -exec grep -l "shim" {} \; | wc -l` and `find /opt/csi/csi-spl -name "*.mjs" -exec grep -l "shim" {} \; | wc -l`
- **Current (`.sh`)**: 27
- **Current (`.mjs`)**: 7
- **Target (03)**: 122 → 114
- **Target (05)**: 114 → 106
- **Verdict**: Agree with changes
- **Reason**: The current counts are already below the targets.

### Row 07: `errorJournal.mjs` line count
- **Command**: `wc -l /opt/csi/csi-spl/csi-spl-wui/src/composables/errorJournal.mjs`
- **Current**: 731 lines
- **Target**: ≤ 400 lines
- **Verdict**: Disagree
- **Reason**: The current line count exceeds the target. The file may need to be split or refactored.
- **Error Handling**: The file contains error handling logic (e.g., `catch` blocks).

### Row 08: Runners Byte-Identity
- **Command**: `sha256sum gh-runner-add.func.sh gh-runner-retire-offline.func.sh gh-runner-remove.func.sh`
- **Current**: Not byte-identical
- **Target**: Byte-identical
- **Verdict**: Disagree
- **Reason**: The three scripts are not byte-identical.

### Row 09: ALLOW Cap
- **Command**: `grep -A 20 "ENC_ALLOW=(" /opt/csi/csi-spl/csi-spl-orc/src/bash/tests/enc-dirs-untouched.tst.sh`
- **Current**: 6 entries
- **Target**: ≤ 40
- **Verdict**: Agree
- **Reason**: The current count is already below the target.

## Proposals
1. **Split `issues.vue`**: Refactor `issues.vue` into smaller components to reduce its line count.
2. **Refactor `errorJournal.mjs`**: Split or refactor `errorJournal.mjs` to reduce its line count.

## Files Checked
- `issues.vue`
- `errorJournal.mjs`
- `gh-runner-add.func.sh`, `gh-runner-retire-offline.func.sh`, `gh-runner-remove.func.sh`
- `enc-dirs-untouched.tst.sh`

## Compliance
- No mistral coding rows.
- No prd or GCP mutations required.
- All measurements taken on `origin/master` (sha: `51edde0b1750e25608606f67b150be0ba12f43bd`).