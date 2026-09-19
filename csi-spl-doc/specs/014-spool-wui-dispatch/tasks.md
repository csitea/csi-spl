# Tasks: Spool WUI dispatch (014)

**Feature**: `specs/014-spool-wui-dispatch` · **Milestone**: M3 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane are written here, not done
here (§2.4); the owner is named.

## Phase 1 — Spec (DISPATCH, CLE-3349)

- [x] T001 Implemented (`5c4cc5f`) — `spec.md` (OQ-014-1..4, the 002 trust-modes amendment), `plan.md`, `contracts/wui-dispatch.md`. Check: `git grep -c OQ-014-1 origin/master -- csi-spl-doc/specs/014-spool-wui-dispatch/spec.md` → 5.
- [x] T002 Implemented (`5c4cc5f`) — 003 `contracts/wui-live-ws.md`: replace only the "not delivered to boxes" rule with a pointer to 014. Check: `git grep -c 014-spool-wui-dispatch origin/master -- csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` → 1. Not changed (WIRE's part of that file): the §1 row still says `box-wui` is "never pinnable"; 014 §0 amends it.

## Phase 2 — Hub + box code (DISPATCH, CLE-3349)

- [x] T010 Implemented (`9f4f0b9`) — config: `SPOOL_HUB_WUI_DISPATCH`, `SPOOL_HUB_WUI_KEY`, `SPOOL_HUB_WUI_KEY_EPHEMERAL` with fail-fast (contract §1); `spool serve` decodes / generates the key and logs only the pubkey. Check: `go test -run TestLoadHubWUIDispatch ./internal/config/` → ok (default off, dispatch without key refused, ephemeral refused in prd, bad key refused and not echoed, key round-trips).
- [x] T011 Implemented (`9f4f0b9`) — `GET /v1/wui/pubkey`; `POST /v1/pins` accepts `box-wui` only for the hub key (`wui_key_mismatch`); hello as `box-wui` refused. Check: `go test -run 'TestWUIDispatchRefusals|TestWUIDispatchFlagOff' ./internal/hub/` → ok (`wui_key_mismatch`, 4401 `unauthorized` even with the hub's own key, 404 pubkey + `bad_json` pin without a key).
- [x] T012 Implemented (`9f4f0b9`; `NewEnvelopeIn` for WIRE's channel/parent tags in the follow-up commit) — dispatch: session identity, recipient resolve (to / leading mention), roster -> box, pins, admit, sign, self-verify, shared commit; `wui.go` comment no longer says "never delivered to boxes". Check: `command grep -c "never delivered to boxes" csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go` → 0.
- [x] T013 Implemented (`9f4f0b9`) — box side: `hubclient` receive refuses a `box-wui` envelope unless `kind ∈ {task, note}`. Check: `go test -run TestBoxRefusesBoxWUIResult ./internal/hub/` → ok; with the check disabled the same test FAILS (mutation run 2026-09-19, n=1).
- [x] T014 Implemented (`9f4f0b9`) — tests: positive (deliveries row verifies with `wire.Envelope.Verify` against the `box-wui` pin; live box writes the inbox) + controls (tampered envelope, wrong key, unpinned `box-wui`, no session, unknown / ambiguous agent, flag off, pin mismatch, hello refused, box-side kind refusal). Check: `go test -count=1 -run 'WUIDispatch|BoxRefusesBoxWUI' -v ./internal/hub/` → 4 PASS: `TestWUIDispatchSignedDeliveryVerifiesAgainstPin`, `TestWUIDispatchRefusals`, `TestWUIDispatchFlagOff`, `TestBoxRefusesBoxWUIResult`. With the hub's pin-equality check removed, `TestWUIDispatchRefusals` FAILS on `wui_unpinned` (mutation, n=1). `bash csi-spl-api/src/bash/tests/run-all-tests.sh` → `ALL csi-spl-api TESTS PASSED` (memory + Postgres + GCS gates) on the rebased tree before push.

## Phase 3 — Handoffs (other lanes)

- [ ] T020 Planned (HOSTING / DEPLOY, iac 029 + 030) — Secret Manager slot `csi-spl-hub-wui-key` per env + accessor for the hub runtime SA, rendered as `SPOOL_HUB_WUI_KEY` into the hub service's secret env; no version resource.
- [ ] T021 Planned (DEPLOY, cnf) — `SPOOL_HUB_WUI_DISPATCH: "true"` in dev, `"false"` in prd; dev `SPOOL_HUB_WUI_KEY_EPHEMERAL: "true"` until T020 has a version.
- [ ] T022 Planned (owner) — mint the key, add the secret versions (contract §2.1); per tenant `spool pin --box box-wui` with the root key (§2.2).
- [~] T023 Partial (HUMANS `a74640b`, 010 T011-T013) — store-backed Registrar + Membership landed: a registered human's session carries a durable `HUM-<n>`, which dispatch uses as `from` as-is (OQ-014-3 (a)). Missing: wiring on the deployed hubs (auth providers + registration day, 010 T030-T034); until then no deployed socket carries a member session, so dispatch answers `dispatch_unauthenticated` there (OQ-014-2).

<!-- version: 0.2.0 · updated: 2026-09-19 · last-edit: 2026-09-19T06:05:00Z -->
