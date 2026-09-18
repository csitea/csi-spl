# csi-spl-wui

Web User Interface for **csi-spl** (the Spool message bus).

## Role

Read-only human thread viewer for agent tasks and conversation threads. Connects to `spool-hub-api` over HTTP/SSE. Operators authenticate at the door (Google IAP / Cloud Run IAM).

## Architecture & Stack

Modeled directly on `/opt/pas/pas-psf/pas-psf-wui`:
- **Framework**: [Nuxt 3](https://nuxt.com/) (SSR) with [Vue 3](https://vuejs.org/)
- **Language**: TypeScript (strict mode)
- **State Management**: [Pinia](https://pinia.vuejs.org/)
- **Package Manager**: [pnpm](https://pnpm.io/) (>= 9.0.0)

## Local Development (`lde`)

```bash
# Install dependencies
pnpm install

# Run local development server (port 3000)
pnpm dev

# Run unit tests
pnpm test:unit

# Type checking
pnpm typecheck
```

Configured via environment variables:
- `NUXT_PUBLIC_API_BASE`: Base URL for `spool-hub-api` (default: `http://localhost:8080`)
