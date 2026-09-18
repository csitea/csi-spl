# Tasks: Spool WUI — read-only thread viewer first

**Feature**: `specs/005-spool-wui` · **Milestone**: M3 · **Redone**: 2026-09-18

Status is by **verification on trunk** (`bbc41e7` for the redo; `9eafd8c` for the viewer code), not by earlier reports
(`../README.md` §2.3). `[x]` Implemented (cited) · `[~]` Partial (missing part
named) · `[ ]` Planned. Live work is gated on D1.

## Phase 1 — Scaffold & lde

- [x] T001 Implemented — Nuxt 3 + TS strict + Pinia + pnpm scaffold (`csi-spl-wui/package.json`, `nuxt.config.ts`, `tsconfig.json`). FR-001.
- [x] T002 Implemented — lde `pnpm dev` (3000), `NUXT_PUBLIC_API_BASE`, `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build` (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 3`). FR-008.
- [x] T003 Implemented — `pnpm test:unit -> 17 pass, 0 fail`; e2e no-x-scroll for `/login`, `/channel/general` at 390×844 / 1280×800 (file present; not re-run in the redo). FR-009.

## Phase 2 — Viewer MVP (US1–US3, P1) 🎯

- [x] T004 Implemented (`9eafd8c`) — `utils/spool-client.mjs` live mode reads `/v1/view/threads`, `/v1/view/threads/{task_id}`, `/v1/view/channels`, `/v1/view/roster` with `Authorization: Bearer` and `credentials: 'omit'`; live send / channel creation / channel feeds throw `ReadOnlyError` (501) without a request; normalisers in `utils/view-api.mjs`. Check: `grep -c '/v1/messages\|/v1/channels' csi-spl-wui/utils/spool-client.mjs -> 0`. FR-002, FR-005.
- [x] T005 Implemented (`9eafd8c`, mock) — `pages/index.vue` thread list via `stores/viewer.ts`: empty state, `unknown_tenant` message, `Older` paging on `next`. Rendered against the mock tenant (headless Chrome screenshot, 4 threads). Live render waits on D1. US1.
- [x] T006 Implemented (`9eafd8c`, mock) — `pages/t/[task_id].vue` reuses `MessageCard.vue` / `KindBadge.vue` / `AgentBadge.vue`; `FileAttachment.vue` links only downloadable blobs (`isDownloadable`), `mode:"path"` shows the on-box path. Rendered against the mock tenant (4 messages oldest first, 1 attachment). US2, US3, FR-006.
- [x] T008 Implemented (`9eafd8c`) — `tests/unit/view-api.test.mjs` (12 tests: normalisers, stub-`fetch` live client, 401 token surfacing, read-only refusals, XSS-as-text); `node --test tests/unit/*.test.mjs -> 29 pass, 0 fail`; `node tests/e2e/no-x-scroll.test.mjs -> 8/8` (adds `/` and `/t/<id>`); `nuxi typecheck -> exit 0`. SC-002, FR-006.
- [ ] T012 Planned — SC-001 on dev: `spool send` box-a → box-b, thread visible in the viewer. Needs D1, D3.

## Phase 3 — Follow & ship (US4, US5)

- [~] T007 Partial (`9eafd8c`) — `/t/[task_id]` polls the thread while visible, `NUXT_PUBLIC_POLL_MS` (default 4000, floor 2000). Missing: `after=` cursor (full refetch today); the legacy `useSpoolEvents.ts` channel poll remains for the mock channel pages. US4.
- [~] T009 Partial — dev Hosting: apply 007 steps `016-firebase-deploy-iam` + `019-firebase-static-site` for dev (owner go) and deploy the generated site; hub origin derived per tenant. Missing: apply + deploy (`curl … https://csi-spl-dev-site.web.app -> 404`). FR-007, FR-004.
- [~] T010 Partial (`9eafd8c`) — `ViewTokenForm.vue` appears on `401`, stores the token in `sessionStorage` (`spool.view_token`) and memory. Missing: the hub door itself (003 T033, after OQ-16) and the social session (CLE-3346 hands the login contract). US5, FR-010.
- [ ] T011 Planned — prd Hosting apply + deploy, after T010 and OQ-W2. FR-007, FR-010.

## Dependencies owned elsewhere

- [ ] D1 003 — view-v1 implemented (door, CORS, §4.1–§4.4). Planned. CLE-3340 confirmed 2026-09-18T19:23Z: view-v1 is what lands, with an lde-only `hub.view_door=off` cnf flag; the GRK-3349 branch API (`/v1/threads`, `/v1/messages`) will not land.
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

<!-- version: 1.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:40:00Z -->
