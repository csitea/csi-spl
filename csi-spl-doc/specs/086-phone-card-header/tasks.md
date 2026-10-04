# 086 a readable card header on phones: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), the 1440/1280 control screenshots byte-identical (FR-007), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes. Each lane posts 390 and 360 px screenshots in topic `c893c3a9`.

**Gate**: Phase 1 starts only after the owner answers spec Q1 (two lines). If the answer is "keep one line", T002 builds the Q1 fallback instead (drop `@box` and the recipient avatar at <= 820 px) and AC2 is replaced by "the header is one line".

---

### Phase 0: Specification
- [x] T001 **spec** (c-246): `spec.md` and this file.

### Phase 1: The two-line header (FR-001..FR-005)
- [ ] T002 **header lines** : at <= 820 px split `.msg-meta` into a "who" line (sender, arrow, recipient avatar, recipient) and a "what" line (AI / typed-by / via-DM badges, kind, responsible, time, edited, reply count, Add emoji, menu): a wrapper element or a forced row break, desktop markup unchanged. `AgentBadge` renders the agent id and the `@box` part as two spans so the box part can be muted and truncate alone (FR-002, FR-003). Replace the SPL-1000 `flex: 1 1 0; min-width: 1em` name rule at <= 820 px. Owns: the `.msg-meta` template block of `src/components/MessageCard.vue` (~:77-135) and its <= 820 px CSS (~:2045-2095); the id/box split in `src/components/AgentBadge.vue` (desktop output unchanged). New e2e `tests/e2e/phone-card-header.test.mjs` (AC1-AC5, plus the before/after visible-card count of spec Q3). Done: the checks above and AC8's list green.

### Phase 2: The thread title (FR-006)
- [ ] T003 **topic title** : the level-3 title (`topic-heading__title` in `src/components/LiveTopicPane.vue` and the title pill in `src/components/TopicPane.vue`) wraps to two lines at <= 820 px with a two-line clamp; Back and the clip controls keep their 44 px boxes. Owns: those title elements' <= 820 px CSS. e2e in `phone-card-header.test.mjs` (AC6). Can run in parallel with T002 (different files). Done: the checks above, plus `mobile-stack` and `mobile-messages` green.

### Phase 3: Help and the real phone
- [ ] T004 **help** : one sentence in `csi-spl-doc/doc/help/interface-overview.md` §8 (phones): the card header is two lines, who above, what and when below; then `node src/node/help/sync-help.mjs` and commit `src/public/help-md/interface-overview.md` in its own commit. Done: `do_check_dist_hygiene`, `lint-mdlinks` green.
- [ ] T005 **real phone** : one Android (Chrome) and one iPhone (Safari): AC1, AC2, AC6 by eye on a prd or dev channel with agent posts; record device, OS, build version, pass/fail and the visible-card count in this file. Done: the row is here.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T00:45:00Z -->
