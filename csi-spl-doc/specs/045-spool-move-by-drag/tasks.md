# Tasks: 045 Move by Drag (SPL-1024)

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 spec, contract, this list. `3bf2d769`, `32d8e712`
- [x] T002 rdb 0069 `moved_at` / `moved_by` / `moved_from_channel` / `moved_from_task` / `moved_from_parent`
      + partial index `messages_moved`. `5b0dedc3`
- [x] T003 rdb 0069 applied dev + prd (`do_spl_db_bootstrap`, `applied 0069_messages_moved.sql`), 2026-09-28
      ~02:20Z, before `5b0dedc3` was pushed (~03:03Z)
- [x] T004 store `Moves` (`TaskCard`, `MoveTopic`, `MoveMessage`, `MovedTaskChannel`), memory + Postgres; the
      view reads carry the move mark. `5b0dedc3`; `internal/store/message_move_test.go` on both drivers
- [x] T005 hub `POST /v1/messages/{id}/move`, `GET /v1/view/messages/{id}/move`, frames `topic_moved` /
      `message_moved`, the §3.7 stale-tag rule for box replies (`followMoved`; a browser reply is already
      stored in its topic's channel since `8d0231d9`). `5b0dedc3`; `internal/hub/message_move_test.go`: one
      case per §3.4 row and per refusal; 6 guards each turn a test red when removed; round-trip budgets
      unchanged. Live: hub `22703074` (1.3.0) on dev + prd contains `5b0dedc3` (`git merge-base --is-ancestor`)
- [x] T006 WUI view override (contract §5), `moveTopic` / `moveMessage` / `moveInfo`, frames. `1e38ddef`
- [x] T007 WUI drag: a middle card onto a rail channel; a right-pane reply onto a middle card; only allowed
      targets light up. `1e38ddef`
- [x] T008 WUI menu Move to channel… / Move to topic… (lazy pickers, phone overlay), 8 s Undo toast, the
      "moved from" note (own line: `d1951060`), old channel URL redirect, 19 locales (18 machine drafts).
      `1e38ddef`, `d1951060`
- [x] T009 e2e `tests/e2e/move-by-drag.test.mjs` in `test:e2e` (31 checks, mock generate); initial JS 159.4 KB
      gzip (ceiling 160). Live proof `tests/e2e/move-live.proof.mjs` (`62e1808b`, `b208df08`, `d1951060`)
- [x] T010 live: WUI `d1951060` on dev, apex and e2e (`build.json`). Proof n=1 each: dev test tenant 26/26 on WUI
      `62e1808b` (before the note fix) incl. the refusal control (a `developer` moving another author's card -> 403 `not_allowed`); prd e2e 25/25 on `d1951060` (that account is the tenant's `biz_owner`, so the not-the-author control is skipped there, §3.4).
      DB rows before/after read with `do_spl_db_query`. Screenshots posted in prd t1 topics `72557f61`
      (3 files) and `e615e3fd` (2 files)

- [x] T011 SPL-1034 hub: rdb 0073 `tenant_memberships.channel_order` (applied dev + prd ~06:23Z before the push),
      `PUT /v1/me/channel-order`, `GET /v1/view/me` carries it in its one round trip (the membership read fills
      the request memo; control: without the memo the budget test reads 5 round trips). `d64ba4c8`; live on
      dev + prd in hub `fc264bab` (1.5.2, `merge-base --is-ancestor`)
- [x] T012 SPL-1034 WUI: the Channels list loads / saves the order, Move up / Move down in the row menu, a
      channel row's link no longer starts a native link drag (the reorder never completed with a real mouse),
      e2e `channel-order.test.mjs` 21/21. `f3a78d2c`, live on dev, apex and e2e (`build.json`). Live proof
      `tests/e2e/channel-order-live.proof.mjs` on dev t1, n=1: 14/14 incl. the CONTROL (another member's
      stored order unchanged). prd e2e has one member, so the control cannot run there
- [ ] T013 SPL-1134 WUI (§3.9, FR-MV-016..019): the 12 px drag handle on every movable card, pointer drag
      from the handle only (`utils/move-drag.mjs`, unit `move-drag.test.mjs`), ONE lit row via `useMove().over`
      (`data-move-drop` / `-scope` / `-ok` rows), "not allowed" on a refusing row, drop elsewhere / Escape =
      cancel, phone hold = the picker; the HTML5 drag removed (no `draggable` row, no `dataTransfer`); the Flow
      list's channel link `draggable="false"`. e2e `move-by-drag.test.mjs` 46/46 at 1440 + 390 and
      `channel-order.test.mjs` 21/21 on the generated bundle; initial JS 155.9 KB gzip (ceiling 160)

Found on the way (fixed): the moved-from note was 0 px wide in the right pane (the author row does not wrap);
`d1951060` gives it its own line and the e2e now asserts its width (control: 30/31 on the old bundle).

<!-- version: 0.4.0 · updated: 2026-09-28 · last-edit: 2026-09-28T15:55:00Z -->
