# 070 review (claude): can the design hit 3 s, and what is cheaper

Reviewer: c-134, independent of the draft's author. Reviewed spec.md draft
v0.1 (`d39d8050`) against the code on tree `origin/master` @ `fc19cdcd`.
Read-only: no hub, dev or prd was touched. Measured numbers below are quoted
from specs 030 and 053 with their own n. Nothing here was re-measured: this
lane ran no model call and no prd read.

## 1. Verdict

**R1 (3 s p95) is reachable, but not with the hop costs the budget assumes.**
The budget table (spec 6) counts the claim and the answer as warm-socket
hops. In the code each one is a **cold dial**, and the 0.5 s poll is
dial-bound, so it cannot tick at 0.5 s. With today's measured p95s the box
path spends its whole 3 s before the model starts. **R2 (180 s) is sound** for
signed posts, but it has two holes: unsigned posts and HANDOFF answers (4).

My main disagreement: **put the fast answer in the hub, not on the boxes.**
The hub already holds the post, the topic and a CPU that is always allocated.
One streamed API call from the hub removes five of the eight budget hops, the
claim race and every harness from the R1 path. The OD seats keep R3: the
ownership, the context and the work.

## 2. Hops the budget under-counts

| # | spec target | what the code does | measured (source, n) | gap |
|---|---:|---|---|---|
| 2 | 0.10 s | every `spool claim` opens a **one-shot role=cli session**: `grep -n 'one-shot' csi-spl-api/src/go/spool-hub-api/internal/hubclient/claim.go` -> line 12, `c.Dial(ctx, wire.RoleCLI)` at 15. A tick runs `--renew` and then `--poll`, two dials in series: `grep -n 'spl_peer_hub --renew\|spl_peer_hub --poll' csi-spl-orc/src/bash/run/spl-peer-poll.func.sh` -> 178, 187 | cold dial 588 ms p50, **1580 ms p95** (030, hub 0.1.17, n=20); 619.5 / 681.4 ms on 0.1.19 (n=12) | **~1.2 s p50, up to ~3.2 s p95**, against a target of 0.10 s |
| 2' | the poll "over the live sidecar socket" (spec 4.2) | no: the claim path never uses the 030 submit socket (`grep -c -i submit csi-spl-api/src/go/spool-hub-api/internal/hubclient/claim.go` -> 0) | - | the spec's DB-read row is wrong today |
| 1' | "4 queries/s from 2 boxes" | 4 seats x 2 dials x 2 ticks/s = **16 dials/s per box, 32 in total**, each with TLS, a challenge and a signed hello | - | 8x the stated load. The tick period becomes 0.5 s + two dials, so ~1.7 s p50 |
| 3 | 0.10 s, "with the topic tail" | the claim row carries the message only (`grep -n 'Msg  *json.RawMessage' .../internal/hub/box_claim.go` -> 57). The topic tail is one more hub read, so one more dial | 588 ms p50 cold | not in the table |
| 6 | 0.00 s | 068's fence (`--check`) before a post is another dial | 588 ms p50 cold | redundant: `answers=` + `if_gen` already enforce the fence atomically in the send (`answer_once.go:45`), so drop the pre-check |
| 7 | 0.15 s | `spool send` over the warm submit socket | 125 / 160 ms p50/p95 on a quiet box, **231.5 / 401.2 ms** with ~20 agents running (030, n=12 and n=20) | the box carries ~20 agents. Budget 0.40 s |
| 1 | 0.30 s | hub -> box | p95 **0.72 s** (053, n=149, prd 2026-09-30) | the spec admits this needs 053 fixes that have no lane in section 8 |
| 4 | 0.80 s | headless Claude Code first token | *I believe, unchecked*: a `claude -p` process sends Claude Code's own system prompt and tool list unless `--system-prompt` and `--tools` replace them (`claude --help \| grep -c -- '--tools'` -> 2, CLI 2.1.288). The 2.37 s p50 in 3.4 was this harness | needs the gate. A bare API call carries only our ~2k tokens |

Re-summed with the measured p95 where one exists (1: 0.72, 2: 2 x 1.58, 3:
1.58, 7: 0.40) and the spec's own targets elsewhere (4: 0.8, 5: 0.5, 8: 0.3),
the total is **~7.5 s p95**. Even with every dial on a warm socket, 1 + 7 + 8
alone are ~1.4 s p95 before the model starts.

## 3. Options it missed, ranked by gain / effort

| rank | option | gain | effort | why |
|---|---|---|---|---|
| **1** | **H. Hub-side fast responder.** On a stored `needs_peer` human post, the hub (a goroutine, not the request) reads the topic tail from its own store and makes one streamed model API call. It posts the text as the topic owner's stand-in, through the same `ClaimAnswer` row (`answers=`), so R5 holds. Then it pushes the message to the owner seat for the work | removes hops 1, 2, 3, 6 and 7. Budget: TTFT 0.8 + stream 0.5 + hub->WUI 0.3 = **~1.6 s**, 1.4 s margin | one hub lane + an API key in Secret Manager | the hub keeps CPU always on and at least one instance warm: `grep -n 'cpu_idle' csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf` -> 79 `false`; `grep -n min_instances csi-spl-cnf/csi-spl/all.env.yaml` -> 60 `1`. No box, no harness, no classifier in the path |
| 2 | **Push-assign** in place of pull-claim, if answers must come from boxes: the hub claims at insert time (owner seat first, else an able seat) and pushes the row and the topic tail in one frame on the live box socket | removes hops 2 and 3 and the 32 dials/s | medium: a hub-side seat choice needs a liveness signal per seat (today the hub knows liveness per box) | the claim is already hub state. A pull loop only adds round trips |
| 3 | Move the claim, renew, check and `send --answers` frames onto the 030 sidecar socket | ~0.5 s off each dial | small: 030 FP-2 did it for submit | needed by any box-side design, including the spec's |
| 4 | Stream into the WUI: post a placeholder and edit it as tokens arrive (`internal/hub/edit.go` exists) | the first words appear at ~1 s | small/medium | it does not change R1 ("full answer"), but it is what a human perceives. Watch edit fan-out and notification noise |
| 5 | The spec's **O+** (headless CLI per seat) | equal to H at best, after ranks 2 and 3 | large: 8 long-lived processes, stream-json unverified for grok, restart and liveness handling | I disagree with choosing it first. It spends subscription quota, the scarcer resource (the fleet stopped on a weekly limit on 2026-10-01), and it puts a harness back next to the answer. Keep warm sessions for the *work*, not for the 3 s text |

Cheap, independent of the choice above: **L6 and L7 first.** `fc19cdcd`
(after the spec) widened `do_spl_dispatch_setup`'s allow rules to reply, post
and archive. Rotation still does not rewrite them
(`grep -rln settings.local.json csi-spl-orc/src/bash/run` -> the setup and
check actions only), so L6 is still needed.

## 4. Risks

| risk | where | recommendation |
|---|---|---|
| **Double answer from RSP-01 / escalate.** The sweep calls a post unanswered when it has "no reply in its topic past the grace" (`grep -n 'no reply in its topic' .../internal/hub/fallback.go` -> 196), not when there is no `ClaimAnswer` row. A responder that posts without `answers=` slips past the 409 guard | spec 7, 120 s row | every answering path, including RSP-01, the fastcall and H, posts with `answers=<msg_id>`. Make one definition of answered (the answer row) and have the sweep read it |
| Late warm answer after the 10 s fallback | spec 7 | safe only if the fallback posts under the **same seat and gen**, so the late one gets `answered` 409. If the fallback runs as another identity it gets `not_responsible`. Test both in L2 |
| **HANDOFF counts as answered.** A HANDOFF reply ends the sweep's interest, so a promise that is never kept silently "meets" R2. The owner also rules out filler posts (HUM-10) | spec 5 | a HANDOFF must carry content (what is known now). The claim stays open (`handed:<lane>`) and the watchdog keeps watching it until the work post |
| **Unsigned posts never reach a box**: `grep -n fallback_unsigned .../internal/hub/fallback.go` -> 231 "stays browser-only" | R2 says "any post by anyone" | H answers them, since it needs no box. Otherwise R2 must state the exception |
| Confidently wrong fast answers: a small model with 2k tokens and no tools, asked "is lane X green?" | quality | system prompt: answer only from the topic tail, and name what the owner seat will check. The gate also samples correctness (n >= 20 hand-graded), not just latency |
| Cost per answer | Q1 | Haiku 4.5 at $1 / $5 per MTok (Anthropic price table, cached 2026-09-25): 2k in + 80 out ~= **$0.0024**, less with a cached system prompt. 1000 posts/day ~= $2.4/day. Not a constraint |
| Auto-mode refusals | build | no lane can mint or place the API key (a secret write). The owner does it, then a named action reads it. L8 on prd is also a refused mutation, so dev only, as the spec says |
| Dial storm | the 0.5 s poll | 32 cold sessions/s against one min-instance hub, every hello signature-verified. Do not ship the 0.5 s poll without rank 3, or only with rank 2 |

## 5. Owner questions (spec 10)

| Q | recommendation |
|---|---|
| Q1 | Haiku 4.5 (`claude-haiku-4-5`) first, and the grok fast tier in parallel. Keep whichever passes the gate on p95 **and** the graded correctness sample. One key per env. With H the key lives in Secret Manager in each GCP project, read by the hub SA, never in a tfvars or on a box. Box-side: one key file per box, 0600, outside every worktree |
| Q2 | Yes, and say it in the policy: "answers to human posts in seated workspaces are posted by code, not by a harness". With H it is the hub posting, so no box harness takes part at all |
| Q3 | Yes, scoped per seat and env as `fc19cdcd` already writes it, plus L6 (rewrite at every seat start, check as a start gate) |
| Q4 | Yes to push. The 0.5 s backstop is only honest over a warm socket (rank 3). With rank 2 or H a slow backstop is enough (5 s, as 068 fixed) |
| Q5 | `ANSWER_TIMEOUT` 4 s, not 10 s: past 3 s R1 is lost anyway, and the fallback then lands at ~6 s. 60 s watchdog: yes. `UnansweredGrace`: 60 s once every path writes the answer row. 170 s owner DM: yes |
| Q6 | Moot under H. Under O+ it is acceptable, if the stream log shows the post, the answer and the seat |
| Q7 | Yes, but `SQL=*` with a read-only *transaction* is not a guard: the SQL runs inside `BEGIN TRANSACTION READ ONLY` (`grep -n 'READ ONLY' csi-spl-orc/src/bash/run/spl-db-query.func.sh` -> 38), and a statement can end that transaction. Use a DB role with SELECT only for this action, then the allow rule is safe |

## 6. Top five

1. The budget under-counts the claim: two **cold dials** per tick (588 ms p50
   / 1580 ms p95 each, 030), plus one for the topic tail and one for the fence.
   Re-summed, ~7.5 s p95.
2. **Hub-side responder (H)**: one streamed API call from the hub (CPU always
   on, min 1 instance). ~1.6 s, no box and no harness in the path. Ranked
   above O+.
3. One definition of "answered": every path posts with `answers=`, and the
   unanswered sweep reads the answer row. Otherwise RSP-01 double-answers.
4. HANDOFF must not close the SLA, and unsigned posts are outside R2 today
   (`fallback.go:231`).
5. Q5: `ANSWER_TIMEOUT` 4 s. Q7: a SELECT-only DB role, not `SQL=*` in a
   read-only transaction.

<!-- last-edit: 2026-10-03T19:10:00Z -->
