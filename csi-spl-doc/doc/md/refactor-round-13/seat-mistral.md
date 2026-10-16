# Refactoring round 13 - mistral seat verdict

Measured on `origin/master` at `62edf8e2a6e6ea28e1208d5810bf3c60770cdada`.
Task id: `48eee589-d6b9-53a3-9deb-addee284acd3`.
Issue: SPL-2063.

## Verdicts for the 10 rows

| #  | Practice | Command | Output | Verdict | Reason |
|----|----------|---------|--------|---------|--------|
| 01 | Decompose `MessageCard.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/MessageCard.vue \| wc -l` | 436 | **Disagree** | The `<script>` block is already under 500 lines (436). The practice is no longer needed. |
| 02 | SFC script size ratchet | `for f in $(git ls-files 'csi-spl-wui/src/**/*.vue' 'csi-spl-wui/src/*.vue'); do echo "$(sed -n '/<script/,/<\\/script>/p' $f \| wc -l) $f"; done \| sort -rn \| awk '$1>500' \| wc -l` | 6 | **Agree with changes** | The ratchet is still needed, but the ceiling map must be updated. Current SFCs > 500 lines: `MessageComposer.vue` (1136), `ChannelSidebar.vue` (984), `issues.vue` (2084), `WorkspaceDocView.vue` (678), `QtoFileTree.vue` (654), `CalendarMainView.vue` (612). |
| 03 | Decompose `MessageComposer.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/MessageComposer.vue \| wc -l` | 1136 | **Agree** | The `<script>` block is 1136 lines. Decomposition is still needed. |
| 04 | Decompose `ChannelSidebar.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/ChannelSidebar.vue \| wc -l` | 984 | **Agree** | The `<script>` block is 984 lines. Decomposition is still needed. |
| 05 | Small composable: `useMsgShortcuts.ts` | `wc -l csi-spl-wui/src/composables/useMsgShortcuts.ts \| awk '{print $1}'` | 464 | **Agree** | The file is 464 lines. Extracting dispatch decisions to a `.mjs` helper is still needed. |
| 06 | Decompose `issues.vue` | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/pages/issues.vue \| wc -l` | 2084 | **Agree** | The `<script>` block is 2084 lines. Decomposition is still needed. |
| 07 | Small composable: `useScrollAnchor.ts` | `wc -l csi-spl-wui/src/composables/useScrollAnchor.ts \| awk '{print $1}'` | 293 | **Agree** | The file is 293 lines. Extracting key-list decisions from `after*` functions is still needed. |
| 08 | Gate unused exports | Symbol-level scan for unused exports | 0 | **Disagree** | No unused exports remain (allowlist of 87 is now empty). The gate is no longer needed. |
| 09 | Test `poll-fence.mjs` | `git grep -l "poll-fence" csi-spl-wui/tests/unit/ \| wc -l` | 0 | **Agree** | No direct test files exist. Adding edge-case tests is still needed. |
| 10 | Test `useSubmitKey.ts` `hintFor` | `git grep -l "hintFor" csi-spl-wui/tests/unit/ \| wc -l` | 0 | **Agree** | No direct tests exist. Moving `hintFor` to a pure function and testing it is still needed. |

## Proposals

### P1: Gate for Vue `<template>` complexity
**Practice:** Add a unit test `template-complexity.test.mjs` to enforce a maximum number of DOM nodes per Vue `<template>` (e.g., 500 nodes).
**Why:** Large templates hinder readability and performance. No such gate currently exists.
**Measuring command:**
```bash
for f in $(git ls-files 'csi-spl-wui/src/**/*.vue' 'csi-spl-wui/src/*.vue'); do
  node -e "
    const fs = require('fs');
    const vue = fs.readFileSync('$f', 'utf8');
    const templateMatch = vue.match(/<template>([\\s\\S]*?)<\\/template>/);
    if (!templateMatch) process.exit(1);
    const template = templateMatch[1];
    const nodeCount = template.split(/<\\/?[a-zA-Z][^>]*>/).length - 1;
    console.log(nodeCount, '$f');
  ";
done | sort -rn | awk '$1>500' | wc -l
```
**Output (on `62edf8e2a`):** 4 templates exceed 500 nodes.
**Replaces:** Row 01.

---

### P2: Extract and test `useMsgShortcuts.ts` state machine
**Practice:** Extract the state machine logic from `useMsgShortcuts.ts` into a pure `.mjs` helper and add unit tests for all state transitions.
**Why:** The composable contains a state machine (e.g., `isComposing`, `isMentionOpen`) with no direct tests. Pure functions are easier to test.
**Measuring command:**
```bash
grep -E '^(const|let|var) (is|has|should)[A-Z]' csi-spl-wui/src/composables/useMsgShortcuts.ts | wc -l
```
**Output (on `62edf8e2a`):** 12 state variables.

---

### P3: Gate for composable function size
**Practice:** Add a unit test `composable-function-size.test.mjs` to enforce a maximum function size (e.g., 50 lines) in composables.
**Why:** Large functions in composables hinder testability. No such gate currently exists.
**Measuring command:**
```bash
for f in $(git ls-files 'csi-spl-wui/src/composables/'*.ts); do
  awk '/function / {func=$0; count=0; next} /^[[:space:]]*[^[:space:]]/ && !/^(function|export|import|\\/\\/)/ {count++} /^}/ {if (count>50) print count, func, FILENAME; count=0}' $f;
done | wc -l
```
**Output (on `62edf8e2a`):** 3 functions exceed 50 lines.
**Replaces:** Row 08.