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
{"key":"SPL-12","number":12,"title":"…","description":"markdown","status":"wip",
 "priority":2,"level":2,"assignee":"CLE-07","labels":["bug"],"deadline":"2026-10-01T12:30:00Z",
 "parent":"SPL-3","task_id":"<uuid>","channel":"issues","created_by":"HUM-10",
 "created_at":"…","updated_by":"CLE-07","updated_at":"…","completed_at":"","canceled_at":""}
```

- `status` (rdb 0055, owner topic f2c32da2): `eval | todo | wip | diss | qas | done`,
  shown as `01-eval, 02-todo, 03-wip, 03-diss, 07-qas, 09-done` (evaluation,
  to do, work in progress, discard, quality assurance, done). A write may
  still send a first-set name; it maps backlog -> eval, in_progress -> wip,
  in_review -> qas, canceled -> diss. `done` stamps `completed_at`, `diss`
  `canceled_at`
- `priority` - "prio" in the WUI (rdb 0054 + 0055, owner topic d81cbf47): 1 (highest)
  .. 5 (lowest, the default for a new issue); "no priority" is gone (it became 5)
- `level`: the row's place in the tree (rdb 0056, SPL-949): 1 epic / feature,
  2 issue, 3 subtask. The hub derives it on every write; an input level is
  only checked (outside 1..3, or not the derived one: 400 `bad_issue`). A
  create may send 0 or omit it. `?sort=level` puts level 1 first
- `kind`: `epic` (carries the reserved label `epic`) or `issue`; `epic`: the
  parent epic's key on an issue, `""` on an epic (`parent` is the same key)
- unset `deadline`, `parent`, `completed_at`, `canceled_at` read `""`
- `task_id` + `channel`: the discussion topic. Post a comment as an ordinary
  browser `send` with this `task_id`, `channel` `issues`, `is_parent` 0.
  `issues` is a reserved channel id, not a channel (spec §Discussion space,
  SPL-68): never listed or creatable, readable by every member of the
  tenant. Send the `channel` the object carries; do not hard-code it.

A label: `{"id":"bug","name":"Bug","color":"#ff0000","created_by":"…","created_at":"…"}`.

## 3. Create and patch body

Any subset of `title, description, status, priority, level, assignee, labels,
deadline, parent, epic, kind`; unknown fields are refused (`bad_json`). Create
needs `title`, and `epic` (or `parent`) unless `kind` is `epic`. In a PATCH an absent (or null) field is left alone; `deadline ""`,
`parent ""`, `assignee ""`, `labels []` clear. `deadline` is RFC 3339 with a
zone and is stored UTC. Refusals: `bad_issue` (shape / range, the detail names
the field), `unknown_label`, `unknown_parent` (absent or a cycle),
`bad_assignee` (not a member, not a roster agent), and the epic rule (§8):
`epic_required` 400, `bad_epic` 400, `epic_has_issues` 409.

## 4. List filters

`status`, `priority`, `level`, `assignee`, `label` take comma lists (any-of);
`assignee` also takes `me` and `none`. `deadline_before` / `deadline_after`
(RFC 3339; an issue without a deadline never matches). `sort`: `priority`
(default), `level`, `deadline`, `updated`, `created`, `number` (spec FR-003).
`epic` takes epic keys (any-of: their issues), `kind` is `epic` or `issue`.
`counts` is per status over the filtered set, with every status present.
`epics` is the §8 summary over EVERY issue of the tenant.

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


## 8. Epics, features, issues, subtasks (SPL-18, rdb 0049 + 0053)

Owner, 2026-09-26: "the issues should have in the left most panel features /
epics", "each issue should have 1 parent epic", and 09:08 (topic 070843ba):
"epic and features are the first level / left most panel, issues (could be
bugs, tasks, etc.) and those could have subtasks in the third level".

- `kind` is a column (rdb 0053), not a label: `epic` or `feature` = level 1
  (no parent, the rows of the Issues tab's left-most panel); `issue` = level 2
  under a level-1 row, or level 3 - a **subtask** - under a level-2 issue.
  Three levels at most; a subtask has no children. The `feature` LABEL stays a
  free type label (bug, feature, ...).
- Issue JSON: `kind` is `epic | feature | issue | subtask`, `epic` the key of
  the level-1 row above it (`""` on a level-1 row), `parent` its direct parent.
- Create / patch: `kind: "epic" | "feature"` makes a level-1 row and drops the
  parent; `epic: <key>` must name a level-1 row; `parent: <key>` takes a
  level-1 row or a level-2 issue (making a subtask). The `epic` label on a
  create still makes an epic (the form rdb 0049 used).
- Refusals: `epic_required` (no parent), `bad_epic` (a level-1 row with a
  parent, a fourth level, a level-2 issue with subtasks moved under an issue,
  `epic` naming a non-level-1 row), `epic_has_issues` (a level-1 row with
  issues made kind issue).
- rdb 0049 moved every existing issue without an epic parent under the
  tenant's epic titled "random" (created where missing); rdb 0053 made the
  labelled epics kind epic.
- Filters: `kind` (comma list of epic, feature, issue, subtask), `epic`
  (rows under these level-1 rows, subtasks included), `parent` (direct
  children: an issue's subtasks).
- List summary `epics[]` (every level-1 row, open ones first):
  `{key, kind, number, title, status, total, done, canceled, counts}` over
  its level-2 issues; progress is Linear's `done / (total - canceled)`.

<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
