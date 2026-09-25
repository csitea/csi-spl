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
| Nuxt shell, stores, components, pages | Implemented (live since P1/P2) | `csi-spl-wui/`; `cd csi-spl-wui && node --test tests/unit/*.test.mjs` → `# pass 1141 # fail 0` on `28442ef6` |
| Live client + viewer pages | Implemented (`9eafd8c`), live render waits on view-v1 | `/v1/view/*` plus `/v1/wui/ws`; `/`, `/t/[task_id]`, `/lobby`; 123 unit pass, e2e 12/12, typecheck exit 0 |
| Live follow | Implemented — `/t` and `/lobby` follow over `/v1/wui/ws` (013 newest-first); reconnect catch-up tasks T007 (A3) | `src/utils/live-follow.mjs` |
| orc lde actions | Implemented | `ls csi-spl-orc/src/bash/run/wui-*.func.sh` → 5 (`wui-{dev,test,build,up,down}.func.sh`) |
| Hosting terraform `016` / `019` | Implemented (tasks T009, T011) | `curl -s https://dev.spool-hub.ai/build.json` → 200 (2026-09-25) |
| Hub viewer API (view-v1) | Implemented (`ec3d593`; `/v1/view/topics` since `57f8a670`), token door OQ-16 open, owner decision (asked in topic 582f7895) | `grep -c 'HandleFunc("GET /v1/view' csi-spl-api/src/go/spool-hub-api/internal/hub/view.go -> 5`; live read verified (tasks T012) |
| Door (view token / session) | Partial — session door Implemented (003 T033b); token door OQ-16 | spec §5 G1 |
| Live dev hub (for SC-001) | Implemented | `curl -s https://dev.api.spool-hub.ai/v1/wui/pubkey` → 200 (2026-09-25) |

## Constitution check

- Paths / env: no `/opt/...` in app source; hub origin from env. ✔
- No key in git / state / log / browser: only UI preferences are stored (spec FR-003 list). ✔
- Uniform API, no invented fields: ✔ — `channel` / `parent_task_id` are hub-envelope
  fields (003 `channels-v1.md`, OQ-W1).
- Reference read-only (pas-psf / csi-rel copied, not imported). ✔

## Order of work

1. 003 implements view-v1 on trunk (dependency D1, not this spec).
2. T004 client: view-v1 §4.3 / §4.4 + `fileUrl` + bearer door; drop live channel/send paths (mock kept).
3. T005 / T006 viewer pages `/` and `/t/[task_id]`; `path`-mode attachments without a link.
4. T007 poll the open thread while visible.
5. T008 unit tests for the live client (stub `fetch`) + e2e no-x-scroll on the new pages.
6. T009 dev Hosting apply (owner go; after 007's DNS + ingress) and deploy.
7. T010 view-token entry (in-memory / `sessionStorage`) → T011 prd Hosting (after OQ-W2).
8. T025–T028 (WUI-UX): verbosity from `kind` + in-browser notifications with
   local read cursors (`./contracts/verbosity-notify-v1.md`). Independent of
   phase-3 channel/DM live wiring.

## Risks

- **Two read APIs — resolved**: 003 (CLE-3340) confirmed view-v1 lands and the
  GRK-3349 branch API (`/v1/threads`, no door) does not. lde gets
  `hub.view_door=off`, refused outside lde.
- **Custom domain vs hub host**: the hub answers `<tenant>.<fqdn>` (031); the
  Hosting custom domain is `env.dns.fqdn` (019). Both depend on the open DNS
  handoff question (README §6.1) — 007's, not 005's.

<!-- version: 1.5.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:35:51Z -->
