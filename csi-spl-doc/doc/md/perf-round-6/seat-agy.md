# Round 6 - agy seat proposal (a-591)

Measured on `4251b33cf` (`origin/master`, 2026-10-15).

A proposal for round 6: UI speed-up round on mobile and desktop (12 concrete actions).
The editor (this seat) merges the expert panel seats into `../perf-round-6-plan.md`.
The expert panel seats (claude, grok, mistral; qwen is disabled in instance settings) write their seat files beside this file,
verify the empirical measurements on current trunk, give verdicts per row, and sign v1.0.

## 1. The 12 actions

| # | slug | sites | number now (measured on `4251b33cf`) | target | kind | batch / lane |
|---|---|---|---|---|---|---|
| 01 | `perf(p6-01-wui-lazy-mount-user-menu)` | `wui:src/components/UserMenu.vue:60` | `v-show="open"`; 606 DOM nodes on Home desktop / 625 on mobile | `v-if="open"` lazy mounting; ~15 fewer DOM nodes on initial paint | simple_coding | Batch 1 (Lane 1 start) |
| 02 | `perf(p6-02-wui-async-topic-panes)` | `wui:src/layouts/default.vue:94-97,203-205` | Synced imports; initial JS gzip 154.9 KB (0.1 KB headroom) | `defineAsyncComponent`; ~8 KB gzip entry JS cut; TTI improved ~20 ms | complex_coding | Batch 1 (Lane 2 start) |
| 03 | `perf(p6-03-wui-memoize-date-iso-parts)` | `wui:src/utils/date-iso.mjs:83-93` | Uncached `formatToParts`; >25 ms for 1,000 dates; 438 ms TBT on mobile channel | Minute-bucketed LRU cache; >90% hits; <5 ms for 1,000 dates | simple_coding | Batch 2 (Lane 1) |
| 04 | `perf(p6-04-wui-deadline-picker-no-sync-reflow)` | `wui:src/components/DeadlinePicker.vue:13,128,153-170` | `getBoundingClientRect` on mount/keystroke; 282 ms layout on mobile login | Pure CSS sizing (`calc(var(--ch-count) * 1ch)`); 0 ms JS reflow | simple_coding | Batch 2 (Lane 2) |
| 05 | `perf(p6-05-wui-lazy-load-code-viewer)` | `wui:src/components/CodeBlock.vue:56-58,64-67` | Static import in dialog; route chunks Docs 960.6 KB gzip / Channels 952.6 KB gzip | Dynamic import `defineAsyncComponent`; ~6 KB gzip route chunk cut | complex_coding | Batch 3 (Lane 1) |
| 06 | `perf(p6-06-wui-live-feed-transition-gate)` | `wui:src/components/LiveFeed.vue:37,112` | Unconditional `<TransitionGroup>` mount transitions; 438 ms TBT, 1064 ms LCP on mobile | `:css="isMounted"` gate; static initial render; >80 ms TBT reduction | simple_coding | Batch 3 (Lane 2) |
| 07 | `perf(p6-07-wui-login-wallpaper-filter-gate)` | `wui:src/layouts/login.vue:9-23,260-275` | 5 SVG signal paths with double drop-shadow filters rendered on front page; 243 ms layout | `v-if="!isFrontPage"`; drops SVG filter tree evaluation on front page; >40 ms layout cut | simple_coding | Batch 4 (Lane 1) |
| 08 | `perf(p6-08-wui-issues-windowed-rows)` | `wui:src/pages/issues.vue:375,520` | Full table row rendering; 620 DOM nodes, 325 ms TBT, 1028 ms LCP on mobile | Progressive windowing (first 25 rows, then rAF); DOM nodes <350; >150 ms LCP gain | complex_coding | Batch 4 (Lane 2) |
| 09 | `perf(p6-09-wui-markdown-fast-path-plain-text)` | `wui:src/components/MarkdownBlock.vue:78-101` | 100% of messages invoke dynamic markdown lexer; >8 ms for 100 plain messages | Regex fast-path for plain text; <1 ms for 100 plain messages; 3x throughput | simple_coding | Batch 5 (Lane 1) |
| 10 | `perf(p6-10-wui-debounce-channel-seed-topics)` | `wui:src/pages/channel/[name].vue:98-100` | Synchronous immediate `seedTopics` on reactive message; 118 ms channel switch on mobile | Coalesce topic seeding with `queueMicrotask` / 16 ms debounce; switch latency <70 ms | simple_coding | Batch 5 (Lane 2) |
| 11 | `perf(p6-11-wui-cache-starter-card-stats)` | `wui:src/stores/channel.ts:103,105,115` | Full re-sort & slice on every message mutation (`channelView`, `rootsByTask`) | Intermediate topic roots & projections cache; O(1) read on message append | complex_coding | Batch 6 (Lane 1) |
| 12 | `perf(p6-12-wui-lazy-render-docs-workspace-tree)` | `wui:src/pages/docs.vue:62-75,157` | Full expanded tree on mount; 807 DOM nodes, 1120 ms LCP, 399 ms TBT on mobile | Fold inactive directories by default; initial DOM nodes <450; >120 ms TBT reduction | complex_coding | Batch 6 (Lane 2) |

## 2. Parallel Lanes

- Lane 1: Rows 01, 03, 05, 07, 09, 11
- Lane 2: Rows 02, 04, 06, 08, 10, 12
- Starts with: Row 01 and Row 02 in parallel (Batch 1)

## 3. Signature

`signed: a-591 on v1.0 consensus (b3a47adaf)`
