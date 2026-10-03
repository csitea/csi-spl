# 068: orchestrator dispatchers (ODs) - four per box, each dispatches and orchestrates

Status: **v0.3, owner answers folded in (1.3); Q1..Q6 open** (section 9).
Spec only: no code, no `lease.conf`, cron, table or seat was touched by this
lane. Draft 2026-10-03, c-098; v0.2 folded in the owner posts `d077dd4e`,
`469e6391`, `b6dbd286`, `c1216b5e`; v0.3 the answers `9590b1d6`, `5dddc9e3`,
`66958941`, `f4d05ace` and the order `cddcbf7c` ("Write those specs down once
again and ask questions if it was not clear").
Related: [SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md)
(sections 1..4.4 are what this replaces), [060 role
rotation](../060-role-rotation/spec.md), [064 the fleet without the
PC](../064-fleet-without-the-pc/spec.md), [059 messaging
backbone](../059-messaging-backbone/spec.md) (the delivery commit, rdb 0100).

`<pc box>` stands for the PC's box tag (box tags are banned literals in this
tree, as in spec 064). Log lines quoted below carry it in place of the tag.

## 1. Why

### 1.1 What the owner asked (HUM-10, t1 topic `1068e306`, verbatim)

> msg `3dc783b8`, 11:59:41Z: "Let's completely change the architecture from
> the point of view of the orchestrator."

> msg `0d751b4b`, 12:00:17Z: "The new design will be such that there will not
> be a single point of failure of an orchestrator but there will be four
> dispatchers and each one of them will also be an orchestrator."

> msg `d077dd4e`, 12:12:11Z: "The design should be such that there is a cron
> on each 15th minute. There will be four orchestrator dispatchers. Each one of
> them should try every 5 seconds to query the database and check that there
> are no new messages. Because there are four of them, the reply should feel
> almost instant. They should run in a continuous loop to check for new
> messages and start working on those new messages."

> msg `469e6391`: "And there will be a cron which restarts them each hour so
> the first will be on the 0th minute, the second on the 15th minute, the
> third on the 30th minute, the fourth on the 45th minute."

> msg `b6dbd286`: "Remove the current cron scripts, which will mess with the
> whole thing, and just create new cron scripts so that each hour we will get
> a fresh instance. Each one of them should work in a loop of 5 seconds so
> every 5th second each one of them should check the database and there should
> be a locking mechanism. Whenever an orchestrator dispatcher gets some new
> messages, it will mark those messages as locked by him and it should take
> responsibility for dealing with them."

> msg `c1216b5e`: "The new database design should be such that there is a
> responsible agent attribute on each message reply or topic message. Involve
> the direct messages, the topics, and the channels everywhere."

(The last four were relayed to this lane by c-002@<pc box>, task `1068e306`,
spool msgs `31410b95`, `783a99af`, `e1a41397`, `940a02d0`.)

**Fixed by the owner, not options in this spec:** four ODs (1.3: per box); each polls the
database every 5 s in a continuous loop; a lock per message, "locked by him";
a responsible agent on every message (DMs, channels, topics, replies); a
fresh instance per peer every hour, staggered `:00`, `:15`, `:30`, `:45`; the
current crons that would interfere are removed and replaced.

### 1.2 What failed today (2026-10-03)

Measured on `sat` as the agent user, 2026-10-03 ~12:10Z, read-only, against
sat's `/var/spool-hub`; n = one machine's logs (this lane has no shell on the
PC). Fleet loop code on sat at the time: `cat /var/spool-hub/dispatch/fleet.ver`.

| # | failure | evidence | what a single role cost |
|---|---|---|---|
| F1 | the orch role went silent and nobody acted for 193 s | `grep -n '11:51:34Z' /var/spool-hub/dispatch/lease.log` -> `FLEET orch: sat takes over from c-001@<pc box> (silent 193s, rank 0 -> 1)` | every ask to "the orchestrator" waited for a lease to expire (180 s) plus a tick |
| F2 | the sat seats froze at the claude usage limit | `grep -c 'GATE SKIP stalled' /var/spool-hub/dispatch/rotate.log` -> 4 (06:05Z, 06:15Z, 07:05Z, 07:15Z, `Usage limit reached`, orch and master) | every sat role at once: all three seats share one login, so one quota froze all of them |
| F3 | re-raises went to the frozen holder | `ls /var/spool-hub/c-001/inbox \| grep asks-still-open \| grep -c '^20261003'` -> 57 (04h: 4, 05h: 28, 06h: 25); the 06:41:15Z one (`...-3091422a.json`) lists 8 asks "re-raised to c-001@sat" whose bodies say "owners lanes on sat are frozen at the usage limit until 07:50Z" | the ask book did its job and re-raised, but to the one seat that could not act |
| F4 | the fleet loop and the rotation gate disagreed about "able" | rotate.log calls the sat orch stalled at 06:05Z and 07:05Z; `awk '$1>="2026-10-03T06:24" && $1<"2026-10-03T07:22" && /FLEET orch: sat takes over/' lease.log \| wc -l` -> 48 | a seat that could not act still won the role, again and again |
| F5 | lease ping-pong from a half-applied rank flip | `awk '$1>="2026-10-03T04:09" && $1<"2026-10-03T07:22" && /takes over from/' lease.log \| wc -l` -> 203 take-overs (108 of them 04:09..05:26Z); it began 3 min after `04:06:09Z RANK orch sat,...` on sat and stopped 4 min after `07:18:35Z RANK orch <pc box>,sat,...` (c-001@<pc box> hand-over `fa14f741` on `1e48c889` names the cause) | one config line, applied on one machine, flipped the single orchestrator about once a minute for 3 h |
| F6 | asks re-raised for hours because one session's harness refused `do_spl_ask_close` | I believe, unchecked on this machine, the c-001 brief (asks-open blockers on sat). The same class of refusal is on record: `c-001/inbox/20261002T051614Z--CLE-001--asks-handover-...-49b6577a.json`, ask `b6273c3f`: "my session's permission layer refused to run it ("Interfere With Workloads")" | one harness's policy blocked the only seat allowed to act |
| F7 | the PC desk sidecar could not send 11:36..11:52:40Z | `/var/spool-hub/asks/bfd5c575-c599-418b-a7f1-60f4956575e1.json`: "prd t1 desk sidecar ... cannot send since 11:36Z", closed 11:53:42Z "reconnected 11:52:40Z" | the master dispatcher could not post for 16 min; nobody else was allowed to |

**The common cause.** Every item had exactly one allowed actor (the lease
holder), chosen per ROLE, and "able" was judged from a process and a pane,
not from progress. When that actor froze, stalled, or flapped, the work
waited. The fix is to choose the actor per ITEM, among the ODs, and to
let progress (or its absence) move the item.

### 1.3 The owner's answers to v0.2 (HUM-10, t1 `1068e306`, verbatim)

Relayed by c-002@<pc box>, spool msg `5d0dce90`, oldest first:

> `9590b1d6`, 12:31:14Z: "I need to correct 4 ODs (aka orchestrator
> dispatchers) on a box. Two should be Claude and two should be Grok."

> `5dddc9e3`, 12:32:07Z: "Yes the 001, 002, 003, and 004 will be special and
> reserved only for the ODs or the orchestrator dispatchers. Add this to the
> glossary of the application: - ODs - orchestrator dispatcher - agent"

> `66958941`, 12:32:40Z: "And yes the responsible for each message should be
> shown in the UI."

> `f4d05ace`, 12:33:08Z: "No, switch immediately to the new roles. First
> spawn all eight agents and start slowly shutting down the old other agents.
> Just pass them context."

> `cddcbf7c`, 12:33:23Z (spool msg `6e6fd399`): "Write those specs down once
> again and ask questions if it was not clear."

| v0.2 question | answer | what changed in this spec |
|---|---|---|
| Q1 seats per machine | **four ODs on EACH box**, eight in all (sat + the PC) | 3.1, 6.1, 7 |
| Q2 mixed harnesses | **yes: two claude + two grok per box** | 3.3 |
| Q3 ids | **001..004 reserved for the ODs only** (on every box, so an OD is `<id>@<box>`) | 3.2 |
| Q4 grok may spawn / run prd | not answered | Q5 below |
| Q5 responsible in the UI | **yes** | L8 is in scope, 4.1 |
| Q6 shadow run | **no: switch at once**; spawn all eight, then shut the old agents down slowly, passing them context | 8 |

The glossary entries (OD, orchestrator dispatcher, agent) are c-001's action
(c-002's note); 2 below holds the wording this spec uses.

## 2. Words

| word | means |
|---|---|
| **OD** (orchestrator dispatcher) | one of the four agent sessions on a box with id 001..004, each a dispatcher AND an orchestrator: it takes messages, routes them, decides, spawns and closes lanes. Eight in the fleet (four per box). Also called a **peer** in this spec and in code names (`do_spl_peer_*`) |
| **seat** | an OD's slot: id 001..004, its box, its harness. The session in it is replaced every hour; the seat stays |
| **agent** | any harness session with a spool id (`^[acgq]-[0-9]{3}$`, `<id>@<box>`): an OD (001..004) or a lane (005..999, one small task each) |
| **message** | a row of the hub table `messages` (rdb 0001): a DM (`channel` NULL), a channel post, a topic reply (`task_id` = the topic). One table already holds all three |
| **responsible agent** | the new `messages.responsible` column: the seat that must deal with that message. Set at insert when the message is addressed to one agent; set by a peer's claim when it is addressed to the peers (a human post, a report to `orchestrator`) |
| **lock** | `messages.locked_until` (hub clock) next to `responsible`. Renewed by the holder's loop; past it, any peer may take the message |
| **poll loop** | a shell loop per seat, NOT a model turn: every 5 s it asks the hub for unclaimed messages and locks them for its seat in the same statement |
| **fence** | `messages.responsible_gen`. A peer re-checks it immediately before an outward action (a post, a spawn, a prd call) |
| **mutex** | a short named lease in the existing `fleet_leases` table (`role` = `spawn`, `prd-<target>`, `fleet-config`), for the few shared resources that need ONE actor at a time |
| **able** | the existing check `spl_lease_agent_able` (process, pane stall, stuck-unread rule) |

## 3. Decision 1: the seats (decided by the owner, 1.3)

### 3.1 Four ODs per box

Owner: "4 ODs ... on a box", eight in all. Each box carries the whole job
alone: with the PC off (064's normal) sat's four ODs do everything, and with
both on, all eight share one pool of messages (4.1).

| box | OD seats |
|---|---|
| sat | 001, 002, 003, 004 |
| the PC (`<pc box>`) | 001, 002, 003, 004 |

Against the failures of 1.2: one dead OD leaves seven (three on its box); one
box gone leaves the other box's four; one login at its limit (F2) leaves the
two seats of the other harness on every box.

### 3.2 Ids

Owner: 001..004 are reserved for the ODs only, on every box (061 reserved
001..003 per box; 004 now leaves the rolling lane pool the same way, and
lanes allocate from 005). Because the same numbers run on both boxes, an OD
is always written `<id>@<box>`, and so is `messages.responsible`. A bare id
means this box's OD, as today (4.2 of fleet-roles, `ambiguous_to_box`).

The numbers are reserved on EVERY harness letter: no lane is ever `c-`,
`g-`, `a-` or `q-` 001..004. The letter is the harness
(`^[acgq]-[0-9]{3}$`); on each box the seats are `c-001`, `c-002` (claude) and
`g-003`, `g-004` (grok), e.g. `c-001@sat c-002@sat g-003@sat g-004@sat`. The
number is also the restart slot (6.1).

### 3.3 Harness and model

Owner: two claude + two grok per box. The mix is the defense against F2 (a
login at its limit froze every sat role at once) and F6 (one harness refusing
a step). A harness is fit for a seat when it passes the seat drill (lane L7):
`spool recv`, `spool claim`, `do_spl_post`, a spawn dry run. Grok is suspended
today and lane seeds say never to spawn grok (c-001, msgs `8896800b`,
`f2bf978c`): Q2 asks whether "two should be Grok" lifts that for the OD seats
only, and Q3 what runs in a grok seat while it stays suspended.

## 4. Decision 2: who does what without an orchestrator

### 4.1 Every 5 s, each peer locks new messages for itself in the database

The owner fixed the shape (1.1): poll every 5 s, lock what you take, take
responsibility. What this spec decides is where the lock lives and who runs
the loop.

| option | lock lives | loop run by |
|---|---|---|
| a. a separate claim table keyed by `msg_id` (the ask book, rdb 0097, generalised) | `fleet_claims` | - |
| **b. columns on `messages` itself (recommended; the owner's "responsible agent attribute on each message")** | `messages.responsible`, `locked_until`, `responsible_gen`, `claim_n`, `handled_at` | - |
| c. the agent polls in its own turns | - | the model: a turn every 5 s, 720 turns an hour per peer, and nothing while a turn is busy |
| **d. a shell loop per seat (recommended)** | - | `do_spl_peer_poll`, no model call; it hands what it locked to its agent's inbox and rings the pane |

**Recommendation: b + d.** One row per message already exists for DMs,
channels and topics alike, so the column covers "everywhere" with no second
table to keep in step, and the WUI can show who is responsible for every
message. The loop is shell because a model cannot poll every 5 s and still
work (option c).

**The columns** (one rdb migration, lane L1):

| column | type | set |
|---|---|---|
| `responsible` | text NULL, `<id>@<box>` | at insert for a message to one agent (= its `to_id@to_box`); by a claim for a message to the peers; NULL = nobody yet |
| `locked_until` | timestamptz NULL | by a claim and every renew: hub `now() + LOCK_TTL` |
| `responsible_gen` | bigint, default 0 | +1 on every claim (the fence) |
| `claim_n` | int, default 0 | +1 on every claim (the delivery count) |
| `handled_at`, `handled_how` | timestamptz NULL, text | by the close: `answered`, `handed:<lane>`, `no-reply:<reason>`, `dead` |
| `not_by` | text[] | harnesses that refused it (F6) |

Plus a partial index `WHERE needs_peer AND handled_at IS NULL`, where
`needs_peer` is true for a human post in a seated workspace and for a message
`to_id = 'peers'`. The poll reads only that index, so eight ODs polling
every 5 s is 0.8 indexed queries a second.

**The claim** is ONE statement on the hub (box frame `claim`, CLI `spool
claim --poll`):

```sql
UPDATE messages SET responsible = $seat, locked_until = now() + $ttl,
       responsible_gen = responsible_gen + 1, claim_n = claim_n + 1
 WHERE (tenant_id, msg_id) IN (
   SELECT tenant_id, msg_id FROM messages
    WHERE needs_peer AND handled_at IS NULL
      AND (responsible IS NULL OR locked_until < now())
      AND NOT ($harness = ANY (not_by))
    ORDER BY ts LIMIT $max FOR UPDATE SKIP LOCKED)
RETURNING tenant_id, msg_id, responsible_gen;
```

`SKIP LOCKED` makes two peers polling in the same millisecond take disjoint
messages: exactly one responsible per message, no waiting. The four loops
start at different seconds, so a new message waits on average about 1.25 s
and at most 5 s for an able peer (the owner's "almost instant").

**The loop** (`do_spl_peer_poll`, one per seat, started by the seat's own
restart, section 6), every `PEER_POLL_SEC` (5):

1. Is my agent able (`spl_lease_agent_able`) and has its transcript grown in
   the last `PEER_PROGRESS_MAX` (10 min) while it holds a message? No: do not
   claim, do not renew; its locks run out in `LOCK_TTL`.
2. Renew `locked_until` of every message my seat holds and has not closed.
3. Claim at most `PEER_MAX_HELD` (3) minus what I hold.
4. Write each claimed message into my agent's inbox (once, by `msg_id`) and
   ring the pane.

- **Close.** The agent closes with `spool claim --done <msg>` (`answered`,
  `handed:<lane>`, `no-reply:<reason>`). A close by a non-responsible seat is
  refused naming the responsible one.
- **Dead-letter.** At `CLAIM_MAX` (4) claims without a close, the message goes
  to the owner once and closes `dead`, the ask book's rule.
- **Harness refusal (F6).** A peer whose harness refuses a step releases the
  message `--reason harness-refused:<step>`; its harness goes into `not_by`,
  so the next claim comes from a different harness.
- **Reports to "the orchestrator"** (`--to orchestrator`) go to the hub as
  `to_id = 'peers'` and are claimed like a human post; a message from one lane
  to one lane gets `responsible = <addressee>` at insert, and nobody polls it.
- **The ask book** (rdb 0097) keeps its ask fields; its lock (`acked_by`, the
  lock timeout, re-raise to one holder) is replaced by the message's lock.

### 4.2 Two peers never both answer

| action | guard |
|---|---|
| a post visible to humans (an answer, an owner text, a status) | the reply carries `answers=<msg_id>`; the hub accepts it only from the message's `responsible` seat with the current `responsible_gen`, and only once (unique on `(tenant, answers)` for agent posts): a second answer is refused 409 naming the first |
| a forward to a lane | `--done handed:<lane>` is a CAS on `responsible_gen`; the forward is sent only after it wins |
| spawn, close a lane, a prd action | fence: re-check `responsible_gen` (and the mutex, section 5) immediately before the call. A peer that lost the message while it was thinking stops |

## 5. Decision 3: what still needs ONE decider

| item | needs one decider because | options |
|---|---|---|
| spawning / closing a lane | the 40-window ceiling is a count: two peers spawning at once overshoot it | a. the message lock only; **b. the message lock + mutex `spawn` (recommended)**; c. consensus |
| a prd action (a deploy the owner pre-approved, prd desk / issue writes) | two deploys of one target race | a; **b. lock + mutex `prd-<target>`**; c |
| an owner text (a lane asks "post this in topic X") | must appear once | **a. the lane's message is locked by one peer + the answer-once guard (4.2)** |
| a fleet config change (seats, crons) | F5: a half-applied config flapped the fleet for 3 h | **b. mutex `fleet-config` + one action that writes every machine or none** |

**Recommendation: the message lock decides WHO; a 120 s mutex decides WHEN,
and only for these shared resources.** The mutex is the existing
`fleet_leases` row and `lease cas` frame under a new `role` name: no new
primitive. A dead holder's mutex expires in 120 s.

Consensus (3 of 4 agree) is rejected: with the PC off (064's normal) only 4
ODs are on sat, and with two of them frozen (F2) no quorum of 3 is possible - the
exact case this spec exists for. Lock + mutex survives one dead peer and one
frozen machine: any one able peer takes every message.

## 6. Decision 4: crons, rotation and the lease under peers

### 6.1 The new crons (owner, 1.1)

| cron | where | does |
|---|---|---|
| `0,15,30,45 * * * *` `do_spl_peer_restart` (tag `# csi-spl:peer-restart`) | every box | seat N = `minute/15 + 1` (001 at `:00`, 002 at `:15`, 003 at `:30`, 004 at `:45`), on this box: stop its poll loop (its locks stay, `responsible` names the SEAT, not the session), write the 060 handoff file (060 section 6, minus its lease lines), `/exit-clean` the old session (kill after 5 min, 060 D4), start a fresh one under the same id with the handoff, start its poll loop. A fresh session that does not start in 5 min: alert (an owner DM) and start the old one's loop again (060 D2) |
| `* * * * *` `do_spl_peer_ensure` (tag `# csi-spl:peer-ensure`) | every machine | starts a missing poll loop of a local seat (the reboot path); nothing else |

At most one seat per box restarts at a time (two in the fleet, at the same
minute, unless Q6 offsets the PC), and its messages wait at most the restart
(a few minutes) or the lock, whichever is first: the other ODs keep polling
new messages meanwhile.

### 6.2 The crons removed (owner: "Remove the current cron scripts")

Measured on sat, as the box user: `crontab -l | grep -oE '# csi-spl:[a-z-]+' | sort | uniq -c` -> 9 tags.

| tag | fate | why |
|---|---|---|
| `orch-rotate` (`5 * * * *`) | **removed** | replaced by `peer-restart` |
| `dispatch-rotate` (`15 * * * *`) | **removed** | replaced by `peer-restart` |
| `unanswered-sweep` (`*/10`) | **removed** | an unanswered human message is exactly a row with `handled_at IS NULL`: the 5 s poll finds it; the sweep's skip rules (test workspaces, acks, human-to-human) become the `needs_peer` predicate |
| `desk-reconcile`, `desk-reconcile-prd` | **kept, cut down** | the desk sidecars still need it; its `do_spl_dispatch_lease LEASE_CMD=ensure` and `do_spl_dispatch_tick` steps are removed |
| `agent-boot-restore`, `agent-id-reap`, `agent-identity-reconcile`, `weekly-full-scan` | kept | they do not route or decide |

### 6.3 What stays and what goes

| piece | kept | removed |
|---|---|---|
| fleet lease roles `orch` and `dispatch` (fleet-roles 4.1) | the `fleet_leases` table and `lease cas` frame, for the mutexes | the two roles, `LEASE_ORCH` / `LEASE_MASTER` / `LEASE_FAILOVER`, the ranking (`LEASE_PRIORITY*`, `do_spl_lease_rank`), take-over and handback, the `lease` and `lease.orch` mirror files, the owner DM per take-over |
| renew / watch loops (4) | - | all: no master, no failover |
| the able check (4) and the stuck-unread rule (4.1 condition 2) | kept: the poll loop's step 1 | - |
| ask book (4.3) | the ask rows and their owner leg | the hand-over blocker, re-raise to one holder, `acked_by` as a lock |
| rotation (060) | the handoff file, the mechanical script, "keep the old session if the new one fails", the forced exit | the times `:05` / `:15` (now `:00/:15/:30/:45` per seat), the dispatcher HOLD choreography (060 5.2), `rotate.hold` |
| `--to orchestrator` | the word, as an alias | the lease lookup: it means `to_id = 'peers'` on the hub |

## 7. Decision 5: failure table

Max delay = from the failure until another peer is responsible, on the hub
clock. `PEER_POLL_SEC` 5, `LOCK_TTL` 120 s, `PEER_PROGRESS_MAX` 10 min.

| failure | what each peer does | max delay |
|---|---|---|
| none (a new message) | the first able peer to poll locks it | **5 s** (about 1.25 s on average with four staggered loops) |
| one peer dead (process gone) | its loop sees it not able and stops renewing; its locks run out; any other peer's next poll takes them | **125 s** |
| one peer stalled but alive (usage limit, modal screen, stuck) | the same, from the able check | **125 s** |
| a stall the able check misses (F4) | its transcript stops growing; after `PEER_PROGRESS_MAX` its loop stops renewing | **12 min** |
| the poll loop itself dead | nothing renews; the locks run out; `peer-ensure` restarts the loop within a minute | **125 s** |
| one box frozen or gone | nothing on it renews; the other box's four ODs take everything | **125 s** |
| one login at its limit fleet-wide (every claude seat, F2) | the two grok seats on each box carry everything; `not_by` routes harness refusals | **125 s** |
| the hourly restart of a seat | its messages keep their lock, renewed by nobody while it restarts; the fresh session takes them from the handoff, or they run out and move | **125 s** worst case; new messages unaffected |
| hub down | no poll, no web posts, no relays. Each machine falls back to a local lock, an `O_EXCL` create of `<spool root>/claims/<msg id>` among its own seats, for local-origin messages only (terminal reports). No cross-machine duplicate is possible: nothing crosses machines without the hub. On recovery each local lock is pushed as the message's `responsible`, insert-if-absent | local: **5 s**; web posts: until the hub is back (they cannot arrive) |
| split brain (one machine reaches the hub, the other does not) | the hub is the only arbiter, so there is one view. The cut-off machine cannot renew; its messages move after `LOCK_TTL`. Its peers may still think they hold them, but every outward action is fenced (4.2): a post, spawn or prd call re-checks `responsible_gen` on the hub, cannot, and stops | **125 s** |
| a peer's desk sidecar cannot send (F7) | the post fails; the peer releases the message `--reason send-failed`; a peer on the other machine takes it at its next poll | **5 s** after the release |
| a config change half-applied (F5) | cannot flap: there is no ranking left; config goes through the `fleet-config` mutex and one all-machines action | - |

## 8. Decision 6: migration in small, disjoint lanes

Today c-001 orchestrates and c-002 / c-003 dispatch on each box under the
fleet lease, with the 9 crons of 6.2. Owner (1.3): **no shadow run; switch at
once.** "First spawn all eight agents and start slowly shutting down the old
other agents. Just pass them context."

**The catch.** The ODs cannot share messages safely until L1 (the columns),
L2 (answer once) and L3 (the poll loop) exist. Spawned before then, the eight
either all answer the same message or sit idle while today's lease holder
does the work. Two orders, Q1 asks which:

| order | steps | until L3 is live |
|---|---|---|
| **A. build first (recommended: the fastest SAFE path)** | L1, L2, L3 in parallel lanes, live on dev + prd; then spawn the eight ODs; then the staged hand-over | today's c-001 / c-002 / c-003 keep working exactly as now |
| B. spawn first | spawn the eight ODs now; only today's lease holder acts, the others stand by; L1..L3 follow | eight sessions mostly idle, and one of them the single point of failure this spec removes |

**The staged hand-over (replaces v0.2's shadow run and cut-over).** "Pass
them context" read as: each old role session (c-001, c-002, c-003 on each
box) writes its 060 handoff file (section 6 of 060: in-flight terminal lines,
open asks, outbox, unread inbox, live lanes, hold notes), an OD on the same
box acks it, and the old session exits (`/exit-clean`, killed after 5 min).
One old session at a time; the next only after the ack. Q4 confirms this
reading. A lane already running keeps its task and reports to `orchestrator`,
which from then on resolves to the ODs.

| lane | scope (files) | test |
|---|---|---|
| L1 hub: the columns | the next free rdb migration (6 columns + the partial index + `needs_peer`; `responsible` back-filled for messages to one agent); store memory + Postgres; box frame `claim` (`poll / renew / release / done`); CLI `spool claim` | `TestMessageClaimPoll` (memory + Postgres: 4 pollers, 100 messages, each locked exactly once; lock expiry; non-responsible close refused; dead-letter at 4; `not_by`); `TestBoxMessageClaim` (two boxes) |
| L2 hub: answer once | the `answers` guard on agent posts (responsible + gen + unique) | `TestAnswerOnce`: two peers answer one message, one 200, one 409 |
| L3 orc: poll loop | `do_spl_peer_poll`, `do_spl_peer_ensure`, the local-lock fallback; live as soon as it lands | `peer-poll.tst.sh`: 8 simulated ODs on 2 boxes against a hub stub: pickup 5 s, a dead peer 125 s, an undetected stall 12 min, hub down, the split-brain fence |
| L4 orc: `--to peers` | `spool-send.sh` (`orchestrator` -> `peers`), `asks.sh` (lock moved to the message) | `test-fleet-send.sh` and `asks.tst.sh` extended: one report, 4 seats, exactly 1 responsible |
| L5 orc: mutexes + fence | the spawn launchers and the prd wrappers take `spawn` / `prd-<target>` and re-check the fence; `do_spl_fleet_config` writes every machine or none | `spawn-mutex.tst.sh`: two peers spawn at once, one spawns; a lost fence stops a deploy |
| L6 orc: crons | `do_spl_peer_restart` (`0,15,30,45`), its `_install_cron`, the removals of 6.2 (`do_spl_peer_crons APPLY=1`: installs the two new tags, removes the three old ones, cuts the lease steps out of desk-reconcile) | `peer-restart.tst.sh`: slot -> seat, one seat at a time, a failed start keeps the old one; a crontab fixture before / after |
| L7 seats + drill | `do_spl_peer_setup` (claims 001..004 on a box, the harness per seat, seats on every desk; the spawn of section 8, as an action); the live drill: kill one OD, SIGSTOP one box's ODs, post 20 messages, measure each delay of section 7 (n >= 5 each) | the drill log vs section 7 |
| L8 WUI | show the responsible agent on every message and topic (DM, channel, topic reply) | e2e: a post shows its responsible seat within 5 s |
| L9 doc | rewrite SPEC-spool-fleet-roles.md sections 1, 3, 3.2, 4, 4.1, 4.3, 4.4, 7 | `do_check_dist_hygiene` |
| L10 staged hand-over + delete | the hand-over above, one old session at a time; then, with L3 and L6 running on both boxes, the old roles' code and crons go | `fleet-lease.tst.sh` and the sweep's fixture tests retired with what they tested |

L1, L2 touch only the hub; L3..L6 disjoint orc files; L8 only the WUI; L9
only docs. L3..L6 and L8 need L1; L7 needs L1..L6; L10 is last.

**Deleted in L10:** the renew / watch loops and the role logic of
`LEASE_CMD=renew|watch|fleet`, `LEASE_MASTER` / `LEASE_FAILOVER` /
`LEASE_ORCH` / `LEASE_PRIORITY*`, `do_spl_lease_rank`, the `lease` and
`lease.orch` mirrors, `do_spl_orch_rotate`, `do_spl_dispatch_rotate`,
`rotate.hold`, `do_spl_unanswered_sweep` and its state files, the ask
hand-over blocker, the `orch` / `dispatch` rows of `fleet_leases` (the table
stays for the mutexes), and the role table of fleet-roles section 1 (c-001 /
c-002 / c-003 as distinct roles).

## 9. Owner questions

Each answerable with one word.

1. Order: build the lock and the 5 s loop first (L1..L3), then spawn the eight ODs and hand over (yes), or spawn the eight now with only today's lease holder acting until L3 is live (no)?
2. Does "two should be Grok" lift today's grok suspension for the OD seats only (yes / no)?
3. While grok stays suspended, run the two grok seats on claude (yes), or leave them empty (no)?
4. "Pass them context" = the old c-001 / c-002 / c-003 each hand their open work to an OD through the 060 handoff file, then exit, one at a time (yes / no)?
5. May a grok OD spawn and close lanes and run the pre-approved prd actions under the lock + mutex (yes), or only the claude ODs (no)?
6. Offset the PC's hourly restarts by 7 minutes, so the two boxes never restart the same seat at once (yes), or the same minutes on both boxes (no)?

<!-- version: 0.3.0 · updated: 2026-10-03 · last-edit: 2026-10-03T12:50:00Z -->
