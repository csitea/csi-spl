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
- [~] T012 Partial — SC-001 locally: the WUI in live mode (`NUXT_PUBLIC_USE_MOCK=0`) against a trunk `spool serve` (`ec3d593`+, `SPOOL_HUB_VIEW_DOOR=off`, lde Postgres holding tenant t1) lists the seeded thread `33330000-…-9001` (3 messages) and opens it oldest-first; CORS preflight from the WUI origin → `204` with the exact origin (headless Chrome screenshot + `curl`, n=1, 2026-09-18). Missing: the same on the dev cloud hub (D3).

## Phase 3 — Follow & ship (US4, US5)

- [x] T007 Implemented — `/t/[task_id]` polls while visible (`NUXT_PUBLIC_POLL_MS`, default 4000, floor 2000); after the first read it passes the last message `cursor` as `after=` and appends new messages, de-duplicated by `msg_id` (`stores/viewer.ts`); client test asserts `after=`; live hub returns `[]` for the last cursor (`curl`, n=1). The legacy `useSpoolEvents.ts` channel poll remains only for the mock channel pages. US4.
- [~] T009 Partial — dev Hosting: apply 007 steps `016-firebase-deploy-iam` + `019-firebase-static-site` for dev (owner go) and deploy the generated site with `NUXT_PUBLIC_API_BASE=https://{tenant}.<fqdn>` (tenant host, `67f6ff6`; read path still open, 007 T072). Missing: apply + deploy (`curl … https://csi-spl-dev-site.web.app -> 404`). FR-007, FR-004.
- [~] T010 Partial — view token: `ViewTokenForm.vue` on `401`, token kept in `sessionStorage` (`9eafd8c`). Social sign-in wired per spec 010 `contracts/auth-v1.md` §1–§4 (`1c4e1a6`: `/login` buttons from `GET /api/v1/auth/providers`, `auth_error` copy, session probe 401 vs unknown, sign out; Hosting rewrite `/api/v1/auth/**`; lde `NUXT_DEV_AUTH_PROXY`) — that is 010 T014–T016. lde browser round trip (010 T017) verified 2026-09-18 in Chrome, n=1 per provider: `auth-demo -addr 127.0.0.1:58181 -app-url/-public-url http://localhost:3044` + `NUXT_DEV_AUTH_PROXY` → `/login?redirect=/t/<id>` → Google / Facebook → fake IdP → lands on `/t/<id>`, `GET /api/v1/auth/session` 200 (`p` = google / facebook), cookie not readable from JS, sidebar shows the name; Sign out → 401 + `/login`; `?auth_error=invalid_state` shows its copy and is dropped from the URL with `redirect` kept. Missing: the hub view door (003 T033, after OQ-16) and how the session reaches `/v1/view/*` (010 OQ-A1). US5, FR-010.
- [ ] T011 Planned — prd Hosting apply + deploy, after T010 and OQ-W2. FR-007, FR-010.

## Dependencies owned elsewhere

- [x] D1 003 — view-v1 on trunk (`ec3d593`, per CLE-3340): `/v1/view/{roster,channels,threads,threads/{task_id}}`, cnf CORS allow-list, lde-only `SPOOL_HUB_VIEW_DOOR=off`. Verified live against a local trunk hub (T012). The token door is still pending OQ-16.
- [~] D2 010 (CLE-3346) — social sign-in routes + contract `auth-v1.md` on trunk (`d5e77eb`); WUI side wired (`1c4e1a6`). Open: 010 OQ-A1 (session → `/v1/view/*`).
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

<!-- version: 1.3.2 · updated: 2026-09-18 · last-edit: 2026-09-18T22:15:00Z -->
