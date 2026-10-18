# Issues multi-select and UI panel: claude reviewer seat

Epic: SPL-2403
Spec: csi-spl-doc/specs/039-spool-issues
Issue: SPL-2498 (this seat), plan issue SPL-2497
Plan reviewed: `csi-spl-doc/doc/md/issues-multiselect-panel-plan.md` v0.1, landed at `64121900d`
Seat: claude, `c002-issues-multiselect-panel-seat-claude` (agent c-435@sat)
Task: `dispatch-405e08ba`

**Verdict on v0.1: CHANGE.** The root cause of the round boxes is right and
measured, and the owner's three points (square boxes, placement, less space)
each have a row. But the plan misses the biggest phone defect (the list
jumps 88 px when the first box is ticked), one proposed space saving puts
the box's tap area over the card text, five statements about today's code
are wrong, and rows 04, 06, 07 and 09 have no red control that fails on
master. Fold section 4 and I sign v1.0.

## 1. What I re-measured, and how

Served: dev `build.json` -> commit `51009ada4`, version 2.1.8, the plan's
pin. Signed in as the dev probe member (`t1`), headless Chrome, dark theme,
25 issues listed at each width. Script, `r.json`, `shift.json` and 8
screenshots: `/var/spool-hub/dispatch/405e08ba/work/seat-claude/` (not in git).

| number in the plan | plan | mine (n) | verdict |
|---|---|---|---|
| phone box `::before` size and radius | 16x16, 8px | 16x16, `8px` (n=1; ticked boxes too) | agree |
| phone header stack, mbar + chips | 52 + 52 = 104 | 52 + 52, top 119 -> 223 (n=1) | agree |
| phone card `padding-inline-start` | 44 px | `44px`; top, title, meta all start at x=44 (n=1) | agree |
| phone card box hit area | 44x44 | 44x44 (n=1) | agree |
| phone bulk bar | 412x88, 6 buttons 44x44 | 412x88, 6 buttons 44x44 (n=1) | agree |
| desktop row box | 16x16 native, radius 0 | 16x16, `appearance: auto`, `0px` (n=1) | agree |
| desktop bulk bar | 1013x69 | 1013x69, 6 buttons 95..128 x 44 (n=1) | agree |
| desktop filter selects | 31 vs 36 px | not reproduced: the visible filter-row controls measure 34 px (x5), 24 and 44 (n=1) | change the number |
| detail tabs, phone | underline 2px, top 0 | underline 2px; the clip control (`radiogroup`) sits **inside** `role=tablist` (n=1) | agree |

Bulk action run: phone, 412x915, ticked SPL-47 and SPL-46 (both `02-todo`),
bulk Status -> `todo`. The bar read "Done: 2 of 2." after 2.7 s and both
stayed `todo` (a deliberate no-op on the data, n=1).

I did not open the desktop issue modal (a row click did not open it in my
script), so I have no desktop number for tabs or header actions.

## 2. What the plan does not have yet

1. **The list jumps 88 px on the first tick.** Card tops 223/352/481 before
   the first tick, 311/440/569 after (n=3, identical each time): the bulk bar
   is inserted above the "Sorted" line instead of taking the header's place,
   so the row under the thumb moves away. In my first run, three taps 250 ms
   apart registered 2 of 3 (n=1, cause not proven); 800 ms apart, 3 of 3
   (n=3). The Gmail mobile list that the code comments cite swaps its top
   bar for the selection bar in place. On the phone this is the biggest
   "manipulate multiple items" defect, and it needs a row.
2. **The unticked box and the status glyph look the same.** In
   `phone-selected.png` each card has a hollow ring at x~20 (the box) and
   another hollow ring before `02-todo` (the status) on the line below. That
   is why the owner reads them as radio buttons. So the square must look
   unlike the status glyph; a smaller radius alone is not enough.
3. **The active tab underline is not the accent colour.**
   `issues.vue:3851` uses `var(--accent, currentColor)`, and `--accent` is
   defined nowhere (`grep -c -- '--accent:' csi-spl-wui/src/assets/css/variables.css`
   -> 0), so the marker is the text colour: measured `rgb(234, 242, 255)`,
   the tab's own `color`. Row 03 should replace it with `--color-accent`,
   which exists.

## 3. Wrong statements about today's code

| plan says | measured | fix |
|---|---|---|
| empty states read "No issues found" / "No comments yet" | `issues.empty` = "No issues match.", history "No history yet." (`grep -n '"empty"' csi-spl-wui/i18n/locales/en.json`) | quote the real keys |
| "hide [the shortcuts line] on mobile" | already `v-if="!phone"` (`issues.vue:90`); the desktop line is 1013x26 | drop the phone half of the item |
| row 07 site `IssueDetailFrame.vue:1-80`, "metadata panel" | the file is 30 lines, a modal/aside wrapper with only a slot (`wc -l` -> 30) | point at the detail markup in `issues.vue` |
| R14 makes WUI coding claude-only | R14 is about vendor reliability; the WUI rule is in the [developer guide](../developer-guide.md), section 4.1 | cite 4.1 |
| row 04 red control: the clip control gets role `radiogroup` | it already has that role on master (`CardClipControl.vue:12`), so the test passes today | assert "no `[role=radiogroup]` inside `[role=tablist]`" (true today) |

## 4. Per row

| # | verdict | what to change |
|---|---|---|
| 01 square box | **agree, with** | Make the unticked square look unlike the status ring (2px `--color-border-strong`; a 3px radius is fine). Red: `::before` radius `8px` today. |
| 02 space | **change** | Keep the 44x44 hit box but do not let it cover text: a 32 px gutter with a 44 px hit box covers x 32..44 of the card's top line (key, status). Either keep the 44 px gutter and save the space vertically (mbar + chips from 104 to <= 80 is fine), or move the box into the card's top line beside the key. Red: header stack 104 today, target <= 80. Guard: `elementFromPoint(card left + 50, card top + 22)` is never the checkbox. |
| 03 3D tabs | **agree, with** | Use `--color-accent` for the top marker (section 2.3). Only `--color-*` tokens, no `rgba(...)` literals in the box-shadow. Red: the active tab's `border-top-width` is 0px today. |
| 04 clip control | **change** | Red control as in section 3. Measure: `.card-clip-ctl` `closest('[role=tablist]')` -> null. |
| 05 bulk bar | **change** | Target no layout shift: card 1's top within 1 px before and after the first tick (88 px today), and the bar <= 56 px high on the phone. This is the row for section 2.1. |
| 06 header actions | **change** | "consistent border, focus rings" cannot be measured. Measure the modal first, then name the buttons and one number each (same height, same gap). |
| 07 detail hierarchy | **reject as written** | Wrong file, and `pnpm run typecheck` is not a red control. Re-scope it after a measured audit of the detail page, or drop it from this round. |
| 08 desktop sheet | **agree, with** | One height for the filter-row controls (34, 24 and 44 px today, n=1). Red: more than one distinct height today. |
| 09 empty states | **change** | No mascot image (the no-images rule, extra bytes): use a `UiIcon` and the real i18n keys in every locale. Red: `[data-test=issues-empty]` has no icon today. |
| 10 e2e suite | **change** | Rows 01..04 cite `tests/e2e/issues-multiselect.test.mjs` and `issues-detail-tabs.test.mjs`, which do not exist (`ls csi-spl-wui/tests/e2e \| grep issue`). Each row should ship its own red test, because a separate tests-only lane would land red tests on trunk. Fold the tests into their rows and drop row 10. |

Batching: rows 01, 02, 03, 08 and 09 all edit `pages/issues.vue` (4142
lines), so five serial lanes queue on one file. Rows 01 and 02 touch the
same CSS block and can be one row.

## 5. Review of v1.0 (`d2924ba27`)

**Verdict on v1.0: CHANGE, three small fixes, then I sign.** Most of my
points are folded: the square with a 2px `--color-border-strong` border, the
44 px gutter with the space saved vertically, the zero-shift target, the
`--color-accent` marker, the tablist red control, the 36 px filter height,
`UiIcon` empty states, and tests inside their rows. Three things are still
wrong, each checked on `origin/master` (`48ad0e912` for `issues.vue`):

| # | v1.0 says | measured | fix |
|---|---|---|---|
| 1 | Row 05: Esc clears the selection; red control "Escape with a selection resets it to 0" | already on master: `onDocKey` in `issues.vue` runs `else if (selected.value.length) clearSelection()` on Escape, with no phone gate, and the block comment above `const selected` says "Esc clears". The red control passes today. | drop row 05, or re-scope it to something that fails on master |
| 2 | Row 02 edits only `IssuesBulkBar.vue` (sites 11-56, 108-140) | the bar's place in the page is `issues.vue` (the `issues-bulk-host` `v-if="bulkOn"` block at lines 10-30), and that block is what pushes the list down. `IssuesBulkBar.vue` has 123 lines, so 108-140 runs past its end. | add `issues.vue` to row 02's sites, and run batch 2 after batch 1 (both edit `issues.vue`, which R1 forbids in parallel) |
| 3 | 5.1 box-shadow `var(--color-shadow, rgba(0, 0, 0, 0.12))`, "no raw `rgba()`" (3.5) | `variables.css` defines no shadow token at all (`grep -oE -- '--[a-z-]*shadow[a-z-]*:'` -> nothing), so the `rgba` fallback is what renders | define the token in `variables.css` for every theme in row 03, or drop the shadow |

Nit, not blocking: row 09 names the history key `history.empty`; the key
is `issue_history.empty`.

## 6. Review of v1.1 (`52121d356`)

**Verdict on v1.1: GOOD.** Checked with `git diff d2924ba27 52121d356`:

1. Row 05 (Esc) is dropped (section 3.8), leaving 8 rows.
2. Row 02's sites now include `issues.vue:10-35` (the bulk host) and
   `IssuesBulkBar.vue:11-56, 108-123`, and batch 2 lands after batch 1.
   Every `issues.vue` batch (1, 2, 3, 4, 6, 7, 8) is serial, so R1 holds.
3. Row 03 defines `--color-shadow` in `variables.css` for every theme, and
   section 5.1 uses `var(--color-shadow)` with no `rgba` fallback.
4. Row 08 names `issue_history.empty`.

Not a blocker: the `<kbd>` chips in audit item 8 have no build row. They are
a candidate for a later round.

## 7. Signature

**Signed: claude seat (c-435@sat) signs plan v1.1 at `52121d356`.**
Consensus allows the 8 build rows to be placed.
