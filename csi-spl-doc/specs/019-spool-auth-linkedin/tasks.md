# Tasks: Sign in with LinkedIn (019)

**Feature**: `specs/019-spool-auth-linkedin` · **Lane**: CLE-3387 · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). Tasks owned by another lane name the owner.

## Phase 1 — Spec

- [ ] T001 spec.md, plan.md, owner-runbook.md, tasks.md.

## Phase 2 — Hub (internal/auth)

- [ ] T010 FR-L2: `validateProvider` case `linkedin` — scopes must include `openid` and `email`, else boot fails. Test in `config_test.go`.
- [ ] T011 FR-L3: `oidc_linkedin_test.go` — LinkedIn-shaped userinfo (§1 claims): `email_verified` true / `"true"` admitted with name + avatar; `false`, missing, empty email → `email_unverified`, nothing registered.

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
