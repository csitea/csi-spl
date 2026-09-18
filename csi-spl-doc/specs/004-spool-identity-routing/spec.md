# Feature Specification: Identity, pins, and routing

**Feature ID**: `004-spool-identity-routing`

**Created**: 2026-09-18

**Status**: Draft

**Input**: The bus vision uses `CLE-07` as if it were unique and trusted
everywhere. Specify global id uniqueness, pin publish/sync/revoke, box id vs
agent id vs IAM door, unicast routing, and dual-write/flush so 003 can route
without TOFU or per-agent cloud keys.

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-identity-routing.md`

**Depends on**: 002 (local pin files + signed `v:1`), 003 HTTP `/v1/messages`
and `/v1/files` (004 adds `/v1/pins` and box mapping).

## User Scenarios & Testing

### User Story 1 - A box pins an id without colliding the fleet (Priority: P1) 🎯 MVP

Operator on box A `spool-keygen --as GRK-03` and `spool-pin`. Hub records
GRK-03 → pubkey, box A. Box B trying to pin GRK-03 to a different key is
refused.

**Why this priority**: Without this, two `CLE-07`s exist and signatures lie.

**Independent Test**: Two fake boxes, two hubs-in-one-process tenants or two
`box_id`s; second pin of same id different key → 409; same key → 200.

**Acceptance Scenarios**:

1. **Given** GRK-03 unpinned on the hub, **When** box A pins pubkey P, **Then**
   `GET /v1/pins` lists GRK-03 with P and box A.
2. **Given** GRK-03 pinned to P, **When** box B pins Q ≠ P, **Then** 409 and
   the stored pin remains P.
3. **Given** GRK-03 pinned to P, **When** box A re-pins P, **Then** 200
   idempotent.

### User Story 2 - Recv on another box verifies with a synced pin (Priority: P1)

Box B’s sidecar pulls pins. A message from GRK-03 (box A) verifies on box B
against the local copy. No pin → 78, no TOFU.

**Acceptance Scenarios**:

1. **Given** pin synced, **When** box B recv’s GRK-03’s message, **Then** sig
   verifies locally.
2. **Given** pin not synced, **When** recv runs, **Then** exit 78, message not
   returned as valid.
3. **Given** local pin ≠ hub pin, **When** sync runs, **Then** neither is
   silently overwritten; 78 / pin_conflict.

### User Story 3 - Dual-write: same-box works when hub is down (Priority: P1)

GRK-03 and CLE-07 on box A. Hub down. Send still lands in CLE-07 inbox.
When hub returns, flush POSTs the same `msg_id` without re-signing.

**Acceptance Scenarios**:

1. **Given** hub down, **When** same-box send, **Then** recv works from
   `$SPOOL_ROOT`.
2. **Given** pending-flush, **When** hub returns, **Then** one hub row, no
   duplicate `msg_id`.
3. **Given** hub 400 bad sig, **When** flush retries, **Then** it stops, 78.

### User Story 4 - Revoke (Priority: P2)

Operator revokes GRK-03. Further messages fail verify. History keeps the old
pubkey.

**Acceptance Scenarios**:

1. **Given** revoke, **When** a new send from GRK-03 reaches the hub, **Then**
   400 unpinned/revoked.
2. **Given** revoke, **When** `--force` pins a new key, **Then** only the new
   key verifies.

### Edge Cases

- Box id missing in hub mode → fail-fast env, no send to hub.
- `HUM-*` / `BOX-*` as `from`: `BOX-*` rejected; `HUM-*` allowed if pinned.
- Two inboxes for the same id on one box: forbidden (one dir per id).

## Requirements

- **FR-001**: Agent ids globally unique in hub `pins` (`SPEC-spool-identity-routing.md`).
- **FR-002**: `$SPOOL_BOX_ID` required when `$SPOOL_HUB_URL` is set.
- **FR-003**: `POST/GET/DELETE /v1/pins` as in 004 plan contract; door IAM maps
  to `box_id`.
- **FR-004**: Local pins under `$SPOOL_ROOT/pins/`; private keys under `$HOME`.
- **FR-005**: No TOFU. Recv verifies against local pins only.
- **FR-006**: Dual-write + flush per `003/contracts/flush.md`.
- **FR-007**: Unicast `to` only.
- **FR-008**: `--force` and revoke write `pins_history`.

## Success Criteria

- **SC-001**: Collision pin → 409 in a two-box test.
- **SC-002**: Cross-box recv verifies after pin sync; fails without it.
- **SC-003**: Hub-down same-box round trip + flush idempotent on `msg_id`.

## Assumptions

- 002 local send/recv exists.
- ysg-box still allocates ids; spool only rejects collisions at pin time.
- WUI is not a pin UI in v1 (`spool-pin` CLI).

## Out of Scope

- Changing ysg-box allocators.
- Per-agent IAM.
- Multi-recipient messages.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
