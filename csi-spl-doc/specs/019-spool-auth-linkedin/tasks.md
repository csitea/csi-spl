# Tasks: Sign in with LinkedIn (019)

**Feature**: `specs/019-spool-auth-linkedin` · **Lane**: CLE-3387 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane name the owner.

## Phase 1 — Spec

- [x] T001 Implemented (`ea6bf1e`) — spec.md, plan.md, owner-runbook.md, tasks.md. Check: `ls csi-spl-doc/specs/019-spool-auth-linkedin` → 4 files.

## Phase 2 — Hub (internal/auth)

- [x] T010 Implemented (this commit, see `git log -1 -- csi-spl-api/src/go/spool-hub-api/internal/auth/oidc_linkedin_test.go`) — FR-L2: `validateProvider` case `linkedin` refuses scopes without `openid` + `email`. Check: `go test -run TestConfigLinkedInScopes ./internal/auth/` → ok (4 refused, default + reordered superset admitted).
- [x] T011 Implemented (same commit as T010) — FR-L1/FR-L3: `oidc_linkedin_test.go` pins the real endpoints + scopes and runs `Exchange` against a LinkedIn-shaped stub (client_secret_post checked, id_token in the token body, §1 claims): `email_verified` true / `"true"` admitted with name + avatar; `false`, `"false"`, missing, no email → `errEmailUnverified`; wrong secret → `errExchange`. Check: `go test -race -count=1 ./internal/auth/...` → ok. CONTROL (mutation, n=1): with the `email_verified` guard in `oidc.go` removed, 4 subtests FAIL.

## Phase 3 — Named action

- [x] T020 Implemented (see `git log -1 -- csi-spl-orc/src/bash/run/spl-auth-idp-secret-seed.func.sh`) — FR-L4: `IDP=<facebook|microsoft|linkedin|xai> ENV=<env> [DRY_RUN=0] ./run -a do_spl_auth_idp_secret_seed`: owner file `$HOME/.gcp/.csi/.spl/<idp>-client-<env>.json` (0600, client_id == cnf), project SA in a throwaway `CLOUDSDK_CONFIG`, `--account` on every secrets call, version only when sha256 differs, verified after the add; a bare-GUID Microsoft secret (Azure "Secret ID") refused (018's request). Check: `bash csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh` → `ALL PASS` (20 assertions); `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` → `17/17 test files passed`. CONTROL (mutation, n=1): client_id compare + dry-run gate removed → 2 FAIL.

## Phase 4 — Other lanes

- [ ] T030 FR-L5 — **CLE-3380**: callbacks derived on `https://api.<fqdn>/api/v1/auth/<p>/callback`.
- [x] T031 Implemented (`e8c2f75`, GRK-3371 for CLE-55) — LinkedIn [in] Logo (`#0A66C2`) next to `social_auth.continue_linkedin` in all 19 locales. Shows only when `/api/v1/auth/providers` lists `linkedin`. FR-L6. Check: `command grep -c social-logo-linkedin csi-spl-wui/src/components/SocialAuthButtons.vue` → 1; `cd csi-spl-wui && node --test tests/unit/auth-client.test.mjs` → pass.

## Phase 5 — Live (blocked on the owner: `~/.gcp/.csi/.spl/linkedin-client-{dev,prd}.json`)

- [ ] T050 Owner: `owner-runbook.md` §2–§3 for dev and prd.
- [ ] T051 dev: client id in `dev.env.yaml`, seed (`IDP=linkedin ENV=dev DRY_RUN=0`), list `linkedin`, deploy, SC-L3. The running hub image must be built from a tree containing `e9815b8` (T010): on 2026-09-19 both envs run `spool-hub:0.1.4` (`do_check_hub_deploy` → `current`, CI run 35445875372), a tag built before it, so the listing waits for the next `env.hub.image.tag` bump (deploy lane).
- [ ] T052 prd: the same, after T051 and T030 are live in prd (OQ-L5).

<!-- version: 0.1.0 · updated: 2026-09-19 -->
