# Feature Specification: Archive and Delete a Topic

**Feature ID**: `041-spool-topic-archive-delete` · **Milestone**: M3 · **Status**: Implemented (live dev + prd, `tasks.md` T001–T011); §3.5 (SPL-986) `tasks.md` T012–T016; §7 (SPL-5520) the daily archive suggestion, default off
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
  view) still works: archive hides, and it locks the topic for people only (next point).
- **People add nothing to an archived topic** (owner HUM-10, msg 51465f86, 2026-11-07:
  "the humans should not be able to insert any input anymore to the archived
  discussions"; SPL-4954). The hub refuses a person's post, reply, poll answer and
  attachment (one browser send frame), edit, added emoji, a move or merge into the topic
  the undo of a promote or a merge back into it, a fold, a kind change, a priority, a
  delete of a reply or of the topic, and a merge of the archived topic into another one
  (owner, form a7d9c260, msg f305bf70: "All four: fold, kind change, priority, delete";
  SPL-4993, SPL-4991, SPL-4992) with `topic_archived`, at any depth of the topic. A fold
  checks both rows, since an archived lobby card shares the live lobby task. A delete or
  merge of a whole topic is refused too when a topic below it is archived, and `can_delete`
  answers the same. A task's parent comes from its own opening row, never from a row merged
  in. The WUI shows no composer there, a short line instead, and
  disables a poll. Unarchive lifts it. Contract: `topic-archive-v1.md` section 5.2.
  Archiving a visitor topic ends that visitor's chat from that browser, until unarchive.
- An **agent's** post on an archived topic is stored and delivered as always, and the
  topic stays archived. (Gmail brings a thread back on a new reply; here the owner did not
  ask for it, and an agent reply un-archiving a topic a human put away is the surprise the
  soft delete exists to prevent.) **INFERRED** — say so if you want the Gmail rule.
- **Found again**: the **Archive** entry in the left rail (icon: Material "archive", the
  Gmail glyph) opens `/archive`: every archived card of the tenant the viewer may read,
  newest archived first, each with **Unarchive**. There is no **Delete** here: the owner's
  order above refuses it on an archived topic, so a person unarchives first (SPL-4993).
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

### 3.5 The same menu on every topic list (SPL-986)

The owner, prd t1 topic `8f58f802`, 2026-09-27:

> the same interface should work in the topic's section and not only in the channels or
> direct msgs

A topic ROW is a task, not a message, so the row first finds its card, then offers the
card menu's own Archive (Gmail icon) and Delete (the same confirm, naming the reply
count). Nothing new on the hub: the row uses the §3.3 rule through the hub's own answer.

- **Which card.** When the row's menu opens (right-click, or its ⋯ button), the browser
  reads the task's first readable message and asks `GET /v1/view/messages/{id}/topic`
  (contract §3) for it, then for the task id itself. The row is that card's topic when
  the card opens the row's task, or when it is a lobby card whose message-rooted thread
  IS the row. A thread on a line of some other topic is part of that topic, and its row
  gets no Archive / Delete (that topic's own row has them). The lobby task never does.
- **What is offered** is the hub's `can_archive` / `can_delete` for the caller, never a
  guess from the screen; a member who may not sees Open and Copy link only.
- **After**: the row leaves the Topics list, the Flow list and the Topics home at once,
  a right pane on a deleted task closes, and the `topic_archived` / `topic_deleted`
  frames do the same in every other tab.

Every place a topic is listed:

| where | Archive / Delete | why |
|---|---|---|
| left rail **Topics** section | yes (right-click, ⋯) | the request |
| left rail **Flow**, its topic rows | yes (right-click, ⋯) | the same row, the same menu |
| the Topics home (`/`, the middle list) | yes (right-click, ⋯) | the same list, drawn in the middle |
| new Omnibox topics in the right pane (`BornTopics`) | yes (the card menu) | they are cards |
| channel / DM / lobby cards | yes | SPL-983 |
| search results (`/search`, the topics group) | no — read-only by design | a result list of the query; an archived topic leaves search anyway, and the hit opens the topic, whose card has the menu |
| the event log (`/events`) | no — read-only by design | it lists events (a record), not topics |
| an issue's discussion topic (`/issues`) | no — refused by design | `409 issue_topic` (§3.2): an issue keeps its own lifecycle |
| `/archive` | Unarchive only | §3.1: Delete is refused while archived, so it is reached after Unarchive (SPL-4993) |

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
| FR-TA-008 | WUI: a card's menu shows Archive and Delete (Archive icon left of the label) to those §3.3 allows; Delete opens a confirm dialog naming the reply count. In a topic pane the menu of every stored message, opening card or reply, offers Archive for the whole topic, on the opening card's permission (owner, t1 bb0091f1 msg 83355f04); the left swipe stays on the latest message | Implemented — `tasks.md` |
| FR-TA-009 | WUI: `/archive` view and the left-rail Archive entry (rail entry: CLE-35017, SPL-979) | Implemented — `tasks.md` |
| FR-TA-010 | every new string in all 19 locales | Implemented — `7325032b` |
| FR-TA-011 | WUI: a topic row of the left-rail Topics section, of Flow and of the Topics home offers the card menu's Archive and Delete by right-click and by its ⋯ button, once the hub's `GET …/topic` said the caller may (§3.5) | Implemented — `tasks.md` T012 |
| FR-TA-012 | WUI: an archived / deleted topic leaves those lists at once and on the `topic_archived` / `topic_deleted` frames | Implemented — `tasks.md` T012 |
| FR-TA-013 | no new strings, no hub change: the entries, words, icons, dialog and endpoints are SPL-983's | Implemented — `tasks.md` T012 |
| FR-TA-014 | a person's input to an archived topic is refused by the hub (`topic_archived`); the WUI draws no composer on it and a short line instead; an agent still posts; Unarchive lifts it (SPL-4954) | Implemented — `tasks.md` T016 |

## 6. Success criteria

- **SC-TA-1**: hub tests on memory + Postgres: archive hides / unarchive restores in every
  list; delete removes card + N children and their deliveries / revisions / reactions /
  kind changes; a non-author member is refused; another tenant's card is 404.
- **SC-TA-2**: live proof in the prd `e2e` tenant and the dev test tenant only:
  archive -> hidden -> unarchive; delete -> the card and N children gone, measured with a
  DB count before and after (`do_spl_db_query`).

## 7. The daily archive suggestion (SPL-5520)

csitea topic `48d75e5f`, item 5 of the owner's weekly list (HUM-10 ticked it,
msg `457da676`): "A daily archive suggestion: a topic with its result posted,
no open ask and 24 h quiet gets one archive poll". The evidence, c-518's count
(SPL-5505), not re-measured here: the owner asked to archive or close a topic
9 times.

`cd csi-spl-orc && ./run -a do_spl_topic_archive_suggest`
(`src/bash/run/spl-topic-archive-suggest.func.sh`) runs on the box of the
dispatch lease holder and posts, as the holder's desk agent, ONE poll into a
topic when all three hold:

1. **the topic's last post is an agent's result**, nobody wrote after it:
   kind `result`, or a body that opens with `**Done**`, `**Live**`,
   `**Answered**`, `**Answer**` or a `## Result` heading. A person's
   follow-up after the result keeps the topic (R7 W1);
2. **no open ask names the topic**: no ask in state open, acked, queued,
   placing or needs_owner whose `topic` or `summary` carries its uuid or its
   first 8 hex digits as a whole token (the zombie sweep's rule, spec 166
   row B6);
3. **24 h without a post** (`ARCHIVE_SUGGEST_QUIET_H`), in the hub's list
   and again on the tail read: a post that came in between keeps the topic.

The candidates are the hub's 500 newest idle topic heads,
`GET /v1/operator/zombie-topics?idle_days=1&order=newest&scope=open` (spec
166 row B5: not archived, no DM, not prioritised; `scope=open`, R7 W4: no
topic in `#lobby`, in a member-only, humans-only, AI-off or private-scope
channel, or with a private-scope line, so the desk agent never posts where
it is not invited). `order=newest` is new with this
section: oldest first, the 5000-row list ended at 2026-11-13T00:35Z while its
`idle_before` was 13:55Z (prd, n=1, 2026-11-14): the topics that went quiet
the day before, the ones this rule is for, were cut off. A topic with no post
from a person is no owner topic and gets no poll; the poll is addressed to
the topic's newest person poster.

```text
**Archive suggestion** for topic `<topic8>`: its last post is the result `<result8>`, no ask is open on it and nobody has posted for 24 h.

(poll) Archive this topic?
(A) Archive
(B) Keep (no suggestion for 7 days)
```

The topic and the result in the first line make each poll its own text: the
hub refuses a second box post of the same body to one person within 24 h
(`409 duplicate_to_human`), and one person may get up to 10 polls a day (R7
W2).

- **Archive** (`Answer: A` to that poll, from a person): the topic is
  archived through `do_spl_topic_archive` as the dispatch holder (section 3).
- **Keep** (`Answer: B`): no suggestion for that topic for 7 days
  (`ARCHIVE_SUGGEST_MUTE_D`); after that it may be polled again once a new
  result makes it qualify.
- **Never twice**: the ledger `$SPOOL_ROOT/dispatch/archive-suggest.tsv`
  (append only: topic, state `asked` | `archived` | `keep`, time, poll id,
  tenant; the last row of a topic wins). An asked topic is never polled
  again; an archived one never. A topic whose last post is an archive poll
  is polled already. **The box tail is not the topic** (R7 delta W1):
  `hub-tail` holds only the posts from, to or delivered to this box
  (`BoxTaskEnvelopes`), so an untagged desk reply or poll from another box,
  or a person's post delivered only to another box's seats, is missing from
  it. The hub list carries each topic's real last post
  (`topic_heads.last_msg_id`, field `last_msg_id`); a topic whose box tail
  does not end on it is kept, and so is one the list names no last post for
  (an older hub). The answers have the same limit: a person's `Answer:`
  that reaches only another box is read when it is in this box's tail. One run at a time: the action holds
  `dispatch/archive-suggest.lock` (`flock -n`; a second run, cron or by
  hand, says OK and does nothing). The ledger and the stamp are box-local
  files, so a live run (`DRY_RUN=0`) needs this box to be
  `ARCHIVE_SUGGEST_BOX` (lease.conf or env; unset = no live run) as well as
  the dispatch holder's: while the lease sits on another box, polls and
  answers wait (R7 W3).
- **Cadence**: every run reads the answers of the asked topics (the topic's
  `hub-tail`); the new polls go out once a UTC day (stamp
  `dispatch/archive-suggest.last`, written by `DRY_RUN=0` only, also when a
  poll failed: that topic waits a day, never an hourly retry), at most
  `ARCHIVE_SUGGEST_MAX` (10) of them, newest topic first.
- **Default off**: `DRY_RUN=1` (the default) posts and archives nothing and
  prints the PLAN lines. The cron, `do_spl_topic_archive_suggest_install_cron`
  (hourly at minute 17, `# csi-spl:topic-archive-suggest`, not installed by
  any other action), runs `src/bash/scripts/topic-archive-suggest-cron.sh`,
  which stays dry until the dispatch `lease.conf` says
  `ARCHIVE_SUGGEST_DRY_RUN=0` and names `ARCHIVE_SUGGEST_BOX`: the owner's
  switch.

Test: `csi-spl-orc/src/bash/tests/spl-topic-archive-suggest.tst.sh` (a stub
hub; each condition excludes its topic; one poll per topic; a second run
posts nothing; A archives, B mutes 7 days; red controls: a code variant
without condition 1, 2 or 3, or without the ledger check, polls the topic it
kept; R7 cases 10-12: a follow-up or a young tail keeps the topic, with a red
control; two polls are two texts; a failed poll stamps the day; the lock;
`ARCHIVE_SUGGEST_BOX`; an archive poll last; case 13: a last post the box
tail lacks, or no `last_msg_id`, keeps the topic, with a red control). Hub:
`TestZombieTopicsListsIdleHeads` (`order=newest`, `last_msg_id` = the
latest line, not the card), `TestZombieTopicsOpenScope`
(`scope=open`, red without the filter) and `TestZombieTopicsRefusals` (a bad
`order` or `scope` is 400) in
`csi-spl-api/src/go/spool-hub-api/internal/hub/zombie_topics_test.go`.

<!-- version: 0.3.2 · updated: 2026-11-14 · last-edit: 2026-11-14T23:10:00Z -->
