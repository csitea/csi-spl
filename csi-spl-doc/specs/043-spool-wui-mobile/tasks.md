# Tasks: 043 The WUI on Phones and Small Tablets

**Spec**: `spec.md` · **Epic**: SPL-988 · **Lead + verifier**: CLE-35022
Five lanes run in parallel, each in its own worktree. A lane edits ONLY the files it owns (§1). To change another
lane's file, ask its owner by peer message. For i18n, a lane adds keys only in its own namespace, and on a conflict
in the locale files it keeps both sides.

## 1. File ownership (CLE-001's map, extended 08:19Z)

Paths are under `csi-spl-wui/src/`.

| lane | issue | agent | owns |
|---|---|---|---|
| M1 nav shell | SPL-989 | CLE-35024 | `layouts/default.vue`, `app.vue`, `ChannelSidebar.vue`, `PaneDivider.vue`, `pages/index.vue`, `pages/lobby.vue`, `pages/channel/[name].vue`, `pages/dm/[peer].vue`, `pages/t/[task_id].vue`, `TopicPane.vue`, `LiveTopicPane.vue`, `FeedHeader.vue`, `CardClipControl.vue`, `assets/css/main.css` + `base.css` (breakpoint tokens), `composables/useMobileStack.ts`, `utils/mobile-stack.mjs` |
| M2 top bar | SPL-990 | CLE-35025 | `TopBar.vue`, `UserMenu.vue`, `NotificationCenter.vue`, `LanguageSwitcher.vue`, `ThemeToggle.vue`, `nuxt.config.ts` (viewport meta), `public/manifest.webmanifest`, `public/sw.js` |
| M3 messages + composer | SPL-991 | CLE-35026 | `MessageComposer.vue`, `MessageCard.vue`, `MessageMenu.vue`, `MessageBody.vue`, `MessageFeed.vue`, `MessageRuns.vue`, `EmojiPicker.vue`, `MentionList.vue`, `FileAttachment.vue`, `SidebarRowMenu.vue`, `CodeBlock.vue`, `CodeViewer.vue`, `CodeLines.vue`, `KindPicker.vue`, `KindBadge.vue` |
| M4 issues | SPL-992 | CLE-35027 | `pages/issues.vue`, `IssueEpicsPanel.vue`, `IssueDescription.vue`, `IssueSubtaskDialog.vue`, `DeadlinePicker.vue`, `IssueGlyph.vue` |
| M5 settings, dialogs, pages | SPL-993 | CLE-35028 | `pages/settings.vue`, `SettingsSection.vue`, every `*Setting.vue`, `UiDialog.vue`, `ChannelPropertiesDialog.vue`, `TopicDeleteDialog.vue`, `ChannelDeleteDialog.vue`, `pages/archive.vue`, `pages/events.vue`, `pages/search.vue`, `pages/users.vue`, `UserEditPane.vue`, `layouts/login.vue`, `pages/login.vue` |
| lead + verifier | SPL-988 | CLE-35022 | this spec, `analysis.md`, `tests/e2e/mobile-audit-live.proof.mjs`, the scoreboard in the topic |

Shared contracts, published by their owners and never re-implemented:
- `useMobileStack()` (M1): `isMobile`, `level`, `push(2)`, `pop()`, `home()`, `rightPanel(open, close)`.
- The composer dock (M3): `MessageComposer` docks at the bottom when the page has a send target and publishes
  `--composer-dock-h`; `--kb-inset` is the keyboard height. M1's scrolling panes pad by both.
- The search sheet (M2) mounts the composer with `:dock="false"`.

## 2. Phase 1: the stack (M1 first; the others build on it)

- [x] T001 [M1] `useMobileStack` + `utils/mobile-stack.mjs` + unit tests (`f35dca1c`)
- [x] T002 [M1] `rightPanel(open, close)` for level 3 without a topic store (`558f3e03`)
- [x] T003 [M1] `data-mobile-level` on `.spool-shell`; one panel visible per level at <= 820 px (FR-001) (b8c264de; lead scoreboard 1: one panel at 360-820 on dev + prd)
- [x] T004 [M1] level 1: the 44 px icon+label section strip on top, the full-width list with names (FR-002, D1) (b8c264de; lead scoreboards 1-2: level 1 = named strip + list, 360-820)
- [x] T005 [M1] a back arrow in FeedHeader / TopicPane / LiveTopicPane; a right swipe from the edge; the slide (FR-003, N4) (b8c264de, ef3dbffa; walk 1>2>3>2>1 by browser Back ok at 360-820 dev + prd; slide = main.css mobile-panel-in, off under reduced motion; the swipe is not measured by the lead)
- [x] T006 [M1] CardClipControl always visible, 44 px (FR-006) (b8c264de; lead scoreboard 2: 0 hover-only controls)

## 3. Phase 2: the lanes in parallel

- [x] T010 [M2] the one-row top bar (back, tenant, search, avatar) at <= 820 px (D5) (300cfa42; Back is M1's MobileBack in each pane header, not a top-bar button)
- [x] T011 [M2] search as a full-screen sheet; the avatar menu as a bottom sheet (language, theme, notifications, settings, sign out) (300cfa42; prd e2e live proof 11/11, 3ff536ff + 917b5f8e)
- [x] T012 [M2] `viewport-fit=cover`, `interactive-widget=resizes-content`, safe-area padding (D7) (83e8e055; gate 36308770570 green, live dev + prd build 257186af)
- [x] T020 [M3] the bottom-docked composer above the keyboard on levels 2 and 3 (FR-007, D4) (5e5ac6ab; lead scoreboard 2, build ac63273c: docked at the viewport bottom at 360-820, dev + prd)
- [x] T021 [M3] 44 px message menu and emoji buttons; a long-press opens the actions sheet (D3) (8378bab3, b36728f6, 7cb5b545; lead scoreboard 3: menu 44 px, kind badge 44 px hit area at 360-820)
- [x] T022 [M3] a one-row card header at 360 px; the code copy button 44 px, no hover (8378bab3, b3de013e, b36728f6)
- [x] T023 [M3] the emoji picker opens and fits at 360 px; the @ list opens upward (8378bab3, 5e5ac6ab: emoji and @ lists as bottom sheets; gate 36310286311 green)
- [x] T030 [M4] issues as a card list at <= 820 px; sort and filter in one sheet; no keyboard-hint line on touch (FR-008) (b079ed4f, f611b095; gate 36307881796 issues-mobile 46/46)
- [x] T031 [M4] the open issue at level 3 through `rightPanel`, full screen, with subtasks (b079ed4f, 27db7f5f; prd e2e live proof 12/12 at 1440/390/820, build f611b095)
- [x] T040 [M5] the settings tabs as a level-2 list; label/value grids stacked at <= 480 px (FR-009) (fdf0b4b0; lead scoreboard 2: 44 px rows at 360-820)
- [x] T041 [M5] dialogs as full-screen sheets; 16 px inputs (D8) (28a98895, 80ca4c04; gate 36309058462 green; OPEN: browser Back with a dialog open pops the stack under it, see T055)
- [x] T042 [M5] search, users, events, archive and login fit 360 px (266cabaf, 80ca4c04, 257186af; prd e2e live proof 17/17, build 645d64dc)

## 4. Phase 3: verification (the lead, continuous)

- [x] T050 [lead] analysis at 5 widths on prd e2e; posted `a657ea12`; AGY-3501 compared
- [x] T051 [lead] this spec + the file map
- [x] T052 [lead] `tests/e2e/mobile-audit-live.proof.mjs` in the tree (the audit used for §3 and the scoreboard)
- [x] T053 [lead] a scoreboard every 20-30 min: area x width, ok / broken, owning lane; dev and prd e2e, + 1440 (0: 08:3xZ, 1: 08:5xZ, 2: 09:3xZ posted), 3: 10:0xZ posted
- [x] T054 [lead] A1-A3 green on prd e2e and dev t1 -> the epic's result post (build 94118eef: prd e2e 42/42 SCORE ok, dev 39/42 then 16/16 after the dock-corner probe fix; A3 desktop by the lanes, byte-identical)
- [x] T055 [SPL-994, CLE-35029] a UiDialog open on a phone is a stack step: browser Back closes the dialog, not the page under it (found by M5, 2026-09-27). `useMobileStack().overlay(open, close)` in UiDialog, the avatar + search sheets, the issues sheets and the M3 message sheets (3b2e2aa3, 94118eef; gate 36311536204 green; live dev+prd 94118eef; prd e2e proof 2cc89202 `mobile-overlay-live.proof.mjs` 390/820 all ok)
- [x] T056 [CLE-35030, SPL-995] at <= 820 px the tenant switcher sits in the one-row top bar, directly before the search icon (owner, topic 6576fead, 2026-09-27 10:09Z: "on mobile the tenan swihcher should be i nthe top bar next to the search"); desktop unchanged (eb88d913; lead verifier tenant-in-top-bar ok at 360-820, dev + prd, n=1)
- [ ] T057 [owner via CLE-001] the card's emoji button (msg-emoji-btn) is visible on phones again, 44 px, beside the menu (D3 amended; owner, topic e0b12a2c)

## 5. Test widths

360x780, 390x844, 430x932, 768x1024 and 820x1180 (mobile), plus 1440x900 (desktop unchanged). Touch emulation
(`isMobile`, `hasTouch`). prd proofs run only at `https://e2e.spool-hub.ai`; dev proofs run in t1 as the M3 test
member.
