# Feature Specification: Identity, pins, and routing

**Feature ID**: `004-spool-identity-routing`

**Created**: 2026-09-18

**Status**: Draft

**Input**: The bus vision uses `CLE-07` as if it were unique and trusted
everywhere. Specify **per-tenant** id uniqueness, tenant-root pin publish/sync/revoke,
unicast routing, and dual-write/flush so a rented hub can route without TOFU
or per-agent cloud keys (see 006).

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-identity-routing.md`

**Depends on**: 002 (local pin files + signed `v:1`), 003 HTTP `/v1/messages`
and `/v1/files` (004 adds `/v1/pins` and box mapping).

## User Scenarios & Testing

### User Story 1 - A box pins its public key with the tenant root (Priority: P1) 🎯 MVP

Renter uses the tenant root key to pin a box pubkey (`box_id`, `pubkey`) via `POST /v1/pins`. Second pin of the same `box_id` with a different key is refused (409). Same key is idempotent (200).

**Why this priority**: Without box pins, the hub cannot verify WS hello connections or incoming message envelopes.

**Independent Test**: Two boxes; pin box A; second pin with different key returns 409; same key returns 200.

**Acceptance Scenarios**:

1. **Given** box A unpinned on the hub, **When** renter pins pubkey P signed by tenant root, **Then** `GET /v1/pins` lists box A with P.
2. **Given** box A pinned to P, **When** someone attempts to pin Q ≠ P for box A without `--force`, **Then** 409 and stored pin remains P.
3. **Given** box A pinned to P, **When** renter re-pins P, **Then** 200 idempotent.

### User Story 2 - Box sidecar syncs pins to verify peer commanders (Priority: P1)

Box B’s sidecar pulls tenant pins via `GET /v1/pins` and stores them in `$SPOOL_ROOT/pins/box-<id>.pub` (SSH `authorized_keys` model). When box B receives a message from box A, it verifies the envelope signature against the local pin copy. No pin → 78, no TOFU.

**Acceptance Scenarios**:

1. **Given** box A pin synced to box B, **When** box B receives box A’s envelope, **Then** signature verifies locally.
2. **Given** box A pin not synced, **When** verification runs, **Then** exit 78, envelope refused.
3. **Given** local pin ≠ hub pin, **When** sync runs, **Then** neither is silently overwritten; 78 / pin_conflict.

### User Story 3 - Dual-write: same-box works when hub is down (Priority: P1)

GRK-03 and CLE-07 on box A. Hub down. Send still lands in CLE-07 local inbox directly under `$SPOOL_ROOT`. When hub returns, flush POSTs the same `msg_id` without re-signing.

**Acceptance Scenarios**:

1. **Given** hub down, **When** same-box send, **Then** recv works directly from `$SPOOL_ROOT`.
2. **Given** pending-flush, **When** hub returns, **Then** one hub row, no duplicate `msg_id`.
3. **Given** hub 400 bad sig, **When** flush retries, **Then** it stops, 78.

### User Story 4 - Box Revoke (Priority: P2)

Tenant root revokes box A via `DELETE /v1/pins/{box_id}`. Further messages from box A fail verify. History keeps the old pubkey in `pins_history`.

**Acceptance Scenarios**:

1. **Given** box A revoked, **When** a new send from box A reaches the hub, **Then** 400 unpinned/revoked.
2. **Given** revoke, **When** `--force` pins a new key, **Then** only the new key verifies.

### Edge Cases

- Box id missing in hub mode → fail-fast env, no send to hub.
- `BOX-*` as `from`: forbidden; agent IDs must be assigned names (`CLE-07`, `GRK-03`).
- Two inboxes for the same id on one box: forbidden (one directory per id).
- Same agent ID across two different boxes: allowed (e.g. `CLE-07@box-a` vs `CLE-07@box-b`).

## Requirements

- **FR-001**: Box IDs uniquely pinned per tenant in `pins (tenant_id, box_id, pubkey)`; agent IDs are unique **per box**.
- **FR-002**: `$SPOOL_BOX_ID` required when `$SPOOL_HUB_URL` is set.
- **FR-003**: `POST/GET/DELETE /v1/pins` signed with tenant root key.
- **FR-004**: Local authorized keys under `$SPOOL_ROOT/pins/box-<id>.pub`; box private key under `$HOME/.spool/keys/` (`0600`).
- **FR-005**: No TOFU. Envelopes verify against local box pins only.
- **FR-006**: Dual-write + flush per `003/contracts/flush.md`.
- **FR-007**: Addressing: unicast `to` specifies `(box_id, agent_id)` when agent ID exists on multiple boxes.
- **FR-008**: `--force` and revoke write `pins_history`.
- **FR-009**: The box harness manages the box keypair and scans `$SPOOL_ROOT/*/` to announce local agent roster at WS hello.
- **FR-010**: Subagents MUST NOT inherit parent IDs or use dotted sub-IDs; each subagent MUST be allocated an independent top-level ID (`^[A-Z]{2,4}-\d+$`) as a first-class peer.

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

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
