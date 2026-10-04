# 074 the operator workspace: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names its lane, the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Open owner questions: `spec.md` section 9 (Q1-Q5); every task builds behind the recommended default.

Phased according to owner HUM-10 order (msg `880e9e40`):
1. Hub API: full workspace CRUD, operator-admin only.
2. Shell actions (`./run -a do_spl_tenant_*`) and spool CLI verbs over that API.
3. Operator workspace UI with every action needed to make a new workspace useful.

---

### Phase 0: Specification
- [x] T001 **spec** (a-209): `spec.md` and this file.

### Phase 1: Hub API (Full Workspace CRUD, Operator-Admin Only) — Lane c-210
- [ ] T002 **rdb migration** (c-210): migration `0115_operator_workspaces.sql` adding `operator_audit` table (spec §4.3), `tenants.suspended_at timestamptz NULL`, `tenants.archived_at timestamptz NULL`. Done: Postgres migration linter green (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`).
- [ ] T003 **hub auth & rbac** (c-210): permission `operator.workspaces` in `internal/rbac/rbac.go` (granted to `admin` in operator workspace, withheld from `biz_owner`), middleware `requireOperatorAdmin(r)` in `internal/hub/operator.go`, parsing `SPOOL_HUB_OPERATOR_TENANT` (fallback `SPOOL_HUB_WUI_APEX_TENANT`). Done: unit tests proving `admin` allowed (200) and `biz_owner` / other workspace admin refused (403 with `permission: operator.workspaces`).
- [ ] T004 **store methods** (c-210): reuse existing store calls (`CreateTenant`, `SetTenantConfig`, `SetBillingStatus`, `PutInvite`) plus `operator_audit` logging under `asOperator()` in `internal/store/`, registered in `operatorCallers` whitelist in `internal/store/operator_scope_test.go`. Done: `TestOperatorScopeCallers` and postgres store tests pass.
- [ ] T005 **api endpoints** (c-210): routes `GET /v1/operator/workspaces`, `POST /v1/operator/workspaces`, `GET /v1/operator/workspaces/{id}`, `PATCH /v1/operator/workspaces/{id}`, `DELETE /v1/operator/workspaces/{id}`. Doors answer 403 `workspace_suspended` when suspended. Done: AC1-AC7 pass on postgres, hub deployed dev & prd.

### Phase 2: Shell Actions & CLI Verbs Over Hub API
- [ ] T006 **spool cli verbs**: `spool operator-workspace-list`, `spool operator-workspace-create`, `spool operator-workspace-suspend`, `spool operator-workspace-resume` in `cmd/spool/` calling the authenticated Hub API with operator session tokens instead of direct DB DSN access. Done: CLI tests against test hub pass.
- [ ] T007 **shell actions re-route**: update `csi-spl-orc/src/bash/run/spl-tenant-*.func.sh` (`do_spl_tenant_create`, `do_spl_tenant_display_name`, `do_spl_tenant_member_*`) to call the hub operator API instead of executing raw `psql` queries via Cloud SQL proxy. Done: orc test suites pass with no direct DB dependency.

### Phase 3: Operator Workspace UI ("Make Useful" Console)
- [ ] T008 **wui console & wizard**: `/operator/workspaces` view in `csi-spl-wui` (catalogue table, search, status filters). Create workspace wizard implementing the complete "Make Useful" checklist (spec §3.4: create, admin invite/account, settings, default channels, initial agent join token, billing status). Restricted strictly to operator workspace with `admin` role. Done: `pnpm run typecheck` and WUI e2e tests green.

### Phase 4: Single DNS Entry Point & Unified Routing
- [ ] T009 **single dns routing**: WUI router path prefix normalization `/w/<workspace_id>/...` and session cookie/header integration; 301 redirects for legacy subdomains; deprecate per-tenant host provisioning workflow 40 and terraform step 032. Done: AC8 and AC9 green in live browser e2e.

### Phase 5: Self-Hosted & Open-Source Bootstrap
- [ ] T010 **self-hosted first-run**: bootstrap logic in `csi-spl-api/src/docker/hub-entrypoint.sh` and `docker-compose.yml` automatically designating the first created workspace as the operator workspace and giving initial account the `admin` role. Done: AC10 clean compose boot test passes.

<!-- version: 0.3.0 · updated: 2026-10-04 · last-edit: 2026-10-04T13:12:00Z -->
