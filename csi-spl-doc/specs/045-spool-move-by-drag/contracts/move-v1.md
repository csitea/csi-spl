# move-v1 — move a topic to a channel, a message to a topic

Spec: `../spec.md`. Every route is a browser (member session) route of the active tenant
(specs/026); an agent's twin over its box socket is §8. No new request header: the CORS preflight allows `POST, GET` with the same
`Authorization, Content-Type, X-Locale` as 032 / 041, so sign-in cannot break on a new preflight.

## 1. Common checks, in order

1. a signed-in member (`editorID`), else `403 forbidden`;
2. billing allows writes (the move only), else `402`;
3. `notes.send` for the move, `topics.read` for the read;
4. `msg_id` is a UUID, else `400 bad_json`;
5. the row exists in retention and in this tenant, else `404 not_found`;
6. the read door (`messageDoor`): a row the caller may not read is `404`;
7. the row is movable (spec 3.1 / 3.2 refusals), else `409 <token>`;
8. the move: the caller is the row's author, the tenant owner or an `admin`, else `403 not_allowed`;
   a REPLY (§3, and a promote) an agent wrote passes for any caller who got past 1-7 (spec 3.4).
   Check 7's `not_in_channel` does not refuse a §3 move of an agent's DM message to the caller
   (spec 3.4): it goes to a channel topic, and its undo `{to_task: <the DM>}` brings it home.

## 2. `POST /v1/messages/{msg_id}/move` `{"to_channel": "<channel id>"}`

`msg_id` is a topic's card (spec 3.1). The target: a channel id (`#` and upper case normalized). One
transaction: walk the topic, set `channel` on every row, stamp them.

`200`:

```json
{"kind":"topic","msg_id":"…","task_id":"…","channel":"ops","from_channel":"devel",
 "moved":true,"moved_by":"HUM-1","moved_at":"…","msg_ids":["…"],
 "undo":{"to_channel":"devel"}}
```

`moved:false` when the move took the topic home (the stamp was cleared).
Refusals: `409 not_a_card` (not a topic's card), `409 not_in_channel` (a DM topic), `409 lobby`,
`409 issue_topic`, `409 same_place`, `404 unknown_channel` (missing, deleted, `issues`, or a
members-only channel the caller is not in), `400 bad_json` (neither or both targets).

## 3. `POST /v1/messages/{msg_id}/move` `{"to_task": "<task uuid>"}`

`msg_id` is a reply (spec 3.2); `to_task` a topic's task id. One transaction: re-home the row, re-channel
its thread, re-point its thread's `parent_task_id`, stamp them.

`200`:

```json
{"kind":"message","msg_id":"…","task_id":"<to_task>","from_task":"…","channel":"ops",
 "from_channel":"devel","moved":true,"moved_by":"HUM-1","moved_at":"…","received_at":"…",
 "msg_ids":["…"],"undo":{"to_task":"<from_task>"}}
```

Refusals: `409 is_card`, `409 not_in_channel`, `409 lobby`, `409 issue_topic`, `409 same_place`,
`409 not_a_card` (the target task has no card), `409 cycle`, `404 not_found` (the target topic does not
exist or the caller may not read it), `404 unknown_channel` (its channel is closed to the caller).

## 4. `GET /v1/view/messages/{msg_id}/move`

`200` `{msg_id, task_id, channel, is_card, can_move, moved_from_channel?, moved_from_task?}` —
`can_move` is check 8 for this caller plus check 7 for the row; the targets are judged when the move
is made (`POST`).

## 5. The view element of a moved row

Beside the envelope, next to `edited_at` / `kind_set_by`, and only while the row is not at home:

```json
{"env":{…},"cursor":"…","channel":"ops","task_id":"…","parent_task_id":"",
 "moved_at":"…","moved_by":"HUM-1","moved_from_channel":"devel","moved_from_task":"…"}
```

These win over `env.channel`, `env.msg.task_id` and `env.parent_task_id` in the browser.
`parent_task_id: ""` means none. `moved_from_task` is present on a message move only.

## 6. Frames (browser socket)

```json
{"type":"topic_moved","msg_id":"…","task_id":"…","channel":"ops","from_channel":"devel","moved":true,"moved_by":"HUM-1","moved_at":"…","msg_ids":["…"]}
{"type":"message_moved","msg_id":"…","task_id":"…","from_task":"…","channel":"ops","from_channel":"devel","moved":true,"moved_by":"HUM-1","moved_at":"…","msg_ids":["…"]}
```

Audience: every browser socket that would have received the row's own `message` frame at its old place
or at its new place (041's `fanoutTopic`, taken for both).

## 7. A person's channel order (SPL-1034, spec 3.8)

- `GET /v1/view/me` gains `"channel_order": ["ops", "devel"] | null` (null = never set).
- `PUT /v1/me/channel-order` body `{"channel_order": ["ops", "devel"]}`:
  - `200 {"channel_order": ["ops", "devel"]}` — normalized (`#` dropped, lower case), duplicates removed
    (first wins); `[]` clears it and answers `{"channel_order": null}`.
  - `400 bad_json` — not a list of strings, more than 200 ids, or an id that is not a channel id.
  - `403 forbidden` — no signed-in member session; `404 not_member` — no membership in this tenant.
  - CORS preflight allows `PUT` with `Authorization, Content-Type, X-Locale` (no new header).
- No live frame: the order is one person's view; their other tabs read it on the next `/v1/view/me`.

## 8. The box `move` frame (an agent; SPL-1988)

An agent moves over its box socket (`spool move`, one-shot `role=cli` session), through the SAME
store write, frames (§6), refusal tokens and move notice as §2 / §3. Request and reply pair on
`msg_id`, a request id the box picks; the reply carries the §2 / §3 body under `move`.

| request | moves | CLI |
|---|---|---|
| `{"type":"move","msg_id":"<req>","task_id":"<topic>","move_to":"<channel>","as":"<agent>","typed_by":"HUM-n"?}` | a topic to a channel (§2) | `spool move --task <uuid> --channel <ch> --as <id> [--acting-for HUM-n]` |
| `{"type":"move","msg_id":"<req>","move_msg":"<msg>","move_to_task":"<topic>","as":"<agent>","typed_by":"HUM-n"?}` | a message to a topic (§3) | `spool move --msg <uuid> --to-task <uuid> --as <id> [--acting-for HUM-n]` |

Checks, in order (spec 3.4 read for an agent):

1. `as` is an agent this box announced, else `403 from_not_announced`; `typed_by`, when set, is a
   member bound as an operator of this box (specs/036 FR-010), else `403 not_allowed`;
2. billing allows writes, else `402`;
3. the row exists in this tenant, else `404 not_found`; the read door: the box's tail rule (sent by it,
   addressed to it, delivered there), the acted-for human's channel door, or - for a message - the
   agent is a member of its channel; else `404 not_found`;
4. the row refusals of §2 / §3 (`lobby`, `not_in_channel`, `issue_topic`, `is_card`, `same_place`);
5. who may: a topic, the agent that started it; a message an AGENT wrote, any agent past 3 (owner, t1
   ffc3b83c); otherwise only an agent acting for (`typed_by`) the tenant owner or an `admin`; else
   `403 not_allowed`;
6. the target: a message's target topic opens with a card the mover reaches as in 3 (else `404
   not_found`; a topic with no card answers `not_found` here, `not_a_card` in the browser), in a
   channel (`not_in_channel`, `issue_topic`, `lobby`); the target channel is one the agent is a
   member of or the acted-for human reads, else `404 unknown_channel`.

`moved_by` is the acting agent; the human it acts for is logged as `acting_for`. A malformed frame
(neither or both targets, an id that is not a lowercase UUID) is `400 bad_frame`.

<!-- version: 0.3.0 · updated: 2026-10-15 · last-edit: 2026-10-15T11:07:42Z -->
