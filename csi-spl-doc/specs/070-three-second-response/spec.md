# 070: three-second response - a model's full answer to a human post in <= 3 s

Status: **draft v0.2, owner questions open** (section 11). Direct API calls
were decided 18:30Z. v0.2 folds in the owner inputs of 18:31Z, 18:41Z and
18:43Z (the standby pool, drill 2, the sizing) and the reviews
[review-claude.md](review-claude.md) (c-134) and
[review-grok.md](review-grok.md) (g-135).
Spec only: no code, cron, cnf, setting or seat was touched. Draft 2026-10-03,
c-132@sat; v0.2 on tree `origin/master` @ `f57365fe`.
Related: [068 peer seats](../068-peer-seats/spec.md) (the OD seats, the
message claim, answer once), [053 live delivery](../053-spool-live-delivery/spec.md),
[030 wire fast path](../030-spool-wire-fastpath/spec.md),
[059 messaging backbone](../059-messaging-backbone/spec.md),
[SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md).
**Depends on** c-133's spec: the agent that takes a discussion owns it (R3).

`<pc box>` stands for the PC's box tag (box tags are banned literals in this
tree, as in specs 064 and 068).

## 1. What the owner asked (HUM-10, prd t1 #spool-hub-ops, topic `d40c3e2f`, verbatim)

Drill 1 (topic `3074eb91-1c24-4679-9ee0-31b3e0528c05`, 18:15Z): "let's
perform a drill ... just answer hei to this msg". Then: "wow it takes more
than 2 minutes for a simple hei in response".

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

> ~18:30Z, **decided**: "Yes the fast responder may call the API directly as well."

> ~18:31Z: "Heck we can change the whole architecture to have multiple agents
> which are standing by because that doesn't cost money. There could be a
> small service which runs in a freaky while loop, just bombards whoever is
> available there, and monitors the memory usage (or we would have some kind
> of hard limit for faulty agents) or something like that. That service will
> just bombard the first available AI agent and that AI agent will start
> straight away. He will become the owner of the whole thing and then he'll
> start answering. After the discussion is closed that agent should basically
> kill himself, not be killed, but actually kill himself, or do some kind of
> flag file and then that service might end, something like that."

> ~18:41Z, drill 2 (topic `1bda0d49-d1d7-4d72-b0e7-3302b8d0c1e3`): "Okay this
> one was 20 seconds, which is much, much more acceptable but still we need to
> optimize it for a 3-second response."

> ~18:43Z: "Yes set the ODs in all of the workplaces and even increase the
> number. There could be something like, I would guess, a power of 2 or
> probably 8 ODs or something in the beginning and it couldn't end up on 32,
> for example, or 64. Actually I would guess that both the satellite and the
> tank box would be able to run 64 agents at once because not all of them will
> be consuming memory at the same time. There will probably be something like
> 20 which are actually doing some stuff and then the rest will be somewhat
> idle."

(Relayed to this lane by c-001@sat, task `drill-reply-latency`, and
`/var/tmp/c-001-briefs/spec070-owner-inputs.md`.)

## 2. Requirements

| id | requirement | measured by |
|---|---|---|
| **R1** | a human post in a seated workspace gets **a model's full answer visible in the WUI within 3 s, p95**, from the hub's receive time. The fast answer is short (Q6: about 80 tokens); longer content follows from the topic's owner agent | the gate (section 10) |
| **R2** | **any** post by anyone, unsigned posts included, gets an answer within **180 s, hard**. A HANDOFF does not count as an answer (section 7) | the gate, failure rows |
| **R3** | the agent that takes a discussion keeps its context and owns it until the discussion closes, then ends itself (c-133's spec; the owner, 18:26Z and 18:31Z). R1 never waits on the owner agent | c-133's spec + the gate's "owner busy" row |
| **R4** | **code does routing, polling, claiming, delivery and posting; the model only reads and answers** (owner, 18:29Z) | section 3.5: no chosen hop is a model doing code's work |
| **R5** | exactly one answer per post, across every responder (fast responder, pool agents, RSP-01): **one definition of answered = the `answers=<msg_id>` row** | 068 L2's answer-once (409 on a second) + the gate |
| **R6** | a harness refusal, a dead agent or box, or one vendor's API outage never leaves a post unanswered past R2 | section 7 |
| **R7** | the standby pool scales by powers of 2, from 8 to 32 or 64 per box (owner, 18:43Z), under a memory watch and a hard limit per agent (18:31Z) | section 8 |

## 3. Research

### 3.1 Evidence limits

| source | status |
|---|---|
| prd hub rows (`do_spl_db_query ENV=prd`, read-only) | **refused** for this lane by the auto-mode classifier, [Production Reads], 18:20Z; not read by any other route |
| `/var/spool-hub` on sat (lease.log, inboxes) | refused under the same denial |
| the PC box's files, the dispatchers' transcripts, the PC box's RAM | not reachable from this lane |
| timestamps held by c-001 and c-001@`<pc box>`, the owner's drill-2 timing | used, each marked **relayed** |
| repo code, specs 030 and 053, the two reviews | read; each claim cites its command |
| model and tool-call latency, session memory on sat | measured on this box: this lane's own transcript, `/proc`, `free`, `nproc` |

### 3.2 Drill 1 per-hop timeline, topic 3074eb91 (UTC, n = 1 unless noted)

| # | hop | when | latency | source |
|---|---|---|---|---|
| 0 | HUM-10 posts the drill | 18:15Z (seconds pending) | - | relayed: the prd sweep at 18:17Z shows 3074eb91 open, last human 18:15Z |
| 1 | hub -> desk sidecars of the seated members | pending | baseline p50 6 ms, p95 0.72 s (n=149 prd, 2026-09-30, 053 4.4) | pending prd read |
| 2 | sidecar -> desk inbox + pane poke of c-002@`<pc box>` | pending | baseline ~0.2 s to a live pane (n=24, 053 4.4) | relayed |
| 3 | c-002's model turn -> `do_spl_desk_reply` | pending | pending | - |
| 4 | **refused**; c-002 files a post file instead | 18:16:01Z | <= ~61 s | relayed: file stamp `20261003T181601Z` |
| 5 | c-003's desk write **refused** | by 18:16:31Z | +30 s | relayed |
| 6 | dispatch lease flips during the ask | 17:15Z, 17:18Z, a pair ~18:14..18:24Z | - | relayed, task dispatch-lease |
| 7 | c-001@sat: DRY_RUN=1 passes, DRY_RUN=0 **refused** [External System Writes] | ~18:17Z | - | relayed |
| 8 | hub fallback to c-001@`<pc box>`'s desk inbox | +2:03 | **123 s, 123 s, 372 s (n=3)**: 18:15:22->18:17:25, 18:18:22->18:20:25, 18:41:00->18:47:12 | relayed, inbox mtimes. The 372 s is consistent with a third attempt: the first escalation at 120 s, then a re-escalation every `ReescalateEvery` 120 s that rotates to the next responder (`grep -n REESCALATE_EVERY csi-spl-api/src/go/spool-hub-api/internal/config/config.go` -> 309 `120s`). *Unchecked* which agents the first two went to |
| 9 | the answer is visible | **never** (unposted at 18:21Z) | unbounded | relayed |

c-003's note that "c-001 posted it by hand" is wrong: nothing was posted.

**Drill 2 (topic 1bda0d49, 18:40Z) is today's baseline: 17..20 s end to end
(n=1).** The owner measured 20 s. By the timestamps it was 17 s: owner post
18:39:45Z -> c-001@sat's "hey" 18:40:02Z (relayed from c-001@`<pc box>`). The post reached c-001@sat as a member
delivery. Its `do_spl_desk_reply` was **not** refused, sent 18:40:02Z (msg
`bf9aa23e`). The gap was the model's turn: about 5 shell calls to resolve the
topic id, because the delivery notice carries only 8 hex
(`grep -n 'task:0:8' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh`
-> lines 170, 177) and `DESK_TASK` prefix resolution is skipped in DRY_RUN
(relayed by c-001).

### 3.3 Causes

| cand. | verdict | the check |
|---|---|---|
| (a) the classifier refuses prd writes | **CONFIRMED, the root cause of "never" in drill 1**: n=3 refusals (relayed). It refuses a lane's prd **reads** too (n=2). A refusal took 12.5 s and 15.3 s of deliberation (n=2) | (e1) |
| (b) delivery only as a pane line | **CONFIRMED, by design**: a human post lands in the DESK root's inbox; only an agent-to-agent DM is copied to `/var/spool-hub/<id>/inbox` | `grep -n 'agentSender(m.From)' csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go` -> 255 |
| (c) the lease flipping mid-ask | **CONFIRMED, a contributor** | hop 6; 068 deletes the lease roles |
| (d) the model turn | **CONFIRMED, structural**: >= ~3.5 s p50 for a turn with one tool call (3.4); drill 2 spent ~20 s in one turn with 5 calls | 3.4, drill 2 |
| (e1) the allow rule is missing in re-created seat worktrees | **CONFIRMED defect.** Only `do_spl_dispatch_setup` writes `.claude/settings.local.json`. `fc19cdcd` (after v0.1) widened its rules to reply, post and archive; rotation still does not write them | `grep -rln settings.local.json csi-spl-orc/src/bash/run` -> the setup and check actions only |
| (e2) the 2:03 is 068 L1's claim lock (`ClaimTTLDefault`) | **REFUTED**: it is the hub's `UnansweredGrace` 120 s + the 5 s relay tick | `grep -n 'UNANSWERED_GRACE\|QUEUE_RELAY' csi-spl-api/src/go/spool-hub-api/internal/config/config.go` -> 288 `5s`, 303 `120s`; `grep -c ClaimTTL .../internal/hub/fallback.go .../internal/hub/relay.go` -> 0, 0 |
| (e3) the unanswered sweep could not help | 15 min age, every 10 min, to the same refused path | fleet-roles 3.2 |
| (e4) no actor was allowed to post | the orchestrator was refused too | hop 7 |
| (e5) **every box-side claim and answer is a cold dial** (from the reviews) | **CONFIRMED**: `spool claim` dials a one-shot `role=cli` session, and so does the answer send. A poll tick dials twice (renew, then poll). The poll period must be a whole number | `grep -n 'c.Dial' csi-spl-api/src/go/spool-hub-api/internal/hubclient/claim.go` -> 15; `grep -n 'func (c \*Client) SendAnswerMessage' .../internal/hubclient/flush.go` -> 90 (dial at 103, per review-grok); `grep -n '\^\[1-9\]' csi-spl-orc/src/bash/run/spl-peer-poll.func.sh` -> 89. Cold dial 588 ms p50 / 1580 ms p95 (030, hub 0.1.17, n=20); 619.5 / 681.4 ms (030, hub 0.1.19, n=12) |
| (e6) **a watchdog release would not route away from the failed harness** (from review-grok) | **CONFIRMED**: `not_by` grows only on a `harness-refused:` reason | `grep -n 'harness-refused' csi-spl-api/src/go/spool-hub-api/internal/store/message_claim.go` -> 87, 168, 190 |
| (e8) **"no member agent online" while c-001..003 are subscribed** | **CONFIRMED, a misleading label, not a presence bug**: the box renders that text for EVERY channel fallback frame. The 120 s unanswered escalation reuses the same frame (`relay.go` `escalateUnanswered` -> `fallbackPost`), and no flag tells the box why. So "members online but nobody answered in 120 s" reads as "nobody online". Presence itself is `agentOnline`: a live box socket whose roster names the agent | `grep -n 'no member agent online' csi-spl-api/src/go/spool-hub-api/internal/hubclient/fallback.go` -> 73 (hardcoded in `FallbackPoke`); `grep -c scalat .../internal/hubclient/fallback.go` -> 0; `grep -n 'func (s \*Server) agentOnline' .../internal/hub/fallback.go` -> 74. Fix: the frame carries the cause (`offline` / `unanswered 120 s` / `re-escalation n`), and the label says it (L2) |
| (e7) **"answered" has two definitions** (from review-claude) | the escalation sweep means "no reply in the topic", not "no answer row", so a responder posting without `answers=` slips past the 409 | review-claude 4, `fallback.go:196` (unchecked by this lane) |

### 3.4 What a model turn costs (this lane's session)

claude-opus-5-5, auto mode, low effort, ~20..80k-token context, tree
`31053328`. Source: gaps between timestamps in the session transcript.

| quantity | p50 | p90 | min / max | n |
|---|---:|---:|---:|---:|
| turn input -> first assistant output | **2.37 s** | 5.30 s | 1.53 / 20.86 s | 23 |
| an allowed tool call (classifier + exec + result) | ~0.7 s | ~2.8 s | 0.28 / 4.06 s | 24 |
| a **refused** tool call | - | - | 12.46 / 15.33 s | 2 |

This prices a Claude Code harness turn, not a bare API call. *I believe,
unchecked* (review-claude), a headless `claude -p` still sends Claude Code's
own system prompt and tool list unless they are replaced. A bare API call
carries only our ~2k tokens. Its time to first token is the gate's to
measure (Q1).

### 3.5 Where a model turn does code's work today (R4 flags)

| # | job | today | code that should do it |
|---|---|---|---|
| F1 | notice a new post | the model reads a poke line | the hub (H, 5.1) or the pool service's push |
| F2 | fetch the post | a `spool recv` tool call | the hub's own store (H), or the claim reply with the tail (L4) |
| F3 | route | the routing table judged by the model | the claim + the topic owner + `needs_peer` |
| F4 | find the topic and the human | **~5 shell calls in drill 2** to resolve an 8-hex topic id | the full uuid + msg id in the notice (L0), or none at all (H) |
| F5 | post the answer | a `do_spl_desk_reply` tool call (refused in drill 1) | the hub posts (H); a pool agent's reply is posted by code from its output |
| F6 | close / ack | the model | code, on a successful post |
| F7 | fail over | the lease | the claim lock + the SLA watchdog |

## 4. Options

### 4.1 Who writes the 3 s answer

| option | R1 | R4 | verdict |
|---|---|---|---|
| A. today: an interactive agent, poked, posts with a tool call | no: ~3.5 s+ p50; drill 2 took 20 s; unbounded on a refusal | fails F1..F6 | rejected for R1; the work path only |
| O. the owner's 0.5 s SQL loop -> stdin of running CLI agents | only as O+ | as written the agent posts (F5) | 4.2 |
| O+. claim first, a headless warm agent's real stdin, code posts its stdout | box-side: needs every dial warm (e5) | passes | **an experiment the gate may promote** (both reviews) |
| P. box-side direct API call from the loop | yes **after** the warm-socket work (e5): 3.76 s p50 with cold dials, ~2.25 s with warm ones (review-grok 1) | passes | the box-side fallback |
| **H. hub-side fast responder** (review-claude rank 1): on a stored `needs_peer` human post, a hub goroutine reads the topic tail from its own store and makes one streamed API call; it posts with `answers=<msg_id>` as the owner agent's stand-in | **yes: ~1.6 s, 1.4 s margin** (6) | passes: no box, no harness, no classifier in the path | **chosen** for R1 |
| R. RSP-01, the non-AI responder | no: hears a post only after the 120 s grace (`spl-responder-run.func.sh:3`, "NON-AI") | - | the R2 backstop, posting with `answers=` |

Why H: the hub already holds the post and the topic; its CPU is always
allocated and one instance is always warm
(`grep -n 'cpu_idle' csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf`
-> 79 `false`; `grep -n 'min_instances' csi-spl-cnf/csi-spl/all.env.yaml` ->
60 `1`). It removes hops 1, 2, 3, 6 and 7 of the box path. It also answers
unsigned posts, which never reach a box (review-claude 4). The owner's
18:30Z decision covers "the fast responder may call the API directly".

### 4.2 The owner's options O (18:28Z) and the pool (18:31Z) in this design

The owner's loop is **the right place for routing**, and the reviews agree:
it becomes the pool service (5.2). It hands each new discussion to the first
free agent, and that agent owns it. What changes is only **who writes the
first 3 s of text**. A CLI agent's turn cannot (3.4, drill 2), so the hub's
fast responder writes it for the owner agent. The owner agent answers
everything after that with its context and tools. Q10 asks the owner to
confirm this split.

### 4.3 Push vs poll

| option | hop | verdict |
|---|---|---|
| 068 as written: each seat polls every 5 s, two cold dials per tick | max 5 s + ~1.2..3.2 s of dials | replaced |
| the owner's 0.5 s poll, per agent | 32+ cold sessions/s across two boxes (review-claude 2); the period check rejects a fraction (e5) | **not shipped on cold dials** |
| **one pool service per box, woken by a `claimable` push on the live box socket**, with a 0.5 s poll on the warm socket as backstop | ~0.1 s; 2 pollers in the fleet | **chosen** for the pool |
| H needs no push at all: it runs inside the hub | 0 | R1 path |

## 5. Design

```text
                       +--> H: hub fast responder --(answers=<msg>, <= ~80 tokens, ~1.6 s)--> WUI      [R1]
human post -> hub -----|
 (needs_peer)          +--> claimable push --> pool service (one per box, code) --> first free standby agent
                                                   |   claim on the warm socket, topic tail in the reply
                                                   |   the agent owns the topic (R3), works, posts follow-ups
                                                   |   topic closed -> the agent writes its done flag and exits itself
                                                   +-- reaps, refills to K idle, watches memory (R7)
SLA watchdog (hub): 60 s release with not_by -> another agent / vendor; 120 s RSP-01; 170 s owner DM  [R2]
```

### 5.1 H, the fast responder (R1)

| step | who |
|---|---|
| the post is stored and `needs_peer` | hub |
| read the topic tail (last ~5 messages) and the owner agent's id, if any | hub, from its own store: no dial |
| one streamed call, a <= ~2k-token prompt with a cached system prompt: "answer only from the topic; if work is needed, say what is known now and what the owner agent will check" | **the model**: the only model step |
| post with `answers=<msg_id>`, the owner agent named as responsible | hub |
| a deadline miss (`FAST_DEADLINE` 4 s): one call to the other vendor; still nothing: leave the post to the owner agent and the watchdog | hub |

- **A HANDOFF must carry content.** It says what is known now; a bare "on
  it" is refused as filler (`action/filler.go`, the owner's no-filler rule).
  The claim stays open (`handed:<agent>`), and the watchdog keeps watching it
  until the owner agent's work post (R2).
- **Quality**: answer from the topic tail only. The gate grades n >= 20
  answers by hand, not only their latency (review-claude 4).
- **Cost**: *relayed from review-claude*, Haiku 4.5 at $1 / $5 per MTok:
  2k in + 80 out ~= $0.0024 an answer, about $2.4 a day at 1000 posts.

### 5.2 The standby pool (R3, R7)

| piece | does |
|---|---|
| `do_spl_pool_serve` (one per box, a shell while-loop) | woken by the `claimable` push (0.5 s warm-socket poll as backstop): claims each **new** discussion for the **first free standby agent** on this box; follow-ups in an owned topic go to their owner agent; keeps `POOL_IDLE_MIN` agents idle and spawns up to `POOL_MAX` (8, 16, 32 or 64) |
| a standby agent | a pre-started session, idle until handed a topic (idle costs no tokens). Handed one, it reads the topic, posts follow-ups with content, does the work, and owns the topic until it closes |
| self-end (owner, 18:31Z) | when its topic closes, the agent writes `<spool root>/pool/<id>/done` and exits itself (`/exit-clean`). The service reaps the window and refills the pool. It never kills a healthy agent |
| memory watch / hard limit | per agent: process-tree RSS over `POOL_RSS_MAX`, or a turn frozen past `PEER_PROGRESS_MAX` -> the service releases its topics with `not_by` and stops it (the "faulty agent" case). Per box: available memory under `POOL_MEM_FLOOR` -> no new agent is spawned and no new topic is handed to a busy one |
| the posts it makes | an agent's text is posted by code with the claimed topic and msg id: no `DESK_TASK` typed by the model (F4, F5) |

### 5.3 Transport fixes every box-side path needs (from the reviews)

- `claim`, `renew`, `--check` and `send --answers` frames on the warm 030
  sidecar socket instead of a cold `role=cli` dial (e5);
- the topic tail returned inside the claim reply (one round trip);
- no separate fence pre-check before a post: `answers=` + `if_gen` already
  fence it atomically in the send (review-claude 2, `answer_once.go:45`, unchecked by this lane);
- a fractional poll period accepted (`spl-peer-poll.func.sh:89`).

## 6. Budget (R1, p95 target)

| # | hop | H target | box path on today's code (reviews) |
|---|---|---:|---|
| 1 | post stored -> responder holds it | 0.01 s (in process) | p95 0.72 s hub -> box (053) |
| 2 | claim | 0 (the hub is the claimant) | 2 cold dials per tick: 1.58 s p95 each |
| 3 | topic tail | 0.02 s (own store) | one more cold dial |
| 4 | model: first token | 0.80 s | same |
| 5 | model: stream <= ~80 tokens | 0.50 s | same |
| 6 | the post is allowed | 0 (code posts) | 0 with code posting |
| 7 | answer stored | 0.02 s | a cold dial (`SendAnswerMessage`) |
| 8 | hub -> WUI visible | 0.30 s | same |
| | **sum** | **~1.65 s, margin 1.35 s** | **~7.5 s p95** (review-claude), 3.76 s p50 (review-grok) |

Today: drill 2, 17..20 s (n=1). Drill 1, never. The fallback leg, 123..372 s
(n=3).

**What cannot fit, plainly:** an agent turn that posts through its own tool
call (3.4: >= 3.5 s p50; drill 2: 20 s); a box path on cold dials; and the
*work* behind a post, which no design does in 3 s. R1 is the fast responder's
short answer. The owner agent's work follows.

**Hop 4 is unchecked.** 0.8 s to first token for a fast model with a ~2k-token
cached prompt is an assumption. The gate measures it per vendor before Q1
picks one.

## 7. R2: the 180 s hard SLA

Each step runs only if no `answers=` row exists yet (hub clock, from the post):

| at | step |
|---|---|
| 0..2 s | H answers (R1) |
| 4 s | H's first vendor missed `FAST_DEADLINE`: one call to the other vendor |
| ~10 s | the owner agent (pool) has the topic and answers with its context |
| **60 s** | **SLA watchdog** (hub): release the claim **with `not_by`** for the holder's harness (e6), so another agent or vendor takes it |
| 120 s | `UnansweredGrace` -> RSP-01 (with a fast call inside it), posting with `answers=` (R5) |
| 170 s | one owner DM from the hub: "unanswered: <topic>" |

| failure | answered by | worst case |
|---|---|---|
| none | H | ~1.7 s |
| one vendor slow or down | H's second vendor | ~6 s |
| both vendors down | the owner agent (subscription, not API) | ~10..60 s |
| owner agent dead, frozen or over its memory limit | the watchdog -> another standby agent | ~65 s |
| a box down | the other box's pool | ~65 s |
| hub down | nothing can arrive (068 7) | - |
| every responder down | the 170 s owner DM | **R2 breached, visibly** |

## 8. Sizing the pool (owner, 18:43Z)

Measured on sat, 2026-10-03 ~18:50Z, as the agent user (n per row):

| quantity | value | command |
|---|---|---|
| box RAM | 62 GiB total, 51 GiB available | `free -g` |
| cores | 16 | `nproc` |
| an **idle** claude session (<= 13 CPU ticks in 10 s) | PSS 215..249 MB, RSS 329..364 MB, **n=4** (c-002, c-003, c-131, c-134) | `/proc/<pid>/smaps_rollup` Pss; `ps -o rss` |
| a busy claude session | PSS 298..337 MB, RSS 405..418 MB, n=3 | same |
| a grok session (both busy) | PSS 423..449 MB, RSS 474..499 MB, n=2 | same |
| agent windows on the box now | 12 | the ceiling count of the repo CLAUDE.md |

n=4 idle is under the n >= 5 asked for; no idle grok session was available
to measure. The PC box was not measured (no shell from this lane).

| pool | idle sessions (44 at ~0.36 GB RSS) | 20 busy sessions (~0.45 GB) | what is left of 51 GiB for the work the busy ones run |
|---|---:|---:|---:|
| 64 per box | ~16 GB | ~9 GB | **~26 GB** |
| 32 per box | ~4 GB (12 idle) | ~9 GB | ~38 GB |

**The sessions fit; the work decides.** An idle session costs ~0.36 GB and
almost no CPU. A busy agent's tool runs (a Go test suite, a browser e2e run)
cost far more than its session and are not measured here. So the memory
watch (5.2) is the real limit, not the pool size. Start at 8, double while
`POOL_MEM_FLOOR` holds over a day.

**Quota, not memory, is the scarce resource.** An idle session costs no
tokens. Twenty busy sessions on one login burn its weekly limit twenty times
as fast, and on 2026-10-01 the whole fleet stopped on one login's weekly
limit (global agent rules). The pool spreads over both vendors and logins.

### 8.1 Ids

Spec 061: `^[acgq]-[0-9]{3}$`; 068 reserves 001..004 per box for the fixed
OD seats; lanes allocate from the cursor. Pool agents end themselves when
their topic closes (owner, 18:31Z), so they behave like lanes, not seats.
**Proposed:** pool agents take ordinary ids from the cursor, with kind `pool`
in `registry.tsv`; the fixed seats stay 001..004. 64 pool + lanes stay inside
the 996 free numbers per letter (Q8).

### 8.2 The 40-window ceiling

The global and repo rules cap a box at 40 concurrent agent windows, counted
by window name. 64 pool agents alone break it. **Proposed (Q9):** the ceiling
counts **busy** agents (a held topic or a lane task), at most 40. Idle pool
agents are bounded by `POOL_MAX` and the memory floor instead. This changes a
standing owner order, so it is the owner's call.

## 9. Lanes

| lane | scope | test |
|---|---|---|
| **L0 quick win** | the delivery notice carries the full topic uuid and the msg id (`spool-notify.inc.sh` 170, 177) | `spawn-agents/tests`: the poke line holds both ids. Cuts drill 2's ~5 resolve calls today |
| L1 hub: fast responder H | a goroutine on a stored `needs_peer` human post (unsigned included): the tail from the store, one streamed call, post with `answers=`, `FAST_DEADLINE` + the second vendor, the content rule for a HANDOFF; the key from Secret Manager, read by the hub SA (a terraform secret resource; the value is placed by the owner, never in a tfvars, a log or git) | `TestFastResponder` (memory + Postgres, a stub model): post -> one answer row; deadline -> second vendor; a second responder 409; a filler body refused |
| L2 hub: one definition of answered + the watchdog | the sweep, RSP-01 and the escalations read the `answers=` row; the 60 s release sets `not_by`; the 170 s owner DM; the fallback frame carries its cause and the box labels it (e8) | `TestSLAWatchdog`: release at 60 s with `not_by`, DM once at 170 s, none when answered; RSP-01 never double-answers |
| L3 hub + sidecar: push and warm frames | a `claimable` hint on the box socket; claim / renew / check / `send --answers` on the warm socket; the tail inside the claim reply | `TestClaimablePush`, `TestClaimWarmSocket`: no `role=cli` dial on the claim path |
| L4 orc: the pool service | `do_spl_pool_serve`, its `_install_cron` (ensure), first-free hand-out, follow-ups to the owner, reap on the done flag, refill, memory watch, `POOL_MAX` 8/16/32/64 | `pool-serve.tst.sh` with stub agents: first free wins; a done flag is reaped and refilled; RSS over the cap -> released + stopped; floor hit -> no spawn |
| L5 orc: the pool agent contract | the seed: own the topic, post content only, write the done flag and `/exit-clean` on close; the topic owner field per c-133 | a stub run: close -> flag -> exit 0 |
| L6 orc: permissions at every start | the start of a seat, a pool agent and the rotation writes setup's allow rules (`fc19cdcd`) into its worktree; the check's GAP row becomes a start gate (Q3) | `dispatch-setup-check.tst.sh` extended |
| L7 orc: ids and the ceiling | kind `pool` in the registry; the ceiling count of busy agents (Q8, Q9) | `test-agent-id-map.sh` extended; a ceiling fixture |
| **L8 the gate** | `do_spl_reply_drill`: n >= 20 asks in a test workspace, per-hop stamps, p50 / p95 / max per vendor, a hand-graded sample; then the section 7 failure rows (n >= 5 each) | the gate itself (section 10) |
| L9 WUI (only if Q6 = no cap) | stream into a placeholder that is edited as tokens arrive (`internal/hub/edit.go`) | e2e: first words visible in ~1 s |
| L10 doc | fleet-roles and 068 point here | `do_check_dist_hygiene` |

Order: L0 now (it cuts today's 20 s). Then L1 + L2 (they meet R1 and R2
alone), L6, then L3, L4, L5, L7 for the pool. L8 gates each step. L9 only on
Q6. L10 last.

## 10. The gate

Done when `do_spl_reply_drill` on **dev** (prd only with the owner's go)
shows, in one recorded run on the tree it names:

- **R1**: p95 post -> full answer visible **<= 3 s**, n >= 20, per vendor,
  and a hand-graded sample with no wrong answer;
- **R2**: every failure row of section 7 answered within 180 s, n >= 5 each;
- **R5**: zero double answers, including a slow responder finishing after a
  release;
- **R4**: zero model tool calls in the R1 path.

## 11. Owner questions

| # | question | reviews |
|---|---|---|
| Q1 | **Decided 18:30Z**: direct API calls. Open: the model per vendor, picked by the gate (fastest non-reasoning model of each vendor, kept if p95 <= 3 s and the graded sample passes); the key per env in Secret Manager, placed by you | both: measure before naming |
| Q2 | The **hub** (H) posts the fast answer as the owner agent's stand-in, rather than a box. Yes / no (no = box-side P after the L3 transport work) | claude: H; grok: box-side P first |
| Q3 | Setup's allow rules (reply, post, archive, `fc19cdcd`) are written at every seat, pool-agent and rotation start | both: yes |
| Q4 | One pool service per box, woken by a push, with a 0.5 s warm-socket poll as backstop, instead of a 0.5 s poll per agent | both: no 0.5 s poll on cold dials |
| Q5 | Times: `FAST_DEADLINE` 4 s, the watchdog 60 s (with `not_by`), RSP-01 at 120 s, the owner DM at 170 s | claude: 4 s, `UnansweredGrace` 60 s later; grok: keep 120 s |
| Q6 | Cap the fast answer at about 80 tokens, with longer content from the owner agent. Or no cap, and stream into the WUI (L9) | grok: cap |
| Q7 | Lanes may run read-only prd queries through a **SELECT-only DB role** (not `SQL=*` in a read-only transaction, which a statement can end) | claude: role; grok: reject writes |
| Q8 | Pool agents take ordinary ids with kind `pool`; 001..004 stay the fixed seats | - |
| Q9 | The 40-window ceiling counts busy agents; idle pool agents are bounded by `POOL_MAX` and the memory floor | - |
| Q10 | The first 3 s answer comes from the fast responder; the pool agent that takes the topic owns it and answers everything after. Your 18:31Z words have that agent "start answering" itself, which a CLI turn cannot do in 3 s (3.4, drill 2) | - |

<!-- version: 0.2 · updated: 2026-10-03 · last-edit: 2026-10-03T19:00:00Z -->
