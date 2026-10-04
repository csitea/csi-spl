# 076 the swappable cloud layer: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names its lane, the files it owns, dependencies (`Needs`), and its done check. Status vocabulary: `../README.md` §2.3. Owner decisions: `spec.md` section 1 and 7 (HUM-10 msg `ac6fbf0c`, `fe7fd2b9`); every task builds against these decisions.

Order per owner mandate:
1. Phase 1: Provider `none` (self-host on compose) — seam neutralization on top of Spec 072 Path P1.
2. Phase 2: Provider `aws` — listed one line each.

Parallelism: Tasks marked **[Parallel]** have disjoint file ownership and may execute concurrently once their prerequisites land.

---

### Phase 0: Specification
- [x] T001 **spec** (a-232): `spec.md` and this file. Done: Landed on master, approved by orchestrator, clean distribution hygiene.

---

### Phase 1: Provider `none` (Self-Host on Compose Seams)

*Prerequisite Note*: Spec 072 tasks T004 (`DEPLOY.md`), T005 (`do_lde_up`), T013 (`config.json`), T014 (`hub.Dockerfile`), T015 (`56_ghcr-images.yml`), T016 (compose image pulls), and T017 (`do_spl_self_host_up`) already deliver the self-hosted compose foundation. The tasks below build strictly the seam neutralization layer on top.

- [x] T002 **cnf cloud provider schema**: Add `env.cloud.provider: gcp|none|aws` (default: `gcp`) to `csi-spl-cnf/csi-spl/all.env.yaml`, `spl-merged-cnf.func.sh`, and validator `EnvModels/cloud.py`. Export `SPOOL_CLOUD_PROVIDER=none` in `docker-compose.yml`.
  - **Owns**: `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-cnf/csi-spl/lde.env.yaml`, `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`, `csi-spl-cnf/src/python/conf-validator/EnvModels/cloud.py`, `docker-compose.yml`.
  - **Needs**: T001.
  - **Done**: `bash csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` passes and `ENV=dev ./run -a do_tpl_gen && git diff --exit-code` exits 0.
  - **Landed** (c-205): `aa211f81`. Reader `do_spl_cloud_provider` (`SPOOL_CLOUD_PROVIDER` > merged cnf > `gcp`), tests `cloud-provider.tst.sh` and conf-validator `tests/` (unittest, `azure` rejected; in CI cnf-suite). lde stays `gcp` (it runs the GCS emulator). dev/prd tfvars byte-identical; the generated `<env>.env.json` gains `env.cloud`.

- [x] T003 **hub go cloud factory** [Parallel]: Create `internal/cloud/` package in `csi-spl-api` with `Factory`, `ComputeProvider`, `DatabaseProvider`, and `SecretsProvider` interfaces. When `SPOOL_CLOUD_PROVIDER=none` (or bucket is empty), force `blob.Dir` (`SPOOL_HUB_FILES_DIR`), eliminate `cloud.google.com/go/storage` initialization, read container revision from `SPOOL_VERSION`/hostname, and connect to plain TCP PostgreSQL DSN.
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/cloud/`, `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go`.
  - **Needs**: T002.
  - **Done**: `go test -v ./internal/cloud/...` and `go test -v ./cmd/spool/...` pass in `csi-spl-api/src/go/spool-hub-api`.
  - **Landed** (c-211): `d747e6a0`. `cloud.New` reads `SPOOL_CLOUD_PROVIDER` (unset = `gcp`; `aws` and unknown values refuse to start). gcp proved unchanged against the pre-076 functions (`cmd/spool/hub_cloud_test.go`); `none` refuses a files bucket and a Cloud SQL socket DSN. Tests: `internal/cloud` 5, `cmd/spool` 12, api suite green.

- [x] T004 **shell cloud dispatch router**: Implement `do_spl_cloud_dispatch <family> <verb> [args]` in `csi-spl-orc/lib/bash/funcs/spl-cloud-dispatch.func.sh`, routing actions dynamically to `do_<family>_<verb>_<provider>`.
  - **Owns**: `csi-spl-orc/lib/bash/funcs/spl-cloud-dispatch.func.sh`, `csi-spl-orc/src/bash/tests/cloud-dispatch.tst.sh`.
  - **Needs**: T002.
  - **Done**: `bash csi-spl-orc/src/bash/tests/cloud-dispatch.tst.sh` passes all dispatch routing and fallback assertions.
  - **Landed** (c-212): `42f8d2d6`. Contract (header of `spl-cloud-dispatch.func.sh`): adapter `do_<family>_<verb>_<provider>`, family/verb `[a-z][a-z0-9_]*`; args pass through untouched, the adapter's stdout/stderr/exit code are the router's; no adapter = stderr FATAL naming the function, return 1, never a fallback (spec 4.2); unknown provider = 1, bad call = 2. `cloud-dispatch.tst.sh`: 19 assertions, stub adapters.

- [ ] T005 **database proxy seam neutralization** [Parallel]: In `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`, update `spl_sql_proxy_start()` to inspect `do_spl_cloud_provider`: when `none`, return exit 0 immediately with `SPL_PROXY_PORT=5432` and `SPL_PROXY_DSN=$SPOOL_HUB_DB_DSN`, allowing `do_spl_db_bootstrap` and operator scripts to execute directly against local Postgres.
  - **Owns**: `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`, `csi-spl-orc/src/bash/tests/sql-proxy-none.tst.sh`.
  - **Needs**: T004.
  - **Done**: `bash csi-spl-orc/src/bash/tests/sql-proxy-none.tst.sh` passes; `SPOOL_CLOUD_PROVIDER=none spl_sql_proxy_start` starts no background proxy process.

- [ ] T006 **secrets seam neutralization** [Parallel]: Route `do_spl_secrets_check` and `do_spl_secrets_seed_all` through `do_spl_cloud_dispatch`. Under `none`, read and seed `.env` mode 600 or `/var/lib/spool/state/session.key` instead of executing `gcloud secrets` CLI commands.
  - **Owns**: `csi-spl-orc/src/bash/run/spl-secrets-check.func.sh`, `csi-spl-orc/src/bash/run/spl-secrets-seed-all.func.sh`, `csi-spl-orc/src/bash/tests/secrets-none.tst.sh`.
  - **Needs**: T004.
  - **Done**: `bash csi-spl-orc/src/bash/tests/secrets-none.tst.sh` passes; validates secret keys in `.env` without calling `gcloud`.

- [ ] T007 **docs publish seam neutralization** [Parallel]: Update `do_publish_docs` in `csi-spl-orc/src/bash/run/publish-docs.func.sh` to route through `do_spl_cloud_dispatch`. Under `none`, copy staged documentation directly into target local directory or mounted Docker volume instead of calling `gcloud storage rsync`.
  - **Owns**: `csi-spl-orc/src/bash/run/publish-docs.func.sh`, `csi-spl-orc/src/bash/tests/publish-docs-none.tst.sh`.
  - **Needs**: T004.
  - **Done**: `bash csi-spl-orc/src/bash/tests/publish-docs-none.tst.sh` passes; mirrors `.md` files to local path with zero cloud network calls.

- [ ] T008 **deploy verification and self-host orchestration dispatch**: Update `check-hub-deploy.func.sh` and `spl-self-host-up.func.sh` to route deployment status and compute orchestration via `do_spl_cloud_dispatch`. Under `none`, deploy verification validates local container readiness and HTTP `/healthz` instead of querying `gcloud run services describe`; `do_spl_self_host_up` acts as the compute deployer for `provider: none` (with cloud deploys remaining in workflows 20 and 30).
  - **Owns**: `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh`, `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh`, `csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh`.
  - **Needs**: T004.
  - **Done**: `bash csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh` passes; validates local endpoint when `SPOOL_CLOUD_PROVIDER=none` with zero `gcloud` invocations.

- [ ] T009 **standalone compose verification**: End-to-end integration test validating clean compose boot with `SPOOL_CLOUD_PROVIDER=none`, running DB migrations, seeding initial workspace, and verifying WebSocket and file upload without reaching any Google APIs.
  - **Owns**: `csi-spl-iac/src/bash/tests/cloud-provider-none-e2e.tst.sh`.
  - **Needs**: T003, T005, T006, T007, T008.
  - **Done**: `bash csi-spl-iac/src/bash/tests/cloud-provider-none-e2e.tst.sh` passes with exit 0 and zero network calls to `*.googleapis.com`.

---

### Phase 2: AWS Provider Foundation (List Only)

- [ ] T010 **aws cnf schema**: Add AWS configuration keys (`env.aws.region`, `env.aws.account_id`, `env.steps.*`) to `csi-spl-cnf`.
- [ ] T011 **aws s3 blob driver**: Implement `blob.S3` driver in `csi-spl-api` using `aws-sdk-go-v2/service/s3` satisfying `blob.Store`.
- [ ] T012 **aws secrets manager driver**: Implement AWS Secrets Manager provider in `internal/cloud/aws` for runtime secret resolution.
- [ ] T013 **aws terraform modules**: Create Terraform modules for ECS Fargate, RDS PostgreSQL 16, S3 buckets, CloudFront CDN, and Route 53.
- [ ] T014 **aws shell dispatch adapters**: Implement `do_*_aws` actions in `csi-spl-orc` (`aws ecs`, `aws s3 sync`, `aws secretsmanager`).
- [ ] T015 **aws github oidc workflows**: Create reusable GitHub Actions deploy workflows authenticating via AWS IAM OIDC roles.
- [ ] T016 **aws clean-room smoke test**: Automated smoke test deploying test stack to AWS dev sandbox and verifying end-to-end messaging.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T15:25:00Z -->
