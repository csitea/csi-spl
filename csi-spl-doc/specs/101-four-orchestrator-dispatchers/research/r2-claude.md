r2-claude: a claude seat standing in for the panel's agy/grok seat (agy has no binary on sat; grok is at its weekly limit).

# 101 review r2: does exactly one OD decide each item? (partition and lease correctness)

Reviewer c-389, 2026-10-06. Reviewed spec 101 v0.1 (`366acebe`), then re-read
against v0.2 (`56783cf5`, r3 folded: its D5..D9). Mine are numbered D10..D13
so they do not collide; section 8 maps them onto r3's. Every claim about a file
cites the command that shows it. One measurement: `go test ./internal/store/
-run 'Claim|Round|Lease|Answer' -count=1` in `csi-spl-api/src/go/spool-hub-api`
-> `ok` (tree `ccd87045`, n = 1 run). Those tests cover the store's state
machine. They do not cover anything below, because every finding below is
about what happens **between** the store and the action.

## 0. Verdicts per section of spec 101 v0.1

| section | verdict | why (detail in the sections below) |
|---|---|---|
| 1 finding (068 + 093 is the design) | **agree** | the store is what 101 says it is (2.1) |
| 2 words | agree | - |
| 3 partition, option d | **change** | d is exclusive per **message**, but the brief asks for per ask, topic and lane. Two messages of one topic or one task can have two owners at once (3.1). Add D10 (topic guard in the accept) and D11 (spawn intent before spawn) |
| 4 lease model, D1 | **agree with D1**, **change** | D1 is real (`role_group.go`, checked). Add: the mutex has no release (4.2). The interim fleet lease (M0..M4) is not a fence (5) |
| 5 prd, D2 | agree | it is routing, not exclusion; prd exclusion is the mutex plus D12 |
| 6 takeover | **block until D12** | the seat restart and the watchdog takeover SPAWN the new session before they RETIRE the old one. For up to 330 s, two sessions carry one seat. The fence names the seat, not the session, so both pass it (3.3) |
| 7 rotation, asks | change | the same overlap as section 6, four times an hour per box |
| 8 migration, D3 | **agree with D3**, change | add D13 (one msg_id on both legs of a peers send) to M1. M0..M4 run on the old lease, which has a double-act window (5) |
| 9 deltas | agree D1..D4 and r3's D6..D9; **refine r3's D5** (8); **add D10..D13** | sections 6 and 8 |
| 10 owner questions | agree | none of D10..D13 needs the owner: they are build items inside 068/093's own scope |

## 1. What "exactly one OD decides" has to mean

The property to prove, **P**: for every item X (a message, a topic, a lane,
a prd target), at every moment there is at most one session whose outward
action on X can take effect.

Outward actions fall into two classes, and they need different proofs:

| class | examples | where it takes effect |
|---|---|---|
| **H**, hub-committed | a post, an answer, a forward, `--done`, a park | inside a hub statement, so a guard in that same statement can stop it |
| **L**, local side effect | a spawn (tmux, worktree), killing a lane, a gcloud or deploy call | outside the hub. The hub can only be **asked** beforehand (check-then-act) |

A lease or a claim on its own gives one *holder of a row*. It gives P only
if every action re-checks the token **atomically with the action** (class H),
or if the action is idempotent on a key the hub already holds (class L).
That is the standard fencing-token argument. Everything below applies it.

**Assumptions the proofs use**

- A1 Postgres row locks and `READ COMMITTED` re-check of an `UPDATE ... WHERE`
  (EvalPlanQual). The CAS statements rely on it.
- A2 One clock decides expiry. **It is not one clock today.** The hub stamps
  times with `s.o.Now()`, and `grep -n 'o.Now = time.Now' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go`
  -> 252. That is each Cloud Run instance's wall clock, not the database's
  `now()`. With two or more instances, one instance writes `locked_until` and
  another compares it. The skew is milliseconds, against 20 s / 120 s margins,
  so this is acceptable. But "the hub's clock" in 068/093/0094 is really N
  synchronised clocks, and the spec should say so as an assumption, not as a
  fact.
- A3 A process can pause for an unbounded time at any instruction: a SIGSTOP
  drill, a VM pause, a laptop suspend (092), swap. Spec 092 says power loss
  is routine, so A3 is the normal case and not an edge case.

## 2. Option d, layer by layer

### 2.1 The store: proven

| claim | proof |
|---|---|
| one accept wins a round | `roundAccept` requires `offered`, seat in `offer_set`, `offer_n = round`, window open (`grep -n 'm.Round.OfferN != a.Round' csi-spl-api/src/go/spool-hub-api/internal/store/message_claim.go` -> 594). Postgres runs it on the row read `FOR UPDATE` (`roundStep`, `message_claim_postgres.go` 354..359). The second accept re-reads `owned` and gets 0 rows |
| a holder call needs the current gen | `roundHolder`: `m.Responsible != a.Seat \|\| m.ResponsibleGen != a.Gen` -> refused (line 608) |
| an expired lock is never renewed | every call settles the row first (`roundSettle`, T5) |
| one answer per message, with no clock at all | `grep -nF 'WHERE r = $4 AND g = $5' csi-spl-api/src/go/spool-hub-api/internal/store/answer_once_postgres.go` -> 19, plus `ON CONFLICT (tenant_id, answers) DO NOTHING` |

**Answer-once proves P for posts that carry `answers=` on its own,
independent of A2 and A3.** The primary key decides. A late holder whose
lock expired but was never settled still matches `r`/`g`. That is harmless:
whichever answer commits first wins, and the other gets 409. This is the
strongest guarantee in the design. **Every H action should be shaped like it.**

### 2.2 Class L actions: not proven

`spl_peer_gate` is fence -> mutex -> fence, then the caller acts. It is
check-then-act. Two ways P breaks:

1. **Pause after the gate (A3).** Seat A passes the gate at t and pauses
   before `spawn-window.sh` runs. A's job lock runs out at
   `anchor + 120 s`. A's `spawn` mutex runs out at t + 120 s
   (`PEER_MUTEX_TTL`). Seat B accepts the next round, passes the gate and
   spawns. A resumes and spawns too. Neither fence nor mutex can see an action
   that has already been decided.
2. **Act, then die before recording it.** A spawns lane L, then its session
   dies before `--park --wait L` or `--done handed:L`. The lock expires, B
   accepts (`claim_n` 2), and nothing on the row says L exists. B spawns L'
   for the same task. **This is the 2026-10-06 duplicate-spawn failure under
   the new design.** v0.1's 3.2 lists it as closed by "the claim, the fence,
   the `spawn` mutex", but none of the three closes it. The mutex serialises
   spawns 120 s apart. It does not deduplicate them.

Fix D11 (section 6): **record the intent on the hub first, then act
idempotently on the recorded key.**

## 3. Where per-message exclusion is not per-item exclusion

### 3.1 Topics and tasks: two messages, two owners

The claim unit is a `messages` row. The brief's units are an ask, a topic
and a lane.

- **The same task asked twice.** The owner's order today reached the fleet
  as at least two messages: c-002's relay and c-001@`<pc box>`'s note, both
  on task `cc7726e7`. Under d each is a separate job, so two seats can own
  them at once and each decide "spawn the panel". Nothing in 068/093 keys a
  decision by `task_id`.
- **Stickiness is a preference, not a guard.** 093 4.3 opens a follow-up's
  first round with `offer_set = {X}`, X being the topic's owner. If X does not
  accept within `OFFER_WINDOW` (20 s), the round lapses (T3) and the next round
  goes to other seats. X can be fresh and still miss it: X is inside one long
  tool call (a 10-minute test run fires no hook, so the inject hook only shows
  the stub after it). Seat Y then owns the follow-up while X still owns or
  parks the opening job of the same topic. A lane report from lane L
  ("done, close me?") is then decided by Y while X still waits on L. Two ODs
  decide on one lane.

Fix D10 (section 6): one predicate in the accept statement. `messages` already
has `task_id uuid NOT NULL` and an index on `(tenant_id, task_id, ts)`
(`grep -n 'task_id' csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql`
-> 60, 81), so the check is one indexed `NOT EXISTS`:

```sql
AND NOT EXISTS (SELECT 1 FROM messages o
                 WHERE o.tenant_id = m.tenant_id AND o.task_id = m.task_id
                   AND o.claim_state IN ('owned','parked')
                   AND o.responsible <> $seat AND o.locked_until >= now())
```

With D10, a topic has exactly one owner while any of its jobs is live: the
topic ownership argument rides on the same row locks as 2.1. Two
simultaneous first accepts on two different rows of one topic need the
topic's rows locked in a fixed order (lock the topic's open rows
`FOR UPDATE ORDER BY msg_id` before the check, or an advisory lock on
`hashtext(tenant||task_id)`), otherwise both `NOT EXISTS` checks see each
other's row as not yet owned. A non-sticky round for a row whose topic is
owned should not open at all (T1 skips it), so the follow-up waits for X
instead of lapsing away from it. The liveness cost: a follow-up waits up to
X's lock (`anchor + 120 s`) when X is dead. That is the same 125 s bound 101
section 6 already accepts.

### 3.2 Lanes

A lane has no row on the hub, so "one OD decides per lane" can only mean
"one OD owns the topic that spawned it". D10 gives that. D11 makes the lane id
visible to the next owner even when the spawning session died mid-step.

### 3.3 One seat, two sessions: the fence cannot tell them apart (blocks section 6)

The fence and answer-once compare `responsible = <id>@<box>` and the gen.
Both name the **seat**, not the session. 068 6.1 says so on purpose
("`responsible` names the SEAT, not the session").

The seat restart spawns the new session **before** it retires the old one:
`sed -n 202,215p csi-spl-orc/src/bash/run/spl-peer-restart.func.sh` shows
`spl_peer_restart_spawn` and then `spl_peer_retire`. The retire waits
`PEER_EXIT_WAIT` (300 s, `grep -n 'PEER_EXIT_WAIT:=' csi-spl-orc/src/bash/run/spl-peer-restart.func.sh`
-> 70) for `/exit-clean`, then `ROTATE_TERM_WAIT` (30 s,
`grep -n 'ROTATE_TERM_WAIT:=' csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` -> 58)
more. 093 8.1's takeover uses the same order
(`grep -n '| SPAWN |\|| RETIRE |' csi-spl-doc/specs/093-agent-watchdog/spec.md`
-> 461, 462).

So for up to 330 s, four times an hour per box, two live sessions hold seat X
at gen g:

- The old one is running `/exit-clean`, whose job is to land work and report.
- The new one is working from the handoff, which lists the same jobs.

Both pass the fence. Both can spawn. Answer-once saves the posts (first wins).
Nothing saves the L actions.

The takeover case is worse. A stall that clears on its own (a usage-limit
reset, a dismissed modal) brings the old session back with a full context,
just as the new one starts.

Fix D12 (section 6): **rotate the fencing token with the session.** Before the
new session starts, the restart or takeover makes one hub call that bumps
`responsible_gen` on every job the seat holds, and puts the new gens in the
seed. The old session's gen is then dead before the new one exists: its
fence returns "lost" and its answers 409. The old session still exits as it
does today. The order of SPAWN and RETIRE can stay, so the "keep the old
session if the new one fails" property of 060 D2 is kept: if the spawn fails,
re-bump and hand the gens back to the old session.

### 3.4 Box power loss and freeze (spec 092)

| case | outcome under d + D10..D12 |
|---|---|
| box off | its sessions are dead, so they cannot act. Locks pass `anchor + 120 s`, then T5. P holds trivially |
| box frozen, resumes later (A3) | `RenewMessageRounds` settles first, so an expired lock is never revived. The resumed session's next fence returns "lost". Its next H action is refused by gen or answer-once. Its L action **already in flight** is covered only by D11. P holds with D11, and not without it |
| box back, stale local files | `claims/*.accept`, inbox stubs and `lease.orch` survive the cut. The hub row is the authority (093 4.5 archives stale stubs), and with the hub up no local file grants anything. The exception is 093 4.6: the local fence "reads the accept file", yet "hub unconfirmed is still exit 2: do not act". These two lines disagree. Pick exit 2 (safety): no local-only job acts until the hub confirms |
| hub unreachable from one box (split) | the fence returns 2 (do not act), and the mutex returns 6 (do not act). P holds. Liveness on that box stops, which is correct |

### 3.5 Hub-down leg of a peers send: one message, two rows (D13)

`spool-send.sh` sends to the peers by the hub leg first, and only if that
fails by the local inbox. Its comment says "so no message is ever both on the
hub and in the local lock" (`grep -n 'no message is ever' csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh`
-> 236). That holds only if a failed exit means "not committed". A relay that
commits on the hub and then loses the reply (a timeout after the commit, a
sidecar crash) exits non-zero. The local leg then mints a **new** id
(`grep -nF 'id="$(cat /proc/sys/kernel/random/uuid)"' csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh`
-> 138). The result is two rows with two ids, so the adopt step's
insert-if-absent cannot match them, and a seat on each side can own one.

Fix D13: mint the msg_id once, before the hub leg. Pass it to the relay and
reuse it in the local leg. Then the hub's primary key and `--adopt` deduplicate.

## 4. The lease and mutex primitive (`fleet_leases`, rdb 0094)

### 4.1 The CAS itself: proven

`INSERT ... ON CONFLICT DO NOTHING` for gen 0 and
`UPDATE ... WHERE ... AND gen = $7` for the rest
(`grep -nF 'AND gen = $7' csi-spl-api/src/go/spool-hub-api/internal/store/fleet_lease_postgres.go`
-> 75). By A1, at most one writer moves a given gen. That makes the row an
exclusive **record**. It does not make it a fence, because no action re-checks
`gen` (2.2, 5).

### 4.2 The mutex is never released

`grep -n 'The mutex is never released' csi-spl-orc/src/bash/run/spl-peer-gate.func.sh`
-> 18. A `spawn` mutex taken by seat A blocks every other seat for 120 s
after A's spawn. With four ODs that share one fleet-wide `spawn` row, the
fleet can spawn about once every 120 s per seat that is not the last holder.
That is a liveness cost, not a safety one, but it works against the owner's
reason for four ODs ("the bottleneck"). Two ways to fix it:

- a release op: CAS to an explicit free holder on the gen you won;
- D11's per-task idempotency. That makes the global mutex needed only for the
  40-window count, so its hold can be just the count-and-create step (a few
  seconds), released at once.

### 4.3 The hub does not enforce the lease rule

The hub accepts any CAS on a matching gen ("Which holder wins is the loops'
rule; the hub only makes the write atomic", `box_lease.go` header). So
take-over-only-when-stale, rank and hold-down live in each box's
`lease.conf`. A config that differs between boxes therefore produces a
legitimate-looking flap, which is 068's F5 (203 flips in 3 h). Today's M0
flip is exactly such a window: c-001 noted the flip order matters. 101's D3
(one action under `fleet-config`) prevents it for the cut-over. For the
mutexes it does not matter, because they have no rank.

## 5. The interim: M0..M4 still run on the fleet lease, which is not a fence

101 keeps the old roles until M4. Over those days P does **not** hold for
the orch role, for three reasons:

1. **A double-act window at takeover.** The standby takes over when the hub
   age exceeds `LEASE_STALE` (`grep -nF '(( FA > LEASE_STALE ))' csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`
   -> 1168), at its next 60 s tick. The old holder finds out only at its own
   next successful tick, and then only through a STANDBY **note** that its
   agent must read. "Finish the message in hand" is explicitly allowed. While
   the old agent is stuck-but-alive (the condition-2 takeover), it acts the
   moment it wakes.
2. **The loop, not the agent, is what dies.** If the box's lease loop dies but
   the agent lives, nobody ever tells that agent STANDBY. The other box takes
   over after 180 s, and both act indefinitely. The self-demote
   `none@unreachable` (line 1211) runs only inside a live loop.
3. **`lease.orch` has no freshness check.** `spool_fleet_orchestrator` reads
   the holder and ignores the epoch (`grep -n 'read -r h _' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-fleet.inc.sh`
   -> 76). After a power cut, before the restarted loop's first tick, the old
   holder's box still resolves `--to orchestrator` to its own local c-001.
   That is the "results in the wrong orchestrator's inbox" failure.

None of these needs building if M4 lands quickly. If the interim runs for
more than a few days, add two cheap guards. (a) `spool_fleet_orchestrator`
treats a `lease.orch` older than `LEASE_STALE` as unknown and relays through
the hub. (b) The desk reconcile cron alerts when a box has a role agent but
no lease loop.

## 6. Deltas to add (D10..D13), all inside 068/093's scope

| id | what | where | closes |
|---|---|---|---|
| D10 | **topic guard in the accept**: refuse T2 while another seat holds a live owned or parked job of the same `(tenant, task_id)`. Lock the topic's open rows in msg_id order (or an advisory lock on the topic) before the check. T1 does not open a non-sticky round for a row whose topic is held | `roundAccept` / `roundOpen` + rdb (maybe an index on `(tenant_id, task_id) WHERE claim_state IN ('owned','parked')`) | 3.1: two ODs on one topic, task or lane |
| D11 | **intent before act, idempotent act**: before any L action the holder parks or touches the job with `wait_token = <lane id it is about to create>` (a gen-checked hub write). The spawn derives the lane id from `(task_id, slot)` and refuses when that lane or worktree already exists. The next owner inherits `wait_token` (T5 keeps it) | 093 T010 + `spawn-window.sh` + `spl_peer_gate` | 2.2: the duplicate spawn after a pause or a crash |
| D12 | **rotate the gen with the session**: the seat restart and the watchdog takeover bump `responsible_gen` on every job the seat holds BEFORE the new session starts, and seed the new gens. Re-bump to hand them back if the spawn fails | `spl_peer_restart_seat`, `do_spl_wd_takeover`, one hub op (`spool claim --rebind <seat>`) | 3.3: two sessions on one seat for up to 330 s |
| D13 | **one msg_id across both legs** of a peers send | `spool-send.sh` `send_peers_local` + the relay | 3.5: one message, two rows, two owners |

Also, wording rather than deltas:

- 101 section 3.1 row d: "prevented by the claim + the fence + the `spawn`
  mutex" should read "prevented by the claim per job (2.1), D10 per topic,
  D11 per lane".
- State A2 (the clocks) in section 6.
- Settle 093 4.6's local-fence contradiction as exit 2.

## 7. The proof, with D10..D13 in place

For any item X and any two sessions S1 != S2:

1. **X is a message.** At most one seat owns X per gen (2.1). D12 makes
   "seat at gen" identify exactly one session. An H action on X commits only
   inside a statement that re-checks seat and gen (holder calls), or under the
   answer key (posts). So no two sessions' H actions on X both take effect.
2. **X is a topic or task.** D10: while any job of X is owned or parked live by
   seat A, no other seat's accept on X succeeds. So the topic has one owner
   seat, and by 1 one session.
3. **X is a lane.** A lane is created only after its id is written to its
   topic's job under the owner's gen (D11). A second creation finds the id
   (idempotent) or the name taken. So at most one lane exists per
   `(task_id, slot)`, and by 2 one OD decides on it.
4. **Across a takeover.** The old seat's gen is dead before the new session
   exists (D12, for same-seat takeover). For cross-seat moves the old lock had
   expired (T5), so every old-gen H call is refused. An L call already in
   flight is idempotent (D11).
5. **Across a box power loss.** Off: no actor. Frozen and resumed: case 4.
   Hub cut: fence exit 2, no action (3.4). One message sent during the cut:
   one id, so one row (D13).

Without D10..D13, steps 2, 3 and the L half of 4 fail, by the counterexamples
in 2.2, 3.1, 3.3 and 3.5.

## 8. Against v0.2 (`56783cf5`): r3's deltas, and one claim to correct

| v0.2 item | r2 |
|---|---|
| r3 D5, the ask key `ask=<topic>:<slug>` checked under the `spawn` mutex | **covers 2.2 case 2** (act, then die), provided the check reads live lanes and not only the mutex row. **Does not cover 2.2 case 1** (a pause after the check): A checks (no lane yet), pauses past the 120 s mutex, B checks (no lane yet), and both create. The fix is D11's ORDER: write the key to the hub under the owner's gen (park, `wait_token`) BEFORE the create, so the second checker finds it. Merge D11 into r3's D5 rather than keeping both |
| r3 D5, "only the topic's owner instructs a lane" | the rule is right, but under 093 nothing enforces "the topic's owner": stickiness lapses after 20 s (3.1). D10 is the enforcement |
| M4: "two `c-001@sat` sessions cannot co-run, `spl_peer_pids`" | **does not hold for the restart path.** `spl_peer_pids` is the GATE's duplicate check. The restart itself then SPAWNS the new session before it RETIRES the old one (`sed -n 202,215p csi-spl-orc/src/bash/run/spl-peer-restart.func.sh`), for up to 330 s, and it logs "two sessions carry $id until a human clears it" when the KILL fails (`grep -c 'two sessions carry' csi-spl-orc/src/bash/run/spl-peer-restart.func.sh` -> 1). They do share one inbox. That is exactly why the fence cannot tell them apart. D12 stands, and it applies to M4's same-id hand-over too |
| r3 D6 (bare `c-00[1-4]` -> `peers`) | agree. It also closes section 5 reason 3 (stale `lease.orch` resolving locally) once M4 lands |
| r3 D7 (sweep stays through the soak) | agree. It is a liveness net and has no safety effect |
| r3 D8 (`PEER_SHADOW=1`) | agree, and it is safe by construction: no accept means no gen, so a fence and an answer can never pass |
| r3 D9 (060 rotations skip seat ids) | agree. Without it two restart paths would race on one id |

<!-- version: 0.2.0 · updated: 2026-10-06 · last-edit: 2026-10-06T18:25:00Z -->
