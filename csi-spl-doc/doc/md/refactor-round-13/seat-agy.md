# Round 13 - agy seat proposal (a-584)

Measured on `dc17f840e` (`origin/master`, 2026-10-15 19:54Z).

A proposal for round 13: WUI cleaner code and better testability.
The editor (this seat) merges the expert panel seats into `../refactor-round-13-plan.md`.
The expert panel seats (claude, grok, mistral, qwen) write their seat files beside this file,
verify the empirical measurements on current trunk, give verdicts per row, and sign v1.0.

## 1. The 10 actions

| # | slug | sites | n (measured on `dc17f840e`) | target | kind |
|---|---|---|---|---|---|
| 01 | `refactor(r13-01-wui-decompose-message-card)` | `wui:src/components/MessageCard.vue` | 1416 script lines | < 500 lines | complex_coding |
| 02 | `refactor(r13-02-wui-decompose-channel-sidebar)` | `wui:src/components/ChannelSidebar.vue` | 1007 script lines | < 500 lines | complex_coding |
| 03 | `refactor(r13-03-wui-decompose-message-composer)` | `wui:src/components/MessageComposer.vue` | 1135 script lines | < 500 lines | complex_coding |
| 04 | `refactor(r13-04-wui-small-composable-mobile-stack)` | `wui:src/composables/useMobileStack.ts` | 531 lines | <= 200 lines | simple_coding |
| 05 | `refactor(r13-05-wui-small-composable-msg-shortcuts)` | `wui:src/composables/useMsgShortcuts.ts` | 464 lines | <= 200 lines | simple_coding |
| 06 | `refactor(r13-06-wui-small-composable-pane-widths)` | `wui:src/composables/usePaneWidths.ts` | 314 lines | <= 150 lines | simple_coding |
| 07 | `refactor(r13-07-wui-small-composable-scroll-anchor)` | `wui:src/composables/useScrollAnchor.ts` | 293 lines | <= 150 lines | simple_coding |
| 08 | `test(r13-08-wui-test-composable-submit-key)` | `wui:src/composables/useSubmitKey.ts` | 0 direct tests | 1 unit test file | tests |
| 09 | `test(r13-09-wui-test-util-poll-fence)` | `wui:src/utils/poll-fence.mjs` | 0 tests | 1 unit test file | tests |
| 10 | `test(r13-10-wui-test-store-edit-mode)` | `wui:src/stores/editMode.ts` | 0 tests | 1 unit test file | tests |

## 2. Parallel Lanes

- Lane 1: Rows 01, 03, 05, 07, 09
- Lane 2: Rows 02, 04, 06, 08, 10
- Starts with: Row 01 and Row 02 in parallel (Batch 1)

## 3. Signature

`signed: a-584 on v0.1 proposed`
