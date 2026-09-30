# Feature Specification: Live delivery — a human post reaches a live agent in seconds, or escalates

**Feature ID**: `053-spool-live-delivery` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-09-30 · **Lane**: LIVE-DELIVERY (hub + box sidecar + orc) · **Epic**: SPL-1225
**Authority**: this file for the rule; the wire additions here are normative until a `contracts/live-ack-v1.md` lands; `tasks.md` for what is built and where.
**Closest pattern**: `038-spool-fallback-responder` (SPL-997) — the same audience (a human post, the tenant responder), extended from "no box was sent it" to "no *live* agent acted".

Status vocabulary follows `../README.md` §2.3.

## 1. The owner's request, verbatim

prd t1 `#spool-hub-bugs` topic `9869051b` and `#spool-hub-devel` `b82f3853`, 2026-09-30:

> a complete rewrite on the messages pulling mechanism is needed … we must have at least 3 seconds response time
> … in which many hours nothing happens to a topic, which must not be the case

Evidence (`b82f3853`): three HUM-10 posts at 20:15–20:17Z reached **no agent** and **no fallback**; the first agent reply came 8 h 21 m later.

## 2. Words

- **Live agent**: an agent whose terminal pane is alive *now* — it would receive a poke. Distinct from **rostered**: an agent the box announced because it has a spool dir on disk (which survives the agent's exit).
- **Heartbeat**: the sidecar's periodic proof of which of its agents are live.
- **Ack / nack**: the sidecar's per-delivery report — the message was written to an inbox **and** a live pane was poked (ack), or there was no live pane / the poke was refused (nack).
- **Escalation ladder**: fast delivery → responder → visible "nobody picked this up" + alert.

## 3. The defect this removes (SPL-1225 root cause)

The hub decides "an agent heard it" from two signals that both lie when agents are asleep:

1. `deliveries.state = 'sent'` — set the instant the frame is relayed to **box-desk**, the shared fan-out box, regardless of any live recipient.
2. `agentOnline` — the box's socket is up **and** its roster names the agent; but the roster is `scanAgents()` = every dir on disk, so a long-dead agent still reads "online".

So a channel post fanned to box-desk is "heard" and "online" while no living agent will ever read it, and the SPL-997 fallback stands down. The already-shipped SPL-1225 hot fix escalates on *no reply in the topic within 120 s* — a ground truth a stale roster cannot fake — but that is a backstop measured in minutes, not the 3 s the owner wants. This spec makes the fast path itself honest.

## 4. Design — Option A (per-agent liveness + per-delivery ack), the owner's pick

### 4.1 A live-only roster (heartbeat)
The sidecar probes each of its agents' panes on a short interval and announces (`TAnnounce`) a roster of **only the live ones**, re-announcing on any change. `agentOnline` then means alive, not "has a dir". A pane that dies drops out within one heartbeat.

### 4.2 Per-delivery ack
For each `recv` the sidecar writes the inbox copy and pokes, then sends a new `TAck` frame keyed by `(msg_id, agent)` carrying the poke outcome (from `spool-notify.sh`: exit 0 shown, 5 no live window, 6 pane refused, 7 exited). The hub records it. A `recv` that no live pane took (nack) is the signal the fast path was missed.

### 4.3 The escalation ladder
| When | What |
|---|---|
| 0 → deliver | fast path: write inbox + poke a **live** agent; the ack confirms it |
| a nack, or no live recipient at fan-out | escalate to the tenant responder **immediately** (no 120 s wait) |
| no reply in the topic after **120 s** | escalate to the responder — **shipped** (SPL-1225 relay sweep, `store.UnansweredPosts`) |
| no reply after **10 min** | post "nobody picked this up: `<where>`" to `#spool-hub-ops` + a visible state; alert |
| continuously | `do_spl_report_unheard` counts drops; a non-zero recent count is an alert |

### 4.4 SLO and how it is measured
p95 human-post → live-agent-poke ≤ **3 s**, end to end. Measured by `do_spl_latency_probe` (per-hop) and the deployed-state checks; the `#spool-hub-ops` alert and `do_spl_report_unheard` catch regressions. Baseline (2026-09-30): hub→box p50 6 ms / p95 0.72 s / max 4.7 s (n=149 real prd); on-box ~0.2 s to a live pane (n=24). Transport already meets 3 s; the fix is liveness, not speed.

## 5. Backwards compatibility (mandatory — running sidecars during the roll)

- Every addition is negotiated by a hello feature (`FeatureLiveAck`, and `FeatureHeartbeat` for §4.1), exactly like `FeatureBackfill`/`FeatureFallback`. A sidecar that does not announce it behaves as today; the hub sends it no new frame and expects no ack from it.
- New `wire.Frame` fields are `omitempty`; an older peer decodes leniently and ignores them. New frame types (`TAck`) are only sent to a box that asked for them.
- The **120 s reply-based escalation (shipped) is the backstop for every sidecar that has not upgraded** — no post is lost during the roll.
- Roll order: the **hub ships first** (accepts and records acks, tolerates their absence, still escalates on the reply-timeout), **then** sidecars upgrade. No step assumes both ends move together.

## 6. Rollout — small shippable steps (each live on dev + prd, each with full gates)

- **S1** hub accepts + records a `TAck` frame from a `FeatureLiveAck` box; no behavior change; old sidecars unaffected. (store: a `deliveries` liveness column or a small `delivery_acks` table.)
- **S2** the sidecar maps the `spool-notify.sh` exit code to an ack and sends it per `(msg_id, agent)`.
- **S3** the hub escalates to the responder on a nack / no-live-recipient at fan-out, immediately (tightens the fast path below 120 s).
- **S4** the sidecar heartbeats a **live-only** roster; `agentOnline` stops counting dead dirs; the SPL-997 immediate fallback becomes honest.
- **S5** the 10-min "nobody picked this up" → `#spool-hub-ops` post + visible state + alert.

Each step: `run-all-tests.sh` + `hub-pg.tst.sh` (Postgres) + `gofmt -l` green before push; no regression of the WUI live path (`fanoutWUI`), the desk tools (`do_spl_desk_*`), or the SPL-997 fallback + SPL-1225 escalation.

## 7. Out of scope

The relay/queue for cross-revision delivery (SPL-1004) and the WUI live stream (specs/014) stay as they are; this spec only makes "an agent heard it" mean a *live* agent, and adds the escalation tail. Options B (hub-side per-agent queues) and C (event wake-ups only) were considered and rejected in `9869051b`: B is a larger build for a guarantee the ack already gives; C leaves the root cause (the folder roster) in place.

<!-- last-edit: 2026-09-30T07:20:00Z — merged from csi-spl-doc/specs/053-spool-live-delivery/spec.md -->
