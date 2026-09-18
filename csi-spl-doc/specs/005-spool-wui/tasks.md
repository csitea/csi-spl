# Tasks: Spool WUI (Slack-like Multi-Channel Interface)

**Feature**: `specs/005-spool-wui` · **Milestone 3 Rollout**

Gate: 003 hub HTTP/WebSocket API and 006 tenant auth.

## Phase 1: Scaffolding & Setup (pas-psf-wui pattern)

- [x] T001 [P] Scaffold `csi-spl-wui/package.json`, `nuxt.config.ts`, and `tsconfig.json` using pnpm, Nuxt 3, Vue 3, Pinia, and strict TypeScript (modeled directly on `/opt/pas/pas-psf/pas-psf-wui`).
- [x] T002 [P] Configure local dev setup (`lde`) scripts: `pnpm dev` (port 3000), `pnpm build`, `pnpm typecheck`, `pnpm test:unit`.
- [x] T003 [P] Implement `csi-spl-wui/composables/useSpoolApi.ts`: typed fetch client for hub HTTP endpoints (`/v1/messages`, `/v1/channels`, `/v1/files/{id}`, `/healthz`).

## Phase 2: User Story 1 & 3 — Shell, Channels & DMs (P1) 🎯 MVP

**Goal**: Operator sees Slack-like sidebar with Channels (`#general`, `#tasks`, `#alerts`) and DMs with online/offline agent status, and can switch channels.

- [x] T004 [US1] Create Pinia stores: `stores/channel.ts` (channel lists & messages) and `stores/roster.ts` (live agents & boxes).
- [x] T005 [P] [US1] Implement `components/ChannelSidebar.vue`: channels list, DM list, and unread badges.
- [x] T006 [US1] Implement `components/MessageFeed.vue` and `components/MessageCard.vue`: chronological message feed with author/kind badges, markdown rendering, and reply count.
- [x] T007 [US1] Implement `pages/channel/[name].vue` and `pages/dm/[peer].vue`.

## Phase 3: User Story 2 & 4 — Threading with `parent_task_id` & Mentions (P1)

**Goal**: Every message has `task_id`; replies carry `parent_task_id` opening in a side Thread Pane; `@mention` directs tasks to agents.

- [x] T008 [US2] Create Pinia store `stores/thread.ts` managing active thread messages filtered by `parent_task_id`.
- [x] T009 [US2] Implement `components/ThreadPane.vue`: right-side collapsible panel rendering thread replies oldest-first with its own composer.
- [x] T010 [US4] Implement `components/MessageComposer.vue`: text input with `@mention` autocompletion for agents in the channel, file attachment button, and send action.

## Phase 4: User Story 5 & Live Events (P2)

**Goal**: Live message streaming via WebSocket / SSE; dynamic channel creation by humans and agents.

- [x] T011 [US5] Implement dynamic channel creation modal in WUI and API endpoint `POST /v1/channels`.
- [x] T012 [P] Implement `composables/useSpoolEvents.ts` for live updates in active channel and thread pane.

## Phase 5: User Stories 6, 7 & 8 — File Downloads, Notifications & Verbosity

**Goal**: Clean file download links, HTML5 browser alerts/chimes, and progressive disclosure of thread notes.

- [x] T015 [US6] Implement `components/FileAttachment.vue`: card displaying filename, formatted byte size, sha256 verify, and direct download button fetching via `GET /v1/files/{sha256}`.
- [x] T016 [US7] Implement `components/NotificationCenter.vue`: HTML5 desktop/browser push notification requests, audio chime trigger, and unread badge management.
- [x] T017 [US8] Implement `components/VerbositySelector.vue` in `components/ThreadPane.vue` allowing switching between `minimal`, `normal`, and `verbose` execution progress notes.

## Phase 6: Dev Harness & Deployment

- [ ] T018 [P] Configure tenant product auth (OAuth2 / Magic Link session issuing HTTP-only cookie; hub signs messages as `HUM-<username>` with virtual `box-wui` key).
- [x] T019 [P] Wire `./run` actions in `csi-spl-orc` (`do_wui_dev`, `do_wui_build`, `do_wui_test`) referencing `pas-psf-orc`.
- [x] T020 [P] Add `csi-spl-wui/tests/e2e` no-x-scroll: `/login` and `/channel/general` at 390x844 and 1280x800 (`pnpm test:e2e`).

Hosting (landed with T019): `csi-spl-iac` steps `016-firebase-deploy-iam` and `019-firebase-static-site` copy the pas-psf/csi-rel Hosting shape (site + custom domain + deploy SA) without shop pages and without minting an SA key. Apply still needs an owner go.

<!-- version: 0.4.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:20:00Z -->
