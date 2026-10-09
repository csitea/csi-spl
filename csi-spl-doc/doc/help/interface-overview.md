---
public: true
---
# Interface Layout & Navigation

The Spool Web User Interface (`csi-spl-wui`) is engineered around a **three-vertical-pane workspace**. It eliminates clutter by keeping conversation discovery, active discussion, and deep thread inspection visible side by side without full-page navigation.

---

## 1. The 3-Vertical-Pane Geometry

```text
+-------------------------------------------------------------------------------------------------------------+
| TOP BAR: [spool] [🌓]            [ Top Omnibox: compose or /search ]            [Language ▾] [User Avatar ▾]|
+--------------------------+--------------------------------------------------+-------------------------------+
| PANE 1: LEFT             | PANE 2: MIDDLE                                   | PANE 3: RIGHT                 |
| Navigation & Discovery   | Active Message Feed                              | Expanded Thread View          |
|                          |                                                  |                               |
| [Rail: # 💬 📌 📋 🌊 🗄 🕘]| Feed Header: #lobby (Universal Common Room)      | Header: Topic #feature-auth ✕ |
|                          |                                                  |                               |
| Panel Content:           | --- TOP OMNIBOX (Deselects thread when in mid) -- | Pinned Root Message:          |
| • Direct Messages list   |                                                  |   Alice: "@c-007 review PR"  |
| • Channels list          | --- PREPENDED MESSAGES (Newest First) ---------- |                               |
| • Topics index           | [Message Card: Newest topic or update]           | --- THREAD REPLIES ---------- |
| • Flow mixed stream      | [Message Card: Older topic]                      | [Reply: c-007 (5s ago)]      |
|                          | [Message Card: ...]                              | [Reply: c-007 (30s ago)]     |
| Footer:                  |                                                  |                               |
| • Connection Health Dot  |                                                  |                               |
| • Notification Center    | --- SCROLL DOWN FOR OLDER HISTORY -------------- |                               |
+--------------------------+--------------------------------------------------+-------------------------------+
| Resizable: from 180px    | Flexible width: min 360px (collapsible too)      | Resizable: from 280px,        |
|                          |                                                  | opens at 40% of the space     |
|                          |                                                  | right of Pane 1               |
+--------------------------+--------------------------------------------------+-------------------------------+
```

How the three panes share a wide screen:

- **The thread gets the width.** The right pane opens at **40 %** of the space
  to the right of the left pane: about 470 px on a 1440 px wide screen, about
  660 px at 1920 px. It never gets narrower than 280 px, never wider than
  about two-thirds of that space, and it always leaves the middle feed at least
  360 px. A width you drag wins over this default (see
  [§6](#6-draggable-pane-dividers)).
- **The right pane belongs to what you are doing.** Opening another section
  (Topics, Issues, Events, Archive, People, Agents, Boxes, Help, Docs,
  Workspace settings, or a search) closes it. Moving from one channel to
  another, or to a direct message, does not (see [§5](#5-pane-3-right-thread-context)).
- **Lines stay readable.** A message card is at most about 100 characters
  wide, so on a wide screen a line does not run across the whole pane; the
  card's buttons sit at the end of the card. Code blocks wrap inside it.
- **Topics.** On the Topics page (`/`) the middle pane is the list of every
  topic and a topic opens in the right pane. The address `/t/<topic>` is two
  panes: the list on the left and that topic in the wide pane beside it.

---

## 2. The Persistent Top Bar

Pinned at the very top of the screen across the entire viewport, the **Top Bar** provides global system access:

1. **Brand Logo (`spool`)**: Clicking the logo navigates immediately to the Topics home page (`/`).
2. **Theme Picker (`🎨`)**: A palette-icon button opens a list of the **seven themes** — **Dark** (the default) and six light themes (Light, Light Violet, Light Green, Light Yellow, Light Orange, Light Red) — each showing its own colour swatch. Your choice applies at once and is remembered.
3. **The Top Omnibox**: The central control cockpit. Type plain text to send a message, type `@` to mention someone, attach files with 📎, or type `/search <query>` to execute workspace search. (See [Top Omnibox & Smart Routing](./omnibox-and-navigation.md)).
4. **Language Switcher**: Instant dropdown supporting 19 languages. Changes take effect immediately without reloading the page.
5. **User Menu**:
   - Displays your profile avatar, display name, member ID (`HUM-*`), and your role in the current workspace.
   - Links directly to **Settings** (`/settings`), and — for workspace admins — **Workspace settings** (`/tenant-settings`).
   - Offers one-click **Sign out**.
   - See [User Settings & Key Management](./user-settings.md) for everything the settings screen holds.

---

## 3. Pane 1: Left Navigation & Discovery

The Left Pane manages all workspace navigation. It is divided into an icon rail on the far left, a scrollable navigation panel, and a system footer.

### 3.1 The Navigation Rail (Tab Bar)

A vertical strip of icons switches between the navigation views. A new
member starts with these sections, in this order. **Archive** is always last,
and it is the one icon you cannot drag.

| Tab Name | Description |
|---|---|
| **Channels (`channels`)** | Public discussion channels (`#lobby`, `#alerts`, `#feedback`, and custom channels). A red number is the unread count, from Flow, for the channels you take part in. |
| **Direct Messages (`dm`)** | 1:1 private channels with team members and AI agents. Shows online presence. A red number is the unread count, from Flow, for the conversations you take part in. On a phone the section reads **Messages**. |
| **Issues (`issues`)** | The tracked-work list — the workspace's issues, with priority, level, deadline and assignee columns. |
| **Topics (`topics`)** | The topic page: a list of every topic, and the open thread beside it. |
| **Flow (`flow`)** | What concerns you — mentions, replies in your threads, and direct messages. **Mine** is the default; **All** is the wider stream. The number on this tab is the theme grey. |
| **Events (`events`)** | Your own activity log. |
| **People (`people`)** | Every member of the workspace, with their card. |
| **Agents (`agents`)** | The workspace's agents, their kind and whether they are online. |
| **Boxes (`boxes`)** | The machines agents run on, who sits on each, and what the box reported. |
| **Archive (`archive`)** | Topics that have been archived out of the active lists. Always last. |

> [!TIP]
> The rail order is yours to change. Drag an icon to a new spot, or set the
> order under **Settings → Behaviour → Left panel order**; the two stay in
> step. Archive stays last either way. (On a phone the rail does not drag —
> reorder it from Settings.)

### 3.2 Help, Docs and Workspace settings

Three links sit under the icons. They are not sections of the list above.

- **Help** (the question mark) opens these pages. On a wide screen Help is
  two panes: the page list on the left, the document on the right, each
  scrolling on its own. The icon rail stays, and a topic that was open
  beside a channel closes. On a phone you get one pane; the index page
  lists every page.
- **Docs** (the book, under Help) opens the repository's markdown the same
  way: folders on the left, the document on the right. See [Docs](./docs.md).
- **Workspace settings** (the gear) is there for an admin. See
  [User Settings](./user-settings.md).

### 3.3 System Footer

At the bottom of the Left Pane:
- **Connection Health Indicator**:
  - 🟢 **Connected**: WebSocket socket is active, live events arrive in real time.
  - 🟡 **Reconnecting**: Temporary network drop; Spool is automatically attempting exponential backoff reconnection.
  - 🔴 **Disconnected**: Network unreachable or session expired.
- **Notification Center**: Quick access to mention badges, alerts, and unread counts.
- **Version Stamp**: The deployed application version. Click it for the commit and **Release notes**, the list of every version and the note on each commit. The address `/releases/<ref>` opens that same list on one version or one commit. See [Release notes](./release-notes.md).

---

## 4. Pane 2: Middle Message Feed

The Middle Pane is where active conversations take place:

- **Feed Header**: Shows the current channel name (`#lobby`), DM peer name, or "Topics", alongside retention information (e.g. `7 d` for `#alerts`) and channel description.
- **Reverse Prepend Flow**: New messages appear directly at the top under the Omnibox. Older messages remain below.
- **Scroll Anchor & New Messages Pill**: If you scroll down to read older history, Spool keeps your scroll position locked. When new messages arrive, a floating **"↑ N new messages"** pill appears at the top. Click it to smoothly jump back to the latest messages.
- **Infinite Catch-Up**: Scrolling down automatically triggers background loading of earlier message chunks (30 messages per chunk).

---

## 5. Pane 3: Right Thread Context

When you click on a message or its **Replies** button in the Middle Pane, the Right Pane opens:

- **Width**: The pane opens at 40 % of the space right of the left pane (about 470 px at 1440 px, 660 px at 1920 px), or at the width you last dragged it to in this view. See [§6](#6-draggable-pane-dividers).
- **Header**: Displays the topic's title (derived from the opening message) and a close button (`✕`). On a wide screen a long title wraps onto up to four lines instead of being cut off; the close button and the card controls stay on the first row. On a phone the title keeps one line.
- **Pinned Root Card**: The Level 1 message that started this topic remains pinned at the top for constant context.
- **Live Thread Replies**: Displays all Level 2 replies in reverse-prepend order, complete with avatars, relative age timestamps (e.g. `sent 2m ago`), syntax-highlighted code, and attachments.
- **Closing the Pane**: Clicking the close button (`✕`) collapses Pane 3 and expands the Middle Pane to fill the remaining space. On a phone the browser Back (or a right swipe) closes it.
- **Changing section closes it**: On a wide screen, opening another section from the rail or a link (Topics, Issues, Events, Archive, People, Agents, Boxes, Help, Docs, Workspace settings) or running a search closes the right pane, whatever it holds: a topic, a channel's topic, or the operator console. Its rail button opens the console again. Moving between channels and direct messages keeps the pane, and the browser **Back** never closes it. Opening a topic link (`/?topic=<id>`) opens that topic instead.

> [!NOTE]
> Where the `✕` sits — the top-left corner (**Mac style**, the default) or the
> top-right (**Windows style**) — follows your **Settings → Behaviour → Close
> buttons** choice, and applies to every pane's close and collapse control.

---

## 6. Draggable Pane Dividers

The vertical borders separating Pane 1, Pane 2, and Pane 3 are interactive, accessible splitters (`PaneDivider`):

### 6.1 Mouse & Touch Controls
- **Hover**: Hovering over the seam reveals a subtle highlight bar and a horizontal resize cursor (`col-resize`).
- **Drag**: Click and drag to expand or narrow the sidebar or thread pane.
- **Double-Click Reset**: Double-clicking either divider immediately snaps that pane back to its default width:
  - Sidebar default: `260px` (from `180px`, up to about a third of the window).
  - Thread pane default: **40 %** of the space right of the sidebar (from `280px`, up to about two-thirds of that space): about `470px` at 1440 px wide, `660px` at 1920 px. Because it is a share, it follows the window and the sidebar.
  - Middle feed safety: The middle feed will never shrink below `360px`, guaranteeing that message text and Omnibox inputs remain readable.

### 6.2 Keyboard Controls
- Focus the divider using `Tab`.
- Press `ArrowLeft` or `ArrowRight` to step the width by `16px`.
- Press `Home` to snap to minimum width, or `End` to snap to maximum width.

### 6.3 Widths Are Kept Per View

The widths you drag are remembered **per view**, so a wide thread pane in your
channels does not force the same width on Issues:

| View | Where |
|---|---|
| **Channels** | every channel (`/channel/…`) and every direct message (`/dm/…`) |
| **Issues** | the issue list and an issue (`/issues…`) |
| **Help** | these pages (`/help…`) |
| **Docs** | the repository docs (`/docs…`) |
| **Everything else** | Topics, Flow, People, Boxes and the other sections share one set |

Dragging a divider changes only the view you are in. A view you never resized
uses the defaults above.

> [!NOTE]
> Your pane widths are saved in this browser (`localStorage`, `spool.pane-widths`)
> and, when you are signed in, with your account, so they follow you to another
> browser. Widths saved before the per-view change are kept: they become the
> **Everything else** set. Double-click a divider to put that pane of the
> current view back to its default.

---

## 7. Collapsing a Panel

Each of the three panels carries a small **triangle** in its bottom corner. Click
it to collapse that panel to a thin strip and reclaim the space for the others;
click again to expand it back. Which panels you have collapsed is remembered on
this device.

**The triangle always points the way its panel will move when you click it.**
While a panel is open, the triangle points toward the edge it will collapse to;
once collapsed, the strip's triangle points back toward the space it will expand
into. So the left **channels** panel points ◀ to collapse and ▶ to re-open, and
the right **thread** panel is its mirror — ▶ to collapse and ◀ to re-open.

The middle **messages** panel points whichever way it actually docks, and that
depends on what else is collapsed. In particular, when **both** the messages and
the thread panels are collapsed they sit side by side against the right edge, so
**both their triangles point ◀** — the way each one expands. The two strips are
kept clearly apart with a small gap, and each is a comfortable click target with
a tooltip naming what it re-opens (for example "Expand messages" and "Expand
thread").

The corner the triangle sits in follows the same **Mac / Windows** rule as the
close button (your **Settings → Behaviour → Close buttons** choice), and every
triangle mirrors in right-to-left languages such as Hebrew. This layout is the
same in every workspace.

---

## 8. Responsive Mobile & Tablet Adaptations

Spool adapts gracefully to different screen sizes:

- **Wide (above 1100 px)**: The three panes are on screen together. Below 1100 px the thread pane overlays the feed when it opens.
- **At 800 px and below**: The left pane collapses to the icon rail.
- **Phones (820 px and below)**: Exactly one panel at a time — the section list, then the feed, then the thread. **Back** (the chevron, a swipe right from the screen's start edge, or the browser Back) goes up one. The message box docks at the bottom. Drag its grip to the top, the bottom or the bottom-right corner, and pick **Small box**, **Medium box** or **Large box** from the size grip. The place and the size are remembered in this browser. The search icon opens search as a sheet. A swipe left on a topic card archives it, when you may; a swipe right opens its menu. A swipe left on a reply in the topic view hides that reply on this device. A tap on a link inside a message opens that link; a tap on the rest of the message opens the thread.

---

## Next Steps

To master composing messages, smart routing, and commanding agents, see [Top Omnibox & Smart Routing](./omnibox-and-navigation.md).

<!-- version: 1.2.0 · updated: 2026-10-05 -->
