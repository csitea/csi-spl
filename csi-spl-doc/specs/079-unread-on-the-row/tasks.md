# 079 one unread model, shown on the row: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

**Gate:** Phase 1 starts after the running lane **c-253** (topic new/total) has landed on master; rebase on it.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes.

---

### Phase 0: Specification
- [x] T001 **spec** (c-245): `spec.md` and this file.

### Phase 1: The model (FR-001, FR-002)
- [x] T002 **pure model** (c-261): new `src/utils/unread-model.mjs` exporting `unreadModel({keys, cursors, channelUnread, dmUnread, muted, topics})` -> `{rows: Map<key,n>, sections: {channels, dms, topics}, title}`; reuse `rowUnread` / `sectionTotal` (`src/utils/flow-keys.mjs`) and `topicUnread` / `countUnread` (`src/utils/read-cursor.mjs`) inside it rather than re-deriving. Owns: `src/utils/unread-model.mjs`, `tests/unit/unread-model.test.mjs` (AC1, AC2), its `src/types/mjs-shims.d.ts` entry. Done: the checks above.
- [x] T003 **composable + grep gate** (c-259): new `src/composables/useUnread.ts` that feeds T002 from `useFlowKeys`, `stores/notification.ts`, `stores/channel.ts` and the cursors, exposing `rowOf(key)`, `section(id)`, `title`. Add the AC3 grep gate to `tests/unit/unread-model.test.mjs` (allow-list: `useUnread.ts`, the stores themselves). Owns: `src/composables/useUnread.ts`, the test. Depends on T002. Done: the checks above (the gate may list today's direct callers as `todo` entries that T004..T006 remove).

### Phase 2: Surfaces read the model (FR-003..FR-009)
- [x] T004 **title + rail** (c-266): `src/app.vue` title uses `useUnread().title` (spec Q1, Q2); the rail badges in `src/components/ChannelSidebar.vue` (`railCount`, ~:1000-1033) use `section()`. Owns: `src/app.vue` (title block), the `railCount` / `unreadOf` functions of `ChannelSidebar.vue`, `src/utils/tab-title.mjs` (keep `unreadTotal` for the model's use only), `tests/unit/tab-title.test.mjs`. e2e: `unread-sum` updated to the row-sum rule. Depends on T003. Done: the checks above. Built: the title is the channel + DM rows (muted out) read through `useUnread()`, not `title`: flow-v1 §2 counts each line under its place AND its topic, so adding `t:` rows double-counted (mock: `(2)` over one unread DM). The rail sums `rowOf` over the rows each section lists (owner t1 77540e6f). `flow-mine` now expects the title to stay `(1)` after Flow opens (Q4).
- [ ] T005 **rows** : sidebar channel, DM and topic rows (`ChannelSidebar.vue` row templates, `data-testid="topic-unread"` ~:455) and the Topics middle list rows (`src/pages/index.vue`, add the badge) read `rowOf(key)`. Owns: the row templates of `ChannelSidebar.vue` (not the functions T004 owns: run T004 first), the row template of `src/pages/index.vue`. New e2e `tests/e2e/unread-on-row.test.mjs` (AC4, AC5). If 078 T003 landed first, skip the `index.vue` part and say so in the commit. Done: the checks above.
- [x] T006 **cards** (c-281): a topic card's `<new>` (`src/components/MessageCard.vue:150,573`, `src/components/LiveFeed.vue:87`) ~~reads `rowOf('t:'+task_id)` instead of `channel.unreadFor`~~ keeps `channel.unreadFor` (spec FR-005, v0.1.1). Owns: those lines, `src/stores/channel.ts` (`unreadFor` doc comment / export). e2e: `topic-unread-count`, `channel-thread-unread` green. Done: the checks above. Built: cards keep `channel.unreadFor` (the local `t:` cursor, FR-005 reworded): hub `keys` let `ch:` cover a topic's replies (062 FR-006), so `rowOf('t:'+id)` zeroed the card on opening the channel and undid CLE-77930 (c-001, option 1); the AC3 gate keeps `MessageFeed.vue` as an allowed reader.
- [ ] T007 **Flow label** : the Flow rail badge's `title` / `aria-label` become "new in Flow" (new i18n key `flow.badge_label` in all 19 `i18n/locales/*.json`), colour unchanged. Owns: the Flow tab badge markup in `ChannelSidebar.vue` (rail block only), the i18n key. e2e assertion added to `tests/e2e/unread-on-row.test.mjs` (AC6). Run after T005 (same file). Done: the checks above.

### Phase 3: Help
- [ ] T008 **help** : `csi-spl-doc/doc/help/channels-and-direct-messages.md` (unread numbers), `csi-spl-doc/doc/help/interface-overview.md` §3.1 (rail badges, Flow "new"), then `node src/node/help/sync-help.mjs`. Done: `./run -a do_check_dist_hygiene`, `lint-mdlinks` green.

<!-- version: 0.1.1 · updated: 2026-10-05 · last-edit: 2026-10-05T02:50:31Z -->
