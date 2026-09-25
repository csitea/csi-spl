# Tasks: Spool message bus (hub)

**Feature**: `specs/003-spool-message-bus` · **Spec**: `./spec.md` · **Plan**: `./plan.md` · **Ground rules**: `../README.md`

**Gate**: spec `002-box-agent-messaging` CLI + `v:1` schema exist (002 US1). Do not implement hub handlers against a forked JSON. OQ-01..16 are resolved (`spec.md` → **Resolved decisions**); OQ-16 was resolved by the session door, so T033 is superseded.

**Status vocabulary** (`../README.md` §2.3): **Implemented** (artifact verified, citation given) · **Partial** (what is missing is named) · **Planned** (nothing built). A checkbox is ticked only for Implemented.

**Verification run (2026-09-18, n=1)**: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` on trunk `9f8f492` → `ALL csi-spl-api TESTS PASSED`, Postgres gate and GCS gate **not** skipped (docker `postgres:16-alpine`, `fake-gcs-server:1.52.2`). Test names cited below are in `csi-spl-api/src/go/spool-hub-api/internal/hub/hub_test.go`. Code shas: wire/store/blob + DDL + migrator `81121a0`; hub + hubclient + CLI `7905e35`; pin sync + flush `e2c7d8d`; pins REST `de33409`; 402/429 `343e833` (006).

**Sync 2026-09-25** (tree `bbe04d26`, n=1, memory store, no Postgres): `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -run 'TestViewAPI|TestViewDoorTokenFailsClosed|TestSessionDoor|TestHealthPaths|TestVersionBody|TestChannelMembershipRouting|TestWUIChannelPost|TestWUIPresence|TestTailStoredAndFollow|TestCrossBoxSendRecvAndResult|TestMirrorLocalSameBox|TestSearchAPI|TestFilesRoundTripAndTenantIsolation' ./internal/hub` -> ok; `go test -count=1 -run 'TestReactionOnOpeningAndReply|TestValidEmoji|TestViewTopicDescWindows|TestMixedTopicHidesTheDMHalf|TestSessionDoorMemberReadsNonMemberRefused|TestViewSessionDoorFailsClosedWithoutMembership' ./internal/hub` -> 6 PASS. The viewer routes were renamed `threads` -> `topics` in `57f8a670` (2026-09-23); citations below use the new names.

## Format: `[ID] [P?] [Story] Description — Status`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [x] T001 Add `internal/hub` (server), `internal/store` (memory + Postgres), `internal/blob` (local dir + GCS), `internal/wire` (frames + envelope, both sides) and the box-side `internal/hubclient`. `internal/{msg,sign,files,spool}` behaviour unchanged. — **Implemented** `81121a0`, `7905e35`; `ls csi-spl-api/src/go/spool-hub-api/internal` lists all five.
- [x] T001a Schema DDL in `csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_<name>.sql` (plain, ordered, forward-only) materialising `data-model.md`. — **Implemented**; `ls csi-spl-rdb/src/sql/postgres/spool-hub/*.sql | wc -l` -> 43 on `bbe04d26` (0001–0043, no `0007`, two files numbered `0021`; 3 files on 2026-09-18).
- [x] T001b `spool migrate --db <dsn> --sql-dir <dir>`: filename order, one transaction each, tracked in `spool_schema_migrations` (filename + sha256; a changed applied file is a hard error); re-run is a no-op. — **Implemented**; `hub-pg.tst.sh` → `spool migrate applies N file(s); re-run is a no-op` (N was 3 on 2026-09-18; the directory holds 43 files on `bbe04d26`). Invoked in the cloud by `do_spl_db_bootstrap` (`9f8f492`, 007 lane).
- [x] T002 [P] Golden vectors for the envelope and hello signing payloads. — **Implemented**; `internal/wire/wire_test.go`.

## Phase 2: Foundational

- [x] T003 Envelope canonicalise + sign + verify around the unchanged inner `v:1`: `sig` over `jq -cS '{from_box,to_box,msg}'` with `to_box` present (OQ-03a). — **Implemented** `81121a0`; golden vectors in `wire_test.go`.
- [x] T004 [P] Fail-fast config (listen, `$SPOOL_HUB_URL`, `$SPOOL_BOX_ID`, product domain, DSN, bucket, queue TTL/cap, retention, `SPOOL_HUB_ALLOW_TEXT_ONLY_WHEN_FILE_MISSING` default false, pin refresh, `$SPOOL_MIRROR_LOCAL`). No hostname literals. — **Implemented**; `grep -n 'AllowTextOnly' internal/config/config.go -> envDefault:"false"`.
- [x] T005 [P] Server harness + `spool serve` on `net/http` (`coder/websocket`), recover/request-ID/access-log middleware, `/healthz`, `/version`, graceful drain closing WS `1001`. — **Implemented** `7905e35`. See T032 for the Cloud Run health path.
- [x] T006 [P] Tenant from the request Host; unknown → `404 unknown_tenant`; two tenants on one process. — **Implemented**; `TestFilesRoundTripAndTenantIsolation`. Resolution semantics owned by 006. **Amended by 026**: the tenant comes from the identity — box requests name it in `X-Spool-Tenant` (`boxTenant`), browsers from the member session (`humanTenant`), both in `internal/hub/resolve.go`; a disagreeing Host → `403 tenant_mismatch`, none named → `tenant_required`.

## Phase 3: User Story 1 — Cross-box send/recv over WS (P1) 🎯 MVP

- [x] T007 [US1] CLI/MCP hub mode (OQ-01, additive): `--to-box` / `to_box`, `delivery` ∈ `local|sent|queued|pending`; local mode byte-for-byte 002. — **Implemented**; e2e + `spool-smoke.tst.sh` green.
- [x] T008 [US1] WS hello challenge-response (OQ-03b): nonce, `{box_id,nonce,ts}`, ±300 s, `4401`/`4408`, `role=box` last hello wins `4409`, `role=cli` never evicts. — **Implemented**; `TestHelloNonceAcceptAndReplayReject`, `TestLastHelloWinsOnlyForBoxRole`.
- [x] T009 [US1] Roster: announce on `role=box` hello, `roster` frame, `roster_duplicate` 409, persisted, cached in `$SPOOL_ROOT/.hub/roster.json`. — **Implemented** `7905e35`.
- [x] T010 [US1] Send frame: `from_box` binding, `sig`, sender-resolved `to_box` (`ambiguous_to_box` 409 / `missing_to_box` 400), `to_box` pinned, file refs held (OQ-11), idempotent `(tenant_id, msg_id)`, live push → `sent`. — **Implemented**; `TestCrossBoxSendRecvAndResult`, `TestTamperedAndAmbiguousAndMissingPin`.
- [x] T011 [US1] Box-side recv: re-verify against the local pin, write inner `v:1` to the inbox; missing pin / bad sig → `78`. — **Implemented**; `TestTamperedAndAmbiguousAndMissingPin`.
- [x] T012 [US1] Two-box tests (result back, unpinned, nonce replay, tampered, ambiguous, missing pin). — **Implemented**; the tests above + e2e `unpinned box refused at hello (exit 78)`, `kind=result crossed back`.

## Phase 4: User Story 2 — Files to object store (P1)

- [x] T013 [US2] `POST /v1/files` with the WS-issued upload token (OQ-10), `t/<tenant>/files/<sha256>`; no token → `401 door`. — **Implemented**; `grep -n '"door"' internal/hub/resolve.go -> 137` (the check moved out of `rest.go`, where the count is now 0).
- [x] T014 [US2] `GET /v1/files/{file_id}` tenant-scoped capability; cross-tenant 404. — **Implemented**; `TestFilesRoundTripAndTenantIsolation`.
- [x] T015 [US2] CLI uploads referenced blobs before the envelope; receiver fetches missing blobs and re-hashes. — **Implemented** `7905e35`.
- [x] T016 [US2] Round-trip test; no bytes in frames; `missing_file` 400 by default. — **Implemented**; `TestFilesRoundTripAndTenantIsolation`.

## Phase 5: User Story 3 — Offline receiver, hub-down sender (P1)

- [x] T017 [US3] Hub queue: `deliveries` row, 7 d TTL, cap 1,000, `queued`, drain on `role=box` hello, expire; no ack (OQ-08). — **Implemented**; `TestOfflineQueueAndHubDownFlush`, e2e `offline receiver: delivery=queued, drained on hello`.
- [x] T018 [US3] Dual-write per `contracts/flush.md`: same-box → `local` unless `$SPOOL_MIRROR_LOCAL`; illegal value fails fast. — **Implemented** for default + fail-fast (`internal/config` `Mirror()`, `internal/hubclient/flush.go`).
- [x] T018a [US3] Test the mirror-**on** path (`SPOOL_MIRROR_LOCAL=1`: same-box send is written locally **and** hub-sent; `delivery` reported as `local`; draining the mirrored copy does not duplicate; hub down → local + pending). — **Implemented**; `TestMirrorLocalSameBox`.
- [x] T019 [US3] Box-side flush in `internal/hubclient` (OQ-15): `.hub/pending/`, idempotent, no re-sign, `ts` unchanged, `.hub/rejected/` + `78`, backoff; hub unreachable → `pending`, exit 0. — **Implemented** `e2c7d8d`; e2e `hub down: cross-box delivery=pending (exit 0)`, `hub back: flush sent the pending envelope`.
- [x] T019a [US3] Reconnect (OQ-05): `spool hub-run` backoff 1 s → 30 s + jitter, re-hello, re-announce, re-sync pins, flush; stop on `4409`. `spool hub-sync` one-shot. — **Implemented**; e2e `hub-run reconnected and received it`.
- [x] T020 [US3] Tests: offline → queued → recv; hub stopped → same-box works, cross-box pending → flush; TTL expiry. — **Implemented**; `TestOfflineQueueAndHubDownFlush` + e2e.

## Phase 6: Production storage and cloud (P1, M1)

- [x] T021 Postgres `internal/store`; contract suite on memory and a temp Postgres (`SPOOL_TEST_PG_DSN`). — **Implemented**; `hub-pg.tst.sh` → `internal/store + internal/hub suites green against Postgres`.
- [x] T021a Retention sweep: queued TTL + cap → `expired`; messages purged per tier. — **Implemented**; `grep -n 'Store.Sweep' internal/hub/server.go -> 336` (inside `RunSweeper`, periodic in `serve`; was line 142 on 2026-09-18).
- [x] T022 [P] GCS `internal/blob`, one bucket, tenant prefix, bucket from cnf. — **Implemented**; `hub-gcs.tst.sh` → `ALL HUB GCS CHECKS PASSED`.
- [x] T023 [P] **Infra lane (007)**, cited not owned: Cloud Run `max-instances=1`, min 1 (cnf), Cloud SQL, GCS, per `../README.md` §6. — **Implemented** (measured 2026-09-23T07:49Z, n=1 each, read-only). `gcloud run services describe csi-spl-hub-dev --project=csi-spl-dev --region=europe-north1 --account=<client_email of the dev project SA key> --format=json` → image `europe-north1-docker.pkg.dev/csi-spl-dev/csi-spl-dev-hub/spool-hub:0.1.24`, Ready=True, latestReadyRevision `csi-spl-hub-dev-00038-6px`, minScale=1, maxScale=1, cloudsql `csi-spl-dev:europe-north1:csi-spl-dev-pg`, `SPOOL_HUB_FILES_BUCKET=csi-spl-dev-files`. The same command for `csi-spl-hub-prd` (`--project=csi-spl-prd`, `--account=<client_email of the prd project SA key>`) → image `europe-north1-docker.pkg.dev/csi-spl-prd/csi-spl-prd-hub/spool-hub:0.1.24`, Ready=True, latestReadyRevision `csi-spl-hub-prd-00036-8vb`, minScale=1, maxScale=1, cloudsql `csi-spl-prd:europe-north1:csi-spl-prd-pg`, `SPOOL_HUB_FILES_BUCKET=csi-spl-prd-files`. Each call ran as that env's project SA in a throwaway `CLOUDSDK_CONFIG`. This describe supersedes the 2026-09-18 reading (image `0.1.0`, prd Cloud Run disabled).

## Phase 7: User Story 4 — Live tail (P2)

- [x] T024 [US4] Tail over the existing WS (OQ-04): `tail{task_id,follow}` → `tail_msg`… `tail_end`, live with `follow`; tenant-scoped; no NATS/SSE (OQ-12). — **Implemented**; `TestTailStoredAndFollow`, e2e `hub-tail returns the 4-message thread`.
- [x] T025 [US4] Test: ordered stored thread, follower sees new send, no bytes, no cross-tenant. — **Implemented**; `TestTailStoredAndFollow`.

## Phase 8: User Story 5 — Door (P3)

- [x] T026 [US5] Hub runs with no GCP credentials on boxes; every unauthenticated path (hello, envelope, file PUT) refused. — **Implemented**; e2e runs boxes with no GCP credentials; `TestTamperedAndAmbiguousAndMissingPin`, `door` 401.
- ~~T027~~ Private-deploy IAM front: **dropped from M1** (OQ-06). `boxes.iam_principal` reserved (`0001_hub_core.sql`).

## Phase 9: User Story 6 — Adapter is another repo (P3)

- [ ] T028 [US6] State in `doc/md/SPEC-spool-box-api.md` that ysg-box MUST only shell the spool verbs; no code in ysg-box from this repo. — **Planned**; `grep -c 'MUST only shell' csi-spl-doc/doc/md/SPEC-spool-box-api.md -> 0`. (Edits a shared narrative doc: integrator's call whether this lane or the integrator lands it.)

## Phase 10: User Story 7 — Read-only viewer API for the WUI (P2, M3 dependency)

Contract `contracts/view-v1.md`. Status per task below; the token door (T033) is superseded by the session door (OQ-16 resolved).

- [x] T031 [US7] `internal/store`: read-only queries `ListThreads(tenant, before, limit, channel, agent)`, `ThreadMessages(tenant, task_id, after, limit)` (envelope bytes + delivery states), `ListChannels(tenant)`; memory + Postgres drivers; contract-suite cases proving `deliveries` is unchanged by every read (FR-019). Add DDL `0004_view_indexes.sql` only if `EXPLAIN` on Postgres shows the thread list needs an index beyond `messages_task` (e.g. `(tenant_id, received_at)`). — **Implemented** `a54abf2` as `ViewBoxes`/`ViewThreads`/`ViewThread`/`ViewChannels`; `TestViewReads` on memory + Postgres. No new DDL (index need unmeasured at human scale).
- [x] T032 [P] Health path reachable on Cloud Run (FR-023): add `GET /v1/health` (same body as `/healthz`), keep `/healthz`; ask 007 to point the LB health check at it. — **Implemented**; `TestHealthPaths`. LB wiring is 007's.
- [x] T033a [US7] Mount the spec-010 auth routes (`/api/v1/auth/*`, not tenant-scoped; `Options.Auth`, `spool serve` loads `SPOOL_HUB_AUTH_*`, no providers = off). — **Implemented**; `TestAuthMountedWithoutTenant`. (= 010 T010.)
- [x] T033b [US7] Session as the M3 view door + credentialed CORS for allow-listed origins (OQ-A1 decided: option a). — **Implemented** (`a74640b`, HUMANS CLE-3351; 010 T011–T013): `SPOOL_HUB_VIEW_DOOR=session` admits member sessions only (store-backed `Membership` + `Registrar` wired into `auth.Options` in `cmd/spool/hub.go`) and sets `Access-Control-Allow-Credentials: true` for exact allow-listed origins; `token` still admits a member session without credentials. Every refusal is `401 view_door` (`TestSessionDoorMemberReadsNonMemberRefused`, `TestViewSessionDoorFailsClosedWithoutMembership`). The access log never carries `Cookie`, `Authorization` or query strings (`TestAccessLogCarriesNoCredentials`; 010 OQ-A4). Per-env switch-on: 010 T019.
- [ ] ~~T033~~ **Superseded** (owner decision 2026-09-19, PRD-ROLLOUT CLE-3373): no view token is built. prd serves the WUI from the apex with `SPOOL_HUB_VIEW_DOOR=session` (T033b, 010 T019), so member sessions are the only door; `token` stays the fail-closed default for an env that names no door. Check: `yq -r '.env.hub.env.SPOOL_HUB_VIEW_DOOR' csi-spl-cnf/csi-spl/prd.env.yaml` → `session`. Original plan kept for the record: View-token door (FR-020, OQ-16): verify `jq -cS '{exp,scope,tenant}'` against `tenants.root_pubkey`, Host tenant match, `exp ≤ now + hub.view_token_max_ttl` (cnf, 12 h); `401 view_door`; redact `Authorization` in access logs. CLI verb `spool hub-view-token --ttl`. Golden vector in `internal/wire`. — **Superseded**: nothing built and nothing to build (unticked because the box is ticked only for Implemented).
- [x] T034 [US7] Handlers `GET /v1/view/{roster,channels,topics,topics/{task_id}}` (renamed from `threads` in `57f8a670`) per `contracts/view-v1.md` §4 (opaque cursors, `bad_cursor`, limit clamp 200, `405` on non-GET, `online` from the live socket map). — **Implemented**; `internal/hub/view.go`, `TestViewAPI`.
- [x] T035 [US7] CORS (FR-021): cnf `SPOOL_HUB_VIEW_CORS_ORIGINS` (no default, never `*`), preflight `204`, only on `/v1/view/*` + `GET /v1/files/{id}`; the cnf key is published to 007 for `csi-spl-cnf`. — **Implemented**; `TestViewAPI`, `TestLoadHubViewDoorAndOrigins`. Also `SPOOL_HUB_VIEW_DOOR` (`token` default, `off` in lde and dev only — config.go refuses it elsewhere; `yq -r '.env.hub.env.SPOOL_HUB_VIEW_DOOR' csi-spl-cnf/csi-spl/lde.env.yaml csi-spl-cnf/csi-spl/dev.env.yaml csi-spl-cnf/csi-spl/prd.env.yaml` -> `off`, `session`, `session` on 2026-09-25; dev ran `off` before the session switch).
- [x] T036 [US7] Tests: US7 acceptance 1–5; cross-tenant 404; queued message still drains after a read; no token/URL in logs; e2e step in `hub-e2e.tst.sh` reading a topic (door `off`; the minted-view-token variant is dropped with T033). — **Implemented**: acceptance 1–5, cross-tenant, drain-after-read in `TestViewAPI`; door-off e2e `3ce1ad5` (`command grep -c 'v1/view' csi-spl-api/src/bash/tests/hub-e2e.tst.sh` -> 6; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` -> ALL csi-spl-api TESTS PASSED, including `/v1/wui/ws` hello + subscribe LOBBY). The token-door e2e is dropped with T033 (superseded); the session door is covered by `TestSessionDoorMemberReadsNonMemberRefused` and `TestViewSessionDoorFailsClosedWithoutMembership` (PASS, n=1, 2026-09-25).

## Phase 10b: Owner goal — live-chat MVP, hub half (2026-09-18)

- [x] T038 Browser live WebSocket `/v1/wui/ws` per `contracts/wui-live-ws.md`: hello/welcome (lobby id + upload token), subscribe/unsubscribe, send stored through the shared `commitRow` path (messages + deliveries `sent`), live fan-out of every stored message of a subscribed task (browser, box agent, hub). — **Implemented**; `TestWUITwoSessionsLobbyLive`, `TestWUIBoxAgentToLobby`. Resend of a stored `msg_id` in a later second re-acks with the stored row's `cursor` (was 409 `conflict_msg`; gap H1, `4872fd7` + `e38468b` µs cursor). Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run TestWUIResendAcrossSecond ./internal/hub` -> ok; on Postgres via `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh`.
- [x] T039 `#general` lobby: `SPOOL_HUB_LOBBY_TASK_ID` defined once in cnf (`2016093`), stored with channel `lobby` (channels.go `storedChannel` → `store.ChannelLobby`; `#general` is the display alias), empty 200 before the first post; `box-wui` reserved (no pin, not pinnable). — **Implemented**; same tests + `TestWUIDoorAndReservedBox`.
- [x] T040 Files for browsers: CORS on POST/GET/DELETE `/v1/files`, owner-requested `DELETE /v1/files/{file_id}` (upload token; 204/404), `blob.Store.Delete` (Dir + GCS). — **Implemented**; `TestWUIFilesUploadDownloadDelete`, blob contract test.

## Phase 10c: User Story 8 — Channels, threads, DMs, presence (M3 lane WIRE, 2026-09-19)

Contract `contracts/channels-v1.md` (+ `view-v1.md` v0.5, `wui-live-ws.md` v0.3, `http-v1.md` v0.5). OQ-W1 resolved (spec.md).

- [x] T041 [US8] `internal/wire`: optional `Channel` / `ParentTaskID` on `Envelope`, signed only when present; `Frame.Channels` (hello/announce). Pre-M3 envelope golden stays byte-identical. — **Implemented** (`83ed0b1`). Check: `command grep -n "ParentTaskID\|Channel" csi-spl-api/src/go/spool-hub-api/internal/wire/*.go | wc -l` -> 17; `cd csi-spl-api/src/go/spool-hub-api && go test -run 'TestEnvelopeLegacyBytes|TestEnvelopeChannelSigned' ./internal/wire` -> ok.
- [x] T042 [US8] rdb `0008_channels_threads.sql`: seed `lobby`/`tasks`/`alerts` per tenant, migrate `channel='general'` → `lobby`, indexes for channel / parent reads. — **Implemented** (`8261caf`). Check: `ls csi-spl-rdb/src/sql/postgres/spool-hub/0008_channels_threads.sql` -> present; `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` -> `spool migrate applies 7 file(s)` + ALL HUB POSTGRES CHECKS PASSED (0007 is DISPATCH's number, not yet on trunk).
- [x] T043 [US8] `internal/store`: `Message.ParentTaskID`; channels (create / known / list with unread + members); subscriptions (replace per box, members per channel); thread queries with roots / parent / DM / peer / viewer; memory + Postgres, contract suite. — **Implemented** (`8261caf`). Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run TestStoreChannels ./internal/store` -> ok (memory; Postgres via hub-pg.tst.sh).
- [x] T044 [US8] Hub: channel + parent on box sends and browser sends (`unknown_channel`, `general` alias), `POST /v1/channels` (+ preflight), `GET /v1/view/channels` unread/members, `/topics` roots + `dm`/`peer`, `/topics/{task_id}/children` (renamed from `threads` in `57f8a670`). — **Implemented** (`2343c8e`). Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run 'TestChannelEnvelopeStored|TestChannelsCreateAndList' ./internal/hub` -> ok; `command grep -c 'HandleFunc("GET /v1/view' csi-spl-api/src/go/spool-hub-api/internal/hub/view.go` -> 5.
- [x] T045 [US8] Membership routing: subscriptions from hello/announce, one delivery per member box, `recv.agents`, drain recomputes `agents`. — **Implemented** (`2343c8e`), **superseded 2026-09-22 by the owner rule** (`64bc9fe`): every member is addressed, not only a mentioned one. Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run 'TestChannelMembershipRouting|TestHubclientChannelRecv' ./internal/hub` -> ok (control: a channel the box did not join -> DeliveryState ErrNotFound, and a DM is not channel-routed).
- [x] T045b [US8] A browser channel post reaches every agent member (owner rule 2026-09-22): signed with the hub-held `box-wui` key, `to_box` `box-wui`, one delivery per member box; the fan-out needs `agents.command` while posting stays `notes.send`. — **Implemented** (`64bc9fe`, `d55189f`). Check: `go test -run TestWUIChannelPost ./internal/hub` -> ok (control: put `|| !strings.Contains(m.Body, "@")` back into `routeChannel` and both fan-out tests fail).
- [x] T046 [US8] Presence frames on `/v1/wui/ws` (box connect/close/announce diff, human first/last socket, snapshot after welcome). — **Implemented** (`2343c8e`). Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run TestWUIPresence ./internal/hub` -> ok; `command grep -c '"presence"' csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` -> 1.
- [x] T047 [US8] Box client: `SPOOL_CHANNELS` → hello/announce `channels`; accept a channel `recv` for another `to_box` only with signed `channel` + `agents`, inbox copy per hosted agent. — **Implemented** (`a4c31ce`). Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run TestHubclientChannelRecv ./internal/hub` -> ok.

## Phase 10d: User Story 9 — Search (CLE-3409, 2026-09-19)

Contract `contracts/search-v1.md` v1.0. WUI omnibox is lane CLE-3410 (reads the contract, does not restate it).

- [x] T048 [US9] Contract `contracts/search-v1.md`: grammar, operator table, entity types, response, errors, operators endpoint. Check: `command grep -c '^| `' csi-spl-doc/specs/003-spool-message-bus/contracts/search-v1.md` -> non-zero.
- [x] T049 [US9] `internal/search`: tokenizer + parser (Gmail precedence), operator table, applicability, validation with `pos`, highlight offsets (UTF-16); table-driven tests per operator. Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run 'TestOperators|TestParseErrors|TestWarnings|TestHighlights' ./internal/search` -> ok.
- [x] T050 [US9] rdb `0020_message_search.sql`: `messages.search_tsv` generated `to_tsvector('simple', body)` + GIN index `messages_search`. Check: `ls csi-spl-rdb/src/sql/postgres/spool-hub/0020_message_search.sql` -> present; applied by `TestSearch` (postgres).
- [x] T051 [US9] `internal/store`: `SearchMessages` / `SearchThreads` / `SearchFiles` on memory + Postgres (SQL compiled from the AST, bind parameters only, RLS scope, statement budget), human display names; contract suite incl. CONTROLS (other tenant, DM privacy, SQL-shaped text). Check: `cd csi-spl-api/src/go/spool-hub-api && SPOOL_TEST_PG_DSN=… go test -run TestSearch ./internal/store` -> ok on memory + postgres (or `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh`).
- [x] T052 [US9] `internal/hub/search.go`: `GET /v1/view/search` + `/operators`, view door, rate limit, grouped sections, cursors; tests incl. CONTROLS. Check: `cd csi-spl-api/src/go/spool-hub-api && go test -run TestSearch ./internal/hub` -> ok.
- [x] T053 [US9] p95 latency with a seeded corpus: `TestSearchP95` (runs in `hub-pg.tst.sh`), recorded in `contracts/search-v1.md` §7 with n, config and date.

## Phase 10e: Reactions (FR-033, documented at sync 2026-09-25)

- [x] T055 [FR-033] Emoji reactions on opening messages and replies: `PUT` / `DELETE /v1/messages/{msg_id}/reactions` + preflight, rdb `0037_message_reactions`, `message_reaction` live frame, `reactions` on topic reads. — **Implemented** `374a36e0`. Check: `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -run 'TestReactionOnOpeningAndReply|TestValidEmoji' ./internal/hub` -> ok (n=1, 2026-09-25). Owning spec is owner question Q3 (`spec.md` → **Open owner questions (sync 2026-09-25)**).

## Phase 11: Polish

- [x] T037 [P] `/version` returns `{ version, commit, built_at }` as `contracts/http-v1.md` §1 says; today `server.go` writes only `{"version"}` (`grep -n '"version": s.o.Version' internal/hub/server.go -> 105`). Needs `-ldflags` for commit/build time in the hub image build (`do_build_push_hub_image`, 007 lane) plus the handler change here. — **Implemented**: `main.commit` / `main.builtAt` stamped by `csi-spl-api/src/bash/build.sh` (git HEAD + UTC time; `SPOOL_BUILD_COMMIT` / `SPOOL_BUILD_TIME` override), which `do_build_push_hub_image` already calls, so no orc change; `TestVersionBody`; a `build.sh` binary served `{"built_at":"2026-09-18T19:42:40Z","commit":"6a43acb8…","version":"0.1.0-dev"}` (n=1). Also `GET /` public hello (`TestRootHello`).

- [x] T029 Hygiene grep: no per-kind routes/frames, no private keys, tokens or signed URLs in logs, no baked hosts or tenant ids. — **Implemented**; `TestPinCLIPublishesAndHygiene` + the CI `distribution-hygiene` sweep.
- [ ] T054 [P] Code-comment sync, no behaviour change (003 docs sync 2026-09-25 may not edit code): `internal/hub/view.go:25` ("a view token is required (OQ-16)") and `internal/hub/view.go:97-98` ("until it is decided the token door admits nobody") say OQ-16 is open → say the session door superseded it; `internal/hub/wui.go:700` cites `wui-live-ws v0.6 §3.3`, which does not exist → cite §3.2 (the `channel` frame row). — **Planned**; `grep -n 'OQ-16' csi-spl-api/src/go/spool-hub-api/internal/hub/view.go` -> lines 25, 98; `grep -n '§3.3' csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go` -> line 700.
- [x] T030 `go test ./...` and `run-all-tests.sh` green; box-API diff clean except additive `to_box` / `delivery` (OQ-01). — **Implemented**; verification run above.

**Dropped** (OQ-02): every REST message-dialect task (`POST/GET /v1/messages`, `POST /v1/recv`). None remains in 003. The viewer API (Phase 10) is read-only and is **not** a revival of them (`contracts/view-v1.md` §0).

## Traceability

| Requirement | Tasks | Status |
|---|---|---|
| FR-001 endpoints | T005, T008–T010, T013, T014, T037 | Implemented |
| FR-002 CLI/MCP only door | T007, T015, T028 | Implemented (T028 doc Planned) |
| FR-003 hello nonce, last hello wins | T008, T012 | Implemented |
| FR-004 envelope verify, `from_box` binding | T003, T010, T012 | Implemented |
| FR-005 sender-resolved `to_box` | T009, T010, T012 | Implemented |
| FR-006 `sent` / `queued` | T010, T017, T020 | Implemented |
| FR-007 files, upload token | T013–T016, T022 | Implemented |
| FR-008 hub-down flush, `pending` | T019, T020 | Implemented |
| FR-009 same-box local, mirror flag | T018, T018a, T020 | Implemented |
| FR-010 idempotent ingest | T010, T019, T021 | Implemented |
| FR-011 notify hygiene | T024, T025 | Implemented (M1 tail) |
| FR-012 stateless | T005, T021, T022, T029 | Implemented |
| FR-013 no per-kind | T029 | Implemented |
| FR-014 no private keys | T003, T029 | Implemented |
| FR-015 tenant everywhere | T006, T021, T022 | Implemented |
| FR-016 no IAM in M1 | T026 | Implemented |
| FR-017 max-instances=1, reconnect | T019a, T023 | Implemented (dev + prd, T023 2026-09-23) |
| FR-018 viewer API | T031, T034 | Implemented |
| FR-019 reads never mutate | T031, T036 | Implemented |
| FR-020 view door | T033b (T033 superseded) | Implemented (session door; OQ-16 resolved) |
| FR-021 CORS allow-list | T035 | Implemented |
| FR-022 viewer tenant-scoped, bytes-as-stored | T031, T034, T036 | Implemented |
| FR-023 Cloud Run-safe health path | T032 | Implemented (LB wiring: 007) |
| FR-024 envelope `channel` / `parent_task_id` | T041, T043, T044 | Implemented |
| FR-025 channels: seed, alias, create, list | T042, T043, T044 | Implemented |
| FR-026 roots, children, DMs | T043, T044 | Implemented |
| FR-027 membership routing (owner rule 2026-09-22) | T045, T045b, T047 | Implemented |
| FR-028 presence | T046 | Implemented |
| FR-029–FR-032 search | T048–T053 | Implemented |
| FR-033 reactions | T055 | Implemented (owner: Q3) |
| NFR-001 region / cnf | T004, T023 | Implemented (dev + prd, T023) |
| NFR-002 error mapping | T012, T020 | Implemented |
| NFR-003 no schema fork | T003, T030 | Implemented |
| NFR-004 no Kafka / no NATS in M1 | T024 | Implemented |
| NFR-005 pas-psf harness | T004, T005 | Implemented |
| NFR-006 limits | T013, T016, T021a, T034 | Implemented |

| Contract endpoint | FR | Status |
|---|---|---|
| WS `/v1/ws` (`contracts/http-v1.md` §2) | FR-001, FR-003–FR-006 | Implemented |
| `POST /v1/files` | FR-001, FR-007 | Implemented |
| `GET /v1/files/{file_id}` | FR-001, FR-007 | Implemented |
| `GET/POST/DELETE /v1/pins` | owned by 004 / 006 (hosted by FR-001) | Implemented (`de33409`) |
| `GET /healthz`, `GET /version` | FR-001 | Implemented (see FR-023 for Cloud Run) |
| `GET /v1/health` | FR-023 | Implemented |
| `GET /v1/view/*` (`contracts/view-v1.md`) | FR-018–FR-022 | Implemented (session door) |
| `POST /v1/channels` (`contracts/channels-v1.md` §5.1) | FR-025 | Implemented |
| `PUT/DELETE /v1/messages/{msg_id}/reactions` (`contracts/http-v1.md` §1a) | FR-033 | Implemented (`374a36e0`) |
| every other browser/admin route | owners per `contracts/http-v1.md` §1 | see the owning spec |
| `GET /v1/view/topics/{task_id}/children` | FR-026 | Implemented |

## Dependencies

002 US1 → T003+. T001a → T001b → T021. Pins (004) → T008. T003 → T010, T011, T019. US1 gates US2, US3. T023 belongs to 007 in the order of `../README.md` §6. T031 → T034 → T036; T033 superseded (OQ-16 resolved); T035 needs 007 to carry the cnf key. 005 (WUI) depends on T034–T035.

## Cross-spec seams (cite, do not fix here)

- 003 T006 ≈ 006 T002 (tenant from Host): one implementation, semantics owned by 006.
- 003 T019 ≈ 004 T010 (flush): decided (OQ-15) — box-side `internal/hubclient`.
- 006 T008–T010 must be WebSocket, not `POST /v1/messages` / `POST /v1/recv` (OQ-02).
- 005 WUI client still calls `/v1/messages` and `/v1/channels` (`contracts/view-v1.md` §7): 005 rebases its read path onto `/v1/view/*`.
- 007: external gates probe `/v1/health` (T032; serverless NEGs have no LB health check — seam closed by the integrator), `SPOOL_HUB_VIEW_CORS_ORIGINS` / `SPOOL_HUB_VIEW_DOOR` env keys (T035) (`hub.view_token_max_ttl` retired with T033), prd rollout (T023, done 2026-09-23).

## Implementation strategy

M1 of 003 = US1 + US2 + US3 + the WS tail of US4 — Implemented and green on Postgres + GCS, live on dev and prd (T023, 2026-09-23). US7, US8, US9 and FR-033 are Implemented. Open 003 work: T028 (doc, Planned), T054 (code comments, Planned) and the owner questions in `spec.md`.

<!-- version: 0.8.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:26:14Z -->
