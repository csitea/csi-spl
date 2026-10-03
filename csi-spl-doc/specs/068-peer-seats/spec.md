# 068: four peer seats - every seat dispatches and orchestrates

Status: **draft for the owner, Q1..Q6 open** (section 9). Spec only: no code,
no `lease.conf`, cron, table or seat was touched by this lane.
Draft 2026-10-03, c-098.
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
waited. The fix is to choose the actor per ITEM, among four peers, and to
let progress (or its absence) move the item.

## 2. Words

| word | means |
|---|---|
| **peer** / **seat** | one of four agent sessions, each a dispatcher AND an orchestrator. "Seat" is the slot (number, home box, harness); "peer" is the session in it |
| **item** | anything a peer must act on: a human post delivery, a report or ask addressed to `orchestrator`, an unanswered-sweep finding, a lane's owner text |
| **claim** | a hub row that says which peer acts on an item, until when. Keyed by the item's `msg_id` |
| **lock** | a claim's `lock_until` (hub clock). Renewed by the holder; past it, any peer may take the item |
| **fence** | the claim's `gen`. A peer re-checks it (CAS) immediately before an outward action (a post, a spawn, a prd call) |
| **mutex** | a short named lease in the existing `fleet_leases` table (`role` = `spawn`, `prd-<target>`, `fleet-config`), for the few shared resources that need ONE actor at a time |
| **able** | the existing check `spl_lease_agent_able` (process, pane stall, rotate hold, stuck-unread rule) |

## 3. Decision 1: the seats

### 3.1 How many per machine

| option | one dead peer | one machine gone | one LOGIN at its limit (F2) | seats with the PC off (064's normal) |
|---|---|---|---|---|
| A. 4 on sat | survives | **does not** | only if harnesses are mixed | 4 |
| B. 3 on sat + 1 on the PC | survives | survives while the PC is on | only if mixed | 3 |
| **C. 2 on sat + 2 on the PC (recommended)** | survives | survives while the PC is on | survives if each machine mixes harnesses | 2 |
| D. 2 + 2, floating (an absent machine's seats respawn on the other) | survives | survives always | survives if mixed | 4 |

**Recommendation: C, each machine running one claude and one grok seat.**
F2 shows the frozen thing is a LOGIN, not a machine: diversity of quota buys
more than a count of seats, and two seats on two quotas keep sat working with
the PC off. D is the next step only if C measures a gap (moving a seat is a
spawn on a shared resource, section 5); it is not needed to remove the single
point of failure.

### 3.2 Ids

Spec 061 reserves 001..003 on EVERY box, so a bare `c-001` means "this
machine's", and the hub refuses it across machines (`ambiguous_to_box`).
Peers must be addressable fleet-wide, and the harness letter is part of the
grammar (`^[acgq]-[0-9]{3}$`).

| option | ids |
|---|---|
| a. keep per-box 001..003, add 004 | `c-001@sat`, `c-002@sat`, `c-001@<pc box>`, ... - two sessions per number |
| **b. seat numbers 001..004 fleet-wide, letter per harness (recommended)** | `c-001@sat`, `g-002@sat`, `c-003@<pc box>`, `g-004@<pc box>` |

**Recommendation: b.** One number = one seat in the whole fleet, so a bare id
is never ambiguous. 004 leaves the rolling pool (061 section 3.5) the way
001..003 did; 001..004 are claimed with `--claim`, never allocated.

### 3.3 Harness and model

Owner split earlier today: claude 40 / grok 50 / agy 10. **Peers may be
mixed, and should be** (F2, F6): a seat is defined by what it must be able to
run, not by its harness. A harness is fit for a seat when it passes the seat
drill (lane L7): `spool recv`, `spool claim`, `do_spl_ask_ack` /
`do_spl_ask_close`, `do_spl_post`, a spawn dry run. Recommended start: 2
claude + 2 grok (one of each per machine); agy is not seated until it passes
the drill.

## 4. Decision 2: who does what without an orchestrator

### 4.1 Every item is fanned out, then claimed by exactly one peer

| option | how one peer is chosen | dead peer | duplicate risk |
|---|---|---|---|
| a. one router peer by lease (today's dispatcher) | the lease | 180 s + tick, for all items | low, but F1..F5 |
| b. owner = `hash(msg_id) mod live peers` | a hash over a membership view | its items wait until the view changes | two views during a change = two owners |
| **c. hub claim per item: the ask book's `ack`-as-lock extended to every item (recommended)** | the first `claim` CAS on the hub wins | its claims release on silence (4.3) | none: one row, one winner |
| c + b's hash as a **head start** only | the hashed peer may claim at once, the others after `CLAIM_GRACE` (30 s) | the grace, then anyone | as c |

**Recommendation: c with the head start.** It is the ask book (fleet-roles
4.3, rdb 0097) generalised: the same idempotent producer keyed by `msg_id`,
per-record commit, lock + timeout and dead-letter. The head start spreads the
load over the four peers without making the hash authoritative.

- **Fan-out.** A web post delivery, a report `--to orchestrator`, a sweep
  finding and an ask each reach ALL seated peers (`--to orchestrator`
  becomes `--to peers`). A peer that sees an item another peer holds
  archives it: no reply, no forward.
- **Claim.** `spool claim --msg <id> --as <seat>` = one SQL statement:
  insert the row if absent, or take it when `state = open`, or `claimed`
  with `lock_until < now()`, or `claimed` by a gone peer (4.3). The winner
  gets `gen`; a loser gets `won=false` with the current holder, as the lease
  `cas` answers today.
- **Lock.** `CLAIM_LOCK` 10 min for routing items, 30 min for a decision,
  renewed with `spool claim --renew`. A peer that stops renewing loses it.
- **Close.** `done` / `declined` (reason) / `handed` (forwarded to a lane,
  naming it). A close by a non-holder is refused naming the holder.
- **Delivery count and dead-letter.** `claim_n` counts every take. At
  `CLAIM_MAX` (4) the item goes to the owner once and closes `dead`, the ask
  book's rule.
- **Harness refusal (F6).** A peer whose harness refuses a step releases the
  claim with `--reason harness-refused:<step>`; the item records the harness
  in `not_by`, so the next claim must come from a different harness. An item
  never waits on one harness's policy again.

### 4.2 Two peers never both answer

| action | guard |
|---|---|
| a post visible to humans (an answer, an owner text, a status) | the post carries `answers=<msg_id>`; the hub keeps a unique index on `(tenant, answers)` for agent posts, so a second answer to the same item is refused 409 naming the first. Idempotency key = the item's `msg_id` |
| a forward to a lane | `close --handed <lane>` is a CAS on the holder; the forward is sent only after it wins |
| spawn, close a lane, a prd action | fence: re-check the claim's `gen` (and the mutex, section 5) immediately before the call. A peer that lost the claim while it was thinking stops |

### 4.3 Peer liveness: progress, not a process

Each machine's existing 60 s loop (`do_spl_dispatch_lease LEASE_CMD=fleet`,
renamed `do_spl_peer_tick`) writes ONE heartbeat row per local seat to the
hub: `fleet_peers (seat, box, harness, able, why, last_seen)`, `last_seen` on
the hub clock. `able` is today's `spl_lease_agent_able`. The hub treats a
seat as **gone** when `last_seen` is older than `PEER_DEAD` (180 s) or its
last tick said `able=false`; a gone seat's claims are takeable at once,
without waiting for `lock_until`.

F4 shows `able` can be wrong in the "able" direction. The lock is the
backstop: a peer that looks able but makes no progress stops renewing and
loses the item at `lock_until`. No item depends on the able check being
right.

## 5. Decision 3: what still needs ONE decider

| item | needs one decider because | options |
|---|---|---|
| spawning / closing a lane | the 40-window ceiling is a count: two peers spawning at once overshoot it, or both spawn for one ask | a. per-item claim only; **b. per-item claim + mutex `spawn` (recommended)**; c. consensus |
| a prd action (a deploy the owner pre-approved, prd desk / issue writes, prd reads a harness refuses) | two deploys of one target race | a; **b. claim + mutex `prd-<target>`**; c |
| an owner text (a lane asks "post this in topic X") | must appear once | **a. per-item claim + the `answers` index (4.2)** |
| a fleet config change (seats, `lease.conf`) | F5: a half-applied config flapped the fleet for 3 h | **b. mutex `fleet-config` + one action that writes every machine or none** |

**Recommendation: the per-item claim decides WHAT; a 120 s mutex decides
WHEN, and only for these shared resources.** The mutex is the existing
`fleet_leases` row and `lease cas` frame under a new `role` name: no new
primitive. Its holder renews it while the action runs and releases it after;
a dead holder's mutex expires in 120 s.

Consensus (3 of 4 agree) is rejected: with the PC off (064's normal) only 2
seats exist, and with one of them frozen (F2) no quorum is possible - the
exact case this spec exists for. Claim + mutex survives one dead peer and one
frozen machine: any one able peer can take every item.

## 6. Decision 4: rotation and the lease under peers

| piece | kept | removed |
|---|---|---|
| fleet lease roles `orch` and `dispatch` (fleet-roles 4.1) | the `fleet_leases` table and `lease cas` frame, reused for the mutexes | the two roles, `LEASE_ORCH` / `LEASE_MASTER` / `LEASE_FAILOVER`, the ranking (`LEASE_PRIORITY*`, `do_spl_lease_rank`), take-over and handback, the `lease` and `lease.orch` mirror files, the owner DM per take-over |
| master / failover renew + watch loops (4) | - | all: no master, no failover |
| the able check (4) and the stuck-unread rule (4.1 condition 2) | kept, per seat, feeding the heartbeat | - |
| ask book (4.3, rdb 0097/0099) | kept: its rows become the claim table's `kind in (blocker, task, escalation)` | role `orch`, the hand-over blocker to a new holder (there is no holder), re-raise to ONE holder (a re-raise = release + fan-out to every able peer) |
| unanswered sweep (3.2) | kept, on every machine | "a standby machine sends nothing": every machine inserts its findings as claim rows keyed by the topic's last `msg_id`; the second insert is a no-op |
| `--to orchestrator` (4.2) | the word, as an alias | the lease lookup: it means `--to peers` |
| rotation (060) | hourly per seat, the handoff file (060 section 6, minus its lease lines), the mechanical script, "keep the old session if the new one fails" | the dispatcher HOLD choreography (060 5.2), `rotate.hold`, the orch-first order. Seats rotate staggered, seat N at `:05 + 15*(N-1)` (`:05`, `:20`, `:35`, `:50`), so at most one seat rotates at a time. A rotating seat first reports `able=false` (`why=rotating`) and releases its claims; the other three cover |

## 7. Decision 5: failure table

Max delay = from the failure until another peer holds the item, on the hub
clock. `CLAIM_GRACE` 30 s, tick 60 s, `PEER_DEAD` 180 s, `CLAIM_LOCK` 10 min.

| failure | what each peer does | max delay |
|---|---|---|
| one peer dead (process gone) | its machine's tick stops its heartbeat; at 180 s the hub marks it gone; the next claim by any other peer takes its items. Its new items: the others claim after the 30 s grace | held items: 180 s + 60 s = **4 min**; new items: **30 s** |
| one peer stalled but alive (usage limit, modal screen, stuck) | its tick reports `able=false`: its items are takeable at the next tick. If the check misses it (F4), it stops renewing and loses each item at `lock_until` | **60 s** when detected; **10 min** (the lock) when not |
| one machine frozen (VM gone, or every seat on it at its quota) | its heartbeats stop; the other machine's peers take everything, as for a dead peer. With mixed harnesses (3.1) a quota freeze hits one seat per machine, not all | **4 min** |
| one login at its limit fleet-wide (every claude seat) | the grok seats carry everything; `not_by` routes harness refusals | **4 min** |
| hub down | no claims, no web deliveries, no relays. Each machine falls back to a local claim, an `O_EXCL` create of `<spool root>/claims/<msg id>` among its own seats, for local-origin items only (terminal reports, local asks). No cross-machine duplicate is possible, because nothing crosses machines without the hub. On recovery each local claim is pushed as a row, insert-if-absent by `msg_id` | local items: **30 s**; web posts: until the hub is back (they cannot arrive) |
| split brain (one machine reaches the hub, the other does not) | the hub is the only arbiter, so there is one view. The cut-off machine's heartbeats stop and its items move to the other machine after 180 s. Its peers may still think they hold items, but every outward action is fenced (4.2): a post, spawn or prd call re-checks the claim on the hub, cannot, and stops. A peer that cannot reach the hub for over 180 s drops its hub claims locally (today's `unknown:hub-unreachable` rule) | **4 min** |
| a peer's desk sidecar cannot send (F7) | the post fails; the peer releases the claim `--reason send-failed`; a peer on the other machine takes it and posts through its own sidecar | **60 s** |
| a config change half-applied (F5) | cannot flap: there is no ranking left to disagree on, and config goes through the `fleet-config` mutex and one all-machines action (section 5) | - |

## 8. Decision 6: migration in small, disjoint lanes

Today c-001 orchestrates and c-002 / c-003 dispatch on each box, under the
fleet lease. The cut-over first runs the peers in **shadow**: they claim and
log what they WOULD do, the old roles still act, and a report compares the
two. Only then are the old roles switched off.

| lane | scope (files) | test |
|---|---|---|
| L1 hub: claim table | the next free rdb migration (`fleet_claims`: tenant, fleet, `msg_id` key, kind, origin, state `open/claimed/done/declined/handed/dead`, holder, gen, lock_until, claim_n, not_by, reason, hub-clock times); store memory + Postgres; box frame `claim` (`get/claim/renew/release/close`); CLI `spool claim` | `TestFleetClaimCAS` (memory + Postgres: a race of 4, lock expiry, a non-holder close refused, dead-letter at 4, `not_by`); `TestBoxFleetClaim` (two boxes) |
| L2 hub: peers + answer once | `fleet_peers` heartbeat and the gone rule; unique `(tenant, answers)` on agent posts | `TestFleetPeerGoneReleases`; `TestAnswerOnce` (two peers answer one post: one 200, one 409) |
| L3 orc: peer tick | `do_spl_peer_tick` (heartbeat from `spl_lease_agent_able`, the local claim fallback), beside the old loop, shadow only | `peers.tst.sh`: 4 simulated seats on 2 machines against a hub stub: dead peer 4 min, stalled peer 60 s, an undetected stall 10 min, hub down, the split-brain fence |
| L4 orc: fan-out + `--to peers` | `spool-send.sh`, `asks.sh` (role `peer`, re-raise = release + fan-out), the unanswered sweep into claims | `test-fleet-send.sh` and `asks.tst.sh` extended: one item, 4 peers, exactly 1 claim, 3 archived |
| L5 orc: mutexes + fence | the spawn launchers and the prd wrappers take `spawn` / `prd-<target>` and re-check the fence; `do_spl_fleet_config` writes every machine or none | `spawn-mutex.tst.sh`: two peers spawn at once, one spawns; a lost fence stops a deploy |
| L6 orc: rotation per seat | `do_spl_peer_rotate`, staggered `:05/:20/:35/:50`, drain then spawn; 060's handoff kept | `peer-rotate.tst.sh`: a rotating seat's claims move; never two seats rotating |
| L7 seats + drill | `do_spl_peer_setup` (claims 001..004, the harness per seat, seats on every desk); the live drill: kill one peer, SIGSTOP one machine's seats, measure each delay of section 7 (n >= 5 each) | the drill log vs section 7 |
| L8 doc | rewrite SPEC-spool-fleet-roles.md sections 1, 3, 4, 4.1, 4.3, 4.4, 7 | `do_check_dist_hygiene` |
| L9 cut-over + delete | after L7's drill: the peers act, the old roles stop | `fleet-lease.tst.sh` retired with what it tested |

L1 and L2 touch only the hub; L3..L6 touch disjoint orc files; L8 only docs.
L3..L6 need L1's frame; L7 needs them all; L9 is last.

**Deleted in L9:** the renew / watch loops and the role logic of
`LEASE_CMD=renew|watch|fleet`, `LEASE_MASTER` / `LEASE_FAILOVER` /
`LEASE_ORCH` / `LEASE_PRIORITY*`, `do_spl_lease_rank`, the `lease` and
`lease.orch` mirrors, `rotate.hold` and the dispatcher rotation phases (060
5.2), the ask hand-over blocker, the `orch` / `dispatch` rows of
`fleet_leases` (the table stays for the mutexes), and the role table of
fleet-roles section 1 (c-001 / c-002 / c-003 as distinct roles).

## 9. Owner questions

Each answerable with one word.

1. Seats: 2 on sat + 2 on the PC (yes), or all 4 on sat (no)?
2. Mixed harnesses: 2 claude + 2 grok, one of each per machine (yes / no)?
3. Seat numbers 001..004 unique across the whole fleet, letter per harness (`c-001@sat`, `g-002@sat`, `c-003@<pc box>`, `g-004@<pc box>`) (yes / no)?
4. May a grok peer spawn and close lanes under the claim + mutex (yes), or only claude peers (no)?
5. May a grok peer run the pre-approved prd actions under the claim + mutex (yes), or only claude peers (no)?
6. Shadow-run the peers for 24 h before switching the old roles off (yes), or switch directly (no)?

<!-- version: 0.1.0 · updated: 2026-10-03 · last-edit: 2026-10-03T12:30:00Z -->
