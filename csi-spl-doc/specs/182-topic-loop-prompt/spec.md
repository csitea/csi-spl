# Spec 182: Topic Loop Prompt (Discussion Loops)

Status: **Draft v0.8** (2026-11-20). Lane `c-301` (`claude`, backup for
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
agent reply" box of no loop of the topic (1.6, 8.5).
Epic: **SPL-2398**. Issue: **SPL-6022**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:f08c0c58-9228-4e2a-af00-dbbdbd328083` (`t1`).
Builds on: [179 pause the agents of a discussion](../179-pause-agents-of-a-discussion/spec.md)
(per-topic hub state, the topic menu entry, who may act on a topic),
[150 topic-list priority](../150-topic-list-priority/spec.md) (the
`topic_priorities` table shape) and [099 topic head](../099-topic-head/spec.md)
(per-topic state lives in its own table, not in `messages`).

Line references were measured on `origin/master` `af8ca0ba7`. Between it and
`412a44ab0` (the v0.2 base) no file this spec cites changed
(`git diff --name-only af8ca0ba7 412a44ab0` lists none of them).

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
| Q3 | **B** — any mix of the triggers, as checkboxes; the six triggers of msg `d44af000` replace v0.2's three (1.2) | 4.1, 4.2, the `triggers` column |
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
| `post_has_file` | a post with a file attached (ATT) | an agent reply or a human post stored with at least one file | 4.2 step 9 |
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
   - the topic's loops, one row each: the first line of the prompt, the
     checked triggers, its state (`on`, `paused`, or `held until hh:mm` by
     the cap), and its author;
   - per row: **Edit**, **Pause** / **Resume**, **Delete**;
   - **Add loop**.
   Add and Edit open the same form: the prompt (a textarea, at most 4000
   characters) and the eleven checkboxes of 1.2 (answer 3 B), with a number
   field for n (5..1440) next to "each n minutes", a text field (1..200
   characters) next to "a post that contains", a number field for n
   (5..1440) next to "no reply for n minutes", and a time (hh:mm) plus a
   time zone (default: the browser's zone) next to "every day at". Each
   field is required exactly when its box is checked. At least one box must
   be checked. Under "after each agent reply" the form says that the
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
   post whose `Files` (`store.go:138`) holds at least one file.
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

<!-- version: 0.8 · updated: 2026-11-20 · last-edit: 2026-11-20T23:30:00Z -->
