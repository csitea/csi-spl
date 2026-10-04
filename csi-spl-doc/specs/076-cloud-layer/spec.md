# 076: the swappable cloud layer (factory pattern for compute, storage, database, secrets, hosting, DNS, identity)

**Feature ID**: `076-cloud-layer` · **Milestone**: M3 · **Status**: Draft
**Created**: 2026-10-04 · **Lane**: a-232 · **Topic**: `a5a141bc-e891-4f26-bcdb-d1ac5efcd89f`
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [001 relay bucket estate](../001-relay-bucket-estate/spec.md) (git-rel GCS relay estate)
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, blob storage, viewer API)
- [007 hub API infra](../007-spool-hub-api-infra/spec.md) (cloud estate, provisioning order, lde, rdb)
- [008 CI/CD logs](../008-spool-cicd-logs/spec.md) (GitHub Actions build + deploy, WIF, quality gates)
- [010 social auth](../010-spool-social-auth/spec.md) (OAuth providers, session cookies, Secret Manager slots)
- [015 native auth](../015-spool-native-auth/spec.md) (email/password authentication, SMTP relay)
- [017 security hardening](../017-spool-security-hardening/spec.md) (DB owner/runtime split, edge limits)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles, permissions, entry gates)
- [026 workspace from identity](../026-spool-tenant-from-identity/spec.md) (single API host, identity resolution)
- [044 open source](../044-spool-open-source/spec.md) (self-hosted and export rules)
- [047 deployability](../047-spool-deployability/deployability-analysis.md) (deployment evaluation and paths)
- [072 rapid deployability](../072-rapid-deployability/spec.md) (P1 compose, P2 estate, P3 boxes)
- [074 operator workspace](../074-operator-workspace/spec.md) (multi-workspace management)
- [075 docs section](../075-docs-section/spec.md) (repo and workspace markdown, docs bucket)

`<BASE_DOMAIN>`, `<fqdn>`, `<workspace_id>`, `<tenant>`, and `<human_id>` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, or API headers.

---

## 1. Why and The Owner's Ask

Today, the spool estate is engineered directly against Google Cloud Platform (GCP). The hub API runs on Google Cloud Run (`030-cloud-run-hub`), file uploads and repo docs are stored in Google Cloud Storage buckets (`050-gcs-files`, `051-gcs-docs`), relational data resides in Google Cloud SQL for PostgreSQL 16 (`040-cloud-sql-postgres`), runtime configuration secrets are stored in GCP Secret Manager, the web user interface (WUI) deploys to Firebase Hosting (`019-firebase-static-site`), domain mapping and certificates rely on Google Cloud DNS (`025-gcp-dns-zone`) and Cloud Run Domain Mappings (`032-gcp-cloud-run-domain-mapping`), and CI deployment authentication relies on GCP Workload Identity Federation (`017-github-wif-deploy`).

While this infrastructure provides a robust production environment, it binds the application tightly to a single cloud vendor. Organizations wishing to run the spool on their own infrastructure or within existing corporate cloud accounts cannot deploy to AWS or self-host on generic virtual machines without extensive code modifications and custom orchestration scripts.

The owner HUM-10 gave the authoritative mandate to create a swappable cloud layer in topic `a5a141bc-e891-4f26-bcdb-d1ac5efcd89f` and previously in topic `6410e374-4b58-45e0-8fa8-693f18ea0281`:

1. Owner HUM-10, topic `6410e374`, msg `03bc3dab`:
   > "Yes any company or organization should be able to spawn their own Google Cloud. Later on we will add support for AWS as well."

2. Owner HUM-10, topic `6410e374`, msg `fe7fd2b9` (recorded in `spec 072` §3.1):
   - **Scope:** every service: compute, blob storage, database, secrets, web hosting, DNS/TLS, CI identity.
   - **Shape:** a factory pattern for the provider interface.
   - **Order:** no-cloud self-host first (phase 1), then AWS (phase 2).
   - **Default:** GCP stays the default provider.

3. Owner HUM-10, topic `a5a141bc`, msg `ac6fbf0c` (15:12Z, 2026-10-04):
   > "go"

4. Owner HUM-10, topic `a5a141bc`, msg `cfc67e74-16d2-4488-8a8f-f0f44efc169d` (owner decisions on 5 questions):
   - **Blob storage for `none`**: "yes - for some minimalistic s3 service" (embedded S3-compatible service in compose, not host volume mounts; S3 Go driver moves to Phase 1).
   - **Secrets for `none`**: Docker Compose secrets backed by a restricted root-owned `.env` (mode 600) generated during `spool-up`.
   - **AWS Compute**: AWS ECS Fargate, matching Cloud Run's serverless container execution model.
   - **AWS WUI**: CloudFront + S3 static bucket hosting managed via Terraform.
   - **Database & Migrations**: Plain standard PostgreSQL SQL dialect without cloud-specific extensions or vendor lock-in.

### Core Principles
1. **Universal Factory Pattern**: Every cloud service is abstracted behind a clean interface. Concrete implementations (`gcp`, `none`, `aws`) are instantiated dynamically through a unified provider factory keyed by configuration (`env.cloud.provider`).
2. **Zero Vendor Leakage in Core Business Logic**: The Go hub API (`csi-spl-api`), the Nuxt WUI (`csi-spl-wui`), and core orchestration scripts must interact exclusively with abstract interfaces. No cloud-vendor SDKs, vendor-specific environment variables, or proprietary CLI tools may be referenced directly outside provider adapters.
3. **No-Cloud Self-Host First (Phase 1)**: The primary initial deliverable is a completely cloud-independent, self-hosted deployment running on Docker Compose (`provider: none`), building directly upon the foundations established in `spec 072` Path P1.
4. **AWS Secondary (Phase 2)**: Full support for Amazon Web Services (ECS, S3, RDS, Secrets Manager, CloudFront, Route 53, IAM OIDC) follows Phase 1, mapped one-to-one against the abstract interfaces.
5. **GCP Remains the Default Supported Provider**: Existing GCP deployments (`dev`, `prd`) continue operating without behavioral regression or performance degradation.
6. **No Literal Hosts or Secrets in Configuration**: Configuration remains strictly parameterized via `csi-spl-cnf`. Provider endpoints and secrets are resolved dynamically at runtime.

---

## 2. Architecture Overview & Scope Definition

The swappable cloud layer encompasses seven distinct infrastructure services governed by two complementary factory mechanisms: the **Go Provider Factory** (in-process abstraction for the hub API) and the **Shell Dispatch Abstraction** (operational and deployment abstraction for `./run` actions and CI/CD pipelines).

```
+----------------------------------------------------------------------------------------------------+
|                                    CONFIGURATION LAYER (csi-spl-cnf)                               |
|                                    env.cloud.provider: gcp | none | aws                            |
+----------------------------------------------------------------------------------------------------+
                                                  │
                 ┌────────────────────────────────┴────────────────────────────────┐
                 ▼                                                                 ▼
+-----------------------------------------------+   +-----------------------------------------------+
|             GO PROVIDER FACTORY               |   |            SHELL DISPATCH ADAPTER             |
|           (csi-spl-api / internal/cloud)      |   |            (csi-spl-orc / csi-spl-iac)        |
+-----------------------------------------------+   +-----------------------------------------------+
  │  1. Compute (Runtime Metadata, Port, Rev)         │  1. Compute (Deploy, Status, Scale)
  │  2. Blob Storage (Files, Docs, Avatars)           │  2. Blob Storage (Upload, Rsync, Lifecycle)
  │  3. Database (PostgreSQL DSN, SSL, Dial)          │  3. Database (Auth Proxy, Migrations, Backup)
  │  4. Secrets (Runtime Secret Resolution)           │  4. Secrets (Check, Seed, Access)
  │  5. Web Hosting (URL Base, Cookie Domains)        │  5. Web Hosting (Static Deploy, Edge Invalidate)
  │  6. DNS/TLS (Endpoint Routing, Cert Status)       │  6. DNS/TLS (Zone Record Provisioning, Certs)
  │  7. CI Identity (OIDC Token Provider)             │  7. CI Identity (Cloud Credential Resolution)
+-----------------------------------------------+   +-----------------------------------------------+
                 │                                                                 │
                 ▼                                                                 ▼
 ┌──────────────────────────────┬──────────────────────────────┬──────────────────────────────────┐
 │        PROVIDER: gcp         │        PROVIDER: none        │          PROVIDER: aws           │
 │       (Current Default)      │     (Phase 1: Self-Host)     │        (Phase 2: Amazon)         │
 ├──────────────────────────────┼──────────────────────────────┼──────────────────────────────────┤
 │ 1. Cloud Run                 │ 1. Docker Compose / Linux    │ 1. AWS ECS (Fargate) / App Runner│
 │ 2. Google Cloud Storage (GCS)│ 2. Local Filesystem (Dir)    │ 2. AWS Simple Storage Service(S3)│
 │ 3. Cloud SQL (Auth Proxy)    │ 3. Standalone PostgreSQL 16  │ 3. AWS RDS PostgreSQL 16 (Proxy) │
 │ 4. GCP Secret Manager        │ 4. Local .env / State Volume │ 4. AWS Secrets Manager / SSM     │
 │ 5. Firebase Hosting          │ 5. Caddy Web Server Container│ 5. AWS S3 + CloudFront CDN       │
 │ 6. Cloud DNS + Cloud Run Map │ 6. Caddy Auto-TLS / nip.io   │ 6. AWS Route 53 + ACM            │
 │ 7. Workload Identity (WIF)   │ 7. Local Daemon / Host Auth  │ 7. AWS IAM OIDC Role Assumption  │
 └──────────────────────────────┴──────────────────────────────┴──────────────────────────────────┘
```

### The Seven In-Scope Services

| # | Service Name | Abstract Responsibility | GCP Concrete (Today) | None Concrete (Phase 1) | AWS Concrete (Phase 2) |
|---|---|---|---|---|---|
| **S1** | **Compute** | Stateless HTTP/WS application execution, process concurrency, revision identifiers | Cloud Run (`030`) | Docker Compose (`hub`) | AWS ECS Fargate |
| **S2** | **Blob Storage** | Content-addressed file storage, streaming upload/read, promotion, quota computation | GCS buckets (`050`, `051`) | Local Directory (`blob.Dir`) | AWS S3 |
| **S3** | **Database** | Relational data persistence, schema migrations, DML runtime connection pooling | Cloud SQL Postgres (`040`) | Local PostgreSQL 16 | AWS RDS PostgreSQL 16 |
| **S4** | **Secrets** | Secure storage and runtime injection of database credentials, OAuth keys, tokens | GCP Secret Manager | `.env` file / state volume | AWS Secrets Manager |
| **S5** | **Web Hosting** | Static asset distribution, Single Page Application routing, API rewrites, caching | Firebase Hosting (`019`) | Caddy reverse proxy | AWS S3 + CloudFront |
| **S6** | **DNS/TLS** | Domain name resolution, apex/subdomain routing, automated TLS certificate lifecycle | Cloud DNS (`025`) + Mapping | Caddy ACME / Let's Encrypt | Route 53 + ACM |
| **S7** | **CI Identity** | Keyless continuous deployment authentication for automated pipeline workflows | GCP WIF (`017`) / SA Key | None / Local permissions | AWS IAM GitHub OIDC |

---

## 3. Today, Measured: The GCP Seam Inventory

Every seam between the repository codebase and GCP was inventoried and measured on branch `a-232-076-cloud-layer-spec` at `origin/master` (commit `bed0f03977b6`). Per CLAUDE.md, every claim carries its verifying command and exact count.

### 3.1 Seams Breakdown by Service

```bash
# Claim verification commands across the repository:
grep -rn "cloud.google.com/go/storage" csi-spl-api/           # 5 occurrences in Go API
grep -rn "OpenGCS" csi-spl-api/                               # 6 occurrences in Go API
grep -rn "K_REVISION" csi-spl-api/                            # 4 occurrences in Go API
grep -rn "K_SERVICE" csi-spl-api/src/docker/                  # 4 occurrences in Docker entrypoint
grep -rn "gcloud run" csi-spl-orc/ csi-spl-iac/ .github/      # 8 occurrences in deploy scripts
grep -rn "gcloud artifacts" csi-spl-orc/ csi-spl-iac/ .github/# 5 occurrences in image pipelines
grep -rn "gcloud compute" csi-spl-orc/ csi-spl-iac/           # 26 occurrences in satellite/infra
grep -rn "gcloud storage\|gsutil" csi-spl-orc/ csi-spl-iac/   # 61 occurrences in storage scripts
grep -rn "cloud-sql-proxy\|spl_sql_proxy" csi-spl-orc/        # 34 occurrences in database scripts
grep -rn "gcloud secrets" csi-spl-orc/ csi-spl-iac/           # 47 occurrences in secrets management
grep -rn "firebase " csi-spl-orc/ csi-spl-iac/ .github/       # 16 occurrences in WUI deployment
grep -rn "gcloud dns" csi-spl-orc/ csi-spl-iac/               # 22 occurrences in DNS actions
grep -rn "google-github-actions/auth\|GCP_WIF" .github/       # 76 occurrences in CI workflows
```

### 3.2 Complete Seams Register

| Seam ID | Service | File & Line | What It Does | Already Abstracted? | Verification Command |
|---|---|---|---|---|---|
| **SM-01** | Compute | `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:252` | Reads `K_REVISION` env var for instance revision id | **No** (direct `os.Getenv`) | `grep -n "K_REVISION" csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go` |
| **SM-02** | Compute | `csi-spl-api/src/go/spool-hub-api/internal/hub/revision.go:27` | Extracts `K_REVISION` for browser socket tracking | **No** (direct `os.Getenv`) | `grep -n "K_REVISION" csi-spl-api/src/go/spool-hub-api/internal/hub/revision.go` |
| **SM-03** | Compute | `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:255` | Binds `PORT` env var (Cloud Run convention) | **Yes** (struct tag `env:"PORT"`) | `grep -n 'env:"PORT"' csi-spl-api/src/go/spool-hub-api/internal/config/config.go` |
| **SM-04** | Compute | `csi-spl-api/src/docker/hub-entrypoint.sh:152` | Checks `${K_SERVICE:-}` to detect Cloud Run environment | **Partial** (`is_plain` shell check) | `grep -n "K_SERVICE" csi-spl-api/src/docker/hub-entrypoint.sh` |
| **SM-05** | Compute | `csi-spl-orc/src/bash/run/build-push-hub-image.func.sh:73-76` | Authenticates and pushes to GCP Artifact Registry | **No** (hardcoded `docker login` to GCP) | `grep -n "SPL_REGISTRY_HOST" csi-spl-orc/src/bash/run/build-push-hub-image.func.sh` |
| **SM-06** | Compute | `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh:40` | Checks Cloud Run service readiness via `gcloud run` | **No** (direct `gcloud run services describe`) | `grep -n "gcloud run" csi-spl-orc/src/bash/run/check-hub-deploy.func.sh` |
| **SM-07** | Compute | `.github/workflows/20_hub-build-deploy.yml:642` | Updates Cloud Run revision image via `gcloud run` | **No** (direct gcloud CLI step) | `grep -n "gcloud run services update" .github/workflows/20_hub-build-deploy.yml` |
| **SM-08** | Compute | `csi-spl-iac/src/terraform/030-cloud-run-hub/03-cloud-run.tf:1` | Provisions Cloud Run v2 service | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/030-cloud-run-hub/03-cloud-run.tf` |
| **SM-09** | Compute | `csi-spl-iac/src/terraform/028-gcp-artifact-registry/03-artifact-registry.tf:1` | Provisions GCP Artifact Registry repository | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/028-gcp-artifact-registry/03-artifact-registry.tf` |
| **SM-10** | Compute | `csi-spl-iac/src/terraform/060-gcp-vm-satellite/03-vm.tf:1` | Provisions GCE VM for agent satellite box | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/060-gcp-vm-satellite/03-vm.tf` |
| **SM-11** | Blob Storage | `csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go:53` | Defines `blob.Store` abstraction interface | **Yes** (pure Go interface) | `sed -n '53,81p' csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go` |
| **SM-12** | Blob Storage | `csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go:84` | Defines `blob.Dir` filesystem driver | **Yes** (implements `blob.Store`) | `grep -n "type Dir struct" csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go` |
| **SM-13** | Blob Storage | `csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go:248` | Implements `blob.GCS` using `cloud.google.com/go/storage` | **Yes** (implements `blob.Store`) | `grep -n "type GCS struct" csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go` |
| **SM-14** | Blob Storage | `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:270,282` | Instantiates `blob.OpenGCS` for files and docs | **Partial** (bypasses factory; checks bucket) | `grep -n "OpenGCS" csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go` |
| **SM-15** | Blob Storage | `csi-spl-orc/src/bash/run/publish-docs.func.sh:94` | Mirrors docs using `gcloud storage rsync` | **No** (direct `gcloud storage rsync`) | `grep -n "gcloud storage rsync" csi-spl-orc/src/bash/run/publish-docs.func.sh` |
| **SM-16** | Blob Storage | `csi-spl-iac/src/terraform/050-gcs-files/03-bucket.tf:1` | Provisions user file storage GCS bucket | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/050-gcs-files/03-bucket.tf` |
| **SM-17** | Blob Storage | `csi-spl-iac/src/terraform/051-gcs-docs/03-bucket.tf:1` | Provisions repository documentation GCS bucket | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/051-gcs-docs/03-bucket.tf` |
| **SM-18** | Blob Storage | `csi-spl-iac/src/terraform/020-gcp-relay-bucket/03-bucket.tf:1` | Provisions git-rel encrypted message relay bucket | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/020-gcp-relay-bucket/03-bucket.tf` |
| **SM-19** | Database | `csi-spl-api/src/go/spool-hub-api/go.mod:12` | PostgreSQL wire protocol client (`jackc/pgx/v5`) | **Yes** (cloud agnostic) | `grep -n "jackc/pgx/v5" csi-spl-api/src/go/spool-hub-api/go.mod` |
| **SM-20** | Database | `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:386` | Starts Cloud SQL Auth Proxy on free local port | **No** (couples to Cloud SQL connection) | `grep -n "spl_sql_proxy_start()" csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` |
| **SM-21** | Database | `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:453` | Wraps command execution via `spl_via_proxy` | **Partial** (abstracts proxy for scripts) | `grep -n "spl_via_proxy()" csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` |
| **SM-22** | Database | `csi-spl-orc/src/bash/run/spl-db-bootstrap.func.sh:78` | Runs migrations over Cloud SQL proxy | **No** (assumes Cloud SQL connection) | `grep -n "spl_sql_proxy_start" csi-spl-orc/src/bash/run/spl-db-bootstrap.func.sh` |
| **SM-23** | Database | `csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf:1` | Provisions Cloud SQL PostgreSQL 16 instance | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf` |
| **SM-24** | Secrets | `csi-spl-api/src/go/spool-hub-api/internal/config/config.go` | Reads secrets from process env vars via `caarlos0/env` | **Yes** (zero cloud API dependencies) | `grep -n "caarlos0/env" csi-spl-api/src/go/spool-hub-api/go.mod` |
| **SM-25** | Secrets | `csi-spl-cnf/csi-spl/all.env.yaml:416,503` | Maps env vars to Secret Manager slot IDs | **Partial** (declarative mapping schema) | `grep -n "csi-spl-hub-auth-session-key" csi-spl-cnf/csi-spl/all.env.yaml` |
| **SM-26** | Secrets | `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:354` | Reads DSN via `gcloud secrets versions access` | **No** (direct `gcloud secrets` call) | `grep -n "gcloud secrets versions access" csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` |
| **SM-27** | Secrets | `csi-spl-orc/src/bash/run/spl-secrets-check.func.sh:125` | Validates secret slots via `gcloud secrets versions list` | **No** (direct `gcloud secrets` call) | `grep -n "gcloud secrets versions list" csi-spl-orc/src/bash/run/spl-secrets-check.func.sh` |
| **SM-28** | Secrets | `csi-spl-orc/src/bash/run/spl-secrets-seed-all.func.sh:69` | Writes secrets via `gcloud secrets versions add` | **No** (direct `gcloud secrets` call) | `grep -n "gcloud secrets versions add" csi-spl-orc/src/bash/run/spl-secrets-seed-all.func.sh` |
| **SM-29** | Web Hosting | `csi-spl-wui/package.json:28` | Builds static bundle via `nuxt generate` | **Yes** (pure static bundle) | `grep -n '"generate"' csi-spl-wui/package.json` |
| **SM-30** | Web Hosting | `csi-spl-wui/src/utils/runtime-config.mjs:1` | Reads dynamic `/config.json` at boot (072 A3) | **Yes** (runtime decoupled from build) | `test -f csi-spl-wui/src/utils/runtime-config.mjs` |
| **SM-31** | Web Hosting | `.github/workflows/30_wui-build-deploy.yml:468` | Deploys WUI using `firebase-tools deploy --only hosting` | **No** (direct Firebase CLI) | `grep -n "firebase-tools" .github/workflows/30_wui-build-deploy.yml` |
| **SM-32** | Web Hosting | `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh:1` | Generates `firebase.json` with headers and rewrites | **No** (Firebase-specific schema) | `test -f csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` |
| **SM-33** | Web Hosting | `csi-spl-iac/src/terraform/019-firebase-static-site/03-firebase-site.tf:1` | Provisions Firebase Hosting site | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/019-firebase-static-site/03-firebase-site.tf` |
| **SM-34** | DNS / TLS | `csi-spl-iac/src/terraform/025-gcp-dns-zone/03-dns.tf:1` | Provisions Cloud DNS managed zone & records | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/025-gcp-dns-zone/03-dns.tf` |
| **SM-35** | DNS / TLS | `csi-spl-iac/src/terraform/032-gcp-cloud-run-domain-mapping/03-domain-mapping.tf:1` | Provisions Cloud Run custom domain mapping | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/032-gcp-cloud-run-domain-mapping/03-domain-mapping.tf` |
| **SM-36** | DNS / TLS | `csi-spl-orc/src/bash/run/wait-for-mapping-cert.func.sh:35` | Polls certificate readiness via `gcloud beta run` | **No** (direct gcloud CLI) | `grep -n "gcloud beta run domain-mappings" csi-spl-orc/src/bash/run/wait-for-mapping-cert.func.sh` |
| **SM-37** | CI Identity | `csi-spl-iac/src/terraform/017-github-wif-deploy/03-wif.tf:1` | Provisions GCP Workload Identity Federation pool/provider | **No** (GCP Terraform resource) | `test -f csi-spl-iac/src/terraform/017-github-wif-deploy/03-wif.tf` |
| **SM-38** | CI Identity | `.github/workflows/20_hub-build-deploy.yml:520` | Authenticates runner via `google-github-actions/auth@v2` | **No** (vendor-specific GitHub Action) | `grep -n "google-github-actions/auth" .github/workflows/20_hub-build-deploy.yml` |
| **SM-39** | CI Identity | `csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh:98` | Resolves active GCP SA in throwaway `CLOUDSDK_CONFIG` | **No** (tightly bound to gcloud config) | `grep -n "CLOUDSDK_CONFIG" csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh` |

---

## 4. Provider Interface & Factory Design

### 4.1 Go Core Abstractions (`csi-spl-api/src/go/spool-hub-api/internal/cloud/`)

To decouple the hub binary from vendor SDKs, `csi-spl-api` defines clean interfaces for the services consumed at runtime. The factory pattern instantiates drivers according to `env.cloud.provider` (passed via `SPOOL_CLOUD_PROVIDER` or derived from `SPOOL_HUB_ENV`).

#### 1. Compute Provider Interface
```go
package cloud

import "context"

// ComputeProvider abstracts platform runtime metadata and environment.
type ComputeProvider interface {
	// Name returns the provider identifier ("gcp", "none", "aws").
	Name() string
	// Revision returns the deployment revision identifier.
	Revision(ctx context.Context) string
	// InstanceID returns the unique identifier of the running instance.
	InstanceID(ctx context.Context) string
	// Zone returns the cloud zone or availability zone where running.
	Zone(ctx context.Context) string
}
```

*Implementations*:
- `gcp`: Inspects `K_REVISION` environment variable and GCP metadata server (`http://metadata.google.internal`).
- `none`: Reads `SPOOL_VERSION` or `GIT_COMMIT` from container environment; returns process PID / container hostname.
- `aws`: Inspects ECS Task Metadata Endpoint (`AWS_CONTAINER_METADATA_URI_V4`).

#### 2. Blob Storage Provider Interface
The existing `blob.Store` interface in `internal/blob/blob.go` is already fully abstracted and provides complete functional parity:
```go
type Store interface {
	Put(ctx context.Context, key string, data []byte) error
	PutReader(ctx context.Context, key string, r io.Reader) (int64, error)
	Promote(ctx context.Context, src, dst string) (existed bool, err error)
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	Exists(ctx context.Context, key string) (bool, error)
	Delete(ctx context.Context, key string) error
	PrefixBytes(ctx context.Context, prefix string) (int64, error)
	Uploaded(ctx context.Context, key string) (time.Time, error)
	Touch(ctx context.Context, key string) error
	List(ctx context.Context, prefix string, fn func(key string, uploaded time.Time) error) error
	Close() error
}
```

*Implementations*:
- `gcp`: `blob.GCS` driver wrapping `cloud.google.com/go/storage`.
- `none`: Generic `blob.S3` driver wrapping `github.com/aws/aws-sdk-go-v2/service/s3` pointing to embedded Compose S3 service endpoint (`http://s3:9000`), with bucket auto-created at `spool-up` (owner decision 1).
- `aws`: Generic `blob.S3` driver wrapping `github.com/aws/aws-sdk-go-v2/service/s3` pointing to regional AWS S3 bucket.

#### 3. Database Provider Interface
The database engine is PostgreSQL 16 across all environments. The abstraction handles connection URI resolution, proxy negotiation, and health validation:
```go
type DatabaseProvider interface {
	Name() string
	// DSN returns the calibrated PostgreSQL connection string.
	DSN(ctx context.Context) (string, error)
	// Ping validates connection pool reachability.
	Ping(ctx context.Context) error
}
```

*Implementations*:
- `gcp`: Resolves Cloud SQL Unix socket path (`/cloudsql/<connection-name>`) on Cloud Run, or localhost proxy DSN.
- `none`: Directly resolves standard TCP connection (`postgres://<user>:<pw>@<host>:<port>/<db>?sslmode=disable`).
- `aws`: Resolves AWS RDS PostgreSQL endpoint with TLS certificate verification (`sslmode=verify-full`).

#### 4. Secrets Provider Interface
The hub runtime consumes configuration through environment variables. The secrets provider resolves sensitive values during initialization:
```go
type SecretsProvider interface {
	Name() string
	// GetSecret retrieves raw secret payload by abstract secret ID.
	GetSecret(ctx context.Context, secretID string) ([]byte, error)
}
```

*Implementations*:
- `gcp`: Cloud Run injects secrets natively into environment variables (`secret_key_ref`); standalone calls use GCP Secret Manager API.
- `none`: Reads values from `.env` or files mounted in state volume (`/var/lib/spool/state/`).
- `aws`: Retrieves secrets from AWS Secrets Manager or ECS parameter injection.

#### 5. Web Hosting Provider Interface
Provides runtime discovery of web origin and cookie forwarding policies:
```go
type WebHostingProvider interface {
	Name() string
	// AuthCookieName returns "__session" for Firebase rewrites, "spool_session" elsewhere.
	AuthCookieName() string
	// PublicOrigin returns the apex web origin.
	PublicOrigin() string
}
```

#### 6. The Unified Cloud Factory
```go
// Factory coordinates initialization of cloud service providers.
type Factory struct {
	provider string
}

func NewFactory(provider string) (*Factory, error) {
	switch provider {
	case "gcp", "none", "aws":
		return &Factory{provider: provider}, nil
	default:
		return nil, fmt.Errorf("unknown cloud provider: %q", provider)
	}
}

func (f *Factory) Compute() ComputeProvider { ... }
func (f *Factory) OpenBlob(ctx context.Context, target string) (blob.Store, error) { ... }
func (f *Factory) Database() DatabaseProvider { ... }
func (f *Factory) Secrets() SecretsProvider { ... }
func (f *Factory) WebHosting() WebHostingProvider { ... }
```

### 4.2 Shell Orchestration & IaC Dispatch (`csi-spl-orc` / `csi-spl-iac`)

Shell actions dispatch operations dynamically based on the merged configuration value `env.cloud.provider`.

#### Dispatch Router Pattern (`do_spl_cloud_dispatch`)
All operational wrappers call a unified router in `csi-spl-orc/lib/bash/funcs/spl-cloud-dispatch.func.sh`:
```bash
do_spl_cloud_dispatch() {
  local family="$1" verb="$2"
  shift 2
  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  local target_func="do_${family}_${verb}_${provider}"
  if declare -F "$target_func" >/dev/null; then
    "$target_func" "$@"
  else
    do_log "FATAL provider '$provider' does not implement action '${family}_${verb}'"
    return 1
  fi
}
```

#### Action Family Dispatch Mapping

| Action Family | Verb | `gcp` Implementation | `none` Implementation | `aws` Implementation |
|---|---|---|---|---|
| **`hub_deploy`** | `roll` | `gcloud run services update` | `docker compose up -d hub` | `aws ecs update-service` |
| **`hub_deploy`** | `verify` | `check-hub-deploy.func.sh` (Cloud Run Ready) | `curl -f http://127.0.0.1:8080/healthz` | `aws ecs wait services-stable` |
| **`wui_deploy`** | `sync` | `firebase deploy --only hosting` | Caddy volume sync / reload | `aws s3 sync && aws cloudfront invalidation` |
| **`db_proxy`** | `start` | Start Cloud SQL Auth Proxy (`spl_sql_proxy_start`) | No-op (direct TCP connection to Postgres) | RDS Proxy or direct TLS connection |
| **`db_proxy`** | `stop` | Terminate proxy process / container | No-op | Terminate session |
| **`secrets`** | `check` | `gcloud secrets versions list` | Verify presence in `.env` / state volume | `aws secretsmanager describe-secret` |
| **`secrets`** | `seed` | `gcloud secrets versions add` | Append / update `.env` key | `aws secretsmanager put-secret-value` |
| **`docs`** | `publish` | `gcloud storage rsync` to GCS docs bucket | Copy to local directory / Docker volume | `aws s3 sync` to S3 docs bucket |
| **`dns`** | `reconcile` | Cloud DNS record set updates | `/etc/hosts` / local Caddyfile config | AWS Route 53 change-resource-record-sets |

---

## 5. Phase 1: Provider `none` (Self-Host on Compose)

Phase 1 delivers complete operational capability with zero cloud dependencies (`provider: none`), executing on a single Linux machine running Docker Compose.

### 5.1 Direct Reuse of Spec 072 Path P1 (Do Not Duplicate)

Spec 072 established the architectural foundation for rapid single-command deployment without cloud resources (Path P1). The swappable cloud layer Phase 1 directly relies upon the artifacts delivered by `spec 072` tasks:

| Spec 072 Task | Deliverable / Artifact | How Spec 076 Phase 1 Reuses It | Status on Trunk |
|---|---|---|---|
| **T004 (L6)** | `DEPLOY.md` baseline guide | Reference documentation for self-hosted compose topology | **Landed** (`c7ed917ad`) |
| **T005 (L31)** | `do_lde_up` & `docker-compose.yml` base | Compose service orchestration baseline | **Landed** (`5ec928322`) |
| **T013 (L1)** | Runtime configuration (`config.json`) | WUI decouples from cloud endpoints via dynamic `/config.json` | **Landed** (`4a5957be3`) |
| **T014 (L25)** | Unified hub Dockerfile (`hub.Dockerfile`) | Single container image runs both cloud and standalone compose | **Landed** (`6a00c67b4`) |
| **T015 (L2)** | CI container publishing to GHCR (`56_ghcr-images.yml`) | Pulls public images `ghcr.io/csitea/spool-{hub,web}` | **Landed** (`fcb1a9115`) |
| **T016 (L7)** | Compose default image pulling (`docker-compose.yml`) | Runs complete stack with `docker compose up -d` without compiling | **Landed** (`251ab6f8`) |
| **T017 (L9)** | One-command setup (`do_spl_self_host_up`) | Automated bootstrap, preflight checks, and domain configuration | **Landed** (`54cacd571`) |
| **T018 (L30)** | Contributor documentation (`CONTRIBUTING-WITH-AGENTS.md`) | Onboarding guide for non-cloud participants | In flight |
| **T033 (L37)** | No-tree compose execution | Compose runs from standalone bundle without git checkout | Open in 072 |
| **T040 (L14)** | Self-hosted stack upgrade (`do_spl_self_host_upgrade`) | Automated pulling of newer container releases | Open in 072 |

### 5.2 Seam Work Delivered by Spec 076 Phase 1

Building strictly on top of Spec 072, Spec 076 Phase 1 implements the concrete seam adapters for `provider: none`:

1. **Configuration Schema (`csi-spl-cnf`)**:
   - Add `env.cloud.provider` with valid values `gcp`, `none`, `aws` (default: `gcp`).
   - For standalone compose, `docker-compose.yml` exports `SPOOL_CLOUD_PROVIDER=none`.
2. **Hub Go Factory Driver (`internal/cloud/none`)**:
   - Blob store: Connects to the embedded Compose S3 service (`http://s3:9000`) using the generic `blob.S3` driver (`aws-sdk-go-v2/service/s3`), using S3 credentials passed via Compose secrets. The default bucket (`spool-files`) is created during `spool-up` setup. Does not force `blob.Dir` (owner decision 1).
   - Docs store: Stored in S3 bucket (`spool-docs`) or local web proxy volume.
   - Compute: Resolves container hostname or `SPOOL_VERSION`; drops `K_REVISION` checks.
   - Database: Directly utilizes TCP DSN (`postgres://${SPOOL_DB_RUNTIME}:...`), bypassing all proxy wrappers.
3. **Database Seam Neutralization**:
   - `spl_sql_proxy_start` checks `$(do_spl_cloud_provider)`: when `none`, it immediately returns exit 0 with `SPL_PROXY_PORT=5432` and `SPL_PROXY_DSN=$SPOOL_HUB_DB_DSN`, allowing all standard database migration and inspection actions (`do_spl_db_bootstrap`, `do_spl_tenant_create`) to execute cleanly against local Postgres.
4. **Secrets Seam Neutralization**:
   - `do_spl_secrets_check` and `do_spl_secrets_seed_all` route through `do_spl_cloud_dispatch`. Under `none`, secrets are validated against and written to `.env` mode 600 (Compose secrets) or `/var/lib/spool/state/session.key`.
5. **Docs Publish Seam Neutralization**:
   - `do_publish_docs` routes through `do_spl_cloud_dispatch`. Under `none`, staged markdown files are copied directly into target local directory or S3 bucket rather than invoking `gcloud storage rsync`.
6. **Deploy Seam Neutralization**:
   - Deploy actions dispatch to local Docker compose lifecycle (`docker compose up -d --no-deps <service>`).

### 5.3 Minimal S3-Compatible Service Evaluation & Selection (for Compose Self-Host)

Per owner HUM-10 decision 1, provider `none` includes an embedded minimal S3-compatible service in `docker-compose.yml` rather than relying on direct host filesystem volume mounts. Three candidates were evaluated for image size, licensing, architecture, and operational simplicity:

| Candidate | Image / Tag | License | Compressed Size | Binary & Architecture | S3 API Fidelity | Recommendation |
|---|---|---|---|---|---|---|
| **MinIO** | `minio/minio:RELEASE.2024-05-10...` | GNU AGPLv3 | ~95 MB (260 MB raw) | Single Go binary (`minio server /data --console-address :9001`) | 100% (Industry standard, v4 signatures, multipart uploads) | **Recommended Default**: Battle-tested with `aws-sdk-go-v2`, zero compatibility issues with standard Go SDK client. Run with `MINIO_BROWSER=off` for minimal memory. |
| **SeaweedFS** | `chrislusf/seaweedfs:latest` | Apache 2.0 | ~45 MB (120 MB raw) | Single Go binary (`weed server -s3 -dir=/data`) | High (embedded S3 gateway + volume server) | **Recommended Permissive Alternative**: Permissive Apache 2.0 license eliminates any AGPL copyleft viral concern for downstream distributors; very low memory footprint. |
| **Garage** | `dxflrs/garage:v1.2.0` | GNU AGPLv3 | ~25 MB (70 MB raw) | Single Rust binary (`garage server`) | Moderate (tailored for lightweight geo-distributed self-hosting) | Viable, but requires explicit cluster layout initialization even for single-node deployments. |

**Selection & Provisioning Contract**:
- Default image: MinIO (or SeaweedFS if Apache 2.0 compliance is strictly required by packaging rules).
- Default internal endpoint: `http://s3:9000`.
- Bucket provisioning: During `do_spl_self_host_up` (step 4), the bootstrap script provisions the default bucket `spool-files` before starting the hub container.
- Credentials: S3 Access Key ID and Secret Access Key are randomly generated (48 hex characters) and stored in `.env` (mode 600) as Compose secrets (`SPOOL_S3_ACCESS_KEY`, `SPOOL_S3_SECRET_KEY`).

---

## 6. Phase 2: AWS Provider Mapping

Phase 2 introduces the AWS cloud provider (`env.cloud.provider: aws`). Detailed implementation tasks will be scheduled in Phase 2; the architecture maps one-to-one to AWS native services:

### 6.1 AWS Service Mapping Matrix

| Scope Service | AWS Target Service | Architectural Implementation Details |
|---|---|---|
| **S1: Compute** | **AWS ECS (Fargate) & ECR** | Containerized hub runs on serverless ECS Fargate tasks behind an Application Load Balancer (ALB) with HTTP/2 and WebSocket support. Images reside in Amazon Elastic Container Registry (ECR). Agent runner boxes run on Amazon EC2 Debian 13 instances. |
| **S2: Blob Storage** | **Amazon S3** | Object storage buckets (`spool-<env>-files`, `spool-<env>-docs`, `spool-<env>-relay`) with S3 Versioning and lifecycle rules. Hub Go client uses `aws-sdk-go-v2/service/s3` with multi-part upload and ETag verification. |
| **S3: Database** | **Amazon RDS PostgreSQL 16** | Managed PostgreSQL 16 instance with automated snapshots, Multi-AZ availability in production, and Performance Insights. Hub connects via standard TLS TCP connections (`sslmode=verify-full`). |
| **S4: Secrets** | **AWS Secrets Manager** | Database DSN, session encryption keys, OAuth client secrets, and payment API keys stored in Secrets Manager. Values are injected directly into ECS Task Definitions at container launch via ARN reference. |
| **S5: Web Hosting** | **Amazon S3 + CloudFront** | Nuxt 3 static export uploaded to private S3 origin bucket. Amazon CloudFront CDN provides global edge distribution, custom domain mapping, and CloudFront Functions for `/api/v1/auth/*` path rewrites to the ALB. |
| **S6: DNS / TLS** | **Route 53 & ACM** | Amazon Route 53 manages public hosted zone records (Alias records pointing to CloudFront and ALB). AWS Certificate Manager (ACM) issues and auto-renews public wildcard TLS certificates (`*.BASE_DOMAIN`). |
| **S7: CI Identity** | **AWS IAM GitHub OIDC** | GitHub Actions workflows authenticate via OpenID Connect (OIDC) through an AWS IAM OIDC Identity Provider (`token.actions.githubusercontent.com`), assuming a dedicated deploy role via `aws-actions/configure-aws-credentials` with zero static keys. |

---

## 7. Owner Decisions & Architectural Directives

Owner HUM-10 formally resolved all five design questions in topic `a5a141bc-e891-4f26-bcdb-d1ac5efcd89f`, msg `cfc67e74-16d2-4488-8a8f-f0f44efc169d` (2026-10-04 15:43Z). These decisions govern the implementation across Phase 1 and Phase 2:

### Decision 1: Blob Storage for Provider `none` (Embedded S3 Service)
- **Question**: Should provider `none` default to direct local host filesystem volume mounts or an embedded S3-compatible service in compose?
- **Owner Decision**: **"yes - for some minimalistic s3 service"**.
- **Architectural Directive**:
  1. The self-hosted compose stack runs an embedded S3-compatible container (MinIO with `MINIO_BROWSER=off` or SeaweedFS).
  2. The generic Go S3 driver (`aws-sdk-go-v2/service/s3`) moves into **Phase 1** (was Phase 2 T011), providing a unified S3 storage abstraction across both self-hosted Compose and native AWS S3.
  3. The default bucket (`spool-files`) is created during `do_spl_self_host_up` before the hub container starts.
  4. Local host folder mounting (`blob.Dir`) is not the default for compose self-hosting.

### Decision 2: Secret Loading Mechanism for Provider `none`
- **Question**: Should secrets for self-hosted deployments without a cloud KMS be passed via `.env` files, Docker Compose secrets, or an encrypted local keystore?
- **Owner Decision**: **Accepted Recommended Default**.
- **Architectural Directive**: Docker Compose secrets backed by a restricted root-owned `.env` file (mode 600) automatically generated during `spool-up` setup. Hub reads secrets from `/run/secrets/` or standard environment variables injected by Compose.

### Decision 3: Primary AWS Compute Architecture for Phase 2
- **Question**: Which compute platform should be the primary deployment target for the containerized Go hub API on AWS?
- **Owner Decision**: **Accepted Recommended Default**.
- **Architectural Directive**: **AWS ECS with AWS Fargate**. Serverless container execution matching Google Cloud Run's architectural profile, with ALB routing, native IAM task role authentication, and zero VM cluster management overhead.

### Decision 4: Static Web Hosting Topology on AWS for Phase 2
- **Question**: Should the Nuxt WUI static bundle be deployed to S3 fronted by CloudFront CDN via Terraform, or should AWS Amplify Hosting be used?
- **Owner Decision**: **Accepted Recommended Default**.
- **Architectural Directive**: **Amazon S3 + CloudFront managed via Terraform**. Matches the existing Terraform step `019` pattern, supports fine-grained cache invalidation, edge headers, and custom domain SSL certificates via ACM.

### Decision 5: Multi-Cloud Database Dialect & Migration Strategy
- **Question**: Should database migrations remain pure standard PostgreSQL (guaranteeing 100% portability across Cloud SQL, RDS Aurora PostgreSQL, and local Postgres containers)?
- **Owner Decision**: **Accepted Recommended Default**.
- **Architectural Directive**: Enforce strict standard PostgreSQL SQL dialect without cloud-specific extensions or vendor lock-in. A migration verification task is added to Phase 1 to statically validate all existing and future migration SQL files.

<!-- version: 0.2.0 · updated: 2026-10-04 · last-edit: 2026-10-04T15:45:00Z -->
