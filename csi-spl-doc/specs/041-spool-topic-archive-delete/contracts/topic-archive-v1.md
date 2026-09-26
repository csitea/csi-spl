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
Checks 1, 3 (`topics.read`), 4–7.

## 4. `DELETE /v1/messages/{msg_id}/topic`

No body. One transaction: walk the topic, delete every row. `200`
`{msg_id, task_id, deleted: <rows>, msg_ids: [...], task_ids: [...]}`.
Answers `404` if the card vanished between the checks and the delete.

## 5. `GET /v1/view/archived?limit=&before=`

The archived cards the caller may read (the rdb 0028 door), newest `archived_at` first.
`limit` 1..200, default 50; `before` is the `next` of the previous page.
`200` `{cards: [<view element §4.4 + task_id, is_parent, archived_at, archived_by, replies, can_delete>], next}`.

## 6. Frames (browser socket)

```json
{"type":"topic_archived","msg_id":"…","task_id":"…","channel":"general","archived":true,"archived_at":"…","archived_by":"HUM-1"}
{"type":"topic_deleted","msg_id":"…","task_id":"…","channel":"general","msg_ids":["…"],"task_ids":["…"]}
```

Audience: every browser socket that would have received the card's own `message`
frame (032's `fanoutDeleted` rule).

<!-- version: 0.1.0 · updated: 2026-09-26 -->
