# 109 Desktop UI refactoring round: tasks

Authority for what is built (`spec.md` holds the behaviour; section numbers below are its sections). Each task is one lane: one agent, one task, the files it owns, its measured before-number, its target, its gate. Status vocabulary: `../README.md` §2.3. **v0.1 draft**: no lane starts before v1.0 (the panel fold).

Paths: `wui/` = `csi-spl-wui/`, `orc/` = `csi-spl-orc/`, `doc/` = `csi-spl-doc/`. Before numbers: `spec.md` sections 2 and 3, WUI `bd165b42`, prd e2e, 1440 x 900.

## Rules for every task

- **Desktop only.** A component the phone also renders keeps its phone e2e green and unchanged (360x780 and 390x844); no `@media` width other than the named breakpoint (`breakpoint-single-source`).
- **Measure before and after with the same probe, same host, n >= 10** (spec section 1 commands), and put both numbers, the WUI sha and n in the commit message. A target missed is reported as missed, with the number.
- **Initial JS** (spec 4.1): `perf-budget.py bundle` on a mock `nuxt generate`; a task may not raise `ci_initial_gzip_kb` (155 KB, red at 155.1 today). New UI loads lazily.
- **The 2026-10-02 refactor-round gates stay green**: `tests/unit/cleancode.test.mjs` (a function > 80 lines, depth > 4 or params > 6 fails; the LONG list may only shrink), `css-color-tokens` (no new hex outside the allow-list), `css-z-scale` (z-index >= 40 is a `--z-*` token), `breakpoint-single-source`.
- **Gate before every push, and again after the mandatory rebase**: `cd csi-spl-iac && ./run -a do_check_pre_push`; for `wui/`: `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`). Extend an existing e2e file rather than add one (a new e2e file reddens the shard control).
- **i18n**: a new or changed string is a key in all 19 locales.
- **Do not touch**: any hub file; spec 103 / 081 key code (`useGlobalKeys.ts`, `useMsgShortcuts.ts`, `vim-panels.mjs`); spec 107 files; spec 099 files.
- **Deploy dev and prd, then prove it live** on the e2e host: `./run -a do_check_deploy_lag`; `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs.

## Order and parallelism

```
T001 spec v1.0 ─┬─► T002 budget gate covers index.html ──► T003 trim "/" preloads
                ├─► T004 one roster + one topics read
                ├─► T005 trace W1 ──► T006 channel first page without the socket
                ├─► T007 tab switch keeps the centre
                ├─► T008 one topic list on home (Q2)
                ├─► T009 reply box in the thread pane (Q3) ──► T011 thread pane header
                ├─► T010 top bar: language picker out, one Workspace settings entry
                ├─► T012 first-run chip, plain headers, workspace box on click, rail divider
                └─► T013 RUM on in prd (Q1)
                    T002..T013 ──► T014 after-numbers + spec status
```

Speed lanes (T002..T007) land before the UI lanes, so the bytes they free pay for any UI that needs a lazy chunk.

## Tasks

| id | task | owned files | before | target | gate (besides the rules) | depends |
|---|---|---|---|---|---|---|
| T001 | Spec v1.0: fold the seats' agreed changes, answer table | `doc/specs/109-desktop-ui-refactor/spec.md`, `tasks.md` | v0.1 | v1.0, review table filled | `do_check_dist_hygiene`, lint-mdlinks | seats s109-2..4 |
| T002 | The CI budget measures every prerendered document: `index.html` as well as `200.html`, a new ceiling `ci_home_gzip_kb` set at the measured mock value (no ratchet up) | `orc/src/bash/scripts/perf-budget.py`, `wui/src/node/test/bundle-size.mjs`, `doc/specs/027-spool-performance/contracts/perf-budgets.json` (one key) | `index.html` not gated; live 349.8 KB (D3) | gated; a CONTROL: the current tree's `index.html` is reported | `orc` perf-budget test on a canned `pub/` with both files; CONTROL shows the old code ignores `index.html` | T001 |
| T003 | The prerendered `/` preloads no more than `200.html` plus the home page chunk: find which of the 85 `modulepreload` links come from the prerender (route payload, `app.head`, plugins) and drop them | `wui/nuxt.config.ts` (prerender / head only), `wui/src/pages/index.vue` (imports only) | 85 chunks, 349.8 KB gzip; W3 4,942 ms | <= 175 KB; W3 <= 2,500 ms median | T002's `ci_home_gzip_kb` lowered to the new value in the same commit; baseline probe `cold / first topic row` n=10 | T002 |
| T004 | One read per resource per load: the avatar code takes the roster from the roster store instead of its own `GET /v1/view/roster`; the first screen reads `/v1/view/topics` once | `wui/src/utils/avatar.mjs`, `wui/src/utils/spool-client.mjs` (roster / topics readers only) | roster 2 per load, topics 2 per first screen (D7, D8) | 1 and 1; perf-live `dupes = []` | a unit test that counts fetches on a mock first screen (roster == 1, topics == 1) plus a CONTROL with the old double read | T001 |
| T005 | Trace W1: why `/lobby` shows its first message after ~5 s warm (D1, D2). Trace and count (lesson rule 2): what the feed waits on (socket open? a read chained after the roster? a long task?). Output a short doc with the trace and the fix shape; no code | `doc/specs/109-desktop-ui-refactor/w1-trace.md` (new) | W1 5,004 ms, `ws open` 4,007 ms | the cause named with numbers, n >= 10 | lint-mdlinks | T001 |
| T006 | Channel first page without the socket (FR-001), in the shape T005 names | named by T005; expected `wui/src/utils/channel-feed.mjs`, `wui/src/pages/lobby.vue` / `channel/*` (no hub file) | W1 5,004 / W2 5,373 ms | W1 <= 1,500 ms median, n=10 | a unit test that the first page renders with the socket still closed, plus a CONTROL; baseline probe n=10 | T005 |
| T007 | A rail tab that does not change the route does not re-render the centre (FR-005) | `wui/src/components/ChannelSidebar.vue` (tab click handler only), `wui/src/pages/index.vue` | Topics 1,152 / Channels 968 ms settled | <= 250 ms settled, n=10 | `switch.mjs` style e2e step added to an existing e2e file: DOM mutations in the centre after a same-route tab click == 0 | T001 |
| T008 | Home shows the topic list once (FR-006, Q2: the left panel shows Channels while the centre shows Topics) | `wui/src/pages/index.vue`, `wui/src/components/ChannelSidebar.vue` (default tab on `/` only) | 2 lists (F1) | 1 list | e2e: on `/` the left panel is not `sidebar-panel-topics`; phone unchanged | T007 (same files: after it) |
| T009 | Reply box docked at the bottom of the thread pane (FR-007, Q3); the top omnibox keeps new topics and search; the box is a lazy component | `wui/src/components/ThreadReplyBox.vue` (new), `wui/src/components/LiveTopicPane.vue` (mount point only) | reply typed ~900 px from the thread (F2) | typed in the pane; Enter / Shift+Enter as the omnibox | e2e: open a topic, type in the pane box, send, row shows in the thread; initial JS unchanged | T001 |
| T010 | Top bar: the language picker moves to the avatar menu and Settings -> Language (FR-008); Workspace settings has one entry, the rail gear (FR-009) | `wui/src/components/TopBar.vue`, `wui/src/components/UserMenu.vue` | 171 px picker (F4); 3 entries (F5) | 0 px in the bar; 1 entry | e2e: no `lang-switcher` in the top bar at 1440, the avatar menu has it; phone unchanged | T001; **after** 107's header-timer lane (c-566) lands its `TopBar.vue` change |
| T011 | Thread pane header: one-line title with ellipsis, labelled controls (FR-011) | `wui/src/components/LiveTopicPane.vue` (header only) | raw 4-line text box, 3 unlabelled icons (F7) | 1 line; every control has `aria-label` and a tooltip | e2e: header height <= 48 px at 1440; axe-style check that every button has a name | T009 (same file: after it) |
| T012 | Small fixes: first-run card becomes a one-line chip once a step is done (FR-010); plain header words (FR-013); workspace box opens on `click` (FR-014); rail divider + "show labels" toggle (FR-012) | `wui/src/components/FirstRunChecklist.vue`, `wui/i18n/locales/*.json` (the `subtitle` key and new keys only), `wui/src/components/TenantDropBox.vue`, `wui/src/assets/css/main.css` (rail divider rule only) | 270 px card (F6); jargon (F8); `click()` opens nothing (F9); no labels (F3) | <= 48 px; plain words; `click()` opens the list; divider and toggle | e2e for each item in an existing file; `css-color-tokens` | T001; the rail divider waits for T007 / T008 if they still hold `ChannelSidebar.vue` |
| T013 | RUM on in prd (Q1): cnf `perf.rum_enabled` true for prd, rendered, deployed | `csi-spl-cnf/csi-spl/prd.env.yaml` (one key) and its rendered files | prd 0 samples | `do_spl_wui_perf_report ENV=prd` shows desktop groups after 7 days | `ENV=prd ./run -a do_tpl_gen` then `git diff --exit-code`; the 066 L9 note in cnf updated | Q1 answer (a) |
| T014 | After-numbers: the spec section 1 probes again (n=10) on the deployed round, plus RUM from T013 if on; a before / after table into `spec.md`, status per FR | `doc/specs/109-desktop-ui-refactor/spec.md` | section 2 | every FR with its after-number, met or missed | lint-mdlinks | T002..T013 |

## Status

| id | status |
|---|---|
| T001 | in progress (v0.1 landed by c-567) |
| T002..T014 | Planned |

<!-- last-edit: 2026-10-08T17:40:00Z — v0.1 draft, c-567 -->
