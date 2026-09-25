# Tasks: the wire fast path (030)

Status lives in `spec.md` §0.5–§0.7. This file exists so the index in
`../README.md` has a task list to point at. It does not add requirements.

| id | item | status | evidence |
|---|---|---|---|
| T001 | FP-2 warm submit on the sidecar socket, byte-identical envelope (FR-004, FR-006) | Implemented | `internal/hubclient/submit.go` `Listen` (`os.Chmod(path, 0o600)`); `spec.md` §0.5–§0.6 |
| T002 | box keepalive so a black-holed socket ends | Implemented | `spec.md` §0.7 |
| T003 | hello `caps` negotiation, absent caps = old path (FR-005) | Planned | tokens live in `contracts/fastpath-v1.md` only. On `4ae33835`, `grep -R 'json:"caps' csi-spl-api` → 0. No hub frame until a measurement says one is needed (FR-001) |
| T004 | FP-1 notifier must not block the sidecar read (FR-002, FR-003) | Implemented | `internal/notify/queue.go`; `cmd/spool/hub.go` `cmdHubRun` calls `notify.Start`. Tests: `TestDeliverDoesNotBlockTheCallerWhileAQueueIsInstalled`, `TestALanePokesInDeliveryOrder`, `TestLanesForDifferentAgentsRunConcurrently` |
| T005 | `do_spl_wire_probe` dial vs warm submit (FR-001) | Implemented | `csi-spl-orc/src/bash/run/spl-wire-probe.func.sh` |
| T006 | rollback flags (FR-007) | Implemented | `c850098d`: `Config.NotifyAsyncOff`, `TestNotifyAsyncOff`, `cmdHubRun` skips `notify.Start` when `SPOOL_NOTIFY_ASYNC` is `0`/`false`/`off`. Submit rollback is `SPOOL_SUBMIT_SOCKET=off` (`SubmitOff`, `submit_test.go`). Unset submit socket stays ON (the default path) |

No open task in this lane asks for a new hub frame.

<!-- version: 0.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:18:58Z -->
