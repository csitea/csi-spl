# Contract: Universal Search API v1 (`GET /v1/view/search/universal`)

Feature: [Spec 197 — Universal Search Panel (`/us`)](../spec.md) (v1.2.2).
Epic: **SPL-1292**. Issue: **SPL-6662**.
Normative order: [view-v1](../../003-spool-message-bus/contracts/view-v1.md) (door, tenant, CORS, retention), [error-envelope](../../003-spool-message-bus/contracts/error-envelope.md), [search-v1](../../003-spool-message-bus/contracts/search-v1.md) (query grammar, highlights, rate limit, time budget), then this file.

**Coexistence invariant (HC1 / HC2):** This contract sits **beside** `GET /v1/view/search` (`search-v1.md`), never inside it. `GET /v1/view/search` and `search-v1.md` remain byte-identical across every build row of Spec 197.
**Build order (v1.2):** Wave 1 (**C1**) ships this endpoint with `calendar` first (real entries only, no `'Week N'` markers, `sort=upcoming` default for `type:calendar`); Wave 2 (**B2–B4**) registers the remaining 16 kinds on the same `universalSource` interface without breaking the wire shape.

---

## 1. Endpoint and Registration

```text
GET     /v1/view/search/universal?q=<raw>&type=&sort=&limit=&cursor=
OPTIONS /v1/view/search/universal
```

- Registered in `csi-spl-api/src/go/spool-hub-api/internal/hub/search.go` (`routeSearch`) and documented in `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json` beside `/v1/view/search` (`:24322`) and `/v1/view/search/operators` (`:24434`).
- **Read-only**, same view door (`view-v1.md` §2), same Host tenant + Postgres FORCE RLS, same CORS allow-list (`OPTIONS` preflight, any other method -> `405 method_not_allowed`).
- **Rate limit:** Shares the per-`(tenant, reader)` **30 searches/min** bucket with `GET /v1/view/search` (`search-v1.md:445`; `429 rate_limited` with `Retry-After` and `Access-Control-Expose-Headers: Retry-After`). Cursor paging ("Load more") calls count against this shared 30/min bucket just as `/v1/view/search` "Load more" does today; Quick Preview cycling (click / `ArrowUp`-`ArrowDown`) MUST NOT call this endpoint.
- **Time budget:** `7 s` Postgres `SET LOCAL statement_timeout` and `8 s` request context (`searchBudgetDefault + 1s`, `internal/hub/search.go:32,162`).

### 1.1 Query Parameters

| Param | Required | Meaning |
|---|---|---|
| `q` | Yes | Raw search query (`search-v1` grammar **v1.9** in Wave 2; existing `type:calendar`/`type:cal` in Wave 1). Empty / whitespace-only, > `512` UTF-16 code units, > `32` terms, or nesting > `8` -> `400 bad_query` with UTF-16 `pos` and `token`. |
| `type` | No | Optional comma-separated kind filter (e.g. `calendar`, `topic,issue`, for shared-link `&us_type=` / API callers; v1 UI filters via `type:` in the Omnibox per owner Q3 = `NO`). If both `&type=` and a top-level `type:` term inside `q` are given, their intersection is searched; an empty intersection -> `400 bad_query`. |
| `sort` | No | When omitted: **`upcoming`** if `kinds == ["calendar"]` (nearest upcoming first), else **`updated_desc`** (last modified, newest first). Allowed values: `upcoming` (valid only when `kinds == ["calendar"]`; `400 bad_query` if combined with non-calendar kinds), `updated_desc`, `updated_asc`, or `relevance` (cross-kind tiered ranking: exact key/title match > FTS `ts_rank_cd` / substring tier > `updated_at DESC`). Any other value -> `400 bad_query`. |
| `limit` | No | Page size. Default **30**, max **100** (clamped above max; `<= 0` -> default 30). |
| `cursor` | No | Opaque base64url JSON cursor from a previous `next` for the exact same `(q, sort, kinds)`. Malformed or mismatched -> `400 bad_cursor`. |

---

## 2. Grammar v1.9 Extensions (`internal/search`, Wave 2 Row B2)

- Existing `search.DefaultTypes` (9 types) and `GET /v1/view/search` are **unchanged**.
- Four universal types added to `internal/search`:
  - `card_msg` (aliases: `card`, `cards`, `card_msgs`) — Level 1 message (`is_parent = 1`).
  - `topic_msg` (aliases: `reply`, `replies`, `topic_msgs`) — Level 2 message (`is_parent = 0`).
  - `lane` (aliases: `lanes`) — active live + queued lanes matching `/monitoring/lanes`.
  - `note` (aliases: `notes`) — reader's own personal notes (confirmed by owner Q6 = `INC`).
- `search.UniversalDefaultTypes` (15 default kinds): `calendar`, `topic`, `card_msg`, `topic_msg`, `issue`, `lane`, `event`, `file`, `doc`, `contact`, `note`, `channel`, `user`, `robot`, `box`. (In Wave 1 `C1`, before Wave 2 registers the other 14 kinds, `calendar` is the active default source.)
- Opt-in kinds (searched only when explicitly named via `type:` or `in:`): `file_line` (`in:file-streams`), `tenant`.
- `search.ParseUniversal(raw, now)`: `type:message` expands to `{card_msg, topic_msg}` (confirmed by owner Q4 = `SEP`).
- `GET /v1/view/search/operators`: marks the 4 new kinds with `"universal_only": true` so `/us` autocomplete offers them while `/s` ignores them.

---

## 3. Response `200 OK`

```json
{
  "query": "type:calendar standup",
  "sort": "upcoming",
  "kinds": ["calendar"],
  "warnings": [],
  "notices": [],
  "partial_errors": [],
  "has_more": false,
  "next": null,
  "items": [
    {
      "kind": "calendar",
      "id": "00000000-0000-4000-8000-000000000102",
      "updated_at": "2026-11-27T08:12:04Z",
      "title": { "text": "Daily standup", "highlights": [[6, 13]] },
      "snippet": { "text": "Engineering daily standup in lobby", "highlights": [[18, 25]] },
      "href": "/calendar?d=2026-11-28&event=00000000-0000-4000-8000-000000000102",
      "where": "2026-11-28",
      "actor": "HUM-10",
      "preview": {
        "starts_at": "2026-11-28T09:00:00Z",
        "ends_at": "2026-11-28T09:30:00Z",
        "all_day": false,
        "location": "Room A",
        "kind": "meeting",
        "audience": "workspace",
        "description_excerpt": "Engineering daily standup in lobby"
      },
      "multicast": {
        "eligible": false,
        "task_id": "",
        "channel": "",
        "title": ""
      }
    }
  ]
}
```

### 3.1 Top-Level Fields

| Field | Type | Semantics |
|---|---|---|
| `query` | string | Raw `q` as received |
| `sort` | string | Effective sort (`upcoming`, `updated_desc`, `updated_asc`, `relevance`) |
| `kinds` | string[] | Closed set of kinds queried for this request |
| `warnings` | array | Non-fatal query parse warnings (`token`, `pos`, `detail`), always `[]` when empty |
| `notices` | string[] | Stable i18n notice codes (e.g. `file_streams_staff_only`, `events_capped_500`, `relevance_pool_capped`), always `[]` when empty |
| `partial_errors` | array | `[{ "kind": "<kind>", "code": "timeout" \| "unavailable" }]` — populated **only** for real timeouts or store errors on sources the caller is authorised to query (including a `realmRefuses` store lookup error for `contact`/`note`, failing closed without aborting workspace hits with `503`). A source skipped due to role, ACL, act-as/box refusal, or feature kill-switch NEVER appears here. |
| `has_more` | bool | `true` iff more rows exist after `items` (within bounded-source caps noted in §4) |
| `next` | string \| null | Opaque cursor for the next page, or `null` when `has_more` is `false` |
| `items` | array | Flat ordered list of up to `limit` hits. No total count is computed (avoids a second scan). |

### 3.2 Item Fields

- `kind`: closed stable enum (`calendar`, `topic`, `card_msg`, `topic_msg`, `issue`, `lane`, `event`, `file`, `doc`, `contact`, `note`, `channel`, `user`, `robot`, `box`, `file_line`, `tenant`).
- `id`: unique stable identifier within `kind` (`event_id`, `task_id`, `msg_id`, issue `KEY`, `agent_id@box` or `agent_id`, namespaced event id `mine:<event_id>` | `workspace:<id>` | `system:<id>` so the three independent event sequences never collide, `file_id/msg_id/name`, `item_id`, `contact_id`, `note_id`, `channel_id`, `HUM-n`, `agent@box`, `box_id`, `stream_id:seq`, `tenant_id`).
- `updated_at`: RFC 3339 UTC timestamp string, or `null` for timeless entities (`user`, `robot`, `tenant`).
- `title`, `snippet`: `{ "text": string, "highlights": [[start, end], ...] }` with UTF-16 code-unit spans (`String.slice`). Plain text only — **never HTML**.
- `href`: canonical app-relative full link per Spec 197 Section 3.3 (`""` only for `tenant`, which switches workspace host).
- `where`: short location label (calendar UTC date, `#channel`, DM peer, issue epic key, box id, or `""`).
- `actor`: actor/author id (`HUM-n`, agent id, or `null` where the kind has no actor); WUI resolves display names from its shell roster with id fallback.
- `preview`: lightweight per-kind object enabling instant right-pane Quick Preview with **zero** extra round trips on click / `ArrowUp`-`ArrowDown`:
  - `calendar` (**Wave 1 `C1`**): `starts_at`, `ends_at`, `all_day`, `location`, `kind`, `audience`, `description_excerpt` (`<= 400` chars). Real entries only: all-day rows matching anchored `all_day AND btrim(title) ~* '^week\s+\d+(\s+of\s+\d{4})?$'` (imported `'Week N'` / `'Week NN of YYYY'` markers, deliberate search-layer exception per HUM-5 `2c547a4e` `OWN`; spec 097 §5.2 `spec.md:808-810` keeps stored rows intact) and `official_days` are NEVER emitted.
  - `topic` / `card_msg` / `topic_msg` / `file`: `task_id`, `msg_id`, `channel`, `from`, `to`, `msg_kind`, `reply_count`, `file_count`, `edited_at`, and for `file`: `file_name`, `bytes`, `file_id`. Optional rich body expand calls `POST /v1/view/previews` (outside the search rate limit).
  - `issue`: `key`, `status`, `priority`, `assignee`, `epic`, `labels`, `deadline`, `description_excerpt` (`<= 400` chars).
  - `lane`: `agent_id`, `agent_box` (`""` in workspace-scoped view), `vendor`, `state` (`live` | `queued`), `scope`, `topic_id`, `topic_title`, `issues`, `wait`.
  - `event` (Q5 = `ALL`): `scope` (`"mine"` | `"workspace"` | `"system"`). For `mine`: `event_id`, `error_id`, `code`, `status`, `method`, `path`, `source`, `message` (`href`: `/monitoring/events#<event_id>`). For `workspace` / `system`: `id`, `kind`, `level`, `actor`, `origin_kind`, `origin_ref`, `message`, plus optional error-group fields `fingerprint`, `n`, `issue_key` on `system` groups (`log_events.go:72-79`; `href`: `/monitoring/events?log=workspace#<id>` or `/monitoring/events?log=system#<id>`, added by row W5e).
  - `doc`: `doc_id`, `item_id`, `top`, `doc_title`, `heading`.
  - `contact`: `contact_id`, `email`, `phone`, `google`.
  - `note`: `note_id`, `pinned`, `priority`, `body_excerpt` (`<= 400` chars).
  - `channel` / `user` / `robot` / `box` / `file_line` / `tenant`: concise identity, presence, count, or stream metadata.
- `multicast`: `{ "eligible": bool, "task_id": string, "channel": string, "title": string }`. `eligible` is `true` **only** for `topic`, `card_msg`, `topic_msg`, and `file` belonging to a non-`issues` channel (matching Spec 186 Q2 `EX`, Q8 `CHN`, R1). `title` is always the carrying topic's true title (resolved via indexed lateral lookup on `messages_task_received`, `0022_messages_thread_walk.sql:19`) so the WUI constructs `TopicPick` directly without an extra lookup.

### 3.3 Cross-Page Topic vs. Card Message Deduplication (At the Source, Wave 2)

Deduplication is enforced **at the source**, not only in the page merge, so a thread with newer replies (`topic.updated_at > card_msg.updated_at`) never emits its opening card a second time on a later page:

- When `topic` is in `kinds`, the `card_msg` source excludes every root message (`is_parent = 1`) whose `task_id` also matches the query's `topic` predicate (Batch 1's shared `spool_search_candidates` probe decides both).
- When that `topic` row is emitted, it carries the matched root body `snippet` and `preview.msg_id` so the reader sees both title and body context on one row.
- When `type:card_msg` is explicitly requested without `topic`, `card_msg` rows are returned directly.
- **Layer H test:** a thread whose title and root body both match and which has a newer reply, fetched with `limit=1` on page 1 then page 2 -> the opening card appears exactly once across all pages.

---

## 4. Opaque Cursor, Calendar `upcoming` Keyset, Kind-Aware Boundary, and Bounded Caps

```go
type universalCursor struct {
    V  int            `json:"v"`            // 1
    H  string         `json:"h"`            // queryHash(q, sort, kinds)
    A  *time.Time     `json:"a,omitempty"`  // watermark updated_at (updated_desc/asc)
    K  search.Type    `json:"k,omitempty"`  // watermark kind
    I  string         `json:"i,omitempty"`  // watermark id
    B  int            `json:"b,omitempty"`  // upcoming bucket: 0 = upcoming/ongoing (ends_at >= now), 1 = past
    S  *time.Time     `json:"s,omitempty"`  // watermark starts_at (sort=upcoming)
    NT bool           `json:"nt,omitempty"` // true once paging timeless (null updated_at) tail
    O  map[string]int `json:"o,omitempty"`  // per-kind offsets inside timeless tail
    RO int            `json:"ro,omitempty"` // offset for sort=relevance
}
```

- **Calendar nearest-upcoming sort (`sort=upcoming`, Wave 1 `C1`):**
  1. **Bucket `0` (`ends_at >= $now`):** ordered `starts_at ASC, event_id ASC`; keyset boundary `(starts_at, event_id) > ($S, $I)`.
  2. **Bucket `1` (`ends_at < $now`):** ordered `starts_at DESC, event_id DESC`; when crossing from Bucket `0` into Bucket `1` on the same page, remaining slots fill from Bucket `1` with no boundary; subsequent Bucket `1` pages apply `(starts_at, event_id) < ($S, $I)`.
  3. All-day rows matching `all_day AND btrim(title) ~* '^week\s+\d+(\s+of\s+\d{4})?$'` are excluded before `LIMIT`, so `'Week N'` markers never consume page slots or trigger false `has_more`.
- **Dated cross-kind sorts (`updated_desc`, `updated_asc`, Wave 2):**
  1. Every dated SQL source receives the global watermark `(A, K, I)` and applies a **kind-aware boundary** so equal `updated_at` timestamps across different kinds are never skipped or duplicated:
     - For `updated_desc` (merge order `updated_at DESC NULLS LAST, kind ASC, id DESC`):
       - source `kind < K`: strictly `updated_at < $A`;
       - source `kind == K`: `(updated_at, id) < ($A, $I)`;
       - source `kind > K`: `updated_at <= $A`.
     - For `updated_asc` (merge order `updated_at ASC NULLS LAST, kind ASC, id DESC`):
       - source `kind < K`: strictly `updated_at > $A`;
       - source `kind == K`: `(updated_at > $A OR (updated_at = $A AND id < $I))`;
       - source `kind > K`: `updated_at >= $A`.
     - Because `SearchMessagesUniversal` reads both `card_msg` and `topic_msg` in one SQL query, when `card_msg <= K <= topic_msg` it applies the inclusive `<= $A` (or `>= $A`) boundary, fetches up to `2*limit + 1` rows, and the Go merger filters strictly past `(A, K, I)`.
  2. Small entity/in-memory sources (`lane`, `event`, `channel`, `box`, `robot`, `user`, `tenant`) filter in Go, sort by the merge key, and slice strictly past `(A, K, I)`.
  3. The hub k-way merges all streams, applies `mod.keepResults` and `lockKeepResults`, and emits the first `limit` items.
  4. If more than `limit` merged items remain or any source returned more than `limit` rows, `has_more = true` and `next` encodes the `limit`-th item's watermark (or `NT: true` + `O` once inside the `null`-timestamp tail).
- **Explicit bounded-source caps (never silent):**
  - `event` (Q5 = `ALL`): scans at most the newest **500** rows per authorised event log (`human_events`, `search-v1.md:364`; `workspace_events` via `WorkspaceEventsPage` for workspace owner/admin; `system_events` via `SystemEventsPage` for operator workspace admin). Unauthorised scopes are skipped silently with zero `partial_errors`. If any queried event log hits its 500-row cap, the answer includes notice `events_capped_500`.
  - `sort=relevance`: ranks over a bounded per-source candidate pool (`max(limit*3, 120)` rows per source), scored by `(tier DESC, score DESC, updated_at DESC, kind ASC, id DESC)` and paged by `RO`. When paging reaches the end of the capped pool while at least one source hit the pool ceiling, `has_more` becomes `false` and the answer includes notice `relevance_pool_capped`.

---

## 5. Errors

| Status | Token | When |
|---|---|---|
| `400` | `bad_query` | Empty/oversized/malformed `q`, unknown `sort`, `sort=upcoming` with non-calendar kinds, disjoint `&type=` and `type:` |
| `400` | `bad_cursor` | Undecodable cursor or `H` mismatch against `(q, sort, kinds)` |
| `401` | `view_door` | View door refusal (`view-v1.md` §2) |
| `404` | `unknown_tenant` | Host maps to no tenant |
| `405` | `method_not_allowed` | Any method other than `GET` / `OPTIONS` |
| `429` | `rate_limited` | Over 30 searches/min per `(tenant, reader)` (shared with `/v1/view/search`; includes `Load more` cursor calls) |
| `503` | `search_budget` | Whole request exceeded 7 s statement timeout with zero partial sources succeeding |
