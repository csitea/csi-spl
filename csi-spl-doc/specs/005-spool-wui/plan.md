# Implementation Plan: Spool WUI (read-only thread viewer)

**Feature ID**: `005-spool-wui` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Narrative**: `../../doc/md/SPEC-spool-wui.md`  
**Prerequisite**: `../003-spool-message-bus/` (hub `GET /v1/messages` and `GET /v1/files/{id}`)

## Summary

Build the human thread viewer in `csi-spl-wui` as a **Nuxt 3 SSR + TypeScript** web application directly modeled after `/opt/pas/pas-psf/pas-psf-wui`. It connects to the hub HTTP API via the door (operator IAP / Cloud Run IAM), renders `v:1` messages chronologically per `task_id`, allows safe file downloads, and streams live updates (SSE or polling).

## Technical Context

**Language/Framework**: Nuxt 3 (SSR), Vue 3, TypeScript, Pinia, pnpm >= 9. Modeled directly on `/opt/pas/pas-psf/pas-psf-wui`.

**Code Home**: `csi-spl-wui/`

**Primary Dependencies**:
- `nuxt`: ^3.16
- `vue`: ^3.5
- `pinia`: ^3.0
- `@pinia/nuxt`: ^0.11
- `pnpm`: ^9.15

**Door Authentication**:
- Operator identity at the door (Google IAP / Cloud Run IAM header `X-Goog-Authenticated-User-Email` or Firebase Auth).
- The WUI never holds agent private keys, never signs messages, and does not post messages in v1.

**Local Dev Setup (`lde`) Reference**:
Directly modeled on `/opt/pas/pas-psf/pas-psf-wui`:
- `pnpm dev --host 0.0.0.0 --port 3000`
- `NUXT_PUBLIC_API_BASE` pointing to local hub (`http://localhost:8080`) or Cloud Run staging
- Fast hot module replacement (HMR) via Vite
- Tests: `pnpm test:unit` and e2e smoke matching `pas-psf-wui` conventions

## Constitution Check

- [ ] **I. Paths** — project under `csi-spl-wui`; no hard-coded `/opt/...` in app source.
- [ ] **II. Env** — API base URL, auth domain, and port configurable via env vars (`NUXT_PUBLIC_API_BASE`).
- [ ] **VII. No key in git/state/log** — WUI holds zero agent private keys; signed GCS URLs never logged.
- [ ] **VIII. Uniform API** — consumes standard `v:1` JSON messages; no per-kind UI dialects.
- [ ] **Reference read-only** — references `pas-psf-wui` architecture without importing or coupling.

## Project Structure

```text
csi-spl-wui/
├── package.json               # pnpm, Nuxt 3, Vue 3, Pinia (matching pas-psf-wui)
├── nuxt.config.ts             # SSR config, runtimeConfig, proxy/CORS
├── tsconfig.json              # strict TypeScript
├── app.vue                    # root layout & navigation
├── pages/
│   ├── index.vue              # recent tasks table / search by task_id
│   └── task/
│       └── [id].vue           # chronological thread view for task_id
├── components/
│   ├── MessageCard.vue        # renders v:1 message (ts, from, to, kind, body)
│   ├── FileAttachment.vue     # download link with hash verify & size display
│   ├── KindBadge.vue          # visual badge for task | result | note | reject
│   └── AgentBadge.vue         # visual badge for CLE-* | GRK-* | AGY-* | HUM-*
├── stores/
│   └── task.ts                # Pinia store caching threads and active tasks
├── composables/
│   └── useSpoolApi.ts         # typed fetch client for hub /v1/messages and /v1/files
└── tests/
    └── unit/                  # component and store unit tests
```

## Build Order

1. Project scaffolding (`package.json`, `nuxt.config.ts`, `tsconfig.json`) matching `pas-psf-wui`.
2. Composable `useSpoolApi` and Pinia store for `/v1/messages`.
3. Task list view (`pages/index.vue`) and thread detail view (`pages/task/[id].vue`).
4. File download card with sha256 verification.
5. Live update subscription (SSE `/v1/events` or fallback polling).
6. Local dev runner integration in `csi-spl-orc`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:35:00Z -->
