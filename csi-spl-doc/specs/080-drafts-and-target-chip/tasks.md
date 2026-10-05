# 080 drafts per place and the target chip: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes.

---

### Phase 0: Specification
- [x] T001 **spec** (c-245): `spec.md` and this file.

### Phase 1: Drafts (FR-001..FR-005, FR-008)
- [x] T002 **drafts util** (c-256): new pure `src/utils/drafts.mjs`: `draftPlaceOf(target)` (not `placeOf`: that name is `open-message.mjs`'s Nuxt auto-import), `clearDrafts(store, humanId)`, `loadDrafts(store, humanId)`, `saveDraft`, `clearDraft`, `pruneDrafts(now)` (30 days / 50 entries), over `storageGetJson` / `storageSetJson` (`src/utils/prefs.mjs`), key `spool.drafts`. Owns: `src/utils/drafts.mjs`, `tests/unit/drafts.test.mjs` (AC4), its `src/types/mjs-shims.d.ts` entry. Done: the checks above.
- [x] T003 **composer wiring** (c-260): the page target (`useOmniboxTarget`, `src/stores/omnibox.ts`) gains a `place` (from the channel / DM / topic it serves; on `/` from `omniboxReplyTaskId`); `src/components/MessageComposer.vue` watches the place, saves the old text and loads the new, saves on input (300 ms debounce), clears on a successful send (not on failure: `TopBar.vue` restore path keeps it). `logout()` in `src/stores/session.ts` calls `clearDrafts(humanId)`. Owns: `src/stores/omnibox.ts`, the text/watch/send block of `MessageComposer.vue` (~:375, :935-1015), the `logout` function of `src/stores/session.ts`, and the `useOmniboxTarget` calls in `src/pages/index.vue`, `src/pages/lobby.vue`, `src/pages/channel/[name].vue`, `src/pages/dm/[peer].vue`, `src/pages/t/[task_id].vue` (one line each). New e2e `tests/e2e/drafts-per-place.test.mjs` (AC1, AC2, AC3, AC7). Depends on T002. Done: the checks above.
- [x] T004 **draft marks** (c-277): a pencil mark on channel / DM rows (`src/components/ChannelSidebar.vue` row templates) and on topic cards (`src/components/MessageCard.vue` header) whose place has a draft, through a small `useDrafts()` composable (`src/composables/useDrafts.ts`) that exposes `has(place)` reactively. Owns: `src/composables/useDrafts.ts`, the row-mark slot in `ChannelSidebar.vue` (share the slot with spec 079 T005: rebase on whichever landed), the header mark in `MessageCard.vue`, i18n `composer.draft_mark` in all 19 locales. e2e assertions added to `tests/e2e/drafts-per-place.test.mjs` (AC3). Depends on T003. Done: the checks above.

### Phase 2: The target chip (FR-006, FR-007)
- [ ] T005 **chip** : a pure `chipLabel(target)` next to `dockTargetHint` in `src/utils/omnibox-topic.mjs`, built from the same target object `send` uses; `MessageComposer.vue` renders the chip at the start of the field while text is non-empty and not in search mode, in both positions (replace the `v-if` at :24-33 that limits it to the bottom dock). A chip click opens the target (spec Q3). Owns: `src/utils/omnibox-topic.mjs` (new function only), the chip block of `MessageComposer.vue` (:24-33 and its styles), i18n `composer.chip_reply`, `composer.chip_new_topic` in all 19 locales, `tests/unit/omnibox-topic.test.mjs` (AC6). New e2e `tests/e2e/composer-target-chip.test.mjs` (AC5); `composer-mode-cue`, `thread-dock-target` stay green. Can run in parallel with T004 (different blocks of `MessageComposer.vue`: rebase if both land the same hour). Done: the checks above.

### Phase 3: Send when back online (FR-009, also mobile; spec Q4)
- [ ] T006 **offline queue** : a network-failed send keeps its pending row with "waiting for network" and is resent with the same `msg_id` on reconnect (`src/stores/channel.ts` `sendLive` / `sendWithResend` ~:403-462, `src/stores/live.ts` reconnect hook); TopBar's Retry (`src/components/TopBar.vue:177-194`) reuses the `msg_id`. Owns: those blocks, i18n `composer.waiting_network`. New e2e `tests/e2e/offline-send-queue.test.mjs` (AC8, CDP offline). `send-failure`, `pane-send-lost` unit tests stay green. Coordinate with the mobile lane that picks up `mobile-usability-ideas-20261004.md` §3.3: this task is that work. Done: the checks above.

### Phase 4: Help
- [ ] T007 **help** : `csi-spl-doc/doc/help/omnibox-and-navigation.md` new section "Drafts and the target chip" (and the offline queue once T006 lands), then `node src/node/help/sync-help.mjs`. Done: `./run -a do_check_dist_hygiene`, `lint-mdlinks` green.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:20:00Z -->
