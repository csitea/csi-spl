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

| From | Operation | Result | `pins_history` row (key recorded) |
|---|---|---|---|
| none | pin P | active P, 200 | `pin` (P) |
| active P | pin P | active P, 200 | `pin` (P) — see §2.1 |
| active P | pin Q, `force=false` | unchanged, 409 `pin_conflict` | — |
| active P | pin Q, `force=true` | active Q, 200 | `force` (Q, the **new** key) |
| active P | revoke | revoked, 200; live sessions of the box closed `unpinned_box` | `revoke` (P) |
| none | revoke | 404 `not_found` | — |
| revoked P | pin P, any `force` | **active P again**, 200 | `pin` (P) |
| revoked P | pin Q, `force=false` | unchanged, 409 `pin_conflict` | — |
| revoked P | pin Q, `force=true` | active Q, 200 | `force` (Q) |

### 2.1 Observed vs intended (Postgres store, `internal/store/postgres.go:93-120`)

- A same-key re-pin is **not** a pure no-op: it bumps `updated_at` and appends
  a `pin` history row. Intended: 200 with no write. **Partial** → task T022.
- A same-key pin on a **revoked** box re-activates it without `force`.
  Intended: re-activating a revoked box requires `force` (a revoke is a
  deliberate cut). **Partial** → task T022.
- History records the key that became active, so the old key of a `force` is
  the previous `pin`/`force` row, not the `force` row itself.

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

## 5. Known gap — replay

Pin and revoke signatures carry only `ts`. A captured request replays inside
the skew window — e.g. a revoke replayed right after a force re-pin revokes the
new key, and (§2.1) a replayed same-key pin re-activates a just-revoked box. Fix = a hub-issued nonce or a monotonic per-box sequence in the signed
payload (task T020). Until then the root key holder should not re-pin the same
box within the skew window of a revoke.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:45:00Z -->
