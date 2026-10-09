# Spec 113: Workspace documents, an outline and a grid over one tree

Version **v1.0** (2026-10-09). v0.1 drafted by seat 1 (agy a-600); v0.2 by
c-605: adds the owner's integrity requirement (section 3), the Perl-to-Go
port (section 6), the one-way markdown export (section 5), and replaces
v0.1's measurement with a committed, rerunnable benchmark (section 2.1).
v1.0 by c-621: folds the 24 changes of review seats 2-5 (all "agree with
changes"; where each landed: section 11) and the owner's answers to Q1 and
Q2 (section 0). The panel agrees, so the build starts (owner rule 10-05).
Build tasks: [tasks.md](tasks.md).

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic d85e7d3c-d584-4114-9bb6-7496de8ee8e0)

| msg | text |
|---|---|
| ad5ae7aa | "qto like support for document editing ..." |
| c81e2686 | "check the /opt/qto project it was a cool project of mine before the days of the ai ..." |
| 7370f63e | "it had the insane idea to implement hierarchy handling with nested set in rdbs and use vue UI with Mojolicious to enable both xls like and doc like views for document editing .." |
| 4e385cf9 | "the answe ris a - because late ron we could generate the files to b level" |
| baad764f | "once YOU get the nested set handling fully working ... frankly said I could not get it work , the hierarchy got always broken , but I am sure YOU can get it working ..." |
| 21240e21 | "I guess you could quickly port the perl api code to the go code .." |

What they decide:

- **The DB is the source of truth** (option (a), 4e385cf9). It supersedes
  spec 075 phase 2's storage (the GCS bucket); 075 phase 1 (repo docs, live)
  stays. Files are generated FROM the DB later (option (b) level), one way
  only: section 5.
- **Hierarchy integrity is THE core requirement** (baad764f). The sibling
  project's tree "got always broken"; this spec is built around never
  breaking it: section 3.
- **Port, do not rewrite from scratch** (21240e21): the hub/store tasks port
  the sibling project's Perl API to Go, inside the integrity work and
  without its bugs: section 6.

v0.2's two open questions, answered by the owner (relayed by the dispatch
lease holder in msg 39185d89) and agreed by every seat:

- **D-Q1 = (a): revision history is an append-only JSONB log** (section 2.3).
- **D-Q2 = (a): printing is standard print CSS**, no headless browser
  (section 4).

## 1. Goals

| # | goal | measured by |
|---|---|---|
| G0 | The tree never breaks: every invariant of section 3.1 holds after every committed transaction | property test 9a + concurrent test 9b green, their controls red; `do_spl_doc_tree_check` prints 0 violations on dev and prd |
| G1 | One rdb table set for doc items per workspace | tenant RLS and isolation test 9e |
| G2 | Two views of the same items: doc view and grid view | e2e 9g, the 160 KB initial-chunk ceiling unchanged |
| G3 | Agents can read/write docs | spool `doc-read` / `doc-write` / `doc-list` verbs + MCP tools (9h) |
| G4 | Files regenerated from the DB, never read back | export test 9f |

## 2. Data model

### 2.1 The measurement

v0.1's table does not hold (c-001's audit): it timed a whole `psql -c`
subprocess (process start + connect, the flat 57-90 ms floor), sent stderr
to /dev/null (a failed statement timed as a success), approximated the
nested-set move, ran n = 1, and its nested-set row is round numbers.

v0.2 measures again, and the script is committed so anyone can rerun it:
[bench/tree-bench.sh](bench/tree-bench.sh) with the three models in
[bench/adj.sql](bench/adj.sql), [bench/lt.sql](bench/lt.sql),
[bench/ns.sql](bench/ns.sql) and the seed in [bench/common.sql](bench/common.sql).

- **Models**, all really implemented, same seed, same ids:
  `adj` = adjacency list + sibling ordinal (`parent_id`, `ord`);
  `lt` = ltree path whose labels ARE the outline number, so path order is
  document order; `ns` = nested set (`lft`, `rgt`) plus `parent_id`, `depth`.
- **Ops**, each ONE function call, under the same per-document lock:
  `insert` a new first child of section 1 (early in the doc: the nested
  set's worst case); `append` a new last child of the last section (its best
  case); `move` the subtree 10.10 to be the first child of section 1;
  `read` the whole subtree of section 1 in document order.
- **Sizes**: fanout 10 at 3 and 4 levels = 1,111 and 11,111 items
  (subtree read = 111 and 1,111 rows).
- **Method**: a throwaway `postgres:16-alpine` container, ONE psql session
  per model, `\timing` around the single call, `ON_ERROR_STOP=1`. Every
  write runs in `BEGIN .. ROLLBACK` then `VACUUM`, so each repetition starts
  from the same tree. After every op, untimed: the model's invariant check,
  and the op's own result check (count, position of the new/moved item,
  md5 of the moved subtree, md5 of the read rows in document order against
  the seed). One warm-up, then **n = 5**; the median is reported.
- **Controls**: per model and size, a planted broken row (a sibling gap, an
  orphaned path, a lft/rgt off by one) must make that model's check fail;
  all 6 were caught (`grep CONTROL bench/raw-2026-10-08.txt`).

**Result**, PostgreSQL 16.15, 16-core box at load average ~12, command
`BENCH_REPS=5 BENCH_CON=pg-s113-c-605 bash tree-bench.sh`, n = 5, median ms
(min..max in [bench/result-2026-10-08.md](bench/result-2026-10-08.md), raw
psql output in [bench/raw-2026-10-08.txt](bench/raw-2026-10-08.txt)):

| model | items | insert (early) | append (end) | move subtree | read subtree |
|---|---:|---:|---:|---:|---:|
| adjacency + ordinal | 1,111 | 0.650 | 0.390 | 1.788 | 1.968 |
| adjacency + ordinal | 11,111 | 0.770 | 0.904 | 0.983 | 5.169 |
| ltree (path = outline no.) | 1,111 | 4.647 | 1.939 | 3.699 | 1.222 |
| ltree (path = outline no.) | 11,111 | 23.362 | 2.206 | 31.785 | 3.172 |
| nested set | 1,111 | 31.257 | 1.125 | 22.515 | 1.036 |
| nested set | 11,111 | 234.422 | 1.218 | 215.527 | 2.180 |

What it shows: the nested set reads fastest but every write early in the
document rewrites lft/rgt of most rows, ~0.02 ms per item (234 ms at 11k),
and grows with the document; ltree pays the same price per following
sibling subtree (23-32 ms at 11k). Adjacency + ordinal writes touch the
siblings of the target parent only: about 1 ms at both sizes, because
fanout 10 keeps every sibling list short.

How to read it (seat 4):

- **Noise.** Load ~12 on 16 cores at n = 5 gives about 1 ms of noise (adj
  move 1.788 ms at 1,111 vs 0.983 ms at 11,111). Differences under 2 ms are
  not ranked; only the 10-200x gaps carry the decision.
- **Wide parents.** The bench fixes fanout at 10. An adj write costs
  O(siblings of the target parent), so one parent with 10,000 flat children
  (a grid's shape) costs what the nested set costs at 11k: seat 4's run of
  `adj.sql` (9257ed1e3, throwaway `postgres:16-alpine`, n = 3, load ~26)
  measured insert-first 218-233 ms and append 3.5-4.2 ms. The bench gains a
  1 x 10,000 case (tasks T000b).
- **Whole-document reads.** The 5 ms read is the subtree of section 1
  (1,111 rows), not a document. A whole document read measured 65-71 ms at
  11,111 items and 852-910 ms at 111,111 (seat 4, n = 3). Print branch and
  `doc-read` of a section are subtree reads; the doc view's first load,
  grid filter/sort, xls export, the export (section 5) and
  `do_spl_doc_tree_check` walk the whole document, hence the size targets
  below and the lazy-loading unit of section 6.

**Size targets** (v1.0; the T002 timing test proves them, section 3.5):
up to **20,000 items per document** and up to **1,000 siblings per
parent**. Beyond them the ops still work but carry no time promise.

### 2.2 Decision: adjacency list + sibling ordinal

Chosen BY the measurement and BY which model passes the property test
(section 3.5) cheaply:

1. **Writes are O(siblings of the target parent)**, independent of the
   document size (not of the parent's width: section 2.1). The nested set's
   O(document) write is what turns one missed shift into a broken tree.
2. **The invariants are mostly plain constraints** (section 3.2): one
   parent each is a single FK column; sibling order is a UNIQUE key. A
   nested set's "no gaps, no overlaps over 2N bounds" cannot be a
   constraint at all, only a full-table scan.
3. **Nothing derived is stored**, so nothing can drift: the outline number
   1 / 1.1 / 1.1.1 is computed at read from the `ord` path (the benchmark's
   recursive CTE). The derived data is the sibling numbering and the export.
   This, not the bench's 23 ms, is the reason against ltree: an id-path
   ltree plus `ord` would write like adj, but its path is still stored
   derived data that can drift from the parent links (seat 4).
4. **The sibling project's UI behaviour stays**: add sibling / parent /
   child, move, delete a branch, print a branch, and the doc + grid views
   map 1:1 onto these ops (section 4).

Schema (T001):

- `workspace_doc` (id, tenant_id, workspace_id, title, rev, timestamps):
  the document header; its row is the per-document lock (section 3.3).
  UNIQUE (tenant_id, id), the target of the item's tenant-carrying FK.
- `workspace_doc_item` (id, tenant_id, doc_id, parent_id, ord, title, body,
  attrs jsonb, rev, timestamps). Every document has ONE hidden root item;
  the top-level sections are its children, so numbering starts at 1.
- **Composite FKs carry the tenant, because FK checks bypass RLS.** Seat 5
  measured (n = 1) a tenant-a session that sees 0 of tenant b's docs and
  still committed an item with `tenant_id = 'a'` and tenant b's `doc_id`.
  So: FK (tenant_id, doc_id) -> workspace_doc (tenant_id, id); the parent
  FK is (tenant_id, doc_id, parent_id) -> workspace_doc_item (tenant_id,
  doc_id, id) ON DELETE RESTRICT, which needs UNIQUE (tenant_id, doc_id,
  id) on the item. Each document then has exactly one tenant, and the
  trigger sees the whole document under RLS.
- Tenant RLS on all three tables: ENABLE **and FORCE** ROW LEVEL SECURITY,
  the repo's `NULLIF` tenant policy plus the `operator_scope` policy, in the
  0107 migration's shape. Without FORCE the owning role sees every tenant.
  The store reaches the tables only through `inTenant` / `asOperator`.
- `workspace_doc_rev_log`: section 2.3.

### 2.3 Decision D-Q1: revision history is an append-only JSONB log

- `workspace_doc_rev_log` (tenant_id, doc_id, rev, op jsonb, actor,
  created_at), UNIQUE (doc_id, rev), the same composite tenant FK and RLS as
  section 2.2. Append-only: no UPDATE or DELETE path in the store, and the
  role has neither grant.
- Each entry is written in the SAME transaction as the `workspace_doc.rev`
  bump it records, and carries the rev it produced and the op: kind, item
  id, from parent + ord, to parent + ord (and for a text edit the field and
  the item rev).
- So a rev can be audited and replayed: the log is the commit order the
  concurrent test replays (section 3.5) and the trail `do_spl_doc_tree_repair`
  cites (section 3.4).

## 3. Hierarchy integrity (the core requirement)

### 3.1 Invariants

For every document D:

| # | invariant |
|---|---|
| I1 | D has exactly one root item (parent_id NULL, ord 1) |
| I2 | every other item has exactly one parent, and it is in D (and in D's tenant) |
| I3 | every item is reachable from the root: no cycle, no orphan |
| I4 | the children of each item are numbered 1..k: no gap, no overlap |
| I5 | siblings are totally ordered by ord (follows from I4) |
| I6 | the outline number of each item is unique in D and derived from I1-I5, never stored |

### 3.2 Checked in the DB

| inv | how |
|---|---|
| I1 at most one | partial unique index on (doc_id) WHERE parent_id IS NULL; CHECK (parent_id IS NOT NULL OR ord = 1) |
| I1 at least one | a DEFERRABLE INITIALLY DEFERRED constraint trigger on `workspace_doc` AFTER INSERT: at commit the document has its root; `DocItemDeleteSubtree` refuses the root (section 3.3) |
| I2 | parent_id is ONE column; the tenant-carrying composite FK of section 2.2, ON DELETE RESTRICT |
| I4 overlap | UNIQUE (doc_id, parent_id, ord) DEFERRABLE INITIALLY IMMEDIATE; CHECK (ord >= 1). The same key is the child-lookup index (children of a parent in order, `max(ord)`) |
| I3, I4 gap | a DEFERRABLE INITIALLY DEFERRED constraint trigger on `workspace_doc_item` (below) |
| all | `do_spl_doc_tree_check` (section 3.4): the full check of I1-I6 on demand |

The item trigger:

- **Events**: AFTER INSERT, UPDATE OF (parent_id, ord, doc_id), DELETE.
- **First statement: `SELECT 1 FROM workspace_doc WHERE id = <doc> FOR
  UPDATE`.** The deferred check alone is not race-proof: each commit checks
  under its own snapshot, so two writers that skip the doc lock each see a
  whole sibling list and both commit a gap. Seat 5's repro: tx1 deletes ord
  3 of 3 and runs the check; tx2 appends at `count(*)+1` = 4 and commits;
  tx1 commits. Without the lock 3 of 3 runs committed `1,2,4`; with the
  lock as the trigger's first statement 3 of 3 refused tx2 ("I4 gap"). It
  is a no-op when the op already holds the lock. The store runs READ
  COMMITTED, so the statement after the wait gets a fresh snapshot (under
  REPEATABLE READ it would be a serialization failure to retry). The DB,
  not the store's discipline, then enforces I3/I4.
- **Checks the parent of OLD and of NEW.** A move or a delete leaves its
  gap under OLD.parent_id, so an INSERT/UPDATE-only, NEW-only trigger
  misses the planted gap-skipping delete. For each touched parent: either
  it has no children (count = 0 is valid: deleting a parent's last child
  must pass, seat 2), or min(ord) = 1 and max(ord) = count.
- **Refuses any change of `doc_id`.**
- **On UPDATE OF parent_id**, a bounded walk from the moved item up to the
  root: reaching the item itself, or exceeding the document's item count,
  is a cycle (I3).
- **Once per (doc, parent) per transaction.** A row trigger fires once per
  shifted row, so a k-sibling shift would check the same parent k times,
  O(k^2) at commit (10^8 row visits at 1 x 10,000). All deferred fires run
  after the last write, so the first fire per (doc, parent) already sees the
  final state; repeats are skipped with a transaction-local key. Its cost is
  timed by the T002 timing test (section 3.5).

### 3.3 Every structural op is ONE transaction under a per-document lock

add sibling / add parent / add child, move (incl. indent / outdent and
reorder), delete subtree: each is one store function, one transaction:

1. `SELECT ... FROM workspace_doc WHERE id = $doc FOR UPDATE` (the lock;
   tenant-scoped through RLS, unlike a cluster-wide advisory lock). The
   store requires **exactly 1 row**: on another tenant's doc RLS returns 0
   rows and no error (seat 5, measured), so 0 rows is a 404 and a rollback,
   never a continue-unlocked.
2. read the positions it needs AFTER the lock, never before it. An append
   position is `max(ord) + 1` from the `(doc_id, parent_id, ord)` index (one
   probe on a wide parent), never `count(*)`.
3. the sibling shifts and the row writes. A shift is ONE statement (the
   deferrable UNIQUE is checked at statement end) or runs under `SET
   CONSTRAINTS .. DEFERRED`; there is no `ord = -1` parking, which the CHECK
   (ord >= 1) forbids. The bench's `adj_move` parks at -1; it is not the
   code to copy.
4. bump `workspace_doc.rev`, append the section 2.3 log entry; commit,
   which runs the deferred triggers.

The op-specific refusals, each before any write:

- `DocItemMove` refuses a target parent inside the moved item's own
  subtree, the item itself included (cycle prevention, I3); the trigger's
  walk is the DB backstop.
- `DocItemDeleteSubtree` refuses the root (I1).

**Lock order.** Every path locks the doc row before any item row. A
caller that runs several ops in one transaction (T005's import) takes the
doc lock once at the top; the nested op calls reuse it.

**Text edits** (title, body, attrs, one grid cell) do not change the
structure: `UPDATE .. WHERE id = $id AND rev = $rev` under the row lock,
bumping the item's `rev`, not the document lock. 0 rows updated is a 404
when the row is gone (a concurrent delete subtree) and a 412 when only the
rev differs; never a 200.

**Outcomes.** Every op ends as exactly one of: **committed** (it returns the
`workspace_doc.rev` it produced, unique per doc), **412** (stale
`workspace_doc.rev` on a structural op, stale item `rev` on a text edit),
**404** (doc or item gone, or another tenant's), **refused** (a move into
its own subtree, a delete of the root).

### 3.4 `do_spl_doc_tree_check` and `do_spl_doc_tree_repair`

- `./run -a do_spl_doc_tree_check` (csi-spl-orc, `DOC_ID=` optional, every
  doc by default, read-only, as the per-env SA): sets `app.rls_scope =
  operator` (an RLS-scoped run sees 0 docs and would print a false
  `violations=0`), runs the I1-I6 queries and prints one line per violation
  plus `violations=<n> docs=<n> items=<n>`; exit 1 when n > 0, **exit 2 on
  `docs=0`** unless `EXPECT_EMPTY=1`.
- `./run -a do_spl_doc_tree_repair` (`DOC_ID=` required, dry run unless
  `DRY_RUN=0`): ONE transaction under the doc lock, so it serializes with
  live ops and passes the deferred triggers. Rebuilds the derived fields
  from the parent links: renumbers each item's children 1..k in their
  current (ord, id) order; cuts an unreachable cycle at its smallest id and
  re-attaches that item at the end of the root; re-attaches any other
  unreachable item there too (ids printed); writes a `repair` entry in the
  section 2.3 log; then runs the check. Prints `renumbered=<n>
  reattached=<n>` and the check's line. `DRY_RUN=0` on prd is an owner go
  (repo rule).

### 3.5 The property test

- A Go test against Postgres (testkit), never against the memory store:
  thousands of random sequences of add sibling / parent / child, move
  (anywhere, incl. into its own subtree, which must be refused), delete
  subtree, per seed; the full invariant check AND a comparison with an
  in-memory model tree after EVERY step.
- **Concurrent writers**: N goroutines on N connections on one document,
  mixing text edits, moves and delete subtree. Writers re-read the rev and
  retry on 412. The check runs after each committed op and at the end.
  "No lost op" means every committed op's effect is in the final tree: the
  model applies the committed ops in rev order (the section 2.3 log) and is
  compared after the run. The test prints the committed / 412 / 404 /
  refused counts, the lock-wait count and the `deadlock_detected` count;
  it **fails on 0 lock waits** (a run without contention proves nothing)
  and on any deadlock.
- **Timing of the real ops** (the bench has no `tenant_id`/`doc_id`, no
  RLS, no deferred trigger and an advisory lock): on testkit Postgres the
  test times add (first / last child), move subtree, delete subtree and a
  subtree read at 11,111 items (fanout 10), at 1 x 1,000 siblings and at
  1 x 10,000 siblings, n = 5, prints median and max per op, and fails above
  the ceilings: **50 ms** per op at 11,111 items and at 1 x 1,000 siblings
  (the size targets of section 2.1); the 1 x 10,000 case is printed, not
  gated.
- Controls, each a planted bug behind a test-only switch that must turn the
  test red: a delete that skips closing the sibling gap; a move that reads
  positions before the lock; a store that ignores the lock's row count.
- The seed of a failing run is printed so it replays.

### 3.6 What the sibling project's code does, and v1.0 does not copy

Read on this box, read-only, 2026-10-08 (the DB writer's hierarchical
insert ~l.291-422 and delete ~l.203-290, its SQL test hierarchy table).
The nine defects, each with what avoids it here:

| # | defect in the sibling | avoided by |
|---|---|---|
| D1 | no parent link: the parent is guessed from `level` and `min(rgt)` | `parent_id` column + FK (2.2, 3.2 I2) |
| D2 | one insert branch writes a leaf of width 4 (`lft = parentRgt-1`, `rgt = parentRgt+2`), which breaks the nested set at once | no lft/rgt; ord shifts checked by UNIQUE + deferred trigger (3.2) |
| D3 | its own seeded test hierarchy breaks the invariants (the root and the last top-level item share `rgt = 23`) | property test after every step (3.5), check action (3.4) |
| D4 | no lock: two writers read the same `lft` and both shift | doc row `FOR UPDATE` in the op and in the trigger (3.2, 3.3) |
| D5 | every insert renumbers a document-wide `seq` | outline number derived at read, never stored (2.2 reason 3, I6) |
| D6 | errors swallowed (an `eval` and a check of the driver's error string) | every op ends in one of four outcomes (3.3) |
| D7 | SQL built by string interpolation of table names and ids | pgx bind parameters; text edits allow-list the column (T002) |
| D8 | ids from a seconds timestamp (two inserts in one second collide) | DB-generated ids |
| D9 | `level`, `seq`, `lft`, `rgt` all nullable, no constraint at all | NOT NULL + CHECK + UNIQUE + FK (3.2) |

## 4. Two views of the same items

- **Doc view**: an outline numbered 1 / 1.1 / 1.1.1, edited in place.
  Context menu: add sibling / parent / child, move (drag, indent, outdent),
  delete branch, print branch.
- **Grid view**: spreadsheet-like rows (outline number, title, body,
  attrs columns), inline edit, filter, sort; structure ops from the row menu.
- **Print (D-Q2)**: print branch is one subtree read rendered with standard
  print CSS by the browser; no server-side renderer and nothing new on the
  integrity path.
- Both are WUI views of the same items; every edit goes through the
  section 3.3 ops, so neither view can break the tree.

## 5. Phase 2: one-way export, DB -> markdown

- Output only. A document is written as markdown whose layout mirrors the
  outline: an item with children is a directory `<n>-<slug>/` with an
  `index.md`, a leaf is `<n>-<slug>.md`, n = its outline number.
- Targets: the per-workspace bucket (the spec 075 phase 2 bucket becomes
  the export's target) and/or a zip download / a repo commit.
- Regenerated on change: after ANY committed write to the document (a
  structural op that bumps `workspace_doc.rev`, or a text edit that only
  bumps an item `rev`), a debounced job writes the export. Text edits do not
  bump the doc rev, so a doc-rev-only trigger would never re-export an
  edited body.
- The export reads the document, its `rev` and the highest item `rev` in
  ONE REPEATABLE READ snapshot, so the header matches the content.
- Never edited back: every file carries a "generated from the DB, doc rev
  <n>, item rev <m>, do not edit" header; no code path reads the export into
  the DB.

## 6. Hub API: port of the sibling project's Perl API to Go

The hub/store tasks PORT the sibling project's Perl API into
`internal/store` (pgx, under RLS) and `internal/hub`, inside the section 3
rules: the hierarchical insert, the delete, the single-column update, the
branch reader, the doc-view and grid controllers, the xls import/export.
[tasks.md](tasks.md) names which routine each Go task ports. The port keeps
the behaviour (which ops exist, what the views show), not the storage: the
nested-set arithmetic is replaced by the section 2.2 model.

- **Lazy loading**: the unit is the children of one expanded node plus its
  ancestors' `ord` path (seat 4 at 11,111 items: 0.4-1.2 ms for the
  children, 0.9 ms for the walk up). Never offset pages over the flattened
  recursive CTE: every page would pay the whole O(doc) walk. The initial
  chunk stays inside its 160 KB ceiling.
- **Grid sort / filter over a whole document** is a whole-document read;
  it is served up to the 20,000-item target of section 2.1 and refused with
  a 413 above it.
- **Concurrency**: section 3.3; its four outcomes; a 412 on a stale `rev`.
- **Search**: indexed per spec 100.
- **Topic link**: topic <-> doc discussion link per spec 075 T015/T016.

## 7. Agents

Spool verbs `doc-read`, `doc-write`, `doc-list`; MCP tools wrap them
(spec 075 T009). `doc-write` runs the same section 3.3 ops.

## 8. Rules

- Distribution hygiene: no literal domains, hosts, or personal names; read
  `BASE_DOMAIN` / the cnf. The sibling project is cited as "a sibling
  project", never by its names, paths or hosts.
- CSP strict; i18n per the repo language rule (agy reviews multilingual
  text last); dark and light themes.

## 9. Tests

| # | test | control | n |
|---|---|---|---|
| a | property test: random add/move/delete, invariants + model tree after every step (Postgres) | planted gap-skipping delete turns it red | >= 5,000 ops x 5 seeds |
| b | concurrent writers on one document, mixed text edits / moves / delete subtree; prints committed / 412 / 404 / refused, lock waits, deadlocks; replays the rev log into the model | planted read-before-lock move turns it red; 0 lock waits fails; a store ignoring the lock's row count turns it red | 8 writers x 500 ops |
| c | constraint + deferred triggers refuse a gap (incl. one left under OLD.parent_id by a delete), an overlap, a cycle, a second root, a doc without a root, a `doc_id` change; deleting a last child passes | the same writes with the trigger dropped commit; a raw-SQL writer that skips the doc lock is refused at commit | 1 per invariant |
| d | `do_spl_doc_tree_check` / `_repair` on a corrupted copy (incl. an unreachable cycle) | a clean doc prints violations=0; an unscoped check exits 2 | 1 per invariant |
| e | tenant RLS: a cross-workspace read returns 0 rows; a cross-tenant `doc_id` / `parent_id` insert is refused; `FOR UPDATE` on a foreign doc returns 0 rows -> 404 | the same read in-tenant returns the rows; the in-tenant `FOR UPDATE` returns exactly 1 row | 1 each |
| f | export: layout mirrors the outline, regenerated on any committed write (structural or text) | an edit of an exported file is not read back | 1 doc, 3 levels |
| g | WUI: doc and grid views lazy (one node's children per load), edits through the ops | initial JS delta > 100 B fails | 1 |
| h | `doc-read` / `doc-write` / `doc-list` verbs work | an unauthenticated request fails | 1 |
| i | timing of the real ops (3.5) at 11,111 items, 1 x 1,000 and 1 x 10,000 siblings | an op over its 50 ms ceiling fails | n = 5 per op and size |

## 10. Review seats

Seat 1 (agy a-600) wrote v0.1. Seats 2-5 reviewed v0.2 at 9257ed1e3; the
changes are numbered as each seat wrote them, and section 11 says where each
landed in v1.0.

| seat | agent | verdict | changes & answers |
|---|---|---|---|
| 2 | a-617 (agy) | agree with changes | 1. Section 3.2 (I3, I4 gap check): Clarify that the deferred trigger must handle `count = 0` (no children) so deleting a parent's last child does not fail the `min=1` condition.<br><br>Answers:<br>Q1: (a) Append-only JSONB log (keeps structure simple).<br>Q2: (a) Standard print CSS (avoids the heavy operational burden of headless browsers). |
| 3 | m-618 (mistral) | agree with changes | 1. Clarify T002's `DocItemMove`: add a note that it refuses moves into a subtree of the moved item (cycle prevention, I3).<br>2. Explicitly list the 9 avoided defects in section 3.6 for auditability.<br>3. Recommend Q1 (a) and Q2 (a): append-only JSONB log and print CSS.<br><br>Perl ports (T002/T004/T005): the spec's adjacency + ordinal model avoids all 9 defects of the sibling project (section 3.6) by design. The port preserves behavior while fixing concurrency (per-document lock) and adding revision control (412 on stale `rev`).<br><br>Answers:<br>Q1: (a) append-only JSONB log.<br>Q2: (a) print CSS. |
| 4 | c-619 (claude) | agree with changes | Angle: the tree model and its evidence. Adjacency + ordinal stands: its worst case below is the nested set's typical case. Extra numbers: my run of `adj.sql` unchanged at 9257ed1e3 in a throwaway `postgres:16-alpine`, n = 3, box load ~26.<br>1. Sections 2.1/2.2: the bench fixes fanout at 10, so "flat in the document size" holds only for narrow parents. A write costs O(siblings of the target parent). One parent with 10,000 flat children (a grid's shape): insert first 218-233 ms, the nested set's 11k cost; append 3.5-4.2 ms. Write "O(siblings of the target parent)", state the target sizes (items per doc, max siblings per parent) and add a 1 x 10,000 case to `tree-bench.sh`.<br>2. Section 2.1 "read": the 5 ms reads the subtree of section 1 (1,111 rows), not a document. Whole document: 65-71 ms at 11,111 items, 852-910 ms at 111,111. Fine for print branch and `doc-read` of a section. The doc view, grid filter/sort, xls export, the export and `do_spl_doc_tree_check` walk the whole document.<br>3. Section 6 "Lazy loading": define the unit as the children of one expanded node plus its ancestors' `ord` path. At 11,111 items: 0.4-1.2 ms for the children, 0.9 ms for the walk up. Never offset pages over the flattened recursive CTE, because every page pays the whole O(doc) walk. A grid sort/filter over a whole document needs a stated size limit.<br>4. Section 2.1: load ~12 on 16 cores at n = 5 gives about 1 ms of noise (adj move 1.788 ms at 1,111 vs 0.983 ms at 11,111). Say that differences under 2 ms are not ranked and only the 10-200x gaps carry the decision.<br>5. Section 2.2 vs ltree: the bench's ltree uses path = outline number, which forces renumbering. An id-path ltree plus `ord` would write like adj. Rest the decision against ltree on reason 3 (the path is stored derived data that can drift), not on the 23 ms.<br>6. T002: the bench has no `tenant_id`/`doc_id`, no RLS, no deferred trigger, and an advisory lock instead of `FOR UPDATE`. Make the store test time the real ops on testkit Postgres at 11,111 items and at 1 x 1,000 siblings, print the times, and fail above a stated ceiling. Section 3.2: say that `UNIQUE (doc_id, parent_id, ord)` is also the child-lookup index.<br>7. Section 3.3 step 2: take the append position as `max(ord) + 1` from that index, not `count(*)` (adj_insert's clamp), so an append to a wide parent is one index probe.<br><br>Answers:<br>Q1: (a) append-only JSONB log. Each entry carries the `workspace_doc.rev` it produced and the op (kind, item id, from/to parent + ord), so a rev can be audited and replayed.<br>Q2: (a) print CSS. Print branch is one subtree read (~5 ms at 1,111 rows), so no server-side renderer is needed. |
| 5 | c-620 (claude) | agree with changes | Angle: integrity under concurrency, invariants I1-I6 and RLS. The design holds (one transaction per op, the doc row as the lock, a deferred check). Five gaps below let a tree or a tenant break anyway. Measured at 9257ed1e3 in a throwaway `postgres:16-alpine` (16.x), RLS-forced tables in the 0107 shape.<br>1. **Section 3.2: the deferred trigger is not race-proof alone (measured).** Each commit checks under its own snapshot, so two writers that skip the doc lock each see a whole sibling list and both commit a gap. Repro: tx1 deletes ord 3 of 3 and runs the check; tx2 appends at `count(*)+1` = 4 and commits; tx1 commits. Without the lock: 3 of 3 runs committed `1,2,4`. With `SELECT 1 FROM workspace_doc WHERE id = doc FOR UPDATE` as the trigger's first statement: 3 of 3 refused tx2 ("I4 gap"). Change: the trigger takes the doc row lock itself (a no-op when the op holds it). These transactions run READ COMMITTED, so the statement after the wait gets a fresh snapshot. Under REPEATABLE READ it is a serialization failure the store retries; say which. Then the DB, not the store's discipline, enforces I3/I4. 9c control: a raw-SQL writer that skips the lock is refused at commit.<br>2. **Section 2.2: FK checks bypass RLS (measured, n = 1).** A tenant-a session sees 0 of tenant b's `doc` rows. It still inserted and committed an item with `tenant_id = 'a'` and tenant b's `doc_id`. Change: composite FKs that carry the tenant. `workspace_doc` gets UNIQUE (tenant_id, id); the item gets FK (tenant_id, doc_id) -> workspace_doc (tenant_id, id); the parent FK becomes (tenant_id, doc_id, parent_id) -> item (tenant_id, doc_id, id). Each document then has one tenant, so the trigger sees all of the document under RLS. 9e control: a cross-tenant `doc_id` insert is refused.<br>3. **Section 3.3 step 1: a lock on another tenant's doc returns 0 rows, no error (measured).** The store requires exactly 1 row from the `FOR UPDATE`; otherwise it returns 404 and rolls back, never continuing unlocked. Make "ignores the lock's row count" a planted-bug control.<br>4. **Section 2.2 RLS wording:** write ENABLE **and FORCE** ROW LEVEL SECURITY, plus the `operator_scope` policy (0107 shape), not just "the NULLIF pattern". Without FORCE, an owning role sees every tenant.<br>5. **Section 3.4: an RLS-scoped check passes falsely.** `do_spl_doc_tree_check` without the operator scope sees 0 docs and prints `violations=0`. Change: it sets `app.rls_scope = operator` and exits 2 on `docs=0` unless `EXPECT_EMPTY=1`. Control: an unscoped run exits 2.<br>6. **Section 3.2 trigger events:** AFTER INSERT, UPDATE OF (parent_id, ord, doc_id), DELETE. Check the parent of OLD **and** of NEW: a move or a delete leaves its gap under OLD.parent_id, so an INSERT/UPDATE-only trigger misses the planted gap-skipping delete. Refuse any `doc_id` change. Walk for a cycle on UPDATE OF parent_id. I1 says "exactly one", but the partial unique index only gives "at most one". Add a deferred trigger on `workspace_doc` INSERT that requires the root at commit, and make `DocItemDeleteSubtree` refuse the root.<br>7. **Section 3.2 cost (not measured):** a row constraint trigger fires once per shifted row. A k-sibling shift checks the same parent k times, O(k^2) at commit (10^8 row visits at seat 4's 1 x 10,000). All deferred fires run after the last write, so the first fire per (doc, parent) already sees the final state. Skip repeats with a transaction-local key and time it in seat 4's T002 timing test.<br>8. **Section 3.4 repair:** one transaction under the doc lock, so it serializes with live ops and passes the deferred trigger. An unreachable cycle is cut at its smallest id, and that item is re-attached at the end of the root (ids printed). `DRY_RUN=0` on prd is an owner go (repo rule).<br>9. **Section 3.3 text edits:** `UPDATE .. WHERE id AND rev` hitting 0 rows is 404 when the row is gone (a concurrent delete-subtree), 412 when only the rev differs; never 200. Section 5 regenerates the export on `workspace_doc.rev`, but text edits do not bump it, so an edited body never re-exports. Change: the export triggers on any committed item write, and its header records the doc rev plus the highest item rev.<br>10. **Section 3.5 / 9b, define the outcomes and prove the overlap.** Each op ends as committed, 412, 404 or refused (move into its own subtree). "No lost op" means every committed op's effect is in the final tree. Every structural op returns the `workspace_doc.rev` it produced, unique per doc. The model applies the committed ops in rev order and is compared after the run. Print the committed/412/404 counts and the lock-wait count, and fail on 0 waits: a run without contention proves nothing. Writers re-read the rev and retry on 412.<br>11. **Section 3.3 lock order:** every path locks the doc row before any item row. T005's import takes the lock once at the top of its one transaction; nested op calls reuse it. 9b mixes text edits, moves and delete-subtree, and prints the `deadlock_detected` count (must be 0).<br>12. **Section 5:** the export reads the doc and its `rev` in ONE REPEATABLE READ snapshot, so the header rev matches the content.<br>13. **T002 vs bench:** spec CHECK (ord >= 1) forbids the bench's `ord = -1` parking in `adj_move`. The port shifts in single statements (the deferrable UNIQUE is checked at statement end) or uses `SET CONSTRAINTS .. DEFERRED`; say so, so the bench is not copied.<br><br>Answers:<br>Q1: (a) append-only JSONB log, seat 4's entry shape, written in the SAME transaction as the rev bump, UNIQUE (doc_id, rev). It is then also the commit order the concurrent test replays (change 10) and the audit trail `do_spl_doc_tree_repair` can cite.<br>Q2: (a) print CSS: print branch is one subtree read; no server-side renderer, nothing new on the integrity path. |

All four seats answered Q1 = (a) and Q2 = (a). Commits: seat 2 23c62bd53,
seat 3 a56c16313, seat 4 2c5e57eb1, seat 5 60b7f4f9f.

## 11. Fold map (v1.0)

| seat#change | change, in short | landed in |
|---|---|---|
| 2#1 | trigger accepts count = 0 children | 3.2 (item trigger, OLD/NEW bullet); 9c |
| 3#1 | `DocItemMove` refuses a move into its own subtree | 3.3 (op refusals); tasks T002 |
| 3#2 | list the 9 avoided defects | 3.6 (table D1-D9) |
| 3#3 | recommend Q1 (a), Q2 (a) | 0 (D-Q1, D-Q2), 2.3, 4 |
| 4#1 | O(siblings of the target parent), size targets, 1 x 10,000 bench case | 2.1 (wide parents, size targets), 2.2 reason 1; tasks T000b |
| 4#2 | whole-document read cost | 2.1 (whole-document reads) |
| 4#3 | lazy-loading unit, no offset paging, grid size limit | 6 |
| 4#4 | differences under 2 ms not ranked | 2.1 (noise) |
| 4#5 | decision vs ltree rests on reason 3 | 2.2 reason 3 |
| 4#6 | time the real ops on testkit Postgres; UNIQUE is the child index | 3.5 (timing), 3.2 I4 row; 9i; tasks T002 |
| 4#7 | append position = `max(ord) + 1` | 3.3 step 2 |
| 5#1 | trigger takes the doc row `FOR UPDATE` first | 3.2 (item trigger, first statement); 9c |
| 5#2 | composite FKs carry tenant_id | 2.2 schema; 3.2 I2; 9e |
| 5#3 | `FOR UPDATE` must return exactly 1 row | 3.3 step 1; 3.5 controls; 9b, 9e |
| 5#4 | ENABLE and FORCE RLS, `operator_scope` | 2.2 schema |
| 5#5 | check runs operator-scoped, exit 2 on docs=0 | 3.4; 9d |
| 5#6 | trigger events, OLD and NEW parent, no doc_id change, cycle walk, root required | 3.2 (I1 at least one, item trigger); 3.3 (delete refuses root); 9c |
| 5#7 | trigger once per (doc, parent) | 3.2 (item trigger, last bullet); 3.5 timing |
| 5#8 | repair in one tx under the lock, cycle cut, prd = owner go | 3.4 |
| 5#9 | text edit 404 vs 412; export on any item write | 3.3 (text edits); 5; 9f |
| 5#10 | four outcomes, rev per op, replay in rev order, fail on 0 waits | 3.3 (outcomes); 3.5 (concurrent writers); 9b |
| 5#11 | lock order, import takes the lock once, deadlock count | 3.3 (lock order); 3.5; 9b; tasks T005 |
| 5#12 | export in one REPEATABLE READ snapshot | 5 |
| 5#13 | no `ord = -1` parking; single-statement shifts or deferred constraints | 3.3 step 3 |

## 12. Owner questions

None open. v0.2's Q1 and Q2 are decided: section 0 (D-Q1, D-Q2).
