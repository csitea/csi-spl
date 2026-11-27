# Spec 182: Topic Loop Prompt (Discussion Loops)

Status: **v0.11 (the owner's dialog changes, building)** (2026-11-26); v0.10 (ready for build planning) (2026-11-25). Lane `c-301` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). v0.1 `bc0353485`; v0.2 folds the
owner's answers to form `2c1c3f5d` (msg `a198ae53`) and the two requirements
in msgs `eae9e64f` and `19acb8f9`; v0.2 `d17f582cb`; v0.3 folds Q9 (msg
`e05bec70`, poll `7e28ed23`), the six triggers (msg `d44af000`), the worked
example (msg `92050cbc`) and the suggested triggers (msg `ad30fe25`), and
adds the binding contracts of 7.1 (section 8); v0.3 `d01889cfd`; v0.4 takes
all six extra triggers (msg `a1d73b19`, poll `39cc8497`) into the decided
set: twelve triggers (1.2), their hooks (4.2), store and contracts (5.1,
7.1), the rows that own each (7.2), and the one list of contract changes
for the lanes building on v0.3 (8.1); v0.4 `91e92e63c`; v0.5 answers the
three points of the L2 lane (c-970, msg `9dc69b0c`): the time-fire seed,
who deletes the loops on archive, and the author's two ids (8.2); v0.5
`b106c0e76`; v0.6 folds the owner's answers to Q10 and Q11 (msg
`46e61a8c`, poll `7ce8419c`): a loop's own agent answer never re-fires it,
and `before_human_reply` is dropped, eleven triggers stay (8.3); v0.6
`081f0f506`; v0.7 adds the three hidden-row places and the two count
CHECKs the L1 review found (c-382, msg `13956ae7`; 8.4); v0.7
`55058f7c1`; v0.8 folds the owner's N4 B (msg `f854f268`, poll
`be4ebf76`): an agent's answer to any loop prompt fires the "after each
agent reply" box of no loop of the topic (1.6, 8.5); v0.8 `4c5633d84`
(on master); v0.9 (lane `a-302`, `agy`, issue **SPL-6440**, `d93a2d686`,
topic `cbb1897b-4d35-44df-93c3-a2bbd2b6defa`) amends the spec with **Channel
loops** (section 9) and held CL1-CL4 for owner poll; v0.10 (lane `a-494`,
`agy`, issue **SPL-6474**, topic `cbb1897b-4d35-44df-93c3-a2bbd2b6defa`)
folds the owner's answers to form `13fb1941` (msg `facaaf33`, 2026-11-25
07:37Z: **CL1 A, CL2 B, CL3 B, CL4 B**), closes all open choices, pins the
workspace archive-topics setting reads on `origin/master`, specifies how the
60/h per-loop cap and 120/h per-channel total cap interact, removes the
per-topic opt-out switch, and finalises the disjoint build rows with red
controls and vendor assignments per the fleet kind table (8.7, 9.1-9.10);
v0.11 (lane `c-068`, `claude`, issues **SPL-6580..SPL-6589, SPL-6592,
SPL-6593**, topic `6e8c1cdb-8358-4404-a88c-0adc6f443c71`) folds the owner's
fourteen messages on the Discussion loops dialog (HUM-10, t1 `6e8c1cdb`,
2026-11-26): one trigger per loop as radio buttons (it reverses Q3 B), the
trigger names the loop, and the dialog's size, drag, buttons, prompt box,
card order, file triggers, clock, columns and font (8.8).
Epic: **SPL-2398**. Issue: **SPL-6022** (v0.1-v0.8); **SPL-6440** (v0.9); **SPL-6474** (v0.10). Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:f08c0c58-9228-4e2a-af00-dbbdbd328083` (`t1`, v0.1-v0.8); `topic:cbb1897b-4d35-44df-93c3-a2bbd2b6defa` (`t1`, v0.9-v0.10).
Builds on: [179 pause the agents of a discussion](../179-pause-agents-of-a-discussion/spec.md)
(per-topic hub state, the topic menu entry, who may act on a topic),
[150 topic-list priority](../150-topic-list-priority/spec.md) (the
`topic_priorities` table shape) and [099 topic head](../099-topic-head/spec.md)
(per-topic state lives in its own table, not in `messages`).

Line references in sections 0-8 were measured on `origin/master` `af8ca0ba7`
(and `e2883a6be` for v0.7); between `af8ca0ba7` and `412a44ab0` (the v0.2
base) no file cited there changed (`git diff --name-only af8ca0ba7 412a44ab0`
lists none of them). Line references in section 9 (v0.9-v0.10) were measured on
`origin/master` `b48786ce3` and re-verified on `c9dd02117` (exact commands in
9.10; between `b48786ce3` and `c9dd02117` only `openapi.json` changed, and
`TopicLoop` remains at `:1113`).

## 0. The owner's words (HUM-10, t1 #spool-hub-devel, topic f08c0c58)

- 08:32:11Z, msg `a0c4e227`: "loops for each agent reply or human reply in a
  discussion - add the functionality on each msg card to set from the right
  click menu on the topic level"
- 08:34:14Z, msg `b20e28e9`: "when the user clicks on the right click menu on
  the topic level and chooses the setup loop prompt it should be possible to
  setup a txt prompt for discussion , which will execute on either agent
  reply or human prompt or another human prompt"
- msg `eae9e64f`: "also the loop replies must not be shown as separate promts
  , they should just run in the background"
- msg `19acb8f9`: "The users should be able to modify the loops of the
  discussions , by choosing from the right cclick menu - right click on topic
  level - discussion loops"
- msgs `d44af000` (the six triggers, 1.2), `92050cbc` (the worked
  example, 4.6) and `ad30fe25` (suggest more triggers, 1.5): quoted where
  they are applied.

Nothing named "loop" existed in the WUI menus or the hub's browser send path
at v0.1:
`git grep -n -i "loop" origin/master -- csi-spl-wui/src/utils/msg-menu.mjs csi-spl-wui/src/utils/topic-menu.mjs csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go | wc -l`
-> 0.

## 1. Decided, and what is open

The owner's answers to form `2c1c3f5d` (msg `a198ae53`, 09:05:50Z), as this
spec applies them:

| Q | Answer | What it decides here |
|---|---|---|
| Q1 | **A** — the topic's agent: the agent that last wrote in the topic | 4.3 step 1 |
| Q2 | **A** — a new message to that agent in the topic, the prompt with the post that fired it quoted | 4.3 step 2; shown to nobody, see 1.1 |
| Q3 | ~~**B** — any mix of the triggers, as checkboxes~~; **v0.11: one trigger per loop, radio buttons** (msg `febf1db4`, 8.8 change 3); the six triggers of msg `d44af000` replace v0.2's three (1.2) | 4.1, 4.2, the `triggers` column |
| Q4 | **B** — only the cap of 12 fires per hour; Q10 A adds one rule on top (1.4) | 4.2, 4.5 |
| Q5 | **A** — whoever the workspace's "Who can archive topics" setting allows (as pause) | 4.1 step 1 and step 3 |
| Q6 | **B** — several loops per topic, each with its own prompt and trigger | section 5 key; the list dialog of 4.1 |
| Q7 | **C** — only the menu entry; nothing on the topic or the messages | 4.1; no badge, no notes |
| Q8 | **A** — the loop's author, marked as sent by the loop | 4.3 step 2; the mark is `messages.loop_id` |
| Q9 | **A** — yes, the agent's answer is an ordinary reply in the topic (msg `e05bec70`, poll `7e28ed23`) | 4.3 step 2, 4.4 step 1 |
| Extra triggers | **all six**: KW, ATT, BLK, IDL, ISS, DLY (msg `a1d73b19`, poll `39cc8497`) | 1.2 rows 6 to 11, 4.2 steps 8 to 12 |
| Q10 | **A** — the agent's answer to a loop prompt never fires the loop that sent it (msg `46e61a8c`, poll `7ce8419c`) | 4.2 step 7, 4.4, `awaiting` in 5.1 |
| Q11 | **C** — drop "before each human reply": keep five of the six triggers of msg `d44af000` (msg `46e61a8c`, poll `7ce8419c`) | 1.2, 4.2 step 4, 5.1 CHECK, 7.1 |
| N4 | **B** — an agent's answer to any loop prompt never fires an "after each agent reply" loop (msg `f854f268`, poll `be4ebf76`, v0.8) | 1.6, 4.2 step 7, 4.4, 4.6 |

### 1.1 Answer 2 and msg eae9e64f, reconciled

Answer 2 says the prompt goes to the agent as a new message in the topic.
`eae9e64f` says the loop must not show up as separate prompts: it runs in
the background. Both hold when the fired prompt is a real message on the
topic's task id that the agent receives, but the topic never shows it:

- It is stored, delivered to the agent's box and answered like any human's
  task in the topic (answer 2 A). The agent's answer goes into the topic.
- No person sees the prompt in the topic: the hub does not fan it out to
  browsers, the views do not list it, and it does not change the topic's
  head, unread counts or "last message" (section 5.2). This is also what
  answer 7 C asks for: nothing on the topic or on the messages.

The agent's **answer** is shown, as an ordinary reply in the topic (Q9 A,
1.3).

### 1.2 The eleven triggers (msgs d44af000, a1d73b19 and 46e61a8c)

HUM-10 (msg `d44af000`, verbatim): "so it must have the check boxes , of
"after reach reply by an agent , before each rely of an each , after each
reply of a human , before each apply of a human , each hour , each <<n>>
minutes". Read as six checkboxes, any mix (answer 3 B). They replace v0.2's
three. Q11 C (msg `46e61a8c`) dropped the fourth, "before each human
reply" (`before_human_reply`, v0.3 to v0.5), so five stay:

| key | box | fires when | detail |
|---|---|---|---|
| `after_agent_reply` | after each agent reply | an agent reply (section 2) is stored | 4.2 step 2 |
| `before_agent_reply` | before each agent reply | a human post that an agent will answer is about to be stored: the prompt is queued to that agent ahead of the post | 4.2 step 3 |
| `after_human_reply` | after each human reply | a human post is stored | 4.2 step 1 |
| `every_hour` | each hour | 60 minutes after the last time fire | 4.2 step 5 |
| `every_n_minutes` | each n minutes | n minutes after the last time fire; n is 5..1440 | 4.2 step 5 |
| `post_has_keyword` | a post that contains a word or phrase you type (KW) | an agent reply or a human post whose body contains the loop's `keyword`: case-free, whole words | 4.2 step 8 |
| `post_has_file` | a post with a file attached (ATT); v0.11: no longer offered, a stored loop keeps it (8.8 change 9) | an agent reply or a human post stored with at least one file | 4.2 step 9 |
| `post_has_file_agent` | v0.11: after an agent post with one or more files attached | an agent reply, or an agent's blocker to another agent, stored with at least one file | 4.2 step 9 |
| `post_has_file_human` | v0.11: after a human post with one or more files attached | a human post stored with at least one file | 4.2 step 9 |
| `blocker_posted` | a blocker posted in the topic (BLK) | a row of kind `blocker` stored on the topic's task id, from anyone to anyone (agent-to-agent too), or a post's kind set to `blocker` | 4.2 step 10 |
| `no_reply_after_human` | no reply for n minutes after a human post (IDL) | n minutes (`idle_min`, 5..1440) after a human post with no agent reply since; a later human post restarts the count | 4.2 step 11 |
| `issue_status_changed` | an issue linked to the topic changes status (ISS) | an issue linked to the topic (`issue_discussions`) is written with a new status | 4.2 step 12 |
| `daily_at` | every day at a set time (DLY) | once a day at `daily_at` (hh:mm) in the loop's own time zone `daily_tz` | 4.2 step 5 |

The first five are from msg `d44af000`; the last six are the owner's answer
to the extra-triggers form (1.5). A loop stored with `before_human_reply`
is refused (5.1 CHECK, `ErrBadTopicLoop`).

The cap stays 12 fires per loop per hour (answer 4 B), so n is at least 5:
12 fires an hour is the most `every_n_minutes` can fire. A post that matches
two checked boxes fires once. The cap counts every fire of a loop, whatever
trigger caused it.

v0.2's "only another human's post" is not in the owner's list and is
dropped.

### 1.3 Q9, answered

The v0.2 form asked whether the agent's answer to a loop prompt is shown in
the topic. HUM-10 answered **A** — "Yes, as an ordinary reply in the topic"
(msg `e05bec70`, poll `7e28ed23`). No question is open.

### 1.4 Q10 and Q11, answered

HUM-10 (msg `46e61a8c`, poll `7ce8419c`, verbatim): "Answer 1: A — The
agent's answer to a loop prompt never fires the loop that sent it Answer 2:
C — Drop it: keep five triggers". No question is open.

- **Q10 A.** The hub knows the answer as the target agent's next agent
  reply in the topic within 30 minutes of the fire (`awaiting`,
  `awaiting_until` in 5.1; 4.4). That reply does not fire this loop; since
  v0.8 (N4 B, 1.6) it fires no other loop's `after_agent_reply` box either. It covers every post trigger, not only
  `after_agent_reply`: the answer can also contain the keyword, carry a file
  (the worked example's PDF, if it is posted) or be a blocker, and none of
  them fires the loop that sent the prompt. The cap of 12 per hour (answer
  4 B) stays for every other cause.
- **Q11 C.** `before_human_reply` is not a trigger: no checkbox, no key in
  the CHECK or the constants, no hook (4.2 step 4). The worked example's
  "after each reply to me by an agent" is served by `after_agent_reply`,
  which fires on every agent reply in the topic, to anyone (4.6).

The form, as sent:

```poll
Q10. A loop with "after each agent reply" fires on the agent's own answer to that loop (for example "PDF sent"), so it fires again, up to 12 times an hour. What should stop that?
(A) The agent's answer to a loop prompt never fires the loop that sent it
(B) Nothing more: the cap of 12 per hour is enough
(C) The agent answers a loop prompt only when the prompt asks for a post
Q11. What does "before each human reply" mean?
(A) After an agent replies to the loop's author: the moment before the author answers
(B) When a human opens the reply box in the topic (needs a new typing signal from the web UI)
(C) Drop it: keep five triggers
```

### 1.5 Extra triggers, answered (msgs ad30fe25, a1d73b19)

HUM-10 (msg `ad30fe25`): "suggest also different type of triggers which
might be worth doing and setting in the modal dialog box during the
configuration setting of the loop". The form below went out as poll
`39cc8497`; HUM-10 took all six (msg `a1d73b19`, verbatim): "Answer:
KW,ATT,BLK,IDL,ISS,DLY — A post that contains a word or phrase you type; A
post with a file attached; A blocker posted in the topic; No reply for n
minutes after a human post; An issue linked to the topic changes status;
Every day at a set time". They are rows 6 to 11 of 1.2. The form, as sent:

```poll
Which extra triggers should the loop dialog offer? Pick any.
[KW] A post that contains a word or phrase you type
[ATT] A post with a file attached
[BLK] A blocker posted in the topic
[IDL] No reply for n minutes after a human post
[ISS] An issue linked to the topic changes status
[DLY] Every day at a set time
```

| key | trigger (1.2) | what it costs, measured on `d01889cfd` |
|---|---|---|
| `KW` | `post_has_keyword` | a text field and one case-free whole-word match per stored post, in the hub; no new event |
| `ATT` | `post_has_file` | none beyond the trigger check: the stored row carries its files (`store.Message.Files`, `internal/store/store.go:138`, v:1 `files[]` JSON) |
| `BLK` | `blocker_posted` | the check on every stored box send of the topic (not only agent replies), and one hook where a post's kind is set (`handleSetMessageKind`, `internal/hub/message_kind.go:65`; the change branch `if c.Seq > 0`, `:123`) |
| `IDL` | `no_reply_after_human` | a due time per loop on the time ticker (4.2 step 5), armed by a human post, cleared by an agent reply |
| `ISS` | `issue_status_changed` | a hook in the hub's one issue write (`updateIssue`, `internal/hub/issues.go:419`, store call `:449`) and the link read `IssueDiscussionLinks` (`internal/store/issue_discussions.go:94`); the prompt quotes the issue, not a post |
| `DLY` | `daily_at` | a time and a time zone per loop on the time ticker. The workspace has no time zone today (`git grep -il time_zone origin/master -- csi-spl-api/src/go/spool-hub-api/internal/store/` lists only the calendar files), so the loop keeps its own IANA zone, the calendar event's rule (`TimeZone`, `internal/store/calendar.go:156`; "" is UTC) |

### 1.6 N4, answered (v0.8)

HUM-10 (t1 f08c0c58, msg `f854f268`, 2026-11-20T20:49:15Z, verbatim):
"Poll: be4ebf76-eb6f-47d4-9874-66577093d977 Answer: B — An agent's answer
to any loop prompt never fires an "after each agent reply" loop".

The question (c-002, 19:52:44Z): two `after_agent_reply` loops of one topic
fire each other, the answer to loop 1's prompt fires loop 2 and back, up to
24 prompts an hour; Q10 A stops a loop firing only on the answer to its own
prompt. N4 B extends that to every loop of the topic. As built (row L2,
SPL-6105):

- A post is an awaited answer when it is the answer to ANY loop of the
  topic: that loop's `awaiting` is the post's sender and the post is before
  its `awaiting_until` (4.4). It clears that loop's wait, as in Q10 A.
- Such a post matches the `after_agent_reply` box of no loop of the topic.
- Only that box is dropped: another loop whose other checked boxes
  (keyword, file, blocker) match the answer still fires on them. The loop
  whose prompt was answered does not fire at all (Q10 A).
- A real agent reply (the answer to no prompt) and a human post still fire
  every loop.

## 2. Terms

- **Loop**: one saved row on a discussion: its prompt, its triggers, its
  state (`on` or `paused`), its author and its counters. A topic has any
  number of loops (answer 6 B).
- **Fire**: the hub sends a loop's prompt once, because of one stored post
  (the **trigger post**).
- **Agent reply**: a post an agent box sends into the discussion that a human
  reads there: to `ALL-0`, or to a `HUM-*` / `GST-*` id. Agent-to-agent
  sends on the same task id (`note`, `result`, `blocker`, `reject` to an
  agent id) are not replies. This is the same line spec 179 section 5.2 row 1
  draws.
- **Human post**: a post a signed-in member stores from the browser
  (`from_box = box-wui`, `from_id = HUM-*`), not a note to self.
- **Time fire**: a fire of `every_hour`, `every_n_minutes`, `daily_at` or
  `no_reply_after_human`, from the time ticker. The first three have no
  trigger post; `no_reply_after_human` quotes the human post that armed it.
- **Issue fire**: a fire of `issue_status_changed`; it quotes the issue
  change, not a post.
- **Loop prompt message**: the message a fire stores and delivers; its
  `messages.loop_id` names the loop (section 5.2).
- Never a trigger: a hub note (`HUB-0`, `PublicNoticeFrom`,
  `internal/hub/public_notice.go:23`), the pause and resume notices of spec
  179, and a loop prompt message.

## 3. How a post reaches an agent today (measured)

Paths under `internal/` are in `csi-spl-api/src/go/spool-hub-api/`.

| step | what happens | where |
|---|---|---|
| 1 | The browser sends a post over the WUI socket; `wuiSend` resolves the recipient. An agent `to`, or a leading `@AGENT`, makes it an agent dispatch. | `internal/hub/wui.go:571`, `wuiRecipient` `:887`, `dispatchAgent` `internal/hub/dispatch.go:51` |
| 2 | `wuiRoute` picks the agent's box (`dispatchCheckIn`). A channel-less reply to `ALL-0` goes to the topic's latest agent (`topicReplyAgent`). In a channel, the post fans out to member agents when `WUIDispatch` is on. | `wui.go:741`, `dispatch.go:134`, `topic_reply.go:26` |
| 3 | The envelope is signed as `box-wui` for the agent's box (`dispatchEnvelope`). | `dispatch.go:228` |
| 4 | `commitRow` stores the row, queues it for the box (`Store.Enqueue`) and fans it out to browsers (`fanoutWUI`). | `internal/hub/ws.go:1014`, `commitRowTyped` `:1037`, `fanoutWUI` `wui.go:1024` |
| 5 | After the ack, `wuiAfterStore` runs the post's after-steps: the fallback responder and the hub notes, including the owner's prio word. This is the hook a human-post trigger joins. | `wui.go:640-654`, `ownerPrioWord` `internal/hub/owner_prio_word.go:97` |
| 6 | If no agent the post was meant for is online, the fallback hands it to one online agent. | `fallbackPost` `fallback.go:236` |
| 7 | The box's hub client takes the `recv` frame, writes the agent's inbox and rings its pane. | `internal/hubclient/hubclient.go:612`, `receive` `:988`; fallback poke `internal/hubclient/fallback.go:72` |
| 8 | The agent answers with `spool send` or `do_spl_desk_reply`. The hub's `onSend` checks it and stores it with `commitRowTyped`, then meters the turn. This is the hook an agent-reply trigger joins. | `ws.go:651`, store `:702`, `meterTurn` `:715` |
| 9 | On the desk, `do_spl_take_auto` gives a new human post in a topic to a dispatcher. The topic's owning agent is the first agent reply to `ALL-0` or `HUM-*`. | `csi-spl-orc/src/bash/run/spl-take-auto.func.sh:52`, `spl_take_auto_owner` `:160` |

## 4. The flow end to end

### 4.1 Set, edit, pause, delete: the "Discussion loops" entry

1. On a topic card (the opening card in the channel feed, and the topic list
   row, which share one menu, `topicCardMenuOpts`,
   `csi-spl-wui/src/utils/topic-menu.mjs:76`), the right-click menu gets
   **Discussion loops…** (`id: 'topic-loops'`, msg `19acb8f9`). It sits with
   the other topic-level entries in `msgMenuItems`
   (`csi-spl-wui/src/utils/msg-menu.mjs:85`). For a viewer the archive
   policy does not allow (answer 5 A), it shows disabled with the reason,
   through `locks` (`topicMenuLocks`, `topic-menu.mjs:38`; the `gated`
   helper, `msg-menu.mjs:94`), as Archive does (CLE-77891). This entry is
   the only place a loop shows (answer 7 C): no badge, no topic notes, no
   mark on any message.
2. The entry opens `TopicLoopsDialog.vue`:
   - the topic's loops, one row each: its title (v0.11: the trigger with
     its parameter, 8.8 changes 1 and 2), the first line of the prompt, its
     state (`on`, `paused`, or `held until hh:mm` by
     the cap), and its author;
   - per row: **Edit**, **Pause** / **Resume**, **Delete**;
   - **Add loop**.
   Add and Edit open the same form: the prompt (a textarea, at most 4000
   characters) and the twelve triggers of 1.2 as one radio group (v0.11,
   8.8 changes 3 and 9; v0.10 had checkboxes, answer 3 B), with a number
   field for n (5..1440) next to "each n minutes", a text field (1..200
   characters) next to "a post that contains", a number field for n
   (5..1440) next to "no reply for n minutes", and a time (hh:mm) plus a
   time zone (default: the browser's zone) next to "every day at". Each
   field is required exactly when its box is checked. Exactly one trigger
   is picked (v0.11). Under "after each agent reply" the form says that the
   agent's answer to this loop's own prompt does not fire it again (Q10 A).
3. The routes, with the shape of `PUT /v1/topics/{task_id}/priority`
   (`internal/hub/topic_priority.go:38`, handler `:52`, auth
   `priorityAllowed` `:176`), each checked with `mayArchiveByPolicy`
   (`internal/hub/topic_archive.go:172`), as spec 179 section 3.1 does for
   pause:
   - `GET /v1/topics/{task_id}/loops`: the list (read door: any member who
     can read the topic; editing needs the policy);
   - `POST /v1/topics/{task_id}/loops` `{"prompt": "...", "triggers": [...]}`:
     add, `201` with the loop;
   - `PUT /v1/topics/{task_id}/loops/{loop_id}`
     `{"prompt"?, "triggers"?, "state"?: "on" | "paused"}`: edit, pause,
     resume; an edit of the prompt or triggers resets the hour counter;
   - `DELETE /v1/topics/{task_id}/loops/{loop_id}`: idempotent `200`.
4. Each write sends one `topic_loops` frame to the topic's viewers who have
   the dialog open (the list's new version), and writes no message in the
   topic (answer 7 C).

The loops are read only by this dialog. The topic list and the topic view
carry nothing new, so their statements and round trips do not change.

### 4.2 Trigger

Every fire is decided by `topicLoopFire(ctx, tenant, task, event)`, where
`event` is one of the eleven trigger keys of 1.2 plus the post (none for a
time fire, the issue change for an issue fire). The hooks:

1. **`after_human_reply`**: in `wuiAfterStore` (`wui.go:647`), after
   `ownerPrioWord`. `wuiAfterStore` runs only for an inserted row
   (`if r.inserted`, `wui.go:640`), so a replay never fires.
2. **`after_agent_reply`**: in `onSend` (`ws.go:702-716`), after
   `commitRowTyped`, only when `r.inserted` and the send is an agent reply
   (section 2). It runs after the `sent` frame, so the agent box never waits.
3. **`before_agent_reply`**: in `wuiSend`, after every refusal check and
   right before `commitRow` (`wui.go:623`), only when the post goes to an
   agent (`rt.signing.agent`, set at `wui.go:777`, or a channel fan-out,
   `rt.signing.fanOut`, `wui.go:797`). The loop prompt is stored and queued
   first, so the agent's inbox holds it before the post. Target: that agent
   (or, for a fan-out, the topic's agent, answer 1 A). L2's test proves the
   box receives the two in that order. A post refused later fires nothing,
   because the hook runs after the last refusal; if `commitRow` then fails,
   the prompt stays alone and the hub logs it.
4. *Dropped in v0.6 (Q11 C):* `before_human_reply` has no hook. The step
   number stays so the references of v0.5 still point at the same steps.
5. **`every_hour`, `every_n_minutes`, `daily_at`, `no_reply_after_human`**:
   a hub ticker, `runTopicLoopTimer`, every 60 s, the pattern of the
   calendar sync (`runGcalSync`, `internal/hub/gcal_sync.go:79-98`,
   `gcalSyncEvery` 60 s, `:44`). Row L2 owns it. Each tick claims due loops
   with one `UPDATE ... WHERE least(next_due_at, idle_due_at, daily_due_at)
   <= now() ... RETURNING` (`ClaimDueTopicLoops`, 7.1.1), which moves each
   due column on in the same statement (`next_due_at` by the interval,
   `daily_due_at` to the next day's `daily_at` in `daily_tz`, `idle_due_at`
   to NULL) and says which keys came due (`TopicLoop.Due`), so two hub
   instances never fire the same tick. A tick missed while no instance ran
   fires once at the next tick: no catch-up burst. Two keys due in one tick
   fire once. A time fire's prompt quotes the topic's latest post, or says
   "no new post since the last fire"; an idle fire quotes the human post
   that armed it (`idle_post`).
6. `topicLoopFire` reads the topic's `on` loops with one index probe
   (`(tenant_id, task_id)`). To keep a tenant with no loops at zero extra
   probes, a per-tenant "has loops" bit is kept in memory and refreshed on
   every loop write. L2 measures it with `TestRoundTripsPerRequest` on
   `WS wui send` and on a box send.
7. A loop fires when every check holds; a failed check is logged once with
   its reason and sends nothing:
   - one of its checked triggers matches (a post that matches two checked
     boxes fires once);
   - the post is not a loop prompt message;
   - the post is not the awaited answer to this loop's last fire (Q10 A,
     4.4);
   - `after_agent_reply` matches only a post that is the awaited answer to
     no loop of the topic (N4 B, 1.6, v0.8); the loop's other boxes still
     match it;
   - the topic is not archived (`messages.archived_at`) and not paused (the
     store's `AnyTopicPaused`,
     `csi-spl-api/src/go/spool-hub-api/internal/store/topic_pause.go:74`,
     landed with spec 179 B1);
   - the loop's author is still a member and the archive policy still lets
     them edit loops (answer 5 A), both read with the author's member id
     (`SetBy`, 7.1.1);
   - the loop's cap is not reached: under 12 fires in its current hour
     (answer 4 B).
8. **`post_has_keyword`**: in the two post hooks (steps 1 and 2), on an
   agent reply or a human post whose body contains the loop's `keyword`,
   case-free, at word edges (a phrase matches as a whole; "PDF" matches
   "pdf," but not "pdfs"). The match is one pure function in the hub,
   `topicLoopKeyword(keyword, body string) bool`, on the body as stored
   (markdown, not rendered), over the loops already read in step 6: no
   extra store probe.
9. **`post_has_file`**: in the same two hooks, on an agent reply or a human
   post whose `Files` (`store.go:138`) holds at least one file. v0.11 (8.8
   change 9): **`post_has_file_agent`** fires on an agent reply or an
   agent's blocker to another agent (the `onSend` hook) with at least one
   file, **`post_has_file_human`** on a human post with at least one file
   (`wuiAfterStore`); `post_has_file` keeps firing on both.
10. **`blocker_posted`**: three places, any sender, any recipient:
    - `onSend` (`ws.go:702-716`), for every inserted row with
      `kind = blocker` on the topic's task id, also agent-to-agent (unlike
      step 2, which takes agent replies only);
    - `wuiAfterStore` (`wui.go:647`) for a browser post stored as a
      blocker;
    - `handleSetMessageKind` (`message_kind.go:123`, inside `if c.Seq > 0`),
      when `c.To == blockerKind` and `c.From != blockerKind`: a post marked
      a blocker afterwards. The quoted post is that message.
    The blocker-issue sweep (`RunBlockerIssues`, `blocker_issue.go:90`) is
    not a hook: it reads blockers after the fact, and would fire late and
    twice.
11. **`no_reply_after_human`**: armed in step 1's hook: every human post
    sets, on the topic's loops with this trigger, `idle_due_at = post +
    idle_min` and `idle_post = <its msg_id>` (`ArmTopicLoopIdle`); a later
    human post re-arms from its own time. Cleared in step 2's hook: any
    agent reply in the topic sets `idle_due_at = NULL`
    (`ClearTopicLoopIdle`). Fired by the ticker (step 5), once per arming.
    A loop prompt message neither arms nor clears it.
12. **`issue_status_changed`**: in `updateIssue` (`issues.go:419`), after
    `UpdateIssue` (`:449`) and its fan-out, when `p.Status != nil` and the
    status differs from the one before the write (the hub reads it with
    `GetIssue`, `internal/store/issues.go:391`, only when the workspace has
    loops, step 6). The issue's topics come from `IssueDiscussionLinks`
    (`issue_discussions.go:94`); each topic's loops with this trigger fire
    once. Every status change through the hub passes here: the browser's
    issue route, the agent's (`issues_agent.go`) and the blocker paths
    (`blocker_issue.go`, `blocker_issue_hold.go`) all call `updateIssue`
    (`git grep -c "s.updateIssue(" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/` -> 4 files: 1, 2, 1, 1 calls).
    Not covered: the issues an epic's close cascade closes inside the store
    (`internal/store/issues.go:195-200`: "that cascade closes its issues
    inside the store, not through UpdateIssue"); only the epic named in the
    write fires. The prompt quotes `SPL-<n> <title>: <before> -> <after>,
    by <actor>`.

### 4.3 Send

1. Target (answer 1 A): `topicAgents` (`topic_reply.go:52`) gives the agents
   that wrote in or were addressed in the topic, newest first; the target is
   the newest one announced now. With none, nothing is sent and the hub logs
   one line. A loop fired by an agent reply goes to that agent.
2. The message (answers 2 A and 8 A): `kind: task`,
   `from: <author HUM-n>`, `to: <agent>`, `task_id: <topic>`, signed as
   `box-wui` with `dispatchEnvelope` (`dispatch.go:228`) for the agent's box,
   stored with `commitRowTyped` and `loop_id = <loop>` (5.2), and queued for
   the box. It is not fanned out to browsers (5.2). The body:

   ```text
   Loop prompt (background; set by @HUM-n, fired by msg:<trigger uuid>)

   <prompt text>

   > <the trigger post, cut to 600 characters, one quote block>
   ```

   The first line is the mark of answer 8 A, for the agent. The agent
   answers in the topic as with any human's task (Q9 A).
3. Its `msg_id` is a UUIDv5 of `(loop_id, trigger msg_id)`. A second try for
   the same trigger is then a no-op insert, the rule `postHubNote` uses for
   its id (`internal/hub/blocker_issue.go:481`). A fire with no trigger post
   seeds on its cause instead (7.1.1): a time fire on the due time, an issue
   fire on the issue, its new status and the time of the write.
4. Target of the new triggers: a post trigger (`post_has_keyword`,
   `post_has_file`, `blocker_posted`) follows step 1 (an agent's post goes
   to that agent, a human's to the topic's agent); `no_reply_after_human`,
   `daily_at` and `issue_status_changed` go to the topic's agent.
5. The box gets it as any `@agent` post (section 3, step 7): inbox plus pane
   poke. The desk needs no change.
   A loop prompt is never mirrored as a DM (SPL-6309): it is `from` the
   author on the topic uuid, the shape of that author's DM, so the box
   notifier tells it apart by the body's first-line mark
   (`spool_notify_is_loop_prompt`, `spool-notify.inc.sh`). Its typed line
   gets the `task` trigger of spec 067 3.1 and sets no `.mirror/peer`; the
   terminal mirror posts nothing for its turn, and the agent's real answer
   reaches the topic as in 4.4. Measured on prd before the fix (n=2): each
   fire gave the author the seat's post and, a minute later, its pane text
   again as a seat -> author DM.

### 4.4 Reply

1. The agent answers in the topic as usual, to the author or to `ALL-0`.
   That answer is an ordinary, visible reply (Q9 A).
2. That answer is an agent reply. The fire sets `awaiting = <agent>` and
   `awaiting_until = fire + 30 min` (`SetTopicLoopAwaiting`, 7.1.1); the
   agent's next agent reply in the topic before then clears both and does
   not fire this loop (Q10 A, 1.4). It fires no loop's `after_agent_reply`
   box either (N4 B, 1.6, v0.8); another loop's other boxes still fire on
   it.
   After `awaiting_until`, or once that reply has cleared it, the agent's
   replies fire this loop again like any other.

### 4.5 Stop

- **By a person**: Pause or Delete in the dialog (4.1). A paused loop keeps
  its prompt and fires nothing until Resume.
- **By the cap** (answer 4 B): after 12 fires in the loop's hour, it holds;
  it fires again when the hour rolls over. The dialog shows "held until
  hh:mm". No note is written (answer 7 C).
- **By the topic**: archiving the topic deletes its loops; so does
  deleting the topic (v0.5). **Row L2 owns it** (v0.5): `handleArchiveTopic`
  (`internal/hub/topic_archive.go:197`) calls `DeleteTopicLoops` (L1, 7.1.1)
  after `SetArchived` (`:205`) succeeds with archive on, and
  `handleDeleteTopic` (`:245`) after `DeleteTopic` (`:251`). A failed delete
  is logged and the archive still answers: an archived topic's loops fire
  nothing anyway (4.2 step 7). Unarchiving restores none. A topic pause
  (spec 179) keeps them and fires nothing; resume needs no step.
- **By the author leaving** the workspace, or losing the archive right: the
  loop fires nothing (4.2 step 7); the dialog says why, and anyone allowed
  may delete it or take it over by editing it (the editor becomes its
  author).

### 4.6 Worked example: the topic as a PDF, mailed after each agent reply

HUM-10 (msg `92050cbc`, verbatim): "an example loop would be I would like
the whole discussion to be exported as pdf and send to me as an email after
each reply to me by an agent".

| step | what happens | built today? |
|---|---|---|
| set | The owner opens **Discussion loops…**, adds a loop with the prompt "Export this whole discussion as a PDF and mail it to me." and checks `after_agent_reply` (every agent reply in the topic, to anyone; Q11 C dropped the narrower "before each human reply") | rows L1-L3 |
| trigger | An agent replies to HUM-10 in the topic; the hub stores it (`ws.go:702`) and fires the loop | rows L1-L2 |
| send | The topic's agent gets the loop prompt in its inbox, the agent reply quoted (4.3); nobody sees the prompt in the topic (5.2) | rows L1-L2 |
| export | The agent makes a PDF of the whole topic | **missing**, (a) below, row L6 |
| mail | The agent mails the PDF to HUM-10 | **missing**, (b) below, row L7 |
| answer | The agent replies "PDF sent" in the topic (Q9 A) | built |
| stop | That reply does not fire this loop again (Q10 A), nor any other loop's "after each agent reply" box (N4 B, v0.8) | rows L1-L2, (c) below |

Measured on `origin/master` `412a44ab0`:

- **(a) No topic PDF an agent can make.**
  `git grep -il pdf origin/master -- csi-spl-api csi-spl-orc/src/bash/run csi-spl-orc/src/bash/scripts`
  lists only `internal/files/sniff.go` (file type sniffing),
  `internal/search/grammar.go` (a search filter) and tests; nothing in orc.
  The only PDF export is the browser's print in the WUI:
  `csi-spl-wui/src/components/MessagePrint.vue`, `TopicExportPdf.vue`,
  `src/utils/msg-print.ts`, `msg-print-run.ts` (SPL-5888). This box has
  `/usr/bin/google-chrome` and `/usr/bin/pandoc` (`which`), but no action
  uses them for a PDF, and they are not a box requirement anywhere.
- **(b) No way for an agent to mail a file to a person.** The hub's mail
  package sends text only: `mail.Message` is `To`, `Subject`, `TextBody`,
  `Template`, `Locale`, `MessageID` (`internal/mail/mail.go:28-39`;
  `git grep -c Attach origin/master -- csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go`
  -> 0). Its callers are sign-in (`internal/auth/native.go:48`), invites
  (`internal/invitemail`), the embed relink and payments. The only mail verb
  of the `spool` CLI is `hub-invite-mail` (`cmd/spool/main.go:100`), which
  resends an invite. No orc, iac or utl action sends mail
  (`git grep -nE "sendmail|mailx|smtp" origin/master -- csi-spl-orc/src/bash/run csi-spl-iac/src/bash/run csi-spl-utl/src/bash/run`
  -> nothing). An agent also does not know, and must not learn, a person's
  address.
- **(c) Self-fire.** With `after_agent_reply` checked, the agent's "PDF
  sent" is itself an agent reply, so under answer 4 B the loop fires again:
  12 PDFs and mails within minutes for one real reply, then a hold until
  the hour rolls over. The owner answered Q10 A (1.4): the agent's answer
  to a loop prompt never fires that loop, so one real reply makes one PDF
  and one mail.

The two missing pieces become rows L6 and L7 (section 7). L7 sends to the
loop's author only: the hub checks that the request names a loop prompt
message of that topic whose loop belongs to the person mailed, so an agent
can mail a person only because that person's loop asked it to.
Row L6 is specified, with its contracts, in [spec 183](../183-agent-topic-pdf-export/spec.md).

## 5. Store

### 5.1 The loops table

New forward-only migration `<NNNN>_topic_loops.sql`, numbered by
`do_rdb_migration_next` at build time (head on `origin/master`: `0298`).
The shape follows `0214_topic_priorities.sql` and `0297_topic_pauses.sql`:
RLS and the `change_stamp` trigger. Several loops per topic (answer 6 B),
so the key is the loop id.

```sql
CREATE TABLE IF NOT EXISTS topic_loops (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    loop_id       uuid        NOT NULL,
    task_id       uuid        NOT NULL,
    prompt        text        NOT NULL CHECK (prompt <> '' AND length(prompt) <= 4000),
    triggers      text[]      NOT NULL CHECK (triggers <@ ARRAY['after_agent_reply','before_agent_reply','after_human_reply','every_hour','every_n_minutes','post_has_keyword','post_has_file','blocker_posted','no_reply_after_human','issue_status_changed','daily_at'] AND cardinality(triggers) >= 1),
    interval_min  integer     CHECK (interval_min BETWEEN 5 AND 1440),
    next_due_at   timestamptz,
    keyword       text        CHECK (keyword <> '' AND length(keyword) <= 200),
    idle_min      integer     CHECK (idle_min BETWEEN 5 AND 1440),
    idle_due_at   timestamptz,
    idle_post     uuid,
    daily_at      time,
    daily_tz      text        NOT NULL DEFAULT 'UTC' CHECK (daily_tz <> '' AND length(daily_tz) <= 64),
    daily_due_at  timestamptz,
    set_by        text        NOT NULL CHECK (set_by <> '' AND length(set_by) <= 64),
    set_at        timestamptz NOT NULL,
    state         text        NOT NULL DEFAULT 'on' CHECK (state IN ('on','paused')),
    hour_start    timestamptz,
    fires_in_hour integer     NOT NULL DEFAULT 0 CHECK (fires_in_hour >= 0),
    fires_total   integer     NOT NULL DEFAULT 0 CHECK (fires_total >= 0),
    last_fired_at timestamptz,
    awaiting      text        NOT NULL DEFAULT '' CHECK (length(awaiting) <= 64),
    awaiting_until timestamptz,
    PRIMARY KEY (tenant_id, loop_id),
    CHECK ((interval_min IS NOT NULL) = ('every_n_minutes' = ANY (triggers))),
    CHECK ((keyword IS NOT NULL) = ('post_has_keyword' = ANY (triggers))),
    CHECK ((idle_min IS NOT NULL) = ('no_reply_after_human' = ANY (triggers))),
    CHECK ((daily_at IS NOT NULL) = ('daily_at' = ANY (triggers)))
);
CREATE INDEX IF NOT EXISTS topic_loops_task ON topic_loops (tenant_id, task_id);
CREATE INDEX IF NOT EXISTS topic_loops_due ON topic_loops (least(next_due_at, idle_due_at, daily_due_at)) WHERE state = 'on';
```

- `interval_min` is set exactly when `every_n_minutes` is checked.
  `next_due_at` is set when `every_hour` or `every_n_minutes` is checked
  (`set_at` + the shorter of 60 min and `interval_min`), moved on by every
  time fire, and NULL otherwise or while paused.
- `keyword`, `idle_min` and `daily_at` are set exactly when their trigger
  is checked. `daily_tz` is an IANA zone name; the hub checks it with
  `time.LoadLocation` before the write (a CHECK cannot), and Postgres reads
  it in `AT TIME ZONE`. `daily_due_at` is the next `daily_at` in `daily_tz`
  after the write or the last fire; NULL otherwise or while paused.
- `idle_due_at` and `idle_post` are written only by the hooks of 4.2 step
  11 and the ticker; NULL while paused. Resume, and an edit of the triggers
  or the times, recompute `next_due_at` and `daily_due_at` and clear
  `idle_due_at`.
- `least()` skips NULLs in Postgres, so `topic_loops_due` is one index for
  the three due times; a loop with none of them is a NULL key the ticker's
  `<= now()` never reads.
- `awaiting` and `awaiting_until` serve Q10 A (4.4): written by the fire,
  cleared by the awaited reply or read as expired after `awaiting_until`.
- The fire counts in the same statement that checks the cap
  (`UPDATE ... SET fires_in_hour = CASE WHEN hour_start <= now() - interval '1 hour' THEN 1 ELSE fires_in_hour + 1 END ... WHERE ... AND (hour_start <= now() - interval '1 hour' OR fires_in_hour < 12) RETURNING ...`),
  so two hub instances never fire past the cap.
- A cap of 12 is a hub option (`SPOOL_HUB_TOPIC_LOOP_CAP`, default 12), not
  a column.
- Channel move or copy (spec 169): the table is added to
  `internal/channelmove/catalogue.go` as `Moved`, keyed on `task_id`.

### 5.2 The loop prompt message stays out of sight (msg eae9e64f)

A new column `messages.loop_id uuid NULL` (same migration). A row with it
set is a loop prompt message. Every place that shows or counts topic
messages leaves such a row out, the way they already treat a note to self
(`messages.note_to_self`, rdb `0278`), but for every viewer:

| place | file | change |
|---|---|---|
| browser fan-out | `internal/hub/wui.go:1024` `fanoutWUI` | returns at once for a row with `LoopID` set |
| topic and thread views, search | `internal/store/view_postgres.go`, `view_topics_batch.go`, the search statements | `AND m.loop_id IS NULL`; the list's golden pin `testdata/view_topics_sql.golden` regenerated |
| topic head (spec 099) | `0144_topic_heads.sql` trigger functions | a loop row does not move the head (new `CREATE OR REPLACE` in the same migration; the oracle in `topic_head_harness_test.go` follows) |
| fallback responder | `internal/store/fallback_postgres.go:79-83` `fallbackHumanPostSQL` | `AND m.loop_id IS NULL`: a loop prompt is never "a human post nobody heard" |
| unanswered sweep | `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` (its rows read, near the `note_to_self` column at `:519`) | a loop row is never a human post waiting for an answer, and never an anchor |
| auto-take | `csi-spl-orc/src/bash/run/spl-take-auto.func.sh:52` | skips a loop row |
| channel counts and unread (v0.7) | `internal/store/channels_postgres.go:391` `countsRead` (its `FROM messages`, `:405`, and the newest-message `LATERAL`, `:408`), called by `ViewChannelStats` (`:325`); Memory `channels_memory.go:398` | `AND loop_id IS NULL` in both reads: a loop prompt counts in no channel total, poster count, unread, or "newest message" |
| view changes (v0.7) | `internal/store/view_changes_postgres.go:27` `viewChangesSQL` (the `new` branch, `:31`); Memory `view_changes.go:82` `ViewChanges` | the `new` branch skips a loop row (`AND loop_id IS NULL`), so a browser's change poll never names it |
| topic PDF export (v0.7, spec 183) | `internal/store/topic_export.go:76` Postgres `TopicExportRows` (its `FROM messages`, `:83`), Memory `:28`; route `internal/hub/topic_export.go:34` | `AND loop_id IS NULL`: the exported PDF holds the agent's answer, never the loop prompt |

The row is still stored, so the agent's reply threads to a real message,
the store keeps it as the record of each fire.

## 6. What is reused, what is missing

| part | reused as it is | missing (built here) |
|---|---|---|
| menu entry | `msgMenuItems` + `gated` + `locks` (`msg-menu.mjs:85,94`), `topicMenuLocks` (`topic-menu.mjs:38`), the emit switch `choose` (`csi-spl-wui/src/components/MessageMenu.vue:158`), the card's menu mount (`MessageCard.vue:405`), the feed's `topic-menu` prop (`LiveFeed.vue:102`) | item `topic-loops`, its lock reason, its emit, the card handler |
| permission | `mayArchiveTopic` (`csi-spl-wui/src/utils/topic-archive.mjs:74`) and `mayArchiveByPolicy` (`topic_archive.go:172`) | nothing new |
| dialog | dialog patterns of `TopicDeleteDialog.vue`, `TopicExportPdf.vue` | `TopicLoopsDialog.vue` (list + form), keys in the 19 locale files (`csi-spl-wui/i18n/locales/`) |
| routes | the `PUT /v1/topics/{task_id}/priority` shape (`topic_priority.go:38,52,176`) | `GET`/`POST /v1/topics/{task_id}/loops`, `PUT`/`DELETE .../loops/{loop_id}`, the `topic_loops` frame |
| store | `TopicPauseStore` layout (`internal/store/topic_pause.go`), `0297` | `topic_loops` + `messages.loop_id` migration, `TopicLoopStore` (Postgres + Memory), RLS registration |
| trigger hooks | `wuiAfterStore` (`wui.go:647`), `onSend` after store (`ws.go:702-716`), `handleSetMessageKind` (`message_kind.go:65,123`), `updateIssue` (`issues.go:419,449`) with `IssueDiscussionLinks` (`issue_discussions.go:94`), the 60 s ticker pattern (`gcal_sync.go:79-98`) | `topicLoopFire`, its calls, `topicLoopKeyword`, the idle arm and clear, `runTopicLoopTimer` |
| send | `topicAgents` (`topic_reply.go:52`), `dispatchEnvelope` (`dispatch.go:228`), `commitRowTyped` (`ws.go:1037`) | the body, the UUIDv5 id, `loop_id` on the row |
| hidden prompt | the `note_to_self` precedent (rdb `0278`) | the nine places of 5.2 (v0.7) |
| box and desk | `recv` -> inbox + poke (`hubclient.go:612,988`) | nothing |
| pause, archive | `AnyTopicPaused` (`store/topic_pause.go:74`), `messages.archived_at` | the two checks in `topicLoopFire`; delete on archive |

## 7. Build order (rows a later lane can take)

| row | depends on | kind | scope | tests and red control |
|---|---|---|---|---|
| **L1 rdb + store** | — | `complex_coding` | `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_topic_loops.sql` (`topic_loops` with the v0.4 columns of 5.1, `messages.loop_id`, the topic-head functions); `internal/store/{topic_loop.go,topic_loop_postgres.go,topic_loop_memory.go,topic_loop_test.go}`; `view_postgres.go`, `view_topics_batch.go`, `fallback_postgres.go`, `fallback_memory.go`; v0.7: `channels_postgres.go`, `channels_memory.go`, `view_changes_postgres.go`, `view_changes.go`, `topic_export.go`; `rls_test.go`; `internal/channelmove/catalogue.go` | `PRE_PUSH_TIER=full`: Postgres + Memory parity; each of the eleven keys is accepted and an unknown one refused, `before_human_reply` included (v0.6); each field CHECK (keyword, idle, daily) refuses a stray or missing value; `ClaimDueTopicLoops` claims each of the three due columns, reports it in `Due` and its pre-move time in `DueAt` (v0.5), moves `daily_due_at` across a DST change in `Europe/Helsinki` by one local day; `ArmTopicLoopIdle` / `ClearTopicLoopIdle` touch only that task's idle loops; the cap `UPDATE` never passes 12 under two concurrent fires and rolls over after an hour; a `loop_id` row is in no view, no topic head and no fallback read, and (v0.7) in no channel count or unread, no view change and no topic export row; a negative `fires_in_hour` or `fires_total` is refused; RLS covers the table. Red control: drop `AND m.loop_id IS NULL` from the topic view statement, and the hidden-row test fails. |
| **L2 hub** | L1 | `complex_coding` | `internal/hub/{topic_loop.go,topic_loop_fire.go,topic_loop_test.go,topic_loop_fire_test.go}`; the hooks in `wui.go` (before and after the store) and `ws.go`; the `fanoutWUI` skip; the time ticker `runTopicLoopTimer`; v0.5: the `DeleteTopicLoops` calls in `topic_archive.go` (4.5) | Each of the eleven boxes fires on its event; v0.6: the target agent's first reply within 30 min of a fire does not fire that loop (any post trigger: agent reply, keyword, file, blocker); v0.8 (N4 B): nor another loop's `after_agent_reply` box, while another loop's keyword box still fires on it, and its next reply, or a reply after 30 min, fires it again; the keyword match at word edges (and not inside a word); a file post fires `post_has_file`, a plain one does not; a blocker fires from an agent-to-agent send, a browser post and a kind change, and the kind change back does not; an idle loop fires once after n minutes with no agent reply, never after an agent reply, and re-arms on a later human post; a daily loop fires once a day at its local time; an issue status change fires the loops of each linked topic once, a priority-only change does not; `before_agent_reply`'s prompt reaches the box before the post; a time loop fires once per due tick across two hub instances and never catches up a burst; a post matching two boxes fires once; a replay does not; a loop prompt message does not; HUB-0 and pause notices do not; paused loops, paused and archived topics do not; the 13th fire in an hour does not; v0.5: a loop with `every_n_minutes` and `daily_at` whose daily fire follows an interval fire sends both (two msg_ids); archiving or deleting the topic leaves no loop, unarchiving brings none back; a member whose session id is not a v:1 id sets a loop that fires, from the derived `HUM-<n>`; the policy table (`everyone`, `admins`, `starter`); no browser frame for a loop row; `TestRoundTripsPerRequest` shows no extra round trip on a tenant with no loop. Red control: remove the cap check, and the agent-reply self-fire test passes 12. |
| **L2b orc** | L1 | `simple_coding` | `spl-unanswered-sweep.func.sh`, `unanswered-sweep-classify.py`, `spl-take-auto.func.sh` and their tests | a loop row is never listed, re-sent or escalated, and never taken. Red control: drop the skip, and the sweep test lists the loop prompt as unanswered. |
| **L3 wui** | L2 | `simple_coding`, then `i18n` (agy has the last word on the locales) | `msg-menu.mjs`, `topic-menu.mjs`, `MessageMenu.vue`, `MessageCard.vue`, `TopicLoopsDialog.vue`, `spool-client*.mjs`, `i18n/locales/*.json` | `pnpm run typecheck`, `test:unit` (i18n parity, untranslated and raw-text gates, cleancode, a `topic-loops` unit test of the menu lock, the form's at-least-one-trigger rule, and each of the four fields required exactly with its box: n, keyword, idle n, time and zone). Red control: a raw string in the dialog, and `i18n-no-raw-text` fails. |
| **L4 e2e** | L3 | `tests` | `csi-spl-wui/tests/e2e/topic-loops.test.mjs` | `BASE_URL=<bundle> pnpm run test:e2e` on the mock: add a loop from the menu, edit it, pause it, delete it; a human post shows no loop prompt card in the topic. Red control: skip the emit, and the dialog never opens. |
| **L6 orc: topic PDF** | — | `simple_coding` | `csi-spl-orc/src/bash/run/spl-topic-pdf.func.sh` (`do_spl_topic_pdf`: `TOPIC_ID`, `ENV`, `OUT`), a script that renders the topic (its rows from `spool hub-tail --task <uuid> --with-channel`, its pictures from the files API) to HTML and prints it with headless Chrome; a `do_box_pkg_install` record for the Chrome it needs; its test | a fixture topic of 3 posts and 1 picture makes a PDF with 3 posts (`pdftotext` count) and the picture; a missing Chrome fails fast with the install command. Red control: drop the picture fetch, and the picture check fails. |
| **L7 api: mail a file to a loop's author** | L1, L2 | `secret` (it handles people's addresses; claude or grok, data rule) | `internal/mail/mail.go` (`Message.Attachments`, a MIME multipart body), a box route `mail_file` and the `spool mail-file --task <uuid> --cause <loop prompt msg_id> --file <path> [--subject ...]` verb (`cmd/spool/main.go`); the hub resolves the address of the loop's author, never the agent | the hub mails only when `--cause` is a loop prompt message of that task whose loop's author is the person mailed (else `403 not_allowed`); at most 12 mails per loop per hour; the address is in no log and no answer; the attachment arrives (`mail.Recorder`). Red control: drop the author check, and a test mailing another member passes. |
| **L5 docs** | L2, L3 | `specs_and_docs` | this spec's row status; `csi-spl-doc/doc/md/spool-cli-reference.md` only if a CLI verb is added | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` |

Q10 and Q11 are answered (1.4); v0.6 removes one key and keeps every other
contract (8.3). L1, L2, L2b, L3 and L6 can run in parallel against the contracts of 7.1. L7 waits for
L1 and L2.

### 7.1 Contracts for parallel rows (binding)

These are binding: a row that needs to change one asks the dispatch holder
first, and the change lands in this spec before the code. Every name below
is new unless a file:line is cited.

#### 7.1.1 Go store (L1 builds it, L2 calls it)

Package `store`, file `internal/store/topic_loop.go`, implemented by
`Memory` and `Postgres` (`var _ TopicLoopStore = (*Memory)(nil)` and
`(*Postgres)(nil)`), in the workspace's own scope, as `TopicPauseStore`
(`internal/store/topic_pause.go`).

```go
const (
	LoopAfterAgentReply       = "after_agent_reply"
	LoopBeforeAgentReply      = "before_agent_reply"
	LoopAfterHumanReply       = "after_human_reply"
	LoopEveryHour             = "every_hour"
	LoopEveryNMinutes         = "every_n_minutes"
	LoopPostHasKeyword        = "post_has_keyword"     // v0.4
	LoopPostHasFile           = "post_has_file"        // v0.4
	LoopBlockerPosted         = "blocker_posted"       // v0.4
	LoopNoReplyAfterHuman     = "no_reply_after_human" // v0.4
	LoopIssueStatusChanged    = "issue_status_changed" // v0.4
	LoopDailyAt               = "daily_at"             // v0.4
	TopicLoopIntervalMin      = 5    // minutes; also the idle n's bounds
	TopicLoopIntervalMax      = 1440 // minutes
	TopicLoopKeywordMax       = 200  // characters, rdb CHECK (v0.4)
	TopicLoopOn               = "on"
	TopicLoopPaused           = "paused"
	TopicLoopPromptMax        = 4000 // characters, rdb CHECK
)

// TopicLoopTriggers: the eleven keys in the order of 1.2 (v0.6).
var TopicLoopTriggers = []string{LoopAfterAgentReply, LoopBeforeAgentReply,
	LoopAfterHumanReply, LoopEveryHour, LoopEveryNMinutes,
	LoopPostHasKeyword, LoopPostHasFile, LoopBlockerPosted, LoopNoReplyAfterHuman,
	LoopIssueStatusChanged, LoopDailyAt}

// ErrBadTopicLoop: an empty or too long prompt, no trigger, an unknown
// trigger or state, a missing or stray interval, keyword, idle n or daily
// time, a daily zone time.LoadLocation refuses, or a set_by not 1..64
// characters. Before any write.
var ErrBadTopicLoop = errors.New("store: a topic loop needs a prompt (1..4000 characters), 1..11 known triggers, an interval of 5..1440 minutes exactly with every_n_minutes, a keyword of 1..200 characters exactly with post_has_keyword, an idle n of 5..1440 minutes exactly with no_reply_after_human, a time and a known zone exactly with daily_at, state on|paused and who (1..64)")

type TopicLoop struct {
	TenantID    string
	LoopID      string    // uuid, lower case
	TaskID      string    // uuid, lower case
	Prompt      string
	Triggers    []string  // distinct, sorted
	SetBy       string    // the author's member id (v0.5): see "The author's two ids" below
	SetAt       time.Time
	State       string    // TopicLoopOn | TopicLoopPaused
	HourStart   time.Time // zero: never fired
	FiresInHour int
	FiresTotal  int
	LastFiredAt time.Time // zero: never fired
	IntervalMin int       // 0 unless every_n_minutes
	NextDueAt   time.Time // zero: no time trigger, or paused
	Awaiting    string    // Q10 A: the agent whose next reply does not fire this loop
	AwaitUntil  time.Time
	// v0.4
	Keyword    string    // "" unless post_has_keyword
	IdleMin    int       // 0 unless no_reply_after_human
	IdleDueAt  time.Time // zero: not armed, or paused
	IdlePost   string    // msg_id of the human post that armed it; "" when not armed
	DailyAt    string    // "hh:mm", "" unless daily_at
	DailyTZ    string    // IANA zone; "" is read and written as "UTC"
	DailyDueAt time.Time // zero: no daily_at, or paused
	Due        []string  // set only by ClaimDueTopicLoops: the time keys that came due this claim
	DueAt      time.Time // v0.5, set only by ClaimDueTopicLoops: the earliest of NextDueAt, DailyDueAt that came due, as it was BEFORE the move; zero when only the idle key came due
}

// TopicLoopEdit: nil / empty fields are kept. A changed Prompt or Triggers
// resets HourStart and FiresInHour. By becomes SetBy and At SetAt (4.5).
type TopicLoopEdit struct {
	Prompt   *string
	Triggers []string // nil: keep
	Interval *int     // nil: keep
	State    *string
	Keyword  *string  // v0.4; nil: keep
	IdleMin  *int     // v0.4; nil: keep
	DailyAt  *string  // v0.4; nil: keep
	DailyTZ  *string  // v0.4; nil: keep
	By       string
	At       time.Time
}

type TopicLoopStore interface {
	// TopicLoops: every loop of taskID, SetAt then LoopID order.
	// ErrBadTopicTask (topic_priority.go:29) on a non-uuid task.
	TopicLoops(ctx context.Context, tenant, taskID string) ([]TopicLoop, error)
	// TopicLoopsOn: only State == on; the fire path's one index probe (4.2 step 6).
	TopicLoopsOn(ctx context.Context, tenant, taskID string) ([]TopicLoop, error)
	// AddTopicLoop stores l (LoopID minted with uid.New when ""), State on.
	// ErrBadTopicTask, ErrBadTopicLoop; ErrNotFound: no such workspace.
	AddTopicLoop(ctx context.Context, tenant string, l TopicLoop) (TopicLoop, error)
	// EditTopicLoop: ErrNotFound when loopID is not a loop of taskID.
	EditTopicLoop(ctx context.Context, tenant, taskID, loopID string, e TopicLoopEdit) (TopicLoop, error)
	// DeleteTopicLoop: false when there was no such loop (never an error).
	DeleteTopicLoop(ctx context.Context, tenant, taskID, loopID string) (bool, error)
	// DeleteTopicLoops: every loop of taskID (the archive path, 4.5); the count.
	DeleteTopicLoops(ctx context.Context, tenant, taskID string) (int, error)
	// CountTopicLoopFire is 5.1's single UPDATE: true and the row after it
	// when the loop is on and under cap in its hour (rolling the hour when
	// HourStart <= at - 1h); false when paused, capped or gone.
	CountTopicLoopFire(ctx context.Context, tenant, loopID string, at time.Time, cap int) (TopicLoop, bool, error)
	// ClaimDueTopicLoops is the time ticker's one UPDATE (4.2 step 5): up to
	// limit on state-on loops where any of NextDueAt, IdleDueAt, DailyDueAt
	// is <= at, every workspace. In the same statement it moves NextDueAt on
	// by the interval, DailyDueAt to the next DailyAt in DailyTZ, and sets
	// IdleDueAt to zero; each row as claimed carries Due (v0.4: was only
	// NextDueAt), e.g. ["every_n_minutes", "no_reply_after_human"], and
	// IdlePost as it was before the clear, and DueAt (v0.5) as it was
	// before the move.
	ClaimDueTopicLoops(ctx context.Context, at time.Time, limit int) ([]TopicLoop, error)
	// ArmTopicLoopIdle (v0.4, 4.2 step 11): on every state-on loop of taskID
	// with no_reply_after_human, IdleDueAt = at + IdleMin and IdlePost =
	// postID. The count of loops armed.
	ArmTopicLoopIdle(ctx context.Context, tenant, taskID, postID string, at time.Time) (int, error)
	// ClearTopicLoopIdle (v0.4): IdleDueAt and IdlePost cleared on every
	// loop of taskID. The count cleared.
	ClearTopicLoopIdle(ctx context.Context, tenant, taskID string) (int, error)
	// SetTopicLoopAwaiting writes Awaiting / AwaitUntil (Q10 A); "" clears.
	SetTopicLoopAwaiting(ctx context.Context, tenant, loopID, agent string, until time.Time) error
	// TenantHasTopicLoops refreshes the hub's in-memory bit (4.2 step 6).
	TenantHasTopicLoops(ctx context.Context, tenant string) (bool, error)
}
```

`store.Message` gains `LoopID string` (`""` = NULL), written by
`InsertMessage` and `InsertMessageSent` to `messages.loop_id`, and read back
by `FanoutRow` (`internal/store/wui_wake.go:32` Memory, `:42` Postgres, whose
`SELECT` gains `loop_id`). Without it a second hub instance that fans out on
a wake (`WakeWUI`, spec 059 S3) would push the loop prompt to browsers, past
the `fanoutWUI` skip.

Points the L2 lane asked to pin (c-970, msg `a74cc799`), as decided:

1. `Message.LoopID` through `FanoutRow`: confirmed, above.
2. The "has loops" bit: `TenantHasTopicLoops` (in the interface). The hub
   caches it per tenant, sets it on its own writes, and re-reads it after a
   30 s TTL, so another instance's first loop is seen within 30 s.
3. `TopicLoops` (one index probe) and the CRUD of the routes of 4.1:
   confirmed. The cap is one call that counts and checks:
   `CountTopicLoopFire(ctx, tenant, loopID, at, cap) (TopicLoop, bool, error)`;
   it answers the row too, because L2 needs `FiresInHour` and `Awaiting`
   after the count. Not `FireTopicLoop`.
4. `TopicLoopStore` is an optional interface: the hub reads it as
   `s.o.Store.(store.TopicLoopStore)`, like `store.ChannelAIAgents`
   (`internal/hub/channel_ai_agents.go:38`). A store without it: the
   routes answer `501 not_implemented` and nothing fires. L2 builds and
   tests against a `_test` double before L1 lands.
5. The time ticker is a hub goroutine, `runTopicLoopTimer` (4.2 step 5),
   and **row L2 owns it**; L1 owns `ClaimDueTopicLoops` only. No orc cron.

The fired message's id (4.3 step 3) is
`uid.FromSeed("topic-loop:" + loopID + ":" + triggerMsgID)`
(`internal/uid/uid.go:21`), so the UUID is minted where `cleancode_test.go`'s
folded list wants it. A fire with no trigger post (v0.4) seeds on its cause:

| fire | seed after `"topic-loop:" + loopID + ":"` |
|---|---|
| a post trigger, `before_agent_reply`, `no_reply_after_human` | the trigger post's `msg_id` (for idle: `IdlePost`) |
| `every_hour`, `every_n_minutes`, `daily_at` | `"due:" + DueAt` (RFC 3339 UTC; v0.5: the pre-move value the claim returns, never a post-move column) |
| `issue_status_changed` | `"issue:" + <number> + ":" + <new status> + ":" + <write time, RFC 3339 UTC>` |

Why the pre-move value (v0.5, c-970 point 1): the post-move columns are
not one per fire. A loop with `every_n_minutes` (60) and `daily_at` (09:00):
the 08:30 interval fire moves `next_due_at` to 09:30 and seeds on the
earliest post-move value, 09:30; the 09:00 daily fire leaves `next_due_at`
at 09:30, moves `daily_due_at` to tomorrow and seeds on 09:30 again. Same
msg_id, so the daily fire is a no-op insert and is lost. A pre-move value
is claimed once per column (the claim moves it past `at`), and two columns
due at the same time come due in the same claim and fire once (4.2 step 5).
Postgres `RETURNING` sees the new row, so L1 returns the old value from the
claim's locked `SELECT ... FOR UPDATE SKIP LOCKED` sub-query, joined in the
`UPDATE ... FROM`; Memory copies it before the move.

**The author's two ids** (v0.5, c-970 point 3). A browser request carries
two: the member id `hum` (`memberID`, `internal/hub/resolve.go:117`), which
`access` (`rbac.go:45`) and `mayArchiveByPolicy` read, and the v:1 `from`
(`editorID`, `edit.go:241`), which is `hum` when `msg.ValidID(hum)` and else
a `HUM-<n>` minted per hub process (`edit.go:246-249`, `humans.session`,
`wui.go:167`). On a Postgres hub a member id is `HUM-<n>` (rdb 0006
`humans.human_id` default `'HUM-' || nextval('humans_seq')`), so the two
are equal there; they differ for a session id that is not a v:1 id (spec
014 OQ-014-3, e.g. `HUM-google-sub-1@t1`, `wui.go:168`).
So `SetBy` stores `hum` (route: `q.hum`, not `q.from`), and every policy and
membership check of 4.2 step 7 and 4.5 reads it. Where a v:1 id is needed
(the fired message's `from`, the mark line and the loop JSON's `set_by`) the hub derives it
from `SetBy` by the same rule as `editorID`. A minted id is per process, as
it is for every post that member makes today: nothing new. `By` of
`TopicLoopEdit` is the editor's `hum` too.

The keyword match is the hub's, not the store's:
`topicLoopKeyword(keyword, body string) bool` in
`internal/hub/topic_loop_fire.go` (row L2). The issue hook reads links with
the existing `IssueDiscussionLinks` (`issue_discussions.go:94`); no new
store call.

#### 7.1.2 HTTP and WS (L2 serves them, L3 calls them)

The loop JSON, every route's answer:

```json
{
  "loop_id": "<uuid>", "task_id": "<uuid>", "prompt": "<text>",
  "triggers": ["after_agent_reply", "every_n_minutes"], "interval_min": 30,
  "next_due_at": "2026-11-20T10:00:00Z",
  "state": "on", "set_by": "HUM-10", "set_at": "2026-11-20T09:30:00Z",
  "fires_in_hour": 3, "held_until": "2026-11-20T10:12:00Z",
  "idle": "",
  "keyword": "pdf", "idle_min": 15,
  "daily_at": "08:00", "daily_tz": "Europe/Helsinki",
  "daily_due_at": "2026-11-21T06:00:00Z"
}
```

v0.4 keys: `keyword` present exactly with `post_has_keyword`; `idle_min`
exactly with `no_reply_after_human`; `daily_at`, `daily_tz` and
`daily_due_at` exactly with `daily_at`. The idle due time is not sent: it
changes on every post, and the dialog does not show it.

- `triggers`: any of the eleven keys of 1.2. `interval_min`: present exactly
  when `every_n_minutes` is in `triggers`. `next_due_at`: present when a
  time trigger is on.
- `held_until`: `hour_start + 1h` when `fires_in_hour >= cap`, else omitted.
- `idle`: `""`, `"author_left"` or `"author_no_right"` (4.5): why an `on`
  loop would not fire.

| route | body | answer | refusals |
|---|---|---|---|
| `GET /v1/topics/{task_id}/loops` | — | `200 {"task_id": "<uuid>", "may_edit": true, "loops": [<loop>...]}` | `404 not_found` (the topic's read door) |
| `POST /v1/topics/{task_id}/loops` | `{"prompt": "...", "triggers": [...], "interval_min": n, "keyword": "...", "idle_min": n, "daily_at": "hh:mm", "daily_tz": "<IANA>"}` (each field only with its trigger; `daily_tz` defaults to `UTC`) | `201 <loop>` | `400 bad_loop`, `403 not_allowed`, `403 demo_read_only`, `404 not_found`, `409 topic_archived` |
| `PUT /v1/topics/{task_id}/loops/{loop_id}` | any of `{"prompt", "triggers", "interval_min", "keyword", "idle_min", "daily_at", "daily_tz", "state"}` | `200 <loop>` | as POST, and `404 not_found` for no such loop |
| `DELETE /v1/topics/{task_id}/loops/{loop_id}` | — | `200 {"loop_id": "<uuid>", "deleted": true}` (`false` when it was gone) | `403 not_allowed`, `404 not_found` (topic) |
| `OPTIONS` on both paths | — | the CORS preflight, as `topicPreflight` (`topic_priority.go:39`) | — |

`may_edit` is the archive-policy answer for the caller (answer 5 A); the
WUI also computes it with `mayArchiveTopic` for the menu lock, and the hub
re-checks every write. After each write the hub sends the topic's readers
`{"type": "topic_loops", "task_id": "<uuid>", "loops": [<loop>...]}`.

#### 7.1.3 `messages.loop_id` (L1 adds it, L2 writes it, L2b reads it)

- Column `messages.loop_id uuid NULL`, no default, no foreign key (a
  deleted loop keeps its prompt messages). Set only by the hub's fire
  (4.3 step 2); NULL on every other row, old rows included.
- `loop_id IS NOT NULL` means: a loop prompt message, `from_id = HUM-n`,
  `from_box = box-wui`, `kind = task`, to one agent.
- SQL readers filter `AND m.loop_id IS NULL` (5.2). L2b's sweep query does
  so in its rows read; no other column changes for it.
- JSON readers: the hub's task read behind `spool hub-tail --task`
  (`spl-take-auto.func.sh:152`) carries `"loop_id": "<uuid>"` on such a row,
  and omits the key when NULL. L2b's auto-take skips a row that has it.

### 7.2 Which row owns each trigger (v0.4)

| trigger | L1 (rdb + store) | L2 (hub) | L3 (wui) |
|---|---|---|---|
| `after_agent_reply`, `after_human_reply`, `before_agent_reply` | the key in the CHECK | the hooks of 4.2 steps 1 to 3 | the box |
| `every_hour`, `every_n_minutes` | `next_due_at`, `ClaimDueTopicLoops` | the ticker `runTopicLoopTimer` | the box, n |
| `post_has_keyword` | `keyword` + CHECK | `topicLoopKeyword` in the post hooks (step 8) | the box, the text field |
| `post_has_file` | the key | the `Files` check in the post hooks (step 9) | the box |
| `blocker_posted` | the key | the three hooks of step 10 (`onSend`, `wuiAfterStore`, `handleSetMessageKind`) | the box |
| `no_reply_after_human` | `idle_min`, `idle_due_at`, `idle_post`, `ArmTopicLoopIdle`, `ClearTopicLoopIdle`, the claim | arm and clear in the post hooks, fire from the ticker (step 11) | the box, n |
| `issue_status_changed` | the key | the hook in `updateIssue` (step 12) | the box |
| `daily_at` | `daily_at`, `daily_tz`, `daily_due_at`, the claim | fire from the ticker | the box, the time, the zone |

L2 owns the ticker goroutine; L1 owns only the claim. L2b reads no new
column: v0.4 adds nothing to `messages`.

## 8. Changes from v0.1

- Section 1: the eight answers applied; the v0.1 form replaced by the table,
  the reconciliation of answer 2 with msg `eae9e64f` (1.1), what answer 4 B
  means (1.2) and Q9 (1.3).
- Menu entry renamed **Discussion loops…**; it lists, adds, edits, pauses
  and deletes the topic's loops (msg `19acb8f9`, answer 6 B).
- No badge, no topic notes, no mark on messages (answer 7 C).
- No `awaiting` rule; the cap alone stops a self-firing loop (answer 4 B).
- Key `(tenant_id, loop_id)`; `state` is `on` / `paused`; new
  `messages.loop_id` and the six hidden-row places of 5.2.
- New row L2b for the sweep and auto-take; the v0.1 row L2b (an
  author-only reply route) is dropped with answer 2 A.

v0.3:

- Q9 answered A (msg `e05bec70`): the agent's answer is an ordinary reply;
  1.3 closed, the Q9 B line of 4.3 step 2 removed.
- New 7.1, the binding contracts for the rows that run in parallel: the Go
  store interface, the HTTP and WS shapes, the `messages.loop_id` column.
- 7.1.1 pins the five points the L2 lane asked (c-970, msg `a74cc799`):
  `LoopID` through `FanoutRow`, the cached "has loops" bit with a 30 s TTL,
  `CountTopicLoopFire`, the optional interface, and the ticker in row L2.
- The six triggers of msg `d44af000` replace v0.2's three (1.2, 4.1, 4.2,
  5.1, 7.1); time triggers run on a hub ticker; "only another human's post"
  is dropped.
- Open: Q10 (self-fire, answer 4 B) and Q11 (what "before each human reply"
  means), one form (1.4). Suggested extra triggers, one form (1.5, msg
  `ad30fe25`).
- New 4.6, the worked example of msg `92050cbc`, with the measured gaps:
  no agent-made topic PDF (row L6), no way to mail a file (row L7), and the
  self-fire it would cause (Q10).

### 8.1 Changes from v0.3 (for the lanes building on `d01889cfd`)

Every contract change of v0.4, in one list. Nothing of v0.3 is renamed or
removed; every v0.3 name keeps its meaning except the two marked
**changed**.

- **Trigger enum** (1.2, 5.1 CHECK, 7.1.1 constants): six new keys,
  `post_has_keyword`, `post_has_file`, `blocker_posted`,
  `no_reply_after_human`, `issue_status_changed`, `daily_at`; new
  constants `LoopPostHasKeyword` .. `LoopDailyAt`, `TopicLoopKeywordMax`,
  and the slice `TopicLoopTriggers`.
- **`topic_loops` columns** (5.1, L1): `keyword`, `idle_min`,
  `idle_due_at`, `idle_post`, `daily_at`, `daily_tz` (default `UTC`),
  `daily_due_at`; three new field CHECKs.
- **changed: index `topic_loops_due`** is now on
  `least(next_due_at, idle_due_at, daily_due_at)` where `state = 'on'`
  (was `next_due_at` only).
- **`TopicLoop`** (7.1.1): new fields `Keyword`, `IdleMin`, `IdleDueAt`,
  `IdlePost`, `DailyAt`, `DailyTZ`, `DailyDueAt`, `Due`.
- **`TopicLoopEdit`**: new fields `Keyword`, `IdleMin`, `DailyAt`,
  `DailyTZ`.
- **`ErrBadTopicLoop`**: same name, wider text and checks (12 keys, the
  three new fields, the zone).
- **changed: `ClaimDueTopicLoops`**: same signature; it now claims on any of
  the three due columns, moves each on, and fills `Due` and `IdlePost`.
- **New store calls**: `ArmTopicLoopIdle`, `ClearTopicLoopIdle` (L1 builds,
  L2 calls).
- **Fired message id**: the v0.3 seed for a trigger post is unchanged; new
  seeds for time and issue fires (7.1.1 table).
- **HTTP / WS** (7.1.2): the loop JSON gains `keyword`, `idle_min`,
  `daily_at`, `daily_tz`, `daily_due_at`; POST and PUT accept the first
  four; `400 bad_loop` covers them.
- **New hub hooks** (L2): `handleSetMessageKind` (`message_kind.go:123`)
  and `updateIssue` (`issues.go:449`), beside the v0.3 `wuiAfterStore` and
  `onSend`; `onSend`'s hook now also runs for an agent-to-agent blocker.
- **WUI form** (L3): six more boxes, a keyword field, an idle n, a time and
  a zone.
- Unchanged: `messages.loop_id`, `FanoutRow`, the 30 s "has loops" bit,
  `CountTopicLoopFire`, the optional interface, the routes' paths, the
  `topic_loops` frame, rows L2b, L4, L6, L7.

v0.4 also: 1.5 records the answer; Q10's note covers the new post triggers
(1.4); 4.3 step 4 names the target of each new trigger; 7.2 maps each
trigger to its rows.

### 8.2 Changes from v0.4 (c-970's three points, msg `9dc69b0c`)

- **Point 1, corrected: the time-fire seed.** It is `"due:" + DueAt`, the
  pre-move due time; new field `TopicLoop.DueAt`, filled only by
  `ClaimDueTopicLoops` (L1). The post-move value loses a daily fire that
  follows an interval fire (7.1.1). L2 seeds on `DueAt` and drops
  `loopDueClaimed`'s post-move scan; its fallback to the claim's minute
  stays for a zero `DueAt`. The seed string format is unchanged.
- **Point 2, owned: archive deletes loops.** Row L2: the two calls in
  `topic_archive.go` (4.5); L1 already has `DeleteTopicLoops`. Topic delete
  added (v0.5).
- **Point 3, corrected: `SetBy` is the member id** (`hum`), not the v:1
  `from`; the v:1 id is derived at fire time by `editorID`'s rule (7.1.1,
  "The author's two ids"). Equal on a Postgres hub today, so this fixes the
  other session sources, not a live defect. No column or JSON field
  changes: `set_by` stays 1..64 characters (a longer member id is refused
  with `400 bad_loop`), and the JSON shows the derived v:1 id.
- Unchanged: every other name, route and column of v0.4.

### 8.3 Changes from v0.5 (the owner's Q10 and Q11, msg `46e61a8c`)

- **Q10 A, decided.** A loop's own prompt answer never fires that loop
  (1.4, 4.4). `awaiting`, `awaiting_until`, `Awaiting`, `AwaitUntil` and
  `SetTopicLoopAwaiting` keep their v0.5 names and meaning, and are now
  always on. L2's switch `Options.TopicLoopSelfFire`
  (`origin/review/c002-s182-l2-hub-topic-loop-fire-v05` `c72855f3e`,
  `internal/hub/topic_loop_fire.go:45,346,411`) has no answer left to
  choose: L2 removes it, and the self-fire test runs with no switch.
- **Q11 C: removed: `before_human_reply`.** The key leaves the 5.1 CHECK,
  the constant `LoopBeforeHumanReply`, `TopicLoopTriggers` (now eleven) and
  the `ErrBadTopicLoop` text (1..11). 4.2 step 4 has no hook; the step
  numbers are kept. The WUI form has eleven boxes. A request with the key
  gets `400 bad_loop`.
- **What each review branch has to drop** (measured with
  `git grep -c -iE 'before_human_reply|BeforeHumanReply' <branch> -- . ':!csi-spl-doc'`):

  | row | branch | sha | files, lines |
  |---|---|---|---|
  | L1 | `review/c002-s182-l1-rdb-store-topic-loops` | `029d81007` | 3, 4 (`0299_topic_loops.sql`, `store/topic_loop.go`, `store/topic_loop_test.go`) |
  | L2 | `review/c002-s182-l2-hub-topic-loop-fire-v05` | `c72855f3e` | 5, 14 (`hub/topic_loop_fire.go`, its tests, `hub/openapi.json`, the contract shim) |
  | L3 | `review/c002-s182-l3-wui-discussion-loops` | `50332b600` | 21, 21 (`src/utils/topic-loops.mjs:19` and its strings in each locale file) |
  | L2b | `review/c002-s182-l2b-orc-sweep-skip-loop-r2` | `4416fe8d8` | 0 |

  None of these branches is on master (`git grep -c topic_loops origin/master -- csi-spl-rdb csi-spl-api/src`
  -> nothing), so L1 edits its own migration in place; no second migration.
- Unchanged: every other key, column, store call, route, frame and row.

### 8.4 Changes from v0.6 (the L1 review, c-382, msg `13956ae7`)

- **5.2, three more hidden-row places** (measured on `origin/master`
  `e2883a6be`): `countsRead` of `ViewChannelStats`, `viewChangesSQL`, and
  the topic PDF export of spec 183 (`TopicExportRows`), each with its
  Memory twin. All three are store reads, so row L1 owns them (its scope
  and tests in section 7). Section 5.2 now has nine places.
- **5.1, two CHECKs:** `fires_in_hour >= 0` and `fires_total >= 0`. L1's
  `0299_topic_loops.sql` already has both
  (`origin/review/c002-s182-l1-rdb-store-topic-loops` `029d81007`, lines
  76 and 77); the spec now matches it.
- Unchanged: every name, route, column and row of v0.6.

### 8.5 Changes from v0.7 (the owner's N4 B, msg `f854f268`)

- **1, 1.6, 4.2 step 7, 4.4 step 2, 4.6, row L2:** the awaited answer to
  any loop of the topic matches no loop's `after_agent_reply` box. Row L2
  builds it in `topicLoopFireIf` (`internal/hub/topic_loop_fire.go`): every
  loop's wait is checked first, then the match runs with the answer flag.
- Unchanged: every name, route, column, key and store contract of v0.7. No
  migration.

### 8.6 Changes from v0.8 (Channel loops, SPL-6440)

- **New Section 9 (Channel loops):** adds channel-level loops behind a
  **Channel loops…** entry in the channel right-click menu
  (`sidebar-row-menu.mjs`), reusing the topic loop editor and eleven-trigger
  set so a channel loop applies dynamically to each open topic in that
  channel.
- **Store and contracts:** two dedicated tables (`channel_loops` +
  `channel_loop_state`) in a new forward-only migration
  (`<NNNN>_channel_loops.sql`), `ChannelLoopStore`,
  `/v1/channels/{channel}/loops` routes, `channel_loops` WS frame, and
  build rows **C1, C2a, C2b, C3, C4, C5** (9.7-9.9).
- **Channel archive keeps channel loops (W1, holder ruling):** channel archive
  is reversible (`handleUnarchiveChannel`, `channel_members.go:576-582`) and
  already keeps `topic_loops` rows (`retireChannel` never calls
  `dropTopicLoops`); keeping `channel_loops` silent while archived
  (`notArchived`) and resuming them on unarchive (with recomputed due times
  and cleared stale idle state) avoids unapproved data loss and surprise
  bursts (9.5).
- **Open owner choices (CL1-CL4):** combination with topic loops, per-topic
  opt-out, channel-loop write permission, and periodic time-trigger fan-out
  on large channels are held open in 9.1 and sent to the dispatch holder as
  one poll draft — none is asserted as decided here.
- Unchanged: `topic_loops`, `messages.loop_id`, the nine hidden-row places
  of 5.2, `TopicLoopStore`, `/v1/topics/{task_id}/loops`, and rows L1-L7.

### 8.7 Changes from v0.9 (owner's CL1-CL4 answers, msg `facaaf33`, SPL-6474)

- **Owner answers recorded (form `13fb1941`, msg `facaaf33`, 2026-11-25 07:37Z):**
  **CL1 A** (both fire), **CL2 B** (no opt-out at first), **CL3 B** (follows
  the workspace's archive-topics permission), **CL4 B** (timed triggers run
  over every open topic, newest first, at most 60 runs/h per loop). All four
  open choices of v0.9 are closed (9.1).
- **CL1 A (9.3 item 3):** additive evaluation of `TopicLoopsOn(T)` and
  `ChannelLoopsOn(C)` is decided; the CL1 B topic-overrides-channel
  alternative is removed.
- **CL2 B (9.3 item 5):** the per-topic opt-out switch (`channel_loop_opt_outs`
  table, toggle UI, and `/v1/topics/{task_id}/channel-loop-opt-outs/{loop_id}`
  routes) is removed. Pausing or archiving a topic already stops its loops.
- **CL3 B (9.4):** replaces v0.9's recommended `mayChannelAIAgents` rule with
  the workspace's **"Who can archive topics"** setting
  (`tenants.topic_archive_policy`, rdb `0093`, read via `Server.archivePolicy`
  and enforced by `Server.mayArchiveByPolicy`), naming every definition and
  read site (`file:line` on `origin/master` `c9dd02117`). Under `'starter'`,
  `change` maps to channel creator (`channelOwner`), workspace owner, or admin.
- **CL4 B (9.6, 9.8.1):** removes the 7-day active-topics cutoff
  (`SPOOL_HUB_CHANNEL_LOOP_ACTIVE_DAYS`) and 25-topic per-tick slice
  (`SPOOL_HUB_CHANNEL_LOOP_MAX_TOPICS`), replacing `ChannelActiveTopics` with
  keyset-paginated `ChannelOpenTopics` (every open unarchived topic whose
  canonical channel matches, newest activity first). Keeps the three-tier
  hourly caps (**12/h** per topic, **60/h** per loop, **120/h** per channel
  total), documents how the 60/h loop cap and 120/h channel cap interact
  (including deterministic `(channel_id, loop_id)` claim order, no carry-over
  of cap-dropped topics, and the cap-stop / skip log contract), returns a
  typed outcome from `CountChannelLoopFire`, and explicitly refuses hidden
  virtual channels (`ChannelIssues` / `ChannelTasks`) with `404 unknown_channel`.
- **Disjoint build rows (9.9):** places `view.go`, `server.go`, `config.go`,
  and `cmd/spool/hub.go` ownership entirely in **C2a** so all six build rows
  (**C1, C2a, C2b, C3, C4, C5**) touch strictly disjoint file sets, each with
  its red-control test and author / cross-vendor R7 reviewer assignment per
  the fleet kind table (`csi-spl-cnf/csi-spl/all.env.yaml:1567-1574`).
- Unchanged: `channel_loops` + `channel_loop_state` schema (9.7, all 11
  triggers kept), channel archive retention (W1, 9.5), `topic_loops`,
  `messages.loop_id`, and rows L1-L7.

### 8.8 Changes from v0.10 (the owner's Discussion loops dialog changes, v0.11)

**Source.** HUM-10, t1 `#refactoring` topic `6e8c1cdb` "discussion loops
refactoring changes", 2026-11-26 11:29-11:36Z, verbatim and in order:
`4bdc60ba`, `1708487a`, `543a5bde` (screenshot `a44133f5`: the Add form, the
Prompt "before each agent reply" typed by hand and that box checked): *"once a
click on a "whne" option , it has to become the title of the loop directly"*;
`7f3ebb17` (screenshot `bebfa879`): *"so instead of say hello here"*;
`9e3161d9` (screenshot `b8e7bad8`): *"the title should be before each agent
reply"*; `a04bba37`: *"and this should work for everry type selected ..."*;
`febf1db4`: *"those choices should be radio buttons - aka one trigger per
loop"*; `e68509d5`: *"also the dialog box should be draggable back and forth
on the screen"*; `ac0a7377`: *"also it should take 70% of the width of the
screen and it should start 10% from the top"*; `1822fb67`: *"The edit pause and
delete buttons should be just buttons with icons and text on hover , known
icons , using the spool-hub's existing style"*; `ae3a2d5c` (screenshot
`b8441ef6`, the Prompt box resized by hand to about 17% of a 2560x1600
screen, ~11 lines): *"the prompt should be still resizable but its default size
should be about this big"*; `a12eb10a`: *"one should be able to drag up and
down the loop cards in the dialog box once they are set"*; `d8e02722`: *"the
option for A post with a file attached , should be changed into 2 actoins , >
> after an agent post with one or more files attached > after a human post with
one or more files attached"*; `e4cb57a6`: *"this date time control should use by
default 24 hours clock"*. Then, relayed by the dispatch holder `c-002` (msg
`f435f15f`): `534340d9` (screenshot `76e9a4ed`): *"the prompt and the Run it
sections of this dialog box should be as 2 columns of a table - the when should
be on the right and the prompt on the left column"*; `ca849d36`: *"this should
be done after the resizing ..."*; `5c03fa45`: *"concentrate only on the Desktop
now , we wil fix the mobile later one"*; `b5ba7424`: *"also the font for the
loops should be bigger - at least in the same size as the font of the
omnibox"*. Where screenshot `bebfa879` points (the list row or the fire line)
is the holder's ruling (msg `7f133bb6`): both.

**Scope.** Desktop (msg `5c03fa45`). At <= 600 px the dialog stays today's
full screen: no new phone work, only no regression.

| # | Issue | Change | Where |
|---|---|---|---|
| 1 | SPL-6580 | **The trigger names the loop.** A loop's title is its one trigger's label with its parameter, first letter upper case: "Before each agent reply", "Every 30 minutes", "A post that contains "deploy"", "No reply for 15 minutes after a human post", "Every day at 09:00 (Europe/Amsterdam)", for every trigger. Derived, never stored: no column, no migration. In the form it is a heading set the moment a radio is picked, and it follows the trigger's field as it is typed. | `utils/topic-loops.mjs` `loopTitle`, `formLoop`; `TopicLoopsDialog.vue` |
| 2 | SPL-6581 | **Where the title shows.** (a) The list row: the title is the row's first line, the prompt's first line under it (it was the prompt's line, then the checked triggers). (b) The fire line: the first line of a loop prompt message names the title after the unchanged mark, `Loop prompt (background; set by @HUM-1, fired by msg:<id>): Before each agent reply`, and the prompt stays below it. The mark `Loop prompt (background; ` is unchanged: the box notify (`spool-notify.inc.sh`) and the time fire's quote match on it. The hub's English labels mirror `en.json` `feed.topic_loops`, held equal by `TestTopicLoopTitleParity`. A loop stored with several triggers names them all, comma separated. | `TopicLoopsDialog.vue`; `hub/topic_loop_title.go`, `hub/topic_loop_fire.go` `loopMessage` |
| 3 | SPL-6582 | **One trigger per loop, radio buttons** (reverses Q3 B). The form's eleven checkboxes become one radio group, none picked on a new loop. Hub: a `POST` or `PUT` body that sends `triggers` sends exactly one distinct key, else `400 bad_loop` (`readLoopBody`); `openapi.json` says `minItems: 1, maxItems: 1` on the request bodies. **Loops stored before v0.11 with several triggers** (no silent change on prd): they read and fire exactly as before; a `PUT` that sends no `triggers` (pause, resume, a new prompt or field) keeps them all; their row names every trigger; their form opens on the first (1.2 order) and says, above the radios, that saving keeps only the trigger chosen (`multi_note`). The store and rdb 0301 (`cardinality(triggers) >= 1`) are unchanged, as they must still hold those rows. | `hub/topic_loop.go`; `topic-loops.mjs` `loopForm` (`trigger`, `others`), `loopFormError`, `loopBody`; the mock |
| 4 | SPL-6583 | **Draggable dialog.** `UiDialog` gains `draggable`: a press on the header (not on its buttons) moves the panel with a mouse, a pen or a finger (pointer events), clamped so the whole panel stays on screen (`utils/dialog-drag.mjs`); a smaller window pulls it back; each open starts at its CSS place. Off at <= 600 px. | `UiDialog.vue`, `composables/useDialogDrag.ts` |
| 5 | SPL-6584 | **70% wide, 10% from the top.** `UiDialog` gains size `wide`: `width: 70vw`, its top at `10vh`, its height its content's up to `80vh`. At <= 600 px the full screen as every size. | `UiDialog.vue`; the loops dialog uses `size="wide" draggable` |
| 6 | SPL-6585 | **Icon buttons.** A row's Edit, Pause / Resume and Delete are the WUI's `icon-btn` with `UiIcon` glyphs `pencil`, `pause` / `play`, `trash` (`pause`, `play` added to `utils/uiIcons.ts`, lucide paths; no new icon library); the words are their `title` and `aria-label`; a locked row keeps the locked reason as its title and stays disabled. | `TopicLoopsDialog.vue`, `uiIcons.ts` |
| 7 | SPL-6586 | **Prompt box size.** The prompt textarea stays resizable (vertical); its default height is `17vh`, the owner's hand-sized box (about 17% of the screen height, ~11 lines on 2560x1600), never under 6 lines. | `TopicLoopsDialog.vue` |
| 8 | SPL-6587 | **Reorder loop cards.** A saved loop's row is dragged up and down by its grip (pointer and touch); on the focused grip, Arrow Up / Arrow Down move it one place (the keyboard way). The order is the hub's: rdb `topic_loops.position` (int, the list's order; new loops go last), `TopicLoops` lists by `position, set_at`, and `PUT /v1/topics/{task_id}/loops/order` `{"loop_ids": [...]}` (the topic's every loop id, once each, else `400 bad_loop`; the archive policy as every write) stores it and sends the `topic_loops` frame, so every viewer and the next open see it. | rdb, store, `hub/topic_loop.go`, `openapi.json`, the dialog |
| 9 | SPL-6588 | **The file trigger in two.** The form offers "After an agent post with one or more files attached" (`post_has_file_agent`) and "After a human post with one or more files attached" (`post_has_file_human`) in place of "A post with a file attached": twelve in the form. The hub fires the first on an agent's post (an agent reply or a box blocker) with a file, the second on a human post with a file (`postMatches`). A stored loop with the old `post_has_file` keeps firing on both, as before, and its row keeps its old label; the form no longer offers it. rdb 0330 re-adds the `triggers` CHECK of 0301 with the two keys (`NOT VALID`: it only widens, no scan). | rdb, store `TopicLoopTriggers`, `hub/topic_loop_fire.go`, the title tables, the form |
| 10 | SPL-6589 | **24-hour clock.** "Every day at" is the WUI's own `hh:mm` text field (24 h, `inputmode="numeric"`, checked against `^([01]\d|2[0-3]):[0-5]\d$`), not the native `<input type="time">`, which follows the browser locale and showed "09:00 AM". The stored value stays `hh:mm`. | `TopicLoopsDialog.vue` |
| 11 | SPL-6592 | **Two columns.** On a desktop the Add / Edit form is two columns: the prompt left, Run it (the radios) right; the title above both, the buttons below. At <= 600 px one column, as before. | `TopicLoopsDialog.vue`; e2e `tests/e2e/topic-loops-dialog.test.mjs` |
| 12 | SPL-6593 | **Bigger text.** The dialog's text (list rows, form labels, radios, fields) is at least the omnibox's (the message composer's) font size, through the composer's own size token, no new number. | `TopicLoopsDialog.vue` |

Channel loops (section 9) reuse this dialog (9.2, 9.8.3); whether
`channel_loops` mirrors change 8's `position` and change 9's two keys is the
holder's call (plan `spec-182-channel-loops-build-plan.md` v1.1, N6).

## 9. Channel loops (v0.9 SPL-6440; v0.10 SPL-6474)

### 9.0 The owner's words (HUM-10, t1 topic `cbb1897b`, 2026-11-24 / 2026-11-25)

Verbatim in `topic:cbb1897b-4d35-44df-93c3-a2bbd2b6defa` (`t1`):

- `2026-11-24 15:49:06Z`, msg `1d74013c` (with a screenshot of the channel
  right-click menu in `#spool-hub-ops`: *Open, Copy link, Add to note, Mute,
  Move up, Move down, Properties, Archive channel, Delete channel*):
  > "add the loops feature on the channel level as well"
- `2026-11-24 15:49:29Z`, msg `3e75de18`:
  > "so that one could specifiy the similar kind of loops actions as they
  > were defined on the topics level"
- `2026-11-24 15:49:36Z`, msg `3fb74ba3`:
  > "for each topic in the channel"
- `2026-11-25 07:37Z`, msg `facaaf33` (answers to form `13fb1941`, CL1-CL4):
  > "Answer 1: A — Both fire"
  > "Answer 2: B — No opt-out at first (pausing or archiving the topic already stops its loops)"
  > "Answer 3: B — Whoever may archive topics in this workspace (its setting)"
  > "Answer 4: B — Every open topic, newest first, at most 60 runs an hour per loop"

**Measured state on `origin/master` `c9dd02117`:** topic loops (rows L1, L2,
L2b, L3, plus SPL-6309 DM-mirror skip) are on `origin/master`
(`0301_topic_loops.sql`, `internal/store/topic_loop*.go`,
`internal/hub/topic_loop*.go`, `TopicLoopsDialog.vue`,
`utils/topic-loops.mjs`), and nothing exists for channel loops:

- `git grep -n -iE "channel_loop|channel-loops|ChannelLoop" origin/master -- csi-spl-api csi-spl-rdb csi-spl-wui | wc -l`
  -> `0`
- `git grep -n -i "loop" origin/master -- csi-spl-wui/src/utils/sidebar-row-menu.mjs csi-spl-wui/src/components/SidebarRowMenu.vue | wc -l`
  -> `0`

### 9.1 Decided design (no open choices)

All engineering invariants and all four owner product choices (**CL1-CL4**,
form `13fb1941`, msg `facaaf33`, 2026-11-25 07:37Z) are decided. No question
remains open; the build rows of 9.9 are ready for a build round plan.

| item | status | decided rule | section |
|---|---|---|---|
| Menu entry and placement | **Decided** | **Channel loops…** (`id: 'channel-loops'`, icon `refresh`) in the channel right-click menu (`sidebar-row-menu.mjs:17-58`, channel block `:24-37`), right after **Properties** and before **Archive channel** / **Delete channel**; no row badge or channel notice (Q7 C, msg `eae9e64f`) | 9.2 |
| Editor and triggers | **Decided** | Shared dialog (`TopicLoopsDialog.vue`) and all eleven triggers of 1.2 (`LOOP_TRIGGERS`) | 9.2 |
| Existing, new and moved topics | **Decided** | Dynamic evaluation at fire/tick time (never copy-on-create): applies to existing open topics, future topics, and topics moved in; moved-out topics stop automatically; `#lobby` container task (`LobbyTaskID`) skipped | 9.3 |
| No-refire (Q10 A, N4 B) | **Decided** | Unified pool per topic (`topicLoops(T) ∪ channelLoops(ch)`): per-`(loop_id, task_id)` 30-min `awaiting` clears on answer (Q10 A) and suppresses `after_agent_reply` across BOTH topic and channel loops on `T` (N4 B) | 9.3 |
| Store layout | **Decided** | Dedicated `channel_loops` + `channel_loop_state` tables (not a nullable column on `topic_loops`); `messages.loop_id` reused as-is, zero changes to `messages` or `topic_loops` | 9.7 |
| Channel delete / archive | **Decided** | Delete cascades via FK; archive **keeps** channel loops silent (archived channels are skipped by `ChannelLoopsOn`, `ClaimDueChannelLoops`, `ClaimDueChannelLoopIdles`, and `channelDoor`, matching how channel archive already keeps `topic_loops`); unarchive resumes them with fresh due times and cleared stale idle timers (no catch-up burst) | 9.5 |
| **CL1** — Combine with topic loops | **Decided (A, msg `facaaf33`)** | **Both fire (additive):** `topicLoopFireIf` evaluates both `TopicLoopsOn(T)` and `ChannelLoopsOn(C)` independently, sharing the unified Q10 A + N4 B no-refire pass | 9.3 |
| **CL2** — Per-topic opt-out | **Decided (B, msg `facaaf33`)** | **No opt-out switch:** uniform across all open topics in the channel; pausing (spec 179) or archiving a topic already stops its loops | 9.3 |
| **CL3** — Who may edit channel loops | **Decided (B, msg `facaaf33`)** | **Workspace archive-topics permission:** follows `tenants.topic_archive_policy` (`everyone` / `admins` / `starter`) via `Server.archivePolicy` + `Server.mayArchiveByPolicy` (`starter` maps to channel creator, owner, or admin) | 9.4 |
| **CL4** — Timed triggers on open topics | **Decided (B, msg `facaaf33`)** | **Every open topic, newest first, up to 60 runs/h per loop**, keeping the **120 runs/h per-channel total cap** and **12 runs/h per-topic cap** (no recency cutoff, no 25-topic slice) | 9.6 |

### 9.2 Menu entry and shared editor ("Channel loops…")

1. **Menu home (verified on `c9dd02117`):** the channel right-click menu
   shown in msg `1d74013c` is built by `rowMenuItems` in
   `csi-spl-wui/src/utils/sidebar-row-menu.mjs:17-58` and rendered by
   `csi-spl-wui/src/components/SidebarRowMenu.vue:50-66`, mounted per
   channel row in `csi-spl-wui/src/components/ChannelSidebar.vue:352-375`
   and opened on right-click via `@contextmenu.prevent="openChannelMenu('ch:' + c.channel_id)"`
   (`ChannelSidebar.vue:325`, `openChannelMenu` `:765`).
2. **Item and position:** add `loops?: boolean` to `rowMenuItems`'s options
   (`sidebar-row-menu.mjs:14`). Inside `if (o.channel)` (`:24-37`), push
   `{ id: 'channel-loops', icon: 'refresh', labelKey: 'sidebar.row_menu.channel_loops' }`
   right after `properties` (`:32`) and before `archive-channel` (`:34`) and
   `delete` (`:36`). The resulting channel menu order is:
   *Open, Copy link, [Add to note], [Mark as read], Mute/Unmute, Move up,
   Move down, Properties, **Channel loops…**, Archive channel, Delete channel.*
   - The `refresh` icon is already registered in `csi-spl-wui/src/utils/uiIcons.ts:421`
     and used by `topic-loops` (`csi-spl-wui/src/utils/msg-menu.mjs:155`).
   - Visibility: `loops` is passed as `showProperties(c.channel_id)`
     (`ChannelSidebar.vue:358`, `useSidebarChannelAdmin.ts:48-50` — every
     signed-in member who can read the channel). Opening the dialog calls
     `GET /v1/channels/{channel}/loops`, which returns `may_edit` (computed
     by the hub from `tenants.topic_archive_policy`, 9.4); viewers without
     write rights see the channel's active loops read-only with Add / Edit /
     Pause / Delete disabled and the lock reason shown, matching `Properties`
     and `TopicLoopsDialog.vue:102-105`.
   - No badge on the channel row, no system post in the channel, and no mark
     on any message (answer 7 C, msg `eae9e64f`).
3. **Shared editor and eleven triggers:** reuse `TopicLoopsDialog.vue`
   (extended with optional `channelId` / `channelName` props) and
   `csi-spl-wui/src/utils/topic-loops.mjs` (`LOOP_TRIGGERS`, `emptyLoopForm`,
   `loopForm`, `loopFormError`, `loopBody`, `loopTriggerLabels`,
   `loopRowState`).
   - Title: `Channel loops — #{name}` (`sidebar.channel_loops.title`), with
     a short muted scope line under the title explaining that each loop runs
     for every open topic in the channel (`sidebar.channel_loops.scope_note`).
   - Same prompt ceiling (1..4000 chars), all eleven trigger checkboxes
     (CL4 B keeps `every_hour`, `every_n_minutes`, and `daily_at`), same
     per-trigger fields and validation, and same per-row actions (**Edit**,
     **Pause** / **Resume**, **Delete**) plus **Add loop**.
   - Row state shows `on`, `paused`, `held until hh:mm` (when either the
     60/h per-loop cap or the 120/h per-channel total cap holds the loop,
     9.6), or the `idle` reason (`author_left` / `author_no_right`).

### 9.3 Scope, inheritance, combination with topic loops, and no-refire

1. **Dynamic inheritance (existing, new, and moved topics):**
   - A channel loop is **not** copied into `topic_loops` when created.
     Instead, the hub evaluates a channel's `on` channel loops dynamically
     for each open (unarchived, unpaused) topic in that channel.
   - **Why:** (a) editing, pausing, resuming, or deleting a channel loop
     takes effect at once on every topic in the channel with one row write;
     (b) topics created after the loop is added — and topics moved into the
     channel (`handleMove`, `internal/hub/message_move.go:197`) — inherit
     the channel's loops automatically; (c) topics moved out of the channel
     stop running the old channel's loops immediately and adopt the
     destination channel's loops.
   - **Excluded topics:** archived topics (`topicClosed`,
     `internal/hub/topic_archived_input.go:32`), paused topics
     (`AnyTopicPaused`, spec 179), DMs (`channel == ""`), and the shared
     `#lobby` container task (`task == s.o.LobbyTaskID`, matching
     `dropTopicLoops` at `internal/hub/topic_loop.go:135` and spec 179 3.1).
     Individual topics created inside `#lobby` (with their own `task_id !=
     LobbyTaskID`) ARE included.
2. **Per-topic runtime isolation:**
   - Although the loop definition lives once on the channel, runtime
     execution state is tracked **per `(loop_id, task_id)`** in
     `channel_loop_state` (9.7):
     - `awaiting` / `awaiting_until` (Q10 A): an agent answering a channel
       loop prompt in topic `T1` clears the wait on `T1` only, never on `T2`.
     - `idle_due_at` / `idle_post` (`no_reply_after_human`): a human post in
       `T1` arms `T1` only; an agent reply in `T2` never clears `T1`'s idle
       timer.
     - `fires_in_hour` / `hour_start`: each topic gets its own per-topic
       cap (12/h, Q4 B) so one noisy topic cannot starve quieter topics, in
       addition to the channel-loop hourly budget (9.6).
     - `msg_id` seed includes `task_id` (9.8.1), so a single time tick or a
       single issue linked to two topics in the same channel generates
       distinct deterministic `msg_id`s per topic.
3. **Combining channel loops with a topic's own loops (CL1 A, msg `facaaf33` — both fire):**
   - On any post, kind-change, or issue event in topic `T` of channel `C`,
     `topicLoopFireIf` (`internal/hub/topic_loop_fire.go:300`) evaluates
     **both** `TopicLoopsOn(T)` and `ChannelLoopsOn(C)` independently. Each
     matching loop fires once for that event (additive), while sharing the
     unified awaited-answer pass below.
   - Timed triggers (`every_hour`, `every_n_minutes`, `daily_at`) and idle
     timers (`no_reply_after_human`) likewise run independently for `T`'s
     topic loops and `C`'s channel loops.
4. **No-refire rules (Q10 A and N4 B, decided):**
   - Topic loops and channel loops on topic `T` share **one awaited-answer
     pass** in `topicLoopFireIf` (`topic_loop_fire.go:311-318`):
     1. First, check every `on` topic loop of `T` AND every `on` channel
        loop of `C` (reading its `(loop_id, T)` state row) for a live
        `awaiting == ev.post.From && now < awaiting_until`.
     2. Every loop whose wait matches clears its `awaiting` slot and does
        not fire on this post for **any** trigger (Q10 A).
     3. If **any** loop (topic OR channel) matched its wait on `T`, set
        `ev.answer = true` for `T`: the post then matches the
        `after_agent_reply` box of **no** loop on `T` — neither topic loops
        nor channel loops (N4 B). Other checked boxes (keyword, file,
        blocker) on *other* loops still match, exactly as in 1.6.
   - **Why unified:** without unifying both pools under N4 B, a channel
     `after_agent_reply` loop and a topic `after_agent_reply` loop on the
     same topic would fire each other in a ping-pong loop up to the hourly
     cap — the exact failure N4 B eliminated.
   - A loop prompt message (`messages.loop_id IS NOT NULL`, `topicLoopPromptMark`
     at `topic_loop_fire.go:70`) is never a trigger for either scope.
5. **No per-topic opt-out switch (CL2 B, msg `facaaf33`):**
   - Channel loops apply uniformly to every open topic in the channel: there
     is no per-topic opt-out table, toggle, or route.
   - Pausing a topic (spec 179, `AnyTopicPaused`) already pauses all loops
     on it (both topic and channel loops), and archiving the topic
     (`topicClosed`) stops them permanently.
6. **Target agent and `before_agent_reply`:**
   - Identical to 4.3 steps 1 and 4 (`loopTarget`, `topic_loop_fire.go:438`):
     an agent post targets that agent; a human post, idle fire, time fire,
     or issue fire targets the topic's newest announced agent (`topicAgents`).
     With no announced agent in that topic, nothing is sent and one info
     line is logged.
   - For `before_agent_reply`, `topicLoopBeforeAgent` (`wui.go:632`,
     `topic_loop_fire.go:219`) runs for both topic and channel loops before
     `commitRow`, so every matching loop prompt is enqueued ahead of the
     human post. On a **brand-new topic** opened in a channel with a
     channel `before_agent_reply` loop and an explicit `@agent` or channel
     fan-out, `rt.channel` is already resolved (`wui.go:627`) and
     `rt.signing.agent` names the target (or `topicAgents` when fan-out
     has no prior agent in the new topic, in which case `before_agent_reply`
     skips if no single target agent is named, while `after_human_reply`
     runs after store if an agent is routed).
   - For `issue_status_changed`, `topicLoopIssue` (`topic_loop_fire.go:270`)
     already iterates every linked `d.TaskID` in `IssueDiscussionLinks`;
     resolving each topic's channel via `s.channelOf(ctx, tenant, "", d.TaskID)`
     (`channels.go:76`, only when `channelLoopsMaybe(tenant)` is true) fires
     matching channel loops for each linked topic in that channel.

### 9.4 Permissions (CL3 B, msg `facaaf33` — workspace archive-topics setting)

1. **Read door (decided):** every route under `/v1/channels/{channel}/loops`
   passes `s.channelDoor(w, r)` (`internal/hub/channel_members.go:123`).
   - A member who can read the channel passes (`GET` returns `200` with
     `may_edit: true|false` and the list).
   - A non-member, a missing channel, an archived channel, or a hidden
     virtual channel (`store.ChannelHidden(ch)`: `ChannelIssues` `"issues"`
     and `ChannelTasks` `"tasks"`, `internal/store/channels.go:56`, which have
     no row in `channels`, `channels_postgres.go:78`) gets
     `404 unknown_channel` (never `403`, keeping private channels invisible,
     `channel_members.go:25-28`, and avoiding an FK error on insert).
2. **Write door (CL3 B — follows the workspace's "Who can archive topics" setting):**
   Every `POST`, `PUT`, and `DELETE` passes `s.channelDoor` (which enforces
   `rbac.ChannelsEdit`, blocking `demo_user`, `channel_members.go:132`),
   `billing.AllowsWrite(t.BillingStatus)`, and `s.mayChannelLoops(ctx, t, row, hum)`,
   which applies the workspace's **`tenants.topic_archive_policy`** setting
   (the exact setting used by topic archive, topic pause, and topic loops):
   - **Setting name and allowed values:** `tenants.topic_archive_policy`
     (`'everyone'` [default when `NULL` or `""`], `'admins'`, `'starter'`).
   - **Where the setting is defined and read on `origin/master` (`c9dd02117`):**

     | layer | symbol / field | `file:line` on `origin/master` (`c9dd02117`) |
     |---|---|---|
     | RDB schema | `tenants.topic_archive_policy` + CHECK | `csi-spl-rdb/src/sql/postgres/spool-hub/0093_tenant_topic_archive_policy.sql:20-24` |
     | Store constants & default | `ArchivePolicyEveryone`, `ArchivePolicyAdmins`, `ArchivePolicyStarter`, `DefaultArchivePolicy`, `ValidArchivePolicy`, `EffectiveArchivePolicy` | `csi-spl-api/src/go/spool-hub-api/internal/store/tenant_settings.go:46-73` |
     | Store model & reads/writes | `Tenant.TopicArchivePolicy`, `getTenant`, `GetTenantSettings`, `PatchTenantSettings` | `internal/store/store.go:74`, `internal/store/postgres.go:213-217`, `internal/store/tenant_settings.go:180,203-204,271-275,300-314` |
     | Hub effective policy | `Server.archivePolicy(t)` (forces `starter` on demo workspace, else `EffectiveArchivePolicy`) | `csi-spl-api/src/go/spool-hub-api/internal/hub/demo.go:76-81` |
     | Hub policy check | `Server.mayArchiveByPolicy(ctx, tenant, hum, stored, change)` | `csi-spl-api/src/go/spool-hub-api/internal/hub/topic_archive.go:172-182` |
     | Existing hub callers & API | `cardAllowed`, `loopIdle` / `handleTopicLoopsGet` / `loopWriter`, `topicCreatePrio`, `tenant_settings`, `/v1/view/me` | `topic_archive.go:151`, `topic_loop.go:107-119,233,245`, `topic_create_prio.go:78`, `tenant_settings.go:53,96,167-172`, `rbac.go:139,208` |
     | WUI readers & settings UI | `archivePolicyOf` / `normalizeMe`, `normalizeTenantSettings`, `mayArchiveTopic`, General settings `<select>` | `csi-spl-wui/src/utils/access.mjs:24-26,46`, `utils/tenant-settings.mjs:25`, `utils/topic-archive.mjs:74-85`, `pages/tenant-settings/general.vue:56,144-147` |

   - **Exact evaluation for a channel (`mayChannelLoops`):**
     Calls `s.mayArchiveByPolicy(ctx, t.ID, hum, s.archivePolicy(t), change)`,
     where `change` (only needed when the effective policy is `starter`) is
     the channel equivalent of `mayChangeTopic`:
     `channelOwner(row.CreatedBy, hum)` (`internal/hub/channel_members.go:103`)
     `|| (err == nil && (a.TenantOwner || a.Has(rbac.Admin)))` (from
     `s.access(ctx, hum, t.ID)`).
     - Under **`everyone`** (default): any signed-in channel member (who
       passed `channelDoor` and `rbac.ChannelsEdit`) may add, edit, pause, or
       delete channel loops.
     - Under **`admins`**: only the workspace owner (`a.TenantOwner`) or a
       workspace admin (`a.Has(rbac.Admin)`).
     - Under **`starter`**: the channel creator (`channelOwner(row.CreatedBy, hum)`),
       workspace owner, or workspace admin. Default channels (`#lobby`,
       `#alerts`, `#feedback`, `#public`) have `created_by = 'hub'` (not
       `HUM-*`), so under `starter` only workspace owners and admins satisfy
       `change`.
     - On the **demo workspace**: `s.archivePolicy(t)` returns `starter`
       (`demo.go:77-79`), and `channelDoor` already blocks `demo_user` via
       `rbac.ChannelsEdit` (`channel_members.go:132`).
   - Refusal when `mayChannelLoops` is false: `403 not_allowed`.
   - `GET /v1/channels/{channel}/loops` returns `"may_edit"` computed from
     the same `mayChannelLoops` check (plus `s.allowed(ctx, hum, t.ID, rbac.ChannelsEdit)`),
     so the WUI dialog renders read-only with the lock reason when `may_edit`
     is `false`.
3. **Fire-time author re-check (decided, matching 4.2 step 7 and 4.5):**
   - `SetBy` stores the author's member id (`hum`, 7.1.1 "The author's two
     ids"). Before firing (and when rendering `idle` in loop JSON),
     `channelLoopIdle(ctx, l, chRow)` verifies:
     1. `s.access(ctx, l.SetBy, l.TenantID)` succeeds and
        `s.canReadChannel(ctx, l.TenantID, l.ChannelID, l.SetBy)` is true
        (else `"author_left"`);
     2. `s.mayChannelLoops(ctx, t, chRow, l.SetBy)` is true (else
        `"author_no_right"`, e.g. when a workspace changes
        `tenants.topic_archive_policy` from `everyone` to `admins` or
        `starter` after the loop was created).
   - An idle loop fires nothing and shows its reason in the dialog; any
     authorized member may delete it or edit it (taking ownership as `SetBy`).

### 9.5 Lifecycle: archive, delete, unarchive, and move

| event | where on `origin/master` (`c9dd02117`) | effect on channel loops |
|---|---|---|
| **Channel deleted** | `handleDeleteChannel` (`channel_members.go:562`) -> `retireChannel` (`:663`) -> `DeleteChannel` (`channels_postgres.go:93`) | `FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE` deletes every `channel_loops` row and cascades to `channel_loop_state` in the same transaction. Memory store deletes both maps inside `DeleteChannel`. |
| **Channel archived** | `handleArchiveChannel` (`channel_members.go:572`) AND `handleArchiveTenantChannel` (`tenant_settings.go:493`) -> `ArchiveChannel` (`channels_postgres.go:136`) | **Keeps** `channel_loops` rows intact (channel archive is explicitly reversible, matching how `ArchiveChannel` keeps `topic_loops` rows — `dropTopicLoops` is called only in `topic_archive.go:217,268`, never in `retireChannel`). While archived, `ChannelLoopsOn`, `ClaimDueChannelLoops`, and `ClaimDueChannelLoopIdles` skip archived channels (`notArchived`), `loopTopicHeld` skips archived cards, and `channelDoor` returns `404 unknown_channel`. |
| **Channel unarchived** | `handleUnarchiveChannel` (`channel_members.go:583`) -> `UnarchiveChannel` (`channels_postgres.go:177`) | Kept channel loops resume automatically. Inside `UnarchiveChannel`'s transaction, `state = 'on'` loops have `next_due_at` and `daily_due_at` recomputed forward from `now` and any stale `idle_due_at` / `idle_post` in `channel_loop_state` is cleared, so revival produces no missed-tick burst. |
| **Topic archived or deleted** | `handleArchiveTopic` (`topic_archive.go:197`), `handleDeleteTopic` (`:248`) -> `dropTopicLoops` (`topic_loop.go:129`) | Deletes `channel_loop_state` rows for that `task_id` (`DeleteChannelLoopTopicState`); the `channel_loops` definition stays intact for all other topics in the channel. |
| **Topic moved between channels** | `handleMove` (`message_move.go:197`) | Calls `DeleteChannelLoopTopicState` for the moved `task_id` so old-channel `idle_due_at` / `awaiting` rows cannot fire after the move; future events in the topic evaluate the destination channel's loops. |
| **Topic merged or merge undone** | `mergeTopic` (`topic_merge.go:77` -> `MergeTopic`, `topic_merge_postgres.go:29`) and `unmergeTopic` (`topic_merge.go:128` -> `UnmergeTopic`, `topic_merge_postgres.go:107`) | `mergeTopic` calls `DeleteChannelLoopTopicState` for the merged-away source `c.m.TaskID`; `unmergeTopic` calls `DeleteChannelLoopTopicState` for the restored task `from` (and `c.m.TaskID`), so no stale `idle_due_at` / `awaiting` row fires across channels after a merge or undo. |
| **Channel moved/copied across workspaces (spec 169)** | `internal/channelmove/catalogue.go:93` (`topic_loops`) | Register `channel_loops` (`Class: Moved`, `Set: "channel_id = @channel"`) and `channel_loop_state` (`Class: Moved`, `Set: "task_id = ANY(@tasks)"`, ordered after `channel_loops` for FK parent-before-child insert order, `catalogue.go:61`). |

### 9.6 Limits, cost, quota, and rate (CL4 B, msg `facaaf33`)

A channel can hold hundreds of topics. Unbounded fan-out would burn LLM
quota, flood box queues (`QueueMaxPerBox`, `internal/hub/server.go:88`),
and stall the 60-second ticker. Five bounds govern channel loops:

1. **Event-driven triggers are O(1) topics per event:**
   `after_agent_reply`, `before_agent_reply`, `after_human_reply`,
   `post_has_keyword`, `post_has_file`, `blocker_posted`,
   `no_reply_after_human`, and `issue_status_changed` fire **only** on the
   specific topic(s) where the event occurred — never across quiet topics in
   the channel.
2. **Three-tier hourly cap and cap interaction (atomic in `CountChannelLoopFire`):**
   Without a channel-wide ceiling, 20 loops × 60 fires/hour would allow
   1,200 prompts/hour on one channel (and 20 × 12 = 240/hour on one topic).
   `CountChannelLoopFire` locks the channel's `channel_loops` rows
   (`<= 20` rows, `ORDER BY loop_id FOR UPDATE`) and enforces all three
   rolling 1-hour caps in one transaction across hub instances:
   - **Per-`(loop_id, task_id)` cap — 12 fires/h:** `SPOOL_HUB_TOPIC_LOOP_CAP`
     (default **12**, Q4 B), stored on `channel_loop_state`. Prevents one
     noisy topic from starving the rest of the channel.
   - **Per-channel-loop cap — 60 fires/h:** `SPOOL_HUB_CHANNEL_LOOP_CAP`
     (default **60**, CL4 B; `Options.ChannelLoopCap` beside `Options.TopicLoopCap`
     at `internal/hub/server.go:121`, wired from `internal/config/config.go:396`
     and `cmd/spool/hub.go:427`). Stored on `channel_loops`; caps one loop
     across all topics in the channel combined.
   - **Per-channel total cap — 120 fires/h:** `SPOOL_HUB_CHANNEL_TOTAL_CAP`
     (default **120**; `Options.ChannelLoopTotalCap`). Computed inside the
     same `FOR UPDATE` transaction as
     `SUM(CASE WHEN hour_start > at - interval '1 hour' THEN fires_in_hour ELSE 0 END)`
     across **all** `channel_loops` rows of `(tenant_id, channel_id)`.

   **How the 60/h per-loop cap and 120/h per-channel cap interact:**
   - **Strict conjunction (atomic no-op on refusal):** a fire succeeds only
     when `topic_fires < 12` **AND** `loop_fires < 60` **AND**
     `channel_active_sum < 120` (after rolling any stale `hour_start <= at - 1h`
     counter to `0`). If any of the three ceilings is reached, **none** of the
     counters increments.
   - **1 or 2 loops on a channel:** each loop can run up to its full
     **60 runs/h** (1 loop -> max 60/h; 2 loops -> 60 + 60 = 120/h); the 120/h
     channel cap never restricts a single loop below 60/h.
   - **3 to 20 loops on a channel:** the **120 runs/h** channel cap is the
     shared binding ceiling across all loops of that channel. Each loop still
     caps individually at **60/h**, and once the sum of active-window fires
     across all loops of that channel reaches **120/h**, **every** loop on
     that channel holds until the earliest active `hour_start + 1h` rolls over
     (dropping that loop's fires out of `channel_active_sum`) so the channel
     sum falls below 120 again. Because `ClaimDueChannelLoops` claims in
     deterministic `(channel_id, loop_id)` order, lower-`loop_id` loops claim
     shared 120/h budget first when 3 or more due loops collide in the same
     tick (accepted in v1 for deterministic testing and simple SQL; fair
     rotation can follow only if multi-loop channels hit 120/h in practice).
   - **Typed stop semantics during a timed tick:** `CountChannelLoopFire`
     returns an outcome (`ChannelFireOK`, `ChannelFireTopicCap`,
     `ChannelFireLoopCap`, `ChannelFireChannelCap`, `ChannelFireInactive`).
     When a single topic hits **12/h** (`ChannelFireTopicCap`), the ticker
     skips that topic and **continues** to older open topics; when the loop
     hits **60/h** (`ChannelFireLoopCap`) or the channel hits **120/h**
     (`ChannelFireChannelCap`), the ticker **stops** scanning that loop
     immediately for the tick.
   - **Shared event + timed budget; independent of topic loops:** both
     event-driven fires and periodic timed fires of a channel loop charge the
     same 12 / 60 / 120 counters, so total channel-loop output can never
     exceed 120 prompts/h per channel regardless of trigger mix. A topic's own
     `topic_loops` rows keep their independent 12/h cap (`CountTopicLoopFire`)
     and do not draw from the channel's 60/h or 120/h budgets.
   - **Dialog `held_until`:** when a loop's own `fires_in_hour >= 60` in an
     active window, `held_until` is `l.HourStart + 1h`. When the loop itself
     is under 60/h but the channel's active sum is `>= 120`, `held_until` is
     the **earliest active `hour_start + 1h`** among the channel's loops (the
     moment channel capacity frees up).
3. **Per-channel loop count ceiling:**
   - At most **`ChannelLoopsMax = 20`** loops per channel (`AddChannelLoop`
     returns `ErrBadTopicLoop` -> `400 bad_loop` when a channel already has
     20 loops). Prevents accidental combinatorial multiplication.
4. **Periodic time triggers (`every_hour`, `every_n_minutes`, `daily_at`) across
   every open topic (CL4 B, msg `facaaf33`):**
   - No recency cutoff (no 7-day active-days filter) and no 25-topic per-tick
     slice.
   - When `ClaimDueChannelLoops` claims due channel loops (in deterministic
     `(channel_id, loop_id)` order), `channelLoopTickOnce` scans **every open
     topic** whose canonical channel is `channel` (matching `channelOf` at
     `internal/hub/channels.go:76-94`: `TopicChannel`, else `TaskFirstChannel`,
     so a task with `topic_head_parts` rows in two channels is scanned only
     under its canonical channel), **newest activity first**
     (`ORDER BY last_at DESC, task_id DESC`), via keyset-paginated
     `ChannelOpenTopics` (`ChannelOpenTopicsPage = 100` rows per page) using
     the existing covering index
     `topic_head_parts_channel (tenant_id, channel, last_at DESC, task_id DESC)`
     (`0144_topic_heads.sql:100`) joined to `topic_heads` where
     `NOT card_archived`, excluding `LobbyTaskID`.
   - For each open topic in newest-first order:
     1. Skip if `loopTopicHeld(ctx, tenant, taskID)` (archived or paused via
        `AnyTopicPaused`) — no cap charged.
     2. Skip if `loopTarget(...)` finds no announced agent (`topicAgents`) —
        no cap charged.
     3. Call `CountChannelLoopFire(..., 12, 60, 120)`: fire on `ChannelFireOK`,
        continue to the next topic on `ChannelFireTopicCap`, and stop scanning
        this loop for the tick on `ChannelFireLoopCap`, `ChannelFireChannelCap`,
        or `ChannelFireInactive`.
   - **Cap-stopped ticks drop unreached older topics (no carry-over):**
     because `ClaimDueChannelLoops` already moved `next_due_at` /
     `daily_due_at` forward, any older open topics not reached before
     `ChannelFireLoopCap` or `ChannelFireChannelCap` stopped the scan are
     **dropped for that occurrence — there is no carry-over cursor and no
     catch-up**. With more than 60 eligible open topics, each occurrence
     runs on the newest 60 eligible topics and drops the older ones,
     matching CL4 B ("every open topic, newest first, at most 60 runs an
     hour per loop").
   - **Cap refusal and skip log contract:**
     - When a timed tick stops on `ChannelFireLoopCap` or
       `ChannelFireChannelCap`, emit **one `Info` log line per `(loop_id,
       tick)`** (`"channel loop tick stopped by cap"`) with structured fields
       `tenant`, `channel`, `loop_id`, `outcome` (`"loop_cap"` |
       `"channel_cap"`), `fired`, `skipped` (total skipped topics before
       stopping, or broken out as `skipped_topic_cap`, `skipped_held`,
       `skipped_no_agent`), and `remaining_unscanned: true`.
     - On each per-topic skip (`ChannelFireTopicCap`) during a tick or event
       fire — and on an event-driven `ChannelFireLoopCap` /
       `ChannelFireChannelCap` refusal — emit one `Info` log line matching
       `s.loopSkip` (`internal/hub/topic_loop_fire.go:390`) with `tenant`,
       `channel`, `task_id`, `loop_id`, and `why` (`"topic_cap"` |
       `"loop_cap"` | `"channel_cap"`).
   - `no_reply_after_human` fires only on topics armed by a human post
     (`channel_loop_state_idle`), charging the same 12 / 60 / 120 caps.
5. **Zero hot-path cost when unused:**
   - Cached per-tenant bit `channelLoopBits` (30 s TTL,
     `TenantHasChannelLoops`, mirroring `topicLoopBits` at
     `internal/hub/topic_loop.go:63-93`). A workspace with no channel loops
     adds **0** store round trips on every browser or box send
     (`TestRoundTripsPerRequest` unchanged).
   - A DM post (`channel == ""`) skips channel loops with **0** probes even
     when the workspace has channel loops.
   - Workspace billing write checks (`billing.AllowsWrite`) and per-box
     queue caps (`QueueMaxPerBox`) apply to every stored prompt as today.

### 9.7 Store and migration

#### Why two dedicated tables instead of a scope column on `topic_loops`

Adding a nullable `channel_id` / `scope` column to `topic_loops` is
**rejected** for four concrete reasons measured on `origin/master`
`c9dd02117`:

1. **Per-topic runtime state is 1-to-N for a channel loop:** `topic_loops`
   (`0301_topic_loops.sql:53-86`) stores `awaiting`, `awaiting_until`,
   `idle_due_at`, `idle_post`, and `fires_in_hour` directly on the single
   row (`task_id uuid NOT NULL`). A channel loop applies to *N* topics at
   once and needs *N* independent `awaiting` and `idle_due_at` slots, so a
   child state table is required regardless.
2. **Hard-delete FK integrity:** `channel_loops` takes
   `FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE`
   (matching `channel_subscriptions`, `0002_channels.sql:22`), giving atomic
   cleanup on `DeleteChannel` without nullable-column FK workarounds.
3. **Zero churn on existing queries, indexes, and spec 186:** keeping
   `topic_loops` untouched preserves `topic_loops_task`, `topic_loops_due`,
   `catalogue.go:93` (`Set: task_id = ANY(@tasks)`), and avoids colliding
   with spec 186 row M10 (`ALTER TABLE topic_loops ADD COLUMN targets jsonb`,
   `csi-spl-doc/doc/md/spec-186-build-plan.md:438`).
4. **Zero changes to `messages`:** `messages.loop_id`
   (`0301_topic_loops.sql:110`) is `uuid NULL` with no foreign key (7.1.3).
   A channel-loop prompt writes `messages.loop_id = <channel_loop.loop_id>`,
   so all nine hidden-row places of 5.2, L2b's sweep/auto-take, and
   SPL-6309's DM-mirror skip work unchanged.

#### Schema (`<NNNN>_channel_loops.sql`)

New forward-only migration numbered by `do_rdb_migration_next` at build
time (head on `origin/master` `c9dd02117`: `0323_fleet_ask_queue_order.sql`).
Both tables carry `ENABLE` + `FORCE ROW LEVEL SECURITY` (`tenant_scope` +
`operator_scope`, matching `0301_topic_loops.sql:95-104`) and the deferred
`change_stamp` trigger (`tenant_change_bump()`, `:106-108`), and are added
to `internal/store/rls_test.go` (beside `"topic_loops"` at `:92`).

```sql
CREATE TABLE IF NOT EXISTS channel_loops (
    tenant_id      text        NOT NULL,
    loop_id        uuid        NOT NULL,
    channel_id     text        NOT NULL,
    prompt         text        NOT NULL CHECK (prompt <> '' AND length(prompt) <= 4000),
    triggers       text[]      NOT NULL CHECK (triggers <@ ARRAY['after_agent_reply', 'before_agent_reply', 'after_human_reply',
                                                                 'every_hour', 'every_n_minutes',
                                                                 'post_has_keyword', 'post_has_file', 'blocker_posted',
                                                                 'no_reply_after_human', 'issue_status_changed', 'daily_at']
                                               AND cardinality(triggers) >= 1),
    interval_min   integer     CHECK (interval_min BETWEEN 5 AND 1440),
    next_due_at    timestamptz,
    keyword        text        CHECK (keyword <> '' AND length(keyword) <= 200),
    idle_min       integer     CHECK (idle_min BETWEEN 5 AND 1440),
    daily_at       time,
    daily_tz       text        NOT NULL DEFAULT 'UTC' CHECK (daily_tz <> '' AND length(daily_tz) <= 64),
    daily_due_at   timestamptz,
    set_by         text        NOT NULL CHECK (set_by <> '' AND length(set_by) <= 64),
    set_at         timestamptz NOT NULL,
    state          text        NOT NULL DEFAULT 'on' CHECK (state IN ('on', 'paused')),
    hour_start     timestamptz,
    fires_in_hour  integer     NOT NULL DEFAULT 0 CHECK (fires_in_hour >= 0),
    fires_total    integer     NOT NULL DEFAULT 0 CHECK (fires_total >= 0),
    last_fired_at  timestamptz,
    PRIMARY KEY (tenant_id, loop_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE,
    CHECK ((interval_min IS NOT NULL) = ('every_n_minutes' = ANY (triggers))),
    CHECK ((keyword IS NOT NULL) = ('post_has_keyword' = ANY (triggers))),
    CHECK ((idle_min IS NOT NULL) = ('no_reply_after_human' = ANY (triggers))),
    CHECK ((daily_at IS NOT NULL) = ('daily_at' = ANY (triggers)))
);

CREATE INDEX IF NOT EXISTS channel_loops_channel ON channel_loops (tenant_id, channel_id);
CREATE INDEX IF NOT EXISTS channel_loops_due ON channel_loops (least(next_due_at, daily_due_at)) WHERE state = 'on';

CREATE TABLE IF NOT EXISTS channel_loop_state (
    tenant_id      text        NOT NULL,
    loop_id        uuid        NOT NULL,
    task_id        uuid        NOT NULL,
    hour_start     timestamptz,
    fires_in_hour  integer     NOT NULL DEFAULT 0 CHECK (fires_in_hour >= 0),
    fires_total    integer     NOT NULL DEFAULT 0 CHECK (fires_total >= 0),
    last_fired_at  timestamptz,
    awaiting       text        NOT NULL DEFAULT '' CHECK (length(awaiting) <= 64),
    awaiting_until timestamptz,
    idle_due_at    timestamptz,
    idle_post      uuid,
    PRIMARY KEY (tenant_id, loop_id, task_id),
    FOREIGN KEY (tenant_id, loop_id) REFERENCES channel_loops (tenant_id, loop_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS channel_loop_state_task ON channel_loop_state (tenant_id, task_id);
CREATE INDEX IF NOT EXISTS channel_loop_state_idle ON channel_loop_state (idle_due_at) WHERE idle_due_at IS NOT NULL;
```

Notes:
- `channel_loop_state` rows are created lazily (`INSERT ... ON CONFLICT DO
  UPDATE`) on the first idle arm, fire count, or awaiting write for
  `(loop_id, task_id)`: quiet topics consume zero rows.
- Pausing a channel loop zeroes `next_due_at` and `daily_due_at` on
  `channel_loops` and clears `idle_due_at` / `idle_post` on its
  `channel_loop_state` rows in the same edit transaction. Editing `prompt`
  or `triggers` resets `hour_start` and `fires_in_hour` on `channel_loops`
  and its `channel_loop_state` rows.

### 9.8 Binding contracts for parallel rows

#### 9.8.1 Go store (`ChannelLoopStore`, C1 builds, C2a and C2b call)

Package `store`, file `internal/store/channel_loop.go`, implemented by
`Memory` and `Postgres` (`var _ ChannelLoopStore = (*Memory)(nil)` and
`(*Postgres)(nil)`), read by the hub as an optional interface
`s.o.Store.(store.ChannelLoopStore)` (`501 not_implemented` when absent,
matching 7.1.1 point 4). Validation reuses `TopicLoopTriggers`,
`TopicLoopOn`, `TopicLoopPaused`, `TopicLoopIntervalMin..Max`,
`TopicLoopPromptMax`, `TopicLoopKeywordMax`, and `ErrBadTopicLoop`.

```go
const (
	ChannelLoopsMax            = 20  // max loops per channel
	ChannelLoopCapDefault      = 60  // SPOOL_HUB_CHANNEL_LOOP_CAP: fires per channel loop per hour across all topics (CL4 B)
	ChannelLoopTotalCapDefault = 120 // SPOOL_HUB_CHANNEL_TOTAL_CAP: total fires per hour summed across all loops of one channel
	ChannelOpenTopicsPage      = 100 // keyset page size for newest-first open-topic scans

	// Outcome strings returned by CountChannelLoopFire (9.6).
	ChannelFireOK         = ""            // fire counted across all three caps
	ChannelFireTopicCap   = "topic_cap"   // per-(loop_id, task_id) 12/h cap reached; ticker skips topic
	ChannelFireLoopCap    = "loop_cap"    // per-channel-loop 60/h cap reached; ticker stops loop
	ChannelFireChannelCap = "channel_cap" // per-channel total 120/h cap reached; ticker stops loop
	ChannelFireInactive   = "inactive"    // loop paused, channel archived, or row gone
)

type ChannelLoop struct {
	TenantID    string
	LoopID      string // uuid, lower case
	ChannelID   string // normalized channel slug
	Prompt      string
	Triggers    []string // distinct, sorted
	SetBy       string   // author's member id (hum), as 7.1.1
	SetAt       time.Time
	State       string // TopicLoopOn | TopicLoopPaused
	HourStart   time.Time
	FiresInHour int
	FiresTotal  int
	LastFiredAt time.Time
	IntervalMin int
	NextDueAt   time.Time
	Keyword     string
	IdleMin     int
	DailyAt     string
	DailyTZ     string
	DailyDueAt  time.Time
	Due         []string  // set only by ClaimDueChannelLoops
	DueAt       time.Time // pre-move earliest due time, as 7.1.1
}

type ChannelLoopTopicState struct {
	TenantID    string
	LoopID      string
	TaskID      string
	HourStart   time.Time
	FiresInHour int
	FiresTotal  int
	LastFiredAt time.Time
	Awaiting    string
	AwaitUntil  time.Time
	IdleDueAt   time.Time
	IdlePost    string
}

type ChannelLoopIdleDue struct {
	Loop     ChannelLoop
	TaskID   string
	IdlePost string // pre-clear arming post msg_id
}

type ChannelOpenTopic struct {
	TaskID string
	LastAt time.Time
}

type ChannelLoopStore interface {
	ChannelLoops(ctx context.Context, tenant, channel string) ([]ChannelLoop, error)
	ChannelLoopsOn(ctx context.Context, tenant, channel string) ([]ChannelLoop, error)
	AddChannelLoop(ctx context.Context, tenant string, l ChannelLoop) (ChannelLoop, error)
	EditChannelLoop(ctx context.Context, tenant, channel, loopID string, e TopicLoopEdit) (ChannelLoop, error)
	DeleteChannelLoop(ctx context.Context, tenant, channel, loopID string) (bool, error)
	DeleteChannelLoops(ctx context.Context, tenant, channel string) (int, error)
	ChannelLoopStates(ctx context.Context, tenant, taskID string, loopIDs []string) ([]ChannelLoopTopicState, error)
	// CountChannelLoopFire atomically locks the channel's loops (ORDER BY loop_id
	// FOR UPDATE) and checks & increments all three hourly caps in one transaction:
	// per-(loop_id, task_id) (topicCap), per-channel-loop (loopCap), and total
	// active-window fires across all loops of that channel (channelTotalCap).
	// Returns outcome = ChannelFireOK ("") when counted, or ChannelFireTopicCap /
	// ChannelFireLoopCap / ChannelFireChannelCap / ChannelFireInactive with no
	// counter incremented.
	CountChannelLoopFire(ctx context.Context, tenant, loopID, taskID string, at time.Time, topicCap, loopCap, channelTotalCap int) (ChannelLoop, ChannelLoopTopicState, string, error)
	// ClaimDueChannelLoops claims state='on' non-archived channel loops whose
	// next_due_at or daily_due_at <= at (ORDER BY channel_id, loop_id FOR UPDATE
	// SKIP LOCKED), moving due columns on and returning Due + pre-move DueAt.
	ClaimDueChannelLoops(ctx context.Context, at time.Time, limit int) ([]ChannelLoop, error)
	// ChannelOpenTopics returns unarchived topics whose canonical channel
	// (matching hub channelOf: TopicChannel, else TaskFirstChannel) is channel
	// (excluding lobbyTaskID), ordered by last_at DESC, task_id DESC, strictly
	// after the keyset cursor (beforeAt, beforeTaskID) when beforeAt is non-zero,
	// up to limit (<= 0 defaults to ChannelOpenTopicsPage), using topic_head_parts_channel.
	ChannelOpenTopics(ctx context.Context, tenant, channel, lobbyTaskID string, beforeAt time.Time, beforeTaskID string, limit int) ([]ChannelOpenTopic, error)
	ArmChannelLoopIdle(ctx context.Context, tenant, channel, taskID, postID string, at time.Time) (int, error)
	ClearChannelLoopIdle(ctx context.Context, tenant, taskID string) (int, error)
	ClaimDueChannelLoopIdles(ctx context.Context, at time.Time, limit int) ([]ChannelLoopIdleDue, error)
	SetChannelLoopAwaiting(ctx context.Context, tenant, loopID, taskID, agent string, until time.Time) error
	DeleteChannelLoopTopicState(ctx context.Context, tenant, taskID string) (int, error)
	TenantHasChannelLoops(ctx context.Context, tenant string) (bool, error)
}
```

- **Fired message id:** `uid.FromSeed("channel-loop:" + loopID + ":" + taskID + ":" + cause)`
  where `cause` uses the exact 7.1.1 cause strings (`msg_id`, `"idle:" + IdlePost`,
  `"due:" + DueAt`, `"issue:" + number + ":" + status + ":" + updatedAt`).
  Including `taskID` guarantees distinct ids when one tick or one issue
  fires multiple topics in the channel.
- **Fired message body:**
  ```text
  Loop prompt (background; channel #<channel>, set by @HUM-n, fired by <cause>)

  <prompt text>

  > <the trigger post / issue / latest post, cut to 600 characters>
  ```
  Keeps the exact `topicLoopPromptMark` prefix (`"Loop prompt (background; "`,
  `topic_loop_fire.go:70`), so `isLoopTrigger`, `latestPost`, and SPL-6309's
  `spool_notify_is_loop_prompt` treat it identically to a topic loop prompt.
- **L7 (`mail-file`) compatibility:** when row L7 is built, its `--cause`
  lookup resolves `messages.loop_id` against `topic_loops` OR `channel_loops`
  to verify the loop's `set_by` matches the recipient.

#### 9.8.2 HTTP and WS (C2a serves, C3 calls)

Channel loop JSON (same fields as 7.1.2, `"channel"` in place of `"task_id"`):

```json
{
  "loop_id": "<uuid>", "channel": "<channel_id>", "prompt": "<text>",
  "triggers": ["after_agent_reply", "every_n_minutes"], "interval_min": 30,
  "next_due_at": "2026-11-25T10:00:00Z",
  "state": "on", "set_by": "HUM-10", "set_at": "2026-11-25T09:30:00Z",
  "fires_in_hour": 3, "held_until": "2026-11-25T10:12:00Z",
  "idle": "",
  "keyword": "pdf", "idle_min": 15,
  "daily_at": "08:00", "daily_tz": "Europe/Helsinki",
  "daily_due_at": "2026-11-26T06:00:00Z"
}
```

| route | body | answer | refusals |
|---|---|---|---|
| `GET /v1/channels/{channel}/loops` | — | `200 {"channel": "<id>", "may_edit": true, "loops": [<loop>...]}` | `404 unknown_channel` (`channelDoor` + `ChannelHidden` / `#issues`), `501 not_implemented` |
| `POST /v1/channels/{channel}/loops` | same body as `POST /v1/topics/{task_id}/loops` (7.1.2) | `201 <loop>` | `400 bad_loop` (incl. `> ChannelLoopsMax`), `403 not_allowed` / `demo_read_only` / `forbidden`, `404 unknown_channel`, `501 not_implemented` |
| `PUT /v1/channels/{channel}/loops/{loop_id}` | same body as `PUT /v1/topics/{task_id}/loops/{loop_id}` (7.1.2) | `200 <loop>` | as POST, plus `404 not_found` (no such loop) |
| `DELETE /v1/channels/{channel}/loops/{loop_id}` | — | `200 {"loop_id": "<uuid>", "deleted": true}` (`false` when gone) | `403 not_allowed`, `404 unknown_channel`, `501 not_implemented` |
| `OPTIONS` on both paths | — | CORS preflight (`GET, POST, PUT, DELETE`), as `topicLoopsPreflight` (`topic_loop.go:45`) | — |

- **Live WS frame:** after each write (`POST`, `PUT`, `DELETE`), the hub
  sends `{"type": "channel_loops", "channel": "<id>", "loops": [<loop>...]}`
  to every channel member's open browser socket via
  `s.fanoutChannelFrame(ctx, tenant, s.channelMemberSet(ctx, tenant, ch), frame)`
  (`internal/hub/wui.go:1352`).
- **`may_edit` and `held_until`:** `may_edit` is computed from
  `tenants.topic_archive_policy` (`mayChannelLoops` + `rbac.ChannelsEdit`,
  9.4). `held_until` is `l.HourStart + 1h` when the loop is at the 60/h
  per-loop cap, or the earliest active `hour_start + 1h` among the channel's
  loops when the channel is at the 120/h total cap (9.6).
- **OpenAPI:** add `ChannelLoop` schema and both paths to
  `internal/hub/openapi.json` beside `TopicLoop` (`:1113`).

#### 9.8.3 WUI (C3 builds, C4 verifies in Chrome)

- `csi-spl-wui/src/utils/sidebar-row-menu.mjs`: add `loops?: boolean` to
  `rowMenuItems` (`:14`), emit `{ id: 'channel-loops', icon: 'refresh', labelKey: 'sidebar.row_menu.channel_loops' }`
  between `properties` (`:32`) and `archive-channel` (`:34`); add `'refresh'`
  to the icon return JSDoc union (`:16`).
- `csi-spl-wui/src/components/SidebarRowMenu.vue`: add `loops?: boolean`
  prop, `channelLoops: []` emit, pass `loops: props.loops` to `rowMenuItems`
  (`:130-142`), and branch `id === 'channel-loops'` -> `emit('channelLoops')`
  in `choose` (`:245-277`).
- `csi-spl-wui/src/components/ChannelSidebar.vue` and
  `csi-spl-wui/src/composables/useSidebarChannelAdmin.ts`: pass
  `:loops="showProperties(c.channel_id)"` and
  `@channel-loops="openChannelLoops(c.channel_id)"` on `<SidebarRowMenu>`
  (`ChannelSidebar.vue:352-375`), lazily mount `<LazyTopicLoopsDialog>`
  with `:channel-id` and `:channel-name` (gated on target, matching
  `ChannelPropertiesDialog` at `ChannelSidebar.vue:641`).
- `csi-spl-wui/src/components/TopicLoopsDialog.vue` and
  `csi-spl-wui/src/utils/topic-loops.mjs`: support `channelId?: string` /
  `channelName?: string` alongside `taskId?: string`, dispatch to
  `listChannelLoops` / `addChannelLoop` / `editChannelLoop` /
  `deleteChannelLoop`, add `channelLoopsFromFrame(frame, channelId)` in
  `topic-loops.mjs`, and subscribe to `useLive().onChannel` (plus
  `onMockChannelLoops` in mock mode).
- `csi-spl-wui/src/utils/live-ws.mjs`: add `channelLoops: 'channel_loops'`
  to `FRAMES` (beside `channelDeleted` at `:35`) and route it to
  `onChannel(f)` (`:529-532`).
- `csi-spl-wui/src/utils/spool-client.mjs`, `spool-client-lazy.mjs`,
  `spool-client-mock.mjs`, `src/types/mjs-shims.d.ts`: add the five
  `*ChannelLoop*` client methods and mock handlers.
- `csi-spl-wui/i18n/locales/*.json` (all 19 locale files): new keys under
  `sidebar.row_menu.channel_loops` and `sidebar.channel_loops.*` (title,
  scope note, empty, locked, error keys), translated with
  `do_spl_lang_review_gct` (language rule).

### 9.9 Build rows (channel loops, C1-C5 — disjoint files, red controls, vendor kind table)

Six small rows, strictly **disjoint in files across all rows** (R1), ready for
a build round planner. Vendor assignments follow the fleet kind table
(`csi-spl-cnf/csi-spl/all.env.yaml:1567-1574`) and standing guards
(`:1514-1530`, `rounds-rulebook.md` 2.7.2, `developer-guide.md` 5.1):

- **`complex_coding`:** main `claude` (90%), backup `agy` (10%); cross-vendor
  R7 reviewer `agy` (or `claude` if authored by `agy`).
- **`simple_coding`:** main `claude` (44%), `agy` (41%, backup), `codex` (15%);
  cross-vendor R7 reviewer `agy` (if authored by `claude`/`codex`) or `claude`
  (if authored by `agy`). Never `mistral`.
- **`tests`:** main `claude` (70%), `agy` (15%, backup), `codex` (15%);
  cross-vendor R7 reviewer `agy` (if authored by `claude`/`codex`) or `claude`
  (if authored by `agy`). Never `mistral`.
- **`specs_and_docs`:** main `agy` (80%), `mistral` (15%), `claude` (5%,
  backup); because **C5** syncs user help into `csi-spl-wui/public/help-md/`,
  `mistral_ui_allowed: false` excludes `mistral` on C5, leaving `agy` (main) /
  `claude` (backup), with cross-vendor R7 reviewer `claude` (if authored by
  `agy`) or `agy` (if authored by `claude`).
- **No `mistral` review seats** (`mistral_review_allowed: false`, owner HUM-10,
  t1 `91992830`, msgs `65a45673` and `591ca574`).
- **Language check (C3):** `do_spl_lang_review_gct` (Google Cloud Translation,
  required by `CLAUDE.md`; optional `agy` review).

`api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` = `csi-spl-wui/`.

| row | batch | depends on | kind | author / R7 reviewer (kind table) | exclusive files (disjoint across all 6 rows) | tests and red control |
|---|---|---|---|---|---|---|
| **C1 rdb + store** | 1 | — | `complex_coding` | author: `claude` (backup `agy`); R7: `agy` (`claude` if `agy`) | `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_channel_loops.sql` (numbered by `do_rdb_migration_next`); `api:internal/store/{channel_loop.go,channel_loop_postgres.go,channel_loop_memory.go,channel_loop_test.go,channels_postgres.go,channels_memory.go,rls_test.go}`; `api:internal/channelmove/catalogue.go` | `PRE_PUSH_TIER=full`: Postgres + Memory parity; all 11 triggers + field CHECKs + `ChannelLoopsMax` (20) ceiling; `CountChannelLoopFire` enforces all three caps concurrently (12/h topic -> `topic_cap`, 60/h loop -> `loop_cap`, 120/h channel total -> `channel_cap`, atomic no-op on refusal) and rolls over after 1 h (including 3-loop 120/h cap interaction); `ClaimDueChannelLoops` and `ClaimDueChannelLoopIdles` skip archived channels (kept by `ArchiveChannel`), move `next_due_at` / `daily_due_at` (incl. DST in `Europe/Helsinki`), and return `Due` + pre-move `DueAt`; `UnarchiveChannel` advances due times from `now` and clears stale idle rows; `ChannelOpenTopics` uses `topic_head_parts_channel`, skips archived topics and `LobbyTaskID`, filters to topics whose canonical channel matches `channel` (a task with `topic_head_parts` rows in two channels appears only under its canonical channel), and keyset-paginates newest-first with no recency cutoff; `DeleteChannel` cascades both tables; RLS + `catalogue_test.go` pass. **Red control:** (a) archive a channel with a due loop and drop `notArchived` from `ClaimDueChannelLoops` -> archived-channel claim test fails; (b) drop the 120/h channel-sum check in `CountChannelLoopFire` -> 3-loop channel-cap test passes 120 and fails. |
| **C2a hub routes + config + WS + OpenAPI** | 2 | C1 | `complex_coding` | author: `claude` (backup `agy`); R7: `agy` (`claude` if `agy`) | `api:internal/hub/{channel_loop.go,channel_loop_test.go,view.go,server.go,openapi.json}`; `api:internal/config/config.go`; `api:cmd/spool/hub.go` | `go test ./internal/hub/... ./internal/config/...`: CRUD (`GET`/`POST`/`PUT`/`DELETE`/`OPTIONS`); CL3 B `tenants.topic_archive_policy` matrix (`everyone`, `admins`, `starter` on user-created and `hub`-created default channels, plus demo workspace forced to `starter`) + `rbac.ChannelsEdit` + `demo_read_only` + billing gate; `channelDoor` + `ChannelHidden` guard returns `404 unknown_channel` to non-members, archived channels, and hidden virtual channels (`#issues` / `ChannelTasks`, preventing an FK 500); `501 not_implemented` when store lacks `ChannelLoopStore`; `ChannelLoopsMax` (20) refusal; `channelLoopBits` cache refresh on write; `channel_loops` WS frame reaches channel members only; `idle` (`author_left` / `author_no_right` after policy flip) and `held_until` (both 60/h loop cap and 120/h channel cap earliest-rollover) reporting; `SPOOL_HUB_CHANNEL_LOOP_CAP` (60) and `SPOOL_HUB_CHANNEL_TOTAL_CAP` (120) config defaults. **Red control:** (a) bypass `channelDoor` -> non-member 404 test fails; (b) hard-code `mayChannelLoops` to `true` -> `admins` / `starter` policy refusal tests fail. |
| **C2b hub fire + tick + topic lifecycle** | 3 | C1, C2a | `complex_coding` | author: `claude` (backup `agy`); R7: `agy` (`claude` if `agy`) | `api:internal/hub/{channel_loop_fire.go,channel_loop_fire_test.go,topic_loop_fire.go,topic_loop.go,message_move.go,topic_merge.go}` | `go test ./internal/hub/...`: all 11 triggers fire on existing, newly created, and moved-in open topics, never on moved-out, merged-away, paused, archived, DM, or `LobbyTaskID` topics; CL1 A additive firing (topic loop + channel loop both fire on same event); unified Q10 A + N4 B stops cross-scope `after_agent_reply` ping-pong while still allowing another loop's keyword/file/blocker box; CL2 B uniform application (no opt-out); CL4 B timed tick scans every open topic newest-first across pages (including >25 topics and >7-day-old topics), skips paused / no-agent topics without charging caps, continues past a `topic_cap` (12/h) topic to older open topics, stops on `loop_cap` (60/h) or `channel_cap` (120/h) dropping unreached older topics with no carry-over cursor on the next tick, and asserts the log contract (one `Info` line per `(loop_id, tick)` with `loop_id`, `channel`, `outcome`, `fired`, `skipped` on cap stop, plus `why="topic_cap"` on a skipped topic); `dropTopicLoops`, `handleMove`, `mergeTopic`, and `unmergeTopic` clear `channel_loop_state`; `TestRoundTripsPerRequest` confirms 0 extra round trips on a tenant with no channel loops and on DM sends. **Red control:** (a) drop unified `ev.answer` across topic + channel pools -> cross-scope ping-pong test fails; (b) stop the tick loop on `topic_cap` instead of continuing -> older open topic after a 12/h-capped topic never fires and test fails. |
| **C3 wui + i18n + unit tests** | 3 (parallel with C2b) | C2a | `simple_coding` (+ `do_spl_lang_review_gct`) | author: `claude` (44%) / `agy` (41%, backup) / `codex` (15%) — never `mistral`; R7: `agy` if `claude`/`codex`, `claude` if `agy` | `wui:src/utils/{sidebar-row-menu.mjs,topic-loops.mjs,live-ws.mjs,spool-client.mjs,spool-client-lazy.mjs,spool-client-mock.mjs}`; `wui:src/components/{SidebarRowMenu.vue,ChannelSidebar.vue,TopicLoopsDialog.vue}`; `wui:src/composables/useSidebarChannelAdmin.ts`; `wui:src/types/mjs-shims.d.ts`; `wui:i18n/locales/*.json` (19 files); `wui:tests/unit/{sidebar-row-menu.test.mjs,topic-loops.test.mjs}` | `pnpm run typecheck`, `pnpm run test:unit` (`i18n-parity`, `i18n-untranslated`, `i18n-no-raw-text`, `cleancode`, `sidebar-row-menu` ordering and `channel-loops` entry, `channelLoopsFromFrame`, 11-trigger form rules), and `do_spl_lang_review_gct` on the 19 locale files. **Red control:** (a) drop `channel-loops` from `rowMenuItems` -> `sidebar-row-menu.test.mjs` fails; (b) leave a raw string in `TopicLoopsDialog.vue` -> `i18n-no-raw-text.test.mjs` fails. |
| **C4 wui e2e** | 4 | C3 | `tests` | author: `claude` (70%, backup `agy`, `codex` 15%) — never `mistral`; R7: `agy` if `claude`/`codex`, `claude` if `agy` | `wui:tests/e2e/channel-loops.test.mjs` | `BASE_URL=<generated bundle> pnpm run test:e2e` on mock: right-click channel row -> **Channel loops…** -> add, edit, pause/resume, delete a loop with all 11 triggers available; verify read-only lock when `may_edit: false` (under `admins` / `starter` policy); verify live `channel_loops` WS frame updates an open dialog; verify no badge or prompt card appears in the channel. **Red control:** drop the `channelLoops` emit in `SidebarRowMenu.vue` (temporary local mutation) -> `channel-loops.test.mjs` fails to open the dialog. |
| **C5 spec status + user help** | 5 | C2b, C4 | `specs_and_docs` | author: `agy` (backup `claude`; never `mistral` due to `wui:public/help-md/`); R7: `claude` (`agy` if `claude`) | `csi-spl-doc/specs/182-topic-loop-prompt/spec.md` (row status); `csi-spl-doc/doc/help/{channels-and-direct-messages.md,index.md}` (or new `loops.md`); `wui:public/help-md/*.md` (synced by `node csi-spl-wui/src/node/help/sync-help.mjs`) | `cd csi-spl-iac && ./run -a do_check_dist_hygiene && ./run -a do_check_pre_push`, `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`, `cd csi-spl-wui && node --test tests/unit/help-sync.test.mjs`. **Red control:** edit `csi-spl-doc/doc/help/` without running `sync-help.mjs` -> `help-sync.test.mjs` fails; run `sync-help.mjs` -> passes. |

#### 9.9.1 Disjointness and batch plan (R1)

- **Zero shared files across all six rows:** `C1` owns the migration and store
  package; `C2a` owns hub routes, `view.go`, `server.go`, `config.go`,
  `cmd/spool/hub.go`, and `openapi.json`; `C2b` owns hub fire/tick and topic
  lifecycle hooks; `C3` owns WUI source, 19 locales, and unit tests; `C4` owns
  the new E2E spec; `C5` owns this spec's status update and synced user help.
- **Parallelism:** Batch 1 (`C1`) -> Batch 2 (`C2a`) -> Batch 3 (`C2b` ∥ `C3`,
  zero file overlap) -> Batch 4 (`C4`) -> Batch 5 (`C5`).

#### 9.9.2 Trigger-to-row ownership (channel loops)

| trigger | C1 (rdb + store) | C2b (hub fire + tick) | C3 (wui) |
|---|---|---|---|
| `after_agent_reply`, `after_human_reply`, `before_agent_reply` | key in `channel_loops` CHECK; per-topic `awaiting` in `channel_loop_state` | unified `topicLoopFireIf` + `topicLoopBeforeAgent` (Q10 A, N4 B across both pools) | shared checkbox in `TopicLoopsDialog.vue` |
| `every_hour`, `every_n_minutes` | `next_due_at`, `ClaimDueChannelLoops`, `ChannelOpenTopics` | `TopicLoopTickOnce` scans every open topic newest-first (CL4 B) under 12/60/120 caps | shared checkbox + n |
| `post_has_keyword` | `keyword` + CHECK | `topicLoopKeyword` on post hooks | shared checkbox + text field |
| `post_has_file` | key in CHECK | `Files` check on post hooks | shared checkbox |
| `blocker_posted` | key in CHECK | `onSend`, `wuiAfterStore`, `handleSetMessageKind` | shared checkbox |
| `no_reply_after_human` | `idle_min` on `channel_loops`, `idle_due_at`/`idle_post` on `channel_loop_state`, `ArmChannelLoopIdle`, `ClearChannelLoopIdle`, `ClaimDueChannelLoopIdles` | arm on human post, clear on agent reply, fire from `TopicLoopTickOnce` | shared checkbox + n |
| `issue_status_changed` | key in CHECK | `topicLoopIssue` resolves each linked topic's channel via `channelOf` | shared checkbox |
| `daily_at` | `daily_at`, `daily_tz`, `daily_due_at`, `ClaimDueChannelLoops`, `ChannelOpenTopics` | `TopicLoopTickOnce` scans every open topic newest-first (CL4 B) under 12/60/120 caps | shared checkbox + time + zone |

### 9.10 Verification commands (`origin/master` `c9dd02117`)

Every file path and line number in section 9 was measured on `origin/master`
`b48786ce3` and re-verified on `origin/master` `c9dd02117` (between
`b48786ce3` and `c9dd02117`, only `openapi.json` changed among cited files,
with `TopicLoop` still at `:1113`) with:

```bash
git rev-parse --short=9 origin/master
git grep -n -iE "channel_loop|channel-loops|ChannelLoop" origin/master -- csi-spl-api csi-spl-rdb csi-spl-wui | wc -l
git grep -n -i "loop" origin/master -- csi-spl-wui/src/utils/sidebar-row-menu.mjs csi-spl-wui/src/components/SidebarRowMenu.vue | wc -l
git grep -n -E 'topic_archive_policy|ArchivePolicy|archivePolicyOf' origin/master -- csi-spl-rdb/src/sql/postgres/spool-hub/0093_tenant_topic_archive_policy.sql csi-spl-api/src/go/spool-hub-api/internal/store/ csi-spl-api/src/go/spool-hub-api/internal/hub/ csi-spl-wui/src/utils/access.mjs csi-spl-wui/src/utils/topic-archive.mjs csi-spl-wui/src/utils/tenant-settings.mjs csi-spl-wui/src/pages/tenant-settings/general.vue
git grep -n -E 'export function (rowMenuItems|topicMenuLocks|topicCardMenuOpts|msgMenuItems|mayArchiveTopic|canDeleteChannel)' origin/master -- csi-spl-wui/src/utils/
git grep -n -E '^func (\(s \*Server\) )?(mayArchiveByPolicy|mayChangeTopic|archivePolicy|channelOwner|channelDoor|retireChannel|handleDeleteChannel|handleArchiveChannel|handleUnarchiveChannel|handleArchiveTenantChannel|fanoutChannelFrame|topicLoopFireIf|topicLoopHuman|topicLoopBeforeAgent|topicLoopAgent|topicLoopKindBlocker|topicLoopIssue|TopicLoopTickOnce|dropTopicLoops|routeTopicLoops|loopTarget|loopCause|loopPromptID|handleMove|topicClosed|channelOf|handleArchiveTopic|handleDeleteTopic|topicLoopsPreflight)\(' origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/
git grep -n -E 'TopicLoopCap|TOPIC_LOOP_CAP|routeTopicLoops' origin/master -- csi-spl-api/src/go/spool-hub-api/
git grep -n -E 'func \(s \*Postgres\) (DeleteChannel|ArchiveChannel|UnarchiveChannel|ClaimDueTopicLoops|CountTopicLoopFire|MergeTopic|UnmergeTopic)' origin/master -- csi-spl-api/src/go/spool-hub-api/internal/store/
git grep -n -E '^func \(s \*Server\) (handleMergeTopic|mergeTopic|unmergeTopic)\(' origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/topic_merge.go
git grep -n -E 'openChannelMenu|SidebarRowMenu|showProperties|deletableChannel|topicLoops:|channelDeleted:|topic_loops|CREATE INDEX.*topic_head_parts_channel|ChannelPropertiesDialog' origin/master -- csi-spl-wui/src/components/ChannelSidebar.vue csi-spl-wui/src/composables/useSidebarChannelAdmin.ts csi-spl-wui/src/utils/live-ws.mjs csi-spl-api/src/go/spool-hub-api/internal/channelmove/catalogue.go csi-spl-api/src/go/spool-hub-api/internal/store/rls_test.go csi-spl-rdb/src/sql/postgres/spool-hub/0144_topic_heads.sql csi-spl-rdb/src/sql/postgres/spool-hub/0301_topic_loops.sql
```

<!-- version: 0.11 · updated: 2026-11-26 · last-edit: 2026-11-26T13:30:00Z -->
