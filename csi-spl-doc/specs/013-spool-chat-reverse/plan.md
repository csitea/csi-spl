# Implementation Plan: 013 Spool chat reverse

**Spec**: `./spec.md` · **Code home**: `csi-spl-wui` (paths below are under `csi-spl-wui/src/`)

## Approach

Evolve the 005 live-chat MVP (`src/utils/live-ws.mjs`, `src/composables/useLive.ts`,
`src/stores/live.ts`, `MessageComposer.vue`, `MessageCard.vue`), do not rewrite it.

| Piece | Where |
|---|---|
| Feed helpers (newest-first, window, search match) | `src/utils/feed.mjs` (pure, unit-tested) |
| Avatars (robot / identicon SVG, deterministic) | `src/utils/avatar.mjs` (pure) + `src/components/SpoolAvatar.vue` |
| Omnibox | `MessageComposer.vue` gains `omnibox` mode: `/search` emits `search`, Esc clears |
| Per-pane live feeds | `src/stores/live.ts` → `useLiveFeed(key)` (`main`, `pane`), same socket |
| Prepend + windowed reveal + bottom sentinel | `src/components/LiveFeed.vue` (`TransitionGroup`, `IntersectionObserver`) |
| Right pane | `src/components/LiveTopicPane.vue` (was `LiveThreadPane.vue`, `57f8a670`) live mode (pinned root, newest-first; reply Omnibox removed `afcbcede`; `ls csi-spl-wui/src/components/LiveTopicPane.vue`) |
| 3-pane geometry | `src/assets/css/main.css` per layout spec §1.1 |

## Decisions (logged to the orchestrator outbox)

1. Own dir `013-spool-chat-reverse` (owner narrative is separate; 012 is taken).
2. Client-side windowing until 003 serves newest-first windows (spec D1).
3. Avatars are generated inline SVG data URIs — no image files, no CDN.
4. In v:1 a thread is a `task_id`; the right pane opens a `task_id` (from the thread list or a message whose `task_id` differs from the feed's).

## Verification

Unit (feed, avatar), typecheck, e2e no-x-scroll incl. `/lobby` and `/` with the pane open;
a live two-tab run against a trunk hub (lde), as in 005 T024.

<!-- version: 0.1.2 · updated: 2026-09-25 · last-edit: 2026-09-25T18:32:11Z -->
