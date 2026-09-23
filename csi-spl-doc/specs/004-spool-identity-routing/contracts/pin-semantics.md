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
- Different key locally → **not clobbered**. `spool hub-sync` exits 78
  (`pin_conflict`); the operator accepts the hub key with `spool pin --force`.
  `spool hub-run` logs the conflict and stays connected, and still installs
  every other pin. One stale pin must not take the box offline.
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

## 6. Retiring a box: revoke is not removal

A revoke ends a box's authority. It does **not** take the box out of the
tenant's roster, and the two are routinely confused.

`GET /v1/view/roster` is built FROM `pins` (store `ViewBoxes`:
`FROM pins LEFT JOIN boxes LEFT JOIN roster`), and
`../../003-spool-message-bus/contracts/view-v1.md` §4.1 says it in as many
words: *revoked pins are listed with `revoked: true`*. So
`DELETE /v1/pins/{box_id}` leaves the box in the owner's JSON for good. The WUI
happens to hide it (`rosterFromView` skips `revoked`); the JSON does not, and an
owner reading the API sees a roster that only grows.

| you want | do |
|---|---|
| this key must stop working, the box stays known | revoke (§2), signed by the tenant root |
| this box must leave the roster | purge the rows: `csi-spl-orc` `do_spl_box_purge` |

`do_spl_box_purge` deletes the `pins`, `boxes`, `roster` and
`channel_subscriptions` rows of an explicitly named box, and nothing else: it
removes an **identity**, never history, so `messages`, `deliveries` and
`pins_history` stay. It is the teardown for the probe and e2e rigs, which pin a
box once and reuse it across runs (`do_spl_box_msg_probe`,
`do_spl_box_file_probe`, `do_spl_m3_e2e`) — nothing ever removed one, so dev/t1
had accumulated 9 boxes of which 7 were dead rigs by 2026-09-21.

Purge is deliberately not automatic at the end of a probe run: a probe that
revoked or purged its own box would need `ROOT_KEY_JSON` and a fresh root-signed
pin on **every** run. Run the teardown when the rig is finished with, and read
`do_spl_roster_show` (the live JSON, through a member session) as the proof.

Guards, because this is a row delete on live data: `BOX_IDS` is an explicit list
with no pattern form; `box-wui` is refused (it is the hub's own WUI-dispatch
signing box, `../../014-spool-wui-dispatch/contracts/wui-dispatch.md` §2.2 — its
`last_hello_at` is null because it never opens a box socket, not because it is
dead); a box that said hello inside `PURGE_MIN_IDLE_HOURS` is held back and the
whole statement rolls back; and every statement runs under
`SET LOCAL app.tenant_id`, so the rdb 0014 row-level-security policy — not the
script — is what makes another tenant's box invisible.

<!-- version: 1.2.0 · updated: 2026-09-21 · last-edit: 2026-09-21T13:25:00Z -->
