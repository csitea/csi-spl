# 093 panel opinion: grok-2

Status: opinion on spec 093 v0.1 (`880524250`, 2026-10-05). This file only.
Questions are the owner's three (555c58dc). Scores use the five properties
(33fab614). Each answer is **agree** or a **replacement of a named section**.

Checked on the draft's own tree, n=1 static read of each cited function.
No live pane replay and no recount of transcript files.

## 0. What the code actually does

| draft claim | verdict | where |
|---|---|---|
| `please run /login` is in `LEASE_STALL_RE`, and a login footer with no spinner and no reset time returns able | holds | `spl_lease_stall` prints the banner only when `spl_lease_limit_until` returns a time, else it returns with empty stdout (`spl-dispatch-lease.func.sh` around the `hit && -z spin` branch). `LEASE_STALL_RE_DEFAULT` contains `please run /login`. The limit parser only reads a reset clock (`limit` or `continuing automatically`) |
| the stuck rule treats the newest transcript mtime as activity, so a prompt plus an error reply looks like work | holds | `spl_fleet_stuck` / `spl_lease_activity`: newest `*.jsonl` mtime under the harness project dir. The comment there says a transcript grows on every prompt, tool call and tool result. The draft's historical count of login lines was not re-run |
| 068's poll **claims** in one statement (`FOR UPDATE SKIP LOCKED`) and writes the inbox; there is no accept step | holds | `PollMessageClaims` sets `responsible` and `locked_until` on the free rows. `do_spl_peer_poll` then writes `<spool>/peer/<id>/` held list and the inbox. A dead model still owns what its loop took |
| "progress" today is a transcript write within 600 s, not a model event within 120 s | holds | `PEER_PROGRESS_MAX` default 600; `spl_peer_tick` compares transcript mtime (or `claimed_at`) and, past it, skips renew. `RenewMessageClaims` itself has no progress predicate: the shell is the only gate, and the gate is mtime |
| lock TTL 120 s, poll 5 s, seats staggered by id | holds | `PEER_LOCK_TTL` 120, `PEER_POLL_SEC` 5; the loop sleeps `((n-1)%4)*period/4` before the first tick |
| the fence and the 409 are the same gate | does not hold as written | `do_spl_peer_fence` is `spool claim --check` (exit 0 mine, 1 lost, 2 hub unconfirmed = do not act). `do_spl_peer_gate` calls that fence, then a mutex. HTTP 409 is answer-once: a second answer to the same generation (`answer_once.go`). Losing the lock and double-posting are different refusals |
| `responsible_gen`, `claim_n`, `not_by`, `handled_*` already exist; offer and park columns do not | holds | rdb `0110_messages_claim.sql` |
| `do_spl_peer_ensure` is an every-minute cron that will also keep the watchdog alive in P1 | the cron pattern holds; the watchdog keeper does not | `do_spl_peer_ensure` starts **poll loops only**, and returns immediately when `peer/seats` is empty. `/var/spool-hub/peer` is absent. `lease.conf` does name `LEASE_ORCH`, `LEASE_MASTER`, `LEASE_FAILOVER` (values not copied here). P1 has no seat file for ensure to watch |
| takeover steps name real 060 / peer-restart functions | the names exist (`spl_rotate_handoff`, `spl_peer_restart_seat`, `spl_rotate_input`, `spl_lease_modal_hit`) | not re-executed |

Section 1's lesson holds: activity is not progress, and today's two guards miss a login screen for the reasons in the table. The replacements below keep that lesson. They change the places the draft puts the lesson back.

## 1. Q1 — decentralization

**Replace section 3's "no single point of failure" paragraph, the layer-3 keeper cell, and section 5.3's fresh rule.** Agree with the rest of the shape: a shell loop per seat, a shell watchdog per box, hooks that write the beat (the model cannot forget), agents that only judge, and section 6.3 (a seat may request a takeover; it may not `kill` or `tmux kill`). The owner's "other agents kill it" is the loops taking the job and the local watchdog stopping the session. A model that kills peers is a second outage.

### 1.1 Replacement of section 3, the paragraph after the layer table

Delete the claim that the single point is gone because no role exists that one agent holds.

What is actually decentralized:

- Liveness is local. Each box reads its own heartbeat files, panes and transcripts. No seat is the only seat that can decide "that process is dead".
- A lock that is not renewed moves by time. Any other ready seat's loop can take it. That does not need an orchestrator.

What is not:

- The hub is still the arbiter of cross-box claim state. While Cloud SQL is down, 068's local `O_EXCL` covers only local-origin files on that box. Another box cannot see those claims, and web posts do not arrive. Say that in the table, as 068 section 7 already does. Do not score it as "no single point".
- P1 does not delete the lease. The 2026-10-05 hang is fixed by S2 marking the holder not able, after which the **existing standby** takes `LEASE_ORCH`. That is "the role fails over in minutes", which is the incident fix. It is not the decentralized end state. P2 is the point where the role disappears, and only if 068's cut-over has landed.

### 1.2 Replacement of section 3, layer 3 "if it dies"

`do_spl_peer_ensure` cannot be the watchdog's keeper until it grows a branch that runs with **zero seats**. Today an empty `peer/seats` returns success and starts nothing, and that is the live machine (no `peer/` directory). P1 lanes and role ids exist without seats.

Add a named action, `do_spl_wd_ensure`, same `* * * * *` cron pattern as peer-ensure, installed by an action, running whether or not `peer/seats` exists. It restarts `do_spl_watchdog` only. It does not start poll loops. Poll loops stay on `do_spl_peer_ensure` and stay inert until seats exist (068, unchanged).

### 1.3 Replacement of section 5.3

Section 1 says a beat counts only a tool call or a non-error reply. Section 5.3 then treats a moving spinner, or the mere fact of PARKED, as fresh. A spinning turn renews forever (S4 does not apply: there is no tool). A parked job renews with no beat at all until `parked_until` (up to 60 min, T6). Both break the owner's 2-minute rule, and both reintroduce "activity is progress".

Two clocks, written by the same hook file:

| clock | moves when | used for |
|---|---|---|
| **liveness** `ts` | any hook run, and the harness pid is alive | renew a **parked** lock; "the process is here" |
| **progress** `progress_ts` | PreToolUse, PostToolUse, or Stop whose last assistant entry is not an API error | renew an **owned** lock; "the model did the hard bit" |

| verdict | rule | the poll loop |
|---|---|---|
| **fresh** | `now - progress_ts <= HB_FRESH` (120 s), or `state=in-tool` and the tool's process still exists and `now - tool_since <= WD_TOOL_MAX[tool]` | renew an OWNED lock (T4) |
| **live** | `now - ts <= HB_FRESH`, `api_error` null, harness pid alive, `now < parked_until` | renew a PARKED lock. Park is not progress |
| **ready** | (fresh or idle) and `api_error` null and no situation hit and held `< PEER_MAX_HELD` (3) | may open or join a round (section 2) |
| **stale** | none of the above | no renew. OWNED and PARKED locks end at `locked_until` (at most 120 s) |

Spinner rule, replacing the unbounded "moved within 45 s" clause: a moving spinner may extend **fresh** by at most one extra `HB_FRESH` past `progress_ts` (a long answer or a compaction). It never renews on its own. A turn with no tool and no non-error Stop for 240 s is stale. A wait that is honestly longer is `--park`, renewed on **liveness**, not on the spinner.

Also replace the section 6.2 row "a long model turn with no tool" so it cites this 240 s bound, and the row "a background task / Monitor" so a park renews only while live. An idle agent that holds nothing is still never acted on.

`in-tool` stays the escape for a real Bash, Monitor or Workflow call, capped by S4's table. A tool whose process is gone is stale at once, not at `WD_TOOL_MAX`.

## 2. Q2 — which agent takes which job

**Replace section 4.3.** Agree with section 4.4's routing table, with one cell changed: "the first able poller" becomes "the seat that wins the round" (below). Keep topic stickiness, lane reports back to the spawner, a takeover offered to another harness, `not_by` for a harness that refused, and real work spawned as a new lane with the seat parked on the result.

Section 4.3 is not the owner's "fastest response". The loops are already phase-staggered by seat number (`spl_peer_loop`), so the lowest phase that is ready wins every new job. The winner then holds an exclusive offer for 45 s (`ACCEPT_SEC`) before anyone else may try. A seat that is fresh only because it is inside a tool (section 5.3) burns that 45 s unable to accept. Four such seats are three minutes of queue, on top of the 120 s lock. The draft rejects a broadcast because accepts would race and because every agent would pay the tokens of every body. The race is already settled by a compare-and-swap (068's `SKIP LOCKED` update, and T2's `responsible_gen` guard). The token cost is solved by not putting the body in the inbox.

### Replacement of section 4.3

One **round**, `OFFER_WINDOW` = 10 s. Not an exclusive 45 s hold.

1. The first ready loop to commit the claim statement **opens** the round. It sets `claim_state=offered`, `offer_until=now()+10s`, `responsible` NULL, `responsible_gen+1`. It does not become the owner. Opening uses the same `FOR UPDATE SKIP LOCKED` select 068 already runs, so two loops cannot open two rounds.
2. Every ready seat's loop, on its next tick inside the window, writes a **stub** into its own inbox: msg id, generation, one-line title, no body. It pokes. The body stays on the hub.
3. The seat that answers first runs T2. The statement updates one row (`claim_state` still `offered`, same generation, `offer_until` still ahead) and returns the body. One row means that seat owns it. Zero rows means it lost: drop the stub, do not answer, do not retry that generation.
4. Sticky follow-up (4.4's second row): the first window's cohort is only the topic's owner seat. If that window lapses, the next window is every other ready seat. A stale owner does not get the first window (insert as `free`, as the draft already says).
5. A seat at `PEER_MAX_HELD` writes no stub. A harness in `not_by` writes no stub.

Who takes the job is then the first agent that **accepts**, which is the fastest response, among seats the code has already decided are eligible. The code decides eligibility. The agent decides accept, release, or "this is lane work, spawn and park".

## 3. Q3 — the claim protocol

**Replace section 4.1's derived states, the actor of T3, the renew exemption in T6, and the second actor of T7.** Agree with the split the draft got right: the loop offers, the agent accepts with its own tool call, a generation fence makes a late agent harmless, `CLAIM_MAX` (4) dead-letters, park exists for an honest wait, and a harness refusal is remembered in `not_by`.

The protocol as written is not unambiguous:

- **Two true states at once.** FREE is `locked_until < now()` even when `accepted_at` is set. OWNED is `accepted_at` set. After expiry both predicates match. 068 does not have this bug: free is only `responsible` null or `locked_until` past, and that single predicate is what `claimFreeSQL` uses.
- **T3 has no actor.** "nobody: time" is also the step that appends `offered_to`. If no statement runs, the lapsed seat is offered again (FR-002 fails). Time is not a writer.
- **T6 cancels T5.** The loop renews a parked lock with no heartbeat until `parked_until` (60 min). Combined with section 5.3, a seat that parks and then dies holds the job for up to an hour. S1 does not fire, because parked counts as fresh.
- **T7 names two actors** and can move PARKED straight back to OWNED when "the event it waited for" arrives. A dead holder's loop would take the job back without an accept, which is the bug section 4 opened by splitting offer from accept.
- **409 is the wrong word for a lost lock.** A lost generation is fence exit 1: do not post, do not retry that generation. An unconfirmed hub is fence exit 2: do not post and do not assume the lock is lost. 409 is a second answer on a generation the seat still held (`answer_once.go`). Keep both. Do not collapse them.

### Replacement of section 4.1

One column, `claim_state`, written by the same statement that writes the clocks. The predicates in the draft become tests that this column matches, not a second definition readers can disagree on.

| `claim_state` | meaning | clocks written by the same statement |
|---|---|---|
| `free` | no round and no holder | `responsible` NULL, `accepted_at` NULL, `locked_until` NULL |
| `offered` | a round is open; nobody owns it | `offer_until`, `responsible_gen`, `offered_cohort text[]`, `responsible` NULL |
| `owned` | an agent accepted | `responsible`, `accepted_at`, `locked_until = now()+120s` |
| `parked` | the holder declared a wait | `responsible`, `parked_until`, `park_reason`, `locked_until = now()+120s` |
| `done` | closed | `handled_at`, `handled_how` (068) |

`offered_to` (seats or cohorts that let a round lapse, newest 4) and `not_by` stay. A row is in exactly one state.

### Replacement of T3, T6 and T7

| # | from -> to | actor | guard, one statement |
|---|---|---|---|
| T3 | `offered` -> `free` | the next loop that runs the claim statement, not "nobody" | `claim_state=offered AND offer_until < now()`. Same statement appends `offered_cohort` onto `offered_to` (cap 4) and increments `claim_n` **once per round**, then the row is `free`. A later T1 can open the next round |
| T6 | `owned` -> `parked` | the holding agent, `--park` | holder + gen; `parked_until` at most 60 min ahead. Renew (T4) while parked only on **liveness** (section 1.3), and only while `now < parked_until`. No liveness: do not renew; `locked_until` expires; the job is `free` inside 120 s. `parked_until` is the last moment a live holder may still be parked, not a renew exemption |
| T7 | `parked` -> `offered` | the holder's loop, when the waited event is visible, or the holder `--unpark` | holder + gen, and the holder's loop is live. Sets a new generation and a 10 s round whose first cohort is the holder. It does **not** set `owned`. A dead holder has no live loop, so this does not run; T5 frees the row |

T1, T2, T4, T5, T8, T9, T10 stay as in the draft, with these guards made exact:

- T1 opens a round only from `free` (including a row T3 or T5 just freed). It increments `responsible_gen`. It does not set `responsible`.
- T2 is the accept CAS in section 2. It sets `claim_state=owned`. It does not run unless the generation in the stub matches.
- T4 renews `locked_until` only under the fresh rule (owned) or the live rule (parked). The hub statement still refuses a renew whose `responsible` is no longer this seat.
- T5 is `locked_until < now()` on `owned` or `parked`, performed by the same statement as T3's actor (the next loop), which sets `claim_state=free` and clears `accepted_at`. It does not increment `claim_n` (expiry is not a failed delivery; a lapsed round is).
- The fence before any outward action reads `claim_state=owned AND responsible=me AND responsible_gen=gen`. Lost = fence exit 1. Hub silent = fence exit 2. Neither is a 409.

A late agent is harmless for the same reason 068 already gives: the generation moved, the fence fails closed, and answer-once still refuses a second post if a post is attempted anyway.

## 4. Scores

Draft, as written in v0.1. Replacement, if sections 3, 4.1, 4.3, 5.3, T3, T6 and T7 are changed as above and 6.2's long-turn row follows 5.3.

| property | draft | why |
|---|---|---|
| robust | 3 | Section 1 matches the stall and stuck code, and offer-versus-accept matches the real one-step claim. The fresh rule then counts a spinner and a park as progress, so the 2-minute lesson does not survive contact with T6 |
| failover-proof | 3 | An unrenewed lock does move, and any ready seat can take it. The hub is still required for a cross-box claim, P1 still fails over a role, and a parked dead seat does not move for up to 60 min |
| fast | 3 | The poll period is 5 s and the lock is 120 s, both already in `do_spl_peer_poll`. The exclusive 45 s offer plus phase-stagger is a queue, not the fastest accept. P1 login failover in about 4 min is a real improvement on a multi-hour blind renew |
| scalable | 4 | One indexed poll per ready seat per 5 s is the 068 shape, and the watchdog is local file and pane reads. Nothing here needs a model in the keeper |
| uninterruptible | 3 | Killing a poll loop loses no job once renew stops (FR-009's idea matches `locked_until`). The same is false while T6 renews without a beat, and a new claim does not proceed while the hub is down |

| property | replacement | why |
|---|---|---|
| robust | 4 | One `claim_state`, two clocks, and every transition has one writer. Hookless harnesses still use the weaker transcript path (S8); that stays open |
| failover-proof | 4 | A dead harness, including one that had parked, stops renewing and the job is free inside one TTL. Cross-box claims still need the hub; that cap is why this is not 5 |
| fast | 4 | A round is 10 s and every ready seat is poked with a stub, so the first accept wins. A long tool may still hold up to its S4 cap, on purpose |
| scalable | 4 | Stubs are one line per eligible seat per round; bodies are read by the winner only. Hub writes stay one CAS per open, per accept, per renew |
| uninterruptible | 4 | Session repair is local and optional to job movement. A hub outage still pauses new cross-box rounds; in-flight work finishes or expires on the clocks the loops already hold |

## 5. Left with the draft on purpose

- Situation list S1–S8, the false-positive table other than the two rows named above, and the takeover path through the existing 060 functions.
- Hooks as the only writer of the heartbeat, the inject hook never archiving and never accepting, and the per-harness ping before injection is trusted.
- Agents do not kill. The watchdog of the same box does, through `do_spl_wd_takeover`, and only on a situation that still hits.
- No code in this opinion. The columns and the keeper are for the tasks file after consensus.

<!-- version: 0.1.0-grok-2 · updated: 2026-10-05 · last-edit: 2026-10-05T20:10:00Z -->
