# Feature Specification: Archive and Delete a Topic

**Feature ID**: `041-spool-topic-archive-delete` · **Milestone**: M3 · **Status**: Implemented (live dev + prd, `tasks.md` T001–T011)
**Created**: 2026-09-26 · **Lane**: TOPIC-ARCHIVE (hub + DB + browser) · **Issue**: SPL-983 (epic 51, spec 033)
**Authority**: this file for the rule; `contracts/topic-archive-v1.md` for the wire; `tasks.md` for what is built and where.

Status vocabulary follows `../README.md` §2.3.

## 1. The owner's request, verbatim

prd t1 `#spool-hub-devel`, topic `8f58f802-3d1d-4bc6-a7d7-d7a378e8502a`, 2026-09-26:

> we should have the right menu options to archive and delete a topic or msg in direct
> msgs (aka card with is_parent=1), which if archived will add a soft delete = 1 and if
> delete will actually delete not only the parent msg or topic but also all of its children

Two additions the same evening (relayed by CLE-001):

> the Archive menu entry gets an icon to its LEFT that looks like Gmail's archive icon

> then we need to create an archive entity in the left-most panel

## 2. Words

- **Card** — a level-1 message (`is_parent = 1`, spec 033) drawn in the middle pane: a
  channel feed, a DM feed, the lobby feed.
- **Topic of a card** — what hangs under it. A card is one of two shapes:
  - **task opener**: the first message of a task that is not the lobby task (every
    channel and DM card). Its topic is that task, every message-rooted thread opened on
    one of its lines (`task_id` = that line's `msg_id`), and every sub-task whose
    `parent_task_id` is in the set, transitively.
  - **lobby card**: a level-1 row of the one shared lobby task (`SPOOL_HUB_LOBBY_TASK_ID`).
    Its topic is its message-rooted thread (`task_id` = the card's `msg_id`) and
    whatever hangs under that, transitively. The lobby task itself is never part of it.
  Any other `is_parent = 1` row (an agent's level-1 line inside a DM topic) is not a card
  and is refused (`409 not_a_card`).
- **Children** — every message of the topic except the card.

## 3. Behaviour

### 3.1 Archive (soft delete)

- `messages.archived_at` / `archived_by` on the card row are the soft-delete flag
  (rdb `0065`). Nothing is removed.
- While set, the topic leaves every normal view: the channel / DM / topics-home lists
  (`GET /v1/view/topics`), the lobby feed (the card row is left out of the lobby task
  read), and search. Reading the topic itself by its task id (a deep link, the Archive
  view) still works: archive hides, it does not lock.
- A reply that arrives on an archived topic is stored and delivered as always; the topic
  stays archived. (Gmail brings a thread back on a new reply; here the owner did not ask
  for it, and an agent reply un-archiving a topic a human put away is the surprise the
  soft delete exists to prevent.) **INFERRED** — say so if you want the Gmail rule.
- **Found again**: the **Archive** entry in the left rail (icon: Material "archive", the
  Gmail glyph) opens `/archive`: every archived card of the tenant the viewer may read,
  newest archived first, each with **Unarchive** and — for those allowed — **Delete**.
- **Restored** by **Unarchive** (the card menu in the Archive view, or the row button),
  which clears both columns.

### 3.2 Delete (cascade, hard)

- Deletes the card AND every child in ONE transaction. The rows referencing a message
  cascade with it (§4). A confirm dialog names the number of replies first.
- An issue's discussion topic (`issues.task_id`) is refused, `409 issue_topic`: an issue
  keeps its own lifecycle (spec 039).
- Attached files: a blob is not a row of the topic. Once no message references it, the
  existing retention door (`file_retention.go`, SweepFiles: unattached blobs older than
  24 h, avatars kept) deletes it. Nothing new is written for files.

### 3.3 Who may (owner: "yes", 2026-09-26, topic 8f58f802)

| who | Archive / Unarchive | Delete |
|---|---|---|
| the card's author (`from_id` = the caller's member id) | yes | yes |
| the tenant owner (`biz_owner`, `TenantOwner`) | yes | yes |
| `admin` | yes | yes |
| any other member | no — the entries are not shown | no |
| an agent / a box | no | no — no box frame exists for either |

Plus the read door: a card the caller may not read answers `404`, as every message
route does (CLE-34986). The browser learns the caller's role from `GET /v1/view/me`.

### 3.4 Live

Open browser sockets that were shown the card get one frame (same audience rule as
032's `message_deleted`):
- `topic_archived` `{msg_id, task_id, channel?, archived: true|false, archived_at?, archived_by?}`
  — a feed drops (or, on `false`, re-fetches) the card, the Archive view adds / drops it.
- `topic_deleted` `{msg_id, task_id, channel?, msg_ids: [...], task_ids: [...]}` — every
  feed and an open topic pane drop those rows; a pane showing one of `task_ids` closes.

## 4. Every table that references a message

Measured on trunk `7325032b`: `grep -n 'REFERENCES messages' csi-spl-rdb/src/sql/postgres/spool-hub/*.sql` -> 4.

| table | key | on a hard delete |
|---|---|---|
| `deliveries` (0001) | (tenant_id, msg_id) FK | ON DELETE CASCADE |
| `message_revisions` (0026) | FK | ON DELETE CASCADE |
| `message_reactions` (0037) | FK | ON DELETE CASCADE |
| `message_kind_changes` (0060) | FK | ON DELETE CASCADE |
| `message_period_counts` (0023) | trigger counters, not per message | untouched: quota counts sends, a delete does not refund |
| `issues.task_id` (0047) | task id, no FK | refused (§3.2) |
| file blobs (GCS / disk) | `messages.files` jsonb | orphaned, swept by the 24 h retention door |

So the delete is `DELETE FROM messages WHERE tenant_id = $1 AND msg_id = ANY($2)` in one
transaction, after the set is walked in the same transaction (§2).

## 5. Functional requirements

| id | requirement | status |
|---|---|---|
| FR-TA-001 | rdb 0065: `messages.archived_at timestamptz NULL`, `archived_by text NULL`, partial index on archived rows; applied dev + prd before any hub reads it | Implemented — `tasks.md` |
| FR-TA-002 | `PUT /v1/messages/{msg_id}/archive` archives a card, `DELETE …/archive` unarchives; §3.3 gate; `409 not_a_card`, `409 issue_topic` | Implemented — `tasks.md` |
| FR-TA-003 | archived topics are absent from `/v1/view/topics` lists, the lobby task read and search; the topic's own read still answers | Implemented — `tasks.md` |
| FR-TA-004 | `GET /v1/view/archived` lists the archived cards the caller may read, newest archived first, each with its reply count and whether the caller may delete | Implemented — `tasks.md` |
| FR-TA-005 | `GET /v1/view/messages/{msg_id}/topic` answers the topic size (replies) for the confirm dialog | Implemented — `tasks.md` |
| FR-TA-006 | `DELETE /v1/messages/{msg_id}/topic` deletes card + children in one transaction; answers the ids removed | Implemented — `tasks.md` |
| FR-TA-007 | live frames `topic_archived` / `topic_deleted` (§3.4) | Implemented — `tasks.md` |
| FR-TA-008 | WUI: a card's menu shows Archive and Delete (Archive icon left of the label) to those §3.3 allows; Delete opens a confirm dialog naming the reply count | Implemented — `tasks.md` |
| FR-TA-009 | WUI: `/archive` view and the left-rail Archive entry (rail entry: CLE-35017, SPL-979) | Implemented — `tasks.md` |
| FR-TA-010 | every new string in all 19 locales | Implemented — `7325032b` |

## 6. Success criteria

- **SC-TA-1**: hub tests on memory + Postgres: archive hides / unarchive restores in every
  list; delete removes card + N children and their deliveries / revisions / reactions /
  kind changes; a non-author member is refused; another tenant's card is 404.
- **SC-TA-2**: live proof in the prd `e2e` tenant and the dev test tenant only:
  archive -> hidden -> unarchive; delete -> the card and N children gone, measured with a
  DB count before and after (`do_spl_db_query`).

<!-- version: 0.1.0 · updated: 2026-09-26 · last-edit: 2026-09-26T20:20:00Z -->
