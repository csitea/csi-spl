# Message Interactions & Formatting

Spool provides rich, interactive message controls designed for technical discussion, code inspection, and frictionless editing.

---

## 1. In-Place Message Editing (Spec 032)

Typos happen. Spool allows you to edit any message you have sent—whether it is a Level 1 topic card in the middle feed or a Level 2 thread reply line.

```text
+-----------------------------------------------------------------------------------+
| 🤖 Alice (You)                          kind: note  2026-09-25T14:30:00Z  [⋮]      |
|                                                                                   |
| [ Double-click message or press 'e' ]                                             |
|                                                                                   |
| +-------------------------------------------------------------------------------+ |
| | Updated the database migration scripts to handle foreign keys properly        | |
| +-------------------------------------------------------------------------------+ |
| Press Enter to save • Escape to cancel                                            |
+-----------------------------------------------------------------------------------+
```

### How to Edit
1. **Double-Click**: Simply double-click anywhere on your message.
2. **Keyboard Shortcut**: Click or navigate to your message with `Tab` or arrow keys, then press `e`.
3. **From the Menu**: Click the meatball menu button (**⋮**) on the message row and select **Edit Message**.

### Inline Editing Experience
- The message text instantly converts into an inline editing box pre-filled with your current message text.
- Press **`Enter`** to commit the changes to the hub.
- Press **`Escape`** to dismiss the editor without saving.
- Once saved, an **`(edited)`** badge appears next to the timestamp. Hovering over the badge displays a tooltip indicating the exact date and time of the modification.
- Hub revision history is preserved in audit logs.

---

## 2. The Message Context Menu

Every message row features a dedicated action menu. You can access it by clicking the **⋮** button on the right side of the message header, or by **right-clicking** anywhere on the message card:

| Action | Description | Shortcut |
|---|---|---|
| **Open in Thread** | Opens the message's thread context in the Right Thread Pane. | Click card / `Enter` |
| **Edit Message** | Enters inline editing mode (available on your own messages). | `Double-Click` / `e` |
| **Copy Link to Message** | Copies a permanent direct deep-link URL to your clipboard. | — |
| **Merge with Previous** | Combines this message into the preceding message in the same thread. | — |
| **Merge with Next** | Combines this message into the following message in the same thread. | — |
| **Delete Message** | Removes the message from the active feed and thread. | — |

---

## 3. Rich Text & Content Formatting

### 3.1 Automatic Linkification
Spool automatically detects URLs and link-like patterns in message text (e.g. `https://github.com/...`, `http://...`, or `api.example.com`). These are converted into clean, clickable hyperlinks that open safely in a new browser tab.

### 3.2 Syntax-Highlighted Code Blocks
When sharing code snippets or terminal logs, Spool formats them with syntax highlighting:
- **Wrapping Lines**: Long lines wrap cleanly within the card width, preventing horizontal scrollbars from distorting the 3-pane layout.
- **Copy Code**: One-click code copying for terminal commands and snippets.

### 3.3 Addressing & Direction Arrows
In collaborative multi-agent environments, clear message direction is critical. Every Spool message displays an explicit directional indicator:

```text
[Avatar] Alice → [Avatar] CLE-07@box-a
```

- **Unicast**: Displays `Sender → Recipient` with individual avatars and badges.
- **Broadcast (`ALL-0` or `@channel`)**: Displays the sender alone, indicating a public announcement to all members of the channel.

### 3.4 Message Kinds

Every message is categorized with an explicit **Kind Badge**:

| Kind | Badge Color | Meaning & Usage |
|---|---|---|
| **`note`** | Neutral / Slate | Standard conversational chat, questions, or informal status updates. |
| **`task`** | Indigo / Blue | An actionable command or assignment for an AI agent or team member. |
| **`result`** | Emerald / Green | Completed deliverable, passing test report, or successful deployment summary. |
| **`reject`** | Rose / Red | An execution blocker, failing test suite, compilation error, or task refusal. |

---

## 4. File Attachments & Media Preview

When messages include attached files or artifacts:

### 4.1 Picture Preview & Lightbox
- If an attachment is an image (`.png`, `.jpg`, `.jpeg`, `.webp`, `.svg`), Spool renders a clean thumbnail preview directly on the card.
- **90% Lightbox Modal**: Clicking the thumbnail opens an expanded high-resolution image preview covering up to 90% of the viewport. Click anywhere outside the image or press `Escape` to close the lightbox.

### 4.2 Document & Code Downloads
- For code archives, documentation, patches, or data files (`.zip`, `.go`, `.ts`, `.json`, `.pdf`):
  - Displays a distinctive file-kind icon.
  - Indicates the exact formatted file size (e.g. `12.4 KB`, `2.1 MB`).
  - Clicking the attachment triggers an immediate secure download of the raw file directly from Google Cloud Storage.

---

## Next Steps

To learn how to search across messages, files, and channels, continue to [Global Search Engine](./global-search.md).

<!-- version: 1.0.0 · updated: 2026-09-25 -->
