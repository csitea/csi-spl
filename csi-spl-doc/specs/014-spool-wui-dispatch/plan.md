# Implementation Plan: 014 Spool WUI dispatch

**Spec**: `./spec.md` · **Contract**: `./contracts/wui-dispatch.md` ·
**Code home**: `csi-spl-api/src/go/spool-hub-api`

## Approach

Reuse the box path end to end. The hub gains one signing key and signs a
browser command exactly as a box would (`wire.NewEnvelope`); the box verifies
it exactly as it verifies a box (`wire.Envelope.Verify` against a synced pin).
No new crypto, no new wire fields, no migration.

| Piece | Where |
|---|---|
| env + fail-fast (`SPOOL_HUB_WUI_*`) | `internal/config/config.go` (`Hub`) |
| key decode / ephemeral generate, pubkey log | `cmd/spool/hub.go` -> `hub.Options.WUIKey`, `WUIDispatch` |
| `GET /v1/wui/pubkey`, dispatch resolve/sign/verify/commit | `internal/hub/dispatch.go` (new) |
| send -> dispatch branch, session identity on the socket | `internal/hub/wui.go` (DISPATCH owns the send -> deliveries path) |
| `box-wui` pin only for the hub key | `internal/hub/rest.go` `handlePin` |
| hello as `box-wui` refused | `internal/hub/ws.go` `hello` |
| box-side role restriction | `internal/hubclient/hubclient.go` `receive` |
| tests | `internal/hub/dispatch_test.go` (new) |

## Test seam

A real 010 session needs the full IdP flow. `hub.Options.SessionID`
(`func(*http.Request, tenant) (humanID, error)`, nil = `Auth.SessionForTenant`)
lets tests assert "this socket is a member session" without faking cookies.
It is set by code only (no env var).

## Decisions

1. OQ-014-1 (a): tenant-root-signed `box-wui` pin, restricted role (spec §0).
2. OQ-014-2 (a): the session always wins; no anonymous dispatch.
3. OQ-014-3: per-process `HUM-<n>` map keyed by the session human id, in its
   own namespace so a browser display name can never collide with it.
4. No rdb 0007: nothing new is persisted.
5. Flag `SPOOL_HUB_WUI_DISPATCH` off by default; ORC: on for dev, off for prd.

## Verification

- `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green (baseline diffed).
- Positive: WUI send `@CLE-07` -> deliveries row for `box-a` whose sig verifies
  against the `box-wui` pin with `wire.Envelope.Verify`; a live `box-a`
  hubclient session writes it to `CLE-07/inbox`.
- Controls: tampered envelope fails the same verify; a key that is not the
  pinned one fails; unpinned `box-wui` -> `wui_unpinned`; no session ->
  `dispatch_unauthenticated`; flag off -> browser-only.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T06:10:00Z -->
