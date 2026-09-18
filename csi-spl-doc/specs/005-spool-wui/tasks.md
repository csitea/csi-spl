# Tasks: Spool WUI (read-only thread viewer)

**Feature**: `specs/005-spool-wui`

Gate: 003 T005 (`GET /v1/messages`) and T007 (`GET /v1/files/{id}`) or a mock/sqlite testhub with identical response shapes.

## Phase 1: Scaffolding & Setup (pas-psf-wui pattern)

- [ ] T001 [P] Scaffold `csi-spl-wui/package.json`, `nuxt.config.ts`, and `tsconfig.json` using pnpm, Nuxt 3, Vue 3, Pinia, and strict TypeScript (modeled directly on `/opt/pas/pas-psf/pas-psf-wui`).
- [ ] T002 [P] Configure local dev setup (`lde`) scripts: `pnpm dev` (port 3000), `pnpm build`, `pnpm typecheck`, `pnpm test:unit`.
- [ ] T003 [P] Implement `csi-spl-wui/composables/useSpoolApi.ts`: typed fetch client for hub HTTP endpoints (`/v1/messages`, `/v1/files/{id}`, `/healthz`).

## Phase 2: User Story 1 — Operator opens a task thread (P1) 🎯 MVP

**Goal**: Operator can open any `task_id` and read the conversation thread in chronological order, with author/kind badges and file attachments.

- [ ] T004 [US1] Create Pinia store `csi-spl-wui/stores/task.ts` to manage thread message state and task summaries.
- [ ] T005 [P] [US1] Implement `KindBadge.vue` (`task`, `result`, `note`, `reject`) and `AgentBadge.vue` (`CLE-*`, `GRK-*`, `AGY-*`, `HUM-*`).
- [ ] T006 [P] [US1] Implement `FileAttachment.vue`: secure download link via hub `/v1/files/{id}`, sha256 display, byte formatting.
- [ ] T007 [US1] Implement `MessageCard.vue`: renders single `v:1` message card (timestamp in RFC3339/local, sender/recipient badges, markdown body rendering without HTML injection).
- [ ] T008 [US1] Implement `pages/index.vue`: recent tasks overview table with search/filter by `task_id` or agent ID.
- [ ] T009 [US1] Implement `pages/task/[id].vue`: full thread page displaying messages in strict oldest-first order.
- [ ] T010 [P] [US1] Component unit tests and render tests against golden `v:1` fixtures.

## Phase 3: User Story 2 — Live updates (P2)

**Goal**: Thread updates live as agents send new messages without requiring manual page reload.

- [ ] T011 [US2] Implement SSE subscription in `useSpoolLive.ts` connecting to hub live notify stream, with automatic graceful fallback to periodic GET polling.
- [ ] T012 [US2] Wire live updates into `stores/task.ts` to append new messages dynamically.

## Phase 4: Dev Harness & Door Authentication

- [ ] T013 [P] Configure door authentication handling (IAP / Cloud Run IAM header forwarding, reading `X-Goog-Authenticated-User-Email` for display).
- [ ] T014 [P] Wire `./run` actions in `csi-spl-orc` (`do_wui_dev`, `do_wui_build`, `do_wui_test`) referencing `pas-psf-orc` local dev setup.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:35:00Z -->
