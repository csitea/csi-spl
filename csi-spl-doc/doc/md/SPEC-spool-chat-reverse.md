# SPEC: Reverse chat flow & Top Omnibox

Status: **Binding M3 Architecture** — adopted as default M3 UX (owner direction 2026-09-18).  
Related: `SPEC-spool-wui.md`, `SPEC-spool-wui-layout.md`, `SPEC-spool-avatars.md`

Chats use a **reverse-flow prepend paradigm**: the user **types at the top** into a unified **Top Omnibox** (combining searching and composing); new messages **prepend** (newest first, immediately under the Omnibox). Older messages sit **below**; scrolling down fetches history.

This is **display only**. `v:1` `ts` / `msg_id` / `task_id` schema fields do not change.
The hub still stores standard chronological timestamps in Postgres. CLI/`spool-tail` stay oldest-first.

---

## 1. Top Omnibox & Prepend Architecture

| Aspect | Specification |
|---|---|
| **Omnibox Position** | Pinned at the **top** of the Middle Pane (above the feed). |
| **Omnibox Dual Role** | **Main Input Box** (default: type and hit Enter to send note/task) + **Search** (explicitly triggered via `/search <query>`). |
| **Feed Insertion** | **Prepend**: New outgoing or incoming live messages enter at the top directly under the Omnibox. |
| **History Scroll** | **Downward**: Users scroll down to read older history; bottom triggers windowed catch-up for older chunks. |
| **Thread Pane (Right)** | Pinned root message at top, newest replies prepended below the thread input/filter. |
| **Avatars** | Every human (`HUM-*`) has an avatar; every agent (`CLE-*`, `GRK-*`, `AGY-*`) has a wild funny robot avatar. |

---

## 2. Behaviour in Reverse Prepend Mode

- The **Top Omnibox** is permanently docked at the top of the middle feed.
- Sending or receiving a message **inserts it under the Omnibox**, shifting older rows down with an entrance transition.
- Live WebSocket event dispatches prepend to the top immediately.
- Infinite scroll triggers when scrolling down towards older messages.
- Accessibility: Focus order and screen reader semantics match visual order (Omnibox, then newest message, then older messages).

---

## 3. Scope & Protocol Invariants

- Hub message storage remains unchanged (`ts`, `msg_id`, `task_id` in Postgres).
- View API (`contracts/view-v1.md`) returns windowed slices; client renders newest-first.
- CLI and MCP tooling retain standard chronological tail streams.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:32:00Z -->

---

## 4. Per-person layout: newest last (owner, topic c6994436, 2026-09-27)

Newest first stays the **default**. A person can pick the mirror image in
Settings -> Behaviour; nobody's view changes until they choose.

| Setting | Values (first = default) | Kept as |
|---|---|---|
| Message order | `newest-first`, `newest-last` | `humans.message_order` (rdb 0070), session claim `message_order` |
| Omnibox position | `top`, `bottom` (> 820 px; phones always dock at the bottom) | `humans.composer_position` (rdb 0070), session claim `composer_position` |

NULL = never picked = the default. `PUT /api/v1/auth/preferences` sets or
clears each key (`unsupported_<key>` for another value).

Newest last, in every message feed (channels, #lobby, DMs) and thread:

- The stores still hand a feed its rows **newest first**, so every window holds
  the newest N; `LiveFeed` only draws them reversed (`utils/view-prefs.mjs`
  `displayOrder`). The DOM order is the reading order: never `column-reverse`
  (section 2's accessibility rule).
- **Load more** for older rows sits **above** the first row. Loading it keeps
  the row being read in place.
- The feed opens at its **bottom**. A reader at the bottom follows new rows and
  late height changes (markdown, pictures, the card clip mode, the phone
  keyboard). A reader scrolled up is not moved; new rows are counted in a
  **"↓ N new"** pill stuck to the bottom edge, which jumps down.
- Our own send jumps to the bottom. A `#<msg_id>` deep link wins over the
  bottom follow. Flipping the setting re-renders open feeds at the newest end.
- Threads: the root on top, replies oldest to newest; new-topic cards
  (BornTopics) sit under the thread.
- Not flipped: the sidebar lists, the `/` topic list, `/search` results (ranked
  by the hub) and the issues sheet.

Code: `composables/useViewPrefs.ts` (the one reader), `composables/useScrollAnchor.ts`
(`newestLast` mode, pure rules in `utils/scroll-anchor.mjs`). Tests:
`tests/unit/view-prefs.test.mjs`, `tests/e2e/message-order.test.mjs`.
