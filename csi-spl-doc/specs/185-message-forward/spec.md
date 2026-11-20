# Spec 185: Forward a Message Card

Status: **Draft v0.3** (2026-11-20). Lane `c-052` (`claude`, backup for
`specs_and_docs`: no agy cli on this box, agy at quota on the other).
v0.1 `16f538b4c`; v0.2 `67870b9d1` folds the owner's answers to form
`1d2011df` (msg `61389b91`, relayed by the dispatch holder, msg `0eff0fee`).
What the answers removed: section 9. v0.3 folds the spec review's W1-W3 and
N1 (a-071, agy PASS on v0.2, msg `b71a97ff`; holder msg `17cfbb3e`):
section 9.1.
Epic: **SPL-2403**. Issue: **SPL-6035**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:82dc7a90-c7a1-41f0-bc16-80674c3fab40` (`t1` #spool-hub-ui).
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the card menu, FR-020's
Export to PDF entry), and reuses [045 move by drag](../045-spool-move-by-drag/spec.md)
(the picker) and [067 DM channel linkage](../067-dm-channel-linkage/spec.md)
(a hub-only marker column, `mirror_of`).

Line references were measured on `origin/master` `62daca7aa`. Next free
number at v0.1: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c 185`
-> 0; of every `origin/*` branch only `review/c-358-s-default-model-v01`
held a folder above 183 (`184-default-model-per-agent-kind`).

## 0. The owner's words (HUM-10, t1 #spool-hub-ui)

Topic 82dc7a90, msg `078700fb`, verbatim: "add the "forward" action to each
msg reply including those which are not written to and from the user of the
system , which will enable the whole msg card re-sending a new msg card to
another discussion within the workspace- also to other channels"

Read as: every card (a topic's opening card and every reply, an agent's or
another person's included) gets a Forward entry; it posts a NEW card, with
the whole content of the original, into another topic of the same
workspace, in any channel (a workspace is a tenant:
`csi-spl-doc/doc/md/guides/system-guide.md:293`).

## 1. Decided

The owner's answers to form `1d2011df` (msg `61389b91`), verbatim, and what
each decides here:

| Q | Answer (verbatim) | What it decides here |
|---|---|---|
| Q1 | "PLN — A plain copy, no header, no link" | 4 step 8: the forward looks like any card of its author; no "Forwarded from" header, no link back. The one hub column left is `fwd_of`, for Q2 (7.1.2) |
| Q2 | "LNK — Shared with the original: when the author removes a file, it leaves the forwards too" | 3.6, row F4: the attachment X follows `fwd_of` |
| Q3 | "TOP — Existing topics only" | 4 step 2, 7.1.1: the forward is always a reply in an existing topic; never a new topic |
| Q4 | "RDR — Any member who can read it and may post" | 4 steps 1 and 5: the source door is the read door; posting is the target's normal rule |
| Q5 | "ALL — Both allowed; the picker asks you to confirm when people who cannot see the original would see the forward" | 4 steps 2 and 3: DM topics and members-only channels' topics are sources and targets; the widening confirm |
| Q6 | "AGT — It reaches them like any post, but an @mention in the forwarded text does not dispatch work" | 4 steps 6 and 9: the body's mentions are not read; the reply routes as any reply in that topic |
| Q7 | "NO — Desktop menu only, like Export to PDF" | 7.1.4: the phone's long-press sheet does not list Forward |

Decided by this spec, not asked (say so in the topic if any is wrong):

- **A snapshot.** The forward copies the body and the file list at the
  moment it is sent. A later edit or delete of the original does not change
  the body (as spec 169's copy, rdb 0250 header: "a copy is a snapshot").
  Files are the one exception, by Q2: the author's X removes them.
- **The forwarder is the author** of the new card (`from`); its kind is
  `note` whatever the original's kind was: a forwarded blocker is not a new
  blocker.
- **Nothing is written into the source topic**: no "forwarded to" line.

## 2. Terms

| term | meaning |
|---|---|
| source | the card the Forward entry was chosen on |
| forward | the new card the hub stores in the target |
| target | an existing topic, in a channel or a DM; the forward is a reply in it (Q3) |
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

`MovePickerDialog.vue` mode `topic` lists, with a filter, the topics of the
channels the viewer may post in, newest first (`:97-104`), reading one page
per channel (`:107-123`, SPL-4892) of the channels `moveChannelTargets`
returns (`csi-spl-wui/src/utils/move-apply.mjs:16-25`: the hub lists only
channels the viewer may read, minus the lobby and `issues`). A pick closes
the dialog and runs the move (`:129-141`). It lists no DM topics; the
client's `listTopics` takes a `dm` filter
(`csi-spl-wui/src/utils/spool-client.mjs:603`).

### 3.3 How the WUI posts a card

- The store's `send(text, parentTaskId, files, channelId, isParent, dmPeer)`
  (`csi-spl-wui/src/stores/channel.ts:540`) calls `api.sendMessage`.
- `sendMessage` (`csi-spl-wui/src/utils/spool-client.mjs:935-976`) builds one
  wui-live-ws section 4 `send` frame: `{task_id, kind: 'note', body, files}`
  plus `msg_id`, `to` / `to_box` (a DM peer), `channel`, `parent_task_id`,
  `is_parent` (`:948-956`). An existing `task_id` makes the post a reply.

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
   agent dispatch). A channel-less reply goes to the topic's agent
   (`topicReplyAgent`, `:782-787`) or, in a DM, to its other person
   (`topicReplyPerson`, `:789-796`); a channel reply gets the agent fan-out
   decision (`:797-798`).
4. `senderAllowed`, the demo checks, and `admit` (`:997-1020`): billing,
   quota, `missingFile` (the blob is held, `ws.go:945`) and `unreadableFile`
   (`ws.go:979`): the sender may attach only a file they may already read.
5. `wuiEnvelope` (`:962-992`), `commitRow` (the one store path), the ack
   (`:804-826`), then `wuiAfterStore` (`:647-654`): agent fallback and notes.
   The browser fan-out is `fanoutWUI` (`:1024`).

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
  same object, so the forward shares the original's files (Q2) without
  copying a byte.
- A blob is as private as the messages that carry it (`fileReadableBy`,
  `rest.go:305-311`), and lives while any message in retention carries it
  (`file_retention.go:15-21`). A forward is one more carrier.
- `DELETE /v1/attachments/{file_id}` (`attachment_remove.go:19-41`) takes the
  file off every message the CALLER may change (the uploader = the author of
  the carrying message, SPL-5570) and deletes the blob when none carries it.
  A forward's author is the forwarder, so today the original's author's X
  would not reach it: row F4 adds that (Q2).

### 3.7 What already copies or moves a message

| what | where | relevant here |
|---|---|---|
| Move a topic / a message, promote a reply (spec 045, 8f588edd) | `message_move.go:58-122` (`resolveMove`), `topic_promote.go:53-114`; WUI `composables/useMove.ts:98-104` | moves the row itself (hub columns `moved_*`, rdb 0069); a forward never moves |
| The channel copy of a DM answer (spec 067 3.4) | `dm_ref.go:164-205` (`dmMirrorRow`); rdb `0112_dm_ref_task.sql` `mirror_of` | a new row built from a stored one, marked by a hub-only nullable uuid column: the pattern of `fwd_of` |
| Copy a channel to another workspace (spec 169) | `store/channel_copy_apply_postgres.go:17-29`; rdb `0250_messages_copied_from.sql` | `copied_from` means "copied from another workspace"; a forward stays in its workspace and gets its own column (7.1.2) |

### 3.8 The v:1 object has no room for a forward marker

`msg.Message` (`msg.go:97-121`) is the signed object. Its comment at
`:107-113`: a reader that predates a new key refuses an object that carries
it (`Parse` disallows unknown keys). So the one marker a forward needs,
`fwd_of`, is a **hub column**, never in a box envelope (7.1.2, 7.1.3).

## 4. The flow end to end

1. **Menu.** On any card of the desktop menu, the entry Forward… after Copy
   link, offered on every card like Copy link, whoever wrote it or was
   addressed (Q4). The phone sheet does not list it (Q7). A viewer with no
   topic to post in sees it disabled with the reason (the `locks` pattern,
   `msg-menu.mjs:49-53`).
2. **Picker.** A dialog like `MovePickerDialog` mode `topic`, one filtered
   list of existing topics (Q3), newest first: the topics of every channel
   the viewer may post in (`#channel` as hint) and the viewer's DM topics
   (the peer's name as hint, Q5). The source's own topic is not offered.
3. **Confirm when the audience widens (Q5).** The source is a DM, or in a
   members-only channel, and the target is a different place (another DM,
   another channel, or a public one): the dialog asks once, "People who
   cannot see the original will see this card." A source in a public
   channel never asks. The WUI decides from the two places it already holds
   (the source row's `channel` / DM ends, the target row); the hub does not
   re-ask.
4. **Send.** One wui-live-ws `send` frame: `forward_of = <source msg_id>`,
   the target topic's `task_id`, a client-minted `msg_id`, `is_parent: 0`, and
   no `body` / `files` (7.1.1).
5. **Hub: the source.** `wuiSend` reads the source row (`GetEditable`), and
   refuses `forward_not_found` (404, the same answer for missing, unreadable,
   hidden and box-locked) unless the forwarder passes `canReadMessage` and the
   topic door (`canReadTopic`, so the box owner lock counts) (Q4).
6. **Hub: the new card.** Body and files are the source's, verbatim; kind
   `note`; from = the forwarder. The body's @mentions are NOT read: the
   forward skips `dispatchAgent` on the body (3.4 step 1), so `to` starts as
   `ALL-0` (Q6).
7. **Hub: the target checks.** The target `task_id` must hold a topic the
   forwarder may read (`canReadTopic`), else `forward_no_topic` 404: without
   this check an unknown `task_id` would open a new topic, which Q3 rules
   out. Then the existing checks (3.4 steps 3-4): archived target,
   `wuiMayPost` (member of the target channel, `notes.send`), billing and
   quota, `unreadableFile` (passes: the forwarder reads the files through
   the source).
8. **Store.** `commitRow` with `fwd_of` set to the source's ROOT (7.1.2)
   in the same insert. The
   stored card is a plain copy (Q1): the WUI shows it like any card of the
   forwarder; nothing on the view row or the frame says it is a forward.
9. **Fan-out (Q6).** The ack to the forwarder; `fanoutWUI` to every browser
   on the target; the reply routes as any reply in that topic (3.4 step 3):
   to the topic's agent, the DM's other person, or the channel's agent
   members. A toast in the forwarder's WUI: "Forwarded to <topic>".
   The after-store notes that read the body are skipped for a forward
   (7.1.3): its text is someone else's words, not the forwarder's.

## 5. Reused, and the gaps

Reused as is: the card menu and its `locks` (3.1), the topic picker's list,
filter, keyboard and per-channel read (3.2), the whole `wuiSend` chain
(3.4), the read door (3.5), shared blobs (3.6), the `mirror_of` pattern
for a hub-only marker (3.7, 3.8), `fanoutWUI`.

| gap | what is missing | row |
|---|---|---|
| G1 | the column that says a row is a forward of which card | F1 |
| G2 | `forward_of` on the send frame; the hub filling body and files from the source, the source door, the existing-topic check, the mention skip | F2 |
| G3 | the store writing `fwd_of` (postgres and memory) | F2 |
| G4 | the Forward entry, its emit and handler | F3 |
| G5 | the picker with DM topics and the widening confirm | F3 |
| G6 | the attachment X following forwards (Q2) | F4 |
| G7 | translations of the new keys, agy's review | F5 |
| G8 | contract and user docs | F7 |

## 6. Build order (rows a later lane can take in parallel)

Every row codes against section 7.1, not against another row's branch: the
WUI row runs on the mock client, the hub rows on the store interface. F1,
F2, F3 and F7 can start together; F4 after F1 and F2; F5 after F3 has
landed its en keys; F6 after F3.

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| F1 | rdb: `fwd_of` and its index | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_fwd_of.sql` (0299 at v0.2; re-check the head) | none | applies twice on a throwaway postgres; `\d messages` lists `fwd_of uuid` nullable and the partial index | a migration test asserting `fwd_of` fails before the file exists |
| F2 | hub: forward send and store | `internal/hub/wui.go` (`wuiIn.ForwardOf`, a `wuiForward` step before `wuiRecipient`; the after-store skips of 7.1.3), new `internal/hub/wui_forward.go` + `wui_forward_test.go`, `internal/store` (postgres + memory write of `fwd_of`), `openapi.json` if the frame schema lists the send fields | 7.1.1-7.1.3 (F1's file for the postgres test) | Go tests on postgres: a forward of a readable card into an existing topic stores the source's body + files and `fwd_of`; a forward of a forward stores the root's msg_id (7.1.2); each refusal of 7.1.1 (`to` / `to_box` included); an @agent in the forwarded body dispatches to no one and writes no mention note; a reply in a topic with an agent reaches that agent | the same forward by a member outside the source's channel must answer `forward_not_found`, and one with an unknown `task_id` `forward_no_topic`; each test fails when its check is removed |
| F3 | WUI: menu entry, picker, send | `utils/msg-menu.mjs`, `MessageMenu.vue`, `MessageCard.vue`, new `ForwardPickerDialog.vue` (or a `forward` mode of `MovePickerDialog.vue`), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`forward_of`), `i18n/locales/*.json` (en + machine drafts) | 7.1.1, 7.1.4, 7.1.5 | `msg-menu.test.mjs`: Forward on every desktop card, absent from the touch list; a unit test of the picker rows (channel topics, DM topics, no source topic) and of the widening rule; `pnpm run typecheck`; i18n gates | drop the entry from `msgMenuItems`: the menu test fails; list it on touch: the touch assertion fails |
| F4 | hub: the X follows forwards (Q2) | `internal/hub/attachment_remove.go`, a one-hop store lookup `WHERE fwd_of = <the X'd card's msg_id>`, its test | F1, F2 | the source author's X removes the file from the source and from every forward of it, chains included (M1 -> M2 -> M3: both M2 and M3 lose it, as both store `fwd_of = M1`); each forward row is changed as an edit is and its viewers get the edit frame (`fanoutEdited`); the HTTP 200 lists only the rows the caller may read (7.1.6); the blob goes when nothing else carries it | a forward of a DIFFERENT card carrying the same file keeps it; a forward in a DM the author is not an end of is changed but absent from the 200 body |
| F5 | i18n: agy's final review | the 18 non-en locale files, the keys of 7.1.4 | F3 landed | agy review per the language rule; gates green | the untranslated-count gate (`i18n-untranslated.test.mjs`) |
| F6 | e2e | new `csi-spl-wui/tests/e2e/msg-forward.test.mjs` | F3 | on the generated bundle, mock-served: forward a reply into a topic of another channel, the card appears there as a plain card; a DM source asks to confirm | the e2e fails when the menu entry is absent |
| F7 | docs | `csi-spl-doc/specs/005-spool-wui/spec.md` (FR-021), `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (section 4: `forward_of` and its refusals), the user help for the card menu | 7.1 | the contract names every field and refusal of 7.1.1 | a doc test or link check that covers the file fails on a removed field |

## 7. Contracts

### 7.1 Binding contracts for the parallel rows

#### 7.1.1 The send frame (wui-live-ws section 4)

```
{ "type": "send",
  "msg_id": "<uuid, client-minted>",
  "task_id": "<the target topic's task_id: an existing topic>",
  "forward_of": "<the source's msg_id>",
  "is_parent": 0,
  "channel": "<the target topic's channel; absent for a DM topic>" }
```

- The other fields are the ones the WUI sends for any reply in that topic;
  a DM topic's reply carries no `channel` and the hub resolves the other
  person (`wui.go:789-796`).
- `body` and `files` are absent. With `forward_of` set, a non-empty `body`
  or `files`, or `is_parent: 1`, is refused `bad_json` 400.
- `to` and `to_box` are absent too, and refused `bad_json` 400 when sent
  with `forward_of`: `wuiRecipient` passes `to` to `dispatchAgent`
  (`wui.go:887-893`), which dispatches to any agent `to` names whatever the
  body says (`dispatch.go:51-57`). The reply's `to` comes only from the
  target topic's routing (7.1.3).
- `forward_of` must be a UUID (`bad_json` 400 otherwise).
- A resend of the same `msg_id` re-acks (the existing duplicate rule, `wui.go:697-716`).
- Refusals added: `forward_not_found` 404 (source missing, unreadable,
  hidden or box-locked: one answer for all) and `forward_no_topic` 404 (the
  `task_id` holds no topic the forwarder may read). Every existing refusal
  of `wuiSend` applies unchanged to the target.
- The ack is the existing ack (`wui.go:813-814`), unchanged.

#### 7.1.2 The column (rdb `<next>_messages_fwd_of.sql`)

| column | type | value |
|---|---|---|
| `fwd_of` | uuid NULL, no default | the ROOT card's msg_id: `source.fwd_of` when the source is itself a forward, else `source.msg_id`. NULL on every row that is not a forward. No FK: the root may expire or be deleted, and a forward of a forward still stores the root's id |

Plus `CREATE INDEX IF NOT EXISTS messages_fwd_of ON messages (tenant_id, fwd_of) WHERE fwd_of IS NOT NULL`
(F4 finds every forward of a card, a chain included, in one hop: storing
the root, not walking `fwd_of`, is chosen so that the X needs no recursive
query and a deleted middle card does not cut the chain). Catalog-only, as 0112 and 0250; RLS unchanged
(messages already ENABLE + FORCE it). Deploy order: before the hub of F2.

#### 7.1.3 The stored message

v:1 unchanged: `from` = forwarder, `to` = whatever the reply routing of the
target topic resolves (3.4 step 3; never an agent named in the body),
`kind` = `note`, `body` and `files` = the source's at forward time. The
envelope is what `wuiEnvelope` builds for any browser reply. `fwd_of` is on
neither the view row nor the `message` frame (Q1: nothing shows it).

After the store (`wuiAfterStore`, `wui.go:647-654`), a forward runs the
agent fallback as any reply, and **skips the three steps that read the
body as the sender's own words**: `noteMentionNonMembers` (SPL-2419,
`:651`), `noteMentionAgentsHumansOnly` (SPL-2423, `:652`) and
`ownerPrioWord` (SPL-5524, `:653`, `owner_prio_word.go`). A forwarded text
that @mentions someone or carries an owner's priority word writes no note
and sets no priority (Q6: "an @mention in the forwarded text does not
dispatch work").

#### 7.1.4 The WUI menu entry and keys

- Menu item: `{ id: 'forward', icon: 'forward', labelKey: 'feed.msg_menu.forward' }`,
  emit `'forward'`; desktop only (Q7), right after Copy link (before Hide
  from flow, Add to note, Export to PDF). No keyboard shortcut in v0.2.
- New i18n keys (en text): `feed.msg_menu.forward` "Forward…",
  `feed.forward.title` "Forward to a topic", `feed.forward.widen` "People
  who cannot see the original will see this card.", `feed.forward.done`
  "Forwarded to {topic}", `feed.forward.none` "No topic you can post in".
  Every key in all 19 locale files (`i18n-parity.test.mjs`).

#### 7.1.5 The picker

Rows, one list, filtered by one query: `{kind: 'topic', id: task_id, hint:
'#channel'}` for the topics of `moveChannelTargets(channels, '')` (the
source's own channel included, the lobby and `issues` left out), read as
`MovePickerDialog.load` reads them, and `{kind: 'dm', id: task_id, hint:
'<peer name>'}` for the viewer's DM topics (`listTopics({ dm: true })`,
`spool-client.mjs:603`). The source's own topic is left out. A pick that
widens the audience (4 step 3) asks first; then it sends the frame of
7.1.1; on a refusal the dialog stays open and shows the reason.

#### 7.1.6 The attachment X on a forwarded file (row F4)

`DELETE /v1/attachments/{file_id}` keeps its answer
(`attachment_remove.go:101-104`: `file_id`, `removed`, `messages`, `kept`,
`blob_deleted`), with one rule for forwards:

- The rows it changes are the caller's own changeable rows, as today, plus
  every forward (`fwd_of` = one of those rows' msg_id) that carries the file.
- Each changed forward gets the edit frame to ITS viewers (`fanoutEdited`),
  whether or not the caller may read it.
- `removed` and `messages` list only rows the caller may read
  (`canReadMessage`); a forward the caller cannot read is changed but named
  nowhere in the answer, and `kept` does not count it. The log line
  (`:99-100`) may name every msg_id: it is not the caller's answer.

## 8. Not in this spec

- Forwarding to another workspace (spec 169 copies whole channels).
- Forwarding into a new topic (Q3), and a forwarded-from header or link
  (Q1).
- Forwarding a whole topic, or several cards at once.
- An agent forwarding over its box socket or the `spool` CLI.
- A "forwarded N times" count on the source.

## 9. Changes from v0.1

The owner's answers (msg `61389b91`) took Q1 PLN, Q3 TOP and Q7 NO instead of
the v0.1 recommendations HDR, ANY and YES; Q2, Q4, Q5, Q6 match v0.1.

- **Q1 PLN removed:** the "Forwarded from" header and the link back; the
  columns `fwd_from`, `fwd_task`, `fwd_channel`, `fwd_title`, `fwd_ts`,
  `fwd_note`; the `forwarded` object on the view row and the `message`
  frame (old 7.1.3); row F4 "the forwarded header" (old G6); the keys
  `feed.forward.header` and `feed.forward.unavailable`. Kept: `fwd_of`,
  which Q2 LNK needs (row F4, old F5).
- **Q3 TOP removed:** the "New topic in #channel" picker rows and the key
  `feed.forward.new_topic`; the frame's new-topic fields (`to`, `to_box`,
  `is_parent: 1`). Added: `forward_no_topic`, so an unknown `task_id` cannot
  open a topic.
- **Q7 NO removed:** the Forward row on the phone's long-press sheet.
- **Q1-Q7 settled:** the refusals that existed only for other answers
  (`forward_not_allowed`, `forward_dm`) are gone.
- Rows renumbered: F1-F7 (v0.1 F1-F8 minus the header row).

### 9.1 Changes from v0.2

The spec review's findings (a-071, agy PASS on `67870b9d1`, msg `b71a97ff`;
the holder's order, msg `17cfbb3e`), each checked on `origin/master`
`62daca7aa`:

- **W1 chained forwards:** `fwd_of` stores the ROOT (`source.fwd_of` else
  `source.msg_id`), chosen over a transitive walk: F4 stays one hop and a
  deleted middle card does not cut the chain (7.1.2, F2, F4).
- **W2 the X's answer:** a forward the caller cannot read is changed and
  fanned out to its own viewers but absent from the HTTP 200 (new 7.1.6, F4).
- **W3 `to` / `to_box`:** refused `bad_json` 400 with `forward_of`, since
  `dispatchAgent` dispatches on an agent `to` alone (`dispatch.go:51-57`)
  (7.1.1, F2).
- **N1 after-store notes:** skipped for a forward, and `ownerPrioWord`
  (`wui.go:653`), which also reads the body, with them (7.1.3, 4 step 9, F2).
