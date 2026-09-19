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

### 1.4 Open Cloud Run Edge (`0.0.0.0/0`) & Connection Exhaustion
- **Condition:** The hub is one Cloud Run instance (`max_instances=1`, OQ-05: the live-socket map is
  per process) with `concurrency=1000` and a 3600 s request timeout; every WebSocket holds one of the
  1,000 request slots for its lifetime. **Owner decision 2026-09-19: no load balancer and no Cloud Armor**
  -- the API is served exactly as csi-rel serves its API, by Cloud Run domain mappings
  (`api.spool-hub.ai`, `dev.api.spool-hub.ai`, per-tenant hosts; lane CLE-3382) with ingress `all`.
  There is therefore no edge policy in front of the hub at all.
- **Threat:** A slowloris or connection flood on `/v1/ws` or `/v1/wui/ws` exhausts the 1,000 slots of the
  single instance (complete denial of service, sign-in included); a password spray on `/api/v1/auth/*`
  meets only the in-process limits.
- **Remediation Requirement:** (FR-SEC-004) In-app edge limits, keyed on the client IP (FR-SEC-006):
  per-IP concurrent-socket and handshake-rate caps, a global socket cap below `concurrency` so REST and
  sign-in keep slots under a flood, hello (handshake) and liveness (ping) timeouts on both sockets, and a
  per-IP request rate on `/api/v1/auth/*`. Refusals are answered before the upgrade (`429` + `Retry-After`),
  so a refused handshake never holds a slot. A distributed flood from many addresses is NOT stopped by
  per-IP limits; that residual risk is accepted with the owner's no-LB decision.

### 1.5 Frontend Content Security Policy (CSP) Hardening
- **Condition:** The Hosting CSP (rendered by `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`;
  `curl -sI https://csi-spl-dev-site.web.app/login`, 2026-09-19, n=1) carries `'unsafe-inline'` in `script-src`
  and `style-src`; `connect-src` is `'self' https://*.<fqdn> wss://*.<fqdn>` (the `127.0.0.1` / `localhost`
  sources are lde-only, `nuxt.config.ts` CSP_DEV).
- **Threat:** `'unsafe-inline'` diminishes resistance against DOM-based XSS attacks.
- **Remediation Requirement:** (FR-SEC-005) Transition to nonce-based or hash-based CSP, eliminate `'unsafe-inline'`,
  and parameterize `connect-src` with production API host patterns during build and deployment.

### 1.6 Client-IP Trust (`X-Forwarded-For`)
- **Condition:** Every per-IP limit (015 native auth, FR-SEC-004 edge) keys on `clientIP(r, hops)`: the
  hops-th `X-Forwarded-For` entry from the right. Deployed hubs ran with `TrustedProxyHops: 0`, i.e. the
  TCP peer, which on Cloud Run is a Google front-end address, not the caller.
- **Threat:** Too few hops collapses every caller into one bucket (one client locks everyone out); too
  many hops keys on a caller-written entry, so rotating a spoofed `X-Forwarded-For` bypasses every limit
  (csi-rel measured exactly that bypass on its leftmost-entry key, `httpmw/ratelimit.go`, 2026-08-31).
- **Remediation Requirement:** (FR-SEC-006) One knob, `SPOOL_HUB_TRUSTED_PROXY_HOPS`, set per env in cnf
  to the MEASURED chain of the path in service (probe `do_spl_probe_client_ip`), and a test that a spoofed
  `X-Forwarded-For` cannot move the limit key. Two paths reach the hub -- the API domain mapping and the
  WUI host's Firebase rewrite of `/api/v1/auth/**` -- and one hops value must be right for both, so both
  are measured before any per-IP limit is turned on. Counters stay in process: with `max_instances=1` one
  process sees every request, and the cross-instance mail floor is already in Postgres (015 FR-006a).

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
  *Status:* Partial — code, cnf and test landed (`4f36ee3`: `do_provision_spool_root`, `do_repair_spool_root`,
  `spool-permissions.tst.sh`); missing: the `DRY_RUN=0` migration on each existing box (owner / ORC, quiet window).
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
  of the Host tenant or that tenant's box upload token (`Authorization: Bearer`, a pinned box or `box-wui`) when
  `SPOOL_HUB_VIEW_DOOR != off`. No credential, a bad/expired token or another tenant's token -> `401 view_door`,
  checked before the blob lookup (no existence oracle); with a credential, another tenant's `file_id` -> 404. No
  signed view token (OQ-16 is still undecided; the token door admits bearers only). Boxes keep working (`spool`
  get-file already sends the upload token); the WUI must fetch with `credentials: 'include'` in the session door
  (CLE-55 lane). Contract: `../003-spool-message-bus/contracts/http-v1.md` §3.
  *Status:* Implemented — hub `1bcff63` + WUI `30e50d6`, live on dev and prd (hub 0.1.8); prd controls in T006.

- **FR-SEC-003 (Root Key Claim Isolation):** The tenant root private key MUST NOT be transmitted over email.
  `TenantWelcome` email MUST omit the private key string, confining display to a single interactive web claim modal.
  *Status:* Planned.

- **FR-SEC-004 (In-App Edge Limits; supersedes "Cloud Armor Hardening"):** With no load balancer (owner
  2026-09-19), the hub itself MUST refuse, before the WebSocket upgrade, a handshake on `/v1/ws` or
  `/v1/wui/ws` beyond a per-IP concurrent-socket cap, a per-IP handshake rate or a global socket cap, and a
  request to `/api/v1/auth/*` beyond a per-IP rate (`429` + `Retry-After`); both sockets MUST enforce a hello
  timeout and a ping liveness timeout. All limits are cnf (`hub.env.SPOOL_HUB_EDGE_*`); Cloud Run limits
  stay cnf (`hub.cloud_run.*`).
  *Status:* Partial (tasks T010: code + cnf landed; 030 apply and per-IP values pending).

- **FR-SEC-005 (CSP Hashes & Production Connect-Src):** Firebase Hosting configuration MUST replace `'unsafe-inline'`
  with build-time hashes or nonces and include the production domain and tenant subdomains in `connect-src`.
  Amended 2026-09-19 (CLE-3394) after measuring `nuxt generate`: the WUI is static files on Firebase Hosting,
  so no server can mint a nonce. The render step therefore hashes (sha256) every inline executable `<script>`
  and every `<style>` block in the generated `.output/public/**/*.html` and emits exactly those hashes:
  `script-src` and `style-src` are `'self'` plus those hashes, with no `'unsafe-inline'` and no `'unsafe-eval'`.
  The render refuses to run without a generated bundle instead of falling back to `'unsafe-inline'`.
  `connect-src` is `'self'` plus the hub's api host(s) and tenant host(s) from cnf, each over `https:` and
  `wss:`, never a bare scheme. `frame-ancestors 'none'`, `base-uri 'self'`, `object-src 'none'` and
  `form-action 'self'` stay. Acceptance: a headless Chrome pass over the WUI routes on dev logs zero CSP
  violations, and a CONTROL (an injected inline `<script>`) runs under the old policy and is blocked under the
  new one. `nuxt preview` (Nitro, lde only) keeps `'unsafe-inline'`: it has no render step to hash, and it
  never serves a deployed env.
  *Status:* Amended; tracked by tasks T013/T014.

- **FR-SEC-006 (Proxy Hops Configuration):** `SPOOL_HUB_TRUSTED_PROXY_HOPS` MUST be set in
  `dev.env.yaml` and `prd.env.yaml` to the measured `X-Forwarded-For` chain of the path in service (Cloud Run
  domain mapping, no LB), and one value MUST drive both the edge limits and native auth.
  *Status:* Partial (tasks T012: knob + probe landed; the measurement is pending, n=0).

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

- **FR-SEC-011 (Deploy Credential Pinning):** CI/CD deploy credentials MUST be per-env and scoped to one
  project. *Superseded (owner 2026-09-19): deploys use the per-env project SA key, GitHub secret
  `GCP_KEY_CSI_SPL_<ENV>` published by iac step `120-github-general-secrets`; workflows `20` and `30` auth
  with `credentials_json`. WIF (`017-github-wif-deploy`) remains only the documented alternative.*
  *Status:* Superseded (tasks T017).

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
  *Status:* Implemented (rdb `0014_tenant_rls.sql` `f228923`, `internal/store/rls.go` `f416b87`; applied dev + prd 2026-09-19; tasks T019..T023).

- **FR-SEC-014 (Tenant isolation fails closed, and stays that way) — amendment 2026-09-19, CLE-3416:**
  (a) A tenant policy MUST match nothing when `app.tenant_id` is unset OR EMPTY. A pooled connection reads `''`, not
  NULL, after any earlier transaction-local `set_config`, so the form is
  `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')` (rdb `0021_rls_fail_closed.sql`). A FOR SELECT
  policy may expose hub-wide catalogue rows whose `tenant_id` IS NULL (025 system roles); no policy may expose a tenant's
  row, or pass any write, without a tenant.
  (b) The store MUST refuse a tenant-scoped statement without a tenant: `inTenant` and the batch path return
  `ErrNoTenant` for an empty or blank tenant before reaching Postgres.
  (c) CI MUST fail when any table with a `tenant_id` column — read from the catalogue after every migration, never a
  hand list — lacks `ENABLE` + `FORCE`, lacks a policy that lets a tenant read and write its own rows and not another's,
  or has a policy that is TRUE for a row without a tenant (`TestRLSPoliciesFailClosed`).
  (d) Every `asOperator` caller is named with its reason in `operatorCallers` (`TestOperatorScopeCallers`). Several
  are reached from HTTP routes — checkout hold / status / claim, the payment webhooks, and the 026 auth session's
  `Memberships` — each keyed by an unguessable checkout id, a verified webhook, or the session's own human, never by a
  tenant id the caller chooses.
  (e) The hub's runtime login MUST NOT be able to lift RLS for itself: it must not own a tenant table nor be able to
  `SET ROLE` to its owner or to a superuser / `BYPASSRLS` role (`store.HubRoleCanLiftRLS`, logged at startup as
  `db.rls_liftable` / `db.rls_not_liftable`; `do_spl_db_rls_check` reports `liftable`, and `EXPECT_NOT_LIFTABLE=1`
  exits 5). `hub-pg.tst.sh` proves the shape with a non-owner runtime role (`TestRLSHubRoleCannotLiftRLS`).
  *Status:* (a)–(d) Implemented and live (0021 applied dev + prd 2026-09-19 17:06Z / 17:07Z). (e) the gate exists and
  runs; the LIVE hub login `spool_hub` still owns the 15 tenant tables on dev and prd (`liftable=15`), because
  `spool migrate` runs under the hub's own DSN. Closing it needs a migration owner role separate from the runtime role
  (a Cloud SQL user, a second DSN secret, grants) — an infra change that waits for the owner's go (task T029).

- **FR-SEC-015 (One permanent cross-tenant suite) — amendment 2026-09-19, CLE-3416 + CLE-3415:** Two tenants hold data
  in EVERY `tenant_id` table (catalogue-driven; an unseeded new table fails the suite). A member, a browser socket and
  a box of A try every read and write path against B — B's Host, `?tenant=B`, `X-Spool-Tenant: B` (026), and B's
  task / message / file / channel / box ids on A's own tenant — and get refused, empty or 404, never B's data; B's
  rows are unchanged after. Store half `internal/store/crosstenant_test.go`, hub half `internal/hub/crosstenant_test.go`
  + `crosstenant_identity_test.go`, all `TestCrossTenant*`; `hub-pg.tst.sh` (10 ci hub job) requires every one to PASS
  against Postgres. Invites and roles have no HTTP route (CLI / operator only; covered at the store level); human keys
  are per human, not per tenant (`TestKeysOtherHumanRefused`).
  *Status:* Implemented (`1e96587`, `17bbe5f`).

## 3. Non-Functional Requirements (NFR-SEC)

- **NFR-SEC-001 (Audit Trail Integrity):** Administrative actions (tenant creation, box pinning, key revocation,
  membership admission) MUST generate structured audit events with monotonic timestamps.
- **NFR-SEC-002 (Fail-Closed Default):** Any failure in cryptographic verification, signature parsing, or session
  membership lookup MUST reject the request with appropriate error envelopes (`401` / `403` / `CloseUnauthorized`).
- **NFR-SEC-003 (Minimal Distroless Attack Surface):** Production containers MUST execute as non-root users on
  distroless base images with read-only root filesystems where possible.

<!-- version: 1.2.0 · updated: 2026-09-19 · last-edit: 2026-09-19T17:10:00Z -->
