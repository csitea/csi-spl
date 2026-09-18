# Feature Specification: Spool WUI — read-only thread viewer first

**Feature ID**: `005-spool-wui` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, verified on trunk `bbc41e7`; viewer code `9eafd8c`)

**Ground rules, index, seams**: `../README.md` (status vocabulary §2.3, seams §5).
**Narrative (end-state vision)**: `../../doc/md/SPEC-spool-wui.md` (Slack-like).
**Binding**: `../002-box-agent-messaging/contracts/trust-modes.md`,
`../002-box-agent-messaging/contracts/message-schema.md` (frozen `v:1`),
`../../doc/md/SPEC-spool-milestones.md`, OQ-01..15 in `../003-spool-message-bus/spec.md`.
**Depends on**: 003 (hub; owns the WUI read API — README §5), 004 (ids,
`CLE-07@box-a`), 006 (tenant = Host, human auth), 007 (Hosting steps `016` / `019`,
DNS, ingress). Dependency order: 005 comes after the M1 demo and M2 (README §4).

## 0. Scope (the redo decision)

005 ships **one slice first**: a **read-only thread viewer** in `csi-spl-wui`
(Nuxt 3) over the **read-only hub viewer API that 003 owns**
(`../003-spool-message-bus/contracts/view-v1.md`, Planned). A human opens the tenant,
sees its threads (one per `task_id`), opens one, reads its messages oldest-first
and downloads attached blobs. **No send, no signing, no key in the browser.**

The Slack-like end state (`SPEC-spool-wui.md`: channels, DMs, `@mention`
commands, notifications, verbosity) is **not** this slice. It needs parts that do
not exist and that other areas own — a human session (006), a hub-side `box-wui`
signer (003/004) and a `channel` field the frozen `v:1` does not carry (002). Those
stories stay below as **Planned (M3 later)** with the blocking gap named (§5).

Why this cut: a thread **is** a `task_id` already (`SPEC-spool-task-lifecycle.md`;
every message of a thread shares it); the hub already stores every envelope per
`(tenant, task_id)` (`grep -n TaskEnvelopes csi-spl-api/src/go/spool-hub-api/internal/store/store.go -> 2`);
OQ-02 keeps send/recv WebSocket-only for boxes. A viewer is buildable without
reopening 002 or the trust model.

## 1. User scenarios

### US1 — Thread list (P1) 🎯 MVP — Partial

A human opens `https://<tenant>.<product-domain>` (tenant from Host, 006) and
sees the tenant's threads, newest activity first: first message's `from`, `to`,
`kind`, a body preview, message count and last-activity time.

**Acceptance**: with `NUXT_PUBLIC_USE_MOCK=0` against a hub holding 3 threads,
the list shows 3 rows by last activity; an empty tenant shows an empty state; an
unknown Host shows "unknown tenant" (hub 404, error token per 003).

### US2 — Thread view (P1) 🎯 MVP — Partial

Selecting a thread shows every stored message of that `task_id` oldest-first:
author as `<id>@<box>` (004 addressing; `from_box` / `to_box` are hub-envelope
fields the viewer shows and never sets), `kind` badge (`task | result | note | reject`),
`ts`, body as text / sanitised markdown.

**Acceptance**: task → note → result renders 3 cards in `ts` order; a body
containing `<script>` renders as text.

### US3 — Attachment download (P1) — Partial

Each `files[]` entry with `mode: "blob"` renders name, bytes and sha256 with a
Download link to `GET /v1/files/{file_id}` (003, tenant-scoped capability).
`mode: "path"` renders as an on-box path with **no link** (the bytes never left
the box; `internal/msg/msg.go` `Attachment`).

### US4 — Live follow (P2) — Planned

An open thread picks up new messages without a reload. Viewer: poll view-v1 §4.4
with `after=` while the tab is visible (runtime config, default 4 s, never under 2 s).
`/v1/ws` is Ed25519-hello only and is **not** a browser transport (OQ-04,
trust-modes); a browser push channel is a later 003 decision.

### US5 — Human sign-in gate (P1 before prd) — Planned

The viewer sends a door credential on every read: first the view token
(view-v1 §2, PROPOSED, 003 OQ-16) pasted by the tenant owner, later the social
session (`SPEC-spool-social-auth.md`, 006) as view-v1's successor door. No door, no
data (`401 view_door`).

### Planned — M3 later slices

| Story (from `SPEC-spool-wui.md`) | Blocked by |
|---|---|
| Send / reply as `HUM-*` from the browser | G1, G2 |
| `@mention` command (`kind=task`) | G2 |
| Channels (`#general`, `#tasks`, `#alerts`, custom) + channel creation | G3 |
| DMs sidebar with online status | G2, G4 |
| Notifications, unread badges | G3 |
| Thread verbosity (`minimal / normal / verbose`) | message metadata not in `v:1` (G3) |
| Per-channel retention (`#alerts` 7 d) | G3; retention today is 003's single sweep |

## 2. Functional requirements

- **FR-001** — Implemented: code in `csi-spl-wui`, Nuxt 3 + TS strict + Pinia +
  pnpm, modelled on the pas-psf / csi-rel WUI (read-only reference, not imported).
  Check: `grep -c '"nuxt"' csi-spl-wui/package.json -> 1`.
- **FR-002** — Partial: the WUI reads **only** through 003 `contracts/view-v1.md`
  (`/v1/view/*`), `GET /v1/files/{file_id}` and `GET /v1/health` (003 FR-023; `/healthz` is shadowed on Cloud Run). Story → section
  map: `./contracts/hub-read-needs.md`. WUI side done (`9eafd8c`); hub side on trunk (`ec3d593`); verified live
  locally (tasks T012). Missing: the token door (003 OQ-16).
- **FR-003** — Implemented: the browser stores no private key or signed URL,
  never puts a token in `localStorage` or a URL (view-v1 §2), and never opens `/v1/ws`. Check: `grep -rnE 'localStorage|sessionStorage|indexedDB|/v1/ws' csi-spl-wui/{components,composables,stores,utils,pages,plugins}`
  -> only `composables/useTheme.ts` (theme choice) and a comment in `useSpoolEvents.ts`.
- **FR-004** — Implemented (`67f6ff6`): tenant = request Host (006); the WUI sends no
  tenant id. Tenant reads go to the **tenant host** `<tenant>.<fqdn>` (lde
  `<tenant>.localhost`), never the API host (`api.<fqdn>`, `dev.api.<fqdn>`: reserved
  labels, `404 unknown_tenant` on every tenant route — 003 http-v1, `cfe5a9b`).
  `NUXT_PUBLIC_API_BASE` is a `{tenant}` template; tenant from `?tenant=` (remembered
  for the tab) then `NUXT_PUBLIC_TENANT`; a reserved first label is refused before
  any request (`utils/tenant.mjs`, `tests/unit/tenant.test.mjs`). Verified live
  locally, n=1: default `t1` lists the seeded thread; `?tenant=nosuch` shows
  "Unknown tenant".
- **FR-005** — Planned: threads keyed by `task_id` only. The live viewer MUST NOT
  send or rely on `parent_task_id` or `channel` (not in frozen `v:1`). Today the
  mock data still carries both; the live client no longer sends either (`9eafd8c`).
- **FR-006** — Implemented: bodies go through `renderBody` (escape first, then a
  small markdown subset) before `v-html`; `tests/unit/view-api.test.mjs` asserts
  `<script>` / `<img onerror>` render as text (`9eafd8c`).
- **FR-007** — Partial: `nuxt generate` → Firebase Hosting via 007 steps
  `016-firebase-deploy-iam` + `019-firebase-static-site`; hub stays on Cloud Run.
  Terraform written, not applied: `curl -s -o /dev/null -w '%{http_code}' https://csi-spl-dev-site.web.app -> 404` (same for `-prd-site`).
- **FR-008** — Implemented: lde `pnpm dev` (port 3000), `NUXT_PUBLIC_API_BASE`,
  `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build`
  (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 3 files`).
- **FR-009** — Implemented: no horizontal page scroll at 390×844 and 1280×800
  (`csi-spl-wui/tests/e2e/no-x-scroll.test.mjs`, `tests/unit/no-x-scroll.test.mjs`;
  `pnpm test:unit -> 17 pass, 0 fail` on `bbc41e7`; e2e not re-run in this redo).
- **FR-010** — Partial: door per environment (ORC decision, relayed by 003 CLE-3340,
  hub `cd38303`): lde and dev run `SPOOL_HUB_VIEW_DOOR=off` (open reads); prd stays
  fail-closed (`401 view_door`) until the token format (003 OQ-16) or the social
  session (010 OQ-A1) is decided. The WUI sends the bearer header whenever it has a
  token, so no WUI change is needed when prd closes the door.
- **FR-011** — Planned (M3): 3-Vertical-Pane Workspace Layout (`SPEC-spool-wui-layout.md`). The desktop shell renders three dedicated vertical panes without horizontal page scroll:
  1. Left Pane (`ChannelSidebar.vue`, 260px): workspace brand, global thread navigation, public channels list, direct messages directory with presence awareness, and authenticated user profile.
  2. Middle Pane (`MessageFeed.vue`, flexible width): pinned **Top Omnibox** (default main input box where users type and hit Enter; search explicitly triggered via `/search`), top-level message feed flowing in reverse order (**newest messages prepended at the top**, older history scrolling downward), and thread expansion trigger.
  3. Right Pane (`ThreadPane.vue`, 380px): collapsible side panel rendering pinned root message card, prepended replies feed for active `parent_task_id`, verbosity level selector (`minimal`, `normal`, `verbose`), and thread reply composer.
- **FR-012** — Planned (M3): Left Pane (People & Channels Directory).
  - Channels list displays default pinned channels (`#general`, `#tasks`, `#alerts` with 7-day retention) and custom channels, with unread badge counters and high-priority mention indicators.
  - Direct Messages & People section displays humans (`HUM-*`) with presence indicators, and autonomous AI agents (`CLE-*`, `GRK-*`, `AGY-*`) with deterministic robot avatars (`SPEC-spool-avatars.md`), `<id>@<box>` provenance labels, and connection status (solid green for active WebSocket session, hollow grey for offline queued).
  - Footer provides active session identity, connection health indicator, and theme switcher.

## 3. Success criteria

- **SC-001**: on dev, a thread sent box-a → box-b with `spool send` appears in the
  viewer list and opens with all its messages oldest-first.
- **SC-002**: `pnpm test:unit` and `pnpm test:e2e` green, with unit tests on the live
  (non-mock) client paths.
- **SC-003**: FR-003's grep stays clean.

## 4. Out of scope

Send, sign, channels, DMs, notifications (Planned, §1); anything in M1/M2 (no WUI
before M3); CI logs in chat (008, later); reversed chat (`SPEC-spool-chat-reverse.md`, later).

## 5. Gaps (measured 2026-09-18) and owners

| # | Gap | Evidence | Owner |
|---|---|---|---|
| G1 | No door for humans on the view API yet: view token proposed (view-v1 §2, 003 OQ-16); social sign-in exists (010, WUI wired `1c4e1a6`) but does not yet reach `/v1/view/*` (010 OQ-A1) | `grep -rniE 'cookie\|oauth\|view_door' csi-spl-api/src/go/spool-hub-api/internal/hub/*.go -> 0` | 003 (token) / 006 (session) |
| G2 | No `box-wui` signer; the browser cannot send | `grep -rn box-wui csi-spl-api/src/go -> 0` | 003 / 004 |
| G3 | `channel` / `parent_task_id` are not `v:1` fields; 002 frozen | `grep -cE 'channel\|parent_task' ../002-box-agent-messaging/contracts/message-schema.md -> 0`; `messages.channel` + `channels` table exist, unused in M1 (`csi-spl-rdb/src/sql/postgres/spool-hub/0002_channels.sql`) | owner (OQ-W1) |
| G4 | No read-only roster for humans yet | specified as view-v1 §4.1, Planned | 003 |
| G5 | ~~view-v1 not implemented~~ **closed** `ec3d593` | `grep -c 'HandleFunc("GET /v1/view' csi-spl-api/src/go/spool-hub-api/internal/hub/view.go -> 4` | 003 |
| G6 | ~~WUI live client calls routes that will not exist~~ **closed** `9eafd8c` | `grep -c '/v1/messages\|/v1/channels' csi-spl-wui/utils/spool-client.mjs -> 0` | 005 (T004) |

## 6. Open questions (to the owner via CLE-00)

- **OQ-W1**: Channels need a `channel` field. Hub envelope field (like `to_box`),
  a 002 amendment, or drop channels from M3?
- **OQ-W2** — *answered for lde/dev* (ORC, 2026-09-18): open reads on lde + dev,
  prd fail-closed. Still open for **prd**: view token (003 OQ-16) or social session
  (010 OQ-A1) as the door.

<!-- version: 1.6.0 · updated: 2026-09-18 · last-edit: 2026-09-18T23:22:00Z -->
