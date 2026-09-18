# Implementation Plan: Identity, pins, and routing

**Feature ID**: `004-spool-identity-routing` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-identity-routing.md`

## Summary

Add hub pin registry, box_id door mapping, pin sync to `$SPOOL_ROOT/pins/`,
and dual-write/flush. No new message schema.

## Technical Context

**Language**: Go 1.22+, module `csi-spl-api/src/go/spool-hub-api`.

**Depends**: 002 pin files; 003 `internal/hub` + `internal/store`.

**New endpoints**: `POST /v1/pins`, `GET /v1/pins`, `DELETE /v1/pins/{box_id}`.

**Tables**: `boxes`, `pins`, `pins_history` (003 `data-model.md`).

**Testing**: two `SPOOL_BOX_ID`s against one testhub; flush idempotency.

## Constitution Check

- [ ] VII — private keys never uploaded
- [ ] VIII — no per-kind pin API
- [ ] II — `$SPOOL_BOX_ID`, `$SPOOL_HUB_URL` fail-fast

## Structure

```text
internal/store/pins.go
internal/hub/pins.go
internal/hubclient/flush.go
cmd/spool  # pin --force/--revoke; sidecar
```

## Build order

After 003 US1 WebSocket messages exist (or in parallel on in-memory testhub). Flush
after local outbox exists (002 US1).

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:42:00Z -->
