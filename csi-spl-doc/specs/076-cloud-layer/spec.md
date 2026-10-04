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
- `none`: `blob.Dir` filesystem driver wrapping local directory (`/var/lib/spool/files`).
- `aws`: `blob.S3` driver wrapping `github.com/aws/aws-sdk-go-v2/service/s3`.

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
   - Blob store: Forces `blob.Dir` (`SPOOL_HUB_FILES_DIR=/var/lib/spool/files`), eliminating any invocation of `cloud.google.com/go/storage`.
   - Docs store: Forces `blob.Dir` (`SPOOL_HUB_DOCS_DIR=/var/lib/spool/docs`).
   - Compute: Resolves container hostname or `SPOOL_VERSION`; drops `K_REVISION` checks.
   - Database: Directly utilizes TCP DSN (`postgres://${SPOOL_DB_RUNTIME}:...`), bypassing all proxy wrappers.
3. **Database Seam Neutralization**:
   - `spl_sql_proxy_start` checks `$(do_spl_cloud_provider)`: when `none`, it immediately returns exit 0 with `SPL_PROXY_PORT=5432` and `SPL_PROXY_DSN=$SPOOL_HUB_DB_DSN`, allowing all standard database migration and inspection actions (`do_spl_db_bootstrap`, `do_spl_tenant_create`) to execute cleanly against local Postgres.
4. **Secrets Seam Neutralization**:
   - `do_spl_secrets_check` and `do_spl_secrets_seed_all` route through `do_spl_cloud_dispatch`. Under `none`, secrets are validated against and written to `.env` mode 600 or `/var/lib/spool/state/session.key`.
5. **Docs Publish Seam Neutralization**:
   - `do_publish_docs` routes through `do_spl_cloud_dispatch`. Under `none`, staged markdown files are copied directly into the shared Docker volume (`hub-docs`) rather than invoking `gcloud storage rsync`.
6. **Deploy Seam Neutralization**:
   - Deploy actions dispatch to local Docker compose lifecycle (`docker compose up -d --no-deps <service>`).

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

## 7. Open Questions for the Owner

The following 5 technical design decisions are presented for the owner's review, each with a concrete recommended default:

### Question 1: Provider Selection Granularity (Global vs Hybrid)
- **Question**: Should `env.cloud.provider` set all 7 services simultaneously (`provider: gcp | none | aws`), or should hybrid configurations be permitted (e.g. self-hosted compute with AWS S3 storage)?
- **Recommended Default**: **Global setting by default, with optional service overrides**. The top-level key `env.cloud.provider: gcp|none|aws` establishes the estate baseline. Advanced operators may override individual services (e.g. `env.cloud.services.blob: aws`) only when explicitly specified. This preserves extreme simplicity for standard deployments while supporting enterprise multi-cloud setups.

### Question 2: Local Blob Storage Engine for Self-Hosting (Filesystem vs MinIO)
- **Question**: For provider `none` in production self-hosting on a single VM, should local filesystem volume storage (`blob.Dir`) remain the permanent storage engine, or should an embedded MinIO/SeaweedFS S3-compatible container be added to `docker-compose.yml`?
- **Recommended Default**: **Keep `blob.Dir` as the default storage engine for `none`**. `blob.Dir` introduces zero memory overhead, requires no background daemon, has zero external network dependencies, and provides optimal I/O throughput on local NVMe storage. An S3-compatible container can be offered as an optional profile for distributed multi-node clusters.

### Question 3: Primary AWS Compute Architecture (ECS Fargate vs App Runner vs EKS)
- **Question**: For Phase 2 AWS deployment, which compute platform should be the primary deployment target for the containerized Go hub API?
- **Recommended Default**: **AWS ECS with AWS Fargate**. ECS Fargate provides exact architectural parity with Google Cloud Run (serverless container execution, automatic task replacement, native IAM task role authentication, seamless Secrets Manager integration). AWS App Runner currently imposes restrictive limits on persistent WebSocket connection lifespans, while AWS EKS introduces disproportionate operational overhead for a single-image API service.

### Question 4: Static Web Hosting Topology on AWS (S3+CloudFront vs Amplify)
- **Question**: For Phase 2 WUI hosting on AWS, should the static web bundle be deployed to S3 fronted by CloudFront CDN via Terraform, or should AWS Amplify Hosting be used?
- **Recommended Default**: **S3 + CloudFront managed via Terraform**. S3 + CloudFront mirrors the project's existing Terraform infrastructure pattern (analogous to step `019`), avoids proprietary Amplify framework lock-in, and allows precise declarative configuration of security headers, edge caching behaviors, and path rewrites to the hub API.

### Question 5: Cloud Database Connectivity Pattern on AWS
- **Question**: Cloud SQL uses Cloud SQL Auth Proxy for secure IAM-gated socket access. On AWS, should RDS use AWS IAM database authentication or standard TLS TCP connections with secrets-managed credentials?
- **Recommended Default**: **Standard TLS TCP connections (`sslmode=verify-full`) with credentials retrieved from AWS Secrets Manager**. AWS IAM DB authentication generates ephemeral tokens with a 15-minute lifetime requiring complex token renewal interceptors in the Go connection pool, whereas standard TLS connection pooling via `jackc/pgx/v5` is highly performant, standard across PostgreSQL, and completely reliable.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T15:25:00Z -->
