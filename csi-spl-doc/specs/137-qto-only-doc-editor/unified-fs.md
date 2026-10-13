# Spec 137: the unified file system as built (T020, T021, T022, T024)

Lane `rdb-api`, issue SPL-1746. What landed, how to use it, and the plan
that retires the docs bucket. Requirements: [spec.md](spec.md) §4 and §5.2;
status: [tasks.md](tasks.md).

## 1. The system tenant (T020, rdb 0191)

- The repository docs live in the reserved tenant `system`
  (`store.SystemTenant`), in the same tables as a workspace's docs:
  `workspace_doc_node`, `workspace_doc`, `workspace_doc_item`,
  `workspace_doc_rev_log`.
- `system` is no workspace. It is suspended (every door answers 403), has no
  host row and no channels, and its root key is a value nobody holds the
  private key of. The operator workspace list, the hours sweep and the
  public-notice sweep leave it out.
- Read: one permissive `FOR SELECT` policy per doctree table admits
  `tenant_id = 'system'` in every scope.
- Write: unchanged. Only `tenant_scope` and `operator_scope` grant
  INSERT, UPDATE and DELETE, so a workspace session cannot write a system row
  (insert: SQL error 42501; update, delete, `FOR UPDATE`: 0 rows). The import
  writes it under the operator scope (`do_spl_doctree_import_md`, T030a).
- The store's doc list (`DocList`, `DocHeadOf`) and search (`DocSearch`)
  filter the caller's own tenant, so system rows never mix into a
  workspace's tree.

## 2. Doc ACLs (T021, rdb 0192)

- `workspace_doc_acl`: one grant per (node, subject, action), effect
  `allow` or `deny`. Subjects: `user:<id>`, `agent:<id>`, `role:<name>`,
  `workspace:*`. Actions: `read`, `edit`, `manage`, `share`.
- `workspace_doc_acl_effect(tenant, node, subjects, action)` applies spec
  §4.3.3 over the node and its ancestors: a matching deny wins, else a
  matching allow, else NULL, and the caller falls back to Layer 1 (the
  workspace roles of spec 025).
- The table starts empty and no route reads it yet, so Layer 1 decides
  everything as before.

## 3. One API over both trees, and the docs bucket's end (T022)

The doctree routes (`/v1/workspace/doctree/...`) take `?fs=`:

| `fs` | tree | reads | writes |
|---|---|---|---|
| `workspace` (default) | the caller's workspace | `docs.read` | `docs.write` |
| `repo` | the `system` tenant (repo docs) | `docs.read` in the caller's workspace | 403 `repo_docs_read_only` |

Any other value answers 400 `bad_query`. Example:
`GET /v1/workspace/doctree/nodes?fs=repo` lists the repo tree's top level.

The spec 075 Docs section still reads the docs bucket (`GET /v1/docs/*`,
`tree.json`). The bucket is retired in steps; each step needs the one before
it to be live:

1. **Now (T024).** The bucket keeps serving reads. A save or retry through
   `PUT /v1/docs/{path}` of a Qto-managed doc answers 409 `qto_managed`.
2. **After the bulk import (T030a..T030d) and the Explorer (T023).** The WUI
   Docs section reads `fs=repo` instead of the bucket. `GET /v1/docs/*` stays
   one release as a fallback for old WUI bundles.
3. **After the push gate (T040, T041)**, every repo `.md` is mapped and
   exported, so nothing is left to edit through spec 075: turn
   `env.docs.repo_edit.enabled` off in the cnf, and stop the bucket upload in
   the deploy workflow.
4. **Removal.** The bucket (`csi-spl-<env>-docs`) and `GET /v1/docs/*` go
   away. Deleting the bucket is a destructive terraform change and needs the
   owner's go.

## 4. Spec 075 repo-edit retired for Qto-managed docs (T024)

- `do_spl_doctree_export_md` writes an export stamp under the title of every
  doc it exports from `csi-spl-doc/doc/md/qto-docs.tsv`:
  ``> Generated from qto doc `<id>`; edit it there.``
- The hub reads the doc's published text. When the stamp is there,
  `PUT /v1/docs/{path}` and `POST /v1/docs/edits/{id}/retry` answer 409
  `qto_managed` and name the Qto doc. Nothing is queued, so `repodocs.Worker`
  pushes no commit that would race the export.
- Docs not yet imported keep the spec 075 edit path until their slice of the
  import lands (spec §5.2 Phase 4).

<!-- version: 0.1.0 · updated: 2026-10-14 -->
