# 088 drafts on a phone: tasks

Authority for what is built (`spec.md` holds the phone behaviour; `../080-drafts-and-target-chip/` holds the model and builds it). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), 080's `drafts-per-place` e2e still green, and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes.

**Order**: Phase 1 starts after 080 T003 (drafts wired into the composer) is on master. Phase 2 after 080 T006 (the offline queue).

---

### Phase 0: Specification
- [x] T001 **spec** (c-246): `spec.md` and this file.

### Phase 1: Survive the phone (FR-001..FR-004, FR-006); after 080 T003
- [x] T002 **flush on hide** (c-286): a `flushDraft()` export in `src/utils/drafts.mjs` (080's file: this new function only, no change to its format) that writes the pending debounced text at once; a new `src/plugins/drafts-flush.client.ts` that calls it on `visibilitychange` -> hidden and on `pagehide`; the composer registers its current place and text getter with one line. Owns: `flushDraft` in `drafts.mjs` and its cases in `tests/unit/drafts.test.mjs`, `src/plugins/drafts-flush.client.ts`, the one registration line in `src/components/MessageComposer.vue`. Done: the checks above, AC2, AC7.
- [ ] T003 **phone e2e** : new `tests/e2e/phone-drafts.test.mjs`: AC1 (chevron, dock Back, edge swipe), AC3, AC5, and AC4 when 087 T004 is on master (skipped with a printed reason before that). A failing AC1 or AC3 is a bug in 080's place change: report it to 080's lane, do not patch it here. Owns: that file. Depends on T002. Done: the checks above.
- [ ] T004 **draft mark at phone size** : if AC5 fails on the 080 T004 build, the <= 820 px CSS of the pencil (>= 12 px) on level-1 rows and on line 2 of the phone card header (086). Owns: only that <= 820 px CSS in `src/components/ChannelSidebar.vue` and `src/components/MessageCard.vue`. Done: AC5; skipped (marked here) when AC5 already passes.

### Phase 2: The offline queue on a phone (FR-005); after 080 T006
- [ ] T005 **hidden and discarded sends** : extend `tests/e2e/phone-drafts.test.mjs` with AC6; where it fails, the fix goes into 080 T006's code by 080's lane, or here with that lane's agreement, keeping one queue. Owns: the AC6 block of the e2e. Done: AC6 green.

### Phase 3: Help and the real phone
- [ ] T006 **help** : one paragraph in `csi-spl-doc/doc/help/omnibox-and-navigation.md` §9 (the message box on a phone): drafts are kept per place and survive switching apps; then `node src/node/help/sync-help.mjs`, `src/public/help-md/omnibox-and-navigation.md` in its own commit. Coordinate with 080 T007, which writes the same page's drafts section: one section, a phone sentence in it. Done: `do_check_dist_hygiene`, `lint-mdlinks` green.
- [ ] T007 **real phone** : Android Chrome (discard the tab via `chrome://discards` or by opening many apps) and iPhone Safari (installed; switch apps, lock, reopen): AC1, AC3 and FR-001 by hand; record device, OS, build version and pass/fail here. Done: the rows are here.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T01:10:00Z -->
