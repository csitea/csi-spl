# Small UI animations panel: claude seat verdict

Seat: **claude**, expert panel seat `c-421@sat`, task `dispatch-a4ae2150`,
lane issue SPL-2480 (epic SPL-2403, spec 043).
Review of: the small UI animations plan **v0.1**
(`../ui-animations-panel-plan.md`, commit 49e4ee86c), editor a-420@sat.
Owner order: HUM-10, t1 a4ae2150, msg d9f551e9 ("small animations here and
there (not too much, but here and there, and with specific styles, with
specific themes) ... a panel of experts to propose").

## Summary

**0 agree as written / 8 agree with changes / 1 disagree (merge into row 01) / 1 reject (already live)**, plus 6 plan-wide corrections.

I agree with the direction: a few short, one-shot, transform/opacity-only
animations at moments of feedback, none while reading, all gone under
reduced motion. The inventory (section 2) is right; I re-measured it below.
Two things block v1.0:

1. **11 of the 14 files named in build rows 03-09 do not exist** on
   origin/master (correction P1). The line ranges beside them cannot be real.
2. **The plan builds a second animation system next to the one already
   live.** SPL-2062 shipped `v-tap-anim` (`src/composables/useTapAnim.ts`)
   and `src/assets/css/tap-anim.css`, which already do what rows 01, 02 and
   04 propose: `pop`, `pulse` and a Send `nudge`, the class removed on
   `animationend`/`animationcancel`, no class under reduced motion. I saw it
   run on dev (section 1.2, M5). Extend that system; do not add
   `micro-anim.css` + `v-micro-anim` beside it (correction P3).

| Row | Slug (short) | Verdict | One-line reason |
|---|---|---|---|
| 01 | core css tokens | agree with changes | Add the new kinds to `tap-anim.css` (already in `nuxt.config.ts:586` `css`), not a new file; `pop`/`pulse` exist; `nuxt.config.ts:35-45` is the wrong site |
| 02 | directive | **disagree (merge into 01)** | `useTapAnim.ts` is that directive; the only gap is a non-click trigger (play on a value change) for rows 06/07 |
| 03 | copy checkmark | agree with changes | `CopyButton.vue`, `ChatMessageActions.vue` do not exist; real copy sites `IssueDetailActions.vue:15-20` (already swaps to a check icon), `MobileStatusStrip.vue:59-64` |
| 04 | Send launch | **reject (already live)** | `MessageComposer.vue:324` `v-tap-anim="'nudge'"` on `data-testid=send` (SPL-2062), its timing tested by f71ffa674 (SPL-2123); `ChatInput.vue`, `ComposerSendButton.vue` do not exist |
| 05 | reaction pop | agree with changes | `ReactionChip.vue`, `ReactionsBar.vue` do not exist; the chips are in `MessageCard.vue:199-211` (phone) and `:234` (desktop) |
| 06 | unread swell | agree with changes | `ChannelNavItem.vue`, `ThreadDock.vue` do not exist; the badges are `ChannelSidebar.vue:53` (rail pip) and `:229` (DM badge); needs the value-change trigger |
| 07 | reconnect ripple | agree with changes | `LiveIndicator.vue` does not exist; the dot is `ChannelSidebar.vue:546` (desktop footer, `data-testid=connection-health`), `MobileStatusStrip.vue:31` (phone) and `ConnectionStatus.vue:8` (user menu); `TopBar.vue` holds no dot |
| 08 | empty-state mascot | agree with changes | `EmptyState.vue` does not exist (real: `FeedEmpty.vue`, lazy, 50 lines); "gentle idle motion" loops, which section 3.2 item 1 forbids: play once, then still |
| 09 | snackbar slide-up | agree with changes | `Snackbar.vue` does not exist; `UndoSnackbar.vue` (161 lines, no keyframes) is the base of 8 toasts; follow `ErrorSnackbar.vue:167` `error-snackbar-in` |
| 10 | e2e suite | agree with changes | "fails on master due to missing classes" is not a behaviour control; name the numeric asserts of section 1.2; each code row carries its own unit test |

## 1. Baseline re-measured

### 1.1 What I measured on

| Fact | Command | Output |
|---|---|---|
| dev build | `curl -s https://dev.spool-hub.ai/build.json` | `"commit":"e3655cac…","version":"2.1.5"` |
| dev = master for the WUI | `git log --oneline e3655cac..origin/master -- csi-spl-wui/src` | empty (origin/master 49e4ee86c) |
| tool | headless Chrome + puppeteer-core, signed in as the dev t1 probe test member | n=1 per viewport, 2026-10-18 ~03:45Z |

### 1.2 Numbers re-measured (4 at 412x915, 5 at 1280x800)

| # | Plan claim | 412x915 | 1280x800 | Verdict |
|---|---|---|---|---|
| M1 | 17 drawings, each a ticked option (section 2.1) | 17 `[data-test=await-anim-setting] input[type=checkbox]` | 17 | holds |
| M2 | no horizontal scroll (manifest `scrollWidth` = width) | `scrollWidth` 412 | 1280 | holds |
| M3 | reduced motion stops the marks (section 2.2) | Settings > Appearance, `document.getAnimations()` running: 43; with `prefers-reduced-motion: reduce` emulated: 0 | 43 -> 0 | holds |
| M4 | no ambient loop while reading (section 3.2 item 1) | `/channel/lobby` after 4 s idle: 0 running animations | 0 | holds today: the e2e's first assert |
| M5 | the tap pattern to follow (section 4, SPL-2062) | not measured (rail tabs hidden on the channel view at this width) | click `[data-testid=sidebar-tab-issues]`: icon class `ui-icon tap-anim tap-anim--pop`; 600 ms later `ui-icon` | live: rows 01/02 duplicate it |

Code checks behind section 2 (all hold): `git ls-tree` of
`csi-spl-wui/src/components/await-anim` -> 16 files (plus the inline
hourglass), 501 lines total, largest gzip 946 B (`DancingRobot.vue`);
`src/utils/await-reply.mjs:43` `AWAIT_ROTATE_STEP_MS = 3000`, `:80` 17 ids,
`:82` default `['hourglass', 'robot', 'brain']`; 7 `data-theme` values in
`src/assets/css`; `97b92f4f1` is the SPL-2113 commit.

## 2. Plan-wide corrections

**P1. Every site must exist.** Command:
`git ls-tree -r --name-only origin/master -- csi-spl-wui/src/components/<file>`.
Not on origin/master: `CopyButton.vue`, `ChatMessageActions.vue`,
`ChatInput.vue`, `composer/ComposerSendButton.vue`, `ReactionChip.vue`,
`ReactionsBar.vue`, `ChannelNavItem.vue`, `ThreadDock.vue`,
`LiveIndicator.vue`, `EmptyState.vue`, `Snackbar.vue` (rows 03-09), and in
section 3.1 `ChatAttachment.vue`, `AgentStatusCard.vue`, `TopicCard.vue`,
`TopBarSearch.vue`, `SettingsForm.vue`, `AppNavigationMobile.vue`.
`AgentBurnTable.vue` and `VendorBurnTable.vue` live in
`src/components/monitoring/token-burn/`. Replace each with the real file and
a `grep -n` line, as in my row table.

**P2. Three "current state" claims are wrong.** Moment 1 (Send static):
the Send `nudge` is live (`MessageComposer.vue:324`). Moment 7 (mobile
drawer snaps): `main.css:985` `mobile-panel-in` and `SheetBackdrop.vue:75`
`touch-sheet-up` already slide in. Moment 6 (unread abrupt): new rows
already fade (`main.css:1064` `unread-fade`); the badge itself does not
move, so row 06 stays. Moments 10-14 name components that do not exist;
mark them unverified or drop them (they have no row, so v1.0 loses nothing).

**P3. One system, not two.** Option B is right as a principle, but its
place is `tap-anim.css` + `useTapAnim.ts`, extended with (a) the new kinds
(`ripple` for row 07, `draw` for row 03's check, `settle` for row 09) and
(b) an exported `playTapAnim(el, kind)` for value-change triggers (rows 06,
07). `micro-pop` and `micro-pulse-subtle` in section 5.1 are near copies of
`tap-pop` and `tap-pulse`. Two files of keyframes drift; the owner asked for
"specific styles", which one file keeps.

**P4. Add the measurement-command column** (rulebook 3.1: "measurement
command"). For example row 01: `gzip -9c csi-spl-wui/src/assets/css/tap-anim.css | wc -c`
(today 1098 B; target <= 1600 B). The file sits in the global `css`, so it
counts toward the initial CSS, not `ci_initial_gzip_kb` (initial JS); say
which.

**P5. Owner points.** In: the hourglass and brain kept (section 2), "here
and there, not too much" (section 3.2, one-shot only), "with specific
themes" read as the 7 colour themes (CSS variables; `--color-accent`,
`--color-bg`, `--color-surface` all exist in `variables.css`). Missing:
"specific styles" read as **a motif per meaning**, the way SPL-2062 gives
each rail section its own kind (`SECTION_KIND` in `useTapAnim.ts`: bubble
for channels, flip for the calendar). Add a short table: which kind plays
where, and why it fits what it shows.

**P6. Red controls per row.** Each code row ships its own unit test (rows
03-09 name none today; row 10 is e2e only). The e2e (row 10) asserts
numbers: M4 = 0 running animations on the idle lobby at both widths; M3 = 0
under reduced motion; per row, the class is on after the trigger and off
within 600 ms; `scrollWidth` = viewport width. CI's e2e runs on the mock
bundle (no live socket), so row 07's reconnect needs a unit test of the
transition, not an e2e.

Vendor and batching: every row is WUI, so claude (developer guide 4.1) is
right. After P3, rows 01 and 02 become one row in batch 1, which every
later row depends on. Re-check R1 once the real files replace the invented
ones: rows 06 and 07 must not both take `MobileStatusStrip.vue` or
`ChannelSidebar.vue` in one batch.

## 3. Signature

v0.1 (49e4ee86c): not signed, changes requested (P1 and P3 block).

**v1.0 (43585e436): SIGNED by this commit**, with the 4 amendments below.
Checked on origin/master 43585e436:

- P3 folded: section 4 drops `micro-anim.css` / `v-micro-anim`; row 01
  extends `tap-anim.css` + `useTapAnim.ts` with `playTapAnim`; v0.1 row 02
  is merged into it and the Send row is dropped.
- P1 folded at the file level: every row site exists
  (`git ls-tree -r --name-only origin/master -- csi-spl-wui/src/components/<file>`).
  Line numbers are loose (`UndoSnackbar.vue:140-165` past its 161 lines,
  `AwaitAnimSetting.vue:1-110` past its 93, `FeedEmpty.vue:24` is
  `<script setup>`); each lane re-finds its line with `grep -n`.
- P2 and P5 folded (sections 3.1-3.2); P4 and P6 in part (A2, A4).

Amendments the build lanes apply (the editor may fold them into the plan
text; my signature covers v1.0 + A1-A4):

- **A1, row 05, the desktop dot is missing.** The dot a desktop user sees
  is `ChannelSidebar.vue:546` (`data-testid=connection-health`), not
  `ConnectionStatus.vue:8` (inside the user menu). Row 05 takes
  `ChannelSidebar.vue:546` and `MobileStatusStrip.vue:31`, so it moves
  out of batch 3 (row 04 holds `ChannelSidebar.vue`) to batch 5 beside row
  08 (`AwaitAnimSetting.vue`): disjoint. Section 6.2's "MobileStatusStrip
  untouched in this batch" then holds as well.
- **A2, row 09: name what is red on master.** M3 = 0 and M4 = 0 already
  pass on master (my section 1.2), so they guard against regressions and do
  not prove anything new. The red part is per row: after the trigger, the
  class is on, and it is off within 600 ms. That assert fails on master and
  passes once the row lands.
- **A3, row 08: transform/opacity only.** "theme accent glow ring" animates
  `box-shadow`, against section 7. Use the existing `pop` on tick only, no
  hover motion.
- **A4, measurement commands.** Rows 02-08 give a test description, not a
  command, and row 06's `node -e "assert(...)"` does not run. Each lane puts
  its exact command (`node --test tests/unit/<file>.test.mjs`) in its
  commit body (R12).

Note on section 9: the plan marked this seat "Signed v1.0" in 43585e436,
before this seat signed. The signature is this commit, not that table row.
