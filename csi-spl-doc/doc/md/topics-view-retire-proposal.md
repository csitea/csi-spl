# Retire the Topics view? — a proposal for the owner's decision

Owner, t1 topic 635f8072 (2026-10-01): "in this way we might eliminate the
whole topics interface". This is the case for and against, and the plan if
the answer is yes. **Nothing is removed until the owner says so.**

## 1. What "the Topics view" is today

| # | piece | where |
|---|---|---|
| 1.1 | `/` — the home page: every topic across channels and DMs, newest first, avatar, people, kinds, count, row menu (Archive / Delete) | `src/pages/index.vue` |
| 1.2 | the Topics rail tab — the same list in the sidebar, pin + drag-reorder, row menu | `ChannelSidebar.vue` `sidebar-panel-topics` |
| 1.3 | `/t/<task_id>` — one topic on its own page, outside any channel | `src/pages/t/[task_id].vue` |
| 1.4 | the Flow tab's topic rows (lane B replaces these anyway) | `ChannelSidebar.vue` `sidebar-panel-flow` |

## 2. What it does that Flow + Search + channels/DMs would NOT cover

| # | job done by Topics today | covered after A/B/C? | what has to move first |
|---|---|---|---|
| 2.1 | **Copy link** on any message points at `/t/<task>#<msg>` (`utils/msg-menu.mjs` `messageLink`); every link already pasted into a post, an issue or a terminal is a `/t/` link | no | `messageLink` → lane A's `/m/<msg>`; `/t/<task>` stays as a **redirect** forever (old links) |
| 2.2 | old apex links `/t/<uuid>` move to the right tenant host (`/v1/view/locate`, `tenant-host-boot.mjs`) | no | keep the `/t/` route as a thin redirect into `/m/` |
| 2.3 | `/` is the **home** page and the 404 page's first suggestion (`error.vue`); the first-run checklist (spec 047 W15) lives there | no | pick a new home (proposal: the Flow list + `#lobby`), move `FirstRunChecklist` there |
| 2.4 | a topic that has **no channel and no DM** (Lane A returns `kind: "topic"` for it) has no other place to open | no | Lane A's fallback today opens `/t/`; keep `/t/` for exactly that case, or give such topics a home channel |
| 2.5 | Archive page opens an archived thread on `/t/` (`pages/archive.vue` `openPath`) | no | point it at `/m/<root>` |
| 2.6 | a topic's thread lines get a plain **Delete** (a topic card in a channel offers only "Delete topic") — the delete-confirm e2e drives it on `/t/` | partly | offer the line Delete in the channel's right-pane thread too |
| 2.7 | pinned + hand-ordered topics (the tab's drag order) | no | drop, or move pins to Flow (owner's call) |
| 2.8 | composer: with the Topics tab open and a row selected, a plain line replies there (`omnibox-topic.mjs`) | yes — the right pane does the same | none |
| 2.9 | Search "topics" hits open `/t/<task>` (`search-results.mjs`) | yes — lane C | none |
| 2.10 | promote-by-drag drop target is named `topics` (`move-drag.mjs`) | yes — it is a channel feed target, only the name | none |
| 2.11 | `/switch-pane:topics`, rail-order id `topics` | n/a | keep accepting the word, map it to Flow |

## 3. Usage evidence

- There is **no per-view usage counter**: the WUI is a static bundle, Firebase
  Hosting serves one HTML for every route, and the event log records a route
  only for errors. The hub cannot tell `/` from the right pane either — both
  read the same `/v1/view/*` endpoints.
- What exists: 12 browser gates and 15 unit files touch `/t/`, the Topics tab
  or the topic list; every "Copy link" since the feature shipped is a `/t/`
  link.
- Cheap way to get evidence before deciding: one event-log line per rail-tab
  open and per `/t/` landing (no hub change), read after a week.

## 4. Recommendation

**Yes, in two steps, and keep `/t/` as a redirect forever.**

1. **Step 1 (when A, B, C are live, ~1 lane-day):** `messageLink` and Archive
   switch to `/m/<id>`; `/` becomes the Flow list (first-run checklist moves
   with it); the Topics rail tab is **hidden by default** but still reachable
   from the rail menu, so nobody loses a pinned list overnight; the usage
   lines from §3 ship.
2. **Step 2 (after one week with no Topics-tab use in the event log, owner's go):**
   delete `pages/index.vue`'s topic list, `sidebar-panel-topics`, the topic
   pins/order, and `pages/t/[task_id].vue` becomes a 20-line redirect to
   `/m/<task>` (or to the topic's channel). The `nav.topics` and
   `pages.index.*` keys go from all 19 locales in the same commit.

## 5. What is removed in step 2

| remove | keep |
|---|---|
| `pages/index.vue` topic list, its row menu + new-pill | the `/` route (now Flow) |
| `ChannelSidebar.vue` `sidebar-panel-topics`, `topicOrder`, topic drag | the topic row menu actions (live on the card) |
| `pages/t/[task_id].vue` body | `/t/<id>` as a redirect |
| rail item `topics`, `SIDE_TABS` entry | `/switch-pane:topics` → Flow |
| i18n `nav.topics`, `pages.index.*` (19 locales) | — |
| e2e that drive the Topics list (re-pointed, not deleted, where they test a card action) | `delete-confirm` re-pointed to the channel thread |

**Decision needed:** (a) go for step 1, (b) the new home — Flow list, or
`#lobby`, (c) keep topic pins (move to Flow) or drop them.
