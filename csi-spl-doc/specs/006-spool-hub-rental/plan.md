# Implementation Plan: Rented spool-hub

**Feature ID**: `006-spool-hub-rental` · **Status**: M1 Partial, M2 Partial · **Date**: 2026-09-18 (redo)

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-hub-rental.md`  
**Index / seams / provisioning order**: `../README.md` §4–§6  
**Hosting**: `../007-spool-hub-api-infra/`

## Summary

The hub is one stateless Cloud Run service (HTTPS + WebSocket) over Postgres +
GCS; 006 adds the **tenant** on top of 003's wire: Host → tenant, root-signed
pins, quota `429`, unpaid `402` + grace, and in M2 a copied csi-rel payment
path that creates/activates tenants. `tenant_id` is on every row and GCS
prefix `t/<tenant>/files/<sha256>` from day one (003 data model).

## Technical Context

- **Code**: `csi-spl-api/src/go/spool-hub-api` — `internal/billing` (event →
  status, write gate, quota), `internal/hub` (`tenantOf`, pin REST, gates in
  send/pin/PUT), `internal/store` (`tenants`, `SetBillingStatus`),
  `cmd/spool` (`root-keygen`, `hub-tenant`, `pin --root-key`).
- **Schema**: `csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql`
  (`tenants`), `0003_payment.sql` (checkouts, webhook dedup).
- **cnf**: `csi-spl-cnf/csi-spl/all.env.yaml` hub env — `SPOOL_HUB_TENANT_HOST_PATTERN`
  (from `env.dns.fqdn`), `SPOOL_HUB_QUOTA_*`, `SPOOL_HUB_BILLING_GRACE`,
  `SPOOL_HUB_PAYMENT_*`. Binaries bake no host and no vendor.
- **Routing**: Host only (`{tenant}.<fqdn>`); prd `*.spool-hub.ai`, dev
  `*.dev.spool-hub.ai`, lde `{tenant}.localhost`. The wildcard records, cert
  and LB are 007 step 10.
- **Tests**: `go test ./...`; `csi-spl-api/src/bash/tests/run-all-tests.sh`
  (hub-e2e on docker Postgres). Both green on `bbc41e7`.

## Constitution Check

- [x] II — no baked hub host: pattern from cnf (`server.go` rejects a pattern not starting `{tenant}.`).
- [x] V — no payment-vendor name in source: Go (`no-baked-host.tst.sh`) + WUI gates (T015).
- [x] VII — no root private key in DB: `tenants.root_pubkey` is a 32-byte CHECK; `0003` stores the public half only.
- [x] VIII — same verbs: 002/003, not this lane.

## Public deploy notes (T014)

M2 public rental: Cloud Run **allow unauthenticated** HTTPS/WSS. The product
door is the box pin and the tenant-root signature, not renter IAM (FR-005).
Unsigned requests are already 400/401/404 at the hub; the hosting shield
rate-limits them so a leaked tenant URL is not a flood. That shield is 007
infra (ingress, step 10), not a credential issued to renters. M1 stays IP
allowlist (cnf `031-gcp-hub-ingress.allowed_ip_ranges`; Cloud Run ingress
only admits the load balancer).

## Build order

1. **Now (M1, no cloud needed)**: done — T001a, T003, T004, T015, T016
   (`3690211`), T011b, T013b (v1.2.0). T013a waits on OQ-006-3.
2. **After 007 README §6 steps 3–10 on dev**: T011c on dev (owner-made tenant,
   second machine), then prd. This closes the M1 demo for 006.
3. **M2**: T012a (after OQ-006-1), T018 → T019 → T020 → T021.

`b6a2e80` (branch `GRK-3338-006-tenants-host`, never pushed) was landed as
`3690211` without its per-tenant quota columns, which nothing enforced;
per-plan quotas wait on OQ-006-1.

<!-- version: 1.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:55:00Z -->
