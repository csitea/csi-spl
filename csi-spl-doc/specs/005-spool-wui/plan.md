# Implementation Plan: Spool WUI — read-only thread viewer first

**Feature ID**: `005-spool-wui` · **Status**: Partial · **Date**: 2026-09-18 (redo)

**Spec**: `./spec.md` · **Needs from 003**: `./contracts/hub-read-needs.md`
**Narrative**: `../../doc/md/SPEC-spool-wui.md` · **Rules / seams**: `../README.md`

## Summary

Point the existing `csi-spl-wui` Nuxt shell at 003's viewer API
(`../003-spool-message-bus/contracts/view-v1.md`), cut its
live surface to thread list + thread view + download, then ship it as a static
site on Firebase Hosting: dev first, then prd; every read carries the view-v1 door. The
Slack-like components already written against mock data stay in the tree,
mock-only, until their gaps (spec §5) close.

## Technical context

- **Stack**: Nuxt 3 (`^3.16`), Vue 3, TypeScript strict, Pinia, pnpm 9 — the
  pas-psf / csi-rel WUI shape (read-only reference).
- **Build / host**: `nuxt generate` → Firebase Hosting site `csi-spl-<env>-site`
  (007 step `019`, `site_id` validated in its `variables.tf`), deploy SA from step
  `016`; hub on Cloud Run (007 step `030`). Terraform and DNS belong to 007.
- **Runtime config**: `NUXT_PUBLIC_API_BASE`, `NUXT_PUBLIC_USE_MOCK` (`1` in
  `pnpm dev`, `0` in production builds — `nuxt.config.ts`).
- **Tests**: `node --test tests/unit/*.test.mjs`; `tests/e2e/no-x-scroll.test.mjs`.

## Verified state (2026-09-18, trunk `bbc41e7`)

| Item | Status | Evidence |
|---|---|---|
| Nuxt shell, stores, components, pages | Implemented (mock data only) | `csi-spl-wui/`; `pnpm test:unit -> 17 pass, 0 fail` |
| Live client | Partial — wrong routes | `utils/spool-client.mjs` calls `/v1/channels`, `/v1/messages?channel=`, `POST /v1/messages` |
| Live follow | Partial — polls channel + roster every 4 s | `composables/useSpoolEvents.ts` |
| orc lde actions | Implemented | `csi-spl-orc/src/bash/run/wui-{dev,test,build}.func.sh` |
| Hosting terraform `016` / `019` | Partial — written, not applied | `curl … https://csi-spl-dev-site.web.app -> 404` |
| Hub viewer API (view-v1) | Planned | `grep -c '/v1/view' …/internal/hub/server.go -> 0`; a non-matching API is on branch `GRK-3349-hub-wui-read-api` `2ecf59f` |
| Door (view token / session) | Planned | spec §5 G1 |
| Live dev hub (for SC-001) | exists, no ingress | integrator measurement 2026-09-18 ~19:00Z: Cloud Run `csi-spl-hub-dev` Ready, no LB (031 not applied) |

## Constitution check

- Paths / env: no `/opt/...` in app source; hub origin from env. ✔
- No key in git / state / log / browser: only the theme choice is stored. ✔
- Uniform API, no invented fields: ✘ today (mock + client use `channel` /
  `parent_task_id`) → T004–T006.
- Reference read-only (pas-psf / csi-rel copied, not imported). ✔

## Order of work

1. 003 implements view-v1 on trunk (dependency D1, not this spec).
2. T004 client: view-v1 §4.3 / §4.4 + `fileUrl` + bearer door; drop live channel/send paths (mock kept).
3. T005 / T006 viewer pages `/` and `/t/[task_id]`; `path`-mode attachments without a link.
4. T007 poll the open thread while visible.
5. T008 unit tests for the live client (stub `fetch`) + e2e no-x-scroll on the new pages.
6. T009 dev Hosting apply (owner go; after 007's DNS + ingress) and deploy.
7. T010 view-token entry (in-memory / `sessionStorage`) → T011 prd Hosting (after OQ-W2).

## Risks

- **Two read APIs**: view-v1 (contract of record) vs the GRK-3349 branch
  (`/v1/threads`, open, credentialed CORS). If the branch lands as-is the viewer
  would ship with no door. Reported to 003; 005 codes against view-v1 only.
- **Custom domain vs hub host**: the hub answers `<tenant>.<fqdn>` (031); the
  Hosting custom domain is `env.dns.fqdn` (019). Both depend on the open DNS
  handoff question (README §6.1) — 007's, not 005's.

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
