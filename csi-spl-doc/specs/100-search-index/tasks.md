# 100 Search index: tasks

**Feature**: `csi-spl-doc/specs/100-search-index` | **Spec**: `./spec.md` v1.0
(`20792f7d`, consensus) | **Research**: `./research/` | no `plan.md` (the
spec's section 9 is the plan).
**Build topic**: t1 `#spool-hub-devel` "Spec 100 search index: build",
task_id `0de14fdf-8f03-4390-b0f4-90d11628c536`. Every build lane reports there.
Owner order: t1 2b25c535 ("as it is": section 11 answered by the panel's
recommendations: Q1 S1r with the audited lift, Q2 no external engine, Q5
hold the 512-char signature lane, Q7 a few seconds of SHARE lock is
acceptable, Q4 and Q8 the panel's defaults).

The spec holds the design, the tests (section 6) and the benchmark (section
8). This file is the order. Sections 9 (P0..P5) and 10 (G1..G7) are the
authority; each task names which it closes.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`roles/` = `csi-spl-rdb/src/sql/postgres/spool-hub-roles/`,
`api/` = `csi-spl-api/src/go/spool-hub-api/`, `store/` = `api/internal/store/`,
`hub/` = `api/internal/hub/`, `orc/` = `csi-spl-orc/src/bash/run/`,
`orct/` = `csi-spl-orc/src/bash/tests/`.

Lane kinds: **rdb** (a migration or role file), **store** (Go in `store/`),
**hub** (Go in `hub/`), **test** (tests only, no product change), **ops-read**
(a named action or a run against an env, read-only or rolled back).

## Rules for every task

- One task = one lane: one agent, the files it names, one commit set.
- `do_check_pre_push` before every push and again after the rebase;
  `PRE_PUSH_TIER=full` for every task that touches `rdb/`, `roles/` or
  `store/` (they run on Postgres).
- **GCP-mutating tasks (T002, T014).** Landing an rdb file on master makes
  the next hub deploy (`20_hub-build-deploy.yml`, step "Apply DB migrations
  before rolling") apply it on **dev AND prd**. So such a task is written and
  tested on its lane branch, and is pushed to master **only after the
  owner's explicit go for that file**, relayed by c-001. **Needs owner go.**
- The hub never needs the new objects to start: it probes for the function
  (as `hasSearchSig` probes for the column) and stays on today's path until
  it is there, so hub tasks may land before T002 is applied.
- New Go functions stay under the clean-code gate (80 lines, depth 4,
  8 params).
- Number the rdb file at rebase: the next free one (0140 on `0c6c9e0f`).

## Order

```
T001 P0 dev probe (rolled back) ─► [T003 CONCURRENTLY runner, only if build > a few s] ─► T002 rdb S1r (owner go)
T005 candidate tsquery walk ─────────────────────────────────────────┐
T010 0135 invariant check                                            │
                                     T002 ─► T004 isolation tests T1..T4
                                     T002 ─► T011 rls-check T5
                                     T002 + T005 ─► T006 messages probe + kill switch ─► T007 topics ─► T008 T6/T7/T8 ─► T009 T9/T10 + budget
                                                                                                       └─► T012 P4 benchmark dev, prd (c-001)
                                                                                                             └─► T013 hub drops 0135 path ─► T014 rdb retire 0135 (owner go)
T015 Q3 cold n>=5 on a prd clone (c-001, owner go; optional)
```

## Tasks

### T001 P0: prove S1r on Cloud SQL dev, inside a rolled-back transaction

- Lane: **ops-read**. Closes G1, G6, G7, G2 (dev), G3 (dev). Phase P0.
- Files: `orc/spl-search-index-probe.func.sh` (new, `do_spl_search_index_probe`),
  `orct/spl-search-index-probe.tst.sh` (new).
- What: as the migrate login through the proxy (the `do_spl_db_bootstrap`
  path), in ONE transaction that always ends in `ROLLBACK`: the P1 DDL from
  spec section 9 (role, column grant, policy, `CREATE EXTENSION IF NOT EXISTS
  btree_gin`, `CREATE INDEX ... USING gin (tenant_id, search_tsv)`, the
  function of section 5.1, `ALTER FUNCTION ... OWNER TO spool_search_reader`);
  then `SET LOCAL ROLE` to the runtime login and `EXPLAIN (ANALYZE, BUFFERS)`
  a rare-word `spool_search_candidates` call. Reports: each DDL step ok/error,
  the index build ms, the plan's index name, insert p50/p95 n>=20 with 3 KB
  real-text bodies with and without the index (r3 T7). Refuses `ENV=prd`.
- Done when: the `.tst.sh` is green with a stubbed psql (a `ROLLBACK` is the
  last statement on every path, prd refused); one run on dev by c-001 (the
  transaction is rolled back, so dev ends unchanged; c-001 runs it, owner
  rule "nothing mutates GCP without the owner" covers the run) posts in the
  build topic: btree_gin ok (G6), OWNER TO ok (G7), plan shows
  `messages_search` as the runtime login (G1), build ms (G2), insert p95
  delta (G3 dev). If G6 fails, S1r drops to the tenant-less GIN (spec G6); if
  G1 or G7 fails, the build stops and goes to option B (spec 4.2) for the
  owner.
- Depends on: nothing. GCP-mutating on landing: **no** (an action only).

### T002 P1: rdb S1r: role, policy, btree_gin, GIN, function

- Status: **done** (2026-10-07): `rdb/0143_messages_search_index.sql`;
  owner go on record (t1 0de14fdf msg 7ff43a97).
- Lane: **rdb**. Phase P1. Q1 answered S1r (owner order, "as it is").
- Files: `rdb/0143_messages_search_index.sql` (new; numbered at rebase),
  `roles/runtime-grants.sql` (EXECUTE on `spool_search_candidates` to the
  runtime), `store/search_index_migrate_test.go` (new).
- What: exactly spec section 9 P1 and 5.1: NOLOGIN NOBYPASSRLS
  `spool_search_reader` (precedent rdb 0126); column SELECT on `messages`;
  `CREATE POLICY search_reader_all ON messages FOR SELECT TO
  spool_search_reader USING (true)`, no write grant; `btree_gin`;
  `CREATE INDEX messages_search ON messages USING gin (tenant_id, search_tsv)`;
  the LANGUAGE sql STABLE SECURITY DEFINER `ROWS 200` function with
  `search_path = pg_catalog, public, pg_temp` naming `public.messages`, owned
  by `spool_search_reader`. Plain `CREATE INDEX` (SHARE lock) unless T003
  ran.
- Done when: the file applies twice through `store.Migrate` on local pg16
  (idempotent); `rls_failclosed_test.go` and `crosstenant_test.go` stay
  green; `PRE_PUSH_TIER=full ./run -a do_check_pre_push` green.
- Depends on: T001 green on dev; T003 if T001's build time triggers it.
- GCP-mutating: **YES**. Landing it on master applies it on dev AND prd at
  the next hub deploy. **Needs owner go** (relayed by c-001) before the push
  to master; until then it stays on the lane branch.

### T003 Q7: CONCURRENTLY build path (conditional)

- Status: **not needed** (2026-10-07). T001's dev run by c-001 (2026-10-06
  18:0xZ, rolled back) built the GIN in 2732 ms (G2); x 19 244 / 13 026 that
  is ~4.0 s on prd (c-001 rounded it to ~4.7 s), under the 5 s line. T002
  shipped as a plain `CREATE INDEX`, and rdb 0143 is already applied on dev
  and prd (schema_head 0143, `a94de03c`), so a CONCURRENTLY path has nothing
  left to build.
- Lane: **store** (or **ops-read**, see below). Phase P1, Q7.
- Run ONLY IF T001's dev build time, scaled to prd rows (x 19 244 / 13 026),
  exceeds a few seconds (5 s unless the owner restates Q7). Otherwise mark
  this task "not needed" with T001's number and skip it.
- Files: either `store/migrate.go` (a per-file no-transaction marker: a file
  that carries it runs outside `pgx.BeginFunc`, `grep -n BeginFunc
  store/migrate.go` -> 89) plus `store/migrate_test.go`; or a named action
  `orc/spl-search-index-build.func.sh` + its `orct/*.tst.sh` that runs
  `CREATE INDEX CONCURRENTLY IF NOT EXISTS` before T002 lands. The lane picks
  one and says why in the build topic.
- Done when: a migration with the marker builds `CONCURRENTLY` on local pg16
  and a failed build leaves no INVALID index behind (or the action refuses on
  one); the existing migrate tests stay green.
- Depends on: T001. GCP-mutating on landing: **no** (the runner change alone).

### T004 P3: isolation tests T1..T4

- Status: **done** (2026-10-07): `store/search_index_rls_test.go`, four
  `TestRLSSearchIndex*` (T1..T4), counted by hub-pg.tst.sh's RLS control. T2
  checks door 2 at the store level (the API-level T6 belongs to T006/T008).
- Lane: **test**. Phase P3. Spec 6: T1, T2, T3, T4.
- Files: `store/search_index_rls_test.go` (new), run by
  `csi-spl-api/src/bash/tests/hub-pg.tst.sh` as the runtime login.
- What: seed tenants A and B (a shared word, a word each, a DM between two
  other members). T1 pin (A, B, unset, `''`, operator scope); T2 planted leak
  in a ROLLED-BACK transaction as the migrate login (T1 FAILS, T6 still
  passes); T3 catalogue (policy, FORCE, role flags, no members, one owned
  function, `prosecdef`, `search_path` with `pg_temp` last, `public.messages`
  in the body); T4 runtime not a member, cannot `SET ROLE` / `ALTER` /
  `CREATE OR REPLACE`, and a planted GRANT in a rolled-back transaction turns
  it red.
- Done when: all four pass on local pg16 and in CI; each plant is shown to
  turn its check red (the test asserts it, not a manual run).
- Depends on: T002 (in the tree; may land on its branch until T002 lands).
  GCP-mutating: **no**.

### T005 The candidate tsquery from the AND-chain walk

- Lane: **store**. Spec 5.1 "`q` is built from the AND-chain walk".
- Files: `store/search_postgres.go` (one new function next to `sigAll`, e.g.
  `candidateQuery(root *search.Node) (string, bool)`), `store/search_test.go`.
- What: the root's AND-chain text terms (phrase or not) joined with `&&`, a
  prefix term carries `:*`; never under an Or or a Not; never from
  `Query.Positive`. Returns false for `from:`-only, OR-only, NOT-only roots.
- Done when: a table test covers word, phrase, prefix, AND, `foo OR bar`
  (false), `-foo` (false), `from:x foo` (`foo`), mixed; no DB needed.
- Depends on: nothing. [P] GCP-mutating: **no**.

### T006 P2: messages section through the function, with the kill switch

- Status: **done** (2026-10-07): `candidateProbeSQL` / `searchCandidates` /
  `hasSearchIndex` in `store/search_postgres.go`, `SPOOL_HUB_SEARCH_INDEX` in
  `hub/search.go`; tests green with the switch `on` and `off`.
- Lane: **store** + **hub** (one lane: the switch is read in `hub/`, used in
  `store/`). Phase P2.
- Files: `store/search_postgres.go`, `store/postgres.go` (the probe
  `hasSearchIndex`, as `hasSearchSig`), `hub/search.go`
  (`SPOOL_HUB_SEARCH_INDEX=on|off`, default `on`; `off` = today's path).
- What: spec 5.1: one probe batch per page (`cap = 500`, at most `cap + 1`
  ids); at most `cap` ids -> today's statement plus `AND m.msg_id =
  ANY($ids::uuid[])`; `cap + 1` -> today's statement unchanged; the id filter
  is never applied to a truncated set. Relevance sort ranks the candidates.
  Order, keyset, LIMIT and every predicate stay in the outer statement. No
  function or `off` -> the 0135 path.
- Done when: `store/search_test.go`, `search_sig_test.go`,
  `hub/search_test.go`, `search_paging_pin_test.go`, `search_budget_test.go`
  green with the switch `on` and `off`; a hub test shows `off` never calls
  the function.
- Depends on: T005; T002 in the tree for the Postgres runs.
  GCP-mutating: **no** (the hub probes).

### T007 P2: topics section through the function

- Lane: **store**. Phase P2, spec 5.2.
- Files: `store/search_postgres.go` (`topicCandidates` only).
- What: task ids from the same probe; the per-topic aggregate and the title
  `array_agg` unchanged (spec 099 owns them).
- Done when: `store/search_test.go` topic cases and `search_issue_test.go`
  green with the switch `on` and `off`.
- Depends on: T006 (same file, serial). GCP-mutating: **no**.

### T008 P3: equivalence tests T6, T7, T8

- Lane: **test**. Spec 6: T6, T7, T8.
- Files: `store/crosstenant_test.go` (search cases also on the S1r path),
  `store/search_index_equiv_test.go` (new).
- What: T6 cross-tenant on both paths; T7 every page of every mixed query
  (text with NOT, `from:`, `in:`, `is:`, `has:`), below and above the cap,
  index path == scan path, row for row and in order; T8 every search-v1 form
  incl. `foo OR bar`, also after edit, delete, expiry, archive, move, merge.
- Done when: all green on local pg16 and in CI.
- Depends on: T007, T004. GCP-mutating: **no**.

### T009 P3: plan and size tests T9, T10, and the buffer budget

- Lane: **test**. Spec 6: T9, T10; P3's budget test.
- Files: `store/search_index_perf_test.go` (new, under `SPOOL_TEST_PERF=1`
  like `TestHiddenUnreadBufferBudget`).
- What: T9 two tenants, one 10x the other, the small one's rare-word buffers
  flat; T10 6+ calls in one session: Q-rare uses the GIN every call, Q-common
  returns `cap + 1` and takes the scan path every call; a buffer budget for
  the spec 8 queries seeded with each query's OWN common words (owner lesson
  5).
- Done when: green locally and in the CI perf job; each threshold written as
  a number in the test.
- Depends on: T008 (same seed helpers). GCP-mutating: **no**.

### T010 The 0135 invariant check while 0135 is the fallback

- Lane: **ops-read**. Spec 5.2 last paragraph.
- Files: `orc/spl-search-sig-check.func.sh` (new, `do_spl_search_sig_check`),
  `orct/spl-search-sig-check.tst.sh` (new), one step after "Apply DB
  migrations before rolling" in `.github/workflows/20_hub-build-deploy.yml`.
- What: read-only `SELECT count(*) FROM messages WHERE search_sig IS NOT NULL
  AND search_sig <> spool_search_sig(search_tsv)` per env; exit 1 when > 0.
- Done when: the `.tst.sh` is green with a stubbed psql (0 -> exit 0, 1 ->
  exit 1); one read-only run on dev and prd by c-001 prints 0.
- Depends on: nothing. [P] GCP-mutating: **no** (a read). Removed by T013.

### T011 P3: rls-check T5, one liftable definer only

- Status: **done** (2026-10-07): every SECURITY DEFINER the login can
  EXECUTE is a `liftable` path, except `<current_schema>.spool_search_candidates`.
  The `.tst.sh` runs it on real pg16 (case 7). Dev, read-only, after 0143:
  `liftable=0`, 54/54 tables forced; the one definer there is
  `public.spool_search_candidates` (owner `spool_search_reader`, runtime
  EXECUTE true), so the allow-list is what keeps it at 0.
- Lane: **ops-read**. Spec 6: T5.
- Files: `orc/spl-db-rls-check.func.sh` (allow-list `spool_search_candidates`
  as the one SECURITY DEFINER the runtime may EXECUTE),
  `orct/spl-db-rls-check.tst.sh`.
- Done when: the `.tst.sh` covers "exactly `{spool_search_candidates}`" ->
  not liftable and "a second definer" -> `liftable`; a read-only run on dev
  after T002 is applied reports `liftable=0`.
- Depends on: T002 (applied on dev for the run). GCP-mutating: **no**.

### T012 P4: the prd benchmark, dev then prd (orchestrator)

- Lane: **ops-read**, run by **c-001** (an orchestrator step, not a build
  lane). Phase P4. Closes G3 (prd shape); tunes `cap`.
- Files: `orc/spl-search-measure.func.sh` only if it lacks a spec 8 query
  (Q-zero, Q-rel, Q-prefix): add it with its `.tst.sh` case, as a separate
  small commit.
- What: spec 8, `MEASURE_N=5`, the seven queries, before (switch `off`) and
  after (`on`), buffers primary, per request and per statement; cold runs
  reported apart.
- Done when: the acceptance list of spec 8 is met and posted in the build
  topic with version / tree / n; `cap` kept at 500 or the new value set in
  a one-line hub change with the numbers.
- Depends on: T009, T010, T011, and T002 applied on dev and prd.
  GCP-mutating: **no** (read-only; the switch flip is an env change on the
  hub revision: **needs owner go** on prd).

### T013 P5 (hub half): drop the 0135 read path

- Lane: **store**. Phase P5.
- Files: `store/search_postgres.go` (`sigAll` and its callers),
  `store/postgres.go` (`hasSearchSig`), `store/search_sig_test.go` (deleted
  or reduced), the T010 step in `20_hub-build-deploy.yml` and its action.
- What: the fallback becomes today's plain scan; nothing reads `search_sig`.
- Done when: the store and hub search tests and T004/T008 green; `grep -rn
  search_sig csi-spl-api/src/go` -> 0 outside the migrate tests.
- Depends on: T012 green on prd. **Needs owner go** (P5 is an owner step).
  GCP-mutating: **no** (code only), but it must be deployed on dev AND prd
  before T014 lands.

### T014 P5 (rdb half): retire 0135

- Lane: **rdb**. Phase P5.
- Files: `rdb/01NN_messages_search_sig_drop.sql` (new): drop the trigger,
  `search_sig` and `spool_search_sig` (narrows long rows by 128 B).
- Done when: applies twice on local pg16; store tests green.
- Depends on: T013 deployed on dev and prd.
- GCP-mutating: **YES** (applies on dev AND prd at the next hub deploy).
  **Needs owner go** before the push to master.

### T015 Q3: a true cold n>=5 on a throwaway prd clone (optional)

- Lane: **ops-read**, run by **c-001**. Closes G4.
- Files: none new unless the clone needs a named action
  (`orc/spl-db-clone.func.sh`, create + same-day delete, with its test).
- Done when: spec 8 queries cold n>=5 posted; the clone is deleted the same
  day (`gcloud sql instances list` shows it gone).
- Depends on: T012. GCP-mutating: **YES** (creates and deletes an instance).
  **Needs owner go** (Q3 is pending). Without it, G4 stays open and T012
  reports "first sample after an idle gap" instead.

## Coverage

| task | spec item |
|---|---|
| T001 | P0 |
| T002 (T003 if the build is long) | P1 |
| T005, T006, T007 | P2 |
| T004 (T1..T4), T011 (T5), T008 (T6..T8), T009 (T9, T10, budget) | P3 (T1..T10, budget) |
| T012 | P4 |
| T013, T014 | P5 |
| T010 | 0135 invariant (5.2) |
| T001 | G1 Cloud SQL plan |
| T001 (dev), T003 | G2 build time and lock |
| T001 (dev), T012 (prd shape) | G3 insert cost |
| T015 (owner go, Q3) | G4 true cold n>=5 |
| closed in the spec | G5 B's size |
| T001 | G6 `CREATE EXTENSION btree_gin` |
| T001 | G7 `ALTER FUNCTION ... OWNER TO` |
| T003 (conditional) | Q7 CONCURRENTLY |
