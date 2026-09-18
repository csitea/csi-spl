# Implementation Plan: 013 Spool chat reverse

**Spec**: `./spec.md` · **Code home**: `csi-spl-wui`

## Approach

Evolve the 005 live-chat MVP (`utils/live-ws.mjs`, `composables/useLive.ts`,
`stores/live.ts`, `MessageComposer.vue`, `MessageCard.vue`), do not rewrite it.

| Piece | Where |
|---|---|
| Feed helpers (newest-first, window, search match) | `utils/feed.mjs` (pure, unit-tested) |
| Avatars (robot / identicon SVG, deterministic) | `utils/avatar.mjs` (pure) + `components/SpoolAvatar.vue` |
| Omnibox | `MessageComposer.vue` gains `omnibox` mode: `/search` emits `search`, Esc clears |
| Per-pane live feeds | `stores/live.ts` → `useLiveFeed(key)` (`main`, `pane`), same socket |
| Prepend + windowed reveal + bottom sentinel | `components/LiveFeed.vue` (`TransitionGroup`, `IntersectionObserver`) |
| Right pane | `components/ThreadPane.vue` live mode (pinned root, reply Omnibox, newest-first) |
| 3-pane geometry | `assets/css/main.css` per layout spec §1.1 |

## Decisions (logged to the orchestrator outbox)

1. Own dir `013-spool-chat-reverse` (owner narrative is separate; 012 is taken).
2. Client-side windowing until 003 serves newest-first windows (spec D1).
3. Avatars are generated inline SVG data URIs — no image files, no CDN.
4. In v:1 a thread is a `task_id`; the right pane opens a `task_id` (from the thread list or a message whose `task_id` differs from the feed's).

## Verification

Unit (feed, avatar), typecheck, e2e no-x-scroll incl. `/lobby` and `/` with the pane open;
a live two-tab run against a trunk hub (lde), as in 005 T024.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T00:05:00Z -->
