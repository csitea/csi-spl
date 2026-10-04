# Desktop WUI usability: ranked spec ideas, 2026-10-04

Topic: t1 `3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed`. Owner HUM-10 (msg
faf578c3): *"ideas for specs to improve the UI usability on desktop wui"*.
Later in the same topic: ea6330ff (spec and build every starter idea except
split view), 81caeb42 and 44ff08f3 (the DoD is the git-spec), 7d842610 (a
consensus with a grok agent first).

This doc is the **evidence base** for the spec lanes. It changes no code. The
ranking merges c-002's ten starter ideas (msg 0b05a8f2) with what the walk
through the app measured; section 4 says what happened to each starter. The
mobile list is a sibling doc (`mobile-usability-ideas-20261004.md`, lane
c-246). An idea marked **also mobile** belongs in both.

## 1. How it was measured

| field | value |
|---|---|
| tree | worktree at `7289ef28` (origin/master, 2026-10-04) |
| bundle | `nuxi dev` with `NUXT_PUBLIC_USE_MOCK=1`, the e2e harness's mock tenant (`tests/e2e/lib/server.mjs`); member session HUM-1 |
| driver | headless Chrome (puppeteer-core 25), device scale 1, no touch |
| viewports | 1440x900 and 1920x1080 |
| when | 2026-10-04T21:01Z..21:08Z |
| n | one walk per task per viewport (n=1) unless a row says otherwise. Click and key counts are deterministic. Times come from a local mock and are only good for ranking things against each other |
| dev / prd | **not driven**. This lane cannot read prd, and dev was left alone. The mock has no hub, so anything that depends on the hub (read sync, live counts) is marked *mock caveat* |
| screenshots | `/var/tmp/c-245-shots/` (outside the repo) |
| code claims | each cites the command and its count, run in `csi-spl-wui/` |
| owner posts | the 32 desktop-UI posts c-002 relayed from the dispatcher transcripts (msg 7f75f5e5; keyword match, about 09-27..10-04). Cited by msg id |

### 1.1 Ten common tasks, measured at 1440x900

| # | task | what it takes today | keyboard-only path |
|---|---|---|---|
| T1 | switch channel | 2 clicks (Channels rail, then the row) when the left pane shows another section | none: `Ctrl+K` does nothing (focus stays on the rail button), `Alt+↓` does nothing (URL unchanged) |
| T2 | open the unread item | 2 clicks (Flow rail, then the row). The title `(1)`, the DM rail `1` and the Flow rail `1` clear together | no "next unread" key: `grep -rniE 'next.?unread' src \| wc -l` -> 0 |
| T3 | reply in a topic | 1 click on the card (the right pane opens and the box reads *"Reply — …"*), then `/`, type, `Enter` | `↑/↓` or `j/k` to the card, `Enter`, `/`, type, `Enter`. Works |
| T4 | find a message | `/`, then `/search scaffold`, then `Enter`: 8 keystrokes of prefix every time; the result is `/search?q=scaffold` | works, but there are no recent searches: `grep -rniE 'recent.?search' src \| wc -l` -> 0 |
| T5 | archive a topic | select the card, then `Shift+A` (1 click + 1 key); or ≡ then Archive (2 clicks) | works for one topic. N topics cost 2N actions: `grep -rniE 'multi.?select\|bulk\|selectedIds\|selection.?mode' src \| wc -l` -> 0 |
| T6 | open settings | 2 clicks (account menu, then Settings) | no key, no palette |
| T7 | read a doc | Docs rail (1 click), then the tree `csi-spl-doc › doc › help › <page>`: 4 clicks or more | no key, no palette |
| T8 | reach the first message card from page load | 35 `Tab` presses. The 8 DM rows take 16 stops (row + ≡ each), and there is no skip link: `grep -rniE 'skip-link\|skip to' src \| wc -l` -> 0 | no key to cycle the panes (F6-style) |
| T9 | back / forward | works: Back from `#feedback` reopened `/lobby?topic=…` with the right pane open | browser keys work |
| T10 | keep a half-written message | a draft typed in `#feedback` **is still in the box after switching to `#alerts`**. A full reload empties it (`""`) | n/a |

## 2. The ranked list

Rank = measured pain × how often it hits ÷ effort. "Owner pick" is ea6330ff's
pick from c-002's numbering.

| rank | title | problem, one line | effort | owner pick |
|---|---|---|---|---|
| 1 | **Command palette (Ctrl+K)** | channel, settings and docs take 2..4+ clicks each; `Ctrl+K` does nothing | M | yes (#3) |
| 2 | **Keyboard focus model + shortcut overlay** | 35 Tab stops to the first card; focus jumps panes after a shortcut (owner 55ad15bc, 8b1a5cc5) | M | yes (#4) |
| 3 | **Drafts per place** | one draft follows you between channels (send-to-wrong-channel risk) and a reload loses it | S | yes (#7) |
| 4 | **Wide-screen layout: line length + proportional panes** | at 1920 the topic pane stays 380 px while message lines run 1267 px wide; at 1440 it truncates the title and the sender | S | partly (#5) |
| 5 | **Next unread** | no key or button goes to the next unread place: 2 clicks through Flow each time | S | yes (#2) |
| 6 | **One unread model** | owner 92c4b3e8, da315c54: new/total vanished and views disagree; not reproduced in the mock (n=1) | M | yes (#1) |
| 7 | **Window identity for two screens** | every tab is titled `(1) spool-hub`, with no channel name and no "open in new window" | S | new |
| 8 | **Search ergonomics** | 8 keystrokes of `/search ` prefix per query, no recent searches, no search-this-channel key | S | new |
| 9 | **Density: compact / comfortable** | one-line cards sit 73 px apart at 1440; *List density* clips text but does not change spacing | S | yes (#9) |
| 10 | **Bulk actions** | archiving N topics costs 2N actions; no multi-select exists (grep -> 0) | M | yes (#8) |
| 11 | **Accessibility baseline** | no skip link; the omnibox placeholder is 4.0:1, under AA 4.5:1 | S | new |
| 12 | **Hover previews** (link-preview follow-up) | an id or spec reference shows nothing until you leave the page (owner 145297d8) | S | yes (#10) |
| 13 | **Clean list titles** (from the mobile list) | every Topics row, left and middle, starts `Topic:` and shows raw `**#lobby**` at 1440 | S | new, also mobile |
| 14 | **Web Push to a closed browser** (from the mobile list) | an alert fires only from an open tab; a closed browser hears nothing | L | new, also mobile |
| 15 | **Offline reading + instant first screen** (from the mobile list) | `sw.js` caches the shell only; a cold open waits for the network | L | new, also mobile |
| — | **Split view** | not now (owner ea6330ff) | — | **no** (#6) |

Top 5 for the owner post: 1 palette, 2 focus model, 3 drafts, 4 wide-screen
layout, 5 next unread.

## 3. The ideas

### 3.1 Command palette (Ctrl+K / Cmd+K)

| field | content |
|---|---|
| problem | T1, T6, T7: 2, 2 and 4+ clicks. `Ctrl+K` pressed on `/lobby` at 1440 opened no dialog, and focus stayed on the Channels rail button. `grep -rniE 'ctrl\+k\|cmd\+k\|quick.?switch\|command.?palette' src --include=*.vue --include=*.ts --include=*.mjs \| wc -l` -> 0. Screenshots: `channels-1440.png`, `docs-1440.png`, `user-menu-1440.png` |
| idea | `Ctrl+K` opens one box. Type to go to any channel, DM, topic, person, doc or settings page, ranked by recent use. A `>` prefix runs actions on the current selection: archive, mark read, new topic, move, toggle a pane, change theme. Each row shows its shortcut, so the palette also teaches the keys |
| standard practice | Slack `Ctrl+K`, Linear `Cmd+K`, GitHub `Ctrl+K`, VS Code `Ctrl+P` / `Ctrl+Shift+P` |
| effort | **M**. A new `CommandPalette.vue`, a pure `utils/palette.mjs` ranker (unit-testable), a hook in `layouts/default.vue`, and reuse of `stores/channel.ts`, `stores/roster.ts`, `utils/msg-menu.mjs` (the action list and its gating) and `utils/settings-nav.mjs` |
| risk / overlap | `SPEC-spool-wui-layout.md` §2.2 *Quick Switcher* specs it, unbuilt; no `specs/*` dir owns it. 075 (docs, c-240) adds docs to Omnisearch: the palette should take docs from that same source, not a second index. 022 (top-bar search) stays the full-text search; the palette only navigates and acts. Not mobile (no keyboard) |

### 3.2 Keyboard focus model + a complete shortcut overlay

| field | content |
|---|---|
| problem | T8: 35 `Tab` presses from load to the first card, with no skip link. Before the feed, the order runs through the top bar (8 stops), the rail and its links (4), a focusable section heading, 16 DM stops, the footer (3), the collapse toggle, the divider and one feed-header control. After a route change nothing moves focus: `layouts/default.vue:284` `router.afterEach` only closes panes. Owner posts: 55ad15bc (*"the focus after hitting Shift + H goes to the second panel, when it should stay in the 3rd panel"*), 8b1a5cc5 (*"on every keyboard shortcut on the left panel … the focus should go back to this panel"*), 37ecf872. Discoverability: `Shift+?` lists message shortcuts only (`shift-question-1440.png`); `/`, `Esc`, `j/k` and the divider keys are only in the help page. Owner 83c39d11 and 59425d3c asked for the shortcuts to be visible |
| idea | (a) One rule: a shortcut keeps focus in the pane where it was pressed, on the next sensible row. (b) `F6` / `Shift+F6` cycles the left, middle and right panes and the omnibox. (c) A skip link to the feed. (d) After a route change, focus goes to the new pane's first row or heading, and an `aria-live` region names the page. (e) The `Shift+?` overlay shows **every** key, grouped by pane, with the keys that work right now highlighted |
| standard practice | Slack (`F6` pane cycling, `Ctrl+/` overlay); Gmail and GitHub (`?` overlay); WAI-ARIA landmarks |
| effort | **M**. `stores/pane-focus.ts` (already owns the active pane), `composables/useMsgShortcuts.ts`, `utils/msg-shortcuts.mjs` (add `NAV_SHORTCUTS` groups), `components/MsgShortcutsHelp.vue`, `layouts/default.vue`, `utils/row-keys.mjs` |
| risk / overlap | Builds on the Shift+letter set (help `keyboard-shortcuts.md` §7). 050 §3.7 decided "no shortcut" for collapse (owner Q7), so F6 must not toggle collapse. **Also mobile** for (d) only |

### 3.3 Drafts per place

| field | content |
|---|---|
| problem | T10, measured: `half written draft` typed on `/channel/feedback`, then two full page loads, gave `""`. `spa draft` typed on `#feedback`, then a sidebar click to `#alerts`, left the box on `#alerts` holding `"spa draft"`, so `Enter` there posts it to the wrong channel. `grep -rniE 'draft' src/components/MessageComposer.vue \| grep -ci storage` -> 0 |
| idea | One draft per place (channel, DM, topic reply), kept across navigation and reloads (browser storage, keyed by workspace and place) and cleared on send. A pencil mark on the row or topic card that holds a draft. Optional: a *Drafts* entry in the palette or Flow |
| standard practice | Slack (per-channel drafts, *Drafts & sent*), Gmail, GitHub (comment drafts survive a reload) |
| effort | **S**. `components/MessageComposer.vue`, a pure `utils/drafts.mjs` (key, save, restore, prune), a mark in `ChannelSidebar.vue` / `MessageCard.vue`. The omnibox Teleport already keeps the text while the box moves (`useOmniboxDock.ts`) |
| risk / overlap | None specced. Follow the per-tenant prefs work (046 / SPL-1182) for the key shape. **Also mobile**: the mobile list (`mobile-usability-ideas-20261004.md` §3.3) adds an offline send queue on top (a message written without signal goes out when the connection is back). One spec should cover both, and sign-out must wipe stored drafts |

### 3.4 Wide-screen layout: readable lines and proportional panes

| field | content |
|---|---|
| problem | 1920x1080 with a topic open: left 260 px, middle 1268 px, **right 380 px (19.8 %)**. The middle message body is 1267 px wide, about 150 characters a line at the default size. At 1440x900 the same 380 px pane truncates the topic title (*"Typed at the ter…"*) and the sender (*"H…"*) while the middle has empty space (`topic-open-1440.png`, `topic-open-1920.png`). Owner 73f13491: *"the right pane content should be more centred into the screen"*. Resizing exists (`components/PaneDivider.vue`, `composables/usePaneWidths.ts`, one account-wide `pane_sizes`), but the default is a fixed 380 px at both sizes and is not kept per view. `grep -rniE 'max-width: *[0-9]+ch' src/components/MessageBody.vue src/components/MessageCard.vue \| wc -l` -> 0 |
| idea | (a) Message text gets a readable measure (about 80..100 ch), and the card's menu and open buttons sit next to the text, not at the far edge. (b) The right pane defaults to a share of the screen (for example 40 % of the space right of the sidebar), not 380 px. (c) Dragged widths are remembered **per view** (channel, Topics, Docs, Help). This absorbs starter #5: resize and collapse already exist |
| standard practice | GitHub (fixed content width), Linear (issue body measure), Slack (thread pane width remembered), Gmail (reading pane) |
| effort | **S**. `assets/css/main.css`, `components/MessageCard.vue` / `MessageBody.vue`, `composables/usePaneWidths.ts`, `utils/pane-widths.mjs` (store `{view: sizes}`), `stores/session.ts` |
| risk / overlap | 050 (collapse) is unchanged. `SPEC-spool-wui-layout.md` §1.2 still describes the old `spool.pane-widths` key; this spec should replace that section. Perf plan E28 touches the `usePaneWidths` resize listener, so coordinate with that lane. Owner b444a115 / efc6f54f (selected-card border) touch the same files. Not mobile |

### 3.5 Next unread

| field | content |
|---|---|
| problem | T2: 2 clicks through Flow per unread item, then back to Flow for the next. No key or button goes to the next unread place (grep -> 0). The "New messages" divider exists (`grep -c 'seat-divider' src/components/LiveFeed.vue` -> 4): the app knows *where*, but has no *go there* |
| idea | `Alt+Shift+↓` / `↑` opens the next / previous channel, DM or topic with unread at its divider and marks it read. A **Next unread** button in the feed header shows how many are left, and says so when none are |
| standard practice | Slack (`Alt+Shift+↓`, *All unreads*), Gmail (`j/k`), Linear inbox (`j/k`) |
| effort | **S**. A pure `utils/next-unread.mjs` over the counts `utils/flow-badge.mjs` / `stores/flow.ts` already hold, the key in `useMsgShortcuts.ts`, a button in `FeedHeader.vue` |
| risk / overlap | Starter #2 asked to land on the first unread with a new-since line: the line is built, so this is the rest of #2. Depends on 3.6 for counts that agree. **Also mobile** (the button) |

### 3.6 One unread model

| field | content |
|---|---|
| problem | Owner 92c4b3e8: *"the feature for showing how many new msgs out of total msgs in a topic … has disappeared"*; da315c54: *"both in the channel view and in the topics view and in the flows view"*. In the mock, opening the unread DM cleared the title `(1)`, the DM rail `1` and the Flow rail `1` together (n=1), so the disagreement did **not** reproduce (*mock caveat*: no hub, so no `GET/PUT /v1/me/reads` sync from `utils/read-sync.mjs`) |
| idea | One store computes unread per place from one cursor set. The rail badges, row badges, tab title, topic new/total and Flow all read it, and a unit test proves they agree for the same input |
| standard practice | Slack, Linear: one unread state behind every badge |
| effort | **M**. `stores/flow.ts`, `utils/read-cursor.mjs`, `utils/read-sync.mjs`, `utils/tab-title.mjs`, `utils/flow-badge.mjs`, and a hub read if the counts are server-side (062) |
| risk / overlap | **Running lane c-253** (topic new/total) is fixing the symptom, and spec 062 owns the server counts. Make this a follow-up of c-253, not a parallel lane. **Also mobile** |

### 3.7 Window identity for two screens

| field | content |
|---|---|
| problem | The owner works on two screens. Every tab is titled `(1) spool-hub`, whatever it shows (measured on `#alerts`, `#lobby` and `#feedback`), so two windows look the same in the taskbar and alt-tab. There is no "open this topic in a new window" (links do open in a new tab). Across tabs, read state moves only through the hub (about 5 s, `utils/read-sync.mjs`): `grep -rn BroadcastChannel src \| wc -l` -> 0. In the mock, tab B still showed `(1)` 6 s after the item was read in tab A (*mock caveat*: no hub) |
| idea | (a) Title `(<unread>) #channel · <topic> — spool-hub`. (b) A **Pop out** item on a topic opens `/t/<id>` in its own window, for the second screen. (c) Tabs share read cursors and drafts at once over `BroadcastChannel`; the hub stays the source of truth |
| standard practice | Slack (`#channel - Workspace` titles, threads in a new window), VS Code (file in the window title), Gmail (pop-out compose) |
| effort | **S**. `utils/tab-title.mjs`, `utils/msg-menu.mjs` (one item), a small `utils/tab-sync.mjs` used by `read-cursor.mjs` and the drafts util from 3.3 |
| risk / overlap | Split view (starter #6) is **not now** (owner ea6330ff). A pop-out window is the cheap way to put two topics side by side on two screens, so the owner should confirm it does not count as split view. Not mobile |

### 3.8 Search ergonomics

| field | content |
|---|---|
| problem | T4: each query costs `/`, 8 characters of `/search `, then the query. No recent searches (grep -> 0). Searching inside the open channel means typing `in:#name` by hand |
| idea | `Ctrl+Shift+F` (or a palette row) opens the box already in search mode. `Ctrl+F` with focus in a feed pre-fills `in:#<this channel>`. The empty search box lists the last 10 queries, per user |
| standard practice | Slack (recent searches, *search in this channel*), GitHub (scoped search pre-fill) |
| effort | **S**. `components/TopBar.vue`, `utils/search.mjs`, `stores/search.ts`, `components/SearchSidePanel.vue` |
| risk / overlap | 022 owns the search box (27 of 31 tasks done); 075 adds docs results. Take `Ctrl+F` only while focus is in the feed, never in a text field. **Also mobile** (recent searches) |

### 3.9 Density: compact / comfortable

| field | content |
|---|---|
| problem | At 1440 and font level 3, one-line cards sit 73 px apart (their menus at y 134, 207, 280 on `/lobby`), so a 900 px screen shows about 10. *List density* (`utils/card-clip.mjs`) clips the body to titles, rows or full text, but does not change spacing; no spacing setting exists (`grep -rniE density src --include=*.vue \| wc -l` -> 0) |
| idea | A *Compact / Comfortable* switch that changes padding, avatar size, and where the time sits (inline in compact). Fonts stay on the 5 levels (starter #9) |
| standard practice | Slack (compact), Gmail (Default / Comfortable / Compact), Linear (list density) |
| effort | **S**. CSS variables in `assets/css/main.css`, a setting next to `CardClipControl.vue` / `ViewPrefsSetting.vue`, stored with the view prefs (`utils/view-prefs.mjs`) |
| risk / overlap | Name it so it is not confused with *List density* (the clip), which help `user-settings.md` §4.3 already uses. Not mobile (phones stay comfortable) |

### 3.10 Bulk actions

| field | content |
|---|---|
| problem | T5: one topic is 1 click + `Shift+A`; ten topics are 20 actions. No multi-select exists (grep -> 0) |
| idea | `x` or a checkbox selects a row, and `Shift`-click selects a range, in Topics, a channel feed and Flow. A bar offers archive, mark read, move and delete, with one undo (the existing `UndoSnackbar`) |
| standard practice | Gmail (`x`, select all), Linear (`x`, `Shift`-click), GitHub issues (checkbox bar) |
| effort | **M**. `components/TopicListEdit.vue`, `MessageFeed.vue`, `FlowList.vue`, `useArchiveUndo.ts` / `useMove.ts` (batch), and a hub batch call or N calls |
| risk / overlap | The archive / move / delete rules (041, 045) stay per item: the bar offers an action only when every selected item allows it. **Also mobile** (long-press select) |

### 3.11 Accessibility baseline

| field | content |
|---|---|
| problem | No skip link (grep -> 0; see T8). The omnibox placeholder is Chrome's default `rgb(117,117,117)` on `rgb(10,20,36)`, **4.0:1**, under WCAG AA 4.5:1, and the placeholder carries the send-key hint. In good shape: `grep -c focus-visible src/assets/css/main.css` -> 17, and every Tab stop measured showed a 2 px solid ring; `grep -rl aria-live src --include=*.vue \| wc -l` -> 27; `grep -rl prefers-reduced-motion src \| wc -l` -> 12. One feed-header `<input>` (T8 stop 35) had neither an `aria-label` nor text for the probe to read; an axe run should confirm whether it has a name |
| idea | A skip link; a themed `::placeholder` at 4.5:1 or better in every theme; a name on every control; an axe-core pass in the e2e suite on `/lobby`, an open topic, `/search` and `/settings` at 1440, so a regression turns CI red |
| standard practice | GitHub (skip to content), WCAG 2.2 AA, axe in CI |
| effort | **S**. `assets/css/main.css`, `layouts/default.vue`, `components/FeedHeader.vue`, one e2e test |
| risk / overlap | 023 §3.5 has the contrast table (text 4.5:1, ring 3:1); extend it to placeholders. **Also mobile** |

### 3.12 Hover previews (a follow-up to link previews)

| field | content |
|---|---|
| problem | Owner 145297d8: *"there are only IDs for me so I cannot understand those IDs. I must be able to navigate … to get better context"*. Ids link now (help `omnibox-and-navigation.md` §8), but you see what is behind one only by leaving the page |
| idea | Hovering a topic id, message id or spec reference for 400 ms shows its first lines, author, place and time, from the same lookup as the link-preview cards |
| standard practice | GitHub (hover cards on issue and PR refs), Linear, Slack |
| effort | **S**. Reuse `utils/link-preview-lookup.mjs` and `components/LinkPreviews.vue`; a small `HoverCard.vue` hooked into `utils/id-links.mjs` |
| risk / overlap | **Running lane c-226** (link previews): start after it lands, as its follow-up. Desktop only (hover) |

### 3.13 Clean list titles (also mobile)

From the mobile list (`mobile-usability-ideas-20261004.md` §3.13), checked here at 1440.

| field | content |
|---|---|
| problem | On the Topics view at 1440x900, every row in the left list and in the middle starts with `Topic:`, and the lobby topic shows raw markdown: `Topic: Welcome to **#lobby**. …` (`topics-1440.png`). The prefix comes from `topic.list_title` = `"Topic: {text}"` (`i18n/locales/en.json:828`, used by `topicRowTitle` in `pages/index.vue:163`). In a 212 px left list it pushes every title onto one more line |
| idea | List rows show plain text (markdown stripped, or the topic's gist, spec 034) and no `Topic:` prefix in a list already headed "Topics" |
| standard practice | Slack (thread list), GitHub (notification list): plain titles |
| effort | **S**. `pages/index.vue`, a strip-markdown helper in `utils/`, the i18n key in every locale |
| risk / overlap | c-253 (topic new/total) works on the same rows, so rebase on it. `topics-view-retire-proposal.md` may remove this list; the strip helper is still needed for Flow and search rows. **Also mobile** |

### 3.14 Web Push to a closed browser (also mobile)

From the mobile list (§3.2). It applies on desktop too: the owner closes the tab or the browser.

| field | content |
|---|---|
| problem | Alerts fire only from a live tab (`utils/notify.mjs`, `new Notification`). With the browser closed, a mention or a DM reaches nobody until the app is reopened. `grep -rliE 'PushManager\|vapid' src \| wc -l` -> 0. Spec 062 Q4 defers "Web Push to a closed app" to a later spec |
| idea | A mention, a DM or a reply in a followed topic notifies through the OS even with no tab open; a click opens that message (the existing notify-open target). Per-channel mute and quiet hours apply |
| standard practice | Slack, GitHub, Linear (browser push per mention / DM, with do-not-disturb) |
| effort | **L**. Hub: a VAPID key pair (secret manager, never in git), a `push_subscriptions` table and migration, a sender on the events that make a Flow entry (062). WUI: `public/sw.js` (`push`, `notificationclick`), `stores/notification.ts`, the Notifications settings page |
| risk / overlap | A store migration (`PRE_PUSH_TIER=full`) and a new secret; touches 062 and 053 (live delivery). One spec for both lists. **Also mobile** |

### 3.15 Offline reading and an instant first screen (also mobile)

From the mobile list (§3.11). On desktop the gain is the cold open, not offline use.

| field | content |
|---|---|
| problem | `public/sw.js` keeps the shell HTML but no API reads, so a cold open shows the skeleton until the network answers. This walk took no cold-open timing worth citing (a dev server compiles on first load); the perf specs own real timings |
| idea | The last ~20 opened feeds and topics are kept on the device. They paint at once on open and refresh in the background; with no network they show read-only under an "offline, as of 14:02" line |
| standard practice | Slack, Gmail, Telegram desktop |
| effort | **L**. `public/sw.js` or an IndexedDB layer in `stores/channel.ts` / `stores/live.ts`, a size cap, a wipe on sign-out and on workspace switch |
| risk / overlap | Workspace data on the device. Overlaps 066 (perceived performance) and 070 on first-screen timing: measure with their metrics. One spec for both lists. **Also mobile** |

### 3.16 Themes with no new idea, and why

| theme from the brief | why |
|---|---|
| back / forward, deep links | T9 works, and help `omnibox-and-navigation.md` §8 documents every link target |
| loading states, perceived speed | `spa-loading-template.html` paints the shell with placeholders, and a sidebar channel switch painted its first card in 147..171 ms (mock, n=2). Spec 066 (answered 2026-10-03) and its build lanes own the metrics |
| operator console, docs editor, last-updated clock, topic new/total, link previews | running lanes c-250, c-240, g-254, c-253, c-226. 3.6 and 3.12 are follow-ups, not repeats |

## 4. c-002's starter list (0b05a8f2): what this doc did with each

| starter | decision | why (evidence) |
|---|---|---|
| #1 One unread model | **kept**, rank 6, as a c-253 follow-up | owner 92c4b3e8 / da315c54; not reproduced in the mock (n=1) |
| #2 Jump to the first unread | **changed** into rank 5 *Next unread* | the "New messages" divider is built (`seat-divider` -> 4); the next-unread key is missing |
| #3 Command palette | **kept**, rank 1 | T1, T6, T7; `Ctrl+K` -> nothing |
| #4 Keyboard-first navigation | **kept and widened**, rank 2 | T8: 35 Tab stops; owner 55ad15bc, 8b1a5cc5, 83c39d11 |
| #5 Resizable, remembered panes | **merged** into rank 4 | resize and collapse are built (`PaneDivider.vue`, 050); per-view memory and proportional defaults are missing |
| #6 Split view | **not now** | owner ea6330ff |
| #7 Drafts that survive | **kept**, rank 3 | T10: the draft follows you to the wrong channel and a reload loses it |
| #8 Bulk actions | **kept**, rank 10 | T5: 2N actions; no multi-select (grep -> 0) |
| #9 Density setting | **kept**, rank 9 | 73 px card pitch at 1440; must not clash with *List density* |
| #10 Hover previews | **kept**, rank 12, after c-226 | owner 145297d8 |

New from the walk: 3.4 (the wide-screen part), 3.7 window identity, 3.8
search ergonomics, 3.11 accessibility baseline. Taken from the mobile list
(c-246, marked also desktop there): 3.13 clean list titles, 3.14 Web Push,
3.15 offline reading; its drafts idea is merged into 3.3.

<!-- last-edit: 2026-10-04T21:22:47Z -->
