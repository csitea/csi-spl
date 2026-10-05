# 085 the phone composer names its destination, and Search has a button: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), the 1440 control screenshots unchanged (spec FR-008), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes. Each lane posts 390 and 360 px screenshots in topic `c893c3a9`.

---

### Phase 0: Specification
- [x] T001 **spec** (c-246): `spec.md` and this file.

### Phase 1: Placeholder, Search button, level 1 (FR-003..FR-007); no dependency on 080
- [x] T002 **phone placeholder** (c-284): at <= 820 px the placeholder is the destination only. Add `composer.phone_placeholder_channel` (`Message #{name}`), `_dm` (`Message @{peer}`), `_reply` (`Reply`), `_search` (`Search`) to all 19 locales; the page targets pick them when `useMobileStack().isMobile` (one line per call). Owns: the `placeholder:` lines of the `useOmniboxTarget` calls in `src/pages/index.vue`, `src/pages/lobby.vue`, `src/pages/channel/[name].vue`, `src/pages/dm/[peer].vue`, `src/pages/t/[task_id].vue`; the locale keys. New e2e `tests/e2e/phone-composer-target.test.mjs` (AC4). Done: the checks above. Built: `phone-composer-target` 14/14 at 390 and 360 (n = 1 run). The level-1 (no topic open) placeholder on `index.vue` keeps the desktop string until T004 sets `_search` with its send guard. Found: AC4's `scrollWidth` cannot see a clipped placeholder (a textarea does not scroll it sideways); measured, `Message #alerts`, `#lobby` and `@<peer>` are cut by the one-line field at 390 and 360 (`Message #a` at 360), only `Reply` fits. The test prints that as INFO; the fix is the composer CSS (an ellipsis) or shorter strings, an orchestrator decision.
- [ ] T003 **Search button** : at <= 820 px the `?` button (`search-syntax-help`) shows the `search` icon, is labelled `search.title`, and a tap sets search mode (the state `/search ` sets today), focuses the field and opens `search-syntax-panel`; a second tap or an empty box leaves search mode. The panel's first rows are the key hints the phone placeholder dropped (FR-005). Owns: the `?` button and syntax-panel block of `src/components/MessageComposer.vue` (~:101-130) and the search-mode toggle it calls; i18n `search.phone_hints` in all 19 locales. e2e in `phone-composer-target.test.mjs` (AC5). Done: the checks above, plus `dock-buttons`, `mobile-go-dock`, `composer-mode-cue` green.
- [ ] T004 **level 1 searches** : on level 1 (`data-mobile-level="1"`) the docked box is search-only: the `/` page target's `send` runs the search, placeholder `composer.phone_placeholder_search`, glyph the magnifier. Owns: the `useOmniboxTarget` call and `onSend` guard in `src/pages/index.vue` (~:214-253), the level-1 glyph case in `MessageComposer.vue`'s `modeGlyph`. e2e in `phone-composer-target.test.mjs` (AC6). Depends on T002 (same call). Done: the checks above.

### Phase 2: The chip on a phone (FR-001, FR-002); after 080 T005
- [ ] T005 **phone chip** : 080 T005's chip, placed for the phone dock: inside the field after the mode glyph, shown on focus or text (spec Q3), 14 px, `chipLabel(target)` cut to 12 characters with the full label in `title`/`aria-label`, and the textarea's first line indented by the chip's width. Owns: the phone CSS of the chip block in `MessageComposer.vue` (the block itself is 080 T005's) and a `phoneChipLabel()` wrapper next to `chipLabel` in `src/utils/omnibox-topic.mjs`; `tests/unit/omnibox-topic.test.mjs` cases (AC3). e2e in `phone-composer-target.test.mjs` (AC1, AC2, AC3's wrap check). **Depends on 080 T005** (`chipLabel` and the chip block). Done: the checks above, plus `thread-dock-target` green.

### Phase 3: Help and the real phone
- [ ] T006 **help** : `csi-spl-doc/doc/help/omnibox-and-navigation.md` §9: drop the stale top-bar search sentence; describe the phone Search button, level 1 searching and the chip; then `node src/node/help/sync-help.mjs` and commit `src/public/help-md/omnibox-and-navigation.md` in its own commit. Done: AC9, `do_check_dist_hygiene`, `lint-mdlinks` green.
- [ ] T007 **real phone** : on one Android (Chrome) and one iPhone (Safari, installed): AC1, AC5 and AC6 by hand with the system keyboard up; record device, OS, build version and pass/fail per AC in this file. Done: the row is here.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T00:30:00Z -->
