; tags.scm -- SQL (tree-sitter-wasm `sql` grammar)
;
; NOT INSTALLED into the shared graft runtime: `dist/graph/queries/sql.scm`
; there is owned by whoever registered `sql` in GENERIC_LANGS, and the Hive SQL
; it runs over lives in a tree this feature does not touch. This is the
; hardened variant, kept as an asset so the reasoning and the tests travel with
; it. The INSERT defect it fixes was reported rather than patched in place.
;
; THE CAPTURE NAMES ARE NOT FREE, AND BEING "CONSUMED" IS NOT ENOUGH.
;
; graft's generic tier consumes `definition.*`, `reference.call`,
; `reference.send`, `reference.class`, `reference.interface`,
; `reference.implementation` and `reference.module`; anything else compiles,
; matches and is silently discarded. An unmapped `@definition.<kind>` is worse
; than discarded -- it falls back to "function" rather than erroring, so
; `@definition.table` would file every table as a function.
;
; The expensive part is one layer further in. `@reference.class` becomes a
; `calls` edge, and resolve.js settles a generic-tier `calls` edge ONLY against
; kinds ["function","method"]. Our definitions are class (tables) and interface
; (views), so EVERY call edge here is extracted and then dropped: measured on
; the client tree, 20,156 raw edges resolved to 0, and the build reported
; success with a healthy node count. `@reference.class` becomes a `references`
; edge, resolved against ["class","interface","struct","enum","type","module"],
; and the same corpus then yielded 1,690 resolved lineage edges.
;
; So: @reference.class for everything here, because nothing here is a function.
; The read/write/drop distinction collapses with it -- a distinction the
; consumer discards is not worth carrying in an installed query.
;
; What this is for: on this estate the SQL is a pipeline, not an application.
; The question an agent actually asks is "who writes db.t and who reads it",
; and answering it needs a define-and-consume map over TABLES, not a symbol
; table over functions. So tables and views are the definitions here.
;
; Two deliberate choices, both of which look wrong at a glance:
;
; 1. `@name` captures the whole `object_reference`, not its `name:` identifier.
;    The grammar splits `app_db.t_target` into schema: and name:, and a map
;    keyed on the bare `t_target` merges tables that live in different schemas.
;    Both directions were measured on the client tree rather than argued:
;
;      under-merge cost  -- 1434 of 1468 captured references are already
;                           schema-qualified (97.7%); only 34 bare FROM/JOIN
;                           targets would fail to match a qualified definition.
;      over-merge cost   -- 44 of the 626 distinct bare table names live under
;                           MORE THAN ONE schema, and they are the load-bearing
;                           ones: `recovery_views_status` under seven,
;                           every `profin_*` / `alfa_*` / `s2000_*` / `arc955_*`
;                           core table under two or three.
;
;    2% of edges missed against seven owners' status tables fused into one node.
;    The qualified text is the identity.
;
; 2. every reference pattern names its PARENT. `(object_reference) @reference`
;    on its own would also match the one inside CREATE TABLE, so every table
;    would reference itself and the define/consume direction would be lost.
;    Tree-sitter returns all matching patterns -- a later, narrower pattern
;    does not override an earlier, broader one -- so the narrowing has to be
;    in the pattern itself.

; ---------------------------------------------------------------- definitions

; CREATE TABLE / CREATE EXTERNAL TABLE / CREATE TABLE ... AS SELECT
(create_table
  (object_reference) @name) @definition.class

; CREATE VIEW ... AS
(create_view
  (object_reference) @name) @definition.interface

; WITH c AS (...) -- a named, file-local relation. Worth having: these are the
; names a reader of a 600-line delivery query trips over first.
;
; @definition.type, not @definition.variable. Both are in the KIND map, so both
; "work" at the capture layer -- but a `references` edge settles only against
; ["class","interface","struct","enum","type","module"], and `variable` is not
; in it. A CTE defined as a variable would be a node that the `FROM c` in its
; own query can never resolve to: present in the graph, unreachable in it.
(cte
  (identifier) @name) @definition.type

; ----------------------------------------------------------------- references

; FROM t / JOIN t -- the read sites.
(relation
  (object_reference) @name) @reference.class

; INSERT -- read this before changing it; the grammar loses the schema here and
; the honest answer was to drop most of the write side rather than fake it.
;
; This grammar does not know Hive's `INSERT OVERWRITE TABLE db.t`. It binds the
; word TABLE as the schema and leaves the real schema stranded in an ERROR
; child:
;
;     (object_reference schema:(identifier "table")
;                       (ERROR "app_x") "." name:(identifier "t_y"))
;
; The text `app_x.t_y` exists in the source and spans children 1..3 -- but no
; single NODE covers it, and a tags query captures nodes. So for this shape the
; only capturable name is the bare `t_y`.
;
; MEASURED on 218 real inserts in the client tree: 17 take the clean ANSI shape,
; 201 -- 92% -- take this one.
;
; Bare is not an option here. Definitions are 100% schema-qualified (268
; create_table, 41 create_view, zero bare), so a bare reference resolves against
; nothing at all; it would add 201 extracted-then-dropped raw edges and make the
; build look healthier than it is -- the same shape as the 20,156 -> 0 above.
; And it would be actively wrong if it ever did resolve: 44 of the 626 distinct
; bare table names on this estate live under MORE THAN ONE schema, and they are
; the hot ones -- `recovery_views_status` appears under seven, and every
; `profin_*` / `alfa_*` / `s2000_*` / `arc955_*` core table under two or three.
; A bare write edge would attach to another owner's table often enough to poison
; exactly the questions this map exists to answer.
;
; THE TRADE, WRITTEN DOWN: reads and drops are complete and qualified; the write
; side keeps only the 8% of inserts spelled the ANSI way. An unrecoverable edge
; is dropped rather than guessed. The real fix is a SQL grammar that parses
; Hive, not a cleverer query -- nothing in this file can recover a name the
; parse threw away.

;   (a) ANSI `INSERT INTO db.t` parses cleanly -- take the qualified name.
;       The anchor `.` matters: without it this pattern also matches the
;       mis-parsed shape above (extra children are allowed between unanchored
;       siblings) and would emit `TABLE db.t`, a name matching no definition.
(insert
  (object_reference
    schema: (identifier)
    .
    name: (identifier)) @name) @reference.class

;   (b) unqualified `INSERT INTO t` -- the leading anchor forces `name:` to be
;       the FIRST child, which is true only when there is no schema and no
;       ERROR before it, so this cannot also match (a) or the Hive shape and
;       double-count. It is doing the work of a "has no schema field"
;       predicate, which tree-sitter has no way to spell.
;
;       The guard drops the unqualified HIVE form `INSERT OVERWRITE TABLE t`,
;       where `name:` is the literal word TABLE and the real name is not in the
;       tree at all -- minting a table called TABLE once per such insert is a
;       fabricated node, which is the worse direction. A table genuinely named
;       `table` is dropped too; that is the trade, and losing one absurd name
;       beats inventing one. (Zero of either shape in the corpus measured, so
;       this pattern is insurance rather than load-bearing.)
(insert
  (object_reference
    .
    name: (identifier) @name)
  (#not-match? @name "^[Tt][Aa][Bb][Ll][Ee]$")) @reference.class

; DROP TABLE t -- rare but load-bearing. A table dropped in one script and
; selected from in another is the failure this map is meant to surface.
(drop_table
  (object_reference) @name) @reference.class
