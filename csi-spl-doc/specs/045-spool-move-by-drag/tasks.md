# Tasks: 045 Move by Drag (SPL-1024)

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 spec, contract, this list (the commit adding this file)
- [ ] T002 rdb 0069 `moved_at` / `moved_by` / `moved_from_channel` / `moved_from_task` + `messages_moved`
- [ ] T003 rdb 0069 applied dev + prd before any hub code reading it is rolled
- [ ] T004 store `Moves` (`MoveTopic`, `MoveMessage`, `MovedTopicChannel`), memory + Postgres; the view
      reads carry the moved fields; tests on both drivers
- [ ] T005 hub `POST /v1/messages/{id}/move`, `GET /v1/view/messages/{id}/move`, frames, the 3.7 reply
      rule; one test per §3.4 row and per refusal, with a control
- [ ] T006 WUI: view override (contract §5), `moveTopic` / `moveMessage` client calls, frames
- [ ] T007 WUI: drag a middle card onto a rail channel; drag a right-pane reply onto a middle card
- [ ] T008 WUI: card menu Move to channel… / Move to topic… with pickers; Undo toast; "moved from" note;
      old channel URL redirect; strings in 19 locales
- [ ] T009 e2e: both drags, the menu path, undo, the refusals (control)
- [ ] T010 roll + deploy dev and prd (after the prd freeze of 2026-09-27 is lifted); live proof in the
      prd `e2e` tenant and the dev test tenant with DB counts; screenshots in both owner topics

<!-- version: 0.1.0 · updated: 2026-09-27 · last-edit: 2026-09-27T21:30:00Z -->
