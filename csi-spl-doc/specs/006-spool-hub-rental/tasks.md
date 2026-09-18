# Tasks: Rented spool-hub

**Feature**: `specs/006-spool-hub-rental`

Gate: 002 v:1 + a testhub process (003 or in-memory/Postgres store).

## Phase 1: Tenant

- [x] T001 `tenants` table: id, root_pubkey, billing_status, quotas
- [x] T002 [P] Resolve tenant from Host/path; fail-fast if unknown
- [x] T003 `do_spl_tenant_create` returns URL + root key **once**; DB has
      pubkey only
- [x] T004 [P] Isolation test: two tenants, same `GRK-03` different keys

## Phase 2: Root-signed pins (US2)

- [x] T005 `POST /v1/pins` verifies tenant root sig
- [x] T006 CLI `spool-pin` / `spool pin` uses `--root-key` / `$SPOOL_TENANT_ROOT_KEY` in hub mode
- [x] T007 Box self-pin without root → 401/400

## Phase 3: Key-only send/recv (US3)

- [x] T008 Hub `/v1/ws` `send` frame verifies `from_box` pin in this tenant and verifies box Ed25519 signature
- [x] T009 Hub `/v1/ws` `hello` authenticates box with nonce challenge-response and box pin; delivers queued `recv` frames
- [x] T010 CLI hub mode: send uses WebSocket envelope; background hubclient daemon receives frames into local inboxes
- [ ] T011 [P] Smoke: two `$SPOOL_ROOT`s, GRK→CLE, no GCP env
- [ ] T011b [P] [US3b] Three pinned peers; CLE→GRK and AGY→CLE `task` both recv

## Phase 4: Quota / unpaid (US4)

- [x] T012 Enforce quota → 429
- [x] T013 Unpaid: send/pin 402, recv ok during grace

## Phase 5: Polish

- [x] T014 Public deploy notes: allow unauthenticated; rate-limit unsigned (doc: 24d086f)
- [ ] T015 Hygiene: no vendor payment name; no private keys in logs

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:35:00Z -->
