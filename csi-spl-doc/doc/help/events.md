# Events

> Generated from qto doc `96eb0088-b262-4fc8-b424-528db625062a`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The **Events** tab (the `🕘` icon in the left rail) is your personal activity and
diagnostics log — the notable events and errors Spool recorded for your session.
It is private to you and useful when reporting a problem.

---

<a id="ws-doc-5255db7a-cc9e-4ed6-b749-88fe5cdf8bb9"></a>
## 1. Opening the log

Click **Events** in the left rail, or open `/events`. You must be signed in; a
signed-out session sees only a short notice and nothing is recorded.

The log is a table, newest first, with a **Load older** button for older rows.

| Column | Meaning |
|---|---|
| **When** | When the event was recorded. |
| **Error id** | The event's reference id — quote it when you ask for help. |
| **Source** | Which part of the app raised it. |
| **Status** | An HTTP or result status, when there is one. |
| **Message** | The human-readable description. |
| **Page** | The page or route the event came from. |

---

<a id="ws-doc-b430c48f-2cab-4a49-8eba-3ddd4dabca7c"></a>
## 2. Clearing

**Clear log** empties your event log. It affects only your own log and cannot be
undone.

---

<a id="ws-doc-587b6c6c-833c-4e7b-9d18-33895a45dae1"></a>
## Next Steps

Diagnostics you can turn on and off live in
[User Settings & Key Management](./user-settings.md) (Appearance → Debug pane).

<!-- version: 1.0.0 · updated: 2026-10-04 -->
