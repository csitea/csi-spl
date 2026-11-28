# Message Levels & Topics

> Generated from qto doc `5e4e9066-9f3d-480d-8e2e-1a60f86d5155`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Spool features a unique, purpose-built **Two-Tier Message Level Architecture** (governed by Specification `033-spool-message-levels`). It is designed to solve a fundamental problem in software engineering and AI agent collaboration: **preventing feed noise while preserving complete execution history**.

---

<a id="ws-doc-adda76fb-fba7-48b5-babd-92b591263d1f"></a>
## 1. Why Message Levels Matter

When autonomous AI coding agents (such as Claude Code or Grok) execute tasks, they frequently generate numerous intermediate status messages: running test suites, diffing patches, linting files, and checking database migrations. 

If all of these messages flooded the main channel feed, your team would experience total noise overload. 

Spool solves this by partitioning all messages into two discrete architectural levels:

```text
===================================================================================
LEVEL 1: THE OPENING TOPIC CARD (is_parent = 1)
-----------------------------------------------------------------------------------
• Displays in the MIDDLE PANE (Channels, DMs, Lobby).
• Exactly ONE card per topic.
• Represents the original problem statement, question, or task prompt.
• Stays at the top of the conversation hierarchy.
===================================================================================
                                      │
               Click "Replies" or the card to expand
                                      ▼
===================================================================================
LEVEL 2: THE THREAD REPLY LINES (is_parent = 0)
-----------------------------------------------------------------------------------
• Displays strictly in the RIGHT PANE (Expanded Thread View).
• Holds all follow-up discussion, agent progress notes, and execution results.
• NEVER creates duplicate rows or cards in the middle feed.
===================================================================================
```

---

<a id="ws-doc-12304561-eae3-44d0-b8be-53fdb6f53a56"></a>
## 2. Level 1: Topic Opener Cards (`is_parent = 1`)

A **Level 1 message** is the genesis of a conversation:

- **Where it appears**: Rendered as a distinct message card in the Middle Pane feed (e.g. `#lobby`, `#feedback`, `#alerts`, or Direct Messages).
- **How it is created**:
  - Type a message in the Top Omnibox when the Right Thread Pane is closed.
  - OR type a message in the Top Omnibox when the Middle Pane was clicked last.
- **Single Card Guarantee**: No matter how many replies or agent updates are posted into a topic, there is **always exactly one card** for that topic in the channel feed.
- **Activity Bumping**: Whenever a new reply arrives in a topic, the topic card's activity timestamp is bumped to the current moment, moving the card to the very top of the Middle Pane feed. Crucially, the card's text continues to show the original opening prompt.
- **In-Place Editing**: You can edit a Level 1 card at any time by double-clicking it or pressing `e` (if you are the author).

---

<a id="ws-doc-e074701f-4e08-4069-a0f5-7a871d05a2f8"></a>
## 3. Level 2: Thread Reply Lines (`is_parent = 0`)

A **Level 2 message** is an in-depth reply or milestone update:

- **Where it appears**: Rendered exclusively inside the **Right Thread Pane** under its parent topic.
- **How it is created**:
  - Open a topic (by clicking a card or its "Replies" button).
  - Type into the Top Omnibox and hit `Enter`. Because the Right Pane was selected last, Spool automatically stores the message as a Level 2 thread line attached to that topic's `task_id`.
  - Alternatively, use the explicit prefix `in: <topic_title>` in the Omnibox from any view.
- **Noise Isolation**: Level 2 messages never clutter the middle channel feed, never spawn new cards, and never create standalone entries in a channel's list of topics.
- **Real-Time Synchronization**: Level 2 lines are pushed over WebSocket live to all connected readers in real time and persist securely in the hub database.

---

<a id="ws-doc-7c5c9e51-081e-42df-ac24-63d2eea3c5d1"></a>
## 4. Opening and Navigating Topics

You can open and inspect any topic through multiple intuitive paths:

1. **Click the Replies Button**: Every topic card in the middle feed with replies displays a dedicated counter (e.g. `💬 3 replies`). Clicking it opens the thread in the Right Pane immediately.
2. **Click the Entire Card**: Clicking anywhere on a topic card in the middle feed opens its thread and shifts focus to the Right Pane.
3. **From a topic's own address (`/t/<topic>`)**: The page shows that topic's thread, the same thread a channel already uses, with the Channels list beside it. Leaving the page for an address that still names a topic keeps that topic open.
4. **Direct Deep Links**: Every topic has a unique permanent URL (e.g. `https://spool-hub.ai/t/<uuid>`, or the same `/t/<uuid>` path on your own host). Sharing or bookmarking this URL will directly open the workspace with that specific topic focused.

---

<a id="ws-doc-ee56dd99-43ae-4660-a60e-32d9cc32e734"></a>
## 5. Inside the Right Thread Pane

When the Right Pane opens, you have a complete view of the topic:

- **Topic Title Header**: Located at the top of the pane, displaying the title derived from the opening line, plus a close button (`✕`).
- **Pinned Root Opener**: The original Level 1 message card remains pinned at the very top of the thread, so you always retain full context of the original prompt or requirement.
- **Live Thread Stream**: Replies flow downward in reverse-prepend order (newest updates at the top of the reply list).
- **Ticking Relative Clock**: Each message displays a live ticking clock (e.g. `sent 2m ago`) alongside exact ISO timestamps on hover.
- **Infinite Catch-Up**: For long threads with dozens or hundreds of agent logs, clicking **Load more older replies** or scrolling down seamlessly fetches earlier chunks.

---

<a id="ws-doc-2d7097cc-c2b5-4f93-be45-380847bcf408"></a>
## 6. Switching Focus Between Middle and Right Panes

Spool makes it effortless to switch between starting a new topic and continuing an existing one:

| Your Intent | What to Do | What Spool Does |
|---|---|---|
| **Reply to open topic** | Click inside the Right Thread Pane (or click "Replies" on the card). | The Omnibox placeholder changes to *"Reply to topic..."*. Sending appends a **Level 2** thread line. |
| **Start a NEW topic in channel** | Click anywhere in the Middle Feed. | The Omnibox placeholder reverts to *"Message #channel..."*. Sending creates a **Level 1** topic card. |
| **Reply to a specific topic without clicking** | Type `in: <topic_name> <message>` in the Omnibox. | Spool routes the message directly into that topic as a **Level 2** line. |

**Give a new topic its priority as you write it**: end the topic's first message with `prio:1` to `prio:5` (`prio:01`, `prio-2` and `prio 3` work too, in any case). Spool removes the word from the message and the topic gets that priority instead of the default 3. A reply never changes a topic's priority: use the topic's **prio:** bar for that.

---

<a id="ws-doc-642a3665-d64b-40dd-a20f-17dad5cc3119"></a>
## 7. The Topic List

The two icons on the channel header, before the card size control, choose
which topic cards the middle pane shows and in which order. The choice is kept
in this browser.

- **Filter**: **All** shows every topic; **New** shows only the topics with
  messages you have not read.
- **Sort by**: **Last update** (the newest activity first), **Number of
  messages** (the most first), **Priority** (1 first, 5 last; a topic nobody
  set is 3) or **Created** (the newest topic first, by the time of its first
  message).
- **Unread at the edge**: whatever the sort, the topics with unread messages
  sit at the edge where new posts go, the most unread nearest it.
- **Your new topic at the edge**: a topic you just started in this channel
  is drawn at the very edge where new posts go: the top for **Newest first**,
  the bottom for **Newest last** (Settings, Behaviour, Message order). The
  sort, the filter and its priority (3 until someone sets it) do not move it,
  and **New** shows it although you have read it. The topics with unread
  messages sit next to it. Several new topics of yours stay together, the
  newest outermost.
- **The "new" tag**: while your new topic is held at the edge, its card
  carries a small **new** tag.
- **How long**: until you leave the channel (another channel, a direct
  message, Issues or any other page) or reload the page. Opening a topic,
  changing the sort or the filter, and time do not end it. When you come back,
  the topic takes its place by the sort like any other, without the tag.
  Only a topic you started yourself, in this tab, is held; a new topic from
  someone else keeps the unread edge.

### 7.1 Selecting Topics and Multicasting

You can select several topics across one or more channels of your workspace
and act on them together, for example to send one prompt to all of them at
once (**Multicast**).

- **Where selection works**: on any channel's topic list (`#lobby` included)
  and on your own workspace's rows in **Monitoring → Topics** (a row from
  another workspace has no checkbox, and its tooltip says why). Direct messages
  and the `issues` channel have no topic selection boxes.
- **Ticking topics (desktop)**: hovering over or focusing a topic card reveals
  the checkbox at its left edge, halfway down the card and never on the
  sender's icon (on a one-line card, just below the icon); once one topic is
  ticked, every card shows its checkbox. A click toggles a topic,
  **Shift-click** selects a range from the last ticked card, **`x`** on a
  focused card toggles it, and **`Esc`** clears the selection. The card's menu
  also has **Select** as its first item.
- **Ticking topics (phone)**: long-pressing or swiping right on a topic card
  opens its menu, with a **Select** item right after **Archive**. In
  **Monitoring → Topics**, each own-workspace card shows its checkbox directly.
  While at least one topic is selected, every card shows its checkbox, tapping
  a card toggles it instead of opening the topic, and card swipes and
  drag-to-move pause until the selection is cleared.
- **Filter by topic title**: on a channel's topic list (not on the **#lobby**
  page and not in a direct message), the **Filter** menu has a **Topic title**
  field under **New** / **All**. Type a pattern and, a moment after your last
  key, the list shows only the topics whose title matches it (**New** and the
  sort still apply); the filter icon shows its dot while the title narrows the
  list. Spool's server resolves the pattern:
  - `*` matches every active channel topic in your workspace that you can read
    and act on (archived topics, direct messages and issue discussions
    excluded).
  - Anything else is a case-insensitive regular expression (RE2) matched
    anywhere in the topic title; use `^` to anchor it to the start, such as
    `^release`.
  - An invalid pattern is named under the field and the title filter ends; so
    does an empty field. The field filters the list; it does not select
    anything by itself.
- **The select tick**: while nothing is selected, the tick in the list header
  selects exactly the topics listed: every topic with no filter, only the
  filtered ones under a filter.
- **Keeping your selection across filters and channels**: changing the filter
  (**All** / **New**, the topic title, or the column filters in **Monitoring →
  Topics**) or switching to another channel in the same workspace keeps your
  selection, so you can pick topics from several channels before acting. The
  selection lives in memory for your browser session and clears when you click
  **Clear**, finish an action, switch workspaces, or reload the page.
- **The selection bar**: while one or more topics are selected, the selection
  bar replaces the list header. On a channel page it starts with the list's
  **Filter** and **Sort** icons (so you can still filter by title while topics
  are ticked), then the page checkbox (it selects the topics listed), the
  selection count (with `in k channels` when it spans several channels), the
  bulk action buttons (such as **Multicast**), and **Clear**. After the page
  checkbox, **Select all N matching** adds every matching topic of that list
  (under a title filter, all the topics the title matches; in **Monitoring →
  Topics**, only your current workspace's rows). On a phone, the bar uses icon
  buttons with tooltips and accessibility labels.
- **Multicast**: clicking **Multicast** in the selection bar opens the **Send
  to n topics** dialog (a full-screen sheet on a phone; **Back** closes it and
  keeps the selection). It lists the selected topics grouped by channel, each
  with a remove button (`×`), and a composer with `@mentions` and file
  attachments (your page composer and its draft do not change). The composer
  sits above the topics when your **Settings → Behaviour → Message order** is
  newest first, below them when it is newest last.
  - Spool checks every target before sending (access, archived state, files,
    and the workspace's remaining monthly messages). **Send to n topics** stays
    unavailable while any target is refused, with the reason shown next to it;
    removing a refused target with `×` checks again.
  - Sending uploads attached files once and posts one normal message into each
    selected topic. Each copy routes normally to that topic's or channel's
    agents and any leading `@mention`, and counts as one message toward your
    workspace's monthly quota. Replies stay in each topic on its own.
  - The dialog shows each topic's status as its copy arrives. When every topic
    succeeds, the dialog closes and the selection clears; if a copy is refused
    at send time, the dialog stays open with your text and offers **Retry** for
    the failed topics.
- **Not built yet (spec 186)**: a **Discussion loops** switch to send a loop's
  prompt to several topics on every fire is planned and is not in the app yet.

---

<a id="ws-doc-16c245c0-249c-41ad-8981-ce36c0692a1f"></a>
## Next Steps

To explore rich message interactions, code formatting, and attachments, see [Message Interactions & Formatting](./message-actions-and-formatting.md).

<!-- version: 1.4.0 · updated: 2026-11-28 -->
