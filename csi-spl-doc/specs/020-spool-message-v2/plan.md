# Implementation Plan: Spool Message Schema `v:2` (020)

**Spec**: `./spec.md` · **Contracts**: `./contracts/`

## 1. Touch points (tree `dabd2d4`)

| where | today | change |
|---|---|---|
| `internal/msg/msg.go` | `const Version = 1`; `Validate` rejects `v != 1` | `V1`, `V2`, `Supported(v)`; `Version` stays `1` (the default writer version); `Validate` accepts `Supported(v)` |
| `internal/config/config.go` | — | box `MsgVersion` (`SPOOL_MSG_VERSION`, default 1); hub `MsgVersion` (`SPOOL_HUB_MSG_VERSION`, default 1); both fail fast outside `{1,2}` |
| `internal/spool/spool.go` `Compose` | writes `msg.Version` | writes `cfg.MsgVersion` (0 → `msg.Version`) |
| `internal/spool/spool.go` legacy bridge | `msg.Version` | `msg.V1`, explicitly |
| `internal/hub/wui.go` (WUI post / dispatch) | `msg.Version` | `Options.MsgVersion` |
| `internal/cicdlogs/cicdlogs.go` | `msg.Version` | `Service.MsgVersion` |
| `internal/wire/wire.go` | — | `Frame.MsgVersions []int` (`msg_versions`); `InnerVersion(env)` |
| `internal/hubclient/hubclient.go` hello | — | sends `MsgVersions: msg.Supported` |
| `internal/hub/ws.go` hello / `push` | — | session keeps the advertised set (absent → `[1]`); `push` skips a row whose inner `v` is not in it |

What does NOT change: `wire.Canonical`, `SigningPayload`, `HelloPayload`,
`msg.Canonical`, `msg.Marshal`, the store schema, the view API, the WUI parser.

## 2. Tests

| test | proves |
|---|---|
| `msg` `TestValidateAcceptsV1AndV2`, `TestV2RoundTrip`, `TestContractLiteralV1RefRejected`, `TestUnknownFileRefKeyRejected` | FR-001, schema §4 rows 5 and 9 |
| `wire` `TestGoldenV1V2Envelopes` | FR-003, golden bytes + sigs + no cross-version replay |
| `config` `TestMsgVersionKnob` | FR-002 fail-fast |
| `hub` `TestMixedFleetV1V2` | SC-003 |
| `hub` `TestV2HeldForV1OnlySession` | SC-004, with the control: the pre-020 behaviour (no guard) pushes and the old reader drops it |
| existing `v:1` suites unchanged | SC-001 |

Module suite: `bash csi-spl-api/src/bash/tests/run-all-tests.sh`.

## 3. Rollout

`./contracts/migration.md` §2. The hub roll goes through the deploy lane
(CLE-3355: `hub.image.tag` bump, step 030 via make). The WUI type change goes
through CLE-55.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T15:10:00Z -->
