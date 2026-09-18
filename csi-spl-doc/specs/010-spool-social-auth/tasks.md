# Tasks: Spool social sign-in (010)

**Feature**: `specs/010-spool-social-auth` · **Milestone**: M2 registration / M3 WUI login · **Created**: 2026-09-18

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane are written here, not done
here (§2.4); the owner is named.

## Phase 1 — Hub sign-in package + cnf (010, CLE-3346)

- [x] T001 Implemented (`9be4b71`) — `internal/auth/config.go`: `SPOOL_HUB_AUTH_*` via `caarlos0/env`, auth off when `SPOOL_HUB_AUTH_PROVIDERS=""`, fail-fast on an unset or `PLACEHOLDER-*` value of a listed provider, ≥32-byte session key, https in dev/prd, fake-IdP override refused in prd, planned providers refused. Check: `go test -run 'TestConfig' ./internal/auth/` → ok. FR-003, FR-007.
- [x] T002 Implemented (`9be4b71`) — signed state + browser-bound nonce cookie, single use, cross-provider replay refused (`token.go`, `handler.go`). Check: `go test -run TestStateCSRF ./internal/auth/` → ok (forged, other browser, cross-provider, replay, bad code). FR-002.
- [x] T003 Implemented (`9be4b71`) — Google code → token → userinfo, `email_verified` required (`idp.go`). FR-001, FR-004.
- [x] T004 Implemented (`9be4b71`) — Facebook Graph v25.0 code → token → `/me` with `appsecret_proof` (`idp.go`). FR-001, FR-004.
- [x] T005 Implemented (`9be4b71`) — `spool_session` signed cookie, `/session`, `/logout`, `SessionFromRequest`, `Registrar` hook, open-redirect guard. Check: `go test -run 'TestSignInEachProvider|TestTamperedSessionCookie|TestStartRedirectsToProvider' ./internal/auth/` → ok. FR-005, FR-006, FR-008 (hook only).
- [x] T006 Implemented (`9be4b71`) — `fakeidp` (Google + Facebook stand-in checking client id/secret, redirect URI, single-use code, bearer, appsecret_proof) and `cmd/auth-demo`. Check: `go run ./internal/auth/cmd/auth-demo` → `OK - both providers signed in against the fake IdP`. SC-001.
- [x] T007 Implemented (`9be4b71`) — tests green with the race detector: `go test -race -count=1 ./internal/auth/...` → ok; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` → `ALL csi-spl-api TESTS PASSED`.
- [x] T008 Implemented (`b5d0a9d`) — cnf `env.auth.social`: 13 env names (`yq '.env.auth.social.env | keys | length' csi-spl-cnf/csi-spl/all.env.yaml` → 13), `PLACEHOLDER-*` client ids, 3 Secret Manager slot ids under `secret_env`, dev/prd intended callback URIs, lde http values; `dev/prd.env.json` re-rendered. Not rendered into 030 (T020).

## Phase 2 — Hub mount + registration (003 CLE-3340, ids 004)

- [x] T010 Implemented (`bc6a6a1`, 003 T033a, CLE-3340) — `spool serve` runs `auth.Load(hc.Env)` and mounts `auth.New` via `hub.Options.Auth` before the middleware; routes answer on any Host. Check: `git grep -n 'auth.Load(hc.Env)' origin/master -- csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go` → 1 hit; `TestAuthMountedWithoutTenant` (unknown tenant host → `200 {"providers":[]}`). Registrar nil until T012.
- [~] T011 Partial (`6a43acb`, 003 T033b, CLE-3340) — the `/v1/view/*` door is the view token OR `ah.SessionForTenant(r, hostTenant)`, every error → `401 view_door`; admits nobody without a Membership (`TestViewSessionDoorFailsClosedWithoutMembership`). The access log carries no Cookie, Authorization or query string (`TestAccessLogCarriesNoCredentials`). OQ-A1 decided (a). Missing: credentialed CORS, which 003 switches on together with a wired Membership + Registrar (T012/T013).
- [ ] T012 Planned (003 + 004 + rdb) — store-backed `Registrar`: first callback creates `HUM-*` (narrative §0, §3.1), returns it into the session; needs a humans table (csi-spl-rdb) and 004's id rule (OQ-A3).
- [~] T013 Partial — seam Implemented (`5e8ecb1`): `auth.Options.Membership` (`Member(ctx, humanID, tenant) (bool, error)`) and `Handler.SessionForTenant`, fail-closed (no Membership, no `HUM-*`, lookup error, not a member all refuse; `session.t` never read). Check: `go test -run TestSessionForTenant ./internal/auth/` → ok. Missing: the store-backed `Membership` (003/006 + rdb), after T012. SEC-001.

## Phase 3 — WUI login (005 CLE-3342)

- [x] T014 Implemented (`1c4e1a6`, 005 CLE-3342) — `/login` renders one plain-link button per `GET /api/v1/auth/providers`, no SDK; empty list → "Sign-in is not available yet". Check (005's, n=1): `node --test tests/unit/*.test.mjs` → 39 pass (9 auth) on `44841b3`.
- [x] T015 Implemented (`1c4e1a6`, 005) — `auth_error` copy per contract §2, code dropped from the URL, `redirect` kept; session probe 200 in / 401 out / else unknown (prior state kept); sign out = `POST logout` → `/login`. Not yet verified with a real browser against the WUI (see T017).
- [x] T016 Implemented (`1c4e1a6` 005, `1dbc29a` 007) — checked-in `csi-spl-wui/firebase.json` and the deploy-time render `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` both send `/api/v1/auth/**` to the hub before the SPA `**` rule (`git grep -c api/v1/auth origin/master -- csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` → 2; `wui-actions.tst.sh` asserts it). FR-010.
- [x] T017 Implemented (005 CLE-3342, 2026-09-18 ~19:43Z, n=1 per provider) — lde browser round trip in Chrome: `auth-demo -addr 127.0.0.1:58181 -app-url http://localhost:3044 -public-url http://localhost:3044` (tree `193afcc`) + `nuxi dev` with `NUXT_DEV_AUTH_PROXY`. Google and Facebook both land on `/t/<id>` with `/api/v1/auth/session` 200; `spool_session` is absent from `document.cookie` (HttpOnly); sign out → session 401; `?auth_error=invalid_state` shows its copy, and the code is dropped while `redirect` is kept. How-to: `csi-spl-wui/README.md` (`eb6d3f6`), `quickstart.md` §2.3.

## Phase 4 — Infra (007 iac; apply is the owner-gated apply lane)

Recorded by 007 (CLE-3344) as its T066–T068 = these T020–T022, behind 007's M1 gaps; T067 folds into its 029 secrets step.

- [ ] T020 Planned (007) — render `env.auth.social.env` into 030 `environment_variables` (merge with `hub.env`) and `env.auth.social.secret_env` into `secret_environment_variables`; extend `tf-steps-render-and-validate.tst.sh` like its DSN assertion.
- [ ] T021 Planned (007) — three empty Secret Manager slots (`csi-spl-hub-auth-session-key`, `csi-spl-hub-auth-google-client-secret`, `csi-spl-hub-auth-facebook-client-secret`) + `roles/secretmanager.secretAccessor` for the hub runtime SA, per env; no version resource (like 040's DSN slot).
- [ ] T022 Planned (007) — derive `SPOOL_HUB_AUTH_APP_URL`, `SPOOL_HUB_AUTH_COOKIE_DOMAIN` and the two redirect URIs from `env.dns.fqdn` in `do_spl_merged_cnf` so the domain stays single-source; drop the literal values from dev/prd.env.yaml.

## Phase 5 — Registration day (owner; runbook `quickstart.md` §3)

- [ ] T030 Planned — Google Cloud console: OAuth consent screen + Web client per env; authorised redirect URI = cnf `SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI`.
- [ ] T031 Planned — Meta developers: one Consumer app (Facebook Login), valid OAuth redirect URIs = cnf `SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI` (dev + prd), privacy + data-deletion URLs, App Review for `email`, `public_profile`, then Publish.
- [ ] T032 Planned — add secret VERSIONS (session key, both client secrets) per env, out of band.
- [ ] T033 Planned — cnf: real client ids, `SPOOL_HUB_AUTH_PROVIDERS: google,facebook`; re-render json; push.
- [ ] T034 Planned — deploy and verify on dev, then prd (`quickstart.md` §3.5). SC-003.

## Phase 6 — Later, same rails

- [ ] T040 Planned — `microsoft` (Entra OIDC). T041 `linkedin`. T042 `xai` (issuer/authorize/token/jwks from cnf). Each: one `IdP` implementation, a `SPOOL_HUB_AUTH_<P>_*` block, a `fakeidp` path set, the same tests.
- [ ] T043 Planned — Facebook deauthorize + data-deletion callback (required for a live Meta app; csi-rel `facebook_callbacks.go` is the donor).
- [ ] T044 Planned — avatar: server-side fetch → `file_id` (narrative §3.4).

<!-- version: 0.5.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:47:09Z -->
