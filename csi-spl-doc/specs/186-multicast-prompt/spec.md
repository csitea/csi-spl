# Spec 186: Multicast Prompt

Status: **Draft v0.3, answered** (2026-11-20). v0.1 `83295f6d1`; v0.2
`b53947cee` folded the spec review's W1-W6 and N1; v0.3 folds the owner's
answers to form `e864b1cb` (Q1-Q5, Q7-Q11, msg `dcf298b8`) and the Q6 chat
answer (msg `1b95d0ec`), and drops every part only an unchosen answer
needed. Lane `c-098` (`claude`, backup for `specs_and_docs`: no agy cli on
this box). Placement `c002-s-multicast-prompt-spec`.
Epic: **SPL-2403**. Issue: **SPL-6058**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:032d8010-f150-4125-b1c2-70e503b1a450` (`t1`).
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the composer),
[185 forward a message card](../185-message-forward/spec.md) (one card into
another topic over the same `send` frame; section 8.1 says where multicast
differs), [045 move by drag](../045-spool-move-by-drag/spec.md) (the topic
picker) and [182 topic loop prompt](../182-topic-loop-prompt/spec.md) (the
multicast loop, 4.8).

Line references were measured on `origin/master` `adcd75dbb` (v0.1) and
re-checked on `4c4e97f75` (v0.3): since `adcd75dbb` the only change in the
files cited here is `csi-spl-wui/src/public/help-md/how-to-post.md`.

## 0. The owner's words (HUM-10, t1 topic 032d8010)

Msg `f7782824`, verbatim: "multicast prompt feature - I would like to be able
to write a single prompt to multiple topics from multiple channels within a
workspace"

Msg `1b95d0ec` (answer to Q6, "How many topics at most per multicast?"),
verbatim: "well I should be able to specify regexes for the topics titles
and * should be multicast to all"

Read as: in the composer, the author writes ONE text (with files, if any),
picks SEVERAL topics, from any channels of the same workspace, by ticking
them or by title regexes (`*` = every topic), and the hub posts it into each
of them. Nothing named multicast exists today:
`git grep -n -i multicast origin/master -- csi-spl-wui/src csi-spl-api/src csi-spl-cnf | wc -l` -> 0.

## 1. Decided (form `e864b1cb`, msgs `dcf298b8` and `1b95d0ec`)

| Q | Question | Answer |
|---|---|---|
| Q1 | How are the target topics picked? | **MSL** — a multi-select picker over the topics of every channel you may post in, with a filter |
| Q2 | Which topics can be targets? | **EX** — existing topics only |
| Q3 | What does each topic get? | **LNK** — one ordinary post per topic, linked by a hidden shared multicast id |
| Q4 | Where are the replies read? | **OWN** — each topic on its own, as any post |
| Q5 | Do agents act on the copies? | **NRM** — each copy is a normal post: the topic's agent, the channel's agents and a leading @mention get it |
| Q6 | How many topics per multicast? | **Regexes on topic titles; `*` = every topic** (chat answer; section 4.2) |
| Q7 | Attachments? | **SHR** — allowed: uploaded once, the same files on every copy |
| Q8 | Members-only channels and DMs as targets? | **CHN** — channel topics only (public and members-only), no DMs |
| Q9 | Some targets refuse: what happens? | **ALL** — nothing is posted unless every target passes a pre-check |
| Q10 | Does it compose with loops (spec 182)? | **CMP** — also a "multicast loop": one loop whose prompt goes to several topics |
| Q11 | Where is it offered? | **BTH** — desktop and the phone dock |

Dropped with the unchosen answers: saved target groups (Q1 GRP/BTH), the
"new topic in #channel" row (Q2 NEW), unlinked copies (Q3 IND), the gathered
"Multicast" view (Q4 GTH), the MEN/NON agent rules (Q5), DM targets (Q8),
the send-what-passes path (Q9 SND), the fixed caps 10/25/50 (Q6).

Two readings this spec makes, for the review to confirm or the owner to
correct:

- **R1** `*` covers every channel topic the author may post in, the lobby
  and `general` included, and leaves out the `issues` channel: an issue's
  discussion is that issue's comment thread, never a topic of a list
  (`TopicQuery.NoIssues`, `internal/store/view.go:43-45`).
- **R2** A hub cnf guard `hub.multicast.max_targets` (default 1000) stops a
  runaway selector. It is a guard, not a product limit: the owner asked for
  "all", so it is set well above a workspace's topic count and raised by cnf.

## 2. Terms

| term | meaning |
|---|---|
| multicast | one composer send into several target topics |
| selector | what picks the targets: ticked topics plus title patterns (4.2) |
| pattern | a topic-title regex, or the line `*` = every topic in scope |
| target | a channel topic the selector resolved to |
| copy | the post the hub stores in one target |
| multicast id | `mc_id`, a client-minted UUID shared by every copy of one multicast, stored on each copy (7.1.3) |
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
  topics. On a phone the composer dock is `MessageComposer.vue` itself
  (`--composer-dock-h`, `MessageComposer.vue:995`), so one button serves
  both (Q11 BTH).
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
   (`topicReplyAgent`, `internal/hub/topic_reply.go:26`); a channel post
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
`canReadChannel` `:71`); `canReadTopic` (`:129`) adds the box owner lock. A
workspace is a tenant (spec 185 section 0): the socket is bound to one
tenant, so a target in another workspace cannot be named.

### 3.4 Topic lists and titles

- `ViewTopics` (`internal/store/view.go:202`, Postgres
  `internal/store/view_postgres.go:132`) lists topics by a `TopicQuery`
  (`view.go:35-66`): `Reader` keeps only topics in a channel that member may
  read (rdb 0028), `NoIssues` drops issue discussions, archived topics are
  always left out, `DM` false lists channel topics; pages of at most
  `viewLimitMax` = 200 (`internal/hub/view.go:43`), keyed by
  `(BeforeAt, BeforeTask)`.
- A topic has no stored title: its title is `subject(body)` of its first
  message, the first line, trimmed, at most `subjectMax` = 140 runes
  (`internal/hub/view.go:44,1094-1100`); `TopicRow.FirstMsg` carries that
  body (`view.go:79`). `git grep -n -i -E 'topic_titles|RenameTopic' origin/master -- csi-spl-rdb csi-spl-api/src`
  -> empty: no rename.
- `MovePickerDialog.vue` mode `topic` lists, with a filter, the topics of
  every channel the viewer may read, one page of 50 per channel
  (`csi-spl-wui/src/components/MovePickerDialog.vue:90-125`, SPL-4892),
  channels from `moveChannelTargets` (`csi-spl-wui/src/utils/move-apply.mjs:16-25`),
  which drops `lobby`, `general` and `issues` (`MOVE_BLOCKED_CHANNELS`,
  `csi-spl-wui/src/utils/move.mjs:13`: a topic never moves in or out of
  them). Single pick; it closes on the pick (`:129-141`). No multi-select
  list exists in the WUI.
- Go's `regexp` is RE2: matching is linear in the input, no backtracking.
  A JavaScript `RegExp` backtracks and differs in syntax, so the WUI never
  decides which titles a pattern matches (4.2).

### 3.5 Attachments

`msg.Attachment` is a blob by `file_id` = the sha256 of the bytes; the
object key is per tenant and file (`internal/blob/blob.go:27-31`), so N
copies carrying one `file_id` share one object. `unreadableFile` lets the
author attach a fresh upload no message carries yet
(`internal/hub/rest.go:346-351`) and any file a message they may read
carries. Limits: body 64 KiB, 16 files (`internal/msg/msg.go:42-43`).

## 4. The flow end to end

### 4.1 Composer and picker

1. **Composer.** A "Send to several topics" button beside the attach
   button (`MessageComposer.vue:288-300`) opens the picker, on the desktop
   and in the phone dock (Q11 BTH, 4.6). The text and the picked files stay
   in the composer.
2. **Picker** (Q1 MSL, Q8 CHN, 7.1.6). One dialog: a filtered list of the
   topics of every channel the author may post in, grouped by channel,
   newest first, each row a checkbox, the open topic preselected; above it a
   **Patterns** field (4.2). No DM rows, no `issues` rows.
3. **Preview.** Every change of the ticks or the patterns (debounced 300 ms)
   sends one `multicast_check` frame (7.1.2). Its answer is the resolved
   target list, each with ok or the refusal token; the dialog shows
   "n topics" and the refused ones with their reason. The Send button
   reads "Send to n topics" and is enabled only when the check returned
   `ok` for every target (Q9 ALL) and n >= 1.

### 4.2 The selector: ticks and title patterns (Q6)

- The Patterns field takes one pattern per line, at most 10 lines, each at
  most 256 bytes.
- The line `*` alone means every topic in scope. (`*` alone is not a valid
  RE2 pattern, so it cannot mean anything else.)
- Any other line is an RE2 regex (Go `regexp`), matched case-insensitively
  (the hub prefixes `(?i)`) and unanchored (`MatchString`: a match anywhere
  in the title) against each topic's title (3.4). `^release` anchors.
  A line that does not compile refuses the check with
  `multicast_bad_pattern` 400, naming the line.
- **Scope**, the same for ticks, patterns and `*`: the channel topics of the
  author's workspace in channels the author may post in (`canReadChannel`
  and `notes.send`, 3.2 step 4), not archived, not in `issues` (R1). The
  lobby and `general` are in scope (R1).
- The targets are the union of the ticked topics and every in-scope topic a
  pattern matches, deduplicated by `task_id`. A ticked topic out of scope
  answers `multicast_no_topic` in the check.
- **The hub alone resolves patterns**, in the check (7.1.2), and returns
  the explicit list. The send then names each target's `task_id` (7.1.1),
  so what is posted is exactly the list the author saw. A topic opened
  after the last check is not a target.
- **Limits**: more targets than `hub.multicast.max_targets` (R2) refuse the
  whole check with `multicast_too_many`; so do more targets than the
  tenant's remaining monthly messages (`messageQuota`), with the quota
  token. Both say the count, so the author narrows the patterns.

### 4.3 Send

1. The WUI uploads the files once (`toFileRefs`, Q7 SHR), mints one
   `mc_id` and, per target of the last check, one ordinary `send` frame
   (7.1.1) with its own `msg_id`, at most 4 in flight. Each copy is the
   author's post into that topic: the same body, files and kind `note`.
2. **Hub, per frame.** The whole chain of 3.2, unchanged, plus the
   multicast checks of 7.1.1: the target topic exists, is a channel topic
   and the author may read it (`multicast_no_topic`, Q2 EX, Q8 CHN); the
   `mc_id` belongs to this author (`bad_json`); the stored copies of this
   `mc_id` stay within the cap (`multicast_too_many`). The copy is stored
   with `mc_id` (Q3 LNK).
3. **Fan-out, per copy** (Q5 NRM): as any post of the author in that topic:
   `topicReplyAgent`, the channel's agents via `routeChannel`, a leading
   @mention dispatch; a paused topic's agents get nothing (spec 179); an
   @mention in a humans-only channel is a plain post. The after-store notes
   run per copy: the text is the author's own words (unlike a forward, 185
   7.1.3).

### 4.4 Results

The composer shows one line per target as its ack or error frame arrives
(matched by `msg_id`). It clears when every target is acked. The pre-check
makes a refusal at send time rare but not impossible (the topic archived,
the quota spent, or a membership lost between check and send): then the
composer keeps the text, lists the refused targets with the token's reason
and offers Retry for them under the same `msg_id`s (a resend of a stored
copy only re-acks). Copies already stored stay: Q9 ALL is a promise of the
check, not a transaction across N topics (7.1.2).

### 4.5 Replies (Q4 OWN)

Each topic is answered on its own, as any post. Nothing gathers the
replies; `mc_id` is on neither the view row nor the `message` frame.

### 4.6 Phone (Q11 BTH)

The button is the same component on both (3.1). On a phone the picker opens
as a full-screen sheet over the dock, the Patterns field above the list,
the Send button fixed at its foot; the result lines replace the list.

### 4.7 Not changed

Editing or deleting a copy is done on that copy's card, as today; a copy is
a normal post for loops, search, export and archive.

### 4.8 The multicast loop (Q10 CMP)

A spec 182 loop whose prompt goes to several topics. It needs 182's loops
on master first: `git grep -n topic_loops origin/master -- csi-spl-rdb csi-spl-api/src | wc -l`
-> 0 on `4c4e97f75`.

1. **Set.** In 182's "Discussion loops" dialog (182 4.1), on a topic the
   author may post in, a "Send to several topics" switch shows the selector
   of 4.2 (ticks and patterns). The loop's home topic is a target always.
   Saved as `targets` on the loop row (7.1.7).
2. **Fire.** The loop fires on its home topic's triggers, as 182 4.2 says.
   Each fire resolves the selector anew, under the loop author's access at
   fire time (so a new topic whose title matches joins, a topic the author
   can no longer read drops out), and runs the check of 7.1.2 for the
   whole set: if any target fails, nothing is sent (Q9 ALL) and the hub
   logs one line naming the loop and the first refusal.
3. **Send.** Per target, the message of 182 4.3 step 2 (`kind: task`, to
   that topic's newest announced agent, hidden by `loop_id`), with
   `mc_id` = UUIDv5 of `(loop_id, the fire's seed)` and `msg_id` = UUIDv5 of
   `(loop_id, the fire's seed, target task_id)`, the seed being 182 4.3
   step 3's. A target with no announced agent is skipped and logged, as 182
   4.3 step 1 does for one topic.
4. **Stop.** As 182 4.5, from the home topic; the cap counts fires, not
   copies.

## 5. Reused, and the gaps

Reused as is: the composer and its file upload, the `send` frame and every
check of `wuiSend` (3.2), the doors (3.3), `ViewTopics` with `Reader` (3.4),
shared blobs (3.5), the per-`msg_id` ack, error frame and resend.

Why N frames and not one `multicast` frame: every check of 3.2 is per
message and per target, and the error frame already names one `msg_id`; a
new frame would have to repeat the chain in a loop and invent a partial
answer. The check frame (7.1.2) is the one new frame: it reads, stores
nothing, and is where patterns become task ids.

| gap | what is missing | row |
|---|---|---|
| G1 | the column that links the copies | M1 |
| G2 | `mc_id` on the frame, the existing-channel-topic check, the cap, the author check, the store write | M2 |
| G3 | the check frame: selector resolution (patterns, `*`), the per-target dry run, the limits | M4 |
| G4 | the composer button, the picker with the Patterns field, the N sends, the result list with Retry | M3 |
| G5 | e2e | M7 |
| G6 | translations, agy's review | M8 |
| G7 | contract and user docs | M9 |
| G8 | the multicast loop | M10 |

## 6. Build order (rows a later lane can take in parallel)

Every row codes against section 7.1, not against another row's branch: the
WUI rows run on the mock client, the hub rows on the store interface. M1,
M2, M3, M4 and M9 can start together; M7 after M3 and M4; M8 after M3 has
landed its en keys; M10 after spec 182's L1 and L2 and this spec's M2 and
M4 have landed. (M5 and M6 were the gathered view and saved groups,
dropped with Q4 GTH and Q1 GRP; the numbers are not reused.)

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| M1 | rdb: `mc_id` and its index | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_mc_id.sql` (head 0298 on `4c4e97f75`; spec 185's F1 and 182's L1 plan the next ones: re-check) | none | applies twice on a throwaway postgres; `\d messages` lists `mc_id uuid` nullable and the partial index | a migration test asserting `mc_id` fails before the file exists |
| M2 | hub: the send-time multicast checks and store | `internal/hub/wui.go` (`wuiIn.McID`, one `wuiMulticast` step after `wuiIDs`), new `internal/hub/wui_multicast.go` + `wui_multicast_test.go`, `internal/store` (postgres + memory: write `mc_id`, `CountMulticast(tenant, mc_id)`, `MulticastAuthor`), cnf `hub.multicast.max_targets` in `csi-spl-cnf/csi-spl/all.env.yaml` | 7.1.1, 7.1.3; M1's file for the postgres test | Go tests on postgres: N frames with one `mc_id` into N readable topics of different channels store N rows with that `mc_id`; each copy routes as 3.2 step 4 (Q5 NRM); an @agent copy into a humans-only channel is a plain post; the (max+1)th copy answers `multicast_too_many`; a resend of a stored copy re-acks, also when that copy is the max-th one (the resend of a stored `msg_id` is exempt from the cap, as from `wuiArchivedRefusal` and `messageQuota`); with the monthly quota set to the stored count + 2, 4 copies store 2 and the other 2 answer the quota token 429; an unpaid tenant answers 402 on every copy; of 3 targets where the middle one is an existing topic of a members-only channel the author is not in, or a DM topic, the first and third are stored and the middle one answers `multicast_no_topic` 404, the same token and detail as an unknown `task_id`, and its error frame names only its own `msg_id` | an unknown `task_id` with `mc_id` must answer `multicast_no_topic` (without the check it opens a topic); a DM topic the author is an end of must answer `multicast_no_topic` (Q8 CHN); a second author reusing the `mc_id` must answer `bad_json`; remove the stored-`msg_id` exemption: the max-th resend answers `multicast_too_many` and the test fails; answer `forbidden` for an unreadable topic: the members-only test fails (it must not say the topic exists) |
| M3 | WUI: button, picker, N sends, results | `components/MessageComposer.vue` (the button, desktop and dock), new `components/MulticastPickerDialog.vue`, new `composables/useMulticastSend.ts`, `stores/channel.ts` (`sendMulticast`, one `sendLive` per target), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`mc_id`, `multicastCheck`), `i18n/locales/*.json` (en + machine drafts) | 7.1.1, 7.1.2, 7.1.4, 7.1.6 | a unit test of the picker rows (channel topics grouped, the lobby and `general` present, `issues` and DM topics absent); a unit test of `useMulticastSend` on the mock: the patterns go to the check verbatim and the WUI evaluates none, Send is disabled while any checked target is not ok, files uploaded once, N frames with one `mc_id` and N `msg_id`s, exactly the check's `task_id`s; the mock socket drops after 2 of 5 frames are acked: the 2 show sent, the 3 others show "waiting for network" (`sendLive` returns `waitForNetwork`, `channel.ts:681,686`), the composer keeps the text until all 5 are acked, and on reconnect the 3 go again under their own `msg_id`s; a send-time refusal lists that target with Retry under the same `msg_id`; a component test at a 390 px viewport opens the picker from the dock; `pnpm run typecheck`; i18n gates | make the mock check refuse one target: Send must stay disabled; evaluate a pattern in JS: the "verbatim" test sees a filtered list and fails; clear the composer on the first ack: the socket-drop test fails; mint a new `msg_id` on the reconnect resend: 7 frames stored, not 5, and the test fails |
| M4 | hub: the check frame | `internal/hub/wui_multicast.go` (`multicast_check` handler, `resolveMulticast`), `wui_multicast_check_test.go` | 7.1.2; `ViewTopics` (3.4) | Go tests on postgres: `*` in a tenant with topics in a public channel, a members-only channel the author is in, one the author is not in, the lobby, `issues`, an archived topic and a DM returns exactly the first two and the lobby one; `^rel` matches "Release 2.0" and not "pre-release"; two patterns and a tick are unioned and deduplicated; a tenant with 450 topics (more than two pages of 200) resolves all 450 under `*`; a bad pattern answers `multicast_bad_pattern` naming its line; max+1 targets, and one target more than the remaining quota, each answer the whole check refused with the count; an archived ticked topic comes back `ok: false` `topic_archived`; no check stores anything (`messages` count unchanged) | stop paging: the 450 test fails; drop `(?i)`: "release" does not match "Release" and the test fails; drop `NoIssues`: the `*` test sees the issue topic and fails |
| M7 | e2e | new `csi-spl-wui/tests/e2e/multicast-prompt.test.mjs` | M3, M4 (mock) | on the generated bundle, mock-served: tick one topic and type `^release` matching two topics in another channel, see "Send to 3 topics", send once, the card appears in all three; a check that refuses one target keeps Send disabled with the reason shown; the same flow at a 390x844 viewport from the dock | the e2e fails when the button is absent |
| M8 | i18n: agy's final review | the 18 non-en locale files, the keys of 7.1.4 | M3 landed | agy review per the language rule; gates green | the untranslated-count gate (`i18n-untranslated.test.mjs`) |
| M9 | docs | `csi-spl-doc/specs/005-spool-wui/spec.md` (an FR for the multicast send: FR-022: FR-020 is the last on `4c4e97f75` and spec 185 row F7 plans FR-021; re-check), `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (section 4: `mc_id` and its refusals; the `multicast_check` / `multicast_checked` frames; `multicast_max` on `welcome`), the user help for the composer (patterns and `*`) | 7.1 | `grep -c -e mc_id -e multicast_no_topic -e multicast_too_many -e multicast_bad_pattern -e multicast_check -e multicast_max csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` -> at least 6 (0 on `4c4e97f75`) | none automatic: no test parses the fields of `wui-live-ws.md`; the reviewer re-runs the grep with one name removed and must see the count drop |
| M10 | rdb + hub + WUI: the multicast loop (Q10 CMP) | `<next>_topic_loops_targets.sql` (7.1.7), the 182 fire path (`resolveMulticast` from M4 per fire), the 182 loop dialog (the switch and the selector), its tests | 4.8, 7.1.7; 182 L1, L2; M2, M4 | Go tests: a loop with `targets` `{"patterns": ["^ops"]}` fires once and stores one hidden `kind: task` per matching topic with one shared `mc_id`; a topic created after the loop was saved whose title matches gets the next fire; a target archived since makes the whole fire send nothing and logs one line; a refire for the same seed is a no-op (UUIDv5 ids) | resolve the targets at save time instead of fire time: the new-topic test fails; send what passes: the archived-target test sees N-1 rows and fails |

## 7. Contracts

### 7.1 Binding contracts for the parallel rows

#### 7.1.1 The send frame (wui-live-ws section 4)

One frame per target, the frame the WUI sends today for a post in that
topic, plus one field:

```
{ "type": "send",
  "msg_id": "<uuid, client-minted, one per copy>",
  "task_id": "<the target topic's task_id, from the check>",
  "kind": "note", "body": "<the text>", "files": [ <the same refs on every copy> ],
  "channel": "<the target topic's channel>",
  "is_parent": 0,
  "mc_id": "<uuid, client-minted, the same on every copy>" }
```

- `to` / `to_box` as the WUI sends them today for that topic; a leading
  @mention in the body dispatches in every copy, as it would in each single
  post (Q5 NRM).
- `mc_id` must be a UUID (`bad_json` 400). A frame without `mc_id` is an
  ordinary send, unchanged. Patterns never travel on a send frame.
- With `mc_id`, `is_parent` must be 0 and the `task_id` must hold an
  existing channel topic the author may read (`canReadTopic`), else
  `multicast_no_topic` 404 (Q2 EX, Q8 CHN). An existing topic the author
  may not read, and a DM topic, answer the same token and detail as an
  unknown one: the refusal never says the topic exists (the 404 rule of
  3.3). Its error frame names its own `msg_id` only; the other copies are
  untouched.
- An `mc_id` already stored with another `from` is refused `bad_json` 400.
- The copy that would make the stored copies of this `mc_id` exceed
  `hub.multicast.max_targets` is refused `multicast_too_many` 400. The
  resend of a `msg_id` already stored is exempt (it adds nothing, and its
  ack may be all the WUI is missing), as in `wuiArchivedRefusal`
  (`topic_archived_input.go:45-61`) and `messageQuota` (`ws.go:914-938`):
  look the `msg_id` up first, count only for a new one.
- The cap is hub cnf `hub.multicast.max_targets`, default 1000 (R2); the
  WUI reads it from the `welcome` frame (`multicast_max`).
- Every existing refusal of `wuiSend` applies to each copy unchanged
  (`topic_archived`, `unknown_channel`, `forbidden`, `402 unpaid`, `429
  quota`: each copy counts as one message in `admit`; `missing_file`, the
  token budget, the demo checks). The ack is the existing ack.

#### 7.1.2 The check frame (Q9 ALL, Q6)

```
{ "type": "multicast_check", "req_id": "<uuid>",
  "task_ids": ["<ticked task_id>", ...], "patterns": ["*" | "<RE2>", ...],
  "files": [ <refs> ], "body": "<the text>" }
->
{ "type": "multicast_checked", "req_id": "<same>",
  "ok": true|false, "error?": "<token>", "detail?": "<text>",
  "targets": [{ "task_id", "channel", "title", "ok": true|false, "error?": "<token>" }] }
```

- `task_ids` at most `multicast_max`, `patterns` at most 10 of at most 256
  bytes; both may be empty, not both (`bad_json` 400).
- Resolution (`resolveMulticast`): pages `ViewTopics` with `Reader` = the
  author, `ReaderChannels`, `NoIssues`, `DM` false, until the end (3.4);
  keeps a topic when `*` is a pattern, or a pattern `(?i)<p>` matches its
  `subject`, or its `task_id` is ticked; drops topics in channels where the
  author lacks `notes.send`. A ticked `task_id` not in that set is listed
  `ok: false` `multicast_no_topic`.
- Per target it runs the read-only checks of 3.2 steps 4 and 5 for a copy
  of this `body` and `files` (archived, moved, door, `notes.send` /
  `agents.command`, billing, `missing_file`, token budget when an agent will
  act), and the quota once for the whole count.
- The whole check is `ok: false` with `error` = `multicast_bad_pattern`
  (detail: the line), `multicast_too_many` (detail: the count and the cap),
  the quota token (detail: the count and the remaining messages), or
  `multicast_none` (no target); `targets` is then as far as resolution got.
  Otherwise `ok` is true only when every target is ok.
- It stores nothing and sends nothing to any box. Its `req_id` lets the WUI
  drop an answer to an older check.
- It is a promise for the moment it runs: the send frames are checked again
  one by one (7.1.1, 4.4).

#### 7.1.3 The stored copy

v:1 unchanged: `from` = author, `to` = what 3.2 step 4 resolves for that
topic, `kind` = `note`, `body` and `files` = the frame's. The hub column
`mc_id` (rdb `<next>_messages_mc_id.sql`: `mc_id uuid NULL`, no default, no
FK; `CREATE INDEX IF NOT EXISTS messages_mc_id ON messages (tenant_id, mc_id) WHERE mc_id IS NOT NULL`;
catalog-only, RLS unchanged) is on neither the view row nor the `message`
frame (Q4 OWN), and never inside the v:1 object (`Parse` refuses an unknown
key, spec 185 3.8). After the store, the fallback and the three notes of
3.2 step 6 run per copy, as for any post.

#### 7.1.4 The WUI keys

New i18n keys (en text): `composer.multicast` "Send to several topics",
`composer.multicast_title` "Send to topics", `composer.multicast_patterns`
"Topic title patterns, one per line; * = every topic",
`composer.multicast_count` "{n} topics", `composer.multicast_send` "Send to
{n} topics", `composer.multicast_max` "At most {max} topics",
`composer.multicast_bad_pattern` "Pattern {line} is not valid: {reason}",
`composer.multicast_sent` "Sent to {n} topics",
`composer.multicast_refused` "Not sent to {topic}: {reason}",
`composer.multicast_retry` "Retry", `composer.multicast_none` "No topic
matches". Every key in all 19 locale files (`i18n-parity.test.mjs`).

#### 7.1.5 (dropped with Q4 GTH)

#### 7.1.6 The picker

Rows, one list, filtered by one query, grouped by channel:
`{kind: 'topic', id: task_id, channel, title}` for the topics of every
channel the author may read except `issues` (not `moveChannelTargets`,
which also drops the lobby and `general`, 3.4), read as
`MovePickerDialog.load` reads them. No `dm` rows (Q8 CHN). Archived topics
are not listed. The open topic is preselected. The filter only narrows the
rows shown; the Patterns field is the selector (4.2), and the count, the
targets and Send come from the last `multicast_checked`.

#### 7.1.7 The loop targets (Q10 CMP, M10)

`<next>_topic_loops_targets.sql`: `ALTER TABLE topic_loops ADD COLUMN IF
NOT EXISTS targets jsonb NULL` (NULL = a one-topic loop, as 182). Shape:
`{"task_ids": [...], "patterns": [...]}`, the limits of 7.1.2. 182's
`POST`/`PUT /v1/topics/{task_id}/loops` accept `targets`; a bad pattern
answers `multicast_bad_pattern` 400 at save. Resolution and checks per fire
as 4.8.

## 8. Related specs

### 8.1 Spec 185 (forward), where multicast differs

Both post into existing topics over the `send` frame, keep every check of
`wuiSend` and store a hub-only marker column (`fwd_of`, `mc_id`). They
differ:

| | forward (185) | multicast (186) |
|---|---|---|
| the text | someone's card, copied by the hub from `forward_of` | the author's own, in the frame |
| targets | one | ticks plus title patterns, `*` = all (4.2) |
| @mentions in the body | not read (185 Q6) | read as the author's own (Q5 NRM) |
| after-store notes | skipped (185 7.1.3) | run per copy |
| widening confirm | yes, a DM or members-only source | none: the author already writes there |
| DM targets | per 185 | none (Q8 CHN) |

A later lane may share one helper for "the target topic must exist and be
readable" (185's `forward_no_topic`, 186's `multicast_no_topic`); whichever
lands first owns it, the other calls it.

### 8.2 Spec 182 (topic loop prompt)

182 repeats a prompt in time inside one topic; multicast sends one prompt
across topics once. Q10 CMP joins them: the multicast loop (4.8, M10,
7.1.7) is a 182 loop with `targets`. A copy of a one-off multicast is a
normal post in its topic, so a loop there whose triggers include a human
post fires on it as on any post.

## 9. Not in this spec

- Targets in another workspace (the socket is bound to one tenant).
- DM topics as targets (Q8 CHN).
- A multicast from an agent, the box socket or the `spool` CLI.
- Editing or deleting all copies at once: each copy is edited or deleted on
  its own card, as today.
- Multicasting an existing card (that is a forward, spec 185).
- A view that gathers the copies and their replies (Q4 OWN).
