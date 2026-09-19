# Tasks: Spool Message Schema `v:2` (020)

**Feature**: `specs/020-spool-message-v2` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). A task owned by another lane is written here and done
there; the owner is named.

## Phase 1 — Spec (MESSAGE-V2)

- [x] T001 `spec.md`, `plan.md`, `tasks.md`.
- [x] T002 `contracts/message-schema-v2.md`: `v:2` as shipped, plus the 10
  places where the `v:1` contract mis-describes the code, each with evidence.
- [x] T003 `contracts/canonical-json-v2.md` (one canonicaliser, golden
  vectors for both versions) and `contracts/migration.md` (phases, hub guard,
  box upgrade list, knobs, rollback).
- [x] T004 002 pointer: one line in `002-box-agent-messaging/contracts/message-schema.md`
  and `spec.md` SC-006 pointing here. Nothing else in 002 changes.

## Phase 2 — Readers (API, P1)

- [ ] T005 `msg`: `V1`/`V2`/`Supported`; `Validate` accepts both. FR-001.
- [ ] T006 `config`: `SPOOL_MSG_VERSION`, `SPOOL_HUB_MSG_VERSION`, fail fast. FR-002.
- [ ] T007 Writers read the knob: `spool.Compose`, `hub/wui.go`, `cicdlogs`; the legacy bridge stays `msg.V1`. FR-002, FR-005.
- [ ] T008 `wire.Frame.MsgVersions`; hubclient hello sends `[1,2]`; hub `push` guard. FR-004.
- [ ] T009 Tests (plan §2), including the guard CONTROL.
- [ ] T010 `run-all-tests.sh` green; CI `10` + `20` green.

## Phase 3 — Deploy readers (P1-deploy)

- [ ] T011 Hub dev, then prd, at a tag that contains T005–T008 (deploy lane **CLE-3355**). Check: `GET /` `commit` on both hubs.
- [ ] T012 Rebuild the box binaries in `contracts/migration.md` §4 (box owners / ORC).
- [ ] T013 WUI: `types/spool.ts` `v: 1 | 2`; local mock rows may stay `v: 1` (UI lane **CLE-55**). FR-006.

## Phase 4 — Writers (P2, owner go per step)

- [ ] T014 dev canary: cnf `env.hub.env.SPOOL_HUB_MSG_VERSION: 2` (dev), one box `SPOOL_MSG_VERSION=2`.
- [ ] T015 After 24 h clean on dev: prd hub + all boxes. SC-005.
- [ ] T016 P3: code defaults to `2` after 7 days (the queue TTL).

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T15:10:00Z -->
