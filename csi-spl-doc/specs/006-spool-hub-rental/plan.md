# Implementation Plan: Rented spool-hub

**Feature ID**: `006-spool-hub-rental` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-hub-rental.md`

## Summary

Add `tenant_id` to hub storage, tenant root pins, signed `POST /v1/recv`,
and a create-tenant action. Public Cloud Run does **not** require renter IAM.
Module remains `csi-spl-api/src/go/spool-hub-api`.

## Technical Context

**Language**: Go 1.22+.

**Storage**: Postgres (or sqlite in tests) with `tenant_id` on mail tables;
GCS `t/<tenant>/files/<sha256>`.

**New HTTP**: `POST /v1/recv`, `POST /v1/pins` (root-signed), tenant resolved
from `Host` / path (cnf).

**Payment**: stub `do_spl_tenant_create`; webhook later, provider from cnf.

**CLI**: `$SPOOL_HUB_URL`, `$SPOOL_TENANT_ROOT_KEY` (operator pin only).

## Constitution Check

- [ ] II — no baked hub host
- [ ] V — no payment-vendor name in source
- [ ] VII — no root private key in DB
- [ ] VIII — same verbs

## Build order

002 US1 → testhub with one tenant → two tenants isolation → signed recv →
quota → payment webhook.

IAM-as-renter-door (003 US5) is **not** implemented for the public service.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
