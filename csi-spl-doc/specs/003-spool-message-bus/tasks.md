# Tasks: Spool message bus (hub)

**Feature**: `specs/003-spool-message-bus` · **Spec**: `./spec.md` · **Plan**: `./plan.md`

**Gate**: spec `002-box-agent-messaging` CLI + `v:1` schema exist (002 US1). Do not implement hub handlers against a forked JSON. Every Open Question is resolved (`spec.md` → **Resolved decisions**); no task is blocked on an OQ any more.

**Status (2026-09-18)**: M1 hub implemented on trunk — docs fold `7d13be5`, `5386fc8`; DDL + migrator + wire/store/blob `81121a0`; hub + hubclient + CLI `7905e35`; Postgres gate + binary e2e `7cd0164`. Gate: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (runs the Postgres/e2e part when a Postgres is available). Open: T022 against real GCS, T028, T023 (infra lane).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [x] T001 Add `internal/hub` (server), `internal/store` (tenant-native, memory driver for unit tests + Postgres), `internal/blob` (local dir for tests + GCS), `internal/wire` (frames + envelope, shared by both sides) and the box-side `internal/hubclient`. `internal/{msg,sign,files,spool}` behaviour unchanged.
- [x] T001a Schema DDL in `csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_<name>.sql` (plain, ordered, forward-only) materialising `data-model.md`; `csi-spl-rdb/README.md`.
- [x] T001b `spool migrate --db <dsn> --sql-dir <dir>`: reads the `.sql` files at runtime, applies them in filename order, one transaction each, tracked in `spool_schema_migrations` (filename + sha256; a changed applied file is a hard error); a re-run is a no-op. The infra lane's `do_setup_app_inf` invokes it.
- [x] T002 [P] Golden vectors for the envelope and hello signing payloads (`internal/wire` tests).

## Phase 2: Foundational

- [x] T003 Envelope canonicalise + sign + verify around the unchanged inner `v:1`, reusing 002 `internal/msg` canonical JSON and `internal/sign`: `sig` over `jq -cS '{from_box,to_box,msg}'` with `to_box` present (OQ-03a); golden vector test.
- [x] T004 [P] Fail-fast config: listen address, `$SPOOL_HUB_URL`, `$SPOOL_BOX_ID`, product domain, store DSN, bucket, queue TTL (7 d), queue cap (1,000), retention (7 d `alerts` / 30 d other), `hub.allow_text_only_when_file_missing` (default false), pin refresh interval, `$SPOOL_MIRROR_LOCAL`. No hostname literals (`internal/config`, pas-psf pattern). Env names published to the infra lane for cnf.
- [x] T005 [P] Server harness in `internal/hub` + `spool serve`: `net/http` (the approved WS library, `coder/websocket`, is `net/http`-native, so Fiber is not used), recover/request-ID/access-log middleware, `/healthz`, `/version`, `runUntilShutdown` graceful drain that also closes WS sockets (`1001`).
- [x] T006 [P] Tenant resolution from the request Host; unknown tenant → `404 unknown_tenant`; test two tenants on one process. Coordinate with 006 T002 (same behaviour, one implementation).

## Phase 3: User Story 1 — Cross-box send/recv over WS (P1) 🎯 MVP

- [x] T007 [US1] CLI/MCP hub mode (OQ-01, additive): `spool-send` gains `--to-box` / `to_box` and returns `delivery` ∈ `local|sent|queued|pending`. Local mode (`$SPOOL_HUB_URL` unset) is byte-for-byte the 002 path.
- [x] T008 [US1] WS hello **challenge-response** (OQ-03b): hub sends `challenge{nonce}` on connect; box signs `{box_id,nonce,ts}`; verify against the `(tenant, box_id)` pin, `ts` ±300 s, nonce single-use per socket; refuse → close `4401`, nothing stored; hello timeout `4408`; `role=box` last hello wins (`4409 superseded`), `role=cli` never evicts.
- [x] T009 [US1] Roster: `role=box` hello carries the `$SPOOL_ROOT/*/` dir scan; `roster` frame replaces it; duplicate id on one box → `roster_duplicate` 409; persisted; tenant roster pushed to every box session and cached by the box in `$SPOOL_ROOT/.hub/roster.json`.
- [x] T010 [US1] Send frame: `from_box` == hello box, verify `sig`, require the sender-resolved `to_box` (`ambiguous_to_box` 409 / `missing_to_box` 400; the hub fills nothing), `to_box` pinned, file refs held (OQ-11 flag), idempotent insert on `(tenant_id, msg_id)` (`conflict_msg` 409), push to a live session → `delivery=sent`.
- [x] T011 [US1] Box-side recv: `recv` frame → re-verify against the locally synced pin → write the inner `v:1` to `$SPOOL_ROOT/<to>/inbox/`; missing pin / bad sig → refuse `78`, write nothing.
- [x] T012 [US1] Two-box test against an in-process hub: GRK-03@box-a → CLE-07@box-b → `result` back; unpinned box; nonce replay; tampered envelope; ambiguous `to`; missing-pin frame → 78.

## Phase 4: User Story 2 — Files to object store (P1)

- [x] T013 [US2] `POST /v1/files` with the **WS-issued upload token** (OQ-10: TTL ~5 min, bound to `box_id` + tenant; `token` frame refreshes it) stores `t/<tenant>/files/<sha256>` in `internal/blob` (local dir in tests). No token → 401.
- [x] T014 [US2] `GET /v1/files/{file_id}`: tenant-scoped capability, streams bytes; never logs a URL; cross-tenant → 404.
- [x] T015 [US2] CLI: `--file-id` / `--put-file` blobs referenced by a hub send are uploaded before the envelope; the receiving box fetches missing blobs by `file_id` into `$SPOOL_ROOT/files/` and re-hashes (so the unchanged `spool-get-file` works).
- [x] T016 [US2] Round-trip test: put on box-a → send with `file_ids` → get on box-b; no bytes in any frame; `missing_file` 400 by default.

## Phase 5: User Story 3 — Offline receiver, hub-down sender (P1)

- [x] T017 [US3] Hub queue: no live session for `to_box` → `deliveries` row, 7-day TTL, cap 1,000 per box, `delivery=queued`; drain on next `role=box` hello; expire after TTL. The hub's part ends at frame delivery: no ack frame, no `acks` table (OQ-08).
- [x] T018 [US3] Dual-write per `contracts/flush.md`: same-box → local only (`delivery=local`) unless `$SPOOL_MIRROR_LOCAL`; illegal value fails fast. *(The mirror-on path is implemented but has no dedicated test yet.)*
- [x] T019 [US3] Box-side flush in `internal/hubclient` (OQ-15; 004 T010 aligns here): pending envelopes in `$SPOOL_ROOT/.hub/pending/`, idempotent by `msg_id`, no re-sign, `ts` unchanged, 400/verify → `.hub/rejected/` + `78`, network/5xx → keep + backoff. Hub unreachable at send → `delivery=pending`, exit 0 (OQ-09).
- [x] T019a [US3] Reconnect contract (OQ-05): `spool hub-run` daemon reconnects on close/read error with exponential backoff 1 s → cap 30 s + jitter, re-hellos, re-announces, re-syncs pins, flushes; stops on `4409 superseded`. `spool hub-sync` = one-shot session.
- [x] T020 [US3] Tests: box-b offline → `queued` → reconnect → recv; hub stopped → same-box works, cross-box `pending` → hub up → flush delivers; TTL expiry; `delivery` state transitions.

## Phase 6: Production storage (P1, M1)

- [x] T021 Postgres implementation of `internal/store`, queries matching `csi-spl-rdb/src/sql/postgres/spool-hub/`; the store contract suite runs against memory and a temp Postgres (`SPOOL_TEST_PG_DSN`).
- [x] T021a Retention sweep: queued TTL + per-box cap → `expired`; messages purged per tier (`alerts` 7 d, others 30 d).
- [ ] T022 [P] GCS implementation of `internal/blob`, one bucket, tenant prefix; the bucket name comes from cnf. *(Code in `internal/blob` (`GCS`, honours `STORAGE_EMULATOR_HOST`); not yet exercised against GCS or fake-gcs — the tests use the `Dir` driver.)*
- [ ] T023 [P] **Infra lane** (not this lane): `csi-spl-iac` Cloud Run with **`max-instances=1`** and min instances 1 (both cnf), Cloud SQL, GCS; tpl-gen + `terraform validate/plan` only, no apply without the owner's go.

## Phase 7: User Story 4 — Live tail (P2)

- [x] T024 [US4] Tail over the existing WS (OQ-04): `tail{task_id,follow}` → `tail_msg`… `tail_end`, then live `tail_msg` for new sends with `follow`. Tenant-scoped. No NATS, no SSE, no notify subjects in M1 (OQ-12).
- [x] T025 [US4] Test: a stored thread tails in order; a follower sees a new send; no bytes or tokens in payloads, no cross-tenant delivery.

## Phase 8: User Story 5 — Door (P3)

- [x] T026 [US5] Test that the hub runs with no GCP credentials on boxes and that every unauthenticated path (hello, envelope, file PUT) is refused.
- ~~T027~~ Private-deploy IAM front: **dropped from M1** (OQ-06). `boxes.iam_principal` stays reserved.

## Phase 9: User Story 6 — Adapter is another repo (P3)

- [ ] T028 [US6] State in `doc/md/SPEC-spool-box-api.md` that ysg-box MUST only shell these verbs; no code in ysg-box from this repo.

## Phase 10: Polish

- [x] T029 Hygiene grep: no per-kind routes/frames, no private keys, tokens or signed URLs in logs, no baked hosts or tenant ids.
- [x] T030 `go test ./...` and `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green; box-API contract diff clean (`internal/{msg,sign,files,spool}` behaviour, CLI verbs, MCP tool names) except the additive `to_box` / `delivery` of OQ-01.

**Dropped** (OQ-02): every REST message-dialect task (`POST/GET /v1/messages`, `POST /v1/recv`). None remains in 003.

## Traceability

| Requirement | Tasks |
|---|---|
| FR-001 endpoints | T005, T008–T010, T013, T014 |
| FR-002 CLI/MCP only door | T007, T015, T028 |
| FR-003 hello nonce verify, last hello wins | T008, T012 |
| FR-004 envelope verify, `from_box` binding | T003, T010, T012 |
| FR-005 sender-resolved `to_box` | T009, T010, T012 |
| FR-006 `sent` / `queued` | T010, T017, T020 |
| FR-007 files, upload token | T013–T016, T022 |
| FR-008 hub-down flush, `pending` | T019, T020 |
| FR-009 same-box local, mirror flag | T018, T020 |
| FR-010 idempotent ingest | T010, T019, T021 |
| FR-011 notify hygiene | T024, T025 |
| FR-012 stateless | T005, T021, T022, T029 |
| FR-013 no per-kind | T029 |
| FR-014 no private keys | T003, T029 |
| FR-015 tenant everywhere | T006, T021, T022 |
| FR-016 no IAM in M1 | T026 |
| FR-017 max-instances=1, reconnect | T019a, T023 |
| NFR-001 region / cnf | T004, T023 |
| NFR-002 error mapping | T012, T020 |
| NFR-003 no schema fork | T003, T030 |
| NFR-004 no Kafka / no NATS in M1 | T024 |
| NFR-005 pas-psf harness | T004, T005 |
| NFR-006 limits | T013, T016, T021a |

| Contract endpoint (`contracts/http-v1.md`) | FR |
|---|---|
| WS `/v1/ws` | FR-001, FR-003–FR-006 |
| `POST /v1/files` | FR-001, FR-007 |
| `GET /v1/files/{file_id}` | FR-001, FR-007 |
| `GET/POST/DELETE /v1/pins` | owned by 004 / 006 (hosted by FR-001) |
| `GET /healthz`, `GET /version` | FR-001 |

## Dependencies

002 US1 → T003+. T001a → T001b → T021. Pins (hosted here, owned by 004) → T008. T003 → T010, T011, T019. US1 (T007–T012) gates US2, US3. T021/T022 can start once T010/T013 interfaces exist. T023 belongs to the infra lane. US6 is documentation only here.

## Cross-spec duplicates to settle (not fixed here; the owners are 004 / 006)

- 003 T006 ≈ 006 T002 (tenant from Host).
- 003 T019 ≈ 004 T010 (flush): **decided** (OQ-15) — box-side `internal/hubclient`; 004 T010 should point here.
- 006 T008–T010 still build `POST /v1/messages` / `POST /v1/recv`: **must become WebSocket** (OQ-02). A note is left in 006 `tasks.md`.
- 004 T003 pins `{id, pubkey}` per **agent** with an IAM door map, while trust-modes pins **boxes** with the tenant root.

## Implementation strategy

MVP of 003 = Milestone 1 = US1 + US2 + US3 + the stored/follow tail of US4, on an in-process hub with the memory store in unit tests, then Postgres + GCS (Phase 6). IAM is out of M1.

<!-- version: 0.3.1 · updated: 2026-09-18 · last-edit: 2026-09-18T16:40:00Z -->
