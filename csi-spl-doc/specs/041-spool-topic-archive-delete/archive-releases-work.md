# What archiving does to the work (SPL-4955)

Addendum to [spec 041](spec.md).

The owner, HUM-10, msg 51465f86, 2026-11-07:

> once the end user has archived a discussion the dispathers must send it to the orchestrator
> to release the lanes used by it , and if there is somethign else to be done to create an
> additional discussion to complete the tasks on the archived discussion if there were any

All of it is code on the box, not a dispatcher's judgement. Refusing human input in an
archived discussion is another lane's work and is not described here.

- **A queued row is not placed.** At take, `do_spl_spawn_place` reads the archive state of
  the row's discussion, else of its `dispatch-<topic8>` or full-id topic
  (`spool lane --archived --topic <id>`, the hub's `lane_op archived` naming a topic). An
  archived one declines the row with the reason `discussion archived: ...`, tells its sender
  and the holder, and takes the next row in the same tick. The sender requeues a row that
  should live on. A failed read places as before, with one WARN; a binary or hub older than
  this ignores the topic and answers lanes with no stamp: placed as before, with one WARN.
- **A placed lane carries its binding.** A launch writes `Ask-Topic: <topic>` into the brief,
  so a brief that names the topic only in prose still binds (t1 2e46fcb6: c-702's brief said
  "t1 topic 2e46fcb6", and the 5-minute run skipped it).
- **A bound lane is released.** `do_spl_archived_seats_free` reads `Ask-Topic:`, then a
  `Task:`, `Topic:` or `Discussion:` line. A line whose value starts with `none`, `n/a`, `na`
  or `no topic` (any case, `**Topic:** None` too) binds no topic, even when it quotes a topic
  later on: "Topic: none live (owner topic 476aff8f archived 11-05)" is a lane with no topic on
  purpose (SPL-5266), and so are "Topic: n/a (was <t8>)" and "Topic: no topic, <t8> archived"
  (SPL-5273). A word that only starts with those letters (`nominal`, `notes`) still binds. A freed lane's open issue goes `onhold`, no longer
  `diss`: it is work left over, not work thrown away. An issue already `done`, `diss` or `qas`
  stays as it is: a hold neither reopens finished or discarded work nor takes it out of review.
- **A seat that answers a whole workspace is never closed by one topic.** Skipped: role seats
  (001-003), a brief whose heading says "standing ... seat", an id seated on desks of 2+
  workspaces, or on a desk box other than this box's own. One desk dir on this box's own desk
  is a plain lane, and is freed.
  The desk walk reads every user's root of the box: a root the cron's user cannot enter (0700) is
  read as its owner, and one it cannot read at all gets a WARN.
- **What is left goes on in one new discussion.** `do_spl_archived_followup` runs in the same
  cron on every box, for topics archived after that box's first run (forward-only). Per topic
  it posts one new discussion in the archived topic's channel, under the dispatch lease holder's
  id, naming the old topic and listing the work; each issue is linked there, then unlinked from
  the old one. `journal.tsv` keeps old -> new, so a crash between the post and the links never
  posts twice. A post that fails sends one blocker to the orchestrator, and is retried every run.
- **A held channel gets no follow-up.** Where nothing may post on its own, the code does not:
  a channel with `no-auto-post` in column 7 of the box map `<spool root>/channel-rules.tsv`, every
  channel of a workspace with a `*` row, a sole seat that is not the holder here, a box whose
  map is missing or unreadable, or a column 7 other than that word, empty or `-`. No post, no
  reply, no link change: one blocker to the orchestrator names the workspace, the topic and what
  was left, once per topic, under its own key in `failed.keys`, so an earlier blocker of the topic
  does not swallow it. The map is
  box-side, never in git: a channel name can be a customer's. A row declined later on such a topic
  stays with its sender and the holder.
- **The map has a named action** (SPL-5146), `do_spl_channel_rule`, never a hand edit. Check, the
  default, reads and changes nothing: `cd csi-spl-orc && ./run -a do_spl_channel_rule`, on each
  box. Exit 0 is fine; 2 is a map that is missing, unreadable or has a bad row; 3 is a stale map:
  older than `CHANNEL_RULE_CHECK_NOT_BEFORE` (default 2026-11-07T05:58:00Z, when the first holds
  were written), holding nothing, or without a hold named in `CHANNEL_RULE_CHECK_WANT`
  (`<tenant> <channel>,...`, from env so that no name reaches git). A map restored with a new
  mtime that still holds something is seen only through `CHANNEL_RULE_CHECK_WANT`.
  `CHANNEL_RULE_CMD=set` writes one row from env, a dry run unless `DRY_RUN=0`.
  It takes `<map>.lock`, the lock of the map's other writer, around the read and the rename,
  waits `CHANNEL_RULE_LOCK_WAIT` seconds (default 30), and exits 1 if the lock is still held. It
  also exits 1, the map unchanged, for a user who could not keep the file's owner: run it as the owner.
  Such a user leaves no lock behind, and `set` opens an existing lock read-only, so a lock of another user does not stop it.
- **A map that cannot be read holds, with an alarm.** Missing or unreadable: every channel reads
  as held, and the log and the blocker say `ALARM`. A map with no row for a channel leaves it
  free. A `*` row without the word in column 7 is malformed, so it holds too.
- **One box posts for a topic.** The holder's box when the hub's roster has the holder's id on
  it in that workspace, else the first such box by name, so every box reads the same answer. A
  box's desk may be under another user's state root, 0700 (measured 2026-11-07 on one box: t1 under the box user's,
  two others only under the agent user's), so the box finds the user whose root holds the live seat (a non-empty `pinned`, not a stub)
  and runs the post, the reply and the links as that user. A desk is seated with the workspace's
  root key, so this run never seats one. No box in the roster
  and no desk here, or no desk on the box the roster names: no post, one blocker, and the run
  stays green.
- **"Unfinished" means** an issue linked to the topic with status `eval`, `todo`, `wip`,
  `blocked` or `onhold`; not archived; not an epic or feature; no `answer` label; title not a
  standing seat's, nor a reviewer seat's (`Seat brief: R7 review ...`, `Lane brief: R7 review ...`:
  the work it reviews has its own issue); every other discussion it links is archived too. Also a
  row declined for the archive in the last hour, bound by its discussion or its topic, in full, as
  8 hex or as `dispatch-<topic8>`. A row declined after the follow-up was posted is added to that
  discussion once (`rows.seen`), answering the archived topic's last human; a topic with no human
  leaves it with its sender and the holder. A workspace's default discussion is never followed up.
  Test workspaces are skipped. A lane kept for uncommitted work is named in the blocker, not listed.

## Requirements

| id | requirement | status |
|---|---|---|
| FR-AW-001 | a queued row whose discussion is archived is declined, not placed; its sender and the holder are told | Implemented — SPL-4955 |
| FR-AW-002 | a lane bound to an archived topic by `Ask-Topic:`, `Task:`, `Topic:` or `Discussion:` is released, its open issue `onhold`; a seat that answers a whole workspace is never closed by one topic | Implemented — SPL-4955 |
| FR-AW-003 | an archived topic with unfinished work gets one new discussion in its channel, listing that work; its issues move there | Implemented — SPL-4955 |

<!-- version: 0.2.0 · updated: 2026-11-07 -->

## The follow-up keeps the priority (SPL-5147)

`do_spl_archived_followup` gives the new discussion the archived one's stored priority, so a queue row re-homed there keeps its place. It calls the agent issue op `inherit-priority` (`spool issue inherit-priority --from <archived> --to <live>`, action `do_spl_topic_inherit_priority`). The caller names no number. The hub copies the row only within one workspace, refuses unless the source is archived and the target live, refuses (`not_followup`) unless the target's opening post names the source as `/t/<source id>`, as the follow-up post does, writes nothing when the source has no row, and keeps a priority the target already has. Any other priority write stays `PUT /v1/topics/{task_id}/priority`, a member session's.

A copy that fails does not stop the move: the issues still go to the follow-up, the run fails, and ONE blocker names it. The archived topic then has no rows left, so the copy is kept in `<state dir>/inherit.pending` and every later run tries it again until it takes. A final refusal (`source_not_archived`, `target_not_live`, `not_followup`) is not kept: its blocker is the record.

## A gone issue and an archived follow-up end the retry (SPL-5244)

A deleted issue is not work left: the read skips an issue with `deleted_at` set, as it skips an archived one. A move the hub refuses `not_found (no such issue)` (the issue was deleted or archived after the read) is final: ONE blocker names it, its key `move:<ref>` goes to `<state dir>/failed.keys`, and later runs skip that issue instead of a WARN every run. A follow-up that was itself archived and followed up is not a move target: `journal.tsv` keeps each hop, so the issues go to the last discussion of that chain (no hub read; a cycle or 20 hops ends the walk), and that later hop takes no priority again, since its own follow-up already copied it. When the chain's last discussion is archived too, the next run follows it up once like any other archive.

## What counts as archived, and when (SPL-5259)

`do_spl_archived_followup` reads "archived" as the hub does (`store.TopicArchived`, the check behind `source_not_archived`): a row of the topic carries `archived_at`. The hub stamps only a topic's opening card (any other message is refused `not_a_card`) or every row of an archived channel, so a reply or a poll card never archives a discussion. An archive is followed up only after it has held `ARCHIVED_FOLLOWUP_SETTLE_MIN` minutes (default 10, at most 1440); the cron runs every 5 minutes, so a follow-up comes 10 to 15 minutes after the archive. A topic put back inside that time is read as live again and gets nothing.

Why: on 2026-11-10 a customer archived the csi-rel topic 637bfd01 at 11:25:18Z (`PUT /v1/messages/<its opening card>/archive`, hub log `topic archive` archived=true) and put it back at 11:25:41Z (`DELETE` on the same card, archived=false). The follow-up had read the archive and posted its new discussion at 11:25:39Z, moving five open issues off a live discussion; the hub then refused the priority copy `source_not_archived`.
