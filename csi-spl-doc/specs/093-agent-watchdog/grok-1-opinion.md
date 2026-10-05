# 093 opinion — grok panelist 1

Independent opinion on `csi-spl-doc/specs/093-agent-watchdog/spec.md` v0.1,
commit `880524250`. Doc only. No other file is changed by this note.

Checked on this worktree while `880524250` was an ancestor of `HEAD`, by
reading the cited sources. The transcript count in section 1 was not
re-measured. `ls /var/spool-hub/peer` prints `No such file or directory`, so
the draft is right that no seat file is live and the poll loop is inert.

## What the code does today

| draft claim | where | result |
|---|---|---|
| A stall banner counts only with a frozen spinner, or with no spinner and a readable reset time. A login banner has neither, so the seat stays able. | `spl_lease_stall` in `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`: a hit with an empty spinner calls `spl_lease_limit_until` and prints a stall only when that returns a time (lines 462-466). `LEASE_STALL_RE_DEFAULT` contains `please run /login` (line 292). `spl_lease_limit_until` only parses a footer that matches `limit` or `continuing automatically` (lines 488-493). | Holds. A login banner is a hit, then it is discarded. |
| The stuck rule treats the newest transcript write as activity, so an error reply looks like work. | `spl_fleet_stuck` / `spl_lease_activity` in the same file (lines 997-1040): last activity is the newest `*.jsonl` mtime under the harness project dir. `LEASE_UNREAD_MAX` defaults to 600. | Holds for the lease. The same mtime is what the poll loop calls progress: `PEER_PROGRESS_MAX` defaults to 600 in `spl-peer-poll.func.sh` (lines 36, 86, 170-176). |
| 068's poll claims in one step. Nothing proves the agent saw the job. | `PollMessageClaims` sets `responsible`, `locked_until = now+ttl`, `responsible_gen + 1` and `claim_n + 1` in one statement (`message_claim_postgres.go`, the second `UPDATE`). `applyClaim` in `message_claim.go` does the same. `spl_peer_tick` writes the inbox after that hub call. | Holds. There is no accept step. |
| Lock TTL is 120 s, poll is 5 s, a seat holds at most 3, claim max is 4, the poll orders with `FOR UPDATE SKIP LOCKED`. | `PEER_LOCK_TTL` 120, `PEER_POLL_SEC` 5, `PEER_MAX_HELD` 3 (`spl-peer-poll.func.sh`); `ClaimMax` 4 (`message_claim.go`); the poll `UPDATE` uses `FOR UPDATE SKIP LOCKED`. | Holds. |
| A renew rewrites the lock to now+TTL. | `RenewMessageClaims` sets `locked_until = now+ttl` only when the remaining time is under `ttl/2` (`message_claim.go` comment; `message_claim_postgres.go` around the renew `UPDATE`). | Holds. Combined with section 5.3 this breaks the 120 s bound. See Q3. |
| The fence refuses a seat that lost the generation. | `do_spl_peer_fence` / `spl_peer_fence` exit 1 when the hub says lost, exit 2 when the hub cannot say. `spl_peer_gate` is a separate function. | Holds. |
| `do_spl_peer_ensure` is a every-minute cron. | `do_spl_peer_ensure_install_cron` installs `* * * * *`. | Holds. The cron is specified; this opinion did not read a live crontab. |
| Hub down is a local `O_EXCL` create that becomes the claim. | Header of `spl-peer-poll.func.sh` (the local lock on `<spool root>/claims/<msg id>`). | Holds for today's one-step claim. Section 4 never says what that file means once claim is split into offer and accept. |
| The takeover names functions that already exist. | `spl_peer_restart_seat`, `spl_peer_stop`, `spl_peer_seed`, `spl_peer_restart_spawn`, `spl_peer_rlog` in the peer restart and ensure files; `spl_rotate_handoff`, `spl_rotate_end`, `spl_rotate_restore`, `spl_rotate_alert`, `spl_rotate_workdir`, `spl_rotate_input` in `spl-rotate-lib.func.sh`. | The names exist. The call order against section 8 was not diffed. |
| Failover of the role waits `LEASE_STALE` 180 s. | `LEASE_STALE` defaults to 180 in `spl-dispatch-lease.func.sh`. | Holds. Section 9's "about 4 min" is this window plus detection, not the 120 s job lock. |

Section 1's lesson holds: activity is not progress. The draft then breaks that lesson in two named places, below.

## Q1 — replacement of section 3's closing paragraph, and of the fresh row in 5.3

The four-layer table in section 3 stays. The hub is the compare-and-swap board for claim state, not an agent. A poll loop per seat, a watchdog per box, and agents that only judge, is the right split. The watchdog must not be required for a job to move. Peers must not kill processes (that part of 6.3 stays; see Q3).

Replace the paragraph that begins "There is no orchestrator role" with:

> P1 still has the fleet lease (section 9). One seat holds the orch role, and the standby takes it only after `LEASE_STALE` (180 s) with no renewal. That role is the single point of failure the owner named, until P2 deletes it. The job path is the part that has no such role, and only once a seat file exists: today `/var/spool-hub/peer` is absent, so no poll loop runs and every ask still depends on the lease holder.
>
> The hub is a board. It is the one writer of claim rows. It is not an agent, so it is not the failure in f5a2f24a. When the hub is unreachable, offer and accept use the local files in 4.5. Posts that exist only on the hub wait, which is already 068's rule for web posts.
>
> A seat is alive only under the replaced fresh rule in 5.3. A moving spinner, a growing transcript, or a parked flag is not enough.

Replace the **fresh** row of 5.3 with:

| verdict | rule | the poll loop |
|---|---|---|
| **fresh** | `api_error` is null AND no situation hit is current AND (`now - progress_ts <= HB_FRESH` (120 s), OR `state = in-tool` and `now - tool_since` is within that tool's S4 cap, OR `state = working` and `now - turn_since <= HB_FRESH` and the spinner text changed within 45 s) | renews (T4), and the value it writes is `progress_ts + HB_FRESH` or, for the spinner arm only, `turn_since + HB_FRESH`. Never `now + 120 s` |
| **ready** | unchanged from the draft: fresh or idle, `api_error` null, no situation hit, fewer than `PEER_MAX_HELD` (3) jobs OWNED | may take offers, but only as 4.3 ranks them |
| **stale** | anything else, including a situation hit or a non-null `api_error` | no renew, no poll |

The spinner arm is a capped grace for one turn with no tool call, not an open renewal. A spinner that keeps moving past 120 s from `turn_since` is stale. S2 (login, limit, access) forces stale even when the spinner moves, which is the line the draft says in S2 and then omits from the fresh row. A long tool stays fresh up to its S4 cap because `tool_since` is a progress event; that is the one deliberate stretch of the 2-minute rule, and it ends when the tool cap ends.

`UserPromptSubmit` still must not move `progress_ts`. That part of section 5.2 stays.

## Q2 — agree with 4.4; replacement of 4.3

4.4 stays as written. A new human post has no owner. A follow-up goes to the topic owner. A lane report goes to the seat that spawned the lane. An investigation goes to another harness. A harness refusal goes to a seat outside `not_by`. Real lane work is a new lane, and the seat parks on a wait token (the replaced T6), it does not do the lane's work itself.

Replace 4.3. "First able poller" offers a job to a busy seat and then waits 45 s before the next seat may see it. Ready includes a seat whose state is `working` or `in-tool` (5.3). That seat is able and has room, so it wins `SKIP LOCKED` ahead of an idle seat that polls a second later. Three lapses at 45 s are 135 s, which spends the whole 2-minute budget before a fourth seat is offered the job. Exclusive offer is still right: a broadcast spends every seat's context on every job, and two accepts would race. The hub statement is the race, not the agents.

Replacement:

- Each poll sends one verdict, `idle` or `busy`. `idle` means heartbeat `state` is `idle` or `starting` (past `WD_START_GRACE`), the ready rule holds, and the seat is not in `offered_to`. `busy` means ready and not idle.
- T1 is one statement. An `idle` poll may take a FREE job at once. A `busy` poll may take it only when it has been FREE for 8 s (no idle seat took it). `FOR UPDATE SKIP LOCKED` stays, so two idle polls still take different rows.
- `offer_until` is `now + 8 s` for an idle taker and `now + 20 s` for a busy taker. Not 45 s.
- The offered seat accepts with its own tool call (T2, unchanged) or the offer lapses. The inject hook (section 7) is how a busy seat sees the offer inside a turn. A busy seat that does not accept inside 20 s loses it.
- Topic stickiness (the draft's insert-as-OFFERED to the owner) stays in front of this ranking. A stale owner is inserted FREE, as the draft says, and then the idle-first rule applies. A live busy owner is offered to that owner with the 20 s window, not to a random idle seat.
- `offered_to` is a one-lap skip, not a permanent ban. The lap is cleared in the same statement when no eligible seat remains, and that statement may then offer. A permanent skip is only `not_by`, which 068 already has. FR-002 as written ("not offered it again") plus a cap of 4 deadlocks a job once four seats have lapsed and `claim_n` did not move.

An idle seat at the prompt is the fastest response. A busy seat is the fallback when nobody is idle. The agent still decides whether to accept.

## Q3 — replacement of 4.1, of T1's counters, of T3, T4, T6 and T7, plus a hub-down clause

Agree with these parts, unchanged:

- Ownership starts at the agent's accept, not at the poll (T2). The accept is one tool call, so a dead model cannot own a job. The guard is `responsible = me AND responsible_gen = <gen in the inbox file> AND offer_until >= now() AND accepted_at IS NULL`, one statement. Zero rows means the agent stops and does not answer.
- The outward fence stays `do_spl_peer_fence` / `spl_peer_gate`: `responsible = me AND responsible_gen = gen` immediately before a post, a spawn or a prd call. A late agent is refused and cannot double-answer.
- T5's meaning: a lock that has run out is FREE, and the next poll offers it. No failover choreography.
- T8, T9, T10's actors: the holder releases or closes; the hub dead-letters at `CLAIM_MAX`.
- 6.3: the box watchdog is the only program that stops a session, and only through `do_spl_wd_takeover` after a situation hit. A seat may request that action. A seat may not `kill` or `tmux kill` a peer. Job movement is T5, not the kill. The kill repairs the session so the id can take work again.

The protocol as written is not one state per row, and the 120 s bound is not the bound the transitions implement.

### 4.1 — one predicate each

The draft's FREE predicate is three ORs. A PARKED row whose `locked_until` has passed matches FREE and PARKED at once. An implementer who checks `parked_until` first will keep the job; one who checks `locked_until` first will free it.

Replace the state table with predicates that partition the unhandled rows. `handled_at IS NOT NULL` is DONE and matches nothing else.

| state | predicate |
|---|---|
| `OFFERED` | `accepted_at IS NULL AND responsible IS NOT NULL AND offer_until >= now()` |
| `OWNED` | `accepted_at IS NOT NULL AND parked_until IS NULL AND locked_until >= now()` |
| `PARKED` | `accepted_at IS NOT NULL AND parked_until >= now() AND locked_until >= now() AND wait_token IS NOT NULL` |
| `FREE` | unhandled, and not the three above |

`locked_until IS NULL` is not an alias of FREE. Today's `claimFreeSQL` treats a null lock as free (`responsible IS NULL OR locked_until IS NULL OR locked_until < now`). Keep that fail-safe only for a row with `accepted_at` set and a null lock (a dropped renew). An open offer keeps `locked_until` null on purpose and is not free until `offer_until`.

### T1 and `claim_n`

T1 still moves FREE to OFFERED, one statement, `SKIP LOCKED`, seat not in `offered_to`, harness not in `not_by`, poll only while ready, `responsible_gen + 1`.

`claim_n` does not move on T1. Today's `applyClaim` increments it on every poll, and `ClaimMax` is 4. Four lapsed offers would dead-letter a job that nobody accepted. `claim_n` increments on T2 only. A lapse is not a delivery. T10 stays `claim_n >= 4` accepted deliveries without a close.

The same T1 statement, when it takes a row whose previous offer or lock has lapsed, appends that previous `responsible` to `offered_to` and keeps the newest 4. There is no separate writer for the lapse. That is the repair of T3, whose actor is "nobody" while the append still has to be written.

### T4 — the lock is `progress_ts + 120 s`

Replace "renewed to `now + LOCK_TTL`" with:

> The poll writes `locked_until = progress_anchor + HB_FRESH`, where `progress_anchor` is `progress_ts`, or `turn_since` when the fresh row's spinner arm is the one that passed. A renew that would not change `locked_until` is a no-op. The loop does not call renew when the seat is stale.

Why the draft's sentence is longer than 2 minutes. Fresh allows a renew while `progress_ts` is already 119 s old. `RenewMessageClaims` then sets `locked_until = now + 120 s` when under half the TTL remains. The job becomes FREE about 120 s after that renew, which is about 240 s after the last progress, plus one poll. FR-001 (offered to another seat within 125 s) is false under that pair. Writing `progress_ts + 120 s` makes the expiry the owner's 2 minutes, and a dead loop stops extending it, so the same bound holds when the poll itself has died.

The `ttl/2` skip in `RenewMessageClaims` can stay only as "do not write when the stored instant is already within 60 s of `progress_anchor + HB_FRESH`". It must not compute the instant as `now + ttl`.

### T6 and T7 — park does not pin a dead seat

Replace T6's "the loop renews a parked lock without a heartbeat until `parked_until`".

A park is a wait token the hub can see: the lane id, the task id, or the CI run id the seat is waiting on, stored in `wait_token`, plus `park_reason` and `parked_until` (at most 60 min ahead). The seat calls `--park` with the holder and the generation, as the draft says.

`locked_until` is still `progress_anchor + HB_FRESH`. Park does not renew it. When the holder's heartbeat goes stale, the row stops matching PARKED and becomes FREE even if `parked_until` is in the future. The next owner inherits `wait_token` and `park_reason` in the offer. S1 still must not treat a live parked seat as a stuck session: the session is allowed to sit, the job is not.

A dead model whose poll loop is still up is the 2026-10-05 shape (the process lived, the lease kept renewing). A park that renews without a heartbeat would hold that job for up to 60 min. That is the claim bug the owner called unclear.

Split T7, which names two actors:

| # | from -> to | actor | guard |
|---|---|---|---|
| T7a | PARKED -> OWNED | the holder, `--unpark` | holder + gen, and fresh |
| T7b | PARKED -> OFFERED | the holder's poll, when the waited-for row has arrived | holder + gen; `offer_until = now + 8 s`; the holder must accept again (T2). A stale holder does not get T7b; the job goes FREE through the lock |

### 4.5 — hub down uses the same two phases

Add this. 068's local path creates `claims/<msg id>` with `O_EXCL` and that create is the claim. Under this protocol that create would make a dead model the owner, which is the bug section 4 exists to close.

- `claims/<msg id>.offer`, created `O_EXCL` by the poll, holds the seat and the generation. A second seat's create fails. The poll deletes the offer at `offer_until` if no accept file exists, and appends itself to a local `offered_to` list.
- `claims/<msg id>.accept` is written by the accept tool, not by the poll. The poll refuses to write it.
- The fence on a local job reads the accept file. Hub exit 2 (unconfirmed) still means do not act, as `spl_peer_fence` already does.
- When the hub is back, the accept is pushed with the adopt call only if the hub row is still free. If another box owns it, the local seat stops.

## Scores

Draft v0.1 as written:

| property | score | why |
|---|---|---|
| robust | 3 | Section 1 matches the stall and stuck code, and offer-then-accept is the right split. The fresh row then treats a moving spinner as an open renewal, and T6 renews a park with no heartbeat for up to 60 min, so a live process with a dead model keeps the job. |
| failover-proof | 3 | The four layers are right, and a poll that stops calling renew does expire today's 120 s lock. P1 still has one orch lease at 180 s, no seat file exists yet, and hub-down is still a one-step local claim. |
| fast | 4 | A new job is seen within one 5 s poll (the stagger in `spl_peer_loop` is real). The dead-holder bound is about 240 s once a renew at the end of the fresh window writes `now + 120 s`, and a busy seat can hold an offer for 45 s. |
| scalable | 4 | One indexed poll per seat per 5 s, `SKIP LOCKED`, at most 3 held. The watchdog is one capture per agent per 30 s. Nothing here needs a model in the loop. |
| uninterruptible | 3 | T5 moves a job when renew stops, and the ensure cron is specified every minute. A parked job, a spinner that never goes stale, and the P1 role lease each stop the flow the owner asked to keep moving. |

This replacement:

| property | score | why |
|---|---|---|
| robust | 4 | Progress, a capped spinner grace, or a live tool. A situation hit or `api_error` forces stale. Park cannot outlive the heartbeat. Left open: a harness with no hooks still depends on S8's transcript read, which is the same family of signal section 1 rejected. |
| failover-proof | 4 | Any ready seat on any box takes a free job, with no role on that path. Hub-down uses the same offer file and accept file. Left open: a job that exists only on the hub does not move while the hub is down, and P1's orch lease remains until 068's cut-over. |
| fast | 4 | Idle seat offered inside one poll, 8 s to accept; busy seat only after 8 s, 20 s to accept. A dead holder's job is free at `progress_anchor + 120 s`. Not under 2 minutes, because that is the owner's threshold. P1's role failover is still the 180 s lease. |
| scalable | 4 | Same poll rate and the same `SKIP LOCKED` statement. The new verdict is one extra parameter on the poll the loop already sends. The watchdog's cost is unchanged. |
| uninterruptible | 4 | A dead model loses the job at 120 s even if the process, the poll loop, or a park remains. A live tool may hold up to its S4 cap, then the lock ends. A turn longer than 120 s with no tool call loses the job and the fence drops the late post; the session itself is not killed until S1 at 240 s. |

## Left as written

Sections 6.1 (S1-S8), 6.2's false-positive list, 7's hook events, 8's reuse of the 060 restart functions, 9's two phases, and 10's "a watchdog never touches another box". S1's takeover at 240 s stays behind T5, so the session repair is not on the job's critical path. Two tests belong on the draft's FR list when the replacements land: a renew writes `progress_anchor + 120 s` and not `now + 120 s` (n >= 20 in the claim suite the draft already names), and a parked row with a stale heartbeat is offered to another seat inside 125 s while `parked_until` is still ahead (n >= 5).

<!-- version: grok-1 · updated: 2026-10-05 -->
