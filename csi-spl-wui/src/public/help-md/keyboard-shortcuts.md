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
| **`Tab`** / **`Shift + Tab`** | Global | Navigate forward or backward through interactive focus stops |

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

These keys act on the **selected message**; in the **Topics** view, the Archive key also acts on the focused topic. They work on a desktop. Turn them off under **Settings → Behaviour → Keyboard shortcuts**; while that setting is off, the keys do nothing.

| Shortcut | Context | Action |
|---|---|---|
| **`Shift + H`** | Selected message, desktop | Hide from flow |
| **`Shift + R`** | Selected message, desktop | Open menu |
| **`Shift + E`** | Selected message, desktop | Edit |
| **`Shift + A`** | Selected message, desktop | Archive / Unarchive |
| **`Shift + O`** | Selected message, desktop | Open |
| **`Shift + P`** | Selected message, desktop | Open parent section |
| **`Shift + U`** | Selected message, desktop | Go to the topic's first message |
| **`Shift + B`** | Selected message, desktop | Back to the reply |
| **`Shift + L`** | Selected message, desktop | Copy link |
| **`Shift + C`** | Selected message, desktop | Copy text |
| **`Shift + K`** | Selected message, desktop | Change kind |
| **`Shift + T`** | Selected message, desktop | Make it a topic |
| **`Shift + M`** | Selected message, desktop | Move or merge… |
| **`Shift + D`** | Selected message, desktop | Delete |
| **`Shift + A`** | Focused topic, Topics view, desktop | Archive the focused topic (Topics view) |

## 8. When these keys stay quiet

A message shortcut runs only when that menu item would be offered for the selected message. **`Shift + R`** opens the selected message's menu. **`Shift + U`** works on a reply: it selects that topic's first message in the same view (the channel, the topic or the direct messages), reading older replies in when that message is not loaded. **`Shift + B`** then selects the reply you came from again, or the topic's latest reply when you did not come from one. On a topic's first message, or a message with no topic, **`Shift + U`** does nothing. It does nothing while you are typing, while a menu or a dialog is open, or while Ctrl, Cmd or Alt is held, and it does nothing on a phone. **`Shift + ?`** opens this list.

<!-- version: 1.2.2 · updated: 2026-10-07 -->
