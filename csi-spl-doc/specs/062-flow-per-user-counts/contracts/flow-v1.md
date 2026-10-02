# flow-v1: the per-member Flow (spec 062, frozen contract)

Status: **frozen** for lanes L3 (hub) and L4 (WUI). A change needs both lanes.
It refines spec 062 sections 3.2 and 4.2; where they differ, this file wins.

## 1. Who gets events

- Only members with a human seat (`HUM-<n>`, `GST-<n>`). Agents get none (Q5).
- Never for the member's own line, nor a line they typed at a terminal (`typed_by`).
- Never for a line the member cannot read (the read door: a DM by its two
  ends, a created channel by its member list). The door is applied again on
  every read, so a member removed from a channel stops counting its events.
- One event per (member, message). Kind precedence: `mention` > `poke` > `dm` > `reply`.

| kind | when |
|---|---|
| `mention` | the body names `@X` / `@X@<box>` (the WUI `MENTION_RE` grammar), or a channel line's `to` is X |
| `poke` | a poke DM to X (`<ID> needs you in <url>/t/<task_id>: "...`) when X has no `mention` event in `<task_id>` yet; with one, the poke folds in and writes **no** event |
| `dm` | a DM whose `to` is X |
| `reply` | a line in a thread X watches (X posted in it, was mentioned in it, or was its `to`) |

## 2. GET /v1/view/flow

Signed-in member session only (403 `forbidden` otherwise, as `/v1/me/reads`).

| query | meaning |
|---|---|
| `limit` | 1..50, default 30 |
| `before` | the `cursor` of the last event of the previous page (opaque) |
| `kind` | `mention` (includes `poke`), `reply` or `dm`; absent = all |
| `counts_only=true` | answer `{counts, unread}` only |

```json
{
  "events": [],
  "next": "",
  "counts": {"mention": 2, "reply": 5, "dm": 1, "total": 8},
  "unread": {"mention": 3, "reply": 9, "dm": 1, "total": 13}
}
```

- `events` is newest first. `next` is `""` on the last page.
- `counts` = **unseen and unread**, the badge: newer than the `f:seen` mark
  AND not covered by a mark (section 3). It drops to 0 when the pane opens.
- `unread` = **unread regardless of `f:seen`**: the in-pane chips.
- `mention` counts include `poke`. `total` = `mention + reply + dm`.
- `kind` filters `events` only; `counts` and `unread` are always the whole flow.
- Expired events (the message's `expires_at`) are never listed or counted.

### 2.1 Event (the thin entry, no `env`)

| field | type | note |
|---|---|---|
| `msg_id` | string | |
| `cursor` | string | for `before=` |
| `received_at` | RFC 3339 | |
| `kind` | `mention` \| `poke` \| `dm` \| `reply` | |
| `unread` | bool | false once a mark covers it |
| `from`, `from_box` | string | |
| `to`, `to_box` | string | `""` when none |
| `typed_by` | string | omitted when empty |
| `channel` | string \| null | null = a DM |
| `task_id` | string | |
| `parent_task_id` | string | omitted for a root topic |
| `text` | string | the body, whitespace folded, at most 90 characters (a cut ends in `…`) |
| `files` | int | attachment count |

## 3. Marks (PUT /v1/me/reads, the existing route)

- `f:seen` `{ts}`: the member opened the Flow pane. Forward-only like every mark.
- `f:<msg_id>` `{ts}`: the member opened that entry from the Flow.
- An event is **covered** (unread = false) by `f:<msg_id>`, by a `t:<task_id>`
  mark at or past it, by `ch:<channel>` at or past it (a channel line), or by
  `dm:<from>` / `dm:<from>@<from_box>` at or past it (a DM).
- `f:<msg_id>` rows are swept with their message.

## 4. WS frame on /v1/wui/ws

```json
{"type": "flow", "counts": {}, "unread": {}, "event": null}
```

- `counts` and `unread` as in section 2; `event` an Event (2.1) or null.
- Only to the sockets of the member the event is for, on every hub process.
- `event` set: a new event was written for that member.
- `event` null (counts only): the member's marks moved (any `PUT /v1/me/reads`),
  pushed to every socket of that member, the writing tab included.
- On reconnect the WUI re-reads `GET /v1/view/flow?counts_only=true`.
- The `message` frame is unchanged.
