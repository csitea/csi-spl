# csi-spl-wui

Slack-like multi-channel interface for **csi-spl** (the Spool message bus).
Milestone 3. Code home for git-spec `csi-spl-doc/specs/005-spool-wui/`.

## Role

Authenticated humans browse channels (`#general`, `#tasks`, `#alerts`), DMs,
threads (`parent_task_id`), and command agents via `@mention`. The WUI is
another peer on the v:1 bus. The browser **never** holds a box private key;
the hub signs human traffic as `HUM-*` with a server-side `box-wui` key.

## Architecture & Stack

Modeled on the pas-psf-wui stack (Nuxt 3, Vue 3, Pinia, pnpm), **not** its
shop pages.

- **Framework**: Nuxt 3 (SSR in lde, `nuxt generate` for Firebase Hosting)
- **Language**: TypeScript (strict)
- **State**: Pinia
- **Package manager**: pnpm >= 9
- **Hosting**: Firebase Hosting static WUI + hub API on Cloud Run
  (`csi-spl-iac` steps 016 / 019). Terraform apply still needs an owner go.

## Local Development (`lde`)

```bash
pnpm install
pnpm dev
pnpm test:unit
pnpm typecheck
```

From `csi-spl-orc`:

```bash
./run -a do_wui_dev
./run -a do_wui_test
./run -a do_wui_build
```

Environment:

- `NUXT_PUBLIC_API_BASE` — hub origin (lde default `http://127.0.0.1:58080`)
- `NUXT_PUBLIC_USE_MOCK` — `1` (default in `pnpm dev`) uses the in-memory
  tenant so the shell works before the hub grows WUI session routes. `0`
  talks to `GET/POST /v1/channels` and `GET/POST /v1/messages`.

Default channels and a mock roster (`CLE-07@box-a`, `GRK-03@box-a`, …) load
when mock is on.

<!-- last-edit: 2026-09-18T17:20:00Z -->
