# Tasks: Sign in with Facebook (049)

**Feature**: `specs/049-spool-auth-facebook` · **Lane**: CLE-35097 · **Created**: 2026-09-29

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3).

## Phase 1 — Spec

- [x] T001 spec.md, plan.md, owner-runbook.md, tasks.md.

## Phase 2 — Hub (internal/auth)

- [ ] T010 FR-F2/FR-F4: `facebook_test.go` runs `Facebook.Exchange` against a Graph-shaped stub (GET token with client secret, `/me` with `appsecret_proof`): success, no email, Graph error, silhouette; and the flow on the fake IdP: Facebook's own denial parameters, state mismatch. Each refusal has a passing control on the same rig.
- [ ] T011 FR-F6: the deletion status page answers HTML to a browser, JSON otherwise, 404 for an unknown code in both forms.

## Phase 3 — WUI

- [ ] T020 FR-F7: static `/privacy` and `/terms` (`csi-spl-wui/src/public/*.html`, no JavaScript), live on both envs before the owner switches the app to Live.

## Phase 4 — Per-tenant method policy

- [ ] T040 FR-F9 / §4: `tenants.auth_methods`, the `method_not_allowed` door in `ActiveTenant`, the tenant-settings checkboxes. Waits on OQ-F3.

## Phase 5 — Live (blocked on the owner: `owner-runbook.md`)

- [ ] T050 Owner: `owner-runbook.md` §2–§6, then the App ID and the secret (file or Secret Manager).
- [ ] T051 dev: App ID in `dev.env.yaml`, seed, list `facebook`, render, 030 apply, a real sign-in with a test Facebook account (SC-F2).
- [ ] T052 prd: the same after T051.

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T05:00:00Z -->
