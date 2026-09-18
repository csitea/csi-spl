# Tasks: Identity, pins, and routing

**Feature**: `specs/004-spool-identity-routing`

Gate: 002 US1 (local pin + local send) and 003 US1 (/v1/ws envelope send) or an
in-memory/Postgres testhub.

## Phase 1: Setup

- [x] T001 [P] SQL migrations for `boxes`, `pins`, `pins_history` in
      `csi-spl-api/src/go/spool-hub-api/internal/store/`
- [x] T002 [P] Env `$SPOOL_BOX_ID` required when `$SPOOL_HUB_URL` set
      (`internal/config`)

## Phase 2: US1 pins

- [x] T003 [US1] `POST /v1/pins` `{box_id, pubkey}` signed with tenant root key
- [x] T004 [US1] Same box_id same key → 200; same box_id different key → 409
- [x] T005 [US1] `GET /v1/pins` list box pubkeys; CLI `spool-pin` publishes when root key provided
- [x] T006 [P] [US1] tests: two box_ids, collision, idempotent

## Phase 3: US2 sync

- [x] T007 [US2] sidecar `GET /v1/pins` writes `$SPOOL_ROOT/pins/box-<box_id>.pub`
- [x] T008 [US2] conflict local≠hub → 78, no clobber
- [x] T009 [P] [US2] recv on box B verifies after sync; 78 without pin

## Phase 4: US3 flush

- [x] T010 [US3] implement `003/contracts/flush.md` in `internal/hubclient` (OQ-15: box-side, not `internal/flush`)
- [x] T011 [US3] hub-down same-box still recvs; flush idempotent on `msg_id`
- [x] T012 [US3] hub 400 stops retry with 78

## Phase 5: US4 revoke

- [x] T013 [US4] `DELETE /v1/pins/{box_id}` signed with tenant root key
- [x] T014 [US4] history row; subsequent verify fails; `--force` new key

## Phase 6: Polish

- [x] T015 Hygiene: no private key in pin JSON; no per-kind routes

<!-- version: 0.2.1 · updated: 2026-09-18 · last-edit: 2026-09-18T18:10:01Z -->
