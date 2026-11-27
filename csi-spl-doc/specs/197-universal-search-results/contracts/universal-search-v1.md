# Contract: Universal Search API v1 (`GET /v1/view/search/universal`)

Feature: [Spec 197 — Universal Search Results Page (`/us`)](../spec.md).
Epic: **SPL-1292**. Issue: **SPL-6662**.
Normative order: [view-v1](../../003-spool-message-bus/contracts/view-v1.md) (door, tenant, CORS, retention), [error-envelope](../../003-spool-message-bus/contracts/error-envelope.md), [search-v1](../../003-spool-message-bus/contracts/search-v1.md) (query grammar, highlights, rate limit, time budget), then this file.

**Coexistence invariant (HC1 / HC2):** This contract sits **beside** `GET /v1/view/search` (`search-v1.md`), never inside it. `GET /v1/view/search` and `search-v1.md` remain byte-identical across every build row of Spec 197.

---

## 1. Endpoint and Registration

```text
GET     /v1/view/search/universal?q=<raw>&type=&sort=&limit=&cursor=
OPTIONS /v1/view/search/universal
```

- Registered in `csi-spl-api/src/go/spool-hub-api/internal/hub/search.go` (`routeSearch`) and documented in `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json` beside `/v1/view/search` (`:24322`) and `/v1/view/search/operators` (`:24434`).
- **Read-only**, same view door (`view-v1.md` §2), same Host tenant + Postgres FORCE RLS, same CORS allow-list (`OPTIONS` preflight, any other method -> `405 method_not_allowed`).
- **Rate limit:** Shares the per-`(tenant, reader)` **30 searches/min** bucket with `GET /v1/view/search` (`search-v1.md:445`; `429 rate_limited` with `Retry-After` and `Access-Control-Expose-Headers: Retry-After`). Cursor paging ("Load more") calls count against this shared 30/min bucket just as `/v1/view/search` "Load more" does today; Quick Preview cycling MUST NOT call this endpoint.
- **Time budget:** `7 s` Postgres `SET LOCAL statement_timeout` and `8 s` request context (`searchBudgetDefault + 1s`, `internal/hub/search.go:32,162`).

### 1.1 Query Parameters

| Param | Required | Meaning |
|---|---|---|
| `q` | Yes | Raw search query (`search-v1` grammar **v1.9**). Empty / whitespace-only, > `512` UTF-16 code units, > `32` terms, or nesting > `8` -> `400 bad_query` with UTF-16 `pos` and `token`. |
| `type` | No | Comma-separated kind filter from `/us` kind chips (e.g. `topic,issue`). If both `&type=` and a top-level `type:` term inside `q` are given, their intersection is searched; an empty intersection -> `400 bad_query`. |
| `sort` | No | `updated_desc` (default: last modified, newest first), `updated_asc` (oldest first), or `relevance` (cross-kind tiered ranking: exact key/title match > FTS `ts_rank_cd` / substring tier > `updated_at DESC`). Any other value -> `400 bad_query`. |
| `limit` | No | Page size. Default **30**, max **100** (clamped above max; `<= 0` -> default 30). |
| `cursor` | No | Opaque base64url JSON cursor from a previous `next` for the exact same `(q, sort, kinds)`. Malformed or mismatched -> `400 bad_cursor`. |

---

## 2. Grammar v1.9 Extensions (`internal/search`)

- Existing `search.DefaultTypes` (9 types) and `GET /v1/view/search` are **unchanged**.
- Four universal types added to `internal/search`:
  - `card_msg` (aliases: `card`, `cards`, `card_msgs`) — Level 1 message (`is_parent = 1`).
  - `topic_msg` (aliases: `reply`, `replies`, `topic_msgs`) — Level 2 message (`is_parent = 0`).
  - `lane` (aliases: `lanes`) — active live + queued lanes matching `/monitoring/lanes`.
  - `note` (aliases: `notes`) — reader's own personal notes (subject to owner poll Q6; omitted if Q6 = `W2`).
- `search.UniversalDefaultTypes` (15 default kinds): `topic`, `card_msg`, `topic_msg`, `issue`, `calendar`, `lane`, `event`, `file`, `doc`, `contact`, `note`, `channel`, `user`, `robot`, `box`.
- Opt-in kinds (searched only when explicitly named via `type:` or `in:`): `file_line` (`in:file-streams`), `tenant`.
- `search.ParseUniversal(raw, now)`: `type:message` expands to `{card_msg, topic_msg}` (if Q4 = `SEP`).
- `GET /v1/view/search/operators`: marks the 4 new kinds with `"universal_only": true` so `/us` autocomplete offers them while `/s` ignores them.

---

## 3. Response `200 OK`

```json
{
  "query": "deploy",
  "sort": "updated_desc",
  "kinds": ["topic", "card_msg", "topic_msg", "issue", "calendar", "lane", "event", "file", "doc", "contact", "note", "channel", "user", "robot", "box"],
  "warnings": [],
  "notices": [],
  "partial_errors": [],
  "has_more": true,
  "next": "<opaque base64url cursor or null>",
  "items": [
    {
      "kind": "topic",
      "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "updated_at": "2026-11-27T08:12:04Z",
      "title": { "text": "Deploy universal search", "highlights": [[0, 6]] },
      "snippet": { "text": "… we deploy the hub after …", "highlights": [[5, 11]] },
      "href": "/channel/lobby?topic=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "where": "#lobby",
      "actor": "HUM-10",
      "preview": {
        "task_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "msg_id": "22222222-2222-4222-8222-222222222222",
        "channel": "lobby",
        "from": "HUM-10",
        "msg_kind": "task",
        "reply_count": 4,
        "file_count": 1,
        "edited_at": "2026-11-27T08:12:04Z"
      },
      "multicast": {
        "eligible": true,
        "task_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "channel": "lobby",
        "title": "Deploy universal search"
      }
    }
  ]
}
```

### 3.1 Top-Level Fields

| Field | Type | Semantics |
|---|---|---|
| `query` | string | Raw `q` as received |
| `sort` | string | Effective sort (`updated_desc`, `updated_asc`, `relevance`) |
| `kinds` | string[] | Closed set of kinds queried for this request |
| `warnings` | array | Non-fatal query parse warnings (`token`, `pos`, `detail`), always `[]` when empty |
| `notices` | string[] | Stable i18n notice codes (e.g. `file_streams_staff_only`, `events_capped_500`, `relevance_pool_capped`), always `[]` when empty |
| `partial_errors` | array | `[{ "kind": "<kind>", "code": "timeout" \| "unavailable" }]` — populated **only** for real timeouts or store errors on sources the caller is authorised to query (including a `realmRefuses` store lookup error for `contact`/`note`, failing closed without aborting workspace hits with `503`). A source skipped due to role, ACL, act-as/box refusal, or feature kill-switch NEVER appears here. |
| `has_more` | bool | `true` iff more rows exist after `items` (within bounded-source caps noted in §4) |
| `next` | string \| null | Opaque cursor for the next page, or `null` when `has_more` is `false` |
| `items` | array | Flat ordered list of up to `limit` hits. No total count is computed (avoids a second scan). |

### 3.2 Item Fields

- `kind`: closed stable enum (`topic`, `card_msg`, `topic_msg`, `issue`, `calendar`, `lane`, `event`, `file`, `doc`, `contact`, `note`, `channel`, `user`, `robot`, `box`, `file_line`, `tenant`).
- `id`: unique stable identifier within `kind` (`task_id`, `msg_id`, issue `KEY`, calendar `event_id`, `agent_id@box` or `agent_id`, `event_id`, `file_id/msg_id/name`, `item_id`, `contact_id`, `note_id`, `channel_id`, `HUM-n`, `agent@box`, `box_id`, `stream_id:seq`, `tenant_id`).
- `updated_at`: RFC 3339 UTC timestamp string, or `null` for timeless entities (`user`, `robot`, `tenant`).
- `title`, `snippet`: `{ "text": string, "highlights": [[start, end], ...] }` with UTF-16 code-unit spans (`String.slice`). Plain text only — **never HTML**.
- `href`: canonical app-relative full link per Spec 197 Section 3.3 (`""` only for `tenant`, which switches workspace host).
- `where`: short location label (`#channel`, DM peer, issue epic key, calendar UTC date, box id, or `""`).
- `actor`: actor/author id (`HUM-n`, agent id, or `null` where the kind has no actor); WUI resolves display names from its shell roster with id fallback.
- `preview`: lightweight per-kind object enabling instant Quick Preview with **zero** extra round trips on keyboard cycling:
  - `topic` / `card_msg` / `topic_msg` / `file`: `task_id`, `msg_id`, `channel`, `from`, `to`, `msg_kind`, `reply_count`, `file_count`, `edited_at`, and for `file`: `file_name`, `bytes`, `file_id`. Optional rich body expand calls `POST /v1/view/previews` (outside the search rate limit).
  - `issue`: `key`, `status`, `priority`, `assignee`, `epic`, `labels`, `deadline`, `description_excerpt` (`<= 400` chars).
  - `calendar`: `starts_at`, `ends_at`, `all_day`, `location`, `kind`, `audience`, `description_excerpt` (`<= 400` chars).
  - `lane`: `agent_id`, `agent_box` (`""` in workspace-scoped view), `vendor`, `state` (`live` | `queued`), `scope`, `topic_id`, `topic_title`, `issues`, `wait`.
  - `event`: `event_id`, `error_id`, `code`, `status`, `method`, `path`, `source`, `message`.
  - `doc`: `doc_id`, `item_id`, `top`, `doc_title`, `heading`.
  - `contact`: `contact_id`, `email`, `phone`, `google`.
  - `note`: `note_id`, `pinned`, `priority`, `body_excerpt` (`<= 400` chars).
  - `channel` / `user` / `robot` / `box` / `file_line` / `tenant`: concise identity, presence, count, or stream metadata.
- `multicast`: `{ "eligible": bool, "task_id": string, "channel": string, "title": string }`. `eligible` is `true` **only** for `topic`, `card_msg`, `topic_msg`, and `file` belonging to a non-`issues` channel (matching Spec 186 Q2 `EX`, Q8 `CHN`, R1). `title` is always the carrying topic's true title (resolved via indexed lateral lookup on `messages_task_received`, `0022_messages_thread_walk.sql:19`) so the WUI constructs `TopicPick` directly without an extra lookup.

### 3.3 Cross-Page Topic vs. Card Message Deduplication (At the Source)

Deduplication is enforced **at the source**, not only in the page merge, so a thread with newer replies (`topic.updated_at > card_msg.updated_at`) never emits its opening card a second time on a later page:

- When `topic` is in `kinds`, the `card_msg` source excludes every root message (`is_parent = 1`) whose `task_id` also matches the query's `topic` predicate (Batch 1's shared `spool_search_candidates` probe decides both).
- When that `topic` row is emitted, it carries the matched root body `snippet` and `preview.msg_id` so the reader sees both title and body context on one row.
- When `type:card_msg` is explicitly requested without `topic`, `card_msg` rows are returned directly.
- **Layer H test:** a thread whose title and root body both match and which has a newer reply, fetched with `limit=1` on page 1 then page 2 -> the opening card appears exactly once across all pages.

---

## 4. Opaque Cross-Kind Cursor, Kind-Aware Boundary, and Bounded Caps

```go
type universalCursor struct {
    V  int            `json:"v"`            // 1
    H  string         `json:"h"`            // queryHash(q, sort, kinds)
    A  *time.Time     `json:"a,omitempty"`  // watermark updated_at
    K  search.Type    `json:"k,omitempty"`  // watermark kind
    I  string         `json:"i,omitempty"`  // watermark id
    NT bool           `json:"nt,omitempty"` // true once paging timeless (null updated_at) tail
    O  map[string]int `json:"o,omitempty"`  // per-kind offsets inside timeless tail
    RO int            `json:"ro,omitempty"` // offset for sort=relevance
}
```

- **Dated sorts (`updated_desc`, `updated_asc`):**
  1. Every dated SQL source receives the global watermark `(A, K, I)` and applies a **kind-aware boundary** so equal `updated_at` timestamps across different kinds are never skipped or duplicated:
     - For `updated_desc` (merge order `updated_at DESC NULLS LAST, kind ASC, id DESC`):
       - source `kind < K`: strictly `updated_at < $A` (timestamp `A` was already emitted before `K`);
       - source `kind == K`: `(updated_at, id) < ($A, $I)`;
       - source `kind > K`: `updated_at <= $A` (timestamp `A` has not yet been emitted for this kind).
     - For `updated_asc` (merge order `updated_at ASC NULLS LAST, kind ASC, id DESC`):
       - source `kind < K`: strictly `updated_at > $A`;
       - source `kind == K`: `(updated_at > $A OR (updated_at = $A AND id < $I))`;
       - source `kind > K`: `updated_at >= $A`.
     - Because `SearchMessagesUniversal` reads both `card_msg` and `topic_msg` in one SQL query, when `card_msg <= K <= topic_msg` it applies the inclusive `<= $A` (or `>= $A`) boundary, fetches up to `2*limit + 1` rows (ensuring source-level dedup never leaves a short page), and the Go merger filters strictly past `(A, K, I)`.
  2. Small entity/in-memory sources (`lane`, `event`, `channel`, `box`, `robot`, `user`, `tenant`) filter in Go, sort by the merge key, and slice strictly past `(A, K, I)`.
  3. The hub k-way merges all streams, applies `mod.keepResults` and `lockKeepResults`, and emits the first `limit` items. Across all unbounded SQL sources, this produces an exact cross-kind page (zero duplicates, zero skips).
  4. If more than `limit` merged items remain or any source returned more than `limit` rows, `has_more = true` and `next` encodes the `limit`-th item's watermark (or `NT: true` + `O` once inside the `null`-timestamp tail).
- **Explicit bounded-source caps (never silent):**
  - `event`: scans at most the newest **500** `human_events` rows (`search-v1.md:364`). If the 500-row cap is hit while `event` is queried, the answer includes notice `events_capped_500`.
  - `sort=relevance`: ranks over a bounded per-source candidate pool (`max(limit*3, 120)` rows per source), scored by `(tier DESC, score DESC, updated_at DESC, kind ASC, id DESC)` and paged by `RO`. When paging reaches the end of the capped pool while at least one source hit the pool ceiling, `has_more` becomes `false` and the answer includes notice `relevance_pool_capped` so the UI tells the reader to narrow the query rather than implying no more matches exist.

---

## 5. Errors

| Status | Token | When |
|---|---|---|
| `400` | `bad_query` | Empty/oversized/malformed `q`, unknown `sort`, disjoint `&type=` and `type:` |
| `400` | `bad_cursor` | Undecodable cursor or `H` mismatch against `(q, sort, kinds)` |
| `401` | `view_door` | View door refusal (`view-v1.md` §2) |
| `404` | `unknown_tenant` | Host maps to no tenant |
| `405` | `method_not_allowed` | Any method other than `GET` / `OPTIONS` |
| `429` | `rate_limited` | Over 30 searches/min per `(tenant, reader)` (shared with `/v1/view/search`; includes `Load more` cursor calls) |
| `503` | `search_budget` | Whole request exceeded 7 s statement timeout with zero partial sources succeeding |
