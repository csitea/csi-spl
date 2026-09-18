# Implementation Plan: Spool message bus (hub)

**Feature ID**: `003-spool-message-bus` · **Status**: M1 hub Implemented (verified 2026-09-18, `spec.md` → Verification); viewer API (US7) Planned · **Date**: 2026-09-18 · **Ground rules**: `../README.md`

**Spec**: `./spec.md` · **Architecture**: `../../doc/md/SPEC-spool-message-bus.md` · **Binding trust/transport**: `../002-box-agent-messaging/contracts/trust-modes.md` · **Milestones**: `../../doc/md/SPEC-spool-milestones.md` · **Box API**: `../../doc/md/SPEC-spool-box-api.md`  
**Prerequisite**: `../002-box-agent-messaging/` (local folder + CLI/MCP)

## Summary

Put a **stateless Cloud Run** process (HTTPS + WebSocket) behind the 002 box API. Boxes hold one Ed25519 key each, pinned by the tenant root. A box authenticates with a signed WS hello and sends box-signed envelopes around the unchanged inner `v:1` object. Persist messages, the hub queue, pins and the roster in **Postgres** (no `acks`, OQ-08), and file bytes in **GCS** (`t/<tenant>/files/<sha256>`, one bucket). Keep `$SPOOL_ROOT` as the local mail store and hub-down queue. M1 runs **`max-instances=1`** (OQ-05), so live dispatch is an in-process socket map; cross-instance dispatch via Postgres `LISTEN/NOTIFY` is **post-M1**. Agents still only call spool CLI/MCP. For M3 the hub adds a **read-only viewer API** (`contracts/view-v1.md`) that the WUI (005) reads with a view token; it never drains or mutates.

## Technical Context

**Language/Version**: Go 1.22+ (same module as 002: `csi-spl-api/src/go/spool-hub-api`).

**Primary Dependencies**: 002 internal packages (`msg` for the inner object and canonical JSON, `sign` for Ed25519); HTTP server harness on `net/http` (pas-psf lifecycle pattern; Fiber dropped because the WebSocket library `github.com/coder/websocket` is `net/http`-native); structured logging (`github.com/rs/zerolog`); Postgres (`pgx/v5`); GCS client. No notify client in M1.

**Server Harness & Logging**: Derived from the `pas-psf` Go architecture (read-only reference):
- `config.Load()`: typed, fail-fast configuration from environment variables.
- `logging.New(cfg)`: root `zerolog.Logger`, RFC3339 timestamps, standard fields (`service: spool-hub-api`, `env`, `version`), JSON in cloud and console in dev/CLI.
- Server lifecycle: `runUntilShutdown` catching `SIGINT`/`SIGTERM`, graceful drain within `API_GRACEFUL_SHUTDOWN_SECONDS` (which must also close WS sockets cleanly), clean shutdown or fatal exit.
- HTTP surface: shared middleware (recover, request ID, structured access logging) and ops probes (`/version`, `/healthz`).

**Storage**: Postgres only (tenants, boxes, pins, roster, messages, deliveries; `data-model.md`; DDL in `csi-spl-rdb/src/sql/postgres/spool-hub/`, applied by `spool migrate`); GCS one bucket `t/<tenant>/files/<sha256>`; local `$SPOOL_ROOT` on the box; **nothing** on container disk.

**Testing & Test Harness**:
- `go test ./...` with `internal/testkit` (pas-psf pattern: `testkit.NewApp(t)` builds an in-memory app, `testkit.AssertEnvelopeError`). 002 already created `internal/testkit`; 003 extends it and does not fork it.
- Contract tests against `contracts/http-v1.md` with golden frames under `internal/hub/testdata/`. Golden vectors for the envelope and hello signing payloads (OQ-03).
- Two-box tests: two temp `$SPOOL_ROOT`s, two box keys, tested against local Postgres test DB (docker compose).
- Shell tests under `csi-spl-api/src/bash/tests/` (run by `run-all-tests.sh`).

**Local Dev Setup (`lde`) Reference** (modelled on `pas-psf`):
- **Terraform (`csi-spl-iac`)**: containerised runner or host `./run` actions (`do_tf_init`, `do_tf_validate`, `do_tf_plan`) rendering tfvars via `tpl-gen` from `csi-spl-cnf`. No apply action (repo rule).
- **Backend (`csi-spl-api`)**: local Postgres test DB (container), fail-fast `.env`, `go run ./cmd/spool hub` (or `cmd/hub`, see Structure Decision).
- **Frontend**: none in this feature. The WUI (spec 005, M3) consumes `contracts/view-v1.md`.

**Target Platform**: Linux boxes + Cloud Run `europe-north1`, min instances 1 by default (cnf, 0 allowed).

**Project Type**: the Go module gained `internal/wire`, `internal/hub`, `internal/store`, `internal/blob` and the box-side `internal/hubclient` (`81121a0`, `7905e35`). IaC is 007's (`../README.md` §6); 003 only names cnf keys.

**Constraints**: Constitution I–VIII. No Kafka. No NATS in M1. No per-agent keys on the hub. No renter IAM. No default hostnames (product DNS `<tenant>.spool-hub.ai` comes from cnf/env only).

**Scale/Scope**: a handful of boxes per tenant, human-scale JSON tasks. Not millions of events.

## Constitution Check

- [x] **I. Paths**: hub + CLI under `csi-spl-api/src/go/spool-hub-api`; no hard-coded `/opt/...`.
- [x] **II. Env**: `$SPOOL_HUB_URL`, `$SPOOL_BOX_ID`, `$SPOOL_ROOT`, `$SPOOL_MIRROR_LOCAL`, store DSN, bucket, queue TTL, pin refresh interval all fail fast from env / cnf.
- [x] **VI. Cnf-only**: Cloud Run service URL, product domain, bucket, min instances from `csi-spl-cnf`.
- [x] **VII. No key in git/state/log**: box and tenant-root private keys never reach the hub; signed URLs not logged; the WS hello `sig` is not a secret but no private material is logged.
- [x] **VIII. Uniform API**: no per-kind routes, frames or fields. OQ-01 resolved: `--to-box` / `delivery` are an additive, allowed change.
- [x] **V. Hygiene**: placeholders in examples (`<DEV_BOX>`, `FirstName LastName`, `box-a`).
- [x] **Reference read-only**: no ysg-box imports; pas-psf patterns are copied, never imported.

Checked against the implemented M1 hub: T029 hygiene test, CI `distribution-hygiene` sweep, `no-ysg-box-ref.tst.sh`. US7 adds two cnf keys (`hub.view_cors_origins`, `hub.view_token_max_ttl`) and must keep all seven boxes ticked.

## Project Structure

```text
specs/003-spool-message-bus/
├── spec.md
├── plan.md                 # this file
├── data-model.md
├── tasks.md
└── contracts/
    ├── http-v1.md          # WS + REST inventory (the hub transport)
    ├── flush.md            # dual-write, box-side flush
    ├── limits.md
    ├── error-envelope.md
    ├── view-v1.md          # read-only viewer API for the WUI (US7, Planned)
    └── nats-subjects.md    # DEFERRED post-M1 notify rules

csi-spl-api/src/go/spool-hub-api/   # same module as 002
├── cmd/spool/                      # CLI + MCP (002) + `serve`, `migrate`, `hub-run`, `hub-sync`, `hub-tail`, `hub-pin`
├── internal/{msg,sign,files,spool} # 002 box API. 003 does NOT change their behaviour
├── internal/config/                # exists (002); hub keys added, fail-fast
├── internal/logging/               # exists (002)
├── internal/testkit/               # exists (002); hub helpers added
├── internal/wire/                  # NEW: frames + envelope/hello signing payloads (both sides)
├── internal/hub/                   # NEW: server harness, WS hello/roster/send/recv/tail, REST files + pins (+ /v1/view, Planned); no disk
├── internal/store/                 # NEW: memory (tests) + Postgres; migrator for csi-spl-rdb DDL
├── internal/blob/                  # NEW: GCS (+ local dir for tests)
└── internal/hubclient/             # NEW (box side): WS client, envelope sign, pin sync, flush (OQ-15)

csi-spl-rdb/src/sql/postgres/spool-hub/   # NEW: ordered forward-only DDL (`spool migrate`)

csi-spl-api/src/bash/              # shell tests and utils (pas-psf pattern)
csi-spl-iac/                        # Cloud Run, Cloud SQL, GCS: apply only with the owner's go
```

**Structure Decision**: one Go module, one binary. The hub is the `spool serve` subcommand; `spool migrate` applies the DDL. Agents never link hub packages. The envelope signing and flush code lives on the **box** side, not in `internal/hub`.

## Build Order (maps to milestones)

| Step | What | Spec story | Milestone |
|---|---|---|---|
| 1 | 002 local folder, unsigned `v:1` (already specified) | 002 | M1 prerequisite |
| 2 | Hub process: harness, probes, tenant-from-Host, in-memory store | US1 | M1 |
| 3 | WS hello + roster + envelope send/recv between two boxes | US1 | M1 |
| 4 | REST files with box proof, GCS in prod / local dir in tests | US2 | M1 |
| 5 | Hub queue for offline `to_box` (`delivery=queued`) + box-side flush when the hub is down | US3 | M1 |
| 6 | Postgres + GCS in integration/prod; Cloud Run rollout is 007's (dev live, prd not) | US1–US3 | M1 |
| 7 | Tail frames on the existing WS (OQ-04) | US4 | M1 |
| 7a | Read-only viewer API `/v1/view/*` + view token + CORS (Planned) | US7 | before M3 |
| 8 | IAM front for private deploys (OQ-06: not in M1) | US5 | after M1 |
| 9 | ysg-box adapter (other repo) | US6 | after M1 |

Pins (004/006) are a hard dependency of step 3: a hello cannot verify without a pinned box.

## Complexity Tracking

*No constitutional violations are intended.* OQ-01 allows the additive `to_box` / `delivery` change to the box API. OQ-05 pins M1 to `max-instances=1`; a cross-instance channel is post-M1.

<!-- version: 0.4.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:10:00Z -->
