# Spec 169 T13: the dev rehearsal of a channel move

Run twice, dev only. The first run (2026-11-07, SPL-4999) moved the rows and failed one P7
proof (section 3). **The second run (2026-11-18, SPL-5845, after T13b and T13c) passed: P7
printed 0 on every proof (section 8).** n=1 each.

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
the scan's only known hits are the fleet topic ids (5.2). A channel stops at P7 when a row left in `<SRC>`, or in a hub-wide table (one with no `tenant_id`, read unfiltered), holds a full task or msg UUID of the set, or the channel's id or name as a whole word, in a column the scan reads; the fleet topic ids are excepted. Row T13b.

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
- **The purge:** its DELETE has not run anywhere; its test stubs psql and gcloud. `runtime-grants.sql:16`
  grants `spool_hub_rt` DELETE on `tenants`, and a local role given those grants ran a DELETE and the
  close on its own slug (R7 review read, n=1). Dev's real grants are not read.

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
workspaces. Run once on 2026-11-18, before the second run's re-seed (section 8.1). Not run after
it: the second run's form asked only for the GO.

## 8. The second run, 2026-11-18 (SPL-5845)

Dev only, after T13b and T13c (SPL-5010) were built. **P7 printed 0 on all 62 proofs, every step
has its `done_at`, and the move closed.** n=1.

### 8.1 The run

| what | value |
|---|---|
| purge, re-seed, first `plan` | tree `344be1c04`, dev hub `/version` commit `4fdfe4ed2` (2.1.5), as the lane's notes record them. `REHEARSAL_CMD=purge DRY_RUN=0` removed the 11-07 workspaces (read back: 0 tenants, 0 messages, 0 open host rows), then `DRY_RUN=0` seeded 3650 posts again, with every `messages.msg` non-empty |
| the move | tree `3a7ae872b` (master, clean worktree), dev hub `/version` commit `b97a764ff`, version 2.2.8, read just before the run |
| from, to | `seed-move-src/rehearsal-move` -> `seed-move-dst` |
| GO | the owner's own click on dev, as HUM-17 (the dev operator workspace's biz owner): answer `a76d5603-73bd-47b3-9295-4f3dd370868f` at 12:18:23Z, `Answer: GO`, form `9bae380b-ee74-434a-be29-2c3a335dccf5`, topic `68ca7fdb-1aef-49b6-b5d4-ba4f82690633` on dev t1 |
| move id | `263af961-0e70-4a98-ac3a-9572b390cf8d`, 12:19:41Z to 12:20:26Z, 45 s on the shell's clock, exit 0 |
| n | 1. No repeat run on this GO |

Before it: `plan` exit 0, no `REFUSE` line, `PLAN count messages 3650`, one mention (the staying
`see /t/` post). `MOVE_CMD=run DRY_RUN=0` with no `MOVE_GO_MSG`: exit 3 (C15). The random-uuid GO
(403 `go_required`) was not tried again.

### 8.2 The steps

From `channel_move_steps`, read back (`done_at - started_at`):

| step | seconds | what |
|---|---|---|
| P1 | 0.09 | |
| P2 | 1.19 | |
| P2b | 0.00 | no seat, so no probe |
| P3 | 0.37 | 2 blobs copied |
| P4 | 4.46 | 3650 messages, 171 topic heads, 1 issue (`MVS-1` -> `MVD-1`), 10 reactions, 10 revisions and 10 deliveries copied to `<DST>` and deleted in `<SRC>`; the 10 deliveries expired (C28) |
| P5 | 0.00 | no rule row on this box |
| P6 | 0.17 | 1 blob deleted, 1 shared blob kept |
| P7 | 8.53 | every proof 0 |

`channel_move_journal`: `mode` `move`, `go_msg_id` `a76d5603`, `done_at` 12:20:26.64Z.

**R3:** P4 at 4.46 s (first run 4.42 s) and P7 at 8.53 s are under the box's 30 s client cap, n=1.
`<SRC>` again held 5 messages when P7 ran, so **P7 on a populated `<SRC>` is still not measured**.

### 8.3 What T13b and T13c changed

- **T13b:** the staying post that failed the first run is now listed, not a hit:
  `MENTIONS uuid with redirect 1`, post `af1776ef-0ed3-09e0-8bbe-99fc65f499d5`, and
  `proof scan messages.body (known 1 of 1, kept: 5.4) 0`. The seed now writes `messages.msg`, and
  that column's proof finds the same post: `proof scan messages.msg (known 1 of 1, kept: 5.4) 0`.
- **T13c:** the hub logs print their days (`RETENTION hub logs: 30 days (log bucket _Default, read
  back a line of csi-spl-hub-dev)`), so `KEPT_UNTIL` prints a date: `2027-04-17`, from the
  off-project copy of the dumps (150 days).

### 8.4 The counts after

Read with `do_spl_db_query` on dev after the move:

| | messages | in the channel | channel row | issues |
|---|---|---|---|---|
| `<SRC>` after | 5 | 0 | 0 | 0 |
| `<DST>` after | 3651 | 3650 | 1 | 1 |

### 8.5 Still not shown

From section 5: the old link over HTTP, a real `<DST>` desk, the other parts of the set, and P7 on
a populated `<SRC>`. The purge's DELETE has now run once on dev, on the 11-07 workspaces (read
back 0); the workspaces of this run are kept (section 7).

