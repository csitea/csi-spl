# 076 the swappable cloud layer: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names its lane, the files it owns, dependencies (`Needs`), and its done check. Status vocabulary: `../README.md` §2.3. Owner decisions: `spec.md` section 1 and 7 (HUM-10 msg `ac6fbf0c`, `fe7fd2b9`, and `cfc67e74`); every task builds against these decisions.

Order per owner mandate:
1. Phase 1: Provider `none` (self-host on compose) — seam neutralization on top of Spec 072 Path P1, featuring an embedded S3-compatible service in Compose, Compose secrets, and generic Go S3 driver.
2. Phase 2: Provider `aws` — listed one line each.

Parallelism: Tasks marked **[Parallel]** have disjoint file ownership and may execute concurrently once their prerequisites land.

---

### Phase 0: Specification

> **Renumbered in v0.2 (owner decisions).** Three tasks were inserted (T004 S3 blob driver, T005 Compose S3, T006 migration SQL scan), so the tasks done before v0.2 moved: old T004 -> T007, old T005 -> T008, old T006 -> T009, old T007 -> T010, old T008 -> T011. The tick commits 214440558 (T006), 2711955cd (T008) and a0fbaad49 (T007) use the OLD numbers. Those five are marked done here; T003 stays open only for the new BlobStoreProvider.

- [x] T001 **spec** (a-232): `spec.md` and this file. Done: Landed on master, approved by orchestrator, clean distribution hygiene.

---

### Phase 1: Provider `none` (Self-Host on Compose Seams & S3 Foundation)

*Prerequisite Note*: Spec 072 tasks T004 (`DEPLOY.md`), T005 (`do_lde_up`), T013 (`config.json`), T014 (`hub.Dockerfile`), T015 (`56_ghcr-images.yml`), T016 (compose image pulls), and T017 (`do_spl_self_host_up`) already deliver the self-hosted compose foundation. The tasks below build strictly the seam neutralization and storage layer on top.

- [x] T002 **cnf cloud provider schema**: Add `env.cloud.provider: gcp|none|aws` (default: `gcp`) to `csi-spl-cnf/csi-spl/all.env.yaml`, `spl-merged-cnf.func.sh`, and validator `EnvModels/cloud.py`. Export `SPOOL_CLOUD_PROVIDER=none` in `docker-compose.yml`.
  - **Owns**: `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-cnf/csi-spl/lde.env.yaml`, `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`, `csi-spl-cnf/src/python/conf-validator/EnvModels/cloud.py`, `docker-compose.yml`.
  - **Needs**: T001.
  - **Done**: `bash csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` passes and `ENV=dev ./run -a do_tpl_gen && git diff --exit-code` exits 0.

- [x] T003 **hub go cloud factory** (factory + Compute/Database/Secrets providers DONE as old T003; the BlobStoreProvider added in v0.2 DONE by c-244: `none` -> `blob.S3` from the `SPOOL_S3_*` env, fail fast when it is missing; `gcp` -> GCS / dir unchanged): Create `internal/cloud/` package in `csi-spl-api` with `Factory`, `ComputeProvider`, `BlobStoreProvider`, `DatabaseProvider`, and `SecretsProvider` interfaces. When `SPOOL_CLOUD_PROVIDER=none`, wire `BlobStoreProvider` to the generic S3 driver (T004) pointing at the Compose S3 endpoint (`http://s3:9000`), read container revision from `SPOOL_VERSION`/hostname, and connect to plain TCP PostgreSQL DSN. Do not force `blob.Dir` (owner decision 1).
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/cloud/`, `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go`.
  - **Needs**: T002.
  - **Done**: `go test -v ./internal/cloud/...` and `go test -v ./cmd/spool/...` pass in `csi-spl-api/src/go/spool-hub-api`.

- [x] T004 **generic s3 blob driver in go api** [Parallel]: Implement generic `blob.S3` driver using `aws-sdk-go-v2/service/s3` satisfying `blob.Store`. Support custom endpoints and path-style addressing for Compose S3 service (`http://s3:9000`), and standard regional addressing for AWS S3. Provides unified object storage across Phase 1 and Phase 2.
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/store/s3/`, `csi-spl-api/src/go/spool-hub-api/internal/store/s3/s3_test.go`.
  - **Needs**: T003.
  - **Done**: `go test -v ./internal/store/s3/...` in `csi-spl-api/src/go/spool-hub-api` passes with mock S3 unit tests and local container integration test.

- [x] T005 **compose minimal s3 service & bucket provisioning** [Parallel]: Add minimal S3-compatible service container to `docker-compose.yml` (MinIO with `MINIO_BROWSER=off` or SeaweedFS). Update `spl-self-host-up.func.sh` to auto-provision default bucket `spool-files` via AWS CLI / S3 client before starting the hub container, and generate access keys in `.env` mode 600 as Compose secrets (`SPOOL_S3_ACCESS_KEY`, `SPOOL_S3_SECRET_KEY`).
  - **Owns**: `docker-compose.yml`, `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh`, `csi-spl-orc/src/bash/tests/self-host-s3.tst.sh`.
  - **Needs**: T002.
  - **Done**: `bash csi-spl-orc/src/bash/tests/self-host-s3.tst.sh` passes; `docker compose up -d` starts S3 container, bucket `spool-files` exists, and hub connects successfully.

- [x] T006 **migration sql portable standard compliance scan** [Parallel]: Create static analysis scan script verifying that all database migration files under `csi-spl-rdb/src/sql/postgres/spool-hub/` and `csi-spl-rdb/src/sql/postgres/spool-hub-roles/` adhere strictly to standard PostgreSQL dialect without GCP Cloud SQL-specific extensions or vendor lock-in (owner decision 5).
  - **Owns**: `csi-spl-iac/src/bash/run/check-sql-portable.func.sh`, `csi-spl-iac/src/bash/tests/check-sql-portable.tst.sh`.
  - **Needs**: T001.
  - **Done**: `bash csi-spl-iac/src/bash/tests/check-sql-portable.tst.sh` passes; scans all migration scripts and exits 0 with zero named vendor tokens.

- [x] T007 **shell cloud dispatch router**: Implement `do_spl_cloud_dispatch <family> <verb> [args]` in `csi-spl-orc/lib/bash/funcs/spl-cloud-dispatch.func.sh`, routing actions dynamically to `do_<family>_<verb>_<provider>`.
  - **Owns**: `csi-spl-orc/lib/bash/funcs/spl-cloud-dispatch.func.sh`, `csi-spl-orc/src/bash/tests/cloud-dispatch.tst.sh`.
  - **Needs**: T002.
  - **Done**: `bash csi-spl-orc/src/bash/tests/cloud-dispatch.tst.sh` passes all dispatch routing and fallback assertions.

- [x] T008 **database proxy seam neutralization** [Parallel]: In `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`, update `spl_sql_proxy_start()` to inspect `do_spl_cloud_provider`: when `none`, return exit 0 immediately with `SPL_PROXY_PORT=5432` and `SPL_PROXY_DSN=$SPOOL_HUB_DB_DSN`, allowing `do_spl_db_bootstrap` and operator scripts to execute directly against local Postgres.
  - **Owns**: `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`, `csi-spl-orc/src/bash/tests/sql-proxy-none.tst.sh`.
  - **Needs**: T007.
  - **Done**: `bash csi-spl-orc/src/bash/tests/sql-proxy-none.tst.sh` passes; `SPOOL_CLOUD_PROVIDER=none spl_sql_proxy_start` starts no background proxy process.
  - **Follow-up landed** (c-222): `cc4fc8d3`, the `db_dsn read <runtime|owner>` / `db_dsn local` seam (SM-26): `spl_via_proxy` and `do_spl_db_bootstrap` read the DSN without gcloud under `none` (runtime `$SPOOL_HUB_DB_DSN`, owner from the self-host `.env`); `db-dsn-none.tst.sh` 16 assertions, 0 gcloud calls.
  - **Follow-up closed**: under `none`, `do_spl_db_bootstrap` does not pin a GCP account and a fresh env seeds the self-host `.env` (mode 600, the T009 seam) instead of Secret Manager. `spl-consumer-lag`, `spl-db-compact`, `spl-db-message-show`, `spl-db-owner-split`, `spl-db-period-count-check`, `spl-db-rls-check`, `spl-hub-member-list` and `spl-tenant-create` reach Postgres through `spl_local_dsn`. `db-actions-none.tst.sh`: 35 assertions, 0 gcloud under none; under gcp the proxy stub is still reached. `spl-m3-e2e.func.sh` still calls gcloud (left; not a one-line change).

- [x] T009 **secrets seam neutralization** [Parallel]: Route `do_spl_secrets_check` and `do_spl_secrets_seed_all` through `do_spl_cloud_dispatch`. Under `none`, read and seed `.env` mode 600 (Compose secrets) or `/var/lib/spool/state/session.key` instead of executing `gcloud secrets` CLI commands (owner decision 2).
  - **Owns**: `csi-spl-orc/src/bash/run/spl-secrets-check.func.sh`, `csi-spl-orc/src/bash/run/spl-secrets-seed-all.func.sh`, `csi-spl-orc/src/bash/tests/secrets-none.tst.sh`.
  - **Needs**: T007.
  - **Done**: `bash csi-spl-orc/src/bash/tests/secrets-none.tst.sh` passes; validates secret keys in `.env` without calling `gcloud`.

- [x] T010 **docs publish seam neutralization** [Parallel]: Update `do_publish_docs` in `csi-spl-orc/src/bash/run/publish-docs.func.sh` to route through `do_spl_cloud_dispatch`. Under `none`, copy staged documentation directly into target local directory or mounted Docker volume instead of calling `gcloud storage rsync`.
  - **Owns**: `csi-spl-orc/src/bash/run/publish-docs.func.sh`, `csi-spl-orc/src/bash/tests/publish-docs-none.tst.sh`.
  - **Needs**: T007.
  - **Done**: `bash csi-spl-orc/src/bash/tests/publish-docs-none.tst.sh` passes; mirrors `.md` files to local path with zero cloud network calls.

- [x] T011 **deploy verification and self-host orchestration dispatch**: Update `check-hub-deploy.func.sh` and `spl-self-host-up.func.sh` to route deployment status and compute orchestration via `do_spl_cloud_dispatch`. Under `none`, deploy verification validates local container readiness and HTTP `/healthz` instead of querying `gcloud run services describe`; `do_spl_self_host_up` acts as the compute deployer for `provider: none` (with cloud deploys remaining in workflows 20 and 30).
  - **Owns**: `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh`, `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh`, `csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh`.
  - **Needs**: T007.
  - **Done**: `bash csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh` passes; validates local endpoint when `SPOOL_CLOUD_PROVIDER=none` with zero `gcloud` invocations.

- [ ] T012 **standalone compose verification**: End-to-end integration test validating clean compose boot with `SPOOL_CLOUD_PROVIDER=none`, running DB migrations, seeding initial workspace, verifying S3 bucket creation, and validating WebSocket and file upload without reaching any Google APIs.
  - **Owns**: `csi-spl-iac/src/bash/tests/cloud-provider-none-e2e.tst.sh`.
  - **Needs**: T003, T004, T005, T008, T009, T010, T011.
  - **Done**: `bash csi-spl-iac/src/bash/tests/cloud-provider-none-e2e.tst.sh` passes with exit 0 and zero network calls to `*.googleapis.com`.

---

### Phase 2: AWS Provider Foundation (List Only)

- [ ] T013 **aws cnf schema**: Add AWS configuration keys (`env.aws.region`, `env.aws.account_id`, `env.steps.*`) to `csi-spl-cnf`.
- [ ] T014 **aws secrets manager driver**: Implement AWS Secrets Manager provider in `internal/cloud/aws` for runtime secret resolution.
- [ ] T015 **aws terraform modules**: Create Terraform modules for ECS Fargate, RDS PostgreSQL 16, S3 buckets, CloudFront CDN, and Route 53.
- [ ] T016 **aws shell dispatch adapters**: Implement `do_*_aws` actions in `csi-spl-orc` (`aws ecs`, `aws s3 sync`, `aws secretsmanager`).
- [ ] T017 **aws github oidc workflows**: Create reusable GitHub Actions deploy workflows authenticating via AWS IAM OIDC roles.
- [ ] T018 **aws clean-room smoke test**: Automated smoke test deploying test stack to AWS dev sandbox and verifying end-to-end messaging.

<!-- version: 0.2.0 · updated: 2026-10-04 · last-edit: 2026-10-04T19:23:36Z -->
