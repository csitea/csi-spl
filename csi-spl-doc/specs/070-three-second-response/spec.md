# 070: three-second response - a model's full answer to a human post in <= 3 s

Status: **draft v0.1, owner questions open** (section 10; direct API calls
decided 18:30Z). Spec only: no code,
cron, cnf, setting or seat was touched. Draft 2026-10-03, c-132@sat, tree
`origin/master` @ `31053328`.
Related: [068 peer seats](../068-peer-seats/spec.md) (the OD 2+2 layout this
builds on: four ODs per box, two claude + two grok, the message claim, answer
once), [053 live delivery](../053-spool-live-delivery/spec.md) (transport
baseline), [030 wire fast path](../030-spool-wire-fastpath/spec.md) (hop
costs), [059 messaging backbone](../059-messaging-backbone/spec.md)
(LISTEN/NOTIFY), [SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md).
**Depends on** c-133's spec: the OD that takes a discussion owns it (R3).

`<pc box>` stands for the PC's box tag (box tags are banned literals in this
tree, as in specs 064 and 068).

## 1. What the owner asked (HUM-10, prd t1 #spool-hub-ops, topic `d40c3e2f`, verbatim)

The drill (topic `3074eb91-1c24-4679-9ee0-31b3e0528c05`, 18:15Z): "let's
perform a drill ... just answer hei to this msg". Then: "wow it takes more than
2 minutes for a simple hei in response".

> "analyse why a response to a simple session takes 2 minutes"

> "it has to be taken down to 3 seconds ... with the new OD 2+2 architecture - analyse and propose practical solutions how-to achieve that"

> ~18:23Z: "The 3 seconds is the target for a full answer of a model."

> ~18:26Z: "anyone writing anything should get answered within 3 minutes" and
> "Once an orchestrator dispatcher takes something, then he answers but he
> keeps the context of that discussion so he becomes the owner of that
> discussion."

> ~18:28Z: "I am even thinking of some kind of simple service which will run in
> a while loop. It will just select the new things from the SQL every half a
> second and output to multiple running CLI agents, just modifying that to
> basically write to the standard input of those CLI agents. They should start
> straight away answering, so once again using the same principle"

> ~18:29Z: "Using the same principle of automating as much as possible (what
> can be automated in code) and leaving as little as possible to the
> intelligence, just to be able to react and to provide some kind of
> intelligent answer"

> ~18:29Z: "But the purpose of this discussion is to be able to create proper
> specs so that we can reduce the response time to 3 seconds." / "Any
> opinions are welcome that will reduce the time to respond to 3 seconds."

> ~18:30Z, **decided** (to c-001@`<pc box>`'s fast-path question): "Yes the
> fast responder may call the API directly as well."

(Relayed to this lane by c-001@sat, task `drill-reply-latency`.)

## 2. Requirements

| id | requirement | measured by |
|---|---|---|
| **R1** | a human post in a seated workspace gets **a model's full answer visible in the WUI within 3 s, p95**, from the hub's receive time | the drill gate (section 9) |
| **R2** | **any** post by anyone gets an answer within **180 s, hard** (every post, every failure in the section 7 table) | the drill gate, failure rows |
| **R3** | the OD that takes a discussion keeps its context and owns it (c-133's spec). R1 and R2 must not wait on the owner seat being free | c-133's spec + the drill's "owner busy" row |
| **R4** | **code does routing, polling, claiming, delivery and posting; the model only reads the message and writes the answer** (owner, 18:29Z) | section 5: no hop of the chosen design is a model turn doing code's work |
| **R5** | exactly one answer per post, across 8 ODs on 2 boxes | 068 L2's answer-once guard (409 on a second answer) |
| **R6** | a harness refusal, a dead seat, a dead box or an API outage never leaves a post unanswered past R2 | section 7 |

## 3. Research: why "hei" took 2+ minutes

### 3.1 Evidence limits

| source | status |
|---|---|
| prd hub rows of 3074eb91 (`do_spl_db_query ENV=prd`, read-only) | **refused** for this lane by the auto-mode classifier, [Production Reads], 18:20Z; not read by any other route |
| `/var/spool-hub` on sat (lease.log, inboxes) | refused under the same denial |
| the PC box's spool files, the dispatchers' transcripts | not reachable from this lane |
| timestamps c-001 already held, and c-001@`<pc box>`'s inbox mtimes | used, each marked **relayed** |
| repo code, specs 030 and 053 | read; each claim cites its command |
| model and tool-call latency | measured on this lane's own session transcript (not prd data) |

### 3.2 Per-hop timeline, topic 3074eb91 (UTC, n = 1 drill unless noted)

| # | hop | when | latency | source |
|---|---|---|---|---|
| 0 | HUM-10 posts the drill | 18:15Z (seconds pending) | - | relayed: the prd unanswered sweep at 18:17Z shows 3074eb91 open, last human 18:15Z |
| 1 | hub -> desk sidecars of the seated members | pending | baseline p50 6 ms, p95 0.72 s (n=149 prd, 2026-09-30, 053 4.4) | pending prd read |
| 2 | sidecar -> desk inbox + pane poke of c-002@`<pc box>` | pending | baseline ~0.2 s to a live pane (n=24, 053 4.4); member delivery was instant on an 18:17:16Z post (relayed) | relayed |
| 3 | c-002's model turn -> `do_spl_desk_reply` | pending | pending | - |
| 4 | **refused**; c-002 files a post file instead | 18:16:01Z | <= ~61 s after hop 0 | relayed: file stamp `20261003T181601Z` |
| 5 | c-003's desk write **refused** | by 18:16:31Z | +30 s | relayed |
| 6 | dispatch lease flips during the ask | c-002->c-003 17:15Z, back 17:18Z, a pair ~18:14..18:24Z | - | relayed, task dispatch-lease |
| 7 | c-001@sat: DRY_RUN=1 passes; DRY_RUN=0 **refused**, [External System Writes] | ~18:17Z | - | relayed |
| 8 | hub fallback re-delivery to c-001@`<pc box>`'s desk inbox | +2:03 | **123 s, n=2** (18:15:22->18:17:25, 18:18:22->18:20:25) | relayed, inbox mtimes |
| 9 | the answer is visible | **never** (unposted at 18:21Z) | unbounded | relayed |

c-003's note that "c-001 posted it by hand" is wrong: nothing was posted (hop 7).

### 3.3 Causes

| cand. | verdict | the check |
|---|---|---|
| (a) the classifier refuses prd writes | **CONFIRMED, the root cause of "never"**: n=3 refusals in the drill (relayed). It refuses a lane's prd **reads** too (n=2, this lane). A refusal took 12.5 s and 15.3 s of deliberation (n=2, 3.4) and then nothing ran | (e1) explains why the allow rule did not apply |
| (b) delivery only as a pane line, no spool message | **CONFIRMED, by design**: a human post lands in the DESK root's inbox; only an agent-to-agent DM is copied to `/var/spool-hub/<id>/inbox` | `grep -n 'agentSender(m.From)' csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go` -> line 255, the `bridgeFleet` guard. 068 L3's loop writes the claimed message into the seat's inbox (`spl-peer-poll.func.sh` step 4), which closes it |
| (c) the lease flipping mid-ask | **CONFIRMED, a contributor**: two holders acted in 3 min and each was refused. 068 deletes the lease roles (L10) | hop 6 |
| (d) the model turn | **CONFIRMED, structural**: one Claude Code turn with one tool call is >= ~3.5 s p50 (3.4). It cannot fit R1 | 3.4 |
| (e1) **the allow rule is missing in re-created seat worktrees** | **CONFIRMED defect.** Only `do_spl_dispatch_setup` writes `.claude/settings.local.json` (one allow rule: the desk reply). No rotation action and no 068 peer action writes it | `grep -rln settings.local.json csi-spl-orc/src/bash` -> `run/spl-dispatch-setup.func.sh`, `run/spl-dispatch-check.func.sh`, `tests/dispatch-setup-check.tst.sh`; the rule: `grep -n 'Bash(' csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh` -> line 287. Relayed (prd `do_spl_dispatch_check`, sat, 18:25Z): GAP `c-00{2,3} desk-reply permission: no .../c-00N/.claude/settings.local.json` |
| (e2) the 2:03 is 068 L1's claim lock (`ClaimTTLDefault` 120 s) | **REFUTED**: the 2:03 is the hub's `UnansweredGrace` 120 s + the 5 s relay tick | `grep -n 'UNANSWERED_GRACE\|QUEUE_RELAY' csi-spl-api/src/go/spool-hub-api/internal/config/config.go` -> 288 `5s`, 303 `120s`; `grep -c ClaimTTL .../internal/hub/fallback.go .../internal/hub/relay.go` -> 0, 0; `ClaimTTLDefault` is used only at `internal/hub/box_claim.go:154` |
| (e3) the unanswered sweep could not help | it lists a post after 15 min, every 10 min, to the same refused path | fleet-roles 3.2 |
| (e4) no actor was allowed to post | the orchestrator, the seat that "runs the production operations agents' harnesses refuse", was refused too | fleet-roles 1, hop 7 |

### 3.4 What a model turn costs

Measured on this lane's own Claude Code session: claude-opus-5-5, auto mode,
low effort, ~20..80k-token context, tree `31053328`. Source: gaps between
timestamps in the session transcript.

| quantity | p50 | p90 | min / max | n |
|---|---:|---:|---:|---:|
| turn input -> first assistant output | **2.37 s** | 5.30 s | 1.53 / 20.86 s | 23 |
| an allowed tool call (classifier + exec + result) | ~0.7 s | ~2.8 s | 0.28 / 4.06 s | 24 |
| a **refused** tool call (deliberation, nothing runs) | - | - | 12.46 / 15.33 s | 2 |

The smallest session answer (turn -> one `do_spl_desk_reply` -> end) is
**~3.5..4 s p50 and 8 s+ p90 before any transport**. That rules out an
interactive agent turn that posts through its own tool call. The answer has to
come out of the model as text and be posted by code (R4).

### 3.5 Where a model turn does code's work today (R4 flags)

| # | job | today | code that should do it |
|---|---|---|---|
| F1 | notice a new post | the model reads a poke line and decides to look | the claim (068 L1) + a push (L1 below) |
| F2 | fetch the post | a `spool recv` tool call on the desk root | the loop hands the post on stdin (L2) |
| F3 | route (whose is it, is it a duplicate) | the routing rule table, judged by the model (fleet-roles 3) | the claim + the topic owner (c-133) + `needs_peer` |
| F4 | pick the topic and the human to answer | `DESK_TO` / `DESK_TASK`, typed by the model | known from the claimed row |
| F5 | post the answer | a `do_spl_desk_reply` tool call (refused in the drill) | the loop posts the model's stdout (L2) |
| F6 | close / ack | `do_spl_unanswered_ack`, `spool claim --done` by the model | the loop, on a successful post |
| F7 | fail over | the lease, judged by process + pane | the claim lock + the SLA watchdog (L4) |

## 4. Options

### 4.1 The answer engine

| option | what answers | R1 (3 s) | R4 | verdict |
|---|---|---|---|---|
| A. today: an interactive agent, poked, posts with a tool call | a Claude Code TUI turn | **no**: >= ~3.5..4 s p50, unbounded on a refusal or a busy pane (3.4) | fails F1..F6 | rejected for R1; kept only for work that needs tools |
| **O. the owner's option**: a 0.5 s SQL loop writes each new row to the stdin of running CLI agents | an agent process | **only as O+ below** | as written, the agent still posts (F5) | see 4.2 |
| **O+. O, done right**: claim first, a **headless** warm agent per seat, its real stdin, its stdout posted by the loop | a warm agent process | **yes** if the model is fast and the context small (4.3) | passes: the model only reads and answers | **chosen** |
| P. a stateless direct API call from the loop (proposed by c-001@`<pc box>`, posted in d40c3e2f) | one streamed model call, <= 2k-token prompt (post + topic tail + a cached system prompt) | **yes** | passes | **chosen as O+'s fallback** (seat busy, dead or refused) |
| R. reuse box-rsp `RSP-01` as the responder | today a non-AI responder that only hears escalations | no: `grep -n 'NON-AI' csi-spl-orc/src/bash/run/spl-responder-run.func.sh` -> "the PERMANENT, NON-AI responder", "in no channel", so it hears a post after the 120 s grace | - | kept as the R2 backstop (section 7), with P inside it |

### 4.2 The owner's option O, hop by hop

| # | hop | O as written | O+ |
|---|---|---|---|
| 1 | post -> visible to the loop | 0.5 s poll: 0.25 s avg, 0.5 s max | push (L1), with the 0.5 s poll as backstop |
| 2 | one agent takes it | several agents get it: two answer | 068 `claim` (SKIP LOCKED): exactly one seat |
| 3 | into the agent | an interactive agent's stdin is its tmux pane: today's poke, refused on unsent text (exit 6), queued behind a busy turn | a headless process's stdin, one user message per post (*I believe, unchecked here*, the claude CLI's print mode with stream-json input and output does this; grok's equivalent likewise; L2's first test proves it) |
| 4..5 | model | a big-context session: 2.37 s p50 to first output | a fast model, small warm context, streamed |
| 6 | post | the agent's tool call (+0.7 s, or refused) | **the loop posts the stdout** with `answers=<msg_id>` under the 068 fence |
| | DB read path | a box cannot read the hub's SQL; the Cloud SQL proxy is a seconds-long prd read the harness refuses | 068 L1's `claim --poll` frame over the live sidecar socket: 4 queries/s from 2 boxes at 0.5 s, on 068's partial index |

O+ keeps what the owner wants from O (warm agents that "start straight away
answering", and the topic's context, R3) and moves every code job out of the
model (R4).

### 4.3 The push

| option | hop 1 | verdict |
|---|---|---|
| 068 as written: poll every 5 s | avg ~1.25 s (four staggered loops), max 5 s: more than the whole budget | replaced |
| the owner's 0.5 s poll | avg 0.25 s, max 0.5 s; 2 boxes x 2 polls/s = 4 indexed reads/s | **kept as the backstop** |
| **push**: the hub sends a `claimable` hint over the box socket it already holds (053: p50 6 ms); the sidecar wakes the seat loops; or Postgres LISTEN/NOTIFY (059 step 1) | ~0.01..0.1 s | **chosen** |

## 5. Design

```text
human post -> hub (stored, needs_peer) --push--> box sidecar --wake--> seat loops (code)
                                                     \-- 0.5 s poll backstop --/
seat loop: claim (068, SKIP LOCKED; topic owner first, R3) -> stdin of its headless agent
headless agent (model): reads the post + topic tail -> writes the answer on stdout
seat loop: streams stdout -> post (answers=<msg_id>, fence) -> claim --done
on busy/dead/refused/timeout: the same loop makes ONE stateless API call (option P) instead
```

| step | who | R4 |
|---|---|---|
| notice, claim, pick the seat (owner seat first, else the first idle able seat) | code: the seat loop + the hub | code |
| hand over the post with the topic tail | code: stdin of the seat's headless agent | code |
| read and answer, or answer `HANDOFF: <one line>` when the post needs work | **the model** | the only model step |
| post the answer, close the claim | code: the loop, from stdout | code |
| work the answer promised (spawn, deploy, a lane's status) | the OD session (068), which owns the topic (R3) | model + tools, outside R1 |

- **The headless agent is the seat.** Each OD seat runs one headless agent
  process for answers (warm, small context, restarted with the seat at its
  068 slot). The seat's interactive session, if kept, does the tool work. The
  human keeps the tmux view: the seat's window tails the agent's stream log.
- **Topic owner (R3)**: the claim prefers the owner seat. When that seat is
  busy (its agent is mid-answer) or not able, the loop of the next idle seat
  answers **as the owner's stand-in**, with the topic tail as its context, and
  `responsible` keeps naming the owner. R1 never waits for one seat.
- **A HANDOFF answer is still a full model answer** (R1): it says what will
  happen and who holds it, and the OD session's work answer follows.

## 6. Budget (R1, p95 target)

| # | hop | target | today | by |
|---|---|---:|---|---|
| 1 | hub stored -> box | 0.30 s | p50 6 ms, p95 0.72 s (053, n=149) | p95 needs 053's live-socket fixes |
| 2 | box -> a seat holds it | 0.10 s | a poke queued behind a busy turn (unbounded); 068 L3: max 5 s | L1 push, L3 idle-first |
| 3 | stdin to the warm agent, with the topic tail (<= ~2k tokens) | 0.10 s | a `spool recv` tool call | L2 |
| 4 | model: first token | 0.80 s | 2.37 s p50 (3.4) | a fast model, small warm context, cached system prompt (*unchecked*: the gate measures it per vendor) |
| 5 | model: stream <= ~80 tokens | 0.50 s | - | L2 |
| 6 | the post is allowed | 0.00 s | refused (12..15 s, then never) | the loop posts (Q2) |
| 7 | answer -> hub | 0.15 s | `spool send` p50 21.5 ms + one RTT 61.5 ms (030, n=20) | already fits |
| 8 | hub -> WUI visible | 0.30 s | pending | the gate measures it |
| | **sum** | **2.25 s** | **unbounded** | margin 0.75 s |

**What cannot fit, plainly:** a Claude Code interactive turn that posts
through its own tool call (hops 3..6: >= ~3.5 s p50); a 5 s poll (hop 2);
and the *work* behind a post (a spawn, a deploy, a lane's status), which no
design does in 3 s. R1 is met by the model's answer text posted by code; the
work follows in the owner seat.

## 7. R2: the 180 s hard SLA

Each step runs only if nothing answered before it (hub clock, from the post):

| at | step | why this time |
|---|---|---|
| 0..3 s | push -> claim -> the warm agent answers (R1) | section 6 |
| ~10 s | the warm agent did not stream within `ANSWER_TIMEOUT` (10 s): the loop makes the stateless API call (option P) | a busy or hung agent |
| **60 s** | **SLA watchdog** (hub, L4): unanswered at 60 s -> release the claim, put the holder's harness into `not_by`; a seat of the **other** harness or box takes it and answers | 068's `LOCK_TTL` 120 s alone would hand over at 125 s, too late for a second try inside 180 s |
| 120 s | the hub's existing `UnansweredGrace` fallback to `RSP-01`, which with option P inside it answers (L5) | needs no OD at all |
| 170 s | still nothing: one owner DM from the hub: "unanswered: <topic>" | the breach is visible before it happens |

| failure | answered by | worst case |
|---|---|---|
| none | the warm agent | 3 s |
| seat agent busy / hung | the same loop's API call | ~13 s |
| a harness refuses (the drill) | no harness is in the post path (code posts); a refusal of the model call itself -> `not_by` -> the other harness | ~63 s |
| seat or box dead | another seat at the next push / 0.5 s poll after the lock or watchdog | ~63 s |
| model API down for one vendor | the other vendor's seats (2 + 2) | ~63 s |
| both vendors down | `RSP-01` at 120 s cannot write a model answer either: the 170 s owner DM | **R2 breached, visibly** |
| hub down | nothing can arrive (068 7) | - |

## 8. Lanes

Each is one small disjoint lane. All build on 068 L1..L3 (claim, answer once,
poll loop).

| lane | scope (files) | test |
|---|---|---|
| L1 hub + sidecar: push | a `claimable` hint on the box socket when a `needs_peer` row is inserted (hub `internal/hub`, `internal/hubclient`); the sidecar touches `<spool root>/peer/wake`; the 068 loop waits on it with the 0.5 s poll as backstop (`PEER_POLL_SEC` default 0.5) | `TestClaimablePush` (memory + Postgres): insert -> hint < 50 ms; `peer-poll.tst.sh`: a wake -> claim < 0.2 s, no wake -> claim <= 0.5 s |
| L2 orc: the seat answer engine | `do_spl_peer_answer`: one headless agent per seat, stdin/stdout bridge, the topic tail as context, posts stdout with `answers=` under the fence, `claim --done` | `peer-answer.tst.sh` with a stub agent: post -> answer posted once; a second seat's answer 409; stdout empty in 10 s -> fallback called; the first test proves the CLI's stream-json mode for claude and grok |
| L3 orc: claim order | owner seat first (c-133's field), else the first idle able seat (the pane spinner the able check already reads) | `peer-poll.tst.sh`: an owner busy -> the idle seat answers as stand-in; an owner idle -> the owner answers |
| L4 hub: the SLA watchdog | the 60 s release + `not_by` + the 170 s owner DM, one read on 068's partial index | `TestSLAWatchdog` (memory + Postgres): a held, unanswered row released at 60 s, the DM once at 170 s, none when answered |
| L5 orc: the stateless fallback | `do_spl_peer_fastcall`: one streamed API call, the key from a per-box key file (never in git, a log or a tfvars); used by L2 and `RSP-01` | a stub endpoint: stream -> one post; no key -> refuse, exit non-zero, nothing posted |
| L6 orc: seat permissions (only if Q3 = yes) | the seat start (`do_spl_peer_restart` / `do_spl_peer_setup`, and the dispatcher rotation until 068 L10) writes the approved allow rule into the seat worktree; `do_spl_dispatch_check`'s GAP row becomes a start gate | `dispatch-setup-check.tst.sh` extended: a re-created worktree gets the rule |
| L7 orc: OD membership | every OD seat is a member of every channel (a seat form of `do_spl_dispatch_subscribe`), so no post takes the 120 s fallback leg (member delivery instant, fallback 123 s, n=2 relayed) | `dispatch-check`: no GAP for any seat |
| **L8 the drill gate** | `do_spl_reply_drill`: n >= 20 simple asks in a test workspace, per-hop stamps (053's trace stages + the post and WUI times), p50 / p95 / max; then the section 7 failure rows (kill a seat, stop one vendor, n >= 5 each) | the gate itself (section 9) |
| L9 doc | fleet-roles 1..3 and 068's poll period and lanes point here | `do_check_dist_hygiene` |

Order: L7 and L6 (cheap, they unblock today's dispatchers too), then L1, L3,
L4, L5 in parallel, then L2, then L8. L9 last.

## 9. The gate

Done when `do_spl_reply_drill` on **dev** (prd only with the owner's go)
shows, in one recorded run on the tree it names:

- **R1**: p95 post -> full answer visible **<= 3 s**, n >= 20, per vendor;
- **R2**: every failure row of section 7 answered within 180 s, n >= 5 each;
- **R5**: zero double answers across the run;
- **R4**: zero model tool calls in the answer path (the agents' stream logs).

## 10. Owner questions

| # | question | why it is the owner's |
|---|---|---|
| Q1 | **Decided 18:30Z**: the fast responder may call the model API directly (section 1). **Still open**: which model per vendor, and the per-env key per box. Proposed: Haiku 4.5 (the current fast claude model) for the claude seats and grok's fast tier for the grok seats, each kept only if the gate shows p95 <= 3 s | billing, keys, vendor choice |
| Q2 | Are OD answers to human posts in seated workspaces **pre-approved prd writes**, posted by code from the model's text (no harness in the post path)? This is the same policy decision as Q3, not a way around the classifier | it is the policy the classifier enforces today |
| Q3 | For the tool-using OD sessions: the allow rule per seat `S` and env `E`, as setup writes it today: `"Bash(sudo -u <box user> env ENV=E TENANT_ID=* DESK_AGENT=S * ./run -a do_spl_desk_reply)"` in `<seat worktree>/.claude/settings.local.json`, `permissions.allow`, written at every seat start (L6). Yes / no | a permission rule |
| Q4 | Push + a 0.5 s poll backstop replaces 068's owner-fixed 5 s poll. Yes / no | 068 1.1 fixed the 5 s |
| Q5 | The SLA times: 10 s fallback, 60 s watchdog release, 170 s owner DM (and `UnansweredGrace` stays 120 s) | they define R2 |
| Q6 | A headless agent per seat for answers; the seat's tmux window shows its stream log rather than a TUI. Acceptable? | how the owner watches the fleet |
| Q7 | May lanes run read-only prd queries (`do_spl_db_query`, a read-only transaction)? Rule text: `"Bash(sudo -u <box user> env ENV=prd SQL=* ./run -a do_spl_db_query)"`. With no, this spec's 3.2 stays pending until c-001 or the owner reads it | a permission rule |

<!-- version: 0.1 · updated: 2026-10-03 · last-edit: 2026-10-03T18:45:00Z -->
