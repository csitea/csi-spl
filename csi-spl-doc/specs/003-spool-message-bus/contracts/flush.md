# Contract: Dual-write and flush

Feature: `003-spool-message-bus`  
Related: `SPEC-spool-identity-routing.md` §5–6

## 1. `spool-send` when hub is configured

Order, always:

1. Build and **sign** `v:1` (local key). Never sign on the hub.
2. Write sender `outbox/` (source of the flush queue).
3. If `$SPOOL_ROOT/<to>/` exists, write recipient `inbox/` (same-box delivery).
4. For each `file_id` not known-uploaded: `POST /v1/files`.
5. `POST /v1/messages` with the signed object.

If 4 or 5 fails after 2/3 succeeded: mark the outbox file
`pending-flush` (sidecar attribute: sibling
`<same-basename>.flush` containing `{ "want": "files"|"message", "tries": N }`,
or a `outbox/pending/` rename — implementation choice, one layout, tests lock
it). Same-box recv still works.

If hub URL is unset: stop after step 3 (pure 002).

## 2. Sidecar flush

`spool sidecar` (or `spool-flush` once) walks pending outbox:

1. POST missing files (idempotent by sha256).
2. POST message (idempotent by `msg_id`).
3. On 200/201: clear pending.
4. On 400 (bad sig / unpinned): **stop retrying**, surface `78`, leave the
   file for the operator. Do not spin.
5. On 401/403/5xx/network: backoff, keep pending.

Do not re-sign. Do not change `ts` or `msg_id`.

## 3. `spool-recv` when hub is configured

1. Drain local `inbox/` first (002).
2. `GET /v1/messages?as=<id>` for hub rows not already in inbox/archive.
3. Write those to local inbox (so ack is still a local rename), then return.
4. `--ack`: local archive rename **and** `ack=true` on the GET (or
   `POST /v1/acks`) so the hub cursor moves.

A message delivered both locally (step 3 of send) and via GET is the same
`msg_id`; recv returns it once.

## 4. Sidecar notify path

On NATS `agent.<id>.inbox`, if `$SPOOL_ROOT/<id>/` exists, write the JSON
into that inbox **iff** the file is not already present (`msg_id` in name or
body). Verify sig against local pins before write; if pin missing, try pin
sync (`GET /v1/pins`) once, then refuse.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
