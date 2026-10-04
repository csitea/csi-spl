# 082 clean list rows: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes.

No task changes the reply control ("3 >>", owner SPL-982): spec §9 Q4.

---

### Phase 0: Specification
- [x] T001 **spec** (c-245): `spec.md` and this file.

### Phase 1: Topics rows (FR-001..FR-004, FR-006)
- [ ] T002 **plain text + row title** : new pure `src/utils/plain-text.mjs` (`plainText(md, max)`) and `rowTitle(subject, gist)` next to `topicOpening` in `src/utils/view-api.mjs`. Owns: `src/utils/plain-text.mjs`, the new export in `src/utils/view-api.mjs`, `tests/unit/plain-text.test.mjs` (AC1), `tests/unit/view-api.test.mjs` (rowTitle cases), the `src/types/mjs-shims.d.ts` entries. Done: the checks above.
- [ ] T003 **use it in both lists + the date rule** : replace `topicRowTitle` in `src/pages/index.vue:161-164` and `src/components/ChannelSidebar.vue:832-835` with `rowTitle`, dropping `topic.list_title` there; desktop `rowTime` in `index.vue:158` (and the sidebar row time, if shown) uses `formatMsgListTs` (`src/utils/channel-feed.mjs:261`). Update only the list-row assertions among the `list_title` tests (spec AC6). Owns: those functions and the row time in the two files. New e2e `tests/e2e/clean-list-rows.test.mjs` (AC2, AC3, AC4 as a grep in the unit suite). Rebase on c-253 / 079 T005 / 080 T004 if they touched the row templates. Depends on T002. Done: the checks above.

### Phase 2: Flow rows (FR-005)
- [ ] T004 **Flow text** : Flow entry text (`src/utils/flow-entries.mjs` `flowText`, `src/components/FlowList.vue:123,147`) goes through `plainText`. Owns: `flowText` and `tests/unit/flow-entries.test.mjs`. e2e AC5 added to `tests/e2e/clean-list-rows.test.mjs`. Depends on T002. Done: the checks above.

### Phase 3: Help
- [ ] T005 **help** : `csi-spl-doc/doc/help/message-levels-and-topics.md` (how a topic row reads: plain title, date rule), then `node src/node/help/sync-help.mjs`. Done: `./run -a do_check_dist_hygiene`, `lint-mdlinks` green.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:45:00Z -->
