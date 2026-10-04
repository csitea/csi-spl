# Mobile usability: 14 spec ideas, ranked (2026-10-04)

Owner request (HUM-10, prd t1 topic `c893c3a9`, msg `cb3a56c0`): "ideas for specs to improve the ui usability
for mobile". Owner DoD (msg `44ff08f3`): "the DoD for this discussion will be the ready specs to implement".

This doc is step 1, the ranked list. It is measured on top of what spec 043 (`specs/043-spool-wui-mobile`) has
already built: one panel at a time, the docked composer, the long-press sheet, swipe to archive and to hide, and
the 44 px pass. Every idea here is something that is **not** built and **not** specced. Where an idea overlaps a
spec or a running lane, the overlap column names it. c-002's ten starter ideas (msg `8c8322a1`) are folded in,
each kept, changed, merged or dropped, in §4.

The desktop list is c-245's (topic `3a74320e`). Ideas that apply to both are marked **also desktop**.

## 1. How it was measured

| field | value |
|---|---|
| build | WUI `v1.1.3` (footer), mock tenant (`NUXT_PUBLIC_USE_MOCK=1`, `pnpm run generate`, served by `serve-generated.mjs`) |
| tree | `7289ef28` |
| viewports | 390x844 and 360x780, `isMobile` + `hasTouch`, headless Chrome (puppeteer-core); taps are `page.tap` / CDP touch events |
| keyboard | emulated by shrinking the viewport to 390x508 (844 minus a 336 px keyboard); **not** a real keyboard |
| n | 1 walk per task per width |
| not done | no real phone was reachable, and dev was not driven (the mock was enough for layout and step counts). A real-phone pass is the first task of every spec built from this list. |
| screenshots | `/var/tmp/c-246-shots/` on the measuring box (35 files, outside the repo) |

The control inventory counts every visible `a`, `button`, `input`, `textarea`, `[role=button]` and tab, with its
box. The task walk counts taps from the screen named in the row.

### 1.1 Common tasks, taps at 390x844

| # | task | taps | what the taps are | a chat app (Slack mobile) |
|---|---|---|---|---|
| 1 | open the unread item from a cold start | 2 | DM row, then the `1 >>` reply link (the unread is a reply in the DM's thread) | 1-2 |
| 2 | reply in a topic, from a cold start | 5 + typing | Channels, `#lobby`, the card, the box, Send | 4 |
| 3 | find a message | 2 + typing **`/search `** | the box, type `/search <terms>`, Enter. `/` sits on the phone keyboard's symbol layer. No search button exists at 390 px | 1 (search tab) + typing |
| 4 | switch channel (`#lobby` to `#feedback`) | 2 | Back, the row | 2 |
| 5 | archive a topic | 1 swipe, or 2 taps | swipe left (no hint on screen), or the menu and Archive | 2 |
| 6 | open a settings section | 3 | avatar, Settings, the section | 3 |
| 7 | read a doc | 3 or more | swipe the section strip (Docs sits at x = 711 px on a 390 px screen), Docs, the file | n/a |
| 8 | change the text size | 4 | avatar, Settings, Appearance, `+` | 3-4 |
| 9 | come back to the channel you were in after reopening the app | +2 to +3 | the app always reopens on level 1 (`/`, Messages tab), so Channels, the row (and the card for a topic) again | 0 (it reopens where you were) |

### 1.2 What the inventory found

| finding | measured | screenshot |
|---|---|---|
| sender names in a card header | **30 px of 126 px** shown at 390 (`CLE-07@box-a` reads `C…`); 31-46 px at 360. Both the sender and the recipient share one row with the avatar, the AI badge, the kind, the status, the time, the emoji and the menu | `w5-topic-390.png`, `w5-topic-360.png` |
| section strip | a looping carousel of 13 entries (10 sections + help, docs, workspace settings); about 5 are on screen at 390. Settings (gear), Event log, People, Agents, Boxes, Archive, Help and Docs need a sideways swipe. It is at the top of the screen | `w1-02-channels.png` |
| search | the 390 px top bar holds About, the workspace, the avatar. No search button: `help/omnibox-and-navigation.md` §9 still says "The search icon in the top bar opens search as a full-screen sheet" (stale since 043 T056) | `390-_.png` |
| message sheet | 10 rows; for a member who is not the topic starter, **5 are disabled**, each with a 78 px explanation. Reply is the top row (y = 226), Delete the bottom row (y = 758, the easiest thumb spot) | `w3-T5-menu-sheet.png` |
| keyboard up (emulated) | of 508 px left, the top bar (58) + topic header (55) + composer block (~83) + status strip (~21) take ~200 px (~40 %); ~2 cards of feed show | `w3-keyboard-508.png` |
| under-44 px controls left after 043 | the status strip (connection, alerts, chime, version: 44x21 each), the two composer grips (48x24, 44x24), the Flow filter chips (26 px tall, 5 of them), the kind badge (26x18) | `390-_lobby.png`, `w1-03-flow.png` |
| pull to refresh | `base.css` lines 45 and 57 set `overscroll-behavior: none` on `html, body, #__nuxt`, which also turns off the browser's own pull-to-refresh; there is no in-app one (`grep -rniE 'pull.?to.?refresh' csi-spl-wui/src` -> 0) | n/a |
| offline | `sw.js` caches only the app shell HTML ("/api/** is never cached", its header). A send over a dropped socket is resent once, then shown with Retry, with the text held in memory only (`stores/channel.ts` ~440-460). No draft survives a killed tab (`grep -c localStorage MessageComposer.vue` -> 0) | n/a |
| notifications | alerts fire only from a live tab (`help/user-settings.md` §6). No Web Push: `grep -rliE 'pushmanager\|vapid' csi-spl-wui/src csi-spl-api/src` -> 0 files. Spec 062 Q4: "Web Push to a closed app is a later spec" | n/a |
| install | `manifest.webmanifest` is complete (standalone, 192/512/maskable icons), but nothing invites the install: `grep -rc beforeinstallprompt csi-spl-wui/src` -> 0 | n/a |
| list titles | the Topics list shows raw markdown (`Topic: Welcome to **#lobby**.`) and prefixes every row with `Topic:` (`i18n/locales/en.json` `topic.list_title`) | `w1-01-topics.png` |
| feed order | the default is newest first, so in a topic the newest reply is at the top, the farthest point from the composer, and the opening message sits next to the composer. The order is a per-user setting (`user-settings.md` §5.3) | `w5-topic-390.png` |
| reopen | after `/channel/feedback`, opening `/` (the manifest's `start_url`) lands on level 1, Messages tab: the place is lost | n/a |

## 2. The ranked list

Rank = how often a phone user meets the problem x how strong the evidence is, divided by the effort. Top 5 first.

| rank | title | problem in one line | effort |
|---|---|---|---|
| 1 | Readable card header on phones | sender names show 30 of 126 px at 390: you cannot tell who wrote a message | S |
| 2 | Push notifications to a closed app (also desktop) | no alert reaches a phone unless a spool tab is alive; Web Push is unbuilt (062 deferred it) | L |
| 3 | Drafts that survive, and an offline send queue (also desktop) | a draft or a failed send lives in memory only; a phone that kills the tab loses the text | M |
| 4 | Reopen where I left off | the installed app always reopens on level 1: +2 to +3 taps to get back to the channel or topic | S |
| 5 | Search and sections within thumb reach | search needs typed `/search`; 8 of 13 sections sit off-screen in a top carousel | M |
| 6 | A message sheet ordered for the thumb | 5 of 10 sheet rows are disabled for a member; Reply is at the top, Delete at the bottom | S |
| 7 | Keyboard-up focus mode | with the keyboard up, ~40 % of the screen is chrome and ~2 cards show | S |
| 8 | Pull to refresh | `overscroll-behavior: none` kills the browser's own pull-to-refresh and there is no in-app one | S |
| 9 | The last under-44 px controls, and the audit gap | status strip 44x21, Flow chips 26 px, grips 24 px, kind badge 26x18 still ship | S |
| 10 | Invite the install (PWA) | the manifest is ready, but nothing tells a phone user to install; iPhone alerts need the install | S |
| 11 | Offline reading and an instant first screen (also desktop) | without signal every feed is empty; a cold open waits for the network before the first list | L |
| 12 | Newest-last by default on phones | the newest reply sits farthest from the composer and the thumb | S |
| 13 | Clean list titles (also desktop) | Topics rows show raw `**markdown**` and a `Topic:` prefix on every row | S |
| 14 | Swipe hints and a "mark read" swipe | swipes are built but invisible: nothing on a card hints them | S |

## 3. The ideas

### 3.1 Readable card header on phones

| field | content |
|---|---|
| problem | At 390 px the sender name shows 30 px of 126 px (`CLE-07@box-a` reads `C…`), at 360 px 31-46 px. One row carries avatar, sender, AI badge, arrow, recipient avatar, recipient, kind, status, time, emoji and menu (`w5-topic-390.png`). Every card on every screen has it. |
| idea | On phones the header shows the sender's full name and the time on the first line. The recipient, kind and status go to a second, smaller line, or are dropped where the screen already says them (a DM, or the topic you are in). The `@box` suffix can wrap or be shortened. |
| standard practice | Slack, WhatsApp and Teams mobile: name + time, nothing else on that line. |
| effort | **S**. `components/MessageCard.vue` (the header template and its <= 820 px CSS), plus a 390/360 check in an e2e test. |
| risk / overlap | Revisits 043 T022 ("a one-row card header at 360 px") and T058 (the 4 px avatar). The link-preview lane (c-226) touched `MessageCard.vue` recently: rebase on it. Desktop unchanged. |

### 3.2 Push notifications to a closed app (also desktop)

| field | content |
|---|---|
| problem | Alerts fire only from a live tab (`user-settings.md` §6). A phone suspends a background tab, so a mention or a DM reaches nobody until the app is opened. 0 files hold `PushManager`/VAPID code; spec 062 Q4 defers "Web Push to a closed app" to "a later spec". On an iPhone, web push works only for an installed app (idea 3.10). |
| idea | Notify on a mention, a DM and a reply in a topic you follow, even with the app closed. A tap opens that message (the existing notify-open target). Per-channel mute (exists) and quiet hours apply. |
| standard practice | Slack, GitHub mobile, Linear: push per mention / DM / followed thread, with a do-not-disturb schedule. |
| effort | **L**. Hub: a VAPID key pair (secret manager, never in git), a `push_subscriptions` table + migration, the sender on the same events that make a Flow entry (062). WUI: `public/sw.js` (`push`, `notificationclick`), `stores/notification.ts`, the Notifications settings page. |
| risk / overlap | A store migration (`PRE_PUSH_TIER=full`); a new secret; touches 062's event source and 053 (live delivery). c-002 #6 (kept). |

### 3.3 Drafts that survive, and an offline send queue (also desktop)

| field | content |
|---|---|
| problem | The composer keeps its draft in memory only (`grep -c localStorage components/MessageComposer.vue` -> 0). A send over a dropped socket is resent once, then shown with Retry, still in memory (`stores/channel.ts` ~440-460). Phones kill background tabs, so switching to another app while on a train loses the text. The only offline sign is a 44x21 dot in the status strip. |
| idea | Each feed and topic keeps its draft on the device until it is sent. A message written without signal shows "waiting for network" and goes out by itself when the connection is back; nothing is ever silently lost. |
| standard practice | WhatsApp (the clock icon, then ticks), Slack (drafts per channel, "will send when online"). |
| effort | **M**. `components/MessageComposer.vue`, `stores/channel.ts`, `stores/live.ts`, a new `utils/outbox.mjs` (IndexedDB or localStorage). The hub already de-dupes a resend by its `msg_id` (the `channel.ts` comment), so a replay is safe. |
| risk / overlap | Drafts are per device: sign-out must wipe them. c-002 #5 (draft part) and #9 (queue part). |

### 3.4 Reopen where I left off

| field | content |
|---|---|
| problem | Opening `/` (the manifest's `start_url`, the app icon) after `/channel/feedback` lands on level 1, Messages tab. Getting back costs 2 taps for a channel, 3 for a topic (task 9). |
| idea | The installed app (and a fresh tab at `/`) reopens on the last channel, DM or topic, at the same scroll position, within a time limit (for example 12 h). A notification tap or a deep link still wins. |
| standard practice | Slack, WhatsApp, Telegram all reopen where you were. |
| effort | **S**. `app.vue` or a route middleware, `composables/useMobileStack.ts` (the restored level must keep a correct Back: 3 -> 2 -> 1), `composables/useScrollAnchor.ts`. |
| risk / overlap | The stack's history entries (043 N3, T055): the restore must push level 2 under level 3, or Back leaves the app. c-002 #8 (scroll part) and #10 (part). |

### 3.5 Search and sections within thumb reach

| field | content |
|---|---|
| problem | Search has no button at 390 px: you type `/search ` (a symbol-layer `/` on a phone keyboard) in the box. The help page still promises a top-bar search icon. The 13-entry section strip is a top carousel with ~5 on screen; Settings, Event log, Archive and Docs need a sideways swipe at the top, the hardest reach for a thumb. |
| idea | One bottom bar on phones: Home (the section list), Flow, Search, and a More button for the rest. It replaces the status strip (connection dot, alerts, chime, version), whose controls move into More. Search opens the existing full-screen search sheet. |
| standard practice | Slack mobile (Home, DMs, Activity, You), GitHub mobile and Linear mobile: a 4-5 icon bottom bar with search on it. |
| effort | **M**. `layouts/default.vue`, `components/ChannelSidebar.vue` (the strip), `components/MobileStatusStrip.vue`, `composables/useMobileStack.ts`, `components/TopBar.vue`, plus `help/omnibox-and-navigation.md` §9. |
| risk / overlap | **This reverses 043 D1** ("no bottom tab bar ... it would cost 56 px"). Replacing the 21 px status strip makes the net cost ~35 px. Owner call. c-002 #1 (merged here). Fix the stale help line either way. |

### 3.6 A message sheet ordered for the thumb

| field | content |
|---|---|
| problem | The long-press / menu sheet has 10 rows. For a member who is not the topic starter, Edit, Archive, Move, Merge and Delete are disabled, each with a 78 px explanation (5 of 10 rows, ~390 px of the sheet). Reply, the most used, is the top row (y = 226). Delete, the most destructive, is the bottom row (y = 758), where the thumb rests. |
| idea | On phones: a row of quick reactions and Reply at the bottom of the sheet, nearest the thumb. Unavailable actions are left out (one "Why are some actions missing?" line explains). Destructive actions sit in their own group, above, in red. |
| standard practice | WhatsApp and Slack long-press: a reaction row plus the common actions. iOS action sheets keep destructive actions apart. |
| effort | **S**. `components/MessageMenu.vue` (order and filtering at <= 820 px), its e2e test. |
| risk / overlap | 043 D3 and `help/message-actions-and-formatting.md` (which says "On a phone the menu begins with Reply"): update the help. |

### 3.7 Keyboard-up focus mode

| field | content |
|---|---|
| problem | Keyboard emulated (390x508): the top bar (58 px), topic header (55), composer block (~83) and status strip (~21) take ~200 px, ~40 % of what is left; about 2 cards of the topic show while you type a reply (`w3-keyboard-508.png`). The placeholder still reads "Reply — Enter for a new line · Ctrl+Enter or Cmd+Enter to send ..." on a phone. |
| idea | While the composer has focus on a phone, the workspace bar and the status strip hide; the topic header shrinks to one line. The phone placeholder says "Reply" only. |
| standard practice | Slack and Telegram: while typing, only the conversation header and the composer stay. |
| effort | **S**. `layouts/default.vue`, `components/TopBar.vue`, `components/MessageComposer.vue` (it already tracks `visualViewport` and `--kb-inset`), the i18n placeholder keys. |
| risk / overlap | Measured with an emulated keyboard only: a real iPhone and Android pass first. The composer already grows (the size grip, `composer-long-msg` tests), so "grows with the text" from c-002 #5 is built. |

### 3.8 Pull to refresh

| field | content |
|---|---|
| problem | `assets/css/base.css` (lines 45, 57) sets `overscroll-behavior: none` on `html, body, #__nuxt`. That stops the shell sliding (prd topic `025cb4f8`) but also turns off the browser's own pull-to-refresh, and there is no in-app one. Live updates come over the socket, but on a flaky network there is no way to say "check now" short of a reload. |
| idea | Pulling down at the top of a list or feed runs the feed's catch-up (`catchUp()` in `stores/channel.ts`) and shows the result, with the "last updated" time. |
| standard practice | Slack, GitHub and Mail mobile. |
| effort | **S**. A new `composables/usePullRefresh.ts`, wired into `components/LiveFeed.vue` and the level-1 lists in `ChannelSidebar.vue`. |
| risk / overlap | Follow-up to g-254 (the last-updated clock): uses it, does not duplicate it. Must not fight the horizontal swipes (archive, menu, Back): vertical axis only, from scroll top only. c-002 #3 (kept). |

### 3.9 The last under-44 px controls, and the audit gap

| field | content |
|---|---|
| problem | After 043, these still ship below 44 px at 390: the status strip's 4 buttons (44x21), the composer's move and size grips (48x24, 44x24), the Flow filter chips (Mine, All, `@`, `↳`, `✉`: 26 px tall) and the kind badge (26x18). 043's audit (`mobile-audit-live.proof.mjs`) reported 0, so it either exempts them or does not reach them. |
| idea | Give each a 44 px hit area (the icon can stay small) and make the audit a CI gate on the mock bundle, so a new small control turns the gate red. |
| standard practice | Apple HIG 44 pt, Material 48 dp. |
| effort | **S**. `components/MobileStatusStrip.vue`, `components/FlowList.vue`, the composer grips in `MessageComposer.vue`, `KindBadge.vue`, and a `tests/e2e/*.test.mjs` version of the audit. |
| risk / overlap | If 3.5 lands, the status strip goes away and its part here is moot. c-002 #7 (changed: narrowed to what is left). |

### 3.10 Invite the install (PWA)

| field | content |
|---|---|
| problem | The manifest is complete and the service worker is registered, but nothing in the app offers the install (`beforeinstallprompt` -> 0 hits). Install is documented only in `help/getting-started.md` §4.2. On an iPhone, alerts (and 3.2) work only once installed. |
| idea | An "Install the app" row in the avatar sheet, and one dismissible banner after the third visit on a phone. Android gets the browser's install prompt; iPhone gets the two-step "Share, Add to Home Screen" picture. Hidden once installed (`display-mode: standalone`). |
| standard practice | X/Twitter and Pinterest PWAs; Slack web's "open in the app" banner. |
| effort | **S**. `plugins/pwa.client.ts`, `components/UserMenu.vue`, a small banner component, i18n. |
| risk / overlap | None found. Pairs with 3.2. |

### 3.11 Offline reading and an instant first screen (also desktop)

| field | content |
|---|---|
| problem | `sw.js` keeps the shell HTML but never `/api/**`, so without signal every list and feed is empty or an error. A cold open waits for the network before the first list paints. |
| idea | The last ~20 opened feeds and topics are kept on the device. With no signal they show read-only under an "offline, as of 14:02" line. On every open the cached lists paint at once and refresh in the background. |
| standard practice | Slack, Telegram, Gmail mobile. |
| effort | **L**. `public/sw.js` or an IndexedDB layer in the stores (`stores/channel.ts`, `stores/live.ts`), sign-out wipe, a size cap. |
| risk / overlap | Workspace data on the device: sign-out and a workspace switch must wipe it. Overlaps the perf specs 066 (perceived performance) and 070 (three-second response) on first-screen timing: measure with their metrics. c-002 #9 (reading part) and #10 (merged). |

### 3.12 Newest-last by default on phones

| field | content |
|---|---|
| problem | The default feed order is newest first. On a phone the newest reply in a topic is at the top, the farthest point from the composer and the thumb, while the opening message sits next to the composer (`w5-topic-390.png`). |
| idea | At <= 820 px the default becomes newest last (bottom, next to the composer), the order of every phone chat app. A user who set the order keeps it. |
| standard practice | Slack, WhatsApp, Telegram, iMessage. |
| effort | **S**. The default of the Message-order setting (`user-settings.md` §5.3) by viewport, in its store or util. |
| risk / overlap | Owner call: newest first may be a deliberate choice. Interacts with 3.8 (which end you pull) and the unread jump (`LiveFeed.vue`, built for both orders). |

### 3.13 Clean list titles (also desktop)

| field | content |
|---|---|
| problem | The Topics list shows raw markdown (`Topic: Welcome to **#lobby**. ...`) and starts every row with `Topic:` (`topic.list_title` in `i18n/locales/en.json`, used in `pages/index.vue:163`), which takes 50 px (measured) of every row on a 390 px screen (`w1-01-topics.png`). Owner `4d2d3d63`, "Remove the topic.. from mobile.", may be this prefix (unconfirmed: the post has no screenshot). |
| idea | List rows show plain text (markdown stripped, or the topic's gist, spec 034), without the `Topic:` prefix in a list that is already titled "Topics". |
| standard practice | Slack's thread list, GitHub's notification list: plain titles. |
| effort | **S**. `pages/index.vue`, a strip-markdown helper in `utils/`, i18n. |
| risk / overlap | The topic-count lane (c-253) works on topic rows: rebase on it. |

### 3.14 Swipe hints and a "mark read" swipe

| field | content |
|---|---|
| problem | Swipe left to archive, swipe right for the menu, swipe left on a reply to hide it are all built (`help/archive.md` §3, `swipe-archive.test.mjs`, `swipe-hide.test.mjs`), but nothing on screen hints them; the help page is the only place they are named. A swipe that starts at the left edge is Back, which the help explains but the screen does not. |
| idea | A one-time "peek" (the first card slides 30 px to show the archive strip) the first time a phone user opens a feed, and a short right swipe that marks a topic read. |
| standard practice | iOS Mail and Gmail: a first-run swipe hint; swipe to mark read. |
| effort | **S**. `composables/useTopicRowSwipe.ts`, `components/MessageCard.vue`, a one-time flag in localStorage. |
| risk / overlap | The right swipe already opens the menu (owner, topic `2d09e9c2`): "mark read" needs a different gesture length or must give way. c-002 #2 (mostly built; the rest kept here). |

## 4. c-002's ten starter ideas (msg `8c8322a1`): what this list did with each

| # | starter idea | verdict | evidence | where it went |
|---|---|---|---|---|
| 1 | Bottom tab bar | **merged, changed** | search has no button at 390; 8 of 13 sections off-screen in a top carousel. 043 D1 rejected a tab bar for its 56 px; replacing the status strip cuts that to ~35 px | 3.5 |
| 2 | Swipe actions on topic cards | **mostly built** | swipe left archives with undo, swipe right opens the menu (`archive.md` §3, `swipe-archive.test.mjs`) | the rest (hints, mark read) in 3.14 |
| 3 | Pull to refresh + last updated | **kept** | `overscroll-behavior: none` disables the browser's own; no in-app one | 3.8 (uses g-254's clock) |
| 4 | Jump to first unread | **dropped, built** | `LiveFeed.vue:18-20` (`unread-jump`, CLE-77804) and `:133` (the phone thread-jump) | n/a |
| 5 | Reply bar that fits the keyboard | **split** | above the keyboard: built (043 T020). Grows with the text: built (size grip, `composer-long-msg`). Camera / gallery: the OS file picker offers both already. The draft and the chrome were not built | drafts in 3.3, the chrome in 3.7 |
| 6 | Push notifications | **kept** | no Web Push code; 062 Q4 deferred it | 3.2 (+ 3.10, the install) |
| 7 | Bigger tap targets | **changed** | 043 did the bulk; 4 groups still under 44 px | 3.9 |
| 8 | Back gesture that follows the app | **mostly built** | 043 N3 (Back = arrow = swipe = browser, one level) and T055 (a dialog is a step). Keeping the scroll position on reopen is not built | 3.4 |
| 9 | Offline reading + send queue | **split** | the send queue and the reading need different stores | 3.3 (queue), 3.11 (reading) |
| 10 | Fast first screen | **merged** | same cache as offline reading; first-screen timing is 066/070's metric | 3.11, partly 3.4 |

## 5. Owner phone posts found (dispatcher transcripts, keyword match, n = 5)

| msg | text (short) | status today |
|---|---|---|
| `4a43f68e` | swipe left on a reply hides it, a thicker line marks the gap | built (`swipe-hide.test.mjs`) |
| `bbe0420d` | desktop gets the same hide | built (desktop side) |
| `bba14976` | "When I click on those links on mobile, nothing happens." | built (message links open in place, `omnibox-and-navigation.md` §8) |
| `e1c6515c` | a vertical black line in the omnibox on mobile | not seen in the 390/360 screenshots (n = 1, mock): no idea filed |
| `4d2d3d63` | "Remove the topic.. from mobile." | possibly the `Topic:` prefix: 3.13 |

The search was a keyword match over dispatcher transcripts, so other phone complaints may exist.

## 6. Out of scope here

Already running, so not proposed again: the operator console (c-250), the docs editor (c-240), the last-updated
clock (g-254, used by 3.8), topic new/total (c-253), link previews (c-226). Desktop-only ideas are c-245's.
