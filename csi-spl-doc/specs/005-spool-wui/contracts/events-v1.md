# Contract: events-v1 — a human's personal event log

**Owner spec**: `../spec.md` FR-016 / FR-017 · **Status**: Implemented (CLE-34990)
**Store**: rdb `0045_human_events.sql` · **Hub**: `internal/hub/events.go`,
`internal/store/human_events*.go` · **WUI**: `src/utils/event-log.mjs`,
`src/utils/error-snackbar.mjs`, `src/plugins/event-log.client.ts`

> Owner, 2026-09-25, PRD #spool-hub-devel, topic 4335f075: "implement the
> feature for all of the errors to occur via a cool sliding snackbar from the
> top , which is about the same size ... Also all of the errors should get
> saved into a personal per user event-log entry in the db , which sould be
> accessible from event log , button after the flow icon on the left most
> pane"

## 1. Model

Every error the WUI shows already lands in ONE place, the tab's error journal
(`src/composables/errorJournal.mjs`, `noteError`), which redacts at capture
(no request/response body, no header, no query string, no stack). Two
subscribers read it; neither opens a second error channel:

- the **snackbar** (`error-snackbar.mjs`) shows it, and
- the **shipper** (`event-log.mjs`) POSTs it to the signed-in human's log.

The log is **per human** (HUM-*), hub-wide like `human_keys` (rdb 0018): no
tenant, outside RLS. The only access path is the session's own HUM-*.

## 2. Routes

Mounted under the auth prefix, like keys-v1, so the credentialed CORS of
`/api/v1/auth/*` covers them (GET and POST only). Every answer is
`Cache-Control: no-store`. No session / no HUM-* = `401 unauthenticated`.

### 2.1 `GET /api/v1/auth/events?limit=&before=`

Newest first. `limit` 1..200 (default 50; above 200 is clamped), `before` =
return only ids below it. `400 bad_request` on a non-positive or non-numeric
value.

```json
{ "events": [ { "id": 42, "kind": "error", "error_id": "ERR-CLIENT-20260925-190000-9B2F",
    "at": "2026-09-25T19:00:00.123Z", "received_at": "2026-09-25T19:00:01.5Z",
    "source": "api", "method": "GET", "origin": "https://api.<<run-time>>.csitea.net",
    "path": "/v1/view/roster", "status": 502, "code": "", "message": "Bad gateway",
    "name": "FetchError", "route": "/lobby" } ],
  "next_before": 0 }
```

`next_before` > 0 = an older page exists; pass it as `before`.

### 2.2 `POST /api/v1/auth/events`

`Content-Type: application/json` (else `415`), body ≤ 64 KiB,
`{"events":[...]}` with 1..20 entries. Each entry carries only these fields,
all optional; **any other field is refused** (`400`, `DisallowUnknownFields`):

| field | rule (rdb 0045) |
|---|---|
| `error_id` | `''` or `^ERR(-CLIENT)?-\d{8}-\d{6}-[0-9A-F]{4}$` (the WUI's `ERROR_ID_RE`) |
| `at` | RFC 3339, the browser's clock |
| `status` | 0..999 |
| `source` ≤80, `method` ≤12, `origin` ≤120, `path` ≤200, `code` ≤120, `message` ≤800, `name` ≤80, `route` ≤200 | characters (runes), valid UTF-8 |

`201 {"added": n}`. The hub stamps `received_at` and keeps the newest **500**
rows per human, deleting older ones in the same transaction.
Per-human write window: 240 POSTs an hour (`Options.EventsWriteLimit`);
above it `429 rate_limited` with `Retry-After`.

### 2.3 `POST /api/v1/auth/events/clear`

Body `{}` (any field = `400`). Deletes every row of the caller.
`200 {"cleared": n}`. Counts against the same write window.

## 3. Client rules (WUI)

- **Signed in only.** While the session is `loading`/`unknown`, records wait;
  `out` drops them (an error with no signed-in human belongs to no log).
- **Batched**: one POST per burst, 1.5 s after the first record, ≤ 20 each.
- **No loop**: the shipper uses `fetch` directly, never `spool-client` (which
  journals transport failures) and never `noteError`. A failed POST retries
  on transport/5xx/429 (≤ 3, backoff or `Retry-After`) and is then dropped;
  401/403 drop the queue; other 4xx drop the batch.
- **Snackbar**: slides down from the top, newest first, ≤ 3 rows; an identical
  error within 5 s bumps a ×N count; 8 s on screen after its last occurrence,
  paused while hovered or focused; close button; `role="alert"`.
- **Event log page**: `/events`, from the left rail's icon directly after Flow.

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T19:45:00Z -->
