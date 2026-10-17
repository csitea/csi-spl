# SPL-2230 recovery: deleted fleet_tokens cost lines put back (2026-10-17)

Counts only; the line values stay in the reinsert file on the box that read
them, never in git.

## 1. What happened

The daily cost rollup deleted live `cost_lines` rows of the `fleet_tokens.<box>`
sources for 2026-10-10..10-15 (the cause is fixed in
`spl-cost-rollup-daily.func.sh`, SPL-2230). Step 1 (SPL-2319,
`do_spl_db_pitr_clone`) read a point-in-time clone of the prd hub DB and wrote
a reinsert file: 2,380 INSERT lines (rows absent from live) and 108 UPDATE
lines (rows live but different).

## 2. The owner's go

HUM-10, t1 topic dbf2f39b, msg f0b235c6 (poll c6bf4897): "INS — Put back the
2,380 deleted lines only". Covered: the 2,380 inserts, once, in one
transaction. Not covered: the 108 updates (left as they are), any other write.

## 3. The run

Step 2 (SPL-2395): `do_spl_db_cost_reinsert`
(`csi-spl-orc/src/bash/run/spl-db-cost-reinsert.func.sh`, 3764432fc), run on
the box that holds the file, as the prd project service account, 13:59Z:

- file md5 checked, `rows=2380 dropped_updates=108 skipped=6`
- DRY_RUN=1: `live_keys=0 dup_keys=0 foreign_src=0`
- DRY_RUN=0: `COMMITTED cost_lines=3629->6009 fleet_tokens_lines=2193->4573`

## 4. Verification

Live `fleet_tokens.*` rows (`superseded_by IS NULL`) per day and source, read
with `do_spl_db_query` before and after the run, against the per-day counts the
PITR read found missing:

| day | source | before | missing (PITR) | expected | after |
|---|---|---:|---:|---:|---:|
| 10-10 | fleet_tokens.<box-1> | 24 | 324 | 348 | 348 |
| 10-10 | fleet_tokens.<box-2> | 61 | 560 | 621 | 621 |
| 10-11 | fleet_tokens.<box-1> | 33 | 248 | 281 | 281 |
| 10-11 | fleet_tokens.<box-2> | 77 | 432 | 509 | 509 |
| 10-12 | fleet_tokens.<box-1> | 31 | 172 | 203 | 203 |
| 10-12 | fleet_tokens.<box-2> | 65 | 212 | 277 | 277 |
| 10-13 | fleet_tokens.<box-1> | 50 | 208 | 258 | 258 |
| 10-13 | fleet_tokens.<box-2> | 127 | 172 | 299 | 299 |
| 10-14 | fleet_tokens.<box-1> | 284 | 44 | 328 | 328 |
| 10-14 | fleet_tokens.<box-2> | 254 | 4 | 258 | 258 |
| 10-15 | fleet_tokens.<box-1> | 336 | 0 | 336 | 336 |
| 10-15 | fleet_tokens.<box-2> | 222 | 4 | 226 | 226 |
| | **total** | **1,564** | **2,380** | **3,944** | **3,944** |

12 of 12 rows match; 3,944 equals the clone's fleet_tokens line count for
those days. The 108 rows that differ were not changed.
