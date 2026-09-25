# Tasks: Spool WUI — read-only thread viewer first

**Feature**: `specs/005-spool-wui` · **Milestone**: M3 · **Redone**: 2026-09-18

Status is by **verification on trunk** (`bbc41e7` for the redo; `9eafd8c` for the viewer code), not by earlier reports
(`../README.md` §2.3). `[x]` Implemented (cited) · `[~]` Partial (missing part
named) · `[ ]` Planned. Live work is gated on D1.

## Phase 1 — Scaffold & lde

- [x] T001 Implemented — Nuxt 3 + TS strict + Pinia + pnpm scaffold (`csi-spl-wui/package.json`, `nuxt.config.ts`, `tsconfig.json`). FR-001.
- [x] T002 Implemented — lde `pnpm dev` (3000), `NUXT_PUBLIC_API_BASE`, `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build` (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 5` on `28442ef6`). FR-008.
- [x] T003 Implemented — `pnpm test:unit -> 17 pass, 0 fail`; e2e no-x-scroll for `/login`, `/channel/lobby` at 390×844 / 1280×800 (file present; not re-run in the redo). FR-009.

## Phase 2 — Viewer MVP (US1–US3, P1) 🎯

- [x] T004 Implemented (`9eafd8c`) — `utils/spool-client.mjs` live mode reads `/v1/view/threads`, `/v1/view/threads/{task_id}` (renamed `/v1/view/topics` in `57f8a670`), `/v1/view/channels`, `/v1/view/roster` with `Authorization: Bearer` and `credentials: 'omit'`; normalisers in `utils/view-api.mjs`. **Superseded by A1 (`2b74ce3`, CLE-3362 2026-09-19):** `ReadOnlyError` is gone. The live client does the following: `listMessages({channel})` → `/v1/view/topics?channel=` and DMs → `?dm=true&peer=`; `createChannel` → `POST /v1/channels` (`409 channel_exists` / `400 bad_channel` kept); `listChannels({read})` → `read=<ch>~<cursor>`, keeping `unread` / `last_cursor` / `retention_days`; `sendMessage` goes over the WUI socket with `channel` / `parent_task_id`; view rows, envelopes and WS frames keep `channel` / `parent_task_id`. Check: `command grep -c "ReadOnlyError('a channel" csi-spl-wui/src/utils/spool-client.mjs -> 0`; `cd csi-spl-wui && node --test tests/unit/*.test.mjs -> 176 pass, 0 fail` (on `69cbe65`). FR-002, FR-005.
- [x] T005 Implemented (`9eafd8c`, mock) — `pages/index.vue` thread list via `stores/viewer.ts`: empty state, `unknown_tenant` message, `Older` paging on `next`. Rendered against the mock tenant (headless Chrome screenshot, 4 threads). Live render: T012. US1, FR-002.
- [x] T006 Implemented (`9eafd8c`, mock) — `pages/t/[task_id].vue` reuses `MessageCard.vue` / `KindBadge.vue` / `AgentBadge.vue`; `FileAttachment.vue` links only downloadable blobs (`isDownloadable`), `mode:"path"` shows the on-box path. Rendered against the mock tenant (4 messages oldest first, 1 attachment; newest-first since 013). US2, US3, FR-006.
- [x] T008 Implemented (`9eafd8c`) — `tests/unit/view-api.test.mjs` (12 tests: normalisers, stub-`fetch` live client, 401 token surfacing, read-only refusals, XSS-as-text); `node --test tests/unit/*.test.mjs -> 29 pass, 0 fail`; `node tests/e2e/no-x-scroll.test.mjs -> 8/8` (adds `/` and `/t/<id>`); `nuxi typecheck -> exit 0`. SC-002, FR-006.
- [x] T012 Implemented — SC-001 locally: the WUI in live mode (`NUXT_PUBLIC_USE_MOCK=0`) against a trunk `spool serve` (`ec3d593`+, `SPOOL_HUB_VIEW_DOOR=off`, lde Postgres holding tenant t1) lists the seeded thread `33330000-…-9001` (3 messages) and opens it oldest-first; CORS preflight from the WUI origin → `204` with the exact origin (headless Chrome screenshot + `curl`, n=1, 2026-09-18). **dev (D3), 2026-09-19 (CLE-3372, n=2):** `box-e2e-a` → `box-e2e-b` `spool send` on hub `0.1.4` (`b067cfd`) tenant t1 is listed by the dev WUI (`csi-spl-dev-site.web.app`, Chrome) and opens on `/t/<id>` "newest first". Check: `./run -a do_spl_m3_e2e` step `a-box-to-box` PASS (`../014-spool-wui-dispatch/acceptance-dev.md`). SC-001, FR-002.

## Phase 3 — Follow & ship (US4, US5)

- [x] T007 Partial — `/t/[task_id]` polls while visible (`NUXT_PUBLIC_POLL_MS`, default 4000, floor 2000); after the first read it passes the last message `cursor` as `after=` and appends new messages, de-duplicated by `msg_id` (`stores/viewer.ts`); client test asserts `after=`; live hub returns `[]` for the last cursor (`curl`, n=1). The legacy `useSpoolEvents.ts` channel poll remains only for the mock channel pages. US4. — **Audit CLE-3358 2026-09-19 (tree c777a2f): not as written.** `command grep -rn pollMs csi-spl-wui/src` → 0; `/t/[task_id]` follows over the WS (`useLiveFeed('main')`), `viewer.refreshThread` has no caller, and there is no `after=` catch-up after a WS reconnect (gap list: G-A). — **Done by A3 (CLE-3368, `ccc8117`, `4c9619e`, `901ea06`):** after a WS reconnect (live-ws `onReconnected`) the live store does one `getThread(id,{after:<last cursor>})` deduped by `msg_id` (`utils/live-follow.mjs` `catchUp`); a 401 `view_door` on `/t`, `/lobby`, `/` and the thread pane shows the door prompt (sign-in link `/login?redirect=&tenant=` and/or view token); `/t` had the verbosity selector (removed `d1648dd0`); roster `online` follows `presence` frames. Check: `cd csi-spl-wui && node --test tests/unit/live-follow.test.mjs` → 18 pass; lde hub `t1.localhost:58081`: forced WS drop recovered the missed row, 0 dups (n=2), presence HUM-32 on→off (n=1). Test count on `28442ef6`: `node --test tests/unit/live-follow.test.mjs` → 22 pass. The verbosity selector on `/t` was removed in `d1648dd0`. FR-002.
- [x] T009 Implemented (GRK-3380, 2026-09-21) — dev Hosting live: `curl -s https://dev.spool-hub.ai/build.json` → `{"commit":"44e94470cb90a1bce16db55d0fa23c0c4b6b1ba2","built_at":"2026-09-21T12:57:19Z","run":"35602385949"}`; `https://csi-spl-dev-site.web.app/build.json` 200, same commit+run. FR-007, FR-004.
- [~] T010 Partial — view token: `ViewTokenForm.vue` on `401`, token kept in `sessionStorage` (`9eafd8c`). Social sign-in wired per spec 010 `contracts/auth-v1.md` §1–§4 (`1c4e1a6`: `/login` buttons from `GET /api/v1/auth/providers`, `auth_error` copy, session probe 401 vs unknown, sign out; Hosting rewrite `/api/v1/auth/**`; lde `NUXT_DEV_AUTH_PROXY`) — that is 010 T014–T016. lde browser round trip (010 T017) verified 2026-09-18 in Chrome, n=1 per provider: `auth-demo -addr 127.0.0.1:58181 -app-url/-public-url http://localhost:3044` + `NUXT_DEV_AUTH_PROXY` → `/login?redirect=/t/<id>` → Google / Facebook → fake IdP → lands on `/t/<id>`, `GET /api/v1/auth/session` 200 (`p` = google / facebook), cookie not readable from JS, sidebar shows the name; Sign out → 401 + `/login`; `?auth_error=invalid_state` shows its copy and is dropped from the URL with `redirect` kept. Missing: the hub view door (003 T033, after OQ-16) and how the session reaches `/v1/view/*` (010 OQ-A1). US5, FR-010.
- [x] T011 Implemented (GRK-3380, 2026-09-21) — prd Hosting live: `curl -s https://spool-hub.ai/build.json` → `{"commit":"44e94470cb90a1bce16db55d0fa23c0c4b6b1ba2","built_at":"2026-09-21T12:57:26Z","run":"35602385949"}` (same commit+run as dev). `https://csi-spl-prd-site.web.app/build.json` 200, same. FR-007, FR-010.

## Phase 4 — Live chat MVP (owner goal 2026-09-18; 003 `contracts/wui-live-ws.md`)

- [x] T021 Implemented (`580688e`, `5531927`) — browser WS client `utils/live-ws.mjs` to `ws(s)://<tenant>.<fqdn>/v1/wui/ws`: hello (`as` only when a v:1 agent id, else hub-assigned), welcome (`as`, `lobby_task_id`, upload token), subscribe, send (`kind` default `note`), ack/error, `token` refresh, capped reconnect + re-subscribe. 12 unit tests (fake WebSocket). FR-002.
- [x] T022 Implemented (`b0bf6ab`) — `/lobby` and `/t/[task_id]` live: history via view-v1 §4.4, then live `message` frames appended (dedupe by `msg_id`); composer on top, newest first (`SPEC-spool-wui-layout.md`); `?as=HUM-n` identity. FR-002, FR-005.
- [x] T023 Implemented (`b0bf6ab`, `5531927`) — attach → `POST /v1/files` (Bearer upload token, refreshed when stale) → `files[]` refs in the send; Download fetches `GET /v1/files/{id}`, checks sha256, saves. US3, FR-002.
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
- [~] P5 Partial — the verbosity toggle (`VerbositySelector.vue`, `7e3f9af`, `6618f03`) was removed in `d1648dd0`; `src/utils/verbosity.mjs` is kept with no caller (`node --test tests/unit/verbosity.test.mjs` → 5 pass on the util). Retire or restore: open, owner decision (asked in topic 582f7895). FR-013.
- [x] P6 Implemented (`69cbe65`; A1 `createChannel` `2b74ce3`) — channel creation in live mode: the sidebar form is no longer `v-if="api.mock"`; the name is slugged (`channelSlug`), `409 channel_exists` / `400 bad_channel` shown in words. Check: `command grep -c 'v-if="api.mock"' csi-spl-wui/src/components/ChannelSidebar.vue` → 0; lde: `A2 Proof 0919` → `#a2-proof-0919` created, a second create → "That channel already exists" (Gap lane A2, 2026-09-19).

## Phase 5 — Verbosity + in-browser notifications (WUI-UX, Gaps 6–7)

Contract: `contracts/verbosity-notify-v1.md`. Does not touch hub, rdb, iac,
channel/DM/roster stores, `wui-live-ws.md`, or `view-v1.md`.

- [x] T025 Implemented (`e70a9f6`) — spec amendment: US6 / US7, FR-013..015, OQ-W3/W4/W5 (a)
  chosen, P4/P5 unblocked. Check: `command grep -c OQ-W3 csi-spl-doc/specs/005-spool-wui/spec.md` → 5.
- [x] T026 Implemented (`7e3f9af`) — `csi-spl-wui/utils/verbosity.mjs`: `verbosityOf` / `applyVerbosity`
  from `kind` only; persist selector in `localStorage` `spool.verbosity` (try/catch).
  Table-driven unit test covers every v:1 kind from `internal/msg/msg.go` `validKinds`.
  (`channel-feed.mjs` no longer delegates here: `git grep -n verbosity -- csi-spl-wui/src/utils/channel-feed.mjs` → 0; the selector was removed in `d1648dd0`.) Check: `cd csi-spl-wui && node --test tests/unit/verbosity.test.mjs` → 5 pass. FR-013, US6, P5.
- [x] T027 Implemented (`7e3f9af`) — `csi-spl-wui/utils/notify.mjs` + `utils/read-cursor.mjs`:
  escalate only on mention of signed-in `HUM-*` / DM / `#alerts`; unread per
  `ch:<slug>` / `dm:<peer>` from local cursors; chime opt-in default off.
  Check: `cd csi-spl-wui && node --test tests/unit/notify.test.mjs tests/unit/read-cursor.test.mjs` → pass. FR-014, FR-015, US7, P4.
- [~] T028 Partial (`6618f03`) — the notification half stands; the verbosity half was removed in `d1648dd0`
  (open, owner decision (asked in topic 582f7895)). Wired `VerbositySelector.vue` (deleted), `ThreadPane.vue` /
  `LiveThreadPane.vue` (now `TopicPane.vue` / `LiveTopicPane.vue`, `57f8a670`), `NotificationCenter.vue`, `stores/notification.ts`,
  `stores/thread.ts` (now `stores/topic.ts`), sidebar unread badges; drop mock `[verbose]` body filter
  and the "task sent" ping. No mock-data import in those files. Check: `cd csi-spl-wui && node --test tests/unit/*.test.mjs` → 94 pass, 0 fail; `node tests/e2e/no-x-scroll.test.mjs` → 12/12. FR-013..015.

## Phase 6 — Donor WUI structure port (owner order 2026-09-19)

Owner: "use all of the available code in the donor WUI — the same stack, the
same vue app structure". Sources move under `csi-spl-wui/src/` (Nuxt
`srcDir: 'src/'`); every `csi-spl-wui/<dir>/…` path in the tasks above now
reads `csi-spl-wui/src/<dir>/…`. Package root, `firebase.json`,
`.output/public`, `tests/` and the orc/CI path consumers are unchanged.

- [x] T029 Implemented (`fff663d`) — `srcDir: 'src/'` layout, `@` alias, discovery unit runner `src/node/test/run-unit-tests.mjs` (`pnpm test:unit`). Check: `cd csi-spl-wui && pnpm test:unit` → all files pass; `pnpm typecheck` → 0. FR-001.
- [x] T030 Implemented (`9fa748d`) — `nuxt.config.ts` donor shape: CSP_DEV/CSP_PROD + security headers as routeRules, vendor chunks, `@nuxtjs/i18n` (en only, `i18n/locales/en.json`). `tests/unit/csp-policy.test.mjs` pins CSP_PROD to `render-wui-firebase-json.sh`. FR-001, FR-007.
- [x] T031 Implemented (`37b453f`) — error stack: `composables/errorJournal.mjs`, `components/common/ErrorNotice.vue` on every viewer/thread/lobby/channel/live-pane error, gated `components/common/DebugPanel.vue` (session claim `diagnostics_enabled === true`, fails shut), `error-journal.client.ts`, `error.vue`, `useSettledQuery` on the prerendered `/login` and `/`. Check: `node tests/unit/error-journal.test.mjs` → 19 pass. FR-001.
- [x] T032 Implemented (`1f30c25`) — `SocialAuthButtons.vue` on `/login`, auth-v1 §4 endpoints and labels kept; `loadProviders()` tells auth-off from unreachable. Check: `node tests/unit/auth-client.test.mjs` → 12 pass (28 on `28442ef6`). US5, FR-010.
- [x] T033 Implemented (`d1225e7`) — donor token scale + base rules on the spool palette. Check: `node tests/unit/theme-tokens.test.mjs` → pass. FR-001.
- [x] T034 Implemented (`e300d5c`) — e2e: `console-errors` gate, shared `tests/e2e/lib/server.mjs`, `serve-generated.mjs`, `puppeteer-core`. Check: `pnpm test:e2e:console-errors` → 7/7; `pnpm test:e2e` → 12/12. FR-009.
- [x] T035 Implemented (`2af5fab` hub, `25649ab` cnf, `bb20552` + `12f5b52` wui, CLE-3440) — `diagnostics_enabled` in the hub's session claims (010 auth-v1 §3): cnf `SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS` grants it per human, empty in every env so it is still shown to nobody until an operator names someone. Read per call, never a cookie claim, so a browser cannot assert it and a removal revokes at the next probe. Check: `go test ./internal/auth/ -run Diagnostics -v` → 4 tests / 12 subtests pass; `node --test tests/unit/diagnostics-claim.test.mjs` → 13 pass (22 on `28442ef6`); live `EXPECT=on|off node tests/e2e/diagnostics-panel-live.proof.mjs` → on: claim true + panel in the DOM, off: claim false + no panel in the rendered body. FR-010.

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
Enter-sends.

**Author-only is OWNER-STATED as of 2026-09-22, not inferred.** It was recorded
all day as our inference; the owner then stated it themselves, watching the
feature live:

> "of course msgs sent by bots should not be editable" — the owner, 2026-09-22

A rule the owner stated and a rule we guessed well are not the same artefact,
and the next reader must not have to work out which this was. The NO-time-window
half stays as CLE-00's ruling of the same day: the owner said "slack wise" but
did not ask for Slack's editing window, and a silent expiry produces bug reports
rather than features.

**Escape-cancels REMAINS INFERRED.** The owner has said nothing about it, so it
keeps its original standing — agreed by CLE-00 and CLE-3444 on 2026-09-22
because Slack does it and this app already dismisses on Escape — and the owner
can still overrule it cheaply. It is deliberately NOT carried along by the
upgrade above.

- [x] T036 Implemented (`ada3bed`) — `src/utils/msg-edit.mjs`: the state machine, pure,
  the way `thread-pane.mjs` and `send-failure.mjs` are. `beginEdit()` has no path that
  yields an empty draft (the owner's "the old msg should be shown there"); `commitEdit()`
  mutates nothing and only reports, so the caller rolls back to `state.original` — the
  CLE-3433 lesson as a shape rather than a comment. Enter / Shift+Enter call the SAME
  `enterAction()` from `code-blocks.mjs` that `MessageComposer.vue` calls, and the test
  asserts every `{inCode, shift, alt, mod}` combination against `enterAction` itself, so
  the two cannot drift. `feed.edit.*` translated in all 19 catalogues (not English
  placeholders), checked for the `<x` and bare-`@` shapes that break `nuxt generate` → 0.
  Check: `cd csi-spl-wui && node --test tests/unit/msg-edit.test.mjs` → 38 pass, 0 fail (50 on `28442ef6`). FR-006.
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
  the reading. Check: `cd csi-spl-wui && node --test tests/unit/msg-edit-wire.test.mjs` → 26 pass, 0 fail. FR-002.
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
  `./node_modules/.bin/nuxi typecheck` → exit 0. FR-006.
- [x] T039 Implemented (`2ba496d`, wired into CI by `d6ca9218`; FR-009) — `tests/e2e/msg-edit.test.mjs`, in real Chrome:
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
  this gate with `BASE_URL` against a signed-in live host would close that gap; it is available to
  whoever picks it up.

  **Follow-up, measured 2026-09-22T08:33Z — the roll landed and the endpoint IS serving.**
  `dd86875` (`cnf(032, CLE-3443): hub 0.1.21`) is live on both hubs, and the route answers:

  | probe (both `api.spool-hub.ai` and `dev.api.spool-hub.ai`) | result |
  |---|---|
  | `OPTIONS /v1/messages/{id}` | `204` — the browser preflight passes |
  | `PATCH /v1/messages/{id}`, no auth | `401 {"error":"view_door"}` |
  | `PATCH /v1/definitely-not-a-route/{id}` (control) | `404` |

  The control is the point: an unknown route still answers 404, so the 401 is the edit route
  refusing an unauthenticated caller rather than a catch-all — the endpoint is mounted and
  reachable from a browser. **Still NOT proved here:** an authenticated PATCH round-trip against
  the deployed hub. That needs a signed-in session (the native-login rate limit is 10 per email
  per 15 min), and this gate is written for the mock bundle, so it is genuinely open work and not
  something this row quietly claims.

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


## CLE-3446 — the owner's two bugs on the day the edit feature shipped

Reported live, ~90 minutes after `ada3bed`..`261f4f7` went out. The owner, 2026-09-22:

> "basically three is some kind of mix between the who sends the msg and the avatar , also the
> editing of the msg appears whenever the bot is sending"

and, minutes later:

> "of course msgs sent by bots should not be editable"

**Two bugs, not one.** They were reported in one breath and it was tempting to treat them as one
mechanism; they are not, and saying so early would have been wrong.

- [x] T042 Implemented (`025b8e6`; renumbered from a duplicate T039; FR-006) — **B: an open editor rode onto the next row.**
  MEASURED FIRST, before any fix: `PATCH /v1/messages/{id}` on dev (t1, viewer `HUM-4`, live sha
  `6026c59`), n=2, against `HUM-17`'s row and `ORC-1`'s row → **403 `not_author`** both times,
  body unchanged and `revision` / `edited_at` null on re-read. The hub half was correct, so this
  was a UI-only defect. (Rule 7, `not_editable`, was NOT reached — rule 6 refuses first for every
  row in reach. Recorded as not-shown rather than implied.)

  The predicate was never wrong; the row under the card changed. `ThreadPane.vue`,
  `LiveThreadPane.vue` and `pages/t/[task_id].vue` mounted the pinned root with **no `:key`**, and
  `stores/live.ts open()` reassigns `taskId` without it passing through null, so the `<aside>` is
  never torn down and Vue PATCHES one `MessageCard`. `editable` is a prop and went false
  correctly; `edit` / `saving` / `editError` are local refs and did not. Fix: key the three mounts
  by `msg_id` AND watch `props.msg.msg_id` in the card (the half that does not depend on every
  future host remembering the key).

  **Re-measured on `28442ef6`:** the keyed mounts are gone — `be836386` replaced the pinned
  root card with `LiveFeed` (`grep -n ":key" TopicPane.vue LiveTopicPane.vue pages/t/[task_id].vue`
  → 0). The watcher half stands: `MessageCard.vue:544`, guard `tests/unit/msg-edit.test.mjs:462`.

  Check: `cd csi-spl-wui && node tests/e2e/msg-edit.test.mjs` → **26/26**. The gate was a
  **NATURAL red on the unfixed tree** — 24/26, exit 1, on
  `{"editing":true,"boxValue":"Welcome to **#lobby**. This is the lde mock feed."}`: an editable
  box, on `CLE-07@box-a`'s message, holding a different author's text. Only the hub's rule 6
  stopped it landing. `PROVE_RED=keep-editor` re-reds it. Unit controls: drop a `:key` → *"ThreadPane
  mounts the root card without a :key"*; delete the watcher → *"MessageCard.vue has no watcher on
  props.msg.msg_id"*. Both restored.

  Why the existing gate stayed green all day: step 8 of `msg-edit.test.mjs` calls `page.goto`
  first, which destroys the component — a true assertion about a situation the 3rd panel never
  reaches.

- [x] T040 Implemented (`70b367d`) — **author-only upgraded from INFERRED to OWNER-STATED**, quoting
  the owner, in this file's ORDERED-vs-INFERRED block, the `utils/msg-edit.mjs` header and
  `useMessageEdit.ts` (FR-006). **Escape-cancels stays INFERRED and each place says so explicitly** rather
  than leaving it to be read out of what is missing. The no-time-window half stays CLE-00's ruling.
  032 §4 was CLE-00's in `89564da`. Check: `node --test tests/unit/msg-edit.test.mjs` → 40 pass.

- [x] T041 Implemented (`816d229`, `e284552`; FR-012) — **A: a channel row is ONE MESSAGE, sender → recipient.**
  No data defect. `threadCards` spread the FIRST message of a task and thereafter updated only
  `last_ts` / `count`, so the row kept the ROOT's `from` / `from_box` / `body` beside the NEWEST
  message's clock. In a two-party conversation the root is always the human, so every row rendered
  the human's identicon and the agent's reply was folded away. `MessageCard` feeds `SpoolAvatar`
  and `AgentBadge` from the same `msg.from`, which is why the NAME was wrong too. Diagnosed by
  CLE-00, re-verified here against the sources before anything changed.

  Built to the format the owner settled (relayed by CLE-3444): per message, sender → recipient,
  the arrow flipping per row, kind badge kept, real ISO 8601 with the `T` and the `Z`.
  `channelView` drops the fold; `recipientOf()` reads the right-hand party from THAT message;
  `formatIsoTs()` is NEW — `formatAbsTs` returns `yyyy-mm-dd HH:MM:SS`, other surfaces read it,
  and a formatter that is nearly right is how two surfaces end up disagreeing about what a
  timestamp is. The 3rd panel's own ticking `sinceMs` clock is untouched.

  **This overturns part of CLE-3425, deliberately and on the owner's word:** "one card per
  task_id" no longer holds on /channel and /dm. What CLE-3425 was protecting survives — newest
  first everywhere, a replied-to thread is the newest thing in the channel — because the reply is
  now a row of its own. Three cases in `channel-reverse` / `list-order` are rewritten with that
  reasoning in them; `threadCards` is kept unchanged with its own tests.

  `e284552` is the follow-up and is the one worth reading: there are **TWO** "everyone" sentinels,
  the hub's `ALL-0` and the client's `@channel` (`parseMention`, `rowFromAck`,
  `stores/channel.ts:320`; stripped by `spool-client.mjs:317` before the wire). Excluding only
  `ALL-0` put an arrow and a generated ROBOT avatar for a participant called "@channel" beside
  every ordinary channel message the viewer sends. **It was found by rendering the row in Chrome,
  not by reading it back** — the unit gate missed it because the gate was written against the
  sentinel that had been measured on dev.

  Check: `node --test tests/unit/*.test.mjs` → **738 pass, 0 fail**; `pnpm run typecheck` exit 0;
  `node tests/e2e/no-x-scroll.test.mjs` → 56/56 (the row got wider). Gate is a NATURAL red:
  restore the fold in `channelView` and *"both sides of a two-party thread are rows, each with its
  OWN sender"* fails with the root's sender on the reply's row.

### Open, filed rather than chased (CLE-3446)

- [ ] T043 Planned (FR-012) — `SpoolAvatar` holds `shown` as a local ref updated only from `watch(picture)`. For every id
  with no stored IdP picture `picture` is `''` on both sides of a swap, so the watcher never fires
  and a reused card could keep the previous face under the new name. **Not the owner's symptom A**
  — that was row identity, above — and much harder to reach now the root mounts are keyed, but the
  mechanism is real on inspection and unproven either way. It needs a signed-in member with a
  stored IdP picture to reproduce; no dev test account has one (they sign in natively, so no
  `avatar_file_id`), and the lde mock forces `api.mock`, which makes `picture` `''` for everyone.

- [ ] T044 Planned (FR-001) — Trap for whoever adds the next export to a `.mjs`: it is a **TWO-file change**.
  `src/types/mjs-shims.d.ts` carries an ambient `declare module '~/utils/<x>.mjs'` that ENUMERATES
  the exports, and TS believes it over the real file for the aliased specifier. A new export is
  then invisible as `has no exported member 'X'` while resolving fine via a relative path —
  measured both ways on the same file in the same run.

- [ ] T045 Planned (FR-003) — the FR-003 guard in `tests/unit/verbosity-notify-wire.test.mjs`
  (`keyRe`, line 65) only matches keys it already allows, so `spool-font-size`, `csi-spl-lang`
  and `spool.hidden-dm-peers` are written unchecked. Collect every `storageSet` /
  `localStorage.setItem` key and diff it against the allow-list. Size S.

### Error snackbar + personal event log (CLE-34990, FR-016 / FR-017, `contracts/events-v1.md`)

Owner, 2026-09-25, topic 4335f075: *"implement the feature for all of the errors to occur via a
cool sliding snackbar from the top , which is about the same size ... Also all of the errors should
get saved into a personal per user event-log entry in the db , which sould be accessible from event
log , button after the flow icon on the left most pane"*.

- [x] T046 (FR-016) `src/utils/error-snackbar.mjs` — queue fed from the error journal; unit
  `tests/unit/error-snackbar.test.mjs` (CLE-34990).
- [x] T047 (FR-017) rdb `0045_human_events.sql` + store `human_events*.go` + hub `events.go`
  (GET / POST / clear under `/api/v1/auth/events`); Go tests `store/human_events_test.go`
  (memory + Postgres) and `hub/events_test.go` (CLE-34990).
- [x] T048 (FR-017) `src/utils/event-log.mjs` (events-v1 client + signed-in batch shipper that never
  journals itself) + `src/plugins/event-log.client.ts`; unit `tests/unit/event-log.test.mjs` (CLE-34990).
- [x] T049 (FR-016) `components/common/ErrorSnackbar.vue` mounted in `layouts/default.vue`, all 19
  locales (GRK-3514: 716af006, 857b5d52).
- [x] T050 (FR-017) `pages/events.vue` + the rail's Event log icon after Flow (GRK-3514 page
  857b5d52, CLE-34990 rail 999d5ba3).
- [x] T051 live proof on dev AND prd, signed in: snackbar slides in, dismisses, the row is on
  `/events` and in `human_events` (GRK-3514 after AGY-3493 left: A1-A6 PASS on dev + prd,
  /tmp/grk3514-proof/{dev,prd}; `human_events` 5 rows each on dev and prd; WUI bf4757fa, hub
  0.6.2 6b055c62 served on both).

<!-- version: 1.11.1 · updated: 2026-09-25 · last-edit: 2026-09-25T20:55:00Z -->
