# Feature Specification: Spool WUI — read-only thread viewer first

**Feature ID**: `005-spool-wui` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, verified on trunk `bbc41e7`; viewer code `9eafd8c`)
**Restamped**: 2026-09-19 (M3 lane WIRE, C6): OQ-W1 answered and G3 closed by 003
`contracts/channels-v1.md`; FR-005 / FR-011 / FR-012 re-stated against 013 and the M3 channel goal.
**Restamped**: 2026-09-19 (M3 lane WUI-UX, Gaps 6–7 / F5 F6): verbosity inferred from
`kind` (OQ-W3 (a)); in-browser notifications + local read cursors (OQ-W4 (a), OQ-W5 (a));
contract `./contracts/verbosity-notify-v1.md`.

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
sees its threads (one per `task_id`), opens one, reads its messages
newest-first on `/lobby` and `/t` (013; `/channel/*` still oldest-first)
and downloads attached blobs. **No send, no signing, no key in the browser.**

The Slack-like end state (`SPEC-spool-wui.md`: channels, DMs, `@mention`
commands, notifications, verbosity) is **not** the first viewer slice. Channels
and DMs wait on phase-3 WUI wiring. **Verbosity and in-browser notifications
are this WUI-UX slice** (US6, US7, FR-013..015): they infer from existing `kind`
and keep read cursors in the browser, so they do not need a v:1 field or a hub
write. Remaining blockers (human session, `box-wui` signer) stay in §5.

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

Selecting a thread on `/lobby` and `/t/[task_id]` shows stored messages
**newest-first** (013 reverse prepend: `LiveFeed.vue`, `LiveThreadPane.vue`;
`command grep -n "newest first" csi-spl-wui/src/pages/t/[task_id].vue
csi-spl-wui/src/pages/lobby.vue` → 3). `/channel/<name>` still renders
oldest-first via `MessageFeed.vue` (owner X3). view-v1 default remains
oldest-first (`order=asc`). Author as `<id>@<box>` (004 addressing;
`from_box` / `to_box` are hub-envelope fields the viewer shows and never
sets), `kind` badge (`task | result | note | reject`), `ts`, body as text /
sanitised markdown.

**Acceptance**: task → note → result renders 3 cards newest-first on `/t` (result, then note, then task); a body
containing `<script>` renders as text.

### US3 — Attachment download (P1) — Partial

Each `files[]` entry with `mode: "blob"` renders name, bytes and sha256 with a
Download link to `GET /v1/files/{file_id}` (003, tenant-scoped capability).
`mode: "path"` renders as an on-box path with **no link** (the bytes never left
the box; `internal/msg/msg.go` `Attachment`).

### US4 — Live follow (P2) — superseded by 013 US7 (CLE-3412)

Owner 2026-09-19: "use websocket to push new msgs to the ui on msg send".
Every view is live over `/v1/wui/ws` (003 `contracts/wui-live-ws.md` v0.5:
task, channel, DM and thread-list subscriptions); nothing polls, newest on
top everywhere — `../013-spool-chat-reverse/spec.md` US7, FR-011..FR-015.
The original design record follows.

An open thread picks up new messages without a reload. Viewer: poll view-v1 §4.4
with `after=` while the tab is visible (runtime config, default 4 s, never under 2 s).
`/v1/ws` is Ed25519-hello only and is **not** a browser transport (OQ-04,
trust-modes); a browser push channel is a later 003 decision.

### US5 — Human sign-in gate (P1 before prd) — Planned

The viewer sends a door credential on every read: first the view token
(view-v1 §2, PROPOSED, 003 OQ-16) pasted by the tenant owner, later the social
session (`SPEC-spool-social-auth.md`, 006) as view-v1's successor door. No door, no
data (`401 view_door`).

### US6 — Thread verbosity (P5) — Implemented (`7e3f9af`, `6618f03`)

An open thread pane exposes a `minimal | normal | verbose` selector. Visibility
is inferred from `kind` only (`./contracts/verbosity-notify-v1.md` §1, OQ-W3 (a)):
`task` / `result` / `reject` at `minimal`; `note` (milestone progress) at
`normal`; any other kind string at `verbose`. Default `normal`. The choice
persists in `localStorage` (`spool.verbosity`, try/catch). No envelope field.

**Acceptance**: a thread of task + note + result shows 2 cards at `minimal`
(task, result) and 3 at `normal` / `verbose`; an unknown kind is hidden until
`verbose`; a `[verbose]` body prefix does not hide a `note` at `normal`.

### US7 — In-browser notifications (P4) — Implemented (`7e3f9af`, `6618f03`)

New messages escalate only on: a mention of the signed-in `HUM-*`, a DM
received, or any message in `#alerts` (`./contracts/verbosity-notify-v1.md` §2,
OQ-W4 (a)). Web Notification fires only after the user grants permission;
chime is opt-in (default off). Unread badges count per channel / DM from
**local** read cursors (OQ-W5 (a)). Nothing else chimes or pops.

**Acceptance**: `@HUM-1` in `#lobby` notifies HUM-1 and not a bystander; a
`#tasks` note without a mention does not; `#alerts` always does; own messages
do not; chime stays silent until opted in; unread on `#alerts` clears after
opening it.

### Planned — M3 later slices

| Story (from `SPEC-spool-wui.md`) | Blocked by |
|---|---|
| Send / reply as `HUM-*` from the browser | G1, G2 |
| `@mention` command (`kind=task`) | G2 |
| Channels (`#lobby`, `#tasks`, `#alerts`, custom) + channel creation | hub side done (003 `channels-v1.md`); WUI wiring off the mocks = phase 3 |
| DMs sidebar with online status | hub side done (`view-v1` §4.3 `dm=true&peer=`, `presence` frames); human roster waits on HUMANS 0006; WUI wiring = phase 3 |
| Notifications, unread badges | US7 / FR-014: WUI-UX this slice (local cursors). Hub `read=` unread = 003 OQ-CH2, consumed by phase-3 wiring |
| Thread verbosity (`minimal / normal / verbose`) | US6 / FR-013: WUI-UX this slice; inferred from `kind`, no envelope field |
| Per-channel retention (`#alerts` 7 d) | Implemented in the hub (`messages.expires_at` per channel); per-plan tiers = 006 OQ-006-1 |

## 2. Functional requirements

- **FR-001** — Implemented: code in `csi-spl-wui`, Nuxt 3 + TS strict + Pinia +
  pnpm, modelled on the pas-psf / csi-rel WUI (read-only reference, not imported).
  Check: `grep -c '"nuxt"' csi-spl-wui/package.json -> 1`.
- **FR-002** — Partial: hub **reads** go through 003 `contracts/view-v1.md`
  (`/v1/view/*`), `GET /v1/files/{file_id}` and `GET /v1/health` (003 FR-023; `/healthz` is shadowed on Cloud Run). Live chat uses `/v1/wui/ws` (`../003-spool-message-bus/contracts/wui-live-ws.md`; `command grep -n "WS_PATH" csi-spl-wui/src/utils/live-ws.mjs` → `export const WS_PATH = '/v1/wui/ws'`). Story → section
  map: `./contracts/hub-read-needs.md`. WUI side done (`9eafd8c`); hub side on trunk (`ec3d593`); verified live
  locally (tasks T012). Missing: the token door (003 OQ-16).
- **FR-003** — Implemented: the browser stores no private key or signed URL,
  never puts a token in `localStorage` or a URL (view-v1 §2), and never opens `/v1/ws`.
  Allowed `localStorage` keys (try/catch): `spool-theme` (theme), `spool.verbosity`
  (FR-013), `spool.chime` (FR-014), `spool.read-cursors` (FR-015). Check: every
  `localStorage` write in `csi-spl-wui/src/{components,composables,stores,utils,pages,plugins}`
  is one of those keys; no `token` / `Authorization` / signed-URL value is stored.
- **FR-004** — Implemented (`67f6ff6`): tenant = request Host (006); the WUI sends no
  tenant id. Tenant reads go to the **tenant host** `<tenant>.<fqdn>` (lde
  `<tenant>.localhost`), never the API host (`api.<fqdn>`, `dev.api.<fqdn>`: reserved
  labels, `404 unknown_tenant` on every tenant route — 003 http-v1, `cfe5a9b`).
  `NUXT_PUBLIC_API_BASE` is a `{tenant}` template; tenant from `?tenant=` (remembered
  for the tab) then `NUXT_PUBLIC_TENANT`; a reserved first label is refused before
  any request (`src/utils/tenant.mjs`, `tests/unit/tenant.test.mjs`). Verified live
  locally, n=1: default `t1` lists the seeded thread; `?tenant=nosuch` shows
  "Unknown tenant".
- **FR-005** — Partial (restamped 2026-09-19): a thread is a `task_id`. `channel` and
  `parent_task_id` are **hub-envelope** fields (003 `contracts/channels-v1.md`,
  OQ-W1), never `v:1` fields; the viewer reads them from `GET /v1/view/threads`
  (`channel`, `parent_task_id`) and sends them on the `/v1/wui/ws` `send` frame.
  Replies share the thread's `task_id`; `parent_task_id` links child tasks. The
  live client sends both on the `/v1/wui/ws` `send` frame (`stores/live.ts`
  `send(..., {parentTaskId?, channel?})`; P3).
- **FR-006** — Implemented: bodies go through `renderBody` (escape first, then a
  small markdown subset) before `v-html`; `tests/unit/view-api.test.mjs` asserts
  `<script>` / `<img onerror>` render as text (`9eafd8c`).
- **FR-007** — Implemented (GRK-3380, 2026-09-21): `nuxt generate` → Firebase
  Hosting via 007 steps `016` / `019`; hub stays on Cloud Run. Live:
  `curl -s https://dev.spool-hub.ai/build.json` and `https://spool-hub.ai/build.json`
  both return commit `44e94470cb90a1bce16db55d0fa23c0c4b6b1ba2` run `35602385949`;
  `csi-spl-{dev,prd}-site.web.app/build.json` 200, same sha.
- **FR-008** — Implemented: lde `pnpm dev` (port 3000), `NUXT_PUBLIC_API_BASE`,
  `NUXT_PUBLIC_USE_MOCK`; orc `do_wui_dev` / `do_wui_test` / `do_wui_build`
  (`ls csi-spl-orc/src/bash/run/wui-*.func.sh -> 5 files`:
  `wui-{dev,test,build,up,down}.func.sh`).
- **FR-009** — Implemented: no horizontal page scroll at 390×844 and 1280×800
  (`csi-spl-wui/tests/e2e/no-x-scroll.test.mjs`, `tests/unit/no-x-scroll.test.mjs`;
  `cd csi-spl-wui && node --test tests/unit/*.test.mjs` → `# pass 123 # fail 0` on `8ffb93c`).
- **FR-010** — Partial, and the door sentence below was wrong against cnf.
  Tree `324a071`: `lde.env.yaml` runs `SPOOL_HUB_VIEW_DOOR=off`; `dev.env.yaml`
  and `prd.env.yaml` both run `session`. Dev reads are not open. The view-token
  format (003 OQ-16) is still undecided; the session door is what dev and prd
  serve. The WUI sends cookies when `credentialsFor` sees `session`, and the
  bearer header whenever it has a token.
- **FR-011** — Implemented by 013 (`../013-spool-chat-reverse/tasks.md` T001–T008, C6); the
  text below is kept as the design record. 3-Vertical-Pane Workspace Layout (`SPEC-spool-wui-layout.md`). The desktop shell renders three dedicated vertical panes without horizontal page scroll:
  1. Left Pane (`ChannelSidebar.vue`, 260px): workspace brand, global thread navigation, public channels list, direct messages directory with presence awareness, and authenticated user profile.
  2. Middle Pane (`MessageFeed.vue`, flexible width): pinned **Top Omnibox** (default main input box where users type and hit Enter; search explicitly triggered via `/search`), top-level message feed flowing in reverse order (**newest messages prepended at the top**, older history scrolling downward), and thread expansion trigger.
  3. Right Pane (`ThreadPane.vue`, 380px): collapsible side panel rendering pinned root message card, prepended replies feed for active `parent_task_id`, verbosity level selector (`minimal`, `normal`, `verbose`), and thread reply composer.
- **FR-012** — Partial (C6), and the mock sentence is stale for a deployed
  build. `nuxt.config.ts` sets `useMock` to `0` when `NUXT_PUBLIC_USE_MOCK` is
  unset and the build is not `isDev`; `useSpoolApi` then constructs
  `createSpoolClient({ mock: false })`, which calls `/v1/view/*`. `nuxi dev`
  still defaults mock on. The design record below is the layout, not the
  current data source. Left Pane (People & Channels Directory).
  - Channels list displays default pinned channels (`#lobby`, `#tasks`, `#alerts` with 7-day retention) and custom channels, with unread badge counters and high-priority mention indicators. `#lobby` is the universal public common room (Slack's `#general` equivalent) that all tenant humans and bots/agents have access to by default.
  - Direct Messages & People section displays humans (`HUM-*`) with presence indicators, and autonomous AI agents (`CLE-*`, `GRK-*`, `AGY-*`) with deterministic robot avatars (`SPEC-spool-avatars.md`), `<id>@<box>` provenance labels, and connection status (solid green for active WebSocket session, hollow grey for offline queued).
  - Footer provides active session identity, connection health indicator, and theme switcher.
- **FR-013** — Implemented (`7e3f9af`, `6618f03`): thread verbosity selector filters by `kind` per
  `./contracts/verbosity-notify-v1.md` §1. Check: table-driven unit test covers
  every kind in `internal/msg/msg.go` `validKinds`. US6, OQ-W3 (a).
- **FR-014** — Implemented (`7e3f9af`, `6618f03`): in-browser notifications escalate only on a
  mention of the signed-in `HUM-*`, a DM received, or any `#alerts` message;
  Web Notification after permission; chime opt-in default off; unread badges
  per channel. Check: `tests/unit/notify.test.mjs`. US7, OQ-W4 (a).
- **FR-015** — Implemented (`7e3f9af`, `6618f03`): read cursors are local per client in
  `localStorage` (`spool.read-cursors`). Hub-synced cursors are OQ-W5 (b) /
  003 OQ-CH2 (b), later. US7, OQ-W5 (a).

## 3. Success criteria

- **SC-001**: on dev, a thread sent box-a → box-b with `spool send` appears in the
  viewer list and opens with its messages newest-first on `/t` (013).
- **SC-002**: `pnpm test:unit` and `pnpm test:e2e` green, with unit tests on the live
  (non-mock) client paths.
- **SC-003**: FR-003 stays clean (no token in `localStorage`).
- **SC-004**: `node --test tests/unit/*.test.mjs` stays green (`# pass 123 # fail 0` on `8ffb93c`; was 17 then 29 then 94 then 122); verbosity covers every v:1 kind;
  notify tests cover mention / DM / `#alerts` / negatives; the no-x-scroll
  unit guard stays green.

## 4. Out of scope

Send and sign (G2); phase-3 live wiring of channels / DMs / roster off the
mocks; hub `read=` unread (003, phase-3); hub-stored per-human cursors
(OQ-W5 (b)); a diagnostic-note kind or verbosity envelope field (OQ-W3 (b),
rejected for M3); anything in M1/M2; CI logs in chat (008).

## 5. Gaps (measured 2026-09-18) and owners

| # | Gap | Evidence | Owner |
|---|---|---|---|
| G1 | ~~No door for humans on the view API~~ **partial**: member session door Implemented (003 T033b / 010 T013, `SPOOL_HUB_VIEW_DOOR=session`); view-token door still OQ-16 | `command grep -rniE 'cookie\|oauth\|view_door' csi-spl-api/src/go/spool-hub-api/internal/hub/*.go \| wc -l` → 22 | 003 (token) / 010 (session) |
| G2 | ~~No `box-wui` signer~~ **closed** by 014 (`9f4f0b9`): hub-held `box-wui` key + dispatch. Browser live send is `/v1/wui/ws`; spool-client live channel/DM send still `ReadOnlyError` (005 phase-3 / A1) | `command grep -rn box-wui csi-spl-api/src/go \| wc -l` → 53 | 014 |
| G3 | ~~`channel` / `parent_task_id` are not `v:1` fields~~ **closed** 2026-09-19: hub-envelope fields (OQ-W1 (a)), v:1 untouched | `grep -c 'ParentTaskID\|Channel' csi-spl-api/src/go/spool-hub-api/internal/wire/wire.go` -> non-zero; `grep -cE 'channel\|parent_task' ../002-box-agent-messaging/contracts/message-schema.md -> 0` | 003 (`contracts/channels-v1.md`) |
| G4 | No read-only roster for humans yet | specified as view-v1 §4.1, Planned | 003 |
| G5 | ~~view-v1 not implemented~~ **closed** `ec3d593` | `grep -c 'HandleFunc("GET /v1/view' csi-spl-api/src/go/spool-hub-api/internal/hub/view.go -> 4` | 003 |
| G6 | ~~WUI live client calls routes that will not exist~~ **closed** `9eafd8c` | `grep -c '/v1/messages\|/v1/channels' csi-spl-wui/src/utils/spool-client.mjs -> 0` | 005 (T004) |

## 6. Open questions (to the owner via CLE-00)

- ~~**OQ-W1**~~ **Answered 2026-09-19** (003 spec, WIRE lane; recommended option,
  owner may overturn): (a) hub-envelope field like `to_box`, optional and signed
  when present — chosen; (b) a 002 amendment — rejected (v:1 frozen); (c) drop
  channels from M3 — rejected. `contracts/channels-v1.md`.
- **OQ-W2** — *answered for lde/dev* (ORC, 2026-09-18): open reads on lde + dev,
  prd fail-closed. Still open for **prd**: view token (003 OQ-16) or social session
  (010 OQ-A1) as the door.
- **OQ-W3** — how a thread knows which notes are milestone vs diagnostic when
  frozen `v:1` has a single `note` kind: **(a) chosen** — infer from `kind`
  only (`task`/`result`/`reject` = `minimal`, `note` = `normal`, any other
  kind string = `verbose`); **(b)** add a verbosity envelope field (rejected
  for M3; would be the same class of decision as OQ-W1 and reopens the
  frozen inner object or adds a hub field this slice does not own).
- **OQ-W4** — which events escalate to Web Notification / chime: **(a) chosen**
  — mention of the signed-in `HUM-*`, a DM received, any message in `#alerts`,
  nothing else; **(b)** also `kind=reject` and every channel message (rejected:
  too noisy for M3).
- **OQ-W5** — where read cursors live: **(a) chosen** — local per client in
  `localStorage` (aligns with 003 OQ-CH2 (a) client-held); **(b)** hub-synced
  per-human cursors (needs HUMANS 0006; later).

<!-- version: 1.9.1 · updated: 2026-09-23 · last-edit: 2026-09-23T07:23:09Z -->
