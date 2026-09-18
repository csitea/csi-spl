# Implementation Plan: Rented spool-hub

**Feature ID**: `006-spool-hub-rental` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-hub-rental.md`  
**Hosting copy**: `../007-spool-hub-api-infra/` (csi-rel + pas-psf infra/DNS).

## Summary

M1 hub = **stateless Cloud Run (HTTPS + WebSocket) + Postgres + GCS**.
`tenant_id` on every row and GCS prefix from day one (encapsulation for
future renters). Public Cloud Run does **not** require renter IAM.
Module: `csi-spl-api/src/go/spool-hub-api`. WS send/recv; REST files/pins.

## Technical Context

**Language**: Go 1.22+.

**Storage**: Postgres (or sqlite in tests) with `tenant_id` on mail tables;
GCS `t/<tenant>/files/<sha256>`.

**Wire**: `wss://…/v1/ws` send/recv; REST pins (root-signed) + files (box-key PUT).
Tenant from **Host** (`<tenant>.spool-hub.ai`; `$SPOOL_HUB_URL` in code).
Queue in **Postgres**, not RAM. One GCS bucket, prefix isolation.
Cloud Run min-instances **1** default, cnf-overridable. Local mode needs no hub.
WS last-hello-wins. Pin list: hello + periodic GET.

**Payment (M2 = public MVP, buy on the site)**: **copy csi-rel**
(`contracts/payment.md`). M1 proto: stub `do_spl_tenant_create` only.

**CLI**: `$SPOOL_HUB_URL`, `$SPOOL_TENANT_ROOT_KEY` (operator pin only).

## Constitution Check

- [ ] II — no baked hub host (T002: `$SPOOL_HUB_TENANT_HOST_PATTERN` from cnf)
- [ ] V — no payment-vendor name in source (T015)
- [ ] VII — no root private key in DB (T001/T003)
- [ ] VIII — same verbs (002/003; not this lane)

## Public deploy notes (T014)

M2 public rental: Cloud Run **allow unauthenticated** HTTPS/WSS. The product
door is the box pin and the tenant-root signature, not renter IAM (FR-006).

Unsigned requests (no WS hello, no tenant-root sig) are already 400/401/404
at the hub. The hosting shield **rate-limits** those unsigned calls so a
leaked tenant URL is not a flood. That rate-limit is infra (Cloud Armor on
031), not a credential we issue to renters.

M1 stays IAP and/or IP allowlist (`hub.cloud_run.ingress` in cnf). This note
does not change 031.

## Build order

002 US1 → testhub with one tenant → two tenants isolation → signed recv →
quota → payment webhook.

IAM-as-renter-door (003 US5) is **not** implemented for the public service.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:00:00Z -->
