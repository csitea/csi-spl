# Implementation Plan: Spool message bus (hub)

**Feature ID**: `003-spool-message-bus` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Architecture**: `../../doc/md/SPEC-spool-message-bus.md` · **Box API**: `../../doc/md/SPEC-spool-box-api.md`  
**Prerequisite**: `../002-box-agent-messaging/` (local folder + Ed25519 + CLI/MCP)

## Summary

Put the 002 box API in front of a **stateless Cloud Run** process. Persist messages/pins/acks in **Postgres**, file bytes in **GCS** (`file_id` = sha256), live notify on **NATS** (`task.<task_id>`). Keep `$SPOOL_ROOT` as the hub-down queue. IAM/OIDC on the door last. Agents still only call spool CLI/MCP.

## Technical Context

**Language/Version**: Go 1.22+ (same binary family as 002).

**Primary Dependencies**: 002 internal packages (`msg`, `sign`, `files`); Cloud Run HTTP server harness (`github.com/gofiber/fiber/v2`); structured logging (`github.com/rs/zerolog`); Postgres (`pgx/v5`); GCS client; NATS client **only in the box sidecar and the hub publisher**, never in agent code.

**Server Harness & Logging**: Derived from `pas-psf` Go architecture:
- `config.Load()`: Typed, fail-fast configuration from environment variables.
- `logging.New(cfg)`: Root `zerolog.Logger` with RFC3339 timestamps, standard fields (`service: spool-hub-api`, `env`, `version`), JSON in cloud and console in dev/CLI.
- Server lifecycle: `runUntilShutdown` pattern catching `SIGINT`/`SIGTERM`, graceful drain within `API_GRACEFUL_SHUTDOWN_SECONDS`, clean shutdown or fatal exit.
- HTTP surface: Shared middleware (recover, request ID, structured access logging) and ops probes (`/version`, `/healthz`).

**Storage**: Postgres (tasks, messages, pins, acks); GCS `files/<sha256>`; local `$SPOOL_ROOT` fallback; **not** container disk.

**Testing & Test Harness**:
- `go test ./...`: tests use `internal/testkit` (modeled directly on `/opt/pas/pas-psf/pas-psf-api/src/internal/testkit/`) with `testkit.NewApp(t)` building in-memory Fiber test instances and `testkit.AssertEnvelopeError`.
- Contract tests against `contracts/http-v1.md` and golden fixtures under `internal/hub/testdata/`.
- Shell function utilities and tests under `csi-spl-api/src/bash/` following `pas-psf` conventions.

**Local Dev Setup (`lde`) Reference**:
Directly modeled on the local development environment from `/opt/pas/pas-psf`:
- **Terraform (`csi-spl-iac`)**: Containerized runner or host `./run` actions (`tfswitch`, `do_tf_init`, `do_tf_plan`, `do_tf_validate`) rendering variables via `tpl-gen` from `csi-spl-cnf`, following `/opt/pas/pas-psf/pas-psf-orc` (`con-*-tf-runner`) and `pas-psf-iac`.
- **Backend (`csi-spl-api`)**: Local Postgres test database (Docker container or local instance modeled on `/opt/pas/pas-psf/pas-psf-api/src/bash/scripts/start-api-test-db.sh`), fail-fast local `.env` loading, and `go run ./cmd/hub` (or `make do-setup-api`).
- **Frontend (`csi-spl-wui`)**: Lightweight thread/task viewer modeled on `/opt/pas/pas-psf/pas-psf-wui` (pnpm, Nuxt/Vite dev server with HMR on localhost, containerized via orc or run directly on host).

**Target Platform**: Linux boxes + Cloud Run `europe-north1`.

**Project Type**: extend the Go module `csi-spl-api/src/go/spool-hub-api` with `internal/httpapp`, `internal/hub` (HTTP), `internal/config`, `internal/logging`, and optional `internal/notify`; IaC under `csi-spl-iac` for Cloud Run / SQL / GCS / NATS when the owner says apply.

**Constraints**: Constitution I–VIII. No Kafka. No per-agent GCP keys. Sign on day one (already 002). No default hostnames.

**Scale/Scope**: handful of boxes, human-scale JSON tasks. Not millions of events.

## Constitution Check

- [ ] **I. Paths** — hub + CLI under csi-spl sub-projects (`csi-spl-api/src/go/spool-hub-api`); no hard-coded `/opt/...`.
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
    ├── nats-subjects.md
    ├── flush.md
    ├── limits.md
    └── error-envelope.md
├── data-model.md

csi-spl-api/src/go/spool-hub-api/   # same module as 002
├── cmd/spool/                      # CLI + MCP entrypoint
├── cmd/hub/ (or spool hub)         # Cloud Run entrypoint: boot order (config, logging, pool, wire, runUntilShutdown)
├── internal/config/                # fail-fast typed config (pas-psf pattern)
├── internal/logging/               # zerolog structured logger (pas-psf pattern)
├── internal/testkit/               # testkit app builder, assertions, fixtures (pas-psf pattern)
├── internal/httpapp/               # server harness, middleware stack, ops probes (/healthz, /version)
├── internal/hub/                   # HTTP handlers (/v1/messages, /v1/files); verify sig; no disk log
├── internal/store/                 # Postgres (and sqlite for tests)
├── internal/objects/               # GCS (and local files/ for tests + fallback)
└── internal/notify/                # NATS publish/subscribe (optional build tag until US4)

csi-spl-api/src/bash/              # shell scripts and function utils (pas-psf pattern)
csi-spl-iac/                        # Cloud Run, Cloud SQL, GCS, NATS — apply only with owner go
```

**Structure Decision**: one Go module continues. Hub is a subcommand (`spool hub`) or dedicated binary (`cmd/hub/main.go`) sharing the pas-psf server harness. Sidecar is `spool sidecar` (NATS + flush). Agents never link those packages.

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

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
