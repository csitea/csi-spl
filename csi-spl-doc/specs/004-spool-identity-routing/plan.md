# Implementation Plan: Identity, pins, and routing

**Feature ID**: `004-spool-identity-routing` · **Status**: Partial (live proof pending) · **Date**: 2026-09-18 (redo)

**Spec**: `./spec.md` · **Contracts**: `./contracts/identifiers.md`,
`./contracts/pin-semantics.md` · **Wire**: `../003-spool-message-bus/contracts/http-v1.md`
· **Rules**: `../README.md`

## Summary

Identity is three layers that never mix: **tenant** (Host → tenant row, root
pubkey), **box** (`$SPOOL_BOX_ID`, one Ed25519 key, pinned by the tenant root),
**agent** (`CLE-07`, a name unique per box, no key). The hub pins boxes, the
boxes sync pins down as authorized_keys, and messages route to
`(to_box, to)`. Local mode has none of this (trust-modes §2).

It is built and tested (spec "Verified status"); the three hardenings found
in the redo (T019, T020, T022) landed in `4f611d6`. What remains is the live
proof (T021), which waits on 007, and an owner decision on the harness (T023).

## Technical Context

| | |
|---|---|
| Code | Go module `csi-spl-api/src/go/spool-hub-api` |
| Id validation | `internal/msg/msg.go` (`ValidID`, `ValidBoxID`) |
| Keys + local pins | `internal/sign/sign.go` |
| Hub pin handlers | `internal/hub/rest.go`; hello / roster / routing `internal/hub/ws.go` |
| Pin sync, roster scan, flush | `internal/hubclient/hubclient.go`, `internal/hubclient/flush.go` |
| Store | `internal/store/{store,memory,postgres}.go` |
| Schema | `csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql` (`tenants`, `boxes`, `pins`, `pins_history`, `roster`) |
| CLI | `cmd/spool` verbs `keygen`, `pin`, `root-keygen`, `hub-tenant`, `hub-pin`, `hub-sync`, `hub-run` |
| Config | `$SPOOL_BOX_ID`, `$SPOOL_HUB_URL`, `$SPOOL_TENANT_ROOT_KEY`, `$SPOOL_MIRROR_LOCAL`, `SPOOL_HUB_HELLO_SKEW` (300s) |
| Tests | `go test ./internal/...` (in-memory testhub); `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` for the repo |

## Constitution / canon check

- [x] Local mode unsigned — `TestUS1_UnsignedNoKeyNoPin` PASS.
- [x] One key per box, no agent keys — `internal/sign/sign.go:4-8`.
- [x] Private keys never uploaded — `TestPinCLIPublishesAndHygiene` PASS.
- [x] No TOFU — `TestTamperedAndAmbiguousAndMissingPin` PASS.
- [x] No per-kind pin API; REST is files + pins only (003 OQ-02).
- [x] Fail-fast env — `internal/config/config.go:79`.
- [x] `BOX-` rejected at every layer — SQL CHECK in `0005_pin_identity.sql` (T019).
- [x] Root-signed writes non-replayable by ordering (T020, `pins.last_op_ts`).

## Build order (remaining)

T019, T020, T022 landed in `4f611d6`. Left:

1. T021 — live proof on dev, after 007 steps 3 (DNS zone) and 10 (ingress)
   exist (`../README.md` §6) and a dev tenant is seeded. The dev DB must first
   be migrated to `0005_pin_identity.sql` (`spool migrate` via
   `do_spl_db_bootstrap`, 007).
2. T023 — owner decision on the harness verb.

## Risks

- Replay is closed by ordering, not a nonce: it relies on the operator clock
  being inside the skew window (pin-semantics §5).
- **Host → tenant** mapping is 006's; pin semantics assume one tenant per request.
- The migration number `0005` skips `0004`, which the 006 tenants-host lane
  holds on its branch (`0004_tenant_quotas.sql`); the runner orders by filename
  and records each file, so either landing order applies cleanly.

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:23:00Z -->
