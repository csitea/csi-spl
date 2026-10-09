# Spec 113: Workspace documents, an outline and a grid over one tree

Version **v0.2** (2026-10-08). v0.1 drafted by seat 1 (agy a-600); v0.2 by
c-605: adds the owner's integrity requirement (section 3), the Perl-to-Go
port (section 6), the one-way markdown export (section 5), and replaces
v0.1's measurement with a committed, rerunnable benchmark (section 2.1).
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
siblings only: about 1 ms at both sizes. Its read is the slowest (a
recursive CTE, 5.2 ms for 1,111 rows), and still far inside a request.

### 2.2 Decision: adjacency list + sibling ordinal

Chosen BY the measurement and BY which model passes the property test
(section 3.5) cheaply:

1. **Writes are O(siblings), flat in the document size.** The nested set's
   O(document) write is what turns one missed shift into a broken tree.
2. **The invariants are mostly plain constraints** (section 3.2): one
   parent each is a single FK column; sibling order is a UNIQUE key. A
   nested set's "no gaps, no overlaps over 2N bounds" cannot be a
   constraint at all, only a full-table scan.
3. **Nothing derived is stored**, so nothing can drift: the outline number
   1 / 1.1 / 1.1.1 is computed at read from the `ord` path (the benchmark's
   recursive CTE). The derived data is the sibling numbering and the export.
4. **The sibling project's UI behaviour stays**: add sibling / parent /
   child, move, delete a branch, print a branch, and the doc + grid views
   map 1:1 onto these ops (section 4).

Schema (T001):

- `workspace_doc` (id, tenant_id, workspace_id, title, rev, timestamps):
  the document header; its row is the per-document lock (section 3.3).
- `workspace_doc_item` (id, tenant_id, doc_id, parent_id, ord, title, body,
  attrs jsonb, rev, timestamps). Every document has ONE hidden root item;
  the top-level sections are its children, so numbering starts at 1.
- Tenant RLS with the repo's `NULLIF` policy pattern on both tables; the
  store reaches them only through `inTenant` / `asOperator`.

## 3. Hierarchy integrity (the core requirement)

### 3.1 Invariants

For every document D:

| # | invariant |
|---|---|
| I1 | D has exactly one root item (parent_id NULL, ord 1) |
| I2 | every other item has exactly one parent, and it is in D |
| I3 | every item is reachable from the root: no cycle, no orphan |
| I4 | the children of each item are numbered 1..k: no gap, no overlap |
| I5 | siblings are totally ordered by ord (follows from I4) |
| I6 | the outline number of each item is unique in D and derived from I1-I5, never stored |

### 3.2 Checked in the DB

| inv | how |
|---|---|
| I1 | partial unique index on (doc_id) WHERE parent_id IS NULL; CHECK (parent_id IS NOT NULL OR ord = 1) |
| I2 | parent_id is ONE column; FK (doc_id, parent_id) -> (doc_id, id) ON DELETE RESTRICT |
| I4 overlap | UNIQUE (doc_id, parent_id, ord) DEFERRABLE INITIALLY IMMEDIATE; CHECK (ord >= 1) |
| I3, I4 gap | a DEFERRABLE INITIALLY DEFERRED constraint trigger: at commit, for each touched parent, min(ord) = 1 and max(ord) = count; for each moved item, a bounded walk up to the root (no cycle) |
| all | `do_spl_doc_tree_check` (section 3.4): the full check of I1-I6 on demand |

### 3.3 Every structural op is ONE transaction under a per-document lock

add sibling / add parent / add child, move (incl. indent / outdent and
reorder), delete subtree: each is one store function, one transaction:

1. `SELECT ... FROM workspace_doc WHERE id = $doc FOR UPDATE` (the lock;
   tenant-scoped through RLS, unlike a cluster-wide advisory lock);
2. read the positions it needs AFTER the lock, never before it;
3. the sibling shifts and the row writes;
4. bump `workspace_doc.rev`; commit, which runs the deferred trigger.

Item text edits (title, body, one grid cell) do not change the structure:
they take a row lock and the item's `rev` (412 on a stale `rev`), not the
document lock. A structural op sent with a stale `workspace_doc.rev` is a 412.

### 3.4 `do_spl_doc_tree_check` and `do_spl_doc_tree_repair`

- `./run -a do_spl_doc_tree_check` (csi-spl-orc, `DOC_ID=` optional, every
  doc by default, read-only, as the per-env SA): runs the I1-I6 queries and
  prints one line per violation plus `violations=<n> docs=<n> items=<n>`;
  exit 1 when n > 0.
- `./run -a do_spl_doc_tree_repair` (`DOC_ID=` required, dry run unless
  `DRY_RUN=0`): rebuilds the derived fields from the parent links: renumbers
  each item's children 1..k in their current (ord, id) order, re-attaches
  an unreachable item at the end of the root (reported by id), then runs the
  check; prints `renumbered=<n> reattached=<n>` and the check's line.

### 3.5 The property test

- A Go test against Postgres (testkit), never against the memory store:
  thousands of random sequences of add sibling / parent / child, move
  (anywhere, incl. into its own subtree, which must be refused), delete
  subtree, per seed; the full invariant check AND a comparison with an
  in-memory model tree after EVERY step.
- Concurrent writers: N goroutines on N connections on one document; the
  check after each committed op and at the end; no deadlock, no lost op.
- Control: a planted bug (e.g. delete that skips closing the sibling gap,
  move that reads positions before the lock) behind a test-only switch
  must turn the test red.
- The seed of a failing run is printed so it replays.

### 3.6 What the sibling project's code does, and v0.2 does not copy

Read on this box, read-only, 2026-10-08 (the DB writer's hierarchical
insert ~l.291-422 and delete ~l.203-290, its SQL test hierarchy table):

- no parent link: the parent is guessed from `level` and `min(rgt)`;
- one insert branch writes a leaf of width 4 (`lft = parentRgt-1`,
  `rgt = parentRgt+2`), which breaks the nested set at once;
- its own seeded test hierarchy breaks the invariants (the root and the
  last top-level item share `rgt = 23`);
- no lock: two writers read the same `lft` and both shift;
- every insert renumbers a document-wide `seq`;
- errors swallowed (an `eval` and a check of the driver's error string);
- SQL built by string interpolation of table names and ids;
- ids from a seconds timestamp (two inserts in one second collide);
- `level`, `seq`, `lft`, `rgt` all nullable, no constraint at all.

## 4. Two views of the same items

- **Doc view**: an outline numbered 1 / 1.1 / 1.1.1, edited in place.
  Context menu: add sibling / parent / child, move (drag, indent, outdent),
  delete branch, print branch.
- **Grid view**: spreadsheet-like rows (outline number, title, body,
  attrs columns), inline edit, filter, sort; structure ops from the row menu.
- Both are WUI views of the same items; every edit goes through the
  section 3.3 ops, so neither view can break the tree.

## 5. Phase 2: one-way export, DB -> markdown

- Output only. A document is written as markdown whose layout mirrors the
  outline: an item with children is a directory `<n>-<slug>/` with an
  `index.md`, a leaf is `<n>-<slug>.md`, n = its outline number.
- Targets: the per-workspace bucket (the spec 075 phase 2 bucket becomes
  the export's target) and/or a zip download / a repo commit.
- Regenerated on change: after a commit that bumps `workspace_doc.rev`, a
  debounced job writes the export for that rev; the export records the rev.
- Never edited back: every file carries a "generated from the DB, rev <n>,
  do not edit" header; no code path reads the export into the DB.

## 6. Hub API: port of the sibling project's Perl API to Go

The hub/store tasks PORT the sibling project's Perl API into
`internal/store` (pgx, under RLS) and `internal/hub`, inside the section 3
rules: the hierarchical insert, the delete, the single-column update, the
branch reader, the doc-view and grid controllers, the xls import/export.
[tasks.md](tasks.md) names which routine each Go task ports. The port keeps
the behaviour (which ops exist, what the views show), not the storage: the
nested-set arithmetic is replaced by the section 2.2 model.

- **Lazy loading**: the doc and grid views load lazily; the initial chunk
  stays inside its 160 KB ceiling.
- **Concurrency**: section 3.3; a 412 on a stale `rev`.
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
| b | concurrent writers on one document | planted read-before-lock move turns it red | 8 writers x 500 ops |
| c | constraint + deferred trigger refuse a gap, an overlap, a cycle, a second root | the same writes with the trigger dropped commit | 1 per invariant |
| d | `do_spl_doc_tree_check` / `_repair` on a corrupted copy | a clean doc prints violations=0 | 1 per invariant |
| e | tenant RLS: a cross-workspace read returns 0 rows | the same read in-tenant returns the rows | 1 |
| f | export: layout mirrors the outline, regenerated on rev change | an edit of an exported file is not read back | 1 doc, 3 levels |
| g | WUI: doc and grid views lazy, edits through the ops | initial JS delta > 100 B fails | 1 |
| h | `doc-read` / `doc-write` / `doc-list` verbs work | an unauthenticated request fails | 1 |

## 10. Owner questions (open, with recommendations)

**Q1. Revision history structure?**
- (a) Keep it simple: append-only JSONB log. *(Recommended)*
- (b) Full relational history table.

**Q2. Printing: PDF via a headless browser, or print CSS?**
- (a) Standard print CSS. *(Recommended)*
- (b) Headless browser PDF generation.
