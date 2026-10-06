# 101 research, seat r1-grok-standin (claude standing in for grok: grok is at its weekly limit)

Reviewer 1 of the spec 101 panel (task `cc7726e7`). Brief: challenge whether 4
ODs are needed at all, price 4 live sessions, and list what the author leaves
unmeasured. This note reviews **spec 101 v0.1 (`366acebe`)**. Section 1 gives
a verdict per section. The evidence (E1..E12) and the cheaper option (R0..R5)
follow. The E ids are evidence rows, so that they do not clash with the
spec's migration steps M0..M6.

`<pc box>` stands for the PC's box tag (box tags are banned literals in this
tree, as in specs 064, 068 and 093).

## 1. Verdict on v0.1, per section

**The core finding stands.** A multi-decider fleet is 068 + 093, and a 101
that invented per-OD partitioned leases would build a third routing model that
093 P2 already plans to delete. I reached the same conclusion independently
before v0.1 landed (section 4).

**What v0.1 does not show** is that more deciders fix what the numbers show.
The measured shape (section 2) is an orchestrator with idle time that misses
its doorbells. Its queue is 82% dispatcher escalations that section 3 of
fleet-roles already says the dispatcher should not send. The box load is lane
load. v0.1's own table 3.2 closes today's four failures with routing (the
claim, `peers`, the spawner-first report), not with a count of seats.

| v0.1 section | verdict | what to change |
|---|---|---|
| 0 owner text, reading | agree | - |
| 1 the finding: 068 + 093 | **agree** | add one line: the build answers *"more orchestrators"*, but section 2 here shows the bottleneck is attention + routing; say which of the two v0.1 fixes |
| 1.1..1.3 trunk / live tables | agree, one addition | 093's hooks are on trunk but **not live for the OD seats on sat**: `ls <spool root>/c-001/heartbeat.json` -> no such file (17:2xZ). `wd-ensure` is the only peer/wd cron (`crontab -l \| grep -cE 'csi-spl:(wd\|peer)'` -> 1). So the inject hook (093 7.2), the one fix for the missed doorbell, is not running |
| 2 words | agree | - |
| 3 partition, option d | **agree** | - |
| 3.2 failure modes | change | add today's **fifth case**: two acting orchestrators already (E10: `c-001@sat` spawned 20 lanes while `lease.orch` named `c-001@<pc box>`). The panel itself was spawned that way. The cut-over (D3) has to cover human-relayed orders to a non-holder, or the claim fences everything except the actor that caused the duplicates |
| 4 lease model, D1 | **agree** | D1 is a real defect; it lands first |
| 5 prd, D2 | change | a harness's refusal is the auto-mode classifier judging each call, not a fixed property of the seat, so a capability recorded once by the drill goes stale. Keep D2 as the *first-round preference*, keep the refusal path (`not_by`) as the authority, and re-probe at every seat restart (hourly), not only at the drill |
| 6 takeover | agree | - |
| 7 rotation, asks, sweep | change | **keep the unanswered sweep through the M5 soak.** It is the one control that does not depend on the claim being right. Removing it with the claim means the only check that posts are answered runs on the mechanism under test. Delete it at M6 |
| 8.1 placement, option A | **change (near block)** | A puts four claude seats on **one box and one login**. That is 068's F2 exactly (*"all three seats share one login, so one quota froze all of them"*, 068 line 71) and the 2026-10-05 incident (093 section 1: one expired login, ~6 h of dead asks). The owner's complaint is *"the single bottle neck"*: four sessions behind one login on one box are still one. Before M4, at least one of: (a) two logins among the four seats, (b) one OD seat on a second box (option C), or (c) the owner accepts the F2 risk in words |
| 8.2 cost | **change** | RAM is the wrong measure. 6 role sessions exist today but 2 act, and a standby seat costs ~0 tokens (E5). Four seats that each poll, accept and answer are four *active* sessions, at up to ~4x E5's ~20 M cache-read tokens an hour if every seat pays a turn per post. Quota, not RAM, is the ceiling (section 5). Measure the fixed cost per active seat (U4) before M4 |
| 8.3 migration | change | add **M0.5 = R1..R3** (section 3): lanes on sat, dispatchers spawn their own lanes, lane reports to the spawner. They need no owner go, no migration and no cut-over, and they move ~80% of the orch's asks (E7) off it within a day. Use the E6..E8 scripts as M5's soak gate: asks per hour, dead rate, re-raise share, before and after |
| 9 deltas | agree D1, D3; change D2 (above); D4 (above) | - |
| 10 owner questions | add | section 8 here: throughput or availability; quota ceiling |

No section is blocked, but 8.1 is close. Placement A with one login fails the
owner's own goal of removing the single point. The panel should not record
consensus on A without (a), (b) or (c).

## 2. What "overwhelmed" measures as

All rows were measured on `sat` at 2026-10-06 ~17:05Z from the local spool
root and the agent user's transcripts, on tree `ccd87045` and spool `1.1.3`.
Nothing here reads prd. Every row gives the command, so a reader can check it
in about a minute.

| # | claim | n | how |
|---|---|---|---|
| E1 | `sat` is not idle, but it has room: 16 cores, load 18.1 / 11.2 / 9.6, 26 of 62 GB RAM available, 24 agent processes | 1 sample | `uptime; nproc; free -g`; `pgrep -x claude \| wc -l` |
| E2 | one claude session uses 225..421 MB RSS; the three OD seats use 361 / 331 / 240 MB | 24 processes | `ps -o rss= -p <pid>` per `SPOOL_AGENT_ID` |
| E3 | the `<pc box>` load is ~105 | **not measured by me**: relayed from the brief | needs `uptime; nproc` on that box, plus the E2 split per agent |
| E4 | the orch session was **not saturated** while `sat` held the orch role. Over 2026-10-05 00:00..13:00Z, gaps over 60 s between transcript entries cover 54% of the time (43% at 120 s, 66% at 30 s) | 9569 transcript entries, 13 h | timestamps of the c-001 worktree's transcripts (`*.jsonl`) under the agent user's `.claude/projects`; lease log: `sat` held orch from 2026-10-03T11:51Z to 2026-10-05T19:00Z |
| E5 | an **active** orch makes 98..148 model calls an hour, ~12..23 M cache-read tokens, ~140..216 k fresh input and ~40..79 k output. A **standby** seat makes 0..20 calls an hour | 13 active hours; c-002 / c-003 on `sat` for standby | `usage` of each assistant entry, deduplicated by message id, per hour |
| E6 | 1656 messages reached `c-001@sat` over 2026-10-04..05 (median 30.5 an hour, max 125). **92% (1519) came from lanes**; 20 came from the dispatchers. By kind: 713 result, 454 note, 266 blocker, 214 task | 48 h | `c-001/{inbox,archive}/*.json`, by `ts`, `from`, `kind` |
| E7 | the asks book on `sat` holds 700 asks (2026-10-02T02:57Z..10-06T16:55Z). **572 (82%) were raised by a dispatcher** (`c-00[23]` / `CLE-00[23]`) to the orchestrator. 147 ended `dead`, the delivery limit of 4, and **124 of those 147** were raised by a dispatcher | 700 | `<spool root>/asks/*.json`, `state`, `from` |
| E8 | a done ask that was never re-raised closed in a median 8.3 min (p90 49). After 1 re-raise: 18.8 min. After 2: 56 min. 45% of the 506 done asks needed at least one re-raise | 506 | `created_at` .. `updated_at` against `raised_n` |
| E9 | 96 asks are a dispatcher asking the orchestrator for a new lane: 70 done, 20 dead, 5 declined | 96 | summary matches `new lane\|spawn\|new ask` (a heuristic: an undercount, never proof of absence) |
| E10 | **today the fleet already runs two acting orchestrators.** `lease.orch` names `c-001@<pc box>` (holder since 13:14:54Z, last `FLEET orch` line), yet `c-001@sat` spawned 20 lanes c-373..c-393 between 15:34Z and 17:01Z | 20 rows | `cat <spool root>/dispatch/lease.orch`; `grep 'FLEET orch' <spool root>/dispatch/lease.log \| tail -2`; `registry.tsv`, requester column |
| E11 | `sat`'s `lease.conf` still ranks `LEASE_PRIORITY_ORCH=<pc box>,sat,box-desk` (the flip has not reached it yet) | 1 | `grep PRIORITY <spool root>/dispatch/lease.conf` |
| E12 | the dispatch lease changed holder 33 times on 2026-10-06 up to 17:00Z, mostly at :15..:18 (rotation, spec 060) | 33 | `grep -c '^2026-10-06.*FLEET dispatch' lease.log` |

### 2.1 What the numbers say

1. **The box and the session are separate bottlenecks.** "tank-001 is
   overwhelmed" is a box claim (E3: load ~105), and box load comes from the
   lanes on that box. An OD seat is 3 of the ~24 processes (E2). Four ODs on
   that box make it worse, and four ODs on `sat` do nothing for it. Placing
   lanes on `sat` does.
2. **The orch session was not out of time** (E4: idle more than half the hour
   at a 60 s gap). Yet asks wait for the re-raise (E8: 45% need at least one,
   and every extra raise roughly triples the wait), and 21% die (E7). That is
   an **attention** failure: a doorbell ringing on a busy pane (fleet-roles
   4.3, the 692aefe8 analysis). A second, third or fourth session does not fix
   a missed doorbell. It adds doorbells.
3. **The orchestrator's queue is fed by the dispatchers.** 82% of the asks are
   dispatcher-to-orch (E7), and 124 of the 147 dead asks are too. Fleet-roles
   section 3 already says the dispatcher *"spawns a new lane, says so in the
   topic, stays the owner"*. E9 shows it asking the orchestrator instead.
   Following that existing rule takes most decisions off the orchestrator,
   with no new seat.
4. **The lane traffic is reports, not decisions** (E6: 70% result + note, 92%
   from lanes). It reaches the orchestrator because every brief says
   `--to orchestrator` and the orchestrator spawned the lane. 093 4.4 already
   routes *"a lane's report, a reply to an ask"* to *"the seat that spawned
   the lane / raised the ask"*.
5. **The failure modes seen today come from more than one actor** (E10).
   Duplicate spawns, a result in the "wrong" `c-001` inbox, and an owner order
   picked up by a standby `c-002@sat` and acted on by a non-holder
   `c-001@sat` are what happens when two orchestrators act with no partition.
   Four ODs multiply this unless the partition is exact. With N deciders there
   are N(N-1)/2 pairs that can collide: 6 for 4, against 1 for 2.

## 3. The simplest option: one orchestrator on the idle box, plus routing

This is option 0. The author should compare every option against it.

| # | change | addresses | size |
|---|---|---|---|
| R0 | the orch on `sat`: `LEASE_PRIORITY_ORCH=sat,...` in both `lease.conf`, `<pc box>` first (already under way) | the orchestrator off the loaded box | config, done today |
| R1 | lanes on `sat` by default: the spawn box pick weighs load (E1 against E3) | E3, the CPU | one spawn rule |
| R2 | the taking OD spawns the lane for real lane work itself, as section 3 already says. It does not raise a `task` ask "new lane please" | E7, E9: 82% of asks, 84% of dead asks | prompt + brief template; a check in `spool-send.sh` that warns on a `task` ask from 002/003 whose body is a spawn request |
| R3 | a lane reports to its **spawner** (`--to <spawner>@<box>`, written into the brief by the spawner), never to `orchestrator`. The `orchestrator` alias stays for decisions and prd operations | E6 (92% lane traffic), today's "result landed in the wrong `c-001`" | spawn seed prompt; `registry.tsv` already holds the requester |
| R4 | the orchestrator keeps exactly what section 3 leaves it: decisions, prd operations a harness refuses, and the backstop | the prd-read misroute | none: the rule exists |
| R5 | an ask is answered from the asks book on every turn, not from pokes (`do_spl_orch_inbox` first): the hook of 093 7.2 | E8, the attention failure | 093 P1, already agreed |

**What it gives, as an upper bound from E6 / E7.** The orchestrator would see
about a fifth of today's asks (the 18% raised by lanes and by the owner) plus
lane reports only from lanes it spawned itself. The dispatchers would carry the
rest, and they already exist and already sit in every channel (2.1). Nothing
new to elect, lease or rotate. The ceiling is still one orchestrator, but E4
says it has room once the doorbell traffic is gone.

**What it does not give.** It does not survive one orchestrator hanging: 093
P0/P1 covers that, with takeover in minutes. It also does not let two
decisions run at the same moment. If the owner's goal is that, go to section
4.

## 4. If the owner wants more than one decider: 093 P2, with N = 4 (v0.1 section 1 agrees)

- 093 P2 (consensus v0.2, 2026-10-05) **deletes** the orch and dispatch roles.
  Every seat claims jobs from one pool, with a two-phase claim and a 120 s
  lock. A follow-up goes to the topic's owner seat, and a report to the
  spawner (093 4.4). "4 ODs" is P2 with four ready seats. The partition is the
  claim on each job, not a key chosen in advance.
- A partition by box, by workspace or by channel, each with its own lease,
  re-adds roles held alone. It brings four failover paths, four rotation
  windows (E12 already shows 33 holder changes a day for one role), four asks
  books and a routing table for `--to orchestrator`. 093 P2 then has to remove
  all of it. v0.1 section 3.1 rejects (a) and (b) for these reasons: agreed.
- **Ids.** Today 001..003 are reserved on every box (fleet-roles 4.1). 068
  already reserves 001..004 for the seats (v0.1 section 1), so the 4th id is
  settled. `box-desk` is in `LEASE_PRIORITY`, and whether it is live is not
  measured here; it matters for 8.1 option (b).
- **prd operations** stay a capability, not a role: 068's `not_by` / 093 4.4
  "a job one harness refused" sends it to a seat whose harness accepts it. For
  the build, that means one seat flagged prd-capable. Which one is an owner
  question, because it is about whose harness and whose login.
- **Prerequisite, unmeasured**: 093 says the 068 claim columns are *"mostly on
  trunk, not live"*. If `messages.responsible` is not written on prd today,
  every multi-decider design starts with no record of who owns a topic. That
  is the duplicate-answer failure. Needs a prd read (U6; v0.1 owner question 3).

## 5. The cost of 4 live sessions

The processes already exist: 6 OD seats (`c-001..003` on two boxes) are alive
today and 2 act. A standby seat costs memory (E2: ~0.25..0.36 GB) and almost
no tokens (E5). **The cost is in acting:**

| | model calls / h | cache-read tokens / h | weekly, at that rate |
|---|---|---|---|
| 1 active orch (E5, `sat`, 2026-10-05) | ~130 | ~20 M | ~3.4 G |
| 4 active ODs, traffic split cleanly by a claim | ~130 + 3x the fixed share per session (rotation re-briefing, polling, sweeps) | ~20 M + 3x the fixed share | the fixed share is unmeasured: U4 |
| 4 active ODs, every post read by every OD (fleet-roles 2.1: "every OD seat is in every channel" and the others "leave it") | up to ~4 x 130 | up to ~80 M | up to ~13.5 G |

- Each call re-reads the whole context: ~150 k tokens per call (21.4 M / 141
  calls, 2026-10-05 06Z). Even a "leave it" turn costs that much. Under 2.1 a
  4-OD design pays it 3 extra times per post, unless the routing (code, not a
  model) decides who is told: 093's round.
- **Quota is the real ceiling, not RAM.** On 2026-10-01 the whole fleet
  stopped on one login's weekly limit, and today grok is at its weekly limit,
  which is why this seat is claude. Four ODs on the agent user's login make an
  OD quota stop four times as likely to be the one that stops the fleet. The
  account's weekly headroom is unmeasured (U5).
- Rotation (spec 060) gives every OD a fresh session every hour, with a
  handoff and a re-read. Four ODs means four rotations and four lease-hold
  windows an hour. One role already flips 33 times a day (E12).

## 6. What the author should measure and not assume

Each item states what to run. A claim without its check reads as confident and
gets routed as work.

| # | unmeasured | why it decides the design | how |
|---|---|---|---|
| U1 | the `<pc box>` load split: ODs against lanes against everything else | if lanes dominate, R1 alone answers "tank is overwhelmed" | on that box: `uptime; nproc`; per `SPOOL_AGENT_ID` `ps -o pcpu,rss`; `pgrep -x claude \| wc -l` |
| U2 | the asks numbers E7/E8 from the `<pc box>` journal (this note has `sat`'s) | the orch held on `<pc box>` most of today | the same jq over that box's `<spool root>/asks/*.json` |
| U3 | today's four failure modes, one row each with ids: duplicate spawns, unanswered owner posts, results in the wrong inbox, prd reads to a refusing seat | how many of them come from more than one actor (E10) and so get worse with 4 | lease.log, registry requester, `do_spl_unanswered_sweep` output |
| U4 | the fixed token cost of one active OD per hour, apart from traffic | the 4-OD row of section 5 | the E5 script over a quiet hour of an active holder |
| U5 | the agent login's weekly quota headroom | whether 4 active sessions fit at all | the account usage page: owner-held |
| U6 | whether 068's claim (`messages.responsible`) and 093 P0/P1 are live | prerequisites of any multi-decider design | prd read (ask c-001); `do_spl_wd_*` running on each box |
| U7 | the busy fraction (E4) of the orch on `<pc box>` today | if it is saturated there and not on `sat`, the box (R0/R1) is the cause | the E4 script over that box's c-001 transcripts |

## 7. Recommendation for v0.2

1. Add **M0.5 = R1..R3** to 8.3 and land them now. They are small, mostly
   rules already, and measurable within a day with the E6..E8 scripts: asks
   per hour to the orch, dead rate, re-raise share. Install 093's hooks on
   the OD seats (R5) in the same step.
2. Keep v0.1's design: option d, 068 + 093, D1 and D3. Do not build per-OD
   leases.
3. D2 as a preference re-probed hourly, with the refusal path as the
   authority.
4. 8.1: do not record option A with four seats on one login. Require two
   logins, or one seat on a second box, or the owner's words accepting F2.
5. Replace 8.2's RAM figure with the active-session token cost (section 5),
   and measure U4 before M4.
6. Keep the unanswered sweep until M6.

## 8. Questions for the owner (add to v0.1 section 10)

1. Is the pain **throughput** (asks wait, E8) or **availability** (the
   orchestrator hangs, 093's incident)? R0..R5 address the first and 093
   P0/P1 the second. The seats address both, but only once M1..M4 are built
   and the owner has given the go.
2. Four seats on one login on one box (v0.1 option A) has the same single
   point as 2026-10-05 (one expired login) and 068's F2 (one quota). Accept
   that, or require a second login or box before the cut-over?
3. What weekly quota should the OD seats stay within (U5)?
