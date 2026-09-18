# Contract: Dual-write and flush

Feature: `003` / `006`  
Binding: `SPEC-spool-trust-modes.md` §6

## 1. `spool-send` when hub URL is set

1. Write sender `outbox/`.
2. If same-box (`$SPOOL_ROOT/<to>/` exists and `to_box` is this box or omitted
   unambiguously): write recipient `inbox/`.
3. Decide hub send:
   - cross-box → always
   - same-box → **skip** unless `$SPOOL_MIRROR_LOCAL` is `1`/`true`
4. If hub send: upload files (REST) if needed, then WS envelope
   (`from_box`, `to_box`, inner `v:1`, box `sig`).

`$SPOOL_MIRROR_LOCAL` default unset = false. Illegal values fail-fast.

If step 4 fails after 1–2: mark outbox pending-flush **only if** a hub send
was required. Same-box without mirror never flushes.

No hub URL: stop after step 2.

## 2. Flush

Walk pending outbox only. Idempotent hub send by `msg_id`. Do not re-sign.
Do not change `ts`. 400/verify → stop retry, exit 78. Network/5xx → backoff.

## 3. Recv

Drain local inbox first. Hub frames (WS) for agents on this box. Same
`msg_id` delivered both locally and via hub is shown once.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:15:00Z -->
