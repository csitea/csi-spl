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

- [x] T004 Implemented (`9eafd8c`) — `utils/spool-client.mjs` live mode reads `/v1/view/threads`, `/v1/view/threads/{task_id}`, `/v1/view/channels`, `/v1/view/roster` with `Authorization: Bearer` and `credentials: 'omit'`; normalisers in `utils/view-api.mjs`. **Superseded by A1 (`2b74ce3`, CLE-3362 2026-09-19):** `ReadOnlyError` is gone. The live client does the following: `listMessages({channel})` → `/v1/view/threads?channel=` and DMs → `?dm=true&peer=`; `createChannel` → `POST /v1/channels` (`409 channel_exists` / `400 bad_channel` kept); `listChannels({read})` → `read=<ch>~<cursor>`, keeping `unread` / `last_cursor` / `retention_days`; `sendMessage` goes over the WUI socket with `channel` / `parent_task_id`; view rows, envelopes and WS frames keep `channel` / `parent_task_id`. Check: `command grep -c "ReadOnlyError('a channel" csi-spl-wui/src/utils/spool-client.mjs -> 0`; `cd csi-spl-wui && node --test tests/unit/*.test.mjs -> 176 pass, 0 fail` (on `69cbe65`). FR-002, FR-005.
- [x] T005 Implemented (`9eafd8c`, mock) — `pages/index.vue` thread list via `stores/viewer.ts`: empty state, `unknown_tenant` message, `Older` paging on `next`. Rendered against the mock tenant (headless Chrome screenshot, 4 threads). Live render waits on D1. US1.
- [x] T006 Implemented (`9eafd8c`, mock) — `pages/t/[task_id].vue` reuses `MessageCard.vue` / `KindBadge.vue` / `AgentBadge.vue`; `FileAttachment.vue` links only downloadable blobs (`isDownloadable`), `mode:"path"` shows the on-box path. Rendered against the mock tenant (4 messages oldest first, 1 attachment). US2, US3, FR-006.
- [x] T008 Implemented (`9eafd8c`) — `tests/unit/view-api.test.mjs` (12 tests: normalisers, stub-`fetch` live client, 401 token surfacing, read-only refusals, XSS-as-text); `node --test tests/unit/*.test.mjs -> 29 pass, 0 fail`; `node tests/e2e/no-x-scroll.test.mjs -> 8/8` (adds `/` and `/t/<id>`); `nuxi typecheck -> exit 0`. SC-002, FR-006.
- [x] T012 Implemented — SC-001 locally: the WUI in live mode (`NUXT_PUBLIC_USE_MOCK=0`) against a trunk `spool serve` (`ec3d593`+, `SPOOL_HUB_VIEW_DOOR=off`, lde Postgres holding tenant t1) lists the seeded thread `33330000-…-9001` (3 messages) and opens it oldest-first; CORS preflight from the WUI origin → `204` with the exact origin (headless Chrome screenshot + `curl`, n=1, 2026-09-18). **dev (D3), 2026-09-19 (CLE-3372, n=2):** `box-e2e-a` → `box-e2e-b` `spool send` on hub `0.1.4` (`b067cfd`) tenant t1 is listed by the dev WUI (`csi-spl-dev-site.web.app`, Chrome) and opens on `/t/<id>` "newest first". Check: `./run -a do_spl_m3_e2e` step `a-box-to-box` PASS (`../014-spool-wui-dispatch/acceptance-dev.md`).

## Phase 3 — Follow & ship (US4, US5)

- [x] T007 Partial — `/t/[task_id]` polls while visible (`NUXT_PUBLIC_POLL_MS`, default 4000, floor 2000); after the first read it passes the last message `cursor` as `after=` and appends new messages, de-duplicated by `msg_id` (`stores/viewer.ts`); client test asserts `after=`; live hub returns `[]` for the last cursor (`curl`, n=1). The legacy `useSpoolEvents.ts` channel poll remains only for the mock channel pages. US4. — **Audit CLE-3358 2026-09-19 (tree c777a2f): not as written.** `command grep -rn pollMs csi-spl-wui/src` → 0; `/t/[task_id]` follows over the WS (`useLiveFeed('main')`), `viewer.refreshThread` has no caller, and there is no `after=` catch-up after a WS reconnect (gap list: G-A). — **Done by A3 (CLE-3368, `ccc8117`, `4c9619e`, `901ea06`):** after a WS reconnect (live-ws `onReconnected`) the live store does one `getThread(id,{after:<last cursor>})` deduped by `msg_id` (`utils/live-follow.mjs` `catchUp`); a 401 `view_door` on `/t`, `/lobby`, `/` and the thread pane shows the door prompt (sign-in link `/login?redirect=&tenant=` and/or view token); `/t` has the verbosity selector; roster `online` follows `presence` frames. Check: `cd csi-spl-wui && node --test tests/unit/live-follow.test.mjs` → 18 pass; lde hub `t1.localhost:58081`: forced WS drop recovered the missed row, 0 dups (n=2), presence HUM-32 on→off (n=1).
- [x] T009 Implemented (GRK-3380, 2026-09-21) — dev Hosting live: `curl -s https://dev.spool-hub.ai/build.json` → `{"commit":"44e94470cb90a1bce16db55d0fa23c0c4b6b1ba2","built_at":"2026-09-21T12:57:19Z","run":"35602385949"}`; `https://csi-spl-dev-site.web.app/build.json` 200, same commit+run. FR-007, FR-004.
- [~] T010 Partial — view token: `ViewTokenForm.vue` on `401`, token kept in `sessionStorage` (`9eafd8c`). Social sign-in wired per spec 010 `contracts/auth-v1.md` §1–§4 (`1c4e1a6`: `/login` buttons from `GET /api/v1/auth/providers`, `auth_error` copy, session probe 401 vs unknown, sign out; Hosting rewrite `/api/v1/auth/**`; lde `NUXT_DEV_AUTH_PROXY`) — that is 010 T014–T016. lde browser round trip (010 T017) verified 2026-09-18 in Chrome, n=1 per provider: `auth-demo -addr 127.0.0.1:58181 -app-url/-public-url http://localhost:3044` + `NUXT_DEV_AUTH_PROXY` → `/login?redirect=/t/<id>` → Google / Facebook → fake IdP → lands on `/t/<id>`, `GET /api/v1/auth/session` 200 (`p` = google / facebook), cookie not readable from JS, sidebar shows the name; Sign out → 401 + `/login`; `?auth_error=invalid_state` shows its copy and is dropped from the URL with `redirect` kept. Missing: the hub view door (003 T033, after OQ-16) and how the session reaches `/v1/view/*` (010 OQ-A1). US5, FR-010.
- [x] T011 Implemented (GRK-3380, 2026-09-21) — prd Hosting live: `curl -s https://spool-hub.ai/build.json` → `{"commit":"44e94470cb90a1bce16db55d0fa23c0c4b6b1ba2","built_at":"2026-09-21T12:57:26Z","run":"35602385949"}` (same commit+run as dev). `https://csi-spl-prd-site.web.app/build.json` 200, same. FR-007, FR-010.

## Phase 4 — Live chat MVP (owner goal 2026-09-18; 003 `contracts/wui-live-ws.md`)

- [x] T021 Implemented (`580688e`, `5531927`) — browser WS client `utils/live-ws.mjs` to `ws(s)://<tenant>.<fqdn>/v1/wui/ws`: hello (`as` only when a v:1 agent id, else hub-assigned), welcome (`as`, `lobby_task_id`, upload token), subscribe, send (`kind` default `note`), ack/error, `token` refresh, capped reconnect + re-subscribe. 12 unit tests (fake WebSocket).
- [x] T022 Implemented (`b0bf6ab`) — `/lobby` and `/t/[task_id]` live: history via view-v1 §4.4, then live `message` frames appended (dedupe by `msg_id`); composer on top, newest first (`SPEC-spool-wui-layout.md`); `?as=HUM-n` identity.
- [x] T023 Implemented (`b0bf6ab`, `5531927`) — attach → `POST /v1/files` (Bearer upload token, refreshed when stale) → `files[]` refs in the send; Download fetches `GET /v1/files/{id}`, checks sha256, saves.
- [x] T024 Implemented — acceptance proven, n=1 each, 2026-09-18:
  - `pnpm test:live` (`tests/e2e/live-interop.test.mjs`, `6e07627`) against CLE-3340's lde hub at `c15cd64` (`/version` commit) → **12/12**: two sockets welcomed, lobby id from welcome, A→B and B→A live, `from`=HUM-801 `from_box`=box-wui, both persist via view-v1, upload content-addressed, B downloads identical bytes, and a **box agent post** (`spool send --from CLE-07 --to ALL-0 --to-box box-wui --task <lobby> --kind note`, `delivery: sent`) arrives live as `CLE-07@box-smoke`. Same suite 11/11 (no box step) against a trunk `spool serve` on the main lde database.
  - Chrome, two tabs on the real pages (WUI `NUXT_PUBLIC_USE_MOCK=0`, trunk hub, lde): `/lobby?as=HUM-12` posts text + `two.txt` (`sha256sum` → `78d26359…`) → appears **live** in the `HUM-11` tab (card `sha256 78d26359fa23`), HUM-11 Download → "Downloaded ✓" (in-browser sha256 matched); HUM-11 replies → appears live in the HUM-12 tab; reload → both messages present exactly once, identity kept.

## Dependencies owned elsewhere

- [x] D1 003 — view-v1 on trunk (`ec3d593`, per CLE-3340): `/v1/view/{roster,channels,threads,threads/{task_id}}`, cnf CORS allow-list, lde-only `SPOOL_HUB_VIEW_DOOR=off`. Verified live against a local trunk hub (T012). The token door is still pending OQ-16.
- [~] D2 010 (CLE-3346) — social sign-in routes + contract `auth-v1.md` on trunk (`d5e77eb`); WUI side wired (`1c4e1a6`). 010 OQ-A1 is DECIDED (a) and the hub implements the session door; WUI half done. `credentialsFor(door)` / `setDoor('session')` in `src/utils/spool-client.mjs` give `credentials:'include'` for the session door, and `'omit'` otherwise (A1 `2b74ce3`). A3 retries with it on a 401 (`4c9619e`). Check: `command grep -c "credentialsFor" csi-spl-wui/src/utils/spool-client.mjs -> ≥1`. Still open, owner-gated: the session door switched on in dev/prd (010 T013, B5). (Audit CLE-3358 2026-09-19 (tree c777a2f); A1 CLE-3362 2026-09-19)
- [x] D3 007 — DNS zone + ingress (031) and Hosting custom domains live (GRK-3380, 2026-09-21): `curl -s https://dev.spool-hub.ai/build.json` and `https://spool-hub.ai/build.json` both return commit `44e94470cb90a1bce16db55d0fa23c0c4b6b1ba2` run `35602385949`.

## Planned — M3 later slices (mock-only code exists, no hub route)

Built against `utils/mock-data.mjs`; kept, not deleted; not live. Each waits on
the spec §5 gap named.

- [x] P1 Implemented (`69cbe65`, `1899368`; A1 client `2b74ce3`) — channels sidebar + `/channel/[name]` render live hub data (`stores/channel.ts`: A1 `listMessages({channel})`, one card per `task_id`; WS frames merged, the feed subscribes its threads; own send from the hub ack). The 4 s poll runs for the mock tenant only (`composables/useSpoolEvents.ts`). The 013 reverse flow on `/channel` / `/dm` is NOT here: decision X3 (owner). Check: `cd csi-spl-wui && node --test tests/unit/channel-feed.test.mjs` → pass; lde: worktree dev WUI on the main hub, `#a2-proof-0919` send rendered without reload (Gap lane A2, 2026-09-19).
- [x] P2 Implemented (`69cbe65`, `1899368`) — DMs `/dm/[peer]` live: A1 `?dm=true&peer=` feed, WS send with `to=<peer>`, frames routed by `belongsTo`. Presence frames: `stores/roster.ts` `live.onPresence` (A1/A3 lane). Check: `cd csi-spl-wui && node --test tests/unit/channel-feed.test.mjs` → pass; lde `/dm/GRK-03%40box-smoke` renders the hub thread (Gap lane A2, 2026-09-19).
- [x] P3 Implemented (GRK-3380, 2026-09-21) — composer + `@mention` (`MessageComposer.vue`, `utils/mention-autocomplete.mjs`); live send is channel-scoped. Check: `command grep -n channel csi-spl-wui/src/stores/live.ts` → `send(body, files, opts:{parentTaskId?, channel?})` (line 166) and `const channel = opts.channel || undefined` (line 186); `client.send` carries `channel`.
- [x] P4 Implemented (`6618f03`, `1f7329d`, `69cbe65`) — notifications. Unread survives reload: stored cursors on hydrate (`isUnread`), hub `unread` via `listChannels({ read })` with the stored hub cursor (`read-cursor.mjs readMap`, `markChannelRead`); per-key mention count; a live frame is keyed by its own channel (A1 keeps `env.channel`), so `#alerts` escalates as alerts while a DM is open. Sidebar: `#alerts` `7 d` retention, mention badge, footer connection-health dot. Check: `cd csi-spl-wui && node --test tests/unit/notify.test.mjs tests/unit/read-cursor.test.mjs tests/unit/verbosity-notify-wire.test.mjs` → pass; `command grep -rn "isUnread" csi-spl-wui/src/stores` → 2; lde reload: `#lobby` badge 1 = hub `unread` 1 for the same `read=` cursor (Gap lane A2, 2026-09-19).
- [x] P5 Implemented (`7e3f9af`, `6618f03`) — verbosity toggle (`VerbositySelector.vue`) inferred from `kind`. Check: `node --test tests/unit/verbosity.test.mjs` → pass.
- [x] P6 Implemented (`69cbe65`; A1 `createChannel` `2b74ce3`) — channel creation in live mode: the sidebar form is no longer `v-if="api.mock"`; the name is slugged (`channelSlug`), `409 channel_exists` / `400 bad_channel` shown in words. Check: `command grep -c 'v-if="api.mock"' csi-spl-wui/src/components/ChannelSidebar.vue` → 0; lde: `A2 Proof 0919` → `#a2-proof-0919` created, a second create → "That channel already exists" (Gap lane A2, 2026-09-19).

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
- [x] T035 Implemented (`2af5fab` hub, `25649ab` cnf, `bb20552` + `12f5b52` wui, CLE-3440) — `diagnostics_enabled` in the hub's session claims (010 auth-v1 §3): cnf `SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS` grants it per human, empty in every env so it is still shown to nobody until an operator names someone. Read per call, never a cookie claim, so a browser cannot assert it and a removal revokes at the next probe. Check: `go test ./internal/auth/ -run Diagnostics -v` → 4 tests / 12 subtests pass; `node --test tests/unit/diagnostics-claim.test.mjs` → 13 pass; live `EXPECT=on|off node tests/e2e/diagnostics-panel-live.proof.mjs` → on: claim true + panel in the DOM, off: claim false + no panel in the rendered body.

## Phase 7 — Editing a sent message, browser half (owner order 2026-09-22, CLE-3445)

Owner: *"we need to add the WUI capability to edit the msgs, slack wise — once a
msg in the 3rd panel is selected, if one presses the e shortcut the msg becomes
once again a textbox and after once writes the new msg (the old msg should be
shown there) and hits the enter the msg is sent"*, and minutes later *"but there
should be a register in the db that the msg was updaed, aka both the old and the
new msg should be stored (for later feature to be able to compare those msgs)."*

**The seam.** The hub, the DB and the append-only revision register are
`032-spool-message-edit` (CLE-3443); that spec's Non-goals name the browser half
— selection, the `e` binding, the inline editor, Escape, the `(edited)` marker
and its i18n string, and the browser e2e — as 005's. These rows are that half.
The contract is cited ONCE, here, so it stays a one-line fix if it moves again:

> `csi-spl-doc/specs/032-spool-message-edit/contracts/message-edit-v1.md` (2dad1df)

**ORDERED vs INFERRED.** The owner named the `e` shortcut, the pre-filled box and
Enter-sends. Two further rules are INFERRED, agreed by CLE-00 and CLE-3444 on
2026-09-22, and the owner can overrule either: **Escape cancels** (Slack does it
and this app already dismisses on Escape), and **author-only with NO time window**
(the owner said "slack wise" but did not ask for Slack's editing window, and a
silent expiry produces bug reports rather than features). Both are marked as
inferred in `src/utils/msg-edit.mjs` and in the unit-test case names too.

- [x] T036 Implemented (`ada3bed`) — `src/utils/msg-edit.mjs`: the state machine, pure,
  the way `thread-pane.mjs` and `send-failure.mjs` are. `beginEdit()` has no path that
  yields an empty draft (the owner's "the old msg should be shown there"); `commitEdit()`
  mutates nothing and only reports, so the caller rolls back to `state.original` — the
  CLE-3433 lesson as a shape rather than a comment. Enter / Shift+Enter call the SAME
  `enterAction()` from `code-blocks.mjs` that `MessageComposer.vue` calls, and the test
  asserts every `{inCode, shift, alt, mod}` combination against `enterAction` itself, so
  the two cannot drift. `feed.edit.*` translated in all 19 catalogues (not English
  placeholders), checked for the `<x` and bare-`@` shapes that break `nuxt generate` → 0.
  Check: `cd csi-spl-wui && node --test tests/unit/msg-edit.test.mjs` → 38 pass, 0 fail.
- [x] T037 Implemented (`a14bc84`) — the wire half. Three keys that were being dropped
  silently: `normalizeViewMessage()` and `messageFromFrame()` both allow-list onto the flat
  row, and `edited_at` / `edited_by` / `revision` ride at the element's TOP level, not
  inside `env.msg`. Each is copied only when present, because §2 omits them until the first
  edit and the marker tests for presence. The edit needs its OWN frame type, measured not
  assumed: `sed -n '77,95p' src/utils/feed.mjs` → line 89 `} else if (list[i].pending &&
  !m.pending) {`, so `mergeById()` drops a repeat of a row already held as confirmed — that
  measurement is now a regression guard in the suite. `applyEdit()` replaces at the existing
  index and never re-sorts (FR-ED-009: an edit does not move the message).
  `editMessage()` = `PATCH /v1/messages/{msg_id}` `{ body }`, `/v1/` not `/api/v1/`, and
  `content-type` is the only header — a NEW request header is a new CORS preflight, which
  has broken sign-in here before, and the test asserts the header set rather than trusting
  the reading. Check: `cd csi-spl-wui && node --test tests/unit/msg-edit-wire.test.mjs` → 26 pass, 0 fail.
- [x] T038 Implemented (`2ba496d`) — the editor itself: `MessageCard.vue` takes `e` on
  the focused row (same `target === currentTarget` guard as its existing Enter / Space),
  becomes a textarea pre-filled with the OLD body, Escape restores and returns focus to the
  row, Enter commits. The `(edited)` marker sits in `msg-meta` with the time, driven by
  `edited_at`'s presence. Author-only via `useMessageEdit()`, whose predicate is the hub's
  own (`m.from === <my id> && m.from_box === 'box-wui' && !m.pending`) — a shortcut that
  opens an editor the hub answers 409/403 for is a defect. One `applyEverywhere()` tells
  every store that may hold the row: the first version told two stores and the browser
  proof caught the lobby feed behind the 3rd panel still showing the OLD body.
  Check: `cd csi-spl-wui && node --test tests/unit/*.test.mjs` → 730 pass, 0 fail;
  `./node_modules/.bin/nuxi typecheck` → exit 0.
- [x] T039 Implemented (`2ba496d`, wired into CI by `<ci sha>`) — `tests/e2e/msg-edit.test.mjs`, in real Chrome:
  focus a row → `e` → the textarea holds the OLD body **as source, not as rendered
  markdown** → type → Enter → the row shows the new body and the marker; a second pass for
  Escape; the same row in the feed behind the panel; a fresh API read; and `e` on somebody
  else's message opening nothing.
  Check: `cd csi-spl-wui && pnpm run test:e2e:msg-edit` → 21/21 OK. It is a `.test.mjs`, not a
  `.proof.mjs`, because it needs no credentials and no live endpoint: it runs in
  `10 ci: quality gate` → `wui: browser e2e (mock, generated)` on every push, against the same
  generated bundle and stub API that job already builds. The `.proof.mjs` shelf here is for the
  ones CI cannot run (`user-menu-live.proof.mjs` needs a real signed-in session).

  **SUBSTITUTION, pinned to the moment it was true.** These e2e legs ran against the generated
  lde MOCK bundle, not a live hub. *Measured 2026-09-22T08:07Z, on sha `2ba496d`, by this lane:*
  `curl -s https://api.spool-hub.ai/version` and `curl -s https://dev.api.spool-hub.ai/version`
  → both `{"commit":"039c2dfa…","version":"0.1.20"}`; and
  `curl -o /dev/null -w '%{http_code}' -X OPTIONS https://dev.api.spool-hub.ai/v1/messages/<uuid>`
  → `404`. The hub half (`d8ecb2a`) was on trunk with its `csi-spl-cnf` image tag unbumped, which
  is contract §8's ordering (`0026` first, image second) and CLE-00's lane, not this one.
  **That 404 is a fact about 08:07Z, not a standing claim** — T009 (the migration and the 0.1.21
  roll) was released shortly afterwards and is expected to change it.

  So, precisely: the browser contract is proved — `e`, the pre-filled box, Enter, Escape, the
  marker, the cross-view update — against a mock that reproduces all four hub refusals
  (`not_author` 403, `not_found` 404, `empty_body` 400, `not_editable` 409). **NOT proved here:
  a real PATCH against the deployed hub**, and durability across a page reload, which is a hub
  property the mock cannot show at all — its store is `cloneMock()` inside the client module and
  a reload resets it, so the gate re-reads through the API instead of claiming it. Re-running
  this gate with `BASE_URL` against a signed-in live host once 0.1.21 is serving would close that
  gap; it is available to whoever picks it up.

  **The gate was shown FAILING, with the defect planted in `src/`, not in the harness.**
  `beginEdit()` changed to `return { msgId, original, draft: '' }`:
  `node --test tests/unit/msg-edit.test.mjs` → **35 pass, 3 fail** (`pre-fills the draft with
  the stored body`, `pre-fills a multi-line body verbatim, fence and all`, `knows whether
  anything was actually typed`), and the Chrome e2e → **20/21, exit 1**, on
  `the box is PRE-FILLED with the old message, as SOURCE not as rendered markdown
  {"expected":"Welcome to **#lobby**. …","got":""}`. Restored (`diff` against the backup →
  identical) and re-run green. The proof also carries `PROVE_RED=prefill-empty|no-marker|no-escape`
  for a harness-side plant that needs no edit to `src/`.

  The PURE half of this was already a CI gate from T036: `tests/unit/msg-edit.test.mjs` runs in
  `wui: unit tests + typecheck` on every push and pins the pre-fill (`beginEdit` never yields an
  empty draft) and the author predicate (`wantsEdit` / `canEditMessage` true only for an own,
  non-pending, `box-wui` row). What was missing until the CI wiring above was the Vue/DOM half —
  `e` actually reaching the handler and the textarea appearing pre-filled — and that is what the
  browser gate now covers.

<!-- version: 1.8.0 · updated: 2026-09-22 · last-edit: 2026-09-22T08:10:00Z -->
