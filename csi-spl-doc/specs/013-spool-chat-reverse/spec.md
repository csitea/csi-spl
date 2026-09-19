# Feature Specification: Spool chat reverse — Top Omnibox, prepend feed, 3-pane, avatars

**Feature ID**: `013-spool-chat-reverse` · **Milestone**: M3 · **Status**: Implemented
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
oldest-first. Everything here lives in `csi-spl-wui`.
**Pages** (owner 2026-09-19, row X3): `/lobby`, `/t/<id>`, the live thread
pane, and also `/channel/<name>`, `/dm/<peer>` and the channel ThreadPane
(tasks T009–T012). The one hub-side ask
(newest-window paging, §4) is additive and owned by 003. US7 (CLE-3412) adds
two additive `wui-live-ws` subscriptions (DM, thread list) hub-side.

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

### US7 — Newest on top everywhere, pushed live (P1, owner 2026-09-19, CLE-3412)
> "also change the flow of the messages, they must not be appended, but
> prepended - aka newest always on the top, use websocket to push new msgs to
> the ui on msg send" — owner, 2026-09-19.

Every message view — `/lobby`, `/channel/<name>`, `/dm/<peer>`, the thread
pane (both), `/t/<id>` and the thread list `/` (search results open in the
thread pane, so they inherit it) — shows the newest row on top and **prepends**
new ones. When anyone sends (this user, another human, a box agent), the hub
pushes the stored message over the one `/v1/wui/ws` socket to every open view
of that channel / DM / thread / thread list; no view polls. The sender's own
row appears at once (optimistic, keyed by the `msg_id` the browser chose) and
is replaced — never duplicated — by the pushed echo. A reader who has scrolled
down keeps their place: the rows above grow, the viewport does not move, and a
"N new" pill at the top of the feed jumps back to the newest. After a socket
drop the client reconnects with backoff, re-subscribes, and reads what it
missed through view-v1, de-duplicated by `msg_id` (thread list: by `task_id`).

**Acceptance**: two browsers on one tenant; A sends in `#lobby`, a channel and
a DM → B shows each at its top within 1 s without a reload; a box
`spool send` into a channel B has open appears at B's top live.

### US6 — Slack-style code blocks (P1, owner 2026-09-19)
> "enable the same feature as in slack to create code blocks by typing \"```\""

In every composer (the Top Omnibox, the thread-pane reply Omnibox, `/channel`
and `/dm`), typing ```` ``` ```` opens a code block in place: the input turns
monospace and a polite live hint says so; Enter adds a line inside the block,
typing ```` ``` ```` again or Esc closes it, Ctrl/Cmd+Enter or the Send button
sends (a block left open is closed on send). No `@`-autocomplete inside a
block. Pasted multi-line code keeps its whitespace. Single backticks are
inline `code`.

The wire is unchanged: the body is plain text with Markdown fences, so boxes
and agents read ```` ``` ```` fences, and agent messages that already carry
fences render the same way. Feed, thread pane and DMs render a fenced block
as a monospace block with whitespace preserved, horizontal scroll **inside
the block only**, an optional language label (```` ```js ````), and a copy
button (`code.copy` / `code.copied`, 19 locales).

Parser rules (`utils/code-blocks.mjs`): a run of 3+ backticks opens anywhere
on a line and the next run of at least as many closes it; one newline after
the opener and before the closer is dropped; an unclosed fence at a line
start runs to the end (truncated agent output), mid-line it stays literal;
1–2 backticks are inline code on one line, and a ```` ``` ```` inside inline
code is content; CRLF/CR read as LF.

Security: the body is parsed into plain strings and rendered with Vue text
interpolation (`MessageBody.vue`); `MessageCard.vue` no longer uses `v-html`,
and no Markdown-to-HTML library is used. SEC-06 CSP (no `unsafe-inline`)
stays clean.

## 2. Functional requirements

- **FR-001** (Implemented, `ec3b91e`; tasks.md): Omnibox component (reuse `MessageComposer.vue`), send on Enter, `/search` filter, Esc clears.
- **FR-002** (Implemented, `ec3b91e`; tasks.md): newest-first render with windowed reveal (default 50) and a bottom sentinel that loads the next older window.
- **FR-003** (Implemented, `ec3b91e`; tasks.md): entrance transition on prepend; disabled under `prefers-reduced-motion`.
- **FR-004** (Implemented, `ec3b91e`; tasks.md): right pane for a `task_id`: pinned root, reply Omnibox, newest-first replies, live.
- **FR-005** (Implemented, `ec3b91e`; tasks.md): 3-pane geometry per `SPEC-spool-wui-layout.md` §1.1 on desktop (left 260px, middle flex, right 380px); on narrow screens the right pane overlays and nothing scrolls sideways (no-x-scroll invariant).
- **FR-006** (Implemented — cards, roster, `@mention` list): deterministic avatars — robot SVG for agents (prefix tint), identicon for `HUM-*`; used on message cards, the roster, and mention suggestions.
- **FR-007** (Implemented, `ec3b91e`; tasks.md): a11y order and semantics as US5.
- **FR-008** (Implemented, `ec3b91e`; tasks.md): no `v:1` change; the live WS client and view reads are reused unchanged (005 T021–T023).
- **FR-009** (Implemented, `76f66b5`; tasks.md T014): the two vertical seams of the 3-pane shell are draggable, keyboard-accessible separators; widths persist in `localStorage` `spool.pane-widths`; the main feed never collapses; no divider when a pane is hidden or overlaying. See `SPEC-spool-wui-layout.md` §1.2.
- **FR-011** (Implemented, `d7c2368`; tasks.md T018): newest on top on every message view as US7, including the thread list `/` (rows ordered by `last_ts`, newest first, a live row moves to the top).
- **FR-012** (Implemented, `fd5ae9a`; tasks.md T019): scroll anchoring — when rows are prepended while the feed is scrolled more than 80 px from its top, the scroll offset follows the row in view (its layout position, so a row dropped from the window's bottom or a move animation cannot shift it) and a "New: N" pill appears (it takes no layout space); the pill (or scrolling back to the top) clears it. At the top, new rows just enter.
- **FR-013** (Implemented, `d7c2368`; tasks.md T020): optimistic own send — the row is shown at once with `pending`, keyed by the client `msg_id` sent in the `send` frame (`wui-live-ws` §4 idempotent `msg_id`); the pushed `message` echo or the `ack` replaces it; a failed send removes it and shows the error. No duplicates in any view.
- **FR-014** (Implemented, `35bf0e0` hub 0.1.10 + `d7c2368`; tasks.md T021–T022): live push for every view over `/v1/wui/ws` — task and channel subscriptions (existing), plus a **DM** subscription (`subscribe {peer}`) and a **thread-list** subscription (`subscribe {all:true}`), hub-side in `wui-live-ws` v0.5 §3.1; tenant-scoped, behind the same door; a member socket only ever receives DMs it is party to.
- **FR-015** (Implemented, `d7c2368`; tasks.md T020, T023): reconnect with capped backoff (existing), then catch-up through view-v1 for every open view, merged by `msg_id` (feeds) or `task_id` (thread list) without dropping loaded older pages or pending rows.
- **FR-010** (Implemented, `4c204d0`; tasks.md T016–T017): Slack-style ``` code blocks as US6 — composer state, fenced + inline rendering without `v-html`, copy button, language label, no wire change.

## 3. Success criteria

- **SC-001**: under lde against a live hub, two sessions: A's send prepends at A's top instantly and at B's top live.
- **SC-002**: `/search` filters without sending; plain text + Enter sends.
- **SC-003**: avatars render for `HUM-*`, `CLE-*`, `GRK-*`, `AGY-*`; same id → same avatar.
- **SC-004**: unit, e2e (no-x-scroll incl. the 3-pane pages) and typecheck green.
- **SC-006** (met on dev n=2, tasks.md T023): on dev, two headless browsers: A's send in `#lobby`, a channel and a DM each shows at B's top within 1 s without a reload; a box `spool send` shows live too; screenshots + timings in `/var/tmp/CLE-3412-proof/`.
- **SC-005**: on dev, typing ```` ``` ```` + code + ```` ``` ```` + Enter shows one code block with the exact text; copy puts exactly that text on the clipboard; an injected `<script>` / `onerror` payload inside and outside the block never executes, 0 CSP violations.

## 4. Dependencies and gaps

| # | Gap | Owner |
|---|---|---|
| D1 | ~~no newest-first window on view-v1 §4.4~~ **closed**: `order=desc&before=` (`1dca945`), used by the WUI (tasks T008) | 003 (CLE-3340) |
| D2 | Custom avatars (`file_id` profile map) | later (avatars §3) |

<!-- version: 0.7.0 · updated: 2026-09-19 · last-edit: 2026-09-19T17:25:00Z -->
