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
  `Task:`, `Topic:` or `Discussion:` line. A freed lane's open issue goes `onhold`, no longer
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
  channel of a workspace with a `*` row, a sole seat that is not the holder here, or a box whose
  map is missing or unreadable. No post, no reply, no link change: one blocker to the orchestrator
  names the workspace, the topic and what was left, once per topic (`failed.keys`). The map is
  box-side, never in git: a channel name can be a customer's. A row declined later on such a topic
  stays with its sender and the holder.
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
