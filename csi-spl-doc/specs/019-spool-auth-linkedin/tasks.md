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

- [ ] T020 FR-L4: `do_spl_auth_idp_secret_seed` (`csi-spl-orc/src/bash/run/spl-auth-idp-secret-seed.func.sh`) + `csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh`.

## Phase 4 — Other lanes

- [ ] T030 FR-L5 — **CLE-3380**: callbacks derived on `https://api.<fqdn>/api/v1/auth/<p>/callback`.
- [ ] T031 FR-L6 — **CLE-55**: LinkedIn brand mark in `SocialAuthButtons.vue`.

## Phase 5 — Live (blocked on the owner: `~/.gcp/.csi/.spl/linkedin-client-{dev,prd}.json`)

- [ ] T050 Owner: `owner-runbook.md` §2–§3 for dev and prd.
- [ ] T051 dev: client id in `dev.env.yaml`, seed (`IDP=linkedin ENV=dev DRY_RUN=0`), list `linkedin`, deploy, SC-L3.
- [ ] T052 prd: the same, after T051 and T030 are live in prd (OQ-L5).

<!-- version: 0.1.0 · updated: 2026-09-19 -->
