# Feature Specification: Live delivery — a human post reaches a live agent in seconds, or escalates

**Feature ID**: `053-spool-live-delivery` · **Milestone**: M3 · **Status**: Partial (S1 and S3 hub side built; S2, S4, S5 Planned)
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

The wire, as built (S1, `internal/wire/wire.go`): hello feature `live_ack` (`wire.FeatureLiveAck`); frame `{"type":"ack","msg_id":<uuid>,"agent":<local agent id>,"outcome":<o>}` (`wire.TAck`), fire and forget, no reply; `outcome` is one of `shown` (exit 0, the ack), `no_window` (5), `refused` (6), `exited` (7), each but `shown` a nack. The hub records an ack only from a box that announced `live_ack`, for an agent that box announced, and for a message it sent that box; the latest poke of a `(msg_id, agent)` replaces the earlier one (rdb `0186_delivery_live_acks.sql`, table `delivery_live_acks`).

### 4.3 The escalation ladder
| When | What |
|---|---|
| 0 → deliver | fast path: write inbox + poke a **live** agent; the ack confirms it |
| a nack, or no live recipient at fan-out | escalate to the tenant responder **immediately** (no 120 s wait) |
| no reply in the topic after **120 s** | escalate to the responder — **shipped** (SPL-1225 relay sweep, `store.UnansweredPosts`) |
| no reply after **10 min** | post "nobody picked this up: `<where>`" to `#spool-hub-ops` + a visible state; alert |
| continuously | `do_spl_report_unheard` counts drops; a non-zero recent count is an alert |

### 4.4 SLO and how it is measured
p95 human-post → live-agent-poke ≤ **3 s**, end to end. Measured by `do_spl_latency_probe` (per-hop, live DM) and `do_spl_latency_hops` (every poke, read-only, section 8) and the deployed-state checks; the `#spool-hub-ops` alert and `do_spl_report_unheard` catch regressions. Baseline (2026-09-30): hub→box p50 6 ms / p95 0.72 s / max 4.7 s (n=149 real prd); on-box ~0.2 s to a live pane (n=24). Transport already meets 3 s; the fix is liveness, not speed.

## 5. Backwards compatibility (mandatory — running sidecars during the roll)

- Every addition is negotiated by a hello feature (`FeatureLiveAck`, and `FeatureHeartbeat` for §4.1), exactly like `FeatureBackfill`/`FeatureFallback`. A sidecar that does not announce it behaves as today; the hub sends it no new frame and expects no ack from it.
- New `wire.Frame` fields are `omitempty`; an older peer decodes leniently and ignores them. New frame types (`TAck`) are only sent to a box that asked for them.
- The **120 s reply-based escalation (shipped) is the backstop for every sidecar that has not upgraded** — no post is lost during the roll.
- Roll order: the **hub ships first** (accepts and records acks, tolerates their absence, still escalates on the reply-timeout), **then** sidecars upgrade. No step assumes both ends move together.

## 6. Rollout — small shippable steps (each live on dev + prd, each with full gates)

- **S1** hub accepts + records a `TAck` frame from a `FeatureLiveAck` box; no behavior change; old sidecars unaffected. (store: a `deliveries` liveness column or a small `delivery_acks` table.) **Implemented** (c-897, SPL-1239): table `delivery_live_acks` (rdb 0186), `store.LiveAcks`, `hub/live_ack.go` `onAck`; checks `hub/live_ack_test.go` (recorded, replaced, refused for an unannounced agent / unknown outcome / unsent message, ignored from a box without the feature), memory and Postgres.
- **S2** the sidecar maps the `spool-notify.sh` exit code to an ack and sends it per `(msg_id, agent)`.
- **S3** the hub escalates to the responder on a nack / no-live-recipient at fan-out, immediately (tightens the fast path below 120 s). **Implemented, hub side** (c-897, SPL-1241): every relay tick (`SPOOL_HUB_QUEUE_RELAY`, 5 s) `escalateNacked` hands a signed human post that a nack names, that no agent acked `shown`, that no fallback took and no agent answered, to the responder through the SPL-1225 escalate path, claimed once. A nack waits `nackSettle` (3 s) so another agent's `shown` ack of the same recv lands first. "No live recipient at fan-out" arrives as the desk box's nack (its panes are gone); a post no box was sent at all stays the SPL-997 immediate fallback. Live only once S2 sidecars send acks; until then the 120 s backstop holds. Checks: `hub/live_ack_test.go` (a nack reaches the responder once; control: a `shown` ack does not escalate; inside the settle nothing does).
- **S4** the sidecar heartbeats a **live-only** roster; `agentOnline` stops counting dead dirs; the SPL-997 immediate fallback becomes honest.
- **S5** the 10-min "nobody picked this up" → `#spool-hub-ops` post + visible state + alert.

Each step: `run-all-tests.sh` + `hub-pg.tst.sh` (Postgres) + `gofmt -l` green before push; no regression of the WUI live path (`fanoutWUI`), the desk tools (`do_spl_desk_*`), or the SPL-997 fallback + SPL-1225 escalation.

## 7. Out of scope

The relay/queue for cross-revision delivery (SPL-1004) and the WUI live stream (specs/014) stay as they are; this spec only makes "an agent heard it" mean a *live* agent, and adds the escalation tail. Options B (hub-side per-agent queues) and C (event wake-ups only) were considered and rejected in `9869051b`: B is a larger build for a guarantee the ack already gives; C leaves the root cause (the folder roster) in place.

## 8. The poke ledger and the hop probe (SPL-6511, latency action 1)

The owner's latency targets (t1 e3b16fea, form ae452613): under 1 s on one box, under 3 s across boxes. Every "faster" claim is held against one named measurement (`csi-spl-doc/doc/md/lesson-speed-up-measure-first.md`), and before this section the box hops could not be split. Only `spool-send.sh` wrote `input.log`, at 1 s resolution. The sidecar path, which carries every cross-box message, logged no poke time, and `notices.log` has no timestamp.

### 8.1 The ledger

`<spool root>/<id>/lifetime/poke-ledger.tsv`: append-only, one tab-separated row per event, times in epoch milliseconds, `-` = not known.

| col | field | `poke` row | `surfaced` row | `prompt` row |
|---|---|---|---|---|
| 1 | event | `poke` | `surfaced` | `prompt` |
| 2 | ts_ms | poke end (Enter sent, or the refusal) | hook time | hook time |
| 3 | to | the addressed id | the agent | the agent |
| 4 | msg_id | the message | the injected message | `-` |
| 5 | written_ms | inbox file mtime | inbox file mtime | `-` |
| 6 | start_ms | poke start | `-` | `-` |
| 7 | rc | `spool_notify_poke` exit code: 0 rung, 5 no window, 6 refused (unsent text), 7 only shells | `-` | `-` |
| 8 | via | `send` (spool-send.sh), `sidecar` (spool-notify.sh), `retry` (spool-poke-retry.sh) | the hook event: `UserPromptSubmit` (idle: the poke started a turn), `PostToolUse` (busy), `SessionStart` | `UserPromptSubmit` |
| 9 | send_ms | when spool-send.sh started (via `send` only) | `-` | `-` |

- **Writers.** `spool_notify_poke` (`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh`) wraps the ring (`spool_notify_poke_ring`), so every path that types into a pane writes its row on every exit code. The msg_id comes from `SPOOL_POKE_MSG_ID`, which `spool_notify` and `spool-notify.sh` set; the retry daemon falls back to the poke line's `msg <id>`. The clock is bash's `EPOCHREALTIME`, so the poke does not fork. `spool-agent-hook.sh` writes a `surfaced` row per injected message (claude) and a `prompt` row per UserPromptSubmit.
- **Bounds.** A row is written only into an agent dir that exists. Past `SPOOL_LEDGER_MAX` bytes (default 1 MiB) the file moves to `.1` and a new one starts, so a reader never sees a row rewritten. A write error never fails the poke or the hook.
- **Clock.** On one box every column reads the same clock. `written_ms` is a file mtime, which the kernel stamps from a coarse clock (a few ms of granularity). Across boxes, the hub hops (8.2) are the cross-clock leg.

### 8.2 The probe action

`cd csi-spl-orc && ./run -a do_spl_latency_hops` (`src/bash/run/spl-latency-hops.func.sh`, `src/bash/scripts/latency-hops.py`) is read-only. It prints `hop, n, p50_ms, p90_ms, max_ms` (nearest-rank percentiles) over the last `LAT_HOURS` (default 24) of every ledger under `LAT_SPOOL_ROOT`:

| hop | from the ledger |
|---|---|
| send script (start -> inbox file) | `send_ms` -> `written_ms`, via `send` |
| inbox file -> poke start (send / sidecar) | `written_ms` -> `start_ms` |
| poke (start -> Enter) | `start_ms` -> `ts_ms`, rc 0 |
| poke -> next prompt | a rung poke -> the agent's next `prompt` row |
| inbox file -> seen, idle / busy | `written_ms` -> the message's first `surfaced` row, by its via |

It also prints the count of each poke exit code. With `ENV=<dev|prd> TENANT_ID=<t>` it adds the hub hops of the latency panel (lat-measure, c-458) through `do_spl_db_query`, which reads ids and timestamps only, never a body. P-A covers sender ts -> hub received -> sent -> box ack, per sender vendor. P-B covers hub received -> sent, per receiving box. `do_spl_latency_probe` (4.4) stays the live write probe, which DMs a seated desk. This one sends nothing.

Checks: `csi-spl-orc/src/bash/features/spawn-agents/tests/test-poke-ledger.sh` covers a same-box send and a relayed (sidecar) delivery, each leaving one row with monotonic stamps, a refused poke leaving rc 6, the hook's rows, and the rotation. `csi-spl-orc/src/bash/tests/latency-hops.tst.sh` checks the exact table from a fixture tree, the window, and the hub SQL.

<!-- version: 0.3.0 · updated: 2026-11-25 · last-edit: 2026-11-25T00:00:00Z -->
