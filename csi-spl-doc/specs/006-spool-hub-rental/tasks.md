# Tasks: Rented spool-hub

**Feature**: `specs/006-spool-hub-rental` · **Spec**: `./spec.md`

Status per `../README.md` §2.3: **Implemented** (cited) · **Partial** (what is
missing) · **Planned**. Measured on trunk `bbc41e7`, 2026-09-18 (spec.md
"Verification basis"). Code/cnf/iac changes are tasks here; this spec makes none.

Gate: 002 local (frozen) + 003 hub + 004 pins. Cloud tasks gate on 007 (README §6).

## Phase 1: Tenant (M1)

- [x] T001 [FR-001] `tenants` table: id, root_pubkey, billing_status, plan_id — **Implemented** (`0001_hub_core.sql`).
- [x] T001a [FR-001a] Add `billing_status=manual` (forward-only migration) — **Implemented** (`3690211`: `0004_tenant_manual.sql`; `manual` writes like `active`, `TestManualTenantMayWrite`).
- [x] T002 [FR-002] Tenant from Host via `$SPOOL_HUB_TENANT_HOST_PATTERN`; unknown → `404 unknown_tenant` — **Implemented** (`internal/hub/server.go` `tenantOf`; 003 T006 is the same code).
- [x] T003 [FR-007] `TENANT_ID=<slug> ./run -a do_spl_tenant_create`: mint root keypair, insert row (`manual`), print URL + root private key **once** — **Implemented** (`3690211`; `tenant-create.tst.sh`; DRY_RUN=0 checked by hand on a temp Postgres, n=1).
- [x] T004 [FR-004] Isolation test: two tenants, same `box-a` + `GRK-03`, different keys; no cross-delivery — **Implemented** (`TestTwoTenantsSameAgentIDIsolated`, `3690211`).
- [x] T016 [FR-016] Refuse reserved slugs (env labels e.g. `dev`, infra hosts e.g. `www`, `api`) — **Implemented** (`msg.ValidTenantID`; the list is in code — labels, not hostnames; `3690211`).

## Phase 2: Root-signed pins (US2, M1)

- [x] T005 [FR-003] `POST /v1/pins` verifies tenant root sig — **Implemented** (`TestPinRESTRootSigned`).
- [x] T006 [FR-003] CLI `spool pin --root-key` / `$SPOOL_TENANT_ROOT_KEY` publishes in hub mode — **Implemented** (`TestPinCLIPublishesAndHygiene`; hub-e2e pins box-a/box-b).
- [x] T007 [FR-003] Pin signed by a non-root (box) key → `400 bad_sig` — **Implemented** (`TestPinRESTRootSigned`).

## Phase 3: Key-only mail (US3/US3b, M1)

The WS send/recv tasks formerly T008–T010 are **003's** (003 T008–T010); they
are not duplicated here.

- [x] T011 [FR-005] Smoke: two `$SPOOL_ROOT`s, GRK→CLE `task` and `result` back, no GCP env — **Implemented** (`hub-e2e.tst.sh` → `ALL HUB E2E CHECKS PASSED`).
- [x] T011b [FR-011] Three pinned peers A→B, B→C, C→A `task` all delivered; prefix never changes auth — **Implemented** (`TestThreePeerMeshRing`).
- [ ] T011c [FR-004] Cloud: owner-made tenant on `dev`, then `prd`; two real machines; M1 demo steps 2–4 — **Planned**; blocked on 007 README §6 steps 3–10 (dev hub exists but has no LB/DNS; prd APIs disabled).
- [x] T011d [FR-007] Dev owner tenant `t1` (the WUI's dev default) — **Implemented** 2026-09-19T10:02Z (CLE-3355):
      `ENV=dev DRY_RUN=0 TENANT_ID=t1 GCP_ACCOUNT=<project SA> ./run -a do_spl_tenant_create` from `csi-spl-orc`, run as the
      dev project key in a throwaway CLOUDSDK_CONFIG; the root private key went straight to a 0600 file owned by the box
      user, never to a log or message. Check: `curl -s https://t1.dev.spool-hub.ai/v1/view/threads` -> `{"next":null,"threads":[]}` 200
      (was `404 unknown_tenant`).

## Phase 4: Quota / unpaid (US4)

- [x] T012 [FR-008] Enforce quota → `429 quota` on send/pin/PUT — **Implemented** (`TestQuotaExceeded429`).
- [ ] T012a [FR-008] Quotas per `plan_id` (cnf plan table) instead of one deploy-wide `SPOOL_HUB_QUOTA_*` — **Planned**; gated on OQ-006-1.
- [x] T013 [FR-009] `grace`/`unpaid`: send/pin/PUT `402`; hello/recv/GET stay up — **Implemented** (`TestUnpaidSendPin402RecvInGrace`).
- [ ] T013a [FR-010] Time the grace: record grace start; after `SPOOL_HUB_BILLING_GRACE` → `unpaid`; retention job deletes data after cnf retention — **Planned**, gated on OQ-006-3 (`BillingGrace` is only validated: `config.go:124,151`).
- [x] T013b [FR-012] Operator verb `spool hub-tenant-billing --tenant <id> --event paid|unpaid|failed|refund|cancel` via `billing.Apply` (= `MapEvent` + `SetBillingStatus`) — **Implemented** (`TestApply`; binary checked on temp Postgres, n=1).

## Phase 5: Payment (US5, M2 — after the M1 demo)

- [x] T017 [FR-013] Schema `payment_checkouts` + `webhook_events_seen`; cnf `SPOOL_HUB_PAYMENT_*` names, no secret values — **Implemented** (`40371a7`).
- [ ] T018 [FR-013] Copy csi-rel `PaymentProvider` + stub, cnf-selected drivers, fail-closed boot — **Planned**.
- [ ] T019 [FR-013] Signed webhook handler; verify before any write; duplicate id → 200 no-op; `paid` → create/activate tenant — **Planned**.
- [ ] T020 [FR-013] lde fake-pay (csi-rel 077) behind `SPOOL_HUB_ENABLE_FAKE_PAY` — **Planned** (cnf flag exists, no code).
- [ ] T021 [FR-014] Thin checkout page + success page + one email: tenant URL + root private key once — **Planned**.

## Phase 6: Polish

- [x] T014 [FR-006] Public deploy notes: allow unauthenticated in M2; rate-limit unsigned at the shield — **Implemented** as doc (`plan.md` "Public deploy notes"); the infra is 007's.
- [x] T015 [FR-015] Hygiene tests: no payment-vendor name / product host in Go; no root private key in hub logs — **Implemented** (`no-baked-host.tst.sh`, `TestRootPrivateKeyNotLogged`, `3690211`).

<!-- version: 1.3.0 · updated: 2026-09-19 -->
