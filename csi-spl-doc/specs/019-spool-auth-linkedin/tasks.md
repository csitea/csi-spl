# Tasks: Sign in with LinkedIn (019)

**Feature**: `specs/019-spool-auth-linkedin` · **Lane**: CLE-3387 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane name the owner.

## Phase 1 — Spec

- [x] T001 Implemented (`ea6bf1e`) — spec.md, plan.md, owner-runbook.md, tasks.md. Check: `ls csi-spl-doc/specs/019-spool-auth-linkedin` → 4 files.

## Phase 2 — Hub (internal/auth)

- [x] T010 Implemented (e9815b8) — FR-L2: `validateProvider` case `linkedin` refuses scopes without `openid` + `email`. Check: `go test -run TestConfigLinkedInScopes ./internal/auth/` → ok (4 refused, default + reordered superset admitted).
- [x] T011 Implemented (same commit as T010) — FR-L1/FR-L3: `oidc_linkedin_test.go` pins the real endpoints + scopes and runs `Exchange` against a LinkedIn-shaped stub (client_secret_post checked, id_token in the token body, §1 claims): `email_verified` true / `"true"` admitted with name + avatar; `false`, `"false"`, missing, no email → `errEmailUnverified`; wrong secret → `errExchange`. Check: `go test -race -count=1 ./internal/auth/...` → ok. CONTROL (mutation, n=1): with the `email_verified` guard in `oidc.go` removed, 4 subtests FAIL.

## Phase 3 — Named action

- [x] T020 Implemented (3c388d9) — FR-L4: `IDP=<facebook|microsoft|linkedin|xai> ENV=<env> [DRY_RUN=0] ./run -a do_spl_auth_idp_secret_seed`: owner file `$HOME/.gcp/.csi/.spl/<idp>-client-<env>.json` (0600, client_id == cnf), project SA in a throwaway `CLOUDSDK_CONFIG`, `--account` on every secrets call, version only when sha256 differs, verified after the add; a bare-GUID Microsoft secret (Azure "Secret ID") refused (018's request). Check: `bash csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh` → `ALL PASS` (20 assertions); `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` → `17/17 test files passed`. CONTROL (mutation, n=1): client_id compare + dry-run gate removed → 2 FAIL.

## Phase 4 — Other lanes

- [x] T030 FR-L5 — Implemented as the WUI apex (owner 2026-09-19, 010 OQ-A2 / FR-010, csi-rel shape; GRK-3380, 2026-09-21). Hosting forwards `/api/v1/auth/**` to the hub, so the IdP callback stays same-origin on `https://<fqdn>/api/v1/auth/<p>/callback`. `wui_auth_base` is the api host (rewrite target). Check: `python3 -c` walk of `csi-spl-cnf/csi-spl/{dev,prd}.env.json` → LinkedIn redirect `https://dev.spool-hub.ai/api/v1/auth/linkedin/callback` / `https://spool-hub.ai/api/v1/auth/linkedin/callback`; `env.steps.019-firebase-static-site.wui_auth_base` → `https://dev.api.spool-hub.ai` / `https://api.spool-hub.ai`. API-host callback URI declined (`redirect_uri_mismatch` measured 2026-09-19). No cnf change.
- [x] T031 Implemented (`e8c2f75`, GRK-3371 for CLE-55) — LinkedIn [in] Logo (`#0A66C2`) next to `social_auth.continue_linkedin` in all 19 locales. Shows only when `/api/v1/auth/providers` lists `linkedin`. FR-L6. Check: `command grep -c social-logo-linkedin csi-spl-wui/src/components/SocialAuthButtons.vue` → 1; `cd csi-spl-wui && node --test tests/unit/auth-client.test.mjs` → pass.

## Phase 5 — Live (blocked on the owner: `~/.gcp/.csi/.spl/linkedin-client-{dev,prd}.json`)

- [ ] T050 Owner: `owner-runbook.md` §2–§3 for dev and prd.
- [ ] T051 dev: client id in `dev.env.yaml`, seed (`IDP=linkedin ENV=dev DRY_RUN=0`), list `linkedin`, deploy, SC-L3. The running hub image must be built from a tree containing `e9815b8` (T010): image blocker cleared by edf0991 (hub 0.1.6 = 4dc854e, which contains e9815b8; cnf tag 0.5.7 on 2026-09-25). Only the owner's LinkedIn app files remain (`linkedin` unlisted, client id `PLACEHOLDER-*` in dev and prd cnf).
- [ ] T052 prd: the same, after T051 and T030 are live in prd (OQ-L5).

## Spec sync 2026-09-25 (CLE-34983, tree bbe04d26)

- [x] T060 spec <-> code audit, n = every FR, SC and task row of 018 + 019. Implemented claims with no code: none (`go test -run 'Microsoft|LinkedIn|OIDC' ./internal/auth/` ok; `auth-demo` 5/5 providers; `auth-idp-secret-seed.tst.sh` ALL PASS). Fixed: status words on FR-011 / FR-L6 (e8c2f75), the callback host is decided (apex, Firebase rewrite), `auth.login_ok provider=` log field, shas for "this commit", the seed action's identity path, the cleared LinkedIn image blocker. Rollout rows stay **Planned** on the owner's app files: cnf lists only `google` in dev and prd (`yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_PROVIDERS' csi-spl-cnf/csi-spl/{dev,prd}.env.json` -> google, google).
<!-- version: 0.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:40:00Z -->
