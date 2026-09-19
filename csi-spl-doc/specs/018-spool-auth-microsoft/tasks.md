# Tasks: 018 Spool sign-in with Microsoft

**Feature**: `specs/018-spool-auth-microsoft` · **Lane**: CLE-3386 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane are listed here but not done
here; each names its owner.

## Phase 0 — Spec

- [ ] T001 spec.md, plan.md, tasks.md, azure-registration-runbook.md.

## Phase 1 — Hub code (CLE-3386)

- [ ] T010 `config.go` Microsoft block: tenant `common` default, syntax (keyword or GUID), scopes ⊇ `openid email`, TRUST_EMAIL refused in prd. FR-001, FR-005, FR-007.
- [ ] T011 `microsoft.go` AuthCodeURL: PKCE S256 from the HMAC-derived verifier, `prompt=select_account`, `response_mode=query`; `handler.go` `nonceExchanger`. FR-002.
- [ ] T012 `idtoken.go` + `microsoft.go` exchange: RS256 + JWKS cache, `aud`/`iss`/`tid`/`nonce`/`exp`/`nbf`, tenant rule, `xms_edov` rule, subject `<tid>/<oid>`. FR-001, FR-003, FR-004, FR-005.
- [ ] T013 `fakeidp`: Microsoft-shaped endpoints, RS256, JWKS, PKCE, per-person tenant / `xms_edov`, token tampering knobs; auth-demo still signs in all providers. FR-008.
- [ ] T014 `microsoft_test.go`: SC-001 + SC-002, every negative case beside its positive control. Suite green with `-race`.
- [ ] T015 cnf `all.env.yaml`: `SPOOL_HUB_AUTH_MICROSOFT_TENANT: common`, dev/prd json re-rendered.

## Phase 2 — Secret path and WUI (other lanes)

- [ ] T020 (CLE-3387, spec 019) `do_spl_auth_idp_secret_seed` with `IDP=microsoft` and a bare-GUID Secret-ID refusal. FR-010. Record the sha here once it lands.
- [ ] T025 (CLE-55, WUI) Microsoft button in `SocialAuthButtons.vue`: four-square mark, `social_auth.continue_microsoft` = "Sign in with Microsoft", Microsoft light-theme colours. FR-011.

## Phase 3 — Deferred

- [ ] T030 Planned (only if the owner asks) — the Graph photo as avatar (`User.Read` scope, authenticated fetch). FR-006.
- [ ] T031 Planned (only if the owner answers OQ-M4 (b)) — certificate credential (`private_key_jwt`).

## Phase 4 — Live (owner + deploy lane)

- [ ] T040 Owner — Azure app `spool-hub-dev` per `azure-registration-runbook.md` §2; file `$HOME/.gcp/.csi/.spl/microsoft-client-dev.json`.
- [ ] T041 Owner — the same for `spool-hub-prd`; `microsoft-client-prd.json`.
- [ ] T042 dev: seed (FR-010), cnf client id + `SPOOL_HUB_AUTH_PROVIDERS` += `microsoft`, render, 030 apply.
- [ ] T043 dev verify: SC-003 (providers, start Location, a real sign-in → `auth.login_ok`).
- [ ] T044 prd: as T042.
- [ ] T045 prd verify: as T043.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:40:00Z -->
