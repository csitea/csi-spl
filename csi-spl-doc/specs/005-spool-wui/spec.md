# Feature Specification: Spool WUI — read-only thread viewer first

**Feature ID**: `005-spool-wui` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, verified on trunk `bbc41e7`)

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
  (`/v1/view/*`), `GET /v1/files/{file_id}` and `GET /healthz`. Story → section
  map: `./contracts/hub-read-needs.md`. Missing: view-v1 is not implemented (G5);
  the live client calls wrong routes (G6).
- **FR-003** — Implemented: the browser stores no private key or signed URL,
  never puts a token in `localStorage` or a URL (view-v1 §2), and never opens `/v1/ws`. Check: `grep -rnE 'localStorage|sessionStorage|indexedDB|/v1/ws' csi-spl-wui/{components,composables,stores,utils,pages,plugins}`
  -> only `composables/useTheme.ts` (theme choice) and a comment in `useSpoolEvents.ts`.
- **FR-004** — Partial: tenant = request Host (006); the WUI sends no tenant id.
  Missing: hub origin per tenant is one env var (`NUXT_PUBLIC_API_BASE`); Host-derived
  base is Planned with Hosting (T009).
- **FR-005** — Planned: threads keyed by `task_id` only. The live viewer MUST NOT
  send or rely on `parent_task_id` or `channel` (not in frozen `v:1`). Today the
  mock data and client use both (G6).
- **FR-006** — Partial: bodies render as text / sanitised markdown; no `v-html` of
  unsanitised input. Missing: an explicit test (T008).
- **FR-007** — Partial: `nuxt generate` → Firebase Hosting via 007 steps
  `016-firebase-deploy-iam` + `019-firebase-static-site`; hub stays on Cloud Run.
  Terraform written, not applied: `curl -s -o /dev/null -w '%{http_code}' https://csi-spl-dev-site.web.app -> 404` (same for `-prd-site`).
- **FR-008** — Implemented: lde `pnpm dev` (port 3000), `NUXT_PUBLIC_API_BASE`,
  `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build`
  (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 3 files`).
- **FR-009** — Implemented: no horizontal page scroll at 390×844 and 1280×800
  (`csi-spl-wui/tests/e2e/no-x-scroll.test.mjs`, `tests/unit/no-x-scroll.test.mjs`;
  `pnpm test:unit -> 17 pass, 0 fail` on `bbc41e7`; e2e not re-run in this redo).
- **FR-010** — Planned: every read carries the view-v1 door (US5); prd additionally
  waits on the owner answer to 003 OQ-16 (OQ-W2).

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
| G1 | No door for humans on the hub yet: view token proposed (view-v1 §2, 003 OQ-16), social session not built | `grep -rniE 'cookie\|oauth\|view_door' csi-spl-api/src/go/spool-hub-api/internal/hub/*.go -> 0` | 003 (token) / 006 (session) |
| G2 | No `box-wui` signer; the browser cannot send | `grep -rn box-wui csi-spl-api/src/go -> 0` | 003 / 004 |
| G3 | `channel` / `parent_task_id` are not `v:1` fields; 002 frozen | `grep -cE 'channel\|parent_task' ../002-box-agent-messaging/contracts/message-schema.md -> 0`; `messages.channel` + `channels` table exist, unused in M1 (`csi-spl-rdb/src/sql/postgres/spool-hub/0002_channels.sql`) | owner (OQ-W1) |
| G4 | No read-only roster for humans yet | specified as view-v1 §4.1, Planned | 003 |
| G5 | view-v1 not implemented | `grep -c '/v1/view' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go -> 0`; a non-matching read API (`/v1/threads`, `/v1/messages?task_id=`) sits on branch `GRK-3349-hub-wui-read-api` (`2ecf59f`) | 003 |
| G6 | WUI live client calls routes that will not exist | `grep -nE "v1/(channels\|messages)" csi-spl-wui/utils/spool-client.mjs` -> `/v1/channels`, `/v1/messages?channel=`, `POST /v1/messages` (OQ-02 removed) | 005 (T004) |

## 6. Open questions (to the owner via CLE-00)

- **OQ-W1**: Channels need a `channel` field. Hub envelope field (like `to_box`),
  a 002 amendment, or drop channels from M3?
- **OQ-W2**: Is the view token (003 OQ-16) acceptable as the only door for **prd**
  Hosting, or must the social session (006) exist first?

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
