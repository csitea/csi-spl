# Round 13 - agy seat proposal (a-584@<box>)

Measured on `e95587ea2` (`origin/master`, 2026-10-16).

A proposal for round 13: WUI cleaner code and better testability.
The editor (this seat) merges the expert panel seats into `../refactor-round-13-plan.md`.
The expert panel seats (claude, mistral) write their seat files beside this file,
verify the empirical measurements on current trunk, give verdicts per row, and sign v1.0.

## 1. The 10 actions (v1.0 signed)

| # | slug | sites | n (measured on `e95587ea2`) | target | kind |
|---|---|---|---|---|---|
| 01 | `refactor(r13-01-wui-decompose-message-card)` | `wui:src/components/MessageCard.vue:466-1881` | 1416 script lines | < 500 lines | complex_coding |
| 02 | `test(r13-02-wui-test-sfc-script-ratchet)` | `wui:tests/unit/sfc-script-size.test.mjs` | 7 SFCs > 500 lines | ratchet test + ceilings | tests |
| 03 | `refactor(r13-03-wui-decompose-message-composer)` | `wui:src/components/MessageComposer.vue:328-1462` | 1135 script lines | < 500 lines | complex_coding |
| 04 | `refactor(r13-04-wui-decompose-channel-sidebar)` | `wui:src/components/ChannelSidebar.vue:711-1717` | 1007 script lines | < 500 lines | complex_coding |
| 05 | `refactor(r13-05-wui-small-composable-msg-shortcuts)` | `wui:src/composables/useMsgShortcuts.ts:1-464` | 464 lines | <= 250 lines | simple_coding |
| 06 | `refactor(r13-06-wui-decompose-issues-page)` | `wui:src/pages/issues.vue:1161-3244` | 2084 script lines | <= 1200 lines | complex_coding |
| 07 | `refactor(r13-07-wui-small-composable-scroll-anchor)` | `wui:src/composables/useScrollAnchor.ts:179-225` | 3 `after*` functions | pure key-list helper | simple_coding |
| 08 | `refactor(r13-08-wui-gate-unused-exports)` | `wui:tests/unit/unused-exports.test.mjs` | 87 unused exports | allowlist gate + top 5 unexported | simple_coding |
| 09 | `test(r13-09-wui-test-util-poll-fence)` | `wui:src/utils/poll-fence.mjs:1-15` | 0 direct test files | edge cases tested | tests |
| 10 | `test(r13-10-wui-test-composable-submit-key)` | `wui:src/composables/useSubmitKey.ts:37-39` | 0 direct tests | pure hint helper tested | tests |

## 2. Parallel Lanes

- Lane 1: Rows 01, 03, 05, 07, 09
- Lane 2: Rows 02, 04, 06, 08, 10
- Starts with: Row 01 and Row 02 in parallel (Batch 1)

## 3. Signature

`signed: a-584@<box> on v1.0`
