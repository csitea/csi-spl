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
- [x] T009 hub 0.9.6: `/version` on dev.api and api both read commit `26d8f0ed` (run 36270605506 green).
      WUI: `build.json` on dev and the apex both read `52426fd3` (run 36271652337; `a9fd49c9` first, run
      36271304720). Re-probe of / and /login on both apexes for 3 min after the WUI deploy: 44/44 = 200.
      `52426fd3` fixed a live defect: a fresh /archive load read before the session door was armed (401)
- [x] T010 owner confirmed §3.3 ("yes", topic 8f58f802, relayed by CLE-001 2026-09-26 20:14Z)
- [x] T011 live proof `tests/e2e/topic-archive-live.proof.mjs`, n=1 per env, WUI `52426fd3` / hub `26d8f0ed`:
      dev t1 (the m3-e2e test member, rows the proof itself created) 12/12 PASS; prd `e2e` tenant
      (https://e2e.spool-hub.ai, guard: claim AND page host = e2e) 12/12 PASS. Card + 3 replies + a
      thread on reply 1: menu ends Archive, Delete; archive -> gone from the feed, the list and search
      read, present in /archive with 4 replies; unarchive -> back; the dialog names 4 replies; delete ->
      `do_spl_db_query` count of the topic's rows (by id and structural) 5 -> 0 on dev and on prd.
      A first dev run's interrupted topic was removed with PHASE=clean (deleted 5)


## SPL-986: the same menu on the topic lists (spec §3.5)

- [x] T012 WUI: `composables/useTopicRowActions.ts` (find the row's card, ask the hub, archive, the
      delete dialog), `utils/topic-archive.mjs` rowCardCandidates / isRowTopic / rowTopicState /
      topicFrameRows / withoutTopics, `utils/sidebar-row-menu.mjs` topicArchive / topicDelete,
      `SidebarRowMenu` Archive / Delete; wired on the rail Topics and Flow topic rows
      (`ChannelSidebar.vue`), the Topics home (`pages/index.vue`) and BornTopics (the card menu);
      `viewer.dropTopics` + the frame hook in `layouts/default.vue`. No hub change, no new string.
      `tests/unit/topic-row-archive.test.mjs` 12/12; unit 136/136 files, typecheck, the CI e2e set
      on a mock generate 7/7, initial JS 156 KB gzip (budget 160)
- [ ] T013 WUI deploy: `build.json` on dev and the apex carry the commit; / and /login re-probed 3 min
- [ ] T014 live proof from the Topics section, dev t1 test member + prd `e2e`, DB counts before / after
- [ ] T015 report on SPL-986 and in topic 8f58f802

<!-- version: 0.3.0 · updated: 2026-09-27 -->
