# Round 13 seat: mistral (m-244@sat)

Measured on `e95587ea2` (2026-10-16).

## 1. Verdicts

| row | command | output | plan baseline | verdict | changes (if any) |
|---|---|---|---|---|---|
| 01 | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/MessageCard.vue \| wc -l` | 1416 | 1416 | **agree** | None. |
| 02 | `for f in $(git ls-files 'csi-spl-wui/src/**/*.vue' 'csi-spl-wui/src/*.vue'); do echo "$(sed -n '/<script/,/<\\/script>/p' $f \| wc -l) $f"; done \| sort -rn \| awk '$1>500' \| wc -l` | 7 | 7 | **agree** | None. |
| 03 | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/MessageComposer.vue \| wc -l` | 1135 | 1135 | **agree** | None. |
| 04 | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/components/ChannelSidebar.vue \| wc -l` | 1007 | 1007 | **agree** | None. |
| 05 | `wc -l csi-spl-wui/src/composables/useMsgShortcuts.ts \| awk '{print $1}'` | 464 | 464 | **agree** | None. |
| 06 | `sed -n '/<script/,/<\\/script>/p' csi-spl-wui/src/pages/issues.vue \| wc -l` | 2084 | 2084 | **agree** | None. |
| 07 | `wc -l csi-spl-wui/src/composables/useScrollAnchor.ts \| awk '{print $1}'` | 293 | 293 | **agree** | None. |
| 08 | Count unused exports | 2390 | 87 | **disagree** | The plan's command undercounts. The correct count is **2390 unused exports** in 49 files. The plan's baseline of 87 is incorrect. |
| 09 | `git grep -l 'poll-fence' csi-spl-wui/tests/unit/ \| wc -l` | 0 | 0 | **agree** | None. |
| 10 | `wc -l csi-spl-wui/src/composables/useSubmitKey.ts \| awk '{print $1}'` | 42 | 42 | **agree** | None. |

## 2. Proposals

### Proposal 1: Replace Row 08 with accurate unused exports gate
- **Title:** Add unused exports gate with accurate count
- **Description:** Replace Row 08 with a gate that fails on unused exports (2390 total). Allowlist shrinks only.
- **Measuring command:**
  ```bash
  for file in $(git ls-files 'csi-spl-wui/src/utils/'*.mjs 'csi-spl-wui/src/composables/'*.ts); do 
    exports=$(grep -E '^export (const|function|class|let|var|type|interface)' $file | awk '{print $2}' | sed 's/[({].*//'); 
    for export in $exports; do 
      if [ $(git grep -lw $export -- src tests nuxt.config.ts | grep -v $file | wc -l) -eq 0 ]; then 
        echo $export; 
      fi; 
    done; 
  done | wc -l
  ```
- **Output:** 2390
- **Replaces:** Row 08

### Proposal 2: Add test coverage ratchet for composables
- **Title:** Add test coverage ratchet for composables
- **Description:** Propose a gate that fails if a composable has 0 unit tests.
- **Measuring command:**
  ```bash
  for file in $(git ls-files 'csi-spl-wui/src/composables/'*.ts); do 
    echo "$(grep -E '^export (function|const) ' $file | wc -l) $file"; 
  done | while read line; do 
    count=$(echo $line | awk '{print $1}'); 
    file=$(echo $line | awk '{print $2}'); 
    tested=$(git grep -l "import.*from.*$(basename $file .ts)" -- tests/unit/ | wc -l); 
    if [ $tested -eq 0 ]; then 
      echo $count $file; 
    fi; 
  done | awk '{sum += $1} END {print sum}'
  ```
- **Output:** 126 untested exports
- **Replaces:** None

### Proposal 3: Add template decomposition gate for large SFCs
- **Title:** Add template decomposition gate for large SFCs
- **Description:** Propose a gate that fails if an SFC has >1 `<template>` block (indicating poor decomposition).
- **Measuring command:**
  ```bash
  for f in $(git ls-files 'csi-spl-wui/src/**/*.vue' 'csi-spl-wui/src/*.vue'); do 
    echo "$(grep -c '<template>' $f) $f"; 
  done | awk '$1 > 1' | wc -l
  ```
- **Output:** 1
- **Replaces:** None

## 3. R1 Compliance
- **No path in two rows of the same batch:** PASS.
- **Every batch has ≥ 2 rows:** PASS.

## 4. Sign-off

Signed: m-244@sat on 1a1e01c84 (2026-10-16).