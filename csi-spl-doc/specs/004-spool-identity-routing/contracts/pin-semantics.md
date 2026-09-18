# Contract: Pin semantics

Status: **binding for 004** (seam owner of pin semantics, `../../README.md` §5).
The REST shape (paths, bodies, auth header) is
`../../003-spool-message-bus/contracts/http-v1.md` §4; the error envelope is
`../../003-spool-message-bus/contracts/error-envelope.md`; 402 / 429 and tenant
host resolution are 006's. Checked against trunk `bbc41e7`
(`internal/hub/rest.go`, `internal/wire/wire.go`, `internal/hubclient/hubclient.go`).

## 1. Signed payloads (tenant root key)

Canonical JSON = `jq -cS` (sorted keys, compact); Ed25519; base64 sig.
`ts` RFC3339 UTC, accepted within ±`SPOOL_HUB_HELLO_SKEW` (cnf, default `300s`).

| Operation | Signed payload |
|---|---|
| pin / force | `{"box_id","force","pubkey","ts"}` |
| revoke | `{"box_id","op":"revoke","ts"}` |

A signature by any other key (including the box key being pinned) or a `ts`
outside the window → 400 `bad_sig`. An agent or a box cannot pin itself.

## 2. State machine per `(tenant, box_id)`

`last_op` = the signed client `ts` of the last op that changed the pin
(`pins.last_op_ts`). "later" = strictly after `last_op` (µs precision).

| From | Operation | Result | `pins_history` row (key recorded) |
|---|---|---|---|
| none | pin P | active P, 200 | `pin` (P) |
| active P | pin P (any ts, any `force`) | no-op, 200, no write | — |
| active P | pin Q, `force=false` | unchanged, 409 `pin_conflict` | — |
| active P | pin Q, `force=true`, later ts | active Q, 200 | `force` (Q, the **new** key) |
| active P | revoke, later ts | revoked, 200; live sessions of the box closed `unpinned_box` | `revoke` (P) |
| revoked P | revoke (any ts) | no-op, 200 | — |
| none | revoke | 404 `not_found` | — |
| revoked P | pin P or Q, `force=false` | unchanged, 409 `pin_conflict` (a revoke is a deliberate cut) | — |
| revoked P | pin P or Q, `force=true`, later ts | active, 200 | `force` |
| any | state change with ts **not later** than `last_op` | unchanged, 409 `stale_pin_op` (CLI exit 78) | — |

History records the key that became active, so the old key of a `force` is the
previous `pin` / `force` row.

**Implemented** in `4f611d6` (`internal/store/{memory,postgres}.go` `PutPin` /
`RevokePin`, `internal/hub/rest.go`, `csi-spl-rdb/…/0005_pin_identity.sql`);
`TestTenantsAndPins` (memory + postgres) and `TestPinRevokeAndForce` PASS.
Before that commit a same-key re-pin appended history and a same-key pin
silently un-revoked a revoked box.

Only the **active** key verifies hello and envelopes. History is audit only.

## 3. Sync down (authorized_keys)

- The box pulls the active pins after every `role=box` hello and on a cnf
  interval (trust-modes §4.1); revoked pins are not listed.
- Missing local pin → written `0644`.
- Same key locally → no-op.
- Different key locally → **not clobbered**; `pin_conflict`, exit 78. The
  operator checks and runs `spool pin --force`.
- Sync never deletes a local pin; a local revoke is `spool pin --revoke`.

## 4. CLI

| Verb | Does |
|---|---|
| `spool keygen [--box]` | box keypair (002) |
| `spool root-keygen --out <path>` | tenant root keypair; prints the pubkey |
| `spool hub-tenant --tenant --root-pubkey` | operator seeds a tenant row (M1; 006 owns tenancy) |
| `spool pin --box --pubkey [--force] [--revoke] [--root-key]` | local pin file; with a root key (hub mode only) also publishes |
| `spool hub-pin --box --pubkey --root-key [--force] [--revoke]` | hub pin only |

## 5. Replay

Pin and revoke signatures carry only `ts`, which is accepted within the skew
window. A captured request is therefore refused by ordering, not by a nonce:
every state change must carry a `ts` later than `last_op` (§2), so a replayed
revoke after a force re-pin, or a replayed force after a revoke, is 409
`stale_pin_op`. Replays that would change nothing (same key on an active pin, a
second revoke) are harmless 200 no-ops. The CLI signs `RFC3339Nano` so two ops
inside one second still order. **Implemented** in `4f611d6`.

Residual: an op signed with a far-future `ts` is refused by the skew check, so
it cannot pre-empt later ops; no nonce, so the ordering rests on the operator's
clock being within the skew window.

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:23:00Z -->
