# Spec 137 panel: seat s137-grok

Seat: `s137-grok` (agent g-959), spec 137 section 6. Reviewed `spec.md` v0.1.0
and `tasks.md` as landed in 43472c355 (SPL-1730), against the code on
origin/master `cbbca79804ac13680eef4ab28818bb9489403312` (2026-10-13).
Doc only: this file builds nothing.

## 0. The five choices in one line

P-Q1 **A**, P-Q2 **A**, P-Q3 **A**, P-Q4 **A**, P-Q5 **A**.

## 1. P-Q1 unnumbered headings — A

**Choice.** A flag on the item, `attrs.numbered = false`. An absent key means
numbered, so every item that exists today keeps the outline it has now.

**Why.** The outline is the sibling `ord` path, computed at read and not a
column (`0157_workspace_docs.sql:10-12`,
`workspace_docs_read.go:111-122`). A stored override (B) is a second number
that a move does not update, which is the drift `check_outline` exists to
refuse (`spl-doctree-md.py:12-14`, `:82-97`). Normalising on import (C)
renumbers a heading someone already cites. The flag lives in `attrs`, which
is already a JSONB object (`0157_workspace_docs.sql:52`), so this needs no
new column.

**Risk.** An unnumbered sibling still consumes `ord`, so the next numbered
heading exports a higher number than the file (`## Overview` then
`## 1. Goals` becomes `2`). The derivation has to skip unnumbered siblings,
in the one reader and in both exporters
(`doctree_export.go:156-157`, `-doctree-export.ts:24`). A heading whose
prefix is not that derived decimal (`A.`, roman, a skip) is imported with
the flag false and the literal prefix left in the title, so the export
reproduces it. The view must hide the outline chip when the flag is false,
or the title and the chip show two numbers (`WorkspaceDocView.vue:95`).

**Fit.** `spl-doctree-md.py:66-68` is the refusal (`NUM` does not match).
`outlineOf` (`workspace_docs_read.go:116-122`) is the one function that
builds the number. Both exporters print `outline + title` with no switch
(`doctree_export.go:9-13` says change them together).

## 2. P-Q2 repo docs in the one file system — A

**Choice.** A. One reserved workspace (a `tenants` row) holds the repo tree.
One extra permissive `FOR SELECT` policy per table lets every workspace read
it. Writes stay on the policies that already exist, so a workspace session
cannot write that tenant.

**Why.** The nested set is one root per tenant
(`0165_workspace_doc_node.sql:76`) and `lft` / `rgt` are unique inside that
tenant (`:60-61`). Repo docs cannot be a `/repo` folder inside each
workspace tree without copying the rows. Copying them (B) spends the
per-tenant cap of 10,000 docs (`:69`, `workspace_doc_nodes.go:51-52`) once
per workspace and has to be re-synced. Leaving them in the docs bucket (C)
keeps the two stores the owner asked to combine. A reserved tenant reuses
the composite foreign keys and the forced RLS already on these tables
(`0157_workspace_docs.sql:64-67`, `:93-100`).

**Risk.** Spec section 4.2.2 names `spool.tenant_id` and
`spool.operator_scope = 'true'`. A live session sets `app.tenant_id` and
`app.rls_scope = 'operator'` (`0165_workspace_doc_node.sql:85-90`). Copied
as written, the policy matches no session. The new policy has to be
`FOR SELECT` only: a `FOR ALL` policy is OR-ed with the existing one and can
grant a write. There are two databases. The map's doc ids are rows of one
of them (`qto-docs.tsv`, 2 lines). The other environment imports the git
export; it does not grow a second authoring tree. At this sha,
`git ls-files '*.md' | wc -l` is 1253 and those files sit in 276 parent
directories. The doc cap (10,000) and the folder cap (1,000, `:70`) both
hold. The spec's 1,247 is the count at `4ac30d59b`, not this tree.

**Fit.** The explorer unions two tenants. It does not become one nested set.
`workspace_doc_node_fixed` refuses a change of `tenant_id` (`0165:94-100`),
so an import inserts the row in the reserved tenant; it does not move a
workspace doc across.

## 3. P-Q3 table editor — A

**Choice.** A now. A toolbar button inserts a pipe-table skeleton into the
paragraph body. A grid modal (B) may later edit that same text. It is not a
second stored form.

**Why.** The paragraph body is the markdown
(`0157_workspace_docs.sql:51`). The CLI already appends a table there:
`doctree add --kind table` checks the pipe shape and edits `body`
(`doctree.go:41-50`, `:633-676`). The read view draws that body through
`MdRun`, and `markdown.mjs` already allows the table tags (`:41-46`). A
`kind = 'table'` item (C) does not fit: an item is a heading, and the node
kinds are only `root`, `folder` and `doc` (`0165_workspace_doc_node.sql:45`).
The grid view is one row per item, and the body is one cell
(`WorkspaceGridView.vue:1-8`), not a cell editor for a pipe table.

**Risk.** A pipe inside a cell has to be escaped, and the round-trip test
has to include one. `spl-doctree-md.py:55` strips the section body; a table
that is the last thing in the section must survive that strip.

**Fit.** The toolbar has one button today, Insert picture
(`WorkspaceDocView.vue:162-174`). The new button inserts the text
`mdTableOK` already accepts, so the WUI and the CLI write the same bytes.

## 4. P-Q4 blockquotes and citations — A

**Choice.** A. The body holds `> passage` and a following
`> — [Source](url)`. The read view styles the attribution. Nothing new is
stored.

**Why.** `attrs` already carries one code block and one image per item
(`doctree.go:41-50`). A structured quote in `attrs` (B) allows one quote per
section and needs a placement rule in both exporters. A paragraph can hold
several quotes, nested quotes and a table in the same body, which is how
inline pictures already work (`-doc-pics.ts:1-8`). The renderer already
allows `blockquote` (`markdown.mjs:43`). Both exporters copy the body
through unchanged (`doctree_export.go:158-159`).

**Risk.** The attribution is a convention: the last paragraph of a quote
that starts with `—` is the source line. A quote with no such line renders
as a quote, which is the right fallback. It is not a field you can query.

**Fit.** The button goes in the same `wsdoc__paratools` row as the table
button (`WorkspaceDocView.vue:162-174`). No migration.

## 5. P-Q5 retirement gate — A

**Choice.** A, narrowed. A path is gated only after it has a row in
`qto-docs.tsv`. A change to that file passes when the file equals a fresh
export of that doc. Files not yet in the map stay editable.

**Why.** An advisory warning (C) does not retire hand editing. A CI job that
commits the drift back to master (B) writes trunk out from under every
lane's rebase (`csi-spl-doc/doc/md/developer-guide.md` section 1.1). The
stamp line the export already writes
(`spl-doctree-md.py:114-115`) and the map (2 rows today) are enough to know
which files are in the scheme. The gate grows with the map, from those 2
rows toward every tracked `*.md`, instead of closing the tree on day one.

**Risk.** The pre-push hook often cannot reach the hub. It then refuses the
mapped diff, rather than letting it through. It must not pick "whichever
database this box can see": the two environments do not share doc ids, and
the map names one of them. The other editor of these files is spec 075
repo-edit: `PUT /v1/docs/{path}` saves an overlay and a worker pushes it to
git (`repo_docs_edit.go:28-30`). That push hits this gate until that path
is retired for mapped files.

**Fit.** `spl-doctree-export-md.func.sh:68-71` already refuses a path
outside `csi-spl-doc/*.md`. The gate's lookup is the map plus one export,
after that restriction is lifted for the files the map names.

## 6. Corrections to tasks.md

1. **T002 names the wrong directory, and it is two jobs.** The gate says
   five reviews in `reviews/`. This seat writes `panel/grok.md`, and
   `panel/claude.md` is already on master (6216915b8). The consensus fold
   is the editor that runs after the five seats, not part of T002.
2. **T014 names a column the table does not have, and two import failures
   have no task.** `workspace_doc` is id, tenant_id, title, rev and the
   audit columns (`0157_workspace_docs.sql:33-42`); 0164 adds `description`
   only. There is no `attrs` for `front_matter`. Keep the YAML on the
   hidden root item's `attrs`, next to the preamble that already lives in
   that item's body, or add an rdb task that adds the column. Spec 1.3
   items 2 and the setext row (F08) are also untasked: a file with no
   `# ` title, and a setext heading. T012 does not cover either.
3. **T013 asks to remove the heading shift that the export is built on.**
   `compose` adds one `#` so the page title stays the only h1, and it
   already leaves a line that is `######` (`spl-doctree-md.py:110-115`).
   The task should say: do not fold two depths onto h6. It should not say
   "drop the shift". T012's flag has to be honoured by `outlineOf` and both
   exporters before the splitter accepts an unnumbered heading, or the
   import writes a decimal the file did not have.
4. **T020 repeats RLS that is already forced, and T030 freezes a stale
   count.** The work left in T020 is a `tenants` row and one permissive
   SELECT policy, using `app.tenant_id` / `app.rls_scope` (section 2). Do
   not run `ENABLE ROW LEVEL SECURITY` again from the spec's SQL. T030
   should say every tracked `*.md`. The 1,247 figure is `4ac30d59b`; this
   tree has 1253 (`git ls-files '*.md' | wc -l` at `cbbca7980`). One lane
   should not import all of them: split by tree (`csi-spl-doc/doc/`,
   `csi-spl-doc/specs/`, then the files outside `csi-spl-doc/` after T017),
   and keep T016 in front of every slice. The import still commits a
   partial doc when a later section fails
   (`spl-doctree-import-md.func.sh:66-68`).
5. **T031's gate fails the successful export, and T032 sits too late.**
   `git status --porcelain` clean after a full export contradicts AC-09:
   the stamp line is an intended diff (`spl-doctree-md.py:114-115`). The
   gate for a slice is "the only new lines are that stamp". T032 (the
   export test drives a Python stub of `spool`, spec 1.3 item 10) is in
   phase 3, while T012-T015 change export output. Move it ahead of those
   tasks. T040 also has to name the spec 075 repo-edit worker
   (`repo_docs_edit.go:28-30`) or that worker's push is the first refusal.

## 7. Version log

| version | date | author | change |
|---|---|---|---|
| 1.0 | 2026-10-13 | s137-grok (g-959) | Choices P-Q1..P-Q5 and five corrections to tasks.md. |

<!-- version: 1.0 · updated: 2026-10-13 · last-edit: 2026-10-13T21:17:31Z -->
