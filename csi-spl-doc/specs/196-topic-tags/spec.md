# Spec 196: Topic Tags

Status: **Draft v0.2** (2026-11-25). Lane `a-743` (`agy`, doc only).
v0.1 `9920e6d74`; v0.2 folds cross-vendor review findings W1-W4 and N1-N8
(`c-750`, claude FAIL on v0.1, msg `2e7461d8`; holder send-back `a3f640f1`):
see section 7.
Epic: **SPL-23**. Issue: **SPL-6524**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:ec5e6237-a8fc-422e-8b30-2b72f61df302` (`t1` `#spool-hub-ui`).
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the 3-pane shell and
Channels left panel), [003 spool message bus](../003-spool-message-bus/spec.md)
(viewer API and browser WS frames), [025 tenant RBAC](../025-spool-tenant-rbac/spec.md)
(multi-role workspace access), [043 mobile WUI](../043-spool-wui-mobile/spec.md)
(3-level stack, 44 px tap targets, 16 px inputs), [099 topic head](../099-topic-head/spec.md)
(fast topic listing), and [150 topic list priority](../150-topic-list-priority/spec.md)
(per-topic side metadata, `change_stamp`, fused `ViewTopicDoor`, live topic frames).

Line references were measured on `origin/master` `d5a2422f4`.
Number **196**: `origin/master` ends at `195-message-revoke`
(`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -n 5`);
none of the remote `refs/heads/review/*` branches naming specs or 196+
(`c-210-message-revoke-spec` ends at 195, `c002-channel-workspace-move-spec`
at 169, `c003-csitea-netvisor-monthly-personnel-cost-spec-r3` touches 125)
and no sibling worktree holds a `196-*` folder, so **196** is the next free number.

Paths below: `api/` = `csi-spl-api/src/go/spool-hub-api/`,
`rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`wui/` = `csi-spl-wui/src/`, `tests/` = `csi-spl-wui/tests/`.

---

## 0. The owner's words (HUM-10, t1 `ec5e6237`, 2026-11-25, verbatim)

- 16:48:53Z: "split the current channels left most section in the topics and card msgs lising into 2 tabs - channels and topic-tags , where it will work so that clicking on the topic-tasgs will present listing of topic tags - which will be lited - most used to least used top to bottom or bottom to top according to pre-pend or post-pend settings of a user"
- 16:49:10Z: "a user should be able to set tags on the topics level"
- 16:50:24Z: "thus one should be able to list topics having the same tag from the topic-tags listing , which are not in the same channel"

### 0.1 Owner decisions (form `dece6b4a`, answered 17:56:15Z, msg `bfaf397e-ddb7-4298-bd22-a76597a44f1f`)

| # | Question | Owner's answer (verbatim) | What it decides here |
|---|---|---|---|
| 1 | Who may set or remove a topic's tags | **B** - only the topic's author and the workspace admins | Section 2.5: hub enforces `mayChangeTopic` (`author`, `biz_owner` / `TenantOwner`, or `admin` in `a.Roles`); WUI hides editor controls from everyone else |
| 2 | Where a tag lives | **A** - in one workspace, its channels share one tag list | Section 2.1: `topic_tags` is tenant-scoped (`tenant_id`), unique per workspace; clicking a tag lists matching topics across all visible channels |
| 3 | How a new tag is made | **A** - typed freely on a topic; it appears in the list once used | Section 2.2, 3.3: no separate tag-admin CRUD required; typing a new tag on a topic upserts it and links it; only tags with visible `count > 0` appear in the list |

### 0.2 Design decisions by this spec

| D | Decision | Why |
|---|---|---|
| D1 | Store tags in two normalized tenant tables (`topic_tags`, `topic_tag_links`) plus `topic_tag_stamps` for exact reconnect deltas, NOT on `topic_heads` or `messages`. | `topic_heads` is written solely by message triggers (`0144_topic_heads.sql`); `topic_priorities` (`0214`) and `topic_pauses` (`0297`) set the precedent for side tables keyed by `(tenant_id, task_id)`. Under `FORCE RLS`, GIN on `text[]` cannot serve `@>` (`0296_calendar_tags.sql:16-18`), whereas B-tree join indexes on `(tenant_id, tag_id, task_id)` work cleanly. |
| D2 | Tag counts and tag listings are computed **through the caller's read door**. A tag used only in private channels the caller cannot see has visible count 0 and is omitted. | Matches `visibleChannels` (`api/internal/hub/view.go:502-505`) and `topicReader` (`view.go:1328-1330`): a non-member must never learn that a private channel or its topics exist. |
| D3 | Canonical Unicode-NFC lowercase slugs (`1..40` runes, spaces collapsed to `-`, leading `#` stripped) with atomic add (`POST`) and remove (`DELETE`) endpoints, max 10 tags per topic. | Eliminates duplicate casing/spacing drift under free-form entry (3A), avoids lost updates when two admins edit concurrently, and keeps `/tag/<slug>` URLs clean and predictable. |
| D4 | Split `#sidebar-panel-channels` internally into two tabs (`Channels` and `Topic tags`), keeping the left icon rail unchanged. Clicking a tag opens `/tag/<slug>` in the middle pane. | Matches the owner's exact words ("split the current channels left most section ... into 2 tabs - channels and topic-tags"), preserves desktop 3-pane widths and spec 043's 3-level mobile stack. |
| D5 | Order the Topic tags list with `displayOrder` (`wui/utils/view-prefs.mjs:94-97`): most-used at top for `newest-first`, most-used at bottom for `newest-last` — DOM order equals reading order. | Matches spec 013 §2 and `unreadFirst` (`wui/utils/unread-first.mjs:26-41`): never CSS `flex-direction: column-reverse`, so keyboard focus and screen readers follow visual order. |
| D6 | Channel topics only in v1 (not DM topics, not the shared lobby container task, not archived topics, not issue discussions). | The owner's ask scopes tags to Channels and cross-channel listing; DM tagging is raised as Q1 for the owner. |
| D7 | WUI-only in v1; CLI and MCP follow in Phase 2 (section 4). | Keeps v1 focused without widening the box WS wire or requiring mixed-fleet sidecar capability gating; the schema is ready for Phase 2 (`added_by text` accepts agent ids). |

---

## 1. What exists today (measured on `origin/master` `d5a2422f4`)

### 1.1 Re-check: no topic tags exist today

Running `git grep -iE 'topic_tags?|topicTags?|hashtag' origin/master -- csi-spl-wui/src csi-spl-rdb csi-spl-api csi-spl-doc/specs` returns only:

- Marketing caption hashtags (`api/internal/marketing/meta_publish.go`, `wui/utils/marketing-handover.mjs`, `csi-spl-doc/specs/090-marketing-automation/spec.md`).
- One hub test struct field named `topicTag` (`api/internal/hub/thread_channel_test.go`, which tests channel routing, not tags).

Nothing stores, serves, or renders tags on topics. Separate domain tag/label features exist for calendar events (`rdb/0296_calendar_tags.sql`, `calendar_tags` + `calendar_events.tag_ids`) and issues (`api/internal/hub/issues.go:1200-1232`, `issue_labels` + `issue_label` WS frame), which provide tested conventions for validation and broadcast.

### 1.2 The left section (`ChannelSidebar.vue` and its parents)

- **Shell parent**: `wui/layouts/default.vue:29-103` renders `.spool-shell` containing `<ChannelSidebar>` (`:49`), `<PaneDivider pane="sidebar">` (`:54-62`), `<main class="spool-main"><slot />...</main>` (`:64-83`), `<PaneDivider pane="topic">` (`:85-93`), and the single right topic pane (`<LiveTopicPane>` / `<TopicPane>` / `<OperatorPane>`, `:99-102`).
- **Sidebar structure**: `wui/components/ChannelSidebar.vue` (1645 lines) splits `<nav class="sidebar">` into:
  - `.sidebar-rail` (`:11-162`): the vertical icon strip (`dm`, `channels`, `issues`, `flow`, etc., defined in `wui/utils/rail-order.ts` and `wui/utils/sidebar-tabs.mjs:7-50`).
  - `.sidebar-body` (`:166-635`): the open rail tab's list panel (mounted lazily per tab via `tabsBuilt`, `:755-756,781`; unmounted on `railOnly` pages, `:166`).
- **The Channels panel**: `#sidebar-panel-channels` (`ChannelSidebar.vue:277-468`, `role="tabpanel"`):
  - Activated when `panelTab === 'channels'`; `tabForPath` (`wui/utils/sidebar-tabs.mjs:70-76`) maps `/`, `/channel`, `/channel/*`, `/t`, and `/t/*` to `'channels'` (and has no `/tag/` rule today).
  - Header `.sidebar-head` (`ChannelSidebar.vue:292-311`): `<MobileBack top />`, `<h2 class="sidebar-help">` (`sidebar.channels`), and the `+` create-channel button (`v-if="canCreate"`, `:300-310`).
  - List `.sidebar-scroll` (`:312-377`): renders `channelRows` (`:993-997`: `unreadOrder.order(pinRows(shownChannels, channelOrder))`), each row linking to `/channel/<channel_id>` (`:339`) with unread badges, drag reorder (`useSidebarRowDrag`, `:1000`), topic-move drop targets (`:319-323`), keyboard nav (`useSidebarRowKeys.ts:59-87`), and `<SidebarRowMenu>`.
  - There are **no** inner sub-tabs in `#sidebar-panel-channels` today. An existing precedent for an in-panel 2-button switcher sits in `#sidebar-panel-people` (`.people-tools` / `.people-filter`, `ChannelSidebar.vue:525-529`).

### 1.3 How a topic is stored and listed

- **Database (`csi-spl-rdb`)**:
  - Messages live in `messages` (`rdb/0001_hub_core.sql:57`), with `is_parent` (`0034`), `edited_at`/`edited_by` (`0026`), `archived_at`/`archived_by` (`0065`).
  - Fast topic list indexes live in `topic_heads` and `topic_head_parts` (`rdb/0144_topic_heads.sql`), maintained strictly by triggers on `messages`.
  - Per-topic metadata lives in side tables keyed by `(tenant_id, task_id)` with fail-closed RLS (`tenant_scope` + `operator_scope`) and `change_stamp` constraint triggers (`rdb/0103_tenant_change_stamps.sql`): `topic_priorities` (`rdb/0214_topic_priorities.sql:27-52`), `topic_pauses` (`rdb/0297_topic_pauses.sql`), and `topic_loops` (`rdb/0301_topic_loops.sql`).
  - Highest migration on `origin/master` `d5a2422f4` is `rdb/0325_vendor_logins_manage.sql`; `refs/rdb-claims/0326` is claimed on origin.
- **Hub store (`api/internal/store/`)**:
  - `TopicQuery` and `TopicRow` live in `store/view.go:35-84` (`TopicRow` carries `Priority` and `Pause`, read inline with no extra round trip).
  - `Postgres.ViewTopics` (`store/view_postgres.go:132-143`) serves from `topic_heads` when enabled (`viewTopicsHeads`, `store/view_topics_head.go:162-168`), else walks `messages` (`viewTopicsSQL`, `view_postgres.go:225-235`). Both end in `summary()` (`view_postgres.go:388-408`), which reads `topic_priorities` via a PK scalar subquery and `topic_pauses` via `LEFT JOIN`.
  - Visibility is enforced in SQL by `readerDoor` (`view_postgres.go:315-326`) / `headDoor` (`view_topics_head.go:338-355`): public channels (`PublicChannels`), channels the reader belongs to (`ReaderChannels`), or DMs the reader is an end of. Archived topics are excluded (`archivedTopicHideSQL` / `headArchived`, `view_topics_head.go:325-333`), as are issue discussions (`NoIssues`, `view_postgres.go:335-337`).
  - Single-topic reads fuse the read door, priority, and pause into one batch via `ViewTopicDoor` / `topicAccessRead` (`store/channels_postgres.go:717-786`), keeping `TestRoundTripsPerRequest` (`api/internal/hub/roundtrips_perf_test.go:30`) green.
  - Reconnect delta reads `ViewChanges` (`store/view_changes_postgres.go:28-50`: kinds `new`, `edit`, `kind`, `move`, `archive`, `react`, `priority`).
  - Every tenant table is enforced by `TestRLSCoversEveryTenantTable` (`store/rls_test.go:103-133`), `change_stamp_test.go:25`, and `api/internal/channelmove/catalogue.go:64` (`catalogue_test.go`).
- **Hub API (`api/internal/hub/`)**:
  - `GET /v1/view/topics` (`view.go:54`, `handleViewTopics` `:631-679`, `listTopics` `:739-800`) and `GET /v1/view/topics/{task_id}` (`:55`, `topicPage` `:1249-1284`) run behind `stampedView` (`view.go:134-136`, `stampGate` in `view_stamp.go:64-108`).
  - Topic metadata mutations follow `topic_priority.go` (`routeTopicPriority` `:37-40`, `handleTopicPriority` `:52-88`), using `fanoutTopic` (`topic_archive.go:379-400`) to broadcast to open browser sockets whose `wuiConn.wants` (`wui.go:522-564`) permits reading that channel/topic.
- **WUI store and views (`csi-spl-wui/src/`)**:
  - `wui/stores/channel.ts` holds channels (`channels`, `ordered`, `:84,114`), active channel feed messages (`messages`, `newestFirst`, `:89,127`), pagination cursor (`olderCursor`, `:122`), per-topic totals/priorities (`totals`, `priorityFor`, `:124,771`), and live socket subscriptions (`followSteps`, `:142-185`).
  - `wui/utils/spool-client.mjs` wraps REST reads and keeps an in-memory cache + listener pattern for topic metadata (`topicPriorities`, `:735-777`).
  - `wui/pages/channel/[name].vue` renders `<FeedHeader>` + `<MessageFeed>` (`:3-4`). `MessageFeed.vue` feeds `<LiveFeed>` (`:23-57`), which renders `<MessageCard>` rows (`MessageCard.vue:107-186` displays `KindBadge`, `topic-priority-badge`, `topic-pinned-new`, `msg-responsible`).
  - Open topics render in `wui/components/TopicPane.vue` (`:30-33`) and `wui/components/LiveTopicPane.vue` (`:30-33`), whose `.topic-head__row2` hosts `<LazyTopicPriorityChooser>` and `<LazyCardClipControl>`.
  - Browser WS frames arrive in `wui/utils/live-ws.mjs:513-587` (`FRAMES.topicPriority` -> `onTopic`, `:557-566`) and fan out through `wui/composables/useLive.ts` (`onTopic`, `:53,125-127,236`).

### 1.4 The newest-first / newest-last setting

- Stored on the account as `humans.message_order` (rdb `0070`), served as session claim `message_order` with values `'newest-first'` (prepend / top, default) and `'newest-last'` (postpend / bottom): `wui/utils/view-prefs.mjs:34,47,56-58`.
- Read in components via `useViewPrefs()` (`wui/composables/useViewPrefs.ts:15-20`), which exposes `messageOrder` and `newestLast = computed(() => messageOrder.value === 'newest-last')`.
- Feeds and lists order rows through:
  - `displayOrder(rows, order)` (`wui/utils/view-prefs.mjs:94-97`), which reverses a newest-first array when `order === 'newest-last'` so DOM order matches reading order;
  - `useUnreadOrder()` (`wui/composables/useUnreadOrder.ts:11-18`) -> `unreadFirst(rows, unreadOf, { atEnd: newestLast })` (`wui/utils/unread-first.mjs:26-41`), which places highest-unread items at the edge where new messages land.

### 1.5 The workspace admin and topic author role check

- **Hub (authoritative)**:
  - `mayChangeTopic` (`api/internal/hub/topic_archive.go:188-194`) returns `true` iff:
    1. `from != "" && from == author` (caller's `editorID` v:1 id equals the opening card's `FromID`, loaded via `openingCard` in `api/internal/hub/topic_priority.go:161-172`), **OR**
    2. `a.TenantOwner || a.Has(rbac.Admin)`, where `a` comes from `s.access(ctx, hum, tenant)` (`api/internal/hub/rbac.go:45-59`). In `api/internal/rbac/rbac.go:280`, `BizOwner` sets `TenantOwner: true`, and `a.Has(rbac.Admin)` (`rbac.go:360-367`) checks the member's full multi-role set `a.Roles` (rdb `0201`).
- **WUI (UI convenience only)**:
  - `mayChangeTopic` (`wui/utils/topic-archive.mjs:20,58-64`) checks `msg.from === viewerId` or `me.tenantOwner === true || TOPIC_ADMIN_ROLES.includes(String(me.role || ''))` (`['biz_owner', 'admin']`).
  - **Subtle gap**: `topic-archive.mjs:63` checks only primary `me.role`, omitting secondary roles in `me.roles` (`wui/utils/access.mjs:41`, populated by `GET /v1/view/me` at `api/internal/hub/rbac.go:207`). A member whose primary role is `developer` with secondary role `admin` passes the hub's `a.Has(rbac.Admin)` but would be hidden by `topic-archive.mjs:63`. Topic tags MUST check both `me.role` and `me.roles`.

### 1.6 The gap

| G | Missing |
|---|---|
| G1 | Persistence: workspace-scoped `topic_tags` table, `topic_tag_links` join table, `topic_tag_stamps` delta table, fail-closed RLS policies, `change_stamp` triggers, `DeleteTopic` / `MergeTopic` cleanup, and spec 169 `channelmove` catalogue + slug-remap handling. |
| G2 | Hub store & API: NFC-normalized tag validation, concurrency locking on cap & orphan prune, `GET /v1/view/topic-tags` (visibility-filtered counts), `GET /v1/view/topics?tag=<slug>` (cross-channel visible topics), `Tags` on `viewTopic` and `topicBody` with 0 extra round trips, `POST /v1/topics/{task_id}/tags` and `DELETE /v1/topics/{task_id}/tags/{slug}` gated by `mayChangeTopic`, dedicated CORS preflight, `topic_tags` WS frame, and `ViewChanges` delta branch. |
| G3 | WUI left section: 2-tab switcher (`Channels` \| `Topic tags`) inside `#sidebar-panel-channels`, `SidebarTopicTags.vue` ordered by use following `useViewPrefs().newestLast`, keyboard nav, live count updates, and its 19-locale translations (`do_spl_lang_review_gct`). |
| G4 | WUI cross-channel tag view: `/tag/[slug]` route (`pages/tag/[slug].vue`), cross-channel topic cards showing each topic's source channel pill, and mobile 3-level stack wiring in `sidebar-tabs.mjs` and `section-strip.mjs`. |
| G5 | WUI topic tag editor & chips: clickable tag chips on level-1 `MessageCard.vue`, lazy `TopicTagsBar.vue` in `TopicPane.vue` and `LiveTopicPane.vue` with free-text + autocomplete editor restricted to author and workspace admins (checking `me.roles` too), and its 19-locale translations (`do_spl_lang_review_gct`). |
| G6 | User help & keyboard-shortcuts docs: `wui/public/help-md/message-levels-and-topics.md`, `wui/public/help-md/user-settings.md`, `wui/public/help-md/keyboard-shortcuts.md`, and `csi-spl-doc/doc/help/keyboard-shortcuts.md`. |

---

## 2. Store and API

### 2.1 Forward-only migration (`csi-spl-rdb`)

Build lane T1 claims the next free migration number before creating the file:

```bash
cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next
```

(Head on `origin/master` `d5a2422f4` is `0325_vendor_logins_manage.sql`; `refs/rdb-claims/0326` is claimed.)

The migration `rdb/<NNNN>_topic_tags.sql` is forward-only, additive, and idempotent (`IF NOT EXISTS`, `DROP POLICY IF EXISTS`, `DROP TRIGGER IF EXISTS`, `SET LOCAL lock_timeout = '5s'`). Runtime DML grants for `spool_hub_rt` come from `spool-hub-roles/runtime-grants.sql` default privileges (same as `0214_topic_priorities.sql:24` and `0296_calendar_tags.sql:22-23`).

```sql
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS topic_tags (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    tag_id     uuid        NOT NULL,
    slug       text        NOT NULL CHECK (char_length(slug) BETWEEN 1 AND 40),
    name       text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 40),
    created_by text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, tag_id),
    UNIQUE (tenant_id, slug)
);

CREATE TABLE IF NOT EXISTS topic_tag_links (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id   uuid        NOT NULL,
    tag_id    uuid        NOT NULL,
    added_by  text        NOT NULL CHECK (char_length(added_by) BETWEEN 1 AND 64),
    added_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, task_id, tag_id),
    FOREIGN KEY (tenant_id, tag_id) REFERENCES topic_tags (tenant_id, tag_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS topic_tag_links_by_tag
    ON topic_tag_links (tenant_id, tag_id, task_id);

CREATE TABLE IF NOT EXISTS topic_tag_stamps (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id    uuid        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, task_id)
);
```

- **Why `topic_tag_stamps`**: `topic_tag_links` hard-deletes rows on tag removal; keeping one tiny `(tenant_id, task_id, updated_at)` row upserted on every add and remove lets `ViewChanges` (`store/view_changes_postgres.go:28-50`) catch both tag additions and tag removals in `?since=` deltas without extra query parameters (identical shape to `topic_priorities` at `view_changes_postgres.go:43-46`), and also serves as the per-topic lock row for concurrent writes (section 2.3).
- **UUID minting**: `tag_id` is minted by `api/internal/uid` (developer guide 2.2.4), never `gen_random_uuid()`, so Memory and Postgres stores behave identically.

### 2.2 Row-Level Security, `change_stamp`, `channelmove`, and topic lifecycle

- **Fail-closed RLS** on all three tables (`topic_tags`, `topic_tag_links`, `topic_tag_stamps`), matching `0214_topic_priorities.sql:39-48`:
  - `ALTER TABLE <t> ENABLE ROW LEVEL SECURITY;`
  - `ALTER TABLE <t> FORCE ROW LEVEL SECURITY;`
  - `CREATE POLICY tenant_scope ON <t> USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')) WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));`
  - `CREATE POLICY operator_scope ON <t> USING (current_setting('app.rls_scope', true) = 'operator') WITH CHECK (current_setting('app.rls_scope', true) = 'operator');`
  - `TestRLSCoversEveryTenantTable` (`api/internal/store/rls_test.go:103-133`) discovers every `tenant_id` table automatically via `pg_class`/`pg_attribute` and enforces `ENABLE + FORCE`; adding the three tables to `rlsTables` (`rls_test.go:68-99`) is optional for that check and also covers them under `TestRLSControl` (`:169-178`).
- **`change_stamp` triggers** on `topic_tags` and `topic_tag_links` (`AFTER INSERT OR UPDATE OR DELETE ... DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump()`), registered in `api/internal/store/change_stamp_test.go:25`, so `stampGate` (`hub/view_stamp.go:64-108`) invalidates conditional `304` ETags on every tag mutation.
- **Cross-workspace channel move / copy (`api/internal/channelmove/catalogue.go`)**:
  - `Moved` (`catalogue.go:15-16`) inserts `<SRC>` rows verbatim under `<DST>` and therefore **cannot** carry `topic_tag_links`: its FK `(tenant_id, tag_id) -> topic_tags` would fail when `<DST>` lacks that `tag_id`, or collide on `UNIQUE (tenant_id, slug)` when `<DST>` holds the same slug under a different `tag_id`.
  - Following the `calendar_tags` (`catalogue.go:196`, spec 097 11.9) and `issue_labels` (`:195`) precedent:
    - `topic_tags` is class **`NotChannel`**: workspace-scoped tag vocabulary; not copied wholesale.
    - `topic_tag_links` is class **`Rewritten`** (with `Refs: task_id = ANY(@tasks)`), carried by a dedicated slug-remap step during channel move/copy: for every `(task_id, slug, name, created_by, added_by, added_at)` of `@tasks` in `<SRC>`, upsert `(dst_tenant, slug)` into `<DST>.topic_tags` (reusing `<DST>`'s existing `tag_id` on slug match, minting a new `tag_id` via `internal/uid` otherwise), insert `(dst_tenant, task_id, dst_tag_id, added_by, added_at)` into `<DST>.topic_tag_links` (`ON CONFLICT DO NOTHING`), delete `<SRC>.topic_tag_links` for `task_id = ANY(@tasks)` (on move, not copy), and prune any now-orphaned `<SRC>.topic_tags`.
    - `topic_tag_stamps` is class **`Moved`** (`Set: task_id = ANY(@tasks)`, no FK to `topic_tags`, matching `topic_priorities` at `catalogue.go:92`).
- **Topic lifecycle**:
  - **Move topic between channels within the same workspace**: `task_id` does not change; links stay intact automatically.
  - **Delete topic** (`api/internal/store/topic_archive_postgres.go:160-182`, `DeleteTopic`): inside `DeleteTopic`'s transaction, delete `topic_tag_links` and `topic_tag_stamps` for `set.TaskIDs`, then prune orphan `topic_tags` rows with no remaining links (using the lock rule in 2.3).
  - **Merge topics** (`api/internal/store/topic_merge_postgres.go:29`, `MergeTopic`): inside `MergeTopic`'s transaction, after `topicTx` locks the source card, lock target B's `topic_tag_stamps` row `FOR UPDATE`. **Deterministic cap rule when `len(tags(B) ∪ tags(A)) > 10`**:
    1. Target topic **B keeps all of its existing tags** (never dropped).
    2. Remaining slots (`max(0, 10 - len(tags(B)))`) are filled from source topic **A's** tags not already on B, ordered by `(added_at ASC, slug ASC)` (earliest-added first, deterministic tie-break by slug). Any overflow tags from A are dropped.
    3. Delete A's rows from `topic_tag_links` and `topic_tag_stamps`, upsert B's `topic_tag_stamps`, and prune any orphaned `topic_tags`.
  - **Promote message** (`api/internal/store/topic_promote_postgres.go:25`, `PromoteMessage`): promoting a reply mints a new `task_id`; **the new topic starts untagged**, and the source topic keeps its tags.
  - **Move single message** (`MoveMessage` of a reply or opener between topics): tags belong to each topic's `task_id`; moving an individual message into another topic does not transfer tags.
  - **Archive / unarchive**: links remain stored while archived (so unarchiving restores the topic's tags), while archived topics are excluded from tag counts and `/v1/view/topics?tag=` (same rule as `archivedTopicHideSQL`).
  - **Orphan pruning**: on `DELETE /v1/topics/{task_id}/tags/{slug}`, if no `topic_tag_links` row remains for `(tenant_id, tag_id)` across the workspace, delete the unused `topic_tags` row under the lock in 2.3 so typos never accumulate.

### 2.3 Normalisation, limits, and concurrency locks

One shared pure function `store.NormalizeTopicTag(raw string) (slug string, err error)` used by every store write and query parameter:

| Rule | Specification |
|---|---|
| Unicode normalization (NFC) | Apply Unicode **NFC** (`golang.org/x/text/unicode/norm.NFC.String`; `String.prototype.normalize('NFC')` in WUI preview) before lowercasing, then lowercase (`strings.ToLower`), then apply NFC again so decomposed forms (e.g. `e` + U+0301) match composed `é`. |
| Leading/trailing whitespace & `#` | Trim (`strings.TrimSpace`), strip all leading `#` (`strings.TrimLeft(s, "#")`), re-trim so `#billing` and `billing` normalize to `billing`. |
| Case | Folded to lowercase (`strings.ToLower`, Unicode-aware; see Q2 if owner wants display-case preservation). Unit tests MUST explicitly cover decomposed `e\u0301` == `é`, Hebrew, Cyrillic, and Turkish `İ` / `ı` (`strings.ToLower("İ")` yields `i\u0307`, where U+0307 is `\p{Mn}`). |
| Internal spaces | Any run of Unicode whitespace (`unicode.IsSpace`) collapsed to a single `-`; consecutive `-` collapsed to one `-`; leading/trailing `-` trimmed. |
| Allowed characters | Unicode letters (`\p{L}`), non-spacing combining marks (`\p{Mn}`, only immediately following `\p{L}` or `\p{Mn}` — supports Turkish `i\u0307`, Hebrew niqqud, stacked diacritics across our 19 locales), Unicode digits (`\p{N}`), `-`, `_`, `.`; must contain at least one `\p{L}` or `\p{N}` (rejects bare `-`, `.`, `..`, control chars, slashes, commas, quotes, HTML brackets). |
| Length | `1..40` Unicode runes (`utf8.RuneCountInString`), at most 128 UTF-8 bytes (`ErrBadTopicTag` -> `400 bad_tag`). |
| Per-topic cap | At most **10** distinct tags per topic (`ErrTooManyTopicTags` -> `400 too_many_tags`; matches `0296_calendar_tags.sql:55`). Adding a tag already present on the topic is an idempotent `200 OK` no-op. |

**Concurrency serialization inside `inTenant` write transactions**:

1. **Per-topic 10-tag cap race** (two concurrent `POST`s on the same topic): before checking count and inserting into `topic_tag_links`, upsert `topic_tag_stamps` (`INSERT INTO topic_tag_stamps (tenant_id, task_id, updated_at) VALUES ($1, $2, $3) ON CONFLICT (tenant_id, task_id) DO UPDATE SET updated_at = EXCLUDED.updated_at`) — the `INSERT ... ON CONFLICT DO UPDATE` acquires an exclusive row lock (`FOR UPDATE`) on `(tenant_id, task_id)` in `topic_tag_stamps` for the duration of the transaction, serializing concurrent `POST` and `DELETE` on the same topic without blocking message inserts.
2. **Orphan prune vs concurrent `POST` race** (`DELETE` pruning `topic_tags` while another topic's `POST` links the same `slug`):
   - On `POST`: upsert `(tenant_id, slug)` in `topic_tags` and hold `FOR KEY SHARE` on the `topic_tags` row (`SELECT tag_id FROM topic_tags WHERE tenant_id = $1 AND slug = $2 FOR KEY SHARE`) before inserting into `topic_tag_links`.
   - On `DELETE` / `DeleteTopic` / `MergeTopic` orphan prune: lock the candidate `topic_tags` row with `SELECT tag_id FROM topic_tags WHERE tenant_id = $1 AND tag_id = $2 FOR UPDATE`, then delete it only if `NOT EXISTS (SELECT 1 FROM topic_tag_links WHERE tenant_id = $1 AND tag_id = $2)`. Because Postgres `FOR UPDATE` conflicts with `FOR KEY SHARE`, a prune never races an in-flight `POST` of the same slug.

### 2.4 Visibility-scoped tag counts and cross-channel listing

- **`ViewTopicTags(ctx, tenant, q TopicTagListQuery)`** (`GET /v1/view/topic-tags`):
  - Joins `topic_tags tt` -> `topic_tag_links ttl` -> live, non-archived, non-expired, non-issue channel topics passing the caller's read door (`PublicChannels` union `ReaderChannels`), using `topic_heads` when enabled (else `messages`):
    - Topic must have at least one non-expired, non-loop channel message in a channel the caller can read (`channel IS NOT NULL`, `channel = ANY($pub) OR channel = ANY($mine)`).
    - Topic must not be archived (`NOT card_archived AND archived_rows = 0`), must not be an issue discussion (`NOT EXISTS (SELECT 1 FROM issues ...)`), and must not be hidden by demo moderation or box-owner lock.
  - Groups by `(tt.slug, tt.name)`, `HAVING COUNT(DISTINCT ttl.task_id) > 0`.
  - Orders by `count DESC, tt.slug ASC` (canonical API order; WUI reverses for `newest-last`).
  - Result: tags used only in private channels the caller cannot see have visible count 0 and are **never returned** (D2).
- **`ViewTopics` with `TopicQuery.Tag`** (`GET /v1/view/topics?tag=<slug>`):
  - Normalizes `tag` via `NormalizeTopicTag` (`400 bad_tag` if invalid; empty result `{"topics":[],"next":null}` if unknown or 0 visible topics).
  - Adds a tag predicate to `viewTopicsSQL` (`store/view_postgres.go:225`), `headWalkSQL` (`store/view_topics_head.go:396`), and `viewTopicsDueSQL` (`:434`):
    ```sql
    AND EXISTS (
      SELECT 1 FROM topic_tag_links ttl
      JOIN topic_tags tt ON tt.tenant_id = ttl.tenant_id AND tt.tag_id = ttl.tag_id
      WHERE ttl.tenant_id = $tn AND ttl.task_id = l.task_id AND tt.slug = $tag
    )
    ```
  - Runs under the existing `readerDoor` / `headDoor`, `archivedTopicHideSQL`, `NoIssues`, `per_topic=N`, `before=` cursor, `lockView`, and `moderation` filters. Thus a caller lists matching topics **across all channels they can see**, and never sees topics from private channels they are not in.
- **Zero extra round trips on existing topic reads (`TestRoundTripsPerRequest`)**:
  - `store/view_postgres.go:388-408` (`summary()`): adds one correlated array expression `COALESCE(ARRAY(SELECT tt.slug FROM topic_tag_links ttl JOIN topic_tags tt ON tt.tenant_id = ttl.tenant_id AND tt.tag_id = ttl.tag_id WHERE ttl.tenant_id = $tn AND ttl.task_id = w.task_id ORDER BY tt.slug), '{}')` into `TopicRow.Tags`, serialized as `viewTopic.Tags []string \`json:"tags,omitempty"\`` (`api/internal/hub/view.go:567-587`).
  - `store/channels_postgres.go:717-727` (`topicAccessRead` inside `ViewTopicDoor`): adds the same correlated array into `TopicAccess.Tags`, serialized as `topicBody.Tags []string \`json:"tags,omitempty"\`` (`view.go:613-625`) on non-`after=` reads (matching `topicPriorityStamp`, `view.go:1205-1207`).

### 2.5 Endpoints, authorisation (Owner 1B), and refusals

Registered via `s.routeTopicTags(mux)` in `routeView` (`api/internal/hub/view.go:66`, beside `routeTopicPriority`). Uses its own dedicated `topicTagsPreflight` handler in `api/internal/hub/topic_tags.go` (`Access-Control-Allow-Methods: POST, DELETE`) so the shared `topicPreflight` (`topic_archive.go:404-412`, which allows `PUT, DELETE` for archive/delete/priority) is not widened.

| Method & Path | Door / Authz | Request | Response (`200 OK`) |
|---|---|---|---|
| `GET /v1/view/topic-tags` | `stampedView` (`humanTenant`, `rbac.TopicsRead`, `readerChannels`) | none | `{ "tags": [ { "slug": "billing", "name": "billing", "count": 7 } ] }` |
| `GET /v1/view/topics?tag=<slug>&...` | existing `stampedView` (`handleViewTopics`) | query `tag=<slug>` (+ existing `per_topic`, `limit`, `before`, `since`) | existing `topicsBody`; each `viewTopic` includes `"tags": [...]` when non-empty |
| `POST /v1/topics/{task_id}/tags` | member session + billing + not demo + `notes.send` + read door + `topicOpenDoor` + **`mayChangeTopic`** | `{ "tag": "billing" }` (max body 1 KiB) | `{ "task_id": "<uuid>", "tags": ["billing"], "added": "billing", "set_by": "<id>", "set_at": "<rfc3339>" }` |
| `DELETE /v1/topics/{task_id}/tags/{slug}` | same as `POST` | path `{slug}` | `{ "task_id": "<uuid>", "tags": [], "removed": "billing", "set_by": "<id>", "set_at": "<rfc3339>" }` |
| `OPTIONS /v1/topics/{task_id}/tags` and `OPTIONS /v1/topics/{task_id}/tags/{slug}` | dedicated `topicTagsPreflight` (`allowOrigin`) | CORS preflight | `204 No Content`, `Access-Control-Allow-Methods: POST, DELETE`, `Access-Control-Allow-Headers: Authorization, Content-Type, X-Locale`, `Max-Age: 7200` |

**Authorisation order on `POST` and `DELETE`** (mirrors `topic_priority.go:55-56` and `topic_archive.go:188-194`):

| Step | Check | HTTP | Error token |
|---|---|---|---|
| 1 | `humanTenant(w, r)` | `401` | `unauthorized` |
| 2 | `editorID(r, t.ID)` and `hum != ""` | `403` | `forbidden` (`permission: "notes.send"`) |
| 3 | `billing.AllowsWrite(t.BillingStatus)` | `402` | `unpaid` |
| 4 | `isDemoVisitor(ctx, t.ID, hum)` | `403` | `demo_read_only` |
| 5 | `permit(w, r, t.ID, hum, rbac.NotesSend)` | `403` | `forbidden` (`permission: "notes.send"`) |
| 6 | `task_id` UUID + `canReadTopic` + `openingCard` | `404` | `not_found` (never `403` for unreadable private topics) |
| 7 | `task == LobbyTaskID` or `card.Channel == ""` (DM, per D6 / Q1 Option A) | `409` | `not_a_topic` |
| 8 | `topicOpenDoor` (archived topic check, `topic_priority.go:56`) | `409` | `topic_archived` |
| 9 | **`mayChangeTopic(ctx, t.ID, hum, from, card.FromID)`** (owner answer 1B: opening card's author — plus `card.TypedBy` if Q6 Option A — OR `a.TenantOwner` (`biz_owner`) OR `a.Has(rbac.Admin)`) | `403` | `not_allowed` |
| 10 | `NormalizeTopicTag` | `400` | `bad_tag` |
| 11 | Per-topic cap (10 distinct tags, `POST` only) | `400` | `too_many_tags` |

### 2.6 Live event frame and reconnect catch-up

- **Frame type**: `topic_tags` (`const topicTagsFrame = "topic_tags"`).
- **Broadcast**: sent via `s.fanoutTopic(ctx, q.t.ID, q.card, withType(topicTagsFrame, q.card, out))` (`api/internal/hub/topic_archive.go:379-400`). Because `fanoutTopic` gates every socket through `wuiConn.wants(taskID, channel, parties, members)` (`api/internal/hub/wui.go:522-564`), only sockets entitled to read `q.card`'s channel receive the frame. Private-channel tag edits never reach non-members.
- **Payload**:
  ```json
  {
    "type": "topic_tags",
    "task_id": "<uuid>",
    "channel": "<channel_id>",
    "tags": ["billing", "q4-plan"],
    "added": "q4-plan",
    "set_by": "HUM-10",
    "set_at": "2026-11-25T19:40:00.123456Z"
  }
  ```
  (`removed` replaces `added` on `DELETE`.)
- **Reconnect catch-up**:
  - `store/view_changes_postgres.go:28-50` gains branch 8 (`'tags'`) reading `topic_tag_stamps WHERE tenant_id = $1 AND updated_at > $2` mapped to the topic's oldest live row, so `?since=` deltas refresh any topic whose tags changed offline.
  - On `live.onReconnected`, the WUI refreshes `GET /v1/view/topic-tags` (stamped view: answers `304` with zero body when unchanged).

---

## 3. WUI

### 3.1 Two tabs in the left Channels section

- Inside `#sidebar-panel-channels` (`wui/components/ChannelSidebar.vue:277-468`), the left icon rail (`sidebar-tab-channels`) does **not** change.
- Replace the static `<h2>` (`sidebar.channels`, `:296-299`) in `.sidebar-head` with a WAI-ARIA 2-tab switcher (`role="tablist"`, `aria-label` = `t('sidebar.channels_tabs_label')`):
  - Tab 1: **Channels** (`id="channels-subtab-channels"`, `data-testid="channels-subtab-channels"`, `aria-controls="channels-subpanel-channels"`).
  - Tab 2: **Topic tags** (`id="channels-subtab-tags"`, `data-testid="channels-subtab-tags"`, `aria-controls="channels-subpanel-tags"`).
  - `<MobileBack top />` stays at the start of `.sidebar-head`; the `+` create-channel button (`:300-310`) renders only while the Channels sub-tab is active and `canCreate` is true (tags are created on topics per owner 3A, never from the sidebar).
- **Sub-tab state**: defaults to `'channels'`; **row T4 adds** `/tag` / `/tag/*` -> `'channels'` to `tabForPath` (`wui/utils/sidebar-tabs.mjs:70-76`, which has no `/tag/` rule on `d5a2422f4`), and **row T5 adds** `tag` to `setLinkOpenHook` (`ChannelSidebar.vue:805`) and switches the inner sub-tab to `'tags'` whenever the route matches `/tag/*`. Navigating to `/channel/<name>` keeps or selects `'channels'`.
- **Channels sub-panel**: completely unchanged in markup, CSS, drag-reorder, topic-move drop targets, unread order, and menus.
- **Topic tags sub-panel** (`wui/components/SidebarTopicTags.vue`, lazy-loaded on first open of the sub-tab or on `/tag/*` so first-load DOM/JS budgets on `/` and `/lobby` do not grow):
  - Backed by a dedicated Pinia store `wui/stores/topic-tags.ts` (loads `GET /v1/view/topic-tags`, caches per-topic tag arrays, subscribes to `live.onTopic` for `topic_tags`, `topic_archived`, `topic_deleted`, `topic_moved`, and reloads on `live.onReconnected`).
  - **Order follows `useViewPrefs().newestLast`** (`wui/composables/useViewPrefs.ts:20`):
    - API returns tags sorted `count DESC, slug ASC`.
    - `SidebarTopicTags.vue` passes the list through `displayOrder(tags, messageOrder)` (`wui/utils/view-prefs.mjs:94-97`):
      - **Newest first** (prepend): most-used tag at the **top**, least-used at the bottom.
      - **Newest last** (postpend): most-used tag at the **bottom**, least-used at the top (matching where new messages appear).
    - DOM order equals visual reading order (never CSS `column-reverse`).
  - Each row is a `<NuxtLink :to="localePath('/tag/' + encodeURIComponent(tag.slug))">` with a tag icon (`UiIcon`), the tag name, and a muted count pill (`data-testid="topic-tag-count"`), matching `.nav-item` height and typography. Active tag carries `.active` and `aria-current="page"`.
  - Empty state: muted translated message (`topic_tags.empty`) when no visible used tags exist.

### 3.2 Tag display and editor on a topic

- **Read-only chips on topic cards** (`wui/components/MessageCard.vue`, inside `.msg-main` for level-1 openers `msg.is_parent !== 0` when `tags.length > 0`):
  - Renders compact tag chips (`data-testid="topic-tag-chip"`, `data-tag="<slug>"`).
  - Clicking a chip calls `@click.stop` and navigates to `/tag/<slug>` without opening the topic pane.
- **Topic tag bar and editor** (`wui/components/TopicTagsBar.vue`, lazy-mounted in `TopicPane.vue` and `LiveTopicPane.vue` under `.topic-head__row2`, `:30-33`, matching `LazyTopicPriorityChooser`):
  - **Visibility**:
    - Every member who can read the topic sees its tag chips (clickable -> `/tag/<slug>`).
    - Only the topic's author or a workspace admin sees the **`+ Add tag`** button (`data-testid="topic-tag-add-btn"`) and per-chip **`×`** remove buttons (`data-testid="topic-tag-remove"`).
    - Helper `mayEditTopicTags(opener, viewerId, me)` in `wui/utils/topic-tags.ts` (new `.ts` module, **not** `.mjs`, respecting `SHIMS_CAP = 102` in `tests/unit/mjs-shims-exist.test.mjs:23`):
      - Returns `false` if `!opener`, archived (`archivedAt`), DM (`!opener.channel`, per D6 / Q1 Option A), or demo visitor.
      - Returns `true` if `viewerId && (opener.from === viewerId || opener.typed_by === viewerId)` (matching Q6 Option A; `from` only if Q6 Option B) OR `me.tenantOwner === true` OR `[me.role, ...(me.roles || [])].some((r) => r === 'biz_owner' || r === 'admin')`.
  - **Editor UX (Owner 3A)**:
    - Clicking `+ Add tag` opens a compact combobox input (`role="combobox"`, `aria-autocomplete="list"`, `maxlength="40"`).
    - Suggestions filter the workspace's existing tags from `useTopicTagsStore` (excluding tags already on this topic), ordered by use.
    - Pressing `Enter` (or `,`) or picking a suggestion calls `POST /v1/topics/{task_id}/tags` optimistically; on failure, rolls back and displays the translated error inline (`role="status"`, matching `TopicPriorityChooser.vue:39,121-126`).
    - Clicking `×` calls `DELETE /v1/topics/{task_id}/tags/{slug}` optimistically with rollback on failure.
    - At 10 tags, `+ Add tag` is disabled with tooltip/title `topic_tags.limit_reached`.
    - Under Q3 Option A, T6 also adds an "Edit tags" entry to the topic card menu (`wui/utils/msg-menu.mjs`) for authorized users, which opens the topic pane and focuses the tag input.

### 3.3 Cross-channel tag listing (`/tag/[slug]`)

- New route `wui/pages/tag/[slug].vue` rendered in `.spool-main` (middle pane):
  - Header: reuses `<FeedHeader :title="'#' + slug" />` (or tag badge + count).
  - Body: reuses `<LiveFeed>` with `always-topic`, `clickable`, `open-button`, `clip`, `virtual`, `has-older`, `@older`, `@open-topic` (same props and `useTopicRoute` pattern as `wui/components/MessageFeed.vue:23-47,144-148`).
  - Data: loads `GET /v1/view/topics?tag=<slug>&per_topic=1&limit=30` (and `before=` cursor for Load more) into `useTopicTagsStore`, ordering cards by the user's `newestLast` setting via `LiveFeed`'s existing `displayOrder`.
  - **Cross-channel source pill**: each card rendered on `/tag/[slug]` displays a clickable channel pill (`#channel-name`, `data-testid="topic-channel-pill"`) linking to `/channel/<channel_id>?topic=<task_id>`, so topics from different channels are immediately distinguishable.
  - Clicking any topic card opens that topic in the right-hand `<TopicPane>` (loading its full thread and allowing replies into its real channel/task).
  - **Omnibox on `/tag/[slug]`**: when a topic pane is open and selected last (`paneTakesLine`), the Omnibox sends replies into that topic; when no topic pane is open, the Omnibox operates in search mode (a new topic requires a channel, so sending a plain message without an open topic is not offered on `/tag/[slug]`).
  - **Live updates**:
    - `topic_tags` frame adding `<slug>` to a visible topic refreshes or inserts that topic card; removing `<slug>` drops the card from the `/tag/[slug]` view at once.
    - `topic_archived` / `topic_deleted` drops the card and decrements counts.

### 3.4 Keyboard and mobile (spec 043 + spec 103)

- **Desktop keyboard**:
  - Sub-tab list inside `#sidebar-panel-channels`: `ArrowLeft` / `ArrowRight` / `Home` / `End` switch between `Channels` and `Topic tags` (`roving tabindex`).
  - Tag list rows: extend `wui/composables/useSidebarRowKeys.ts` with `onTagRowKey` mirroring `onChannelRowKey` (`:59-87`): `ArrowDown` / `ArrowUp` (and `j` / `k` when `session.claims?.keyboard_shortcuts !== false`), `Home` / `End` navigate tag rows; `Enter` opens `/tag/<slug>` and focuses Panel 2 (`.spool-main`).
  - Tag editor: `ArrowDown` / `ArrowUp` move through autocomplete suggestions; `Enter` selects/submits; `Escape` closes the editor and restores focus to `+ Add tag`.
  - Focus rings use `--focus-ring` / `--focus-ring-w` (`tests/unit/focus-tokens.test.mjs`), font sizes use `rem` (`tests/unit/font-size.test.mjs`).
  - Documented in `csi-spl-doc/doc/help/keyboard-shortcuts.md` and `wui/public/help-md/keyboard-shortcuts.md` (T7).
- **Mobile (`<= 820 px`, spec 043)**:
  - **3-level stack**:
    - Level 1: `#sidebar-panel-channels` full width with the 2-tab switcher (`Channels` \| `Topic tags`, each `>= 44 px` tall) and tag list rows (`>= 44 px` tall, FR-002 / FR-005).
    - Level 2: tapping a tag navigates to `/tag/<slug>`. On `d5a2422f4`, `isSectionPage('/tag/...')` already returns `false` (`wui/utils/section-strip.mjs:24-28`), while `chatKind('/tag/...')` returns `''` (`:96-101`); **row T4 adds** `p.startsWith('/tag/') -> 'channel'` to `chatKind`, so `/tag/<slug>` renders `FeedHeader` with `<MobileBack />` (`>= 44 px`) and enters `mobileDiscussionStack`.
    - Level 3: tapping a topic card opens `TopicPane` full width; Back (header chevron, left-edge swipe, or browser Back) walks `3 -> 2 (/tag/<slug>) -> 1 (Topic tags list)` via `mobileDiscussionStack` (`wui/utils/mobile-stack.mjs:245-258`).
  - **No hover-only controls (FR-006)**: `+ Add tag` and chip remove buttons (or an explicit `>= 44 px` "Edit tags" button that opens a bottom sheet on phones so chips stay compact without overlapping 44 px targets) are always visible to authorized users.
  - **iOS zoom prevention (spec 043 D8)**: the tag input uses `font-size: 1rem` (16 px) at `@media (max-width: 820px)`.
  - **Desktop unchanged (`> 820 px`, spec 043 S2)**: 3-pane widths and the Channels sub-tab remain unchanged.

### 3.5 i18n keys and the language rule

- Every user-visible string (including `aria-label`, `title`, `placeholder`, empty states, and error messages) is a translation key in `csi-spl-wui/i18n/locales/en.json` and all 18 other locale files (`bg, el, es, et, fi, he, lt, lv, mk, nl, pl, ro, ru, sk, sr, sv, tr, uk` — 19 locales total).
- **Per-lane shipping rule (no unreviewed text ever reaches dev/prd)**: each WUI lane (T5 and T6) lands its own keys across all 19 locale files AND runs `i18n-no-raw-text.test.mjs`, `i18n-parity.test.mjs`, `i18n-untranslated.test.mjs`, and Google Cloud Translation (`cd csi-spl-orc && ./run -a do_spl_lang_review_gct`, `csi-spl-orc/src/bash/run/spl-lang-review-gct.func.sh`) in that same lane before landing.
- Key split by lane:
  - **T5 keys**: `sidebar.channels_tabs_label`, `sidebar.topic_tags`, `sidebar.help.topic_tags`, `topic_tags.empty`, `topic_tags.count_aria`, `topic_tags.page_title`, `topic_tags.page_empty`, `topic_tags.channel_link_aria`.
  - **T6 keys**: `topic_tags.add`, `topic_tags.edit`, `topic_tags.placeholder`, `topic_tags.remove_aria`, `topic_tags.suggestions_label`, `topic_tags.limit_reached`, `topic_tags.error_bad_tag`, `topic_tags.error_forbidden`, `topic_tags.error_archived`, `topic_tags.error_generic`.

---

## 4. Agents / spool CLI and MCP

**Decision: WUI-only for v1; CLI and MCP deferred to Phase 2** (confirmable in Q5).

### Why WUI-only for v1

1. **Matches the owner's ask**: every line of the owner's request (section 0) and form `dece6b4a` concerns WUI browsing and human tagging; no agent workflow was requested yet.
2. **Matches existing topic-metadata precedent**: `topic_priority` (`api/internal/hub/topic_priority.go`, spec 150) is browser-only — there is no `spool topic-priority` CLI verb or MCP tool.
3. **Owner answer 1B limits agent writes**: under 1B (author and workspace admins only), a box agent is never a workspace admin (`api/internal/hub/box_archive.go:29`: "a box is not a tenant admin"). An agent could only tag topics it opened itself (`card.FromID == f.As`), which is a small fraction of workspace topics.
4. **Avoids box-wire and mixed-fleet risk in v1**: box reads/writes travel over `/v1/ws` (`api/internal/wire/wire.go:96-102`, `api/internal/hub/topics_agent.go:46-73`, `box_archive.go:34-51`). Adding new box frames requires capability gating in `hello` + sidecar upgrades across every box (older sidecars route unknown frames into `s.replies`, as documented in spec 195 D4).

### Clean Phase 2 path (preserved by v1)

- `topic_tags.created_by` and `topic_tag_links.added_by` are `text` columns accepting both `HUM-*` and agent ids.
- **Phase 2a (read)**: add additive `tags?: string[]` to `agentTopic` (`api/internal/hub/topics_agent.go:33-37`) and `tag=<slug>` query filter to `agentTopicQuery` (`:78-100`), exposed via `spool topic-list --tag <slug>` and MCP `spool_read_link` / `spool_tail` metadata.
- **Phase 2b (write)**: add a capability-gated `TTopicTags` box WS frame + `spool topic-tag add|rm` CLI verb and MCP `spool_topic_tag` tool, allowing an announced agent to tag topics it authored (`card.FromID == f.As && card.FromBox == x.box`) using the exact same `store` write path and `fanoutTopic` broadcast.

---

## 5. Build rows (T1..T7, one lane per row)

**Owner-question baseline**: unless the owner answers otherwise before a row starts, every row below builds **Option A (recommended)** of its listed Qs in section 6 (`Q1-Q6`). Whole-plan scope follows **Q5 Option A** (WUI-only in v1; if the owner picks Q5 Option B, a follow-up row `T8` adds `agentTopic.Tags` + capability-gated `TTopicTags` box frame + CLI/MCP).

Clean-code limits apply to every row: max 75 lines/function, depth 4, 7 params in Go (`api/internal/cleancode/cleancode_test.go`), 5 params in TS/Vue (`tests/unit/cleancode.test.mjs`), no `SELECT *` in Go, and new WUI utils written as `.ts` (never `.mjs`, `SHIMS_CAP = 102` in `tests/unit/mjs-shims-exist.test.mjs:23`).

| Row | Layer / Scope | Files | Depends on | Done test | Red control |
|---|---|---|---|---|---|
| **T1** | **RDB + store schema, CRUD, locking & `channelmove` remap**: claim next migration (`do_rdb_migration_next`), create `topic_tags`, `topic_tag_links`, `topic_tag_stamps` with fail-closed RLS and `change_stamp` triggers; add NFC `NormalizeTopicTag`, `TopicTagStore` (Memory + Postgres) with `topic_tag_stamps` + `FOR KEY SHARE`/`FOR UPDATE` locks, `DeleteTopic` cleanup, `MergeTopic` deterministic cap-10 union (B kept + A filled by `added_at ASC, slug ASC`), `rlsTables`, `change_stamp_test.go`, `channelmove/catalogue.go` (`topic_tags` `NotChannel`, `topic_tag_links` `Rewritten` with `<DST>` slug-remap helper, `topic_tag_stamps` `Moved`) | `rdb/<NNNN>_topic_tags.sql`, `api/internal/store/topic_tags.go`, `topic_tags_postgres.go`, `topic_tags_test.go`, `topic_archive_postgres.go`, `topic_merge_postgres.go`, `rls_test.go`, `change_stamp_test.go`, `crosstenant_test.go`, `channel_copy_apply_postgres.go`, `api/internal/channelmove/catalogue.go`, `catalogue_test.go` | Q2 (builds Option A: lowercase NFC) | `PRE_PUSH_TIER=full ./run -a do_check_pre_push`; Postgres tests for NFC + `e\u0301`/Turkish `İ`/`ı`, 10-tag cap under concurrent `POST`s, concurrent `DELETE` prune vs `POST`, `MergeTopic` when `A+B > 10` (B kept, A filled by `added_at, slug`), `DeleteTopic` orphan prune, `channelmove` slug remap (`<DST>` existing slug with different `tag_id` + new slug), RLS, cross-tenant isolation, change stamp | Drop `FORCE ROW LEVEL SECURITY` on `topic_tag_links` -> `TestRLSCoversEveryTenantTable` fails RED; omit `change_stamp` trigger -> `change_stamp_test.go` fails RED; classify `topic_tag_links` as plain `Moved` -> `<DST>` FK/slug remap test fails RED |
| **T2** | **Store topic reads & delta**: add `ViewTopicTags` (visibility-filtered counts, `count > 0` only), `TopicQuery.Tag` filter in `viewTopicsSQL` / `headWalkSQL` / `viewTopicsDueSQL`, inline `TopicRow.Tags` in `summary()`, `TopicAccess.Tags` in `topicAccessRead` (`ViewTopicDoor`), and `ViewChanges` `'tags'` branch | `api/internal/store/view.go`, `view_postgres.go`, `view_topics_head.go`, `channels_postgres.go`, `view_changes_postgres.go`, `testdata/view_topics_sql.golden`, `view_topics_test.go`, `pipelined_reads_test.go`, `topic_tags_test.go` | T1; Q1 (builds Option A: channels only) | `PRE_PUSH_TIER=full ./run -a do_check_pre_push`; Postgres tests proving cross-channel tag filtering, private-channel omission from `ViewTopicTags` & `ViewTopics(Tag:)`, archived/expired/issue exclusion, `ViewTopicDoor` tags, and `ViewChanges` on add + remove | Remove `readerDoor` filter from `ViewTopicTags` -> private-channel tag leaks to non-member and test fails RED; drop `topic_tag_stamps` branch from `viewChangesSQL` -> removal delta test fails RED |
| **T3** | **Hub API, authz (1B), live frame & OpenAPI**: `GET /v1/view/topic-tags`, `?tag=` on `handleViewTopics`, `Tags` on `viewTopic` & `topicBody`, `POST /v1/topics/{task_id}/tags`, `DELETE /v1/topics/{task_id}/tags/{slug}`, dedicated `topicTagsPreflight` (`POST, DELETE`), `mayChangeTopic` gate (+ `typed_by` per Q6 Option A), `topic_tags` WS fanout via `fanoutTopic`, OpenAPI schema | `api/internal/hub/topic_tags.go`, `topic_tags_test.go`, `view.go`, `view_delta.go`, `openapi.json`, `roundtrips_perf_test.go` | T2; Q1 (Option A: 409 on DM), Q6 (Option A: `typed_by` counts as author) | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` + `PRE_PUSH_TIER=full`: every status code (401/402/403/404/409/400), author (`from` and `typed_by`) + `biz_owner` + multi-role `admin` allow vs non-author developer `403 not_allowed`, private topic `404` + no WS frame leak, `topicTagsPreflight` returns `POST, DELETE` without changing `topicPreflight`, `TestRoundTripsPerRequest` unchanged | Bypass `mayChangeTopic` -> non-author member write returns 200 instead of 403 and fails RED; broadcast `topic_tags` without `wuiConn.wants` -> non-member socket receives private frame and fails RED |
| **T4** | **WUI client, store, pure utils & WS wiring**: pure `topic-tags.ts` (NFC normalization preview, `mayEditTopicTags` checking `me.roles`, `orderTopicTags`), `live-ws.mjs` `FRAMES.topicTags`, `spool-client.mjs` + mock methods, Pinia `stores/topic-tags.ts`, `sidebar-tabs.mjs` (`tabForPath` `/tag/` -> `'channels'`) + `section-strip.mjs` (`chatKind` `/tag/` -> `'channel'`) | `wui/utils/topic-tags.ts`, `wui/utils/live-ws.mjs`, `wui/utils/spool-client.mjs`, `wui/utils/spool-client-mock.mjs`, `wui/stores/topic-tags.ts`, `wui/types/spool.ts`, `wui/utils/sidebar-tabs.mjs`, `wui/utils/section-strip.mjs`, `tests/unit/topic-tags.test.mjs` | T3 (parallelizable on frozen contract); Q2 (Option A), Q4 (Option A), Q6 (Option A) | `pnpm run typecheck` + `tests/unit/topic-tags.test.mjs`, `cleancode.test.mjs`, `mjs-shims-exist.test.mjs` green | Invert `newestLast` reversal in `orderTopicTags` -> unit test fails RED; check only `me.role` without `me.roles` -> multi-role admin test fails RED |
| **T5** | **WUI left panel tabs + `/tag/[slug]` cross-channel listing + T5 i18n**: add `Channels` \| `Topic tags` tab switcher + `setLinkOpenHook` `tag` handling to `ChannelSidebar.vue`, new `SidebarTopicTags.vue` ordered by use + `newestLast`, `useSidebarRowKeys.ts` tag-row keys, new `pages/tag/[slug].vue`, read-only tag chips + cross-channel pill on `MessageCard.vue`, and T5's 8 i18n keys across all 19 locales verified with Cloud Translation | `wui/components/ChannelSidebar.vue`, `wui/components/SidebarTopicTags.vue`, `wui/composables/useSidebarRowKeys.ts`, `wui/pages/tag/[slug].vue`, `wui/components/MessageCard.vue`, `csi-spl-wui/i18n/locales/*.json`, `tests/e2e/topic-tags-list.test.mjs` | T4; Q4 (Option A: single tag) | `pnpm run typecheck` + `cleancode.test.mjs` + `font-size.test.mjs` + `focus-tokens.test.mjs` + `i18n-parity` / `i18n-no-raw-text` / `i18n-untranslated` + `do_spl_lang_review_gct` + `BASE_URL=<bundle> pnpm run test:e2e` (1440 px & 390 px: tab switch, `newest-first` vs `newest-last` order, cross-channel listing + channel pill, mobile 3-level Back `3->2->1`, Channels tab unchanged) | Drop `displayOrder` in `SidebarTopicTags.vue` -> `newest-last` e2e check fails RED; drop a key from `fi.json` -> `i18n-parity.test.mjs` fails RED |
| **T6** | **WUI topic tag editor, live sync + T6 i18n**: new lazy `TopicTagsBar.vue` (autocomplete + free-text add, remove, optimistic rollback, 44 px mobile targets / 16 px input), wire into `TopicPane.vue`, `LiveTopicPane.vue`, and `msg-menu.mjs` ("Edit tags"), and T6's 10 i18n keys across all 19 locales verified with Cloud Translation | `wui/components/TopicTagsBar.vue`, `wui/components/TopicPane.vue`, `wui/components/LiveTopicPane.vue`, `wui/utils/msg-menu.mjs`, `csi-spl-wui/i18n/locales/*.json`, `tests/e2e/topic-tags-editor.test.mjs` | T4, T5; Q3 (Option A: pane header + card menu) | `pnpm run typecheck` + `i18n-parity` / `i18n-no-raw-text` / `i18n-untranslated` + `do_spl_lang_review_gct` + `BASE_URL=<bundle> pnpm run test:e2e` (1440 px & 390 px: author & admin add/remove/autocomplete, live update in sidebar & `/tag/[slug]`, non-author non-admin read-only, keyboard `Enter`/`Escape`, 44 px / 16 px phone checks) | Render add/remove buttons for non-author developer -> e2e role-gate assertion fails RED; ignore `topic_tags` WS frame -> live sync test fails RED; leave an English string in `bg.json` -> `i18n-untranslated.test.mjs` fails RED |
| **T7** | **User help & keyboard-shortcuts docs**: document topic tags, cross-channel `/tag/<slug>` listing, Message-order tie-in, and tag/tab keyboard shortcuts | `wui/public/help-md/message-levels-and-topics.md`, `wui/public/help-md/user-settings.md`, `wui/public/help-md/keyboard-shortcuts.md`, `csi-spl-doc/doc/help/keyboard-shortcuts.md` | T5, T6 | `do_check_dist_hygiene` + `lint-mdlinks` green; help pages cover tab order, permissions (1B), cross-channel `/tag/<slug>`, and keyboard shortcuts | Break a relative link in `keyboard-shortcuts.md` -> `lint-mdlinks` fails RED |

Dependency order: `T1 -> T2 -> T3 -> T4 -> T5 -> T6 -> T7` (T4 may proceed in parallel with T2/T3 in mock mode once T3's wire contract is locked).

---

## 6. Open questions for the owner

1. **Direct-message topics**: Should tags apply only to **channel** topics, or to direct-message topics as well?
   - **A (recommended)**: Channel topics only — the Topic tags tab splits Channels, while DMs stay in Direct messages.
   - **B**: Both channel and DM topics (a tag used only on a DM would be visible only to its two participants).
2. **Tag capitalization**: Should tags normalize to lowercase (`billing`, `release-notes`), or keep the first author's capitalization (`Billing`, `Q4-Plan`) while matching case-insensitively?
   - **A (recommended)**: Always lowercase canonical slugs (no casing drift across users; URL matches display).
   - **B**: Keep the first-created capitalization for display and match case-insensitively.
3. **Where tags are edited**: Where should the topic's author and workspace admins edit tags?
   - **A (recommended)**: In the open topic pane header (beside priority) plus an "Edit tags" action in the topic card's menu; topic cards in the feed show clickable read-only tag chips.
   - **B**: Also show an inline `+` tag button directly on every topic card in the channel/tag feed.
4. **Multi-tag filtering**: Should clicking a tag in v1 filter by one tag at a time, or support combining multiple tags (AND filter)?
   - **A (recommended)**: Single tag in v1 (one click lists that tag's topics across channels; multi-tag AND filter later if needed).
   - **B**: Multi-tag AND filter in v1.
5. **Agents (spool CLI / MCP)**: Should v1 be WUI-only, or also let agents read tags (`topic_list`) and tag topics they authored via CLI / MCP?
   - **A (recommended)**: WUI-only in v1; add CLI and MCP in Phase 2.
   - **B**: Include agent read and author-set in v1.
6. **Terminal-typed topics (`typed_by`)**: When a human starts a channel topic from an agent's terminal (`typed_by = HUM-n`, `from = <agent>`), should that human count as the topic's author for tagging (in addition to workspace admins)?
   - **A (recommended)**: Yes — treat `typed_by` as the human author when present.
   - **B**: No — check `from` only (workspace admins can still tag agent-opened topics).

---

## 7. Review log

### 7.1 v0.2 (folding `c-750` claude R7 review of `9920e6d74`, msg `2e7461d8`)

| Finding | Resolution | Section |
|---|---|---|
| **W1** `channelmove` `Moved` breaks `topic_tag_links` FK / slug uniqueness; `topic_tags` class unnamed | Classified `topic_tags` as `NotChannel`, `topic_tag_links` as `Rewritten` with `<DST>` slug-remap upsert + orphan prune, `topic_tag_stamps` as `Moved`; added remap test & red control in T1 | 2.2, 5 (T1) |
| **W2** Build rows omitted dependencies on open owner questions Q1-Q6 | Stated Option A baseline in section 5 header and listed Q1/Q2/Q3/Q4/Q6 per row (plus Q5 for whole plan) in `Depends on` | 5 |
| **W3** T5/T6 shipped WUI strings before T7 added locales & ran Cloud Translation | Split locale keys into T5 (8 keys) and T6 (10 keys), each running i18n unit gates + `do_spl_lang_review_gct` before landing; T7 holds help & shortcuts docs | 3.5, 5 (T5-T7) |
| **W4** T1 omitted `store/topic_merge_postgres.go` (`MergeTopic :29`) and had no deterministic cap-10 rule | Cited `topic_merge_postgres.go:29`, added it to T1 files, and specified deterministic merge rule (B keeps all existing tags; remaining slots filled from A by `added_at ASC, slug ASC`) + test | 2.2, 5 (T1) |
| **N1** Measured sha `3582fc44b` vs parent `d5a2422f4` | Updated measured sha to `d5a2422f4` | Header, 1, 2.1 |
| **N2** `tabForPath` and `chatKind` `/tag/` rules read as already present | Explicitly marked both as absent on `d5a2422f4` and added by T4 (`setLinkOpenHook` by T5) | 1.2, 3.1, 3.4, 5 (T4, T5) |
| **N3** Wrong path `csi-spl-doc/doc/md/keyboard-shortcuts.md` | Replaced with verified `csi-spl-doc/doc/help/keyboard-shortcuts.md` and `wui/public/help-md/keyboard-shortcuts.md` | 1.6, 3.4, 5 (T7) |
| **N4** No NFC normalization or `\p{Mn}` / Turkish `İ`/`ı` handling | Added NFC before & after `strings.ToLower`, allowed `\p{Mn}` after `\p{L}`/`\p{Mn}`, added `e\u0301`/Turkish `İ`/`ı` test in T1 | 2.3, 5 (T1) |
| **N5** Unspecified locks for 10-tag cap race and orphan-prune vs `POST` race | Specified `topic_tag_stamps` `INSERT ... ON CONFLICT DO UPDATE` row lock per topic and `topic_tags` `FOR KEY SHARE` (`POST`) vs `FOR UPDATE` (`DELETE` prune) + concurrency tests in T1 | 2.3, 5 (T1) |
| **N6** Ambiguous CORS preflight vs shared `topicPreflight` | Specified dedicated `topicTagsPreflight` (`POST, DELETE`) leaving `topicPreflight` untouched | 2.5, 5 (T3) |
| **N7** Missing lifecycle rules for `PromoteMessage` and `MoveMessage` | Added explicit rules citing `topic_promote_postgres.go:25` (new promoted topic starts untagged; moving a single message does not transfer tags) | 2.2 |
| **N8** `rls_test.go` `TestRLSCoversEveryTenantTable` auto-discovers tables | Clarified auto-discovery (`:103-133`) vs optional `rlsTables` (`:68-99`, `TestRLSControl` `:169-178`) | 2.2 |

<!-- version: 0.2.0 · updated: 2026-11-25 · last-edit: 2026-11-25T19:57:00Z -->
