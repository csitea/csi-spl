# Tasks: 018 Spool sign-in with Microsoft

**Feature**: `specs/018-spool-auth-microsoft` · **Lane**: CLE-3386 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane are listed here but not done
here; each names its owner.

## Phase 0 — Spec

- [x] T001 Implemented (`c29e78c`) — spec.md, plan.md, tasks.md, azure-registration-runbook.md. Check: `ls csi-spl-doc/specs/018-spool-auth-microsoft/` → 4 files.

## Phase 1 — Hub code (CLE-3386)

- [x] T010 Implemented (`4dc854e`) — `config.go` Microsoft block: tenant `common` default, syntax (keyword or GUID), scopes ⊇ `openid email`, TRUST_EMAIL refused in prd. FR-001, FR-005, FR-007.
- [x] T011 Implemented (`4dc854e`) — `microsoft.go` AuthCodeURL: PKCE S256 from the HMAC-derived verifier, `prompt=select_account`, `response_mode=query`; `handler.go` `nonceExchanger`. FR-002.
- [x] T012 Implemented (`4dc854e`) — `idtoken.go` + `microsoft.go` exchange: RS256 + JWKS cache, `aud`/`iss`/`tid`/`nonce`/`exp`/`nbf`, tenant rule, `xms_edov` rule, subject `<tid>/<oid>`. FR-001, FR-003, FR-004, FR-005.
- [x] T013 Implemented (`4dc854e`) — `fakeidp`: Microsoft-shaped endpoints, RS256, JWKS, PKCE, per-person tenant / `xms_edov`, token tampering knobs; auth-demo still signs in all providers. FR-008.
- [x] T014 Implemented (`4dc854e`) — `microsoft_test.go`: SC-001 + SC-002, every negative case beside its positive control. Check (tree 4dc854e, n=1 each): `go test -race -count=1 ./internal/auth/...` → ok; `go test -count=1 -run Microsoft ./internal/auth/` → ok (TestMicrosoftSignIn, …WorkEmailNeedsVerifiedDomain, …TenantMode 9 cases, …IDTokenForgeriesRefused 17 forgeries, …PKCE, …JWKSCache, TestConfigMicrosoftTenant); `go run ./internal/auth/cmd/auth-demo` → `OK - all 5 providers signed in against the fake IdP`; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` → `ALL csi-spl-api TESTS PASSED`.
- [x] T015 Implemented (`f004b8b`) — cnf `all.env.yaml`: `SPOOL_HUB_AUTH_MICROSOFT_TENANT: common`, dev/prd json + 030 tfvars re-rendered by `ENV=<env> ./run -a do_tpl_gen`. Check: `yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_MICROSOFT_TENANT' csi-spl-cnf/csi-spl/prd.env.json` → `common`; `SPOOL_HUB_AUTH_PROVIDERS` unchanged (microsoft is listed nowhere).

## Phase 2 — Secret path and WUI (other lanes)

- [x] T020 Implemented by CLE-3387 (`3c388d9`, spec 019) — `do_spl_auth_idp_secret_seed` with `IDP=microsoft` and a bare-GUID Secret-ID refusal. FR-010. Check (re-run by CLE-3386 on 4dc854e, n=1): `bash csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh` → `auth-idp-secret-seed: ALL PASS` (21 PASS lines, including the microsoft Secret-ID refusal and its CONTROL).
- [x] T025 Implemented (`e8c2f75`, GRK-3371 for CLE-55) — Microsoft four-square MS-SymbolLockup in `SocialAuthButtons.vue`, `social_auth.continue_microsoft` = "Sign in with Microsoft" in all 19 locales, light-theme colours `#FFFFFF` / `#8C8C8C` / `#5E5E5E`. Shows only when `/api/v1/auth/providers` lists `microsoft`. FR-011. Check: `command grep -c social-logo-microsoft csi-spl-wui/src/components/SocialAuthButtons.vue` → 1; `cd csi-spl-wui && node --test tests/unit/auth-client.test.mjs` → pass (SocialAuthButtons marks advertised-only).

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

## Spec sync 2026-09-25 (CLE-34983, tree bbe04d26)

- [x] T060 spec <-> code audit, n = every FR, SC and task row of 018 + 019. Implemented claims with no code: none (`go test -run 'Microsoft|LinkedIn|OIDC' ./internal/auth/` ok; `auth-demo` 5/5 providers; `auth-idp-secret-seed.tst.sh` ALL PASS). Fixed: status words on FR-011 / FR-L6 (e8c2f75), the callback host is decided (apex, Firebase rewrite), `auth.login_ok provider=` log field, shas for "this commit", the seed action's identity path, the cleared LinkedIn image blocker. Rollout rows stay **Planned** on the owner's app files: cnf lists only `google` in dev and prd (`yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_PROVIDERS' csi-spl-cnf/csi-spl/{dev,prd}.env.json` -> google, google).
- [ ] T050 code tidy found by the sync: `jwksMaxBytes` (`idtoken.go`) is defined and never read (the 1 MiB cap is `readJSON`'s `io.LimitReader`); `EmailTrusted` (`oidc.go`) is never set true since Microsoft left `oidc.go` (4dc854e); `config.go` header still says "no PKCE". Owner: CLE-34983.
<!-- version: 0.2.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:40:00Z -->
