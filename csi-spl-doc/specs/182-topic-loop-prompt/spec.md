# Spec 182: Topic Loop Prompt

Status: **Draft v0.1** (2026-11-20). Lane `c-301` (`claude`, backup for
`specs_and_docs`: no agy cli on this box).
Epic: **SPL-2398**. Issue: **SPL-6022**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:f08c0c58-9228-4e2a-af00-dbbdbd328083` (`t1`).
Builds on: [179 pause the agents of a discussion](../179-pause-agents-of-a-discussion/spec.md)
(per-topic hub state, the topic menu entry, who may act on a topic),
[150 topic-list priority](../150-topic-list-priority/spec.md) (the
`topic_priorities` table shape) and [099 topic head](../099-topic-head/spec.md)
(per-topic state lives in its own table, not in `messages`).

Line references were measured on `origin/master` `af8ca0ba7`. The next-free
check (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -3`)
gave `180-outlook-calendar-import`, `181-buy-private-workspace-vm` and
`README.md` on `9bd36fa53`, so 182 was free.

## 0. The owner's words (HUM-10, t1 #spool-hub-devel, topic f08c0c58)

- 08:32:11Z, msg `a0c4e227`: "loops for each agent reply or human reply in a
  discussion - add the functionality on each msg card to set from the right
  click menu on the topic level"
- 08:34:14Z, msg `b20e28e9` ("Chat about this" on poll `8044eaec`): "when the
  user clicks on the right click menu on the topic level and chooses the setup
  loop prompt it should be possible to setup a txt prompt for discussion ,
  which will execute on either agent reply or human prompt or another human
  prompt"

The dispatch holder read this back in msg `d985ec61`: the topic's right-click
menu gets **Set up loop prompt**, a text prompt is saved on that discussion,
it runs on each agent reply, on each human post, or only on another human's
post (the user picks), and the same menu shows the loop and turns it off.

Nothing named "loop" exists in the WUI menus or the hub's browser send path
today:
`git grep -n -i "loop" origin/master -- csi-spl-wui/src/utils/msg-menu.mjs csi-spl-wui/src/utils/topic-menu.mjs csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go | wc -l`
-> 0.

## 1. Open questions for the owner (forms)

The holder can post this block as one form, as it is. The first option of
each question is the recommended one. Every part of this spec that depends on
an answer is marked **[Qn]**.

```poll
Q1. Which agent gets the loop prompt when it fires?
(A) The topic's agent: the agent that last wrote in the topic
(B) One agent picked in the setup form
(C) Every agent that wrote in the topic
Q2. What does "the prompt runs" mean?
(A) A new message to that agent in the topic: the prompt, with the post that fired it quoted
(B) The same message, but the agent answers only to the loop's author, not in the topic
(C) No new message: the prompt is added under the post that fired it
Q3. Which triggers can a loop have?
(A) One per loop: any agent reply, any human post, or only another human's post
(B) Any mix of the three, as checkboxes
Q4. How is a loop kept from firing on itself forever?
(A) The agent's answer to a loop prompt never fires it, and a cap of 12 fires per hour stops it
(B) Only the cap of 12 fires per hour
(C) It stops after 20 fires; its author turns it on again
Q5. Who may set up, change or stop a loop?
(A) Whoever the workspace's "Who can archive topics" setting allows (as pause)
(B) The workspace owner and admins only
(C) Any member who can read the topic
Q6. How many loops can one topic have?
(A) One; setting a new one replaces it
(B) Several, each with its own prompt and trigger
Q7. How does a loop show?
(A) A Loop badge on the topic header (click to edit or stop), and each fired message marked Loop prompt
(B) Only the mark on each fired message
(C) Only the menu entry; nothing on the topic or the messages
Q8. Who is the sender of a fired loop prompt?
(A) The loop's author, marked as sent by the loop
(B) The hub (HUB-0), naming the author in the text
```

What each recommendation rests on:

- **Q1 A**: the hub already picks "the topic's agent" for a reply without an
  `@` in a channel-less topic (`topicReplyAgent`,
  `internal/hub/topic_reply.go:26`, newest first through `topicAgents`,
  `:52`). The same rule answers "which agent" without a picker.
- **Q2 A**: a new message to the agent is exactly the path an `@agent` post
  takes today (section 3). B adds a reply route the hub does not have; C
  changes a stored, signed message.
- **Q4 A**: the agent's own answer is the commonest self-trigger (trigger
  "any agent reply"); the cap stops what is left, such as two agents in one
  topic answering each other.
- **Q5 A**: the same policy check spec 179 section 3.1 uses for pause, with
  no new rule.
- **Q8 A**: an agent already answers a human's post. A HUB-0 note is a
  notice, and the hub hands only a `HUM-` post to the fallback responder
  (`internal/hub/fallback.go:237`).

## 2. Terms

- **Loop**: one saved row on a discussion: the prompt text, its trigger(s),
  its target agent rule **[Q1]**, its author, and its counters.
- **Fire**: the hub sends the loop prompt once, because of one stored post
  (the **trigger post**).
- **Agent reply**: a post an agent box sends into the discussion that a human
  reads there: to `ALL-0`, or to a `HUM-*` / `GST-*` id. Agent-to-agent
  sends on the same task id (`note`, `result`, `blocker`, `reject` to an
  agent id) are not replies. This is the same line spec 179 section 5.2 row 1
  draws.
- **Human post**: a post a signed-in member stores from the browser
  (`from_box = box-wui`, `from_id = HUM-*`), not a note to self.
- **Another human's post**: a human post whose `from_id` is not the loop's
  author.
- Never a trigger: a hub note (`HUB-0`, `PublicNoticeFrom`,
  `internal/hub/public_notice.go:23`), the pause and resume notices of spec
  179, and a message the loop itself sent.

## 3. How a post reaches an agent today (measured)

Paths under `internal/` are in `csi-spl-api/src/go/spool-hub-api/`.

| step | what happens | where |
|---|---|---|
| 1 | The browser sends a post over the WUI socket; `wuiSend` resolves the recipient. An agent `to`, or a leading `@AGENT`, makes it an agent dispatch. | `internal/hub/wui.go:571`, `wuiRecipient` `:887`, `dispatchAgent` `internal/hub/dispatch.go:51` |
| 2 | `wuiRoute` picks the agent's box (`dispatchCheckIn`). A channel-less reply to `ALL-0` goes to the topic's latest agent (`topicReplyAgent`). In a channel, the post fans out to member agents when `WUIDispatch` is on. | `wui.go:741`, `dispatch.go:134`, `topic_reply.go:26` |
| 3 | The envelope is signed as `box-wui` for the agent's box (`dispatchEnvelope`). | `dispatch.go:228` |
| 4 | `commitRow` stores the row, queues it for the box (`Store.Enqueue`) and fans it out to browsers. | `internal/hub/ws.go:1014`, `commitRowTyped` `:1037` |
| 5 | After the ack, `wuiAfterStore` runs the post's after-steps: the fallback responder and the hub notes, including the owner's prio word. This is the hook a human-post trigger joins. | `wui.go:640-654`, `ownerPrioWord` `internal/hub/owner_prio_word.go:97` |
| 6 | If no agent the post was meant for is online, the fallback hands it to one online agent. | `fallbackPost` `fallback.go:236` |
| 7 | The box's hub client takes the `recv` frame, writes the agent's inbox and rings its pane. | `internal/hubclient/hubclient.go:612`, `receive` `:988`; fallback poke `internal/hubclient/fallback.go:72` |
| 8 | The agent answers with `spool send` or `do_spl_desk_reply`. The hub's `onSend` checks it and stores it with `commitRowTyped`, then meters the turn. This is the hook an agent-reply trigger joins. | `ws.go:651`, store `:702`, `meterTurn` `:715` |
| 9 | On the desk, `do_spl_take_auto` gives a new human post in a topic to a dispatcher. The topic's owning agent is the first agent reply to `ALL-0` or `HUM-*`. | `csi-spl-orc/src/bash/run/spl-take-auto.func.sh:52`, `spl_take_auto_owner` `:160` |

## 4. The flow end to end

### 4.1 Set

1. On a topic card (the opening card in the channel feed, and the topic list
   row, which share one menu, `topicCardMenuOpts`,
   `csi-spl-wui/src/utils/topic-menu.mjs:76`), the right-click menu gets
   **Set up loop prompt…** (`id: 'loop-prompt'`). When the topic already has a
   loop, the entry reads **Loop prompt…** and opens the same form. It sits
   with the other topic-level entries in `msgMenuItems`
   (`csi-spl-wui/src/utils/msg-menu.mjs:85`). For a viewer who may not set
   one **[Q5]**, it shows disabled with the reason, through `locks`
   (`topicMenuLocks`, `topic-menu.mjs:38`; the `gated` helper,
   `msg-menu.mjs:94`), as Archive does (CLE-77891).
2. The entry opens `LoopPromptDialog.vue`, which holds:
   - the prompt: a textarea, at most 4000 characters;
   - the trigger(s): radios or checkboxes **[Q3]**;
   - the target agent **[Q1]**: no control for A; for B, a picker of the
     topic's agents; for C, no control;
   - Save, Stop loop (only when one exists) and Cancel.
3. Save calls `PUT /v1/topics/{task_id}/loop` with
   `{"prompt": "...", "triggers": ["agent_reply" | "human_post" | "other_human_post"], "agent": "<id>"}`.
   `agent` is sent only under Q1 B. The route has the shape of
   `PUT /v1/topics/{task_id}/priority`
   (`internal/hub/topic_priority.go:38`, handler `:52`, auth
   `priorityAllowed` `:176`). Under Q5 A, it checks `mayArchiveByPolicy`
   (`internal/hub/topic_archive.go:172`), as spec 179 section 3.1 does.
   Under Q6 A, a second PUT replaces the loop and resets its counters.
4. The hub stores the row (section 5), answers `200` with the loop, and sends
   one `topic_loop` frame to the topic's viewers. Under Q7 A it also writes
   one visible note: "Loop prompt set by @HUM-n: fires on <trigger>."

### 4.2 Trigger

1. **A human post**: in `wuiAfterStore` (`wui.go:647`), after
   `ownerPrioWord`, the hub calls `s.topicLoopFire(ctx, tenant, m, triggerHuman)`.
   `wuiAfterStore` runs only for an inserted row (`if r.inserted`,
   `wui.go:640`), so a replay never fires.
2. **An agent reply**: in `onSend` (`ws.go:702-716`), after `commitRowTyped`
   and only when `r.inserted` and the send is an agent reply (section 2),
   the hub calls `s.topicLoopFire(ctx, tenant, m, triggerAgent)`. It runs
   after the `sent` frame, so the agent box never waits on it.
3. `topicLoopFire` reads the topic's loop with one primary-key probe. With no
   row, nothing more happens. To keep the hot path to zero extra probes on a
   tenant with no loops, a per-tenant "has loops" bit is kept in memory and
   refreshed on every loop write. L2 measures this with
   `TestRoundTripsPerRequest` on `WS wui send` and on a box send.
4. It fires only when every check below holds. Any check that fails is
   logged once with its reason, and nothing is sent:
   - the trigger post's kind matches the loop's trigger(s) **[Q3]**;
   - the trigger post is not one the loop sent, and not the target agent's
     answer to the last fire **[Q4]** (section 4.4);
   - the topic is not archived (`messages.archived_at`) and not paused (the
     store's `AnyTopicPaused`,
     `csi-spl-api/src/go/spool-hub-api/internal/store/topic_pause.go:74`,
     landed with spec 179 B1);
   - the loop's author may still set it **[Q5]** and is still a member;
   - the hour cap is not reached **[Q4]**.

### 4.3 Send

1. Target **[Q1]**: under A, `topicAgents` (`topic_reply.go:52`) gives the
   newest agent that is announced now. Under B, it is the loop's stored
   agent. Under C, every agent `topicAgents` lists, one message each. With no
   announced agent, nothing is sent; the hub logs one line, and under Q7 A
   the badge shows "no agent".
2. The message **[Q2] [Q8]**: under Q2 A + Q8 A it is `kind: task`,
   `from: <author HUM-n>`, `to: <agent>`, `task_id: <topic>`, signed as
   `box-wui` with `dispatchEnvelope` (`dispatch.go:228`) for the agent's box,
   and stored with `commitRowTyped`, which queues it for the box and fans it
   out to browsers. The body:

   ```text
   Loop prompt (set by @HUM-n, fired by msg:<trigger uuid>)

   <prompt text>

   > <the trigger post, cut to 600 characters, one quote block>
   ```

3. Its `msg_id` is a UUIDv5 of `(loop id, trigger msg_id, agent)`. A second
   try for the same trigger is then a no-op insert, the same rule
   `postHubNote` uses for its id (`internal/hub/blocker_issue.go:481`).
4. The box gets it as any `@agent` post (section 3, step 7): inbox plus pane
   poke. The desk needs no change: the message is a human's task in a topic.

### 4.4 Reply

1. The agent answers in the topic as usual. That answer is an agent reply,
   so it would match trigger "any agent reply".
2. Under Q4 A, firing sets `awaiting = <agent>` on the loop. The next agent
   reply in the topic from that agent clears `awaiting` and does not fire.
   Any other agent's reply, and any human post, is judged normally.
3. Under Q2 B, the answer goes to the author only. That needs a route the hub
   does not have: a topic-bound DM reply. It would be a gap of its own (row
   L2b).

### 4.5 Stop

- **By a person**: **Stop loop** in the dialog, or the badge **[Q7]**, calls
  `DELETE /v1/topics/{task_id}/loop` (same check as PUT; idempotent `200`).
  Under Q7 A the hub writes the note "Loop prompt stopped by @HUM-n."
- **By the cap** **[Q4]**: under A or B, after 12 fires in the rolling hour,
  the loop stays saved but marked `held`. It fires again when the hour rolls
  over. Each hold writes one note. Under C, after 20 fires the loop is marked
  `stopped`, and only its author turns it on again.
- **By the topic**: archiving the topic deletes its loop. A pause keeps the
  loop but fires nothing (4.2 step 4), and resume needs no step.
- **By the author leaving** the workspace: the loop stops firing (4.2
  step 4), and the badge says why.

## 5. Store

New table in a forward-only migration: `<NNNN>_topic_loops.sql`, numbered by
`do_rdb_migration_next` at build time. The head is `0298` on `origin/master`.
The shape follows `0214_topic_priorities.sql` and `0297_topic_pauses.sql`:
`(tenant_id, task_id)` primary key, RLS, and the `change_stamp` trigger. If
Q6 is B, the key becomes `(tenant_id, loop_id)` with an index on
`(tenant_id, task_id)`.

```sql
CREATE TABLE IF NOT EXISTS topic_loops (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id       uuid        NOT NULL,
    loop_id       uuid        NOT NULL,
    prompt        text        NOT NULL CHECK (prompt <> '' AND length(prompt) <= 4000),
    triggers      text[]      NOT NULL CHECK (triggers <@ ARRAY['agent_reply','human_post','other_human_post'] AND cardinality(triggers) >= 1),
    agent         text        NOT NULL DEFAULT '' CHECK (length(agent) <= 64),
    set_by        text        NOT NULL CHECK (set_by <> '' AND length(set_by) <= 64),
    set_at        timestamptz NOT NULL,
    state         text        NOT NULL DEFAULT 'on' CHECK (state IN ('on','held','stopped')),
    awaiting      text        NOT NULL DEFAULT '' CHECK (length(awaiting) <= 64),
    hour_start    timestamptz,
    fires_in_hour integer     NOT NULL DEFAULT 0,
    fires_total   integer     NOT NULL DEFAULT 0,
    last_fired_at timestamptz,
    last_trigger  uuid,
    PRIMARY KEY (tenant_id, task_id)
);
```

- `agent` is used only under Q1 B. `state = 'stopped'` is used only under
  Q4 C.
- The fire updates the counters and `awaiting` in the same statement that
  checks the cap
  (`UPDATE ... WHERE fires_in_hour < 12 RETURNING ...`), so two hub instances
  never fire past the cap.
- The views carry the loop with zero extra round trips: `GET /v1/view/topics`
  carries a `loop` flag, and `GET /v1/view/topics/{task_id}` carries the
  whole row. Each is read as a `LEFT JOIN` in the statement that already
  reads `topic_priorities` and `topic_pauses` (spec 179 section 6.1 names
  the two statements).
- Channel move or copy (spec 169): the table is added to
  `internal/channelmove/catalogue.go` as `Moved`. The loop follows its topic.

## 6. What is reused, what is missing

| part | reused as it is | missing (built here) |
|---|---|---|
| menu entry | `msgMenuItems` + `gated` + `locks` (`msg-menu.mjs:85,94`), `topicMenuLocks` (`topic-menu.mjs:38`), the emit switch `choose` (`csi-spl-wui/src/components/MessageMenu.vue:158`), the card's menu mount (`MessageCard.vue:405`), the feed's `topic-menu` prop (`LiveFeed.vue:102`) | item `loop-prompt`, its lock reason, its emit, the card handler |
| permission | `mayArchiveTopic` (`csi-spl-wui/src/utils/topic-archive.mjs:74`) and `mayArchiveByPolicy` (`topic_archive.go:172`) **[Q5 A]** | nothing under A; under B or C, one new check in each |
| setup form | dialog patterns of `TopicDeleteDialog.vue`, `TopicExportPdf.vue` | `LoopPromptDialog.vue`, keys in the 19 locale files (`csi-spl-wui/i18n/locales/`) |
| badge | the open topic's header rows (`LiveTopicPane.vue:25-34`, `TopicPane.vue:33-34`) | `LoopBadge.vue` **[Q7]** |
| route | the `PUT /v1/topics/{task_id}/priority` shape (`topic_priority.go:38,52,176`) | `PUT` / `DELETE /v1/topics/{task_id}/loop`, the `topic_loop` frame |
| store | `TopicPauseStore` layout (`internal/store/topic_pause.go`), `0297` | `topic_loops` migration, `TopicLoopStore` (Postgres + Memory), RLS registration |
| trigger hooks | `wuiAfterStore` (`wui.go:647`), `onSend` after store (`ws.go:702-716`) | `topicLoopFire` and its two calls |
| send | `topicAgents` (`topic_reply.go:52`), `dispatchEnvelope` (`dispatch.go:228`), `commitRowTyped` (`ws.go:1037`) | building the body, the UUIDv5 id |
| box and desk | `recv` -> inbox + poke (`hubclient.go:612,988`) | nothing |
| pause, archive | `AnyTopicPaused` (`store/topic_pause.go:74`), `messages.archived_at` | the two checks in `topicLoopFire`; delete on archive |

## 7. Build order (rows a later lane can take)

| row | depends on | kind | scope | tests and red control |
|---|---|---|---|---|
| **L1 rdb + store** | Q6 (key shape), Q4 (cap columns) | `complex_coding` | `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_topic_loops.sql`; `internal/store/{topic_loop.go,topic_loop_postgres.go,topic_loop_memory.go,topic_loop_test.go}`; the view and door statements; `rls_test.go`; `internal/channelmove/catalogue.go` | `PRE_PUSH_TIER=full`: Postgres + Memory parity; the cap `UPDATE` never passes 12 under two concurrent fires; RLS covers the table. Red control: drop the `fires_in_hour < 12` guard, and the concurrent-fire test fails. |
| **L2 hub** | L1; Q1, Q2, Q3, Q4, Q5, Q8 | `complex_coding` | `internal/hub/{topic_loop.go,topic_loop_fire.go,topic_loop_test.go,topic_loop_fire_test.go}`; one call each in `wui.go` and `ws.go` | Each trigger fires once; a replayed `msg_id` does not; the agent's own answer does not **[Q4 A]**; HUB-0 and pause notices never fire; paused and archived topics never fire; the policy table **[Q5]**; `TestRoundTripsPerRequest` shows no extra round trip on a tenant with no loop. Red control: remove the `awaiting` check, and the self-fire test loops to the cap. |
| L2b hub, only under Q2 B | L2 | `complex_coding` | a topic-bound reply-to-author route | its own tests |
| **L3 wui** | L2; Q3, Q5, Q7 | `simple_coding`, then `i18n` (agy has the last word on the locales) | `msg-menu.mjs`, `topic-menu.mjs`, `MessageMenu.vue`, `MessageCard.vue`, `LoopPromptDialog.vue`, `LoopBadge.vue`, `spool-client*.mjs`, `i18n/locales/*.json` | `pnpm run typecheck`, `test:unit` (i18n parity, untranslated and raw-text gates, cleancode, a `loop-menu` unit test). Red control: a raw string in the dialog, and `i18n-no-raw-text` fails. |
| **L4 e2e** | L3 | `tests` | `csi-spl-wui/tests/e2e/topic-loop-prompt.test.mjs` | `BASE_URL=<bundle> pnpm run test:e2e` on the mock: set from the menu, the badge shows, a human post makes a fired card, stop removes the badge. Red control: skip the emit, and the dialog never opens. |
| **L5 docs** | L2, L3 | `specs_and_docs` | `csi-spl-doc/doc/md/spool-cli-reference.md` (only if a CLI verb is added), this spec's row status | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` |

L1 can start before the answers only if Q6 and Q4 come back as recommended.
Every other row waits for the answers its "depends on" names.

<!-- version: 0.1 · updated: 2026-11-20 · last-edit: 2026-11-20T09:45:00Z -->
