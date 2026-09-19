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
- [ ] T005 Planned (ORC / TESTS) — Add automated test `csi-spl-orc/src/bash/tests/spool-permissions.tst.sh` asserting `/var/spool-hub` disallows unauthorized non-group user access and enforces sticky or group isolation. FR-SEC-001.

---

## Phase 3 — API Surface & Blob Storage Access Control (API / HUB)

- [ ] T006 Planned (HUB lane) — Enhance `internal/hub/rest.go` `handleGetFile`: require valid session authentication (`s.sessionMayRead`) or bearer upload token (`s.bearer`) when `ViewDoor != ViewDoorOff`. Eliminate unauthenticated capability URL exposure. FR-SEC-002.
- [ ] T007 Planned (API TESTS) — Add unit and regression tests in `internal/hub/rest_test.go`: assert unauthenticated `GET /v1/files/{file_id}` returns `401 view_door` under `ViewDoorSession`. FR-SEC-002.
- [ ] T008 Planned (PAYMENTS lane) — Update `internal/payments/handler.go`: remove `root_private_key` from `TenantWelcome` email template and payload. Confine key reveal to the single interactive browser checkout session (`/checkout/success`). FR-SEC-003.
- [ ] T009 Planned (PAYMENTS TESTS) — Add regression test verifying `TenantWelcome` email body does not contain private key strings or base64 cryptographic seeds. FR-SEC-003.

---

## Phase 4 — Perimeter Defense & Network Hardening (IAC / CLOUD ARMOR)

- [ ] T010 Planned (IAC lane) — Update `csi-spl-iac/src/terraform/031-gcp-hub-ingress/03-cloud-armor.tf`: implement Cloud Armor rate-limiting security rule for `/v1/ws`, `/v1/wui/ws`, and `/api/v1/auth/*` to prevent connection exhaustion and brute-force attacks. FR-SEC-004.
- [ ] T011 Planned (CNF / DEPLOY) — Define production IP allowlists in `prd.env.yaml` to retire the temporary open `0.0.0.0/0` M1 ingress exception upon M2 sign-off. FR-SEC-004.
- [ ] T012 Planned (CNF / DEPLOY) — Calibrate `SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` in `dev.env.yaml` and `prd.env.yaml` to reflect the exact load balancer hops (Cloud Armor -> Cloud Run NEG), preventing IP spoofing in sliding-window rate limits. FR-SEC-006.

---

## Phase 5 — Frontend Content Security Policy & Client Hardening (WUI)

- [ ] T013 Planned (WUI lane) — Hardening of `csi-spl-wui/firebase.json`: remove `'unsafe-inline'` from CSP `script-src` and `style-src`; replace with build-time hashes or nonces. FR-SEC-005.
- [ ] T014 Planned (WUI lane) — Parameterize `connect-src` in `firebase.json` and Nuxt configuration to explicitly allow production tenant API and WebSocket origins while blocking untrusted external domains. FR-SEC-005.

---

## Phase 6 — CI/CD Pipeline & Invariant Verification (CI/CD / INTEGRATOR)

- [x] T015 Implemented (`internal/auth/password.go`, `native_config.go`) — Enforce minimum Argon2id parameters (m >= 19 MiB, t >= 2) and refuse debug tokens in production environments. Check: `go test -run TestNativeConfigValidate ./internal/auth/` -> PASS. FR-SEC-008.
- [x] T016 Implemented (`internal/store/postgres.go`) — Enforce parameterized database queries and prepared statements across all store operations, preventing SQL injection vulnerabilities. Check: `grep -rn "fmt.Sprintf.*SELECT" csi-spl-api/src/go/spool-hub-api/internal/store/` -> 0 hits. FR-SEC-010.
- [~] T017 Partial (`017-github-wif-deploy`, `20_hub-build-deploy.yml`) — Apply `017-github-wif-deploy` terraform in GCP and populate GitHub repository variables `GCP_WIF_PROVIDER_*` and `GCP_DEPLOY_SA_EMAIL_*` to transition automated deployment away from manual out-of-band triggers. FR-SEC-011.
- [x] T018 Implemented (`.github/workflows/10_ci-quality.yml`) — Distribution-hygiene automated sweep: zero personal names, literal OS users, personal home directories, or owner email addresses committed to version control. Check: `bash csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` -> PASS. FR-SEC-012.

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:00:00Z -->
