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
- [x] T011 Implemented (`6a43acb` door seam, 003 T033b; `a74640b` HUMANS CLE-3351) — `SPOOL_HUB_VIEW_DOOR=session`: member sessions only on `/v1/view/*` and `/v1/wui/ws`, every refusal `401 view_door`; credentialed CORS (`Access-Control-Allow-Credentials: true`) for the exact allow-listed origins only, never reflected or `*`; the hub refuses to boot the session door without `SPOOL_HUB_AUTH_PROVIDERS` / `Options.Auth`. `token` (default) still admits a member session, without credentials. The access log carries no Cookie, Authorization or query string (`TestAccessLogCarriesNoCredentials`). FR-009, OQ-A1 (a). Check: `go test -count=1 -run 'SessionDoor' ./internal/hub/` → ok (`TestSessionDoorMemberReadsNonMemberRefused`: anonymous 401, member 200 + `Allow-Credentials: true`, **CONTROL** non-member with a valid session 401 `view_door` on view and ws; `TestSessionDoorNeedsAuth`).
- [x] T012 Implemented (`cf06dd5` rdb 0006, `ee9f4ca` store, `a74640b` wiring; HUMANS CLE-3351) — `store.Humans.Admit` + `store.AuthHooks` (auth.Registrar): the first callback mints `HUM-<n>` (`humans_seq`, OQ-A3 (a)), idempotent on `(provider, subject)`, never linked by email; with `?tenant=` the human must be admitted (FR-014: member / unexpired invite on the verified email / bootstrap owner on a zero-member tenant), else `auth_error=not_allowed` and nothing is written. Postgres serialises per identity (advisory xact lock) and per tenant (row lock: one bootstrap owner). `password` (015) is a provider like any other. Check: `SPOOL_TEST_PG_DSN=<pg16> go test -count=1 -run Humans ./internal/store/` → ok (memory + postgres); `go test -count=1 -run TestStoreBackedRegistrarAndMembership ./internal/auth/` → ok.
- [x] T013 Implemented (`5e8ecb1` seam, `ee9f4ca` store, `a74640b` wiring; HUMANS CLE-3351) — `store.AuthHooks.Member` over `tenant_memberships` (asked on every request, so a removed or disabled human is out at once; lookup error fails closed), wired as `auth.Options.Membership` in `cmd/spool/hub.go`; the same hooks are `auth.Options.Unlinker` for 010 FR-013. FR-015: a member session's `HUM-*` overrides the asserted `hello.as` on `/v1/wui/ws` (mutation-checked: removing the override fails the test). Check: `go test -count=1 ./internal/auth/ ./internal/store/` → ok; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` → `ALL csi-spl-api TESTS PASSED` on `bda54ab`. SEC-001.
- [x] T018 Implemented (`bda54ab`, HUMANS CLE-3351) — `spool hub-invite --tenant <id> --email <addr> [--role owner|member] [--ttl 168h]` (via `$SPOOL_HUB_DB_DSN`): the prd way to seat a first owner while bootstrap is off (FR-014, OQ-A5). Check: `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` → `ok - spool hub-invite: invite for an existing tenant, unknown tenant refused`.
- [ ] T019 Planned (owner + DEPLOY CLE-3355) — turn the door on per env: dev `SPOOL_HUB_VIEW_DOOR=session` + `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true` once a provider is live on dev (T033, or 015 password); prd `session` after T034, with bootstrap `false` and the first owner by `spool hub-invite` (OQ-A5). Flipping the door before a provider is listed fails the boot on purpose.

## Phase 3 — WUI login (005 CLE-3342)

- [x] T014 Implemented (`1c4e1a6`, 005 CLE-3342) — `/login` renders one plain-link button per `GET /api/v1/auth/providers`, no SDK; empty list → "Sign-in is not available yet". Check (005's, n=1): `node --test tests/unit/*.test.mjs` → 39 pass (9 auth) on `44841b3`.
- [x] T015 Implemented (`1c4e1a6`, 005) — `auth_error` copy per contract §2, code dropped from the URL, `redirect` kept; session probe 200 in / 401 out / else unknown (prior state kept); sign out = `POST logout` → `/login`. Not yet verified with a real browser against the WUI (see T017).
- [x] T016 Implemented (`1c4e1a6` 005, `1dbc29a` 007) — checked-in `csi-spl-wui/firebase.json` and the deploy-time render `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` both send `/api/v1/auth/**` to the hub before the SPA `**` rule (`git grep -c api/v1/auth origin/master -- csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` → 2; `wui-actions.tst.sh` asserts it). FR-010.
- [x] T017 Implemented (005 CLE-3342, 2026-09-18 ~19:43Z, n=1 per provider) — lde browser round trip in Chrome: `auth-demo -addr 127.0.0.1:58181 -app-url http://localhost:3044 -public-url http://localhost:3044` (tree `193afcc`) + `nuxi dev` with `NUXT_DEV_AUTH_PROXY`. Google and Facebook both land on `/t/<id>` with `/api/v1/auth/session` 200; `spool_session` is absent from `document.cookie` (HttpOnly); sign out → session 401; `?auth_error=invalid_state` shows its copy, and the code is dropped while `redirect` is kept. How-to: `csi-spl-wui/README.md` (`eb6d3f6`), `quickstart.md` §2.3.

## Phase 4 — Infra (007 iac; apply is the owner-gated apply lane)

Recorded by 007 (CLE-3344) as its T066–T068 = these T020–T022, behind 007's M1 gaps; T067 folds into its 029 secrets step.

- [x] T020 Implemented (`19914c1`, `eccb5a1`, IDP lane CLE-3353) — the 030 template merges `env.auth.social.env`, `env.auth.native.env` and `env.mail.env` into `environment_variables`; it injects the session key only when a provider is listed or native sign-in is enabled, each LISTED provider's client secret, and the SMTP password only while `SPOOL_HUB_MAIL_TRANSPORT=smtp`, because Cloud Run refuses a revision whose secret has no version. Check: `bash csi-spl-iac/src/bash/tests/hub-auth-030.tst.sh` → `PASS: all hub-auth-030.tst.sh assertions` (controls: `providers=google,xai` injects exactly those two secrets + the session key; native on + smtp injects the session key + the SMTP password).
- [x] T021 Implemented (`19914c1`, `eccb5a1`) — 030 `06-auth-secret-slots.tf`: 7 empty slots (session key, 5 IdP client secrets, `csi-spl-hub-mail-smtp-password`), no version resource. The accessor binding stays scoped to the injected secrets (`03-runtime-sa.tf`, which now depends on the slots). There is no `029` step to fold this into (007 T060 not started). Check: `grep -c csi-spl-hub- csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars` → the `auth_secret_ids` line lists 7. Not applied: DEPLOY's 030 apply, which waits on the owner's gcloud login.
- [ ] T022 Planned (007) — derive `SPOOL_HUB_AUTH_APP_URL`, `SPOOL_HUB_AUTH_COOKIE_DOMAIN` and the two redirect URIs from `env.dns.fqdn` in `do_spl_merged_cnf` so the domain stays single-source; drop the literal values from dev/prd.env.yaml.

## Phase 5 — Registration day (owner; runbook `quickstart.md` §3)

Owner runbook for T030–T034, all five providers: `idp-registration-runbook.md`.

- [ ] T030 Planned — Google Cloud console: OAuth consent screen + Web client per env; authorised redirect URI = cnf `SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI`.
- [ ] T031 Planned — Meta developers: one Consumer app (Facebook Login), valid OAuth redirect URIs = cnf `SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI` (dev + prd), privacy + data-deletion URLs, App Review for `email`, `public_profile`, then Publish.
- [ ] T032 Planned — add secret VERSIONS (session key, both client secrets) per env, out of band.
- [ ] T033 Planned — cnf: real client ids, `SPOOL_HUB_AUTH_PROVIDERS: google,facebook`; re-render json; push.
- [ ] T034 Planned — deploy and verify on dev, then prd (`quickstart.md` §3.5). SC-003.

## Phase 6 — Later, same rails

- [x] T040 Implemented (`f17210e`, IDP lane CLE-3353) — `microsoft` on the generic OIDC client (`internal/auth/oidc.go`). Authority `SPOOL_HUB_AUTH_MICROSOFT_TENANT` defaults to `consumers`; any other tenant is refused at boot unless `SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL=true` (spec OQ-I1). Check: `go test -run 'TestConfigMicrosoftTenantTrust|TestOIDC' ./internal/auth/` → ok.
- [x] T041 Implemented (`f17210e`) — `linkedin` on the generic OIDC client, `email_verified=true` required. Check: `go test -run TestOIDCEmailVerification ./internal/auth/` → ok.
- [x] T042 Implemented (`f17210e`) — `xai` on the generic OIDC client. Its endpoints come only from cnf (`SPOOL_HUB_AUTH_XAI_{AUTH,TOKEN,USERINFO}_URL`), https is required, and there is no Go default. xAI does publish an OIDC issuer (`curl -s https://auth.x.ai/.well-known/openid-configuration` → 200, n=1, 2026-09-19); whether it registers third-party clients is spec OQ-I2. `plannedProviders` is empty. Check: `command grep -n 'plannedProviders = ' csi-spl-api/src/go/spool-hub-api/internal/auth/config.go` → `map[string]bool{}`; `go test -run TestConfigOIDC ./internal/auth/` → ok. CONTROL: `TestOIDCBadStateOrNonceRefused` refuses a forged state, another browser's nonce, a tampered nonce cookie and a state minted for google, per provider, and admits the genuine flow. Mutation-checked once: with the cookie check disabled, 6 subtests fail.
- [x] T043 Implemented (`f17210e`, flake fixed `f869bc3`) — `POST /api/v1/auth/facebook/{deauthorize,data-deletion}` verify the `signed_request` HMAC first and fail closed with `400`, then call `Options.Unlinker` (HUMANS wires the store's `UnlinkIdentity`). Data-deletion returns `{url, confirmation_code}` with a self-verifying code; `GET …/data-deletion?code=` answers 200 or 404. Check: `go test -count=300 -run TestFacebookMetaCallbacks ./internal/auth/` → ok. `go run ./internal/auth/cmd/auth-demo` → `OK - all 5 providers signed in against the fake IdP`.
- [ ] T044 Planned — avatar: server-side fetch → `file_id` (narrative §3.4).

<!-- version: 0.7.0 · updated: 2026-09-19 -->
