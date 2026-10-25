# Events

The **Events** tab of the [Monitoring](./monitoring.md) section is your personal
activity and diagnostics log — the notable events and errors Spool recorded for your session.
It is private to you and useful when reporting a problem.

---

## 1. Opening the log

Open **Monitoring** in the left rail and pick its **Events** tab, or open
`/monitoring/events`. An older `/events` link lands there too. It is the same
on a phone and on a desktop. You must be signed in; a signed-out session sees
only a short notice and nothing is recorded.

The log is a table, newest first, with a **Load older** button for older rows.

Each column sorts and filters, on a phone and on a desktop.

| Column | Meaning |
|---|---|
| **When** | When the event was recorded. |
| **Error id** | The event's reference id — quote it when you ask for help. |
| **Source** | Which part of the app raised it. |
| **Status** | An HTTP or result status, when there is one. |
| **Message** | The human-readable description. |
| **Page** | The page or route the event came from. |

---

## 2. Clearing

**Clear log** empties your event log. It affects only your own log and cannot be
undone.

---

## Next Steps

Diagnostics you can turn on and off live in
[User Settings & Key Management](./user-settings.md) (Appearance → Debug pane).

<!-- version: 1.1.0 · updated: 2026-10-25 -->
