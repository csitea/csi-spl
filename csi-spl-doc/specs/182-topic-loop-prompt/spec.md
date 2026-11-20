# Spec 182: Topic Loop Prompt (Discussion Loops)

Status: **Draft v0.3** (2026-11-20). Lane `c-301` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). v0.1 `bc0353485`; v0.2 folds the
owner's answers to form `2c1c3f5d` (msg `a198ae53`) and the two requirements
in msgs `eae9e64f` and `19acb8f9`; v0.2 `d17f582cb`; v0.3 folds Q9 (msg
`e05bec70`, poll `7e28ed23`), the six triggers (msg `d44af000`), the worked
example (msg `92050cbc`) and the suggested triggers (msg `ad30fe25`), and
adds the binding contracts of 7.1 (section 8).
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
| Q4 | **B** — only the cap of 12 fires per hour | 4.2, 4.5; see Q10 in 1.4 |
| Q5 | **A** — whoever the workspace's "Who can archive topics" setting allows (as pause) | 4.1 step 1 and step 3 |
| Q6 | **B** — several loops per topic, each with its own prompt and trigger | section 5 key; the list dialog of 4.1 |
| Q7 | **C** — only the menu entry; nothing on the topic or the messages | 4.1; no badge, no notes |
| Q8 | **A** — the loop's author, marked as sent by the loop | 4.3 step 2; the mark is `messages.loop_id` |
| Q9 | **A** — yes, the agent's answer is an ordinary reply in the topic (msg `e05bec70`, poll `7e28ed23`) | 4.3 step 2, 4.4 step 1 |

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

### 1.2 The six triggers (msg d44af000)

HUM-10 (msg `d44af000`, verbatim): "so it must have the check boxes , of
"after reach reply by an agent , before each rely of an each , after each
reply of a human , before each apply of a human , each hour , each <<n>>
minutes". Read as six checkboxes, any mix (answer 3 B). They replace v0.2's
three:

| key | box | fires when | detail |
|---|---|---|---|
| `after_agent_reply` | after each agent reply | an agent reply (section 2) is stored | 4.2 step 2 |
| `before_agent_reply` | before each agent reply | a human post that an agent will answer is about to be stored: the prompt is queued to that agent ahead of the post | 4.2 step 3 |
| `after_human_reply` | after each human reply | a human post is stored | 4.2 step 1 |
| `before_human_reply` | before each human reply | **[Q11]**; proposed: an agent reply addressed to the loop's author is stored (the moment before the author replies) | 4.2 step 4 |
| `every_hour` | each hour | 60 minutes after the last time fire | 4.2 step 5 |
| `every_n_minutes` | each n minutes | n minutes after the last time fire; n is 5..1440 | 4.2 step 5 |

The cap stays 12 fires per loop per hour (answer 4 B), so n is at least 5:
12 fires an hour is the most `every_n_minutes` can fire. A post that matches
two checked boxes fires once.

v0.2's "only another human's post" is not in the owner's list and is
dropped.

### 1.3 Q9, answered

The v0.2 form asked whether the agent's answer to a loop prompt is shown in
the topic. HUM-10 answered **A** — "Yes, as an ordinary reply in the topic"
(msg `e05bec70`, poll `7e28ed23`). No question is open.

### 1.4 Open questions (one form)

Two questions are open. Neither changes the schema of 5.1 or the contracts
of 7.1 (both are columns or keys that exist either way), so L1 and L3 do not
wait for them; L2 builds the recommended answer behind one switch.

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

- **Q10 A** (recommended): the hub knows the answer as the target agent's
  next agent reply in the topic within 30 minutes of the fire
  (`awaiting`, `awaiting_until` in 5.1); that reply fires every other loop
  as usual, but not this one. Without it, the worked example of 4.6 mails
  the owner up to 12 PDFs in a burst for one real reply. B is answer 4 B as
  it stands. C revisits Q9 and depends on every agent following the prompt.
- **Q11 A** (recommended): the hub has that event already (an agent reply
  stored, `ws.go:702`), and it fits the owner's example "after each reply to
  me by an agent" exactly. B has no hub signal today:
  `grep -rln '"typing"' csi-spl-api/src/go/spool-hub-api/internal/hub/*.go`
  -> nothing; it needs a WUI-to-hub frame and its own row.

### 1.5 Suggested extra triggers (msg ad30fe25)

HUM-10 (msg `ad30fe25`): "suggest also different type of triggers which
might be worth doing and setting in the modal dialog box during the
configuration setting of the loop". Each is a suggestion for the owner to
take or drop; none is in the build rows until taken.

```poll
Which extra triggers should the loop dialog offer? Pick any.
[KW] A post that contains a word or phrase you type
[ATT] A post with a file attached
[BLK] A blocker posted in the topic
[IDL] No reply for n minutes after a human post
[ISS] An issue linked to the topic changes status
[DLY] Every day at a set time
```

| key | what it costs |
|---|---|
| `KW` | a text field and one case-free whole-word match per stored post, in the hub; no new event |
| `ATT` | none beyond the trigger check: the stored post already carries its files |
| `BLK` | none beyond the trigger check: `kind = blocker` on the stored post |
| `IDL` | a timer per loop on the time-trigger tick (4.2 step 5), reset by every reply |
| `ISS` | a hook in the hub's issue status write and the `issue_discussions` join; the prompt quotes the issue, not a post |
| `DLY` | a time and the workspace's time zone on the time-trigger tick |

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
- **Time fire**: a fire of `every_hour` or `every_n_minutes`, with no
  trigger post.
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
   characters) and the six checkboxes of 1.2 (answer 3 B), with a number
   field for n (5..1440) next to "each n minutes". At least one must be
   checked. Under "after each agent reply" the form says what Q10 decides
   (whether the agent's own answers fire the loop again).
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
`event` is one of the six trigger keys of 1.2 plus the post (none for a time
fire). The hooks:

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
4. **`before_human_reply`** **[Q11]**: under Q11 A, the hook of step 2 when
   the agent reply's `to` is the loop's author. Under B, a new WUI frame
   (row L3b, not in v0.3). Under C, the box is not offered.
5. **`every_hour`, `every_n_minutes`**: a hub ticker,
   `runTopicLoopTimer`, every 60 s, the pattern of the calendar sync
   (`runGcalSync`, `internal/hub/gcal_sync.go:79-98`, `gcalSyncEvery` 60 s,
   `:44`). Each tick claims due loops with one `UPDATE ... WHERE next_due_at
   <= now() ... RETURNING` (`ClaimDueTopicLoops`, 7.1.1), which also moves
   `next_due_at` on, so two hub instances never fire the same tick. A tick
   missed while no instance ran fires once at the next tick: no catch-up
   burst. A time fire's prompt quotes the topic's latest post, or says "no
   new post since the last fire".
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
   - under Q10 A, the post is not the awaited answer to this loop's last
     fire (4.4);
   - the topic is not archived (`messages.archived_at`) and not paused (the
     store's `AnyTopicPaused`,
     `csi-spl-api/src/go/spool-hub-api/internal/store/topic_pause.go:74`,
     landed with spec 179 B1);
   - the loop's author is still a member and the archive policy still lets
     them edit loops (answer 5 A);
   - the loop's cap is not reached: under 12 fires in its current hour
     (answer 4 B).

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
   its id (`internal/hub/blocker_issue.go:481`).
4. The box gets it as any `@agent` post (section 3, step 7): inbox plus pane
   poke. The desk needs no change.

### 4.4 Reply

1. The agent answers in the topic as usual, to the author or to `ALL-0`.
   That answer is an ordinary, visible reply (Q9 A).
2. That answer is an agent reply. **[Q10]** Under A, the fire set
   `awaiting = <agent>` and `awaiting_until = fire + 30 min`; the agent's
   next agent reply in the topic before then clears it and does not fire
   this loop. It fires every other loop as usual. Under B, it fires this
   loop too, until the cap (1.4). Under C, the agent posts only when the
   prompt asks.

### 4.5 Stop

- **By a person**: Pause or Delete in the dialog (4.1). A paused loop keeps
  its prompt and fires nothing until Resume.
- **By the cap** (answer 4 B): after 12 fires in the loop's hour, it holds;
  it fires again when the hour rolls over. The dialog shows "held until
  hh:mm". No note is written (answer 7 C).
- **By the topic**: archiving the topic deletes its loops. A topic pause
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
| set | The owner opens **Discussion loops…**, adds a loop with the prompt "Export this whole discussion as a PDF and mail it to me." and checks `before_human_reply` (Q11 A: an agent reply addressed to the author) or `after_agent_reply` (every agent reply) | rows L1-L3 |
| trigger | An agent replies to HUM-10 in the topic; the hub stores it (`ws.go:702`) and fires the loop | rows L1-L2 |
| send | The topic's agent gets the loop prompt in its inbox, the agent reply quoted (4.3); nobody sees the prompt in the topic (5.2) | rows L1-L2 |
| export | The agent makes a PDF of the whole topic | **missing**, (a) below, row L6 |
| mail | The agent mails the PDF to HUM-10 | **missing**, (b) below, row L7 |
| answer | The agent replies "PDF sent" in the topic (Q9 A) | built |
| stop | That reply fires the loop again unless Q10 is A: up to 12 mails in a burst | (c) below |

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
  the hour rolls over. With `before_human_reply` under Q11 A, the same
  holds when the agent addresses "PDF sent" to the owner. The spec's answer
  is Q10 A (1.4): the agent's answer to a loop prompt never fires that loop.
  It needs the owner because it changes answer 4 B.

The two missing pieces become rows L6 and L7 (section 7). L7 sends to the
loop's author only: the hub checks that the request names a loop prompt
message of that topic whose loop belongs to the person mailed, so an agent
can mail a person only because that person's loop asked it to.

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
    triggers      text[]      NOT NULL CHECK (triggers <@ ARRAY['after_agent_reply','before_agent_reply','after_human_reply','before_human_reply','every_hour','every_n_minutes'] AND cardinality(triggers) >= 1),
    interval_min  integer     CHECK (interval_min BETWEEN 5 AND 1440),
    next_due_at   timestamptz,
    set_by        text        NOT NULL CHECK (set_by <> '' AND length(set_by) <= 64),
    set_at        timestamptz NOT NULL,
    state         text        NOT NULL DEFAULT 'on' CHECK (state IN ('on','paused')),
    hour_start    timestamptz,
    fires_in_hour integer     NOT NULL DEFAULT 0,
    fires_total   integer     NOT NULL DEFAULT 0,
    last_fired_at timestamptz,
    awaiting      text        NOT NULL DEFAULT '' CHECK (length(awaiting) <= 64),
    awaiting_until timestamptz,
    PRIMARY KEY (tenant_id, loop_id),
    CHECK ((interval_min IS NOT NULL) = ('every_n_minutes' = ANY (triggers)))
);
CREATE INDEX IF NOT EXISTS topic_loops_task ON topic_loops (tenant_id, task_id);
CREATE INDEX IF NOT EXISTS topic_loops_due ON topic_loops (next_due_at) WHERE next_due_at IS NOT NULL AND state = 'on';
```

- `interval_min` is set exactly when `every_n_minutes` is checked.
  `next_due_at` is set when a time trigger is checked (`set_at` + the
  shorter of 60 min and `interval_min`), moved on by every time fire, and
  NULL otherwise or while paused.
- `awaiting` and `awaiting_until` serve Q10 A (4.4); under B or C they stay
  empty. They exist either way, so L1 does not wait for Q10.
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
| trigger hooks | `wuiAfterStore` (`wui.go:647`), `onSend` after store (`ws.go:702-716`) | `topicLoopFire` and its two calls |
| send | `topicAgents` (`topic_reply.go:52`), `dispatchEnvelope` (`dispatch.go:228`), `commitRowTyped` (`ws.go:1037`) | the body, the UUIDv5 id, `loop_id` on the row |
| hidden prompt | the `note_to_self` precedent (rdb `0278`) | the six places of 5.2 |
| box and desk | `recv` -> inbox + poke (`hubclient.go:612,988`) | nothing |
| pause, archive | `AnyTopicPaused` (`store/topic_pause.go:74`), `messages.archived_at` | the two checks in `topicLoopFire`; delete on archive |

## 7. Build order (rows a later lane can take)

| row | depends on | kind | scope | tests and red control |
|---|---|---|---|---|
| **L1 rdb + store** | — | `complex_coding` | `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_topic_loops.sql` (`topic_loops`, `messages.loop_id`, the topic-head functions); `internal/store/{topic_loop.go,topic_loop_postgres.go,topic_loop_memory.go,topic_loop_test.go}`; `view_postgres.go`, `view_topics_batch.go`, `fallback_postgres.go`, `fallback_memory.go`; `rls_test.go`; `internal/channelmove/catalogue.go` | `PRE_PUSH_TIER=full`: Postgres + Memory parity; the cap `UPDATE` never passes 12 under two concurrent fires and rolls over after an hour; a `loop_id` row is in no view, no topic head and no fallback read; RLS covers the table. Red control: drop `AND m.loop_id IS NULL` from the topic view statement, and the hidden-row test fails. |
| **L2 hub** | L1 (Q10, Q11: recommended answer behind one switch) | `complex_coding` | `internal/hub/{topic_loop.go,topic_loop_fire.go,topic_loop_test.go,topic_loop_fire_test.go}`; the hooks in `wui.go` (before and after the store) and `ws.go`; the `fanoutWUI` skip; the time ticker `runTopicLoopTimer` | Each of the six boxes fires on its event; `before_agent_reply`'s prompt reaches the box before the post; a time loop fires once per due tick across two hub instances and never catches up a burst; a post matching two boxes fires once; a replay does not; a loop prompt message does not; HUB-0 and pause notices do not; paused loops, paused and archived topics do not; the 13th fire in an hour does not; the policy table (`everyone`, `admins`, `starter`); no browser frame for a loop row; `TestRoundTripsPerRequest` shows no extra round trip on a tenant with no loop. Red control: remove the cap check, and the agent-reply self-fire test passes 12. |
| **L2b orc** | L1 | `simple_coding` | `spl-unanswered-sweep.func.sh`, `unanswered-sweep-classify.py`, `spl-take-auto.func.sh` and their tests | a loop row is never listed, re-sent or escalated, and never taken. Red control: drop the skip, and the sweep test lists the loop prompt as unanswered. |
| **L3 wui** | L2 | `simple_coding`, then `i18n` (agy has the last word on the locales) | `msg-menu.mjs`, `topic-menu.mjs`, `MessageMenu.vue`, `MessageCard.vue`, `TopicLoopsDialog.vue`, `spool-client*.mjs`, `i18n/locales/*.json` | `pnpm run typecheck`, `test:unit` (i18n parity, untranslated and raw-text gates, cleancode, a `topic-loops` unit test of the menu lock and the form's at-least-one-trigger rule). Red control: a raw string in the dialog, and `i18n-no-raw-text` fails. |
| **L4 e2e** | L3 | `tests` | `csi-spl-wui/tests/e2e/topic-loops.test.mjs` | `BASE_URL=<bundle> pnpm run test:e2e` on the mock: add a loop from the menu, edit it, pause it, delete it; a human post shows no loop prompt card in the topic. Red control: skip the emit, and the dialog never opens. |
| **L6 orc: topic PDF** | — | `simple_coding` | `csi-spl-orc/src/bash/run/spl-topic-pdf.func.sh` (`do_spl_topic_pdf`: `TOPIC_ID`, `ENV`, `OUT`), a script that renders the topic (its rows from `spool hub-tail --task <uuid> --with-channel`, its pictures from the files API) to HTML and prints it with headless Chrome; a `do_box_pkg_install` record for the Chrome it needs; its test | a fixture topic of 3 posts and 1 picture makes a PDF with 3 posts (`pdftotext` count) and the picture; a missing Chrome fails fast with the install command. Red control: drop the picture fetch, and the picture check fails. |
| **L7 api: mail a file to a loop's author** | L1, L2 | `secret` (it handles people's addresses; claude or grok, data rule) | `internal/mail/mail.go` (`Message.Attachments`, a MIME multipart body), a box route `mail_file` and the `spool mail-file --task <uuid> --cause <loop prompt msg_id> --file <path> [--subject ...]` verb (`cmd/spool/main.go`); the hub resolves the address of the loop's author, never the agent | the hub mails only when `--cause` is a loop prompt message of that task whose loop's author is the person mailed (else `403 not_allowed`); at most 12 mails per loop per hour; the address is in no log and no answer; the attachment arrives (`mail.Recorder`). Red control: drop the author check, and a test mailing another member passes. |
| **L5 docs** | L2, L3 | `specs_and_docs` | this spec's row status; `csi-spl-doc/doc/md/spool-cli-reference.md` only if a CLI verb is added | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` |

Q10 and Q11 are open (1.4) but change no schema or contract: L1, L2, L2b,
L3 and L6 can run in parallel against the contracts of 7.1. L7 waits for
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
	LoopBeforeHumanReply      = "before_human_reply"
	LoopEveryHour             = "every_hour"
	LoopEveryNMinutes         = "every_n_minutes"
	TopicLoopIntervalMin      = 5    // minutes
	TopicLoopIntervalMax      = 1440 // minutes
	TopicLoopOn               = "on"
	TopicLoopPaused           = "paused"
	TopicLoopPromptMax        = 4000 // characters, rdb CHECK
)

// ErrBadTopicLoop: an empty or too long prompt, no trigger, an unknown
// trigger or state, a missing or stray interval, or a set_by not 1..64
// characters. Before any write.
var ErrBadTopicLoop = errors.New("store: a topic loop needs a prompt (1..4000 characters), 1..6 known triggers, an interval of 5..1440 minutes exactly with every_n_minutes, state on|paused and who (1..64)")

type TopicLoop struct {
	TenantID    string
	LoopID      string    // uuid, lower case
	TaskID      string    // uuid, lower case
	Prompt      string
	Triggers    []string  // distinct, sorted
	SetBy       string    // HUM-n
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
}

// TopicLoopEdit: nil / empty fields are kept. A changed Prompt or Triggers
// resets HourStart and FiresInHour. By becomes SetBy and At SetAt (4.5).
type TopicLoopEdit struct {
	Prompt   *string
	Triggers []string // nil: keep
	Interval *int     // nil: keep
	State    *string
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
	// limit on loops whose NextDueAt <= at, every workspace, NextDueAt moved
	// on in the same statement; the rows as claimed.
	ClaimDueTopicLoops(ctx context.Context, at time.Time, limit int) ([]TopicLoop, error)
	// SetTopicLoopAwaiting writes Awaiting / AwaitUntil (Q10 A); "" clears.
	SetTopicLoopAwaiting(ctx context.Context, tenant, loopID, agent string, until time.Time) error
	// TenantHasTopicLoops refreshes the hub's in-memory bit (4.2 step 6).
	TenantHasTopicLoops(ctx context.Context, tenant string) (bool, error)
}
```

`store.Message` gains `LoopID string` (`""` = NULL), written by
`InsertMessage` and `InsertMessageSent` to `messages.loop_id`.

The fired message's id (4.3 step 3) is
`uid.FromSeed("topic-loop:" + loopID + ":" + triggerMsgID)`
(`internal/uid/uid.go:21`), so the UUID is minted where `cleancode_test.go`'s
folded list wants it.

#### 7.1.2 HTTP and WS (L2 serves them, L3 calls them)

The loop JSON, every route's answer:

```json
{
  "loop_id": "<uuid>", "task_id": "<uuid>", "prompt": "<text>",
  "triggers": ["after_agent_reply", "every_n_minutes"], "interval_min": 30,
  "next_due_at": "2026-11-20T10:00:00Z",
  "state": "on", "set_by": "HUM-10", "set_at": "2026-11-20T09:30:00Z",
  "fires_in_hour": 3, "held_until": "2026-11-20T10:12:00Z",
  "idle": ""
}
```

- `triggers`: any of the six keys of 1.2. `interval_min`: present exactly
  when `every_n_minutes` is in `triggers`. `next_due_at`: present when a
  time trigger is on.
- `held_until`: `hour_start + 1h` when `fires_in_hour >= cap`, else omitted.
- `idle`: `""`, `"author_left"` or `"author_no_right"` (4.5): why an `on`
  loop would not fire.

| route | body | answer | refusals |
|---|---|---|---|
| `GET /v1/topics/{task_id}/loops` | — | `200 {"task_id": "<uuid>", "may_edit": true, "loops": [<loop>...]}` | `404 not_found` (the topic's read door) |
| `POST /v1/topics/{task_id}/loops` | `{"prompt": "...", "triggers": [...], "interval_min": n}` (`interval_min` only with `every_n_minutes`) | `201 <loop>` | `400 bad_loop`, `403 not_allowed`, `403 demo_read_only`, `404 not_found`, `409 topic_archived` |
| `PUT /v1/topics/{task_id}/loops/{loop_id}` | any of `{"prompt", "triggers", "interval_min", "state"}` | `200 <loop>` | as POST, and `404 not_found` for no such loop |
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
- The six triggers of msg `d44af000` replace v0.2's three (1.2, 4.1, 4.2,
  5.1, 7.1); time triggers run on a hub ticker; "only another human's post"
  is dropped.
- Open: Q10 (self-fire, answer 4 B) and Q11 (what "before each human reply"
  means), one form (1.4). Suggested extra triggers, one form (1.5, msg
  `ad30fe25`).
- New 4.6, the worked example of msg `92050cbc`, with the measured gaps:
  no agent-made topic PDF (row L6), no way to mail a file (row L7), and the
  self-fire it would cause (Q10).

<!-- version: 0.3 · updated: 2026-11-20 · last-edit: 2026-11-20T10:00:00Z -->
