# 114 Workspace document privacy and sharing: tasks

v0.2: the panel is folded ([spec.md](spec.md) section 7); the build tasks
below wait for the owner's answers to Q1-Q4 (section 8), and nothing below
T001 is built until then. They assume Q1 (a); another answer rewrites them.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial /
in progress, `[ ]` Planned).

## 1. Documentation and evidence

- [x] **T000**: `spec.md` v0.1 + the tasks skeleton + `bench/` (the model (a)
  proof, its two controls and the M1-M4 measurements).
  - Owns: `csi-spl-doc/specs/114-workspace-doc-privacy-sharing/**`.
  - Done: v0.1 run, `bench/raw-2026-10-09.txt`: 29 `PASS`, C1 and C2 caught.
- [x] **T001**: review panel on v0.1 (a-716 agy, c-714 and c-715 claude,
  m-717 mistral; grok not seated, weekly limit), folded into v0.2 by c-719.
  - Done: `BENCH_N="6 100" BENCH_REPS=5 bash bench/isolation-bench.sh` prints
    `SUMMARY pass=55 controls_caught=11 of 11` and the M1-M5 lines of
    section 3.2 (`bench/raw-2026-10-09-v02.txt`).

## 2. Build, after the owner answers

Order matters: T002a lands BEFORE the migration's first grant row can exist
in any env; the migration itself may land first (it opens nothing without a
grant).

- [ ] **T002a**: the store's own-workspace reads name the tenant explicitly
  (c-714 #3, c-715 #4). Today they scope by RLS alone, so `share_read` would
  mix shared documents into the receiver's own list and search (spec P10,
  control C10). In `csi-spl-api/src/go/spool-hub-api/internal/store/`:
  - `wsdoc_hub.go:41-45` `wsDocHeadSQL` (used by `docHeads` :47, `DocList`
    :61, `DocHeadOf` :72): add `AND d.tenant_id = $tenant`.
  - `wsdoc_hub.go:91-105` `DocSearch`: add `AND i.tenant_id = $tenant` for
    the own search; its comment at :89 ("another tenant's items never
    match") becomes true by the filter, not by RLS.
  - `DocHead` and `DocHit` gain the owning `tenant_id` (spec 4.4 label).
  - `workspace_docs_read.go:58` `DocSubtree` and :65 `DocChildren` read one
    document by id and stay unfiltered: a receiver must read a shared
    document through them, and RLS + the share policies decide.
  - Done: a store test on testkit Postgres seeds one accepted grant to the
    session's tenant and asserts `DocList` and `DocSearch` are unchanged;
    `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green.
- [ ] **T002**: data model. Migration 0159 (or the next free number) from
  `bench/share-grant.sql`; `spool-hub-roles/runtime-grants.sql` gains
  `REVOKE DELETE ON workspace_doc_share FROM :"runtime_role";` (its default
  privileges, line 34, grant DELETE on every new table). The Go test ports
  P1-P14 and C1-C11 and pins the `pg_policies` set (P12). DDL first, dev
  and prd, `PRE_PUSH_TIER=full`.
- [ ] **T003**: store and hub API: grant, accept, revoke, the "Shared with
  this workspace" and "Waiting for you to accept" lists (separate calls);
  the grant call answers one and the same error for "no such workspace" and
  "workspace refuses shares" (no id oracle, spec 4.1); a revoke pushes "doc
  gone" to the receiver's open views and bumps its doc-list change stamp
  (spec 4.3). Needs T002a live in the env first.
- [ ] **T004**: WUI: share dialog, accept, the two shared lists, the revoke
  notice "This document is no longer shared with you."
- [ ] **T005**: restoring ONE workspace (c-715 #6): a named action
  `do_spl_db_restore_tenant` (restore the dump with `do_spl_db_restore` into
  a scratch database, then an operator-scope copy of that workspace's rows,
  grants whose `to_tenant` is missing reported, not copied), or a line in
  this spec stating it out of scope.
