# csi-spl-wui

Slack-like multi-channel interface for **csi-spl** (the Spool message bus).
Milestone 3. Code home for git-spec `csi-spl-doc/specs/005-spool-wui/`.

## Role

First slice: a read-only thread viewer (one thread per `task_id`). Channels,
DMs and `@mention` commands are later M3 slices, mock-only today. The browser
**never** holds a box private key; when human send arrives (later slice) the
hub signs it as `HUM-*` with a server-side `box-wui` key.

## Fronts this WUI copies (implementation, not shop pages)

| Tree | What we take |
|---|---|
| `pas-psf-wui` / `csi-rel-wui` | Nuxt 3 + Pinia + pnpm, `variables.css` / `base.css` / `main.css`, document `overflow-x: clip` + `max-width: 100%`, `.version` stamp, `nuxt generate` to Firebase Hosting |
| `dob-luk-wui` | Dark navy + cyan token pair, light `data-theme` override, inline SVG favicon, `__APP_VERSION__` / `#app-version` |
| `ora-cam-wui` | `data-theme` toggle, `prefers-reduced-motion`, 44–48px tap targets, `overflow-x: clip` on `html` |

Do **not** copy storefront catalogue/cart, workshop WhatsApp CTAs, or camp
pages. Hosting remains Firebase Hosting + Cloud Run API (`016` / `019`).

## Architecture & Stack

- **Framework**: Nuxt 3 (SSR in lde, `nuxt generate` for Firebase Hosting)
- **Language**: TypeScript (strict)
- **State**: Pinia
- **Package manager**: pnpm >= 9
- **Theme**: dark default (navy/cyan); light via the sidebar toggle

## Local Development (`lde`)

```bash
pnpm install
pnpm dev
pnpm test:unit
pnpm test:e2e
pnpm typecheck
```

`pnpm test:e2e` loads `/login` and `/channel/general` at 390x844 and 1280x800
and asserts `document.scrollingElement.scrollWidth <= innerWidth`. When
`BASE_URL` is unset it starts `nuxi dev` with the mock tenant. Uses
puppeteer-core when resolvable (`PUPPETEER_CORE` or `node_modules`); otherwise
Chrome DevTools Protocol against `CHROME_PATH` (default `/usr/bin/google-chrome`).

From `csi-spl-orc`:

```bash
./run -a do_wui_dev
./run -a do_wui_test
./run -a do_wui_build
```

Environment:

- `NUXT_PUBLIC_API_BASE` — hub origin (lde default `http://127.0.0.1:58080`)
- `NUXT_PUBLIC_USE_MOCK` — `1` (default in `pnpm dev`) uses the in-memory
  tenant. `0` reads the hub's read-only viewer API only
  (`csi-spl-doc/specs/003-spool-message-bus/contracts/view-v1.md`:
  `/v1/view/threads`, `/v1/view/threads/{task_id}`, `/v1/view/roster`,
  `/v1/view/channels`, plus `GET /v1/files/{file_id}` and `/v1/health`). The
  browser never opens `/v1/ws`. Live send, channel creation and channel feeds
  refuse: the M3 viewer is read-only (spec 005 §0).
- `NUXT_PUBLIC_POLL_MS` — thread poll interval (default 4000, floor 2000).

View token: on a `401` the viewer asks for one and keeps it in
`sessionStorage` (`spool.view_token`), never `localStorage` or a URL.

Sign-in in lde (spec 010 `contracts/auth-v1.md`, fake Google + Facebook):

```bash
cd ../csi-spl-api/src/go/spool-hub-api && go run ./internal/auth/cmd/auth-demo -addr 127.0.0.1:58181 -app-url http://localhost:3000 -public-url http://localhost:3000
```

```bash
NUXT_DEV_AUTH_PROXY=http://127.0.0.1:58181 pnpm dev
```

Open `http://localhost:3000/login` (use `localhost`, matching `-app-url`, so the
session cookie lands on the same origin). `NUXT_DEV_AUTH_PROXY` forwards
`/api/v1/auth/**` same-origin, as the Hosting rewrite does in dev/prd.

Pages: `/` thread list, `/t/<task_id>` one thread oldest first. The mock
channel / DM pages remain for the later M3 slices (spec 005 §1, Planned).

<!-- last-edit: 2026-09-18T21:45:00Z -->
