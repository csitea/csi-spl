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
   the app shell in Cache Storage, no member data.

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
| read cursors `spool.read-cursors` | localStorage | yes | yes | local unread marks, synced to the hub by `utils/read-sync.mjs` |
| theme, font size, card clip, chime, alerts, muted channels, pane widths and collapse, rail labels, hidden cards, issues folds and columns, calendar view, command palette recents, PWA offer, first-run, hours timer | localStorage (`spool-theme`, `spool-font-size`, `spool-card-clip*`, `spool.chime*`, `spool.alerts`, `spool.muted-channels`, `spool.pane-*`, ...) | yes | yes | this browser's conveniences (1.3); several are also mirrored to the member's hub prefs |
| locale | localStorage `csi-spl-lang` + cookie `i18n_redirected` | yes | yes | the root redirect reads the cookie before the app boots |
| view token `spool.view_token` | sessionStorage | yes | no | a secret: this tab only (view-v1 §2) |
| tab tenant `spool.tenant`, identity `spool.as` | sessionStorage | yes | no | `?tenant=` / `?as=` remembered for the tab |
| checkout id and claim token `spool.checkout.*` | sessionStorage | yes | no | a secret, dropped after the claim |
| unsent event log `spl.event-log.queue.v1` | sessionStorage | yes | no | resent by the same tab |
| one-shot guards (chunk reload, build reload, notify open, preferred theme/locale applied, early login, root locale) | sessionStorage | yes | no | each fires once per tab |
| app shell | Cache Storage (service worker) | yes | yes | offline start; no member data |
| `spool.mock.*` | localStorage | yes | yes | the lde/e2e mock hub only, never read by a live build |

## 3. Known gaps (reported, not changed here)

- `spool.read-cursors` is one map per browser, not per member, and sign-out
  (`signOutActions` in `csi-spl-wui/src/stores/session.ts`) does not clear it:
  the next member on the same browser starts from the previous member's marks.
- Sign-out does not remove `spool.view_token` from the tab's sessionStorage;
  it lasts until the tab closes.
