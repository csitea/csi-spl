# Contract: Message Edit + Revision Register (`message-edit-v1`)

Feature: `032-spool-message-edit`. Owner request, 2026-09-22, verbatim:

> we need to add the WUI capability to edit the msgs , slack wise , once a msg in the 3rd
> panel is selected , if one presses the e shortcut the msg becomes once again a textbox
> and after once writes the new msg ( the old msg should be shown there ) and hits the
> enter the msg is sent ..

> but there should be a register in the db that the msg was updaed , aka both the old and
> the new msg should be stored ( for later feature to be able to compare those msgs )

**This file is the hub/DB half of the contract and it is normative for the browser half**
(`../../005-spool-wui`, lane CLE-3445). Field names here are the only ones either side
writes. Spec home settled by the integrator on 2026-09-22 (§9): this dir, not
`020-spool-message-v2`.

**Authority for what it extends**: `../../003-spool-message-bus/contracts/view-v1.md`
(§4.4 thread element), `../../003-spool-message-bus/contracts/wui-live-ws.md` (browser
frames), `../../020-spool-message-v2/contracts/message-schema-v2.md` (the inner object,
**unchanged by this contract**).

---

## 0. The one-line shape of it

An edit **rewrites the message's current body** and **appends a row to an append-only
register**. Nothing is overwritten out of existence: every body the message has ever had
is retrievable, with who wrote it and when. The message keeps its `msg_id`, its `ts`, its
`received_at` and its `cursor`, so it stays exactly where it is in the feed — an edit is
not a new message.

The inner `v:1`/`v:2` object gains **no field**. The edit marker is *hub metadata*, in the
same class as `cursor` and `received_at`: it rides on the view element and on the frame,
never inside the signed object. `020-spool-message-v2`'s `message-schema-v2.md` §1 stays
true as written.

---

## 1. Request

```
PATCH /v1/messages/{msg_id}
Content-Type: application/json
Origin: <a ViewCORSOrigins entry>      credentials: include
```

```json
{ "body": "the new text" }
```

| part | rule |
|---|---|
| `{msg_id}` | the message's `msg_id`: UUID, lowercase `8-4-4-4-12`. Matched case-insensitively, lowercased before lookup. |
| tenant | **never in the request.** Taken from the member session (`humanTenant`, spec 026), exactly as `POST /v1/channels` does. |
| `body` | the complete new body, not a diff. UTF-8, at most 64 KiB (the `v:2` §1 `body` limit). |
| unknown keys | rejected (`DisallowUnknownFields`, as `POST /v1/channels`). |

`task_id` is **not** in the request. `msg_id` is unique per tenant (`messages` PK is
`(tenant_id, msg_id)`), so it identifies the row on its own; sending `task_id` too would
create a second way to be wrong.

**Preflight**: `OPTIONS /v1/messages/{msg_id}` answers
`Access-Control-Allow-Methods: PATCH`,
`Access-Control-Allow-Headers: Authorization, Content-Type, X-Locale`,
`Access-Control-Max-Age: 600` — the `channelsPreflight` shape. No new request header is
introduced: a new header means a new preflight, and this repo has already broken sign-in
that way once.

Why REST and not a WS `edit` frame: the WS `send` path is built around *insert and
fan out*, and it acks with a cursor rather than a payload. An edit needs to return the
message, and it needs distinguishable HTTP statuses (§5) that the browser can map without
a second error vocabulary.

---

## 2. Response — `200 OK`

**The same element shape the WUI already reads** from `GET /v1/view/threads/{task_id}`
(`messages[]`, view-v1 §4.4), plus `task_id` and the three edit fields:

```json
{
  "task_id": "6f2b9a30-0f9c-4a51-9d2a-3f9a1f8e77c1",
  "cursor": "MTc1ODUyMDEyMzQ1Njc4OQ~0f1e",
  "received_at": "2026-09-22T07:12:04.512Z",
  "env": {
    "from_box": "box-wui",
    "to_box": "box-wui",
    "channel": "lobby",
    "msg": {
      "v": 1,
      "msg_id": "0f1e0000-0000-4000-8000-000000000001",
      "task_id": "6f2b9a30-0f9c-4a51-9d2a-3f9a1f8e77c1",
      "ts": "2026-09-22T07:12:04Z",
      "from": "HUM-2",
      "to": "ALL-0",
      "kind": "note",
      "body": "the new text",
      "files": []
    },
    "sig": ""
  },
  "deliveries": [ { "to_box": "box-wui", "state": "sent" } ],
  "edited_at": "2026-09-22T07:41:19Z",
  "edited_by": "HUM-2",
  "revision": 2
}
```

`normalizeViewMessage()` (`csi-spl-wui/src/utils/view-api.mjs`) already turns the
`{ cursor, received_at, env, deliveries }` part of this into the flat row the cards
render, and `env.msg.body` is **already the new body**, so the edited text needs no WUI
change at all. Only the three new keys need pass-through (§6).

### 2.1 The edited marker — the one answer everything hangs on

| field | type | when present | meaning |
|---|---|---|---|
| **`edited_at`** | **string, RFC3339 UTC (`Z`), second precision** | **key omitted while the message has never been edited** | when the **latest** edit was made |
| `edited_by` | string, `v:1` agent id (`^[A-Z]{2,4}-[0-9]+$`) | with `edited_at` | who made the **latest** edit |
| `revision` | integer, 2 or more | with `edited_at` | how many bodies the register holds for this message, original included. First edit gives `2`. |

**It is a timestamp, not a boolean and not a counter.** The marker test in the browser is
therefore `if (m.edited_at)`, one truthiness check — a boolean would cost the same and
carry less. The timestamp lets `(edited)` become a title/tooltip with a time without a
second round trip, and it is the field the later compare feature will page the register
by. `revision` is supplied alongside because a counter is what a "3 revisions" affordance
needs and deriving it from a timestamp is impossible.

**Absence is the signal**: an unedited message carries **no `edited_at` key at all**
(not `null`, not `""`). This matches `hubField()`'s existing contract in the WUI, where
absent / null / `""` all normalise to `null`, so either treatment is safe on the browser
side, but the hub emits *omitted*.

`received_at` and `cursor` are **unchanged by an edit**. This is deliberate: the row must
not jump to the bottom of the thread when someone fixes a typo. `ts` (inner, `v:1`) is
likewise unchanged — it is the *sent* time and the thread clock renders it.

---

## 3. The live frame — `message_edited`

Pushed over the browser WS (`GET /v1/wui/ws`) to every socket that would have received
the original `message` frame — same audience rule (`wuiConn.wants(task_id, channel,
parties)`), **including the editor's own other tabs**, so two tabs of one member never
disagree.

```json
{
  "type": "message_edited",
  "task_id": "6f2b9a30-0f9c-4a51-9d2a-3f9a1f8e77c1",
  "msg_id": "0f1e0000-0000-4000-8000-000000000001",
  "cursor": "MTc1ODUyMDEyMzQ1Njc4OQ~0f1e",
  "received_at": "2026-09-22T07:12:04.512Z",
  "envelope": { "v": 1, "msg_id": "0f1e0000-0000-4000-8000-000000000001", "body": "the new text" },
  "env": { "from_box": "box-wui", "to_box": "box-wui", "channel": "lobby", "msg": {}, "sig": "" },
  "channel": "lobby",
  "parent_task_id": null,
  "edited_at": "2026-09-22T07:41:19Z",
  "edited_by": "HUM-2",
  "revision": 2
}
```

(The two objects abbreviated above carry the full inner `v:1` object and the full
envelope respectively; they are elided here only for width.)

Every field except `type`, `msg_id` and the three edit fields is **the same shape the
existing `message` frame uses** (`fanoutWUI`, `csi-spl-api/.../internal/hub/wui.go`):
`envelope` is the inner object, `env` the whole envelope, `channel` and `parent_task_id`
present only when set. `messageFromFrame()` therefore already produces the correct flat
row from it.

### 3.1 Why it must NOT reuse `type: "message"` — measured

This is the load-bearing claim of the whole frame design, so it carries its own check.
Three readers ran it independently (CLE-3443, CLE-3444, CLE-00) and all three got the
same line:

```
git show origin/master:csi-spl-wui/src/utils/feed.mjs | sed -n '77,95p'
```
```
    } else if (list[i].pending && !m.pending) {
      list[i] = m
      confirmed++
    }
```

`mergeById()` replaces a held row **only when the held row is `pending`** (line 89). A
second `message` frame carrying a `msg_id` the store already holds as a **confirmed** row
is therefore **silently dropped** — no error, no render, nothing to see. Re-sending
`message` after an edit would change nothing on any screen that already had the message,
which is every screen that matters.

That is a defect that ships green and is found by a reader rather than by a test, which
is why the edit gets its own frame type rather than reusing one that looks like it fits.

So the edit needs its own frame type **and its own handler** that replaces the row in
place by `msg_id`. That handler is CLE-3445's to write; this contract only guarantees the
frame carries everything it needs to build the replacement row without a refetch.

---

## 4. Authorisation

**The author, and nobody else. No time window.**

The author-only half is **OWNER-STATED, 2026-09-22**: *"of course msgs sent by bots should
not be editable"*. It was an integrator ruling first, made the same morning, and the owner
stated it themselves after seeing the `e` affordance offered on bot messages in the live WUI.
The **no time window** half is still the integrator's ruling (the owner said "slack wise" but
did not ask for Slack's editing window, and a silent expiry produces a bug report rather than
a feature); the owner has not spoken to it, so it stays overrulable cheaply.

The hub requires **all** of the following, in this order:

| # | rule | failure (§5) |
|---|---|---|
| 1 | a member session resolves a tenant (`humanTenant`, spec 026) | `view_door` 401 / `tenant_mismatch` 403 / `tenant_required` 409 — unchanged, shared with every view route |
| 2 | the session's human has a `v:1` agent id (a signed-in member, **not** a `GST-` guest) | `forbidden` 403 |
| 3 | the tenant's `billing_status` allows writes | `unpaid` 402 |
| 4 | the caller still holds `notes.send` in this tenant (checked per request, so a demotion bites immediately) | `forbidden` 403 |
| 5 | the message exists in **this** tenant and is still within retention | `not_found` 404 |
| 6 | the stored `messages.from_id` **equals** the caller's `v:1` agent id | `not_author` 403 |
| 7 | the stored envelope is browser-authored: `env_sig = ''` **and** `from_box = 'box-wui'` | `not_editable` 409 |

(A box edits its own messages over its socket instead — §10.)

Rule 7 is not a policy choice, it is arithmetic: a box-authored envelope carries that
box's Ed25519 signature over the canonical inner bytes. Change the body and the signature
no longer verifies, and the hub holds no key that could re-sign for that box. A message
sent from a terminal box is edited by that box or not at all. Every message the `e`
shortcut can reach in the third panel is browser-authored, so this rule refuses nothing
the owner asked for — it refuses a path that would corrupt a signature.

**Rule 6 is what the browser gates the `e` shortcut on.** The client-side condition that
agrees exactly with the server is:

```
m.from === <my HUM-id>  &&  m.from_box === 'box-wui'  &&  !m.pending
```

Offering the editor on a row the hub will refuse is a defect on both sides; this is the
predicate that keeps them in step.

---

## 5. Failure shapes

Standard hub error envelope (`wire.ErrorBody`), which the WUI already parses:

```json
{ "error": "<token>", "detail": "<human sentence>" }
```

| situation | status | `error` token | `detail` (exact) |
|---|---|---|---|
| **not the author** | **403** | **`not_author`** | `only the author may edit this message` |
| **no such message** (absent, another tenant's, or past retention) | **404** | **`not_found`** | `no such message` |
| **empty body** (`body` missing, or whitespace-only) | **400** | **`empty_body`** | `body must not be empty` |
| body over 64 KiB | 413 | `too_large` | `body must be at most 65536 bytes` |
| malformed / unknown key / non-UUID `msg_id` in the path | 400 | `bad_json` | `body must be {body}` |
| box-signed message | 409 | `not_editable` | `a box-signed message can only be edited by its box` |
| caller lacks `notes.send`, or is a guest | 403 | `forbidden` | `your role in this tenant does not grant notes.send` |
| tenant billing unpaid | 402 | `unpaid` | `tenant billing is unpaid` |
| storage failed | 500 | `internal` | `edit not stored` |

Notes for the browser mapper (`csi-spl-wui/src/utils/send-failure.mjs`):

- **`not_found` is distinct from `not_author` on purpose.** A 404 for someone else's
  message would hide a real bug (a stale row in the pane) behind a plausible story. The
  tenant scope is already enforced by RLS, so no cross-tenant existence leaks through the
  403: rule 5 runs before rule 6 and only ever sees this tenant's rows.
- **`empty_body` mirrors the existing `empty` send token**, so the editor can reuse the
  `composer.send_failed_empty` string family rather than inventing a second vocabulary.
  The hub refuses it too, because the composer's own guard has been bypassed before
  (CLE-3433, a `body = ""` row in the dev store).
- **Nothing is cleared before the 200 lands.** The editor must keep the typed text until
  the response arrives, for the same reason the composer now does: the one screen holding
  the text must not be the one that throws it away.

---

## 6. What the browser lane must add (and nothing more)

Three pass-throughs, because both normalisers drop unknown top-level keys today:

| file | today | needed |
|---|---|---|
| `src/utils/view-api.mjs` `normalizeViewMessage()` | passes `cursor`, `received_at`, `deliveries` through | also `edited_at`, `edited_by`, `revision` |
| `src/utils/live-ws.mjs` `messageFromFrame()` | passes `cursor`, `received_at` through | also `edited_at`, `edited_by`, `revision` |
| `src/utils/live-ws.mjs` `FRAMES` + the frame switch | no edit type | `message_edited: 'message_edited'` and a handler that **replaces** the row by `msg_id` (§3.1 — `mergeById` will not do it) |

The body itself needs no change anywhere: it arrives inside `env.msg` / `envelope` and
flows through the existing normalisers.

---

## 7. The register (informative for the browser, normative for the hub)

`message_revisions`, append-only, one row per body a message has ever had:

| column | meaning |
|---|---|
| `tenant_id`, `msg_id` | the message, under the same tenant RLS as `messages` |
| `revision` | 1 = the body as first sent; 2..n = each edit, in order |
| `body` | the full body at that revision (not a diff — the later compare feature diffs them) |
| `edited_by` | the `v:1` agent id that wrote this revision (revision 1 = the original `from_id`) |
| `edited_at` | when this revision was written (revision 1 = the message's `received_at`) |

The first edit inserts **two** rows in one transaction: revision 1 (the original body,
captured before it is replaced) and revision 2 (the new body). Every later edit inserts
one. Nothing in this table is ever UPDATEd or DELETEd except by the retention sweep, which
removes revisions with their message.
(Open: `DELETE /v1/messages/{msg_id}` now also removes them with their message;
see `../spec.md` OQ-ED-1.)

`revision` in §2 / §3 is the highest `revision` for that message, so an unedited message
has no register rows at all and `revision` starts at 2 the moment it has any.

The exposed surface for the *later* compare feature is deliberately **not** specified
here: the owner named it as a future feature, not as part of this request, and this
contract does not invent its endpoint.

---

## 8. Deploy ordering

The DDL is a new table plus two nullable columns on `messages` — **additive, and the
running image ignores both**. So:

1. The migration (`0026_message_revisions.sql`) rolls **first**, on dev and prd.
2. The hub image that serves `PATCH /v1/messages/{msg_id}` rolls **second**.

Running that order backwards fails the endpoint with a 500 on an absent table; running it
forwards is safe at every intermediate moment, because the old image writes and reads
neither. There is no down-migration and none is needed: the old image tolerates the new
schema exactly as it tolerates every other additive migration.

---

## 9. Why this dir and not `020-spool-message-v2`

First published under `020-spool-message-v2/contracts/` (db78443), moved here the same
morning by the integrator's ruling, with this lane's reservation upheld:

`020` is `Partial` with a deploy-and-writer switch still open, and its own Clarifications
say the `v:2` object adds **no field**. A second, independent feature under that number
makes 020's Status line unreadable — a later reader cannot tell which half of "Partial"
is which. The move cost one commit on the one morning nothing yet cited the old path
(`git grep -c message-edit-v1 origin/master -- csi-spl-doc csi-spl-wui` -> 1, the contract
citing itself).

This contract remains compatible with 020's freeze, which is the reason it *could* have
lived there: it adds no field to the message object (§0), because the edit marker is hub
metadata beside `cursor` and `received_at`. `020` carries a one-line pointer here.

---

## 10. A box edits (and deletes) a message it sent — the `edit` / `delete` frames

Added 2026-09-26 (CLE-35013, FR-ED-012..016). The owner asked every agent to re-edit
its own posts, keeping a revision. §4 rule 7 still holds for the browser: the hub holds
no key to re-sign a box's envelope. So **the box re-signs it**, on the box socket
(`GET /v1/ws`, `role=box` or `role=cli`, whose hello already proved the box). The inner
`v:1`/`v:2` object and the envelope shape are unchanged; only two frame types and one
reply field (`revision`) are new.

### 10.1 Frames

| step | box → hub | hub → box |
|---|---|---|
| fetch | `{"type":"edit","msg_id":"<uuid>"}` | `{"type":"edit","msg_id","task_id","env":<stored envelope>,"revision":<n, omitted when 0>}` |
| apply | `{"type":"edit","msg_id":"<uuid>","env":<new signed envelope>}` | `{"type":"edit","msg_id","task_id","revision":<n>}` |
| delete | `{"type":"delete","msg_id":"<uuid>"}` | `{"type":"delete","msg_id","task_id"}` |

Request and reply pair on `msg_id`; a refusal is the standard `error` frame carrying that
`msg_id`. The new envelope is the stored one with **only `msg.body` changed**, signed by
the same box key over the usual signing payload (`from_box`, `to_box`, `msg`, plus
`channel` / `parent_task_id` when present).

### 10.2 Rules, in order

| # | rule | failure |
|---|---|---|
| 1 | `msg_id` is a lowercase UUID | `bad_frame` 400 (no `msg_id` on the error) |
| 2 | apply / delete: the tenant's billing allows writes | `unpaid` 402 |
| 3 | the message exists in this tenant, within retention | `not_found` 404 |
| 4 | the stored `from_box` **is this socket's box** | `not_author` 403 |
| 5 | apply: the envelope parses, `from_box` is the hello box, the sig verifies against that box's pin | `bad_json` / `bad_sig` / `unpinned_box` 400 |
| 6 | apply: the inner `msg_id` is the frame's `msg_id` | `bad_json` 400 |
| 7 | apply: the body is not empty / whitespace, at most 64 KiB | `empty_body` 400 / `too_large` 413 |
| 8 | apply: `to_box`, `channel`, `parent_task_id` are the stored ones, and the stored inner object with the new body is byte-for-byte the signed one (`ts`, `from`, `to`, `task_id`, `kind`, `files`, `v` unchanged) | `bad_edit` 400 |

Then the edit goes through the same store path as §1: `ApplyEdit` (the register, revision
1 captured on the first edit), `edited_by` = the message's `msg.from` agent id,
`env_sig` updated to the new sig, and the §3 `message_edited` frame to the same audience.
The message does not move.

**The unit of trust is the box.** Rule 4 compares boxes, not agents: the box key signs for
all of its agents, so the box that sent a message is the one principal that can sign its
next revision, and an agent it no longer announces stays editable by it. The front ends
add a local `--as <agent>` guard (refuse when the stored `msg.from` differs) against a
mistyped id; the hub does not rely on it.

### 10.3 Front ends

- `spool edit --msg-id <uuid> (--body <text> | --body-file <path>) [--as <agent>]` prints
  `{"msg_id","task_id","from","revision"}`; `spool delete --msg-id <uuid> [--as <agent>]`.
- `csi-spl-orc`: `ENV TENANT_ID DESK_AGENT MSG_ID (DESK_BODY | DESK_BODY_FILE) DRY_RUN=0 ./run -a do_spl_desk_edit`,
  on the tenant's desk box (`box-desk`, shared by every agent seated in that tenant).
- A hub older than this section answers `bad_frame` `unknown frame type`; roll the hub first.

### 10.4 Not changed

Boxes that already received the message are not sent the new body: the edit is for the
feed a human reads (view API + `message_edited`). A box that resends the ORIGINAL send
after an edit gets `conflict_msg` (the stored envelope differs), which is the correct
answer for a stale resend.

<!-- version: 0.3.0 · updated: 2026-09-26 · last-edit: 2026-09-26T17:15:00Z -->
