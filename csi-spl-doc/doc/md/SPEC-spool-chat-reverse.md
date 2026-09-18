# SPEC: Reverse chat flow (long-term WUI option)

Status: **after M3**. Not the M3 default.  
Related: `SPEC-spool-wui.md`

Chats gain a **UI option** to **reverse** the transcript: the user **types at
the top**; new messages **prepend** (newest first, immediately under the
composer). Older messages sit **below**; scroll down for history.

This is **display only**. `v:1` `ts` / `msg_id` / `task_id` do not change.
The hub still stores chronological time. CLI/`spool-tail` stay oldest-first
unless a later `--reverse` flag is added.

---

## 1. Two modes

| Mode | Composer | Insert | History |
|---|---|---|---|
| **Classic** (M3 default) | Bottom | **Append** (Slack-like) | Oldest at top; scroll down for new |
| **Reverse** (this feature) | **Top** | **Prepend** | Newest under the composer; scroll down for older |

The option is per **human user** (and may follow a tenant default). Persist
in the WUI account/prefs, not in the message schema.

---

## 2. Behaviour in reverse mode

- Composer is pinned at the **top** of the channel / DM / thread.
- Sending or receiving a message **inserts it under the composer**, shifting
  older rows down.
- Live WS frames prepend the same way.
- Load-more / infinite scroll loads **older** messages **below**.
- Threads inherit the parent view’s mode unless overridden.

Screen readers and keyboard order must match visual order (composer, then
newest, then older) so “prepend” is not a CSS-only trap.

---

## 3. Out of this feature

Changing M3 to reverse-only. Protocol sort on the hub. Mobile-only
exceptions (same two modes).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:40:00Z -->
