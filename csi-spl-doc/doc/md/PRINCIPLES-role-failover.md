# Proposal: role failover, the HDFS way

**Status: PROPOSAL, for the owner's review. No code until it is approved.**

The owner, t1 topic 27f01e16 ("The orchestrator is a single point of failure"),
2026-10-02, in order:

1. *"This sounds quite a lot like the Hadoop file system failover situations.
   Let's take all of the lessons from Hadoop and create some guiding
   principles on how to do all of this."*
2. *"Okay what would be the simplest poor man's implementation of all of
   these things within the scope of our system?"*
3. *"And once again the guiding principle should be that our software does
   the mechanical things and the orchestrator does the actual intelligence.
   Everything which is simple and has logical rules should be in the
   software. Everything which requires real intelligence should be passed to
   the Claude Code instances."*
4. *"We can implement all of these small processes in Go and they can run
   natively or via containers on the satellite and on the [box PC] hosts."*
5. *"But first create some kind of proper proposal on how to do all of those
   features, which will be the parallel of the ones of the [Hadoop]."*

The roles this covers are the fleet's single-actor roles: the
**orchestrator** (`orch`) and the **master dispatcher** (`dispatch`), on two
machines, the box PC and the satellite. The mechanism it builds on is
[SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md) sections 1, 4, 4.1,
4.3 and 4.4. It extends the HDFS analysis posted in that topic at 18:41Z
and keeps its seven lessons. This doc proposes; it does not edit the spec.

## 1. Principle zero: software does the mechanics, agents judge

Every failover step that follows a fixed rule is software: the health check,
the take-over, the fence, the generation check, poke delivery, alerts, the
drill. An agent never has to notice, remember or decide any of them. Agents
get only what needs judgement: what to do with a hand-over list, whether an
ask is done, what to tell the owner.

Every feature below is marked **[software]** or **[agent]** per step. Almost
all of it is software.

## 2. Implementation shape: small Go processes on both machines

The software side is Go, in the module we already ship,
`csi-spl-api/src/go/spool-hub-api` (it builds the `spool` CLI, which already
speaks the hub `lease` and `ask` frames). No new language, no new service.

| piece | what it is | runs |
|---|---|---|
| `spool fleet run` | one long-running process per machine: the lease loop, the health pinger, the fence wait, failback hold-down, alerts. Each is a goroutine on its own ticker | natively (a user systemd unit as the agent user) or in a container (one compose service, the spool root and tmux socket mounted), on BOTH machines |
| `spool fleet act-ok --role <r>` | a one-shot check, exit 0 or refuse; the fence and the generation check | called first by every role action script (spawn, close, owner post, ask ack/close) |
| `spool fleet drill` | a one-shot failover drill with a report | weekly from cron, and by hand |
| `./run -a do_spl_fleet_*` | thin bash wrappers, one per piece | the named-action rule of this repo: nothing ad hoc |

Migration is step by step. Today the loop is bash
(`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`, 816 lines). The new
pieces start in Go and are called by the bash loop. The loop itself moves to
`spool fleet run` once the Go side has the same tests
(`fleet-lease.tst.sh` replayed against it). Until then both machines run the
bash loop as today.

## 3. The minimum set

The smallest build that closes the 2026-10-02 failures:

| # | build | feature | phase (section 7) |
|---|---|---|---|
| M1 | one id per agent: `lease.conf`, the lease row, the window name | 4.9 graceful vs forced | 0 (c-036, running) |
| M2 | `spool fleet act-ok`, called by every role action | 4.5 fencing | 1 |
| M3 | the gen in the local mirror, checked by `act-ok` | 4.6 epochs | 1 |
| M4 | the fence wait: a take-over acts only after the old row is 360 s old | 4.5 fencing | 1 |
| M5 | the ping health check | 4.3 health monitor | 2 |
| M6 | failback only after 30 min able, and only through the graceful path | 4.8 no automatic failback | 3 |

Everything else is a follow-up.

## 4. The features, one by one

Each section: the HDFS feature, our parallel today with evidence, the gap,
the poor man's Go implementation (software or agent per step), and the build
phase (section 7).
Log lines are from `<spool root>/dispatch/lease.log` and `rotate.log` on the
box PC, 2026-10-02.

### 4.1 Active / standby pair

**HDFS.** Exactly one NameNode serves. A hot standby has the same state and
can take over in seconds.

**Ours today.** One trio per machine (orchestrator, master, failover
dispatcher). The fleet lease picks one machine's orchestrator and one
dispatcher for the whole fleet (spec 4.1). The standby machine's agents read
and stay ready.

**Gap.** None in the shape. The gaps are in how the switch happens
(4.3 to 4.9).

**Implementation.** No change. **[software]** `spool fleet run` keeps the
same table of decisions as the bash loop.

**Phase.** None.

### 4.2 Leader lock (the ZooKeeper lock)

**HDFS.** The active holds an ephemeral lock in ZooKeeper. If its session
dies, the lock vanishes and the standby's ZKFC takes it.

**Ours today.** The hub row `fleet_leases` (rdb 0094), one per (tenant,
fleet, role), written only by compare-and-set on `gen`
(`spl-dispatch-lease.func.sh:728`, `--if-gen`). It "vanishes" when it is
180 s old on the hub's clock. This is the lock, and it works.

**Gap.** None.

**Implementation.** **[software]** `spool fleet run` uses the same frame
(`lease_op get | cas`). No hub change.

**Phase.** 5.

### 4.3 Health monitor (ZKFC HealthMonitor)

**HDFS.** The ZKFC calls the NameNode's health-check RPC on a timer. A
NameNode that is up but cannot answer is unhealthy, and the ZKFC gives up the
lock for it.

**Ours today.** `spl_lease_agent_able` (`spl-dispatch-lease.func.sh:302`)
checks a live process, a rotation hold and a stalled pane footer. Since
931cd8d0 the orch role also has the "stuck" rule (`spl_fleet_stuck`, `:641`):
idle with an unread inbox message older than 600 s. Before that rule,
16:37Z-18:27Z, the orchestrator was alive and renewing but deaf: a stray
character in its input box and a window-name mismatch stopped every poke, 93
messages went unread, and nothing failed over (spec 4.1, "two conditions").

**Gap.** The stuck rule infers health from side effects (transcript mtime,
pane spinner) and fails open (`:638`: no transcript or no pane = not stuck).
It cannot see a poke that never arrived.

**Implementation (M5).**
- **[software]** Every tick, the pinger goroutine sends the holder a
  `ping` message through the normal send path (spool file + pane poke), so
  the check covers delivery too.
- **[agent]** The role prompt: on any poke, `touch <inbox>/.pong`. A reflex,
  not a decision.
- **[software]** No `.pong` newer than a ping older than 600 s, with no turn
  in progress = not able, so the machine stops renewing and the standby takes
  over 180 s later. This does not fail open: no pong is a verdict.
- **[software]** A missing pane is logged every hour, not once.

**Input from the stopped lanes.**
- Condition 2 (stuck) is already on master as 931cd8d0, decided on the
  holder's own machine: about 10 min + 180 s to a take-over. 15 new checks in
  `fleet-lease.tst.sh` section 15 pass; no live drill yet. Its "idle" signal
  reads the claude TUI spinner text, which breaks if the TUI changes. In Go,
  **[software]** a Claude Code hook writes a heartbeat file on every prompt
  and tool call, and the verdict reads that instead of the pane.
- Pokes by pane (WIP, branch `c-040-poke-by-pane`, not on master) measured
  both causes of the 16:37Z-18:27Z deafness: (a) the pane lookup matched the
  id literally, and every record still said `CLE-001` while the agent was
  `c-001` (exit 5); (b) one stray `p` in the input box refused every poke
  (exit 6) until the poke was dropped at 300 s. Its design: **[software]**
  one resolver over the whole alias set; a stale one-line draft is cleared,
  the poke submitted and the draft typed back; after 3 refusals and 180 s,
  ONE "`<id>` is DEAF" alert. Its fake-TUI test is 50/50 with a control.

**Phase.** 2: first pokes by pane (the stopped c-040's branch), so the ping
lands where the agent is; then the rule (the stopped c-039's branch).

### 4.4 Shared edit log (Quorum Journal Manager)

**HDFS.** Every metadata change is written to a majority of JournalNodes.
The standby replays the log continuously, so a take-over loses nothing.

**Ours today.** The ask book (spec 4.3): the hub table `fleet_asks`
(rdb 0097) plus a journal on every machine. A new orch holder gets one
handover blocker listing every open ask.

**Gap.** Only kinds `blocker` and `task` are asks. A `note` that carried a
real request stays in the old holder's inbox, on the old machine.

**Implementation.**
- **[agent]** The dispatcher decides that a message is a request. That is
  judgement, and already its job.
- **[software]** Its forward then passes `spool-send.sh --ask`, which exists.
  Nothing new to build.

**Phase.** 5 (one line in the dispatcher's role prompt).

### 4.5 Fencing

**HDFS.** Before the standby goes active, it runs the fencing methods
(`sshfence`, a shell command). If fencing fails, the transition does not
happen. Never two actives.

**Ours today.** None. The old machine stands its agents down only when its
own loop rewrites the local mirror `lease.orch`, or when that mirror is over
180 s old, and only if the agent reads the file and obeys. The orch lease
moved at 18:32:19Z (`FLEET orch: c-001@box-desk -> c-001@sat`); the box PC's
orchestrator had not seen it and spawned lanes from 18:32Z to 18:35Z. The
spawn and send paths never read the lease:
`grep -c 'lease\.orch\|if-gen'` on `spawn-core.inc.sh`, `spawn-claude.sh` and
`spool-send.sh` -> 0, 0, 0.

**Gap.** Standing down is voluntary.

**Implementation (M2 + M4).**
- **[software]** `spool fleet act-ok --role <r>`: refuses unless the local
  mirror names this agent's id and box, carries the current gen and is at
  most 180 s old. The spawn scripts, `spool-send.sh` (when sending as the
  role) and `asks.sh` (ack, close) call it first. The agent cannot forget the
  rule; the script refuses for it. Lane agents hold no role and skip it.
- **[software]** The fence wait: after winning a take-over (not a renewal),
  the new machine mirrors itself active only once the old row is 360 s old on
  the hub's clock. By then the old machine's mirror is stale, so its `act-ok`
  refuses even if its loop is dead. Cost: up to 3 more minutes of failover.
  Gain: no double spawns.
- **[agent]** Nothing. The old orchestrator only sees refusals.

**Phase.** 1, with 4.6 and 4.11.

### 4.6 Epoch numbers

**HDFS.** Each new active gets a higher epoch. A JournalNode that promised
epoch N refuses every write from below N, so a zombie active is harmless even
when fencing fails.

**Ours today.** The hub row has `gen`
(`csi-spl-rdb/src/sql/postgres/spool-hub/0094_fleet_leases.sql:22`), and only
the lease writes check it. The local mirror is `<ID>@<box> <epoch>`
(`spl_fleet_apply`), so no role action knows the gen.

**Gap.** Nothing downstream can tell a stale holder's action from a current
one.

**Implementation (M3).**
- **[software]** The mirror carries the gen: `<ID>@<box> <epoch> <gen>`.
  Readers that split on spaces keep working.
- **[software]** `act-ok --gen <n>`: an action records the gen at its start
  and passes it at each guarded step, so an action that straddles a take-over
  is refused at its next step.
- **[software]**, later: ask ack/close send the gen, and the hub refuses one
  below the row's. Not in the minimum set: it is a hub change, and `act-ok`
  already covers the box.

**Phase.** 1.

### 4.7 Quorum: a third witness

**HDFS.** Two NameNodes never decide between themselves. The lock lives in a
ZooKeeper quorum of 3 or 5, and QJM needs a majority of 2N+1 JournalNodes.
Two nodes alone cannot tell "the other is dead" from "the link is cut".

**Ours today.** The two machines never vote with each other. The hub is the
witness, and its clock stamps the row (spec 4.1). The machine that cannot
reach it loses: the box PC logged `HUB-UNREACHABLE` (a DNS timeout) about 30
times from 15:13Z to 17:05Z, and the dispatch role went to `none@unreachable`
at 15:50:42Z, the self-demotion working as designed.

**Gap.** None in the shape. A hub outage means nobody renews and both roles
go to `none`, which is safe.

**Implementation.**
- **[software]** Keep the hub as the single witness. No ZooKeeper: the hub
  already sits on a managed database, and a second consensus system costs
  more than an hour with no orchestrator.
- **[software]** One test: both machines cut off from the hub end at `none`,
  never both active.
- The box PC's DNS timeouts are an ops issue, tracked separately.

**Phase.** 4, with 4.13.

### 4.8 No automatic failback

**HDFS.** The ZKFC never fails back. A recovered NameNode joins as standby.
Switching back is a deliberate, graceful operation.

**Ours today.** Instant handback by `LEASE_PRIORITY` (spec 4.1). The result
is flapping: `FLEET dispatch: box-desk takes over from CLE-002@sat (silent
2s, rank 2 -> 1)` at 15:18:59Z, and the same at 15:34Z, 15:51Z, 16:01Z and
16:34Z, while the box PC could not reach the hub. The orch lease failed over
to the satellite at 18:32:19Z and came back 3 minutes later (18:35:26Z), to
the machine that had just failed.

**Gap.** A handback is a forced take-over with no fence and no handoff, made
when the preferred machine is least proven.

**Implementation (M6).** Keep the priority (the box PC leads while it is
on), but take back only when proven, and only gracefully:
- **[software]** `spool fleet run` keeps an "able since" time per role: the
  first tick the local candidate was able and the hub reachable, reset on any
  failed tick. The priority takes back only after `LEASE_FAILBACK_HOLD`
  (1800 s).
- **[software]** The handback runs the graceful path of 4.9, not a bare CAS.
- **[software]** `LEASE_FAILBACK_HOLD=0` keeps today's behaviour;
  `LEASE_FAILBACK=manual` turns failback off, as in HDFS.
- **[agent]** Reading the handoff file and carrying on.

**Phase.** 3 (the stopped c-039's branch is the start).

### 4.9 Graceful vs forced failover

**HDFS.** `hdfs haadmin -failover` asks the active to go standby first, then
makes the other active. Fencing runs only if that fails. Planned and crash
paths are separate.

**Ours today.** Both paths exist. Forced: the fleet loop. Graceful: the
hourly rotation (spec 4.4,
[specs/060-role-rotation/spec.md](../../specs/060-role-rotation/spec.md)):
quiesce, handoff file, spawn, ack, retire. The graceful path is what broke:
`FAIL HOLD: the lease did not move to CLE-003 in 240s (it is c-003@box-desk)`
at 17:19:05Z and 18:19:05Z. The rotation waited for the old id while the
lease named the new one. The same split shows in `NO-LOCAL-AGENT orch: ...
(CLE-001: no live process)` at 18:29:14Z while `c-001` ran: `lease.conf` still
says `LEASE_ORCH=CLE-001`.

**Gap.** Two names for one agent break both paths: the graceful one fails,
and the forced one can fire on a healthy agent.

**Implementation (M1).**
- **[software]** One id per agent in `lease.conf`, the lease row, the window
  name and the rotation (spec 061 L6). `do_spl_dispatch_check` reports a
  `LEASE_*` id with no live process of that id as a GAP.
- **[software]** The failback of 4.8 reuses the rotation's steps: one
  graceful path, tested once.

**Phase.** 0: c-036 (one id + L6), running now.

### 4.10 Data side: heartbeats and re-replication

**HDFS.** Each DataNode heartbeats every 3 s. Silent for about 10 min = dead,
and its blocks are copied elsewhere automatically.

**Ours today.** The parallel is a lane agent's work, not data. An ask acked
by an agent that then goes quiet is released after `ASKS_LOCK_MIN` (60 min)
and raised again (spec 4.3). A lane that dies mid-task has no such rule.

**Gap.** A dead lane's task waits until someone notices.

**Implementation.**
- **[software]** `spool fleet run` lists lanes in `registry.tsv` whose
  process is gone and whose branch is not on trunk, and raises one ask per
  lane to the orchestrator: "c-NNN died with unlanded work on <branch>".
- **[agent]** The orchestrator decides: respawn from the branch, or close.

**Phase.** 5.

### 4.11 Data side: safe mode at start-up

**HDFS.** A NameNode starts read-only until enough block reports have
arrived, so it never acts on half-known state.

**Ours today.** A new holder is told `ACTIVE` and starts at once, with the
handover blocker in its inbox (spec 4.3).

**Gap.** It can act before it has read what it inherited.

**Implementation.**
- **[software]** After a take-over, `act-ok` refuses spawns until the new
  holder has acked the handover blocker (one `spool ask` read), or 10 min
  have passed. Owner posts and ask closes stay allowed.
- **[agent]** Reading the hand-over list: judgement.

**Phase.** 1 (one more rule in `act-ok`).

### 4.12 Data side: checksums

**HDFS.** Every block has a checksum, checked on read and by a background
scanner.

**Ours.** The parallel is the lease mirror files. A half-written mirror
reads as no holder. `spl_fleet_apply` already writes a temp file and renames
it, which is the right guard. **No change.**

### 4.13 Failure is normal: drill it

**HDFS.** The design assumes nodes fail all the time, and the HA docs ask
operators to test failover before relying on it.

**Ours today.** `csi-spl-orc/src/bash/tests/fleet-lease.tst.sh` simulates two
machines (section 15: stuck, busy, control, dead). Spec 4.1's status says the
live drill follows the satellite rebuild. Every failover on 2026-10-02 was
unplanned.

**Implementation.**
- **[software]** `spool fleet drill` (wrapper `do_spl_fleet_drill`): put the
  holder on hold with the existing `rotate.hold`, measure the time to the
  new holder, check that the old machine let no guarded action through in
  that window, release, and let 4.8 hand back. Weekly from cron.
- **[agent]** Reading the drill report when it is red.

**Phase.** 4, with 4.7.

## 5. Summary

| feature | ours today | poor man's change | who |
|---|---|---|---|
| 4.1 active / standby | trio per machine, one fleet lease | none | software |
| 4.2 leader lock | hub row, CAS on gen | none; Go loop later | software |
| 4.3 health monitor | process, pane, stuck rule (fails open) | ping each tick, `.pong` reflex | software + agent reflex |
| 4.4 shared log | ask book for blockers and tasks | forwards of requests carry `--ask` | agent decides, software records |
| 4.5 fencing | none | `act-ok` on every role action + 360 s fence wait | software |
| 4.6 epochs | gen on the hub row only | gen in the mirror, checked by `act-ok` | software |
| 4.7 quorum | hub as witness; self-demotion | keep; add both-unreachable test | software |
| 4.8 no auto failback | instant handback, flapping | 30 min able + graceful handback | software |
| 4.9 graceful vs forced | rotation broken by id split | one id; failback reuses rotation | software |
| 4.10 re-replication | asks re-raised; dead lanes not | dead lane = one ask | software finds, agent decides |
| 4.11 safe mode | new holder acts at once | no spawns until hand-over acked | software |
| 4.12 checksums | atomic mirror writes | none | software |
| 4.13 drill | simulated only | weekly `spool fleet drill` | software |

## 6. Which process runs each feature

| feature | process | where |
|---|---|---|
| 4.2 leader lock, 4.3 health (pinger + verdict), 4.8 failback hold-down, 4.10 dead-lane asks | `spool fleet run` (long-running, one goroutine per job) | both machines, natively (user systemd unit as the agent user) or one container |
| 4.5 fencing, 4.6 epochs, 4.11 safe mode | `spool fleet act-ok` (one-shot, exit code) | wherever a role action runs: called by the spawn scripts, `spool-send.sh`, `asks.sh` |
| 4.9 graceful hand-over | the rotation actions (bash, as today), started by `spool fleet run` for a failback | both machines |
| 4.13 drill, 4.7 both-unreachable test | `spool fleet drill` (one-shot) + `fleet-lease.tst.sh` | cron, weekly, on the lease holder's machine |
| 4.4 requests as asks | `spool-send.sh --ask` (exists) | the dispatcher's forward |
| 4.1, 4.12 | no new process | - |

## 7. Build order, once approved

Each phase lands and is proven live before the next starts. c-036 (one id +
L6 + satellite relay) is not a phase: it fixes today's breakage and carries
on now. The standby take-over (c-039) and pokes-by-pane (c-040) lanes were
stopped before landing; their findings and branches are the starting point
of phases 2 and 3.

| phase | builds | features | why this order |
|---|---|---|---|
| 0 | one id everywhere (c-036, running) | 4.9 (M1) | every other rule matches on the id; today's two false verdicts came from the split |
| 1 | `spool fleet act-ok` + its callers, gen in the mirror, fence wait, safe mode | 4.5, 4.6, 4.11 (M2-M4) | closes the 18:32Z double-actor case; cheapest, and protects every later phase |
| 2 | pokes by pane, then the ping health check | 4.3 (M5) | the ping is only as good as its delivery |
| 3 | failback hold-down + graceful failback | 4.8 (M6) | stops the flapping; needs phase 0's working rotation |
| 4 | `spool fleet drill` + the both-unreachable test | 4.7, 4.13 | proves phases 1-3 live, then weekly |
| 5 | `spool fleet run` replaces the bash loop; dead-lane asks; `--ask` forwards | 4.2, 4.10, 4.4 | a port, once the rules are settled and tested |

## 8. Questions for the owner

Each needs a yes, a no or a number before its phase starts.

1. **Approve the shape?** Software = small Go processes in the existing
   `spool` CLI (`spool fleet run | act-ok | drill`), on both machines;
   agents only judge. Yes / no.
2. **Native or container** for `spool fleet run`: a user systemd unit as the
   agent user (simplest, sees tmux directly), or one compose service with the
   spool root and the tmux socket mounted? Proposed: native.
3. **Fence wait (4.5):** a take-over waits until the old row is 360 s old
   before acting, so failover takes up to ~6 min instead of ~3. Accept?
4. **Failback (4.8):** hold-down of 30 min, then a graceful handback; or no
   automatic failback at all (`manual`, as in HDFS)? Proposed: 30 min.
5. **Witness (4.7):** keep the hub as the only witness (a hub outage = no
   orchestrator anywhere, safely), and no ZooKeeper-style quorum? Proposed:
   yes.
6. **Safe mode (4.11):** a new holder may not spawn until it has acked its
   hand-over list (or 10 min pass). Accept?
7. **Build order (section 7):** phases 0-5 as listed, one at a time?
8. **Draft swap (4.3, phase 2):** may the poke clear a stale one-line
   draft in an agent's input box, submit, and type the draft back (guards:
   unchanged 60 s, one line, cursor after the text)? Or alert only?
9. **Who hears "orchestrator is DEAF"** (and the stuck take-over): the
   dispatch holder (an agent, today), or the owner directly by desk DM?
10. **Stuck rule for dispatchers too?** Condition 2 covers only the
    orchestrator today.
11. **Heartbeat by hook (4.3):** replace the TUI-spinner "idle" signal with a
    hook-written heartbeat file, and publish it to the hub so the standby can
    decide remotely when the holder's own loop is down?

<!-- version: 0.1.0 · updated: 2026-10-02 · last-edit: 2026-10-02T22:00:00Z -->
