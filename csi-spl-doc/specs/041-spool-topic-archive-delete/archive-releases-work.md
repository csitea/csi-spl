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
  this answers no stamp, and places as before with no WARN.
- **A placed lane carries its binding.** A launch writes `Ask-Topic: <topic>` into the brief,
  so a brief that names the topic only in prose still binds (t1 2e46fcb6: c-702's brief said
  "t1 topic 2e46fcb6", and the 5-minute run skipped it).
- **A bound lane is released.** `do_spl_archived_seats_free` reads `Ask-Topic:`, then a
  `Task:`, `Topic:` or `Discussion:` line. A freed lane's open issue goes `onhold`, no longer
  `diss`: it is work left over, not work thrown away. An issue already `done` stays `done`.
- **A seat that answers a whole workspace is never closed by one topic.** Skipped: role seats
  (001-003), a brief whose heading says "standing ... seat", an id seated on desks of 2+
  workspaces, or on a desk box other than this box's own. One desk dir on this box's own desk
  is a plain lane, and is freed.
- **What is left goes on in one new discussion.** `do_spl_archived_followup` runs in the same
  cron, on the dispatch lease holder's machine only, for topics archived after that box's first
  run (forward-only). Per topic it posts one new discussion in the archived topic's channel, as
  the holder, naming the old topic and listing the work; each issue is linked there, then
  unlinked from the old one. `journal.tsv` keeps old -> new, so a crash between the post and the
  links never posts twice. A post that fails sends one blocker to the orchestrator, and is
  retried every run.
- **"Unfinished" means** an issue linked to the topic with status `eval`, `todo`, `wip`,
  `blocked` or `onhold`; not archived; not an epic or feature; no `answer` label; title not a
  standing seat's; every other discussion it links is archived too. Also a row declined for the
  archive in the last hour, when the topic has no follow-up yet; a later one reaches only its
  sender and the holder. A workspace's default discussion is never followed up. Test workspaces
  are skipped. A lane kept for uncommitted work is named in the blocker, not listed.

## Requirements

| id | requirement | status |
|---|---|---|
| FR-AW-001 | a queued row whose discussion is archived is declined, not placed; its sender and the holder are told | Implemented — SPL-4955 |
| FR-AW-002 | a lane bound to an archived topic by `Ask-Topic:`, `Task:`, `Topic:` or `Discussion:` is released, its open issue `onhold`; a seat that answers a whole workspace is never closed by one topic | Implemented — SPL-4955 |
| FR-AW-003 | an archived topic with unfinished work gets one new discussion in its channel, listing that work; its issues move there | Implemented — SPL-4955 |

<!-- version: 0.1.0 · updated: 2026-11-07 -->
