# Feature Specification: Spool Security Hardening & Threat Mitigation

**Feature ID**: `017-spool-security-hardening` · **Milestone**: M3/M4 Consolidation · **Status**: Partial
**Created**: 2026-09-19 · **Lane**: SECURITY · **Owner ask**: Comprehensive IT security analysis & remediation spec
**Builds on**: `001-relay-bucket-estate`, `002-box-agent-messaging`, `003-spool-message-bus`, `004-spool-identity-routing`, `006-spool-hub-rental`, `007-spool-hub-api-infra`, `010-spool-social-auth`, `014-spool-wui-dispatch`, `015-spool-native-auth`.
**Authority**: `./contracts/security-baseline.md`

Status vocabulary follows `../README.md` §2.3: **Implemented** (cited), **Partial** (missing part named), **Planned**.

---

## 0. Executive Summary & Security Posture

The `csi-spl` system implements a federated agent message spool across GCP cloud infrastructure (`csi-spl-hub`)
and local machine execution environments (`box`). Cryptographic identity relies on Ed25519 asymmetric signatures,
tenant root keys, Argon2id credentials, and HMAC-SHA256 session state.

This specification identifies vulnerabilities, structural design trade-offs, and compliance gaps across the
estate, establishing actionable hardening requirements to elevate `csi-spl` to an enterprise security baseline.

---

## 1. Threat Model & Key Attack Vectors

### 1.1 Host-Level Spool Permissions & Multi-Tenant Agent Isolation
- **Condition:** In `csi-spl-cnf/csi-spl/all.env.yaml` and `provision-spool-root.func.sh`, `/var/spool-hub` is
  provisioned with `mode 2777` with the POSIX sticky bit explicitly stripped (`chmod -t`) and default ACLs set to `o::rwx`.
- **Threat:** Any unprivileged local user, service account, or compromised container on the box can read,
  modify, truncate, or delete messages in any agent's spool directory. Because local messages are unsigned (`002`),
  an adversary on the host can forge commands to executing agents, resulting in local privilege escalation.
- **Remediation Requirement:** (FR-SEC-001) Enforce a dedicated OS group (e.g. `spool-agents`) for agent processes,
  restore POSIX sticky bit (`+t`) or set `other` permissions to `---` (`mode 2770`), and implement directory-per-agent
  discretionary access controls.

### 1.2 Unauthenticated Content-Addressed Blob Access (`GET /v1/files/{file_id}`)
- **Condition:** The `GET /v1/files/{file_id}` endpoint relies strictly on knowledge of the SHA-256 hash
  as a capability URL without requiring tenant authentication or session tokens.
- **Threat:** While SHA-256 has 256 bits of entropy, file hashes appear in plaintext HTTP logs, proxy traces,
  referrer headers, browser history, and WUI client state. Anyone possessing a valid tenant host and SHA-256 hash
  can download confidential attachments across the public internet.
- **Remediation Requirement:** (FR-SEC-002) Require either a signed view token, active member session cookie, or
  box upload token for `GET /v1/files/{file_id}`, while retaining content addressing for deduplication.

### 1.3 Plaintext Tenant Root Key Transmission via SMTP
- **Condition:** In `internal/payments/handler.go`, upon tenant checkout claim, the tenant's master Ed25519
  private key is returned in API plaintext and transmitted via standard outbound SMTP email (`TenantWelcome`).
- **Threat:** Email transit across intermediate MTAs and mailbox storage is susceptible to interception and
  compromise. Possession of the tenant root private key grants absolute control over tenant box pinning and revocation.
- **Remediation Requirement:** (FR-SEC-003) Provide web-only zero-knowledge key generation where the private key
  is rendered strictly once in the browser interface; email notifications must contain only the tenant URL and setup
  instructions, never the raw private seed.

### 1.4 Public Cloud Armor Ingress Policy (`0.0.0.0/0`) & Connection Exhaustion
- **Condition:** Cloud Armor allows `0.0.0.0/0` in dev and prd as an M1 exception. Cloud Run runs with
  `max_instances=1` and `concurrency=1000`.
- **Threat:** A slowloris or distributed connection exhaustion attack targeting WebSocket `/v1/ws` or `/v1/wui/ws`
  can exhaust the 1,000 concurrent connection limit of the single instance, causing complete denial of service.
- **Remediation Requirement:** (FR-SEC-004) Restore CIDR restriction or Cloud Armor rate limiting rules on
  connection initiations (`SRC_IPS_V1` rate-based bans) and implement hub-level per-IP WebSocket connection quotas.

### 1.5 Frontend Content Security Policy (CSP) Hardening
- **Condition:** In `firebase.json`, CSP includes `'unsafe-inline'` in `script-src` and `style-src`, while
  `connect-src` only allows `127.0.0.1` and `localhost`.
- **Threat:** `'unsafe-inline'` diminishes resistance against DOM-based XSS attacks.
- **Remediation Requirement:** (FR-SEC-005) Transition to nonce-based or hash-based CSP, eliminate `'unsafe-inline'`,
  and parameterize `connect-src` with production API host patterns during build and deployment.

### 1.6 Distributed Rate Limiting & Proxy Header Trust
- **Condition:** Native auth rate limiting (`internal/auth/ratelimit.go`) is held in-process memory (`limiter`)
  and defaults to `TrustedProxyHops: 0`.
- **Threat:** Multi-instance scaling or container restarts reset rate limits. Incorrect proxy hops cause the
  hub to evaluate internal Google Cloud proxy IPs rather than the true client IP.
- **Remediation Requirement:** (FR-SEC-006) Store persistent rate counters or integrate Cloud Armor security
  policies for brute-force protection, and pin `TrustedProxyHops` in configuration to match the exact proxy topology.

### 1.7 Tenant Isolation Rests on One Go `WHERE` Clause (SEC-08)
- **Condition:** Every tenant-scoped table carries `tenant_id` (rdb 0001 FR-015), but isolation is enforced only by
  `WHERE tenant_id = $1` in `internal/store/*_postgres.go`. The hub's database login owns the tables it queries
  (`spool migrate` runs under the same DSN), so nothing in Postgres stops a query that forgets that clause.
- **Threat:** One missing predicate, whether a new view query, a refactor or a copy-pasted JOIN, returns or mutates
  every tenant's messages, pins or members. No test catches it, because every test tenant sees its own rows either way.
- **Remediation Requirement:** (FR-SEC-013) Add Postgres row level security as defense in depth, keyed on a
  transaction-local tenant setting, and give the cross-tenant jobs a narrow, explicit path of their own.

---

## 2. Functional Requirements (FR-SEC)

- **FR-SEC-001 (Host Spool DAC):** Host spool provisioning (`do_provision_spool_root`) MUST restrict `/var/spool-hub`
  to authorized agent group members with `chmod 2770` and default ACLs excluding world (`o::---`).
  *Status:* Planned.
  - **Clarified 2026-09-19 (lane SEC-01):** the group is cnf `env.box.spool_root_group`, default `spool-agents`;
    `other` is cnf `env.box.spool_root_other`, default `---`; the root mode is `27<g><o>` derived from it
    (`2770` for `---`). The root stays **not sticky**: the frozen 002 contract (`local-folder-layout.md`) makes an ack
    an atomic rename inbox -> archive of a message ANOTHER user wrote, which a sticky dir forbids to a non-owner.
    Isolation is therefore the group boundary, which is what 002 asks for ("standard Unix user/group boundaries");
    002 fixes `0775` dirs and `0664` files beneath the root and neither changes: an outsider cannot traverse a `2770`
    root, so those modes are no longer world-reachable.
  - Every OS user that runs an agent, or reads or writes the spool (the box owner too), MUST be a member of the
    group. A running process keeps the groups it started with, so members restart their agents / re-login after
    joining.
  - `do_provision_spool_root` never creates the group or changes membership. When the group is missing it leaves an
    EXISTING root untouched (WARN, exit 0: a live box is not broken by a `do_setup_app_inf`) and refuses to make a
    new one.
  - Existing boxes migrate with the named repair action `do_repair_spool_root` (csi-spl-orc): `DRY_RUN=1` by default
    prints the plan; `DRY_RUN=0 SPOOL_ROOT_MEMBERS="<user> ..."` creates the group, adds the members, re-groups the
    tree, sets setgid on every dir, applies the ACL model and verifies it. Run it in a quiet window (no agent mid-send).

- **FR-SEC-002 (File Download Authentication):** `GET /v1/files/{file_id}` MUST require either a valid member session
  or box bearer capability token when `SPOOL_HUB_VIEW_DOOR != off`.
  *Status:* Planned.

- **FR-SEC-003 (Root Key Claim Isolation):** The tenant root private key MUST NOT be transmitted over email.
  `TenantWelcome` email MUST omit the private key string, confining display to a single interactive web claim modal.
  *Status:* Planned.

- **FR-SEC-004 (Edge Rate Limiting & Cloud Armor Hardening):** Cloud Armor security policies MUST enforce rate-limiting
  rules on `/v1/ws`, `/v1/wui/ws`, and `/api/v1/auth/*` before traffic reaches Cloud Run.
  *Status:* Planned.

- **FR-SEC-005 (CSP Nonce & Production Connect-Src):** Firebase Hosting configuration MUST replace `'unsafe-inline'`
  with build-time hashes or nonces and include the production domain and tenant subdomains in `connect-src`.
  *Status:* Planned.

- **FR-SEC-006 (Proxy Hops Configuration):** `SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` MUST be configured in
  `dev.env.yaml` and `prd.env.yaml` to match Cloud Load Balancing + Cloud Run ingress topology.
  *Status:* Planned.

- **FR-SEC-007 (Cryptographic Nonce Validation):** Hello handshake challenge nonces MUST be generated with 256 bits
  of cryptographically secure randomness and validated with constant-time equality comparisons.
  *Status:* Implemented (`internal/hub/ws.go` line 123, `crypto/rand`).

- **FR-SEC-008 (Argon2id Memory Cost Gate):** Native authentication configuration MUST reject any Argon2id memory
  parameter below 19 MiB (`19456 KiB`) in production deployments.
  *Status:* Implemented (`internal/auth/native_config.go` line 77).

- **FR-SEC-009 (Zero Secret State Invariant):** Database DSNs, session keys, and OAuth secrets MUST NOT be written
  into Terraform state files or checked into version control.
  *Status:* Implemented (`040-cloud-sql-postgres`, `030-cloud-run-hub`, `10_ci-quality.yml`).

- **FR-SEC-010 (Postgres Parameterized Queries):** Database queries throughout `internal/store` MUST utilize
  parameterized bindings (`$1, $2, ...`) with zero dynamic string interpolation for identifiers and clauses.
  *Status:* Implemented (`internal/store/postgres.go`).

- **FR-SEC-011 (Workload Identity Federation Pinning):** CI/CD deploy credentials MUST use keyless Workload Identity
  Federation pinned strictly to the repository and trunk branch ref.
  *Status:* Partial (`017-github-wif-deploy` written, awaiting repository variable activation).

- **FR-SEC-012 (Audit Logging & Distribution Hygiene):** Server middleware MUST emit structured JSON logs withholding
  sensitive tokens, queries, and credentials, adhering to repo distribution hygiene standards.
  *Status:* Implemented (`internal/hub/server.go` line 365, `10_ci-quality.yml`).

---

- **FR-SEC-013 (Postgres Row Level Security):** Every table that carries `tenant_id` (`tenants`, `boxes`, `pins`,
  `pins_history`, `roster`, `messages`, `deliveries`, `channels`, `channel_subscriptions`, `tenant_memberships`,
  `tenant_invites`, `payment_checkouts`) MUST have `ENABLE` and `FORCE ROW LEVEL SECURITY`. `FORCE` is what makes the
  policies apply to the hub login, which owns the tables. A row MUST be visible and writable only when the
  transaction-local setting `app.tenant_id` equals its `tenant_id`. The store sets it with
  `set_config('app.tenant_id', $1, true)` at the start of every tenant-scoped transaction (`inTenant`). The one other
  path is `app.rls_scope = 'operator'`, also transaction-local, and only named callers may set it (`asOperator`):
  the retention sweep, the payment webhook and the checkout lookups (the tenant is unknown until the checkout row is
  read), and `spool migrate`. A statement that sets neither sees zero rows, so the design fails closed. Hub-wide
  identity tables (`humans`, `human_identities`, `password_credentials`, the token tables) and `webhook_events_seen`
  have no `tenant_id` and stay outside RLS. A superuser or a `BYPASSRLS` role skips every policy, so the hub MUST
  connect as a role with neither, and `spool hub` logs which one it got at startup.
  *Status:* Planned (rdb `0014_tenant_rls.sql`, `internal/store/rls.go`; tasks T019..T023).

## 3. Non-Functional Requirements (NFR-SEC)

- **NFR-SEC-001 (Audit Trail Integrity):** Administrative actions (tenant creation, box pinning, key revocation,
  membership admission) MUST generate structured audit events with monotonic timestamps.
- **NFR-SEC-002 (Fail-Closed Default):** Any failure in cryptographic verification, signature parsing, or session
  membership lookup MUST reject the request with appropriate error envelopes (`401` / `403` / `CloseUnauthorized`).
- **NFR-SEC-003 (Minimal Distroless Attack Surface):** Production containers MUST execute as non-root users on
  distroless base images with read-only root filesystems where possible.

<!-- version: 1.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T14:00:00Z -->
