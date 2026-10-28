# 148: local dev mode (single docker-compose developer stack for spool-hub)

**Feature ID**: `148-local-dev-mode` · **Milestone**: M3 · **Status**: Planned (Spec Only) · **Version**: 0.2.0
**Created**: 2026-10-20 · **Epic**: SPL-2400 · **Issue**: SPL-2645 · **Lane**: a-623-c002-spec148-owner-decisions-v02
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

6. **Owner HUM-10, topic `fe5d70de`, msg `d0a66b04` (06:4xZ, Q1 steering, verbatim, binding)**:
   > "Mail in local dev mode? mailpit , but the solution should be such that the developer must be able to test all of the scenarios for login - except those requiring cloud providers"

7. **Owner HUM-10, topic `fe5d70de`, msg `5ae83885` (06:4xZ, Q2 steering, verbatim, binding)**:
   > "Answer 2: B — A one-click "Dev login" button that signs you straight in as the workspace owner"

8. **Owner HUM-10, topic `fe5d70de`, msg `278101e9` (06:4xZ, Q3 steering, verbatim, binding)**:
   > "Answer 3: B — One docker-compose.yml with a "dev" profile"

### Core Principles

1. **P1: The 'Local' Provider of Spec 076 on Root Compose**: This specification defines the developer-facing implementation of the `none` / `local` provider designed in [spec 076 §5](../076-cloud-layer/spec.md#5-phase-1-provider-none-self-host-on-compose) and the single-machine execution path P1 in [spec 072 §3](../072-rapid-deployability/spec.md#3-who-deploys-and-on-what). The stack operates via ONE root `docker-compose.yml` leveraging Docker Compose profiles (`--profile dev`) to activate dev-only containers and configurations without file duplication or configuration drift.
2. **P2: Stranger-Proof One-Liner**: A developer with zero prior knowledge of Spool internals can execute a single command from a clean repository clone (`./run -a do_dev_mode_up`). Before starting any container or build, the command validates every system prerequisite and prints a plain, actionable error naming the exact installation command if any prerequisite is missing.
3. **P3: Parameterized Default Secrets with Production Refusal**: Local development requires zero manual credential generation. Working developer-safe default secrets are provided for all components (database, session signing, object storage). Every secret is parameterized via environment variables. To prevent security incidents, an automated startup assertion refuses to start if any default dev secret is detected in `dev` or `prd` environments.
4. **P4: Instant One-Click Dev Login**: A one-click "Dev login" button signs the developer straight into the application as the workspace owner of the local workspace. It exists strictly in local dev mode and is refused at startup and per-request in `dev` and `prd`. Social sign-in (Google, Microsoft, LinkedIn, Facebook, xAI) is "requires a cloud provider", so it is explicitly out of scope for local dev mode testing.
5. **P5: 100% Offline Mailpit & Non-Cloud Login Coverage**: Outbound transactional emails are captured by an embedded Mailpit container (`axllent/mailpit:v1.21` under `--profile dev`). Every login and account lifecycle scenario that does not require a cloud provider (native sign-up, email verification, sign-in, password reset, admin password reset, password change, workspace invitations, and invitation acceptance) is fully testable and automated through Mailpit's REST API (`/api/v1/messages`) without outbound internet access.
6. **P6: Clean Idempotent Lifecycle**: One command to start (`up`), one command to stop (`down`). A teardown with purge leaves no orphaned processes, volumes, or host port bindings.

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
  - The standalone root `docker-compose.yml:85` runs SeaweedFS 4.48 (`weed mini`) with an S3 API on port 9000 under `SPOOL_CLOUD_PROVIDER=none`.
  - Local dev mode standardizes on the S3-compatible service (SeaweedFS) matching the swappable cloud layer (Spec 076) and standalone compose.

#### 2. Relational Persistence (Postgres 16)
- **Cloud Reality**: GCP Cloud SQL for PostgreSQL 16 (`csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf`). In production, Cloud Run connects via Unix socket `/cloudsql/<connection-name>`, and administration actions connect via Cloud SQL Auth Proxy (`spl_sql_proxy_start`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:250` (`tcpDSN.DSN` refuses `/cloudsql/` Unix sockets when `SPOOL_CLOUD_PROVIDER=none`)
  - `csi-spl-api/src/go/spool-hub-api/internal/store/postgres/store.go:1` (Postgres driver via `jackc/pgx/v5`)
  - `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:386` (`spl_sql_proxy_start`)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:25-29` (`pg: image: postgres:16-alpine`, port 55432)
- **What `lde` Does Today**: Fully emulated. Runs `postgres:16-alpine` in compose (`csi-spl-orc/src/docker/docker-compose-rdb.yaml:10`) on port 55432 with direct TCP connection (`postgres://spool:spool_lde_pw@pg:5432/spool?sslmode=disable`).
- **Gaps / What Breaks**: The database container starts cleanly, but schema migrations require initialization. In standalone compose, `hub-init` (`docker-compose.yml:102`) executes `spool init` prior to `hub` starting.

#### 3. Sign-in & Identity (Social Providers vs Native Auth & Dev Login)
- **Cloud Reality**:
  - Social authentication delegates to Google, Microsoft, LinkedIn, Facebook, and xAI OAuth 2.0 / OIDC endpoints (`csi-spl-cnf/csi-spl/all.env.yaml:352`).
  - Production requires public DNS callbacks and registered OAuth client secrets stored in Secret Manager (`csi-spl-hub-auth-google-client-secret`, etc.).
  - Session state is encrypted with a 32-byte AES key (`csi-spl-hub-auth-session-key`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1` (HTTP OAuth handshake and callback handlers)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:1` (native email/password authentication)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native_config.go:87-89` (`SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS` refusal outside `lde`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native_config.go:90-92` (`SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED=false` refusal outside `lde`)
  - `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:489` (`AuthBootstrapOwner` configuration)
  - `csi-spl-wui/src/pages/login.vue:1` (login view rendering social and native buttons)
- **Owner Ruling (msgs d0a66b04, 5ae83885)**:
  - Social sign-in (Google, Microsoft, LinkedIn, Facebook, xAI) **"requires cloud providers"** and is **out of scope** for local testing.
  - Mock IdP (`fakeidp`) is discarded as a compose service.
  - Identity in local dev mode is provided by:
    1. A one-click **Dev login** button that signs you straight into the workspace as workspace owner (owner HUM-10 msg `5ae83885`).
    2. Complete native auth email/password flows testable locally through Mailpit (owner HUM-10 msg `d0a66b04`).

#### 4. Secret Management & Runtime Configuration
- **Cloud Reality**: GCP Secret Manager stores database DSNs, session encryption keys, OAuth secrets, and payment API tokens (`csi-spl-cnf/csi-spl/all.env.yaml:416-520`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:115` (`envSecrets.Secret` reading process environment)
  - `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:354` (`gcloud secrets versions access`)
  - `csi-spl-orc/src/bash/run/spl-secrets-check.func.sh:125` (`gcloud secrets versions list`)
- **What `lde` Does Today**: The hub runtime consumes secrets through environment variables via `envSecrets`. In `lde`, `do_gen_docker_env` generates static `.env` files.
- **Gaps / What Breaks**: Standalone compose reads secret files mounted under `/run/secrets/` (`docker-compose.yml:44-49`). Local dev mode provides parameterized environment variables and default local secret files (`csi-spl-api/src/docker/local-secrets/`) with strict production refusal guards.

#### 5. Mail & Transactional Messaging
- **Cloud Reality**: Cloud Run relies on an external authenticated SMTP relay (e.g. Google Workspace SMTP or SendGrid) to send workspace invitations, account verifications, and password reset links.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:52` (`TLSNone = "none"`, loopback catcher support)
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:61` (`type SMTP struct`)
  - `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:268` (`mailPreflight` pre-startup connectivity check)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:174` (`SPOOL_HUB_MAIL_TRANSPORT: "log"`)
  - `docker-compose.yml:209-218` (`SPOOL_HUB_MAIL_TRANSPORT`, `SPOOL_HUB_MAIL_SMTP_HOST`, etc.)
- **What `lde` Does Today**: `SPOOL_HUB_MAIL_TRANSPORT: "log"`. Outbound emails are printed as structured log lines to stdout.
- **Owner Ruling (msg d0a66b04)**: Embedded Mailpit (`axllent/mailpit:v1.21`) under the `dev` profile. The hub delivers mail via SMTP to `mail:1025` with `TLSNone = "none"`. Developers inspect captured emails visually on `http://localhost:8025`, and integration tests verify delivery and extract tokens via Mailpit's REST API (`/api/v1/messages`).

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
- **What `lde` Does Today**: Standalone compose (`docker-compose.yml:216`) uses Caddy to serve the generated bundle and proxy `/api/*` and `/v1/ws` to the hub on port 8080.
- **Gaps / What Breaks**: None. Caddy remains the web gateway.

#### 8. Push Notifications & Real-Time Events
- **Cloud Reality**: Spool uses native WebSockets (`/api/v1/live`, `/v1/ws`) rather than third-party push notification gateways (FCM, APNs).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/live.go:1` (WebSocket live hub connection)
  - `csi-spl-wui/src/composables/useLiveSocket.ts:1` (WUI WebSocket client)
- **What `lde` Does Today**: Fully functional locally over TCP WebSocket via Caddy proxy.
- **Gaps / What Breaks**: None.

#### 9. Payments & Billing
- **Cloud Reality**: Production workspace upgrades and paid bot seat allocations interact with Stripe API endpoints (`spec 077`).
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/payments/config.go:54` (`EnableFakePay bool`)
  - `csi-spl-api/src/go/spool-hub-api/internal/payments/config.go:137` (assertion enforcing `SPOOL_HUB_ENABLE_FAKE_PAY` only in `lde`/`dev`)
  - `csi-spl-cnf/csi-spl/lde.env.yaml:141` (`SPOOL_HUB_ENABLE_FAKE_PAY: "true"`)
- **What `lde` Does Today**: Emulated via `SPOOL_HUB_ENABLE_FAKE_PAY="true"`. Mock checkout rail activates workspaces without external Stripe calls.
- **Gaps / What Breaks**: None. Local dev mode keeps `SPOOL_HUB_ENABLE_FAKE_PAY="true"`.

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
| **1** | **Object Storage** | GCP Cloud Storage (GCS buckets) | `internal/blob/blob.go:256`, `cmd/spool/hub.go:316` | `fake-gcs-server` on port 54443 | Embedded SeaweedFS S3 on port 9000 | **Working**: standardized on S3 API |
| **2** | **Relational DB** | GCP Cloud SQL Postgres 16 | `internal/cloud/cloud.go:250`, `store.go:1` | Standalone `postgres:16-alpine` | Containerized Postgres 16 with healthcheck | **Working**: fully emulated locally |
| **3** | **Authentication** | Google, LinkedIn, Microsoft OAuth | `internal/auth/handler.go:1`, `native.go:1` | Disabled (`auth_providers: ""`, `auth_native: false`) | **One-Click Dev Login** (workspace owner) + **Native Auth** (testable via Mailpit). Cloud social IdPs out of scope. | **Decided**: Owner msgs `d0a66b04`, `5ae83885`. FakeIdP dropped. |
| **4** | **Secrets** | GCP Secret Manager | `internal/cloud/cloud.go:115`, `spl-cloud-cnf.func.sh:354` | Process env files in `.local/share/` | Parameterized dev defaults in compose + anti-leak guard | **Working**: Parameterized defaults |
| **5** | **Mail** | Authenticated SMTP Relay | `internal/mail/mail.go:52`, `cmd/spool/hub.go:268` | Stdout log transport (`mail: log`) | Local Mailpit container (`--profile dev`, SMTP:1025, Web:8025) | **Decided**: Owner msg `d0a66b04`. Mailpit integrated. |
| **6** | **Compute Metadata** | Cloud Run Metadata Server | `internal/hub/revision.go:27`, `internal/cloud/cloud.go:237` | `noneCompute` (hostname / `SPOOL_VERSION`) | Container hostname / `SPOOL_VERSION` via `noneCompute` | **Working**: Decoupled in Spec 076 |
| **7** | **Web Hosting** | Firebase Hosting CDN | `render-wui-firebase-json.sh:1`, `runtime-config.mjs:1` | `pnpm dev` on port 3000 | Caddy reverse proxy + static bundle on port 8080 | **Working**: Caddy handles routing |
| **8** | **Push / Live** | Cloud Run WebSockets | `internal/hub/live.go:1`, `useLiveSocket.ts:1` | Direct TCP WebSocket connection | Direct WebSocket proxying via Caddy (`/v1/ws`, `/api/v1/live`) | **Working**: Native protocol |
| **9** | **Payments** | Stripe API | `internal/payments/config.go:54,137` | `SPOOL_HUB_ENABLE_FAKE_PAY="true"` | Fake pay rail enabled by default | **Working**: Fake rail operational |
| **10**| **External APIs** | GitHub Docs API, Gandi DNS | `lde.env.yaml:117`, `README.md:42` | Disabled (`""`) | Disabled / Mock endpoints | **Working**: Non-blocking |

---

## 2. Architecture & Docker Compose Topology

Per owner HUM-10 msg `278101e9` ("One docker-compose.yml with a 'dev' profile"), local dev mode uses the **single root `docker-compose.yml`** file with Docker Compose profiles (`docker compose --profile dev up -d`), eliminating configuration duplication and drift.

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
|                               DOCKER COMPOSE: docker compose --profile dev up                         |
|                                                                                                       |
|  ┌──────────────────┐    ┌──────────────────┐    ┌─────────────────────────────────────────────────┐  |
|  │        pg        │    │        s3        │    │                       mail                      │  |
|  │  Postgres 16-alp │    │ SeaweedFS (S3)   │    │            Mailpit Catcher (profile: dev)       │  |
|  │  Port 5432 (TCP) │    │ Port 9000 (S3)   │    │            Port 1025 (SMTP Submission)          │  |
|  └─────────┬────────┘    └────────┬─────────┘    │            Port 8025 (Web UI & REST API)        │  |
|            │                      │              └────────────────────────┬────────────────────────┘  |
|            ▼                      │                                       │                           |
|  ┌──────────────────┐             │                                       │                           |
|  │     hub-init     │             │                                       │                           |
|  │ Migrations & DML │             │                                       │                           |
|  │ Exit 0 on Ready  │             │                                       │                           |
|  └─────────┬────────┘             │                                       │                           |
|            │                      │                                       │                           |
|            ▼                      ▼                                       ▼                           |
|  ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐  |
|  │                                                hub                                              │  |
|  │                        Spool Hub API (spool serve, SPOOL_CLOUD_PROVIDER=none)                   │  |
|  │                        - Port 8080 (Internal)                                                   │  |
|  │                        - Dev Login Endpoint: POST /api/v1/auth/dev-login                        │  |
|  │                        - Native Auth: register, verify, login, reset, invites                   │  |
|  │                        - SMTP Client: delivers to mail:1025 (TLSNone)                           │  |
|  └────────────────────────────────────────────────┬────────────────────────────────────────────────┘  |
|                                                   │                                                   |
|                                                   ▼                                                   |
|  ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐  |
|  │                                                web                                              │  |
|  │                 Caddy Web Gateway (Reverse Proxy /api, /v1/ws -> hub; Serves WUI SPA)          │  |
|  │                 - Published Host Port: 127.0.0.1:8080                                           │  |
|  │                 - DevToolbar: One-Click "Dev Login" Button + "Mailpit Inbox" Link               │  |
|  └─────────────────────────────────────────────────────────────────────────────────────────────────┘  |
+-------------------------------------------------------------------------------------------------------+
```

### 2.1 Storage Stand-in: SeaweedFS S3
Root `docker-compose.yml:85` runs `chrislusf/seaweedfs:4.48` (`weed mini`):
- Fully permissive Apache 2.0 license.
- Memory footprint: ~35 MB.
- Provides standard S3 API on port 9000 (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY_FILE`).
- Automatically creates `spool-files` bucket upon invocation.
- Consumed natively by Go driver `internal/blob/s3.go:64`.

### 2.2 Mail Catcher Stand-in: Mailpit Integration
Mailpit (`axllent/mailpit:v1.21`) is integrated into root `docker-compose.yml` under `profiles: ["dev"]`:
```yaml
  mail:
    image: axllent/mailpit:v1.21
    profiles: ["dev"]
    user: "1000:1000"
    ports:
      - "127.0.0.1:1025:1025"
      - "127.0.0.1:8025:8025"
    networks: [spool]
    restart: unless-stopped
```
- **SMTP Submission Port**: `1025` (consumed by the hub API via `SPOOL_HUB_MAIL_TRANSPORT=smtp`, `SPOOL_HUB_MAIL_SMTP_HOST=mail`, `SPOOL_HUB_MAIL_SMTP_PORT=1025`, `SPOOL_HUB_MAIL_SMTP_TLS=none`).
- **Interactive Web Interface**: `8025` (accessible to the developer at `http://localhost:8025`).
- **REST API**: Exposes `/api/v1/messages` for automated testing of email verification, password reset, and workspace invitation tokens.

### 2.3 Identity Stand-in: One-Click Dev Login & Scope of Local Authentication

#### 2.3.1 Cloud Social Sign-in is Out of Scope
Owner HUM-10 instructed: *"the solution should be such that the developer must be able to test all of the scenarios for login - except those requiring cloud providers"* (msg `d0a66b04`).
- Third-party social authentication (Google, Microsoft, LinkedIn, Facebook, xAI) strictly requires registered OAuth cloud provider applications, client credentials, and registered redirect URIs.
- Consequently, social authentication **requires a cloud provider** and is **explicitly out of scope** for local dev mode testing.
- The mock IdP container (`fakeidp`) is discarded from Docker Compose.

#### 2.3.2 The One-Click Dev Login
Per owner HUM-10 msg `5ae83885` (*"A one-click 'Dev login' button that signs you straight in as the workspace owner"*), local dev mode provides an instant authentication mechanism:
1. **User Experience**: The WUI renders a prominent **Dev login** button in the login interface and DevToolbar when running in local dev mode.
2. **Behavior**: Clicking the button sends a request to `POST /api/v1/auth/dev-login`.
3. **Session Creation**: The hub mints an authenticated session for `dev-owner@spool.local`, automatically assigns the `RoleTenantOwner` role in the default seeded workspace (`main`), issues an AES-GCM signed session cookie (`h.sessionCookie`), and immediately redirects the user into the application as workspace owner.
4. **Strict Production & Dev Anti-Leak Refusal**:
   - The Dev Login endpoint is governed by configuration flag `SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED` (default `false`).
   - Following the existing refusal precedent in `internal/auth/native_config.go:87-89` (`SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS` refusal) and `native_config.go:90-92`:
     ```go
     if c.DevLoginEnabled && (c.Env == "prd" || c.Env == "dev" || c.CloudProvider != "none") {
         return fmt.Errorf("SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED is strictly refused in %q (local dev mode only)", c.Env)
     }
     ```
   - **Startup Assertion**: If `SPOOL_HUB_ENV` is `dev` or `prd`, setting `SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED=true` halts process startup with a fatal exit code `1`.
   - **Per-Request Refusal**: The HTTP handler inspects `s.Env` on every incoming call. In `dev` and `prd`, it returns `404 Not Found`, writes a security warning log (`auth.dev_login_refused_production`), and terminates the connection.

### 2.4 Offline Network Enforcement
Local dev mode operates 100% offline once images are present:
- Containers attach to bridge network `spool`.
- Gateway publishes strictly on `127.0.0.1:8080`.
- All email verification, invite delivery, and password reset flows execute locally via Mailpit on loopback without external network queries.

---

## 3. Parameterized Default Secrets & Anti-Leak Guards (Owner Request 08:1xZ)

Local dev mode ships with working default secrets so that `up` succeeds out of the box with zero manual credential configuration, while every secret remains fully overridable via environment variables.

### 3.1 Secrets Register & Parameter Mappings

| Secret Name / Role | Parameter Name (Env Override) | Local Dev Default Value | Purpose | Production Target (Secret Manager Slot) |
|---|---|---|---|---|
| **Database Superuser Password** | `SPOOL_DB_SUPERUSER_PASSWORD` | Secret file: `spool_db_superuser_password` | Postgres administrative user bootstrap | Provisioned out-of-band |
| **Database Schema Owner Password**| `SPOOL_DB_OWNER_PASSWORD` | `spool-dev-owner-pw` | DDL schema migration role password | `csi-spl-hub-db-dsn-owner` |
| **Database Runtime Password** | `SPOOL_DB_RUNTIME_PASSWORD` | `spool-dev-runtime-pw` | DML application connection password | `csi-spl-hub-db-dsn-runtime` |
| **Session Encryption Key** | `SPOOL_AUTH_SESSION_KEY` | `0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef` (32-byte hex) | AES-GCM browser session cookie cipher | `csi-spl-hub-auth-session-key` |
| **S3 Storage Access Key ID** | `SPOOL_S3_ACCESS_KEY` | `spool-dev-s3-access-key` | SeaweedFS S3 authentication | Cloud IAM / Secret Manager |
| **S3 Storage Secret Access Key** | `SPOOL_S3_SECRET_KEY` | Secret file: `spool_s3_secret_key` | SeaweedFS S3 signing key | Cloud IAM / Secret Manager |
| **JWT Verification Secret** | `SPOOL_JWT_SECRET` | `spool-dev-jwt-signing-secret-key-xyz` | Ephemeral token verification | `csi-spl-hub-jwt-secret` |

### 3.2 Anti-Leak Startup Guard (Fail-Fast Refusal in Dev / Prd)

Under no circumstances may any default developer secret or dev login flag be active in `dev` or `prd`. The validation logic is integrated into `internal/config/config.go` and `cmd/spool/hub.go`, mirroring `internal/auth/native_config.go:87-92`:

```go
var devDefaultSecrets = map[string]string{
    "SPOOL_DB_SUPERUSER_PASSWORD": "spool-dev-superuser-pw",
    "SPOOL_DB_OWNER_PASSWORD":     "spool-dev-owner-pw",
    "SPOOL_DB_RUNTIME_PASSWORD":   "spool-dev-runtime-pw",
    "SPOOL_AUTH_SESSION_KEY":      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "SPOOL_S3_ACCESS_KEY":         "spool-dev-s3-access-key",
    "SPOOL_JWT_SECRET":            "spool-dev-jwt-signing-secret-key-xyz",
}

func ValidateProductionSecrets(env string, activeSecrets map[string]string, devLoginEnabled bool) error {
    if env == "prd" || env == "dev" {
        if devLoginEnabled {
            return fmt.Errorf("FATAL: SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED is strictly forbidden in %s", env)
        }
        for key, defaultValue := range devDefaultSecrets {
            if activeSecrets[key] == defaultValue {
                return fmt.Errorf("FATAL: detected default dev credential for %s in %s environment; refusing startup", key, env)
            }
        }
    }
    return nil
}
```

- **Enforcement**: If `SPOOL_HUB_ENV` is set to `prd` or `dev` and any active secret matches a known dev default value, or `SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED` is true, the process terminates immediately with exit code `1`.
- **Verification**: Unit tests in `internal/config/config_leak_test.go` assert refusal across all dev secrets and the dev login toggle.

---

## 4. The Stranger-Proof One-Liner & Prerequisite Checks (Owner Request 08:2xZ)

Owner HUM-10 instructed that "a person not knowing anything of the system would be able to just run the one liner and get some kind of error msg if he is missing some binaries etc. and just get it work" (msg `6b8bf9c3`).

### 4.1 The Command
From a fresh clone of the repository:
```bash
./run -a do_dev_mode_up
```
Under the hood, the action executes preflight checks, then starts the stack:
```bash
docker compose --profile dev up -d
```

### 4.2 Sequential Prerequisite Check Pipeline

The preflight script (`csi-spl-orc/src/bash/scripts/dev-preflight.sh`) executes before any Docker command or build step. Checks run in strict sequence. If any check fails, execution halts immediately with a clear error message and the exact command to resolve it across all major operating systems:

| Sequence | Prerequisite | Verification Command & Condition | Plain Error Message | Fix Command (Ubuntu/Debian) | Fix Command (macOS) | Fix Command (Fedora/RHEL) |
|---|---|---|---|---|---|---|
| **1** | **OS & Arch** | `uname -s` in `(Linux, Darwin)` && `uname -m` in `(x86_64, aarch64, arm64)` | `ERROR: Unsupported operating system or CPU architecture. Spool local dev requires Linux or macOS (x86_64 or arm64).` | Upgrade OS / run on supported Linux VM | Upgrade macOS / run on supported hardware | Upgrade OS / run on supported Linux VM |
| **2** | **Git CLI** | `command -v git >/dev/null && git --version` (>= 2.30) | `ERROR: Git is not installed or version is older than 2.30.` | `sudo apt-get update && sudo apt-get install -y git` | `brew install git` | `sudo dnf install -y git` |
| **3** | **Docker Engine** | `command -v docker >/dev/null && docker info >/dev/null 2>&1` | `ERROR: Docker engine is not running or current user lacks docker permissions.` | `sudo systemctl start docker && sudo usermod -aG docker $USER` | `open -a Docker` (Start Docker Desktop) | `sudo systemctl start docker && sudo usermod -aG docker $USER` |
| **4** | **Docker Compose v2** | `docker compose version` returns `Docker Compose version v2.*` (>= 2.20.0) | `ERROR: Docker Compose v2 plugin is missing or older than v2.20.0.` | `sudo apt-get install -y docker-compose-plugin` | `brew install docker-compose` | `sudo dnf install -y docker-compose-plugin` |
| **5** | **Free Disk Space** | `df -PB 1G . \| awk 'NR==2 {print $4}'` >= 5 | `ERROR: Insufficient disk space. Spool local dev requires at least 5 GB of free disk space.` | `docker system prune -f` (Free up disk space) | `docker system prune -f` (Free up disk space) | `docker system prune -f` (Free up disk space) |
| **6** | **Available RAM** | Free memory >= 2048 MB (`/proc/meminfo` or `sysctl hw.memsize`) | `ERROR: Insufficient system memory. Spool local dev requires at least 2 GB of available RAM.` | Close unused applications | Increase Docker Desktop memory allocation | Close unused applications |
| **7** | **Free Ports** | Ports `8080`, `5432`, `9000`, `8025`, `1025` not bound on `127.0.0.1` | `ERROR: Port <PORT> is already bound by another service on this machine.` | `sudo lsof -i :<PORT> -sTCP:LISTEN` (Inspect and stop conflicting service) | `lsof -i :<PORT> -sTCP:LISTEN` (Inspect and stop conflicting service) | `sudo ss -tulpn \| grep :<PORT>` (Inspect and stop conflicting service) |

---

## 5. Non-Cloud Login Scenarios & End-to-End Acceptance Test (Owner Request d0a66b04)

Owner HUM-10 explicitly directed that *"the solution should be such that the developer must be able to test all of the scenarios for login - except those requiring cloud providers"* (msg `d0a66b04`).

Every scenario below was measured directly from the repository code. Each scenario operates without external cloud dependencies and is verifiable end to end through Mailpit's REST API (`http://127.0.0.1:8025/api/v1/messages`).

### 5.1 Measured Non-Cloud Login Scenarios

#### Scenario 1: Native Sign-Up & Email Verification Delivery
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:105` (`POST RoutePrefix + "register"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:248-307` (`handleRegister`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:320-356` (`mint` generating crypto token & sending mail)
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:340` (`EmailVerification` template)
- **Flow**: Developer submits `{"email": "user@example.com", "password": "securepassword123", "name": "Test User"}`. Hub creates unverified credential in store, generates a 32-byte hex token (`newToken`), and sends verification email via SMTP `:1025` to Mailpit with link `/verify-email?token=<tok>`. Returns `202 Accepted` with `{"status": "verification_required"}`.
- **Mailpit Verification**: Query `GET http://127.0.0.1:8025/api/v1/messages`. Verify message addressed to `user@example.com` exists. Parse token from the HTML/plain body URL.

#### Scenario 2: Email Verification Token Consumption
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:106` (`POST RoutePrefix + "email/verify"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:363-399` (`handleVerify`)
- **Flow**: Developer submits `{"token": "<extracted_token>", "password": "securepassword123"}`. Hub validates token hash against Postgres store (`store.ConsumeVerification`), confirms password match, and marks credential verified. Returns `204 No Content`. (If password does not match, returns `401 ErrTokInvalidCredentials`; if expired, returns `410 ErrTokVerifyExpired`).

#### Scenario 3: Native Sign-In (Password Authentication)
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:107` (`POST RoutePrefix + "login"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:451-491` (`handleLogin`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:507-534` (`checkPassword`)
- **Flow**: Developer submits `{"email": "user@example.com", "password": "securepassword123"}`. Hub validates Argon2id hash, checks verification status (`cred.Verified()`), binds workspace landing through Registrar (`registerLogin`), issues AES-GCM signed session cookie (`n.h.sessionCookie`), logs activity audit event (`recordAuth`), and returns `200 OK` with session claims, workspace memberships, and user preferences.

#### Scenario 4: Self-Service Password Reset Request (Forgot Password)
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:108` (`POST RoutePrefix + "password/forgot"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:594-625` (`handleForgot`)
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:342` (`PasswordReset` template)
- **Flow**: Developer submits `{"email": "user@example.com"}`. Route answers enumeration-safe `204 No Content`. Hub mints reset token (`TokenReset`) with 1-hour TTL, enforces per-account mail floor, and sends password reset email to Mailpit with link `/reset-password?token=<tok>`.
- **Mailpit Verification**: Query `GET http://127.0.0.1:8025/api/v1/messages`. Verify new message with subject "Reset your password" exists. Extract reset token.

#### Scenario 5: Password Reset Completion & Auto Sign-In
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:109` (`POST RoutePrefix + "password/reset"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:674-712` (`handleReset`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:722-757` (`signInAfterReset`)
- **Flow**: Developer submits `{"token": "<reset_token>", "password": "newpassword456"}`. Hub verifies token (`ConsumeReset`), updates credential with new Argon2id hash, revokes all prior sessions (`RevokeSessions`), sets new session cookie, and signs the user straight into the app, returning `200 OK` with session response.

#### Scenario 6: Workspace Admin Member Password Reset
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/member_password_reset.go:15-145` (`POST /v1/members/{human_id}/password-reset`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/admin_reset.go:58-120` (`AdminPasswordReset`)
- **Flow**: Signed-in workspace admin triggers password reset for member. Hub verifies caller role (`members.invite`), invalidates member's existing password with a random dummy hash, revokes member's active sessions, mints a reset token, and sends password reset link to member's email via Mailpit.
- **Mailpit Verification**: Inspect Mailpit inbox to confirm member received the reset link.

#### Scenario 7: Authenticated Password Change
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:110` (`POST RoutePrefix + "password/change"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:764-804` (`handleChange`)
- **Flow**: Authenticated user submits `{"current_password": "newpassword456", "new_password": "finalpassword789"}`. Hub checks active session, verifies current password, updates store with new hash, clears session cookie (`MaxAge: -1`), and returns `204 No Content`. Subsequent requests with old cookie return `401 Unauthorized`.

#### Scenario 8: Workspace Invitation & Delivery
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/rbac.go:323-375` (`POST /v1/members/invites`)
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/rbac.go:552` (route registration)
  - `csi-spl-api/src/go/spool-hub-api/internal/store/humans_postgres.go:584` (`INSERT INTO tenant_invites`)
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/server.go:191` (`s.mailInvite`)
- **Flow**: Workspace admin posts `{"email": "colleague@example.com", "role": "developer"}`. Hub records invitation in `tenant_invites` and delivers an invitation email containing the workspace join URL to Mailpit. Returns `201 Created` with `{"mail": "sent"}`.
- **Mailpit Verification**: Query Mailpit REST API to verify invitation email was delivered to `colleague@example.com`.

#### Scenario 9: Workspace Invitation Acceptance (Landing via Register or Login)
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:414-427` (`registerLanding`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:540-564` (`registerLogin`)
  - `csi-spl-api/src/go/spool-hub-api/internal/store/humans_postgres.go:317, 488` (`UPDATE tenant_invites SET accepted_at ...`)
  - `csi-spl-api/src/go/spool-hub-api/internal/store/invite_landing.go:36` (`SELECT i.tenant_id FROM tenant_invites`)
- **Flow**: Invitee signs up or logs in with `colleague@example.com`. Hub's `registerLanding` inspects pending invites for that email, admits human to the inviting workspace, creates membership, marks invite accepted in Postgres, and binds the workspace into the issued session cookie.

#### Scenario 10: Session Validation & Introspection
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:289` (`GET RoutePrefix + "session"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:596-648` (`session`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1565-1581` (`SessionFromRequest`)
- **Flow**: Client sends request with session cookie. Hub decrypts and verifies AES-GCM token and expiry timestamp, looks up user permissions and workspace memberships, and returns `200 OK` with full user profile and settings. Returns `401 Unauthorized` if session is absent, expired, or invalid.

#### Scenario 11: Active Workspace Switch
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/tenant.go:200-260` (`switchTenant`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/tenant.go:275` (`POST RoutePrefix + "tenant"`)
- **Flow**: User belonging to multiple workspaces posts `{"tenant": "<target_workspace_id>"}`. Hub validates membership, updates last active timestamp, issues refreshed session cookie bound to the target workspace, and returns `200 OK`.

#### Scenario 12: Sign-Out (Logout)
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:293` (`POST RoutePrefix + "logout"`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1553-1561` (`logout`)
- **Flow**: Client posts to logout route. Hub logs `sign_out` event in user activity audit, sets session cookie `MaxAge: -1` to clear cookie from browser, and returns `204 No Content`.

#### Scenario 13: Session Expiry & Revocation Enforcement
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1574-1579` (expiry check in `SessionFromRequest`)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/revoke.go:32` (`RevokeSessions`)
- **Flow**: Protected endpoints reject any session token where `time.Now() > s.Exp` with `401 Unauthorized`. Any token issued prior to a password reset or admin revocation is caught by `h.revoked.dead(ctx, s, now)` and rejected.

#### Scenario 14: First-User Bootstrap Workspace Owner
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:489` (`AuthBootstrapOwner`)
  - `docker-compose.yml:20-22` (`SPOOL_BOOTSTRAP_OWNER=auto`)
- **Flow**: On a fresh stack, the first user to register and verify email automatically claims the owner seat (`RoleTenantOwner`) of default workspace `main`.

#### Scenario 15: Federated Account Password Reset Notice Mail
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:627-666` (`forgotFederated`)
  - `csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go:656` (`FederatedSignIn` template)
- **Flow**: If a password reset is requested for an email associated with an external IdP (e.g. imported account), the hub sends an informational email via Mailpit advising the user to sign in using their external provider.

---

### 5.2 Acceptance Walkthrough

```
1. PREFLIGHT & BOOTSTRAP
   ./run -a do_dev_mode_up
   -> Validates 7 prerequisites (OS, Git, Docker, Compose v2, Disk, RAM, Ports).
   -> Starts root compose: docker compose --profile dev up -d
   -> Containers start: pg (5432), s3 (9000), mail (1025/8025), hub-init, hub (8080), web (8080).
   -> hub-init runs DDL migrations, seeds tenant 'main', exits 0.

2. ONE-CLICK DEV LOGIN
   Open http://localhost:8080.
   -> Click "Dev login" button.
   -> Hub mints owner session for dev-owner@spool.local in workspace 'main'.
   -> Browser lands inside workspace lobby with full administrative privileges.

3. OFFLINE VERIFICATION
   Block outbound gateway traffic (or disconnect internet).
   -> Stack remains 100% operational; all assets served locally.

4. AUTOMATED LOGIN SCENARIOS WALKTHROUGH
   Run automated test suite:
   bash csi-spl-orc/src/bash/scripts/dev-mailpit-scenarios.sh
   -> Scenario 1: POST /register user@example.com -> Mailpit receives verification email.
   -> Scenario 2: Extracts token from Mailpit /api/v1/messages; POST /email/verify -> 204 OK.
   -> Scenario 3: POST /login user@example.com -> 200 OK + session cookie.
   -> Scenario 4: POST /password/forgot -> Mailpit receives reset email.
   -> Scenario 5: Extracts token; POST /password/reset -> 200 OK (auto sign-in).
   -> Scenario 6: POST /password/change -> 204 OK; old cookie invalidated.
   -> Scenario 7: POST /v1/members/invites colleague@example.com -> Mailpit receives invite.
   -> Scenario 8: Register colleague@example.com -> lands directly in workspace 'main'.
   -> Scenario 9: POST /tenant switch -> switches workspace cleanly.
   -> Scenario 10: POST /logout -> 204 OK; session terminated.

5. TEARDOWN
   ./run -a do_dev_mode_down --purge
   -> Containers stopped and removed.
   -> Volumes purged.
   -> Host ports 8080, 5432, 9000, 8025, 1025 completely freed.
```

---

## 6. Rollout Plan (Build Rows)

The implementation is broken down into nine independent, strictly disjoint build rows. No two rows touch the same file:

| Row | Area | Deliverable / Task | Affected Files | Verification Command |
|---|---|---|---|---|
| **B1** | `orc` | Preflight check script & error handlers | `csi-spl-orc/src/bash/scripts/dev-preflight.sh` | `bash csi-spl-orc/src/bash/tests/test-dev-preflight.tst.sh` |
| **B2** | `cnf` | Parameterized environment defaults and Mailpit integration variables | `.env.example` | `grep -E "SPOOL_MAIL_SMTP_HOST|mailpit" .env.example` |
| **B3** | `api` | One-click Dev-login hub endpoint (`POST /api/v1/auth/dev-login`) & strict dev/prd anti-leak guard | `csi-spl-api/src/go/spool-hub-api/internal/auth/dev_login.go` | `go test ./src/go/spool-hub-api/internal/auth/... -run TestDevLogin` |
| **B4** | `api` | Parameterized secrets & anti-leak startup guard | `csi-spl-api/src/go/spool-hub-api/internal/config/config.go` | `go test ./src/go/spool-hub-api/internal/config/... -run TestValidateProductionSecrets` |
| **B5** | `docker` | Root compose dev profile (`--profile dev`) for Mailpit and dev overrides | `docker-compose.yml` | `docker compose --profile dev config` |
| **B6** | `orc` | Shell wrapper actions `do_dev_mode_up` and `down` | `csi-spl-orc/src/bash/run/dev-mode-up.func.sh`, `csi-spl-orc/src/bash/run/dev-mode-down.func.sh`, `csi-spl-orc/src/bash/run/dev-mode-ctl.func.sh` | `./run -a do_dev_mode_up && ./run -a do_dev_mode_down` |
| **B7** | `wui` | WUI local dev helpers (Dev-login button + Mailpit mailbox link) | `csi-spl-wui/src/components/DevToolbar.vue` | `pnpm --dir csi-spl-wui test:unit` |
| **B8** | `doc` | Developer onboarding documentation & quickstart guide | `csi-spl-doc/doc/md/local-dev-mode-guide.md` | `./run -a do_check_dist_hygiene` |
| **B9** | `test` | Automated end-to-end integration test walking all non-cloud login scenarios via Mailpit REST API | `csi-spl-orc/src/bash/scripts/dev-mailpit-scenarios.sh` | `bash csi-spl-orc/src/bash/scripts/dev-mailpit-scenarios.sh` |

---

## 7. Open Questions for Owner HUM-10 (Decided)

The three architectural questions submitted to owner HUM-10 in v0.1.0 are fully decided and binding:

1. **Q1: Mail Catcher Visual UI vs Stdout Stream**:
   - *Option A (Recommended)*: Embed Mailpit (`axllent/mailpit`) in compose, publishing port 8025 so developers can visually inspect HTML emails, verification links, and password resets in a real web UI.
   - *Option B*: Keep stdout logging (`SPOOL_HUB_MAIL_TRANSPORT=log`) with debug tokens in JSON responses (`SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=true`), avoiding an extra container at the cost of visual email preview.
   - **DECIDED: Option A (Mailpit) + the login-scenario rule** (owner msg `d0a66b04`: *"Mail in local dev mode? mailpit , but the solution should be such that the developer must be able to test all of the scenarios for login - except those requiring cloud providers"*). Embed `axllent/mailpit:v1.21` in root compose under `profiles: ["dev"]`. All non-cloud login scenarios must be testable locally through Mailpit.

2. **Q2: Social Authentication Stand-in Strategy**:
   - *Option A (Recommended)*: Embed the in-tree `fakeidp` service into compose, allowing developers to test real OAuth redirect flows (Google, Microsoft, LinkedIn) using local mock profiles.
   - *Option B*: Provide an instant "One-Click Dev Login" button in the WUI dev toolbar that immediately mints an authenticated session as the workspace owner, bypassing the OAuth handshake entirely.
   - **DECIDED: Option B (One-Click Dev Login)** (owner msg `5ae83885`: *"Answer 2: B — A one-click "Dev login" button that signs you straight in as the workspace owner"*). `fakeidp` is discarded as a compose service. A one-click Dev Login button signs the developer straight into the workspace as workspace owner. Social sign-in requiring cloud providers (Google, Microsoft, LinkedIn, Facebook, xAI) is explicitly out of scope for local dev mode.

3. **Q3: Compose Topology File Layout**:
   - *Option A (Recommended)*: Maintain a dedicated `docker-compose.dev.yml` file optimized for local development (including Mailpit and FakeIdP), while keeping root `docker-compose.yml` dedicated to minimal production self-hosting.
   - *Option B*: Merge dev stand-ins into the root `docker-compose.yml` using Docker Compose profiles (`--profile dev`).
   - **DECIDED: Option B (One docker-compose.yml with a "dev" profile)** (owner msg `278101e9`: *"Answer 3: B — One docker-compose.yml with a "dev" profile"*). No separate `docker-compose.dev.yml`. All local dev containers and overrides live in root `docker-compose.yml` gated behind `--profile dev`.

---

<!-- version: 0.2.0 · updated: 2026-10-20 · last-edit: 2026-10-20T14:15:00Z -->
