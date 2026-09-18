# Tasks: Spool WUI — read-only thread viewer first

**Feature**: `specs/005-spool-wui` · **Milestone**: M3 · **Redone**: 2026-09-18

Status is by **verification on trunk `bbc41e7`**, not by earlier reports
(`../README.md` §2.3). `[x]` Implemented (cited) · `[~]` Partial (missing part
named) · `[ ]` Planned. Live work is gated on D1.

## Phase 1 — Scaffold & lde

- [x] T001 Implemented — Nuxt 3 + TS strict + Pinia + pnpm scaffold (`csi-spl-wui/package.json`, `nuxt.config.ts`, `tsconfig.json`). FR-001.
- [x] T002 Implemented — lde `pnpm dev` (3000), `NUXT_PUBLIC_API_BASE`, `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build` (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 3`). FR-008.
- [x] T003 Implemented — `pnpm test:unit -> 17 pass, 0 fail`; e2e no-x-scroll for `/login`, `/channel/general` at 390×844 / 1280×800 (file present; not re-run in the redo). FR-009.

## Phase 2 — Viewer MVP (US1–US3, P1) 🎯

- [~] T004 Partial — `utils/spool-client.mjs` live mode: add view-v1 §4.3 thread list and §4.4 thread read with `Authorization: Bearer <view_token>`; remove live `/v1/channels`, `/v1/messages?channel=`, `POST /v1/messages`; mock mode keeps working. Missing: all of the live change (spec §5 G6). FR-002, FR-005.
- [ ] T005 Planned — page `/` = thread list (`stores/thread.ts`), empty state, unknown-tenant state. US1.
- [ ] T006 Planned — page `/t/[task_id]` = thread view reusing `MessageCard.vue`, `KindBadge.vue`, `AgentBadge.vue` (`<id>@<box>`); `FileAttachment.vue` links `mode:"blob"` to `GET /v1/files/{file_id}`, shows `mode:"path"` as text; body as text / sanitised markdown. US2, US3, FR-006.
- [ ] T008 Planned — unit tests for T004 with a stub `fetch` (URLs, empty lists, 404/400) and an XSS-as-text test; e2e no-x-scroll on `/` and `/t/<id>` (mock). SC-002, FR-006.
- [ ] T012 Planned — SC-001 on dev: `spool send` box-a → box-b, thread visible in the viewer. Needs D1, D3.

## Phase 3 — Follow & ship (US4, US5)

- [~] T007 Partial — poll the open thread while `document.visibilityState === 'visible'`. Missing: today `composables/useSpoolEvents.ts` polls channel + roster every 4 s. US4.
- [~] T009 Partial — dev Hosting: apply 007 steps `016-firebase-deploy-iam` + `019-firebase-static-site` for dev (owner go) and deploy the generated site; hub origin derived per tenant. Missing: apply + deploy (`curl … https://csi-spl-dev-site.web.app -> 404`). FR-007, FR-004.
- [ ] T010 Planned — door UI: view-token entry kept in memory / `sessionStorage` (view-v1 §2), `401 view_door` → re-prompt; social session later (006). US5, FR-010.
- [ ] T011 Planned — prd Hosting apply + deploy, after T010 and OQ-W2. FR-007, FR-010.

## Dependencies owned elsewhere

- [ ] D1 003 — view-v1 implemented (door, CORS, §4.1–§4.4). Planned: `grep -c '/v1/view' …/internal/hub/server.go -> 0`; branch `GRK-3349-hub-wui-read-api` (`2ecf59f`) implements a different API.
- [ ] D2 006 — human session (social IdP), view-v1's successor door.
- [ ] D3 007 — DNS zone + ingress (031) before a Hosting custom domain and a reachable dev hub (README §6).

## Planned — M3 later slices (mock-only code exists, no hub route)

Built against `utils/mock-data.mjs`; kept, not deleted; not live. Each waits on
the spec §5 gap named.

- [~] P1 Partial (mock) — channels sidebar + `/channel/[name]` (`ChannelSidebar.vue`, `stores/channel.ts`). Blocked: G3.
- [~] P2 Partial (mock) — DMs `/dm/[peer]` (`stores/roster.ts`). Blocked: G2, G4.
- [~] P3 Partial (mock) — composer + `@mention` (`MessageComposer.vue`, `utils/mention-autocomplete.mjs`). Blocked: G1, G2.
- [~] P4 Partial (mock) — notifications (`NotificationCenter.vue`, `stores/notification.ts`). Blocked: G3.
- [~] P5 Partial (mock) — verbosity toggle (`VerbositySelector.vue`). Blocked: metadata not in `v:1`.
- [ ] P6 Planned — channel creation. Blocked: G3 (no route; `POST /v1/channels` does not exist).

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
