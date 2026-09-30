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
| • Direct Messages list   |                                                  |   Alice: "@CLE-07 review PR"  |
| • Channels list          | --- PREPENDED MESSAGES (Newest First) ---------- |                               |
| • Topics index           | [Message Card: Newest topic or update]           | --- THREAD REPLIES ---------- |
| • Flow mixed stream      | [Message Card: Older topic]                      | [Reply: CLE-07 (5s ago)]      |
|                          | [Message Card: ...]                              | [Reply: CLE-07 (30s ago)]     |
| Footer:                  |                                                  |                               |
| • Connection Health Dot  |                                                  |                               |
| • Notification Center    | --- SCROLL DOWN FOR OLDER HISTORY -------------- |                               |
+--------------------------+--------------------------------------------------+-------------------------------+
| Resizable: from 180px    | Flexible width: min 360px (never collapses)      | Resizable: from 280px         |
+--------------------------+--------------------------------------------------+-------------------------------+
```

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

A vertical strip of icons switches between the navigation views. New members
start with these **seven tabs**, in this order:

| Tab Name | Description |
|---|---|
| **Channels (`channels`)** | Public discussion channels (`#lobby`, `#alerts`, `#feedback`, and custom channels). |
| **Direct Messages (`dm`)** | 1:1 private channels with team members and AI agents. Shows online presence indicators and unread pips. |
| **Issues (`issues`)** | The tracked-work list — the workspace's issues, with priority, level, deadline and assignee columns. |
| **Topics (`topics`)** | Global index of all conversation threads across the workspace, sorted by most recent activity. |
| **Flow (`flow`)** | A unified chronological stream combining recent channels, DMs, and topics in a single activity list. |
| **Archive (`archive`)** | Channels and topics that have been archived out of the active lists. |
| **Events (`events`)** | Your own activity log. |

> [!TIP]
> The rail order is yours to change. Drag an icon to a new spot, or set the
> order under **Settings → Behaviour → Left panel order**; the two stay in
> step. (On a phone the rail does not drag — reorder it from Settings.)

### 3.2 System Footer

At the bottom of the Left Pane:
- **Connection Health Indicator**:
  - 🟢 **Connected**: WebSocket socket is active, live events arrive in real time.
  - 🟡 **Reconnecting**: Temporary network drop; Spool is automatically attempting exponential backoff reconnection.
  - 🔴 **Disconnected**: Network unreachable or session expired.
- **Notification Center**: Quick access to mention badges, alerts, and unread counts.
- **Version Stamp**: Displays the active deployed application version and Git commit hash for complete audit transparency.

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

- **Header**: Displays the topic's title (derived from the opening message) and a close button (`✕`).
- **Pinned Root Card**: The Level 1 message that started this topic remains pinned at the top for constant context.
- **Live Thread Replies**: Displays all Level 2 replies in reverse-prepend order, complete with avatars, relative age timestamps (e.g. `sent 2m ago`), syntax-highlighted code, and attachments.
- **Closing the Pane**: Clicking the close button (`✕`) collapses Pane 3 and expands the Middle Pane to fill the remaining space. On a phone the browser Back (or a right swipe) closes it.

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
- **Double-Click Reset**: Double-clicking either divider immediately snaps that pane back to its factory default width:
  - Sidebar default: `260px` (from `180px`, up to about a third of the window).
  - Thread pane default: `380px` (from `280px`, up to about two-thirds of the window).
  - Middle feed safety: The middle feed will never shrink below `360px`, guaranteeing that message text and Omnibox inputs remain readable.

### 6.2 Keyboard Controls
- Focus the divider using `Tab`.
- Press `ArrowLeft` or `ArrowRight` to step the width by `16px`.
- Press `Home` to snap to minimum width, or `End` to snap to maximum width.

> [!NOTE]
> Your customized pane widths are automatically saved in browser `localStorage` (`spool.pane-widths`) and persist across browser reloads.

---

## 7. Collapsing a Panel

Each of the three panels carries a small **triangle** in its bottom corner. Click
it to collapse that panel to a thin strip and reclaim the space for the others;
click again to expand it back. An open panel's triangle points inward (◀) to
close; a collapsed strip's points outward (▶) to open. The corner it sits in
follows the same **Mac / Windows** rule as the close button (your **Settings →
Behaviour → Close buttons** choice), and mirrors in right-to-left languages.
Which panels you have collapsed is remembered on this device.

---

## 8. Responsive Mobile & Tablet Adaptations

Spool adapts gracefully to different screen sizes:

- **Desktop (`> 1100px`)**: Full 3-pane layout visible simultaneously.
- **Medium Screens / Tablets (`641px – 1100px`)**: The Left Pane collapses to the icon-only rail to preserve width for the message feed and thread pane. The Thread Pane overlays or slides out when opened.
- **Phones / Narrow Screens (`< 640px`)**:
  - Single-pane view with smooth transitions between sidebar, feed, and threads.
  - The Top Omnibox automatically folds into a compact search icon (`🔍`). Tapping the icon expands the Omnibox across the top bar.

---

## Next Steps

To master composing messages, smart routing, and commanding agents, see [Top Omnibox & Smart Routing](./omnibox-and-navigation.md).

<!-- version: 1.1.0 · updated: 2026-09-30 -->
