# Contract: the folded Flow read (spec 130, lane L1)

The read the WUI (L2a) renders and `spool flow` prints. It adds to
`../../062-flow-per-user-counts/contracts/flow-v1.md`; the plain `events`
page stays as it was until the WUI switches.

## 1. Request

`GET /v1/view/flow?fold=day[&kind=<k>][&limit=<n>][&before=<cursor>]`

| param | rule |
|---|---|
| `fold` | `day`: answer `lines` instead of `events` |
| `kind` | `mention` (takes `poke`, `blocked`, `ready` too), `reply`, `dm`, `blocked`, `ready`, `release` (release lines only; 400 without `fold=day`) |
| `limit` | topic lines per page, 1..50, default 30 |
| `before` | the `next` of the previous page |

## 2. Response

```json
{"counts": {...}, "unread": {...}, "keys": {...}, "lines": [<line>...], "next": "<cursor>|"}
```

`counts`, `unread`, `keys`: as flow-v1. A `blocked` or `ready` event counts
under `mention`.

### 2.1 A topic line: one topic on one UTC day

| field | value |
|---|---|
| `kind` | the strongest of the day: `blocked` > `ready` > `mention` > `poke` > `dm` > `reply` |
| `day` | `YYYY-MM-DD`, UTC |
| `count` | events folded |
| `at` | the newest event, RFC 3339 |
| `unread` | any folded event unread |
| `task_id`, `msg_id`, `channel` (null = DM), `parent_task_id` | the topic and its newest event |
| `title` | the topic's first message, one line, 90 chars |
| `text` | the newest event's body, one line, 90 chars |
| `ids`, `ids_more` | up to two author ids, newest first, then the count of the others (`c-002 +2`) |
| `issue` | the topic's issue number, absent = none. A `blocked` line opens it |
| `link` | `/t/<task_id>#<msg_id>` |
| `mark` | `t:<task_id>`: opening the line writes it at the newest event (`at`, `msg_id`), covering every event it folds |

### 2.2 A release line: the releases of one UTC day

| field | value |
|---|---|
| `kind` | `release` |
| `day`, `at` | the UTC day, the newest `released_at` |
| `version_from`, `version_to`, `versions` (= `count`) | the day's span: `v1.3.400 .. v1.3.420 (21 versions)` |
| `sha` | the newest version's commit; `link` is `/releases/<sha>` |
| `mark` | `f:rel:<version_to>` (a valid `PUT /v1/me/reads` key) |
| `unread` | newer than `f:seen` and no `f:rel:<version_to>` mark |

Every member of every tenant on the hub sees the same release lines (Q1).
There is no environment name: each hub lists its own releases.

## 3. The window and the cursor

The hub folds the member's newest 200 events past `before` and keeps the
first `limit` lines; it stops at the first event of the next line. `next` is
the raw cursor of the oldest event kept, so the next page folds the next
200; a topic-day cut by a page edge shows as two lines. Release lines are
those released below `before` (or now) and down to the oldest kept event
when there is a next page, else 30 days back. Lines come newest first.
