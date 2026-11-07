# Spec 169 T13: the dev rehearsal of a channel move

Run once on 2026-11-07, dev only, SPL-4999. **The rows moved; T13 is not passed: P7
failed one proof (section 3).** The first prd move still waits for it.

## 1. The run

| what | value |
|---|---|
| hub | dev `/version` commit `0b2f05cb1`, version 8.9.2, read just before the run |
| action tree | the move: `2b6d3670e` (lane branch; the seed action is not on master yet). The first seed: `0b2f05cb1` plus the action uncommitted. The repair, a re-seed of the same two workspaces at 16:40:38Z: `6e2fde6f7`, the same patch as `2b6d3670e` before a rebase |
| seed | `ENV=dev DRY_RUN=0 ./run -a do_spl_channel_move_rehearsal_seed`: 3650 posts over 98 topics and 73 threads (171 tasks), 2 blobs, 1 issue |
| from, to | `seed-move-src/rehearsal-move` -> `seed-move-dst`, two throwaway workspaces |
| GO | the owner's own click on dev (biz owner of the operator workspace): answer `9936e762-17d8-4af3-8e42-e00b59b2567d`, form `707c1e61-c93b-4b33-8983-d1c7a98d8c3b` |
| move id | `077a9d72-7ed4-4175-acc8-ad5a8cb520c7` |
| n | 1. No repeat run on this GO |

Before it: `plan` exit 0, no `REFUSE` line. `DRY_RUN=0` with no GO: refused, exit 3 (C15). A
random uuid as the GO: HTTP 403 `go_required`.

## 2. The steps

From `channel_move_steps`, read back:

| step | seconds | what |
|---|---|---|
| P1 | 0.07 | |
| P2 | 1.27 | |
| P2b | 0.00 | no seat, so no probe |
| P3 | 0.36 | 2 blobs copied |
| P4 | 4.42 | 3650 posts; 10 deliveries expired (C28) |
| P5 | 0.00 | no rule row on this box, no lane note |
| P6 | 0.17 | 1 blob deleted, 1 shared blob kept |
| P7 | about 9, from the shell's clock | failed, so it has no `done_at` |

**R3 and the 30 s cap:** P4 at 4.42 s and P7 at about 9 s are under the box's `curl -m 30`, n=1. P4's
cost follows the channel. P7's does not: the scan reads every `<SRC>` row of every table with a text
column and every row of the hub-wide tables, and here `<SRC>` held 5 messages when it ran, so **P7 on
a populated `<SRC>` is not measured**, and the first prd `<SRC>` is populated. P4 ran through the hub; `do_spl_db_query`, on the same DSN secret, logs in
as `spool_hub_rt`, which has TEMP. Its `CREATE TEMP TABLE` and the audit door passed there.

## 3. What failed

`proof scan messages.body 1`. The hit is the seeded staying post `see /t/<moved topic>` in
`rehearsal-stay`. Every other proof printed 0, the shared blob as `known 1 of 1, kept: 5.5`.
`FATAL P7: a proof of section 5 is not 0`; P7 is not done and the journal has no `done_at`.

This is risk R7 measured, n=1, one full link: Q4 leaves such posts in place and lists them (5.4), and
the scan's only known hits are the fleet topic ids (5.2). A channel stops at P7 when a row left in `<SRC>` holds a full task or msg UUID of the set, or the channel's id or name as a whole word, in a column the scan reads; the fleet topic ids are excepted. Row T13b.

Read from the scan and probed by the R7 review on a throwaway local Postgres, not on dev:

| row left after the move | scan |
|---|---|
| post in `<SRC>`, `/t/<full task uuid>` | hit |
| post in `<SRC>`, full msg uuid | hit |
| post in `<SRC>`, `#<channel name>`, no link | hit |
| post in `<SRC>`, 8-hex short id | none |
| post in another workspace, full uuid | none |

**This seed under-reports the hit.** T13's seed wrote `messages.msg` as `{}`, while a real row holds the
body there too (prd t1, 2000 newest messages: 2000 of 2000, read by the dispatch holder), so a real row
would also hit `scan messages.msg`. The action now writes it. The rows on dev keep `{}` (ON CONFLICT),
so the next run purges first.

## 4. The counts

| | messages | in the channel | channel row | issues | reactions | revisions | deliveries |
|---|---|---|---|---|---|---|---|
| `<SRC>` before | 3655 | 3650 | 1 | 1 | 10 | 10 | 11 |
| `<SRC>` after | 5 | 0 | 0 | 0 | 0 | 0 | 1 |
| `<DST>` before | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| `<DST>` after | 3651 | 3650 | 1 | 1 | 10 | 10 | 11, 10 expired |

The 5 left in `<SRC>`: 3 staying posts, a DM and the hub's `public` notice, which it writes to a new
workspace. The issue is `MVD-1` in `<DST>`.

## 5. What this run does not show

- **The old link over HTTP.** The redirect rows exist (1 issue, 3650 msg, 3821 task, to 2026-12-07),
  but the seed workspaces have no member, so no reader followed one. The 3821 are 171 task ids and
  the 3650 msg ids; why the msg ids are also under `task` was not read.
- **A real `<DST>` desk:** the seed has no seat, so P2b sent nothing.
- **Other parts of the set:** Qto docs, hours rows, calendar events, members and invites.
- **The closing step of P7:** `CloseChannelMove` did not run, because P7 failed.
- **The purge:** its DELETE has not run anywhere, and whether `spool_hub_rt` may DELETE on `tenants`
  is not checked. Its test stubs psql and gcloud.

## 6. Other findings

- `KEPT_UNTIL` prints `not read: no date for hub logs`: the shell never sends those days (T8c), so
  every run ends this way and Q3's last date never prints. Row T13c.
- **The seed turned wf 40 red on dev** (runs 42390207479, 42391108808): a new tenant opens a
  `pending` host row and the reconcile read it as a host to add. Fixed in the seed action, which now
  closes the row in its own transaction; the dev rows were repaired at 16:40:38Z by running the action
  again, which is the only dev evidence that a re-seed holds (n=1). The first reconcile after it, run
  42393597501, job `reconcile dev`: `OK nothing to reconcile in dev`, success, no `seed-move` line.

## 7. To clean up

`ENV=dev REHEARSAL_CMD=purge DRY_RUN=0 ./run -a do_spl_channel_move_rehearsal_seed` removes both
workspaces. Not run: the owner's form names them, and T13 runs again after T13b, on the owner's new GO.
