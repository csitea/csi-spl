# Spec 182: Topic Loop Prompt (Discussion Loops)

Status: **Draft v0.2** (2026-11-20). Lane `c-301` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). v0.1 `bc0353485`; v0.2 folds the
owner's answers to form `2c1c3f5d` (msg `a198ae53`) and the two requirements
in msgs `eae9e64f` and `19acb8f9` (section 8).
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

Nothing named "loop" existed in the WUI menus or the hub's browser send path
at v0.1:
`git grep -n -i "loop" origin/master -- csi-spl-wui/src/utils/msg-menu.mjs csi-spl-wui/src/utils/topic-menu.mjs csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go | wc -l`
-> 0.

## 1. Decided, and the one open question

The owner's answers to form `2c1c3f5d` (msg `a198ae53`, 09:05:50Z), as this
spec applies them:

| Q | Answer | What it decides here |
|---|---|---|
| Q1 | **A** — the topic's agent: the agent that last wrote in the topic | 4.3 step 1 |
| Q2 | **A** — a new message to that agent in the topic, the prompt with the post that fired it quoted | 4.3 step 2; shown to nobody, see 1.1 |
| Q3 | **B** — any mix of the three triggers, as checkboxes | 4.1, 4.2, the `triggers` column |
| Q4 | **B** — only the cap of 12 fires per hour | 4.2, 4.5; see 1.2 |
| Q5 | **A** — whoever the workspace's "Who can archive topics" setting allows (as pause) | 4.1 step 1 and step 3 |
| Q6 | **B** — several loops per topic, each with its own prompt and trigger | section 5 key; the list dialog of 4.1 |
| Q7 | **C** — only the menu entry; nothing on the topic or the messages | 4.1; no badge, no notes |
| Q8 | **A** — the loop's author, marked as sent by the loop | 4.3 step 2; the mark is `messages.loop_id` |

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

What the owner's words leave open is whether the agent's **answer** is
shown. v0.2 shows it as an ordinary reply: without it, a loop has no
visible effect. That is the one open question, Q9 below.

### 1.2 What answer 4 B means in use

With trigger "any agent reply" checked, the agent's answer to a fired prompt
is itself an agent reply, so it fires the loop again. Under 4 B only the cap
stops that: such a loop fires up to 12 times in an hour, then holds until
the hour rolls over (4.5). With several loops in one topic, the answer to
loop X can fire loop Y; each loop has its own cap. The form for a loop says
so next to the "any agent reply" box.

### 1.3 The one open question (form)

```poll
Q9. A loop prompt runs in the background. Is the agent's answer to it shown in the topic?
(A) Yes, as an ordinary reply in the topic
(B) No; the agent only acts, and posts in the topic only if the prompt tells it to
```

**[Q9]** marks every part that depends on it. A recommended: the loop then
works on every agent with no prompt wording needed, and the owner sees what
each loop did. Under B the hub tells the agent in the prompt header to send
its answer only when the prompt asks for a post, and nothing else changes in
the hub.

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
- **Another human's post**: a human post whose `from_id` is not the loop's
  author.
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
   characters) and three checkboxes (answer 3 B): any agent reply, any human
   post, only another human's post. At least one must be checked. Under
   "any agent reply" the form says that the agent's own answers then fire
   the loop too, up to 12 times an hour (1.2).
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

1. **A human post**: in `wuiAfterStore` (`wui.go:647`), after
   `ownerPrioWord`, the hub calls `s.topicLoopFire(ctx, tenant, m, triggerHuman)`.
   `wuiAfterStore` runs only for an inserted row (`if r.inserted`,
   `wui.go:640`), so a replay never fires.
2. **An agent reply**: in `onSend` (`ws.go:702-716`), after `commitRowTyped`
   and only when `r.inserted` and the send is an agent reply (section 2),
   the hub calls `s.topicLoopFire(ctx, tenant, m, triggerAgent)`. It runs
   after the `sent` frame, so the agent box never waits on it.
3. `topicLoopFire` reads the topic's `on` loops with one index probe
   (`(tenant_id, task_id)`). To keep a tenant with no loops at zero extra
   probes, a per-tenant "has loops" bit is kept in memory and refreshed on
   every loop write. L2 measures it with `TestRoundTripsPerRequest` on
   `WS wui send` and on a box send.
4. A loop fires when every check holds; a failed check is logged once with
   its reason and sends nothing:
   - one of its checked triggers matches the post (a post that matches two
     checked boxes, such as another human's post with both human boxes
     checked, fires once);
   - the post is not a loop prompt message;
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

   The first line is the mark of answer 8 A, for the agent. Under Q9 B it
   adds: "Answer in the topic only if the prompt asks for a post."
3. Its `msg_id` is a UUIDv5 of `(loop_id, trigger msg_id)`. A second try for
   the same trigger is then a no-op insert, the rule `postHubNote` uses for
   its id (`internal/hub/blocker_issue.go:481`).
4. The box gets it as any `@agent` post (section 3, step 7): inbox plus pane
   poke. The desk needs no change.

### 4.4 Reply

1. The agent answers in the topic as usual, to the author or to `ALL-0`
   **[Q9]**. Under Q9 A that answer is an ordinary, visible reply.
2. That answer is an agent reply, so it fires every loop of the topic with
   "any agent reply" checked, the one it answers included, until each
   loop's cap (1.2).

### 4.5 Stop

- **By a person**: Pause or Delete in the dialog (4.1). A paused loop keeps
  its prompt and fires nothing until Resume.
- **By the cap** (answer 4 B): after 12 fires in the loop's hour, it holds;
  it fires again when the hour rolls over. The dialog shows "held until
  hh:mm". No note is written (answer 7 C).
- **By the topic**: archiving the topic deletes its loops. A topic pause
  (spec 179) keeps them and fires nothing; resume needs no step.
- **By the author leaving** the workspace, or losing the archive right: the
  loop fires nothing (4.2 step 4); the dialog says why, and anyone allowed
  may delete it or take it over by editing it (the editor becomes its
  author).

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
    triggers      text[]      NOT NULL CHECK (triggers <@ ARRAY['agent_reply','human_post','other_human_post'] AND cardinality(triggers) >= 1),
    set_by        text        NOT NULL CHECK (set_by <> '' AND length(set_by) <= 64),
    set_at        timestamptz NOT NULL,
    state         text        NOT NULL DEFAULT 'on' CHECK (state IN ('on','paused')),
    hour_start    timestamptz,
    fires_in_hour integer     NOT NULL DEFAULT 0,
    fires_total   integer     NOT NULL DEFAULT 0,
    last_fired_at timestamptz,
    PRIMARY KEY (tenant_id, loop_id)
);
CREATE INDEX IF NOT EXISTS topic_loops_task ON topic_loops (tenant_id, task_id);
```

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
| **L2 hub** | L1 | `complex_coding` | `internal/hub/{topic_loop.go,topic_loop_fire.go,topic_loop_test.go,topic_loop_fire_test.go}`; one call each in `wui.go` and `ws.go`; the `fanoutWUI` skip | Each trigger box fires; a post matching two boxes fires once; a replay does not; a loop prompt message does not; HUB-0 and pause notices do not; paused loops, paused and archived topics do not; the 13th fire in an hour does not; the policy table (`everyone`, `admins`, `starter`); no browser frame for a loop row; `TestRoundTripsPerRequest` shows no extra round trip on a tenant with no loop. Red control: remove the cap check, and the agent-reply self-fire test passes 12. |
| **L2b orc** | L1 | `simple_coding` | `spl-unanswered-sweep.func.sh`, `unanswered-sweep-classify.py`, `spl-take-auto.func.sh` and their tests | a loop row is never listed, re-sent or escalated, and never taken. Red control: drop the skip, and the sweep test lists the loop prompt as unanswered. |
| **L3 wui** | L2 | `simple_coding`, then `i18n` (agy has the last word on the locales) | `msg-menu.mjs`, `topic-menu.mjs`, `MessageMenu.vue`, `MessageCard.vue`, `TopicLoopsDialog.vue`, `spool-client*.mjs`, `i18n/locales/*.json` | `pnpm run typecheck`, `test:unit` (i18n parity, untranslated and raw-text gates, cleancode, a `topic-loops` unit test of the menu lock and the form's at-least-one-trigger rule). Red control: a raw string in the dialog, and `i18n-no-raw-text` fails. |
| **L4 e2e** | L3 | `tests` | `csi-spl-wui/tests/e2e/topic-loops.test.mjs` | `BASE_URL=<bundle> pnpm run test:e2e` on the mock: add a loop from the menu, edit it, pause it, delete it; a human post shows no loop prompt card in the topic. Red control: skip the emit, and the dialog never opens. |
| **L5 docs** | L2, L3 | `specs_and_docs` | this spec's row status; `csi-spl-doc/doc/md/spool-cli-reference.md` only if a CLI verb is added | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` |

Only Q9 is open, and it changes one line of the prompt header (4.3 step 2),
so L1 to L4 can start now.

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

<!-- version: 0.2 · updated: 2026-11-20 · last-edit: 2026-11-20T09:30:00Z -->
