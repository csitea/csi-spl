# Spec 186: Multicast Prompt

Status: **Draft v0.6, the owner's select-then-Multicast flow** (2026-11-24). v0.1
`83295f6d1`; v0.2
`b53947cee` folded the spec review's W1-W6 and N1; v0.3 (`a86daa6c5`) folds
the owner's answers to form `e864b1cb` (Q1-Q5, Q7-Q11, msg `dcf298b8`) and
the Q6 chat answer (msg `1b95d0ec`), and drops every part only an unchosen
answer needed; v0.4 (`cbbc11996`) folds the v0.3 delta review (c-240, msg
`9598398d`: W1-W5, N1-N6) and put R2 (the cap) and R3 (the phone entry) to
the owner as form `a07226d8` (t1 `032d8010`); v0.5 folds the owner's answers
(msg `ee9b2558`: R2 **QTA**, R3 **ATT**), drops the target cap with every
part only it needed (`hub.multicast.max_targets`, `multicast_too_many`,
`multicast_max`), and folds the v0.4 review's notes (c-240, msg
`d12953b2`: N1 the R2/R3-dependent spots, N2 the box-lock filter's row
type, 7.1.2). v0.6 folds the owner's 2026-11-24 redesign (msgs
`5fdfff6c`, `656b2576`, `4b3833e7`, and the addendum `ae2caeb2`): the
targets are no longer picked from the composer. Step 1 is a **select
phase**: topics are ticked in a topic list the way issues are ticked, also
by criteria and by title pattern; step 2 is a **Multicast** button in the
selection bar, beside the other bulk actions as Archive is on issues, that
opens the prompt for the selected topics. Every composer entry is dropped
(R3 ATT, the desktop button beside Attach, the phone long press); the
select phase is one shared component whose second user is spec 153's
priority action (section 8.3). Versions: section 10. Open questions for
the holder: section 11.
v0.1-v0.5: lane `c-098`. v0.6: lane `c-038` (`claude`, backup for
`specs_and_docs`: agy on its usage limit), placement
`c002-s186-v06-select-multicast`.
Epic: **SPL-2403**. Issues: **SPL-6058** (v0.1-v0.5), **SPL-6360** (v0.6).
Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:032d8010-f150-4125-b1c2-70e503b1a450` (`t1`).
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the composer),
[185 forward a message card](../185-message-forward/spec.md) (one card into
another topic over the same `send` frame; section 8.1 says where multicast
differs), [045 move by drag](../045-spool-move-by-drag/spec.md) (the topic
picker) and [182 topic loop prompt](../182-topic-loop-prompt/spec.md) (the
multicast loop, 4.8).

Line references were measured on `origin/master` `adcd75dbb` (v0.1) and
re-checked on `4c4e97f75` (v0.3): since `adcd75dbb` the only change in the
files cited here is `csi-spl-wui/src/public/help-md/how-to-post.md`. The
references v0.4 adds (the box lock, the phone dock, the rdb head) were read
on `7df5cecfc`; the ones v0.5 adds (the quota, the Attach button, the
phone e2e tests that tap it, `keepTopics`, `TopicRow.Parties`) on
`2500f49fc`; the ones v0.6 adds (the issues list's multi-select, the
event log's bulk bar, the topic card and its menu, the topic lists, the
socket's frame switch) on `387370a79`.

## 0. The owner's words (HUM-10, t1 topic 032d8010)

Msg `f7782824`, verbatim: "multicast prompt feature - I would like to be able
to write a single prompt to multiple topics from multiple channels within a
workspace"

Msg `1b95d0ec` (answer to Q6, "How many topics at most per multicast?"),
verbatim: "well I should be able to specify regexes for the topics titles
and * should be multicast to all" (as the dispatch holder relayed the hub
row, c-002 msg `1ab08343`; the topic is not readable from this box)

Msg `ee9b2558` (20:51:09Z, form `a07226d8`), as the dispatch holder
c-003@sat relayed it (msg `37cdfda8`): "Answer 1: ATT — Inside the Attach
sheet; the dock row stays Back | Attach | Send" and "Answer 2: QTA — No cap:
only the existing per-sender quota counts each copy".

Owner, HUM-10, t1 `032d8010`, 2026-11-24, verbatim (these override every
entry point decided before them):

- 07:12:47Z msg `5fdfff6c`: "The multi-cast feature should work so that
  one should be able to select a list of message topics in the topics list
  view or in the channels view (the same way one is able to select multiple
  issues). Once the issues are selected by certain criteria, then there
  should be the button "multicasts", the same way it is done for, for
  example, the archive button on the issues."
- 07:13:09Z msg `656b2576`: "which overrides my previous requests for
  keeping longer. Press the play button and separate control for the whole
  thing on the UI on the desktop."
- 07:13:30Z msg `4b3833e7`: "First, the select phase, which also should
  enable the selection by regexes, and then the multicast play button."
- Still standing: 07:05:19Z poll `e722e403`, answer A (msg `a158a4fd`): a
  build round for M1-M9 follows this spec (a planner).

Owner addendum, HUM-10, t1 `906c1b28`, 08:34:27Z, msg `ae2caeb2`,
verbatim: "this could be combined with the implementation of the multicast
feature - first pre-select list of topics similarly how the issues are
selected ... check that discussion latest 2 comments of mine". The dispatch
holder's reading (c-002): the select phase is ONE shared selection; spec
186's Multicast and spec 153's priority setting are two bulk actions on it,
built once (section 8.3).

Superseded, kept as history only (R3, section 1): msg `ee9b2558` R3 **ATT**
(the Attach sheet row); 07:04:46Z msg `fe3ced5e` (a long press on the play
button on a phone); 07:04:57Z msg `afc6f1d7` (a separate desktop control
beside the composer).

These words were relayed by the dispatch holder in the lane brief; this
lane did not read the t1 rows itself.

Read as: the author first SELECTS several topics, from any channels of the
same workspace, by ticking them in a topic list, by the list's criteria, or
by title regexes (`*` = every topic); a Multicast button in the selection
bar then opens one prompt (ONE text, with files, if any), and the hub posts
it into each selected topic. Nothing named multicast exists today:
`git grep -n -i multicast origin/master -- csi-spl-wui/src csi-spl-api/src csi-spl-cnf | wc -l` -> 0.

## 1. Decided (form `e864b1cb`, msgs `dcf298b8` and `1b95d0ec`)

| Q | Question | Answer |
|---|---|---|
| Q1 | How are the target topics picked? | **MSL** — a multi-select over the topics of every channel you may post in, with a filter; since v0.6 (S1) the multi-select is the topic lists' select phase, not a picker dialog |
| Q2 | Which topics can be targets? | **EX** — existing topics only |
| Q3 | What does each topic get? | **LNK** — one ordinary post per topic, linked by a hidden shared multicast id |
| Q4 | Where are the replies read? | **OWN** — each topic on its own, as any post |
| Q5 | Do agents act on the copies? | **NRM** — each copy is a normal post: the topic's agent, the channel's agents and a leading @mention get it |
| Q6 | How many topics per multicast? | **Regexes on topic titles; `*` = every topic** (chat answer; section 4.2) |
| Q7 | Attachments? | **SHR** — allowed: uploaded once, the same files on every copy |
| Q8 | Members-only channels and DMs as targets? | **CHN** — channel topics only (public and members-only), no DMs |
| Q9 | Some targets refuse: what happens? | **ALL** — nothing is posted unless every target passes a pre-check |
| Q10 | Does it compose with loops (spec 182)? | **CMP** — also a "multicast loop": one loop whose prompt goes to several topics |
| Q11 | Where is it offered? | **BTH** — desktop and phone; since v0.6 (S1) the same flow on both, from the selection bar, not from the dock |
| R2 | A target cap? (form `a07226d8`, msg `ee9b2558`) | **QTA** — no cap: only the existing quota counts each copy |
| R3 | The phone entry? (form `a07226d8`, msg `ee9b2558`) | ~~**ATT** — inside the Attach sheet~~: **superseded** by S1 (v0.6); so are msgs `fe3ced5e` (phone long press) and `afc6f1d7` (desktop control beside Attach) |
| S1 | The flow (msgs `5fdfff6c`, `656b2576`, `4b3833e7`, 2026-11-24) | **SEL** — select topics in a topic list as issues are selected (ticks, criteria, title regexes), then a **Multicast** button in the selection bar opens the prompt; no composer entry |

Dropped with the unchosen answers: saved target groups (Q1 GRP/BTH), the
"new topic in #channel" row (Q2 NEW), unlinked copies (Q3 IND), the gathered
"Multicast" view (Q4 GTH), the MEN/NON agent rules (Q5), DM targets (Q8),
the send-what-passes path (Q9 SND), the fixed caps 10/25/50 (Q6), the cnf
guard and the confirm above N (R2 CNF/ASK), the topic-header button and the
fourth dock button (R3 HDR/DCK). Dropped in v0.6 by S1: every composer
entry, i.e. the Attach sheet (R3 ATT, `AttachSheet.vue`,
`composer.attach_files`), the desktop button beside Attach, the phone long
press on Send (msg `fe3ced5e`, never in a landed version) and the picker
dialog of v0.5 4.1 / 7.1.6 (its list becomes the select phase).

One reading this spec decides (the v0.3 review confirmed it), the two
owner answers to the v0.4 questions, and the v0.6 flow:

- **R1, decided.** `*` covers every channel topic the author may post in,
  the lobby and `general` included ("* should be multicast to all" plus Q8
  CHN), and leaves out the `issues` channel: an issue's discussion is that
  issue's comment thread, never a topic of a list
  (`TopicQuery.NoIssues`, `internal/store/view.go:43-45`), so a title
  pattern cannot name it and the select phase cannot tick it.
- **R2, decided: QTA, no target cap.** Nothing counts targets: no cnf key,
  no cap refusal, no limit on the `welcome` frame. The one limit is the
  existing monthly message quota, and each copy counts as one message in
  it (`admit`, 3.2 step 5), so a multicast larger than the remaining quota
  is refused whole at the check (Q9 ALL on the existing quota, 4.2). The
  form's words say "per-sender quota"; the quota that exists is per
  workspace: `messageQuota(ctx, tenant, msgID)` counts
  `CountMessagesSince(ctx, tenant, ...)` (`internal/hub/ws.go:918-938` on
  `2500f49fc`), and no per-sender message quota exists
  (`git grep -n -i -E 'sender.?quota|quota.?per.?sender' origin/master -- csi-spl-api/src csi-spl-cnf | wc -l`
  -> 0). This spec reuses that quota as it is and adds none. A `*`
  multicast loop with `daily_at` sends one `kind: task` per target per
  fire, each counted in that quota, while 182's stop cap counts fires (4.8
  step 4).
- **R3, superseded (history).** v0.5 decided ATT (msg `ee9b2558`): docked,
  Attach opened a sheet of "Files" and "Send to several topics", and on the
  desktop a multicast button sat beside Attach. On 2026-11-24 the owner
  first moved the phone entry to a long press on the play (Send) button
  (07:04:46Z msg `fe3ced5e`) with a separate desktop control (07:04:57Z msg
  `afc6f1d7`), then replaced both eight minutes later by S1 (msg
  `656b2576`: "which overrides my previous requests for keeping longer").
  None of the three reached master as code. A draft of the long-press
  design (branch `review/c002-s186-v06-phone-longpress-send`, `97c48803f`)
  was written before S1 and is not landed.
- **S1, decided: SEL, select then Multicast** (msgs `5fdfff6c`,
  `656b2576`, `4b3833e7`). The composer is not touched: the phone dock row
  stays Back | Attach | Send (topic `d4bc9db4`,
  `MessageComposer.vue:270-275`; `csi-spl-wui/tests/e2e/dock-buttons.test.mjs:158`
  and `tests/unit/touch-ui.test.mjs:235-238` keep asserting it), Attach
  keeps opening the OS picker at once, docked or not, and the three phone
  e2e tests that tap Attach (`composer-buttons-bottom.test.mjs:121-128`,
  `mobile-rail-whole-icons.test.mjs:254-259`,
  `snackbar-top-mobile.test.mjs:137-140`) stay as they are. The flow is
  the issues list's (3.6): tick topics, the selection bar replaces the
  list's header, and its **Multicast** button (beside the bulk actions)
  opens the prompt (4.1). The owner's "multicast play button" (msg
  `4b3833e7`) is that prompt's Send. Same on desktop and phone (4.6).

## 2. Terms

| term | meaning |
|---|---|
| multicast | one prompt sent into several target topics |
| select phase | the shared topic multi-select of the topic lists (4.1, 7.1.6): ticks, criteria and title patterns; its bulk actions are Multicast (this spec) and Set priority (spec 153, 8.3) |
| selection | the `task_id`s the select phase holds; the targets of a bulk action |
| selection bar | the bar that replaces a topic list's header while the selection is not empty, as `IssuesBulkBar.vue` does (3.6) |
| selector | what picks the topics: ticked topics plus title patterns (4.2) |
| pattern | a topic-title regex, or the line `*` = every topic in scope |
| target | a channel topic the selector resolved to |
| copy | the post the hub stores in one target |
| multicast id | `mc_id`, a client-minted UUID shared by every copy of one multicast, stored on each copy (7.1.3) |
| author | the signed-in member who selects and sends; the `from` of every copy |

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
  (`--composer-dock-h`, `MessageComposer.vue:995`), and its button row is
  the owner's Back | Attach | Send (R3). Attach calls `openFiles`
  (`MessageComposer.vue:288-300`, `useComposerFiles`), which opens the
  hidden file input at once, docked or not.
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
  them). Single pick; it closes on the pick (`:129-141`). No topic list
  has a multi-select; the issues list and the event log do (3.6).
- The topic lists a member sees (measured on `387370a79`). The Topics
  page is gone (owner, t1 `e4bfddb1`, msg `a78e06c8`: "Remove the whole
  topics view"; `csi-spl-wui/src/pages/index.vue:1-4`). What lists topics
  now: a channel's page, `pages/channel/[name].vue:3-4` = `FeedHeader` +
  `MessageFeed` -> `LiveFeed` -> one `MessageCard` per topic opener
  (`LiveFeed.vue:83`), with spec 150's Filter New/All and Sort in the
  header (`components/TopicListControl.vue:1-12`, `FeedHeader.vue:47`);
  the DM and lobby pages reuse that feed. And Monitoring -> Topics (spec
  153 3.10, `pages/monitoring/topics/index.vue:1-11`): one narrow row per
  topic with lane activity, from every workspace the reader may see, a
  title linked only "when it is this workspace's topic", column filters
  in a sheet (`SheetHead.vue`, `SheetPhoneBar.vue`).
- A topic card already owns the touch gestures: a long press opens its
  menu (`useCardLongPress`, `MessageCard.vue:778`; menu `LazyMessageMenu`,
  `:410-447`), a left swipe archives the topic and a right swipe opens the
  menu (`MessageCard.vue:38-41`, owner t1 `2d09e9c2`), and the first ~3 mm
  is the move handle (`:54-56`, spec 045).
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

### 3.6 The issues list's multi-select (the model, owner msg `5fdfff6c`)

Owner HUM-10, t1 `53ab04e7`, msg `14b0e604`: "the issues listing should
have checkboxes to perform multiple actions the same way as in gmail".
Measured on `387370a79`:

- **Row box.** Each issue row has a checkbox
  (`csi-spl-wui/src/pages/issues.vue:409-418`, `data-test=issues-row-check`);
  a shift-click checks the run from the last box clicked, `x` the focused
  row, Esc clears (`composables/useIssueBulk.ts:8-16`).
- **Selection bar.** With one row checked, `IssuesBulkBar.vue` (lazy) takes
  the list header's place (`pages/issues.vue:12-31`;
  `components/IssuesBulkBar.vue:1-9`): the page box (all / some / none of
  the rows shown), the count, the bulk buttons Status, Assignee, Move to,
  **Archive**, Delete (`IssuesBulkBar.vue:90-96`; Archive `:94`) and Clear.
  After a page-wide check Gmail's line offers "Select all N matching"
  (`:98-103`), i.e. every row the filters match, loaded or not.
- **Criteria.** The selection is made under the list's filters (status,
  priority, level, label: `pages/issues.vue:218-256`); "another filter is
  another list: nothing stays checked" (`useIssueBulk.ts:30-31,65`).
- **The run.** No bulk route on the hub: per-item calls, at most
  `BULK_PARALLEL` at a time (`utils/issues-bulk.ts:80`, `runBulk`), a
  progress line and a result line naming the failed keys
  (`IssuesBulkBar.vue:52-56`). Archive and Delete confirm first
  (`useIssueBulk.ts:55,146`).
- **Phone.** The same bar and boxes; the buttons show icons only, the
  names on `aria-label` and `title` (`IssuesBulkBar.vue:38,43`).
- **Pure helpers**, keyed by strings, not by issues: `toggleKey`,
  `rangeSelect`, `pageState`, `toggleAll`, `keepShown`, `runBulk`
  (`utils/issues-bulk.ts:20,34,47,56,68,80`).
- **A second copy exists.** The event log's bar (`components/EventsBulkBar.vue:1-7`,
  spec 162 B7) re-draws the same bar for one action. The select phase of
  this spec is built once and reused (4.1, 8.3), not copied a third time.

## 4. The flow end to end

### 4.1 Select, then Multicast (S1)

**Step 1, the select phase** (shared, 7.1.6; Q1 MSL, Q8 CHN).

1. **Where.** A channel's topic list (the "channels view": each topic card
   of `LiveFeed`, 3.4) and Monitoring -> Topics (the "topics list view",
   spec 153 3.10), on rows of the author's own workspace only: another
   workspace's row shows no box, and its `title` says why (3.3: a
   multicast cannot cross workspaces). Not in DM lists (Q8 CHN), not in
   `issues` (R1). Question H1 (section 11) asks the holder to confirm
   these two places.
2. **Ticks.** Each topic card or row carries a checkbox at its start, as
   an issue row does (3.6): a click toggles, a shift-click checks the run
   from the last box clicked, `x` the focused card, Esc clears. On a
   desktop the box shows on hover and on focus, and on every card once one
   topic is ticked, so an unticked feed reads as today (question H3).
3. **Criteria.** The list's own filters narrow what is shown (the channel
   page's Filter New/All, Monitoring -> Topics' column filters); the page
   box ticks every topic shown, and Gmail's line then offers "Select all
   N matching" (3.6). On a channel's topic list the filter also holds the
   **title search** (item 4), and the header's **select tick** (row 2,
   while nothing is ticked) ticks exactly the topics listed: all of them
   with no filter, only the filtered ones with a filter (owner HUM-10, t1
   `f7b53cf8`, 2026-11-26, msg `5b8f9db2`: "make the search by title part
   of the filter and the select the one which actually selects either all ,
   but the already listed / filtered"; SPL-6613). A filter change does NOT clear the selection, unlike
   the issues list (3.6): the selection spans channels, so moving from one
   channel's page to another keeps it (question H2). It is kept for the
   session in one store per workspace and cleared by Clear, by a finished
   bulk action, or by switching workspace.
4. **By title pattern** (Q6, msg `4b3833e7`; a filter since SPL-6613,
   msg `5b8f9db2`). The channel topic list's Filter popover (the funnel,
   beside New / All) has a "Topic title" field: one pattern, the RE2 rules
   of 4.2, `*` = every topic in scope. 300 ms after the last key it sends
   one `topic_select` frame (7.1.2) with the text as typed; the hub
   resolves it and returns the explicit `task_id`s, and the list keeps only
   those topics (New and the sort still apply). The WUI never evaluates a
   pattern. A bad pattern names its line under the field and ends the
   title filter; an empty field ends it too. The answer narrows the list,
   it does not join the selection: the select tick then ticks the topics
   listed. The filter icon's dot shows while the title narrows the list.
   The field is on a channel's topic list only (not the lobby or a DM) and
   only where `topic_select` can be sent (R7 W1); it lives while the
   page's header does. The bar and the header have no "Select by title"
   button. `TopicSelectPatterns.vue` (the multi-line pattern box) stays
   for the multicast loop's field (4.8, M10).
5. **The selection bar.** While the selection is not empty the bar takes
   the list header's place, as `IssuesBulkBar` does (3.6): on a channel
   page first the list's filter and sort (so the title filter of item 4
   stays usable while topics are ticked; SPL-6613), the page box (it ticks
   the topics listed), "n selected" (with "in k channels" when k > 1), the
   bulk buttons, Clear. Its buttons come from a list each bulk action adds
   itself to; this spec adds **Multicast**, spec 153 adds **Set
   priority** (8.3). A progress line and a result line, as on issues,
   belong to the bar; the action fills them.

**Step 2, Multicast** (the button "multicasts" of msg `5fdfff6c`).

1. **The prompt.** Multicast opens a dialog titled "Send to n topics": the
   selected topics, grouped by channel, each with a remove cross, and
   a composer (above or below them, see below), the same text field, @mentions and Attach as the
   page composer (an instance of `MessageComposer` whose `send` emit the
   dialog handles, so the page's own composer is not changed; question
   H5). Its Send button, the owner's "multicast play button" (msg
   `4b3833e7`), reads "Send to n topics".
   The composer's place follows the person's Settings -> Behaviour
   "Message order", read live: newest first (prepend, the default) puts it
   ABOVE the target list, newest last (append) BELOW it, on desktop and
   phone alike (owner HUM-10, t1 `c9b86153`, 2026-11-26: "the multicast
   prompt should be on top of the topics to multicast to based on the
   pre-pend or append order of the person in his personal settings";
   SPL-6603, test `csi-spl-wui/tests/e2e/multicast-composer-order.test.mjs`).
2. **Preview.** On open, and on every change of the list, the text or the
   files (debounced 300 ms), the dialog sends one `multicast_check` frame
   (7.1.2) naming the selected `task_id`s. Its answer is each target with
   ok or the refusal token; the dialog shows "n topics" and the refused
   ones with their reason; an answer whose `req_id` is not the newest sent
   is dropped (7.1.2). Send is enabled only when the check returned `ok`
   for every target (Q9 ALL) and n >= 1; a refused target can be removed
   from the list with its cross, which re-runs the check.
3. **Send** as 4.3; results as 4.4. When every copy is acked the dialog
   closes and the selection clears.

### 4.2 The selector: ticks and title patterns (Q6)

- The title field of the topic list filter (4.1, step 1 item 4; the loop's
  pattern box, 4.8, takes several lines) takes one pattern per
  line, at most 10 lines, each at most 256 bytes. The hub trims each line (Go `strings.TrimSpace`) before
  anything else and drops a line that is then empty.
- The trimmed line `*` means every topic in scope, so ` * ` does too.
  (`*` alone is not a valid RE2 pattern, so it cannot mean anything else;
  untrimmed, ` * ` would compile and match every title with a space.)
- Any other line is an RE2 regex (Go `regexp`), matched case-insensitively
  (the hub prefixes `(?i)`) and unanchored (`MatchString`: a match anywhere
  in the title) against each topic's title (3.4). `^release` anchors.
  A line that does not compile refuses the check with
  `topic_select_bad_pattern` 400, naming the line.
- **Scope**, the same for ticks, patterns and `*`: the channel topics of the
  author's workspace in channels the author may read (`canReadChannel`)
  and, for the action the frame names, may act in (Multicast:
  `notes.send`, 3.2 step 4; spec 153's priority: its own permission,
  8.3), not archived, not in `issues` (R1), and
  not hidden from the author by the box owner lock (row B5: a topic that
  touches a box locked to someone else reads as absent, `topicDoor`,
  `internal/hub/privacy.go:145-150`; on a list,
  `lockViewFor(...).keepTopics`, `internal/hub/view.go:776-781` and
  `box_lock_view.go:313-333`, the lobby exempt). The lobby and `general`
  are in scope (R1). A hidden topic is never resolved, so its title never
  comes back in any answer: a pattern is not a title oracle.
- The targets are the union of the ticked topics and every in-scope topic a
  pattern matches, deduplicated by `task_id`. A ticked topic out of scope
  is left out by `topic_select` and answers `multicast_no_topic` in
  `multicast_check`.
- **The hub alone resolves patterns**, in `topic_select` (7.1.2), and
  returns the explicit list, which joins the selection. The check and the
  send then name each target's `task_id` (7.1.1), so what is posted is
  exactly the list the author saw. A topic opened after the pattern was
  applied is not selected; applying the pattern again picks it up.
- **Limit** (R2 QTA): no target count. More targets than the tenant's
  remaining monthly messages (`messageQuota`) refuse the whole
  `multicast_check` with the quota token, saying the count and the remaining messages, so the
  author narrows the selection. An unlimited quota (`MessagesPerMonth` <= 0)
  refuses nothing.

### 4.3 Send

1. The dialog uploads the files once (`toFileRefs`, Q7 SHR), mints one
   `mc_id` and, per target of the last check, one ordinary `send` frame
   (7.1.1) with its own `msg_id`, at most 4 in flight. Each copy is the
   author's post into that topic: the same body, files and kind `note`.
2. **Hub, per frame.** The whole chain of 3.2, unchanged, plus the
   multicast checks of 7.1.1: the target topic exists, is a channel topic
   and the author may read it (`multicast_no_topic`, Q2 EX, Q8 CHN); the
   `mc_id` belongs to this author (`bad_json`). No count of the copies of
   one `mc_id` (R2 QTA): each copy passes the quota in `admit` as any
   post. The copy is stored with `mc_id` (Q3 LNK).
3. **Fan-out, per copy** (Q5 NRM): as any post of the author in that topic:
   `topicReplyAgent`, the channel's agents via `routeChannel`, a leading
   @mention dispatch; a paused topic's agents get nothing (spec 179); an
   @mention in a humans-only channel is a plain post. The after-store notes
   run per copy: the text is the author's own words (unlike a forward, 185
   7.1.3).

### 4.4 Results

The dialog shows one line per target as its ack or error frame arrives
(matched by `msg_id`). It closes, and the selection clears, when every
target is acked. The pre-check
makes a refusal at send time rare but not impossible (the topic archived,
the quota spent, or a membership lost between check and send): then the
dialog stays open, keeps the text, lists the refused targets with the token's reason
and offers Retry for them under the same `msg_id`s (a resend of a stored
copy only re-acks). Copies already stored stay: Q9 ALL is a promise of the
check, not a transaction across N topics (7.1.2).

### 4.5 Replies (Q4 OWN)

Each topic is answered on its own, as any post. Nothing gathers the
replies; `mc_id` is on neither the view row nor the `message` frame.

### 4.6 Phone (Q11 BTH, S1)

The same two steps as on a desktop. The composer and its dock row (Back |
Attach | Send) are not touched.

- **Entering the select phase.** A topic card's menu (opened by a long
  press or a right swipe, 3.4) gets a first item "Select", which ticks
  that topic. A Monitoring -> Topics phone card has no menu
  (`grep -c -i menu csi-spl-wui/src/pages/monitoring/topics/index.vue`
  -> 0 on `387370a79`), so there its box shows at the card's start
  always. While the selection is not empty every card shows its box, a tap
  on a card toggles it instead of opening the topic, and the swipes and
  the move handle are off until the selection is empty (question H4).
- **The selection bar** takes the header's place at the top, as the
  issues list's does on a phone (3.6): icon buttons, each name on
  `aria-label` and `title`: the page box, the count, Multicast, Clear
  (the title search is in the Filter popover, SPL-6613).
- **Moving between channels** (the Channels list, the left panel) keeps the
  selection (4.1, step 1 item 3); the bar shows on every channel page of
  that workspace while the selection is not empty.
- **Multicast** opens the dialog as a full-screen sheet: the selected
  topics, then the composer at its foot with its own Attach and "Send to
  n topics"; Back closes the sheet and keeps the selection; the result
  lines replace the list.

### 4.7 Not changed

Editing or deleting a copy is done on that copy's card, as today; a copy is
a normal post for loops, search, export and archive.

### 4.8 The multicast loop (Q10 CMP)

A spec 182 loop whose prompt goes to several topics. It needs 182's loops
on master first: `git grep -n topic_loops origin/master -- csi-spl-rdb csi-spl-api/src | wc -l`
-> 0 on `4c4e97f75`, 40 on `2500f49fc` (182's L1, `0301_topic_loops.sql`,
landed; M10 also needs 182's L2, section 6).

1. **Set.** In 182's "Discussion loops" dialog (182 4.1), on a topic the
   author may post in, a "Send to several topics" switch shows the
   selector of 4.2: the select phase's current selection as the ticks
   (empty when nothing is selected) and the select phase's pattern field,
   whose patterns are stored unresolved. The loop's home topic is a target
   always. Saved as `targets` on the loop row (7.1.7).
2. **Fire.** The loop fires on its home topic's triggers, as 182 4.2 says.
   Each fire resolves the selector anew, under the loop author's access at
   fire time (so a new topic whose title matches joins, a topic the author
   can no longer read drops out), and runs the check of 7.1.2 for the
   whole set. A target with no announced agent is a failed target of that
   check (`loop_no_agent`; 182 4.3 step 1 skips such a fire for one
   topic). If any target fails, nothing is sent (Q9 ALL, no partial fire)
   and the hub logs one line naming the loop and the first refusal.
3. **Send.** Per target, the message of 182 4.3 step 2 (`kind: task`, to
   that topic's newest announced agent, hidden by `loop_id`), with
   `mc_id` = UUIDv5 of `(loop_id, the fire's seed)` and `msg_id` = UUIDv5 of
   `(loop_id, the fire's seed, target task_id)`, the seed being 182 4.3
   step 3's.
4. **Stop.** As 182 4.5, from the home topic; the cap counts fires, not
   copies, so a fire of a `*` loop sends one message per target, each
   counted in the monthly quota; a fire whose targets exceed the remaining
   quota fails whole at step 2's check (R2 QTA).

### 4.9 The Omnibox's send with 2+ ticked (the second path)

Owner HUM-10, t1 #spool-hub-ui topic `ec411af3` (msg `f0a3b378`, also
filed as `4649db44`): "if there a re selected topics ( more than 1 ) in
the channel topics listing regardless of wheather or not a topic is open ,
typing a text on the omnibox and hitting the play button should work as a
multicast to all of hte selected topics". Issue **SPL-6741**.

1. **When.** The selection (7.1.6) holds 2 or more topics and the client
   can send `multicast_check` (`canMulticastCheck`). An open topic does
   not matter. With 0 or 1 ticked the Omnibox sends as before (a reply to
   the open topic, else a new topic in the page's channel).
2. **Not multicast**, as before: a `/search` line, a `/note` line (spec
   155 2.5) and a line whose `in: <title>` names one topic (it names its
   target).
3. **Before the send.** The GO button's label and tooltip read "Send to n
   topics" (`multicast.send`), the target chip "n topics"
   (`multicast.count`, its tooltip `multicast.send`; the phone dock has
   no chip, its GO says it); the 7.1.4 keys, already in every locale.
4. **Send.** GO and the send key (Settings -> Behaviour "Text fields")
   hand the text and files to the Multicast flow
   (`useMulticastSend().sendNow`, loaded on the first such send): the same
   upload, one `multicast_check` with the text, then one copy per selected
   topic with one `mc_id` (4.3). No compose step; the Multicast dialog
   opens on the copies (4.4), mounted by TopBar (`via: 'omnibox'`), so it
   shows on a page with no selection bar too.
5. **Results.** Every copy acked: the dialog closes and the selection
   clears. A check that refuses sends nothing: the dialog stays in compose
   with the text in its own composer and the refused targets named, as
   4.1 step 2 item 2. While the send runs the selection bar's actions are
   off (`busy`).
6. **Tests.** `csi-spl-wui/tests/e2e/multicast-omnibox.test.mjs` (2+
   ticked with and without an open topic: one copy in each ticked topic,
   none elsewhere; 1 ticked: the normal send), `tests/unit/multicast-send.test.mjs`
   (`sendNow`).

## 5. Reused, and the gaps

Reused as is: the composer (inside the Multicast dialog) and its file
upload, the `send` frame and every
check of `wuiSend` (3.2), the doors (3.3), `ViewTopics` with `Reader` (3.4),
shared blobs (3.5), the per-`msg_id` ack, error frame and resend.

Why N frames and not one `multicast` frame: every check of 3.2 is per
message and per target, and the error frame already names one `msg_id`; a
new frame would have to repeat the chain in a loop and invent a partial
answer. The two new frames (7.1.2) read and store nothing: `topic_select`
is where patterns become task ids (shared by every bulk action),
`multicast_check` is the per-target dry run.

| gap | what is missing | row |
|---|---|---|
| G1 | the column that links the copies | M1 |
| G2 | `mc_id` on the frame, the existing-channel-topic check, the author check, the store write | M2 |
| G3 | the frames: `topic_select` (patterns, `*`) and `multicast_check` (the per-target dry run, the quota for the whole count) | M4 |
| G4 | the shared select phase: boxes on topic cards and Monitoring -> Topics rows, the selection store, the selection bar with its action list, "Select by title" | M3 |
| G9 | the Multicast button, the dialog with its composer, the N sends, the result list with Retry | M11 |
| G5 | e2e | M7 |
| G6 | translations, agy's review | M8 |
| G7 | contract and user docs | M9 |
| G8 | the multicast loop | M10 |

## 6. Build order (rows a later lane can take in parallel)

Every row codes against section 7.1, not against another row's branch: the
WUI rows run on the mock client, the hub rows on the store interface. M1,
M2, M3, M4 and M9 can start together; M11 after M3 has landed (it adds a
button to M3's bar and must not fork it); M7 after M3, M4 and M11; M8
after M3 and M11 have landed their en keys; M10 after spec 182's L1 and L2
and this spec's M2, M3 and M4 have landed. Spec 153's Set priority action
(8.3) waits on M3 too. (M5 and M6 were the gathered view and saved groups,
dropped with Q4 GTH and Q1 GRP; the numbers are not reused. In v0.6 M3
became the shared select phase and its v0.5 multicast half moved to the
new row M11.)

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| M1 | rdb: `mc_id` and its index | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_mc_id.sql` (head `0301_topic_loops.sql` on `2500f49fc`, spec 182's L1; spec 185's F1 plans one more, so 0302 or later: re-check) | none | applies twice on a throwaway postgres; `\d messages` lists `mc_id uuid` nullable and the partial index | a migration test asserting `mc_id` fails before the file exists |
| M2 | hub: the send-time multicast checks and store | `internal/hub/wui.go` (`wuiIn.McID`, one `wuiMulticast` step after `wuiIDs`), new `internal/hub/wui_multicast.go` + `wui_multicast_test.go`, `internal/store` (postgres + memory: write `mc_id`, `MulticastAuthor`); no cnf key (R2 QTA) | 7.1.1, 7.1.3; M1's file for the postgres test | Go tests on postgres: N frames with one `mc_id` into N readable topics of different channels store N rows with that `mc_id`; each copy routes as 3.2 step 4 (Q5 NRM); an @agent copy into a humans-only channel is a plain post; 1200 copies of one `mc_id` with an unlimited quota all store (no cap, R2 QTA); a resend of a stored copy re-acks, also with the quota spent (`messageQuota` exempts a stored `msg_id`); with the monthly quota set to the stored count + 2, 4 copies store 2 and the other 2 answer the quota token 429; an unpaid tenant answers 402 on every copy; of 3 targets where the middle one is an existing topic of a members-only channel the author is not in, or a DM topic, the first and third are stored and the middle one answers `multicast_no_topic` 404, the same token and detail as an unknown `task_id`, and its error frame names only its own `msg_id` | an unknown `task_id` with `mc_id` must answer `multicast_no_topic` (without the check it opens a topic); a DM topic the author is an end of must answer `multicast_no_topic` (Q8 CHN); a second author reusing the `mc_id` must answer `bad_json`; add any count of the copies of one `mc_id`: the 1200 test fails; answer `forbidden` for an unreadable topic: the members-only test fails (it must not say the topic exists) |
| M3 | WUI: the shared select phase (S1; also spec 153's Set priority, 8.3) | new `stores/topicSelect.ts` (the selection per workspace, 7.1.6), new `composables/useTopicSelect.ts` (ticks, shift-range, `x`, Esc, page box, Select all N matching, Select by title; the action list), new `components/TopicSelectBar.vue` (lazy, the bar of 4.1 step 1 item 5, drawn as `IssuesBulkBar.vue` is and reusing `utils/issues-bulk.ts`'s helpers, not a third copy of the bar's logic), new `components/TopicSelectPatterns.vue` (the pattern field, also M10's), `components/MessageCard.vue` + `components/LiveFeed.vue` (the box on a topic opener card; the menu's "Select" item via `components/MessageMenu.vue`; tap toggles and swipes off while the selection is not empty), `components/FeedHeader.vue` (the bar in the header's place), `pages/monitoring/topics/index.vue` (the row box, own-workspace rows only), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`topicSelect`), `i18n/locales/*.json` (en + machine drafts). Not touched: `MessageComposer.vue`, `dock-buttons.test.mjs`, `touch-ui.test.mjs` and the three phone Attach e2e tests (S1) | 7.1.2 (`topic_select`), 7.1.4, 7.1.6 | unit tests of the store and composable: tick, shift-range and Esc as on issues; a selection made on channel A's page is still there on channel B's page and the bar says "in 2 channels"; a filter change keeps it; Clear and a workspace switch empty it; the page box and "Select all N matching" tick exactly the topics the filter matches; Select by title sends the patterns verbatim in one `topic_select` and adds exactly the answer's `task_id`s, deduplicated; a bad-pattern answer adds nothing and names the line; an answer with an older `req_id` is dropped; DM cards and `issues` cards show no box; on Monitoring -> Topics another workspace's row shows no box; the bar lists the actions registered with it (a test action registers and shows); a component test at a 390 px viewport: the card menu's "Select" ticks the card, a tap then toggles instead of opening the topic, a left swipe does not archive while the selection is not empty; `dock-buttons.test.mjs` and `touch-ui.test.mjs` stay green unchanged; `pnpm run typecheck`; i18n gates | evaluate a pattern in JS: the "verbatim" test sees a filtered list and fails; clear the selection on a filter change (the issues rule): the "channel B" test fails; leave the swipe on in selection mode: the swipe test archives and fails; render a box on a DM card: the DM test fails |
| M4 | hub: the two frames | `internal/hub/wui.go` (two cases in the frame switch, `wui.go:359-381` on `387370a79`), new `internal/hub/topic_select.go` (`topic_select` handler, `resolveTopicSelector`, shared by every bulk action) + `topic_select_test.go`, `internal/hub/wui_multicast.go` (`multicast_check` handler), `wui_multicast_check_test.go` | 7.1.2; `ViewTopics` (3.4) | Go tests on postgres, `topic_select` with action `multicast`: `*` in a tenant with topics in a public channel, a members-only channel the author is in, one the author is not in, the lobby, `issues`, an archived topic and a DM returns exactly the first two and the lobby one; a topic in a channel the author reads but which touches a box locked to someone else (row B5) is absent under `*` and under `.`, and its title is in no answer; a channel the author reads without `notes.send` is absent for action `multicast`; ` * ` (spaces round the star) resolves as `*`; a line of spaces is dropped; `^rel` matches "Release 2.0" and not "pre-release"; two patterns and a tick are unioned and deduplicated; a tenant with 450 topics (more than two pages of 200) resolves all 450 under `*`; a bad pattern answers `topic_select_bad_pattern` naming its line; an unknown action answers `bad_json`. `multicast_check`: 1200 targets with an unlimited quota are all `ok` (no cap, R2 QTA); one target more than the remaining quota answers the whole check refused with the quota token, the count and the remaining messages; an archived topic comes back `ok: false` `topic_archived`; a `task_id` out of scope comes back `multicast_no_topic`; neither frame stores anything (`messages` count unchanged); with one frame of a kind in flight on a connection, a newer `req_id` of that kind cancels it: the older gets no answer, the newer one answer | stop paging: the 450 test fails; drop `(?i)`: "release" does not match "Release" and the test fails; drop `NoIssues`: the `*` test sees the issue topic and fails; drop the box-lock filter (7.1.2): the box-lock test sees the hidden topic's title and fails; drop the action's permission filter: the no-`notes.send` test fails; count the quota per target instead of once: the quota test refuses at the first target past it, not the whole check, and fails; drop the trim: ` * ` compiles as a regex, misses the titles without a space, and the test fails |
| M7 | e2e | new `csi-spl-wui/tests/e2e/multicast-prompt.test.mjs` | M3, M4, M11 (mock) | on the generated bundle, mock-served, desktop: on channel A's page tick one topic, go to channel B's page, Select by title `^release` matching two topics there, the bar reads "3 selected" "in 2 channels", click Multicast, see "Send to 3 topics", type and send once, the card appears in all three and the selection is empty; a check that refuses one target keeps Send disabled with the reason shown, and removing that target enables it; the same flow at a 390x844 touch viewport: long-press a topic card, its menu's "Select", tap two more cards, the bar's Multicast opens the full-screen sheet, send; the dock row is still `dock-back,attach,send` and Attach still opens the OS picker at once | the e2e fails when the card box, the menu's "Select" item, the bar's Multicast button or Select by title is absent |
| M8 | i18n: agy's final review | the 18 non-en locale files, the keys of 7.1.4 | M3 and M11 landed | agy review per the language rule; gates green | the untranslated-count gate (`i18n-untranslated.test.mjs`) |
| M9 | docs | `csi-spl-doc/specs/005-spool-wui/spec.md` (an FR for the select phase and the multicast send: FR-022: FR-020 is the last on `4c4e97f75` and still on `387370a79`, and spec 185 row F7 plans FR-021; re-check), `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (section 4: `mc_id` and its refusals; the `topic_select` / `topic_selected` and `multicast_check` / `multicast_checked` frames), the user help for the topic lists (ticking topics, the selection bar, Select by title with patterns and `*`, Multicast, the phone's "Select" menu item) | 7.1 | `grep -c -e mc_id -e multicast_no_topic -e topic_select_bad_pattern -e topic_select -e multicast_check -e multicast_none csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` -> at least 6 (0 on `4c4e97f75`) | none automatic: no test parses the fields of `wui-live-ws.md`; the reviewer re-runs the grep with one name removed and must see the count drop |
| M10 | rdb + hub + WUI: the multicast loop (Q10 CMP) | `<next>_topic_loops_targets.sql` (7.1.7), the 182 fire path (`resolveTopicSelector` from M4 per fire), the 182 loop dialog (the switch, the current selection as ticks, M3's pattern field), its tests | 4.8, 7.1.7; 182 L1, L2; M2, M3, M4 | Go tests: a loop with `targets` `{"patterns": ["^ops"]}` fires once and stores one hidden `kind: task` per matching topic with one shared `mc_id`; a topic created after the loop was saved whose title matches gets the next fire; a target archived since makes the whole fire send nothing and logs one line; a target topic with no announced agent makes the whole fire send nothing and logs `loop_no_agent`; a refire for the same seed is a no-op (UUIDv5 ids) | resolve the targets at save time instead of fire time: the new-topic test fails; send what passes: the archived-target test sees N-1 rows and fails; skip the agentless target and send the rest: the no-agent test sees N-1 rows and fails |
| M11 | WUI: the Multicast action (S1 step 2) | new `components/MulticastDialog.vue` (the selected topics with remove crosses, a `MessageComposer` instance whose `send` it handles, the preview, the result lines; a full-screen sheet on a phone), new `composables/useMulticastSend.ts`, `stores/channel.ts` (`sendMulticast`, one `sendLive` per target), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`mc_id`, `multicastCheck`), the one line that adds Multicast to M3's action list, `i18n/locales/*.json` (en + machine drafts). Not touched: the page composer and its dock row | M3; 7.1.1, 7.1.2 (`multicast_check`), 7.1.4 | a unit test of `useMulticastSend` on the mock: the check names exactly the selection's `task_id`s and carries no pattern; Send is disabled while any target is not ok; removing a refused target re-runs the check; files uploaded once; N frames with one `mc_id` and N `msg_id`s, exactly the check's `task_id`s; the mock socket drops after 2 of 5 frames are acked: the 2 show sent, the 3 others show "waiting for network" (`sendLive` returns `waitForNetwork`, `channel.ts:681,686` on `2500f49fc`), the dialog keeps the text until all 5 are acked, and on reconnect the 3 go again under their own `msg_id`s; a send-time refusal lists that target with Retry under the same `msg_id`; when all are acked the dialog closes and the selection is empty; the page composer's draft is unchanged by a multicast; an answer with an older `req_id` than the newest sent is dropped; `pnpm run typecheck`; i18n gates | make the mock check refuse one target: Send must stay disabled; clear the dialog on the first ack: the socket-drop test fails; mint a new `msg_id` on the reconnect resend: 7 frames stored, not 5, and the test fails; send through the page composer's store draft: the "draft unchanged" test fails |

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
- No count of the copies of one `mc_id` and no cnf key (R2 QTA): each copy
  is one message in the monthly quota, as any post. The resend of a
  `msg_id` already stored re-acks and is never refused by the quota or
  the archive (`messageQuota`, `ws.go:918-938`; `wuiArchivedRefusal`,
  `topic_archived_input.go:48-61`).
- Every existing refusal of `wuiSend` applies to each copy unchanged
  (`topic_archived`, `unknown_channel`, `forbidden`, `402 unpaid`, `429
  quota`: each copy counts as one message in `admit`; `missing_file`, the
  token budget, the demo checks). The ack is the existing ack.

#### 7.1.2 The two read-only frames: select and check (Q9 ALL, Q6, S1)

**`topic_select`**, the select phase's resolver, shared by every bulk
action (4.1 step 1 item 4):

```
{ "type": "topic_select", "req_id": "<uuid>", "action": "multicast" | "<a later action>",
  "task_ids": ["<ticked task_id>", ...], "patterns": ["*" | "<RE2>", ...] }
->
{ "type": "topic_selected", "req_id": "<same>",
  "ok": true|false, "error?": "<token>", "detail?": "<text>",
  "topics": [{ "task_id", "channel", "title" }] }
```

- `patterns` at most 10 of at most 256 bytes; `task_ids` has no count of
  its own (R2 QTA): duplicates count once, and the frame is bounded by the
  socket's read limit, `maxFrameBytes` = 512 KiB (`internal/hub/ws.go:30`,
  `SetReadLimit` `wui.go:239`). Both may be empty, not both (`bad_json`
  400). An `action` the hub does not know answers `bad_json` 400; this
  spec defines `multicast`, spec 153 adds its own (8.3).
- Resolution (`resolveTopicSelector`): pages `ViewTopics` with `Reader` =
  the author, `ReaderChannels`, `NoIssues`, `DM` false, until the end
  (3.4); applies the box owner lock to each page as the topic list does
  (4.2). `keepTopics` takes `[]viewTopic` and reads `Participants`
  (`internal/hub/box_lock_view.go:315-333`), while `ViewTopics` returns
  `store.TopicRow`, whose seats are `Parties` (`internal/store/view.go:78`):
  the filter drops a row when `lockViewFor(author).hidesSeat(p)` holds for
  any `p` in `row.Parties`, the lobby exempt (the same loop as
  `keepTopics`, run on the store rows before titles are read; converting
  each row to a `viewTopic` first is the other way). It keeps a topic
  when the trimmed `*` is a pattern, or a pattern `(?i)<p>` matches its
  `subject`, or its `task_id` is ticked; drops topics in channels where the
  author lacks the action's permission (`multicast`: `notes.send`). A
  ticked `task_id` not in that set is left out of `topics` (it reads as
  absent, the 404 rule of 3.3).
- `ok: false` with `error` = `topic_select_bad_pattern` (detail: the
  line) adds nothing; `topics` empty with `ok: true` is a selection of
  none (the WUI says "No topic matches").
- **Cost bound**: one `topic_select` in flight per connection; a newer one
  cancels the running one (its context), which then answers nothing. A
  resolution pages the in-scope topics (200 a page) and runs at most 10
  RE2 matches on titles of at most 140 runes, linear in the input (3.4).

**`multicast_check`**, the Multicast dialog's dry run (4.1 step 2):

```
{ "type": "multicast_check", "req_id": "<uuid>",
  "task_ids": ["<selected task_id>", ...],
  "files": [ <refs> ], "body": "<the text>" }
->
{ "type": "multicast_checked", "req_id": "<same>",
  "ok": true|false, "error?": "<token>", "detail?": "<text>",
  "targets": [{ "task_id", "channel", "title", "ok": true|false, "error?": "<token>" }] }
```

- No patterns: the selection is already explicit (the loop of 4.8 is the
  one place patterns reach a multicast unresolved, and it calls
  `resolveTopicSelector` on the hub itself). `task_ids` empty answers
  `multicast_none`; bounded as above.
- Each `task_id` is checked to be in scope as `resolveTopicSelector` with
  action `multicast` would keep it, else `ok: false` `multicast_no_topic`.
- Per target it runs the read-only checks of 3.2 steps 4 and 5 for a copy
  of this `body` and `files` (archived, moved, door, `notes.send` /
  `agents.command`, billing, `missing_file`, token budget when an agent will
  act), and the quota once for the whole count.
- The whole check is `ok: false` with `error` = the quota token (detail:
  the count and the remaining messages), or `multicast_none` (no target);
  `targets` is then as far as the check got. Otherwise `ok` is true only
  when every target is ok.
- **Cost bound**: one `multicast_check` in flight per connection, as
  `topic_select`; the WUI sends at most one per 300 ms (4.1).
- Both frames store nothing and send nothing to any box. Their `req_id`
  lets the WUI drop an answer to an older frame.
- A check is a promise for the moment it runs: the send frames are checked
  again one by one (7.1.1, 4.4).

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

New i18n keys (en text). The select phase (M3): `topic_select.label`
"Selected topics", `topic_select.count` "{count} selected",
`topic_select.in_channels` "in {n} channels", `topic_select.select_page`
"Select all topics shown", `topic_select.select_row` "Select {title}",
`topic_select.select_matching` "Select all {total} matching",
`topic_select.select` "Select" (the card menu's item), SPL-6613's
`feed.topic_list.filter_title` "Topic title" (the filter's title field),
`topic_select.by_title` "Select by title",
`topic_select.patterns` "Topic title patterns, one per line; * = every
topic", `topic_select.apply` "Add matching topics",
`topic_select.bad_pattern` "Pattern {line} is not valid: {reason}",
`topic_select.none` "No topic matches", `topic_select.clear` "Clear
selection", `topic_select.other_workspace` "Another workspace's topic:
it cannot be selected here". The Multicast action (M11):
`multicast.action` "Multicast", `multicast.title` "Send to {n} topics",
`multicast.count` "{n} topics", `multicast.send` "Send to {n} topics",
`multicast.remove` "Remove {title}", `multicast.sent` "Sent to {n}
topics", `multicast.refused` "Not sent to {topic}: {reason}",
`multicast.retry` "Retry", `multicast.none` "No topic selected". Every
key in all 19 locale files (`i18n-parity.test.mjs`). The v0.5 keys
`composer.multicast*` and `composer.attach_files` are dropped with the
composer entry (S1).

#### 7.1.5 (dropped with Q4 GTH)

#### 7.1.6 The select phase (shared; S1, M3)

One component set every bulk action on topics reuses; no action builds a
second topic multi-select (owner addendum `ae2caeb2`, 8.3).

- **Selection.** `stores/topicSelect.ts`: per workspace, an ordered list of
  `{task_id, channel, title}` (the title from the card, the row or the
  `topic_selected` answer). Kept for the browser session across channel
  pages and Monitoring -> Topics, cleared by Clear, by a workspace switch
  and by an action that reports it finished. Never stored on the hub.
- **Where boxes show.** On a topic opener card of a channel's topic list
  (`LiveFeed`), the lobby and `general` included, and on Monitoring ->
  Topics rows of the reader's own workspace. Never on a DM card, an
  `issues` card, a reply card inside a topic, nor another workspace's row.
- **Bar.** `TopicSelectBar.vue`, drawn while the selection is not empty in
  the header's place on those pages: on a channel page the topic list's
  filter and sort first (`TopicListControl`, the header's own, Topic title
  included: a filter change while topics are ticked keeps the selection,
  4.1 step 1 item 3; SPL-6613, holder GO `dc0fa0cb`), the page box (it
  ticks the topics listed), the count ("in k
  channels" when k > 1), the registered actions in their
  registration order, Clear; at 390 px it fits with no horizontal
  overflow and Multicast on screen (`multicast-prompt.test.mjs` P); a progress line and a result line an action
  fills, as on issues (3.6).
- **Actions.** `useTopicSelect().registerAction({ id, icon, labelKey,
  run(selection) })`; `run` gets the selection and returns when the action
  is done or cancelled; a finished action clears the selection. Multicast
  (M11) registers `multicast`; spec 153 registers its priority action.
- **Patterns.** The title field of the topic list filter
  (`TopicListControl.vue`, SPL-6613): `useTopicSelect().filterByTitle`
  sends `topic_select` (7.1.2) with the action the page was opened for;
  with no action yet chosen it sends the action of the first registered
  button (`multicast` while this spec's action is the only one). The
  answer is `stores/topicSelect.ts` `titleMatch`; `useTopicListChoice`
  exposes its ids (`titleIds`, a channel page only) and `MessageFeed`
  passes them to `topicListView` (`only`). `TopicSelectPatterns.vue`, the
  multi-line field, is the loop's (M10).
- **Criteria.** The page box, the header's select tick and "Select all N
  matching" use the page's own filters: the tick and the page box tick the
  topics listed (`store.shown`, what the filters keep). On a channel page
  "all N matching" pages the channel's topics through the existing list
  call (`listTopics`, as `MovePickerDialog.vue:111-116` reads them) until
  the end; under a title filter it adds the hub's answer for the page's
  channel instead, N exact, with no paging. Tests:
  `csi-spl-wui/tests/unit/topic-select.test.mjs`,
  `tests/unit/topic-list-order.test.mjs` and
  `tests/e2e/topic-title-filter.test.mjs` (desktop and 390x844).

#### 7.1.7 The loop targets (Q10 CMP, M10)

`<next>_topic_loops_targets.sql`: `ALTER TABLE topic_loops ADD COLUMN IF
NOT EXISTS targets jsonb NULL` (NULL = a one-topic loop, as 182). Shape:
`{"task_ids": [...], "patterns": [...]}`, the limits of 7.1.2. 182's
`POST`/`PUT /v1/topics/{task_id}/loops` accept `targets`; a bad pattern
answers `topic_select_bad_pattern` 400 at save. Resolution
(`resolveTopicSelector`, action `multicast`) and checks per fire as 4.8.

## 8. Related specs

### 8.1 Spec 185 (forward), where multicast differs

Both post into existing topics over the `send` frame, keep every check of
`wuiSend` and store a hub-only marker column (`fwd_of`, `mc_id`). They
differ:

| | forward (185) | multicast (186) |
|---|---|---|
| the text | someone's card, copied by the hub from `forward_of` | the author's own, in the frame |
| targets | one | the select phase's selection: ticks plus title patterns, `*` = all (4.1, 4.2) |
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

### 8.3 Spec 153 (the Queue tab's priority), the select phase's second user

Owner addendum (t1 `906c1b28`, msg `ae2caeb2`, section 0): the topic
multi-select is built once. Spec 153 3.22
([153 3.22](../153-monitoring-lanes-tab/spec.md), "The Queue tab:
requests and plans, priority, drag, resources, and why it slows") sets a
discussion's priority one topic at a time (3.22.6, "On a lane": the
chooser writes that topic's priority). Its bulk form is the select phase's
second action, **Set priority**: it registers with the bar of 7.1.6,
opens 153's 1..5 chooser once, and writes each selected topic's priority
with 153's own route and permission (`runBulk`, 3.6). Its permission
filter in `topic_select` is 153's to define (an `action` value of its
own, 7.1.2). Spec 153's Q1-Q12 plan reuses M3 and adds no second topic
multi-select; its row that needs it waits on M3. This spec defines only
the shared part; the priority action, its route and its tests are 153's.

## 9. Not in this spec

- Targets in another workspace (the socket is bound to one tenant).
- DM topics as targets (Q8 CHN).
- A multicast from an agent, the box socket or the `spool` CLI.
- Editing or deleting all copies at once: each copy is edited or deleted on
  its own card, as today.
- Multicasting an existing card (that is a forward, spec 185).
- A view that gathers the copies and their replies (Q4 OWN).

## 10. Versions

| version | sha | what |
|---|---|---|
| v0.1 | `83295f6d1` | first draft, questions Q1-Q11 |
| v0.2 | `b53947cee` | the spec review's W1-W6 and N1 |
| v0.3 | `a86daa6c5` | the owner's answers Q1-Q11 (form `e864b1cb`, msgs `dcf298b8`, `1b95d0ec`) |
| v0.4 | `cbbc11996` | the v0.3 review (c-240, msg `9598398d`); R2 and R3 to the owner (form `a07226d8`) |
| v0.5 | `31b583afe` | R2 QTA, R3 ATT (msg `ee9b2558`); the v0.4 review's N1, N2 |
| v0.6 | this commit | S1: select, then Multicast (msgs `5fdfff6c`, `656b2576`, `4b3833e7`; addendum `ae2caeb2`) |
| v0.7 | SPL-6741 | 4.9: the Omnibox's send multicasts to the selection when 2+ are ticked (msg `f0a3b378`) |

### 10.1 Changes in v0.6

- Section 0 and 1: the owner's 2026-11-24 words; R3 ATT, msg `fe3ced5e`
  (phone long press) and msg `afc6f1d7` (desktop control) recorded as
  superseded history; decision S1 added; Q1 and Q11 read through S1.
- Terms: select phase, selection, selection bar.
- 3.4: the topic lists that exist (the Topics page is gone; a channel's
  topic list; Monitoring -> Topics) and the card's gestures. New 3.6: the
  issues list's multi-select, cited on `387370a79`, as the model.
- 4.1 rewritten: step 1 the select phase (ticks, criteria, Select by
  title), step 2 the Multicast button and its dialog. 4.2: patterns are
  resolved by `topic_select`, scope per action. 4.3, 4.4: the dialog, not
  the composer. 4.6 rewritten: the phone selects through the card menu,
  the bar on top, the dialog as a full-screen sheet; the dock untouched.
  4.8: the loop dialog takes the selection and the pattern field.
- 5: G3 is the two frames, G4 the shared select phase, new G9 the
  Multicast action.
- 6: M3 is now the shared select phase (no composer change, no Attach
  sheet, the three phone Attach e2e tests untouched); new M11 the
  Multicast dialog and send; M4 adds `topic_select` and the action's
  permission filter; M7's cells select in two channels and on a phone
  through the card menu; M8, M9, M10 follow.
- 7.1.2: the resolver moves to `topic_select` / `topic_selected`
  (`resolveTopicSelector`, an `action` field); `multicast_check` names
  task ids only; `multicast_bad_pattern` is renamed
  `topic_select_bad_pattern`. 7.1.4: `topic_select.*` and `multicast.*`
  keys replace `composer.multicast*` and `composer.attach_files`. 7.1.6:
  the picker becomes the shared select phase.
- 8.1: targets come from the selection. New 8.3: spec 153's priority as
  the select phase's second action.

## 11. Open questions for the dispatch holder (to ask the owner as a form)

This lane did not guess these; the text above takes the first reading
named in each, so a different answer changes only the cited spots.

- **H1. Which lists?** "The topics list view or the channels view" (msg
  `5fdfff6c`): the Topics page was removed (msg `a78e06c8`). This spec
  reads the topics list view as Monitoring -> Topics (spec 153 3.10) and
  the channels view as a channel's topic list. Alternative: a channel's
  topic list only (Monitoring -> Topics lists only topics with lane
  activity, across workspaces). Spots: 4.1 step 1 item 1, 7.1.6, M3.
- **H2. Does the selection survive moving between channels?** The issues
  list clears it on a filter change (3.6). This spec keeps it across
  channel pages of one workspace, so one multicast can reach several
  channels (msg `f7782824`, "multiple channels"). Alternative: one
  channel's list at a time, several channels only by Select by title.
  Spots: 4.1 step 1 item 3, 4.6, 7.1.6.
- **H3. Desktop boxes: always, or on hover until the first tick?** The
  issues list shows them always. This spec shows them on hover and focus
  until one topic is ticked, so the feed reads as today. Spot: 4.1 step 1
  item 2.
- **H4. Phone: how does selecting start?** This spec adds "Select" to the
  card menu (long press or right swipe); then taps toggle and the swipes
  pause. Alternative: a box on every card always, as issues on a phone.
  Spot: 4.6.
- **H5. Where is the prompt written?** This spec writes it in the
  Multicast dialog's own composer (the holder's reading: the button "opens
  the prompt for the selected topics"). Alternative: while topics are
  selected, the page composer's play button reads "Send to n topics" and
  multicasts. Spots: 4.1 step 2, M11.
