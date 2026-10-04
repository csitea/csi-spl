# 083 next unread: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

**Gate:** starts after spec 079 Phase 2 (`useUnread()`) has landed; T003's key waits for 081 T004 (`useGlobalKeys.ts`).

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes.

---

### Phase 0: Specification
- [x] T001 **spec** (c-245): `spec.md` and this file.

### Phase 1: The order (FR-001)
- [ ] T002 **pure order** : new `src/utils/next-unread.mjs`: `unreadOrder(rows, sidebar, muted)` and `stepPlace(order, current, dir)` (wrap once). Owns: `src/utils/next-unread.mjs`, `tests/unit/next-unread.test.mjs` (AC1), the `src/types/mjs-shims.d.ts` entry. Done: the checks above.

### Phase 2: Key and button (FR-002..FR-006)
- [ ] T003 **go there** : a `src/composables/useNextUnread.ts` that reads `useUnread()` and the sidebar order (`stores/channel.ts` `ordered`, the DM list), and opens the target (route for `ch:` / `dm:`, `useOpenMessage().openMessage` for `t:`), scrolling to the divider (`LiveFeed.vue` `jumpToUnread`, exposed if needed); `Alt+Shift+↓/↑` registered in `src/composables/useGlobalKeys.ts` (081); the key added to the overlay table's Global group in `src/utils/msg-shortcuts.mjs` (AC5); i18n `unread.caught_up`. Owns: `useNextUnread.ts`, one block in `useGlobalKeys.ts`, one row in `msg-shortcuts.mjs`, a minimal `defineExpose` in `LiveFeed.vue` if `jumpToUnread` is not reachable. New e2e `tests/e2e/next-unread.test.mjs` (AC2, AC3). Depends on T002, 079, 081 T004. Done: the checks above.
- [ ] T004 **header button** : **Next unread · N** in `src/components/FeedHeader.vue` (before `CardClipControl`), shown when N > 0, also on a phone; i18n `unread.next_button` in all 19 locales. Owns: `FeedHeader.vue`, the i18n key. AC4 in `tests/e2e/next-unread.test.mjs`. Depends on T003. Done: the checks above.

### Phase 3: Help
- [ ] T005 **help** : `csi-spl-doc/doc/help/keyboard-shortcuts.md` (generated Global group picks up the key) and `csi-spl-doc/doc/help/channels-and-direct-messages.md` (the button), then `node src/node/help/sync-help.mjs`. Done: `./run -a do_check_dist_hygiene`, `lint-mdlinks` green.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:55:00Z -->
