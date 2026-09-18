# Contract: Dual-write and flush

Feature: `003` / `006`  
Binding: `../../002-box-agent-messaging/contracts/trust-modes.md` §6

## 1. `spool-send` when hub URL is set

1. Write sender `outbox/`.
2. If same-box (`$SPOOL_ROOT/<to>/` exists and `to_box` is this box or omitted
   unambiguously): write recipient `inbox/`.
3. Decide hub send:
   - cross-box → always
   - same-box → **skip** unless `$SPOOL_MIRROR_LOCAL` is `1`/`true`
4. If hub send: upload files (REST, WS-issued upload token) if needed, then
   the WS envelope (`from_box`, `to_box`, inner `v:1`, box `sig`). `to_box` is
   resolved **on the box** before signing (explicit `--to-box`, else the
   cached tenant roster `$SPOOL_ROOT/.hub/roster.json`); the hub never fills
   it (OQ-03).

`$SPOOL_MIRROR_LOCAL` default unset = false. Illegal values fail-fast.

If step 4 fails after 1–2 because the hub is unreachable: keep the **signed
envelope** as pending-flush (`$SPOOL_ROOT/.hub/pending/<msg_id>.json`),
**only if** a hub send was required, and report `delivery=pending` with exit
`0` (OQ-09). Same-box without mirror never flushes.

`delivery` values (trust-modes §8, extended by OQ-09):

| value | meaning |
|---|---|
| `local` | same-box, hub skipped |
| `sent` | hub pushed the frame to a live `to_box` socket |
| `queued` | hub stored it; the receiving box is offline (7-day TTL) |
| `pending` | the hub was unreachable; the box holds it for flush (the hub never saw it) |

No hub URL: stop after step 2.

## 2. Flush

Walk `$SPOOL_ROOT/.hub/pending/` only, oldest first. Send the stored
envelope bytes as they are: do not re-sign, do not change `ts` or `to_box`.
Idempotent on the hub by `msg_id`. Success (`sent`/`queued`) removes the
pending file. 400/verify → move it to `$SPOOL_ROOT/.hub/rejected/`, stop,
exit 78. Network/5xx → keep it and back off.

Flush runs on every accepted hello: the box daemon (`spool hub-run`) after each
(re)connect, and the one-shot `spool hub-sync`. Reconnect backoff is
exponential, 1 s doubling to a **30 s** cap with jitter; last hello wins
(`./http-v1.md` §2.6).

## 3. Recv

`spool-recv` reads the local inbox only (unchanged 002 verb). The box session
socket writes each verified `recv` frame into `$SPOOL_ROOT/<to>/inbox/`; a
frame whose `msg_id` is already in that agent's inbox or archive is not
written twice. `--ack` archives locally; nothing is reported to the hub
(OQ-08).

## 4. Where it runs

Flush is a **box-side** function in `internal/hubclient` (OQ-15). It is not a
hub handler, and 004 T010 (`internal/flush`) is aligned to the same package.
Because the sender fills `to_box` before signing (OQ-03), a flush replays the
exact signed bytes.

Spec mapping: FR-008, FR-009, FR-010 (`../spec.md`).

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:55:00Z -->
