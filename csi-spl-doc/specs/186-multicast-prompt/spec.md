# Spec 186: Multicast Prompt

Status: **Draft v0.1** (2026-11-20). Lane `c-098` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). Placement `c002-s-multicast-prompt-spec`.
Epic: **SPL-2403**. Issue: **SPL-6058**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:032d8010-f150-4125-b1c2-70e503b1a450` (`t1`).
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the composer),
[185 forward a message card](../185-message-forward/spec.md) (one card into
another topic over the same `send` frame; section 8.1 says where multicast
differs) and [045 move by drag](../045-spool-move-by-drag/spec.md) (the topic
picker). Relates to [182 topic loop prompt](../182-topic-loop-prompt/spec.md)
(section 8.2).

Line references were measured on `origin/master` `adcd75dbb`. Next free
number: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c '^csi-spl-doc/specs/186-'`
-> 0, and `git log --all --oneline -- 'csi-spl-doc/specs/186-*'` over every
fetched branch -> empty (184 and 185 are on master).

## 0. The owner's words (HUM-10, t1 topic 032d8010)

Msg `f7782824`, verbatim: "multicast prompt feature - I would like to be able
to write a single prompt to multiple topics from multiple channels within a
workspace"

Read as: in the composer, the author writes ONE text (with files, if any),
picks SEVERAL topics, from any channels of the same workspace, and the hub
posts it into each of them. Nothing named multicast exists today:
`git grep -n -i multicast origin/master -- csi-spl-wui/src csi-spl-api/src | wc -l` -> 0.

## 1. The owner's open questions (one form)

Each question is decided by the owner; the first option is the
recommendation. Every part of sections 4 to 7 that depends on an answer is
marked **[Qn]**; the build rows name the answers they wait for.

| Q | Question | Options (recommended first) |
|---|---|---|
| Q1 | How are the target topics picked? | **MSL** — a multi-select picker over the topics of every channel you may post in (and your DMs, Q8), with a filter. **GRP** — saved target groups only ("my release topics"), picked by name. **BTH** — the picker, plus saving a selection as a group for next time |
| Q2 | Which topics can be targets? | **EX** — existing topics only (as 185 Q3). **NEW** — existing topics and "a new topic in #channel" rows |
| Q3 | What does each topic get? | **LNK** — one ordinary post per topic, each with its own msg id, and a hidden shared multicast id that links the copies (a hub column; nothing shows it unless Q4 is GTH). **IND** — fully independent posts, nothing links them |
| Q4 | Where are the replies read? | **OWN** — each topic is answered on its own, as any post. **GTH** — as OWN, plus one "Multicast" view that lists every copy with its replies (needs Q3 LNK) |
| Q5 | Do agents act on the copies? | **NRM** — each copy is a normal post in its topic: the topic's agent, the channel's agents and a leading @mention get it as they would get your own post there. **MEN** — only a leading @mention dispatches; no topic or channel agent fan-out. **NON** — no agent dispatch at all, a copy is read by people only |
| Q6 | How many topics at most per multicast? | **10**. **25**. **50**. (Same workspace only, as asked: the picker lists no other workspace) |
| Q7 | Attachments? | **SHR** — allowed; uploaded once, the same files on every copy. **TXT** — text only |
| Q8 | Members-only channels and DMs as targets? | **ALL** — any topic you may post in: public and members-only channels and your DM topics. **CHN** — channel topics only (public and members-only), no DMs. **PUB** — public channels only |
| Q9 | Some targets refuse (archived, no longer a member, quota): what happens? | **SND** — the others are posted; the composer lists the refused ones with the reason and a Retry. **ALL** — nothing is posted unless every target passes a pre-check |
| Q10 | Does it compose with loops (spec 182)? | **APT** — apart: a multicast is a one-off; a copy is a normal post, so an existing loop of that topic fires on it as on any post. **CMP** — also a "multicast loop": a loop whose prompt goes to several topics |
| Q11 | Where is it offered? | **DSK** — the desktop composer only (as 185 Q7). **BTH** — desktop and the phone dock |

## 2. Terms

| term | meaning |
|---|---|
| multicast | one composer send into several target topics |
| target | a topic the author picked; in a channel or a DM [Q8] |
| copy | the post the hub stores in one target |
| multicast id | `mc_id`, a client-minted UUID shared by every copy of one multicast [Q3 LNK] |
| author | the signed-in member who sends; the `from` of every copy |

## 3. What exists today (measured)

### 3.1 How the composer posts into one topic

- The composer emits `send(text, parentTaskId, files, channelId)`
  (`csi-spl-wui/src/components/MessageComposer.vue:397-398`); the target is
  the page's topic, or one topic named by an `in: <title>` clause on the
  Omnibox line (`csi-spl-wui/src/composables/useComposerSend.ts:104-121`,
  `csi-spl-wui/src/utils/topic-in.mjs:1-12`). The `in:` list is the
  composer's own one-topic picker (`csi-spl-wui/src/composables/useComposerPickers.ts:110-156`,
  catalogue `topicChoices`, `topic-in.mjs:80`). There is no way to name two
  topics.
- The store's `send` (`csi-spl-wui/src/stores/channel.ts:540`) calls
  `sendLive` (`:640-696`): files become refs once (`toFileRefs`), an
  optimistic row is drawn under a client-minted `msg_id`, one frame goes over
  the socket with one automatic resend (`sendWithResend`, `:684`), a network
  failure waits for reconnect under the same `msg_id`.
- The frame is built by `sendMessage`
  (`csi-spl-wui/src/utils/spool-client.mjs:935-976`): `{task_id, kind: 'note',
  body, files}` plus `msg_id`, `to` / `to_box`, `channel`, `parent_task_id`,
  `is_parent` (`:948-956`). Contract: `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md`
  section 4 (`:115-148`). Every browser post is this one WebSocket frame.

### 3.2 The hub's send path and its checks

`wuiSend` (`csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go:571-643`),
per frame, in order:

1. `wuiIDs` (`:831-852`): `task_id` and `msg_id` UUIDs, `is_parent` 0 or 1.
2. `wuiRecipient` (`:887-930`): `to`, and when box-wui dispatch is on, the
   agent a leading `@ID` in the body names (`dispatchAgent`,
   `internal/hub/dispatch.go:51`).
3. `wuiMessage` (`:700`): the v:1 object, `from` = the member.
4. `wuiRoute` (`:741-800`): the channel and parent tags (`checkTags`), the
   archived-topic refusal (`wuiArchivedRefusal`,
   `internal/hub/topic_archived_input.go:48-61`), the moved-topic refusal,
   a humans-only channel turning an @agent into a plain post
   (`channelHumansOnly`, `:756-758`), note to self (`:759-761`), then
   `wuiMayPost` (`:858-873`): the member must READ the target channel
   (`canReadChannel`, else `unknown_channel` 404) and hold `notes.send`
   (`agents.command` for an agent dispatch). Then the addressee: an @agent
   dispatch (`:765-781`); a channel-less reply goes to the topic's agent
   (`topicReplyAgent`, `internal/hub/topic_reply.go:26`) or, in a DM, to its
   other person (`topicReplyPerson`, `topic_reply.go:93`); a channel post
   gets the channel agent fan-out decision (`:797-798`).
5. `senderAllowed`, `demoDM`, `admit` (`:997-1020`: billing, the message
   quota `messageQuota` `internal/hub/ws.go:918`, `missingFile` `ws.go:945`,
   `unreadableFile` `ws.go:979`), `demoAgentTurn` and `tokenBudget`
   (`internal/hub/token_budget.go:40`) when an agent will act, the demo audit
   (`:593-612`).
6. `wuiEnvelope` (`:962-992`), `commitRow` (`ws.go:1014`, the one store
   path), the ack (`wuiAck`, `:804-826`), then `wuiAfterStore`
   (`:647-654`): the agent fallback and three notes that read the body
   (mentions of non-members SPL-2419, agents in a humans-only channel
   SPL-2423, the owner's priority word SPL-5524). A channel post's delivery
   to each member box is `routeChannel` (`internal/hub/channels.go:351`),
   gated by `channelAgentsHear`; spec 179's topic pause is read with the
   topic's access row (`internal/store/channel_humans.go:56-59`, rdb 0297).
7. A refusal is one `error` frame naming the frame's `msg_id`
   (`wuiRefuse`, `:659-672`; `wuiErr.MsgID`, `:147`), and a resend of a
   stored `msg_id` re-acks (contract section 4; `wuiArchivedRefusal` lets it
   pass).

Every check is per message and per target. **A send with an unknown
`task_id` opens a new topic**: no check asks that the task exists (spec 185
adds `forward_no_topic` for this).

### 3.3 Who may read and post (the doors)

`internal/hub/privacy.go`: a channel message is readable by the channel's
humans; the default channels and issue discussions are public to the
workspace, every created channel is members-only (`:13-33`,
`canReadChannel` `:71`); a DM is readable by its two ends only
(`canReadMessage`, `:94-102`); `canReadTopic` (`:129`) adds the box owner
lock. A workspace is a tenant (spec 185 section 0): the socket is bound to
one tenant, so a target in another workspace cannot be named.

### 3.4 The pickers that exist

- `MovePickerDialog.vue` mode `topic` lists, with a filter, the topics of
  every channel the viewer may read, one page of 50 per channel
  (`csi-spl-wui/src/components/MovePickerDialog.vue:90-125`, SPL-4892),
  channels from `moveChannelTargets` (`csi-spl-wui/src/utils/move-apply.mjs:16-25`:
  minus the lobby and `issues`). Single pick; it closes on the pick (`:129-141`).
- DM topics: `listTopics({ dm })` (`spool-client.mjs:603`).
- No multi-select list exists in the WUI.

### 3.5 Attachments

`msg.Attachment` is a blob by `file_id` = the sha256 of the bytes; the
object key is per tenant and file (`internal/blob/blob.go:27-31`), so N
copies carrying one `file_id` share one object. `unreadableFile` lets the
author attach a fresh upload no message carries yet
(`internal/hub/rest.go:346-351`) and any file a message they may read
carries. Limits: body 64 KiB, 16 files (`internal/msg/msg.go:42-43`).

## 4. The flow end to end

1. **Composer.** A "Send to several topics" button beside the attach
   button (`MessageComposer.vue:288-300`) opens the picker [Q11: desktop
   only, or also the phone dock]. The text and the picked files stay in the
   composer.
2. **Picker.** A dialog with one filtered list, grouped by channel, each
   row a checkbox: the topics of every channel the author may post in (the
   `MovePickerDialog.load` read), plus their DM topics [Q8], newest first;
   the open topic is preselected. [Q2 NEW: a "New topic in #channel" row per
   channel.] [Q1 GRP/BTH: a "Groups" list above, and "Save as group".] The
   count shows "n of max" [Q6]; the (max+1)th tick is refused in place.
3. **Send.** The WUI uploads the files once (`toFileRefs`) [Q7], mints one
   `mc_id` [Q3 LNK] and, per target, one ordinary `send` frame (7.1.1) with
   its own `msg_id`, at most 4 in flight. Each copy is the author's post
   into that topic: the same body, files and kind `note`.
4. **Hub, per frame.** The whole chain of 3.2, unchanged, plus three
   multicast checks (7.1.1): the target topic exists and the author may read
   it (`multicast_no_topic`) [Q2 EX], the copy count of that `mc_id` is
   under the cap (`multicast_too_many`) [Q6], and the `mc_id` belongs to
   this author (`bad_json`). Store with `mc_id` [Q3 LNK].
5. **Fan-out, per copy.** As any post of the author in that topic [Q5]:
   NRM: `topicReplyAgent`, the channel's agents via `routeChannel`, a
   leading @mention dispatch, a paused topic's agents get nothing (spec
   179); MEN: only the @mention; NON: the hub stores the copy browser-only
   (7.1.3). The after-store notes run per copy: the text is the author's own
   words (unlike a forward, 185 7.1.3).
6. **Results.** The composer shows one line per target as its ack or error
   frame arrives (matched by `msg_id`): sent, or refused with the token's
   reason. [Q9 SND] The composer clears when every target is sent; if some
   are refused it keeps the text and offers Retry for those (the same
   `msg_id`s: a resend of a stored copy only re-acks). [Q9 ALL] A pre-check
   frame (7.1.2) runs first and nothing is sent unless it passes for all.
7. **Replies.** [Q4 OWN] Each topic is answered on its own; nothing else.
   [Q4 GTH] A "Multicast" view (7.1.5) lists every copy with its topic and
   its replies, opened from the author's own copy.

## 5. Reused, and the gaps

Reused as is: the composer and its file upload, the `send` frame and every
check of `wuiSend` (3.2), the doors (3.3), the topic read of the move picker
(3.4), shared blobs (3.5), the per-`msg_id` ack, error frame and resend.

Why N frames and not one `multicast` frame: every check of 3.2 is per
message and per target, and the error frame already names one `msg_id`; a
new frame would have to repeat the chain in a loop and invent a partial
answer. The hub change stays three checks and a column.

| gap | what is missing | row | depends |
|---|---|---|---|
| G1 | the column that links the copies | M1 | Q3 LNK |
| G2 | `mc_id` on the frame, the existing-topic check, the cap, the store write | M2 | Q2, Q3, Q6 |
| G3 | the copy's agent rule when not NRM | M2 | Q5 MEN / NON |
| G4 | the composer button, the multi-select picker, the N sends, the result list with Retry | M3 | Q1, Q7, Q8, Q9, Q11 |
| G5 | the pre-check frame | M4 | Q9 ALL |
| G6 | the gathered view | M5 | Q4 GTH |
| G7 | saved target groups (a table, routes, the picker list) | M6 | Q1 GRP / BTH |
| G8 | translations, agy's review | M8 | none |
| G9 | contract and user docs | M9 | none |

## 6. Build order (rows a later lane can take in parallel)

Every row codes against section 7.1, not against another row's branch: the
WUI rows run on the mock client, the hub rows on the store interface. M1,
M2, M3 and M9 can start together once the form is answered; M5 after M1
and M2; M7 after M3; M8 after M3 has landed its en keys.

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| M1 | rdb: `mc_id` and its index [Q3 LNK] | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_mc_id.sql` (head 0298 at v0.1; spec 185's F1 plans 0299: re-check) | Q3 | applies twice on a throwaway postgres; `\d messages` lists `mc_id uuid` nullable and the partial index | a migration test asserting `mc_id` fails before the file exists |
| M2 | hub: the multicast checks and store | `internal/hub/wui.go` (`wuiIn.McID`, one `wuiMulticast` step after `wuiIDs`), new `internal/hub/wui_multicast.go` + `wui_multicast_test.go`, `internal/store` (postgres + memory: write `mc_id`, `CountMulticast(tenant, mc_id)`, `MulticastAuthor`) | 7.1.1, 7.1.3; M1's file for the postgres test | Go tests on postgres: N frames with one `mc_id` into N readable topics of different channels store N rows with that `mc_id`; each copy routes as 3.2 step 4 [Q5]; an @agent copy into a humans-only channel is a plain post; the (max+1)th copy answers `multicast_too_many`; a resend of a stored copy re-acks | an unknown `task_id` with `mc_id` must answer `multicast_no_topic` (without the check it opens a topic); a second author reusing the `mc_id` must answer `bad_json`; each test fails when its check is removed |
| M3 | WUI: button, picker, N sends, results | `components/MessageComposer.vue` (the button), new `components/MulticastPickerDialog.vue`, new `composables/useMulticastSend.ts`, `stores/channel.ts` (`sendMulticast`, one `sendLive` per target), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`mc_id`), `i18n/locales/*.json` (en + machine drafts) | 7.1.1, 7.1.4, 7.1.6; Q1, Q7, Q8, Q9, Q11 | a unit test of the picker rows (channel topics grouped, DM topics [Q8], lobby and `issues` absent, the cap [Q6]); a unit test of `useMulticastSend` on the mock: files uploaded once, N frames with one `mc_id` and N `msg_id`s, a refused target listed with its token and retried with the same `msg_id`; `pnpm run typecheck`; i18n gates | make the mock refuse one target: the result list must show it and the composer must keep the text; drop the cap: the cap test fails |
| M4 | hub + WUI: the pre-check [Q9 ALL only] | `internal/hub/wui_multicast.go` (`multicast_check` frame), its test; `useMulticastSend.ts` | 7.1.2; M2 | a check of N targets answers one line per target and stores nothing | a target in an archived topic must come back refused |
| M5 | hub + WUI: the gathered view [Q4 GTH only] | new `internal/hub/view_multicast.go` (`GET /v1/view/multicast/{mc_id}`), its test, `openapi.json`; new `pages/m/[mc_id].vue` | 7.1.5; M1, M2 | the view lists every copy the reader may read, with its topic and reply count, newest reply first | a copy in a members-only channel the reader left must be absent |
| M6 | rdb + hub + WUI: saved groups [Q1 GRP / BTH only] | `<next>_multicast_groups.sql` (tenant, member, name, task_ids, RLS), `internal/hub/multicast_groups.go`, the picker's group list | 7.1.7 | a member's group lists only topics they may still read when opened | another member's group must read 404 |
| M7 | e2e | new `csi-spl-wui/tests/e2e/multicast-prompt.test.mjs` | M3 | on the generated bundle, mock-served: pick three topics in two channels, send once, the card appears in all three; one refused target shows its reason and Retry | the e2e fails when the button is absent |
| M8 | i18n: agy's final review | the 18 non-en locale files, the keys of 7.1.4 | M3 landed | agy review per the language rule; gates green | the untranslated-count gate (`i18n-untranslated.test.mjs`) |
| M9 | docs | `csi-spl-doc/specs/005-spool-wui/spec.md` (an FR for the multicast send: FR-022 if 185 has taken FR-021; re-check), `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (section 4: `mc_id` and its refusals), the user help for the composer | 7.1 | the contract names every field and refusal of 7.1.1 | a doc test or link check that covers the file fails on a removed field |

## 7. Contracts

### 7.1 Binding contracts for the parallel rows

#### 7.1.1 The send frame (wui-live-ws section 4)

One frame per target, the frame the WUI sends today for a post in that
topic, plus one field:

```
{ "type": "send",
  "msg_id": "<uuid, client-minted, one per copy>",
  "task_id": "<the target topic's task_id>",
  "kind": "note", "body": "<the text>", "files": [ <the same refs on every copy> ],
  "channel": "<the target topic's channel; absent for a DM topic>",
  "is_parent": 0,
  "mc_id": "<uuid, client-minted, the same on every copy>" }
```

- `to` / `to_box` as the WUI sends them today for that topic; under Q5 NRM
  a leading @mention in the body dispatches in every copy, as it would in
  each single post.
- `mc_id` must be a UUID (`bad_json` 400). A frame without `mc_id` is an
  ordinary send, unchanged.
- [Q2 EX] With `mc_id`, `is_parent` must be 0 and the `task_id` must hold a
  topic the author may read (`canReadTopic`), else `multicast_no_topic`
  404. [Q2 NEW] `is_parent: 1` with a `channel` also passes: it opens a new
  topic there, as a new post does today.
- An `mc_id` already stored with another `from` is refused `bad_json` 400.
- [Q6] The copy that would make the stored copies of this `mc_id` exceed
  the cap is refused `multicast_too_many` 400. The cap is hub cnf
  (`hub.multicast.max_targets`), the WUI reads it from the `welcome` frame
  (`multicast_max`).
- Every existing refusal of `wuiSend` applies to each copy unchanged
  (`topic_archived`, `unknown_channel`, `forbidden`, `402 unpaid`, `429
  quota`: each copy counts as one message, `missing_file`, the token budget,
  the demo checks). The ack is the existing ack.

#### 7.1.2 The pre-check frame [Q9 ALL only]

`{ "type": "multicast_check", "targets": [{"task_id", "channel?"}...], "files": [...], "body_bytes": n }`
-> `{ "type": "multicast_checked", "targets": [{"task_id", "ok": true|false, "error?": "<token>"}] }`.
It runs the read-only checks of 3.2 steps 4 and 5 per target and stores
nothing. Absent under Q9 SND.

#### 7.1.3 The stored copy

v:1 unchanged: `from` = author, `to` = what 3.2 step 4 resolves for that
topic, `kind` = `note`, `body` and `files` = the frame's. [Q3 LNK] The hub
column `mc_id` (rdb `<next>_messages_mc_id.sql`: `mc_id uuid NULL`, no
default, no FK; `CREATE INDEX IF NOT EXISTS messages_mc_id ON messages (tenant_id, mc_id) WHERE mc_id IS NOT NULL`;
catalog-only, RLS unchanged) is on neither the view row nor the `message`
frame unless Q4 is GTH (7.1.5). Never inside the v:1 object (`Parse`
refuses an unknown key, spec 185 3.8). [Q5 MEN] the copy skips
`topicReplyAgent` and the channel fan-out (`fanOut` false), keeping an
@mention dispatch. [Q5 NON] the copy also skips the @mention dispatch: it is
stored with the unsigned browser-only envelope. After the store, the
fallback and the three notes of 3.2 step 6 run per copy, as for any post.

#### 7.1.4 The WUI keys

New i18n keys (en text): `composer.multicast` "Send to several topics",
`composer.multicast_title` "Send to topics", `composer.multicast_count`
"{n} of {max}", `composer.multicast_max` "At most {max} topics",
`composer.multicast_sent` "Sent to {n} topics", `composer.multicast_refused`
"Not sent to {topic}: {reason}", `composer.multicast_retry` "Retry",
`composer.multicast_none` "No topic you can post in". [Q1 GRP/BTH]
`composer.multicast_groups` "Groups", `composer.multicast_save_group` "Save
as group". [Q2 NEW] `composer.multicast_new_topic` "New topic in #{channel}".
Every key in all 19 locale files (`i18n-parity.test.mjs`).

#### 7.1.5 The gathered view [Q4 GTH only]

`GET /v1/view/multicast/{mc_id}` -> `{ "mc_id", "copies": [{ "msg_id",
"task_id", "channel?", "title", "replies", "last_reply_at?" }] }`, the
copies the reader may read (`canReadMessage`), 404 when none. The author's
own copy card carries `mc_id` on the view row so the WUI can link it.

#### 7.1.6 The picker

Rows, one list, filtered by one query, grouped by channel:
`{kind: 'topic', id: task_id, channel, title}` for the topics of
`moveChannelTargets(channels, '')` read as `MovePickerDialog.load` reads
them; [Q8 ALL] `{kind: 'dm', id: task_id, peer, title}` from
`listTopics({ dm: true })`. Archived topics are not listed. The open topic is
preselected. A tick past the cap is refused with `composer.multicast_max`.

#### 7.1.7 Saved groups [Q1 GRP / BTH only]

Table `multicast_groups (tenant_id, member_id, group_id uuid, name text,
task_ids uuid[], created_at)`, RLS ENABLE + FORCE, one member's groups
visible to that member only; `GET/PUT/DELETE /v1/multicast-groups[/{id}]`.
A group stores task ids, never access: when opened, a topic the member may
no longer read is dropped from the list.

## 8. Related specs

### 8.1 Spec 185 (forward), where multicast differs

Both post into existing topics over the `send` frame, keep every check of
`wuiSend` and store a hub-only marker column (`fwd_of`, `mc_id`). They
differ:

| | forward (185) | multicast (186) |
|---|---|---|
| the text | someone's card, copied by the hub from `forward_of` | the author's own, in the frame |
| targets | one | up to the cap [Q6] |
| @mentions in the body | not read (185 Q6) | read as the author's own [Q5] |
| after-store notes | skipped (185 7.1.3) | run per copy |
| widening confirm | yes, a DM or members-only source | none: the author already writes there |
| new topic | no (185 Q3) | [Q2] |

A later lane may share one helper for "the target topic must exist and be
readable" (185's `forward_no_topic`, 186's `multicast_no_topic`); whichever
lands first owns it, the other calls it.

### 8.2 Spec 182 (topic loop prompt)

182 repeats a prompt in time inside one topic; multicast sends one prompt
across topics once. [Q10 APT] They stay apart: a copy is a normal post in its
topic, so a loop there whose triggers include a human post fires on it as on
any post, and nothing else changes. [Q10 CMP] would add a loop whose prompt
targets several topics: a separate spec, after 182 is built (its tables are
not on master: `git grep -n topic_loops origin/master -- csi-spl-rdb csi-spl-api/src | wc -l` -> 0).

## 9. Not in this spec

- Targets in another workspace (the socket is bound to one tenant).
- A multicast from an agent, the box socket or the `spool` CLI.
- Editing or deleting all copies at once: each copy is edited or deleted on
  its own card, as today.
- Multicasting an existing card (that is a forward, spec 185).
