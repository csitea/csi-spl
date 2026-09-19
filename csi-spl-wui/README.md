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

## Layout

Same shape as the `pas-psf-wui` donor: `nuxt.config.ts` sets `srcDir: 'src/'`,
so every Nuxt source lives under `src/` (`app.vue`, `error.vue`, `assets/css`,
`components/`, `composables/`, `layouts/`, `pages/`, `plugins/`, `public/`,
`stores/`, `types/`, `utils/`, `node/test`). The package root keeps
`package.json`, `nuxt.config.ts`, `firebase.json`, `.version`, `tests/` and the
build output `.output/public`, so `pnpm dev` / `pnpm generate` and the Hosting
contract run from `csi-spl-wui/` exactly as before. `@/` and `~/` both resolve
to `src/`.

`pnpm test:unit` runs `src/node/test/run-unit-tests.mjs`, which discovers every
`tests/unit/*.test.mjs` (exit 1 on any failure or when none is found).

## Local Development (`lde`)

### In docker compose, against the live lde hub

The whole stack runs from `csi-spl-orc` with docker compose: Postgres, the GCS
emulator, the hub (`spool serve`) and this WUI (the `wui` service in
`csi-spl-orc/src/docker/docker-compose-wui.yaml`: the Nuxt dev server with
`NUXT_PUBLIC_USE_MOCK=0` and `NUXT_PUBLIC_API_BASE=http://{tenant}.localhost:<hub port>`).
The service mounts this whole directory, so it follows any source layout. It
needs no network at runtime: it starts this tree's own `node_modules/nuxt`
(no corepack, no pnpm, no registry) as the owner of this directory, so its
`.nuxt` stays yours and a host typecheck keeps working.

Stand up and smoke the hub stack (pg, gcs, migrate, serve, box hello; exit 0 =
all PASS). It also seeds tenant `t1` and pins the box `box-smoke` under it.
Tenants and schema in lde come from here; `do_spl_db_bootstrap` is the
dev/prd (Cloud SQL) counterpart and is not used locally:

```bash
cd csi-spl-orc && ./run -a do_setup_app_inf
```

Start the WUI container (waits for `GET http://localhost:<wui port>/` -> 200).
This directory must already have `node_modules` (a hydrated worktree, or
`pnpm install` here):

```bash
cd csi-spl-orc && ./run -a do_wui_up
```

Without `node_modules`, let a one-shot container install it first. This is the
only lde step that needs the npm registry:

```bash
cd csi-spl-orc && LDE_WUI_INSTALL=1 ./run -a do_wui_up
```

The container runs whatever `node_modules` this tree has, so after a
`package.json` / `pnpm-lock.yaml` change run `pnpm install` here first. A stale
tree shows as `Could not load <module>. Is it installed?` in
`docker logs <project>-wui-1`. If the WUI port is taken (e.g. by a host
`nuxi dev` on 3000), `do_wui_up` names the process: stop it, or pass another
`LDE_WUI_PORT`.

Open `http://localhost:3000/` (cnf `env.lde.wui.host_port`). It lists the
threads of tenant `t1` from the hub at `http://t1.localhost:58080`.

A second tree next to a running one overrides every host port. The hub's
`SPOOL_HUB_VIEW_CORS_ORIGINS` follows the WUI ports in use: `do_gen_docker_env`
adds this tree's `LDE_WUI_PORT`, every sibling tree's `LDE_WUI_PORT` (from its
rendered `compose.env`), and `LDE_WUI_EXTRA_ORIGINS`. The hub picks the list up
when `do_wui_up` or `do_setup_app_inf` re-applies it:

```bash
cd csi-spl-orc && LDE_PG_PORT=55433 LDE_GCS_PORT=54444 LDE_HUB_PORT=58081 ./run -a do_setup_app_inf
```

```bash
cd csi-spl-orc && LDE_PG_PORT=55433 LDE_GCS_PORT=54444 LDE_HUB_PORT=58081 LDE_WUI_PORT=3008 ./run -a do_wui_up
```

A WUI served outside compose (e.g. a host `nuxi dev --port 3067`) against the
main checkout's hub: from the main checkout, re-apply the hub with that origin:

```bash
cd csi-spl-orc && LDE_WUI_EXTRA_ORIGINS=http://localhost:3067 ./run -a do_wui_up
```

Check a browser origin is allowed (expected: `204` and
`Access-Control-Allow-Origin` echoing exactly that origin):

```bash
curl -s -o /dev/null -D - -X OPTIONS -H 'Origin: http://localhost:3008' -H 'Access-Control-Request-Method: GET' http://t1.localhost:58081/v1/view/threads
```

To put threads on the hub, route messages between two boxes (a message
between two agents of one box is delivered locally and never reaches the
hub). The state dir is `$HOME/.local/share/csi-spl/lde/<tree-slug>`
(`main` for the main checkout, the lowercased worktree name otherwise):

```bash
export LDE_S=$HOME/.local/share/csi-spl/lde/main H=$HOME/.local/share/csi-spl/lde/main/hello U=http://t1.localhost:58080
```

Make and pin a second box `box-peer` with the tenant root key:

```bash
SPOOL_BOX_ID=box-peer SPOOL_ROOT=$H/spool-box-peer SPOOL_KEYS_DIR=$H/keys $LDE_S/bin/spool keygen > $H/box-peer.pub
```

```bash
SPOOL_HUB_URL=$U SPOOL_BOX_ID=box-smoke SPOOL_ROOT=$H/spool-box-smoke SPOOL_KEYS_DIR=$H/keys $LDE_S/bin/spool hub-pin --box box-peer --pubkey "$(tail -1 $H/box-peer.pub)" --root-key $H/root.key --force
```

A box announces the agents that have a dir under its `SPOOL_ROOT`:

```bash
mkdir -p $H/spool-box-smoke/CLE-910 $H/spool-box-peer/CLE-911
```

```bash
SPOOL_HUB_URL=$U SPOOL_BOX_ID=box-peer SPOOL_ROOT=$H/spool-box-peer SPOOL_KEYS_DIR=$H/keys $LDE_S/bin/spool hub-sync
```

```bash
SPOOL_HUB_URL=$U SPOOL_BOX_ID=box-smoke SPOOL_ROOT=$H/spool-box-smoke SPOOL_KEYS_DIR=$H/keys $LDE_S/bin/spool hub-sync
```

```bash
SPOOL_HUB_URL=$U SPOOL_BOX_ID=box-smoke SPOOL_ROOT=$H/spool-box-smoke SPOOL_KEYS_DIR=$H/keys $LDE_S/bin/spool send --from CLE-910 --to CLE-911 --kind task --body "hello over the lde hub"
```

```bash
SPOOL_HUB_URL=$U SPOOL_BOX_ID=box-smoke SPOOL_ROOT=$H/spool-box-smoke SPOOL_KEYS_DIR=$H/keys $LDE_S/bin/spool hub-sync
```

Check the hub, then reload the WUI (expected: the thread with subject
`hello over the lde hub`, participants `CLE-910@box-smoke, CLE-911@box-peer`):

```bash
curl -s http://t1.localhost:58080/v1/view/threads
```

Stop the WUI only, or the whole stack (`LDE_PURGE=1` also drops the volumes):

```bash
cd csi-spl-orc && ./run -a do_wui_down
```

```bash
cd csi-spl-orc && ./run -a do_teardown_app_inf
```

### The lde switches: sign-in and WUI dispatch

Sign-in and dispatch are off in lde by default (cnf `env.lde.switches` in
`csi-spl-cnf/csi-spl/lde.env.yaml`). Each switch is an env var on the `./run`
call. `do_gen_docker_env` re-renders `hub.env` on every `do_setup_app_inf` and
`do_wui_up`, so pass the same switches to both, or the second call turns them
off again:

| switch | effect on the lde hub |
|---|---|
| `LDE_AUTH_NATIVE=1` | email + password sign-in (spec 015). Mail transport `log`, and register / forgot return the token in the body (debug tokens), so no inbox is needed |
| `LDE_AUTH_PROVIDERS=google,...` | social sign-in (spec 010). Export `SPOOL_HUB_AUTH_<P>_CLIENT_ID` and `_CLIENT_SECRET` for each provider, plus `SPOOL_HUB_AUTH_IDP_BASE_URL` for a fake IdP. They never go in cnf |
| `LDE_WUI_DISPATCH=1` | WUI dispatch (spec 014) with an ephemeral `box-wui` key. The hub mints a new key each time it starts |

An auth switch also gives the tree a session key, generated once into
`<state dir>/auth-session.key` with mode 0600. It is never in git. Auth uses
the WUI origin: the WUI dev server proxies `/api/v1/auth/**` to the hub, and
`SPOOL_HUB_AUTH_APP_URL` and the redirect URIs are
`http://localhost:<wui port>`. They follow `LDE_WUI_PORT`.

Turn native sign-in and dispatch on:

```bash
cd csi-spl-orc && LDE_AUTH_NATIVE=1 LDE_WUI_DISPATCH=1 ./run -a do_setup_app_inf
```

```bash
cd csi-spl-orc && LDE_AUTH_NATIVE=1 LDE_WUI_DISPATCH=1 ./run -a do_wui_up
```

Check it. Expected: `{"native":true,"providers":[]}`:

```bash
curl -s http://t1.localhost:58080/api/v1/auth/providers
```

Expected: `200 {"box_id":"box-wui","dispatch":true,"pubkey":"..."}`:

```bash
curl -s http://t1.localhost:58080/v1/wui/pubkey
```

Pin `box-wui` under `t1` with the smoke tenant's root key. The helper checks
that the pins row holds the hub's key. The key is ephemeral, so re-run it after
every hub restart:

```bash
cd csi-spl-orc && ./run -a do_spl_pin_box_wui
```

Another tenant needs its own root key:

```bash
cd csi-spl-orc && TENANT_ID=acme ROOT_KEY=/path/to/acme-root.key ./run -a do_spl_pin_box_wui
```

### On the host, with pnpm

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

- `NUXT_PUBLIC_API_BASE` — hub origin template: `{tenant}` becomes the tenant label
  (lde default `http://{tenant}.localhost:58080`; deployed
  `https://{tenant}.<fqdn>`). Tenant reads must go to the **tenant host** — the
  API host (`api.<fqdn>`, `dev.api.<fqdn>`, any reserved first label) answers
  `404 unknown_tenant` on every tenant route, and the WUI refuses it up front.
- `NUXT_PUBLIC_TENANT` — default tenant (lde `t1`). `?tenant=<id>` overrides it
  and is remembered for the tab.
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

Live chat against a real hub (two WUI sockets, lobby exchange, persistence,
file round trip; skipped without `HUB_URL`):

```bash
HUB_URL=http://t1.localhost:58080 pnpm test:live
```

Two browser sessions: open `/lobby?as=HUM-1` and `/lobby?as=HUM-2` in two
windows (`as` must be a v:1 agent id; omit it and the hub assigns one).

Checkout (spec 006 T021w, `contracts/checkout-v1.md`): `/checkout` reads the
plan and rail, and `/checkout/success` polls until the checkout is paid, then
claims the root private key ONCE and shows it once, with copy and download.
`NUXT_DEV_AUTH_PROXY` also forwards `/api/v1/checkout/**` to the hub. The claim
token is kept in `sessionStorage` (`spool.checkout.claim`) and dropped after
the claim. The key is held only in the page's memory. A reload shows "already
claimed". The unit rules are in `tests/unit/checkout-client.test.mjs`.

Pages: `/` thread list, `/t/<task_id>` one thread oldest first. The mock
channel / DM pages remain for the later M3 slices (spec 005 §1, Planned).

<!-- last-edit: 2026-09-18T22:10:00Z -->
