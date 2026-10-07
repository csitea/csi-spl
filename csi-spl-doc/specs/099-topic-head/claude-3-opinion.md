# 099 Topic head: panel opinion, seat claude-3 (the test set as the gate)

Seat claude-3, 2026-10-07: is section 7 + `test-results.md` + the harness a
gate that stops a wrong head? Tree: origin/master `ae42081c6` (harness from
`a44a267b4`). Runs: postgres:16-alpine, non-superuser CREATEROLE app role
(`hub-pg.tst.sh` shape), Go 1.25.14; scratch controls from an uncommitted test
file, since removed.

## 1. Verdict

**Accept with changes**: the gate's design is right, but four rules of section 2
have no fixture that can fail them, and the head-read compare cannot pass a
correct head (F2, F3).

## 2. Findings, most severe first

### F1. A first insert into an old topic makes a partial head the backfill then skips (spec 4.2, 8.2)

- Wrong: `topic_head_add` upserts on insert, and "on the topic's first insert
  it also probes the card", that is, it treats the missing head as an empty
  topic. Between the DDL (8.1) and the backfill (8.2) every old topic has no
  head. The first new line in an old topic creates a head with `n = 1`, and
  `topic_head_backfill(500)` "rebuilds the next 500 topics **with no head**",
  so it skips that topic for good: the lobby and every active topic. The
  `rebuild` advisory lock (4.4) does not help; `add` never takes it.
- Evidence: spec 4.2 and 8.2 text (I believe, unchecked: no head code exists).
- Change for v1.0: `topic_head_add` runs `topic_head_rebuild` when its upsert
  INSERTED the head row (a miss) and the topic has another row in `messages`;
  `add` takes the same per-topic lock key as `rebuild` (tenant AND task, so
  two tenants sharing a task uuid never block or mix). Tests:
  `TestTopicHeadInsertIntoTopicWithoutHead` (rows exist, head rows deleted as
  operator to stand for "before DDL", one insert, then diff empty with no
  backfill) and C6 below.

### F2. The head-read compare can never pass a correct head (spec 2, harness:495)

- Wrong: `compareAll` checks `sameRows(head, walk)`, which compares `Kinds`
  as an ORDERED list (`view_topics_test.go:141`). The walk orders kinds by
  `(received_at, msg_id::text)`; a head stores `{kind: n}` (3.2) and cannot
  give that order back. Seed topic A alone is `[task result note]`. The spec
  itself says order does not matter (section 2, `hub/view.go:856` counts into
  a map).
- Change: `sameRowsHead` compares kinds as a multiset (sorted) and all else as
  `sameRows`; T005 adds a hub test that the JSON of `/v1/view/topics` is
  byte-identical in `off` and `on` for the same fixture, which is the real
  contract.

### F3. Four rules of section 2 have no fixture that can fail them

I broke one rule at a time in a copy of `refTopicsSQL` and paged every shape
of the named case (limit 3, walk's cursor), the way `compareAll` does
(n = 1 run each):

| broken rule (copy of ref) | fixture | caught | pages |
|---|---|---|---|
| tie-break `task_id::text ASC` in the LIMIT | E28 | **no** | 357 |
| cursor ignores `task_id` (`last_at < $15`) | E28 | **no** | 357 |
| card rule dropped (`z.msg_id = t.task_id OR`) | E13 | **no** | 300 |
| card rule dropped | E29 | **no** | 308 |
| agent box ignored | E01 | **no** | 314 |
| `first_parent` under the door | E30 | **no** | 314 |
| archived row checks expiry | E23 | yes | 2 |
| no lobby exception | E15 | yes | 73 |
| first line over all rows, not door rows | E26 | yes | 74 |
| expired lines counted | E20 | yes | 2 |
| roots / viewer / parent= / noissues ignored | E01 | yes | 5 / 45 / 1 / 242 |

Why each miss, and the case that fixes it:

- **E28 is vacuous.** T1..T3 are the three newest topics, so page 1 is exactly
  the tie group and no page boundary falls inside it. Change: 5 tied topics
  (limit 3 splits them) and an `expect` that asserts a page ends inside the
  tie. Name: E28 rewritten; control `tie_break_asc`, `cursor_ignores_task`.
- **The card rule is never exercised.** When the card is archived it is still
  in its own topic, so the "any row" rule hides the topic anyway. The card
  rule only matters once the card row has LEFT its topic. New
  `E31 archive a card moved to another topic`: move `b0` into A, archive it:
  B (still holding `b1`) must hide by the card rule alone.
- **Agent box is never exercised**: AGT-1 is always on `box-a`. New
  `E32 the same agent on two boxes` (an AGT-1@box-b line in B).
- **"Roots/parent ignore the door" is never exercised**: every child's first
  line is in a public channel. New `E33 a child topic whose first line is in
  #crew`: for HUM-3, roots must still exclude it.
- Change: add every row above to `TestTopicHeadReferenceControl` with the
  case it needs and **paging** (today the control reads page 1 only), and
  make "each control caught on its case" a hard assertion.

### F4. Writers with no case (the "every writer" claim of 4.1 / test-results 1.2)

`grep -rnE 'UPDATE messages|DELETE FROM messages|INSERT INTO messages'`
over `internal/store/*.go` (non-test) gives 33 lines; over
`csi-spl-orc/src/bash/run/*.func.sh` 6 more. Mapped:

| writer | file:line | case today |
|---|---|---|
| insert | `postgres.go:385` | E01..E03 |
| insert, duplicate resend (`ON CONFLICT DO NOTHING`) | `postgres.go:389` | **none** |
| edit / delete line | `message_edit_postgres.go:129`, `:166` | E04, E05, E16 |
| edit fan-out to DM mirrors | `dm_mirror_postgres.go:87` (`applyEditTx` per copy) | **none** |
| archive / unarchive on mirrors | `dm_mirror_postgres.go:98`, `:102` | **none** (`grep -ci mirror topic_head_harness_test.go` -> 0; test-results 1.2 item 3 says E13 covers them: it runs the call on zero mirror rows) |
| kind | `message_kind_postgres.go:39` | E06 |
| move line / topic, clear home | `message_move_postgres.go:49`, `:55`, `:154` | E07..E09, E11 |
| merge lines | `message_merge_postgres.go:44` | E17 |
| promote / demote | `topic_promote_postgres.go:60`, `:85`, `:95` | E12, E12b |
| merge / unmerge topic | `topic_merge_postgres.go:25..110` | E10, E11 |
| merge re-parents the source's children | `topic_merge_postgres.go:60` | **none** (B has no child, so 0 rows) |
| archive / delete topic | `topic_archive_postgres.go:75`, `:79`, `:161` | E13..E15, E18 |
| delete / archive channel | `channels_postgres.go:114`, `:147` | E19, E29 |
| unarchive channel | `channels_postgres.go:175` | **none** (`grep -c UnarchiveChannel` -> 0) |
| sweep purge | `postgres.go:631` | E24 |
| non-head updates: claim x4, replay env, search_sig | `message_claim_postgres.go:76,89,114,270`, `replay_postgres.go:33`, `postgres.go:655` | T002 one generic `rev` test |
| orc psql: dedup, topic delete, demo wipe, msg wipe, dataset load, search seed | `spl-msg-dedup:102`, `spl-topic-delete:81`, `spl-demo-wipe:137`, `spl-msg-wipe:74`, `spl-public-dataset-load:339`, `spl-search-seed:79` | **none** |
| tenant cascade | FK | E25 (T002) |

Change, new cases: `E34 duplicate resend counts once`, `E35 archive a DM
card with a mirror` (+ `E35b` unarchive), `E36 edit a mirrored line`,
`E37 unarchive a channel` (the undo of E29), `E38 merge a topic that has a
child` (K re-parented: `parent=` moves), `E39 move an archived reply to
another topic` (A shows again, B hides), `E40 two lines of one topic at the
same received_at` (the subject tie-break `msg_id::text`). For the non-head
writers, `TestTopicHeadNonHeadUpdatesKeepRev` names each statement above and
asserts `rev` unchanged. For the orc writers, each existing pg test
(`msg-dedup.tst.sh`, `topic-delete.tst.sh`, `demo-wipe.tst.sh`,
`msg-wipe.tst.sh`) asserts `topic_head_diff` empty after its run once 0138
exists (they write as operator or tenant scope, so they also exercise the
operator WITH CHECK).

v1.0 should also say: a later migration that updates `messages` (as 0042,
0043, 0050, 0132 did) rebuilds every topic it touches, in one statement.

### F5. `topic_head_diff` controls cover three corruptions of ~20 columns (7.1)

- The verify, the daily check (8.6) and every case lean on the diff. Change: `TestTopicHeadDiffDetectsEveryColumn`: for each column of 3.1 and
  3.2, corrupt it on one head (as operator) and assert the diff names that
  topic; plus `missing_head` (a topic with rows and no head),
  `orphan_head` (a head with no rows), `missing_part`, `orphan_part`.
  `TestTopicHeadTriggerControls`: disable each trigger in turn and assert one
  case fails: `ins` -> E01, `upd` -> E07, `del` -> E16 (7.1 names only upd).

### F6. The random test as specified costs ~30 min and does not replay (7.2)

- Cost: every 25 ops the full oracle = ~314 pages (test-results) x ~15 ms =
  ~4.5 s; 20 checks a seed x 20 seeds = ~30 min, before the per-op diff.
  T001 alone took 93 s here (`go test ./internal/store -run TestTopicHead`,
  n = 1, shared 16-core box; test-results: 57 s).
- Replay: picking "a topic" from `f.task` (a Go map) is not deterministic per
  seed. v1.0 must say ops draw from sorted slices only.
- Ops missing from the list: duplicate resend, archive / unarchive channel,
  merge lines, edit the first line, child-topic insert, equal timestamps,
  a mirror pair. Each new E-case should be a random op too.
- Sweep: `Sweep(now)` is global (test-results 1.2 item 4). E24's own sweep at
  `t0 + 1 min` also deletes rows of OTHER packages' tests sharing the DSN
  (`internal/hub` has 30 test files on `SPOOL_TEST_PG_DSN`; whether any holds
  a row expiring that soon is unchecked). Change: random ops purge with the
  sweep's chunk DELETE plus a `tenant_id` predicate (same trigger, same
  500-row chunks); only E24 and C5 call the global `Sweep`.
- Change: default (pre-push) = 4 seeds x 300 ops, diff after every op, the
  oracle on a seeded sample of 16 shapes every 25 ops and the full grid at the
  end; `SPOOL_TEST_LONG=1` = 200 seeds, run nightly, not pre-push.

### F7. Concurrency: C4 can pass without ever retrying; no C for the backfill (7.3)

- C4 "every call ok, or 40P01 and its retry ok" passes when no deadlock ever
  happened. Change: C4 logs the retries seen (n), and `C4b` forces the
  deadlock with two transactions in lockstep (a barrier between their
  statements) and asserts one `40P01` and a successful retry.
- New `C6`: backfill chunks against inserts into topics that have no head
  yet (F1); `C7`: two tenants with the SAME task uuid written at once, each
  head right (lock key and RLS); `C8` (perf, `SPOOL_TEST_PERF=1`): 8 writers
  into one hot topic, insert p95 printed with n (every insert of a topic
  serialises on its head row until commit).

### F8. The insert-cost gate's n cannot carry a p95 (7.5, Q6)

- With n = 20 the p95 is the 19th of 20 values: one checkpoint or GC pause
  decides the gate. The 200k-message seed through `InsertMessage` is
  minutes of setup.
- Change: n >= 200 per arm, interleaved with and without the trigger
  (`ALTER TABLE .. DISABLE TRIGGER` as the owning test role), seed by
  `INSERT .. SELECT generate_series` with triggers off then the backfill;
  gate on the added p50 AND p95, n stated. Add `hot topic` (5 000 lines, 200
  parties: the jsonb row rewrite) and `bulk` (1 000-row `INSERT .. SELECT`,
  the dataset-load path) variants; the sweep chunk gets a ceiling, not a print.

### F9. RLS / runtime role cases miss the statement triggers and the operator writers (7.4)

- The runtime-role case is one INSERT; the UPDATE / DELETE statement triggers
  run only as the owner role. `TestTopicHeadRuntimeRole`: E01, E07, E13, E16,
  E18 as `spool_hub_rt` under tenant scope, diff empty.
- `TestTopicHeadOperatorWrites`: the sweep and an orc-style operator delete
  keep heads right (operator WITH CHECK).
- `TestTopicHeadCrossTenantSameTask`: one task uuid in t1 and t2; a t1 write
  leaves t2's head and `rev` unchanged.

### F10. The switch has no guard against an incomplete backfill (5.1)

- `on` probes only that the table exists. A topic with no head row is simply
  absent from the head read, so `on` before the backfill finished drops topics
  from every list, and shadow would show it only at its 1-in-10 sample.
- Change: a per-tenant "backfilled" mark written by the backfill's last empty
  chunk; the head read serves the walk for a tenant without it. Test:
  `TestTopicHeadReadFallsBackUntilBackfilled`.

### F11. Smaller

- 7.1: `refTopicsSQL` replaces `oracleTopicsSQL` (test-results 1.2.1). Agree.
- 9 (risk "uuid order vs text"): on postgres:16-alpine, collation
  `en_US.utf8`, 200 000 random uuids ordered by `id` and by `id::text` gave
  0 position differences (n = 1 run). The risk row can cite that; E28 (fixed
  per F3) pins it.
- `refTopicsSQL`, read rule by rule against `viewTopicsSQL`
  (`view_postgres.go:193..352`), states the contract right (order key and
  `first_parent` without the door; count, kinds, parties, first line with it;
  archived with no expiry and the lobby exception; the cursor). Its risk is a
  shared misreading with the walk, which F3's controls are for.
- Due heads (5.3) merge with fresh heads under the LIMIT: add `E20p`, a due
  topic that sorts exactly at a page boundary.

## 3. Owner questions

| # | answer | why |
|---|---|---|
| Q1 | **agree: triggers** | F4: six orc psql writers and every future migration write `messages` outside Go; a per-call design misses all of them. |
| Q2 | **agree: exact** | E20..E23 already prove the walk's answer; add E20p (page boundary). |
| Q3 | **change: shadow compares every request** (`SAMPLE=1`) for the 24 h | prd lists n = 446 in 8.4 h (spec 1.1) = ~1 270/day; 1 in 10 is ~127 compares. A defect hitting 2 % of lists escapes 127 compares with p = 0.98^127 = 7.7 %, and 1 270 with p < 1e-11. The head read is the cheap one. |
| Q4 | **agree** | plus the verify (8.3) must print n topics checked and exit 0 before shadow starts. |
| Q5 | **agree** | the harness hook must then route `TaskIDs` to the walk, or that compare is the walk against itself; say so. |
| Q6 | **change the method, keep 5 ms** | F8: n >= 200 interleaved, p50 and p95, hot-topic and bulk variants. |
| Q7 | **agree** | |
| Q8 | **agree** | and the verify runs after every dev DDL deploy, not only daily. |

## 4. tasks.md

1. **Add T001b (now, no product change, before T002):** E28 rewritten; E31..E40
   and E20p; the reference controls of F3 with paging, each a hard assertion;
   `sameRowsHead` (F2). These run against today's walk, so they land green
   before any head exists. T001's text still says "compare with
   oracleTopicsSQL": update it.
2. **T002 gains F1:** `add` rebuilds on a head miss and shares `rebuild`'s
   lock key; `TestTopicHeadInsertIntoTopicWithoutHead`; F5's
   `TestTopicHeadDiffDetectsEveryColumn` belongs here, with the diff function.
3. **Split T003:** T003a diff and trigger controls, RLS, runtime role,
   operator, cross-tenant (fast, pre-push); T003b random + C1..C8 (default
   budget, F6); T003c cost (`SPOOL_TEST_PERF=1`, F8). Budget for the whole 099
   set under `PRE_PUSH_TIER=full`: <= 3 min, stated in the task.
4. **T006 adds** the "backfilled" mark (F10) and the orc pg tests' diff (F4);
   **T007 adds** the nightly `SPOOL_TEST_LONG=1` random run (200 seeds).
5. **T005 depends on** T006's verify printing 0 mismatches on dev, and
   includes `TestTopicHeadReadFallsBackUntilBackfilled` and the byte-identical
   JSON test of F2.
