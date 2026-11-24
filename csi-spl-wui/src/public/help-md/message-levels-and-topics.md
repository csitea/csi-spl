# Message Levels & Topics

Spool features a unique, purpose-built **Two-Tier Message Level Architecture** (governed by Specification `033-spool-message-levels`). It is designed to solve a fundamental problem in software engineering and AI agent collaboration: **preventing feed noise while preserving complete execution history**.

---

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

## 4. Opening and Navigating Topics

You can open and inspect any topic through multiple intuitive paths:

1. **Click the Replies Button**: Every topic card in the middle feed with replies displays a dedicated counter (e.g. `💬 3 replies`). Clicking it opens the thread in the Right Pane immediately.
2. **Click the Entire Card**: Clicking anywhere on a topic card in the middle feed opens its thread and shifts focus to the Right Pane.
3. **From a topic's own address (`/t/<topic>`)**: The page shows that topic's thread, the same thread a channel already uses, with the Channels list beside it. Leaving the page for an address that still names a topic keeps that topic open.
4. **Direct Deep Links**: Every topic has a unique permanent URL (e.g. `https://{{site}}/t/<uuid>`, or the same `/t/<uuid>` path on your own host). Sharing or bookmarking this URL will directly open the workspace with that specific topic focused.

---

## 5. Inside the Right Thread Pane

When the Right Pane opens, you have a complete view of the topic:

- **Topic Title Header**: Located at the top of the pane, displaying the title derived from the opening line, plus a close button (`✕`).
- **Pinned Root Opener**: The original Level 1 message card remains pinned at the very top of the thread, so you always retain full context of the original prompt or requirement.
- **Live Thread Stream**: Replies flow downward in reverse-prepend order (newest updates at the top of the reply list).
- **Ticking Relative Clock**: Each message displays a live ticking clock (e.g. `sent 2m ago`) alongside exact ISO timestamps on hover.
- **Infinite Catch-Up**: For long threads with dozens or hundreds of agent logs, clicking **Load more older replies** or scrolling down seamlessly fetches earlier chunks.

---

## 6. Switching Focus Between Middle and Right Panes

Spool makes it effortless to switch between starting a new topic and continuing an existing one:

| Your Intent | What to Do | What Spool Does |
|---|---|---|
| **Reply to open topic** | Click inside the Right Thread Pane (or click "Replies" on the card). | The Omnibox placeholder changes to *"Reply to topic..."*. Sending appends a **Level 2** thread line. |
| **Start a NEW topic in channel** | Click anywhere in the Middle Feed. | The Omnibox placeholder reverts to *"Message #channel..."*. Sending creates a **Level 1** topic card. |
| **Reply to a specific topic without clicking** | Type `in: <topic_name> <message>` in the Omnibox. | Spool routes the message directly into that topic as a **Level 2** line. |

**Give a new topic its priority as you write it**: end the topic's first message with `prio:1` to `prio:5` (`prio:01`, `prio-2` and `prio 3` work too, in any case). Spool removes the word from the message and the topic gets that priority instead of the default 3. A reply never changes a topic's priority: use the topic's **prio:** bar for that.

---

## 7. The Topic List

The two icons on the channel header, before the card size control, choose
which topic cards the middle pane shows and in which order. The choice is kept
in this browser.

- **Filter**: **All** shows every topic; **New** shows only the topics with
  messages you have not read.
- **Sort by**: **Last update** (the newest activity first), **Number of
  messages** (the most first) or **Priority** (1 first, 5 last; a topic nobody
  set is 3).
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

### 7.1 Selecting Topics and Multicasting (Planned — spec 186)

> [!NOTE]
> **Planned (spec 186, not built yet).** The topic selection and multicast
> controls below describe the planned workflow and are not in the live app yet.

Once built, you will be able to select multiple topics across one or more
channels of your workspace and act on them together — for example, to send one
prompt to several topics at once (**Multicast**).

- **Where selection will work**: on any channel's topic list (`#lobby` included)
  and on your own workspace's rows in **Monitoring → Topics** (rows from another
  workspace will not be selectable). Direct messages and the `issues` channel
  will not have topic selection boxes.
- **Ticking topics (desktop)**: hovering over or focusing a topic card will
  reveal the checkbox at its start; once one topic is ticked, checkboxes will
  appear on every card. Clicking will toggle a topic, **Shift-click** will
  select a range from the last ticked card, **`x`** on a focused card will
  toggle it, and **`Esc`** will clear the selection.
- **Ticking topics (phone)**: long-pressing or swiping right on a topic card
  will open its menu with a first item **Select** (in **Monitoring → Topics**,
  each own-workspace card will show its checkbox directly). While at least one
  topic is selected, every card will show its checkbox, tapping a card will
  toggle it instead of opening the topic, and card swipes and drag-to-move will
  pause until the selection is cleared.
- **Keeping your selection across filters and channels**: changing the channel
  filter (**All** / **New**, or column filters in **Monitoring → Topics**) or
  switching to another channel in the same workspace will keep your selection,
  so you can pick topics from several channels before acting. The page checkbox
  will select every topic currently shown, and **Select all N matching** will
  select all matching topics in that list (in **Monitoring → Topics**, only your
  current workspace's matching rows). The selection will stay in memory for your
  current browser session and clear when you click **Clear**, finish an action,
  switch workspaces, or reload the page.
- **The selection bar**: while one or more topics are selected, the selection
  bar will replace the list header. It will show the page checkbox, the
  selection count (with `in k channels` when spanning multiple channels),
  **Select by title**, the bulk action buttons (such as **Multicast**), and
  **Clear**. On a phone, the bar will use icon buttons with tooltips and
  accessibility labels.
- **Select by title (patterns and `*`)**: opening **Select by title** from the
  selection bar — or from the list header when nothing is selected — will let
  you enter one pattern per line (up to 10 lines; as a sheet on a phone):
  - `*` on a line will select every active channel topic in your workspace that
    you can read and act on (excluding archived topics, direct messages, and
    issue discussions).
  - Any other line will act as a case-insensitive regular expression (RE2)
    matched anywhere in the topic title (use `^`, such as `^release`, to anchor
    to the start).
  - **Add matching topics** will ask the hub to resolve the patterns and add
    the matching topics to your selection (deduplicated). An invalid pattern
    will name the line and add nothing.
- **Multicast**: clicking **Multicast** in the selection bar will open the
  **Send to n topics** dialog (a full-screen sheet on a phone). It will list
  the selected topics grouped by channel — each with a remove button (`×`) —
  above a composer with `@mentions` and file attachments (your page composer
  and its draft will not change).
  - Spool will check every target before sending (access, archived state, files,
    and remaining workspace message quota). **Send to n topics** will stay
    disabled while any target is refused; removing refused targets with `×`
    will re-check.
  - Sending will upload attached files once and post one normal message into
    each selected topic. Each copy will route normally to that topic's or
    channel's agents and any leading `@mention`, and count as one message
    toward your workspace's monthly quota. Replies will stay in each topic on
    its own.
  - The dialog will show per-topic status as copies arrive. When every topic
    succeeds, the dialog will close and the selection will clear; if a copy is
    refused at send time, the dialog will stay open with your text and offer
    **Retry** for the failed topics.
  - In **Discussion loops**, the **Send to several topics** switch will reuse
    your current selection and title patterns so a loop can post to matching
    topics on every fire (patterns will be re-resolved at fire time).

---

## Next Steps

To explore rich message interactions, code formatting, and attachments, see [Message Interactions & Formatting](./message-actions-and-formatting.md).

<!-- version: 1.3.0 · updated: 2026-11-24 -->
