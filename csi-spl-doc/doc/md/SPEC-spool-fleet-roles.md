# Spool fleet roles: orchestrator and dispatchers

> Generated from qto doc `3d695437-8fa3-4ed3-99e9-db7e93f8f46e`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

How the agents that run a box split the work of reading traffic, deciding, and
doing. Owner decision 2026-10-01: two dispatchers (a master and a failover)
route every message. Owner decisions 2026-10-03 (sections 2.1, 3): every OD
seat (orchestrator, master, failover) is in every channel, and the OD that
takes a post answers it and owns that topic.

<a id="ws-doc-1214da5c-bf7d-4656-a3cb-9578af4f21fb"></a>
## 1. Roles

Agent ids follow the grammar in [spec 061 section 0](../../specs/061-agent-id-rename/spec.md#0-the-marker-the-old-form-ends-2026-10-03):
`^[acgmq]-[0-9]{3}$` (`m` = mistral since 2026-10-08, [spec 110](../../specs/110-mistral-vendor/spec.md)). Roles `001`..`003` are claimed (`--claim`), never allocated. Legacy `CLE-` ids end at `2026-10-03T20:59:59Z`.

A role seat's letter is the vendor that runs it (SPL-1685, owner 2026-10-13): the
orchestrator run by Grok is `g-001`, by claude `c-001`, by agy `a-001`. The
table below names the claude ids. Test "is this a role seat" with the one helper
(`spl_is_role_seat` / `SPL_ROLE_SEAT_RX` in bash, `agentid.IsRoleSeat` in Go),
never with a literal list. Section 4.4 says how a rotation changes the letter.

The numbers `001`..`003` are fixed; the letter is a parameter (SPL-1695, owner
HUM-10): `ROTATE_ROLE_VENDOR` in `<spool root>/dispatch/rotate.conf` (the
environment, or `SPL_ROLE_VENDOR`, overrides it; unset = claude). A script that
needs a role seat as a default never writes `c-001`: it asks `spl_role_seat N`
(spool-env.inc.sh), which answers lease.conf's `LEASE_ORCH` / `LEASE_MASTER` /
`LEASE_FAILOVER` when that names seat N (a seat switch flips it), else seat N in
the parameter's letter. Test: `spawn-agents/tests/test-role-seat-vendor-param.sh`.

| id | role | does | never does |
|---|---|---|---|
| `c-001` | orchestrator | decides; spawns, re-seats and closes agents; verifies "live" claims; runs the production operations agents' harnesses refuse (prd reads, prd desk and issue writes, deploys the owner pre-approved); in every channel (2.1), it takes a post only as section 3 says | takes a post the dispatch lease holder has taken; routes routine traffic; runs terraform jobs itself (plan, apply, reconcile: spawns a lane for them, section 1.4) |
| `c-002` | master dispatcher | takes every new post (section 3): answers it itself and owns its topic; does the work itself when it fits its session, spawns a new lane when it is real lane work; delivers agents' owner texts to their topics after checking the claim; escalates decisions to `c-001` | runs the prd operations its harness refuses (those stay `c-001`'s); decides for the owner |
| `c-003` | failover dispatcher | the same as `c-002`, but only while it holds the lease (section 4) | dispatches while on standby |
| `c-NNN` | lane agents | one brief each: build, test, land, prove live, report to `c-001` | route other lanes' traffic |

Every agent runs in **auto** permission mode on the current default model. The
spawner sets `--dangerously-skip-permissions`; the model comes from the agent user's
settings, and a relaunch (`restore-claude-plain.sh`) passes it explicitly
because `--resume` keeps the session's old model.

<a id="ws-doc-da6b4940-9722-43d7-862f-11c41e2f7020"></a>
### 1.1 One agent, one small task

Owner decision 2026-10-01, tightened 2026-10-02: *"the same agent is re-used
for completely different new tasks and that should NOT be the case - the agents
should do 1 small task and then killed / exited"*. A lane agent does **one small
task**: one owner ask, one bug or one feature, and exits as soon as that task
is verified. Every live agent costs memory and CPU on the box, and every turn
re-reads its whole context, so an agent carrying three tasks pays for all three
on every turn.

| situation | do |
|---|---|
| a **new ask**, in any topic, even in the same code or the same topic | **always a new small lane**, spawned by `c-001`; its brief names the old lane's notes and commits as context. Never hand it to a running lane because it is alive, idle or "already in that code" |
| a follow-up that is part of the lane's **own task** (an answer it asked for, a correction to the same ask) | the owning lane if it is alive; if it has closed, a fresh lane that starts from its branch and notes |
| a defect in the lane's **own just-shipped commit**, inside its own task | the same lane fixes it before it exits; this is the only exception, and anything beyond that commit is a new ask |
| a lane is sent a different task | it refuses it and tells `c-001`, which spawns a new lane for it |
| a lane's task is verified | it reports and exits (`/exit-clean`); `c-001` verifies the claim (section 3.1) and closes it at once if it has not |
| a lane waits more than about an hour for an owner answer | park its context (branch, held commit, the open question) in `/var/tmp/c-parent-level/dispatch/hold/<topic>/`, close it, and respawn from the hold dir when the answer comes |

"Stand by in case the owner answers later" is not a reason to keep an agent
open, and neither is "it could take the next ask". The OD that took the post
applies the first two rows (section 3): it forwards only a follow-up to the
owning lane, and a new ask that is real lane work gets a NEW lane, which it
spawns itself. `c-001` applies the rest.

**When a human ends the discussion, the agent ends too.** A human closes or
archives the topic, or says in any words that it is done or no longer active:
the dispatcher tells `c-001`, and `c-001` closes the lane. The agent does not
look for new work in that topic, and posts nothing more there. If it still has
something to say (a risk, a follow-up, an idea), it sends one message to the
dispatcher, which passes it to `c-001`. `c-001` decides whether it deserves
the humans' time; if so, `c-001` (or a new lane) opens a **new** discussion.
An agent never reopens a closed discussion on its own.

⏸️ on a topic's opening message = on hold (not archived). An agent sets or
clears it with `do_spl_react`.

<a id="ws-doc-8d605fe4-b3ff-4985-bc94-0d138c865523"></a>
### 1.2 Refactoring rounds need no owner go

The rules for creating and executing bug-fix rounds and refactoring rounds (round size cap of at most 10 items, push caps, continuous execution, and standing rules R1–R16) have their one home in [rounds rulebook](rounds-rulebook.md).

Owner, HUM-10 msg 3d22fcea (2026-10-10): *"refactoring is something which we
should have embedded in our system core way of operating. We will do
refactoring constantly, all of the time. You just pick all the best practices
and you implement them. You shouldn't need my go-ahead for that."*

Rounds run continuously and need no owner go: when round N's actions are
served (its plan's R5), the dispatcher holding the lease requests round N+1's
planner at once (`c-001` places it); the plan's panel seats and, once the
panel has signed, its row lanes follow without a go. Plans:
`refactor-round-<N>-plan.md`; the retro that feeds the next round:
`refactor-round-<N>-retro.md` (both in `csi-spl-doc/doc/md`). A row that needs
a prd mutation, a `terraform apply` or a key still needs the owner's go for
that one call (repo `CLAUDE.md`); the round itself does not. All round creation
and standing rules (R1–R16) are in [rounds-rulebook.md](rounds-rulebook.md).

<a id="ws-doc-1c29fd39-9360-47ea-8f21-6978e62ce515"></a>
### 1.3 Issues track the work, discussions stay talk

Owner, HUM-10, t1 5ea2e615 (2026-10-12), decided in
[spec 135](../../specs/135-work-process/spec.md) v1.0: the discussion is for
talk; the issue holds the condensed record of what is done or being done and
links to the discussion (msg f2c24a7b). Who does which step (the flow and the
state table: spec 135 sections 4 and 5):

| role | does | never does |
|---|---|---|
| owner | says what the work is; agrees the entity of work (`eval` -> `todo`); decides owner questions; pauses (`onhold`); reopens a `done` issue | is filed an issue for a question asked to the owner; is asked to move a status |
| dispatch holder | files one issue per taken discussion from its first answer, in `eval`, description starting `Source: /t/<uuid>` and the restart card, key posted back in the topic (Q1, Q4); an evaluation or answer is an `answer` issue; sets `todo` once agreed; marks `blocked` + `needs-owner` while an owner question holds it (Q2); spawns the lane for the key; tells the owner the key, sha and release | files an issue for a question TO the owner; sets `done` on an unchecked claim |
| `c-001` | refuses a placement without an issue key | files issues for a discussion it does not own |
| lane | works one issue; cites its key in the landing commit (`feat(<area>, SPL-n)` or `Closes: SPL-n`); keeps the card current and comments a checkpoint per landed sha, blocker and rotation; ships the docs in the same lane or says `Docs: none (<why>)`; ends the issue with a reason if it stops without landing | touches another issue's status; sets its own issue `done` by hand; posts in the owner's topic |
| the closer (every 5 min) | `do_spl_issue_close_landed` sets `done` when the citing commit lands (Q3) | closes an epic, or re-closes what the owner reopened |

The key is enforced at the lane's exit and its rate measured weekly (Q6);
`qas` is only for a review a human asked for (Q7); the branch model is
unchanged ([developer guide](developer-guide.md) 1.1-1.4, Q5). Commands for
lanes: [lane issue and docs](lane-issue-and-docs.md).

<a id="ws-doc-0810a441-f54e-4bd8-87cc-6d21755a3ea8"></a>
### 1.4 The orchestrator never runs terraform itself

Owner, HUM-10, t1 topic cd592c84-45ab-49a6-927c-0864718e53b9, msg 116ab2b5-90e3-4905-9317-10397a3c4d35 (2026-10-14), verbatim:

> "I don't understand why the orchestrator must run Terraform jobs. The orchestrator must spawn agents to run Terraform jobs, and then they should report to him."

The orchestrator never runs a terraform plan, apply or reconcile (any `do_tf_*`,
`make do-tf-*`, `make do-provision`, `do_spl_tenant_host_reconcile`, or another
infra action that runs terraform) in its own session. When an infra task or an
owner apply go comes to the orchestrator (or is placed on it), it places a
lane (kind `complex_coding`, claude) that carries the owner's go msg id,
re-plans, applies only the plan the owner approved, and reports back to the
orchestrator.

<a id="ws-doc-dd1b1c90-390b-4c60-a421-a317af4db98e"></a>
## 2. Where messages come from

| source | arrives as | first reader |
|---|---|---|
| web UI posts (owner, members) | a desk delivery: a spool message in the seated agent's inbox + a poke line in its pane | the dispatcher seated on that workspace's desk |
| terminal (agents' reports, peer handoffs, relays) | a v:1 spool message in `$SPOOL_ROOT/<id>/inbox/` + a poke line | the addressee: a dispatcher for traffic, `c-001` only for escalations |
| the owner's own terminal | typed into the orchestrator's pane | `c-001` |

The dispatchers are seated on every workspace desk the box serves
(`do_spl_desk_up DESK_AGENT=c-002`, and `c-003`). `c-001` stays seated
too, so a post that names it still reaches it.

A channel created later gets every OD seat on the next desk reconcile tick
(`do_spl_dispatch_tick`: `do_spl_dispatch_subscribe DRY_RUN=0` every tick,
dev and prd, while `lease.conf` exists; a changed `GAP`/`DEAD`/`UNSEATED` set
is logged, a new prd `GAP` goes to the lease holder and to the orchestrator
after an hour open).

<a id="ws-doc-5769dd4a-685d-43ad-be1f-fd5fbb20575d"></a>
### 2.1 Every OD seat is in every channel

Owner (HUM-10, t1 `d40c3e2f`, 2026-10-03 ~18:25Z), verbatim: *"Of course
every OD should be a member of every channel because they are the ones to
take in whatever comes and decide what to do."* This reverses the
2026-10-01 rule (both dispatchers in every channel, the orchestrator in none).

| what | rule |
|---|---|
| who | every OD seat: `LEASE_ORCH`, `LEASE_MASTER`, `LEASE_FAILOVER` (`c-001`..`c-003`) |
| where | on every box of the fleet: this machine's desk box plus, in fleet mode, every box of `LEASE_PRIORITY` / `_ORCH` / `_DISPATCH` (`DISPATCH_FLEET_BOXES` overrides) |
| which channels | every live channel of every non-test workspace, the default ones included; `#issues` and the retired `#tasks` excluded |
| done by | `do_spl_dispatch_subscribe` (setup step 10, and every desk reconcile tick through `do_spl_dispatch_tick`) |
| a humans-only channel | its people removed every agent (SPL-2423, owner HUM-10 2026-10-17, t1 `ccb3d037`: "no new agents should be added by the system"; hub mark `channels.humans_only_at`, rdb 0206): no OD seat is added, reported `HUMANS-ONLY`, no GAP; a person inviting an agent lifts it |
| a seat the workspace does not roster | the hub refuses its subscription (`not_a_member`): reported `UNSEATED`, a GAP in `do_spl_dispatch_check`, fixed by seating it (`do_spl_desk_up`), never by the subscribe |
| verified by | `do_spl_dispatch_check`: per channel `OD seats n/m`, any missing seat a GAP; per workspace the unseated seats. On another box a role seat of the same number under any vendor letter is that OD seat (a box seating `c-002` holds the `g-002` master of another, SPL-1756); no seat of that number there stays a GAP |

A new channel is covered by the next tick, not by the hub on create: the
hub has no record of which ids are a fleet's OD seats (they live in each
machine's `lease.conf`), and a post in the gap is caught by the unanswered
sweep (3.2) and by the 3-minute rule (3).

Membership decides who RECEIVES a post, not who answers it: section 3.

Receiving is not typing: the orchestrator seat (`LEASE_ORCH` / the orch lease,
unless it holds the dispatch lease) is typed a human's channel post only when
the post names it (`@c-001`, `c-001`, `orchestrator`); every other one waits
in its inbox, and the 2-minute backstop and the unanswered sweep reach it as
messages addressed to it (`spool_notify_orch_quiet`, owner HUM-10 2026-10-07).

<a id="ws-doc-64b35c15-3c3a-4153-87b6-beaa6edbe9f3"></a>
## 3. The routing rule: the OD that takes a post owns it

Owner (HUM-10, t1 `d40c3e2f`, 2026-10-03 ~18:26Z), verbatim: *"The
dispatchers must be able to post. The dispatcher should be doing everything
as well. We need to set up this system so that anyone writing anything
should get answered within 3 minutes. Once an orchestrator dispatcher takes
something, then he answers but he keeps the context of that discussion so
he becomes the owner of that discussion."*

**Every human post is answered within 3 minutes.** (How fast the model's
first words appear is a separate design, not this section's.)

Every OD seat receives every channel post (2.1). Exactly one of them takes
it, so a post never gets two answers:

| the post | who takes it |
|---|---|
| in a topic an OD already owns | the owner (below); every other OD that receives it leaves it, and forwards it to the owner if it reached only them |
| new (a new topic, or a topic no OD owns) | the dispatch lease holder (section 4), at once |
| names an OD (`@c-001`) | that OD |
| still unanswered after 2 minutes (no agent reply in the topic) | the orchestrator lease holder, as the 3-minute backstop; it then owns the topic |

A seat on standby (the failover while the master holds the lease, the other
machine's trio while this one holds it) reads and takes nothing.

**Taking is a named action the human sees** (owner go, t1 `bc1a43e1`,
2026-10-08): the taker runs `do_spl_take` (`DESK_AGENT`, `DESK_TO`,
`DESK_TASK`, `TAKE_PLAN`) before any other work. It posts one line in that
topic to that human through `do_spl_desk_reply` ("Taken by <id>@<box>:
<plan>. I post the result here."), once per topic and taker (ledger
`dispatch/take.log`), and with `TAKE_NOTIFY` tells the agents by spool note
in the same call. A note to the agents alone is not a take.

**The taker answers the post itself and owns that topic.** It keeps the
topic's context and answers every follow-up there; it does not hand the
conversation to another agent. Ownership ends when a human closes the
topic (section 1.1).

**The taker does the work itself** when it fits in its own session: an
answer, a status, a lookup, a check. Only real lane work (a code change to
build, test, land and deploy) goes to a lane: the taker spawns a NEW lane
for it (never a running one, section 1.1), stays the owner, and posts the
lane's result in the topic. What stays with `c-001`: prd operations a
dispatcher's harness refuses, and decisions; a question only the owner can
answer is posted as a blocker in the topic.

**The owner record.** Spec 068's claim is the record: a human channel post
in a seated workspace is a peer message, and the seat that claims it is
stored in `messages.responsible` (`<id>@<box>`, rdb 0110,
`internal/store/message_claim.go`); the owner of a topic is the
`responsible` of its opening post. Until the 068 poll loops run, nothing
claims, and the owner is the OD whose reply is the first agent reply in the
topic (its `from_id@from_box`): every OD sees that reply in the topic
itself.

For each message the taker does exactly one thing, then archives it:

| the message is | the taker |
|---|---|
| a question or ask it can answer or do in its own session | answers it in the topic, now |
| real lane work (a new ask needing a build, test, land, deploy) | spawns a new lane, says so in the topic, stays the owner and posts the result |
| a follow-up to a live lane's own task (an answer it asked for, a correction to that same ask) | forwards it verbatim, with topic and message id, to that lane |
| a status question | asks the owning lane for a one-paragraph status and posts it in the asker's topic |
| an agent's owner text ("post this in topic X") | checks the claim (section 3.1), then posts it verbatim with its screenshots |
| a decision, an approval, a prd operation its harness refuses | escalates to `c-001` in one message: who asked, where, the exact words, what it needs; keeps the topic and posts the outcome |
| a duplicate or chatter | archives it, no reply |

Ownership of a lane's code comes from the spool registry, the window names
and the orchestrator's lane table. An OD never guesses which lane owns
something; it asks `c-001`.

<a id="ws-doc-41c921ec-fb7f-443c-b144-79a3e95755bd"></a>
### 3.1 A "live" claim is checked before it is posted

A web UI change is live only when the served `build.json` commit contains the
agent's commit (`git merge-base --is-ancestor <sha> <served>`); a hub change is
checked the same way against `/version`. An unproven claim goes back to the
agent.

<a id="ws-doc-5628be9b-5b62-4cdf-83a9-3497b7b51b5b"></a>
### 3.2 The unanswered sweep: the pull that finds what nobody answered

The routing rule acts on DELIVERIES, so it only ever sees a post the moment
it arrives. A post that arrived before the dispatchers existed, while a seat
was down, whose poke was lost, or that an agent read and never answered, is
never looked at again. Measured 2026-10-01: two bugs posted in csi-rel
#development on 2026-09-28 sat three days unanswered until the owner pinged
("the pulling mechanism should work for all the tenants, not only the spool
t1 tenant").

`do_spl_unanswered_sweep` (csi-spl-orc) is the pull. Every 10 minutes, from
the box crontab (tag `# csi-spl:unanswered-sweep`, installed by
`do_spl_unanswered_sweep_install_cron`, step 11 of `do_spl_dispatch_setup`),
it reads EVERY workspace of the hub in one read-only query and lists each
topic whose LAST message is a human's and older than 15 minutes.

| a topic whose last message is | the sweep |
|---|---|
| an agent's | leaves it: answered |
| a take line (`do_spl_take`, "Taken by ... I post the result here."), younger than 30 minutes (`SWEEP_TAKE_GRACE`) | leaves it: taken. A take is not the answer (SPL-1718): after the 30 minutes the topic is listed again, aged and keyed from the oldest human post before the take, until an agent answers. A human post after a take keeps that oldest post as the age |
| a human's, in a test workspace (`e2e`, or an id or name with `e2e`, `test` or `proof` as a word) | leaves it |
| a human's, in an archived topic or an archived or deleted channel | leaves it: closed |
| a line a human typed in an agent's terminal (`typed_by`, specs/036) | leaves it: the agent read it where it was typed |
| a human's post addressed to another human (a DM or a channel post to `HUM-n`), or in `#issues` / `#tasks` | leaves it |
| a post by the probe human (`SWEEP_SKIP_HUMANS`, default `HUM-1` on prd) | leaves it |
| a post a dispatcher acked (`do_spl_unanswered_ack`) | leaves it: handled, until a new human post in that topic |
| a human's, younger than 15 minutes | leaves it: the live delivery has it |
| a pure acknowledgement ("ok", "thanks", emoji only) | lists it in its own table, never sends it |
| any other human post | sends it to the lease holder |

`do_spl_dispatch_check`'s unsigned count leaves out `#issues`, `#tasks` and
`#probe` (the live-proof channel), the same channels `SWEEP_SKIP_CHANNELS`
skips. Both numbers it prints leave them out: how many human posts, and how
many of them were stored unsigned. The skip is the channel, so a post in
`#probe` does not count, whoever sent it (SPL-1648).

Delivery is ONE spool note per sweep (task `unanswered-sweep`) to the lease
holder, with only the items NEW since the last sweep: a table of workspace,
channel, topic, last human post, age, who and the first 120 characters. The
memory is `<spool root>/dispatch/unanswered.state`, keyed by the topic's last
message, so a new human post in a known topic is a new item. An item still
open two hours after its note is sent once more (`AGAIN`); still open two
hours after that, it is escalated to `c-001`, once. The dispatcher treats
each item like a delivery under section 3. An item that needs no agent reply
(an announcement, a link, a topic the owner closed in words) is acked, never
answered with filler:
`./run -a do_spl_unanswered_ack TOPIC=<uuid or its first 8 hex> REASON=<why>`
appends to `<spool root>/dispatch/unanswered.acks`, and every human post in
that topic up to that moment is left out from then on (`ACK_LIST=1` lists
the acks). A new human post in the topic opens it again.

`<spool root>/dispatch/unanswered.last` holds the last delivered sweep's time
and open counts; `do_spl_dispatch_check` shows it as the `unanswered sweep`
row and calls it a GAP when the sweep never ran, its last note failed, or it
is over 30 minutes old. Without `DELIVER=1` the action only reports: run it
by hand to see the current list.

<a id="ws-doc-f0a9302b-49fa-4e37-a3cd-7f0c0695e687"></a>
## 4. Master and failover: the heartbeat lease

```mermaid
sequenceDiagram
    participant M as c-002 (master)
    participant L as lease file
    participant W as lease watcher
    participant F as c-003 (failover)
    participant O as c-001
    loop every 60 s while the master's agent process lives and is able to act
        M->>L: write "c-002 <epoch>"
    end
    W->>L: read every 60 s
    Note over W: lease older than 180 s
    W->>L: write "c-003 <epoch>"
    W->>F: DISPATCH LEASE: you are now ACTIVE
    W->>O: failover took over
    F->>F: dispatch own inbox + the master's unread inbox
    M->>L: master back: write "c-002 <epoch>"
    W->>F: DISPATCH LEASE: STANDBY
    W->>O: master is back
```

- The lease is one line, `<holder> <epoch>`, in `$SPOOL_ROOT/dispatch/lease`.
  Only the holder dispatches.
- The **renew loop** follows the master BY AGENT ID: each tick it looks for a
  live agent process (claude, grok or vibe, spec 134 P0) whose environment
  carries `SPOOL_AGENT_ID=<master>`, so a
  relaunched master is picked up with no manual step. No such process, no
  renewal, and the lease goes stale.
- **Live means able to act**: a live process is not enough. On
  2026-10-02 the master sat on `Usage limit reached · Continuing
  automatically at 7:20am` with an owner post in its prompt while the lease
  stayed fresh. Each tick also reads the footer of the agent's own tmux pane
  (the last 12 non-blank lines of the visible screen, found by walking the
  pid's parents to a `pane_pid`). A modal trust, onboarding or login-picker
  screen is a stall on sight. A dismissable modal is a stall on sight too:
  `LEASE_MODAL_RES` is one entry per line: a title regex, then an optional
  tab and an option-line regex. The default title is `teach auto mode about
  your environment` and the option line is `Not now` or `Don't show again`
  (the picker on that dialog). Each must be its own line, within 16 lines,
  and a line above a trailing idle prompt does not count, so a transcript
  mention is not a stall. The able check presses Escape once, waits
  `LEASE_MODAL_WAIT` seconds (default 3) and reads the pane again. Still
  there: the seat stays not able, so the lease fails over, and the
  orchestrator is told once. Escape cancels and chooses nothing. The fleet
  settings turn that offer off (`skillOverrides.auto-mode-setup` = `off`).
  A usage-limit, `/login` or invalid-key banner
  is only a hint, because claude leaves it under the prompt after it resumes
  (a false positive at 04:09Z, the master working under it). It counts only
  while a turn is in progress whose spinner (`… (12s · ↓ 214 tokens)`) has
  not changed for 45 s; a working turn's timer moves every second. A stall
  means no renewal, logged once as `renew stop <id> (stalled pid=<n>: <why>)`,
  and the 180 s failover fires.
  The same rule picks the fleet lease's local candidates (section 4.1), so a
  machine whose whole trio is stalled lets the fleet lease go stale and the
  other machine takes over. No pane found fails open (process-only rule).
- **A dispatcher is able only when its box can post** (spec 092 FR-002).
  The dispatcher is the seat that posts, so in fleet mode a dispatch candidate
  also needs the box's `LEASE_TENANT` desk: its `spool hub-run` sidecar alive
  (`<desk>/spool/.hub/hub-run.pid`) and its current session's last word
  `hub session up` (the last session line of `hub-run.log`, stamped no earlier
  than the pid file). On 2026-10-05 a box back from a power cut took dispatch
  51 s before its desk sidecar was up. The reason lands in `able.<id>` and in
  `NO-LOCAL-AGENT` (`desk: no hub-run sidecar ...`, `desk: session not up
  ...`, `desk: sidecar pid=<n> (re)started, no session up since`). A holder
  whose desk drops stops renewing and fails over in 180 s, like a dead
  process. `LEASE_DESK_GATE=0` turns it off; `LEASE_DESK_DIR` replaces the
  desk dir (default `<state>/desk/<LEASE_TENANT>/<LEASE_DESK_BOX>`).
  Knobs: `LEASE_BLOCK_RE`, `LEASE_STALL_RE`, `LEASE_STALL_FROZEN`,
  `LEASE_PANE_TAIL`, `LEASE_MODAL_RES`, `LEASE_MODAL_WAIT`.
- The **watch loop** promotes the failover after 180 s without renewal (never
  a failover with no live process: that is logged once as `NO-FAILOVER`) and
  keeps the lease fresh in its name, under a lock so it cannot overwrite a
  master renewal. When the master renews again, the watcher sends
  the failover `STANDBY`; the master's own renewal is the handback.
- On promotion the failover also works through the master's unread inbox,
  skipping what the master's outbox shows it already handled.
- Every transition is logged once to `$SPOOL_ROOT/dispatch/lease.log` and
  reported to `c-001`.
- Both loops are the run action `do_spl_dispatch_lease`
  (`LEASE_CMD=show|renew|watch|ensure|stop`). The desk reconcile cron runs
  `ensure` every tick, which starts a loop that is not running; that is what
  brings them back after a reboot. `$SPOOL_ROOT/dispatch/lease.conf` (the ids)
  is the opt-in: without it `ensure` starts nothing.
- Setting it all up on a machine: [HOWTO-setup-dispatchers.md](HOWTO-setup-dispatchers.md)
  (`do_spl_dispatch_setup`, verified by `do_spl_dispatch_check`).

<a id="ws-doc-3e11a9b0-8186-4b11-a7c2-a77d0555ccfa"></a>
### 4.1 Across machines: the fleet lease (spec 061)

Owner decision "a" (t1 5fe56859, 2026-10-01): exactly ONE orchestrator and
ONE master dispatcher act at a time across BOTH machines, the box PC and the
satellite ([SYS.md section 1](SYS.md)). The box PC's trio leads while it is
on. When it goes silent (night, reboot), the satellite's trio takes over
within about 3 minutes, and hands back when the PC returns. Later the
priority flips to the satellite by one config change.

| role | box PC | satellite (box `sat`) |
|---|---|---|
| orchestrator | `c-001@<box>` | `c-001@sat` |
| master dispatcher | `c-002@<box>` | `c-002@sat` |
| failover dispatcher (local) | `c-003@<box>` | `c-003@sat` |

Owner rules (t1 2efb3e78, 2026-10-01): ids `001`, `002` and `003` are
reserved on EVERY box (orchestrator, master, failover), and a session is
named `<ID>@<box>`, where the box is the machine's desk box id (box.env
`SPOOL_DESK_BOX`, 3 letters preferred). The format is owned by spec 058.
Because the same ids run on both machines, a bare id says
nothing about the machine: every lease holder carries its box.

**Where the lease lives: the hub**, not a bucket. Both machines already reach
the hub (the satellite has no public IP, but reaches it through NAT), and the
box key's pin authenticates every write. The hub stamps the row with ITS
clock, so the two machines' clocks never have to agree. The
compare-and-set is one SQL statement. A bucket would have needed a new GCP
resource, and its age would have come from each machine's own clock.

- The row: rdb `0094_fleet_leases`, one per (tenant, fleet, role), with
  `holder = <ID>@<box>` (rdb 0095; 0094 wrote `<box>:<ID>`), the writing box (from the authenticated
  hello, never from the frame), `gen`, and `renewed_at`.
- The primitive: the box frame `lease` (`lease_op get | cas`), CLI
  `spool lease --fleet <f> --role <r> [--holder <ID>@<box> --if-gen <n>]`.
  A `cas` writes only while the row's `gen` is still the one the caller read.
  A lost race answers `won=false` with the current row, not an error.
- The rule lives in the loop, not in the hub: `do_spl_dispatch_lease
  LEASE_CMD=fleet`, one loop per machine, every 60 s, for role `orch` and role
  `dispatch`:

| this machine | does |
|---|---|
| no live candidate (orch: `LEASE_ORCH`; dispatch: `LEASE_MASTER`, else `LEASE_FAILOVER`; each as its seat runs it now, below) | writes nothing; a lease it held goes stale; past the next vendor's wait its seat switches vendor in place (below) |
| holds it | renews; the local master/failover order still applies inside the machine, but a move between two of its seats of one vendor tier, and the move back, is made only once wanted `LEASE_SEAT_HOLD` (2) ticks in a row (`SEAT-HOLD <role>: ...`, SPL-3069); a holder with no live process, a rotation hold, an S2 limit, a stalled pane or a stuck unread moves at once; each change of a seat's able verdict is logged once (`ABLE <id>: ...`) |
| holder silent > 180 s on the hub's clock | takes over |
| ranks before the holder's machine in the role's ranking (`LEASE_PRIORITY_ORCH` / `LEASE_PRIORITY_DISPATCH`, else `LEASE_PRIORITY`), its candidate able for `LEASE_HOLDDOWN` s without a break, and the machine not in `LEASE_INTERMITTENT` | takes it back (the handback) |
| ranks before the holder, but able for less than `LEASE_HOLDDOWN` s, or listed in `LEASE_INTERMITTENT` | holds back, logged once as `HOLD <role>: ...` |
| otherwise | stands by |

- **A box losing power is routine** (spec 092, owner t1 368e1565: a laptop
  box will lose power often; the fleet is N always-on cloud boxes plus such
  intermittent boxes). The always-on boxes carry every role alone, and a
  returning box takes nothing back until it is proven healthy:
  - **Hold-down**: a rank handback waits until this machine's candidate has
    been able (the desk included, for dispatch) for `LEASE_HOLDDOWN` s
    (default 300; 0 = at once) without a break. A tick without a candidate,
    or a gap over `LEASE_STALE` between two ticks (the machine was off; the
    clock file `fleet.<role>.able-since` outlives a power cut), restarts the
    clock. Taking an empty or stale role is never delayed.
  - **Intermittent boxes**: `LEASE_INTERMITTENT` (lease.conf or env, boxes
    comma-separated) lists the boxes that drop off without warning. A listed
    box never hands back by rank; it takes a role only when the role is empty
    or its holder is stale. Rank it where it should stand among the boxes
    that ARE up; the class, not the name, keeps it from taking roles back.
- **Vendor fallback: claude, then grok, then agy** (SPL-2521, owner HUM-10,
  t1 b3e90079, 2026-10-19: "there was login on the claude and ... grok should
  have been able to take over the orchestratio n, but it did not"; msg
  dfe76b16: "the order is claude -> grok -> agy"). Until then the candidates
  were the claude ids above only, and grok came in only through the hourly
  rotation (4.4), never on a stall. Now:
  - **the role's own seat switches vendor in place** (SPL-2544; c-001's
    decision, option 2). SPL-2521/2532 ran separate standby seats (`g-001`,
    `a-001`, `g-002`, ...); on the boxes those ids are links to the claude
    seats' dirs (4.4, "the id follows the vendor"), so a standby start wrote
    over a claude seat's prompt (2026-10-19 09:5xZ), and since SPL-2541 all 6
    default ids were refused: the failover could never start. Now there is
    one process per seat. When no seat of the role on this machine passes the
    able + stuck test and the holder has been silent past the next vendor's
    wait (below), the lease (`spl_fleet_switch_tick`) launches
    `do_spl_role_failover` (`csi-spl-orc/src/bash/run/spl-role-failover.func.sh`)
    for the role's seat (orch `LEASE_ORCH`, dispatch `LEASE_MASTER`), at most
    once per `LEASE_SWITCH_RETRY` (120 s). Under the rotation's lock
    (`rotate.<orch|dispatch>.lock`; a rotation in flight goes first) and the
    id lock, it takes the next vendor after the seat's that passes its guards
    (grok: the rotation's `spl_rotate_grok_why`; agy: lane-mix and a lease
    that counts it), whose wait has run and that is not backed off
    (`ROLE_FAILOVER_BACKOFF`, 1800 s). It runs `role-seat-switch.sh` (the one
    dir moves, every other letter links to it, so the inbox, handoff and lease
    key carry over) and refuses a start whose dir is not its own (no other
    seat's `lifetime/prompt.txt` is ever written). It then starts the vendor
    in the seat through the rotation's spawn (the start check, the identity
    map), and `ROLE_FAILOVER_SETTLE` (30 s) later judges it with the lease's
    own test, then asks for a proof of work (SPL-2609): the lease's test
    alone passes for a session that started and sits at an idle prompt (its
    stuck check fires only on an unread inbox older than 600 s), so a seat
    that never reads its inbox passed it. Right after the start the switch
    sends the seat a probe task on the spool (its inbox, poked; task
    `failover-<role>-rotate-<ts>-failover-<new id>`) carrying the rotation's
    ACK command (`ROLE_FAILOVER_CMD=ack ... do_spl_role_failover`, which runs
    the hourly rotation's ack sender `spl_rotate_ack_send`: accepted only
    from the new pid). The command is in the inbox only, never in the seed.
    The seat is able only once that ack is a result in its outbox within
    `ROLE_FAILOVER_ACK_WAIT` (300 s; grok role sessions acked 12-17 s after
    their start in the rotations of 2026-10-18/19, n=7). Able: `lease.conf`
    takes the new id, the old session ends, and `role-failover/seat.<NNN>`
    records it. Not able (no ack, or the lease's test fails): the new session
    closes, the dirs go back, `lease.conf` is untouched, that vendor is
    backed off, the next vendor is tried.
    The lease follows the seat's link at once (`spl_fleet_seat_id`).
    `LEASE_ORCH_FALLBACK` / `LEASE_DISPATCH_FALLBACK` now list VENDORS
    (default `LEASE_VENDOR_ORDER`; an old id list reads as its letters'
    vendors; `none` = off); `LEASE_ROLE_SWITCH=0` turns the switch off;
    `do_spl_role_fallback_up` is a no-op. An agy process (comm `agy`) counts
    as live;
  - **the vendor ranks before the machine** (`LEASE_VENDOR_ORDER`, default
    `claude,grok,agy,claude2`; the vendor is the id's letter, and `claude2` a
    claude process started with `CLAUDE_CONFIG_DIR`, the second login, SPL-2943,
    spec 060 section 5.3): a fallback seat never
    takes a role from an able seat of a better vendor, and an able claude
    seat on any box takes it back from a grok or agy holder (the handback,
    with `LEASE_HOLDDOWN`, also from an intermittent box);
  - **a claude seat anywhere comes first**: a seat switches to a vendor (and
    a seat of a worse vendor takes a role) only when the holder has been
    silent `LEASE_STALE` + `LEASE_FALLBACK_WAIT` (60 s) per step down the
    order (grok > 240 s, agy > 300 s). A machine
    whose best able seat is of a worse vendor than the one holding stops
    renewing (`FALLBACK-WAIT <role>: ...`, logged once) and waits the same way;
  - **bound**: from the last renewal of a seat that cannot act to the switch
    is at most `LEASE_STALE` + `LEASE_FALLBACK_WAIT` + one `LEASE_PERIOD` =
    300 s with the defaults, no human step; the new vendor's start and one
    more tick follow. The lease logs `SWITCH <role>: ...`, then
    `VENDOR <role>: <old> (claude) -> <new> (grok)`, and an orch switch DMs
    the owner once like any take-over.
  - **the handback** is the hourly rotation's (4.4): for a seat in
    `role-failover/seat.<NNN>` the successor is claude once claude can act
    (`spl_rotate_claude_out` says nothing), else the seat keeps its vendor;
    a standby box hands its seat back too.
  - **The no-orchestrator alert** (`spl_asks_orch_alert`,
    `csi-spl-orc/src/bash/run/spl-asks-tick.func.sh`; the hub's orch holder
    silent past `ASKS_ORCH_STALE`, 600 s) was posted 2026-10-18T12:07:09Z
    and sat in #alerts 19 h 30 min with nobody acting. Now, still open after
    `ASKS_ORCH_PAGE_MIN` (30; 0 = off), the owner (`ASKS_OWNER`) gets ONE
    direct message; and the cleared post keeps how long it was open
    (`Cleared <ts> after 19 h 30 min open, nothing to do. Was: ...`). Test:
    `csi-spl-orc/src/bash/tests/asks.tst.sh` R2/R3.
  - Tests: `csi-spl-orc/src/bash/tests/fleet-lease-vendor-failover.tst.sh`
    (the 2026-10-19 login expiry on two boxes, the lease side) and
    `role-failover.tst.sh` (the switch: grok, grok unable -> agy, the
    handback, the red control of the 10-19 overwrite, the rotation lock;
    case 11, the red control of a seat at an idle prompt that never acks
    the probe: not able).
- **The standby takes over on two conditions** (owner, t1 27f01e16,
  2026-10-02: "The failover should just stand by and in certain conditions he
  should take over"). Measured 16:37Z-18:27Z that day: the orchestrator's
  process was alive and renewing, but a stray character in its input box and a
  window-name mismatch stopped every poke - 93 unread, and nothing failed over
  because the lease followed the process.

  | condition | who sees it | then |
  |---|---|---|
  | 1. the holder's process is gone, stalled (section 4) or its machine is silent | the holder's machine: no able candidate, so no renewal | the standby machine takes over when the row is 180 s old |
  | 2. the orchestrator is **stuck**: idle while its oldest unread inbox message is over 10 min old | the holder's machine, every tick: the orch candidate is dropped (`stuck pid=<n>: oldest unread <s>s > 600s, idle <s>s` in `NO-LOCAL-AGENT`) | the same: no renewal, the standby takes over 180 s later |

  *Unread* = an inbox message (`<root>/<orch id>/inbox/*.json`) that arrived
  after the agent's last activity. *Last activity* = the newest write of a
  transcript in the agent's project dir (`<HOME>/.claude/projects/<cwd>/*.jsonl`,
  every prompt, tool call and tool result). A grok seat's last activity is
  its own session (`<HOME>/.grok/sessions/<cwd, url-encoded>/<sid>/updates.jsonl`,
  a reply, thought, tool call or tool result), never a claude transcript of
  the same cwd (SPL-1696: g-001 in `/opt` read "idle 4105s" from one while
  it worked). *Idle* = no turn in progress (no `…(12s · …)` spinner, nor
  grok's `… [stop]`, in the pane footer), so a long tool call is busy, not
  stuck. A message read before the last activity never counts, so an inbox
  nobody archives does not trip an agent that works. No transcript or no pane
  found = not stuck (fails open). Knob `LEASE_UNREAD_MAX` (600 s; 0 = off,
  rule 1 only). Only the orch role has condition 2.

  The stuck orchestrator stays out until its transcript grows past the unread
  message (the poke lands, a human clears its input), then its machine takes
  the role back on priority. **The owner gets ONE DM per take-over** (a
  failover, not a handback): from the new holder's desk to `LEASE_OWNER`, else
  `ASKS_OWNER` of `lease.conf` (`LEASE_OWNER_CMD` replaces it); no owner set =
  one `WARN` in `lease.log`, nothing sent. Logged as `OWNER-DM orch take-over`.

- **Only the holder acts.** The loop mirrors the result into the local lease
  files the agents read: `$SPOOL_ROOT/dispatch/lease` (dispatch) and
  `lease.orch` (orchestrator), one line `<ID>@<box> <epoch>`. **An agent acts
  only while the file names its own id AND its own box AND is at most 180 s
  old.** Otherwise it stands by:
  it reads and stays ready, but does not route, spawn or post. The age rule
  covers a stopped loop: its machine's file goes stale at about the moment the
  hub row does, so a machine that stops renewing also stands its own agents
  down, and the other machine takes over (no window with two actors, beyond
  the two machines' clock skew).
- Every holder change is logged once to `lease.log` (`FLEET <role>: <old> ->
  <new>`). The agent it activates hears `FLEET LEASE <role>: you are now
  ACTIVE`. The agent it stands down hears `... STANDBY`. Each is told once.
- **A hub this machine cannot reach** is logged once (`HUB-UNREACHABLE`). A
  holder that cannot renew for longer than 180 s demotes ITSELF locally
  (mirror `unknown:hub-unreachable`), because by then the other machine may
  already act.
- On a standby machine, the unanswered sweep sends nothing: the holder's
  machine sends it, and sending from both would deliver every item twice. Its
  gap notes go to its own orchestrator.
- Opt-in: `lease.conf` with `LEASE_FLEET`, `LEASE_MACHINE` (this machine's
  box, default its desk box id), `LEASE_PRIORITY` (the boxes, preferred
  first, e.g. `<pc box>,sat`),
  `LEASE_ENV`, `LEASE_TENANT` (the workspace whose hub row holds the lease;
  both machines' desk boxes must be pinned in it) and `LEASE_DESK_BOX` (default
  `box-desk`). With `LEASE_FLEET` set, `ensure` runs the fleet loop INSTEAD of
  renew + watch. **Flipping the priority to the satellite** = `LEASE_PRIORITY`
  `sat` first in BOTH machines' `lease.conf`.
- **One role on its own ranking** (owner, t1 aad0e6cf, 2026-10-03: the orch
  defaults to the satellite, the dispatchers stay where they are):
  `LEASE_PRIORITY_ORCH` and `LEASE_PRIORITY_DISPATCH` in `lease.conf` (or the
  environment), same form and validation as `LEASE_PRIORITY`, each in BOTH
  machines' `lease.conf`. Unset, the role ranks on `LEASE_PRIORITY`, so a
  `lease.conf` without them behaves exactly as before. E.g.
  `LEASE_PRIORITY=<pc box>,sat` + `LEASE_PRIORITY_ORCH=sat,<pc box>` hands the
  orch role back to the satellite and the dispatch role back to the pc.
- **Move one role to a named box** (SPL-2643, owner csitea 1be68c11):
  `cd csi-spl-orc && ROLE=orch|dispatch TO_BOX=<box> DRY_RUN=0 ./run -a do_spl_role_move`
  (dry run by default) writes the hub pin row `pin-<role>`, which every box's
  loop reads and ranks that box first for the role, over every `lease.conf`;
  it fails fast on a box in no ranking, a box the hub beats do not call
  healthy, or (this machine) no able seat, and waits for the hub row to be
  renewed from the box, else undoes the pin. The pin ends after
  `LEASE_PIN_TTL` (86400 s, 0 = never) or with `TO_BOX=none`. Test:
  `csi-spl-orc/src/bash/tests/spl-role-move.tst.sh`.
- Tests: `csi-spl-orc/src/bash/tests/fleet-lease.tst.sh` simulates two
  machines against a hub stub (CAS, expiry at 181 s, priority handback, local
  order, lost race, unreachable hub, hub clock, stalled agents, 6b: a
  per-role `LEASE_PRIORITY_ORCH`, and section
  15: a stuck holder fails over with one owner DM, a busy one does not, the
  `LEASE_UNREAD_MAX=0` control renews it, a dead one still fails over at
  181 s; section 19, spec 092 with N = 3 boxes: the desk gate, the hold-down,
  a restarted sidecar, an intermittent box, and the `LEASE_DESK_GATE=0
  LEASE_HOLDDOWN=0` control that hands back at once). The hub side is tested by
  `TestFleetLeaseCAS` (memory + Postgres) and `TestBoxFleetLease`.

<a id="ws-doc-5de900ba-0de3-4d5b-900e-a6150ead844e"></a>
### 4.2 Messages and reports across machines (specs/058 N1)

Each machine has its own spool root (`/var/spool-hub`). A peer message or a
report must reach the agent's inbox on WHICHEVER machine it runs, and a
report must reach the orchestrator that holds the lease, not a fixed id on
the sender's machine.

| send | goes |
|---|---|
| `spool-send.sh --to <id>`, `<id>` an agent of this machine (its dir or a `registry.tsv` row) | local, unchanged |
| `--to <id>@<box>` | the machine named: this machine's own desk box is local, any other box is relayed with that `to_box`. The role ids 001-003 exist on EVERY machine, so a bare `c-001` always means this machine's, and the hub refuses it across machines (`ambiguous_to_box`) |
| `--to <id>` NOT on this machine | relayed: `spool-fleet-relay.sh` (as the box user) signs it with THIS machine's desk box and hands it to the hub over the live desk sidecar; the hub roster names the box that holds `<id>`; that machine's sidecar writes it into the agent's desk inbox AND, through `SPOOL_FLEET_ROOT`, into `/var/spool-hub/<id>/inbox`, and rings the pane. `delivery` is the hub's (`sent`, `queued`, `pending`) |
| `--to <id>` known nowhere (or no fleet desk configured) | refused, exit 13, nothing written. The bare `spool send` refuses an unknown local id too (exit 3, `unknown_local_agent`): it no longer mints an orphan inbox |
| `--to orchestrator` | the orch lease holder from `<root>/dispatch/lease.orch` (`<ID>@<box>`: local when the box is this machine's, else relayed to that box); `none@unreachable` or no file -> `LEASE_ORCH`, then `SPOOL_ORCHESTRATOR_ID` |

- The fleet desk: `SPOOL_FLEET_ENV` + `SPOOL_FLEET_TENANT` in box.env
  (`box-config.sh`), else `LEASE_ENV` + `LEASE_TENANT` of `lease.conf`; the box
  is `SPOOL_DESK_BOX`. The sender must be seated on that desk (the hub refuses
  an unannounced sender); the relay says so and sends nothing.
- Only agent-to-agent DMs are copied into the harness root, only into an
  inbox that already exists, once (inbox or archive), and a failed copy is
  retried by the hub's redelivery. Human DMs and channel mentions stay on the
  desk.
- Attachments do not cross machines (exit 2): name a path in the body.
- Rollout: the copy needs the desk sidecar restarted on the new binary; the
  desk reconcile restarts a sidecar whose binary was rebuilt, and
  `do_spl_desk_up` passes `SPOOL_FLEET_ROOT` (default `/var/spool-hub`).
- Tests: `internal/hub/fleet_send_test.go` (two machines through one hub, both
  ways, reports while the orch lease flips), `internal/spool/fleet_test.go`,
  `spawn-agents/tests/test-fleet-send.sh` (two simulated roots, the relay
  script against a fake `/proc`).

<a id="ws-doc-e391c436-5cac-438f-acea-03aaae5e1451"></a>
### 4.3 Asks to the orchestrator: fire and forget, tracked until closed

Owner bug t1 #spool-hub-bugs 2f7996aa (2026-10-02 01:58Z): "there needs to be
some kind a state mechanism both in the db and on the file system, that you
must fire and forget and then the orchestrator (or the next orchestrator if
the previous one just died) would know to check and get and continue".

**Why the 692aefe8 escalations were lost** (measured 2026-10-02 on the box PC):

| when | what | why nothing happened |
|---|---|---|
| 20:06Z | c-002 -> c-001, kind `task`, msg 7b7f6e64: "new topic 692aefe8, your call" | landed in the inbox and rang the pane once (`.pokes/notices.log` line 1). A decision request, no deadline, no state: 52 more messages followed it before the next reminder (29 notes, 17 results, 5 tasks, 1 blocker) |
| 01:51Z | the "reminder": a `note` on ANOTHER topic (396fe7e5, msg 4aeb5002) | an FYI note about a report; nothing in it reads as an open ask |
| 01:55Z | c-002 -> c-001, kind `blocker`, msg 39451306 | acted on at ~02:10Z, after the owner wrote "but nothing done" |
| all night | c-001's inbox: 954 messages, 0 archived, `.agent-inbox-seen` empty | nothing ever marked a message handled; the orchestrator read by poke lines, and a poke that lands mid-turn is easy to miss |
| for hours | pokes to c-002 REFUSED ("pane holds unsent text", spool-send exit 6) | answers back to the sender were not rung either |

The common cause: an ask was a file plus a doorbell, with no state of its own,
no re-raise, and on the old holder's disk only.

**The ask log.** The shape is Kafka's on what the estate already has (owner,
t1 12d34d3a: "resembles the main principle of how Kafka works ... use
whatever we have: a database, a file system, distributed nodes, the agents"):

| Kafka | here |
|---|---|
| topic / partition | the recipient `role` (`orch` today; `dispatch` next) within the fleet |
| record, idempotent producer | one row per ask keyed by the spool `msg_id` that carried it: a replay (journal sync, a retried send) changes nothing |
| durable log, replicated | the hub table `fleet_asks` (rdb 0097, every machine reads it) + each machine's journal `<spool root>/asks/<msg id>.json` and the append-only `asks/journal.log` |
| consumer commit after handling (share group, KIP-932) | per record, not an offset: `ack` = acquired (in progress, by `<ID>@<box>`), `done` = accepted, `declined` (with a reason) = rejected. An offset would let one stuck ask block every later one; a per-record commit does not |
| acquisition lock + timeout | an `ack` is a lock: a holder quiet `ASKS_LOCK_MIN` (60) minutes after acking (no re-ack, no close) loses it - the tick releases the ask (op `release`: acked -> open, `acked_by` kept as the last holder) and re-raises it the same tick, labelled "LOCK EXPIRED, acked by X". Acking again renews the lock. An ack of an ask another holder has acked is refused (409 `ask_held`, naming the holder; spec 134 3.3, SPL-1569, rdb 0183): before it, the second ack silently replaced the first holder, so two orchestrators could both work one ask |
| at-least-once redelivery | the lease tick re-raises an uncommitted ask (unacked `ASKS_RERAISE_MIN`, acked and past its deadline, or its lock just expired); handling is idempotent: closing a closed ask is refused naming who closed it and why |
| delivery count + limit, archived | `raised_n` counts every delivery (a hand-over and a re-raise alike). At `ASKS_MAX_RAISES` (4) an open ask is not raised again: it goes to the owner once (unless the age leg already told them) and is closed as `dead` with the reason (op `dead`, rdb 0099), e.g. "max delivery count 4 reached (raised 4x); the owner was told". No owner leg configured: dead-lettered anyway, the reason says nobody was told |
| consumer-group rebalance, replay | a new orch holder (the fleet lease, 4.1) gets ONE handover blocker listing every open ask of its role, from the hub - also when the dead holder had read them |
| retention | a closed ask stays a week, then a write prunes it |

**The flow.**

1. **Sender, fire and forget.** `spool-send.sh` with kind `blocker` or `task`
   to the orchestrator (`--to orchestrator`, or its id) journals the ask
   BEFORE it returns, then pushes it to the hub in the background (`asks.sh
   sync`); a hub outage never delays or fails the send. `--ask
   <blocker|task|escalation>` makes any send an ask, `--no-ask` (or
   `SPOOL_ASKS=0`) none, `--ask-deadline <RFC 3339 UTC>` sets when it is due.
   Raised some other way: `do_spl_ask_put`.
2. **Every machine's lease tick** (`do_spl_asks_tick`, its own process each
   tick) pushes the journal asks the hub has not got yet.
3. **The orch holder's machine** also: hands every open ask to a new holder
   (or on its first tick), re-raises the unacked ones after
   `ASKS_RERAISE_MIN` (15) minutes in one blocker on task `asks-open`, and
   after `ASKS_OWNER_MIN` (60) tells the owner ONCE: `ASKS_OWNER_CMD`, else a
   DM to `ASKS_OWNER` (a `HUM-` id) from the holder's desk. Neither set: one
   WARN per ask, nothing sent. Before the re-raise it releases every acked
   ask whose lock expired (`ASKS_LOCK_MIN`, 60; 0 = off), and after the owner
   leg it dead-letters every open ask raised `ASKS_MAX_RAISES` times (4; 0 =
   no limit), whichever of the age and the count comes first. Every knob may
   sit in `lease.conf` (`do_spl_dispatch_setup DISPATCH_ASKS_<KNOB>=...`); the
   tick's summary line counts "lock expired N" and "dead-letter due N".
4. **The orchestrator, on start and when raised:** `./run -a
   do_spl_orch_inbox` (open asks first, untracked blocker/task, FYI collapsed
   one row per sender), then per ask `ASK_ID=<8 hex> ./run -a do_spl_ask_ack`
   and, when decided, `ASK_ID=<8 hex> ASK_REASON='...' ./run -a
   do_spl_ask_close` (`ASK_STATE=declined` needs the reason), and the answer
   to the sender in the ask's topic. Closing archives the ask's message;
   `ORCH_INBOX_ARCHIVE=1 ./run -a do_spl_orch_inbox` moves the FYI older than
   `ORCH_INBOX_KEEP_MIN` (60) and the closed asks' messages to `archive/`.
   From any pane: `asks.sh [open|ack|done|decline|inbox|sync|tick]`.

The owner reminder names the topic it belongs to: the title, who is waiting,
the summary, what to do, and the topic id. When that topic is a channel the
owner can read, the reminder is a reply in it. Otherwise it is a new topic
that still names the title. When the title could not be read, the reminder
keeps the older id line. Once the ask is acknowledged, closed or dead, the
next tick posts one line in the reminder's topic: `resolved:` and the reason.
A dead-letter in the same tick is answered on the following tick.

The mechanical parts are code (owner, 02:19Z: "whenever something can be
pre-coded with pre-existing logic, there should be code for it"); taking,
deciding and answering an ask stay the agent's.

- Without a fleet (no `LEASE_FLEET`) the journal is the whole book: the
  one-machine behaviour.
- Tests: `TestFleetAskLifecycle` / `TestCheckFleetAsk` (memory + Postgres),
  `TestBoxFleetAskSurvivesTheOrchestrator` (two boxes: the home holder lists
  the ask and dies before acking, the other machine's successor gets it,
  re-raises, acks and closes it, the late close is refused),
  `TestFleetAskLockTimeoutAndDeadLetter` (memory + Postgres: the holder on
  one box acks and dies, the successor on another releases, re-raises and
  acks; dead after the limit, 409 after, pruned in a week),
  `TestBoxFleetAskLockReleaseAndDeadLetter` (the same through `spool ask`),
  and `csi-spl-orc/src/bash/tests/asks.tst.sh` (two simulated machines, 47
  checks: fire and forget, hub down, kill-mid-ask handover, re-raise, owner
  leg, close, the inbox view, and section 10: lock expiry across the
  machines, renewal, the delivery limit and the dead-letter, each with a
  control running the old filter).

**OD pool jobs, role `od` (spec 134 steps P1 + P2, rdb 0183, SPL-1569).**
The same table carries the OD pool's jobs: one row per job (`route_post`,
`spawn`, `lane_verify`, `box_op`), locked by any able seat. Built, not yet
used: nothing inserts or locks them before P3/P4, and the lease holder does
all OD work until P6 lists a kind in the pool row. The ops, all on `spool ask`:

| op | does |
|---|---|
| `enqueue --kind <k> --id <msg id> --from <ID> [--topic --issue SPL-n --dedupe <key> --vendor-allow claude\|grok --needs box:<box>\|prd --lease <s> --needs-owner]` | inserts a job; a second OPEN job of the same kind and `--dedupe` key is 409 `ask_duplicate` naming the open one |
| `lock-next --seat <ID>@<box> --vendor claude\|grok [--harness <h>] [--caps prd]` | the hub locks the oldest free job of the pool's kinds for the seat (gen + 1, `lock_until` = now + `lease_s`), or answers none. Free = open, or locked with `lock_until` passed: expiry is lazy, no tick. The 4th lost lock closes it `dead` (the answer's `dead`). The `box:` cap is the session's box |
| `renew`, `done`, `decline`, `release --id <job> --by <seat> --gen <n>` | the holder at its gen; anyone else, or an old gen, is 409 `ask_held` naming the holder. `release --refuse <harness>` adds it to `not_by` |
| `release --by <seat>` (no `--id`) | frees every job the seat holds, gen + 1: the supervisor's kill |
| `decline` of an open or `needs_owner` job, `reopen` | the human or admin answer; `reopen` is `needs_owner` -> open |
| `pool [--set --by <ID> --kinds a,b --claude-n --grok-n --min-boxes --vendor-out --out-until]` | reads or writes the `od_pool` row (target 2 + 2 on 2 boxes; kinds empty = nothing is locked) |
| `list --role od --free` | the jobs a seat could lock now |

The book's ops (`ack`, `raise`, `escalate`, `queue`, `dead`) are 409
`ask_op_refused` on an od job, and the od ops on a book ask, so the two lock
regimes never mix. Tests: `TestFleetAskLockNext`, `TestFleetAskLockNextRaces`
(4 seats on 1 row, n = 20, exactly one lock; 40 rows, each locked once),
`TestFleetAskLockNextAckCAS` (memory + Postgres), `TestBoxOdPoolLockNext`
(two boxes through `spool ask`).

**OD pool seats and their supervisor (spec 134 step P3, SPL-1710).** Two
shell actions, off by default. With `od_pool.kinds` empty no seat locks
anything, so the lease keeps doing all OD work.

| action | does |
|---|---|
| `do_spl_od_seat` (`OD_SEAT_ID=<c-NNN\|g-NNN>`) | the seat's loop, every `OD_TICK` (15 s): `lock-next` while able and holding nothing; renew the held job at its gen while able and the heartbeat's `progress_ts` is at most `OD_PROGRESS_MAX` (900 s) old, else let the lock run out; a 409 drops the job; a locked job goes to the seat's own inbox as a task (pointers only). State in `<spool root>/od/<id>/` |
| `do_spl_od_pool_supervise` (`OD_POOL_SUPERVISE=1`) | every 30 s per box: the able check per seat of this box (`spl_lease_agent_able`, the lease's own); two failed ticks = release its jobs (gen + 1), then `do_spl_wd_takeover`; every seat of a vendor failed twice with a limit banner = the pool row goes to 0 + 4 until the banner's reset, and back after it. Slots `<vendor>-<k>` are fleet leases `od-<vendor>-<k>` held by their seat; a slot whose holder is silent `OD_SLOT_TTL` (300 s) is taken by one other box (compare-and-set). One spawn or retire per tick; an extra seat takes no new job and is retired once it holds none. Off: it retires the seats it spawned (the P3 rollback) |
| `do_spl_od_pool_supervise_install_cron` | the two cron lines (`* * * * *` and `sleep 30`), installed with `OD_POOL_SUPERVISE=0` unless `OD_CRON_SUPERVISE=1` |

A takeover refuses a seat stalled at a usage limit (situation S2 is never
taken over): the seat stays and the dispatch holder gets one note an hour.
Only a whole vendor out moves seats to the other vendor. Tests (hub,
spawn and takeover stubbed, each with a mutation control):
`od-pool-spof.tst.sh`, `od-pool-replace.tst.sh` and `od-pool-vendor.tst.sh`.

**The spawn queue places by work class (SPL-1817).** A queued spawn request
carries its class (rdb 0195) and the placer keeps the owner's bands of the
live lanes; the rule, its numbers and its commands live in one place:
[fleet-rules-index.md](fleet-rules-index.md) section 2, the row "spawn queue:
work classes and bands".

<a id="ws-doc-718510f3-4b5e-4a96-a6e7-07855f5b6079"></a>
### 4.4 Hourly rotation: a fresh session per role (spec 060)

Every role gets a FRESH session under the SAME id once an hour, so no
orchestrator or dispatcher carries an ever larger context: the orchestrator
at `:05` (`do_spl_orch_rotate`), the dispatchers at `:15`
(`do_spl_dispatch_rotate`: the master while the failover covers it under
`<spool root>/dispatch/rotate.hold`, then the failover). The ids never swap
roles, a new session that does not start or ack leaves the old one in the
role with an alert, and no step calls a model. The whole contract - phases,
handoff file, ack, failure paths, switches - is
[specs/060-role-rotation/spec.md](../../specs/060-role-rotation/spec.md);
it is not restated here.

- the one change to this section's lease: `spl_lease_agent_able` reads a
  fresh `rotate.hold` naming an id as "held: rotation", so renew, watch and
  the fleet candidate skip that id; a hold older than `ROTATE_HOLD_MAX`
  (1800 s) is ignored with one `WARN` in `lease.log` (060 FR-023, FR-024);
- **the id follows the vendor** (SPL-1685): a rotation whose successor is
  another vendor starts it under that vendor's letter (`c-001` -> `g-001`)
  with `role-seat-switch.sh`. Before the spawn, the seat's one real spool dir
  moves to the new id, and every other letter of the seat (`a/c/g/m/q-00N`)
  becomes a link to it. Mail sent to the old id, a `${X:-c-001}` default or a
  queued message still lands in the live inbox, and the desk dirs move the same
  way. `lease.conf` (`LEASE_ORCH`, `LEASE_MASTER`, `LEASE_FAILOVER`, and the
  master's `rotate.hold`) takes the new id only once the new pid shows, so the
  old pid keeps the lease until then. The ack may come from either id. A
  failed rotation puts `lease.conf` and the dirs back. CLOSE retires the old
  id's identity record. The knob is `ROTATE_ROLE_ID_FOLLOWS_VENDOR` (default
  1; `0` keeps the claude id for every vendor);
- **the successor's vendor**: `ROTATE_ROLE_VENDOR` (section 1) decides it
  for all three role seats (`spl_rotate_role_vendor`,
  `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh`), and the SPAWN line
  names why. `grok` = grok through its guards (lane-mix's CLI, sign-in and
  limit checks, the seat verdicts' weekly limit, a fleet lease that counts a
  grok holder), else claude. `claude` = **claude active, grok standby**
  (SPL-1869, owner HUM-10 t1 e799211c, poll answer A): claude, and grok ONLY
  while claude cannot act and grok passes the same guards. Claude cannot act
  when there is no claude CLI, when the newest watchdog verdict of this
  box's claude seats is `S2 kind=limit` or `kind=auth` (within
  `ROTATE_CLAUDE_LIMIT_FRESH`, 6 h, and newer than every clean verdict), or
  when this box's dispatch lease names a claude seat silent past
  `LEASE_STALE` (180 s). Once claude is able again, the next rotation is
  claude. Both out = claude, both reasons named. The standby swap (a seat
  out on its limit) follows the same rule. A seat the lease's in-place
  failover moved (4.1) goes back to claude at the first rotation once claude
  can act, never before. `ROTATE_GROK_STANDBY=0` in
  `rotate.conf` keeps claude whatever its state. Tests: `orch-rotate.tst.sh`
  sections 15, 18, 20 and `dispatch-rotate.tst.sh` 19;
- **agy as the dispatcher** (SPL-3395, owner HUM-10 t1 2144cff4, poll
  aed5a733 answer C: "replay first, then live with a net"):
  `ROTATE_ROLE_VENDOR=agy` seats agy in the master AND failover dispatch
  seats only (`a-002`, `a-003`; the lease counts an `agy` process as the
  holder). It goes through `spl_rotate_agy_why`: lane-mix with an `agy=100`
  `specs_and_docs` row (its CLI, sign-in and limit checks) and a fleet lease
  that counts an agy holder; either fails = claude, the reason in the SPAWN
  line. The orch seat never takes agy: `ROTATE_ROLE_VENDOR=agy` there =
  claude, refused by name. A set-hours drill is a hand run with the
  variable in the environment (it beats `rotate.conf`), so the next cron
  rotation seats the vendor `rotate.conf` names again (claude by default).
  Tests: `dispatch-rotate.tst.sh` section 26, `orch-rotate.tst.sh` 15;
- **a standby box's orch seat follows the vendor too** (SPL-2774): the
  hourly orch rotation skips a box whose orch lease another machine holds,
  and the restore never changes a seat's CLI, so on 2026-10-21 the standby
  box's seat stayed `g-001` (grok) on its weekly limit after the owner moved the role to
  claude. `ROTATE_CMD=standby ./run -a do_spl_orch_rotate` (dry run unless
  `DRY_RUN=0`) re-seats it: on a standby box whose one live orch seat runs
  another vendor than the successor rule above names, with
  `ROTATE_ROLE_VENDOR` set or the seat unable to act (its vendor's newest
  watchdog verdict `S2 kind=limit`), the rotation's own QUIESCE .. CLOSE
  starts the seat on that vendor (`g-001` -> `c-001`, the id follows the
  vendor), with the handoff and the ack, retires the old session and sets
  `lease.conf` `LEASE_ORCH` after the ack. It has no age, boot or stall gate
  and never takes or moves the fleet lease; on the holder's box (or with no
  fleet lease) it is refused, exit 3. The dispatch pair's standby swap is
  `do_spl_dispatch_rotate`'s (SPL-1777). Test: `orch-rotate.tst.sh`
  section 21;
- what ran: `<spool root>/dispatch/rotate.log`, one line per step;
- stop it: `ROTATE=0` (or `ROTATE_DISPATCH=0`) in
  `<spool root>/dispatch/rotate.conf` (060 FR-090);
- `do_spl_dispatch_check` has a `dispatch rotation` row: a GAP when the last
  rotation on the machine holding the lease is over 3 h old (060 FR-072).

<a id="ws-doc-e753651a-35dc-4d00-991b-e5bcfe7d6cbb"></a>
## 5. What this replaced

Before 2026-10-01 the orchestrator read every message itself, a standing first
responder covered one workspace, and a relay agent forwarded posts from all
workspaces. Three paths meant duplicate routing and an orchestrator buried in
traffic. Both older agents retire once the dispatchers have routed a test post
end to end in every seated workspace.

<a id="ws-doc-8b184924-0010-4fec-be34-468006a0d089"></a>
## 6. Failure modes seen on 2026-10-01

| failure | effect | guard |
|---|---|---|
| a reboot restore resumed a neighbour's session in a window | pokes reached the wrong conversation; three lanes ran nowhere | the restore records each pane's session from the live process and refuses an inconsistent triple; a post-boot check compares window, env, cwd and transcript |
| registry rows kept pre-reboot pane ids; tmux reuses pane numbers after a restart | a re-run window rename renamed a neighbour's window | the registry is refreshed after every restore; a resolver checks that a pane still runs that agent before using it |
| the shared checkout lagged trunk | spawns re-installed a stale pre-push hook | spawn from an up-to-date worktree; the common hook execs the pushing worktree's own hook |

<a id="ws-doc-2bbfa5d3-6b7b-4424-88b4-53b15a8e8597"></a>
## 7. Status

| piece | state |
|---|---|
| `c-002`, `c-003` spawned (auto mode, current model) | live since 2026-10-01 |
| lease renew + watch loops | `do_spl_dispatch_lease` with tests (a replay of the 2026-10-01 live failover test); ensured every 5 min by the desk reconcile cron; repo loops live since 2026-10-01 06:28Z; the interim watch loop is stopped, the interim renew loop is stopped by the orchestrator at cutover |
| setup and verify on a new machine | `do_spl_dispatch_setup` (DRY_RUN plan, idempotent) + `do_spl_dispatch_check`; prompt: [HOWTO-setup-dispatchers.md](HOWTO-setup-dispatchers.md) |
| dispatchers seated on every workspace desk | done 2026-10-01: both seated in every workspace on the box (do_spl_dispatch_check) |
| every OD seat in every channel (2.1) | code on trunk 2026-10-03 (`do_spl_dispatch_subscribe` / `_check` / `_tick`); applied per env by the orchestrator with `DRY_RUN=0` |
| web UI posts reach the dispatchers | done 2026-10-01: `do_spl_dispatch_subscribe` put both dispatchers in every channel of all 6 workspaces and took the orchestrator out (the hub delivers to a channel's subscribed agents; the fallback list only when none is online). `do_spl_dispatch_check`: no gap. t1 proven on live traffic: 227 human posts reached the master, the orchestrator only DMs and @mentions |
| a channel created after the subscribe | done 2026-10-01: `do_spl_dispatch_tick` on every desk reconcile tick re-runs the subscribe (one read per workspace, no write when nothing changed) and reports a changed gap set: `DISPATCH` lines in the cron log; on prd one `dispatch-gaps` note to the lease holder per new `GAP`, the orchestrator once when it is still open after an hour; test workspaces (`<spool root>/dispatch/test-workspaces`, shared with the sweep) left out |
| @mention of the orchestrator in a channel it left | open: the WUI refused it ("Not told"); decision: the WUI pokes a seated non-member agent by DM with a visible note (a confirm in private channels) |
| unanswered-post sweep over every workspace (section 3.2) | `do_spl_unanswered_sweep` + `do_spl_unanswered_sweep_install_cron` with fixture tests (2026-10-01); every 10 min from the box crontab; a row in `do_spl_dispatch_check` |
| one lease across the box PC and the satellite (4.1) | live on the box PC since 2026-10-01 23:24Z (rdb 0094 + 0095 on dev + prd, hub `lease` frame, `LEASE_CMD=fleet`; prd rows `c-001@box-desk` / `c-002@box-desk`; the interim lease.sh retired). The satellite trio `c-001/002/003@sat` and the live drill follow the satellite rebuild and the owner's go for its prd pins |
| hourly dispatcher rotation (4.4) | `do_spl_dispatch_rotate` + the hold in `spl_lease_agent_able` + `do_spl_dispatch_rotate_install_cron` (`15 * * * *`, tag `# csi-spl:dispatch-rotate`) on trunk with sandbox tests (2026-10-02); the cron is installed after the live proof (060 L3) |
| messages and reports across machines (4.2) | code on trunk 2026-10-02; live once the satellite's desk is pinned and both sidecars run the new binary |
| asks to the orchestrator tracked until closed (4.3) | code on trunk 2026-10-02 (rdb 0097, `spool ask`, `do_spl_asks_*`, `do_spl_orch_inbox`); live once rdb 0097 is applied on dev + prd, the hub rolls, and the lease loops restart on the new tree |
| retiring the standing first responder and the relay agent | first responder retired 2026-10-01; the relay agent retires once a csitea end-to-end post is proven |

<!-- version: 0.9.1 · updated: 2026-10-14 · last-edit: 2026-10-14T17:30:00Z -->
