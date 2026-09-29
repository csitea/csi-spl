# Tasks: Sign in with Facebook (049)

**Feature**: `specs/049-spool-auth-facebook` · **Lane**: CLE-35097 · **Created**: 2026-09-29

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3).

## Phase 1 — Spec

- [x] T001 spec.md, plan.md, owner-runbook.md, tasks.md.

## Phase 2 — Hub (internal/auth)

- [x] T010 Implemented (CLE-35097, hub commit after `461fa46d`) — FR-F2/FR-F4: `facebook_test.go` runs `Facebook.Exchange` against a Graph-shaped stub (GET token with client secret, `/me` with `appsecret_proof`): success, no email, Graph error, silhouette; and the flow on the fake IdP: Facebook's own denial parameters, state mismatch. Each refusal has a passing control on the same rig. Check: `go test -race -count=1 -run 'TestFacebook|TestCallbackFailuresLandOnLogin' ./internal/auth/` → ok. CONTROL (mutation, n=1): the `email == ""` guard in `idp.go` removed → `no email` and `blank email` FAIL.
- [x] T011 Implemented (same commit) — FR-F6: the deletion status page answers HTML to a browser, JSON otherwise, 404 for an unknown code in both forms; `Content-Security-Policy: default-src 'none'`. Check: `go test -run TestFacebookMetaCallbacks ./internal/auth/` → ok.

## Phase 3 — WUI

- [x] T020 Implemented (`461fa46d`) — FR-F7: static `/privacy` and `/terms` (`csi-spl-wui/src/public/*.html`, no JavaScript), live on both envs before the owner switches the app to Live. Check: `node --test csi-spl-wui/tests/unit/legal-pages.test.mjs` → 8/8; CONTROL: an injected `<script>` fails it.

## Phase 4 — Per-tenant method policy

- [ ] T040 FR-F9 / §4: `tenants.auth_methods`, the `method_not_allowed` door in `ActiveTenant`, the tenant-settings checkboxes. Waits on OQ-F3.

## Phase 5 — Live (blocked on the owner: `owner-runbook.md`)

- [x] T050 Owner (2026-09-29): Meta app `spool-hub`, App ID 913022908351919, published. Secret handed over by file. Check: Graph `oauth/access_token?grant_type=client_credentials` with the App ID + secret -> app token OK, app name spool-hub (control: made-up App ID -> 101 Invalid Client ID). Open: App domains reads `spool-hub..ai` (typo, owner to fix).
- [x] T051 dev: App ID + `google,facebook` in cnf (`3587d960`); secret versions seeded dev + prd (sha256 verified); 030 applied (1 added, 1 changed; it also shipped SPL-1126/1128/1129). Check: `curl -s https://dev.spool-hub.ai/api/v1/auth/providers` -> google, facebook; the start redirect carries client_id 913022908351919 + the dev callback. **Not proven by a real sign-in on dev**: every owner try there ended at Meta's "Feature Unavailable" before the grant (no dev callback in the hub log). Closed on the owner's word ("you can close and mark all of the issues as done", 2026-09-29): the same app + config as prd, proven there.
- [x] T052 prd (`4133bfbc`, 030 applied on the owner's order): **proven**. Hub log 2026-09-29T18:28:30Z `GET /api/v1/auth/facebook/callback` 302, 18:28:32Z `auth.login_ok provider=facebook tenant=t1` (hub 2.5.4). The unblock was Meta granting advanced access: Graph `/913022908351919/permissions` -> email + public_profile live (only user_payment_tokens was live before). Issues SPL-402/403/404/405 + SPL-28 closed.

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T05:00:00Z -->
