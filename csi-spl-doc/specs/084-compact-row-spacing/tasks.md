# 084 compact row spacing: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

**Gate:** after spec 078 T006 (message measure) has landed: both edit the `.msg` rules.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes.

---

### Phase 0: Specification
- [x] T001 **spec** (c-245): `spec.md` and this file.

### Phase 1: Variables, with today's values (FR-002, no visible change)
- [ ] T002 **spacing variables** : add `--row-pad-y`, `--row-gap`, `--row-avatar`, `--row-list-pad-y` to `src/assets/css/variables.css` with today's pixels, and make the `.msg` rule (`src/assets/css/main.css:328-336`), the avatar size of message cards, and the sidebar / Topics row padding read them. Owns: `variables.css` (new variables), the `.msg` rule, the row-padding rules they replace. New e2e `tests/e2e/row-spacing.test.mjs` with AC1 only (pitch unchanged). Done: the checks above, and a 1440 screenshot diff of `/lobby` and `/` equal to before.

### Phase 2: The setting (FR-001, FR-003..FR-005)
- [ ] T003 **setting** : new `src/utils/row-spacing.mjs` modelled on `src/utils/font-size.mjs` (`loadRowSpacing`, `saveRowSpacing`, `applyRowSpacingAttr`), applied before first paint the way font size is (`src/plugins/font-size.client.ts` pattern, or the same early script); compact values under `html[data-row-spacing="compact"]` inside a `min-width: 821px` media query in `src/assets/css/base.css`; a control in `src/components/settings/appearance.vue` under Font size (new `src/components/RowSpacingSetting.vue`); i18n `settings.row_spacing.*` in all 19 locales. Owns: those files. Tests: `tests/unit/row-spacing.test.mjs` (AC5); AC2, AC3, AC4 added to `tests/e2e/row-spacing.test.mjs`; `no-x-scroll`, `card-edge-inset`, `font-size` green in both modes (AC6). Depends on T002. Done: the checks above.

### Phase 3: Help
- [ ] T004 **help** : `csi-spl-doc/doc/help/user-settings.md` §4 new *Row spacing* subsection (next to §4.2 Font size, distinct from §4.3 List density), then `node src/node/help/sync-help.mjs`. Done: `./run -a do_check_dist_hygiene`, `lint-mdlinks` green.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T23:05:00Z -->
