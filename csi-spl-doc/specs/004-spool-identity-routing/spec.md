# Feature Specification: Identity, pins, and routing

**Feature ID**: `004-spool-identity-routing` · **Milestone**: M1

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo; verified on trunk `bbc41e7`, code unchanged since `9f8f492`)

**Status**: **Partial** — implemented in code and tests (in-memory testhub and
a temp Postgres); not yet exercised against a live hub (dev hub has no ingress; prd has
no Cloud Run). See "Verified status".

**Input**: The bus uses `CLE-07` as if it were unique and trusted everywhere. It
is not. Specify the identifiers (tenant, tenant root, box, box key, agent),
their format and scope, the pin lifecycle (pin / force / revoke / sync), and how
a message is routed to `(to_box, to)` — reconciled with the binding trust model.

**Authorities**: redo rules and seams `../README.md` (§2, §5);
trust model `../002-box-agent-messaging/contracts/trust-modes.md` (wins on any
difference); narrative `../../doc/md/SPEC-spool-identity-routing.md`.

**Contracts (this dir)**: `contracts/identifiers.md` (every id, format, scope,
key) and `contracts/pin-semantics.md` (409, force, history, revoke, sync).
The REST **shape** of `/v1/pins` and the WS hello / roster / envelope frames are
003's: `../003-spool-message-bus/contracts/http-v1.md` §2, §4 — cited, not restated.

**Seams** (`../README.md` §5): 004 owns pin semantics and identifiers. 003 owns
the wire. 006 owns tenant host resolution, tenant root key issuance, quota
(429) and unpaid (402). 007 owns the estate that makes a hub reachable.

**Depends on**: 002 (local folders, unsigned local mode, `spool keygen`, pin
files). **Used by**: 003 (hello / envelope verify), 005 (shows `from@from_box`),
006 (tenant root).

## Canon (restated from trust-modes, not redefined)

- **Local mode** (`$SPOOL_HUB_URL` unset): unsigned, no keys, no box id, no
  pins read. Identity = the agent directory under `$SPOOL_ROOT` (trust-modes §2).
- **Hub mode**: one Ed25519 keypair **per box**, shared by its agents; no agent
  keypairs; `from_box` / `to_box` only in the hub envelope (trust-modes §3, §5).
- **Tenant root key** is the only key that may pin or revoke a box pubkey.
- **No TOFU**: a first message never installs a pin (trust-modes §7).
- `delivery = local | sent | queued | pending`.
- **`BOX-` is forbidden as an agent-id prefix.**

## User Scenarios & Testing

### User Story 1 - Tenant root pins a box pubkey (Priority: P1) 🎯 MVP

The renter signs a pin for `(box_id, pubkey)` with the tenant root key. First
pin → 200. Same key again → 200. A different key without `force` → 409
`pin_conflict`, stored pin unchanged. A box key cannot pin itself.

**Why**: without a pin the hub refuses the box's hello and no receiver can
verify its envelopes.

**Independent test**: `TestPinRESTRootSigned`, `TestTenantsAndPins`.

1. **Given** box A unpinned, **When** a root-signed pin for P arrives, **Then**
   200 and the pin list carries `{box_id: A, pubkey: P}`.
2. **Given** A pinned to P, **When** Q≠P is pinned without `force`, **Then** 409
   `pin_conflict`, pin stays P.
3. **Given** A pinned to P, **When** P is pinned again, **Then** 200, no write.
4. **Given** a sig by any key other than the tenant root, **Then** 400 `bad_sig`.

### User Story 2 - Receiving box syncs pins and verifies locally (Priority: P1)

After hello the box pulls the tenant's pins and installs
`$SPOOL_ROOT/pins/box-<box_id>.pub`. Received envelopes verify against the
**local** copy; no per-message hub call (SSH `authorized_keys` model).

**Independent test**: `TestPinSyncWritesAndConflictNoClobber`, `TestRecvVerifiesAfterPinSync`.

1. **Given** A's pin synced to B, **When** B receives A's envelope, **Then** it verifies.
2. **Given** no local pin for A, **When** B receives A's envelope, **Then** refuse, exit 78.
3. **Given** local pin ≠ hub pin, **When** sync runs, **Then** the local file is
   untouched, `pin_conflict`, exit 78; the operator resolves with `spool pin --force`.

### User Story 3 - Unicast routing to `(to_box, to)` (Priority: P1)

Agent ids are unique per box, so two boxes may both announce `CLE-07`. The box
daemon announces its roster (`$SPOOL_ROOT/*/` names matching the agent-id
regex) on `role=box` hello and on change. The **sender** resolves `to_box` from
its local roster copy and signs it into the envelope; the hub never mutates
signed bytes (003 OQ-03).

**Independent test**: `TestCrossBoxSendRecvAndResult`, `TestTamperedAndAmbiguousAndMissingPin`,
`TestRosterIsPerBox`, `TestLastHelloWinsOnlyForBoxRole`.

1. **Given** `CLE-07` on box A and box B, **When** a send leaves `to_box`
   unresolved, **Then** 409 `ambiguous_to_box`.
2. **Given** a roster listing an id twice, or an invalid id (incl. `BOX-1`),
   **Then** 409 `roster_duplicate`.
3. **Given** `CLE-07` on two boxes, **Then** the hub does NOT 409 — they are
   `CLE-07@box-a` and `CLE-07@box-b`.

### User Story 4 - Dual-write keeps same-box mail off the hub (Priority: P1)

Same-box sends land in the local inbox first; the hub is skipped unless
`$SPOOL_MIRROR_LOCAL=1` (trust-modes §6). A required hub send that fails is
`pending` and flushed later with the same `msg_id` and signature — flush is
box-side (`internal/hubclient`, OQ-15); its contract is
`../003-spool-message-bus/contracts/flush.md`. 004 owns only the identity rule
that the flushed envelope is not re-signed.

**Independent test**: `TestHubDownSameBoxRecvAndFlushIdempotent`, `TestFlushHTTP400StopsRetryWith78`.

1. **Given** hub down, **When** same-box send, **Then** recv works from `$SPOOL_ROOT`.
2. **Given** a pending flush, **When** the hub returns, **Then** one hub row per `msg_id`.
3. **Given** the hub rejects the signature, **Then** flush stops, exit 78.

### User Story 5 - Revoke and force-replace (Priority: P2)

A root-signed revoke marks the pin revoked, appends history, and closes the
box's live session. `force` re-pins a new key; only the new key verifies.

**Independent test**: `TestPinRevokeAndForce`, `TestPinCLIPublishesAndHygiene`.

1. **Given** A revoked, **When** A sends, **Then** refused `unpinned_box`; hello closes.
2. **Given** A revoked, **When** `force` pins Q, **Then** only Q verifies.
3. **Given** no pin for A, **When** revoke, **Then** 404 `not_found`.
4. **Given** A revoked, **When** P or Q is pinned without `force`, **Then** 409.
5. **Given** a force re-pin after a revoke, **When** the captured revoke is
   replayed, **Then** 409 `stale_pin_op` and the new key stays active.

### Edge Cases

- `$SPOOL_HUB_URL` set and `$SPOOL_BOX_ID` missing or invalid → fail fast at
  config load; nothing sent.
- A tenant root key (`--root-key` / `$SPOOL_TENANT_ROOT_KEY`) without
  `$SPOOL_HUB_URL` → fail fast (a root key only publishes to a hub).
- Sub-agents never inherit a parent id and never use dotted ids (`AGY-01.1`
  fails the regex); each gets its own top-level id and directory.
- Pin writes on an unpaid tenant (402) or over quota (429) → 006.
- Tenant resolved from the request Host; unknown host → `unknown_tenant` (006). (Amended by 026: tenant is resolved from identity, session, or pinned box key; one API host api.<domain>, per-tenant Host routing retired).

## Requirements

Status per `../README.md` §2.3. Code citations are at trunk `bbc41e7`.

- **FR-001** — Identifiers, formats and scopes are exactly
  `contracts/identifiers.md`: agent id `^[A-Z]{2,4}-[0-9]+$` minus `BOX-`,
  unique per box; box id `^[a-z0-9][a-z0-9-]{0,31}$`, unique per tenant.
  **Implemented** — `grep -n 'idRe\|boxRe =' internal/msg/msg.go` -> lines 32, 35.
- **FR-002** — `$SPOOL_BOX_ID` required and validated when `$SPOOL_HUB_URL` is
  set; local mode never reads it; no default. **Implemented** —
  `internal/config/config.go:79`.
- **FR-003** — Pin and revoke carry a **tenant-root** signature over the
  canonical payloads in `contracts/pin-semantics.md` §1; the pin list is
  box-authenticated (WS-issued token), not root-signed. **Implemented** —
  `internal/hub/rest.go:99-205`; `TestPinRESTRootSigned` PASS.
- **FR-004** — Box private key `$HOME/.spool/keys/box-<box_id>.key` `0600`;
  local pins `$SPOOL_ROOT/pins/box-<box_id>.pub` `0644`; private keys never
  leave the box. **Implemented** — `internal/sign/sign.go:26-27`;
  `TestPinCLIPublishesAndHygiene` PASS.
- **FR-005** — No TOFU: the hub verifies hello and envelopes against its pin
  row; the receiver re-verifies against its local pin; missing → 78.
  **Implemented** — `TestTamperedAndAmbiguousAndMissingPin`, `TestRecvVerifiesAfterPinSync` PASS.
- **FR-006** — Pin sync installs missing pins, is a no-op on the same key, and
  never clobbers a differing local pin (78). **Implemented** —
  `internal/hubclient/hubclient.go:508-540`; `TestPinSyncWritesAndConflictNoClobber` PASS.
- **FR-007** — Unicast; the sender signs `to_box`; unresolved and ambiguous →
  409 `ambiguous_to_box`; the hub fills no signed field. **Implemented** —
  `internal/hub/ws.go:332`.
- **FR-008** — pin / force / revoke each append a `pins_history` row
  (`reason ∈ {pin, force, revoke}`); only the active key verifies; a same-key
  re-pin writes nothing; re-activating a revoked box needs `force`
  (`contracts/pin-semantics.md` §2). **Implemented** — `4f611d6`;
  `TestTenantsAndPins` (memory + postgres), `TestPinRevokeAndForce` PASS.
- **FR-009** — The box daemon (`spool hub-run` / `hub-sync`) scans
  `$SPOOL_ROOT/*/` and announces the roster on `role=box` hello and on change;
  duplicate or invalid id → 409 `roster_duplicate`. **Implemented** —
  `internal/hubclient/flush.go:228`, `internal/hub/ws.go:268,478`.
- **FR-010** — Agent-id **allocation** is the harness's (the box harness's
  `next-agent-id.sh` or the renter's own), not spool's; the harness prepares
  the directories and ensures the box key exists before the AI CLI starts.
  **Implemented** — allocation: `csi-spl-orc/src/bash/features/spawn-agents/scripts/next-agent-id.sh` (`8c5bf43`);
  preparation: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-harness.sh` (spec 012, `c619d5d`), which takes the id
  with `--as` and never allocates. Contract:
  `../012-spool-box-api/contracts/spool-harness.md`.
- **FR-011** — Sub-agents get independent top-level ids. **Implemented** by the
  regex (FR-001); allocation is FR-010.
- **FR-012** — `BOX-` rejected at every validation point
  (`contracts/identifiers.md` §2). **Implemented** — Go `msg.go:180`
  (`TestValidID` PASS); SQL `roster` CHECK in `0005_pin_identity.sql`
  (`4f611d6`, `TestRosterIsPerBox/postgres` PASS).
- **FR-013** — A replayed pin / revoke cannot change a pin: each state change
  needs a signed `ts` later than the last one (`pins.last_op_ts`), else 409
  `stale_pin_op`. **Implemented** — `4f611d6`; `TestPinRevokeAndForce`
  (replayed revoke after force → 409) PASS.
- **FR-014** — The M1 proof exercises pins and cross-box routing against the
  live dev hub on the product domain. **Planned** — blocked on 007 ingress → T021.

## Verified status (2026-09-18)

| Area | Status | Evidence |
|---|---|---|
| Id regex + `BOX-` rejection (Go) | Implemented | `msg.go:180`; `TestValidID` PASS |
| `BOX-` rejection (SQL CHECK) | Implemented | `0005_pin_identity.sql` (`4f611d6`) |
| Schema `tenants / boxes / pins / pins_history / roster` | Implemented | `0001_hub_core.sql`, `0005_pin_identity.sql`; `TestPinSQLLivesInRDB` PASS |
| Pin / revoke / list | Implemented | `rest.go`; pin tests PASS |
| Pin sync, no-clobber | Implemented | `hubclient.go:508` |
| Roster, ambiguous `to_box`, last-hello-wins | Implemented | `ws.go:158,268,332` |
| Pin replay guard, same-key no-op, revoke needs force to undo | Implemented | `4f611d6` (pin-semantics §2, §5) |
| Live dev hub | Partial | Cloud Run `csi-spl-hub-dev` Ready, `spool-hub:0.1.0`, ingress `internal-and-cloud-load-balancing`, no LB → `curl …a.run.app/version` -> 404 from the Google front end; no live pin exercised |
| Live prd hub | Planned | `gcloud run services list --project=csi-spl-prd --account=$GCP_ACCOUNT` -> `SERVICE_DISABLED` |

Test runs (tree: this lane's worktree at `4f611d6`; n=1 each):
- `go test -count=1 ./...` in `csi-spl-api/src/go/spool-hub-api` -> all packages ok (in-memory store).
- `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` (temp `postgres:16-alpine`,
  migrations 0001..0005) -> store + hub suites ok, `ALL HUB E2E CHECKS PASSED`.
- `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` -> 6/6 (one earlier run read
  5/6, rerun 6/6 unchanged — flaky, not this change).

## Success Criteria

- **SC-001**: Different-key pin → 409 in a two-box test. **Implemented** (testhub).
- **SC-002**: Cross-box recv verifies after pin sync; 78 without it. **Implemented** (testhub).
- **SC-003**: Hub-down same-box round trip; flush idempotent on `msg_id`. **Implemented** (testhub).
- **SC-004**: SC-001..003 pass against the live dev hub on the product domain. **Planned** (T021).

## Assumptions

- The harness allocates agent ids per box; spool only validates.
- M1 tenants are owner-made (`spool hub-tenant`); self-service is 006 / M2.
- No pin UI in M1; pins are CLI (`spool pin`, `spool hub-pin`).

## Out of Scope

- Changing box-harness allocators or the 002 local model.
- Per-agent keys or IAM; the private-deploy IAM door (003 OQ-06, not M1).
- Multi-recipient / box-wide fanout; cross-tenant uniqueness.

<!-- version: 1.3.0 · updated: 2026-09-20 · last-edit: 2026-09-20T06:40:00Z -->
