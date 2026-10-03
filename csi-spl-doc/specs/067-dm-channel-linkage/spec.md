# 067: agent <-> person direct messages connect to the channel discussion

Status: **draft, owner questions open** (section 9). Spec only; no code,
workflow, gate or `CLAUDE.md` was touched. Draft 2026-10-03, c-120.
Related: [036 terminal mirror](../036-spool-terminal-mirror/) (the biggest
DM producer, section 2), [028 terminal delivery](../028-spool-terminal-delivery/),
[062 flow per-user counts](../062-flow-per-user-counts/) (`flow_events`).
The unread-count fix in the same owner topic is lane c-119's, not this spec's;
section 6.5 only says how this spec counts against c-119's definition.

## 1. What the owner asked (t1 #spool-hub-bugs, topic `77540e6f`, HUM-10, ~08:35Z, verbatim)

> "Also now there are too many kinds of unconnected direct messages between
> agents and persons. An agent should contact a person whenever it actually
> replies to it, either in a direct message or by tagging that person in a
> channel. The person must provide the answer in the channel. If the person
> provides the answer in the direct message, then it should be seen also in
> the channel."

Follow-up, same topic, verbatim:

> "Direct message is not a thing which has been part of a channel in which
> the agent has not tagged the person or has just replied. It's just a reply
> message for a long thread of messages where there have been many other
> clients, because if I read this from the direct messages, I completely lose
> the context. What is this message about? It just doesn't make sense."

**Reading.** Four rules, in the owner's order of pain:

1. **A reply in a channel thread stays in that thread.** It never appears in
   the person's direct messages (DMs). The person sees it in the channel and
   in Flow, with the thread around it.
2. **An agent contacts a person only when it actually replies to them**:
   a DM reply to the person's DM, or a channel reply that tags `@person`.
   Status lines, terminal echoes and "I'm on standby" are not contact.
3. **A DM about a channel topic carries that topic's id** (asks about it,
   answers about it, pokes about it).
4. **A person's answer given in such a DM is also seen in the channel**: the
   hub mirrors it into the topic as a thread reply, marked as from a DM.

## 2. What exists today (measured 2026-10-03)

How a DM is stored: a `messages` row with `channel IS NULL`; there is no DM
table and no DM channel kind
(`grep -n "channel IS NULL" csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go` -> line 220).
`task_id` is the DM's own thread. **No column links a DM to a channel topic**
(`grep -n "ADD COLUMN" csi-spl-rdb/src/sql/postgres/spool-hub/*.sql | grep -i messages` -> only
`is_parent`, `typed_by`, `edited_*`, `kind_set_*`, `archived_*`, `moved_from_*`, `has_files`).
The one link that exists is text: the mention-poke body
`<ID> needs you in <origin>/t/<task_id>: "…"` (`csi-spl-wui/src/utils/mention-poke.mjs:60-67`).

### 2.1 Agent -> person DMs, by kind, last 14 days

Run by c-001 on prd at 08:39Z (read-only `do_spl_db_query`, output kept in
`/var/tmp/c120-prd-queries-0839Z.txt`); dev by c-120 the same hour. "linked" =
the DM's `task_id` is also the `task_id` of some channel message. The SQL is
section 10, Q-A.

| # | kind (body shape) | who sends it | prd n | prd linked | dev n | dev linked |
|---|---|---|---|---|---|---|
| H | agent prose: final answers, status, "I'm on standby", brief echoes | the 036 terminal mirror, `spool-mirror.py post --event answer` (most), plus `do_spl_desk_reply`, ask / lease / rotate owner DMs | 7,596 | 235 | 6,845 | 5 |
| B | `[typed by <ID>] : 'SPOOL …'` | the 036 mirror, a peer agent's poke line typed into the pane (`spool-mirror.py:483`) | 4,209 | 38 | 3,276 | 0 |
| C | `[terminal] …` | the 036 mirror, a prompt typed in the pane (`spool-mirror.py:105`) | 320 | 0 | 320 | 0 |
| A | `[channel post from HUM-n, topic xxxxxxxx] …` | the 036 mirror echoing a CHANNEL post that the 028 notifier typed into the pane (`spool-notify.inc.sh:170`) | 209 | 7 | 1,801 | 0 |
| D | `<task-notification> …` | the 036 mirror, CLI-internal text | 157 | 0 | 163 | 0 |
| G | other `[…]` | mirror proofs | 3 | 0 | 2 | 0 |
| | **total** | | **12,494** | **280 (2 %)** | **12,407** | **5** |

Dev split by producer (n = 12,407 over 14 days): rows with `typed_by` set
(mirror only) 3,057; agent rows without it 9,350; "Seen:" 0; mention-poke DMs
from a person's browser 1.

So **at least four of the six kinds are the terminal mirror** (B, C, A, D),
and most of H is too. The mirror posts EVERY turn into the agent's DM with the
desk's human, whatever the turn was about: the DM topic is "the DM topic the
human last wrote in, else the one used before, else a new one"
(`spool-mirror.py:355-380`, `pick_topic`). A turn that answered a channel
thread is posted into that DM with no topic, no channel and no thread: the
owner's "if I read this from the direct messages, I completely lose the
context".

### 2.2 Channel replies addressed to one person (prd, 14 days, section 10 Q-B)

| from -> to | thread reply (`is_parent` 0) n |
|---|---|
| CLE-n -> HUM-n | 1,876 |
| GRK-n -> HUM-n | 217 |
| c-n -> HUM-n | 100 |
| RSP-n -> HUM-n | 81 |
| AGY-n -> HUM-n | 37 |

These are desk replies (`do_spl_desk_reply` sends `--to HUM --task <topic>`,
no `--channel`, `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh:120-121`) and
the responder's "Seen" (`spl-responder-run.func.sh:155-163`). They stay in the
channel when the topic has an opening card, but:

### 2.3 The path that turns a channel reply into a DM (the owner's follow-up)

`channelOf` gives a box send the channel of its task's **earliest
`is_parent = 1` row** only (`internal/hub/channels.go:69-80`,
`TopicChannel`). A channel topic whose opening card is missing (opened as a
reply, swept, moved) has no such row, so an untagged agent reply on that task
is stored with **`channel = NULL`: a DM**, sitting on the channel topic's
`task_id`. `boxLevel` already falls back to `TaskFirstChannel` for the level
(`channels.go:118-147`, prd t1 `e802196b`, 2026-09-29), `channelOf` does not.
That is exactly the "linked" column of 2.1: **280 prd DMs in 2 weeks share a
channel topic's id** (235 agent prose in 5 topics, 38 typed-by echoes, 7
channel-post echoes). Each shows in the person's DM list
(`listTopics({ dm: true })`, `csi-spl-wui/src/stores/channel.ts:186` ->
`channel IS NULL`) and counts as a Flow `dm`.

### 2.4 Flow events (prd, all retained rows, section 10 Q-C)

| kind | on a channel message | addressed (`to` = the person) | n |
|---|---|---|---|
| `dm` | no | yes | 1,590 |
| `reply` | yes | no | 203 |
| `mention` | yes | yes | 130 |

The 130 `mention` rows are channel replies whose `to` is the person: the hub
ranks `to` as a mention **with or without an @-tag**
(`internal/store/flow_postgres.go:32`).

### 2.5 The mention-poke DM

When a person @-tags someone in the WUI, the author's browser ALSO sends a
separate DM with a **new** `task_id` (`csi-spl-wui/src/composables/useMentionPoke.ts:78-83`).
The topic survives only as the `/t/<id>` link in the body. An agent that
answers that poke with `do_spl_desk_reply` answers into the poke DM, not the
channel topic, so the answer is cut off from the discussion it is about.
(prd count of poke DMs not measured; dev n = 1 in 14 days.)

## 3. The model

### 3.1 Rule 1: a channel thread reply is never a DM

- **Hub.** `channelOf` falls back to `TaskFirstChannel` like `boxLevel`: a
  message on a task that has ANY channel row is stored in that channel. Only
  a task with no channel row at all is a DM. (Fixes 2.3, the 280.)
- **Mirror.** The 036 mirror posts a turn into a DM only when the turn
  answered a DM. It records the trigger of the turn (the notifier already
  knows it: the typed line's task and whether it was a channel post) and:
  - turn triggered by a DM -> mirror the answer into THAT DM topic (today's
    behaviour, but keyed to the trigger, not "the last DM");
  - turn triggered by a channel post, a peer agent's poke, a task
    notification or the terminal -> **post nothing to the DM**. The agent's
    real reply reaches the channel by `do_spl_desk_reply` / `spool send`.
- **Mirror echoes stop.** Kinds A (channel-post echo), B (typed-by poke),
  C (`[terminal]` prompt) and D (task-notification) are not posted to a DM at
  all (they are the agent's own pane traffic, not contact with a person).
  Whether the terminal stays visible somewhere else is Q2.

### 3.2 Rule 2: an agent contacts a person only when replying

An agent writes to a person in exactly two ways:

| situation | how | stored as |
|---|---|---|
| the person DMed the agent | a DM reply on that DM's `task_id` | DM |
| anything about a channel topic (an answer, a question, a result) | a thread reply in that topic, **tagging `@person`** when it needs them | channel |

Every other agent -> person DM stops (section 4). In Flow, a channel reply
reaches a person as `mention` only when it tags them; an untagged reply whose
`to` is them counts as `reply` (they watch the thread) - Q4.

### 3.3 Rule 3: a DM about a topic carries the topic id

New nullable column `messages.ref_task_id uuid` (the channel topic this DM is
about). Set by:

- the mention-poke DM (`useMentionPoke.ts`): the topic it was raised in;
- an agent DM that asks the person about a topic (`spool send --ref <task>`,
  a new CLI / MCP flag);
- a DM reply on a DM thread whose root carries one (inherited, like
  `channelOf` inherits a channel).

The WUI shows a DM with `ref_task_id` under a one-line header "about
#channel / topic title", linked to the topic; the person never has to guess
"what is this message about".

### 3.4 Rule 4: the person's DM answer is seen in the channel

When a **person** sends a DM whose thread has `ref_task_id` = T (T in a
channel C), the hub, in the same transaction, inserts a copy:

- `channel` = C, `task_id` = T, `is_parent` 0, `from_id` = the person,
  `to_id` = the agent, same body and files;
- new column `messages.mirror_of uuid` = the DM's `msg_id` (the WUI renders
  "via DM" on it; Flow and unread treat it as a normal thread reply).

Only person -> agent DMs are mirrored (an agent's DM reply is mirrored only if
Q5 says so). The agent then answers in the channel (rule 2), so the
conversation continues where the owner wants it: "The person must provide the
answer in the channel".

## 4. What stops

| today (section 2) | after |
|---|---|
| H: mirror posts every agent turn into the desk DM | only answers to a DM-triggered turn, into that DM |
| A, B, C, D: mirror echoes into the DM | not posted to a DM (Q2: a non-notifying terminal view, or nothing) |
| an untagged agent reply on a card-less channel topic stored as a DM (280 / 14 d on prd) | stored in the channel |
| mention-poke DM to a PERSON (Flow already shows the @mention) | not sent (Q3); poke to an AGENT stays, with `ref_task_id` |
| agent's reply to a poke DM lands in the poke DM | lands in the `ref_task_id` topic, tagging the person |
| channel reply with `to` = person and no tag = Flow `mention` | Flow `reply` (Q4) |
| rotate ALERT / ask / lease-takeover owner DMs (`spl-rotate-lib.func.sh:709`, `spl-asks-tick.func.sh:254`, `spl-dispatch-lease.func.sh:790`) | unchanged: they ARE contact (a question or alert to the owner); they get `ref_task_id` when they are about a topic |

## 5. Not in scope

The unread arithmetic itself (c-119); spec 066; DM between two persons
(they are not the complaint, n = 7 on prd channels, 9 DMs on dev); the
desk sidecar's delivery INTO the pane (028); history: rows already stored stay
as they are (Q6).

## 6. Edge cases

1. **DM with no topic** (the person DMs an agent out of the blue): stays a
   plain DM both ways; no `ref_task_id`, nothing mirrored. Rule 1 only stops
   agent-initiated DMs that are not replies.
2. **A private channel the person cannot see**: the hub mirrors (3.4) only
   when the person is a member of C (`channel_humans`) and C is not archived,
   the same door as `flow_postgres.go:37-39`. Otherwise the DM stays a DM and
   the WUI header says "about a topic you cannot open" without the title. An
   agent never tags a person into a channel they cannot read: `do_spl_desk_reply`
   falls back to a DM with `ref_task_id`.
3. **Edit / delete of the DM answer**: an edit or archive of the DM row is
   applied to its `mirror_of` copy in the same transaction; the copy itself is
   not editable separately (the WUI edits the DM). Deleting the copy alone is
   an operator action and leaves the DM.
4. **Moved topic** (`moved_from_task`): `ref_task_id` follows the move like
   other rows of the task (the move action updates it).
5. **Duplicate echo**: a DM with `ref_task_id` posted by the agent is NOT
   mirrored back (only person -> agent, 3.4), so no loop; an agent
   reading its own mirrored copy in the channel ignores rows with `mirror_of`.
6. **Unread counting (c-119's definition)**: c-119 defines the Messages total
   as the sum of the listed DMs' unread (person<->person and agent->person),
   and the Topics total as the sum of per-topic unread. This spec only moves
   rows between the two: a reply that was wrongly a DM (2.3) now counts in its
   topic; a mirrored copy counts in its topic for the OTHER members and never
   for its author; the DM original counts for the agent (agents have no
   badge). No row counts in both totals for one person. L4 and L6 rebase onto
   c-119's commits and keep its "total == sum" tests green.

## 7. Risks

- The mirror (036) is how the owner watches agents from a phone. Cutting it
  out of DMs without a replacement (Q2) loses that view.
- `channelOf` change: a DM thread that later gets a channel row (a move)
  would make new replies channel replies. That is the intended reading of a
  moved topic; L2's test covers it.
- `ref_task_id` from the browser is untrusted: the hub keeps it only when the
  sender can read T (same door as edge case 2), else drops it.

## 8. Build lanes

Small lanes, ONE task each, disjoint files. Each runs
`lane-map.sh --check <its files>` first and takes the next free migration
number when it starts (0107 is the latest on `origin/master` today). Hub paths
under `csi-spl-api/src/go/spool-hub-api/`, WUI under `csi-spl-wui/`, orc under
`csi-spl-orc/src/bash/`. c-119 has `internal/hub/flow.go`,
`internal/store/flow.go` and `internal/store/flow_postgres.go` open: L6 waits
for c-119 to land.

| lane | one task | files (new unless "edit") | its test | after | must NOT touch |
|---|---|---|---|---|---|
| L1 hub inherit (rule 1, 2.3) | `channelOf` falls back to `TaskFirstChannel` | `internal/hub/channels.go` (edit) | `internal/hub/channels_test.go` (edit): untagged box reply on a card-less channel task -> stored in the channel, not NULL; a genuine DM stays NULL; a moved topic; POSTGRES `PRE_PUSH_TIER=full ./run -a do_check_pre_push` | - | flow files (c-119), WUI, orc |
| L2 mirror by trigger (rule 1) | the notifier records each typed line's trigger (task, DM or channel); the mirror posts an answer only for a DM trigger, into that DM; kinds A-D not posted | `features/spawn-agents/scripts/spool-mirror.py` (edit), `features/spawn-agents/lib/spool-notify.inc.sh` (edit, write the trigger file only) | `features/spawn-agents/tests/test-spool-mirror.sh`, `test-spool-notify.sh` (edit): channel-triggered turn posts nothing; DM-triggered posts into that DM; echo kinds dropped; `./run -a do_check_pre_push_lint` | Q2 | hub, WUI, `spl-desk-reply*` |
| L3 rdb + store | `messages.ref_task_id uuid NULL`, `messages.mirror_of uuid NULL` + index; store insert/read carries both (Postgres + memory) | `csi-spl-rdb/src/sql/postgres/spool-hub/01NN_dm_ref_task.sql`; `internal/store/postgres.go`, `internal/store/memory.go`, `internal/msg/` envelope field (edits) | store test on POSTGRES (insert/read round trip, RLS), the catalogue gate; migration applied dev + prd BEFORE L4 lands (DDL first) | - | flow files, WUI |
| L4 hub ref + DM->channel mirror (rules 3, 4) | accept `ref_task_id` (dropped if the sender cannot read T), inherit it on DM replies, mirror a person's DM answer into T in the same txn, edits / archives follow (edge 3) | `internal/hub/dm_ref.go`; one call each in `internal/hub/ws.go` and `internal/hub/wui.go` (edit) | `internal/hub/dm_ref_test.go`: mirror inserted with `mirror_of`, not for agent -> person, not for a channel the person cannot see, edit + archive propagate, no loop; POSTGRES | L3 | flow files, WUI, orc |
| L5 CLI / MCP + desk reply (rule 2) | `spool send --ref <task>` and MCP field; `do_spl_desk_reply` answering a DM with `ref_task_id` replies in T tagging the person (falls back to the DM, edge 2) | `cmd/spool/main.go`, `internal/mcp/mcp.go` (edits); `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh` (edit) | `cmd/spool` test for the flag; `csi-spl-orc/src/bash/tests/spl-desk-reply-ref.tst.sh` (new; no desk-reply test exists today): poke-DM reply lands in T with `@HUM-n`; `./run -a do_check_pre_push_lint` | L4 | WUI, `spool-mirror.py` |
| L6 Flow ranking (Q4) | a channel line's `to` ranks `mention` only when the body tags them, else `reply` | `internal/store/flow_postgres.go`, `internal/store/flow.go` (edits, line 32 / 179 twins) | `internal/store/flow_*_test.go` (edit): untagged `to` -> `reply`, tagged -> `mention`, memory = Postgres; c-119's total == sum tests stay green | c-119 landed, Q4 | WUI, orc |
| L7 WUI (rules 3, 4) | the poke frame carries `ref_task_id`; no poke DM to a person (Q3); DM header "about #c / topic" with link; "via DM" marker on `mirror_of` rows | `src/composables/useMentionPoke.ts`, `src/utils/mention-poke.mjs` (edits); the DM pane and message row components (edits, markers only); `i18n/locales/*.json` (two keys, all locales) | `tests/unit/mention-poke.test.mjs` (edit); `tests/e2e/` DM header + via-DM marker, phone and desktop; `pnpm run typecheck`; `BASE_URL=<bundle> pnpm run test:e2e` | L4 | `ChannelSidebar.vue` counts (c-119), hub, orc |
| L8 agent rule text | the one-line rule "DM a person only to reply to their DM; otherwise reply in the topic and tag them" where agents read posting rules | `csi-spl-doc/doc/help/how-to-post.md` (edit, one section) | `./run -a do_check_dist_hygiene` | L5 | code |

## 9. Owner questions (each with the proposed default)

1. **Q1** The four rules of section 1 as the model, rule 1 (a channel reply
   is never a DM) first? Default: **yes**.
2. **Q2** The terminal mirror (036) leaves the DM. Where does the terminal
   view go? Default: **a separate per-agent "Terminal" view on the agent's
   page that never notifies and never counts as unread**; the DM keeps only
   the agent's replies to the person's DMs. Alternative: drop the echoes
   (A-D) entirely, keep nothing.
3. **Q3** Stop the mention-poke DM to a PERSON (the @mention already reaches
   them in Flow and the channel), keep it for agents with the topic id?
   Default: **yes**.
4. **Q4** A channel reply addressed (`to`) to a person but not tagging them
   counts in their Flow as `reply`, not `mention`? Default: **yes** (the
   owner's rule: contact = DM reply or tag).
5. **Q5** Mirror into the channel only the PERSON's DM answers, not the
   agent's DM replies? Default: **yes** (the agent answers in the channel
   itself, rule 2).
6. **Q6** Rows already stored (the 280 prd DMs on channel topics, the mirror
   DMs) stay as they are? Default: **yes**, no history rewrite; optionally an
   operator action later to move the 280 into their channels.
7. **Q7** Start L1 (the 280 bug) and L2 (the mirror) now, before the
   other answers? Default: **yes**, they need only Q1 and Q2.

## 10. The measurement SQL (read-only, `ENV=<env> SQL="…" ./run -a do_spl_db_query`)

**Q-A** agent -> person DMs by kind, and whether the DM's topic id exists in a channel:

    with dm as (select m.*, exists(select 1 from messages c where coalesce(c.channel,'')<>'' and c.task_id=m.task_id) linked from messages m where coalesce(m.channel,'')='' and m.to_id like 'HUM-%' and m.from_id not like 'HUM-%' and m.ts > now()-interval '14 days') select case when body like '[channel post from %' then 'A channel-post echo' when body like '[typed by %' then 'B typed-by echo' when body like '[terminal]%' then 'C terminal echo' when body like '<task-notification>%' then 'D task-notification' when body like '[%' then 'G other bracket' else 'H agent prose' end fam, linked, count(*), count(distinct to_id) people, count(distinct from_id) agents, count(distinct task_id) topics from dm group by 1,2 order by 1

**Q-B** channel messages by sender -> recipient shape:

    select regexp_replace(from_id,'[0-9]+','N','g') f, regexp_replace(to_id,'[0-9]+','N','g') t, is_parent, count(*) from messages where coalesce(channel,'')<>'' and ts > now()-interval '14 days' group by 1,2,3 order by 4 desc limit 20

**Q-C** Flow events vs the message's channel:

    select f.kind, coalesce(m.channel,'')<>'' in_channel, m.to_id=f.member_id addressed, count(*) from flow_events f left join messages m on m.msg_id=f.msg_id group by 1,2,3 order by 4 desc
