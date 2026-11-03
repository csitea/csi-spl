# The per-person Qto document lock

Spec 125 row B8 ([spec](../../specs/125-netvisor-integration/spec.md) section
5.3, case C-NVS-8; owner HUM-10 constraints C7, C8, C9), issue SPL-4723. A Qto
document can be locked to one human: then that human alone can read it. No
other member, no admin role, no agent seat and no act-as clone sees it.

## 1. What the lock is

- `workspace_doc.restricted_to_human` (rdb
  `0256_workspace_doc_restricted_to_human.sql`): `NULL` = the workspace's
  document, as before; `HUM-<n>` = that human's alone.
- The database enforces it, not the hub: the RESTRICTIVE policy `human_lock`
  on `workspace_doc` lets a locked row through only when the transaction's
  `app.doc_human_id` is its human, and `human_lock` on `workspace_doc_item` and
  `workspace_doc_rev_log` lets a row through only when its document is
  visible. Unset `app.doc_human_id` means no human: fail closed.
- The hub sets `app.doc_human_id` (`store.WithHuman`, carried by every scope
  statement) only for a signed-in member who is not an act-as clone, on the
  doctree routes (`docTreeHuman`, `csi-spl-api/.../hub/wsdoc_lock.go`) and the
  doc section of the global search. An agent token, a desk, the operator
  scope, migrations and the reporting SQL never carry it.
- `app.doc_human_id` is its own setting, not rdb 0255's `app.human_id`: that
  one opens a Netvisor owner's finance rows and only `netvisor_postgres.go`
  sets it (`TestNetvisorHumanScopeCallers`), so reading a locked document
  never also opens finance data.
- So every read path is covered, including ones written later: read, head,
  children, subtree, grid, list, folder tree (`docNodeSelect` drops a doc node
  whose document is hidden), doctree search, global search, export through
  the API. A hidden document answers 404, and lists and searches leave it
  out.

## 2. Who can set it

| action | who | route |
|---|---|---|
| create a locked document | a signed-in member holding `docs.write`, locked to themselves | `POST /v1/workspace/doctree` with `"restricted": true` |
| lock an existing document | the same, to themselves only | `PUT /v1/workspace/doctree/{doc}/lock` `{"restricted": true, "rev": n}` |
| lift the lock | its human, the only caller who can see it | the same route with `"restricted": false` |

An agent token or an act-as clone gets `403 restricted_needs_human`. A repo
doc (`fs=repo`) gets `403 repo_docs_unlockable`. Anyone else asking about a
locked document gets `404`. The head (`GET .../doctree/{doc}`) carries
`restricted_to_human`, which only the lock's human ever reads as non-empty.

## 3. Limits

- A channel move or copy (spec 158) does not see a locked document, so it
  stays in its workspace.
- A recursive folder delete by another member removes the folder but not a
  locked document inside it. The document then shows at its human's tree
  root.

## 4. Tests

`TestWorkspaceDocRestrictedToHuman`
(`csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_lock_test.go`, Postgres,
`PRE_PUSH_TIER=full`): the owner reads every path, and another admin, an
act-as clone and an agent token get 404 / 0 rows and cannot write. Red
controls: drop `human_lock` on `workspace_doc_item` and the doctree search
leaks; drop it on `workspace_doc` and the reads leak; remove the
`docNodeSelect` filter and the folder tree leaks.
