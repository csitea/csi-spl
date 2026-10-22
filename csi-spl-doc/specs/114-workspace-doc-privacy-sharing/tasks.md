# 114 Workspace document privacy and sharing: tasks

v0.3 (2026-10-22, SPL-2914): the owner decided Q1 = (a) (topic 555a4e29,
msg 15021657) and asked for each workspace's own private bucket
([spec.md](spec.md) section 9); its build rows are section 3. Nothing in
sections 2 and 3 is built before the owner approves v0.3; T002a-T004 also
wait for Q2-Q4.

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
- [ ] **T005**: restoring ONE workspace (c-715 #6; v0.3: row R6 below
  covers it from the workspace's own bucket): a named action
  `do_spl_db_restore_tenant` (restore the dump with `do_spl_db_restore` into
  a scratch database, then an operator-scope copy of that workspace's rows,
  grants whose `to_tenant` is missing reported, not copied), or a line in
  this spec stating it out of scope.

## 3. Per-workspace private bucket (spec section 9), after the owner approves v0.3

Rows in the [rounds rulebook](../../doc/md/rounds-rulebook.md) shape: what,
sites (file:line on origin/master f382ca9d2), red control, measure-after
target, vendor (kind table of the global agent rules: GCP reads and moving
workspace data = `secret`, so claude, never qwen or agy), batch. Files are
disjoint across rows of one batch; batch 2 starts when batch 1 is on master.
Terraform apply and any IAM change need the owner's go for that call.

| row | what | sites | red control | measure after | vendor | batch |
|---|---|---|---|---|---|---|
| R1 | read-only audit action `do_gcp_audit_wsdoc_buckets` (csi-spl-iac) + its test: every workspace has a 052 bucket; each is uniform + `enforced`, no `allUsers` / `allAuthenticatedUsers`, no non-legacy member but the hub runtime SA; no workspace `qto-assets` reference still on 050. Exit non-zero on a finding | new `csi-spl-iac/src/bash/run/gcp-audit-wsdoc-buckets.func.sh` + `src/bash/tests/gcp-audit-wsdoc-buckets.tst.sh`; pattern `gcp-audit-iam.func.sh`, `spl-db-backup.func.sh` :102-110 | fixture policy with `allUsers`, fixture bucket list missing one workspace, fixture `public_access_prevention: inherited`: each must FAIL | prd 0 findings; dev names exactly the 5 workspaces without a bucket (spec 9.1) until R2 is applied | claude | 1 |
| R2 | cnf + 052: dev's 5 missing workspaces; a `lifecycle_rule` on `backup/` with new variable `backup_retention_days` (cnf); `make do-tf-plan` dev and prd, plans attached, apply only on the owner's go | `csi-spl-cnf/csi-spl/dev.env.yaml` :163, `all.env.yaml` :236-239, `csi-spl-iac/src/terraform/052-gcs-workspace-docs/03-workspace-docs-buckets.tf` :18-45, `02-variables.tf`; rendered tfvars via `do_tpl_gen` | `git diff --exit-code` after `ENV=<env> ./run -a do_tpl_gen`; a plan that destroys or replaces any existing 052 bucket is refused (plan shows `0 to destroy`) | expected plan dev: 5 to add + 22 in-place (lifecycle), 0 to destroy; prd: 18 in-place, 0 to destroy; after apply R1 dev = 0 findings | claude | 1 |
| R3 | hub: Qto pictures of a non-`system` workspace are written to and read from its 052 bucket `qto-assets/<sha256>`; read falls back to the old 050 key until R4 has run; `system` unchanged | `csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_assets.go` :121-150 (`docAssetKeep`, :143 Put), :152-178 (`handleDocTreeAssetGet`, :163 Get); quota `internal/hub/fileusage.go` :51 | a test with the route reverted to `s.o.Blob.Put` sees the bytes in the shared store and FAILS | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green; live: a picture PUT on a dev workspace lands in its bucket (`gcloud storage ls gs://<bucket>/qto-assets/` +1), 050 +0 | claude | 1 |
| R5 | `do_spl_doctree_export_md` and `do_spl_doctree_import_md` refuse a `TENANT_ID` not in cnf `docs.repo_export_tenants` (`[system, t1]` today) | `csi-spl-orc/src/bash/run/spl-doctree-export-md.func.sh` :40-45, `spl-doctree-import-md.func.sh` :33 (`TENANT_ID`, no allow-list), `csi-spl-cnf/csi-spl/all.env.yaml` (docs block), new test `csi-spl-orc/src/bash/tests/doctree-export-tenant-allow.tst.sh` | a map row with `TENANT_ID=<off-list>` must be refused (exit non-zero, nothing written); the same with the list check removed must FAIL the test | the 3 t1 rows and 287 repo rows still export byte-stable (`QTO_CHECK=1`), any other workspace refused | mistral | 1 |
| R4 | move action `do_spl_wsdoc_assets_move` (csi-spl-orc), dry run unless `DRY_RUN=0`: for each workspace doc's `attrs.assets` sha256, copy 050 `t/<tenant>/files/<sha>` to its 052 `qto-assets/<sha>`, verify sha256 of the copy, report; never deletes from 050 | new `csi-spl-orc/src/bash/run/spl-wsdoc-assets-move.func.sh` + test; reads the refs as in spec 9.1 (`attrs ? 'assets'`) | test: a copy whose bytes differ (fixture) must be reported FAIL and not counted moved | prd: 1 of 1 moved, R1 "still on 050" = 0; dev: 0 | claude | 2 |
| R6 | daily per-workspace Qto backup `do_spl_wsdoc_backup`: each workspace's Qto docs (operator scope, one workspace per run) to its own bucket `backup/<yyyy-mm-dd>/`; restore-read check counts docs and items; wired after wf 45's dump | new `csi-spl-orc/src/bash/run/spl-wsdoc-backup.func.sh` + test; `.github/workflows/45_db-backup.yml` (one step) | test: a backup of workspace A written to B's bucket must be refused; a backup missing one doc must fail the count check | prd: 5 workspaces with docs = 5 dated prefixes, counts equal to `select count(*) ... where tenant_id = <slug>`; restore of one workspace touches only its bucket | claude | 2 |
| R7 | the catalogue test of spec 9.4.1: every workspace-doc write route (`/v1/workspace/docs/*`, doctree asset PUT) for a non-`system` tenant writes 0 bytes to a recording shared store | new `csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_private_store_test.go` | run on the tree before R3: the asset route writes to the shared store, the test FAILS | green after R3; a new route added without the resolver fails it | claude | 2 |

R5 is `simple_coding` (no credential, no workspace data: the cnf list and a
fixture map), so mistral is main and claude backup. Every other row reads GCP
or moves workspace data (`secret`), so claude main and the cnf `secret` row's
backup (claude, grok or mistral; never qwen or agy); no brief names a
credential path.
