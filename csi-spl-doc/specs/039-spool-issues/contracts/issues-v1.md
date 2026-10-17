# issues-v1 — the hub's issue API (specs/039)

Browser routes use the view door (session, tenant from identity, 026); box
agents use their own socket (§6). Errors are `{error, detail}`.

## 1. Routes

| method | path | permission | answer |
|---|---|---|---|
| GET | `/v1/view/issues?<filters>` | topics.read | 200 `{prefix, statuses, counts, issues, labels, channel, default_discussion}` |
| GET | `/v1/view/issues/{ref}` | topics.read | 200 `{issue}`; 404 `not_found` |
| POST | `/v1/issues` | notes.send | 201 `{issue}` |
| PATCH | `/v1/issues/{ref}` | notes.send | 200 `{issue}`; 404 `not_found` |
| DELETE | `/v1/issues/{ref}` | notes.send + (creator, or `tenant.settings`) | 200 `{issue}` (the row as deleted); 404 `not_found`; 403 `forbidden`; 409 `issue_has_children` |
| POST | `/v1/issue-labels` | notes.send | 201 `{label}`; 409 `label_exists` |
| POST | `/v1/issues/{ref}/opened` | a member session | 200 `{key, unopened: false}`; 404 `not_found` (§2.1) |
| POST | `/v1/issues/{ref}/discussions` | notes.send | 200 `{issue}` with its discussions (§2.2); 400 `unknown_discussion` / `ambiguous_discussion`; 404 `not_found` |
| DELETE | `/v1/issues/{ref}/discussions/{task}` | notes.send | 200 `{issue}`; 409 `last_discussion`; 404 `not_found` (§2.2) |
| OPTIONS | the write paths | — | 204, `POST, PATCH, DELETE`, no new request header |

`{ref}` is `SPL-12`, `spl-12` or `12`. A write on an unpaid tenant is the
billing refusal every write gets.

DELETE (SPL-1027, rdb 0071) is a soft delete: the row gets `deleted_at` /
`deleted_by` and every read, patch and parent lookup treats it as absent
from then on. The discussion topic and the number stay.

## 2. The issue object

```json
{"key":"SPL-12","number":12,"title":"…","description":"markdown","status":"wip",
 "priority":2,"level":2,"assignee":"CLE-07","labels":["bug"],"deadline":"2026-10-01T12:30:00Z",
 "parent":"SPL-3","task_id":"<uuid>","channel":"issues","created_by":"HUM-10",
 "created_at":"…","updated_by":"CLE-07","updated_at":"…","completed_at":"","canceled_at":""}
```

- `status` (rdb 0055, owner topic f2c32da2; rdb 0061, SPL-966):
  `eval | todo | wip | diss | blocked | onhold | qas | done`, shown as
  `01-eval, 02-todo, 03-wip, 03-diss, 05-blocked, 06-onhold, 07-qas, 09-done`
  (evaluation, to do, work in progress, discard, blocked - waiting on
  something or someone, on hold - paused on purpose, quality assurance,
  done). Every tenant has the same set. A write may
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
  It is the issue's OWN comment thread, not the discussion it came from
  (§2.2).
- `discussions` (SPL-1593, rdb 0194): the topics the issue links to, at least
  one (§2.2).

A label: `{"id":"bug","name":"Bug","color":"#ff0000","created_by":"…","created_at":"…"}`.

### 2.0 The browser's list carries no description (P5-06, SPL-1739)

`GET /v1/view/issues` (the WUI sheet) answers every issue object with
`"description": ""`: the sheet paints none, and on prd the text was up to
0.9 MB detoasted per list read (`csi-spl-doc/doc/md/perf-round-5-plan.md`
row 6). The text comes with the single read `GET /v1/view/issues/{ref}`,
which the WUI makes before it opens an issue, so an opened issue never shows
a blank description. Everything else keeps the text: a live frame (§5), the
agent list (§6), search (`type:issue` matches words in the description) and
the hours export. Postgres reads the narrow projection
(`ListIssueSheet`); the memory store has the one list read.

### 2.1 `unopened`: a new issue, not opened yet (SPL-1559, rdb 0184)

Owner HUM-10 (t1 7edebc75, msg 7d76ce22): "A new issue should be marked as a
new issue, which has not been opened yet, so it will be distinguishable from
the rest of the issues."

- A member's list (`GET /v1/view/issues`) and single read
  (`GET /v1/view/issues/{ref}`) carry `"unopened": true|false` per issue for
  that member. A live frame (§5) is sent to the whole tenant and carries no
  `unopened`; a client keeps the row's mark and asks the single read when a
  frame makes the row the member's to do.
- `true` when the issue is still to do (not `done`, not `diss`), not a level-1
  row, assigned to the member, not created by the member, and the member has
  no `issue_opens` row for it.
- `POST /v1/issues/{ref}/opened` records the open (the first one is kept, a
  repeat is a no-op); it is per member, so it is read state, not an issue
  write: no `notes.send`, no `issue` frame, a demo seat may call it.
- rdb 0184 backfilled every live issue as opened by its assignee at the
  deploy: only issues assigned after it are new.
- The WUI marks an unopened row with the unread row's dot and bold title
  (`.unread-dot`, as in the Flow list), clears it when the issue opens, and
  the Issues tab counts exactly those rows.

### 2.2 `discussions`: every issue links to one or more (SPL-1593, rdb 0194)

Owner HUM-10, t1 topic fcf09921: "Issues must be linked to one or more
discussions." (msg 3e75e13e) "We must create a special part of the UI
somewhere in the bottom panel where one could click on that one or more
discussions." (msg 9a8e4764) "that link in the database should be enforced,
so it should be not null. For all of the existing issues, they could link to
this discussion." (msg 62f96f94) It replaces spec 135 Q4 A (the source as a
description line only).

```json
"discussions":[{"task_id":"<uuid>","state":"live","title":"Login breaks","channel":"devel",
                "linked_by":"HUM-10","linked_at":"…"}]
```

- A list read and a live frame carry `task_id`, `linked_by`, `linked_at`. A
  single read (`GET /v1/view/issues/{ref}`, the agent `get`) adds `state`:
  `live`, `archived` (it still opens: owner msg 28b479fd) or `gone` (no
  message left: the WUI opens its "no longer exists" page), and, only when
  the reader may read that topic, `title` (the opening line) and `channel`.
- The database keeps the rule: `issue_discussions` (one row per issue and
  topic); an issue with no row is refused at COMMIT, and so is removing an
  issue's last row. A topic has no table, so the link carries no foreign key
  to it.
- When a discussion is deleted physically (its last message gone: a delete,
  a topic or channel delete, the retention sweep), its links go; an issue
  left with none links its tenant's default discussion (owner msg 81a43a7f,
  "B"). A topic merged into another moves its links there.
- The default (`issue_discussion_default`, Go `store.IssueDiscussionDefault`):
  in t1 the owner's topic `fcf09921-8f21-4518-a117-f8ddb41bfff5`; in every
  other workspace its "Issue backlog" topic (owner msg e3c349e2, "A"), a #lobby
  card the hub posts (it is signed, so SQL cannot) under msg_id = task_id =
  the first 128 bits of sha256(`spool-issue-backlog:<tenant>`), at start, on
  every retention sweep and on a link to it. rdb 0194 linked every issue that
  existed to it.
- Add: `{"discussion":"<topic id | 8-hex short id | a link carrying /t/<id>>"}`.
  A short id must match exactly one topic of the tenant
  (`ambiguous_discussion` otherwise, never a guess); the actor must be able to
  read the topic (`unknown_discussion` otherwise). The default discussion is
  always accepted. A second add is a no-op. At most 20 per issue.
- Remove: the last one is refused, `last_discussion` 409.
- The WUI (SPL-1593): a "Discussions" section in the issue's bottom panel,
  above the comment box, lists them (each opens its topic; an archived one
  is marked and opens; a deleted one opens a "no longer exists" note in place, no route of its own), links one
  (a pasted topic link or id) and unlinks one (never the last). A new issue
  starts linked to `default_discussion`; a subtask links its parent's; "make
  an issue" from a message links that message's topic.

## 3. Create and patch body

Any subset of `title, description, status, priority, level, assignee, labels,
deadline, parent, epic, kind, discussions`; unknown fields are refused
(`bad_json`). Create needs `title` and at least one discussion (§2.2):
`discussions` is a list of topic ids, short ids or `/t/` links, each one
resolved as an add is, `discussion_required` 400 for none. A create with no
`discussions` field links the `/t/` links of its description that resolve (the
spec 135 card's `Source` line, which an older `spool` binary sends); none
of either is `discussion_required`. The list answer's `default_discussion`
is the workspace's default (§2.2): the WUI starts a new issue linked to it.
A PATCH ignores
`discussions` (§1 add / remove change them). `epic` (or `parent`) is optional since W16 (spec 047): an issue
without one stands alone at level 2 and may take subtasks. In a PATCH an absent (or null) field is left alone; `deadline ""`,
`parent ""`, `assignee ""`, `labels []` clear. `deadline` is RFC 3339 with a
zone and is stored UTC. Refusals: `bad_issue` (shape / range, the detail names
the field), `unknown_label`, `unknown_parent` (absent or a cycle),
`bad_assignee` (not a member, not a roster agent), and the epic rule (§8):
`bad_epic` 400, `epic_has_issues` 409 (`epic_required` is no longer sent since
W16).
A PATCH also takes `cascade: true`, the confirmation of an epic close (§9);
`epic_close_confirm` 409 refuses that close without it.

## 4. List filters

`status`, `priority`, `level`, `assignee`, `label` take comma lists (any-of);
`assignee` also takes `me` and `none`. `deadline_before` / `deadline_after`
(RFC 3339; an issue without a deadline never matches). `sort`: `priority`
(default), `level`, `deadline`, `updated`, `created`, `number` (spec FR-003).
`epic` takes epic keys (any-of: their issues), `kind` is `epic` or `issue`.
`counts` is per status over the filtered set, with every status present.
`epics` is the §8 summary over EVERY issue of the tenant.

## 5. Live frames on `/v1/wui/ws`

- `{"type":"issue","op":"create"|"update"|"delete","issue":{…}}` - on
  `delete` the client drops the row with that `key` (SPL-1027). The issue
  carries no `unopened` (§2.1).
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
| `link` / `unlink` | `issue_ref`, `body` (the discussion, §2.2) | `{issue}` with its discussions |

- `as` must be an agent THIS box announced, else `error`
  `from_not_announced` 403 (the send rule). The agent is `created_by` /
  `updated_by`.
- Writes follow the tenant billing rule; refusals are §3's tokens in an
  `error` frame carrying the request's `msg_id`.
- A comment is stored by the hub as a reply-level (033 level 2) note from the
  agent on the issue's `task_id` in `#tasks`, `to` `ALL-0`, `to_box`
  `box-wui`, unsigned like a browser post, and shown live in browsers. It is
  delivered to no box.
- Front ends: `spool issue <op> --as <AGENT> …` (prints the reply as JSON);
  `create --discussions <id>,…`, `link|unlink --ref SPL-3 --discussion <id>`.

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
- Refusals: `bad_epic` (a level-1 row with a
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

## 9. Closing an epic closes and archives its issues (SPL-1643)

Owner HUM-10, t1 1ccf3a20: msg 4913b500 "Epic close should also archive all
the issues"; msg d6300003 "if one closes an epic, it must be clear that he
knows what he's doing. Then all of the issues will be closed as well, with
some kind of automated post explaining why the issue has been closed"; msg
7c07c95d "if something doesn't work as expected, that should be filed as a
bug".

- **The rule** (`store.ClosesEpic`, one function for both drivers, so every
  path gets it: the WUI, bulk status, `PATCH`, an agent's `update`, `spool
  issue update`): a status change of a level-1 row (epic or feature) into
  `done` or `diss` gives every open descendant (all levels) the same status,
  stamped as a patch stamps it, then archives the row and every live
  descendant (rdb 0084, as `archive?cascade=1`), in the update's transaction.
- **The confirmation**: while the epic has open descendants, the update needs
  `cascade: true`; without it `409 epic_close_confirm`, the detail naming the
  count (`SPL-17 has 12 open issues: ...`). The WUI asks "Close SPL-17 and its
  12 open issues?" with a Close button and resends with it; the CLI flag is
  `spool issue update --cascade`. An epic with no open descendant closes and
  archives without it.
- **The answer** (`PATCH` and agent `update`) adds `archived` (true),
  `closed` (the keys it closed) and `descendants` (every key archived with
  it); the frame is `op: "archive"` with `descendants`, so tabs drop them.
- **The comment**: each issue it closed gets a hub note on its topic:
  `Closed because its epic SPL-17 was closed by <who> at <ISO UTC>.`
- **Unarchive** of a level-1 row always restores its archived descendants
  (with or without `cascade`), keeps every status, and notes on each:
  `Restored from the archive because its epic SPL-17 was restored by <who> at
  <ISO UTC>; its status stays <status>.`
- **A failure files a bug.** The cascade runs under a savepoint: when it fails
  the epic's own status change stands, nothing else moves, and the answer
  carries `archived: false` and `cascade_error`. A failed cascade or a comment
  that was not posted files one issue labelled `bug`, assigned to whoever
  closed the epic, naming the epic (linked), the issues left behind and the
  reason.
- Hub notes are English, like the blocker notes; the WUI strings are in every
  locale (`issues_epic_close.*`).
- **Live proof** on a deployed env: `ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a
  do_spl_issue_epic_close_probe` (csi-spl-orc) files a test epic with 2 open
  issues as the probe member, checks the 409, the cascade close (all 3 read
  404), the unarchive (all 3 back, done), then archives the tree again.

## 10. An epic closes by itself when its last issue closes (SPL-1729)

Owner HUM-10, t1 1ccf3a20, poll 954cd02f answered "B — Close it
automatically".

- **The trigger** (`store.ClosesChild`, both drivers' `UpdateIssue`): an
  update that moves a row under an epic into `done` or `diss`, or moves a
  closed row under another parent.
- **The rule** (`store.EpicAutoStatus`): the nearest open level-1 row above
  it closes when it has at least one live descendant (all levels) and none
  is open: `done` when any is done, `diss` when every one was dismissed. An
  epic with no issues never closes by itself; an epic already closed is left
  as it is.
- **Through section 9, never a second rule**: the epic's status change runs
  the same cascade, so the epic and every issue under it are archived, in the
  child's update transaction. Postgres locks the epic row before counting, so
  two last issues closing at once serialize and the second one closes it.
- **No loop**: section 9 closes an epic's issues inside the store, not
  through `UpdateIssue`, so it never triggers this; an auto-close answers the
  epic's own cascade only (test `TestEpicAutoClose`, store and hub).
- **The answer** (`PATCH` and agent `update`) of the closing issue adds
  `epic_closed: {key, status, archived, descendants}`; the tabs get the
  issue's `update` frame, then the epic's `archive` frame with
  `descendants`. The epic's topic gets a hub note:
  `Closed as <status> automatically: its last open issue SPL-n was closed by
  <who> at <ISO UTC>.` A failed cascade files the bug of section 9.
- Only the moment the last issue closes triggers it: an epic left with only
  closed issues by a delete or an archive stays open until it is closed by
  hand.
- **The one-time backfill** of the epics already in that state:
  `ENV=prd TENANT_ID=t1 DESK_AGENT=<id> DRY_RUN=1 ./run -a
  do_spl_issue_epic_autoclose_backfill` (csi-spl-orc) prints the plan;
  `DRY_RUN=0` comments on each epic, sets its status (the cascade archives
  it) and writes an undo file. `ISSUE_KEYS` narrows it; `ISSUE_EMPTY_KEYS`
  names open epics with no live issue to close as done too, which the hub
  never does by itself and only a decision names.
- **Every issue under an epic** (SPL-2354, spec 135): `ENV=prd TENANT_ID=<ws>
  DESK_AGENT=<id> ./run -a do_spl_issue_epic_backfill` (csi-spl-orc) plans
  the epic of each orphan level-2 issue (its spec's epic, else one new
  `Spec NNN - <heading>` epic, else an `Area: ...` epic) and links it with
  `DRY_RUN=0`, in batches of `ISSUE_BACKFILL_LIMIT`, open issues first. A
  link the hub answers with an archived `epic_closed` (SPL-1729: an open
  epic left with no open issue) restores that epic before the next link; it
  stays closed. `ISSUE_BACKFILL_CMD=verify` fails on an orphan left, a second
  epic for one spec, or a written link (`tried.tsv`) that did not land.

<!-- version: 0.9.0 · updated: 2026-10-14 · last-edit: 2026-10-14T00:00:00Z -->
