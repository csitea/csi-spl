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

- [x] T003 Implemented (`4f36ee3`, `csi-spl-orc/src/bash/run/provision-spool-root.func.sh`) — Update `csi-spl-orc/.../provision-spool-root.func.sh`: transition `/var/spool-hub` permissions from `2777` to `2770`, remove world-writable ACLs (`o::rwx` -> `o::---`), and enforce execution under dedicated group `spool-agents`. FR-SEC-001. Check: `bash csi-spl-orc/src/bash/tests/spool-permissions.tst.sh` -> 25 PASS, 0 FAIL (as the box owner user, with sudo -n, 2026-09-19).
- [x] T004 Implemented (`4f36ee3`, `csi-spl-cnf/csi-spl/all.env.yaml` env.box + rendered dev/prd env.json; migration procedure: `csi-spl-orc/README.md` §/var/spool-hub permissions model) — Update `csi-spl-cnf/csi-spl/all.env.yaml`: set default `env.box.spool_root_other: "---"` and document operator migration procedure for existing agent boxes. FR-SEC-001. Check: `yq -r '.env.box' csi-spl-cnf/csi-spl/all.env.yaml` -> group `spool-agents`, other `---`.
- [x] T005 Implemented (`4f36ee3`) — Add automated test `csi-spl-orc/src/bash/tests/spool-permissions.tst.sh` asserting `/var/spool-hub` disallows unauthorized non-group user access and enforces sticky or group isolation. FR-SEC-001. Amended 2026-09-19: group isolation, not sticky (spec FR-SEC-001 clarification); the test carries a CONTROL: an outsider's read and inject SUCCEED under the old `2777`/`o::rwx` model and FAIL under the new one. Check: `bash csi-spl-orc/src/bash/tests/spool-permissions.tst.sh` -> 25 PASS, 0 FAIL (as the box owner user, with sudo -n, 2026-09-19); the orc suite `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` -> 18/18 files.
- [~] T019 Partial (`4f36ee3`; missing: the DRY_RUN=0 run on each live box, owner / ORC in a quiet window) — Named migration action `csi-spl-orc/src/bash/run/repair-spool-root.func.sh` (`./run -a do_repair_spool_root`), `DRY_RUN=1` default: create the group, add `SPOOL_ROOT_MEMBERS`, re-group the tree, setgid every dir, apply the ACL model, verify. Never run on a live box outside a quiet window. FR-SEC-001. Check: `./run -a do_repair_spool_root` (dry run) on a live 2777 box -> plan printed, `stat -c %a /var/spool-hub` still 2777; spool-permissions.tst.sh §3 proves DRY_RUN=0 on a scratch tree.

---

## Phase 3 — API Surface & Blob Storage Access Control (API / HUB)

- [~] T006 Partial (HUB lane, CLE-3392) — `internal/hub/rest.go` `handleGetFile`: require a member session (`s.sessionMayRead`) or an upload token of the Host tenant (`s.bearer`) when `ViewDoor != ViewDoorOff`, before the blob lookup; `401 view_door` otherwise. http-v1 §3 / view-v1 amended. Missing: dev + prd deploy (hub image tag), WUI downloads with credentials (CLE-55). FR-SEC-002.
- [~] T007 Partial (API TESTS, CLE-3392) — `internal/hub/rest_test.go` `TestGetFileNeedsCredential` (token / session / off doors) + `TestGetFileMemberSession`. CONTROL: with the pre-change handler the same tests fail `anonymous GET: 200 confidential attachment` (3 of 3 door cases); anonymous, garbage, other-tenant token and non-member session -> 401, other tenant's id with a credential -> 404, own box / member -> 200. Missing: the deployed dev e2e (`do_spl_m3_e2e`). FR-SEC-002.
- [ ] T008 Planned (PAYMENTS lane) — Update `internal/payments/handler.go`: remove `root_private_key` from `TenantWelcome` email template and payload. Confine key reveal to the single interactive browser checkout session (`/checkout/success`). FR-SEC-003.
- [ ] T009 Planned (PAYMENTS TESTS) — Add regression test verifying `TenantWelcome` email body does not contain private key strings or base64 cryptographic seeds. FR-SEC-003.

---

## Phase 4 — Edge Limits In-App & Client-IP Trust (HUB / CNF; no LB, owner 2026-09-19)

- [~] T010 Partial (HUB lane, CLE-3393) — In-app edge limits (Cloud Armor superseded: owner 2026-09-19, no LB, API on Cloud Run domain mappings as csi-rel). Implemented: `internal/edge` Guard in front of the hub mux (85030d5): per-client-IP concurrent-socket cap, per-IP handshake rate and a global socket cap on `/v1/ws` + `/v1/wui/ws` (`429` + `Retry-After` before the upgrade), per-IP request rate on `/api/v1/auth/*` (preflights free), `SPOOL_HUB_HELLO_TIMEOUT` and ping liveness on both sockets; cnf `hub.env.SPOOL_HUB_EDGE_*` (caa0327): global cap 900 (< concurrency 1000), hello 10s, ping 30s/15s ON; per-IP caps `"0"` until T012 measures the hops. Cloud Run limits stay cnf `hub.cloud_run.*`: `max_instances=1` (OQ-05), `concurrency=1000`, `timeout_seconds=3600` — csi-rel's API runs 10 / 80 / 120 s, a request/response shape that does not fit a WebSocket hub. Check: `go test -run TestEdge ./internal/hub/` -> PASS (CONTROLS: limits off -> the n+1-th socket / auth request succeeds; on -> 429, and a rotated spoofed X-Forwarded-For stays 429; hops one too high shown spoofable; ping off keeps a dead peer's slot, on frees it). Missing: the 030 apply that puts the cnf keys on the service (CLE-3355, from trunk >= caa0327) and the per-IP values, which follow T012. FR-SEC-004.
- [x] T011 Superseded (owner 2026-09-19: no load balancer, no Cloud Armor, so there is no edge allowlist to narrow; the per-IP limits of T010 replace it). FR-SEC-004.
- [~] T012 Partial (HUB / CNF, CLE-3393) — Implemented: one knob `SPOOL_HUB_TRUSTED_PROXY_HOPS` (hub config) drives the edge limits and native auth; `SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` retired from cnf and refused by the hub when it disagrees (85030d5, caa0327); measurement probe `GET /v1/debug/client-ip` (+ `/api/v1/auth/client-ip`, the only prefix the WUI host's Firebase rewrite forwards) behind cnf `SPOOL_HUB_CLIENT_IP_PROBE`, read by `csi-spl-orc ./run -a do_spl_probe_client_ip` (measure + spoof-control modes). Check: `bash csi-spl-orc/src/bash/tests/spl-probe-client-ip.tst.sh` -> ALL PASS; `go test -run 'TestEdgeClientIPProbe|TestEdgeHopsTooHighIsSpoofable' ./internal/hub/` -> PASS. Missing: the measurement itself, n=0 — it needs the probe on the service (030 apply, CLE-3355) and the Cloud Run domain mapping in service (CLE-3382); hops stay `"0"` until then. TWO paths reach the hub (API domain mapping; WUI host `/api/v1/auth/**` via the Firebase rewrite) and their chains may differ: measure both, and turn the per-IP limits on only if one hops value keys both on the caller. FR-SEC-006.

---

## Phase 5 — Frontend Content Security Policy & Client Hardening (WUI)

- [~] T013 Partial (`59f26e1`; dev verified, prd deploy pending) — Hosting CSP (`csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`, which writes `csi-spl-wui/firebase.json`) has no `'unsafe-inline'`: `script-src`/`style-src` are `'self'` plus the sha256 of every inline `<script>`/`<style>` in the generated `.output/public` (no nonce: static hosting has no server). The render refuses without a bundle and on an `on*=`/`style=""` attribute. Checks: `node --test csi-spl-wui/tests/unit/csp-policy.test.mjs` -> 19 pass (mutation: `'unsafe-inline'` back in script-src -> 4 fail); `BASE_URL=https://csi-spl-dev-site.web.app node csi-spl-wui/tests/e2e/csp-violations.test.mjs` on dev build `59f26e1` (build.json) -> 0 violations on 7 routes, CONTROL injected inline script + `onerror` handler blocked (2 violation events). Before, on dev `a27e106` with `EXPECT_CONTROL=runs` -> both ran (n=1 each). Missing: prd, gated by cnf `019 wui_deploy` (CLE-3354). Styles need no `'unsafe-inline'`: 11 SFC `<style>` blocks, 0 `style=""` attributes. FR-SEC-005.
- [x] T014 Implemented (`59f26e1`) — `connect-src` from cnf only: `'self'` plus the hub api host(s) (`<label>.<BASE_DOMAIN>` from 031 `extra_host_labels` / 032 `api_host_label`) and the tenant hosts (`env.dns.mapped_tenants`, else `*.<fqdn>`), each `https://` + `wss://`; never a bare scheme. Check: `csp-policy.test.mjs` "connect-src" + "never a bare scheme" (dev and prd) pass; dev live header: `connect-src 'self' https://dev.api.<BASE_DOMAIN> wss://dev.api.<BASE_DOMAIN> https://*.dev.<BASE_DOMAIN> wss://*.dev.<BASE_DOMAIN>`. Residual: a CSP host wildcard matches any depth, so prd's `*.<BASE_DOMAIN>` also admits the dev hosts until tenants are enumerated in cnf. FR-SEC-005.

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
