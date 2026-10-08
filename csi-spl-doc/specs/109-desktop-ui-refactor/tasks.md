# 109 Desktop UI refactoring round: tasks

Authority for what is built (`spec.md` holds the behaviour; section numbers below are its sections). Each task is one lane: one agent, one task, the files it owns, the files it must not touch, its measured before-number, its target, its gate. Status vocabulary: `../README.md` §2.3.

Paths: `wui/` = `csi-spl-wui/`, `orc/` = `csi-spl-orc/`, `doc/` = `csi-spl-doc/`. Before numbers: `spec.md` sections 2 and 3, WUI `bd165b42`, prd e2e, 1440 x 900. Panel names: `spec.md` header (icon column, panels 1, 2, 3).

## Rules for every task

- **Register the files, then check them** (s109-4): at spawn, `lane-map.sh put --files <the task's owned files>`, then `lane-map.sh --check <those files> --agent <id>` before the first edit. Several live lanes carry `files: []` today, so a `free` result against an empty row proves nothing. Check the named lanes below by hand (`git -C <their worktree> status`).
- **Desktop only.** A component the phone also renders keeps its phone e2e green and unchanged (360x780 and 390x844); no `@media` width other than the named breakpoint (`breakpoint-single-source`).
- **Measure before and after with the same probe, same host, n >= 10** (spec section 1 commands), and put both numbers, the WUI sha and n in the commit message. A missed target is reported as missed, with its number.
- **Re-measure the before-number on the WUI sha the lane starts from** (prd moved from `bd165b42` to `64963b52` during the review); the commit names both shas (s109-3).
- **Record each probe round's longest connect** (CDP `timing.connectEnd - connectStart`). A round with a connect over 1 s goes to its own column, out of the median and the p95: the measuring box's link stalls in bursts (s109-3).
- **A signed-in probe needs the prd e2e login**, which exists only on the drafting box (spec section 1). Run there, or ask c-002 for a login; never mint one with `do_spl_m3_e2e` (it writes to prd).
- **Initial JS** (spec 4.1): `perf-budget.py bundle` on a mock `nuxt generate`. No 109 task changes `ci_initial_gzip_kb` (lane c-568 owns it). New UI loads lazily (`defineAsyncComponent`). **No UI lane (T008..T012, T015) starts while workflow 10 is red on trunk.**
- **The 2026-10-02 refactor-round gates stay green**: `tests/unit/cleancode.test.mjs` (a function over 80 lines, depth over 4 or more than 6 params fails; the LONG list may only shrink), `css-color-tokens` (no new hex outside the allow-list), `css-z-scale` (z-index >= 40 is a `--z-*` token), `breakpoint-single-source`.
- **Gate before every push, and again after the mandatory rebase**: `cd csi-spl-iac && ./run -a do_check_pre_push`; for `wui/`: `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`). Extend an existing e2e file rather than add one (a new e2e file reddens the shard control).
- **i18n**: a new or changed string is a key in all 19 locales.
- **No task touches**: any hub file; spec 103 / 081 key code (`useGlobalKeys.ts`, `useMsgShortcuts.ts`, `vim-panels.mjs`); spec 107 files (including its header timer); spec 099 files.
- **Deploy dev and prd, then prove it live** on the e2e host: `./run -a do_check_deploy_lag`; `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs.

## Order and parallelism

```
T001 spec v1.0 ─┬─► T013 RUM on in prd (first: a real before-week)
                ├─► [c-568 done] T002 budget gate covers index.html ──► T003 trim "/" preloads ──► T007 tab switch keeps the centre
                ├─► T004 one roster + one topics read                                                │
                ├─► T005 trace W1 ──► T006 channel first page without the socket                     ▼
                ├─► T011 panel 3 header                                             T008 one topic list on home (Q2) ──► T015 rail divider + labels
                ├─► [107 timer landed] T010 top bar: language picker out
                └─► T012 first-run chip, plain headers, workspace box on click
                    T002..T015 ──► T014 after-numbers + spec status
```

- **`index.vue`**: T003 -> T007 -> T008 (s109-2, s109-4).
- **`ChannelSidebar.vue` (2,294 lines)**: T007 -> T008 -> T015, one at a time. None of them starts while c-563@sat (sidebar clock gap) holds uncommitted edits to it (s109-4).
- **`LiveTopicPane.vue`**: T011 only (T009 dropped, owner Q3 = no).
- **`TopBar.vue`**: belongs to c-566 (107 header timer) until that lands; T010 starts after it.
- The speed lanes (T002..T007) land before the UI lanes, so the bytes they free pay for any UI that needs a lazy chunk.

## Tasks

| id | task | owned files | must not touch | before | target | gate (besides the rules) | depends |
|---|---|---|---|---|---|---|---|
| T001 | Spec v1.0: fold the seats' agreed changes, fill the answer table | `doc/specs/109-desktop-ui-refactor/spec.md`, `tasks.md` | any code | v0.1 | v1.0 | `do_check_dist_hygiene`, lint-mdlinks | seats s109-2..4 |
| T002 | The CI budget measures every prerendered document: `index.html` as well as `200.html`, with a new ceiling `ci_home_gzip_kb` set at the measured mock value (never ratcheted up). All three counters agree on the set rule | `orc/src/bash/scripts/perf-budget.py`, `wui/src/node/test/bundle-size.mjs`, `wui/tests/e2e/calendar.test.mjs` (AC-02 block only), `doc/specs/027-spool-performance/contracts/perf-budgets.json` (the new key only) | any WUI component; `ci_initial_gzip_kb` | `index.html` not gated; live 349.8 KB (D3) | gated; a CONTROL: the current tree's `index.html` is reported | `orc` perf-budget test on a canned `pub/` with both files; CONTROL shows the old code ignores `index.html` | T001; **after c-568 is done** (builds on `4b1ed47de` or later) |
| T003 | The prerendered `/` preloads no more than `200.html` plus the home page chunk: find which of the 85 `modulepreload` links come from the prerender (route payload, `app.head`, plugins) and drop them | `wui/nuxt.config.ts` (prerender / head only), `wui/src/pages/index.vue` (imports only) | `perf-budget.py`; `ci_initial_gzip_kb` (no raise) | 85 chunks, 349.8 KB gzip | `ci_home_gzip_kb` <= 175 KB; `/` first topic row faster on the `d1440-4g` profile (~1 s expected at 1.6 Mbps), n=10 | `ci_home_gzip_kb` lowered to the new value in the same commit; `ci_initial_gzip_kb` unchanged; baseline probe `PROFILES=d1440-4g` `cold / first topic row`, n=10 before and after (s109-3: on a fast link the chunks cost only ~70 ms) | T002 |
| T004 | One read per resource per load: a settled view read is kept for the load (or a short TTL), so a second caller that starts after the first read settled reuses it (D8: the in-flight read is already shared) | `wui/src/utils/spool-client.mjs` (`live` / `inflight` only) | `avatar.mjs`; any store or hub file | roster 2 per load, topics 2 per first screen (D7) | 1 and 1; perf-live `dupes = []` | a unit test that counts fetches on a mock first screen (roster == 1, topics == 1), plus a CONTROL where the two reads start apart in time (the old code reads twice) | T001 |
| T005 | Trace W1: why `/lobby` shows its first message after ~5 s warm (D1, D2). Trace and count (lesson rule 2): what the feed waits on (socket open? a read chained after the roster? a long task?). Split `ws open` into "the app asks for the socket" and "the socket's connect and handshake". Re-measure W1..W3 from a second box (n >= 10, same WUI sha) before closing, so a box-link stall is not taken for a WUI cause (s109-3). Output a short doc with the trace and the fix shape; no code | `doc/specs/109-desktop-ui-refactor/w1-trace.md` (new) | any code | W1 5,004 ms, `ws open` 4,007 ms | the cause named with numbers, n >= 10, on two boxes | lint-mdlinks | T001; the drafting box's e2e login (rules) |
| T006 | Channel first page without the socket (FR-001), in the shape T005 names | named by T005; expected `wui/src/utils/channel-feed.mjs`, `wui/src/pages/lobby.vue`, `wui/src/pages/channel/*` | any hub file; `ChannelSidebar.vue` | W1 5,004 / W2 5,373 ms | W1 <= 1,500 ms median, n=10 | a unit test that the first page renders with the socket still closed, plus a CONTROL; baseline probe n=10 | T005 |
| T007 | A rail tab that does not change the route does not re-render panel 2 (FR-005) | `wui/src/components/ChannelSidebar.vue` (tab click handler only), `wui/src/pages/index.vue` | the rail markup (T015's) | Topics 1,152 / Channels 968 ms settled | <= 250 ms settled, n=10 | an e2e step in an existing file: DOM mutations in panel 2 after a same-route tab click == 0 | T003 (`index.vue`); c-563's `ChannelSidebar.vue` edits committed |
| T008 | Home shows the topic list once (FR-006; owner Q2 = yes: panel 1 shows Channels while panel 2 shows Topics) | `wui/src/pages/index.vue`, `wui/src/components/ChannelSidebar.vue` (default tab on `/` only) | the rail markup (T015's) | 2 lists (F1) | 1 list | e2e: on `/` panel 1 is not `sidebar-panel-topics`; phone unchanged | T007; workflow 10 green |
| T010 | Top bar: the language picker moves to the avatar menu and Settings -> Language (FR-008); the avatar menu shows Workspace settings only while the rail is collapsed (FR-009) | `wui/src/components/TopBar.vue`, `wui/src/components/UserMenu.vue` | the 107 header timer (do not move, restyle or rename it; the freed 171 px is the timer's room first); `FirstRunChecklist.vue` | 171 px picker (F4); 3 Workspace settings entries (F5) | 0 px in the bar; 1 entry | e2e: no `lang-switcher` in the top bar at 1440, the avatar menu has it; the picker stays `defineAsyncComponent` in `UserMenu.vue` (`UserMenu` is in the initial set); `ci_initial_gzip_kb` unchanged; phone unchanged | T001; **after c-566's 107 header timer lands on `TopBar.vue`**; workflow 10 green |
| T011 | Panel 3 header: one-line title with ellipsis, labelled controls (FR-011) | `wui/src/components/LiveTopicPane.vue` (header only) | `TopBar.vue` | raw 4-line text box, 3 unlabelled icons (F7) | 1 line; every control has `aria-label` and a tooltip | e2e: header height <= 48 px at 1440; every button has an accessible name | T001; workflow 10 green |
| T012 | Small fixes: the first-run card becomes a one-line chip once a step is done, and its Workspace settings link goes with it (FR-010, FR-009); plain header words (FR-013); the workspace box opens on `click` (FR-014) | `wui/src/components/FirstRunChecklist.vue`, `wui/i18n/locales/*.json` (the `subtitle` key and new keys only), `wui/src/components/TenantDropBox.vue` | `ChannelSidebar.vue`; `main.css` | 270 px card (F6); jargon (F8); `click()` opens nothing (F9) | <= 48 px; plain words; `click()` opens the list | an e2e for each item, in an existing file | T001; workflow 10 green |
| T013 | RUM on in prd (owner Q1 = yes): cnf `perf.rum_enabled` true for prd, rendered, deployed. **Lands first**, so RUM records a real before-week while the speed lanes build | `csi-spl-cnf/csi-spl/prd.env.yaml` (one key) and its rendered files | any WUI or hub file | prd 0 samples | `ENV=prd ./run -a do_spl_wui_perf_report` shows desktop groups after 7 days | `ENV=prd ./run -a do_tpl_gen`, then `git diff --exit-code`; the 066 L9 note in cnf updated | T001 (Q1 = yes) |
| T014 | After-numbers: the spec section 1 probes again (n=10) on the deployed round, plus RUM from T013, run on the drafting box (the e2e login) with the longest-connect column; a before / after table into `spec.md`, with a status per FR | `doc/specs/109-desktop-ui-refactor/spec.md` | any code | section 2 | every FR with its after-number, met or missed | lint-mdlinks | T002..T008, T010..T013, T015 |
| T015 | Rail divider and an optional "show labels" toggle (FR-012), split out of T012 (s109-4) | `wui/src/components/ChannelSidebar.vue` (rail block only), `wui/src/components/RailOrderSetting.vue`, `wui/src/assets/css/main.css` (the rail rules only), `wui/i18n/locales/*.json` (new keys only) | panel 1 lists; `index.vue` | no labels, no grouping (F3) | divider between the talk and workspace groups; labels toggle, default off | e2e: divider present, labels shown only when the setting is on; `css-color-tokens`; phone unchanged | T008; workflow 10 green |

## Status

| id | status |
|---|---|
| T001 | Implemented: v1.0 (c-567) |
| T009 | **Dropped**: owner Q3 = no (msg `272d5ffd`); the reply box stays in the top-bar omnibox |
| T004 | Implemented (c-567): a settled roster / topic-list read is kept for the first screen (10 s), any write drops it; unit: mock first screen roster 1, topics 1 (CONTROL, old live: 2 and 2). Live signed-in before/after: pending the drafting box's probe |
| T013 | Implemented: prd `perf.rum_enabled` true (c-580) |
| T005 | Implemented: [w1-trace.md](w1-trace.md) (c-581): W1 waits on the app boot and first render (CPU), not the socket; warm W1 on WUI `ce1461b5` 2,445 ms (drafting box loaded) / 1,250 (second box) / 844 (drafting box idle), n=10 each; T006 re-shaped to CPU (w1-trace.md section 5) |
| T002 | Implemented: `index.html` gated as `ci_home_gzip_kb` 351.2 KB (85 chunks, mock generate; all three counters agree), CONTROL: the old code read `200.html` only (c-566) |
| T003, T006..T008, T010..T012, T014, T015 | Planned |

<!-- last-edit: 2026-10-08T18:25:00Z — v1.0 fold of seats s109-2..4, c-567 -->
