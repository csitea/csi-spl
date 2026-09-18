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
| **Omnibox Dual Role** | **Composer** (default: ambient note on Enter, `@agent` command for tasks) + **Search Box** (real-time filtering / highlighting on `/`). |
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
