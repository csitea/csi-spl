# WUI client state: what survives a reload or a closed tab

Issue SPL-2169 (repo review suggestion 6: "Client state handling on refresh or
tab close is unclear with Pinia only. Clarify persistence strategy."). Measured
on master `4d0fcef06` (2026-10-18) with
`git grep -nE 'localStorage|sessionStorage|indexedDB|document\.cookie|caches\.open' -- csi-spl-wui/src`.
Pinned by `csi-spl-wui/tests/e2e/client-state-reload.test.mjs`.

## 1. The strategy

1. **The hub is the source of truth.** Pinia stores hold memory only; no
   store uses a persistence plugin (`grep -n persist csi-spl-wui/package.json`
   -> none). Every reload or new tab rebuilds them from the hub: the session
   from `GET /api/v1/auth/session` (the hub's cookie, which the WUI never
   reads), channels, topics, messages and the roster from their reads, then
   the live socket.
2. **The URL says where you are.** The page path (`/channel/<name>`,
   `/dm/<peer>`, `/t/<task_id>`) and its query (`?topic=`, `?tenant=`, `?as=`) are
   the place a reload returns to.
3. **localStorage keeps this browser's conveniences**, per profile, across
   tab close and restart: preferences and work in progress that is cheap to
   lose. Every read and write is in `try/catch` (`csi-spl-wui/src/utils/prefs.mjs`):
   blocked storage only means the default.
4. **sessionStorage keeps what belongs to this tab only**: the view token,
   the tab's tenant and `as` identity, one-shot guards. Gone when the tab
   closes.
5. **No secret in localStorage, a cookie or a URL.** The view token
   (view-v1 §2) and the checkout claim token stay in sessionStorage or memory;
   the session cookie is the hub's, set and cleared by the hub.
6. **IndexedDB is not used.** The service worker (`src/public/sw.js`) keeps
   the app shell and the `/_nuxt` bundle files in Cache Storage, no member
   data.
7. **Offline, the last copy of a feed is read** (SPL-2149, section 4). The
   first page of each channel or DM feed read from the hub, and the channel
   list, are kept in localStorage `spool.offline-feeds`, and shown when a read
   fails for want of a network. This is member data on the device: it is
   dropped at sign-out (section 3).

## 2. The inventory

"Reload" = the same tab reloaded; "close" = the tab closed and the page opened
again in the same browser profile.

| state | where kept | reload | close | why |
|---|---|---|---|---|
| Pinia stores (channel, topic, session, roster, search, editMode, ...) | memory | no | no | rebuilt from the hub (1.1) |
| signed-in session | hub cookie (HttpOnly, the hub's) | yes | yes | the hub's; the WUI asks `GET /api/v1/auth/session` |
| `spool.was-signed-in` | localStorage | yes | yes | tells "your session ended" from "never signed in" (`utils/session-recover.mjs`) |
| page, channel, DM, open topic | the URL | yes | only by reopening the URL | 1.2 |
| composer drafts `spool.drafts` | localStorage, per member | yes | yes | spec 080; 30 days / 50 places, dropped at send and at sign-out |
| read cursors `spool.read-cursors` | localStorage | yes | yes | local unread marks, synced to the hub by `utils/read-sync.mjs`; dropped at sign-out (section 3) |
| theme, font size, card clip, chime, alerts, muted channels, pane widths and collapse, rail labels, hidden cards, issues folds and columns, calendar view, command palette recents, PWA offer, first-run, hours timer | localStorage (`spool-theme`, `spool-font-size`, `spool-card-clip*`, `spool.chime*`, `spool.alerts`, `spool.muted-channels`, `spool.pane-*`, ...) | yes | yes | this browser's conveniences (1.3); several are also mirrored to the member's hub prefs |
| locale | localStorage `csi-spl-lang` + cookie `i18n_redirected` | yes | yes | the root redirect reads the cookie before the app boots |
| view token `spool.view_token` | sessionStorage | yes | no | a secret: this tab only (view-v1 §2); dropped at sign-out |
| tab tenant `spool.tenant`, identity `spool.as` | sessionStorage | yes | no | `?tenant=` / `?as=` remembered for the tab |
| checkout id and claim token `spool.checkout.*` | sessionStorage | yes | no | a secret, dropped after the claim |
| unsent event log `spl.event-log.queue.v1` | sessionStorage | yes | no | resent by the same tab |
| one-shot guards (chunk reload, build reload, notify open, preferred theme/locale applied, early login, root locale) | sessionStorage | yes | no | each fires once per tab |
| app shell, `/_nuxt` bundle files | Cache Storage (service worker: `spool-shell-v1`, `spool-chunks-v1`) | yes | yes | offline start; no member data |
| last feed pages and channel list `spool.offline-feeds` | localStorage | yes | yes | offline reading (section 4); at most 8 feeds and 1.5 M characters; dropped at sign-out |
| `spool.mock.*` | localStorage | yes | yes | the lde/e2e mock hub only, never read by a live build |

## 3. Sign-out (SPL-2556)

Two gaps found by SPL-2169 are closed in `signOutActions`
(`csi-spl-wui/src/stores/session.ts`):

- `spool.read-cursors` is one map per browser. Sign-out removes it
  (`clearCursors` in `csi-spl-wui/src/utils/read-cursor.mjs`), so the next
  member on the same browser does not start from the previous member's marks.
  It is cleared rather than keyed per member: the member's marks are kept on
  the hub (`GET /v1/me/reads`, `utils/read-sync.mjs`) and come back with that
  member's next sign-in, and a per-member key would touch every reader of the
  map. It is cleared after the navigation to the login page: the open feed
  marks itself read again when the session goes out, and the route watch in
  `csi-spl-wui/src/plugins/notify.client.ts` no longer marks the last open
  channel read on the login page. A mark read in the last 5 s before sign-out
  (`PUSH_MS`) may not have reached the hub yet and is lost with the map.
- Sign-out removes `spool.view_token` from the tab's sessionStorage and from
  the API client (`setViewToken('')`), instead of keeping it until the tab
  closes.
- Sign-out removes `spool.offline-feeds` (SPL-2149, `clearOfflineFeeds`), so
  the next member on the browser never reads the previous member's messages.

Pinned by `csi-spl-wui/tests/e2e/client-state-reload.test.mjs` (O1, O2) and
`csi-spl-wui/tests/unit/read-cursor.test.mjs`.

## 4. Offline reading (SPL-2149)

UI review suggestion 8 (owner HUM-10, t1 1061f05f msg 4d63f24c): "ADD
OFFLINE/PWA SUPPORT. PwaInstallOffer exists but no service worker or offline
fallback was found." The worker did exist (`src/public/sw.js`, registered in
`src/plugins/pwa.client.ts`) and answered an offline navigation with its
cached document. Measured on the mock bundle (master `f54dded26`, n=1 per
case, `/channel/lobby` visited online, then CDP offline and a reload):

| served as | after the offline reload |
|---|---|
| the e2e harness (`serve-generated.mjs`, no cache header) | blank: 0 characters of text, every `/_nuxt` chunk `ERR_INTERNET_DISCONNECTED` |
| with Hosting's `/_nuxt` immutable header | the 3 cards render, from the HTTP cache and the mock's in-memory data |

So offline reading rested on the HTTP cache alone, the live hub's reads kept
nothing (an offline reload of a live tab has no messages: the session probe
answers `unknown`, which reads nothing), and nothing said the tab was offline.
What changed:

1. **Bundle files.** The worker keeps a copy of each `/_nuxt/**` file a page
   loads in `spool-chunks-v1`, beside the page's own request, and answers
   from it only while it is offline (`navigator.onLine` false). Online the
   page's request is never answered by the worker: answering every bundle
   file turned i18n-split and last-data-clock red on master 37411c802 (wf10
   39462940979). Hashed names: never stale; `/_nuxt/builds/**` stays the
   network's; at most 400 files. Unit test
   `csi-spl-wui/tests/unit/sw-app-shell.test.mjs`.
2. **Feeds.** `csi-spl-wui/src/utils/offline-feed.mjs` keeps each first page
   the channel store reads (`refresh`) and the channel list
   (`loadChannels`). A read that fails because the browser is offline, or a
   fetch that reached no server, shows the kept copy; the store's
   `offlineAt` holds the time it was read. A live tab whose probe answers
   `unknown` while offline (`readsKeptCopy`, `utils/offline-queue.mjs`)
   opens the channel from the kept copy. The mock hub's reads fail offline as
   a fetch would. Unit test `csi-spl-wui/tests/unit/offline-feed.test.mjs`.
3. **The strip.** `csi-spl-wui/src/components/OfflineBanner.vue` says
   "You are offline" and, for a kept copy, the time it was saved. Its strings
   are on demand (second catalogue). The channel and DM pages mount it and
   it renders only while the browser is offline. Its chunk loads with the
   page, and the reader's after the first page it keeps, so the worker holds
   both for the offline reload. Neither is in the first download
   (`ci_initial_gzip_kb`): master was at its 155 KB ceiling.

Pinned by `csi-spl-wui/tests/e2e/offline-read.test.mjs` (red on master
`f54dded26`: the page is blank after the offline reload). Not covered by an
e2e: the live hub path (CI e2e is the mock bundle) and a lazy page chunk
never loaded online, which still fails offline.

## 5. A tab open across a deploy (SPL-2770)

A deploy removes the previous build's `/_nuxt/` files. A tab still on that
build then asks for a chunk that is gone. Measured on prd 2026-10-21 (n=1):
`curl -s -o /dev/null -w '%{http_code} %{content_type}' https://spool-hub.ai/_nuxt/doesnotexist123.js`
-> `200 text/html`: the `**` SPA rewrite answered with the app shell, so the
import failed as a MIME error and the tab went white (owner, twice,
2026-10-20).

The hosting config (`csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`,
snapshot `csi-spl-wui/firebase.json`) now rewrites `/_nuxt/**`, ahead of `**`,
to a sentinel path the build never writes, so a missing file answers 404.
Hosting serves an existing file before any rewrite, so the current build is
untouched. This replaces the narrower `/_nuxt/builds/**` rule (CLE-77803).
With the 404, Vite's preload fails and `src/plugins/chunk-reload.client.ts`
reloads the tab once into the live build (`vite:preloadError`,
`app:chunkError`, or the browser's "Failed to fetch dynamically imported
module"). The local `serve-generated.mjs` answers the same 404. Unit test
`csi-spl-wui/tests/unit/firebase-builds-manifest.test.mjs` (red on master
`4e673f24c`: a missing chunk got 200 `/200.html`).
