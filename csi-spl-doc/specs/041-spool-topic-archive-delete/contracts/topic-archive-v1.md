# topic-archive-v1 — archive, unarchive and delete a topic card

Spec: `../spec.md`. Every route is a browser (member session) route of the active tenant
(specs/026). No new request header: the CORS preflight allows `PUT, DELETE, GET` with the
same `Authorization, Content-Type, X-Locale` as 032, so sign-in cannot break on a new
preflight.

## 1. Common checks, in order

1. a signed-in member (`editorID`), else `403 forbidden` (permission `notes.send`);
2. billing allows writes (mutations only), else `402`;
3. `notes.send` for mutations, `topics.read` for reads;
4. `msg_id` is a UUID, else `400 bad_json`;
5. the message exists in retention and in this tenant, else `404 not_found`;
6. the read door (`messageDoor`): a card the caller may not read is `404`;
7. the row is a card (spec §2), else `409 not_a_card`;
8. its task is not an issue's topic, else `409 issue_topic`;
9. mutations: the caller is the author, the tenant owner or an `admin`, else
   `403 not_allowed`.

## 2. `PUT /v1/messages/{msg_id}/archive` · `DELETE /v1/messages/{msg_id}/archive`

No body. `200` with `{msg_id, task_id, archived: true|false, archived_at?, archived_by?}`.
Idempotent: archiving an archived card keeps its first `archived_at`.
Unarchive of a card that is not archived answers `200` with `archived: false`.

## 3. `GET /v1/view/messages/{msg_id}/topic`

`200` `{msg_id, task_id, replies, task_ids, can_delete, can_archive}` — `replies` is the
number of children a delete would remove now (spec §2), `task_ids` the tasks of the topic.
`can_delete` is false while the card is archived (SPL-4993).
Checks 1, 3 (`topics.read`), 4–7.

## 4. `DELETE /v1/messages/{msg_id}/topic`

No body. One transaction: walk the topic, delete every row. `200`
`{msg_id, task_id, deleted: <rows>, msg_ids: [...], task_ids: [...]}`.
Answers `404` if the card vanished between the checks and the delete.

## 5. `GET /v1/view/archived?limit=&before=`

The archived cards the caller may read (the rdb 0028 door), newest `archived_at` first.
`limit` 1..200, default 50; `before` is the `next` of the previous page.
`200` `{cards: [<view element §4.4 + task_id, is_parent, archived_at, archived_by, replies, can_delete>], next}`.
`can_delete` is always false here: a person unarchives before a delete (SPL-4993).

## 5.1 The archive stamp on a topic read

Lists leave an archived topic out, but `GET /v1/view/topics/{task_id}` answers
one read by its id (a link, a notification, this view). Its body then carries
the topic's stamp, `archived_at` and `archived_by` (omitted while the topic is
live), by the lists' own rule: an archived row of the task, the lobby's
excepted, or the archived lobby card whose thread it is. Only a first or
reverse-window read carries it; an `after=` poll and the lobby never do. The
WUI marks the topic with it (the Archived badge, t1 8fb802cd).

## 5.2 A person's input to an archived topic

Owner HUM-10, msg 51465f86 (SPL-4954). While the topic is archived (the stamp of
section 5.1, on anything named or on any task above it: a message climbs to its task, a
task to the parent task of its opening row, as far as the topic's own walk goes down, and the
lobby ends the climb):

| route | answer |
|---|---|
| browser socket `send` (post, reply, poll answer, attachment) | `error` frame, `error: topic_archived`, status 409, nothing stored or delivered |
| `PATCH /v1/messages/{msg_id}` | `409 topic_archived` |
| `PUT /v1/messages/{msg_id}/reactions` | `409 topic_archived`, except the report emoji |
| `POST /v1/messages/{msg_id}/move` `{to_task}` | `409 topic_archived` when `to_task` is archived |
| `POST /v1/messages/{msg_id}/merge-topic` `{to_task}` | `409 topic_archived` when `to_task` or the source topic is archived (SPL-4992) |
| `POST /v1/messages/{msg_id}/merge-topic` `{undo}` | `409 topic_archived` when a row's stored home task or parent is archived; the payload's `from_task` is not what decides (SPL-4991) |
| `POST /v1/messages/{msg_id}/merge` (fold), `PATCH /v1/messages/{msg_id}/kind`, `PUT /v1/topics/{task_id}/priority`, `DELETE /v1/messages/{msg_id}`, `DELETE /v1/messages/{msg_id}/topic` | `409 topic_archived` (owner msg f305bf70, SPL-4993) |
| `POST .../promote-topic` `{undo}` | `409 topic_archived` when the topic the row came from is archived; the row stays where it is |
| `POST /v1/embed/{embed_id}/messages` (a visitor; its topic is the visitor id) | `409 topic_archived`, nothing stored; the chat frame says the conversation is closed |

- A `send` whose `msg_id` is already stored still acks: a resend adds nothing.
- A DM naming an archived topic in `ref_task_id` is stored without the claim, so
  no mirror row lands in the topic.
- Open: removing one's own emoji; the box socket (an agent's post); the embed
  visitor's route, where a visitor has no way to unarchive. Removing one's own
  emoji and moving a row out are not input. Unarchive lifts every refusal, and is how a
  person reaches Delete.
- `DELETE /v1/messages/{msg_id}/archive` lifts all of it.

## 6. Frames (browser socket)

```json
{"type":"topic_archived","msg_id":"…","task_id":"…","channel":"general","archived":true,"archived_at":"…","archived_by":"HUM-1"}
{"type":"topic_deleted","msg_id":"…","task_id":"…","channel":"general","msg_ids":["…"],"task_ids":["…"]}
```

Audience: every browser socket that would have received the card's own `message`
frame (032's `fanoutDeleted` rule).

<!-- version: 0.2.0 · updated: 2026-10-03 -->
