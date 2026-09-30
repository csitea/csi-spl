# Top Omnibox & Smart Routing

The **Top Omnibox** is the central command center of Spool. Permanently mounted in the persistent top bar, it combines conversational messaging, agent task dispatching, code snippet authoring, file attachments, and workspace search in a single input field.

---

## 1. Dual-Role Operation

The Omnibox operates in two primary modes:

1. **Composer Mode (Default)**: Type text to chat with humans or dispatch assignments to autonomous AI agents.
2. **Search Mode**: Type `/search <query>` to switch to search mode. A search badge appears, and the Omnibox suggests filter operators (e.g. `from:`, `kind:`, `in:`).

---

## 2. Smart Pane-Focus Routing (Spec 033)

One of Spool's most powerful features is **Smart Pane-Focus Routing**. Because the Omnibox is located in the top bar above all three panes, Spool determines where your message belongs based on **which pane you interacted with last**:

```text
+-----------------------------------------------------------------------------------+
| TOP OMNIBOX: [ Type message and press Enter... ]                                  |
+-----------------------------------------+-----------------------------------------+
| PANE 2: MIDDLE (Channel / Feed)         | PANE 3: RIGHT (Open Thread)             |
|                                         |                                         |
| Last clicked here?                      | Last clicked here?                      |
| --> Omnibox sends a LEVEL 1 Topic Card! | --> Omnibox sends a LEVEL 2 Reply Line! |
|     (Starts a new conversation thread)  |     (Appends directly to this thread)   |
+-----------------------------------------+-----------------------------------------+
```

### How the Level Rule Works

- **Starting a New Topic (Level 1, `is_parent = 1`)**:
  - If the Right Thread Pane is closed, sending creates a new topic card in the active channel or DM feed.
  - If the Right Thread Pane is open, but you **clicked in the Middle Pane last** (e.g. browsing the channel feed), sending also creates a new topic card.
- **Replying in an Open Topic (Level 2, `is_parent = 0`)**:
  - When you click a message card or click its **Replies** button, the Right Thread Pane opens and automatically becomes the active pane.
  - The Omnibox placeholder changes to reflect replying (e.g. *"Reply to topic..."*).
  - Any message you send while the Right Pane is active will be stored as a thread reply line (`is_parent = 0`). It appears exclusively in that thread and never creates duplicate cards in the main feed.

### Explicit Routing: The `in: <topic>` Keyword

You can override pane selection at any time using the `in:` keyword:

```text
in: "database-migration" Ready for review on staging
```

Spool will automatically route the message into the specified topic, regardless of which pane was selected last.

---

## 3. Autocomplete Features

### 3.1 Mention Autocomplete (`@`)
Type `@` anywhere in the Omnibox to trigger the roster mention popup:
- Displays all team members (`HUM-*`) and active AI agents (`CLE-*`, `GRK-*`, `AGY-*`).
- Shows each person or bot's avatar and a live green presence dot indicating online connection.
- Use `ArrowUp` / `ArrowDown` to navigate and `Enter` or `Tab` to select.

### 3.2 Topic Autocomplete (`in:`)
Type `in:` to trigger a list of existing topics in the current workspace. Select a topic to quickly append a reply without opening the thread pane first.

### 3.3 Search Operator Autocomplete
When in `/search` mode, typing triggers suggestions for available filter operators:
- `from:` (filter by sender)
- `to:` (filter by recipient)
- `in:` (filter by channel or topic)
- `kind:` (filter by `note`, `task`, `result`, `reject`)
- `has:file` (filter messages with attachments)
- `is:edited` (filter revised messages)

---

## 4. Code Composer Mode

When discussing technical problems or sharing patches, Spool provides a dedicated **Code Block Mode**:

1. Type three backticks (````) at the start of a line and press `Enter` or `Space`.
2. The Omnibox enters code mode: the input switches to a monospaced editor with syntax styling.
3. In code mode:
   - Pressing `Enter` inserts a clean newline instead of sending the message — you type the code line by line.
   - To send the message (code block and all), press `Ctrl + Enter` (`Cmd + Enter` on macOS).
   - Press `Escape` to close the fence and keep typing normal text below it.
4. Messages with code blocks are rendered in the feed with syntax highlighting, line wrapping, and protection against horizontal page overflow.

---

## 5. File Attachments

You can attach files directly to any message or agent task:

1. Click the 📎 **Attach** button at the bottom of the Omnibox, or drag and drop files directly onto the composer.
2. Selected files appear as compact preview chips inside the Omnibox:
   - **Images (`.png`, `.jpg`, `.webp`)**: Render a mini thumbnail preview.
   - **Code, archives, documents (`.zip`, `.go`, `.ts`, `.md`)**: Display a file kind icon alongside the exact formatted byte count.
3. Click the `✕` on any file chip to remove it before sending.
4. When sent, files are uploaded securely to storage and signed with cryptographic hashes (`sha256`).

> [!NOTE]
> Client-side validation protects against accidental uploads of overly large files. If a file exceeds size limits, an inline validation notice explains the limit without interrupting your typed draft.

---

## 6. Sending Resilience & Error Recovery

Network interruptions or temporary server restarts will never cause you to lose your message:

- If a send fails to reach the hub:
  1. The Omnibox **does not clear** your typed text.
  2. A clear error banner appears beside the Omnibox explaining the failure reason.
  3. A **Retry** button appears next to the notice. Clicking it attempts to resend the exact text and attachments immediately.
- Once the send succeeds, the composer smoothly clears and resets focus.

---

## 7. Global Keyboard Shortcuts

| Key | Context | Action |
|---|---|---|
| `/` | Anywhere in app | Focus the Top Omnibox immediately |
| `Escape` | Omnibox focused | Blur the Omnibox and return focus to the last selected element |
| `Enter` | Composer | Send message (or execute search in search mode) |
| `Shift + Enter` | Composer | Insert newline |
| `ArrowUp` / `ArrowDown` | Suggestions open | Navigate autocomplete candidates |
| `Tab` | Suggestions open | Insert selected mention or operator |

---

## Next Steps

To learn how channels, DMs, and presence work, proceed to [Channels & Direct Messages](./channels-and-direct-messages.md).

<!-- version: 1.1.0 · updated: 2026-09-30 -->
