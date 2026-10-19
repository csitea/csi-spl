# 148: local dev mode (single docker-compose developer stack for spool-hub)

**Feature ID**: `148-local-dev-mode` · **Milestone**: M3 · **Status**: Planned (Spec Only) · **Version**: 0.1.0
**Created**: 2026-10-20 · **Epic**: SPL-2400 · **Issue**: SPL-2645 · **Lane**: a-549-c002-spec-local-dev-mode
**Authority**: this file for system architecture, dependency gap analysis, prerequisite contracts, parameterized secrets, and acceptance criteria. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, blob storage, viewer API)
- [007 hub API infra](../007-spool-hub-api-infra/spec.md) (cloud estate, provisioning order, lde, rdb)
- [010 social auth](../010-spool-social-auth/spec.md) (OAuth providers, session cookies, Secret Manager slots)
- [015 native auth](../015-spool-native-auth/spec.md) (email/password authentication, SMTP relay)
- [017 security hardening](../017-spool-security-hardening/spec.md) (DB owner/runtime split, edge limits)
- [018 entra auth](../018-spool-auth-microsoft/spec.md) (Microsoft Entra ID, PKCE, mock IdP keys)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles, permissions, workspace admin vs operator)
- [044 open source](../044-spool-open-source/spec.md) (self-hosted and export rules)
- [047 deployability](../047-spool-deployability/deployability-analysis.md) (deployment evaluation and paths)
- [072 rapid deployability](../072-rapid-deployability/spec.md) (Path P1 compose on local machines, P2 estate, P3 boxes)
- [076 cloud layer](../076-cloud-layer/spec.md) (the swappable cloud layer: provider `none` / `local`)
- [077 checkout activation](../006-spool-hub-rental/spec.md) (fake payment rail `SPOOL_HUB_ENABLE_FAKE_PAY`)

`<BASE_DOMAIN>`, `<fqdn>`, `<workspace_id>`, `<tenant>`, `<secret>`, and `<token>` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, or API headers.

---

## 0. The Owner's Request & Business Intent (Verbatim, Binding)

The owner HUM-10 gave the authoritative mandate to create a "local dev mode" in topic `fe5d70de-45a5-4a10-9d03-8450579e0849` (channel `csitea-web-devel`, 2026-10-20):

1. **Owner HUM-10, topic `fe5d70de`, msg `d260f283`**:
   > "we need to create a "local dev mode" in which the spool-hub will operate"

2. **Owner HUM-10, topic `fe5d70de`, msg `6b9682da`**:
   > "Which will be basically everything running trough a local dev ocker-compose - with some minio or other s3 mimicking services just running locally"

3. **Owner HUM-10, topic `fe5d70de`, msg `0aead6c1` (poll `1a1dca73`)**:
   > "A — A developer runs spool-hub (hub + web UI + DB) on their own machine to build and test it"

4. **Owner HUM-10, topic `fe5d70de`, msg `2523f57e-c8cf-4376-a6a1-e6862a372801` (08:1xZ, parameterized secrets)**:
   > "for the local dev setup we could use default , but paraemtrized secrets"

5. **Owner HUM-10, topic `fe5d70de`, msg `6b8bf9c3-85e5-4981-a619-df77900d73ca` (08:2xZ, stranger-proof one-liner)**:
   > "so that a person not knowing anything of the system would be able to just run the one liner and get some knd of error msg if he is missing some binaries etc. and just get it work"

### Core Principles

1. **P1: The 'Local' Provider of Spec 076**: This specification defines the developer-facing implementation of the `none` / `local` provider designed in [spec 076 §5](../076-cloud-layer/spec.md#5-phase-1-provider-none-self-host-on-compose) and the single-machine execution path P1 in [spec 072 §3](../072-rapid-deployability/spec.md#3-who-deploys-and-on-what).
2. **P2: Stranger-Proof One-Liner**: A developer with zero prior knowledge of Spool internals can execute a single command from a clean repository clone. Before starting any container or build, the command validates every system prerequisite and prints a plain, actionable error naming the exact installation command if any prerequisite is missing.
3. **P3: Parameterized Default Secrets with Production Refusal**: Local development requires zero manual credential generation. Working developer-safe default secrets are provided for all components (database, session signing, object storage, mock OAuth). Every secret is parameterized via environment variables. To prevent security incidents, an automated startup assertion refuses to start if any default dev secret is detected in `dev` or `prd` environments.
4. **P4: 100% Offline Capability**: Once container images are present, the entire stack (hub API, web UI, Postgres database, S3 object storage, authentication, mail catcher) operates without any outbound network connectivity to GCP, AWS, or public identity providers.
5. **P5: Clean Idempotent Lifecycle**: One command to start (`up`), one command to stop (`down`). A teardown with purge leaves no orphaned processes, volumes, or host port bindings.

---

## 1. Cloud Seam Inventory (Measured from Code)

Every dependency the hub API (`csi-spl-api`) and the web UI (`csi-spl-wui`) have on cloud infrastructure or real external accounts was measured directly from the repository code.

### 1.1 Seams Breakdown by Dependency Area

#### 1. Object Storage (GCS vs S3)
- **Cloud Reality**: In GCP, the hub stores user file uploads (`SPOOL_HUB_FILES_BUCKET`) and documentation bundles (`SPOOL_HUB_DOCS_BUCKET`) in Google Cloud Storage buckets provisioned in steps `050-gcs-files` and `051-gcs-docs`. Documentation synchronization uses `gcloud storage rsync`.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go:256` (`OpenGCS` using `cloud.google.com/go/storage`)
  - `csi-spl-api/src/go/spool-hub-api/internal/blob/s3.go:64` (`type S3 struct`, generic S3 driver)
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:138` (`gcpBlob.Docs` instantiating `OpenGCS`)
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:175` (`noneBlob.Files` instantiating `blob.OpenS3`)
  - `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:316` (`openBlobStore` file store resolver)
  - `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:329` (`openDocsStore` documentation store resolver)
  - `csi-spl-orc/src/bash/run/publish-docs.func.sh:94` (`gcloud storage rsync` invocation)
- **What `lde` Does Today**: `lde` runs `fsouza/fake-gcs-server:1.52.2` at port 54443 (`csi-spl-cnf/csi-spl/lde.env.yaml:31`, `csi-spl-orc/src/docker/docker-compose-infra.yaml:37`) via `STORAGE_EMULATOR_HOST=gcs:4443`.
- **Gaps / What Breaks**:
  - `fake-gcs-server` emulates only the Google Cloud Storage API; it does not provide an S3 API.
  - The standalone root `docker-compose.yml:78` runs SeaweedFS 4.48 (`weed mini`) with an S3 API on port 9000 under `SPOOL_CLOUD_PROVIDER=none`.
  - Having `lde` on `fake-gcs-server` while standalone compose uses S3 creates architectural drift. Local dev mode must standardize on an S3-compatible service (SeaweedFS / MinIO) matching the swappable cloud layer (Spec 076).

#### 2. Relational Persistence (Postgres 16)
- **Cloud Reality**: GCP Cloud SQL for PostgreSQL 16 (`csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf`). In production, Cloud Run connects via Unix socket `/cloudsql/<connection-name>`, and administration actions connect via Cloud SQL Auth Proxy (`spl_sql_proxy_start`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:250` (`tcpDSN.DSN` refuses `/cloudsql/` Unix sockets when `SPOOL_CLOUD_PROVIDER=none`)
  - `csi-spl-api/src/go/spool-hub-api/internal/store/postgres/store.go:1` (Postgres driver via `jackc/pgx/v5`)
  - `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:386` (`spl_sql_proxy_start`)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:25-29` (`pg: image: postgres:16-alpine`, port 55432)
- **What `lde` Does Today**: Fully emulated. Runs `postgres:16-alpine` in compose (`csi-spl-orc/src/docker/docker-compose-rdb.yaml:10`) on port 55432 with direct TCP connection (`postgres://spool:spool_lde_pw@pg:5432/spool?sslmode=disable`).
- **Gaps / What Breaks**: The database container starts cleanly, but schema migrations require explicit initialization. In standalone compose, `hub-init` (`docker-compose.yml:100`) executes `spool init` prior to `hub` starting.

#### 3. Sign-in & Identity (OAuth Providers, Native Email/Password, Sessions)
- **Cloud Reality**:
  - Social authentication delegates to Google, Microsoft, LinkedIn, Facebook, and xAI OAuth 2.0 / OIDC endpoints (`csi-spl-cnf/csi-spl/all.env.yaml:352`).
  - Production requires public DNS callbacks and registered OAuth client secrets stored in Secret Manager (`csi-spl-hub-auth-google-client-secret`, etc.).
  - Session state is encrypted with a 32-byte AES key (`csi-spl-hub-auth-session-key`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/fakeidp/fakeidp.go:1` (`package fakeidp`, mock OAuth provider)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1` (HTTP OAuth handshake and callback handlers)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:1` (native email/password authentication)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native_config.go:88` (`SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS` refusal outside `lde`)
  - `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:489` (`AuthBootstrapOwner` configuration)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:63-64` (`auth_native: false`, `auth_providers: ""`)
  - `csi-spl-wui/src/pages/login.vue:1` (login view rendering social and native buttons)
- **What `lde` Does Today**:
  - In `lde.env.yaml`, `auth_native` is `false` and `auth_providers` is empty (`""`).
  - If a developer sets `LDE_AUTH_NATIVE=1`, native auth is enabled with `SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS: "true"`, returning confirmation tokens directly in the HTTP JSON response body to bypass mail delivery.
  - Social OAuth buttons in the WUI are disabled or fail because external IdP client IDs and secrets are unset.
  - `do_gen_docker_env` writes a random session key into `$HOME/.local/share/csi-spl/lde/<tree>/session.key`.
- **Gaps / What Breaks**: Outside contributors cannot test social sign-in without creating real Google Cloud or LinkedIn OAuth developer applications. Local dev mode must package the existing in-tree mock IdP (`fakeidp`) as a first-class compose service or dev route.

#### 4. Secret Management & Runtime Configuration
- **Cloud Reality**: GCP Secret Manager stores database DSNs, session encryption keys, OAuth secrets, and payment API tokens (`csi-spl-cnf/csi-spl/all.env.yaml:416-520`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:115` (`envSecrets.Secret` reading process environment)
  - `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:354` (`gcloud secrets versions access`)
  - `csi-spl-orc/src/bash/run/spl-secrets-check.func.sh:125` (`gcloud secrets versions list`)
- **What `lde` Does Today**: The hub runtime already consumes secrets exclusively through environment variables via `envSecrets`. In `lde`, `do_gen_docker_env` generates static `.env` files.
- **Gaps / What Breaks**: Clean in runtime, but lacks standard developer-safe default values in compose. Developers must manually configure `.env` unless defaults are embedded with strict production guards.

#### 5. Mail & Transactional Messaging
- **Cloud Reality**: Cloud Run relies on an external authenticated SMTP relay (e.g. Google Workspace SMTP or SendGrid) to send workspace invitations, account verifications, and password reset links.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:52` (`TLSNone = "none"`, loopback catcher support)
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:61` (`type SMTP struct`)
  - `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:268` (`mailPreflight` pre-startup connectivity check)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:174` (`SPOOL_HUB_MAIL_TRANSPORT: "log"`)
- **What `lde` Does Today**: `SPOOL_HUB_MAIL_TRANSPORT: "log"`. Outbound emails are printed as structured log lines to stdout.
- **Gaps / What Breaks**: Developers cannot visually verify rendered HTML email templates, test verification links in a real browser mailbox, or inspect headers without digging through container logs.

#### 6. Cloud Run Compute Specifics
- **Cloud Reality**: Cloud Run injects `K_REVISION`, `K_SERVICE`, and `PORT`. Container processes query the GCP instance metadata server (`http://metadata.google.internal`) for project IDs and service account identity tokens.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/revision.go:27` (revision tracking)
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:155` (`gcpCompute.Revision` reading `K_REVISION`)
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:237` (`noneCompute.Revision` falling back to `SPOOL_VERSION` or container hostname)
  - `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:276` (`Port` / `PORT` binding)
  - `csi-spl-api/src/docker/hub-entrypoint.sh:152` (`is_plain` detecting `K_SERVICE`)
- **What `lde` Does Today**: Decoupled. When `SPOOL_CLOUD_PROVIDER=none`, `noneCompute` provides deterministic revision identifiers without calling GCP metadata endpoints.
- **Gaps / What Breaks**: None.

#### 7. Web Hosting & Single-Page Application Delivery
- **Cloud Reality**: Nuxt 3 static bundle is published to Firebase Hosting (`csi-spl-iac/src/terraform/019-firebase-static-site/03-firebase-site.tf`). Firebase rewrites `/api/**` to Cloud Run and forwards session cookies (`__session`).
- **Code Citations**:
  - `.github/workflows/30_wui-build-deploy.yml:468` (`firebase-tools deploy --only hosting`)
  - `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh:1` (Firebase rewrite generation)
  - `docker-compose.yml:216` (`web` service using Caddy reverse proxy)
  - `csi-spl-wui/src/utils/runtime-config.mjs:1` (runtime `/config.json` loading)
- **What `lde` Does Today**: `do_wui_up` runs `pnpm dev` on port 3000 with `NUXT_DEV_AUTH_PROXY` proxying auth routes. Standalone compose (`docker-compose.yml:216`) uses Caddy to serve the generated bundle and proxy `/api/*` and `/v1/ws` to the hub.
- **Gaps / What Breaks**: Running `pnpm dev` requires Node.js, pnpm, and local build dependencies on the host machine. Local dev mode should allow running both containerized static bundles (zero host dependencies) and live hot-reloading dev servers.

#### 8. Push Notifications & Real-Time Events
- **Cloud Reality**: Spool uses native WebSockets (`/api/v1/live`) rather than third-party push notification gateways (FCM, APNs).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/live.go:1` (WebSocket live hub connection)
  - `csi-spl-wui/src/composables/useLiveSocket.ts:1` (WUI WebSocket client)
- **What `lde` Does Today**: Fully functional locally over TCP WebSocket.
- **Gaps / What Breaks**: None.

#### 9. Payments & Billing
- **Cloud Reality**: Production workspace upgrades and paid bot seat allocations interact with Stripe API endpoints (`spec 077`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/payments/config.go:54` (`EnableFakePay bool`)
  - `csi-spl-api/src/go/spool-hub-api/internal/payments/config.go:137` (assertion enforcing `SPOOL_HUB_ENABLE_FAKE_PAY` only in `lde`/`dev`)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:141` (`SPOOL_HUB_ENABLE_FAKE_PAY: "true"`)
- **What `lde` Does Today**: Emulated via `SPOOL_HUB_ENABLE_FAKE_PAY="true"`. Mock checkout rail activates workspaces without external Stripe calls.
- **Gaps / What Breaks**: None. Local dev mode must keep `SPOOL_HUB_ENABLE_FAKE_PAY="true"`.

#### 10. External Integrations & DNS
- **Cloud Reality**: GitHub API for in-WUI documentation editing (`SPOOL_HUB_DOCS_EDIT_GITHUB_API`); Gandi LiveDNS for external routing.
- **Code Citations**:
  - `csi-spl-cnf/csi-spl/lde.env.yaml:117` (`SPOOL_HUB_DOCS_EDIT_GITHUB_API: ""`)
  - `csi-spl-orc/README.md:42` (Gandi LiveDNS actions)
- **What `lde` Does Today**: Disabled (`""`).
- **Gaps / What Breaks**: None. Stays local or off.

---

### 1.2 Summary Gap Table

| # | Service Area | Cloud Production Reality | In-Tree Code Citation | Current `lde` Behavior | Local Dev Mode Stand-in | Gap Status |
|---|---|---|---|---|---|---|
| **1** | **Object Storage** | GCP Cloud Storage (GCS buckets) | `internal/blob/blob.go:256`, `cmd/spool/hub.go:316` | `fake-gcs-server` on port 54443 | Embedded SeaweedFS S3 on port 9000 | **Drift**: `lde` uses GCS emulator; local dev mode unifies on S3 API |
| **2** | **Relational DB** | GCP Cloud SQL Postgres 16 | `internal/cloud/cloud.go:250`, `store.go:1` | Standalone `postgres:16-alpine` | Containerized Postgres 16 with healthcheck | **Working**: fully emulated locally |
| **3** | **Authentication** | Google, LinkedIn, Microsoft OAuth | `internal/auth/fakeidp/fakeidp.go:1`, `handler.go:1` | Disabled (`auth_providers: ""`, `auth_native: false`) | Local `fakeidp` mock service + Native auth with bootstrap owner | **Missing**: Social login breaks without cloud keys; mock IdP fills gap |
| **4** | **Secrets** | GCP Secret Manager | `internal/cloud/cloud.go:115`, `spl-cloud-cnf.func.sh:354` | Process env files in `.local/share/` | Parameterized dev defaults in compose + anti-leak guard | **Missing**: Dev defaults required for zero-config startup |
| **5** | **Mail** | Authenticated SMTP Relay | `internal/mail/mail.go:52`, `cmd/spool/hub.go:268` | Stdout log transport (`mail: log`) | Local Mailpit container (SMTP:1025, Web UI:8025) | **Missing**: No web inbox to inspect transactional mail |
| **6** | **Compute Metadata** | Cloud Run Metadata Server | `internal/hub/revision.go:27`, `internal/cloud/cloud.go:237` | `noneCompute` (hostname / `SPOOL_VERSION`) | Container hostname / `SPOOL_VERSION` via `noneCompute` | **Working**: Decoupled in Spec 076 |
| **7** | **Web Hosting** | Firebase Hosting CDN | `render-wui-firebase-json.sh:1`, `runtime-config.mjs:1` | `pnpm dev` on port 3000 | Caddy reverse proxy + static bundle or dev server | **Working**: Caddy handles static assets and `/api` proxying |
| **8** | **Push / Live** | Cloud Run WebSockets | `internal/hub/live.go:1`, `useLiveSocket.ts:1` | Direct TCP WebSocket connection | Direct WebSocket proxying via Caddy (`/v1/ws`, `/api/v1/live`) | **Working**: Native protocol |
| **9** | **Payments** | Stripe API | `internal/payments/config.go:54,137` | `SPOOL_HUB_ENABLE_FAKE_PAY="true"` | Fake pay rail enabled by default | **Working**: Fake rail operational in `lde` |
| **10**| **External APIs** | GitHub Docs API, Gandi DNS | `lde.env.yaml:117`, `README.md:42` | Disabled (`""`) | Disabled / Mock endpoints | **Working**: Non-blocking for local core |

---

## 2. Architecture & Docker Compose Topology

Local dev mode bundles the entire Spool estate into a single, cohesive Docker Compose topology. Every cloud service gap identified in Section 1 is paired with a local container stand-in.

```
+-------------------------------------------------------------------------------------------------------+
|                                    LOCAL DEVELOPER MACHINE (Clean OS)                                 |
+-------------------------------------------------------------------------------------------------------+
                                                     │
                                                     ▼
+-------------------------------------------------------------------------------------------------------+
|                                        PREFLIGHT VERIFICATION                                         |
|  Checks: OS Arch, Git >= 2.30, Docker Daemon, Compose v2, Free Disk (>=5GB), RAM (>=2GB), Free Ports  |
+-------------------------------------------------------------------------------------------------------+
                                                     │
                                                     ▼ (pass)
+-------------------------------------------------------------------------------------------------------+
|                                      DOCKER COMPOSE NETWORK: spool-dev                                |
|                                                                                                       |
|  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐    ┌─────────────────────────┐  |
|  │        pg        │    │        s3        │    │       mail       │    │         fakeidp         │  |
|  │  Postgres 16-alp │    │ SeaweedFS (S3)   │    │  Mailpit Catcher │    │  Mock Social IdP        │  |
|  │  Port 5432 (TCP) │    │ Port 9000 (S3)   │    │  Port 1025 (SMTP)│    │  Port 8085 (HTTP/OAuth) │  |
|  └─────────┬────────┘    └────────┬─────────┘    │  Port 8025 (Web) │    └────────────┬────────────┘  |
|            │                      │              └────────┬─────────┘                 │               |
|            ▼                      │                       │                           │               |
|  ┌──────────────────┐             │                       │                           │               |
|  │     hub-init     │             │                       │                           │               |
|  │ Migrations & DML │             │                       │                           │               |
|  │ Exit 0 on Ready  │             │                       │                           │               |
|  └─────────┬────────┘             │                       │                           │               |
|            │                      │                       │                           │               |
|            ▼                      ▼                       ▼                           ▼               |
|  ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐  |
|  │                                                hub                                              │  |
|  │                        Spool Hub API (spool serve, SPOOL_CLOUD_PROVIDER=none)                   │  |
|  │                                         Port 8080 (Internal)                                    │  |
|  └────────────────────────────────────────────────┬────────────────────────────────────────────────┘  |
|                                                   │                                                   |
|                                                   ▼                                                   |
|  ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐  |
|  │                                                web                                              │  |
|  │                 Caddy Web Gateway (Reverse Proxy /api, /v1/ws -> hub; Serves WUI SPA)          │  |
|  │                                   Published Host Port: 127.0.0.1:8080                            │  |
|  └─────────────────────────────────────────────────────────────────────────────────────────────────┘  |
+-------------------------------------------------------------------------------------------------------+
```

### 2.1 Storage Stand-in: Evaluation of MinIO vs SeaweedFS vs fake-gcs-server

Owner HUM-10 explicitly mandated an S3-compatible service ("with some minio or other s3 mimicking services just running locally", msg `6b9682da`). Three candidate storage engines were evaluated:

| Candidate | Image & Tag | License | Compressed Image Size | Memory Footprint | Native S3 Parity | Auto Bucket Creation | Assessment & Recommendation |
|---|---|---|---|---|---|---|---|
| **SeaweedFS** | `chrislusf/seaweedfs:4.48` | **Apache 2.0** | ~45 MB (120 MB raw) | ~35 MB | Excellent (S3 API on `:9000`) | Built-in via `weed mini` startup command | **Recommended Default**: Fully permissive Apache 2.0 license eliminates AGPL copyleft concerns for open-source distributors. Extremely low memory footprint. Already tested and active in root `docker-compose.yml:78`. |
| **MinIO** | `minio/minio:RELEASE.2024-05-10...` | **GNU AGPLv3** | ~95 MB (260 MB raw) | ~110 MB | 100% Industry Standard | Requires secondary `mc mb` bootstrap container | **Viable Alternative**: Battle-tested, but carries AGPL licensing restrictions and requires a multi-step bucket creation wrapper. |
| **fake-gcs-server** | `fsouza/fake-gcs-server:1.52.2` | Apache 2.0 | ~30 MB (80 MB raw) | ~25 MB | **0% (GCS API only)** | Automatic directory mount | **Rejected for Compose**: Does not implement the S3 API. Retaining it would preserve vendor lock-in to Google Cloud Storage drivers rather than fulfilling the swappable cloud layer (Spec 076). |

**Architectural Rationale**: SeaweedFS provides a compliant S3 API on port 9000, runs under a permissive Apache 2.0 license, automatically creates the required `spool-files` bucket upon invocation of `weed mini`, and seamlessly pairs with the hub's pure Go `blob.S3` client driver (`internal/blob/s3.go:64`).

### 2.2 Mail Catcher Stand-in: Mailpit Integration
In place of logging transactional emails to stdout, local dev mode embeds `axllent/mailpit:v1.21`:
- **SMTP Submission Port**: `1025` (consumed by the hub API via `SPOOL_HUB_MAIL_SMTP_HOST=mail`, `SPOOL_HUB_MAIL_SMTP_PORT=1025`, `SPOOL_MAIL_TLS_MODE=none`).
- **Interactive Web Interface**: `8025` (accessible to the developer at `http://localhost:8025`).
- **Capabilities**: Captures 100% of outgoing emails (workspace invites, email verifications, password resets), renders multipart HTML/plain text, verifies token links, and exposes a REST API (`/api/v1/messages`) for automated integration tests.

### 2.3 Identity Stand-in: Embedded `fakeidp` Mock Service
Rather than disabling social authentication or requiring real cloud developer credentials, local dev mode runs the repository's internal mock IdP (`internal/auth/fakeidp/fakeidp.go`):
- **Endpoints**: Implements standard Google, Microsoft Entra, LinkedIn, and Facebook OAuth 2.0 endpoints.
- **Port**: Listens internally on port `8085`.
- **Pre-seeded Personas**:
  - `dev-admin@spool.local` (Spool-Hub Workspace Administrator)
  - `alice@spool.local` (Regular Workspace Member)
  - `bob@spool.local` (Invited Guest Contributor)
- **Zero-Friction Authentication**: Skips external consent screens and immediately redirects the browser to the callback URL with valid authorization codes and stable avatar PNGs.

### 2.4 Offline Network Enforcement
Local dev mode guarantees complete offline operation:
- All services attach to a single user-defined bridge network (`spool-dev`).
- The Caddy gateway publishes ports strictly to `127.0.0.1:8080`.
- Automated test suites verify offline operation by booting the stack inside a containerized sandbox with outbound gateway routing severed (`iptables -A OUTPUT -d 0.0.0.0/0 -j DROP`), confirming that the hub `/version`, WUI login, post creation, and file uploads succeed with zero dropped packets.

---

## 3. Parameterized Default Secrets & Anti-Leak Guards (Owner Request 08:1xZ)

Per owner HUM-10's explicit instruction (msg `2523f57e`), local dev mode ships with working default secrets so that `up` succeeds out of the box with zero manual credential configuration, while every secret remains fully overridable via environment variables.

### 3.1 Secrets Register & Parameter Mappings

| Secret Name / Role | Parameter Name (Env Override) | Local Dev Default Value | Purpose | Production Target (Secret Manager Slot) |
|---|---|---|---|---|
| **Database Superuser Password** | `SPOOL_DB_SUPERUSER_PASSWORD` | `spool-dev-superuser-pw` | Postgres administrative user bootstrap | Provisioned out-of-band |
| **Database Schema Owner Password**| `SPOOL_DB_OWNER_PASSWORD` | `spool-dev-owner-pw` | DDL schema migration role password | `csi-spl-hub-db-dsn-owner` |
| **Database Runtime Password** | `SPOOL_DB_RUNTIME_PASSWORD` | `spool-dev-runtime-pw` | DML application connection password | `csi-spl-hub-db-dsn-runtime` |
| **Session Encryption Key** | `SPOOL_AUTH_SESSION_KEY` | `0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef` (32-byte hex) | AES-GCM browser session cookie cipher | `csi-spl-hub-auth-session-key` |
| **S3 Storage Access Key ID** | `SPOOL_S3_ACCESS_KEY` | `spool-dev-s3-access-key` | SeaweedFS / MinIO S3 authentication | Cloud IAM / Secret Manager |
| **S3 Storage Secret Access Key** | `SPOOL_S3_SECRET_KEY` | `spool-dev-s3-secret-key-1234567890` | SeaweedFS / MinIO S3 signing key | Cloud IAM / Secret Manager |
| **Mock IdP Client Secret** | `SPOOL_OAUTH_DEV_SECRET` | `spool-dev-oauth-client-secret` | Mock Google/LinkedIn client secret | `csi-spl-hub-auth-*-client-secret` |
| **JWT Verification Secret** | `SPOOL_JWT_SECRET` | `spool-dev-jwt-signing-secret-key-xyz` | Ephemeral token verification | `csi-spl-hub-jwt-secret` |

### 3.2 Anti-Leak Startup Guard (Fail-Fast Refusal in Dev / Prd)

Under no circumstances may any default developer secret be used in `dev` or `prd` environments. An automated startup guard is integrated directly into the hub configuration validation pipeline (`internal/config/config.go` and `cmd/spool/hub.go`):

```go
// Anti-Leak Guard Logic:
var devDefaultSecrets = map[string]string{
    "SPOOL_DB_SUPERUSER_PASSWORD": "spool-dev-superuser-pw",
    "SPOOL_DB_OWNER_PASSWORD":     "spool-dev-owner-pw",
    "SPOOL_DB_RUNTIME_PASSWORD":   "spool-dev-runtime-pw",
    "SPOOL_AUTH_SESSION_KEY":      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "SPOOL_S3_ACCESS_KEY":         "spool-dev-s3-access-key",
    "SPOOL_S3_SECRET_KEY":         "spool-dev-s3-secret-key-1234567890",
    "SPOOL_OAUTH_DEV_SECRET":      "spool-dev-oauth-client-secret",
    "SPOOL_JWT_SECRET":            "spool-dev-jwt-signing-secret-key-xyz",
}

func ValidateProductionSecrets(env string, activeSecrets map[string]string) error {
    if env == "prd" || env == "dev" {
        for key, defaultValue := range devDefaultSecrets {
            if activeSecrets[key] == defaultValue {
                return fmt.Errorf("FATAL: detected default dev credential for %s in %s environment; refusing startup", key, env)
            }
        }
    }
    return nil
}
```

- **Enforcement**: If `SPOOL_HUB_ENV` is set to `prd` or `dev` and any active secret matches a known dev default value, the process terminates immediately with an exit code of `1` and outputs the fatal error message.
- **Verification**: Covered by unit test `internal/config/config_leak_test.go` asserting refusal across all 8 keys.

---

## 4. The Stranger-Proof One-Liner & Prerequisite Checks (Owner Request 08:2xZ)

Owner HUM-10 instructed that "a person not knowing anything of the system would be able to just run the one liner and get some kind of error msg if he is missing some binaries etc. and just get it work" (msg `6b8bf9c3`).

### 4.1 The Command
From a fresh clone of the repository:
```bash
./run -a do_dev_mode_up
```
*(Or via direct script `./spool-dev.sh up`)*

### 4.2 Sequential Prerequisite Check Pipeline

The preflight script executes before any Docker command, network download, or build step. Checks run in strict sequence. If any check fails, execution halts immediately with a clear, human-readable error message indicating the missing item and the exact copy-paste command to resolve it across all major operating systems.

| Sequence | Prerequisite | Verification Command & Condition | Plain Error Message | Fix Command (Ubuntu/Debian) | Fix Command (macOS) | Fix Command (Fedora/RHEL) |
|---|---|---|---|---|---|---|
| **1** | **OS & Arch** | `uname -s` in `(Linux, Darwin)` && `uname -m` in `(x86_64, aarch64, arm64)` | `ERROR: Unsupported operating system or CPU architecture. Spool local dev requires Linux or macOS (x86_64 or arm64).` | Upgrade OS / run on supported Linux VM | Upgrade macOS / run on supported hardware | Upgrade OS / run on supported Linux VM |
| **2** | **Git CLI** | `command -v git >/dev/null && git --version` (>= 2.30) | `ERROR: Git is not installed or version is older than 2.30.` | `sudo apt-get update && sudo apt-get install -y git` | `brew install git` | `sudo dnf install -y git` |
| **3** | **Docker Engine** | `command -v docker >/dev/null && docker info >/dev/null 2>&1` | `ERROR: Docker engine is not running or current user lacks docker permissions.` | `sudo systemctl start docker && sudo usermod -aG docker $USER` | `open -a Docker` (Start Docker Desktop) | `sudo systemctl start docker && sudo usermod -aG docker $USER` |
| **4** | **Docker Compose v2** | `docker compose version` returns `Docker Compose version v2.*` (>= 2.20.0) | `ERROR: Docker Compose v2 plugin is missing or older than v2.20.0.` | `sudo apt-get install -y docker-compose-plugin` | `brew install docker-compose` | `sudo dnf install -y docker-compose-plugin` |
| **5** | **Free Disk Space** | `df -PB 1G . \| awk 'NR==2 {print $4}'` >= 5 | `ERROR: Insufficient disk space. Spool local dev requires at least 5 GB of free disk space.` | `docker system prune -f` (Free up disk space) | `docker system prune -f` (Free up disk space) | `docker system prune -f` (Free up disk space) |
| **6** | **Available RAM** | Free memory >= 2048 MB (`/proc/meminfo` or `sysctl hw.memsize`) | `ERROR: Insufficient system memory. Spool local dev requires at least 2 GB of available RAM.` | Close unused applications | Increase Docker Desktop memory allocation | Close unused applications |
| **7** | **Free Ports** | Ports `8080`, `5432`, `9000`, `8025`, `1025` not bound on `127.0.0.1` | `ERROR: Port <PORT> is already bound by another service on this machine.` | `sudo lsof -i :<PORT> -sTCP:LISTEN` (Inspect and stop conflicting service) | `lsof -i :<PORT> -sTCP:LISTEN` (Inspect and stop conflicting service) | `sudo ss -tulpn \| grep :<PORT>` (Inspect and stop conflicting service) |

### 4.3 Prerequisite Test Matrix
To guarantee that the one-liner satisfies the owner's requirement, an automated test script (`csi-spl-orc/src/bash/tests/test-dev-preflight.tst.sh`) executes against clean test containers, systematically withholding one prerequisite at a time:
- Scenario A: Docker absent -> verifies error message matches row 3, exits `65`.
- Scenario B: Docker Compose v1 present -> verifies error message matches row 4, exits `65`.
- Scenario C: Port 8080 occupied -> verifies error message matches row 7 naming port 8080, exits `65`.
- Scenario D: Disk space constrained (< 5 GB) -> verifies error message matches row 5, exits `65`.
- Scenario E: All prerequisites satisfied -> exits `0` and proceeds to container launch.

---

## 5. End-to-End Acceptance Test Scenario

The entire developer journey is validated against a clean machine or isolated container:

### Scenario Walkthrough

```
1. FRESH CLONE
   git clone https://github.com/csitea/csi-spl.git && cd csi-spl

2. ONE-LINER STARTUP
   ./run -a do_dev_mode_up
   -> Preflight validates environment (all 7 checks pass).
   -> SeaweedFS S3, Postgres 16, Mailpit, and FakeIdP start and pass healthchecks.
   -> hub-init runs migrations, seeds DML runtime user, creates tenant 'main', exits 0.
   -> hub starts under SPOOL_CLOUD_PROVIDER=none; passes healthcheck.
   -> web (Caddy) starts and publishes 127.0.0.1:8080.

3. OFFLINE VERIFICATION
   sudo ip link set dev eth0 down (or block outbound WAN)
   -> Outbound traffic blocked; stack remains 100% operational.

4. HEALTH & VERSION PROBE
   curl -fsS http://127.0.0.1:8080/version
   -> Returns HTTP 200 OK with local version metadata.

5. WUI ONBOARDING & SIGN-IN
   Open http://localhost:8080 in browser.
   -> First user sign-in automatically claims owner seat (SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true).
   -> Email verification sent via local Mailpit.
   -> Developer opens http://localhost:8025, clicks verification link, signs in.

6. CHANNEL POST & WEBSOCKET BROADCAST
   Post message "Hello Spool local dev mode" into #lobby (task_id: 00000000-0000-4000-8000-000000000001).
   -> Message persists in local Postgres.
   -> Live WebSocket connection broadcasts update to WUI in real time.

7. ATTACHMENT UPLOAD & S3 VERIFICATION
   Upload attachment file (e.g. diagram.png).
   -> Hub uploads payload to SeaweedFS S3 bucket spool-files.
   -> File can be downloaded back via WUI and matches SHA256 checksum.

8. TEARDOWN
   ./run -a do_dev_mode_down --purge
   -> All containers stop and are removed.
   -> Volumes are purged.
   -> Host ports 8080, 5432, 9000, 8025, 1025 are completely freed.
```

---

## 6. Rollout Plan (Build Rows)

The implementation is broken down into eight independent, disjoint build rows suitable for small, isolated lanes:

| Row | Area | Deliverable / Task | Affected Files | Verification Command |
|---|---|---|---|---|
| **B1** | `orc` | Preflight check script & error handlers | `csi-spl-orc/src/bash/scripts/dev-preflight.sh` | `bash csi-spl-orc/src/bash/tests/test-dev-preflight.tst.sh` |
| **B2** | `docker` | Mailpit container integration | `csi-spl-orc/src/docker/docker-compose-mail.yaml` | `docker compose -f ... up -d mail && nc -zv 127.0.0.1 1025` |
| **B3** | `api` | FakeIdP standalone runner & container | `csi-spl-api/src/docker/fakeidp.Dockerfile`, `cmd/fakeidp/main.go` | `go test ./src/go/spool-hub-api/internal/auth/fakeidp/...` |
| **B4** | `api` | Parameterized secrets & anti-leak startup guard | `csi-spl-api/src/go/spool-hub-api/internal/config/config.go` | `go test ./src/go/spool-hub-api/internal/config/... -run TestValidateProductionSecrets` |
| **B5** | `orc` | Unified compose file for dev mode | `docker-compose.dev.yml` (or `docker-compose.yml` overlay) | `docker compose -f docker-compose.dev.yml config` |
| **B6** | `orc` | Shell wrapper actions `do_dev_mode_up` and `down` | `csi-spl-orc/src/bash/run/dev-mode-ctl.func.sh` | `./run -a do_dev_mode_up && ./run -a do_dev_mode_down` |
| **B7** | `wui` | WUI local dev helpers (Mailpit link, dev login selector) | `csi-spl-wui/src/components/DevToolbar.vue` | `pnpm --dir csi-spl-wui test:unit` |
| **B8** | `doc` | Developer onboarding documentation & quickstart guide | `csi-spl-doc/doc/md/local-dev-mode-guide.md` | `./run -a do_check_dist_hygiene` |

---

## 7. Open Questions for Owner HUM-10 (Max 3)

The following three architectural decisions are submitted to owner HUM-10 for steering:

1. **Q1: Mail Catcher Visual UI vs Stdout Stream**:
   - *Option A (Recommended)*: Embed Mailpit (`axllent/mailpit`) in compose, publishing port 8025 so developers can visually inspect HTML emails, verification links, and password resets in a real web UI.
   - *Option B*: Keep stdout logging (`SPOOL_HUB_MAIL_TRANSPORT=log`) with debug tokens in JSON responses (`SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=true`), avoiding an extra container at the cost of visual email preview.

2. **Q2: Social Authentication Stand-in Strategy**:
   - *Option A (Recommended)*: Embed the in-tree `fakeidp` service into compose, allowing developers to test real OAuth redirect flows (Google, Microsoft, LinkedIn) using local mock profiles.
   - *Option B*: Provide an instant "One-Click Dev Login" button in the WUI dev toolbar that immediately mints an authenticated session as the workspace owner, bypassing the OAuth handshake entirely.

3. **Q3: Compose Topology File Layout**:
   - *Option A (Recommended)*: Maintain a dedicated `docker-compose.dev.yml` file optimized for local development (including Mailpit and FakeIdP), while keeping root `docker-compose.yml` dedicated to minimal production self-hosting.
   - *Option B*: Merge dev stand-ins into the root `docker-compose.yml` using Docker Compose profiles (`--profile dev`).

---

<!-- version: 0.1.0 · updated: 2026-10-20 · last-edit: 2026-10-20T02:36:00Z -->
