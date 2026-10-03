# 070: three-second response - a model's full answer to a human post in <= 3 s

Status: **draft v0.4, owner questions open** (section 11). v0.4: the pool
service is a native Go process on both boxes (owner, 19:15Z; 5.2, L3). v0.3 applied the
owner's answers of 18:50Z: **the 3 s answer is the call response of a
standby agent on the box** (Q2 = boxes, Q10 = no), which reverses v0.2's
hub-side fast responder. v0.2 folded in the owner inputs of 18:31Z, 18:41Z
and 18:43Z and the reviews [review-claude.md](review-claude.md) (c-134) and
[review-grok.md](review-grok.md) (g-135); both reviewed v0.1.
Spec only: no code, cron, cnf, setting or seat was touched. Draft 2026-10-03,
c-132@sat; v0.4 on tree `origin/master` @ `d4d693a8`.
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

> ~18:50Z, **answers to v0.2's section 11** (msg `a0ba23fe`): "Q2: fast
> responder in the hub, or on the boxes? Boxes Q6: cap the 3 s answer at ~80
> tokens, with the full work from the topic owner? Yes Q8: the id scheme for
> pool agents As the current scheme: rolling ID numbers, like C or G or
> A-3-digit at box name Q9: the 40-window ceiling counts busy agents only? Yes
> Q10: the first 3 s answer comes from the fast responder, not a pool agent?
> No, 3 seconds should be the call response. That is an agent who is on
> standby."

> 2026-10-03 ~19:15Z, #spool-hub-devel topic `55c97c00` (msgs `3b3e7ca5`,
> `6e263273`): "Yeah and the service could be created in Go so that it would
> be extremely fast. The polling service" and "And I would guess that it
> should run natively both on the satellite and on the tank box."

(Relayed to this lane by c-001@sat, task `drill-reply-latency`, and
`/var/tmp/c-001-briefs/spec070-owner-inputs.md`.)

## 2. Requirements

| id | requirement | measured by |
|---|---|---|
| **R1** | a human post in a seated workspace gets **the call response of a standby agent on a box: a full answer of about 80 tokens, visible in the WUI within 3 s, p95**, from the hub's receive time (Q2 boxes, Q6 yes, Q10 no). Longer work follows from the same agent, now the topic's owner | the gate (section 10) |
| **R2** | **any** post by anyone, unsigned posts included, gets an answer within **180 s, hard**. A HANDOFF does not count as an answer (section 7) | the gate, failure rows |
| **R3** | the agent that takes a discussion keeps its context and owns it until the discussion closes, then ends itself (c-133's spec; the owner, 18:26Z and 18:31Z). R1 never waits on the owner agent | c-133's spec + the gate's "owner busy" row |
| **R4** | **code does routing, polling, claiming, delivery and posting; the model only reads and answers** (owner, 18:29Z) | section 3.5: no chosen hop is a model doing code's work |
| **R5** | exactly one answer per post, across every responder (standby agents on both boxes, RSP-01): **one definition of answered = the `answers=<msg_id>` row** | 068 L2's answer-once (409 on a second) + the gate |
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
| (e8) **"no member agent online" while c-001..003 are subscribed** | **CONFIRMED, a misleading label, not a presence bug**: the box renders that text for EVERY channel fallback frame. The 120 s unanswered escalation reuses the same frame (`relay.go` `escalateUnanswered` -> `fallbackPost`), and no flag tells the box why. So "members online but nobody answered in 120 s" reads as "nobody online". Presence itself is `agentOnline`: a live box socket whose roster names the agent | `grep -n 'no member agent online' csi-spl-api/src/go/spool-hub-api/internal/hubclient/fallback.go` -> 73 (hardcoded in `FallbackPoke`); `grep -c scalat .../internal/hubclient/fallback.go` -> 0; `grep -n 'func (s \*Server) agentOnline' .../internal/hub/fallback.go` -> 74. Fix: the frame carries the cause (`offline` / `unanswered 120 s` / `re-escalation n`), and the label says it (L5) |
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
| F1 | notice a new post | the model reads a poke line | the pool service, woken by the hub's push (L2) |
| F2 | fetch the post | a `spool recv` tool call | the claim reply, with the topic tail inside it (L2) |
| F3 | route | the routing table judged by the model | the claim + the topic owner + `needs_peer` |
| F4 | find the topic and the human | **~5 shell calls in drill 2** to resolve an 8-hex topic id | the claimed row carries both (L2); today: the full uuid + msg id in the notice (L0) |
| F5 | post the answer | a `do_spl_desk_reply` tool call (refused in drill 1) | code posts the standby agent's streamed output (L3) |
| F6 | close / ack | the model | code, on a successful post |
| F7 | fail over | the lease | the claim lock + the SLA watchdog |


## 4. Options

### 4.1 Who writes the 3 s answer

| option | R1 | R4 | verdict |
|---|---|---|---|
| A. today: an interactive agent, poked, posts with a tool call | no: ~3.5 s+ p50 (3.4); drill 2, 17..20 s; unbounded on a refusal | fails F1..F6 | rejected for R1 |
| H. a hub-side fast responder (v0.2's choice, review-claude rank 1) | ~1.65 s | passes | **rejected by the owner** (Q2 = boxes, Q10 = no, 18:50Z). Not kept as a hidden fallback |
| P. a stateless direct API call from the box loop (review-grok's primary) | ~2.25 s on warm sockets | passes | **not the owner's model** (Q10: the answer is a standby agent's call response). It is kept only as **Q11 (a)**, the owner's to choose if the gate shows a warm agent turn cannot fit |
| **S. a standby agent on the box** (the owner's 18:28Z loop + 18:31Z pool + 18:50Z Q10): the pool service hands the post to a warm, idle agent process on its stdin; the agent's streamed call response is posted by code; the agent then owns the topic | **only if its turn is warm** (6.2) | passes when code posts its output | **chosen** |
| R. RSP-01, the non-AI responder | hears a post after the 120 s grace | - | the R2 backstop: it forwards to any standby agent |

### 4.2 Push vs poll (unchanged from v0.2)

| option | hop | verdict |
|---|---|---|
| each seat polls every 5 s, two cold dials per tick (068 as written) | max 5 s + ~1.2..3.2 s of dials | replaced |
| a 0.5 s poll per agent on cold dials | 32+ cold sessions/s across two boxes (review-claude 2) | not shipped |
| **one pool service per box, woken by a `claimable` push on the live box socket**, a 0.5 s poll on the warm socket as backstop | ~0.1 s | **chosen** |

## 5. Design

```text
human post -> hub (needs_peer) --claimable push--> pool service (one per box, a native Go process)
   claim on the warm socket, topic tail in the reply (one round trip)
   -> stdin of the FIRST FREE standby agent (warm, idle, headless)          [R1: the call response]
   <- its streamed answer (<= ~80 tokens, no tool call) -> code posts it with answers=<msg_id>
   the same agent now owns the topic (R3): it works with tools, posts follow-ups,
   and on close writes its done flag and exits itself; the service reaps and refills (R7)
SLA watchdog (hub): 4 s next standby, 60 s other box, 120 s RSP-01, 170 s owner DM   [R2]
```

### 5.1 The standby agent

| state | what it is |
|---|---|
| **standby** | a pre-started agent CLI process (claude or grok), authenticated, its session prompt already sent once (a warm-up turn primes the provider's prompt cache), **idle on its stdin**. Idle costs no tokens (owner, 18:31Z) |
| **call response** | the pool service writes one user message on stdin: the post, the topic tail (<= ~2k tokens), and the instruction "answer in about 80 tokens from this topic only; if work is needed, say what is known now and what you will check". **No tool call in this turn.** Code reads the streamed output and posts it with `answers=<msg_id>` |
| **owner** | from the next turn on, the same agent owns the topic (R3, c-133): it uses its tools, posts follow-ups with content (never filler), and answers further posts in the topic |
| **done** | the topic closes: the agent writes `<spool root>/pool/<id>/done` and exits itself (`/exit-clean`); the service reaps it and starts a new standby |

- **Code reads the agent's output**, so the standby runs headless: stream
  output on stdout, one user message per line on stdin. *I believe,
  unchecked*, the claude CLI's print mode with stream-json input and output
  does this; grok's equivalent is unchecked. L1 proves both. The agent's tmux
  window tails its stream log, so the fleet stays visible in tmux (Q13).
- **A post in an owned topic whose owner is mid-turn** goes to a free standby
  agent for the call response, written for the owner (who is named as
  responsible). The owner reads it on its next turn. R1 never waits for a busy
  owner.

### 5.2 The pool service (owner, 18:28Z, 18:31Z and 19:15Z)

**A Go program, run natively on both boxes** (owner, 19:15Z: "created in Go
so that it would be extremely fast", "run natively both on the satellite and
on the tank box"). Not a container, not a shell loop.

| piece | does |
|---|---|
| **`spool pool serve`** (Go, a new subcommand of the `spool` binary in the csi-spl-api module, `cmd/spool`) | one process per box. It holds ONE warm session on the hub's box socket: the `claimable` push wakes it, and a 0.5 s poll on the same warm socket is its backstop (no cold dial, e5). It claims each new post, hands a new topic to the first free standby, and a follow-up to its owner or, when the owner is busy, to a standby. It writes the post + topic tail to the agent's stdin, reads its streamed output, and posts it with `answers=<msg_id>` (F4, F5). It keeps `POOL_IDLE_MIN` standby agents and grows `POOL_MAX` 8 -> 16 -> 32 -> 64 |
| handover deadline | no first token from the standby in `CALL_DEADLINE` (4 s): the next free standby of the other vendor takes it (the first one's late output is refused by `answers=`, R5) |
| memory watch / hard limit (owner, 18:31Z) | per agent: process-tree RSS over `POOL_RSS_MAX`, or no progress for `PEER_PROGRESS_MAX`: release its topics with `not_by`, stop it, refill. Per box: available memory under `POOL_MEM_FLOOR`: spawn no new agent. Read from `/proc` in Go, no shell-out |
| reaping | the agent's `<spool root>/pool/<id>/done` flag (it ends itself, owner 18:31Z): the service reaps the window and starts a new standby |
| **`do_spl_pool_serve`** (orc, bash) + `do_spl_pool_serve_install_cron` (`* * * * *`, tag `# csi-spl:pool-serve`) | **only install, start and keep the Go binary running.** No routing, claiming or posting in bash |

**The native install and start path, the same on sat and on the PC box.**
It reuses the path the desk sidecars already run on:

1. **Build and install**: `spl_host_spool`
   (`csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:236`) builds the
   `spool` binary on the host with `csi-spl-api/src/bash/build.sh` (the
   host Go toolchain) into `$SPL_STATE_DIR/bin/spool`
   (`$HOME/.local/share/csi-spl/cloud/<env>/bin/spool`). It keeps the binary
   when it was built from this tree's HEAD, builds when the tree is newer,
   refuses a downgrade, and renames the build into place atomically. Being a
   subcommand of the same binary, the pool service needs no new artefact and
   no new build step.
2. **Start**: `do_spl_pool_serve` (`ENV=<env>`) runs `spool pool serve
   --env <env> --box <desk box>` detached, as the box user, from that binary,
   with its pid in `<spool root>/pool/serve.pid` and its log under the box's
   log dir. Already running from the current binary: nothing to do.
3. **Keep running**: the cron runs `do_spl_pool_serve` every minute. A dead
   process is restarted. A process older than the installed binary (a new
   build) is restarted, the rule the desk reconcile already applies to a
   sidecar whose binary was rebuilt (fleet-roles 4.2, Rollout).
4. **Both boxes**: the PC box runs the same action from its own checkout, its
   own state dir and its own desk box. *Unchecked from this lane* whether the
   PC box's desk sidecar is built by this same path (no shell there). L3's
   acceptance runs on both boxes. Spec 068 8.1 holds: the cron line resolves
   to a repo checkout, nothing under `/var/tmp` or a home dir.

### 5.3 Transport fixes on the critical path (the reviews, e5)

`claim`, `renew`, `--check` and `send --answers` on the warm 030 sidecar
socket, not a cold `role=cli` dial; the topic tail inside the claim reply; no
separate fence pre-check (`answers=` + `if_gen` fence the send atomically,
review-claude 2, unchecked by this lane); a fractional poll period accepted
(`spl-peer-poll.func.sh:89`). Without these, R1 is lost before the model
starts (~7.5 s p95, review-claude).

## 6. Budget (R1, p95, a standby agent on the box)

### 6.1 Per hop

| # | hop | p95 budget | basis | measured or estimate |
|---|---|---:|---|---|
| 1 | post stored -> `claimable` on the box | 0.40 s | today p95 0.72 s, p50 6 ms (053 4.4, prd, 2026-09-30) | **measured, n=149**; 0.40 s needs 053's live-socket work |
| 2 | claim on the warm socket, tail in the reply | 0.16 s | the 030 submit leg on a warm socket, p95 160 ms (hub 0.1.19) | **measured, n=12** (a proxy: a send, not a claim) |
| 3 | stdin write to the idle standby | 0.01 s | a local pipe | estimate, n=0 |
| 4 | the standby's first token | **0.90 s** | the only measured agent-CLI turn: 2.37 s p50, 5.30 s p90 (3.4: Opus-class, 20..80k context, auto mode, a busy session) | **measured n=23, and it does NOT fit**; 0.90 s is an **estimate** for a warm, short-context, fast-model turn, n=0 |
| 5 | stream ~80 tokens | 0.60 s | ~135 tokens/s | estimate, n=0 |
| 6 | code posts with `answers=` on the warm socket | 0.40 s | 030 submit p95 160 ms quiet (n=12), 401 ms with ~20 agents running (n=20) | **measured** |
| 7 | hub -> WUI visible | 0.30 s | one socket write in the same process (review-grok 1) | estimate, n=0 |
| | **sum** | **2.77 s** | margin 0.23 s | 3 of 7 hops measured |

With today's hop 1 (0.72 s p95), the sum is 3.09 s: **over by 0.09 s**. R1
needs both 053's live-socket work (hop 1) and a warm turn (hop 4).

### 6.2 Can a standby agent-CLI turn fit 3 s? Plainly

**Not on any number measured today.** The one measured agent-CLI turn takes
2.37 s p50 and 5.30 s p90 to its first token (n=23). That alone is more than
the 1.5 s the model gets (hops 4 + 5), before it writes a word. Both reviews
put a cold turn at 5..15 s. Drill 2 took 17..20 s.

It can fit **only as a warm turn**, and each of these is needed:

| # | what makes the turn warm | removes |
|---|---|---|
| W1 | **pre-started**: the process is running, authenticated, idle on stdin | process start, login, CLI init |
| W2 | **primed**: a warm-up turn already sent the session prompt, so the provider's prompt cache holds it | re-reading the long prefix on the first token |
| W3 | **short context**: a replaced, short system prompt; for the call response, no tool list or a minimal one; the post + <= ~2k tokens of topic tail | the 20..80k context of 3.4 |
| W4 | **a fast model** for the call response (claude's fast tier; grok's fast tier) | the large model's first-token time |
| W5 | **streamed** output, read by code as it arrives | waiting for the turn to end |
| W6 | **the ~80-token cap** (Q6 yes) and **no tool call** in the call-response turn | generation time; a tool call's 0.7 s (or a 12..15 s refusal) |
| W7 | **a fresh agent**: a standby has no history, and owners hand off when their context grows | context growth |

Whether W1..W7 bring the first token under 0.90 s p95 is **unmeasured** (n=0).
So **L1 measures it first**, before anything else is built: a warm standby per
vendor, n >= 20 call responses, first token and last token.

**If it does not fit, the smallest change, for the owner to pick (Q11):**

| option | change | cost |
|---|---|---|
| (a) | the call response skips the agent's own model loop: the pool service makes one streamed API call **on the standby agent's behalf**, posted as that agent, and the agent stays the owner and does the work (the API was allowed 18:30Z) | the agent did not write its own first 80 tokens. Q10 asked for the agent's call response, so this is the owner's call, not a quiet fallback |
| (b) | R1 counts the **first words** visible in 3 s, streamed into a placeholder that is edited as tokens arrive (`internal/hub/edit.go`) | a looser R1 than "full answer" |
| (c) | accept the measured p95 (e.g. 4..5 s) | misses 3 s |

## 7. R2: the 180 s hard SLA

Each step runs only if no `answers=` row exists yet (hub clock, from the post):

| at | step |
|---|---|
| 0..3 s | a standby agent's call response (R1) |
| 4 s | no first token (`CALL_DEADLINE`): the next free standby, other vendor, same box |
| **60 s** | **SLA watchdog** (hub): release the claim **with `not_by`** (e6), so the other box's pool takes it |
| 120 s | `UnansweredGrace` -> RSP-01 (non-AI) forwards it to any free standby agent, on either box |
| 170 s | one owner DM from the hub: "unanswered: <topic>" |

| failure | answered by | worst case |
|---|---|---|
| none | a standby agent | ~3 s |
| that standby is slow or its vendor is down | the other vendor's standby | ~7 s |
| no free standby on the box, or the box is down | the other box's pool | ~63 s |
| the pool service is dead | `do_spl_pool_serve`'s ensure cron restarts it; else the watchdog | ~63 s |
| both vendors down | nothing can write an answer | **R2 breached; the 170 s DM** |
| hub down | nothing can arrive (068 7) | - |
| an unsigned post (it never reaches a box, `fallback.go:231` per review-claude) | **open, Q14** | - |

## 8. Sizing the pool (owner, 18:43Z)

Measured on sat, 2026-10-03 ~18:50Z, as the agent user (n per row):

| quantity | value | command |
|---|---|---|
| box RAM | 62 GiB total, 51 GiB available | `free -g` |
| cores | 16 | `nproc` |
| an **idle** claude session (<= 13 CPU ticks in 10 s) | PSS 215..249 MB, RSS 329..364 MB, **n=4** | `/proc/<pid>/smaps_rollup` Pss; `ps -o rss` |
| a busy claude session | PSS 298..337 MB, RSS 405..418 MB, n=3 | same |
| a grok session (both busy) | PSS 423..449 MB, RSS 474..499 MB, n=2 | same |
| agent windows on the box now | 12 | the ceiling count of the repo CLAUDE.md |

These were interactive sessions. A headless standby process was not measured.
n=4 idle is under the n >= 5 asked for, no idle grok session was available,
and the PC box was not measured.

| pool | idle sessions (~0.36 GB RSS each) | 20 busy (~0.45 GB) | left of 51 GiB for the busy agents' tool runs |
|---|---:|---:|---:|
| 64 per box | 44: ~16 GB | ~9 GB | **~26 GB** |
| 32 per box | 12: ~4 GB | ~9 GB | ~38 GB |

**The sessions fit; the work decides.** A busy agent's tool runs (a Go test
suite, a browser e2e run) cost far more than its session and were not
measured, so the memory watch (5.2) is the real limit. Start at 8, double
while `POOL_MEM_FLOOR` holds for a day.

**Quota is the scarcer resource.** An idle standby costs no tokens. Twenty
busy agents on one login burn its weekly limit twenty times as fast, and the
whole fleet once stopped on one login's weekly limit. The pool spreads over
both vendors and over logins.

### 8.1 Ids (Q8, decided 18:50Z)

The current scheme: pool agents take rolling ids, `c-`, `g-` or `a-` plus 3
digits, at the box name (spec 061). `registry.tsv` marks them kind `pool`;
nothing else changes.

### 8.2 The 40-window ceiling (Q9, decided 18:50Z)

The ceiling counts **busy** agents only (a held topic or a lane task), at most
40 per box. Idle standby agents are bounded by `POOL_MAX` and the memory
floor. The ceiling's count command and the global agent rules change to
match (L7).

## 9. Lanes

| lane | scope | test |
|---|---|---|
| **L0 quick win** | the delivery notice carries the full topic uuid and the msg id (`spool-notify.inc.sh` 170, 177) | `spawn-agents/tests`: the poke line holds both ids. Cuts drill 2's ~5 resolve calls today |
| **L1 first: the standby benchmark** | `do_spl_standby_bench`: one warm standby per vendor (W1..W7), n >= 20 call responses on dev; first token, last token, output size; proves the headless stdin/stdout mode for claude and grok | its own report. **Decides Q1 (the model) and Q11** before L3..L5 are built |
| L2 hub + sidecar: push and warm frames | a `claimable` hint on the box socket; claim / renew / check / `send --answers` on the warm socket; the tail inside the claim reply; a fractional poll | `TestClaimablePush`, `TestClaimWarmSocket`: no `role=cli` dial on the claim path |
| L3 api + orc: the pool service | **Go**: `spool pool serve` in `csi-spl-api/src/go/spool-hub-api` (`cmd/spool` + an `internal/pool` package): the warm box session, first free standby, follow-ups to the owner or a standby, `CALL_DEADLINE` handover, the stdin/stdout bridge, posts with `answers=`, reap on the done flag, refill, memory watch, `POOL_MAX`. **orc**: `do_spl_pool_serve` + `do_spl_pool_serve_install_cron` only install (`spl_host_spool`), start and keep the binary running, natively on sat and on the PC box | Go `TestPoolServe` (stub agents, a stub hub): first free wins; a deadline hands over and the late answer gets 409; done -> reaped and refilled; RSS cap -> released and stopped; floor -> no spawn. bash `pool-serve-ensure.tst.sh`: not running -> started; dead -> restarted; a newer binary -> restarted; running and current -> untouched; the cron line resolves to a checkout (068 8.1) |
| L4 orc: the standby agent contract | the headless start, the warm-up turn, the call-response prompt (no tools, ~80 tokens), the owner phase, the done flag and `/exit-clean`; the topic owner field per c-133 | a stub run through all four states |
| L5 hub: one definition of answered + the watchdog | the sweep, RSP-01 and the escalations read the `answers=` row; the 60 s release sets `not_by`; the 170 s owner DM; the fallback frame carries its cause (e8) | `TestSLAWatchdog`; RSP-01 never double-answers |
| L6 orc: permissions at every start | the start of every agent writes setup's allow rules (`fc19cdcd`) into its worktree; the check's GAP row becomes a start gate (Q3) | `dispatch-setup-check.tst.sh` extended |
| L7 orc: ids and the ceiling | kind `pool` in the registry; the busy-only ceiling count in the count command and the agent rules (Q8, Q9 decided) | `test-agent-id-map.sh` extended; a ceiling fixture |
| **L8 the gate** | `do_spl_reply_drill`: n >= 20 asks in a test workspace, per-hop stamps, p50 / p95 / max per vendor, a hand-graded sample; then the section 7 failure rows (n >= 5 each) | the gate itself (section 10) |
| L9 WUI (only if Q11 = b) | stream into a placeholder edited as tokens arrive | e2e: first words in ~1 s |
| L10 doc | fleet-roles and 068 point here | `do_check_dist_hygiene` |

Order: L0 now (it cuts today's 17..20 s). **L1 next, alone**: its numbers
decide whether S can meet R1 and which model to run. Then L2 + L5 + L6 in
parallel, then L3 + L4 + L7, then L8. L9 only on Q11 (b). L10 last.

## 10. The gate

Done when `do_spl_reply_drill` on **dev** (prd only with the owner's go)
shows, in one recorded run on the tree it names:

- **R1**: p95 post -> a standby agent's full call response visible
  **<= 3 s**, n >= 20, per vendor, and a hand-graded sample with no wrong
  answer;
- **R2**: every failure row of section 7 answered within 180 s, n >= 5 each;
- **R5**: zero double answers, including a standby that finishes after its
  `CALL_DEADLINE` handover;
- **R4**: zero model tool calls in the call-response turn.

## 11. Owner questions

| # | question | state |
|---|---|---|
| Q1 | The standby model per vendor: picked by L1 (the fastest model whose warm call response fits), not named in advance | open: L1 measures |
| Q2 | fast responder in the hub, or on the boxes? | **decided 18:50Z: boxes** |
| Q3 | Setup's allow rules (reply, post, archive, `fc19cdcd`) are written at every agent start | open (both reviews: yes) |
| Q4 | One pool service per box, woken by a push, with a 0.5 s warm-socket poll as backstop, instead of a 0.5 s poll per agent | open (both reviews: no 0.5 s poll on cold dials) |
| Q5 | Times: `CALL_DEADLINE` 4 s, the watchdog 60 s (with `not_by`), RSP-01 at 120 s, the owner DM at 170 s | open |
| Q6 | cap the 3 s answer at ~80 tokens, with the full work from the topic owner? | **decided 18:50Z: yes** |
| Q7 | Lanes may run read-only prd queries through a SELECT-only DB role | open |
| Q8 | the id scheme for pool agents | **decided 18:50Z: the current scheme** (rolling ids at the box name) |
| Q9 | the 40-window ceiling counts busy agents only? | **decided 18:50Z: yes** |
| Q10 | the first 3 s answer comes from a fast responder, not a pool agent? | **decided 18:50Z: no**, the call response of a standby agent |
| **Q11** (new) | If L1 shows a warm standby turn cannot reach the first token in ~0.9 s p95: (a) the pool service makes the call response one direct API call on the standby agent's behalf, and the agent stays the owner; (b) R1 counts the first words visible in 3 s (streamed); or (c) accept the measured p95 | new, raised by Q10 |
| **Q12** (new) | The standby agent's model: the call response needs a fast model (W4), while the owner phase does real work. One fast model for the whole life of a pool agent, or a switch of model after the call response (*unchecked* whether the CLIs can switch inside a headless session) | new |
| **Q13** (new) | Standby agents run headless (code must read their output); each agent's tmux window tails its stream log instead of showing an interactive screen. Acceptable? | new |
| **Q14** (new) | An unsigned post never reaches a box (review-claude, `fallback.go:231`). With the responder on the boxes: let the hub forward unsigned posts to the pool, or keep them outside R2 | new, raised by Q2 |

<!-- version: 0.4 · updated: 2026-10-03 · last-edit: 2026-10-03T19:30:00Z -->
