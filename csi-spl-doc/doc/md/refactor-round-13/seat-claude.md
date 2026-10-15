# Round 13 - claude seat verdict (c-243@sat)

Seat: **c-243@sat** (claude), expert panel of
[refactor-round-13-plan.md](../refactor-round-13-plan.md) v0.3. Issue SPL-2045.

**One sha:** every number below was measured in this session on
**`e95587ea2`** (`origin/master`, 2026-10-16), n=1 per command, from
`csi-spl-wui/` unless the command says otherwise. The plan measured on
`dc17f840e`; every count it cites reproduces on `e95587ea2` except the one in
row 08 (42 lines, not 43).

Baseline on `e95587ea2`, for every row's "behaviour kept" check:
`node src/node/test/run-unit-tests.mjs` -> `unit runner: all 379 file(s) passed`
(rc 0, 2m29s); `node tests/unit/cleancode.test.mjs` -> rc 0.

## 1. Summary

| # | verdict | the one reason |
|---|---|---|
| 01 | agree with changes | count holds; the site range is wrong and 39 tests read the file's source |
| 02 | agree with changes | count holds; the site range is wrong and 48 tests read the file's source |
| 03 | agree with changes | count holds; the site range is wrong and 26 tests read the file's source |
| 04 | **disagree** | the pure helper already exists (`utils/mobile-stack.mjs`, 239 lines, 5 test files) |
| 05 | agree with changes | the helper already exists at 458 lines; a "<= 200 pure helper" target contradicts it |
| 06 | **disagree** | the pure helper already exists (`utils/pane-widths.mjs`, 307 lines, tested) |
| 07 | agree with changes | the math is already in `utils/scroll-anchor.mjs`; move the anchor-restore decisions, not "lines" |
| 08 | agree with changes | no unit test can import a `.ts` file; move `hintFor` into `submit-key.mjs` and test it there |
| 09 | agree with changes | `mayHavePoll` is already tested (2 asserts); the grep misses it; test the edge cases only |
| 10 | **disagree** | a 12-line store with one setter: a test of it protects nothing |

**Count: 0 agree / 7 agree with changes / 3 disagree / 3 proposals.**
Proposals P1, P2, P3 (section 3) replace rows 10, 04 and 06.

## 2. Per row: command, output, verdict

### 2.1 Rows 01-03: SFC decomposition

| row | command | output |
|---|---|---|
| 01 | `sed -n '/<script/,/<\/script>/p' src/components/MessageCard.vue \| wc -l` | 1416 |
| 02 | `sed -n '/<script/,/<\/script>/p' src/components/ChannelSidebar.vue \| wc -l` | 1007 |
| 03 | `sed -n '/<script/,/<\/script>/p' src/components/MessageComposer.vue \| wc -l` | 1135 |
| 01 | `grep -n '<script\|</script>' src/components/MessageCard.vue` | `466:<script setup lang="ts">`, `1881:</script>` |
| 02 | `grep -n '<script\|</script>' src/components/ChannelSidebar.vue` | `711:<script setup lang="ts">`, `1717:</script>` |
| 03 | `grep -n '<script\|</script>' src/components/MessageComposer.vue` | `328:<script setup lang="ts">`, `1462:</script>` |
| 01 | `git grep -l "components/MessageCard.vue" tests/unit \| wc -l` | 39 |
| 02 | `git grep -l "components/ChannelSidebar.vue" tests/unit \| wc -l` | 48 |
| 03 | `git grep -l "components/MessageComposer.vue" tests/unit \| wc -l` | 26 |
| 01 | `git log --since=2026-10-09 --oneline -- src/components/MessageCard.vue \| wc -l` | 17 |
| 02 | same, `ChannelSidebar.vue` | 15 |
| 03 | same, `MessageComposer.vue` | 5 |

Verdict for each: **agree with changes**. The counts hold. Changes:

1. **Fix the sites.** The plan writes `MessageCard.vue:2-1417`,
   `ChannelSidebar.vue:2-1008` and `MessageComposer.vue:2-1136`. Those lines are
   the `<template>`. The `<script>` blocks are `466-1881`, `711-1717` and
   `328-1462` (grep above).
2. **List the source-reading tests in the test column (R2).** 39, 48 and 26
   unit test files name these files by path, so a decomposition that moves code
   out breaks or silently weakens them. The row's "behaviour kept" check is
   each of those files passing **with its asserts re-pointed at the new file,
   none deleted**: count `assert` lines in those files before and after, and
   the count must not drop. Smoke tests alone (typecheck, cleancode) cannot
   show that.
3. **The red control is the gate from P1, not a one-off probe.** A `wc -l`
   before and after proves nothing once the lane closes; the next feature
   commit can grow the file back. With 17 commits in 7 days on MessageCard
   that is likely.
4. **Row 01 vs row 05:** `MessageCard.vue` uses `useMsgShortcuts` (same
   lane 1, serial, fine). **Rows 01, 02 and 03 all use `useMobileStack`**
   (`grep -oE 'use(MobileStack|MsgShortcuts|SubmitKey)\b' <file> | sort -u` on
   each: MessageCard -> `useMobileStack useMsgShortcuts`, ChannelSidebar ->
   `useMobileStack useSubmitKey`, MessageComposer -> `useMobileStack
   useSubmitKey`). With row 04 on lane 2 running beside rows 01/03 on lane 1,
   any API change in row 04 edits callers lane 1 is rewriting. Dropping row 04
   (below) removes that overlap.

### 2.2 Row 04: `useMobileStack.ts`

| command | output |
|---|---|
| `wc -l src/composables/useMobileStack.ts` | 531 |
| `sed -n '2,24p' src/composables/useMobileStack.ts \| grep "from '"` | `} from '~/utils/mobile-stack.mjs'` (among others) |
| `wc -l src/utils/mobile-stack.mjs` | 239 |
| `git grep -l "utils/mobile-stack.mjs" tests/unit` | 5 files (`breakpoint-single-source`, `mobile-overlay`, `mobile-stack`, `sidebar-tabs`, `touch-ui`) |

Verdict: **disagree**. The pure stack math the row wants to extract was already
extracted into `utils/mobile-stack.mjs` and is tested by 5 files. What is left
in the composable is Vue and router wiring, which cannot become a pure helper.
Getting it under 200 lines would only move wiring into another `.ts` file, which
is no gain in testability. It also creates the cross-lane caller overlap from
2.1 item 4. **Replace with P2.**

### 2.3 Row 05: `useMsgShortcuts.ts`

| command | output |
|---|---|
| `wc -l src/composables/useMsgShortcuts.ts` | 464 |
| `grep -n "from '~/utils/msg-shortcuts.mjs'" src/composables/useMsgShortcuts.ts` | line 19: `backJump, listRowFor, offeredItems, parentJump, replyBack, shortcutFor, shortcutItem, shortcutsOn` |
| `wc -l src/utils/msg-shortcuts.mjs` | 458 |
| `git grep -l "utils/msg-shortcuts.mjs" tests/unit` | `msg-shortcuts.test.mjs` |
| `git grep -l "useMsgShortcuts" tests/unit \| wc -l` | 0 |

Verdict: **agree with changes**. The shortcut dictionary and matching logic
already live in `msg-shortcuts.mjs`, which is 458 lines and tested, so "a pure
helper under 200 lines" contradicts the code. What has no test is the
composable's own keydown dispatch (0 test files name it). Change the target to:
**move the dispatch decisions (key + state -> action) out of the composable
into a `.mjs`, with a new test of that function. Target
`useMsgShortcuts.ts <= 250` lines, and a mutation of one moved branch must turn
the new test red.** Do not grow `msg-shortcuts.mjs` past its 458 lines; put the
moved code in a new file.

### 2.4 Row 06: `usePaneWidths.ts`

| command | output |
|---|---|
| `wc -l src/composables/usePaneWidths.ts` | 314 |
| `sed -n '2,24p' src/composables/usePaneWidths.ts \| grep "from '"` | `} from '~/utils/pane-widths.mjs'` |
| `wc -l src/utils/pane-widths.mjs` | 307 |
| `git grep -l "utils/pane-widths.mjs" tests/unit` | `pane-widths.test.mjs` |
| `git grep -l "composables/usePaneWidths.ts" tests/unit \| wc -l` | 2 |
| `grep -cE '^\s*(export )?function' src/composables/usePaneWidths.ts` | 23 |

Verdict: **disagree**. The clamping and ratio math is already the 307-line
tested `pane-widths.mjs`. The composable is 23 small functions of state and
persistence, none of them longer than the 80-line function gate allows
(`node tests/unit/cleancode.test.mjs` -> rc 0, `LONG` empty). The marginal
gain is the lowest of the ten rows. **Replace with P3.**

### 2.5 Row 07: `useScrollAnchor.ts`

| command | output |
|---|---|
| `wc -l src/composables/useScrollAnchor.ts` | 293 |
| `wc -l src/utils/scroll-anchor.mjs` | 117 |
| `git grep -l "utils/scroll-anchor.mjs" tests/unit` | `newest-live`, `thread-jump`, `view-prefs` |
| `grep -nE "^function after" src/composables/useScrollAnchor.ts` | `179 afterPatch(a, next: string[], prev: string[])`, `194 afterPrepend(a, b, prev, next)`, `210 afterAppend(a, b, prev, next)` |

Verdict: **agree with changes**. A line target ("<= 150") is the wrong
measure, because the offset math is already in `scroll-anchor.mjs`. The
untested decisions are the three `after*` functions, which compare `prev` and
`next` row-key lists. Change the target to: **split the key-list decision
(which row to hold, whether to stick to the bottom) out of the three `after*`
functions into `scroll-anchor.mjs` as pure functions, with tests for prepend,
append and patch. Red control: mutate one decision and a new test turns red.**

### 2.6 Row 08: `useSubmitKey.ts`

| command | output |
|---|---|
| `wc -l src/composables/useSubmitKey.ts` | 42 (plan: 43) |
| `git grep -l "useSubmitKey(" tests/unit \| wc -l` | 0 |
| `git grep -l "useSubmitKey" tests/unit` | `submit-key.test.mjs` |
| `grep -cE "^\s*it\(" tests/unit/submit-key.test.mjs` | 16 |
| `git grep -hoE "from '[^']*\.ts'" tests/unit \| wc -l` | 0 |
| `node --version` | v20.19.2 |

Verdict: **agree with changes**. The plan's count is right, but the row cannot
be built as written. No unit test imports a `.ts` module (0 of 379 files), and
node v20.19.2 cannot load one that depends on `~/` aliases and Nuxt
auto-imports (`computed`). The key logic is already in `utils/submit-key.mjs`
and covered by 16 tests. The one untested piece of logic is `hintFor`, a 3-line
mode-to-key rule. Change: **move it into `submit-key.mjs` as a pure
`submitHintFor(mode, base)`, keep `hintFor` as a one-line wrapper so the
composable's API does not change, and test it in `submit-key.test.mjs`. The
plan's red control (mutate `hintFor`, the test turns red) still holds.** The
API must stay fixed because `MessageComposer.vue` (row 03, lane 1) and
`ChannelSidebar.vue` (row 02) call it.

### 2.7 Row 09: `poll-fence.mjs`

| command | output |
|---|---|
| `wc -l src/utils/poll-fence.mjs` | 15 |
| `git grep -l "poll-fence" tests/unit \| wc -l` | 0 |
| `grep -n "poll-fence" src/utils/poll.mjs` | `53:export { mayHavePoll } from './poll-fence.mjs'` |
| `git grep -n "mayHavePoll" tests/unit/poll-control.test.mjs` | lines 11, 77, 78, 79, 169 |

Verdict: **agree with changes**. The plan's grep is a filename probe, and it
misses that `mayHavePoll` is re-exported by `poll.mjs` and asserted in
`poll-control.test.mjs:77-79`, with one true and one false case. Change: **the
new `poll-fence.test.mjs` adds only the edge cases those 2 asserts do not hold:
a 4-backtick fence, a trailing tab or space, CRLF, a fence at the end of the
body, and `null` or empty input. The red control is the regex mutation; the
`0 -> 1` file count is not a red control.**

### 2.8 Row 10: `editMode.ts`

| command | output |
|---|---|
| `wc -l src/stores/editMode.ts` | 12 |
| `git grep -l "editMode" tests/unit \| wc -l` | 0 |
| `git grep -l "useEditModeStore\|isEditing" -- src` | `TopBar.vue`, `WorkspaceDocView.vue`, `editMode.ts` |

Verdict: **disagree**. The store is one `ref` and one setter that assigns it. A
test of it asserts that assignment works, and no mutation a reviewer would make
is caught that typecheck does not already catch. It is the lowest-value row.
**Replace with P1.**

## 3. Proposals the plan missed

### 3.1 P1: SFC `<script>` size ratchet (replaces row 10; kind `tests`)

| command | output |
|---|---|
| `for f in $(git ls-files 'src/**/*.vue' 'src/*.vue'); do echo "$(sed -n '/<script/,/<\/script>/p' $f \| wc -l) $f"; done \| sort -rn \| awk '$1>500' \| wc -l` | 7 of 257 SFCs |
| same, the 7 | `issues.vue` 2084, `MessageCard.vue` 1416, `MessageComposer.vue` 1135, `ChannelSidebar.vue` 1007, `WorkspaceDocView.vue` 678, `QtoFileTree.vue` 654, `CalendarMainView.vue` 612 |
| `sed -n 26,37p tests/unit/cleancode.test.mjs` | `MAX_LINES = 80` per function, `LONG` empty: there is no limit on the size of a file or a `<script>` block |

Action: a new `tests/unit/sfc-script-size.test.mjs` (a new file, so no lane
shares it) with `MAX_SCRIPT = 500` and a ceiling map of today's 7 SFCs at their
current counts. A new SFC over 500 fails; a listed one that grows past its
ceiling fails; one under its ceiling is reported, the same design as `LONG`.
Rows 01-03 and P2 do not edit it. The closing retro lowers the 4 ceilings,
which gives those rows a red control that outlives the lane. **Red control:**
plant 501 lines in a scratch SFC and the test turns red; remove them and it
turns green. **Place it first in lane 2**, before row 02, so every
decomposition lands under the gate.

### 3.2 P2: decompose `pages/issues.vue` (replaces row 04; kind `complex_coding`)

| command | output |
|---|---|
| `sed -n '/<script/,/<\/script>/p' src/pages/issues.vue \| wc -l` | **2084**, the largest `<script>` in the WUI and larger than rows 01 and 02 combined |
| `grep -n '<script\|</script>' src/pages/issues.vue` | `1161:<script setup lang="ts">`, `3244:</script>`; file 4108 lines |
| `git grep -l "pages/issues.vue" tests/unit \| wc -l` | 19 |
| `git log --since=2026-10-09 --oneline -- src/pages/issues.vue \| wc -l` | 18, the busiest of the four big SFCs |
| `grep -oE "from '~/composables/[^']+'" src/pages/issues.vue \| grep -E 'MobileStack\|SubmitKey\|MsgShortcuts'` | `useMobileStack`, `useMsgShortcuts`, `useSubmitKey` |

Action: extract the board, column and drag concerns out of the `<script>` of
`issues.vue` (`1161-3244`) into composables or subcomponents. The target is
`<= 1200` script lines in this round, not 500: at 18 commits in 7 days the
page is a live feature surface, and one lane cannot safely take it down to 500.
Test column: the 19 source-reading tests, with their asserts re-pointed and the
same count check as rows 01-03. The P1 ceiling locks the result. **R1:** it
imports the composables of rows 05 (lane 1) and 08, so P2 must not change their
APIs. It runs on lane 2 after row 02.

### 3.3 P3: no-unused-export gate (replaces row 06; kind `simple_coding`)

| command | output |
|---|---|
| for each `^export (async )?(function\|const\|class) <name>` in `src/composables/*.ts`, `src/utils/*.{mjs,ts}`: `git grep -lw <name> -- src tests nuxt.config.ts`, excluding the defining file | **87** exports, in 49 files, have no user outside their own file |
| total exports scanned | 2465 |
| top files | `utils/perf-rum.mjs` 12, `utils/act-as-mock.mjs` 7, `utils/omnibox-dock.mjs` 6, `utils/mock-data.mjs` 4, `utils/calendar-swipe.mjs` 4 |
| `git grep -nw useRealmHours -- .` | 1 hit, its own definition: a 99-line composable with no caller (spec 118 lists it, `specs/118-multi-workspace-hours/tasks.md:188`) |

Action: a new `tests/unit/unused-exports.test.mjs` that fails on an export
with no importer outside its file, with an allow-list of today's 87 that may
only shrink. In this row, drop the `export` keyword (or delete the dead code)
in the top 5 files only (33 entries), to stay inside the max-5-sites rule.
`useRealmHours` stays listed: whether to wire it or delete it is spec 118's
call, not this round's. **Red control:** add an unused `export const` and the
test turns red. None of the 49 files is a row 01-09 site (checked against
`useMobileStack`, `useMsgShortcuts`, `usePaneWidths`, `useScrollAnchor`,
`useSubmitKey`, `mobile-stack`, `msg-shortcuts`, `pane-widths`,
`scroll-anchor`, `poll-fence` and `submit-key`: 0 matches).

Measured but not proposed: `composables/useMove.ts`, 253 lines with 0 test
files naming it (`git grep -l useMove tests/unit | wc -l` -> 0). Its logic is
already in `utils/move-apply.mjs` (388 lines, 4 test files), so it ranks below
P1-P3.

## 4. R1 and the 2-lane check

| check | result |
|---|---|
| every batch holds >= 2 rows | yes: 5 batches of 2 (plan 3.1) |
| no path in two rows of one batch | yes for the files each row names |
| **lanes run asynchronously** | when row 01 lands, row 03 starts beside whatever lane 2 is on (plan 3.1). So R1 has to hold for **every pair of an odd row and an even row**, not only within a batch. |
| odd vs even overlap | row 04 (lane 2) owns `useMobileStack.ts`, which rows 01 and 03 (lane 1) call: an API change there edits lane 1's files. Row 08 (lane 2) owns `useSubmitKey.ts`, which row 03 (lane 1) calls. |
| with the changes above | dropping row 04 removes the first overlap; row 08 keeping its API removes the second. P1 adds one new test file only; P3 adds one and edits 5 source files that are outside every row. |

Suggested lanes, if P1-P3 are taken:

- **Lane 1:** 01 -> 03 -> 05 -> 07 -> 09
- **Lane 2:** P1 -> 02 -> P2 -> P3 -> 08

Vendor mix after the swap: claude 7 (01, 02, 03, P2, 08, 09, P1), simple
coding 3 (05, 07, P3). R7 cross-vendor review is unchanged.

## 5. Signature

`signed: c-243@sat on 1a1e01c8433af5a974f6ffd0c698e22bd8ce2401` (plan v1.0; rows unchanged from v0.4 `5356c84d5`, checked with `git diff 5356c84d5 1a1e01c84 -- csi-spl-doc/doc/md/refactor-round-13-plan.md`)
