# Feature Specification: Rented spool-hub

**Feature ID**: `006-spool-hub-rental`

**Created**: 2026-09-18

**Status**: Draft

**Input**: End goal — any user pays to rent a spool-hub so their Claude Code,
Grok, and Antigravity agents intercommunicate using only public/private keys.

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-hub-rental.md`

**Depends on**: 002 (local `v:1` + keys), 003 HTTP shapes (this feature
**replaces** “GCP IAM as the renter door” with tenant URL + Ed25519).

## Context

002/003/004 described an internal fleet: box IAM at Cloud Run, globally unique
ids, ysg-box as the machine. The product is a **paid tenant**. Isolation is
the tenant, not the GCP project. Agent auth is the pin table of **that**
tenant. Recv on a public URL must prove possession of `as`’s key.

## User Scenarios & Testing

### User Story 1 - Renter obtains a tenant (Priority: P1) 🎯 MVP

A paying user (or operator `do_spl_tenant_create`) receives tenant id, hub
URL, and tenant root keypair. Root private key is not stored on the hub.

**Why this priority**: Without a tenant there is no namespace to pin into.

**Independent Test**: create tenant in testhub; `tenants.root_pubkey` set;
root private key absent from DB dumps.

**Acceptance Scenarios**:

1. **Given** a create-tenant action, **When** it succeeds, **Then** a URL and
   root pubkey exist and the private root is returned once.
2. **Given** cancelled billing after grace, **When** `spool-send` hits the
   hub, **Then** `402 unpaid`; `spool-recv` still works during grace.

### User Story 2 - Operator pins agents with the root key (Priority: P1)

Renter pins `GRK-03` and `CLE-07` with the tenant root. Agents cannot pin
themselves. Same id different key in **this** tenant → 409. Same id in
**another** tenant is a different row.

**Acceptance Scenarios**:

1. **Given** root-signed pin of GRK-03, **When** GRK-03 sends, **Then** hub
   accepts.
2. **Given** GRK-03 not pinned, **When** it sends, **Then** 400 unpinned.
3. **Given** tenant B, **When** it pins GRK-03 to another key, **Then** tenant
   A is unchanged.

### User Story 3 - Two kinds of agent talk via the hub, keys only (Priority: P1)

On two machines (or two `$SPOOL_ROOT`s), Grok and Claude use the same CLI/MCP
and `$SPOOL_HUB_URL`. Send is `v:1` signed by `from`. Recv is `POST /v1/recv`
signed by `as`. No GCP credentials in the environment.

**Acceptance Scenarios**:

1. **Given** both pinned, **When** GRK-03 sends a `task` to CLE-07, **Then**
   CLE-07 `spool-recv --as CLE-07` returns it; a recv signed by GRK-03 as
   `as=CLE-07` is 401.
2. **Given** no `CLOUDSDK_*` / IAM, **When** the CLI talks to a public testhub,
   **Then** send/recv still succeed.
3. **Given** a file, **When** put-file + send + get-file, **Then** hash
   matches (002 contract).

### User Story 4 - Quota and unpaid (Priority: P2)

Over quota → 429. Unpaid after grace → send/pin refused, recv still until
data expiry.

### Edge Cases

- Replay of `POST /v1/recv` with old `ts` → reject.
- Tenant URL leaked: unpinned POSTs are 400; recv still needs the agent key.
- Root key lost: operator rotation procedure (out of MVP: support re-root
  with a break-glass we hold? **No** — we do not escrow. Lost root = new
  tenant or a documented re-root signed by payment-account proof, later spec).

## Requirements

- **FR-001**: Tenants as in `SPEC-spool-hub-rental.md` §2.
- **FR-002**: Pin uniqueness and isolation **per tenant**.
- **FR-003**: Pin/revoke signed by tenant root only.
- **FR-004**: Hub recv is signed `POST /v1/recv`; open GET-by-as is forbidden
  on the public deployment.
- **FR-005**: Send verifies `v:1.sig` against that tenant’s pins only.
- **FR-006**: No renter GCP IAM requirement. No per-agent API token.
- **FR-007**: Uniform box API (same verbs for CLE/GRK/AGY).
- **FR-008**: Quota and unpaid codes as specified.
- **FR-009**: `v:1` schema unchanged.

## Success Criteria

- **SC-001**: Two tenants, identical agent ids, no cross-talk.
- **SC-002**: Grok→Claude round trip on a testhub with only key files + hub URL.
- **SC-003**: Recv without a valid `as` signature cannot list another agent’s
  inbox.
- **SC-004**: `go test` plus a two-directory CLI smoke (two “machines”).

## Assumptions

- 002 CLI exists. Payment webhook may be stubbed (`billing_status=manual`).
- ysg-box adapter is not in this MVP.
- WUI may lag; CLI is enough to prove the product.

## Out of Scope

NATS, Kafka, git-rel, ysg-box, customer GCP accounts, card storage, custom
domains, token SSE.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
