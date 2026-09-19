# Tasks: Spool Security Hardening & Threat Mitigation (017)

**Feature**: `specs/017-spool-security-hardening` · **Milestone**: M3/M4 Consolidation · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane are written here, not done here; the owner is named.

---

## Phase 1 — Specification, Threat Analysis & Architecture Baseline (SECURITY)

- [x] T001 Implemented (`017-spool-security-hardening`) — Comprehensive threat analysis, trust boundary definition, and architectural baseline contract (`./contracts/security-baseline.md`). FR-SEC-007, FR-SEC-008, FR-SEC-010.
- [x] T002 Implemented (`017-spool-security-hardening`) — Security hardening specification (`./spec.md`) and phased implementation plan (`./plan.md`). Mapping of all FR-SEC-001..012.

---

## Phase 2 — Local Box Discretionary Access Control (ORC / CNF)

- [ ] T003 Planned (ORC lane) — Update `csi-spl-orc/.../provision-spool-root.func.sh`: transition `/var/spool-hub` permissions from `2777` to `2770`, remove world-writable ACLs (`o::rwx` -> `o::---`), and enforce execution under dedicated group `spool-agents`. FR-SEC-001.
- [ ] T004 Planned (CNF lane) — Update `csi-spl-cnf/csi-spl/all.env.yaml`: set default `env.box.spool_root_other: "---"` and document operator migration procedure for existing agent boxes. FR-SEC-001.
- [ ] T005 Planned (ORC / TESTS) — Add automated test `csi-spl-orc/src/bash/tests/spool-permissions.tst.sh` asserting `/var/spool-hub` disallows unauthorized non-group user access and enforces sticky or group isolation. FR-SEC-001. Amended 2026-09-19: group isolation, not sticky (spec FR-SEC-001 clarification); the test carries a CONTROL: an outsider's read and inject SUCCEED under the old `2777`/`o::rwx` model and FAIL under the new one.
- [ ] T019 Planned (ORC lane) — Named migration action `csi-spl-orc/src/bash/run/repair-spool-root.func.sh` (`./run -a do_repair_spool_root`), `DRY_RUN=1` default: create the group, add `SPOOL_ROOT_MEMBERS`, re-group the tree, setgid every dir, apply the ACL model, verify. Never run on a live box outside a quiet window. FR-SEC-001.

---

## Phase 3 — API Surface & Blob Storage Access Control (API / HUB)

- [ ] T006 Planned (HUB lane) — Enhance `internal/hub/rest.go` `handleGetFile`: require valid session authentication (`s.sessionMayRead`) or bearer upload token (`s.bearer`) when `ViewDoor != ViewDoorOff`. Eliminate unauthenticated capability URL exposure. FR-SEC-002.
- [ ] T007 Planned (API TESTS) — Add unit and regression tests in `internal/hub/rest_test.go`: assert unauthenticated `GET /v1/files/{file_id}` returns `401 view_door` under `ViewDoorSession`. FR-SEC-002.
- [ ] T008 Planned (PAYMENTS lane) — Update `internal/payments/handler.go`: remove `root_private_key` from `TenantWelcome` email template and payload. Confine key reveal to the single interactive browser checkout session (`/checkout/success`). FR-SEC-003.
- [ ] T009 Planned (PAYMENTS TESTS) — Add regression test verifying `TenantWelcome` email body does not contain private key strings or base64 cryptographic seeds. FR-SEC-003.

---

## Phase 4 — Edge Limits In-App & Client-IP Trust (HUB / CNF; no LB, owner 2026-09-19)

- [ ] T010 Planned (HUB lane, CLE-3393) — In-app edge limits (Cloud Armor superseded: owner 2026-09-19, no LB, API on Cloud Run domain mappings as csi-rel). `internal/edge` + `hub.Server` middleware: per-client-IP concurrent-socket cap, per-IP handshake rate and a global socket cap on `/v1/ws` + `/v1/wui/ws` (refused `429` + `Retry-After` before the upgrade), per-IP request rate on `/api/v1/auth/*`, hello timeout and ping liveness timeout on both sockets; every limit is cnf `hub.env.SPOOL_HUB_EDGE_*`. Cloud Run limits stay cnf `hub.cloud_run.*`: `max_instances=1` (OQ-05, per-process socket map), `concurrency=1000`, `timeout_seconds=3600` (socket lifetime) — csi-rel's API runs 10 / 80 / 120 s, which does not fit a WebSocket hub (80 slots would be the whole flood budget). Check: CONTROL test in `internal/hub/edge_test.go` (the flood handshake succeeds with the limits off, is `429` with them on). FR-SEC-004.
- [x] T011 Superseded (owner 2026-09-19: no load balancer, no Cloud Armor, so there is no edge allowlist to narrow; the per-IP limits of T010 replace it). FR-SEC-004.
- [ ] T012 Planned (HUB / CNF, CLE-3393) — One knob `SPOOL_HUB_TRUSTED_PROXY_HOPS` (hub config) drives the edge limits and native auth (`SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` retired from cnf); set per env in `dev.env.yaml` / `prd.env.yaml` to the X-Forwarded-For chain MEASURED on the path in service with `csi-spl-orc ./run -a do_spl_probe_client_ip` (Cloud Run domain mapping once CLE-3382 cuts over; not assumed). Check: spoofed-XFF test (rotating the caller-written entry does not move the limit key). FR-SEC-006.

---

## Phase 5 — Frontend Content Security Policy & Client Hardening (WUI)

- [ ] T013 Planned (SEC lane CLE-3394, CSP policy + its test) — Hosting CSP (`csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`, which writes `csi-spl-wui/firebase.json`): remove `'unsafe-inline'` from `script-src` and `style-src`; the render hashes every inline `<script>`/`<style>` of the generated `.output/public` (no nonce: static hosting has no server). Tests: `csi-spl-wui/tests/unit/csp-policy.test.mjs` (render against a fixture bundle) and `csi-spl-wui/tests/e2e/csp-violations.test.mjs` (headless Chrome, zero violations per route; CONTROL: injected inline script blocked, and runs under the old policy). FR-SEC-005.
- [ ] T014 Planned (SEC lane CLE-3394) — `connect-src` from cnf only: `'self'` plus the hub api host(s) (`<label>.<BASE_DOMAIN>`, e.g. `api.` / `dev.api.`) and the tenant hosts (`<tenant>.<fqdn>`, a `*.<fqdn>` wildcard while tenants are not enumerated in cnf), each as `https://` and `wss://`; never a bare scheme. FR-SEC-005.

---

## Phase 6 — CI/CD Pipeline & Invariant Verification (CI/CD / INTEGRATOR)

- [x] T015 Implemented (`internal/auth/password.go`, `native_config.go`) — Enforce minimum Argon2id parameters (m >= 19 MiB, t >= 2) and refuse debug tokens in production environments. Check: `go test -run TestNativeConfigValidate ./internal/auth/` -> PASS. FR-SEC-008.
- [x] T016 Implemented (`internal/store/postgres.go`) — Enforce parameterized database queries and prepared statements across all store operations, preventing SQL injection vulnerabilities. Check: `grep -rn "fmt.Sprintf.*SELECT" csi-spl-api/src/go/spool-hub-api/internal/store/` -> 0 hits. FR-SEC-010.
- [x] T017 Superseded (owner 2026-09-19: key-based deploy, not WIF-first) — deploys authenticate with the per-env project SA key: GitHub secrets `GCP_KEY_CSI_SPL_DEV` / `GCP_KEY_CSI_SPL_PRD` (published by iac step `120-github-general-secrets`, `03-github-actions-secrets.tf`), consumed as `credentials_json` by `20_hub-build-deploy.yml` and `30_wui-build-deploy.yml`. Check: `gh secret list -R csitea/csi-spl` -> both names (2026-09-19); `grep -c credentials_json .github/workflows/20_hub-build-deploy.yml .github/workflows/30_wui-build-deploy.yml` -> 1 each. `017-github-wif-deploy` stays only the alternative the workflows fall back to. FR-SEC-011.
- [x] T018 Implemented (`.github/workflows/10_ci-quality.yml`) — Distribution-hygiene automated sweep: zero personal names, literal OS users, personal home directories, or owner email addresses committed to version control. Check: `bash csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` -> PASS. FR-SEC-012.

## Phase 7 — Postgres Row Level Security, defense in depth (RDB / STORE, SEC-08, lane CLE-3395)

- [ ] T019 Planned (RDB) — `csi-spl-rdb/src/sql/postgres/spool-hub/0014_tenant_rls.sql`: `ENABLE` + `FORCE ROW LEVEL SECURITY` and a `tenant_scope` (`app.tenant_id`) plus an `operator_scope` (`app.rls_scope = 'operator'`) policy on the 12 tables that carry `tenant_id`. Metadata only: no table rewrite and no data change, so it is safe on live data. FR-SEC-013.
- [ ] T020 Planned (STORE) — `internal/store/rls.go` `inTenant` / `asOperator`. Every `*_postgres.go` statement on a tenant table runs inside one of them, and `Migrate` applies each file under operator scope. FR-SEC-013.
- [ ] T021 Planned (TESTS) — `hub-pg.tst.sh` runs the store, hub and auth suites as a NON-superuser role that owns the tables (the Cloud SQL shape; a superuser skips every policy). A CONTROL test in `internal/store/rls_test.go` shows that, with tenant A's scope, a query without `WHERE tenant_id` sees none of B's rows and cannot write one. With RLS switched off for the same query, it sees B's rows. FR-SEC-013.
- [ ] T022 Planned (MEASURE) — Latency cost of the per-transaction scope on the hub-pg suite, before and after, with n stated. FR-SEC-013.
- [ ] T023 Planned (DEPLOY) — Order matters. Roll a hub image that sets the scope, then apply 0014 with `do_spl_db_bootstrap` (dev, then prd). The other order hides every row from the running hub until the roll finishes. Check that the hub role has neither `rolsuper` nor `rolbypassrls`. FR-SEC-013.

---

<!-- version: 1.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T14:00:00Z -->
