# Tasks: Spool WUI — read-only thread viewer first

**Feature**: `specs/005-spool-wui` · **Milestone**: M3 · **Redone**: 2026-09-18

Status is by **verification on trunk** (`bbc41e7` for the redo; `9eafd8c` for the viewer code), not by earlier reports
(`../README.md` §2.3). `[x]` Implemented (cited) · `[~]` Partial (missing part
named) · `[ ]` Planned. Live work is gated on D1.

## Phase 1 — Scaffold & lde

- [x] T001 Implemented — Nuxt 3 + TS strict + Pinia + pnpm scaffold (`csi-spl-wui/package.json`, `nuxt.config.ts`, `tsconfig.json`). FR-001.
- [x] T002 Implemented — lde `pnpm dev` (3000), `NUXT_PUBLIC_API_BASE`, `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build` (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 3`). FR-008.
- [x] T003 Implemented — `pnpm test:unit -> 17 pass, 0 fail`; e2e no-x-scroll for `/login`, `/channel/lobby` at 390×844 / 1280×800 (file present; not re-run in the redo). FR-009.

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

## Phase 4 — Live chat MVP (owner goal 2026-09-18; 003 `contracts/wui-live-ws.md`)

- [x] T021 Implemented (`580688e`, `5531927`) — browser WS client `utils/live-ws.mjs` to `ws(s)://<tenant>.<fqdn>/v1/wui/ws`: hello (`as` only when a v:1 agent id, else hub-assigned), welcome (`as`, `lobby_task_id`, upload token), subscribe, send (`kind` default `note`), ack/error, `token` refresh, capped reconnect + re-subscribe. 12 unit tests (fake WebSocket).
- [x] T022 Implemented (`b0bf6ab`) — `/lobby` and `/t/[task_id]` live: history via view-v1 §4.4, then live `message` frames appended (dedupe by `msg_id`); composer on top, newest first (`SPEC-spool-wui-layout.md`); `?as=HUM-n` identity.
- [x] T023 Implemented (`b0bf6ab`, `5531927`) — attach → `POST /v1/files` (Bearer upload token, refreshed when stale) → `files[]` refs in the send; Download fetches `GET /v1/files/{id}`, checks sha256, saves.
- [x] T024 Implemented — acceptance proven, n=1 each, 2026-09-18:
  - `pnpm test:live` (`tests/e2e/live-interop.test.mjs`, `6e07627`) against CLE-3340's lde hub at `c15cd64` (`/version` commit) → **12/12**: two sockets welcomed, lobby id from welcome, A→B and B→A live, `from`=HUM-801 `from_box`=box-wui, both persist via view-v1, upload content-addressed, B downloads identical bytes, and a **box agent post** (`spool send --from CLE-07 --to ALL-0 --to-box box-wui --task <lobby> --kind note`, `delivery: sent`) arrives live as `CLE-07@box-smoke`. Same suite 11/11 (no box step) against a trunk `spool serve` on the main lde database.
  - Chrome, two tabs on the real pages (WUI `NUXT_PUBLIC_USE_MOCK=0`, trunk hub, lde): `/lobby?as=HUM-12` posts text + `two.txt` (`sha256sum` → `78d26359…`) → appears **live** in the `HUM-11` tab (card `sha256 78d26359fa23`), HUM-11 Download → "Downloaded ✓" (in-browser sha256 matched); HUM-11 replies → appears live in the HUM-12 tab; reload → both messages present exactly once, identity kept.

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
- [x] P4 Implemented (`6618f03`) — notifications (`NotificationCenter.vue`, `stores/notification.ts`, `plugins/notify.client.ts`). Local cursors + mention/DM/#alerts escalation. Channel/DM live wiring stays phase-3. Check: `node --test tests/unit/notify.test.mjs tests/unit/read-cursor.test.mjs tests/unit/verbosity-notify-wire.test.mjs` → pass.
- [x] P5 Implemented (`7e3f9af`, `6618f03`) — verbosity toggle (`VerbositySelector.vue`) inferred from `kind`. Check: `node --test tests/unit/verbosity.test.mjs` → pass.
- [ ] P6 Planned — channel creation. Blocked: G3 (no route; `POST /v1/channels` does not exist).

## Phase 5 — Verbosity + in-browser notifications (WUI-UX, Gaps 6–7)

Contract: `contracts/verbosity-notify-v1.md`. Does not touch hub, rdb, iac,
channel/DM/roster stores, `wui-live-ws.md`, or `view-v1.md`.

- [x] T025 Implemented (`e70a9f6`) — spec amendment: US6 / US7, FR-013..015, OQ-W3/W4/W5 (a)
  chosen, P4/P5 unblocked. Check: `command grep -c OQ-W3 csi-spl-doc/specs/005-spool-wui/spec.md` → 5.
- [x] T026 Implemented (`7e3f9af`) — `csi-spl-wui/utils/verbosity.mjs`: `verbosityOf` / `applyVerbosity`
  from `kind` only; persist selector in `localStorage` `spool.verbosity` (try/catch).
  Table-driven unit test covers every v:1 kind from `internal/msg/msg.go` `validKinds`.
  `channel-feed.mjs` `applyVerbosity` delegates here. Check: `cd csi-spl-wui && node --test tests/unit/verbosity.test.mjs` → pass. FR-013, US6, P5.
- [x] T027 Implemented (`7e3f9af`) — `csi-spl-wui/utils/notify.mjs` + `utils/read-cursor.mjs`:
  escalate only on mention of signed-in `HUM-*` / DM / `#alerts`; unread per
  `ch:<slug>` / `dm:<peer>` from local cursors; chime opt-in default off.
  Check: `cd csi-spl-wui && node --test tests/unit/notify.test.mjs tests/unit/read-cursor.test.mjs` → pass. FR-014, FR-015, US7, P4.
- [x] T028 Implemented (`6618f03`) — wire `VerbositySelector.vue`, `ThreadPane.vue` /
  `LiveThreadPane.vue`, `NotificationCenter.vue`, `stores/notification.ts`,
  `stores/thread.ts`, sidebar unread badges; drop mock `[verbose]` body filter
  and the "task sent" ping. No mock-data import in those files. Check: `cd csi-spl-wui && node --test tests/unit/*.test.mjs` → 94 pass, 0 fail; `node tests/e2e/no-x-scroll.test.mjs` → 12/12. FR-013..015.

## Phase 6 — Donor WUI structure port (owner order 2026-09-19)

Owner: "use all of the available code in the donor WUI — the same stack, the
same vue app structure". Sources move under `csi-spl-wui/src/` (Nuxt
`srcDir: 'src/'`); every `csi-spl-wui/<dir>/…` path in the tasks above now
reads `csi-spl-wui/src/<dir>/…`. Package root, `firebase.json`,
`.output/public`, `tests/` and the orc/CI path consumers are unchanged.

- [x] T029 Implemented (`fff663d`) — `srcDir: 'src/'` layout, `@` alias, discovery unit runner `src/node/test/run-unit-tests.mjs` (`pnpm test:unit`). Check: `cd csi-spl-wui && pnpm test:unit` → all files pass; `pnpm typecheck` → 0.
- [x] T030 Implemented (`9fa748d`) — `nuxt.config.ts` donor shape: CSP_DEV/CSP_PROD + security headers as routeRules, vendor chunks, `@nuxtjs/i18n` (en only, `i18n/locales/en.json`). `tests/unit/csp-policy.test.mjs` pins CSP_PROD to `render-wui-firebase-json.sh`.
- [x] T031 Implemented (`37b453f`) — error stack: `errorJournal.mjs`, `ErrorNotice.vue` on every viewer/thread/lobby/channel/live-pane error, gated `DebugPanel.vue` (session claim `diagnostics_enabled === true`, fails shut), `error-journal.client.ts`, `error.vue`, `useSettledQuery` on the prerendered `/login` and `/`. Check: `node tests/unit/error-journal.test.mjs` → 19 pass.
- [x] T032 Implemented (`1f30c25`) — `SocialAuthButtons.vue` on `/login`, auth-v1 §4 endpoints and labels kept; `loadProviders()` tells auth-off from unreachable. Check: `node tests/unit/auth-client.test.mjs` → 12 pass.
- [x] T033 Implemented (`d1225e7`) — donor token scale + base rules on the spool palette. Check: `node tests/unit/theme-tokens.test.mjs` → pass.
- [x] T034 Implemented (`e300d5c`) — e2e: `console-errors` gate, shared `tests/e2e/lib/server.mjs`, `serve-generated.mjs`, `puppeteer-core`. Check: `pnpm test:e2e:console-errors` → 7/7; `pnpm test:e2e` → 12/12.
- [ ] T035 Open — `diagnostics_enabled` in the hub's session claims (010 auth-v1 §3) so an operator can be granted the panel; until then it is shown to nobody.

<!-- version: 1.7.0 · updated: 2026-09-19 · last-edit: 2026-09-19T09:40:00Z -->
