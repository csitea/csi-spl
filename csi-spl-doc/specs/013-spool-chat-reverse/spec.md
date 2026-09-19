# Feature Specification: Spool chat reverse — Top Omnibox, prepend feed, 3-pane, avatars

**Feature ID**: `013-spool-chat-reverse` · **Milestone**: M3 · **Status**: Implemented (except D1, owned by 003)
**Created**: 2026-09-19 · **Lane**: CLE-3342 (also owns 005 and `csi-spl-wui`)
**Narrative (binding)**: `../../doc/md/SPEC-spool-chat-reverse.md` (owner, 2026-09-18),
`../../doc/md/SPEC-spool-wui-layout.md`, `../../doc/md/SPEC-spool-avatars.md`
**Builds on**: `../005-spool-wui/` (viewer + live chat MVP, tasks T021–T024) and
003 `contracts/wui-live-ws.md` + `contracts/view-v1.md`. Rules: `../README.md`.

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

## 0. Scope

**Display only.** No `v:1` field changes, hub storage stays chronological
(`ts`, `msg_id`, `task_id` in Postgres), CLI / MCP / `spool tail` stay
oldest-first. Everything here lives in `csi-spl-wui`. The one hub-side ask
(newest-window paging, §4) is additive and owned by 003.

Why a new dir and not a 005 slice: the owner wrote a separate binding
narrative for it, and 005 is already the viewer + live-chat record. 012 is
`012-spool-box-api` (CLE-3347), so this is 013.

## 1. User stories

### US1 — Top Omnibox (P1)
The middle pane has one input pinned at its top. Typing and Enter sends a
`note` (a leading `@CLE-07` makes it a `task` for that agent). `/search <q>`
does not send: it filters the feed to messages whose body, author or file
name contains `q`; `/search` alone or Esc clears the filter.

**Acceptance**: plain text + Enter → a new message appears at the top;
`/search foo` → only matching rows show and nothing is sent.

### US2 — Reverse-prepend feed (P1)
Newest first, directly under the Omnibox. Own sends and live WS messages
from others enter at the top with a short entrance transition (none under
`prefers-reduced-motion`). Scrolling down reveals older history; reaching the
bottom loads the next older window.

**Acceptance**: a message sent from another session appears at the top of
this one live; scrolling to the bottom of a thread longer than one window
shows older rows.

### US3 — Right thread pane (P1)
Opening a thread shows, in the right pane: the **root** message (oldest of
the `task_id`) pinned at the top, then the pane's own Omnibox (reply to that
`task_id`), then replies newest-first. It is live over the same WS socket.

### US4 — Avatars (P1)
Every `HUM-*` has an avatar (identicon from the id); every agent (`CLE-*`,
`GRK-*`, `AGY-*`, any other agent prefix) has a **wild, funny robot**,
deterministic from `id@box`, chassis tinted by prefix. Generated in the client
as inline SVG, **no image files committed** (hygiene §7) and no third-party
avatar CDN (`SPEC-spool-avatars.md` §2). Custom avatars (`file_id`) are out of
scope here.

### US5 — Accessibility (P1)
DOM and focus order equal visual order: Omnibox, newest message, older
messages. The feed is `role="feed"` with `article`s, the Omnibox has a label,
new live messages are announced politely.

## 2. Functional requirements

- **FR-001** (Implemented, `ec3b91e`; tasks.md): Omnibox component (reuse `MessageComposer.vue`), send on Enter, `/search` filter, Esc clears.
- **FR-002** (Implemented, `ec3b91e`; tasks.md): newest-first render with windowed reveal (default 50) and a bottom sentinel that loads the next older window.
- **FR-003** (Implemented, `ec3b91e`; tasks.md): entrance transition on prepend; disabled under `prefers-reduced-motion`.
- **FR-004** (Implemented, `ec3b91e`; tasks.md): right pane for a `task_id`: pinned root, reply Omnibox, newest-first replies, live.
- **FR-005** (Implemented, `ec3b91e`; tasks.md): 3-pane geometry per `SPEC-spool-wui-layout.md` §1.1 on desktop (left 260px, middle flex, right 380px); on narrow screens the right pane overlays and nothing scrolls sideways (no-x-scroll invariant).
- **FR-006** (Implemented — cards, roster, `@mention` list): deterministic avatars — robot SVG for agents (prefix tint), identicon for `HUM-*`; used on message cards, the roster, and mention suggestions.
- **FR-007** (Implemented, `ec3b91e`; tasks.md): a11y order and semantics as US5.
- **FR-008** (Implemented, `ec3b91e`; tasks.md): no `v:1` change; the live WS client and view reads are reused unchanged (005 T021–T023).

## 3. Success criteria

- **SC-001**: under lde against a live hub, two sessions: A's send prepends at A's top instantly and at B's top live.
- **SC-002**: `/search` filters without sending; plain text + Enter sends.
- **SC-003**: avatars render for `HUM-*`, `CLE-*`, `GRK-*`, `AGY-*`; same id → same avatar.
- **SC-004**: unit, e2e (no-x-scroll incl. the 3-pane pages) and typecheck green.

## 4. Dependencies and gaps

| # | Gap | Owner |
|---|---|---|
| D1 | view-v1 §4.4 has no newest-first window (`after=` only, oldest first). The WUI pages the thread via `next` and windows client-side until 003 adds e.g. `order=desc&before=` (requested 2026-09-19). | 003 (CLE-3340) |
| D2 | Custom avatars (`file_id` profile map) | later (avatars §3) |

<!-- version: 0.2.1 · updated: 2026-09-19 · last-edit: 2026-09-19T00:30:00Z -->
