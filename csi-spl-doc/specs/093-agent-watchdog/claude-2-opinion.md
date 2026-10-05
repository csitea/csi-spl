# 093 opinion: claude panelist 2

Status: **opinion, 2026-10-05**, on [spec.md](spec.md) v0.1 at commit `880524250`.
Topic: t1 `340f3be9-bd64-4419-8267-cb1b8083d8ea`. Author: claude panelist 2 (c-325).
I wrote this independently of the other panelists. It is spec only: no code, cron,
table or seat was touched.

## 0. Verdicts

| question | verdict | where |
|---|---|---|
| Q1 decentralization | **agree**, plus three amendments (A1..A3) | section 2 |
| Q2 which agent takes which job | **replace 4.3** (offer to a small set, first accept wins) and **amend 5.3 "ready"** (a per-job touch) | section 3 |
| Q3 claim protocol | **replace 4.1 + 4.2** (same idea, fewer new columns, claim_n counts owners not offers, inbox reconciled, one SQL statement per transition) | section 4 |

The draft gets the core right: **ownership starts at an accept that only a live
model can make, a lock is renewed only on proof of progress, and the fence makes a
late agent harmless.** My changes fix four holes I found by reading the code that the
draft builds on (section 1). None of them changes the architecture.

## 1. The draft's claims, checked against the code

| draft claim | check | result |
|---|---|---|
| 1: `spl_lease_stall` returns "able" for a login screen (stall hint, no spinner, no reset time) | `grep -n -A22 '^spl_lease_stall()' csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` | **true**. The branch `[[ -n "$hit" && -z "$spin" ]]` prints only when `spl_lease_limit_until` reads a reset time. Without one it returns 0 with no output, which means able |
| 1: `spl_fleet_stuck` counts the newest transcript write as activity, so a poke plus its error reply looks active | `grep -n -A20 '^spl_fleet_stuck()' …spl-dispatch-lease.func.sh` and `grep -n -A16 '^spl_lease_activity()' …` | **true**. Activity is the newest `*.jsonl` mtime, with no filter for content |
| 3/4: 068's claim columns exist (`responsible`, `locked_until`, `responsible_gen`, `claim_n`, `not_by`, `handled_*`) | `grep -c 'ADD COLUMN IF NOT EXISTS' csi-spl-rdb/src/sql/postgres/spool-hub/0110_messages_claim.sql` -> 8 | **true** |
| 4.2 T1: `FOR UPDATE SKIP LOCKED` poll | `grep -n 'SKIP LOCKED' csi-spl-api/src/go/spool-hub-api/internal/store/message_claim_postgres.go` -> 3 (1 comment, 2 statements) | **true**. One claim does `responsible_gen + 1` **and `claim_n + 1`**, and dead-letters at `ClaimMax = 4` (`message_claim.go:40`) |
| 4.2 T4: the loop renews "the seat's locks" | `RenewMessageClaims` in the same file | **true, and it renews per SEAT**: every row `responsible = seat`, in one UPDATE. Nothing is per job (this matters for hole H1) |
| 5.3 replaces the loop's progress check | `sed -n 1,20p csi-spl-orc/src/bash/run/spl-peer-poll.func.sh` | the loop **already** gates renewal on `PEER_PROGRESS_MAX` (600 s) of **transcript writes**, the same signal section 1 shows is fooled. The draft never names it. See A3 |
| 8.1: every takeover step reuses an existing function | `grep -l '^<fn>()'` for the 10 names in 8.1 under `csi-spl-orc/src/bash/run/` | **true**. All 10 exist in `spl-rotate-lib.func.sh`, `spl-peer-restart.func.sh` or `spl-peer-ensure.func.sh` |
| 9: no seats are live | `ls /var/spool-hub/peer` | **true** on this box: no such directory |
| 068 section 7: hub down falls back to an `O_EXCL` local lock | `grep -n O_EXCL csi-spl-doc/specs/068-peer-seats/spec.md` | **true**, but only for local-origin messages |

**Holes found** (each is fixed in sections 3-4):

- **H1. A heartbeat proves the seat is alive, not that each held job is being
  worked.** Renewal is per seat, and `PEER_MAX_HELD` is 3. Example: a seat accepts
  A (a 40 min investigation with a tool call every minute) and B (a one-line owner
  question). The heartbeat stays fresh, so B is renewed for 40 min. T5 never fires,
  and neither does S1 (progress is fresh). The owner waits 40 min while other
  seats sit idle.
- **H2. A lapsed offer leaves its file in the inbox.** The loop writes each claimed
  message into the inbox once (`spl-peer-poll.func.sh`, step 4). Nothing removes it
  when the offer lapses (T3) or another seat wins. Under the draft's S1 ("an inbox
  file … older than 120 s" and no progress), an **idle, healthy** seat holding a
  stale offer file is rung at 120 s and **taken over at 240 s**. That is a false
  takeover, and nothing in 6.2 guards against it.
- **H3. Lapsed offers burn the dead-letter budget.** T1 is 068's claim, which does
  `claim_n + 1`. Four lapsed 45 s offers (four busy seats) close a job `dead` after
  about 3 min, even though no agent ever owned it.
- **H4. Serial offers are slow.** Each lapse costs 45 s before the next seat is tried.
  With two busy seats ahead of an idle one, a new owner post waits more than 90 s.
  That is the opposite of the owner's "fastest response".

## 2. Q1, decentralization: agree, with three amendments

Agree with section 3: a hub that arbitrates, a shell poll loop per seat, a shell
watchdog per box, and agents that judge. No role is held by one agent alone. This
answers f5a2f24a.

- **A1. Name the one arbiter honestly.** "No single point of failure" is true of
  *roles*, not of *state*. The hub (Cloud Run plus one Cloud SQL instance) is the
  only place a claim is decided. That is the right choice: a managed database is
  far more available than a model session, and it is what makes a race settle in
  one statement. When it is down, though, only local-origin jobs move (068
  section 7). Say so in section 3, and score failover-proof 4, not 5.
- **A2. Ship the incident fix first, alone.** The 6 h outage in section 1 came from
  one branch: a stall hint with no spinner and no readable reset time returns
  "able". Treat that case as **not able**, with the transcript's last entry as the
  tie-breaker against a stale banner (6.2's last row). That is a small change to
  `spl_lease_stall` plus a fixture, and it fixes the incident under today's lease
  with no new layer. Make it P0, ahead of P1.
- **A3. State that 093 replaces `PEER_PROGRESS_MAX`.** The poll loop's progress gate
  today counts transcript writes. Those are exactly the activity-not-progress
  signal of section 1. 5.3's "fresh" must replace it, not sit beside it, or a
  login-expired seat still renews for 600 s.

## 3. Q2, which agent takes which job

### 3.1 Replacement for section 4.3: offer to a set of K, first accept wins

The owner said "who takes the inbox files depends on the fastest response from an
agent". The draft makes it serial: one seat, 45 s, then the next. Replace that
with a **bounded race**:

- An open job collects up to **`OFFER_K` (default 2)** candidate seats. Each ready
  poll loop that sees the job adds its own seat to `offer_set`, if the set has room
  and the seat is not in `lapsed` (T1' in 4.2'). The first joiner opens a 45 s
  window. The second joins the same window, usually within 5 s.
- Both agents see the offer: an idle one through the pane ring, a busy one through
  the inject hook within one tool call. **The first `spool claim --accept` wins.**
  The other gets 409 and drops the job; its loop also archives the file (4.5').
- Cost: K agents read each new job. The loser spends one short turn. K is a knob:
  `OFFER_K=1` is exactly the draft. My default of 2 doubles the intake tokens and
  removes H4. A slow candidate no longer delays the job if the other one is quick.
- Harness mix: a loop does not join a set that already holds a seat of its own
  harness during the first 5 s of the window. That leaves room for a different
  harness, which also covers the "one harness's login expired" case (4.4) without
  a separate rule.
- Topic stickiness, lane reports and replies to an ask (4.3 and 4.4): **agree**. At
  insert they get `offer_set = {owner seat}` and a 45 s window. When that window
  lapses, the job is open to the pool like any other.

The table in 4.4 stays as written, read with "offered to" meaning "in the first
`offer_set`".

### 3.2 Amendment to 5.3 "fresh": a per-job touch (fixes H1)

Keep `PEER_MAX_HELD` at 3, but renew a job only when **both** of these hold:

1. the seat's heartbeat is fresh (5.3, unchanged), and
2. the job was **touched** within `JOB_IDLE_MAX` (15 min). A touch is any hub call
   that names the job: accept, a fenced post or spawn (`do_spl_peer_fence` already
   calls the hub with `--msg`), park, unpark, or an explicit `spool claim --touch
   <msg>`. Each sets `touched_at = now()`.

A seat deep in job A must therefore **park or release B** within 15 min, or B is
not renewed and moves (T5) while the seat stays healthy. The Stop hook gets one
more line in 7.1: "you hold N jobs untouched for over 10 min: park, release or
touch them". A parked job is renewed until `parked_until` without a touch, as in
the draft.

## 4. Q3, the claim protocol

### 4.1' States (replaces 4.1)

All times are **hub clock**. A box never compares its own clock with a lock time.

| state | predicate on the row (`handled_at IS NULL` unless DONE) |
|---|---|
| `FREE` | `accepted_at IS NULL AND (locked_until IS NULL OR locked_until < now())` |
| `OFFERED` | `accepted_at IS NULL AND locked_until >= now() AND cardinality(offer_set) > 0` |
| `OWNED` | `accepted_at IS NOT NULL AND locked_until >= now() AND parked_until IS NULL` |
| `PARKED` | `accepted_at IS NOT NULL AND parked_until >= now()` (lock renewed up to it) |
| `EXPIRED` -> FREE | `accepted_at IS NOT NULL AND locked_until < now()`: the next poll clears `accepted_at`, `responsible`, `touched_at`, `parked_*` in the same statement that re-offers |
| `DONE` | `handled_at` set (068) |

**The offer window reuses `locked_until`**, so no `offer_until` is needed and 068's
"lock past = free" reading still holds. New columns (one migration, constant
defaults, catalog-only): `offer_set text[] '{}'`, `lapsed text[] '{}'` (the
draft's `offered_to`, capped at 8), `offer_n int 0`, `accepted_at`, `touched_at`,
`parked_until timestamptz NULL`, `park_reason text NULL`. **`claim_n` now counts
accepts, not offers** (fixes H3). `offer_n` counts windows. `OFFER_MAX` (6) windows
with no accept closes the job `dead` and sends the owner one DM: "nobody
accepted <msg> in 6 tries".

### 4.2' Transitions: one actor and one SQL statement each

| # | transition | actor | the statement's guard (`WHERE`), and what it sets |
|---|---|---|---|
| T1' | FREE -> OFFERED, or join an open OFFERED | a **ready** seat's poll loop | FREE or OFFERED, `cardinality(offer_set) < OFFER_K`, `NOT me = ANY(offer_set)`, `NOT me = ANY(lapsed)`, `NOT harness = ANY(not_by)`, `FOR UPDATE SKIP LOCKED`. From FREE it sets `offer_set = {me}`, `locked_until = now() + 45 s` and `offer_n + 1`, and moves the previous window's set into `lapsed`. On a join it sets `offer_set = offer_set \|\| me` and leaves the window as it is |
| T2' | OFFERED -> OWNED | the **agent**: `spool claim --accept <msg> --offer <offer_n>` | `accepted_at IS NULL AND me = ANY(offer_set) AND offer_n = $n AND locked_until >= now()`. Sets `responsible = me`, `accepted_at = touched_at = now()`, `locked_until = now() + 120 s`, `responsible_gen + 1`, `claim_n + 1`, `offer_set = '{}'`. **Returns the new `responsible_gen`**, which becomes the fence value |
| T3' | OFFERED -> FREE | time | the window passes with no accept. The next T1' handles it lazily (see the FREE row) |
| T4' | OWNED -> OWNED (renew) | the seat's poll loop | `responsible = me`, heartbeat fresh (checked in the loop), and `touched_at >= now() - JOB_IDLE_MAX` or PARKED. Batched per seat as today, with the touch predicate added |
| T5' | OWNED -> FREE | time | `locked_until < now()`. This is the owner's 2-minute rule |
| T6'-T9' | park / unpark / release / done | the agent | the draft's T6-T9 unchanged. The guard is `responsible = me AND responsible_gen = $gen`, and each also sets `touched_at` |
| T10' | -> DONE `dead` | the poll statement | `claim_n >= CLAIM_MAX` (4 owners failed) or `offer_n >= OFFER_MAX` (6 windows, nobody accepted) |

### 4.3' How a race is settled

- **Two accepts at once.** Both run T2' on the same row. Postgres takes the row lock
  for the first. Under READ COMMITTED, the second re-evaluates its `WHERE` after the
  first commits, sees `accepted_at IS NOT NULL` and updates 0 rows. **1 row = you
  own it, at the returned gen. 0 rows = 409, drop the job.** There is no third
  outcome and no tie-break rule, because the database row lock is the tie-break.
- **A late accept after the window.** `locked_until >= now()` fails, so 0 rows, 409.
- **A late accept for an old window it was in.** `offer_n = $n` fails, because a
  re-offer bumped `offer_n`. 409.
- **A late outward action after T5'.** The fence (`responsible = me AND
  responsible_gen = gen`) fails, so 409. Unchanged from 068.
- **Two poll loops opening the same FREE row.** `SKIP LOCKED`: one opens it and the
  other skips it this tick. On the next tick the other one joins (T1'), which is
  what K = 2 wants.

### 4.4' Expiry

| what expires | effect | who notices |
|---|---|---|
| an offer window | the set goes to `lapsed`, and the job is FREE for seats not in `lapsed` | the next poll of any seat. Losing seats reconcile their inbox (4.5') |
| an owner's lock (no progress, or untouched) | FREE. The late owner is fenced on its next action | the next poll. The watchdog's S1 also rings, then repairs the session (8) |
| a park | becomes OWNED again: it must be touched or renewed within 120 s | the owner's Stop/inject hook says "park on <msg> ended" |
| everything, when every seat of a harness is out (S2) | jobs fall to the other harnesses, through `not_by` and the harness-mix join rule | nobody needs to |

### 4.5' Inbox reconciliation (fixes H2)

Every tick, the renew/poll call already returns the seat's rows. The loop compares
the offer files in `<id>/inbox/` (each one carries `msg_id` and `offer_n`) against
what the hub returned. A file whose window lapsed, was won by another seat, or
whose job is DONE is moved to `<id>/archive/` with `"lost": "<lapsed|taken|done>"`.
For seats, **S1 reads the hub's held set** (`<spool root>/peer/<id>/held`, written
by the loop) and never inbox ages. Inbox-age S1 stays for lanes only, since lanes
receive no offers.

### 4.6' Hub down

The agent's `spool claim --accept` falls back to 068's `O_EXCL` create of
`<spool root>/claims/<msg id>`. So even off-hub, **the accept is the agent's tool
call**, never the loop's. The loop writes a local-origin job to its own seat's
inbox as an offer. When the hub returns, the local claim is pushed
insert-if-absent, as 068 already does.

## 5. Scores (owner 33fab614)

1 = weak, 5 = strong.

| property | draft v0.1 | why (draft) | with this opinion | why (replacement) |
|---|---|---|---|---|
| robust | 3 | progress-only heartbeat is right, but H1 (a busy seat sits on other jobs), H2 (false takeover of an idle seat from a stale offer file) and H3 (4 lapsed offers = dead) are real failure paths | 4 | per-job touch, reconciled inboxes and owner-counting `claim_n` close all three. Still open: harnesses without hooks rely on S8's weaker signal |
| failover-proof | 4 | no role, any seat takes any job, but the hub is the one arbiter, and while hub is down only local jobs move (draft says 5) | 4 | same arbiter, same honest limit. P0 (A2) removes today's 6 h failure mode before any new layer lands |
| fast | 3 | offered in 5 s, but each lapse adds 45 s in series (H4). A dead holder takes 120-125 s | 4 | the first of K = 2 accepts, usually within one tool call. A dead holder is still 120 s, by the owner's own threshold |
| scalable | 4 | about 0.2 hub queries/s per seat; the watchdog is O(agents) per 30 s | 4 | the same query rate (a join is the poll's own UPDATE). Intake tokens grow K times, which the K knob bounds |
| uninterruptible | 4 | locks survive slot restarts, and a takeover costs at most one lock period | 4 | the same, plus a parked job survives its owner's takeover up to `parked_until` and is then re-offered with its topic history |

## 6. Not checked

- 068's `TestAnswerOnce` was not run. The fence claims are taken from 068 and from
  the `do_spl_peer_fence` source, not from a test run in this lane.
- The ping-test results in 7.3 (grok, agy, qwen hooks) are the draft's reading of
  the binaries. I did not re-measure them.
- The latencies in section 5 are design arithmetic (poll period, window, TTL), n = 0
  measured. FR-001/FR-002 should measure them with n >= 20, as the draft says.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T20:10:00Z -->
