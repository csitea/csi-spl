# Implementation Plan: Identity, pins, and routing

**Feature ID**: `004-spool-identity-routing` · **Status**: Partial · **Date**: 2026-09-18 (redo)

**Spec**: `./spec.md` · **Contracts**: `./contracts/identifiers.md`,
`./contracts/pin-semantics.md` · **Wire**: `../003-spool-message-bus/contracts/http-v1.md`
· **Rules**: `../README.md`

## Summary

Identity is three layers that never mix: **tenant** (Host → tenant row, root
pubkey), **box** (`$SPOOL_BOX_ID`, one Ed25519 key, pinned by the tenant root),
**agent** (`CLE-07`, a name unique per box, no key). The hub pins boxes, the
boxes sync pins down as authorized_keys, and messages route to
`(to_box, to)`. Local mode has none of this (trust-modes §2).

Most of it is built and tested (spec "Verified status"). The remaining work is
three small code hardenings (T019, T020, T022) and the live proof (T021), which
waits on 007.

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
- [ ] `BOX-` rejected at every layer — SQL CHECK missing (T019).
- [ ] Root-signed writes non-replayable (T020).

## Build order (remaining)

1. T019, T022 — independent, code + rdb + tests; any order.
2. T020 — changes the signed pin payload; coordinate with 003 (it hosts the wire
   in `http-v1.md` §4) and 006 (root-key tooling). Land before M2 self-service.
3. T021 — after 007 steps 3 (DNS zone) and 10 (ingress) exist for dev
   (`../README.md` §6) and a dev tenant is seeded.

## Risks

- **Replay** of pin/revoke inside the skew window (pin-semantics §5) — M1
  mitigated by owner-only root keys; must close before renters hold root keys (M2).
- **Un-revoke by same-key pin** (pin-semantics §2.1) combines with replay.
- **Host → tenant** mapping is 006's (`GRK-3338-006-tenants-host` is live);
  004's pin semantics assume it resolves one tenant per request.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
