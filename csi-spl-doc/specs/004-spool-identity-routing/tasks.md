# Tasks: Identity, pins, and routing

**Feature**: `specs/004-spool-identity-routing` · redo 2026-09-18

Status per `../README.md` §2.3. `[x]` = **Implemented** and re-verified in the
redo (citation given); `[~]` = **Partial**; `[ ]` = **Planned**. Code paths are
relative to `csi-spl-api/src/go/spool-hub-api/`. Verification run: trunk
`bbc41e7` (code as at `9f8f492`), n=1, `go test -count=1 ./internal/...`
filtered to pin/roster/flush/id tests -> 21 PASS, 0 FAIL, in-memory store.

## Phase 1: Setup

- [x] T001 [P] Schema `tenants`, `boxes`, `pins`, `pins_history`, `roster` in
      `csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql` (not in
      `internal/store/` — SQL lives in rdb). FR-001, FR-008 —
      `TestPinSQLLivesInRDB` PASS.
- [x] T002 [P] `$SPOOL_BOX_ID` required + validated when `$SPOOL_HUB_URL` set
      (`internal/config/config.go:79`). FR-002.
- [x] T003 [P] Agent-id regex rejects `BOX-` in Go (`internal/msg/msg.go:180`).
      FR-001, FR-012 — `TestValidID` PASS.

## Phase 2: US1 pins

- [x] T004 [US1] Root-signed pin, payload `{box_id,force,pubkey,ts}`, ±300 s
      (`internal/hub/rest.go:122`, `internal/wire/wire.go:192`). FR-003 —
      `TestPinRESTRootSigned` PASS.
- [x] T005 [US1] Same key → 200; different key without force → 409
      `pin_conflict`. FR-003 — `TestTenantsAndPins` PASS.
- [x] T006 [US1] Pin list, box-authenticated by the WS-issued token
      (`rest.go:99`). FR-003.
- [x] T007 [US1] CLI `spool pin` (local + publish with root key), `spool hub-pin`,
      `spool root-keygen`, `spool hub-tenant` (`cmd/spool/main.go`, `hub.go`).
      FR-003, FR-004 — `TestPinCLIPublishesAndHygiene` PASS.

## Phase 3: US2 sync

- [x] T008 [US2] Sync pins after hello and on interval to
      `$SPOOL_ROOT/pins/box-<id>.pub` (`internal/hubclient/hubclient.go:508`,
      `flush.go:282`). FR-006 — `TestPinSyncWritesAndConflictNoClobber` PASS.
- [x] T009 [US2] Local ≠ hub → `pin_conflict`, 78, no clobber. FR-006.
- [x] T010 [US2] Receiver verifies against the local pin; 78 without. FR-005 —
      `TestRecvVerifiesAfterPinSync` PASS.

## Phase 4: US3 routing

- [x] T011 [US3] Roster scan of `$SPOOL_ROOT/*/`, announced on `role=box` hello
      and on change (`flush.go:228`). FR-009.
- [x] T012 [US3] Duplicate / invalid roster id → 409 `roster_duplicate`
      (`internal/hub/ws.go:268,478`); same id on two boxes allowed. FR-009 —
      `TestRosterIsPerBox` PASS.
- [x] T013 [US3] Sender signs `to_box`; ambiguous → 409 `ambiguous_to_box`
      (`ws.go:332`); unpinned `to_box` → `unpinned_box`. FR-007 —
      `TestTamperedAndAmbiguousAndMissingPin` PASS.

## Phase 5: US4 dual-write / flush (identity part only; flush is 003)

- [x] T014 [US4] Flush re-sends the stored signed envelope, same `msg_id`, no
      re-sign; box-side `internal/hubclient` (OQ-15). FR-005 —
      `TestHubDownSameBoxRecvAndFlushIdempotent`, `TestFlushHTTP400StopsRetryWith78` PASS.

## Phase 6: US5 revoke / force

- [x] T015 [US5] Root-signed revoke `{box_id,op:"revoke",ts}`; history row; live
      session closed `unpinned_box` (`rest.go:172-205`). FR-008 —
      `TestPinRevokeAndForce` PASS.
- [x] T016 [US5] `force` replaces the key; only the active key verifies. FR-008.

## Phase 7: Hygiene

- [x] T017 No private key in any pin body, message or log; no per-kind routes.
      FR-004 — `TestPinCLIPublishesAndHygiene` PASS.
- [x] T018 Tenant row seeded by operator for M1 (`spool hub-tenant`); tenancy
      itself is 006. FR-003.

## Phase 8: Remaining (code tasks — not done by this docs lane)

- [ ] T019 [P] Add `AND agent_id !~ '^BOX-'` to the `roster.agent_id` CHECK
      (new rdb migration, not an edit of `0001`), plus a store test. FR-012.
      Owner: rdb/api lane.
- [ ] T020 Make root-signed pin / revoke non-replayable: add a nonce (hub-issued,
      single use) or a monotonic per-box `seq` to both signed payloads; reject
      reuse. Wire change → coordinate with 003 (`http-v1.md` §4) and 006
      (root-key tooling). FR-013. Before M2.
- [ ] T021 Live proof on dev: two boxes, owner-seeded tenant, pin / 409 /
      sync / cross-box send / ambiguous `to_box` / revoke through
      `https://<tenant>.<product-domain>`. Blocked on 007 steps 3 and 10
      (`../README.md` §6). FR-014, SC-004.
- [~] T022 Pin store semantics (`internal/store/postgres.go:93-120`, and the
      memory store to match): same-key re-pin must not write
      (no `updated_at` bump, no history row); a same-key pin on a **revoked** box
      must require `force`. Tests in `internal/store` + `internal/hub`. FR-008.
      (`contracts/pin-semantics.md` §2.1.)
- [ ] T023 Harness bootstrap (allocate id, create dirs, ensure box key, start
      `spool hub-run`) lives outside this repo today; decide whether a
      `spool-harness` verb is in scope for M1 or stays the box harness's. FR-010.
      Owner question → CLE-00.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
