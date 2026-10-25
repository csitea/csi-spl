# Keyboard Shortcuts Cheat Sheet

Spool is designed with a **keyboard-first philosophy**, enabling software engineers and operators to navigate channels, inspect threads, author code blocks, and command AI agents without taking their hands off the keyboard.

---

## 1. Global Navigation

| Shortcut | Context | Action |
|---|---|---|
| **`Ctrl + K`** / **`Cmd + K`** | Global, not on a phone, also while typing and over Settings | Open the **command palette**: type to jump to a section, channel, person, topic, doc or settings page, then `Enter`; start with `>` to run an action on the selected message (Archive, Reply, …) or switch the theme. `Ctrl + K` again or `Escape` closes it. |
| **`/`** | Global, not on a phone | Focus the **Top Omnibox** immediately. On a phone the box is docked and `/` does nothing. |
| **`Escape`** | Omnibox focused | Blur the Omnibox and return focus to the previously active element |
| **`Escape`** | Modal or menu open | Dismiss open modal, dialog, or context menu |
| **`Escape`** | Message editor active | Cancel in-place message edit and restore original text |
| **`Shift + W`** | Global, desktop, not while typing | Close the **rightmost pane**, the same as its X: the topic pane on the right first, then a section page (Issues, Calendar, …), then the search results on the left. With no pane open beyond the conversation it does nothing. In a text field it types a capital W; `Ctrl + W` / `Cmd + W` stays the browser's. Off while **Settings → Behaviour → Keyboard shortcuts** is off |
| **`Tab`** / **`Shift + Tab`** | Global | Navigate forward or backward through interactive focus stops |
| **`ArrowDown` / `ArrowUp`** | Channels list, a channel row focused (a click on it keeps the focus there), desktop | Open the next or previous channel at once; the focus moves with it. The list does not wrap at its ends |
| **`j` / `k`** | Channels list, a channel row focused, desktop | The same as `ArrowDown` / `ArrowUp`; off while **Settings → Behaviour → Keyboard shortcuts** is off |
| **`Home` / `End`** | Channels list, a channel row focused, desktop | Open the first or the last channel |
| **`Enter`** | Channels list, the open channel's row, desktop | Move the focus into the channel's messages |

---

## 2. Top Omnibox & Composer

| Shortcut | Context | Action |
|---|---|---|
| **`Enter`** | Omnibox (Plain text) | Send message or dispatch agent task (default; see **Settings → Behaviour → Text fields**) |
| **`Enter`** | Omnibox (`/search` mode) | Submit global workspace search query |
| **`Shift + Enter`** | Omnibox | Insert a newline without sending |
| **`Ctrl + Enter`** / **`Cmd + Enter`** | Omnibox / Composer | Send — even inside a code block |
| **` ``` `** + **`Enter`** | Omnibox start of line | Enter **Code Composer Mode** (fenced code editor) |
| **`Enter`** | In Code Block | Insert a newline |
| **`Escape`** | In Code Block | Close the fence and keep typing normal text below it |
| **`@`** | Omnibox | Trigger mention autocomplete for team members and AI agents |
| **`in:`** | Omnibox | Trigger topic autocomplete for target routing |
| **`ArrowDown` / `ArrowUp`** | Autocomplete menu | Move selection through suggestion list |
| **`Enter` / `Tab`** | Autocomplete menu | Insert selected mention, topic, or operator |

---

## 3. Message Cards & Thread Navigation

| Shortcut | Context | Action |
|---|---|---|
| **`Double-Click`** | Any message of yours | Open **In-Place Message Editor** |
| **`e`** | Focused message of yours | Open **In-Place Message Editor** |
| **`Enter`** | Focused message card | Open the message's thread context in the **Right Thread Pane** |
| **`Enter`** | Editing message | Save changes and update message across workspace |
| **`Right-Click`** | Message card | Open **Message Actions Context Menu** |
| **`ArrowDown` / `ArrowUp`** | Message feed | Move focus between message cards in feed |
| **`j` / `k`** | Message feed | **j** moves the selection down and **k** moves it up, the same as the arrow keys |

---

## 4. Pane Dividers & Resizing

| Shortcut | Context | Action |
|---|---|---|
| **`Double-Click`** | Pane divider seam | Reset sidebar or thread pane to default width |
| **`ArrowLeft` / `ArrowRight`** | Focused pane divider | Step pane width by **`16px`** |
| **`Home`** | Focused pane divider | Snap pane to its minimum permitted width |
| **`End`** | Focused pane divider | Snap pane to its maximum permitted width |

---

## 5. Global Search Results (`/search`)

| Shortcut | Context | Action |
|---|---|---|
| **`ArrowDown` / `ArrowUp`** | Search results | Move selection across grouped search result items |
| **`Enter`** | Selected search item | Open the selected message, thread, channel, or file |
| **`Home` / `End`** | Search results | Jump directly to the top or bottom of the search results |

---

## 6. Accessibility & Screen Reader Support

Spool conforms to modern accessibility standards:
- **Logical Tab Order**: Follows DOM reading order (Top Bar → Navigation Rail → Active Feed → Thread Pane).
- **WAI-ARIA Attributes**: Message cards announce sender, timestamp, kind, and reply counts via `aria-label` and `aria-describedby`.
- **Live Regions**: Incoming live messages and connection status transitions announce via `aria-live="polite"`.

---

## 7. Message shortcuts

These keys act on the **selected message**. They work on a desktop. Turn them off under **Settings → Behaviour → Keyboard shortcuts**; while that setting is off, the keys do nothing.

| Shortcut | Context | Action |
|---|---|---|
| **`Shift + H`** | Selected message, desktop | Hide from flow |
| **`Shift + R`** | Selected message, desktop | Open menu |
| **`Shift + E`** | Selected message, desktop | Edit |
| **`Shift + A`** | Selected message, desktop | Archive / Unarchive |
| **`Shift + O`** | Selected message, desktop | Open |
| **`Shift + P`** | Selected message, desktop | Open parent section |
| **`Shift + B`** | Selected message, desktop | Go to the topic's first message in the list |
| **`Shift + U`** | Selected message, desktop | Back to the reply |
| **`Shift + L`** | Selected message, desktop | Copy link |
| **`Shift + C`** | Selected message, desktop | Copy text |
| **`Shift + K`** | Selected message, desktop | Change kind |
| **`Shift + X`** | Selected message, desktop | Make it a task |
| **`Shift + T`** | Selected message, desktop | Make it a topic |
| **`Shift + M`** | Selected message, desktop | Move or merge… |
| **`Shift + D`** | Selected message, desktop | Delete |

## 8. When these keys stay quiet

A message shortcut runs only when that menu item would be offered for the selected message. **`Shift + R`** opens the selected message's menu. **`Shift + B`** works on a reply in the topic pane on the right: it selects that topic's first message in the list in the middle (the channel's or the direct messages' card, or the topic's row in the topic view) and scrolls it into view. When the list does not show that topic, it selects the topic's first message in the topic pane instead, reading older replies in when that message is not loaded. **`Shift + U`** on that first message selects the reply you came from again, in the panel it was in, or the topic's latest reply when you did not come from one. On a topic's first message, or a message with no topic, **`Shift + B`** does nothing. It does nothing while you are typing, while a menu or a dialog is open, or while Ctrl, Cmd or Alt is held, and it does nothing on a phone. **`Shift + ?`** opens this list.

## 9. Release notes

In the **Release notes** dialog (the version at the bottom of the left pane, then **Release notes**). The letter keys work on a desktop, never while you type, and turn off with **Settings → Behaviour → Keyboard shortcuts**.

| Shortcut | Context | Action |
|---|---|---|
| **`j` / `k`** | Release notes list, desktop | Move to the next or previous version row; past the last one it loads older versions |
| **`Enter`** | A version row, desktop | Open that version alone |
| **`h` / `l`** | An opened version, desktop | Show the older or the newer version |
| **`Escape`** | An opened version | Back to the list, on the version you opened (**All versions** does the same) |
| **`Escape`** | Release notes list | Close the dialog |

**Load older versions** at the end of the list reads the next older versions, until the list ends with **This is the first entry**.

## 10. Issue row shortcuts

On the **Issues** list these keys act on the **selected issue row**, the same keys the messages use for the same actions. Each runs the row's right-click menu item, and only when that menu offers it. They work on a desktop and follow **Settings → Behaviour → Keyboard shortcuts**. On a phone, swipe an issue card **left** to archive it (after a confirm) and **right** to open its menu, the same as a message card; a long press opens the menu too.

| Shortcut | Context | Action |
|---|---|---|
| **`Shift + R`** | Selected issue row, desktop | Open menu |
| **`Shift + E`** | Selected issue row, desktop | Edit |
| **`Shift + A`** | Selected issue row, desktop | Archive |
| **`Shift + O`** | Selected issue row, desktop | Open |
| **`Shift + P`** | Selected issue row, desktop | Open parent |
| **`Shift + L`** | Selected issue row, desktop | Copy link |
| **`Shift + K`** | Selected issue row, desktop | Change kind |
| **`Shift + M`** | Selected issue row, desktop | Move to… |
| **`Shift + D`** | Selected issue row, desktop | Delete |

## 11. Flow line shortcuts

In the **Flow** list these keys act on the **selected line**, the same keys the messages use for the same actions. A line folds one topic's day (or one day of releases), so the keys that change one message (edit, archive, move, delete, the thread jumps) do nothing there. **Shift + O** opens the discussion, or the release log on a release line. Right-click a line (a long press on a phone) for its menu: Open discussion, Open issue when the topic has one, Open release log, Copy link, Copy text and Mark read. They follow **Settings → Behaviour → Keyboard shortcuts**.

| Shortcut | Context | Action |
|---|---|---|
| **`Shift + R`** | Selected Flow line, desktop | Open menu |
| **`Shift + O`** | Selected Flow line, desktop | Open discussion |
| **`Shift + O`** | Selected Flow line, desktop | Open release log |
| **`Shift + L`** | Selected Flow line, desktop | Copy link |
| **`Shift + C`** | Selected Flow line, desktop | Copy text |
| **`Shift + K`** | Selected Flow line, desktop | Change kind |

<!-- version: 1.2.5 · updated: 2026-10-11 -->
