# Tasks: 013 Spool chat reverse

Status by verification (`../README.md` §2.3): `[x]` Implemented (cited) · `[~]` Partial · `[ ]` Planned.

- [x] T001 Implemented (`c4b3cca`) — `utils/feed.mjs`: newest-first (stable), `windowed`, `parseOmnibox`, `matchesSearch` (body, author, `id@box`, file names), `rootAndReplies`; 6 unit tests. FR-002, FR-001.
- [x] T002 Implemented (`c4b3cca`, `ec3b91e`, mention list: this commit) — `utils/avatar.mjs` robots (CLE teal / GRK orange / AGY purple chassis; varied head, eyes, mouth, antenna, extras) and HUM identicons, inline-SVG data URIs, deterministic per `id@box`; 4 unit tests; `SpoolAvatar.vue` on message cards, the roster and the `@mention` suggestions.
- [x] T003 Implemented (`ec3b91e`) — `MessageComposer.vue` `omnibox` mode: Enter sends (a leading `@CLE-07` sends `kind=task` `to=CLE-07`), `/search <q>` emits `search` and sends nothing, Esc clears; labelled textarea. FR-001.
- [x] T004 Implemented (`ec3b91e`) — `LiveFeed.vue`: `TransitionGroup` prepend (none under `prefers-reduced-motion`), 50-row windows, `IntersectionObserver` bottom sentinel reveals older, `role="feed"`, `aria-posinset`/`setsize`, polite announcer for live arrivals. Windows are client-side over the paged thread (spec D1). FR-002, FR-003, FR-007.
- [x] T005 Implemented (`ec3b91e`) — `useLiveFeed('main'|'pane')` on the one WS socket; `LiveThreadPane.vue`: pinned root, reply Omnibox, newest-first replies, live; opened from a thread row (plain click; Ctrl/middle-click still opens `/t/<id>`), from `/?thread=<id>`, or "Open thread" on a card of another task. FR-004.
- [x] T006 Implemented (`ec3b91e`) — `--thread-w: 380px`; the pane overlays below 1100px; `node tests/e2e/no-x-scroll.test.mjs` → 12/12 incl. `/?thread=<id>` (pane open) at 390×844 and 1280×800; `nuxi typecheck` exit 0; `node --test tests/unit/*.test.mjs` → 69 pass. FR-005, SC-004.
- [x] T007 Implemented — live acceptance, n=1 each, 2026-09-19 (~00:09Z): WUI `NUXT_PUBLIC_USE_MOCK=0` against a trunk `spool serve` (lde, view door off), lobby seeded with 60 messages over the real WS (`seed history #1..60`).
  - Load: 50 rows, newest (`#60`) on top, `Loading older…` sentinel. Scrolling to the sentinel → 68 rows, oldest at the bottom (SC-001 history).
  - Tab `?as=HUM-22` sends "prepend check from HUM-22" → top of its own feed at once; top of the `?as=HUM-21` tab live, announced "New message from HUM-22@box-wui" (SC-001).
  - `/search history #5` in HUM-21 → exactly 11 rows (`#59..#50`, `#5`), Omnibox cleared, nothing sent; Esc → filter gone, top row unchanged (SC-002).
  - Thread list → click the demo thread → URL stays `/`, pane shows root `GRK-03@box-smoke, task` pinned + 2 newest-first replies; avatars on those cards are robots; lobby cards for `HUM-22`/`HUM-30` are identicons (SC-003).
- [x] T008 Implemented — 003 shipped `order=desc&limit=&before=` on view-v1 §4.4 (`1dca945`, contract 0.4.0); the WUI opens a feed with the newest 50 (`order=desc`) and the bottom sentinel fetches the next older window with `before=<next>` (this commit; `getThread({order,before})`, 2 unit tests incl. mock paging). The pinned-root views (right pane, `/t/<id>`) page to the oldest row. Live, n=1: lobby of 69 → 50 on load, 69 after scrolling, oldest at the bottom; hub log shows the second windowed read.

## X3 scope extension — `/channel/<name>`, `/dm/<peer>`, channel ThreadPane (owner 2026-09-19: "X3 yes")

- [x] T009 Implemented (`14f821a`) — `utils/channel-feed.mjs` `channelView`: one card per thread root, newest first (`feed.mjs` `newestFirst`), `/search` filter, 50-row windows; the store keeps holding rows oldest first and A2's merge (`mergeLive`, `rowFromAck`) is unchanged. `stores/channel.ts` gains `newestFirst`/`hasOlder`/`search`/`lastLive`/`loadOlder`/`setSearch` only. Check: `cd csi-spl-wui && node --test tests/unit/channel-reverse.test.mjs` → `# tests 12` / `# pass 12` (re-measured 2026-09-19, n=1, tree d7b08da; the earlier "11 pass" was a miscount, the file is unchanged since `14f821a`) (live append on top, own send on top, older page at the bottom, windows, thread rows, search, wiring).
- [x] T010 Implemented (`14f821a`) — `pages/channel/[name].vue` and `pages/dm/[peer].vue`: the Omnibox (`MessageComposer omnibox`) on top, then `MessageFeed.vue`, which now renders the lobby's `LiveFeed.vue` (optional `count-for` / `always-thread` props added there; no second feed). Check: `command grep -c '<LiveFeed' csi-spl-wui/src/components/MessageFeed.vue` → 1.
- [x] T011 Implemented (`14f821a`) — `ThreadPane.vue` as `LiveThreadPane`: pinned root, reply Omnibox, replies newest first via `LiveFeed`, `live-pane` geometry. Check: `command grep -c 'pinned-root' csi-spl-wui/src/components/ThreadPane.vue` → 1.
- [x] T012 Implemented — verification, n=1 each, 2026-09-19: `node --test tests/unit/*.test.mjs` → 222 pass / 0 fail (211 before); `nuxi typecheck` exit 0; `node tests/e2e/no-x-scroll.test.mjs` → 14/14 incl. `/channel/lobby` and `/dm/CLE-07%40box-a` at 390×844 and 1280×800; console-errors e2e → zero. lde (main stack, hub view door off): two headless sessions on `/channel/lobby`, B (390×844) sends a root from the Omnibox → top of B and live top of A (1280×800), 3 rows newest first; `/dm/CLE-07@box-demo` Omnibox above the feed at both sizes. CI on `14f821a`: 10 run 35444194054 success, 30 run 35444194023 success, `csi-spl-dev-site.web.app` serves `14f821a4`.
- [x] T013 Implemented (`e1e50b5`, GRK-3365 A6) — server paging of older threads on `/channel/<name>` and `/dm/<peer>`: `listMessages({channel|dm, before})` passes view-v1 §4.3 `next` as `before=` and returns `{messages, next}`; the channel store sentinel loads the next page, appends older rows at the bottom, de-duplicates by `msg_id`, and stops when `next` is null. Mock `next` stays null. Check: `cd csi-spl-wui && node --test tests/unit/channel-paging.test.mjs` → 8 pass; `node --test tests/unit/*.test.mjs` → 235 pass / 0 fail (rebased tree); `nuxi typecheck` exit 0. lde n=1: seeded `#a6-page-0919` with 25 threads; first paint 20 rows (`#25` top, `#06` last, oldest hidden, sentinel "Loading older…"); scroll → `before=<next>` fetch, 25 rows, `#01` at the bottom. CI on `e1e50b5`: 10 run 35445851929 success; 30 run 35445851919 success, `csi-spl-dev-site.web.app/build.json` commit `e1e50b55`; prd skipped (`019.wui_deploy` false). 20 did not run (paths).

- [x] T014 Implemented (`76f66b5`, GRK-3366) — draggable vertical dividers on the 3-pane shell (`PaneDivider.vue`, `utils/pane-widths.mjs`): pointer drag, `role="separator"` + ArrowLeft/Right/Home/End, double-click reset, clamp so the main feed stays ≥ 360px, persist `localStorage` `spool.pane-widths` (try/catch), no divider when the sidebar is the 72px rail or the thread pane is closed/overlaying. Check: `cd csi-spl-wui && node --test tests/unit/pane-widths.test.mjs` → 19 pass; `node src/node/test/run-unit-tests.mjs` → all 23 files passed (rebased tree); `nuxi typecheck` exit 0. FR-009.

## CLE-3402 — top-right user avatar, dropdown and Settings (owner 2026-09-19)

- [x] T015 Implemented (`12ece07`, `505a38e`) — the top-right corner is the signed-in person's avatar (`components/UserMenu.vue` in `.app-corner`, `layouts/default.vue`), after pas-psf's header account control; clicking it opens a dropdown (name/email, **Settings**, Sign out); signed out it is the sign-in entry. The avatar reuses `SpoolAvatar` (010 T044 stored IdP picture, else the identicon); no new endpoint — the session claims (auth-v1 §4) carry name/email/`hum`/`p`/`t`. `/settings` (`pages/settings.vue`): profile, Language (CLE-3403 `<LanguageSetting />`), Appearance, sign-in method + change password (password sessions), Sign out. The sidebar footer no longer repeats identity/Sign out. Spec: `doc/md/SPEC-spool-wui-layout.md` §1.3 (what was ported from pas-psf `/account` and what was left out, and why). Checks, 2026-09-19:
  - `node src/node/test/run-unit-tests.mjs` → all 22 files pass (21 before; `tests/unit/user-menu.test.mjs` 9 tests); `nuxt typecheck` exit 0.
  - `node tests/e2e/no-x-scroll.test.mjs` n=2: 13/14 (one cold-compile timeout, `390x844 /lobby` waiting for `.spool-shell`), then 14/14.
  - live on dev, build `505a38e` (n=2, both 10/10): `BASE=https://dev.<domain> EMAIL=<invited t1 member> PW_FILE=<0600> OUT=/var/tmp/CLE-3402-proof node tests/e2e/user-menu-live.proof.mjs` — signed out desktop + mobile (corner = Sign in, `href=/login?redirect=/lobby`, x-scroll 0), native sign-in → avatar top-right (`Account menu for <user>`, member identicon), keyboard (Enter → Settings focused, ArrowDown → Sign out, Escape → button, `aria-expanded` false), items `["Settings","Sign out"]`, `/settings` sections Profile/Language/Appearance/Sign-in and security with the change-password form, mobile x-scroll 0, Sign out → corner is Sign in again.
  - prd `505a38e`, anonymous only (prd t1 is the owner's real tenant): corner = Sign in, x-scroll 0.
  - regression + recovery: build `2e2c601` (021 language switcher) sent an `x-locale` header on the cross-origin `/api/v1/auth/*` calls; the hub's CORS allows only `Content-Type`, so sign-in read "unavailable" on dev + prd (reported to CLE-3403 with the preflight). Hotfix `ecd9ad9`; the live proof re-ran on dev `ecd9ad9` → 10/10 (n=3 total), header switcher + `<LanguageSetting />` in place; prd `ecd9ad9` anonymous: corner = Sign in, 0 CORS errors, x-scroll 0.
  - NOT proven: an IdP picture in the corner (the test member is native, no picture); the owner's Google sign-in on dev shows it by the same `SpoolAvatar` path proven in 010 T044.

## CLE-3407 — Slack-style ``` code blocks (owner 2026-09-19: "enable the same feature as in slack to create code blocks by typing \"```\"")

- [x] T016 Implemented (`4c204d0`) — `utils/code-blocks.mjs` (fence parser `tokenize`/`parseBody`, composer state `fenceStateAt`/`enterAction`/`exitFence`/`closeOpenFence`), `components/MessageBody.vue` (block + inline rendering by text interpolation, lang label, copy button, `aria-live` "copied"), `MessageCard.vue` without `v-html`, `MessageComposer.vue` in-block state (monospace, live hint, Enter = newline, ``` / Esc close, Ctrl/Cmd+Enter send, no `@` picker in a block), `code.*` + `composer.code_hint` in 19 locales (`add_keys.py` + `splice_locales.py --delta`, machine drafts). FR-010. Checks, n=1, 2026-09-19, tree `4c204d0`: `cd csi-spl-wui && node --test tests/unit/code-blocks.test.mjs` → 30 pass (unclosed fence, fence inside inline code, CRLF, 20k-char line, longer fences, XSS strings, no `v-html`); `node src/node/test/run-unit-tests.mjs` → all 29 files, 318 tests pass; `nuxt generate` exit 0; local `tests/e2e/csp-violations.test.mjs` → 0 violations on 7 routes, control blocked; `no-x-scroll` → 50/50; `console-errors` → zero. CI on `4c204d0`: 30 run 35454927591 unit+typecheck success, prd deploy success (`spool-hub.ai/build.json` commit `4c204d0c`), dev deploy cancelled by a newer run; dev then served `1ad609f` (contains `4c204d0`).
- [x] T017 Implemented (`7e09ccc`) — live proof on dev (SC-005): `BASE=https://dev.spool-hub.ai EMAIL=<t1 test member> PW_FILE=<0600> OUT=/var/tmp/CLE-3407-proof node tests/e2e/code-blocks-live.proof.mjs` → 11/11 PASS on build `1ad609f` (n=2 runs; the first failed only its own English-label assertion, the page rendered in the member's bg locale; now locale-neutral): typing ```js turns the Omnibox monospace with the hint; Enter adds 8 lines, sends nothing; ``` closes; Enter sends; the card has one block labelled `js` with the exact text (tabs, blank line, 400-char line), `white-space: pre`, the block scrolls sideways and the page does not (desktop and 390×844: x-scroll 0); copy → clipboard equals the code exactly, label flips; CONTROL: `<script>` + `<img onerror>` inside and outside the block shown as text, 0 dialogs, 0 `img`/`script` in the body, 0 CSP violations. Screenshots `composer-in-block.png`, `composer-closed.png`, `feed-code-block-desktop.png`, `feed-copied.png`, `feed-code-block-mobile.png`. NOT proven live: the thread-pane and `/dm` composers (same `MessageComposer`/`MessageCard` components), a screen reader run (semantics only: `figure` + label, live hint, button names).

## CLE-3412 — newest on top everywhere, pushed live (owner 2026-09-19, US7)

- [x] T018 Implemented (`d7c2368`) — thread list `/` newest first and live: `utils/thread-list.mjs` `bumpThread` (a pushed message moves / inserts its thread row at the top; child threads skipped), `mergeThreadPage` (reconnect catch-up by `task_id`); `stores/viewer.ts` `follow()` sends `subscribe {all:true}`, unfollows on leave. FR-011. Check: `cd csi-spl-wui && node --test tests/unit/newest-live.test.mjs` → `# pass 25` (tree `fd5ae9a`, n=1).
- [x] T019 Implemented (`d7c2368`, `783a137`, `5b75227`, `fd5ae9a`) — `utils/scroll-anchor.mjs` (`prependedCount`, `anchorAfterPrepend`, `scrollerOf`, `firstVisibleRow`, `layoutTop`) + `composables/useScrollAnchor.ts` in `LiveFeed.vue` and `pages/index.vue`: the row in view keeps its place when rows land on top, a "New: N" pill (zero-height sticky row under the sticky top bar) jumps back; our own send jumps to the top. Three defects found live and fixed on the way (the page, not `.feed-body`, scrolls since the 022 top bar; a 50-row window drops a row at the bottom, so the height delta undercounts; the pill itself pushed the rows 53 px). Check: `node tests/e2e/scroll-anchor.test.mjs` (real Chrome, mock tenant) → 6/6 at 480 and 800 px, row in view moves < 2 px. FR-012.
- [x] T020 Implemented (`d7c2368`) — optimistic own send in `stores/live.ts` (lobby, `/t`, thread pane), `stores/channel.ts` (channels, DMs) and `ThreadPane.vue` (`pendingHere`): the card carries the client `msg_id` sent in the frame, `pending` until the echo or ack replaces it (`feed.mjs` `mergeById`, `channel-feed.mjs` `mergeLive`), removed on a failed send; reconnect catch-up merges (`mergePage`, `mergeById`) instead of replacing; the channel ThreadPane re-reads on reconnect. FR-013, FR-015.
- [x] T021 Implemented (`35bf0e0`; live on hub 0.1.10, `c8dadef`, dev + prd, rolled by CLE-3355) — hub `wui-live-ws` 0.5: `subscribe {peer}` and `subscribe {all:true}`, per-socket rule `wants()` in `internal/hub/wui.go`. Check: `go test -race ./...` green (tree `35bf0e0`, n=1); `TestWUIPeerSubscribeDM`, `TestWUIAllSubscribe`; CONTROL: removing the party rule makes both fail (a member got `C->B`). FR-014.
- [x] T022 Implemented (`d7c2368`) — `live-ws.mjs` `subscribePeer`/`unsubscribePeer`/`subscribeAll`/`unsubscribeAll`, re-sent after every reconnect before `onReconnected` fires; `channel-feed.mjs` `dmFollow`; `/dm/<peer>` follows its peer. FR-014.
- [x] T023 Implemented (`a6d148c`, `67b7330`) — proofs. Unit: `node src/node/test/run-unit-tests.mjs` → all 34 files pass (`newest-live.test.mjs` 25: ordering, dedupe, scroll anchoring, reconnect catch-up, WS follows). Live on dev, WUI `91687b2` (contains `fd5ae9a`), hub 0.1.10, n=2 runs, both 12/12 PASS: `BASE=https://dev.<domain> EMAIL=<t1 test member> PW_FILE=<0600> OUT=/var/tmp/CLE-3412-proof/dev-final-<n> BOX_CMD='<do_spl_box_msg_probe PROBE_BOX=box-live-probe PROBE_TASK=<lobby>>' node tests/e2e/newest-live.proof.mjs`. Two browser sessions of the same member; B's top row shows A's send in #lobby 65 / 105 ms, #live-proof 146 / 160 ms, DM 143 / 126 ms, thread list (new root) 119 / 93 ms; A's own card 9–18 ms, exactly one copy after the echo; B scrolled down: anchor row y 64.19 → 64.19 px, pill shown, pill → scrollTop 0; a box `spool send` into the lobby on B's top before the probe's own read-back returned (4.6 / 6.0 s after the probe started, which includes its hub-sync). Screenshots + `results.json` under `/var/tmp/CLE-3412-proof/`. NOT proven: two *different* humans (the dev test tenant has one test member; the fan-out rule for distinct humans is the Go test), a per-message box-push latency (the probe's own steps are inside the 4.6 s), prd live (prd t1 is the owner's real tenant: anonymous build check only, `spool-hub.ai/build.json` commit `91687b2`), reconnect catch-up live (unit only). SC-006.

## CLE-3423 — the code viewer: highlighting, no sideways scroll, a generic dialog, a 3-A4 send limit (owner 2026-09-19)

Owner, verbatim: "add proper syntax highlighting in the code windows - some kind of lightweight small lib to support many languages; also the code snippets must not have horizontal scrolling, if the code is too big it should have a small icon based \"open\" to open it fully. There should be a button to pop-up a big modal-dialog as well … this pop-up should know how to present the source code in full - if the source code snippet is greater than 3 A4, then an error during the upload should be presented prompting to do a file upload instead".

- [x] T024 Implemented (`de1451e` core, `469c432` components + locales) — FR-016/017/018.
  - **Highlighting, as tokens.** `utils/highlighter.mjs` drives `highlight.js` (pinned `~11.11.0`) through its emitter interface with `createTokenEmitter` (`utils/code-view.mjs`), which appends `{ text, cls }` runs instead of concatenating `<span>`s. **No HTML string is built anywhere**, so the `v-html`-free guarantee of `4c204d0` is kept by construction rather than by sanitising; `scopeToClass` transcribes highlight.js's own `scopeToCSSClass`, so the theme is plain CSS over our palette tokens in `CodeLines.vue` and follows `data-theme` light/dark. 36 grammars in `utils/code-langs.mjs`, each a literal `() => import(...)` so the bundler gives it its own chunk.
  - **NOT lowlight**, though it is the obvious pick (it returns a hast tree, which is the only reason this lane can highlight at all without `v-html`). Measured on this tree 2026-09-20 with `pnpm run generate`: its one entry point re-exports its `all` + `common` grammar bundles and the package declares no `sideEffects: false`, so Rollup kept them — **one 806 KB chunk statically importing every grammar, inside the initial graph**. Our emitter is 60 lines and costs nothing. `tests/unit/code-view.test.mjs` asserts lowlight is not a dependency.
  - **Bundle, measured with `src/node/test/bundle-size.mjs` on both builds** (`initial` = exactly the chunks `200.html` asks for — its `<script src>` and `<link rel=modulepreload>`; a transitive walk cannot tell `import "x"` from `import("x")` and read 179 KB as 526 KB). Tree `a228c92` (before) vs `469c432` (after): **initial 20 chunks 518.2 → 535.1 KB raw, 173.5 → 179.1 KB gzip (+16.9 raw / +5.6 gzip)**; all client JS 66 → 103 chunks, 1154.1 → 1355.2 KB raw, 343.0 → 422.1 KB gzip. The whole +79 KB gzip is lazy: the highlight.js runtime is 1 chunk, 20.5 KB raw / 8.2 KB gzip, and **is not in the initial set** (the script names the chunk if it ever is).
  - **No horizontal scrolling.** `CodeLines.vue` renders one row per source line, soft-wrapping with a hanging indent on the continuations as the wrapped-line marker; `.code-lines` is `overflow-x: hidden` and only `.no-wrap` (the dialog's opt-out) is `auto`. A 300-character line therefore wraps instead of scrolling. **This reverses the half of T017 that proved the block scrolls sideways**, so the unit assertion that pinned it was rewritten, not deleted, and `tests/e2e/code-blocks-live.proof.mjs` was updated with it (it also now reads the block through its rows and through `innerText`, since one row per line means `pre.textContent` has no newlines left to give — the browser's own serialisation, and therefore select-and-copy, still does).
  - **Preview + two ways in.** `previewOf` (20 lines / 1200 chars, cut on a line boundary, a prefix of the source byte for byte) bounds what a card shows; the head carries GRK-3370's `open` icon (`554e995`) and `copy`, and a cut preview also gets an explicit labelled button. **No new glyph was needed**, so `uiIcons.ts` is untouched and the `maximize` collision I flagged to GRK-3370 is withdrawn.
  - **The generic dialog.** `UiDialog.vue`: focus trap, Escape, backdrop, restored focus, locked page scroll, `aria-modal` + labelled title, scrollable body, teleported to `<body>` on the client only. It owns no content; `CodeViewer.vue` is the first content type and a file preview is a later sibling of it (extension point only — no file preview, by instruction).
  - **The 3-A4 send limit.** `sendLimitError` over the parsed body, wired into `MessageComposer.onSend`, refusing with a `role="alert"` line and KEEPING the text so it can be attached instead. Deliberately not `ErrorNotice`: that mints an `ERR-CLIENT-…` into the diagnostics journal, and a validation message would bury the failures the journal exists for. `code.*` (7 new keys) in all 19 locales via `add_keys.py` + `splice_locales.py --delta`; the 18 non-English ones are machine drafts, as every non-English catalogue here is until a native speaker reviews it (`src/python/i18n/README.md` step 3).
  - Checks, tree `469c432`, 2026-09-20, n=1: `cd csi-spl-wui && node src/node/test/run-unit-tests.mjs` → all 41 files pass; `node --test tests/unit/code-view.test.mjs` → 40 pass; `node --test tests/unit/code-blocks.test.mjs` → 30 pass; `pnpm run typecheck` → exit 0; `pnpm run generate` → exit 0. Boundaries are covered both ways (150 lines sends / 151 refuses; 9000 chars sends / 9001 refuses) with controls: an over-long INLINE span is not a block and is not refused; a `<script>` payload comes back byte-identical through four grammars; prose is left plain instead of coloured as the one grammar loaded; the shipped `highlight.js/lib/core.js` contains no `eval`, no `new Function` and no `WebAssembly`.
  - CI on `469c432`: 10 quality gate run `35487073608` success; 30 WUI run `35487073597` success with **Deploy WUI to dev** and **Deploy WUI to prd** both `success`. Live `build.json` then read `8536e7b` on dev and prd (a later lane's run `35487175879`); `git merge-base --is-ancestor 469c432 8536e7b` → exit 0, so both sites served this change.

- [x] T025 Proven — SC-007, live on dev. `BASE=https://dev.spool-hub.ai EMAIL=<t1 test member> PW_FILE=<0600> OUT=/var/tmp/CLE-3423-proof/run2 PUPPETEER_CORE=<wui>/node_modules/.pnpm/puppeteer-core@25.11.0/.../puppeteer-core.js node tests/e2e/code-viewer-live.proof.mjs` → **20/20 PASS** on build `cea65d28` (`git merge-base --is-ancestor 469c432 cea65d28` → exit 0, so that build carries this change), 2026-09-21, n=2 runs. The first run was 18/19 and the one FAIL was the SCRIPT's own fixture, not the product: `overCode` was 170 lines of `line_N = N`, over the LINE limit but only 2329 characters, so the "text is kept" assertion compared it against 9000. The fixture now pads every line past `SEND_LIMIT.chars / SEND_LIMIT.lines` (170 lines / 12069 chars) and a CONTROL step asserts it is over on BOTH axes, so neither half of the check alone can carry the pass.
  - Evidence from the run: bounded preview 20 of 46 lines, cut marker `"20 of 46 lines"`, both the icon and the explicit button present; `lang=python` with 41 highlighted tokens in the card and 93 in the dialog (the grammar chunk arrived); a 300-character line wraps — `blockScrolls=false`, document x-scroll 0 at 1280×800 **and** 390×844; the dialog is `aria-modal=true`, labelled, teleported out of the card, takes focus, holds all 46 lines byte-exact with 46 line numbers, its body scrolls while `documentElement` is `overflow:hidden` and the page x-scroll stays 0; Tab 12× cannot leave it; wrap and line-number toggles flip (`numsBefore=46 → numsAfter=0`) and the page still does not scroll sideways; copy yields the 2136-character source exactly; Escape closes, unlocks the page and returns focus to `code-open`. The over-limit send is refused with `role="alert"` reading "…170 lines / 12069 characters, over the limit of about 3 A4 pages (150 lines or 9000 characters). Attach it as a file instead.", 0 messages sent and 12077 characters kept in the composer. CONTROL: 0 dialogs, 0 `img`/`script` in the body, the `<script>` payload shown as text, 0 CSP violations. Screenshots `card-preview-desktop.png`, `card-preview-mobile.png`, `dialog-full-source.png`, `dialog-copied.png`, `composer-refused.png` + `results.json` under `/var/tmp/CLE-3423-proof/run2/`.
  - Local gates on this tree, 2026-09-21, n=1 each: `node tests/e2e/no-x-scroll.test.mjs` → **56/56**; `node tests/e2e/csp-violations.test.mjs` → **0 violations on 9 routes, control blocked** (inline script and inline handler both refused, 2 violations recorded as expected); `node tests/e2e/console-errors.test.mjs` → **zero console errors**.
  - NOT proven live: the thread-pane and `/dm` composers (same `MessageComposer` / `MessageCard` components as the lobby); a screen-reader run (semantics only — `role="dialog"` + `aria-modal` + labelled title, `aria-pressed` on the toggles, `role="alert"` on the refusal, `user-select: none` on the gutter); auto-detection live (unit only — it needs a fence with no tag AND a grammar already loaded); prd signed-in (prd t1 is the owner's real tenant, anonymous build check only).


## CLE-3425 / CLE-3429 — lists ordered by LAST activity, and exactly one thread section (owner 2026-09-20/21)

- [x] T026 Implemented (`9adb06c`, CLE-3425) — `/channel` and `/dm` order thread cards by LAST activity, not by the root ts: `src/utils/feed.mjs` (`activityOf`, `newestActivityFirst`) and `src/utils/channel-feed.mjs` (`threadCards` lifting the newest moment onto `last_ts`, plus `orderChannels`, `orderPeers`, `dmActivity`); `data-ts` on `MessageCard` and the thread rows. A live reply therefore raises `last_ts` and moves the card with no refetch and no duplicate row. Check, this tree (`035f77c` + this commit), 2026-09-21, n=1: `cd csi-spl-wui && node --test tests/unit/list-order.test.mjs` -> **28 pass, 0 fail**. Live proof script: `tests/e2e/list-order-live.proof.mjs`. FR-011.
- [x] T027 Implemented (`cea65d2`, CLE-3425) — the sidebar channel and DM lists are newest-first and live through ONE tab-wide `all` follow rather than a subscription per row: `src/plugins/spool-live.client.ts`, the ref-counted `all` subscription in `src/utils/live-ws.mjs`, and `src/stores/channel.ts` (`noteLive`, `addChannel`, `ordered`). Covered by the same suite as T026 — its +12 cases are the sidebar half of those 28. FR-011, FR-014.
- [x] T028 Implemented (`e54e4db`, CLE-3429) — exactly one thread section in the shell (1..1): `src/utils/thread-pane.mjs` plus mutually exclusive `v-if` / `v-else` mounting in `src/layouts/default.vue` and the `closes()` sync watcher, so no route in the walk can show two panes or none. Shell invariant, no FR of its own. Check, same tree, n=1: `node --test tests/unit/thread-pane-single.test.mjs` -> **7 pass, 0 fail**.
- The code viewer (FR-016/017/018, CLE-3423) is deliberately NOT restated here: it is T024-T025 above, written by the lane that measured it. An earlier index-sync pass numbered it `T027` against a trunk that did not yet carry those rows; the numbering in this file is the owning lane's.

### CLE-3425 — the measurement behind T026/T027, the hub half, and the live proof

Owner, verbatim: "change the order of appearance in the messages / any listing …
the default order should be newest first and popping on the top when a new msg
arrives and not being presented as the last one … and it should pop-up in
real-time … without the user having to refresh the page — use web sockets".
CLE-3412 delivered that for the messages of the OPEN view; the owner asked
again, so this lane measured every other list first and then fixed what failed.

Measured before-state, dev t1, 2026-09-20, WUI `019b93f`, hub 0.1.16:

| list | before | verdict |
|---|---|---|
| thread list `/` | newest activity first, live | already right (CLE-3412) |
| lobby feed | newest message first, live | already right (CLE-3412) |
| `/channel`, `/dm` cards | ordered by the ROOT ts | **wrong** |
| sidebar channels | a-z from the hub, never live | **wrong** |
| sidebar DMs | a-z by label | **wrong** |
| search results | order unknown — the page showed the view door | **blocked** |

The channel evidence, `GET /v1/view/threads?channel=lobby` (n=8 rows): the lobby
task `first_ts` 2026-09-19T16:29:52Z, `last_ts` 2026-09-20T03:04:50Z — the most
recently active thread in the channel — rendered BELOW seven threads whose only
activity was 17:56–18:56 the previous day. The sidebar evidence: rendered
`alerts, live-proof, lobby, tasks` while activity was live-proof 03:24:56Z,
lobby 03:04:50Z, the other two idle.

- T026 / T027 above are this lane's; what the rows do not carry is the WHY and
  the session gate. `channelView` sorted cards on the ROOT `ts`, so a reply into
  a thread moved nothing at all; it now sorts on `threadCards`' `last_ts`. The
  sidebar took ONE tab-wide `all` follow instead of a subscription per row, and
  `all` had to become ref-counted (`live-ws.mjs`) so the thread list on `/`
  dropping its own follow does not take the shell's down. Gated on the member
  session afterwards in `cbac1cd` (W4, CLE-55): signed out the whole follow -
  socket included - reads nothing. Measured signed out on prd `/lobby` and
  `/channel/lobby`, WUI `6c0fd44`, n=2 pages: `/v1/view/*` request count **1**
  (only `/v1/view/search/operators`, fired by `TopBar.vue`, another lane's
  file), down from 2.

- [x] T029 Implemented (`ebe5f55`; live on hub **0.1.17**, `39a5a25`, dev + prd,
  rolled by CLE-3355) — the hub answers newest first and pushes the one event a
  message fan-out cannot carry. `GET /v1/view/channels` newest activity first
  (`store.SortChannelStats` / `ChannelActivity`, both stores) and each row now
  carries `created_at`, so a channel created seconds ago ranks although it holds
  no message (channels-v1 **1.1.0**). New `channel` WS frame on
  `POST /v1/channels` to every browser socket of the tenant (wui-live-ws
  **0.6.0**). `view-v1` §4.1 humans and the search `humans` group: newest member
  first. Checks: `go test -race ./...` green (tree `ebe5f55`, n=1);
  `TestViewChannelsNewestActivityFirst`, `TestWUIChannelFrameOnCreate` (with the
  CONTROL that another tenant's socket gets nothing),
  `TestViewRosterHumansNewestFirst`, `TestSortChannelStatsNewestActivityFirst`,
  `TestSortHumansNewestFirst`.
- [x] T030 Implemented (`de64134`) — search rows carry the clock their group is
  ordered by (`search.mjs` `rowAt`, `data-key` + `data-ts` on every row), the
  last list whose rendered order could not be read off the page.
- [x] T031 Proven — SC-006 extended, live on dev, **12/12 PASS**, build
  `3a473a7` + hub 0.1.17 (`/var/tmp/CLE-3425-proof/after-dev-3`; the run before
  it, `after-dev-2`, passed the same 11 checks and failed only the script's own
  vacuous-group bug, fixed in the same commit as this line):
  `BASE=https://dev.<domain> EMAIL=<t1 test member> PW_FILE=<0600> OUT=<dir> node tests/e2e/list-order-live.proof.mjs`.
  Two signed-in sessions A and B. ORDER (read off `data-ts`, which must never
  increase down a list): thread list 50 rows, lobby feed 33, `#lobby` thread
  cards 20, sidebar channels 5, sidebar DMs (1 peer stamped of 9), search
  `threads:5` and `messages:5`; the thread list also matches the hub's own
  answer row for row. LIVE, with no reload: a reply into an OLD thread moves its
  card to B's top in **164 ms**, a message in another channel moves that channel
  to the top of B's sidebar in **109 ms**, a channel created by A appears on top
  of B's sidebar in **174 ms** (the `channel` frame) — all against a 1000 ms
  limit. Screenshots + `results.json` per run.
  - NOT time-ordered, reported rather than passed: the search `robots`, `users`,
    `channels` and `boxes` groups carry no clock per row (the hub orders those
    by id), so the script names them instead of checking them.
  - NOT proven: two DISTINCT humans (dev t1 has one test member — the fan-out
    rule for distinct humans is the Go test); prd signed in (prd t1 is the
    owner's real tenant: anonymous checks only — `spool-hub.ai/build.json`
    carries the shas, and the signed-out request count above); the DM-list tail
    beyond one peer with DM history.
- [x] T032 Fixed on the way, separate commit (`3a473a7`) — `/search` reads
  through `withSessionRetry`. Signed in as the test member, `/search?q=live`
  rendered "This tenant's threads need a member sign-in or a view token." and 0
  result rows (n=2, `/search` and `/en/search`), so search order could not be
  audited at all: `stores/search.ts` read straight through, so a member's first
  read on a fresh page never armed the session door (010 FR-009). `2dfefe7`
  fixed the same thing for `/channel`, `/dm` and the roster and did not reach
  the 022 search store. No live worktree or branch owned search.

<!-- version: 0.10.0 · updated: 2026-09-21 · last-edit: 2026-09-21T08:15:00Z -->

<!-- version: 1.1.0 · updated: 2026-09-21 · last-edit: 2026-09-21T08:25:00Z -->
