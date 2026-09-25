# Implementation Plan: Rented spool-hub

**Feature ID**: `006-spool-hub-rental` · **Status**: M1 Partial (second real machine missing), M2 Implemented on the card rail (per-plan quotas + timed grace Planned) · **Date**: 2026-09-18 (redo) · synced 2026-09-25 at `bbe04d26`

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-hub-rental.md`  
**Index / seams / provisioning order**: `../README.md` §4–§6  
**Hosting**: `../007-spool-hub-api-infra/`

## Summary

The hub is one stateless Cloud Run service (HTTPS + WebSocket) over Postgres +
GCS; 006 adds the **tenant** on top of 003's wire: the tenant row (resolved from
identity since 026), root-signed
pins, quota `429`, unpaid `402` + grace, and in M2 a copied csi-rel payment
path that creates/activates tenants. `tenant_id` is on every row and GCS
prefix `t/<tenant>/files/<sha256>` from day one (003 data model).

## Technical Context

- **Code**: `csi-spl-api/src/go/spool-hub-api` — `internal/billing` (event →
  status, write gate, quota), `internal/hub` (`resolve.go` tenant resolution since 026 —
  `tenantOf` was removed in `6c66ac01`; pin REST, gates in send/pin/PUT),
  `internal/payments` (checkout, claim, signed webhooks), `internal/store` (`tenants`, `SetBillingStatus`),
  `cmd/spool` (`root-keygen`, `hub-tenant`, `pin --root-key`).
- **Schema**: `csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql`
  (`tenants`), `0003_payment.sql` (checkouts, webhook dedup),
  `0004_tenant_manual.sql`, `0011_payment_hold.sql`, `0013_payment_claim_link.sql`,
  `0025_checkout_buyer_locale.sql`, `0041_tenants_display_name.sql`.
- **cnf**: `csi-spl-cnf/csi-spl/all.env.yaml` hub env — `SPOOL_HUB_TENANT_HOST_PATTERN`
  (from `env.dns.fqdn`; legacy since 026 but still required at boot,
  `internal/config/config.go:335` — spec OQ-006-5), `SPOOL_HUB_QUOTA_*`, `SPOOL_HUB_BILLING_GRACE`,
  `SPOOL_HUB_PAYMENT_*`. Binaries bake no host and no vendor.
- **Routing (026)**: one API host per env, cnf `env.dns.api_fqdn`
  (`api.spool-hub.ai`, `dev.api.spool-hub.ai`); the tenant comes from the
  session or the box's `X-Spool-Tenant` (`SPOOL_TENANT`). Per-tenant hosts
  (024) are retired: `mapped_tenants: []` in dev and prd; no wildcard and no
  load balancer (032 Cloud Run domain mappings only). lde keeps
  `{tenant}.localhost` (`csi-spl-cnf/csi-spl/lde.env.yaml:78`).
- **Tests**: `go test ./...`; `csi-spl-api/src/bash/tests/run-all-tests.sh`
  (hub-e2e on docker Postgres). Both green on `bbc41e7`; the cited unit
  tests re-run green on `bbe04d26` (2026-09-25, n=1, in-memory store).

## Constitution Check

- [x] II — no baked hub host: API host and legacy pattern from cnf (`server.go:143` rejects a pattern not starting `{tenant}.`).
- [x] V — no payment-vendor name in source: Go (`no-baked-host.tst.sh`) + WUI gates (T015).
- [x] VII — no root private key in DB: `tenants.root_pubkey` is a 32-byte CHECK; `0003` stores the public half only.
- [x] VIII — same verbs: 002/003, not this lane.

## Public deploy notes (T014)

M2 public rental: Cloud Run **allow unauthenticated** HTTPS/WSS. The product
door is the box pin and the tenant-root signature, not renter IAM (FR-005).
Unsigned requests are already 400/401/404 at the hub; the hosting shield
rate-limits them so a leaked tenant id is not a flood. **Superseded
2026-09-19** for M1 and the shield: the 031 load balancer, its Cloud Armor and
the IP allowlist were removed ("exactly csi-rel: no load balancer"); the hub is
Cloud Run `ingress: all` (`csi-spl-cnf/csi-spl/all.env.yaml:76`), reached
through 032 domain mappings, and edge limits are in-app (017 T010). Whether
FR-006 is dropped or re-targeted is spec OQ-006-4.

## Build order

1. **Now (M1, no cloud needed)**: done — T001a, T003, T004, T015, T016
   (`3690211`), T011b, T013b (v1.2.0). T013a waits on OQ-006-3.
2. **Cloud**: done on dev and prd with two box clients on one machine
   (T011c, T011d); left: the second real machine (owner step). This closes
   the M1 demo for 006.
3. **M2**: T018 → T022 done (card rail live on prd, `7f779c4d`); T012a waits
   on OQ-006-1; T021w's PayPal button waits on PayPal being switched on.

`b6a2e80` (branch `GRK-3338-006-tenants-host`, never pushed) was landed as
`3690211` without its per-tenant quota columns, which nothing enforced;
per-plan quotas wait on OQ-006-1.

<!-- version: 1.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:23:33Z -->
