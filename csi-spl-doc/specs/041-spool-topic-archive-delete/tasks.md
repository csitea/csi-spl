# Tasks: 041 Archive and Delete a Topic (SPL-983)

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 icons `archive` / `unarchive` / `delete` + every string in 19 locales. `7325032b`;
      `tests/unit/msg-menu.test.mjs` (keys and translations per locale)
- [x] T002 spec, contract, this list; permission proposal posted to the owner topic
      `8f58f802` (msg `8bfc7a6f`), 2026-09-26 20:05Z
- [ ] T003 rdb 0065 `messages.archived_at` / `archived_by` + partial index
- [ ] T004 rdb 0065 applied dev + prd (`do_spl_db_bootstrap`), before any hub reads it
- [ ] T005 store: `ArchiveCard`, `TopicSet`, `DeleteTopic`, `ArchivedCards`; archived filter in
      `ViewTopics`, the lobby `ViewTopic`, search — memory + Postgres, tests on both
- [ ] T006 hub routes + frames (contract §2–§6), `internal/hub/topic_archive_test.go`
- [ ] T007 WUI: menu entries (Archive / Unarchive / Delete on cards), `TopicDeleteDialog`,
      live frames drop the card
- [ ] T008 WUI: `/archive` page; rail entry by CLE-35017 (SPL-979) after the page sha
- [ ] T009 hub roll dev + prd (`/version`), WUI deploy dev + prd (`build.json`)
- [ ] T010 owner confirms §3.3 before Delete is live on prd
- [ ] T011 live proof: prd `e2e` + dev test tenant, archive -> hidden -> unarchive; delete with a
      DB count before / after

<!-- version: 0.1.0 · updated: 2026-09-26 -->
