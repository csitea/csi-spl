# Implementation Plan: Spool message bus (hub)

**Feature ID**: `003-spool-message-bus` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Architecture**: `../../doc/md/SPEC-spool-message-bus.md` · **Box API**: `../../doc/md/SPEC-spool-box-api.md`  
**Prerequisite**: `../002-box-agent-messaging/` (local folder + Ed25519 + CLI/MCP)

## Summary

Put the 002 box API in front of a **stateless Cloud Run** process. Persist messages/pins/acks in **Postgres**, file bytes in **GCS** (`file_id` = sha256), live notify on **NATS** (`task.<task_id>`). Keep `$SPOOL_ROOT` as the hub-down queue. IAM/OIDC on the door last. Agents still only call spool CLI/MCP.

## Technical Context

**Language/Version**: Go 1.22+ (same binary family as 002).

**Primary Dependencies**: 002 internal packages (`msg`, `sign`, `files`); Cloud Run HTTP; Postgres; GCS client; NATS client **only in the box sidecar and the hub publisher**, never in agent code.

**Storage**: Postgres (tasks, messages, pins, acks); GCS `files/<sha256>`; local `$SPOOL_ROOT` fallback; **not** container disk.

**Testing**: `go test ./...` with a fake hub (httptest + sqlite/memory) before real Cloud Run; contract tests against `contracts/http-v1.md`.

**Target Platform**: Linux boxes + Cloud Run `europe-north1`.

**Project Type**: extend the 002 Go module with `internal/hub` (HTTP) and optional `internal/nats`; IaC under `csi-spl-iac` for Cloud Run / SQL / GCS / NATS when the owner says apply.

**Constraints**: Constitution I–VIII. No Kafka. No per-agent GCP keys. Sign on day one (already 002). No default hostnames.

**Scale/Scope**: handful of boxes, human-scale JSON tasks. Not millions of events.

## Constitution Check

- [ ] **I. Paths** — hub + CLI under csi-spl sub-projects; no hard-coded `/opt/...`.
- [ ] **II. Env** — hub URL, `$SPOOL_ROOT`, buckets, NATS URL fail-fast env / cnf.
- [ ] **VI. Cnf-only** — Cloud Run service URL and bucket from `csi-spl-cnf`.
- [ ] **VII. No key in git/state/log** — agent private keys never on the hub; signed URLs not logged.
- [ ] **VIII. Uniform API** — no per-kind routes.
- [ ] **V. Hygiene** — placeholders in examples (`<DEV_BOX>`, `FirstName LastName`).
- [ ] **Reference read-only** — still no ysg-box imports.

## Project Structure

```text
specs/003-spool-message-bus/
├── spec.md
├── plan.md                 # this file
├── tasks.md
└── contracts/
    ├── http-v1.md
    └── nats-subjects.md

csi-spl-utl/src/go/spool/   # same module as 002
├── internal/hub/           # HTTP handlers; verify sig; no disk log
├── internal/store/         # Postgres (and sqlite for tests)
├── internal/objects/       # GCS (and local files/ for tests + fallback)
└── internal/notify/        # NATS publish/subscribe (optional build tag until US4)

csi-spl-iac/                # Cloud Run, Cloud SQL, GCS, NATS — apply only with owner go
```

**Structure Decision**: one Go module continues. Hub is a subcommand (`spool hub`) or the same binary with `SPOOL_MODE=hub`. Sidecar is `spool sidecar` (NATS + flush). Agents never link those packages.

## Build Order (maps to architecture §10)

| Step | What | Spec story |
|---|---|---|
| 1 | 002 local folder + pin (already specified) | 002 |
| 2 | HTTP API on a process (memory/sqlite) | US1 |
| 3 | Postgres + GCS | US2 |
| 4 | Local queue flush when hub down | US3 |
| 5 | NATS JetStream notify | US4 |
| 6 | IAM/OIDC on Cloud Run | US5 |
| 7 | ysg-box adapter (other repo) | US6 |

Do not start NATS or Kafka before step 2 works on a dummy folder/process.

## Complexity Tracking

*No constitutional violations.* NATS is deferred to US4 so the HTTP contract is proven first (architecture: “don’t debug NATS before spool-send works”).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T12:50:00Z -->
