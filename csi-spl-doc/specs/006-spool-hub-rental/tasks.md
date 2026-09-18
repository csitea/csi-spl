# Tasks: Rented spool-hub

**Feature**: `specs/006-spool-hub-rental`

Gate: 002 signed `v:1` + a testhub process (003 T005 or sqlite).

## Phase 1: Tenant

- [ ] T001 `tenants` table: id, root_pubkey, billing_status, quotas
- [ ] T002 [P] Resolve tenant from Host/path; fail-fast if unknown
- [ ] T003 `do_spl_tenant_create` returns URL + root key **once**; DB has
      pubkey only
- [ ] T004 [P] Isolation test: two tenants, same `GRK-03` different keys

## Phase 2: Root-signed pins (US2)

- [ ] T005 `POST /v1/pins` verifies tenant root sig
- [ ] T006 CLI `spool-pin` uses `$SPOOL_TENANT_ROOT_KEY` in hub mode
- [ ] T007 Agent self-pin without root → 401/400

## Phase 3: Key-only send/recv (US3)

> **⚠ T008–T010 are superseded (003 OQ-02, 2026-09-18).** Hub send/recv is
> **WebSocket only**; `POST/GET /v1/messages` and `POST /v1/recv` no longer
> exist. Rewrite these three tasks against `../003-spool-message-bus/contracts/http-v1.md`
> §2 (hello with nonce, box-signed envelope, `recv` frames) before implementing
> them. The 003 hub already implements that transport; 006 adds tenant/billing
> on top. Not implemented by 003.

- [ ] T008 `POST /v1/messages` verifies `from` pin **in this tenant** (no IAM)
- [ ] T009 `POST /v1/recv` signed by `as`; replay window on `ts`
- [ ] T010 CLI hub mode: recv uses POST /v1/recv; send unchanged `v:1`
- [ ] T011 [P] Smoke: two `$SPOOL_ROOT`s, GRK→CLE, no GCP env
- [ ] T011b [P] [US3b] Three pinned peers; CLE→GRK and AGY→CLE `task` both recv

## Phase 4: Quota / unpaid (US4)

- [ ] T012 Enforce quota → 429
- [ ] T013 Unpaid: send/pin 402, recv ok during grace

## Phase 5: Polish

- [ ] T014 Public deploy notes: allow unauthenticated; rate-limit unsigned
- [ ] T015 Hygiene: no vendor payment name; no private keys in logs

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T15:55:00Z -->
