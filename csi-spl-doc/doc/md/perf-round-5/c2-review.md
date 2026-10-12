# Perf round 5 — seat c2 (claude, reviewer)

Seat `c2` reviews `g1` (grok), `m1` (mistral) and `a1` (agy). Doc only.
Tree: `origin/master` at `a78826641`. Every claim about a file below carries
the command that showed it, run from the repo root on that tree (n=1 each,
read-only). No prd query was run by this seat; prd numbers are the proposers'
and are cited as theirs.

Short names: `A=csi-spl-api/src/go/spool-hub-api/internal`,
`R=csi-spl-rdb/src/sql/postgres/spool-hub`.

The one rule this review applies: an action counts only if (1) it is not
landed or dropped already, (2) its site still exists on this tree, and
(3) its gain is measured, or it carries a gate that drops it when the
measurement says no (owner addendum 2: no measured or historical gain = not
worth doing).

## 1. Summary

| seat | AGREE | DISAGREE | note |
|---|---:|---:|---|
| g1 | 8 | 2 | measured on prd insights (24 h, `calls=3572566`), each row with a drop gate |
| m1 | 0 | 10 | every row is the 2026-10-06 plan (`ap-01b..ap-08`) or round 2 (`R2-1`, `R2-2`): landed, dropped or live |
| a1 | 1 | 9 | four rows are dropped `ap-03/06/08/09` items; four have no measurement; one is CI, out of scope |

## 2. Review of g1

1. **5.1 Incremental unanswered sweep: AGREE.** The site is real:
   `sed -n 276,300p csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh`
   shows `WITH k AS MATERIALIZED (SELECT DISTINCT ON (m.tenant_id, m.task_id)`
   over 7 days plus `regexp_replace(left(l.body, 400)...)` in the outer list.
   g1's own split (warm 57 ms, 15 456 buffers, against a 216.81 ms mean,
   n=1473) is the right reading: the cost is pages re-read every minute, not
   the join. Largest single gain on the table (28.3 %). The risk is row
   equality; the hourly full reconcile plus a diff on one prd day is the
   correct gate. Keep g1's section 6 sentence in the plan.
2. **5.2 topic_head_apply_marks add path: AGREE.** `sed -n 300,316p
   $R/0144_topic_heads.sql` shows `topic_head_add` calling
   `topic_head_lock` then `topic_head_rebuild(miss_tn, miss_tk)` on a
   `last_at = '-infinity'` miss. 2 530 applies against 1 343 inserts says many
   are not adds. g1's gate (split add vs rebuild in a rolled-back lab first;
   drop if add-only is under 5 ms) is the right order. Must land before 5.3,
   which also adds to the write path.
3. **5.3 Channel counts as a maintained aggregate: AGREE, gated and
   sequenced after 5.2.** 6 907 × 14.26 ms is still 8.7 %. Against: `e908f41b`
   chose the index-only scan to avoid a drifting counter, and
   `count(DISTINCT from_id)` needs a poster side table. Agree only with g1's
   gate (oracle on insert/expire/delete; drop if the trigger adds > 2 ms to
   the insert), and only measured after 5.2 lands, or the two write-path
   changes cannot be told apart.
4. **5.4 search_sig check off the per-deploy path: AGREE.** `grep -n
   do_spl_search_sig_check .github/workflows/20_hub-build-deploy.yml` -> 627:
   it runs on every hub deploy, which matches 25 calls a day. `sed -n 6,11p
   csi-spl-orc/src/bash/run/spl-search-sig-check.func.sh` names the reason as
   a Postgres-upgrade drift of `hashtext`. A full scan per deploy for a drift
   that only a server-version change can cause is waste: 2.5 s of one of the
   few prd connections each time. Keep the full scan on a version change;
   record the server version the last full check passed on.
5. **5.5 Flow fold unread as one anti-join: AGREE, EXPLAIN first.** 630 ms
   is what a user waits on GET flow (n=51). No plan yet; g1's drop gate
   (correlated subplan is not the time -> drop) is required, as the shape
   only helps if the per-row `archivedHideSQL` dominates.
6. **5.6 DM pointers top-N per arm: AGREE, EXPLAIN first.** `sed -n 10,44p
   $A/store/dm_pointers_postgres.go` confirms no inner `LIMIT` and `env` in
   the materialized rows. One correction for the lane: `grep -n "messages_to "
   $R/0001_hub_core.sql` -> `(tenant_id, to_box, to_id, ts)`, so an inner
   `LIMIT` with `ORDER BY received_at` still reads every heap row of the pair
   to sort it; the gain is not carrying `env` of the whole pair through the
   CTE, not an index stop. If the EXPLAIN shows the heap read, not the sort,
   is the time, the fix needs an index and that is a write cost on
   `messages`; then drop.
7. **5.7 Release-day scalar off the badge: DISAGREE.** `grep -n
   release_notes_released_at $R/0177_flow_v2.sql` -> an index on
   `released_at DESC`, and `sed -n 166,168p $A/store/flow_postgres.go` shows
   the scalar is bounded by the member's `f:seen` mark: an index range of the
   days since the reader last looked, usually zero to a few rows. Likely well
   under g1's own 2 ms drop line, and moving it couples the badge to a
   different route's read. Not worth a lane without the EXPLAIN g1 asks for.
8. **5.8 Issue list omits description: AGREE.** `sed -n 5,6p
   csi-spl-wui/src/pages/issues.vue` -> "The description is only in the
   opened issue." The lane must check the modal path first: `grep -n
   "d.description" csi-spl-wui/src/pages/issues.vue` -> 1449, a draft copy
   that may read the list row. Small (1.6 %), but low risk and a clean
   projection fix.
9. **5.9 Release-note page does not window the whole table: AGREE.** A
   query that grows with every shipped commit, and a page whose keys are
   already limited. Small today (0.8 %), but the cost is unbounded by design;
   equal page contents is the right proof.
10. **5.10 Relay three reads, one batch: DISAGREE.** g1's own against-case
    wins: means 0.04 / 0.09 / 0.28 ms, no screen waits, the 2026-10-06 plan
    dropped this class, and the scans still run. Two saved round trips on a
    background tick are not a measured gain.

## 3. Review of m1

m1's measurement table is the 2026-10-06 baseline, not today's: flow counts
`11,229 × 77.1 ms` is the pre-`0fd227cd9` number (g1 measures 5 140 ×
11.16 ms on the current tree). Every action is landed, dropped or live:

`git log --oneline origin/master | grep -iE 'ap-0[0-9]'` ->
`a8e372341` + `0fd227cd9` (ap-01b), `0576d2cdc` + `4b14b1e77` (ap-02),
`8fc4fd7aa` (ap-04, `0138`), `180849fdf` + `4ebb0deb2` (ap-05), `f7536e327`
(ap-08 dropped), `71a2a4a92` (ap-07 spec 099; heads `on` in prd:
`grep -n SPOOL_HUB_TOPIC_HEADS csi-spl-cnf/csi-spl/prd.env.yaml` -> 290).

1. **Flow counts seek on stored place/time: DISAGREE.** Landed (ap-01a
   `dc271bcc8`, `5cebb1159` with migration `0137`; ap-01b `a8e372341`, then
   `0fd227cd9` 42 -> 4 ms p50). m1's proposed `0136` is already
   `0136_tenant_settings_jsonb.sql` (`ls $R | grep ^013`).
2. **Channel archived lines by mark: DISAGREE.** Landed (ap-02, above).
3. **Messages autovacuum: DISAGREE.** Landed as `0138_messages_autovacuum.sql`.
4. **Server-maintained topic summary: DISAGREE.** Landed (topic heads, spec
   099, flag `on` in prd).
5. **WUI channels GET per PUT: DISAGREE.** Landed (`180849fdf`, proof
   `4ebb0deb2`); also a WUI file, outside an API/DB panel.
6. **Batch Flow event updates in the insert: DISAGREE.** ap-08 lab found no
   insert piece >= 10 ms and dropped it (`f7536e327`).
7. **WS permessage-deflate with context takeover: DISAGREE.** Compression is
   live: `sed -n 221,230p $A/hub/wui.go` -> `CompressionNoContextTakeover`,
   and the comment records why takeover was rejected (+258 MB heap at 200
   sockets against a 512Mi instance).
8. **Reconnect delta `since=<cursor>`: DISAGREE.** Live: `grep -n '"since"'
   $A/hub/view_delta.go` -> 67.
9. **Flow counts scope / plan cache: DISAGREE.** m1's own text: "No A/B
   reproduced a slowdown". No measured gain.
10. **Split archived OR into two probes: DISAGREE.** ap-03 was dropped when
    topic heads replaced the walk; g1 measures the topic-list reads at 92 ×
    44.96 ms and 150 × 23.48 ms, outside the top of total time.

## 4. Review of a1

a1's section 3 correctly lists ap-01a/b, ap-02, ap-04, ap-00 and ap-07 as
done. But its actions re-open four dropped rows, and most rows carry no
measurement of the site they change.

1. **Debounce Flow counts on wakes: DISAGREE.** This is ap-06, dropped: its
   gate (a measured burst of per-member PUTs) was never met, and after
   `0fd227cd9` the badge is 4 ms p50. a1's own numbers (5 882 calls, 24.1 s,
   ~4.1 ms) do not show a burst; g1 lists it under "not worth".
2. **Insert trigger reads `search_tsv` instead of re-parsing: DISAGREE.**
   The change cannot work as written: `sed -n 55,57p
   $R/0135_messages_search_sig.sql` -> "A BEFORE trigger runs before the
   stored search_tsv is computed", and line 35 records why the generated
   form was rejected. The parse runs only for bodies >= 1024 bytes, and the
   ap-08 lab (`f7536e327`) found no insert piece >= 10 ms.
3. **Split the archived OR: DISAGREE.** ap-03, dropped (see m1 #10).
4. **Walk subject via covering index: DISAGREE.** ap-09, folded into spec 099
   (`71a2a4a92`) and dropped with the walk.
5. **Typed structs for WUI frames: AGREE, gated by a bench.** The maps are
   still there: `grep -c 'map\[string\]any' $A/hub/wui.go` -> 7, the message
   frame at `wui.go:989` and the channel frame at `wui.go:1243`. Round 4 G12
   measured the same practice on presence frames at 62.2 us -> 3.4 us and 420
   -> 10 allocs (`grep -n G12 csi-spl-doc/doc/md/perf-round-4-plan.md` -> 46),
   which is the historical evidence the addendum asks for. On `GOMAXPROCS=1`
   the fan-out shares the instance's one P. Gate: a `go test -bench` of the
   message frame encode at 1 / 10 / 50 sockets, n>=6, and byte-identical
   JSON; drop if allocs fall by less than half.
6. **Typed struct for the merge frame: DISAGREE.** a1's own against-case:
   merges are rare; no count given. Fold it into #5's lane only if it is the
   same struct.
7. **FlowFanout pushes deltas: DISAGREE.** 21.31 ms × 310 = 6.6 s a day
   (a1's numbers), and a delta badge drifts whenever a frame is missed: the
   correctness cost exceeds the gain.
8. **`file_count` column for search: DISAGREE.** 6 calls a day (a1's
   number); a schema change on `messages` for a route that is not in the top
   20.
9. **`withoutAgent` slice copy: DISAGREE.** No measurement, and a1's own
   against-case says it is only measurable in massive channels.
10. **Cache CI tool installs: DISAGREE for this panel.** CI, not API or DB.
    Route it to the standing CI seat if wanted.

## 5. What c1 should take from this seat

- Agreed by c2: g1 5.1, 5.2, 5.3 (after 5.2), 5.4, 5.5, 5.6, 5.8, 5.9;
  a1 #5 (typed frames, bench-gated).
- Disputed by c2: g1 5.7 (the scalar is an index range past the reader's
  mark), g1 5.10 (sub-ms, no screen waits).
- Not worth doing, from these three files: every m1 row (landed, dropped or
  live); a1 #1-#4 (ap-06, ap-08, ap-03, ap-09 already dropped; a1 #2 cannot
  work in a BEFORE trigger); a1 #6-#10 (no measured gain, or out of scope).
- Ordering: 5.2 and 5.3 both touch the message write path; one lane each,
  but 5.3's insert measurement runs only after 5.2 is live.
