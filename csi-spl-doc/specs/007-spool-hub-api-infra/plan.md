# Implementation Plan: spool-hub-api infra

**Feature ID**: `007-spool-hub-api-infra` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-hub-api-infra.md`

## Summary

Morph/copy infra from **csi-rel** and **pas-psf** into csi-spl. Strip shop.
Host `spool-hub-api` on Cloud Run with DNS like those apps.

## Technical Context

**References (read-only):**
`/opt/csi/csi-rel/{csi-rel-iac,csi-rel-orc,csi-rel-cnf}`
`/opt/pas/pas-psf/{pas-psf-iac,pas-psf-orc,pas-psf-cnf}`

**This repo:** `csi-spl-iac`, `csi-spl-orc`, `csi-spl-cnf`, `csi-spl-rdb`,
`csi-spl-api`.

**Language:** existing `./run` bash + terraform 1.9.x as csi-spl-iac already
uses; Go hub unchanged.

## Copy order

1. Morph docker compose + gen-docker-env into `csi-spl-orc` (US1).
2. Enable extra GCP APIs on `001`; add TF steps 003, 005, 007, 017, 028,
   029, 030, 031, 040, spool-files bucket (US2–4).
3. DNS cnf for `spool-hub.ai` (no host in Go).
4. rdb migrations: spool tables only.
5. Tests: compose up; `terraform validate`; grep rdb for store table names
   must be zero.

## Constitution

Owner go for apply. No keys in tf state. Region `europe-north1`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:00:00Z -->
