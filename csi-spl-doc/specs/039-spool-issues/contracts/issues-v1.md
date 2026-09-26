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

See `tasks.md` T006 for the state of this section.
