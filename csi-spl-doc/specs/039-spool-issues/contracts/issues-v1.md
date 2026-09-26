# issues-v1 — the hub's issue API (specs/039)

Browser routes use the view door (session, tenant from identity, 026); box
agents use their own socket (§6). Errors are `{error, detail}`.

## 1. Routes

| method | path | permission | answer |
|---|---|---|---|
| GET | `/v1/view/issues?<filters>` | topics.read | 200 `{prefix, statuses, counts, issues, labels, channel}` |
| GET | `/v1/view/issues/{ref}` | topics.read | 200 `{issue}`; 404 `not_found` |
| POST | `/v1/issues` | notes.send | 201 `{issue}` |
| PATCH | `/v1/issues/{ref}` | notes.send | 200 `{issue}`; 404 `not_found` |
| POST | `/v1/issue-labels` | notes.send | 201 `{label}`; 409 `label_exists` |
| OPTIONS | the three write paths | — | 204, `POST, PATCH`, no new request header |

`{ref}` is `SPL-12`, `spl-12` or `12`. A write on an unpaid tenant is the
billing refusal every write gets.

## 2. The issue object

```json
{"key":"SPL-12","number":12,"title":"…","description":"markdown","status":"in_progress",
 "priority":2,"level":3,"assignee":"CLE-07","labels":["bug"],"deadline":"2026-10-01T12:30:00Z",
 "parent":"SPL-3","task_id":"<uuid>","channel":"tasks","created_by":"HUM-10",
 "created_at":"…","updated_by":"CLE-07","updated_at":"…","completed_at":"","canceled_at":""}
```

- `status`: `backlog | todo | in_progress | in_review | done | canceled`
- `priority`: 0 none, 1 urgent, 2 high, 3 medium, 4 low
- `level`: 0 none, 1 XS, 2 S, 3 M, 4 L, 5 XL
- unset `deadline`, `parent`, `completed_at`, `canceled_at` read `""`
- `task_id` + `channel`: the discussion topic. Post a comment as an ordinary
  browser `send` with this `task_id`, `channel` `tasks`, `is_parent` 0.

A label: `{"id":"bug","name":"Bug","color":"#ff0000","created_by":"…","created_at":"…"}`.

## 3. Create and patch body

Any subset of `title, description, status, priority, level, assignee, labels,
deadline, parent`; unknown fields are refused (`bad_json`). Create needs
`title`. In a PATCH an absent (or null) field is left alone; `deadline ""`,
`parent ""`, `assignee ""`, `labels []` clear. `deadline` is RFC 3339 with a
zone and is stored UTC. Refusals: `bad_issue` (shape / range, the detail names
the field), `unknown_label`, `unknown_parent` (absent or a cycle),
`bad_assignee` (not a member, not a roster agent).

## 4. List filters

`status`, `priority`, `level`, `assignee`, `label` take comma lists (any-of);
`assignee` also takes `me` and `none`. `deadline_before` / `deadline_after`
(RFC 3339; an issue without a deadline never matches). `sort`: `priority`
(default), `level`, `deadline`, `updated`, `created`, `number` (spec FR-003).
`counts` is per status over the filtered set, with every status present.

## 5. Live frames on `/v1/wui/ws`

- `{"type":"issue","op":"create"|"update","issue":{…}}`
- `{"type":"issue_label","label":{…}}`

Sent to every browser socket of the tenant, the writer's own tabs included.

## 6. Agents (box socket)

On a box's own `/v1/ws` session (role `box` or `cli`, after the signed
hello), one request frame and one reply, paired on `msg_id` (a UUID the box
mints):

```json
{"type":"issue","msg_id":"<uuid>","issue_op":"create","as":"CLE-07","issue":{"title":"…","priority":2}}
{"type":"issue","msg_id":"<uuid>","issue_op":"create","issue":{"issue":{…}}}
```

| `issue_op` | request fields | reply `issue` |
|---|---|---|
| `list` | `query` (§4 in URL query form; `assignee=me` is `as`) | the §1 list object |
| `get` | `issue_ref` | `{issue}` |
| `create` | `issue` (§3 body) | `{issue}` |
| `update` | `issue_ref`, `issue` (§3 patch) | `{issue}` |
| `label` | `issue` = `{name, color?}` | `{label}` |
| `comment` | `issue_ref`, `body` (1..20000 characters) | `{issue, msg_id, task_id, channel}` |

- `as` must be an agent THIS box announced, else `error`
  `from_not_announced` 403 (the send rule). The agent is `created_by` /
  `updated_by`.
- Writes follow the tenant billing rule; refusals are §3's tokens in an
  `error` frame carrying the request's `msg_id`.
- A comment is stored by the hub as a reply-level (033 level 2) note from the
  agent on the issue's `task_id` in `#tasks`, `to` `ALL-0`, `to_box`
  `box-wui`, unsigned like a browser post, and shown live in browsers. It is
  delivered to no box.
- Front ends: `spool issue <op> --as <AGENT> …` (prints the reply as JSON).

## 7. Lists never show an issue's discussion

`GET /v1/view/topics` (every list: a channel's cards, the Topics tab, DMs)
leaves out the topic of every issue (`TopicQuery.NoIssues`): the talk about an
issue lives in its right pane. `GET /v1/view/topics/{task_id}` still reads it.

<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
