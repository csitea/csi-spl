# Tasks: 041 Archive and Delete a Topic (SPL-983)

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 icons `archive` / `unarchive` / `delete` + every string in 19 locales. `7325032b`;
      `tests/unit/msg-menu.test.mjs` (keys and translations per locale)
- [x] T002 spec, contract, this list; permission proposal posted to the owner topic
      `8f58f802` (msg `8bfc7a6f`), 2026-09-26 20:05Z
- [x] T003 rdb 0065 `messages.archived_at` / `archived_by` + partial index `messages_archived`. `0834fe98`
- [x] T004 rdb 0065 applied dev + prd (`do_spl_db_bootstrap`, `applied 0065_messages_archived.sql`),
      2026-09-26 ~20:26Z dev / ~20:30Z prd, before any hub code reading it was rolled. The first prd run's
      runtime-grants step failed after the apply; the rerun re-applied the grants (`migrated … grants re-applied`)
- [x] T005 store `TopicArchive` (`CardState`, `SetArchived`, `TopicOf`, `DeleteTopic`, `ArchivedCards`,
      `TopicReplies`); archived filter in `ViewTopics`, the lobby `ViewTopic` / batch read, search.
      `0834fe98`; `internal/store/topic_archive_test.go` TestTopicArchiveAndDelete, memory + Postgres
- [x] T006 hub routes + frames (contract §2–§6). `f14fc3f9`; `internal/hub/topic_archive_test.go`: one case
      per role (author, biz_owner, admin allowed; member, no-session caller / agent refused; red with the
      gate removed), lobby frames, issue topic refused, preflight. Roll 0.9.6 `26d8f0ed`
- [x] T007 WUI: a middle card's menu (LiveFeed `openButton` = the middle pane) ends with Archive then
      Delete for its author / the tenant owner / an admin (`utils/topic-archive.mjs` mayChangeTopic);
      Delete opens `TopicDeleteDialog` (lazy), which reads the reply count from the hub first; the
      `topic_archived` / `topic_deleted` frames drop rows in every store and close a pane on a deleted
      task (`layouts/default.vue`). The commit adding this line; `tests/unit/topic-archive.test.mjs`;
      the CI e2e set replayed on a mock generate 12/12, initial JS 155.9 KB gzip (budget 160)
- [x] T008 WUI: `/archive` page (list, open, Unarchive, Delete, live updates). The commit adding this
      line; the rail entry is CLE-35017's (SPL-979), sent this page's sha
- [ ] T009 hub roll dev + prd (`/version`), WUI deploy dev + prd (`build.json`)
- [x] T010 owner confirmed §3.3 ("yes", topic 8f58f802, relayed by CLE-001 2026-09-26 20:14Z)
- [ ] T011 live proof: prd `e2e` + dev test tenant, archive -> hidden -> unarchive; delete with a
      DB count before / after

<!-- version: 0.1.0 · updated: 2026-09-26 -->
