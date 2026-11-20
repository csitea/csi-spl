# Spec 185: Forward a Message Card

Status: **Draft v0.1** (2026-11-20). Lane `c-052` (`claude`, backup for
`specs_and_docs`: no agy cli on this box, agy at quota on the other).
Epic: **SPL-2403**. Issue: **SPL-6035**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:82dc7a90-c7a1-41f0-bc16-80674c3fab40` (`t1` #spool-hub-ui).
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the card menu, FR-020's
Export to PDF entry), and reuses [045 move by drag](../045-spool-move-by-drag/spec.md)
(the picker) and [067 DM channel linkage](../067-dm-channel-linkage/spec.md)
(the hub-written copy, `mirror_of`).

Line references were measured on `origin/master` `62daca7aa`. Next free
number at v0.1: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c 185`
-> 0; of every `origin/*` branch only `review/c-358-s-default-model-v01`
holds a folder above 183 (`184-default-model-per-agent-kind`).

## 0. The owner's words (HUM-10, t1 #spool-hub-ui)

Topic 82dc7a90, msg `078700fb`, verbatim: "add the "forward" action to each
msg reply including those which are not written to and from the user of the
system , which will enable the whole msg card re-sending a new msg card to
another discussion within the workspace- also to other channels"

Read as: every card (a topic's opening card and every reply, an agent's or
another person's included) gets a Forward entry; it posts a NEW card, with
the whole content of the original, into another topic or channel of the same
workspace (a workspace is a tenant: `csi-spl-doc/doc/md/guides/system-guide.md:293`).

## 1. The owner's open questions (one form)

Every part of sections 4 to 7 that depends on an answer is marked **[Qn]**.
The first option of each is the recommendation; the spec is written for it.

| Q | Question | Options |
|---|---|---|
| Q1 | What does the forwarded card show? | **HDR** (rec.): the original's body and files, under a header "Forwarded from <author>, <topic>" with a link back to the original (a reader who may not open the original sees the header; the link says it is not available to them) / **NTE**: as HDR, plus a short note the forwarder types above it / **PLN**: a plain copy, no header, no link |
| Q2 | The original's attachments and images | **LNK** (rec.): re-linked: the forward carries the same files (no bytes copied); when the original's author removes a file (the X), it also leaves the forwards of their card / **KEP**: re-linked, and a forward keeps the file even after the author removes it from the original / **TXT**: the text only, no files |
| Q3 | Where can a card be forwarded to? | **ANY** (rec.): an existing topic, as a reply, or a channel, as a new topic; any the forwarder may post in / **TOP**: existing topics only / **CHN**: channels only (always a new topic) |
| Q4 | Who may forward a card they neither wrote nor received? | **RDR** (rec.): any member who can read it and may post / **OWN**: the workspace owner and admins only / **PRT**: only its author and addressee (and the owner and admins) |
| Q5 | Direct messages and members-only channels, as source or target | **ALL** (rec.): both may be a source and a target; when the target's readers are not all readers of the source, the picker asks to confirm first / **NDS**: a DM card is never forwarded; a DM is never a target / **NDT**: a DM card may be forwarded, but a DM is never a target |
| Q6 | Agents that are members of the target channel | **AGT** (rec.): it reaches them like any post (the 2026-09-22 rule: a channel post reaches every agent member), but no @mention inside the forwarded text dispatches to anyone / **BRW**: people only; no agent receives a forwarded card |
| Q7 | The phone's long-press sheet | **YES** (rec.): Forward is on the sheet too, after Copy link / **NO**: desktop menu only, like Export to PDF |

Decided by this spec, not asked (say so in the topic if any is wrong):

- **A snapshot.** The forward copies the body and the file list at the
  moment it is sent. A later edit or delete of the original does not change
  it (as spec 169's copy, rdb 0250 header: "a copy is a snapshot").
- **The forwarder is the author** of the new card (`from`); its kind is
  `note` whatever the original's kind was: a forwarded blocker is not a new
  blocker.
- **Nothing is written into the source topic**: no "forwarded to" line.

## 2. Terms

| term | meaning |
|---|---|
| source | the card the Forward entry was chosen on |
| forward | the new card the hub stores in the target |
| target | an existing topic (the forward is a reply in it) or a channel / DM (the forward opens a new topic) |
| forwarder | the signed-in member who chose Forward |

## 3. What exists today (measured)

No forward exists: `git grep -n -i forward origin/master -- csi-spl-wui/src csi-spl-api/src/go/spool-hub-api/internal/hub csi-spl-api/src/go/spool-hub-api/internal/msg | grep -v _test`
lists only proxy headers, share links and a CSS keyword.

### 3.1 The card's menu

- The entries are built by `msgMenuItems` (`csi-spl-wui/src/utils/msg-menu.mjs:85-138`).
  Copy link is on every message (`:89`, `:105`); Export to PDF is the
  desktop-only `pdf` entry right after Copy link, Hide from flow and Add to
  note (`:109`; the why at `:73-77`: the phone sheet's rows are measured to fit).
- `MessageMenu.vue` passes the flags (`:131-153`), declares one emit per entry
  (`:80-104`, `'export-pdf'` at `:103`) and maps a chosen id to it (`:158-184`,
  `export-pdf` at `:179`).
- `MessageCard.vue` mounts the menu with `pdf` unconditionally (`:426`), so
  every card offers it, and wires each emit (`:430-452`). Move to channel /
  topic open `LazyMovePickerDialog` (`:445-447`, `:455-462`).
- The menu's unit test is `csi-spl-wui/tests/unit/msg-menu.test.mjs`; the
  phone sheet's e2e is `tests/e2e/phone-card-menu.test.mjs`; FR-020's e2e is
  `tests/e2e/msg-export-pdf.test.mjs`.

### 3.2 The picker that exists (spec 045)

`MovePickerDialog.vue` lists, with a filter, the channels the viewer may post
in (mode `channel`, `:90-96`, from `moveChannelTargets`,
`csi-spl-wui/src/utils/move-apply.mjs:16-25`: the hub lists only channels the
viewer may read, minus the current one, the lobby and `issues`) or the topics
of those channels, newest first (`:97-104`), reading one page per channel
(`:107-123`, SPL-4892). A pick closes the dialog and runs the move (`:129-141`).

### 3.3 How the WUI posts a card

- The store's `send(text, parentTaskId, files, channelId, isParent, dmPeer)`
  (`csi-spl-wui/src/stores/channel.ts:540`) calls `api.sendMessage`.
- `sendMessage` (`csi-spl-wui/src/utils/spool-client.mjs:935-976`) builds one
  wui-live-ws section 4 `send` frame: `{task_id, kind: 'note', body, files}`
  plus `msg_id`, `to` / `to_box` (a DM peer), `channel`, `parent_task_id`,
  `is_parent` (`:948-956`). A new `task_id` is a new topic; an existing one is
  a reply.

There is no HTTP route that creates a browser message: every browser post is
this WebSocket frame.

### 3.4 The hub's send path and its checks

`wuiSend` (`csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go:571-643`) runs,
in order:

1. `wuiIDs` (task, msg id, panel flag), `wuiRecipient` (`:887-918`): the `to`,
   and an agent named by an @mention in the BODY (`dispatchAgent(to, f.Body)`, `:890`).
2. `wuiMessage` (`:700-716`): the v:1 object, `From` = the member, `Files` =
   `wuiAttachments(f.Files)` (`:932-949`).
3. `wuiRoute` (`:741-800`): channel / parent tags, the archived-topic refusal
   (`wuiArchivedRefusal`, `topic_archived_input.go:48`), the moved-topic
   refusal, and `wuiMayPost` (`:858-873`): the member must READ the target
   channel (`canReadChannel`) and hold `notes.send` (`agents.command` for an
   agent dispatch); then the agent fan-out decision (`:797-798`).
4. `senderAllowed`, the demo checks, and `admit` (`:997-1020`): billing,
   quota, `missingFile` (the blob is held, `ws.go:945`) and `unreadableFile`
   (`ws.go:979`): the sender may attach only a file they may already read.
5. `wuiEnvelope` (`:962-992`), `commitRow` (the one store path), the ack
   (`:804-826`), then `wuiAfterStore` (`:647-654`): agent fallback and notes.
   The browser fan-out is `fanoutWUI` (`:1024`), which already adds
   hub-only fields to the `message` frame (`mirror_of`, `:1083-1085`).

### 3.5 Who may read a card (the read door)

`csi-spl-api/src/go/spool-hub-api/internal/hub/privacy.go`:

- A channel message is readable by the channel's humans; the default
  channels and issue discussions are public to the workspace; every created
  channel is members-only and a non-member reads 404 (`:13-33`, `canReadChannel`
  `:71-85`). These are the "members-only" places of this spec.
- A DM (no channel) is readable by its two ends only (`canReadMessage`, `:94-102`).
- `messageDoor` (`:107-124`) is the per-message door of every message route,
  plus the hidden-message rule (specs/077). The topic door adds the box owner
  lock (`topicDoor`, `:145-150`), which `messageDoor` does not ask.

### 3.6 Attachments

- `msg.Attachment` (`internal/msg/msg.go:86-94`): `mode` `blob`, `file_id` =
  the sha256 of the bytes. The object key is `blob.Key(tenant, fileID)`
  (`internal/blob/blob.go:29`): within one workspace the same bytes are the
  same object, so "copying" a file is the same object as re-linking it.
- A blob is as private as the messages that carry it (`fileReadableBy`,
  `rest.go:305-311`), and lives while any message in retention carries it
  (`file_retention.go:15-21`). A forward is one more carrier.
- `DELETE /v1/attachments/{file_id}` (`attachment_remove.go:19-41`) takes the
  file off every message the CALLER may change (the uploader = the author of
  the carrying message, SPL-5570) and deletes the blob when none carries it.
  A forward's author is the forwarder, so today the original's author's X
  would not reach it **[Q2]**.

### 3.7 What already copies or moves a message

| what | where | relevant here |
|---|---|---|
| Move a topic / a message, promote a reply (spec 045, 8f588edd) | `message_move.go:58-122` (`resolveMove`), `topic_promote.go:53-114`; WUI `composables/useMove.ts:98-104` | moves the row itself (hub columns `moved_*`, rdb 0069); a forward never moves |
| The channel copy of a DM answer (spec 067 3.4) | `dm_ref.go:164-205` (`dmMirrorRow`); rdb `0112_dm_ref_task.sql` `mirror_of` | **the closest precedent**: the hub builds a new row from a stored one (new msg_id, same body and files, an unsigned box-wui envelope) and marks it with a hub-only column the view row and the frame carry |
| Copy a channel to another workspace (spec 169) | `store/channel_copy_apply_postgres.go:17-29`; rdb `0250_messages_copied_from.sql` | `copied_from` means "copied from another workspace"; a forward stays in its workspace and gets its own columns (7.1.2) |

### 3.8 The v:1 object has no room for "forwarded from"

`msg.Message` (`msg.go:97-121`) is the signed object. Its comment at
`:107-113`: a reader that predates a new key refuses an object that carries
it (`Parse` disallows unknown keys). So, like `mirror_of`, the forwarded-from
facts are **hub columns**, shown to browsers in the view row and the frame,
never in a box envelope (7.1.2-7.1.4).

## 4. The flow end to end

1. **Menu.** On any card, desktop menu (and the phone sheet **[Q7]**), the
   entry Forward… after Copy link. It is offered on every card, like Copy
   link, whoever wrote it or was addressed **[Q4]**: a viewer who cannot post
   anywhere sees it disabled with the reason (the `locks` pattern,
   `msg-menu.mjs:49-53`).
2. **Picker.** A dialog like `MovePickerDialog`, one filtered list: first
   "New topic in #<channel>" rows, then topics (newest first, `#channel` as
   hint), then DMs **[Q3, Q5]**. The source's own topic is not offered as a
   target. The same channel IS offered (another topic of it).
3. **Confirm when the audience widens [Q5].** The WUI knows the source's
   place: a DM, or a created channel, forwarded to a place with readers who
   cannot read the source (another channel, or a public one), asks once:
   "People who cannot see the original will see this card." A forward from a
   public channel never asks.
4. **Send.** One wui-live-ws `send` frame with `forward_of = <source msg_id>`,
   the target's `task_id` (existing topic) or a fresh one plus `channel` / `to`
   (new topic), a client-minted `msg_id`, and no `body` / `files` (7.1.1).
5. **Hub: the source.** `wuiSend` reads the source row (`GetEditable`), and
   refuses `forward_not_found` (404, the same answer for missing, unreadable,
   hidden and box-locked) unless the forwarder passes `canReadMessage` and the
   topic door (`canReadTopic`, so the box owner lock counts) **[Q4]**.
6. **Hub: the new card.** Body and files are the source's, verbatim (or the
   files are dropped **[Q2 TXT]**); kind `note`; from = the forwarder; to =
   `ALL-0`, or the DM peer. The body's @mentions do NOT dispatch: the forward
   skips `dispatchAgent` on the body (3.4 step 1) **[Q6]**.
7. **Hub: the target checks**, all existing (3.4 steps 3-4): archived target,
   `wuiMayPost` (member of the target channel, `notes.send`), billing and
   quota, `unreadableFile` (passes: the forwarder reads the files through the
   source).
8. **Store.** `commitRow` with the `fwd_*` columns set (7.1.2), in the same
   insert.
9. **Fan-out.** The ack to the forwarder; `fanoutWUI` sends the `message`
   frame with `forwarded` (7.1.3) to every browser subscribed to the target;
   agent members of a target channel get the delivery like any post **[Q6]**,
   without the forwarded facts (3.8). A toast in the forwarder's WUI:
   "Forwarded to <target>".
10. **Render.** The card in the target shows the header from `forwarded`
    **[Q1]**: "Forwarded from <author name>, <topic title>" (FR-019: a name,
    never an id); the link opens the source; a reader the hub refuses gets
    "The original is not available to you".

## 5. Reused, and the gaps

Reused as is: the card menu and its `locks` (3.1), the picker's list,
filter, keyboard and per-channel topic read (3.2), the whole `wuiSend` chain
(3.4), the read door (3.5), blob re-linking (3.6), the `mirror_of` pattern
for a hub-only marker (3.7, 3.8), `fanoutWUI`.

| gap | what is missing | row |
|---|---|---|
| G1 | columns that say a row is a forward and where from | F1 |
| G2 | `forward_of` on the send frame; the hub filling body and files from the source, the source door, the mention skip | F2 |
| G3 | the `forwarded` object on the view row and the `message` frame; the store reading and writing `fwd_*` (postgres and memory) | F2 |
| G4 | the Forward entry, its emit and handler | F3 |
| G5 | the target picker with new-topic rows, DMs and the widening confirm | F3 |
| G6 | the forwarded header on a card, and the "not available" link | F4 |
| G7 | the attachment X following forwards **[Q2 LNK]** | F5 |
| G8 | translations of the new keys, agy's review | F6 |
| G9 | contract and user docs | F8 |

## 6. Build order (rows a later lane can take in parallel)

Every row codes against section 7.1, not against another row's branch: the
WUI rows run on the mock client, the hub rows on the store interface. Rows
F1-F4 and F8 can start together once the form is answered; F5 only for Q2
LNK; F6 after F3 and F4 have landed their en keys; F7 after F3 and F4.

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| F1 | rdb: the `fwd_*` columns | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_forwarded.sql` (0299 at v0.1; re-check the head) | none | applies twice on a throwaway postgres; `\d messages` lists the six columns, nullable | a migration test asserting `fwd_of` fails before the file exists |
| F2 | hub: forward send, store, view, frame | `internal/hub/wui.go` (`wuiIn.ForwardOf`, a `wuiForward` step before `wuiRecipient`), new `internal/hub/wui_forward.go` + `wui_forward_test.go`, `internal/store` (postgres + memory write and read of `fwd_*`), `internal/hub/view.go` (view row), `openapi.json` | 7.1 (F1's file for the postgres test) | Go tests on postgres: a forward of a readable card stores body + files + `fwd_*`, the frame and the view row carry `forwarded`; each refusal of 7.1.1; an @agent in the forwarded body dispatches to no one | the same forward by a member outside the source's channel must answer `forward_not_found`; the test fails if the door check is removed |
| F3 | WUI: menu entry, picker, send | `utils/msg-menu.mjs`, `MessageMenu.vue`, `MessageCard.vue`, new `ForwardPickerDialog.vue` (or a `forward` mode of `MovePickerDialog.vue`), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`forward_of`), `i18n/locales/*.json` (en + machine drafts) | 7.1.1, 7.1.5, 7.1.6 | `msg-menu.test.mjs`: Forward on every card, desktop (and phone **[Q7]**); a unit test of the picker rows; `pnpm run typecheck`; i18n gates | drop the entry from `msgMenuItems`: the menu test fails |
| F4 | WUI: the forwarded header | `MessageCard.vue` (or a small `ForwardedHeader.vue`), `types/spool.ts` (`forwarded`), the feed / topic mappers that keep `mirror_of` today, `i18n/locales/*.json` | 7.1.3 | a unit test renders a row with `forwarded` and shows author name, topic title, link; without it, nothing | the same row without `forwarded` must not render the header |
| F5 | hub: the X follows forwards **[Q2 LNK]** | `internal/hub/attachment_remove.go`, a store lookup by `fwd_of`, its test | F1, F2 | the source author's X removes the file from the source and from every forward of it, and the blob goes when nothing else carries it | a forward of a DIFFERENT card carrying the same file keeps it |
| F6 | i18n: agy's final review | the 18 non-en locale files, the keys of 7.1.5 | F3, F4 landed | agy review per the language rule; gates green | the untranslated-count gate (`i18n-untranslated.test.mjs`) |
| F7 | e2e | new `csi-spl-wui/tests/e2e/msg-forward.test.mjs` | F3, F4 | on the generated bundle, mock-served: forward a reply to another channel as a new topic, the card shows the header; forward into an existing topic | the e2e fails when the menu entry is absent |
| F8 | docs | `csi-spl-doc/specs/005-spool-wui/spec.md` (FR-021), `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (section 4: `forward_of`; the `message` frame: `forwarded`), the user help for the card menu | 7.1 | the contract names every field of 7.1.1 and 7.1.3 | the contract test or link check that covers the file fails on a removed field |

## 7. Contracts

### 7.1 Binding contracts for the parallel rows

#### 7.1.1 The send frame (wui-live-ws section 4)

```
{ "type": "send",
  "msg_id": "<uuid, client-minted>",
  "task_id": "<target topic's task_id, or a fresh uuid for a new topic>",
  "forward_of": "<the source's msg_id>",
  "channel": "<target channel>",          // new topic in a channel
  "to": "<peer id>", "to_box": "<box>",   // new topic in a DM [Q5]
  "is_parent": 1 }                        // 1 = new topic, 0 = a reply
```

- `body` and `files` are absent. With `forward_of` set, a non-empty `body`
  or `files` is refused `bad_json` 400. The note of **[Q1 NTE]** rides in
  `fwd_note` (at most 2000 characters).
- `forward_of` must be a UUID (`bad_json` 400 otherwise).
- A resend of the same `msg_id` re-acks (the existing duplicate rule, `wui.go:697-716`).
- Refusals added: `forward_not_found` 404 (source missing, unreadable,
  hidden or box-locked: one answer for all), `forward_not_allowed` 403
  (**[Q4 OWN/PRT]** only), `forward_dm` 403 (**[Q5 NDS/NDT]** only). Every
  existing refusal of `wuiSend` applies unchanged to the target.
- The ack is the existing ack (`wui.go:813-814`), unchanged.

#### 7.1.2 The columns (rdb `<next>_messages_forwarded.sql`)

All nullable, no default (catalog-only, as 0112 and 0250); NULL on every row
that is not a forward. RLS unchanged (messages already ENABLE + FORCE it).

| column | type | value |
|---|---|---|
| `fwd_of` | uuid | the source's msg_id. No FK: the source may expire or be deleted |
| `fwd_from` | text | the source's author id (`HUM-*` or an agent id); the WUI shows the name |
| `fwd_task` | uuid | the source's task_id (the link back) |
| `fwd_channel` | text | the source's channel; NULL for a DM |
| `fwd_title` | text | the source topic's title at forward time, at most 200 characters **[Q1 HDR/NTE]** |
| `fwd_ts` | timestamptz | the source's `ts` |

Plus `fwd_note text` only for **[Q1 NTE]**, and a partial index
`messages_fwd_of ON messages (tenant_id, fwd_of) WHERE fwd_of IS NOT NULL`
only for **[Q2 LNK]** (F5 looks forwards up by source).

#### 7.1.3 The `forwarded` object (view row and `message` frame)

```
"forwarded": { "of": "<msg_id>", "from": "<author id>", "task_id": "<uuid>",
               "channel": "<channel, omitted for a DM>",
               "title": "<topic title>", "ts": "<RFC 3339>",
               "note": "<only for [Q1 NTE]>" }
```

Omitted on a row that is not a forward. On the view row next to `mirror_of`
(`view.go:1134-1138`); on the frame next to `mirror_of` (`wui.go:1083-1085`).
Browser only: never in a box envelope, never in the v:1 object (3.8). With
**[Q1 PLN]** the columns are still written (the X of F5 needs `fwd_of`) and
the WUI shows no header.

#### 7.1.4 The stored message

v:1 unchanged: `from` = forwarder, `to` = `ALL-0` or the DM peer, `kind` =
`note`, `body` and `files` = the source's at forward time (`files` = `[]` for
**[Q2 TXT]**). The envelope is what `wuiEnvelope` builds for any browser post
(signed for the channel fan-out when **[Q6 AGT]** and the tenant pinned
box-wui, else unsigned; **[Q6 BRW]**: always the unsigned browser-only
envelope, no box delivery).

#### 7.1.5 The WUI menu entry and keys

- Menu item: `{ id: 'forward', icon: 'forward', labelKey: 'feed.msg_menu.forward' }`,
  emit `'forward'`; desktop: right after Copy link (before Hide from flow, Add
  to note, Export to PDF); phone **[Q7 YES]**: right after Copy link. No
  keyboard shortcut in v0.1.
- New i18n keys (en text): `feed.msg_menu.forward` "Forward…",
  `feed.forward.title` "Forward to", `feed.forward.new_topic` "New topic in
  #{channel}", `feed.forward.widen` "People who cannot see the original will
  see this card.", `feed.forward.done` "Forwarded to {target}",
  `feed.forward.header` "Forwarded from {author}, {topic}",
  `feed.forward.unavailable` "The original is not available to you",
  `feed.forward.none` "Nowhere you can post". Every key in all 19 locale
  files (`i18n-parity.test.mjs`).

#### 7.1.6 The picker

Rows, one list, filtered by one query: `{kind: 'channel', id: channel_id}`
("new topic"), `{kind: 'topic', id: task_id, hint: '#channel'}`, `{kind: 'dm',
id: '<peer>@<box>'}` **[Q5 ALL]**. Channels from `moveChannelTargets(channels, '')`
(the source's own channel included, the lobby and `issues` left out); topics
as `MovePickerDialog.load` reads them, minus the source's own topic. A pick
sends the frame of 7.1.1; on a refusal the dialog stays open and shows the
reason.

## 8. Not in this spec

- Forwarding to another workspace (spec 169 copies whole channels; a card
  across workspaces is a separate request).
- Forwarding a whole topic, or several cards at once.
- An agent forwarding over its box socket or the `spool` CLI.
- A "forwarded N times" count on the source.

## 9. Changes

v0.1: first draft.
