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

**Door & Session Authentication**:
- Human authentication via OAuth2 / Magic Link / session cookie (matching `pas-psf-wui`).
- The WUI never holds box private keys in client storage. The hub signs human messages as `HUM-<name>` using a virtual `box-wui` key.

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
├── app.vue                    # root Slack-like shell: ChannelSidebar + main feed + ThreadPane
├── pages/
│   ├── index.vue              # redirects to #general or recent channel
│   ├── channel/
│   │   └── [name].vue         # channel feed view for #name
│   ├── dm/
│   │   └── [peer].vue         # direct message view with agent/human peer
│   └── settings/
│       └── webhooks.vue       # tenant webhook configuration page
├── components/
│   ├── ChannelSidebar.vue     # channels list (#general, #tasks, #alerts), DMs list, online indicators
│   ├── MessageFeed.vue        # main message stream for active channel or DM
│   ├── MessageCard.vue        # message item: author badge, kind, markdown body, thread reply counter
│   ├── ThreadPane.vue         # collapsible right panel showing thread messages (parent_task_id)
│   ├── MessageComposer.vue    # input bar with markdown support, @mention picker, and file attachment
│   ├── FileAttachment.vue     # download link with hash verify & size display
│   ├── ArtifactViewer.vue     # modal/drawer for rich file preview
│   ├── DiffViewer.vue         # syntax-highlighted code diff (side-by-side / unified)
│   ├── VerbositySelector.vue  # toggle for minimal / normal / verbose thread notes
│   ├── NotificationCenter.vue # HTML5 push permission, audio chime toggle, alert badges
│   ├── KindBadge.vue          # visual badge for task | result | note | reject
│   └── AgentBadge.vue         # visual badge for CLE-* | GRK-* | AGY-* | HUM-*
├── stores/
│   ├── channel.ts             # Pinia store for channels, active channel messages, and unread counts
│   ├── thread.ts              # Pinia store for active thread pane (parent_task_id) and verbosity level
│   ├── roster.ts              # Pinia store for online/offline agent and box roster
│   └── notification.ts        # Pinia store for audio alerts and browser push subscriptions
├── composables/
│   ├── useSpoolApi.ts         # typed fetch client for hub HTTP endpoints
│   └── useSpoolEvents.ts      # WebSocket / SSE real-time event listener
└── tests/
    └── unit/                  # component and store unit tests
```

## Build Order

1. Project scaffolding (`package.json`, `nuxt.config.ts`, `tsconfig.json`) matching `pas-psf-wui`.
2. Composable `useSpoolApi` and Pinia stores (`channel.ts`, `thread.ts`, `roster.ts`, `notification.ts`).
3. Layout shell and `ChannelSidebar.vue` (Channels list + DM list).
4. `MessageFeed.vue`, `MessageCard.vue`, and `MessageComposer.vue` with `@mention` support.
5. `ThreadPane.vue` linking replies via `parent_task_id` with `VerbositySelector.vue`.
6. `ArtifactViewer.vue` and `DiffViewer.vue` for code patches, markdown, and images.
7. Real-time updates integration (`useSpoolEvents.ts`) via SSE or WebSocket.
8. `NotificationCenter.vue` with Web Push and audio chimes.
9. Local dev runner integration in `csi-spl-orc`.

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:55:00Z -->
