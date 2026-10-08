# 109 Desktop UI refactoring round: measured waits and friction, then small lanes

**Feature ID**: `109-desktop-ui-refactor` · **Milestone**: M3 · **Status**: v0.1 draft (seat s109-1), waiting for review seats
**Created**: 2026-10-08 · **Drafter / folder**: c-567 (seat s109-1) · **Topic**: t1 `2b61230c-0182-4b8e-baee-3476ae969a6d` · lane dispatch `dispatch-2b61230c`
**Authority**: this file for behaviour; [tasks.md](tasks.md) for what is built. Docs only: this spec builds nothing (`../README.md` §2.4). Every FR below is **Planned**.

**Scope: the desktop web app only** (viewport wider than `MOBILE_STACK_MAX_PX`). Phone layouts do not change. A task that edits a component the phone also renders must show the phone e2e unchanged (tasks.md rules).

Builds on, and does not change:
- [027 performance](../027-spool-performance/spec.md): the initial-chunk budget (`ci_initial_gzip_kb` 155 KB).
- [066 perceived-performance metrics](../066-perceived-performance-metrics/spec.md): the RUM metrics M1..M8 and `do_spl_wui_perf_report`.
- [081 command palette and pane keys](../081-command-palette-and-pane-keys/spec.md), [103 vim navigation](../103-vim-navigation/spec.md): keys are theirs. This round adds no key binding.
- [099 topic head](../099-topic-head/spec.md): the hub side of the topic list (`topic_heads` is `shadow` on prd today). This round does not touch the hub.
- [107 hours tracking](../107-hours-tracking/spec.md): its settings and header-timer lanes are live; no 107 file is touched.
- [082 clean list rows](../082-clean-list-rows/spec.md), [084 compact row spacing](../084-compact-row-spacing/spec.md): the row look.
- [Lesson: measure first](../../doc/md/lesson-speed-up-measure-first.md): every task below starts from a number and ends with the same number measured again.

---

## 0. The owner's ask (verbatim, HUM-10, t1 `2b61230c`)

| msg | text |
|---|---|
| `69b3d3e4` | "ui refactoring round" |
| `47da0ecf` | "for more user friendly, slick and fast UI on the desktop web interface" |

Reading: three goals, each with a number. **Fast** = the waits in section 2 get shorter. **Slick** = fewer re-renders and less noise on screen. **User friendly** = the common flows of section 3 have no duplicate or dead UI, and the reply box sits where the thread is.

---

## 1. How it was measured

| what | value |
|---|---|
| date | 2026-10-08, 16:44..17:23 UTC |
| host | the prd **e2e** workspace host (`https://e2e.<domain>`), never the apex (the apex is the owner's t1) |
| viewport | 1440 x 900, headless Chrome, CPU 1x, the drafting box's network |
| WUI | `3.6.9`, `bd165b424448daa1703d5ae175ed75e02fb715ca` (`<host>/build.json`) for every run |
| hub | `3.6.7` `eabfa288` for the runs before ~17:01Z (first load, Flow, baseline); `3.7.0` `6dddb0f44af5` for the perf-budget run at 17:23Z (`api.<domain>/version`). The panel-switch run at 17:12Z is on one of the two: the hub rolled in between |
| tree | `0b38b6ff3` (origin/master at the start) |
| member | the env's m3-e2e test member (a business owner in e2e) |
| raw evidence | `/var/tmp/spec109/` on the drafting box: `fl-warm/`, `fl-cold/`, `flow/`, `baseline/`, `live/`, `sw/`, `perf-budget.json`, `flows/`, `audit/`, and a `*.log` per run |

Commands (all read-only, except `SEND=1`, which writes 10 messages into e2e `#lobby`):

```
ENV=prd PF_N=10 PF_PROFILES=d1440 PF_COLD_CACHE=0|1 ./run -a do_spl_wui_perf_first_load
ENV=prd PF_N=10 PF_PROFILES=d1440 ./run -a do_spl_wui_perf_flow_events
BASE=https://e2e.<domain> TENANT=e2e N=10 PROFILES=d1440 SEND=1 node tests/e2e/perf-baseline-live.proof.mjs
ENV=prd TENANT_ID=e2e DRY_RUN=0 PERF_EMAIL=<e2e member> ./run -a do_spl_perf_budget
/var/tmp/spec109/switch.mjs   rail tab click -> panel visible / DOM settled (400 ms quiet), n=10 per tab
/var/tmp/spec109/flows.mjs    the common flows of section 3, clicks and keys counted, n=1 each
```

### 1.1 Real-user (RUM, spec 066) data: prd has none

| env | rows in `wui_perf_samples` | why |
|---|---|---|
| prd | **0, ever** (`ENV=prd ./run -a do_spl_db_query`, `select device, metric, count(*) ... group by 1,2` -> 0 rows) | cnf `perf.rum_enabled` is off on prd: "prd stays off until the 3 % overhead A/B passes on dev (lane L9 flips it)" (`csi-spl-cnf/csi-spl/prd.env.yaml`) |
| dev | 1,042 desktop + 278 phone, 2026-10-03..08 | on since 066 L5 |

`do_spl_wui_perf_report` for prd t1 needs a workspace-admin login that the drafting box does not hold (403 for the m3-e2e member); for prd e2e it returns 0 groups. So **every prd number below is a lab number**. Dev RUM, desktop, all builds (under n = 100 a 066 round must not plan from a row; it is shown for the order only):

| metric | p50 ms | p75 ms | p95 ms | n |
|---|---|---|---|---|
| `load_messages` cold | 3,752 | **6,180** | 12,105 | 73 |
| `switch_view` topic | 1,418 | 1,524 | 1,698 | 20 |
| `load_rail` cold | 674 | 1,203 | 2,616 | 36 |
| `load_rail` warm | 542 | 765 | 1,610 | 77 |
| `load_messages` warm | 560 | 709 | 1,356 | 29 |
| `switch_view` channel | 154 | 256 | 532 | 6 |
| `send_ack` | 138 | 218 | 259 | 15 |
| `inp` | 40 | 56 | 144 | 527 |
| `type_next_paint` | 20 | 34 | 89 | 88 |
| `scroll_jank` (longest gap) | 17 | 20 | 61 | 61 |

Dev RUM agrees with the prd lab on the order: **messages after a load** and **switching to a topic** are the slow moments; typing and scrolling are fine. Owner question Q1 asks to switch RUM on in prd, so that this round's before and after come from real users.

---

## 2. The measured waits (prd e2e, desktop 1440)

Ranked by the median a user waits. WUI `bd165b42` throughout; hub per section 1.

| # | wait | median | p90 / p95 | n | probe |
|---|---|---|---|---|---|
| W1 | `/lobby` (a channel) to its **first message, warm cache** | **5,004 ms** | p95 11,074 | 10 | baseline `warm first msg` |
| W2 | `/lobby` to its first message, cold cache | **5,373 ms** | p95 10,021 | 10 | baseline `cold first msg`; LCP 6,248, TTI 7,081, TBT 1,628 |
| W3 | `/` (home) to the first topic row, cold | **4,942 ms** | p95 7,504 | 10 | baseline `cold / first topic row` |
| W4 | click the **Topics** or **Channels** rail tab until the page stops changing | **1,152 / 968 ms** | p90 1,248 / 1,174 | 10 each | `switch.mjs` settled; the panel itself shows in 85..88 ms. DM and Flow settle in 62..64 ms |
| W5 | client route to `/` until the topic list shows | **977 ms** | p95 1,703 | 10 | baseline `topic list` |
| W6 | first load to the rail, warm / cold | 882 / 1,053 ms | p90 1,096 / 2,544 | 10 / 10 | first-load `rail` |
| W7 | Issues tab settled; Calendar route settled | 725 / 857 ms | p90 969 / 1,343 | 10 | `switch.mjs` |
| W8 | click a topic row until the pane shows a message | 541 ms | p95 914 | 10 | baseline `open topic` |
| W9 | send until hub-confirmed (`data-pending` gone) | 544 ms | p95 1,188 | 10 | baseline `send confirmed`; shown at 327 ms |
| W10 | `/search?q=probe` to results | 709 ms | p95 29,731 | 10 | baseline `search`; one outlier of ~30 s |

Facts behind them (same runs):

| # | fact | number |
|---|---|---|
| D1 | W1 is barely better warm than cold, so the wait is not the download | warm 5,004 vs cold 5,373 ms |
| D2 | the hub socket opens late, and the first message comes after it | `ws open after nav` 4,007 ms median (p95 7,816), n=10 |
| D3 | the **prerendered `/` page preloads 85 JS chunks, 349.8 KB gzip**; `200.html` and `/lobby` preload 3 chunks, 154.5 KB | the `perf-budget.py` set rule (`<script src>` + `modulepreload`) applied to the live `/index.html` and `/200.html`, gzip level 6 |
| D4 | the CI budget reads only `200.html`, so it **cannot see D3** (`perf-budget.py` line 120: `html_path = os.path.join(pub, "200.html")`); the live check fails on prd: `dev_initial_gzip_kb` 350.2 > 241.5 | `do_spl_perf_budget` prd, n=12 |
| D5 | the CI gate is red today at 155.1 KB > 155 (gate run `37804341298`, as the brief states it; not re-run here) | `perf-budgets.json` `ci_initial_gzip_kb` 155.0 |
| D6 | a cold `/lobby` makes **322 requests**, 243 of them JS (857 KB on the wire), 15 API reads | baseline `cold requests`, `cold total KB` |
| D7 | duplicate reads: `GET /v1/view/roster` twice per load, `GET /v1/view/topics` twice per first screen | perf-live `dupes` (roster n=2 per load); flow timing `first-screen`: roster n=19, topics n=20 for 10 rounds |
| D8 | two callers read the roster: `utils/spool-client.mjs` (lines 670, 684) and `utils/avatar.mjs` (line 216) | `grep -rn view/roster csi-spl-wui/src` |
| D9 | the hub is not the wait: view reads p50 34..55 ms, p95 52..193 ms | `do_spl_perf_budget` prd, n=12 |

**Top 5 waits for the round**: W1/W2 (channel first message ~5 s), W3 (home first row ~4.9 s cold), D3 (home preloads 350 KB), W4 (Topics / Channels tab 1.0..1.2 s re-render), D7 (duplicate first-screen reads).

---

## 3. Friction audit (desktop 1440, prd e2e)

### 3.1 Clicks and keys per common flow

n=1 each (`flows.mjs`), screenshots under `/var/tmp/spec109/flows/`.

| flow | path today | clicks | keys | time to the result | screenshot |
|---|---|---|---|---|---|
| open a DM | rail DM tab -> person row | 2 | 0 | 1.3 s | `dm-3.png` |
| reply in a thread | Topics tab -> topic row -> `/` to focus -> type | 2 | 1 + text | pane 0.5 s; the composer is then the **top bar**, ~900 px from the thread | `reply-5.png` |
| find a message | `/` -> type `/search probe` -> Enter | 0 | 2 + 13 chars | 1.8 s | `search-4.png` |
| switch workspace | workspace box -> pick | 2 | 0 | list 0.6 s | `workspace-1.png` |
| open settings | avatar -> Settings | 2 | 0 | 0.8..2.2 s (n=2) | `settings-3.png` |
| command palette | Ctrl+K | 0 | 1 | 0.4 s | `palette-1.png` |

The counts are already low. The friction is in what is on screen and where the reply box is, not in the number of clicks.

### 3.2 Friction items (ranked by how often a user meets them)

| # | item | evidence |
|---|---|---|
| F1 | **Home shows the same topic list twice**: the left panel (Topics) and the centre list hold the same rows in the same order; the left wraps titles to 5 lines in 212 px | `/var/tmp/spec109/audit/01-shell.png`, `01-shell.tsv` |
| F2 | **Reply box far from the thread**: a reply is typed in the top-bar omnibox (x 243..1085, y 7), the thread is in the right pane (x 970..1440); the only cue is a chip "Reply · <title>" in the omnibox | `flows/reply-5.png` |
| F3 | **Rail of 11 unlabelled icons plus 3 links** (Channels, DMs, Issues, Topics, Flow, Event log, People, Agents, Boxes, Calendar, Archive; Help, Docs, Workspace settings); labels only on hover | `01-shell.tsv`, rows `sidebar-tab-*` |
| F4 | **The language picker takes 171 px of the top bar** (x 1207..1378) on every page, for a setting changed about once; it is also in Settings -> Language | `01-shell.tsv` `lang-switcher`; `flows/settings-3.png` |
| F5 | **Workspace settings in three places** on one screen: rail gear, avatar menu, first-run card | `flows/settings-1.png`, `audit/01-shell.png` |
| F6 | **The first-run card keeps 270 px** (of 842) at the top of home with 2 of 3 steps done | `audit/01-shell.png` |
| F7 | **Thread pane header** is the opening's raw text in a box (4 lines, cut mid-word) plus three unlabelled icon buttons | `flows/reply-3.png` |
| F8 | **Jargon in the centre header**: "Topics · read-only · workspace-scoped" | `audit/01-shell.png` |
| F9 | The workspace box opens only on `mousedown`; a scripted or assistive `click()` opens nothing (the probe's synthetic click got no list; a real mouse press did) | `csi-spl-wui/src/components/TenantDropBox.vue` line 26 (`@mousedown`) |

Checked and kept: Ctrl+K palette (1 key, 0.4 s), `/` to focus, DM in 2 clicks, the Settings sections.

---

## 4. Requirements

| FR | requirement | answers | before -> target |
|---|---|---|---|
| FR-001 | A channel shows its first message without waiting for the hub socket: the first page comes from the view read, the socket only adds live rows. The task first traces W1 and names the cause (lesson rule 2); if the trace points elsewhere, the trace wins | W1, W2, D1, D2 | warm 5,004 -> **<= 1,500 ms** median (n=10) |
| FR-002 | The CI budget measures **every prerendered document** (`index.html` and `200.html`), each against its own ceiling | D3, D4 | home not gated -> gated |
| FR-003 | The prerendered `/` preloads no more than `200.html` does plus the home page's own chunk | D3, W3 | 349.8 -> **<= 175 KB** gzip; W3 4,942 -> <= 2,500 ms |
| FR-004 | One read per resource per load: roster and topics are each fetched once on the first screen | D7, D8 | 2 -> **1** per load; perf-live `dupes = []` |
| FR-005 | A rail tab that does not change the centre does not re-render it | W4 | Topics 1,152 / Channels 968 -> **<= 250 ms** settled |
| FR-006 | Home shows the topic list once (Q2 decides which panel gives way) | F1 | 2 lists -> 1 |
| FR-007 | A reply is typed in a box docked at the bottom of the thread pane (Q3); the top omnibox stays for new topics and search | F2 | ~900 px away -> in the pane |
| FR-008 | The top bar holds the workspace box, the omnibox, the notification controls and the avatar. The language picker moves into the avatar menu and Settings | F4 | 171 px freed |
| FR-009 | Workspace settings has one entry on screen (the rail gear); the avatar menu keeps it only while the rail is collapsed | F5 | 3 -> 1 |
| FR-010 | The first-run card shrinks to a one-line chip once any step is done, and goes away when all are done | F6 | 270 -> <= 48 px |
| FR-011 | The thread pane header shows the topic title on one line (ellipsis) and labelled controls (tooltip and `aria-label`) | F7 | raw text box -> title line |
| FR-012 | The rail gets a visible divider between talk (Channels, DMs, Topics, Flow, Issues, Calendar) and workspace (Event log, People, Agents, Boxes, Archive), and a "show labels" toggle, default off | F3 | 0 labels -> optional labels |
| FR-013 | Plain words in headers: no "read-only · workspace-scoped" | F8 | i18n keys only |
| FR-014 | The workspace box opens on `click` (keyboard and assistive tech included), not only on `mousedown` | F9 | `click()` opens nothing -> opens |

Non-goals: new features, new key bindings (081, 103), hub changes (099), phone layouts, a colour or theme redesign.

### 4.1 Budget rule for this round

D5: the CI gate is at 155.1 KB, red. **No task may add initial JS** unless the same commit removes at least as much (measured with `perf-budget.py bundle`). FR-003 and FR-004 are expected to free room; they land first.

---

## 5. Review table

| seat | agent | verdict | changes asked | file / msg |
|---|---|---|---|---|
| s109-1 | c-567 (claude, drafter) | draft v0.1 | - | this file |
| s109-2 | a-574 (agy) | agree with changes | 1. Make T007 depend on T003 (both own `index.vue`, preventing parallel conflict). 2. Recommend Q1(a), Q2(a), Q3(a). | this file |
| s109-3 | grok | pending | | |
| s109-4 | c-565 (claude, integration) | agree with changes | 1. **The lane map cannot see a 109 collision today**: c-566, c-568 and c-563 carry `files: []` (`lane-map.sh --json`), so `--check` says `free` for every path here, `TopBar.vue` included. Rule for every 109 lane: `lane-map.sh put --files <its owned files>` at spawn and `--check` them before the first edit; a `free` against an empty row proves nothing. 2. **T002 waits for c-568** (AC-02, live): c-568 changed `perf-budget.py` on trunk at `4b1ed47de` (node zlib gzip). T002 starts after c-568 is done and builds on that sha; D4's "line 120" is now line 137. 3. **There are three initial-byte counters, not two**: `perf-budget.py:137`, `bundle-size.mjs:37` and the e2e `tests/e2e/calendar.test.mjs:71` (AC-02, `INITIAL_KB = 155` hard-coded at line 32). Add `calendar.test.mjs` (AC-02 block only) to T002's owned files, or state that AC-02 stays on `200.html`; otherwise the three disagree again, the defect `4b1ed47de` just fixed. 4. **The 155 KB gate is c-568's, not 109's**: T002/T003 never touch `ci_initial_gzip_kb` (T003's 175 KB is the new `ci_home_gzip_kb` only, and its gate shows `ci_initial_gzip_kb` unchanged, since `nuxt.config.ts` also shapes `200.html`); no UI lane (T008..T012) starts while workflow 10 is red on trunk. 5. **T010 after c-566, and the timer is 107's**: `TopBar.vue` is c-566's file until its header timer lands (107 Q7 = B; its task is not on trunk yet, `grep -c T019 107-hours-tracking/tasks.md` -> 0). Once it lands, T010 must not move, restyle or rename the timer element: the 171 px the picker frees is the timer's room first. 6. **T010 keeps the picker lazy**: `LanguageSwitcher.vue` (493 lines) is `defineAsyncComponent` today (`TopBar.vue:105`), and `UserMenu` is in the initial set (`TopBar.vue:97`). In `UserMenu.vue` it stays `defineAsyncComponent`; gate: `ci_initial_gzip_kb` unchanged. 7. **FR-009's third entry is in T012's file**: the first-run card's settings link is `FirstRunChecklist.vue`, which T012 owns, not T010. Move that part of FR-009 to T012. 8. **FR-012 is under-owned**: T012 owns only `main.css` for the rail divider and the "show labels" toggle, but the toggle needs `ChannelSidebar.vue` markup and a setting (none exists: `grep -rn showLabels csi-spl-wui/src` -> 0; the rail setting is `RailOrderSetting.vue`). Split FR-012 into T015, owning `ChannelSidebar.vue` (rail block), `RailOrderSetting.vue` and the `main.css` rule, after T008. 9. **Serialise `ChannelSidebar.vue` (2,294 lines)**: T007 -> T008 -> T015, and none of them starts while c-563@sat (sidebar clock gap, live) holds uncommitted edits to it (`git -C …/c-563 status` -> `M ChannelSidebar.vue`). Seconds seat 2: T007 after T003 (`index.vue`). 10. **Each task names what it must not touch**: T002 no WUI component; T003 no `ci_initial_gzip_kb` raise and no `perf-budget.py`; T004 no store or hub file beyond the two readers; T007/T008 not the rail markup (T015's); T009/T011 not `TopBar.vue`; T010 not the 107 timer, not `FirstRunChecklist.vue`; T012 not `ChannelSidebar.vue`. **Q1**: (a), and land T013 first, so RUM records a real before-week while the speed lanes build. **Q2**: (a). **Q3**: (a), with the box lazy (T009 already says so). | this file |

The fold (v1.0) takes every change that two or more seats agree on; a single-seat change is listed with the reason it was kept or dropped.

---

## 6. Owner questions

Each carries the drafter's recommendation; the build follows it unless the owner answers otherwise.

| # | question | options | recommendation | changes task |
|---|---|---|---|---|
| Q1 | Switch real-user timing (spec 066 RUM) **on in prd** now, so that this round is ranked and proved on real desktop users? prd has 0 samples; the 066 overhead A/B (L9) has not cleared it yet | (a) yes, prd on now; (b) wait for 066 L9 | **(a)**: the collector is fire-and-forget and lazy (066 section 4.0); without it every prd number stays a lab number | T013 |
| Q2 | Home shows the topic list twice (F1). Which one goes? | (a) the left panel shows Channels while the centre shows Topics; (b) the centre shows the selected topic's messages and the left keeps the list; (c) keep both | **(a)**: the centre has the room (1,133 px) for title, people and count; the left at 212 px wraps titles to 5 lines | T008 |
| Q3 | The reply box (F2): docked at the bottom of the thread pane, or keep the single top omnibox? | (a) docked in the pane; the omnibox keeps new topics and search; (b) keep the top omnibox only | **(a)**: the reply is typed where it is read | T009 |

<!-- last-edit: 2026-10-08T17:40:00Z — v0.1 draft, c-567 -->
