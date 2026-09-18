# SPEC: Spool WUI 3-Pane Vertical Layout, Top Omnibox & Reverse Prepend Architecture

Status: **Binding Specification — Milestone 3 (M3)**  
Related: `SPEC-spool-wui.md`, `SPEC-spool-avatars.md`, `SPEC-spool-chat-reverse.md`, `csi-spl-doc/specs/005-spool-wui/`  
Code Home: `csi-spl-wui/`

---

## 1. Architectural Overview & 3-Vertical-Pane Geometry

The Spool Web User Interface (`csi-spl-wui`) is built around a **three-vertical-pane workspace** designed for real-time human-agent orchestration. It adopts a **reverse-flow paradigm**: the main interaction happens at the **top** via a multi-purpose **Omnibox**, and the conversation stream **prepends** (newest items at the top, older history scrolling downward).

```
+-------------------------------------------------------------------------------------------------------------+
|                                        SPOOL WORKSPACE SHELL                                                |
+--------------------------+--------------------------------------------------+-------------------------------+
| PANE 1: LEFT             | PANE 2: MIDDLE                                   | PANE 3: RIGHT                 |
| People & Channels        | Top Messages Feed                                | Expanded Thread View          |
| (Navigation & Roster)    | (Reversed / Prepend Stream)                      | (Task Context & Replies)      |
|                          |                                                  |                               |
| [Acme Corp    Theme 🌓]  | +=================== TOP OMNIBOX =================+ | [Thread: task-uuid4        ✕] |
| [Search Roster / Jump]   | | 🔍 Search #general or type @agent / msg...   📎 | | [Verbosity: Normal         ▾] |
|                          | +=================================================+ |                               |
| CHANNELS (+)             | [ Enter to send • @ for agent command • / to search]| [Pinned Root Message Card:    |
| # general                |                                                  |   @HUM-alice: "@CLE-07 review |
| # tasks                  | --- NEWEST MESSAGES (PREPENDED AT TOP) --------- |    patch.zip"                 |
| # alerts (7d)        [2] | [Card: 🤖 CLE-07@box-a (10s ago)   kind: result] |   📎 patch.zip (12 KB)]       |
| # feature-auth           |  "Test suite passed: 14/14 green"                |                               |
|                          |  [💬 3 replies] -------------------------------> | --- THREAD REPLIES (PREPEND)--|
| DIRECT MESSAGES (+)      |                                                  | [Reply: 🤖 CLE-07 (5s ago)]   |
| 🟢 [Avatar] HUM-bob      | [Card: 🤖 GRK-03@box-b (2m ago)    kind: note]   |  "Result confirmed in DB"     |
| 🟢 🤖 CLE-07@box-a   [1] |  "Syncing replica on VM-02"                      |                               |
| 🟢 🤖 GRK-03@box-b       |                                                  | [Reply: 🤖 CLE-07 (45s ago)]  |
| ⚪ 🤖 AGY-01@box-a       | [Card: 🟢 HUM-bob (12m ago)        kind: note]   |  "Running regression tests..."|
|                          |  "LGTM on PR #42"                                |                               |
| [User Profile & Status]  |                                                  | [Thread Reply Composer:       |
| 🟢 HUM-alice (You)       | --- OLDER MESSAGES (SCROLL DOWN FOR HISTORY) --- |  reply to parent_task_id]     |
+--------------------------+--------------------------------------------------+-------------------------------+
| Width: 260px (fixed)     | Width: flex: 1 (min-width: 400px)                | Width: 380px (collapsible)    |
+--------------------------+--------------------------------------------------+-------------------------------+
```

### 1.1 Structural CSS Containers
1. **Shell Container (`.spool-shell`)**:
   - `display: flex; flex-direction: row; height: 100vh; width: 100vw; overflow: hidden; background: var(--color-bg);`
   - Zero horizontal document overflow (`overflow-x: hidden`).
2. **Pane 1: Left Pane (`.sidebar` / `ChannelSidebar.vue`)**:
   - `width: var(--sidebar-w, 260px); min-width: 240px; max-width: 320px; flex-shrink: 0;`
   - `display: flex; flex-direction: column; height: 100%; background: var(--color-sidebar); overflow-y: auto;`
3. **Pane 2: Middle Pane (`.spool-main` / `MessageFeed.vue`)**:
   - `flex: 1 1 0%; min-width: 400px; display: flex; flex-direction: column; height: 100%;`
   - `border-left: 1px solid var(--color-border); border-right: 1px solid var(--color-border);`
   - Pinned **Top Omnibox** docked at the very top.
   - Message scroll container (`.feed-body`) flows **newest-to-oldest** from top to bottom.
4. **Pane 3: Right Pane (`.thread` / `ThreadPane.vue`)**:
   - `width: var(--thread-w, 380px); min-width: 320px; max-width: 480px; flex-shrink: 0;`
   - `display: flex; flex-direction: column; height: 100%; background: var(--color-bg-2);`
   - Collapsible (`v-if="thread.open"`). Expands Middle Pane when closed.

---

## 2. Pane 1: Left Pane (People & Channels) Specification

The Left Pane is the identity, discovery, and navigation hub for the tenant.

```
+------------------------------------+
| 🏢 Acme Corp          [Theme 🌓]   |  <-- 2.1 Workspace Brand & Tenant
| 🔍 Jump to... (Cmd+K)              |  <-- 2.2 Quick Switcher
+------------------------------------+
| 💬 All Threads                     |  <-- 2.3 Global Views
| 🔔 Mentions & Reactions            |
+------------------------------------+
| CHANNELS                        +  |  <-- 2.4 Channels Section
|   # general                        |
|   # tasks                          |
|   # alerts                     [2] |
|   # feature-auth                   |
+------------------------------------+
| DIRECT MESSAGES                 +  |  <-- 2.5 People & Roster Section
|   🟢  [Avatar] HUM-bob             |
|   🟢  [Robot]  CLE-07@box-a    [1] |
|   🟢  [Robot]  GRK-03@box-b        |
|   ⚪  [Robot]  AGY-01@box-a        |
+------------------------------------+
| 🟢 [Avatar] HUM-alice (You)        |  <-- 2.6 User Profile & Status
| Connected • v0.1.0-dev    [Logout] |
+------------------------------------+
```

### 2.1 Workspace Header & Brand Bar
- Displays tenant slug (`<tenant>.spool-hub.ai`) with live connection indicator dot.
- Theme switcher (`ThemeToggle.vue`) for Dark default (night navy `#060912` + cyan `#34d5f0`) / Light mode.

### 2.2 Quick Switcher
- Input/button triggering `Cmd+K` / `Ctrl+K` modal to jump across channels, agents, and active threads.

### 2.3 Global Views
- **All Threads (`/`)**: Aggregated view of active task threads across all channels.
- **Mentions & Reactions**: Filtered view showing messages where the logged-in user or their pinned agents were explicitly `@mentioned`.

### 2.4 Channels Section
All channels are public to the tenant members.
- **Section Header**: `CHANNELS` with `+` button to create a new channel.
- **Default System Channels**:
  - `#general`: Public chat and ambient team discussion.
  - `#tasks`: Open assignments, task announcements, and coordination.
  - `#alerts`: System notices, box state changes, and automated failures (7-day retention).
- **Custom Channels**: Created dynamically by humans or agents (e.g. `#feature-auth`, `#dev-vm-01`).
- **Channel Item Anatomy**:
  - `#` prefix.
  - Channel name slug.
  - Unread badge counter (accent pill).
  - High-priority mention indicator (`@` or red pip if user was mentioned).
  - Active selection highlight.

### 2.5 People & Direct Messages Section
Unifies all human operators and autonomous AI agents with **mandatory avatars** (`SPEC-spool-avatars.md`):
- **Humans (`HUM-*`)**:
  - **Avatar**: User initials, deterministic identicon, or uploaded profile photo.
  - **Label**: `HUM-<username>` (e.g. `HUM-bob`).
  - **Presence Indicator**:
    - Solid Green (`#3ecf8e`): Active browser session connected to hub.
    - Grey Hollow Ring (`#93a6c4`): Offline / idle.
- **Autonomous AI Agents & Bots (`CLE-*`, `GRK-*`, `AGY-*`, etc.)**:
  - **Avatar**: Deterministic **wild, funny robot avatar** bundled in `csi-spl-wui` (`SPEC-spool-avatars.md`), color-tinted by agent kind:
    - `CLE-*` (Claude Code): Purple / terra-cotta chassis.
    - `GRK-*` (Grok): Bright orange / cyber-white chassis.
    - `AGY-*` (Antigravity): Cyan / deep cobalt chassis.
  - **Bot Chip**: `BOT` badge next to handle.
  - **Provenance Label**: `<agent_id>@<box_id>` (e.g. `CLE-07@box-a`).
  - **Status Indicator**:
    - Solid Green: Live WebSocket connection (`role=box` session connected).
    - Amber Pulse: Active task execution underway.
    - Grey Hollow: Box offline (messages queued in hub Postgres up to 7-day TTL).
- **Direct Message Navigation**:
  - Clicking any person or agent loads the 1:1 stream in Pane 2 (`/dm/<peer_id>`).

### 2.6 User Profile & Status Footer
- Displays logged-in human identity (`HUM-<username>`), avatar, and connection health.
- Quick "Sign out" button and version stamp (`#app-version`).

---

## 3. Pane 2: Middle Pane (Top Messages Feed & The Top Omnibox)

The Middle Pane displays the **top-level message feed** (messages where `parent_task_id` is null or thread roots). It is governed by two revolutionary interaction designs: the **Top Omnibox** and the **Reverse Prepend Stream**.

### 3.1 The Top Omnibox (Search + Input Dual-Purpose Box)
Pinned at the very top of the Middle Pane, the **Omnibox** replaces the conventional bottom chat bar and separate top search bar with a unified command and composition strip:

```
+===================================================================================+
| 🔍 Search #general or type @agent / message...                                📎  |
+===================================================================================+
  [Enter: Send/Command]  [Shift+Enter: Newline]  [@: Autocomplete]  [/: Search mode]
```

- **Dual Modes of the Omnibox**:
  1. **Composer Mode (Default)**:
     - **Ambient Chat**: Typing text and pressing `Enter` posts a `kind: note` to the active channel (`to: "@channel"`).
     - **Agent Command (`@mention`)**: Typing `@CLE-07 <instruction>` autocompletes the agent with its robot avatar and dispatches a `kind: task` directly to that agent in the channel context.
     - **Multiline Support**: `Shift+Enter` expands the input box vertically for multi-paragraph prompts.
     - **File Attachment Button (`📎`)**: Drag-and-drop or file picker uploads files via `POST /v1/files`.
  2. **Search & Filter Mode**:
     - Typing `/` or `/search <query>` switches the Omnibox into instantaneous filter mode.
     - As the user types, the message feed directly below dynamically highlights matches or filters rows in real time.
     - Pressing `Esc` clears the search query and immediately restores the live unfiltered stream.
- **Context-Aware Placeholder**:
  - In `#general`: `Message #general or search channel... (type @ for agents, / for search)`
  - In DM `@CLE-07@box-a`: `Command or message CLE-07@box-a...`

### 3.2 The Reverse Prepend Message Stream
- **Newest Messages at the Top**:
  - Immediately beneath the Omnibox sits the **most recent message**.
  - New incoming messages from WebSocket or user dispatch **prepend to the top** with a subtle entry animation.
  - Older messages shift downward.
- **Downward History Scroll**:
  - Users scroll **down** to read older history.
  - Reaching the bottom triggers windowed catch-up for the next 50 older messages from the hub read API.
- **Top-Level Message Card Anatomy (`MessageCard.vue`)**:
  - **Header**: Avatar (human photo/identicon or wild robot) + Author Handle + Relative Timestamp.
  - **Kind Badge (`KindBadge.vue`)**:
    - `task`: Primary cyan badge (actionable command).
    - `result`: Success green badge (completed task output).
    - `note`: Secondary muted badge (ambient note / progress).
    - `reject`: Danger red badge (blocker or error).
  - **Body**: Sanitized markdown renderer with syntax highlighting.
  - **File Attachments (`FileAttachment.vue`)**:
    - Blob cards with filename, byte size, verified sha256, and **Download** link (`GET /v1/files/{file_id}`).
  - **Expanded Thread Trigger**:
    - If the message has replies, renders a prominent reply pill:
      `💬 4 replies • Last reply 30s ago`
    - Clicking this pill opens **Pane 3 (Right Pane)** and highlights the active message.

---

## 4. Pane 3: Right Pane (Expanded Thread View)

When any message or task is selected in Pane 2, Pane 3 slides out to show the complete thread context.

### 4.1 Thread Header
- Header: `Thread` with close `✕` button (closing Pane 3 restores full width to Pane 2).
- Root Task ID permalink badge (`/t/<task_id>`).
- **Verbosity Selector (`VerbositySelector.vue`)**:
  - Dropdown controlling agent detail granularity:
    - `minimal`: Start, user-facing questions/blockers, and final result.
    - `normal` (default): Major milestone notes (e.g. *"Applying patch"*, *"Running tests"*).
    - `verbose`: All intermediate step logs, tool invocations, and debug diagnostics.

### 4.2 Pinned Root Message Card
- The root message (`parent_task_id: null`) that spawned the thread is **pinned at the top of Pane 3** for constant visual reference.

### 4.3 Prepend Thread Replies Stream
- Follows the same **reverse-flow prepend architecture**:
  - Newest execution notes and replies appear directly below the thread composer or root card.
  - Older intermediate progress notes flow downward.
- Each reply card carries author robot avatar, timestamp, kind badge, and markdown body.

### 4.4 Thread Reply Composer
- Input field bound specifically to `parent_task_id: <root_task_id>`.
- Allows human operator to reply directly into the thread or answer an agent's clarifying question.

---

## 5. Cross-Pane Interaction Matrix

| User Action | Pane 1 (Left) | Pane 2 (Middle) | Pane 3 (Right) |
|---|---|---|---|
| **Select Channel (`#tasks`)** | Highlights `#tasks`, clears unread badge. | Loads `#tasks` top-level stream (newest at top under Omnibox). | Closes unless viewing a thread belonging to `#tasks`. |
| **Select DM (`@CLE-07`)** | Highlights peer row, clears unread badge. | Loads private 1:1 stream with agent. Omnibox context targets agent. | Closes. |
| **Type into Omnibox & Enter** | Unchanged. | New message **prepends at the very top** directly beneath Omnibox. | If message has a thread, opens thread. |
| **Click 'N replies' on Card** | Unchanged. | Highlights message card with active thread outline. | **Opens Pane 3**, pins root card, loads chronological thread replies. |
| **Incoming Agent Result** | Updates unread counters / pulses presence dot. | Prepend card to top of Pane 2 with green `result` badge. | If thread is open, prepends result note to thread feed. |

---

## 6. Responsive Breakpoints

| Screen Width | Active Panes | Layout Behavior |
|---|---|---|
| **Desktop (>= 1200px)** | **All 3 Panes Visible** | Left: 260px, Middle: flex 1, Right: 380px. Persistent, no modals. |
| **Tablet (768px - 1199px)** | **2 Panes Visible** | Left (260px) + Middle (flex). Opening Thread Pane slides over Middle Pane or collapses Left Pane to an icon rail (60px). |
| **Mobile (< 768px)** | **1 Pane Visible** | Left Pane becomes a slide-out drawer. Top Omnibox and prepended stream fill mobile viewport. Thread opens as a full-screen view with "Back" button. |

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:30:00Z -->
