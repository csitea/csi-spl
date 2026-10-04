# 074: the operator workspace (one place to manage every workspace on a cloud instance)

**Feature ID**: `074-operator-workspace` · **Milestone**: M3 · **Status**: In Progress
**Created**: 2026-10-04 · **Lane**: a-209 · **Topic**: aa35699c-94ef-44b7-8f28-a51f53664d91
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
[006 workspace rental](../006-spool-hub-rental/spec.md) (workspace lifecycle and billing),
[025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles, permissions, and gates),
[026 workspace from identity](../026-spool-tenant-from-identity/spec.md) (single API host, identity resolution),
[044 open source](../044-spool-open-source/spec.md) (self-hosted and export rules),
[046 workspace settings](../046-spool-tenant-settings/spec.md) (workspace-internal settings),
[054 admin act-as](../054-spool-admin-view-as/spec.md) (temporary technical clone),
[072 rapid deployability](../072-rapid-deployability/spec.md) (one-command setup, dev usability),
[073 agent join tokens](../073-agent-join-tokens/spec.md) (seat a box without root key),
and `../../doc/md/SPEC-spool-identity-routing.md` (identity and routing).

`<BASE_DOMAIN>`, `<fqdn>`, `<workspace_id>`, `<operator_workspace>`, and `<human_id>` are placeholders. No estate value appears as a value to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, or API headers.

---

## 1. Why and The Owner's Ask

Today, workspaces are created and governed through low-level operational scripts (`do_spl_tenant_*`), direct database insertions via the spool CLI (`spool hub-tenant`, `spool hub-tenant-billing`), or raw database migrations. Each workspace operates in an isolated silo with no administrative console to govern the multi-workspace cloud instance as a unified whole. Furthermore, provisioning individual DNS subdomains (`<workspace>.<BASE_DOMAIN>`) introduces substantial latency (~30 minutes for TLS certificate provisioning) and operational fragility.

The owner established the architectural requirements in prd workspace `t1`, topic `aa35699c-94ef-44b7-8f28-a51f53664d91`, verbatim, in chronological order:

1. Owner HUM-10, msg `15ba3d07-3624-4591-9ddc-158a32a6447b`:
   > "we need to make the spool-hub tenant a bit special , so thhat it will be the only place to magage the other spool-hub tenants on a cloud instance ( aka one DNS entry point )"

2. Owner HUM-10, msg `9e90b5d6-8bfb-4e0c-ab9a-7e55b53e2f6f`:
   > "and it will be the only tenant to provid the ui for that as well"

3. Owner HUM-10, msg `94071e2e-10a8-45e5-817d-fd51d8592424`:
   > "and only the admin of the spool-hub could perform any spool-hub instance specific changes , like add or remove tenants - he has to be admin , not biz owner"

4. Owner HUM-10, msg `880e9e40-6050-4887-ac96-44bc11311337`:
   > "first we need to create / update the api for the CRUD of tenants , than add the shell actions to e possible to create it via the CLI and than at the end create the UI for it with all ofthe possible actions to perform in order for a tenant to become useful"

5. Owner HUM-10, msg `e76a7b38`:
   > "go do it"

### Core Principles
1. **One Designated Operator Workspace per Cloud Instance**: One workspace on the instance is configured as the operator workspace (the instance management hub). It serves as the single administrative pane of glass.
2. **Single DNS Entry Point**: The entire cloud instance is accessed via one DNS entry point (the apex domain `<BASE_DOMAIN>` on production, `dev.<BASE_DOMAIN>` on development). Workspaces are distinguished by URL path prefixes (e.g. `/w/<workspace_id>/`) or session context, retiring legacy per-workspace vanity DNS routing.
3. **Exclusive Management Interface**: The UI to list, create, suspend, rename, configure billing, and inspect member/agent counts across workspaces exists **only** within the operator workspace. No regular workspace exposes this UI.
4. **Strict Administrative Gate (`admin`, not `biz_owner`)**: Only a member holding the `admin` role in the operator workspace may execute instance-level actions. A business owner (`biz_owner`) of the operator workspace is explicitly refused permission for instance mutations. A workspace administrator of workspace A has zero access to workspace B.
5. **Universal Model for Self-Hosted and Cloud Deployments**: On a self-hosted or open-source instance (spec 044, 072), the first workspace provisioned during bootstrap automatically becomes the operator workspace, empowering the self-hoster without requiring cloud infrastructure tools.
6. **Ordered Three-Phase Implementation**:
   - Phase 1: Hub API for full workspace CRUD (operator-admin only, built in parallel by lane c-210).
   - Phase 2: Shell actions (`./run -a do_spl_tenant_*`) and CLI verbs (`spool hub-tenant-*`) re-routed over that API.
   - Phase 3: The operator workspace UI incorporating every action needed to make a newly provisioned workspace immediately useful.

---

## 2. Today, Measured (Baseline Architecture)

Every claim below is verified against master (tree `origin/master` @ `803aff49a`):

| Concern | Current Implementation | Source Citation |
|---|---|---|
| **Workspace Creation Verb** | `do_spl_tenant_create` in `csi-spl-orc`: requires `TENANT_ID`, generates Ed25519 root keypair, inserts into DB via `spool hub-tenant`, pins `box-wui` (SPL-1290), provisions host via terraform/Cloud Run mapping (SPL-959). Default `DRY_RUN=1`. | `csi-spl-orc/src/bash/run/spl-tenant-create.func.sh:41-60` |
| **Workspace Display Name Verb** | `do_spl_tenant_display_name`: updates `tenants.display_name` directly in Postgres via Cloud SQL proxy. | `csi-spl-orc/src/bash/run/spl-tenant-display-name.func.sh:22-38` |
| **Workspace Role Mutation Verb** | `do_spl_tenant_member_role`: updates `tenant_memberships.role` via direct `psql` update. | `csi-spl-orc/src/bash/run/spl-tenant-member-role.func.sh:17-35` |
| **Workspace Member Add Verb** | `do_spl_tenant_member_add`: provisions human and membership directly via `psql`. | `csi-spl-orc/src/bash/run/spl-tenant-member-add.func.sh:35-80` |
| **Workspace Responders Verb** | `do_spl_tenant_responders`: updates fallback responder agent IDs in `tenants.fallback_responders`. | `csi-spl-orc/src/bash/run/spl-tenant-responders.func.sh:18-35` |
| **Workspace Sort Order Verb** | `do_spl_tenant_sort_order`: updates `tenants.sort_order`. | `csi-spl-orc/src/bash/run/spl-tenant-sort-order.func.sh:17-30` |
| **Workspace Host Provisioning Verb** | `do_spl_tenant_host_provision`: manages Cloud Run domain mapping, Firebase hosting domain, and Gandi LiveDNS/GCP Cloud DNS. | `csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh:28-65` |
| **Workspace Host Deprovisioning Verb** | `do_spl_tenant_host_deprovision`: tears down domain mapping and DNS records. | `csi-spl-orc/src/bash/run/spl-tenant-host-deprovision.func.sh:24-50` |
| **Workspace Host Reconcile Verb** | `do_spl_tenant_host_reconcile`: reconciles mapped workspace hosts against cnf. | `csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh:20-55` |
| **Workspace Test Purge Verb** | `do_spl_tenant_test_purge`: cleans up test workspace data in Postgres. | `csi-spl-orc/src/bash/run/spl-tenant-test-purge.func.sh:15-40` |
| **CLI Workspace Bootstrap** | `spool hub-tenant --tenant <id> --root-pubkey <b64> [--billing-status <status>]`: directly inserts into `tenants` table via `$SPOOL_HUB_DB_DSN`. | `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:516-544`, `cmd/spool/main.go:46, 137, 175` |
| **CLI Workspace Billing** | `spool hub-tenant-billing --tenant <id> --event paid\|unpaid\|failed\|refund\|cancel`: applies billing event via `$SPOOL_HUB_DB_DSN`. | `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:550-571`, `cmd/spool/main.go:47, 138, 177` |
| **Intra-Workspace Settings (046)** | `GET/PATCH /v1/tenant/settings`: guarded by permission `tenant.settings` (biz_owner, admin). Edits only the caller's active workspace. No route lists or edits other workspaces. | `csi-spl-doc/specs/046-spool-tenant-settings/spec.md:47-68`, `csi-spl-wui/src/pages/tenant-settings.vue` |
| **Intra-Workspace Act-As (054)** | Admin clones a user via a temporary technical human `HUM-*` (`humans.technical = true`) within the *same* workspace. Strict boundary: cannot clone cross-workspace. | `csi-spl-doc/specs/054-spool-admin-view-as/spec.md:20-29, 54-74, 93` |
| **Intra-Workspace Agent Join (073)** | Short-lived single-use join token (`spj1.<tenant>.<secret>`) seats a box within that *single* workspace. Guarded by `keys.manage`. | `csi-spl-doc/specs/073-agent-join-tokens/spec.md:21-27, 77-95, 120-127` |
| **Apex Host Serving Default Workspace** | Production apex `<BASE_DOMAIN>` serves default workspace `t1` via `wui_default_tenant: "t1"`. Legacy vanity subdomains (`<tenant>.<BASE_DOMAIN>`) route via `wui_tenant_hosts: true`. | `csi-spl-cnf/csi-spl/prd.env.yaml:67-73`, `csi-spl-doc/specs/README.md:240-260`, `csi-spl-wui/src/plugins/tenant-host.client.ts:1-5` |
| **Single API Host (026)** | Hub API consolidated under `api.<BASE_DOMAIN>`. Workspace resolution operates via `X-Spool-Tenant` header, session cookie `t`, or pinned box public key. Per-tenant API DNS retired. | `csi-spl-doc/specs/026-spool-tenant-from-identity/spec.md:11-26, 173-176`, `csi-spl-doc/specs/README.md:351` |
| **Database RLS Scoping** | Postgres RLS enforces workspace isolation: `inTenant(workspace, fn)` sets transaction-local `app.tenant_id`. Every tenant table enforces RLS. Cross-workspace operations require `asOperator()`. | `csi-spl-api/src/go/spool-hub-api/internal/store/rls.go:17-20, 37-47, 159-166` |
| **`asOperator` Callers Whitelist** | Static test asserts all callers of `asOperator` are whitelisted (retention sweeper, checkout, migrations, session memberships). No general cross-workspace management route exists today. | `csi-spl-api/src/go/spool-hub-api/internal/store/operator_scope_test.go:19-35, 45-60` |
| **RBAC Roles & Permissions** | `biz_owner` holds every permission including `billing.manage`, `tenant.settings`, `members.invite`. `admin` holds `tenant.settings`, `members.invite`, `keys.manage`, but *not* `billing.manage`. | `csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go:39-47, 84-95` |

---

## 3. The Design

```
+----------------------------------------------------------------------------------------------------+
|                                    CLOUD INSTANCE (ONE DNS ENTRY POINT)                            |
|                                    https://<BASE_DOMAIN>/                                          |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  │
                       ┌──────────────────────────┴──────────────────────────┐
                       ▼                                                     ▼
    ┌──────────────────────────────────────┐              ┌──────────────────────────────────────┐
    │     DESIGNATED OPERATOR WORKSPACE    │              │          REGULAR WORKSPACES          │
    │     e.g. /w/operator/ (or /w/t1/)    │              │    /w/engineering/, /w/marketing/    │
    │  (cnf: instance.operator_workspace)  │              │                                      │
    ├──────────────────────────────────────┤              ├──────────────────────────────────────┤
    │ Role: admin                          │              │ Role: admin / biz_owner / member     │
    │  ├─ Instance Workspaces Console (UI) │              │  ├─ Intra-Workspace Settings (046)   │
    │  ├─ List / Search all workspaces     │              │  ├─ Local Members / Roles (CRUD)     │
    │  ├─ "Make Useful" Creation Wizard    │              │  ├─ Local Seated Agents (073)        │
    │  ├─ Suspend / Reactivate / Archive   │              │  ├─ Local Channels & Topics          │
    │  ├─ Update display name & settings   │              │  │                                   │
    │  ├─ Set billing / plan tier          │              │  │  [NO Instance Workspaces UI]      │
    │  └─ Inspect members / agent counts   │              │  │  [NO Cross-Workspace Controls]    │
    │                                      │              │  │  [Attempt to access operator      │
    │ Role: biz_owner                      │              │  │   routes returns 403 Forbidden]   │
    │  └─ [REFUSED instance mutations]     │              │  │                                   │
    └──────────────────────────────────────┘              └──────────────────────────────────────┘
                       │                                                     │
                       ▼                                                     ▼
        /v1/operator/workspaces (API)                             /v1/tenant/settings (API)
            asOperator() store scope                                inTenant() store scope
                       │                                                     │
                       └──────────────────────────┬──────────────────────────┘
                                                  ▼
                                      PostgreSQL + Row-Level Security
                                (operator_audit table, rdb 0115)
```

### 3.1 Designated Operator Workspace
- **Instance Configuration**: The operator workspace is declared in configuration (`csi-spl-cnf/csi-spl/all.env.yaml` under `env.instance.operator_workspace` and rendered into environment files), exposed to the hub as the environment variable `SPOOL_HUB_OPERATOR_TENANT`.
- **Fallback Resolution**: When `SPOOL_HUB_OPERATOR_TENANT` is unset, it defaults to `SPOOL_HUB_WUI_APEX_TENANT` (cnf `wui_default_tenant`, `t1` on dev and prd). If both are empty, operator endpoints answer HTTP 404.
- **No Hardcoded Slug**: The codebase contains no literal workspace identifier (such as `t1` or `operator`) hardcoded as an authority. In existing estates, it defaults to the existing root workspace (e.g. `t1`); in fresh or self-hosted deployments, it defaults to the first created workspace.
- **Dual Functionality**: The operator workspace is a standard, fully functioning workspace (carrying channels, members, topics, notes, agents, and local settings), but additionally serves as the administrative cockpit for the entire cloud instance.

### 3.2 Single DNS Entry Point and Unified Routing
- **Consolidated Entry Point**: The entire cloud instance is reached via **one DNS entry point**:
  - Production: `https://<BASE_DOMAIN>/`
  - Development: `https://dev.<BASE_DOMAIN>/`
  - Local / Self-Hosted: `http://localhost:8080/` or `https://<self-hosted-domain>/`
- **Unified Navigation**: Workspaces are addressed via URL path prefixes:
  - Format: `https://<BASE_DOMAIN>/w/<workspace_id>/[channel|settings|...]`
  - Deep-link compatibility: Legacy routes (e.g. `/lobby?tenant=<id>`) seamlessly normalize to the `/w/<workspace_id>/` path structure.
  - Active workspace context: The active workspace is pinned in the browser session and transmitted via the `X-Spool-Tenant` header and the authenticated session token (spec 026).
- **Retirement of Per-Workspace DNS Routing**:
  - Legacy vanity routing (`https://<workspace>.<BASE_DOMAIN>`) is formally phased out.
  - Existing vanity domains issue an HTTP 301 Permanent Redirect to `https://<BASE_DOMAIN>/w/<workspace>/`.
  - Deprecates terraform step `032-gcp-cloud-run-domain-mapping` for individual workspaces, eliminates workflow 40 (`tenant-host-reconcile`), and terminates the 30-minute TLS certificate provisioning wait time (addressing spec 047 B5 and spec 072 research 08).
  - Workspace creation becomes instantaneous (sub-second database commit).

### 3.3 The Operator Management Interface (WUI)
The operator management interface lives exclusively in the operator workspace:
- **Visibility Condition**: In `csi-spl-wui`, the "Instance Workspaces" navigation tab and route (`/operator/workspaces`) appear **if and only if**:
  1. The current active workspace matches `pub.operatorWorkspace` (rendered from `SPOOL_HUB_OPERATOR_TENANT`), **and**
  2. The authenticated user holds the `admin` role in that workspace.
- **Strict Isolation**: When navigating any regular workspace, or when viewing the operator workspace as a non-admin (e.g. `biz_owner`, `developer`, `member`), the navigation item is entirely omitted from DOM and router definitions. Direct navigation to `/operator/workspaces` redirects to `/lobby` with an access alert.

### 3.4 The "Making a New Workspace Useful" Checklist (Owner msg `880e9e40`)
When an operator creates a new workspace, creating the database row alone leaves it empty and inert. Per the owner's explicit mandate, the operator API, CLI, and UI must provide every action required for the workspace to become immediately operational:

1. **Core Workspace Creation**:
   - Slug validation (`^[a-z0-9][a-z0-9-]{0,31}$`, no reserved words `dev`, `prd`, `api`, `www`, `operator`).
   - Root Ed25519 keypair generation; public key stored in DB.
   - Immediate pinning of `box-wui` (signed with the root key while in memory, resolving SPL-1290) so browser posts are verified.
2. **Initial Administrator / Member Onboarding**:
   - Prompt for the initial workspace administrator's email and role (`first_admin_email`, `first_admin_role`, default `admin`).
   - Option A: Mint an email invitation with an immediate join link.
   - Option B: Create the account directly with a one-time temporary password (046 `POST /v1/members`), allowing immediate sign-in.
3. **Workspace Configuration & Metadata**:
   - Set the workspace display name (e.g. "Acme Engineering").
   - Set default preferred locale (`default_locale`, e.g. `en`, `sv`, `nl`, `de`).
   - Configure the workspace issue key prefix (e.g. `ENG-`, `OPS-`).
   - Configure default locale (`default_locale`, e.g. `en`, `sv`, `nl`, `de`) and topic archive policies (`topic_archive_policy`). Fallback responders remain managed at the workspace settings level (spec 046 `PATCH /v1/tenant/settings` or CLI verb `do_spl_tenant_responders`), not via the operator workspace PATCH route.
4. **Default Communication Channels**:
   - Automatically seed default public channels (`#general`, `#lobby`, `#announcements`) so members have an immediate home upon landing.
5. **Seating Agent Boxes**:
   - Provide an immediate action to mint an initial agent join token (`spj1.<tenant>.<secret>`, spec 073) so developers can attach CLI or worker agents to the new workspace in seconds without touching the root private key.
6. **Billing & Plan Assignment**:
   - Assign initial billing status (`billing_status`, default `manual`, or `active`, `grace`, `unpaid`, `internal`). Workspace suspension is an orthogonal lifecycle state controlled via `suspended: true|false` setting `tenants.suspended_at`, not a billing status.
   - Allocate seat and monthly message quotas per instance policies.
7. **Lifecycle Controls**:
   - Suspend / reactivate toggle: instantly cut off access (`403 workspace_suspended`) while preserving data.
   - Soft delete: mark workspace archived (`tenants.archived_at = now()`) and suspended (`tenants.suspended_at = now()`) via `DELETE /v1/operator/workspaces/{id}`.
   - Hard purge: explicitly refused (`?purge` returns 400).

---

## 4. Security Architecture

### 4.1 Role and Permission Enforcement
The owner established a decisive security rule (msg `94071e2e-10a8-45e5-817d-fd51d8592424`):
> "and only the admin of the spool-hub could perform any spool-hub instance specific changes , like add or remove tenants - he has to be admin , not biz owner"

- **New Permission: `operator.workspaces`**:
  - Catalogued in `internal/rbac/rbac.go` as `operator.workspaces` ("manage every workspace on the cloud instance").
  - Granted **strictly to the `admin` role** within the designated operator workspace.
  - **Withheld from `biz_owner`**: The business owner (`biz_owner`) of the operator workspace does **not** receive `operator.workspaces`. An operator workspace `biz_owner` attempting to create, suspend, or modify another workspace is refused with HTTP 403 (`permission: operator.workspaces`).
  - **Withheld from Regular Workspaces**: Neither `admin` nor `biz_owner` of any regular workspace holds this permission.
- **Server-Side Authorization Middleware**:
  Every operator route executes the middleware `requireOperatorAdmin(r)`:
  ```go
  func (s *Server) requireOperatorAdmin(w http.ResponseWriter, r *http.Request) (*auth.Session, error) {
      sess := auth.FromContext(r.Context())
      if sess == nil || sess.HumanID == "" {
          http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
          return nil, errUnauthorized
      }
      if sess.Tenant != s.operatorWorkspace {
          http.Error(w, `{"error":"forbidden","permission":"operator.workspaces","reason":"operator_workspace_required"}`, http.StatusForbidden)
          return nil, errForbidden
      }
      role, err := s.store.MemberRole(r.Context(), sess.Tenant, sess.HumanID)
      if err != nil || role != rbac.Admin {
          http.Error(w, `{"error":"forbidden","permission":"operator.workspaces","reason":"operator_admin_required"}`, http.StatusForbidden)
          return nil, errForbidden
      }
      return sess, nil
  }
  ```

### 4.2 Hub Operator API Routes (Phase 1, c-210 contract)

| Method & Route | Auth & Permission | Request Body | Response & Behaviour |
|---|---|---|---|
| `GET /v1/operator/workspaces` | Operator `admin` | - | 200 OK: array of `{id, display_name, billing_status, plan_id, created_at, suspended_at, archived_at, operator}`. |
| `POST /v1/operator/workspaces` | Operator `admin` | `{id, display_name?, billing_status?, root_pubkey?, first_admin_email?, first_admin_role?, no_mail?}` | 201 Created: answers generated `root_private_key` once; 409 conflict if slug exists. Reuses `CreateTenant` and `PutInvite`. |
| `GET /v1/operator/workspaces/{id}` | Operator `admin` | - | 200 OK: workspace metadata plus its last 50 `operator_audit` trail entries. |
| `PATCH /v1/operator/workspaces/{id}` | Operator `admin` | `{display_name?, billing_status?, suspended?, default_locale?, topic_archive_policy?}` | 200 OK: updates configuration; toggles `suspended_at`. Suspended doors return 403 `workspace_suspended`. |
| `DELETE /v1/operator/workspaces/{id}` | Operator `admin` | - | 200 OK: SOFT delete (sets `suspended_at = now()` and `archived_at = now()`, rows stay). Calling with `?purge` returns 400. |

- **Suspension Door Lock**: A suspended workspace's doors (browser login, box API hello/pins, and WebSocket frames) answer **403 `workspace_suspended`**.
- **Self-Protection**: The operator workspace cannot suspend or archive itself (`409 conflict`, self-lockout forbidden).

### 4.3 Database Schema & RLS Boundaries (rdb 0115)
- **Schema Migration (`0115_operator_workspaces.sql`)**:
  - Adds `tenants.suspended_at timestamptz NULL`.
  - Adds `tenants.archived_at timestamptz NULL`.
  - Creates the immutable audit table `operator_audit`:
  ```sql
  CREATE TABLE operator_audit (
      id           bigserial   PRIMARY KEY,
      at           timestamptz NOT NULL,
      tenant_id    text        NOT NULL,
      actor_tenant text        NOT NULL,
      actor_hum    text        NOT NULL,
      action       text        NOT NULL CHECK (action IN (
                        'list', 'read', 'create', 'update', 'suspend', 'resume', 'archive'
                    )),
      detail       jsonb       NOT NULL DEFAULT '{}'::jsonb
  );
  CREATE INDEX operator_audit_tenant_at ON operator_audit (tenant_id, at);
  ```
  The primary key `id` is a `bigserial` sequence (resolving drift 1). `tenant_id` names the target workspace without a foreign key constraint, ensuring the audit history outlives any soft-deleted or archived workspace. Indexes on `(tenant_id, at)` allow fast retrieval of the latest 50 audit entries. RLS policies `tenant_scope` and `operator_scope` guard access.
- **Scoped Isolation (`inTenant`)**:
  All standard member, channel, message, and agent operations continue to run strictly within the transaction-local `inTenant(workspace, fn)` scope (`SELECT set_config('app.tenant_id', $1, true)`).
- **Operator Scope (`asOperator`)**:
  - Cross-workspace queries and mutations execute within dedicated store functions using `asOperator(ctx, fn)` (`SELECT set_config('app.rls_scope', 'operator', true)`).
  - Reuses existing vetted store methods (`CreateTenant`, `SetTenantConfig`, `SetBillingStatus`, `PutInvite`).
  - Whitelist validation: Methods registered in `operatorCallers` in `internal/store/operator_scope_test.go`.

---

## 5. Self-Hosted and Open-Source Deployments (044, 072)

To maintain complete architectural parity across public cloud, private enterprise, and developer environments (spec 044 §1, spec 072 §3):
1. **Initial Bootstrap**:
   - When a self-hosted instance boots with an empty database (e.g. via `docker compose up` or single-server deployment), the setup process or first-run wizard prompts for the initial instance configuration.
   - The very first workspace created is automatically flagged as the designated operator workspace (`SPOOL_HUB_OPERATOR_TENANT` defaults to it).
2. **Initial Administrator Account**:
   - The initial account created during bootstrap is granted both `admin` and `biz_owner` roles in that first workspace, immediately equipping them to access the operator management console.
3. **Zero Cloud Dependencies**:
   - Self-hosters manage all subsequent workspaces entirely through the web interface, without needing GCP IAM, Cloud SQL proxies, gcloud CLI tools, or terraform runs.
   - The single DNS entry point model operates seamlessly on `localhost:8080`, private IP addresses, or internal company domains.

---

## 6. User Stories and Priorities

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Operator Admin | Navigate to the Operator Workspace UI and view a catalogue of all workspaces on the cloud instance with member and agent counts. | Instant visibility into estate health and tenant activity from one place. |
| **US2** | **P1** | Operator Admin | Create a new workspace directly from the UI and execute the complete onboarding checklist (invite admin, configure settings, seed channels, mint join token). | Reduces workspace onboarding time from 30+ minutes of manual ops to under 2 seconds. |
| **US3** | **P1** | Operator Admin | Suspend an abusive, unpaid, or compromised workspace with a single click, instantly cutting off member and agent sessions while preserving data. | Rapid incident containment and automated billing enforcement. |
| **US4** | **P1** | Workspace Member | Access their workspace under the single DNS entry point (`https://<BASE_DOMAIN>/w/<workspace>/`) without relying on custom subdomains. | Immediate availability, consistent cookie context, and no certificate provisioning delays. |
| **US5** | **P1** | Security / Owner | Verify that a `biz_owner` of the operator workspace is strictly refused permission to execute instance mutations. | Guarantees technical separation of duties per the owner's explicit mandate. |
| **US6** | **P2** | Operator Admin | Update another workspace's display name, default locale, topic archive policy, and billing status from the UI. | Eliminates reliance on `do_spl_tenant_*` CLI wrappers for everyday adjustments. |
| **US7** | **P2** | Operator Admin | Inspect the member roster and seated agent keys of a workspace in read-only mode to assist with support requests. | Enables effective troubleshooting without violating workspace member privacy. |
| **US8** | **P2** | Self-Hoster | Start a new spool instance via Docker Compose and have the first workspace automatically serve as the operator workspace. | Frictionless developer experience and turnkey open-source deployment. |
| **US9** | **P3** | Workspace Member | Navigate to an old vanity URL (`<workspace>.<BASE_DOMAIN>`) and be transparently redirected (HTTP 301) to the unified single DNS entry point. | Backward compatibility and seamless migration for existing bookmarks. |

---

## 7. Functional Requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | **Designated Operator Workspace**: One workspace per cloud instance is designated as the operator workspace via `SPOOL_HUB_OPERATOR_TENANT` (fallback `SPOOL_HUB_WUI_APEX_TENANT`, `t1`); no literal workspace ID is hardcoded. | Implemented (v8.5.6) |
| **FR-002** | **Single DNS Entry Point**: The cloud instance serves all workspaces under one DNS entry point; workspace context is resolved via `/w/<workspace_id>/` URL paths, session cookies, and `X-Spool-Tenant` headers. | Planned |
| **FR-003** | **Vanity Subdomain Deprecation**: Legacy per-workspace subdomains (`<workspace>.<BASE_DOMAIN>`) issue an HTTP 301 redirect to the single DNS entry point; workflow 40 and terraform step 032 are retired for individual workspaces. | Planned |
| **FR-004** | **Exclusive Operator UI**: The workspace management interface (`/operator/workspaces`) is exposed exclusively in the designated operator workspace to members holding the `admin` role; it is completely omitted in all other workspaces and for non-admin roles. | Planned |
| **FR-005** | **Workspace Catalogue API & UI**: An operator admin can list all workspaces on the instance (`GET /v1/operator/workspaces`) with status, display name, created_at, suspended_at, archived_at, and operator flag. | Implemented (v8.5.6) |
| **FR-006** | **Instant Workspace Provisioning & Useful Checklist**: An operator admin can create a new workspace via `POST /v1/operator/workspaces` and complete the onboarding checklist (admin invite, display name, default channels, join token, billing) without DNS delays. | Implemented (v8.5.6) |
| **FR-007** | **Workspace Suspension & Soft Delete**: An operator admin can suspend (`PATCH /v1/operator/workspaces/{id}` with `suspended: true`) and soft-delete (`DELETE /v1/operator/workspaces/{id}`) a workspace. Suspended doors return 403 `workspace_suspended`. | Implemented (v8.5.6) |
| **FR-008** | **Operator Workspace Immortality**: The designated operator workspace cannot be suspended or deleted; attempts fail with `409 conflict`. | Implemented (v8.5.6) |
| **FR-009** | **Cross-Workspace Settings Management**: An operator admin can update display name, default locale, and topic archive policy of any workspace (`PATCH /v1/operator/workspaces/{id}`). Fallback responders remain managed within workspace settings (spec 046). | Implemented (v8.5.6) |
| **FR-010** | **Cross-Workspace Billing Control**: An operator admin can update the billing status (`active`, `grace`, `unpaid`, `manual`, `internal`) via `PATCH /v1/operator/workspaces/{id}`. (Suspension is an orthogonal state controlled via `suspended: true|false`, not a billing status). | Implemented (v8.5.6) |
| **FR-011** | **Roster & Audit Inspection**: An operator admin can view a workspace's configuration and its last 50 audit entries (`GET /v1/operator/workspaces/{id}`); message and channel contents remain inaccessible. | Implemented (v8.5.6) |
| **FR-012** | **Strict Role Boundary (`admin`, not `biz_owner`)**: Instance mutation routes require the `admin` role in the operator workspace; a `biz_owner` lacking the `admin` role is refused with `403` (`permission: operator.workspaces`). | Implemented (v8.5.6) |
| **FR-013** | **Cross-Tenant Admin Rejection**: An administrator of regular workspace A attempting to access operator endpoints or another workspace's data is refused with HTTP 403 `forbidden`. | Implemented (v8.5.6) |
| **FR-014** | **Immutable Audit Trail**: Every cross-workspace action is recorded in `operator_audit` (`id bigserial PRIMARY KEY`, `at`, `tenant_id`, `actor_tenant`, `actor_hum`, `action`, `detail`). | Implemented (v8.5.6) |
| **FR-015** | **Store & RLS Isolation**: Cross-workspace store methods run strictly under `asOperator(ctx, fn)`; all intra-workspace operations remain strictly bound to `inTenant(workspace, fn)`. | Implemented (v8.5.6) |
| **FR-016** | **Self-Hosted First-Run Designation**: In fresh or self-hosted environments without an explicit operator workspace configured, the first created workspace automatically becomes the operator workspace and its initial administrator is granted `admin`. | Planned |

---

## 8. Acceptance Scenarios

| # | Check / Test | Proves |
|---|---|---|
| **AC1** | **List Workspaces from Operator Workspace**: Authenticated as `admin` in the operator workspace, call `GET /v1/operator/workspaces` -> receives 200 OK with JSON array of all instance workspaces including metadata, counts, and status. | FR-004, FR-005 |
| **AC2** | **Create Workspace via Operator API**: Call `POST /v1/operator/workspaces` with slug `acme-test` -> receives 201 Created; root public key stored in DB; `box-wui` is pinned; workspace is immediately resolvable under `/w/acme-test/`. | FR-002, FR-006 |
| **AC3** | **Suspend and Reactivate Workspace**: Operator admin calls `PATCH /v1/operator/workspaces/acme-test` with `suspended: true` -> member sign-in and agent WS connect return 403 `workspace_suspended`; subsequent call with `suspended: false` -> access restored immediately. | FR-007 |
| **AC4** | **Owner Rule: `biz_owner` of Operator Workspace Refused**: Authenticated as `biz_owner` (without `admin` role) in the operator workspace, call `POST /v1/operator/workspaces` or `DELETE /v1/operator/workspaces/acme-test` -> receives **403 Forbidden** (`permission: operator.workspaces`). | FR-012 (HUM-10 mandate) |
| **AC5** | **Regular Workspace Admin Refused**: Authenticated as `admin` of regular workspace `acme-test`, call `GET /v1/operator/workspaces` or attempt mutation on workspace `t1` -> receives **403 Forbidden** (`operator_workspace_required`). | FR-013 |
| **AC6** | **Operator Workspace Immortality**: Call `DELETE /v1/operator/workspaces/<operator_workspace>` or `PATCH` with `suspended: true` -> receives **409 Conflict** (`cannot_suspend_operator_workspace`); operator workspace remains active. | FR-008 |
| **AC7** | **Audit Log Verification**: Following AC2 and AC3, query `operator_audit` -> records exist matching `actor_hum`, actions (`create`, `suspend`), `tenant_id`, and `detail`. | FR-014 |
| **AC8** | **Single DNS Entry Point Navigation**: Accessing `https://<BASE_DOMAIN>/w/acme-test/lobby` loads the WUI in `acme-test` context with no external subdomain request; browser console shows 0 network calls to `<workspace>.<BASE_DOMAIN>`. | FR-002 |
| **AC9** | **Vanity Subdomain 301 Redirect**: Sending HTTP request to `https://acme-test.<BASE_DOMAIN>/lobby` -> receives HTTP 301 redirecting to `https://<BASE_DOMAIN>/w/acme-test/lobby`. | FR-003 |
| **AC10** | **Self-Hosted Bootstrap Designation**: Starting a fresh test hub with an empty database, invoke initial setup -> first workspace created is assigned as operator workspace and initial admin receives `admin` role. | FR-016 |

---

## 9. Numbered Questions for the Owner

Each question is formulated for a concise, one-line answer and is paired with a recommended default:

| ID | Question | Recommended Default |
|---|---|---|
| **Q1** | Should the operator workspace identifier be stored in cnf/environment (`SPOOL_HUB_OPERATOR_TENANT`), in the database (`tenants.is_operator`), or both? | **Both**: cnf/env defines the instance authority; database column `is_operator` mirrors it with a unique constraint preventing multiple operator workspaces. |
| **Q2** | For routing regular workspaces under the single DNS entry point, should the WUI use explicit path prefixes (`/w/<workspace_id>/...`) or keep URLs clean and rely solely on session switching? | **Explicit path prefixes (`/w/<workspace_id>/...`)**: allows multiple workspaces to be open in separate browser tabs and supports bookmarkable links. |
| **Q3** | What is the grace period before retiring legacy per-workspace DNS CNAMEs and workflow 40? | **30 days**: maintain HTTP 301 redirects on existing CNAMEs for 30 days before tearing down legacy terraform step 032 resources. |
| **Q4** | Should operator admins have read access to message channels or topics of other workspaces for technical support? | **No (metadata and rosters only)**: operator admins can view members, agents, and quotas, but never message contents or DMs (zero-trust privacy). |
| **Q5** | When a workspace is suspended, should queued messages for its agents be discarded or held until reactivation? | **Held until retention expiry (spec 006 FR-010)**: unexpired deliveries remain queued in PostgreSQL and resume delivery upon reactivation. |

---

## 10. Not in Scope

- Changing the underlying message bus protocol (specs 003, 020).
- Modifying intra-workspace RBAC permissions or channel management (specs 025, 046).
- Creating cross-workspace message bridges or cross-workspace agent routing (workspaces remain fully air-gapped namespaces).
- Cloud billing integration for automated Stripe tenant checkout (handled by existing spec 006 contracts).

---

## 11. Version Log

| Version | Change | Author |
|---|---|---|
| v0.1 | Initial complete specification: background audit, single DNS entry point, operator workspace UI and API, strict `admin` role enforcement, audit logging, self-hosted bootstrap, user stories, requirements, acceptance scenarios, and owner questions. | a-209 |
| v0.2 | Incorporated owner messages 880e9e40 & e76a7b38: explicit "useful workspace" onboarding checklist (admin invite, channel seed, join tokens, settings, billing), aligned Phase 1 API route contract (`GET/POST/PATCH/DELETE /v1/operator/workspaces`) with c-210 implementation. | a-209 |
| v0.3 | Aligned with c-210 live API contract (msg 6fd5cf85): `SPOOL_HUB_OPERATOR_TENANT`, permission `operator.workspaces`, `operator_audit` table (rdb 0115), `tenants.suspended_at`/`archived_at`, 403 `workspace_suspended`. | a-209 |
| v0.4 | Reconciled 3 Phase 1 drifts identified by c-001/c-210 (v8.5.6): (1) `operator_audit.id` is `bigserial PRIMARY KEY` (not uuid), no FK on `tenant_id`; (2) `billing_status` valid values are `active\|grace\|unpaid\|internal\|manual` - workspace suspension is orthogonal via `PATCH {"suspended": true\|false}` setting `tenants.suspended_at`; (3) removed fallback responders from `PATCH /v1/operator/workspaces/{id}` (retained in workspace settings spec 046). Marked Phase 1 FRs as Implemented (v8.5.6). | a-209 |

<!-- version: 0.4.0 · updated: 2026-10-04 · last-edit: 2026-10-04T13:25:00Z -->
