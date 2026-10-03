# Review: 070 three-second response

Reviewer g-135. Spec `d39d80503913b5830e89b386db4e28d4ebc2784d` (ancestor of `fc19cdcd`, origin/master when this was written). Code read on that tree. No prd query and no hub write. The model timings in spec section 3.4 were not remeasured here.

## Verdict

The 2.25 s table meets 3 s after two transports change and the fast answer stays about 80 tokens. On this tree the claim and the `answers=` post each open a new hub session, and the topic tail is a third fetch. Those three sit outside the table. Paying them, a p50 path is already past 3 s before the p95 tails.

Make the direct API call the primary path. Keep the warm CLI as an experiment the gate can promote. The 180 s ladder can hold once a release puts the harness in `not_by`.

## 1. Budget against the code

Transport numbers below are quoted from spec 030 §0.5, not remeasured here. Version: hub `0.1.19`, commit `2e4c1ce`, quiet box, n=12. Dial leg (cold session, CLI spawn included): p50 619.5 ms, p95 681.4 ms. Submit leg (warm sidecar socket): p50 125 ms, p95 160 ms. TCP+TLS first byte, hub `0.1.17`, commit `39a5a25`, n=20: p50 220.6 ms, p95 266.5 ms.

| hop | budget | on this tree |
|---|---:|---|
| 1 hub stored to box | 0.30 s | 053 baseline p95 0.72 s (n=149, 2026-09-30). A hint on the live box socket can hit 0.30 s. Cross-process wake is already LISTEN/NOTIFY (`internal/hub/wake.go`). L1 still has to send the `claimable` hint. |
| 2 a seat holds it | 0.10 s | `Client.Claim` dials `role=cli` (`hubclient/claim.go:15`). Same shape as the 619 ms dial leg. L1 adds a wake file. It leaves the claim on the cold dial. |
| topic tail | (absent) | `claimCols` (`message_claim_postgres.go:21`) returns that one message. A tail is another `spool` call. |
| 3 stdin to the agent | 0.10 s | Unchecked, as the spec says. A one-shot CLI start misses 0.10 s. |
| 4+5 model | 1.30 s | Unchecked for a direct call. The 2.37 s p50 (spec 3.4, n=23, Claude Code turn) prices the harness, so it does not price a raw API call. 0.50 s covers about 80 tokens. R1 has no token cap, and `fanoutWUI` (`wui.go:850`) sends one stored row, so the human sees text when generation finishes. |
| 6 the post is allowed | 0.00 s | Holds when the loop calls `spool send` itself. A harness tool call is the path the drill refused. |
| 7 answer to hub | 0.15 s | `SendAnswerMessage` dials and is never queued (`flush.go:86-103`), so it skips the warm submit socket. The nearest number is the 619 ms dial leg, where the table uses 21.5 ms + 61.5 ms. |
| 8 hub to WUI | 0.30 s | A socket write on the same process while `max_instances` is 1 (`csi-spl-cnf/csi-spl/all.env.yaml`). Plausible on a live tab. A deploy drops every browser socket; reconnect wait starts around 250-500 ms (`live-ws.mjs`, `reconnectDelayMs`). |

Two cold dials, one tail fetch, and a model that hits 1.30 s: 0.30 + 0.62 + 0.62 + 1.30 + 0.62 + 0.30 = 3.76 s at the dial p50. Drop the tail fetch and it is still about 3.14 s.

Put claim and `answers=` on the warm socket (submit p95 160 ms) and return the tail inside the claim, and 2.25 s is the right sum. L1 and L2 as written do neither.

Each seat tick dials twice (`spl-peer-poll.func.sh:178` renew, `:187` poll). Four seats on two boxes at 0.5 s is 32 cold sessions a second. The spec's "4 queries/s" is one poller per box. `PEER_POLL_SEC` rejects a fraction (`spl-peer-poll.func.sh:89`, `^[1-9][0-9]*$`).

## 2. Ranked changes

1. **Warm socket for claim and for `answers=`.** About 1 s back. Effort medium. The submit socket already exists. `SendAnswerMessage` stays synchronous: the comment at `flush.go:86` is right that a queued flush skips the guard. The frame carries `answers` and `if-gen`, and the hub answers before the call returns.
2. **Direct API call as the primary (option P). Warm CLI as the experiment.** The owner already allowed the API call. The topic tail is the context a warm process would have kept, without a classifier and without an unproven stdin protocol. L5 is the smaller build. Promote O+ only when the gate shows it is faster.
3. **Tail inside the claim statement.** One round trip back. Effort small.
4. **One poller per box**, woken by the push, handing the row to the owner seat or the first idle engine. Matches the spec's own query math. Effort small.
5. **Cap the fast answer at about 80 tokens.** Longer work goes out as `HANDOFF:`. This is what makes hop 5 true. A 400-token answer at 150 tokens/s is 2.7 s of generation after the first token, and nothing is on screen before that single post. Write the cap into R1.
6. **Token streaming into the WUI**, only if the owner refuses the cap. It changes when the first word appears. The clock on "full answer visible" stays on the last token.

O+ as the chosen primary is the wrong default. The owner's loop is the right place for routing. The text should come from one streamed call.

## 3. Risks

- **Double answers.** `SKIP LOCKED` plus the unique `answers=` row holds for two guarded posts. `applyRelease` (`message_claim.go:188`) clears `responsible` and adds `not_by` only when the reason starts with `harness-refused:`. A 60 s watchdog that releases without that reason lets the same harness take the row again. A late post that skips `--answers` is a second visible body. The gate's zero-double row has to include a slow stdout that finishes after the release.
- **Lost posts.** Close the claim only after the hub accepts the answer. A send error leaves the row open for the next seat.
- **Short bodies.** `IsFiller` (`action/filler.go`) refuses a human-facing body that is only "on it", "received" or "ack". "hei" is outside that list. A HANDOFF that is only a status word never appears, and the claim stays open until the watchdog.
- **Cost.** Eight always-on CLI processes (four seats, two boxes) are the standing cost. A direct call bills per answer. The 32 cold sessions/s above is what a naive 0.5 s poll costs.
- **Able check.** L3's idle-first reads the pane spinner (`spl_peer_able`). A headless process has no spinner. Busy means the stdout bridge is open.
- **Classifier.** Q2 takes it off the post path. A headless Claude Code with tools still on can spend 12-15 s on a refused tool call (spec 3.4, n=2) inside the 10 s timeout. Turn tools off, or skip the harness CLI.
- **Both vendors down.** The 170 s owner DM is the honest breach. `RSP-01` is non-AI today (`spl-responder-run.func.sh:3`). P inside it needs the same key and the same warm post, or the 120 s step is another cold dial plus a model call.

## 4. Section 10

| # | recommendation |
|---|---|
| Q1 | Leave the model unnamed until a measurement. On dev, n>=20, one 2k-token prompt, each vendor's fastest non-reasoning model, cached system prompt. Keep a vendor when p95 of (warm claim + time to the last token of an 80-token cap + warm post + WUI) is <= 3 s. One key file per box per env, mode 0600, never in git, a log or a tfvars. |
| Q2 | Yes. The loop posts with `spool send --answers`. The classifier stays on the interactive session. |
| Q3 | Yes for the interactive session. Write the three rules setup already writes (reply, post, archive: `spl-dispatch-setup.func.sh:291`) at every seat start. R1 does not need them once Q2 is yes. The drill failed because the re-created worktree had none. |
| Q4 | Yes to the push. The 0.5 s backstop needs the integer check at `spl-peer-poll.func.sh:89` widened, and one poller per box on the warm socket. Eight independent 0.5 s loops on cold dials miss 3 s and load the hub. |
| Q5 | Yes to 10 / 60 / 170, and keep `UnansweredGrace` at 120 s. The 60 s release has to set `not_by` (today only a `harness-refused:` reason does). If P is primary, the first call's own deadline is about 2.5 s and the 10 s step is the other vendor. `ClaimTTLDefault` is 120 s (`message_claim.go:41`), which is too late for a second try inside 180 s, so the watchdog stays. |
| Q6 | Yes. The window tails the stream log. That pane is not the idle signal. |
| Q7 | Yes, read-only. The action should reject a statement that writes. Section 3.2 can stay pending. The holes above are in the code, and a prd read would leave them where they are. |

## Commands (this tree, `fc19cdcd`)

```text
git log -1 --format=%H -- csi-spl-doc/specs/070-three-second-response/spec.md
  -> d39d80503913b5830e89b386db4e28d4ebc2784d
grep -n 'c.Dial' csi-spl-api/src/go/spool-hub-api/internal/hubclient/claim.go
  -> 15
grep -n 'func (c \*Client) SendAnswerMessage' .../internal/hubclient/flush.go
  -> 90 (Dial at 103)
grep -n 'const claimCols' .../internal/store/message_claim_postgres.go
  -> 21
grep -n 'spl_peer_hub --' csi-spl-orc/src/bash/run/spl-peer-poll.func.sh
  -> 178 renew, 187 poll
```
