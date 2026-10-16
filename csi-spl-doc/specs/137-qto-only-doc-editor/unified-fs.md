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
  (`do_spl_doctree_import_md QTO_FS=repo`, T030a) writes it through the hub,
  whose store opens the `system` tenant scope only for the callers of §3.
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
| `repo` | the `system` tenant (repo docs) | `docs.read` in the caller's workspace | an agent or an admin of the operator workspace (T030a); anyone else 403 `repo_docs_read_only` |

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

## 5. A page into the repo tree (T030a)

The CLI picks the tree with `SPOOL_DOCTREE_FS=repo` (every doctree request
then carries `?fs=repo`); the desk action takes it as `DOCTREE_FS=repo`. The
import runs as a desk agent of the operator workspace (`t1`), so its box token
is the writer the hub admits:

`cd csi-spl-orc && AGENT_ID=<seat> ENV=prd TENANT_ID=t1 DESK_AGENT=<seat> MD_PATH=<page> QTO_FS=repo DRY_RUN=0 ./run -a do_spl_doctree_import_md`

- The map row gets a third column, `repo`; `do_spl_doctree_export_md` reads
  it and exports that row from the repo tree. A two-column row stays in the
  workspace tree.
- A page that is already an export (it carries a generated-from line) can be
  imported again: the splitter drops the old line and the export writes the
  new doc's. Remove its old map row first: the import refuses a mapped page.
- The ids in the map are prd's. A dev import is a rehearsal: give it its own
  `QTO_MAP` and restore the md file after it.

## 6. How a lane writes Qto: its own seat, or the command list

Every Qto write (`do_spl_desk_doctree` with `DRY_RUN=0`, and so
`do_spl_doctree_import_md`, the md export's writes and `do_spl_desk_wsdoc
write`) runs as the caller's OWN desk seat: `DESK_AGENT` must be the caller's
id, `AGENT_ID`, else `SPOOL_AGENT_ID` / `MCP_BOT_AGENT_ID`, else the agent id
of the tmux window `$TMUX_PANE` is in. A `sudo -u <box user>` hop strips the
pane, so pass `AGENT_ID=<your id>`. A write for another seat, or with no
caller id, is refused before any hub call:

> DESK_AGENT=c-001 is not you (c-129): a lane without its own desk seat sends
> the DRY_RUN=0 command list to the orchestrator, who runs it as its own seat

Why (SPL-2078): two lanes ran every T030B write as `DESK_AGENT=c-001`, and Qto
history credits c-001 with 185 imports, 5 edits and 7 deletes it never made.

- **A lane with a seat** in that desk writes as itself:
  `AGENT_ID=<you> DESK_AGENT=<you> ... DRY_RUN=0`.
- **A lane without one** (most lanes) prepares the exact commands with
  `DRY_RUN=1` (the default; reads and dry runs work for any seated
  `DESK_AGENT`), writes the `DRY_RUN=0` command list to a file under
  `/var/spool-hub/dispatch/`, and sends the orchestrator one message naming
  it. The orchestrator runs each line as its own seat.
- The guard: `csi-spl-orc/src/bash/tests/desk-doctree.tst.sh` section 9.

### 6.1 Starting a desk: a lane never starts another's

`do_spl_desk_up` with `DRY_RUN=0` resolves its caller the same way and
refuses a LANE caller whose id is not `DESK_AGENT`, before anything starts:

> DESK_AGENT=c-001 is not you (m-260): a lane never starts a desk; send c-001
> the command

It differs from the Qto write on purpose: a role seat (`-001`..`-004`, a peer
seat, a watchdog-expected seat: `spl_ars_is_seat`) may start any desk, a
caller with no agent id (the desk cron, `do_spl_desk_up_all` under it, a human
shell) is not checked, and a lane seating ITSELF (`spool-agent.sh` at spawn,
`spool-mcp.sh --seat`) stays open. Dry runs stay open.

Why (SPL-2227): on 2026-10-16 a mistral lane whose brief had no deploy step
ran `DESK_AGENT=c-001 ENV=prd DRY_RUN=0 do_spl_desk_up` six times. The guard:
`csi-spl-orc/src/bash/tests/desk-up-caller.tst.sh`.

## 7. A doc's pictures: `<doc>.assets/NN-name.ext` (gap G6, SPL-2201)

Owner HUM-10 picked layout A (msg 300d9a2c on poll c9f33bec, t1 topic
d31406c0): "the paths must be accordingly relative to one another" (msg
2423c8e3), and the files live in the hub's object store, the text in the
database (msg 78f4ffd3, poll 60020e7b answer A).

Status: **built** under SPL-2201: the hub routes, `spool doctree asset-put`
/ `asset-get`, the import, the export and the Qto view. A desk runs the two
verbs once its spool is rebuilt from a tree that has them (`spl_host_spool`).

- **Layout.** A doc's pictures sit in one folder next to its md file, named
  after it: `foo.md` -> `foo.assets/01-flow-map.png`. A picture's name is two
  digits, a dash and a short lower-case name (`a-z`, `0-9`, single dashes),
  then `.png`, `.jpg`, `.jpeg`, `.gif` or `.webp`.
- **The link is the same text in the repo and in Qto**: the path relative to
  the md file, `![Flow map](foo.assets/01-flow-map.png)`.
- **Import** (`do_spl_doctree_import_md`). The split lists each picture link
  outside code fences and inline code spans whose target is a path, not a URL
  (no scheme, no leading `/` or `#`). A link that breaks the layout, or names
  a file that is missing, is refused before any hub call; the FATAL names the
  link. After the sections, each picture is uploaded under its relative path
  (`spool doctree asset-put <doc> <path> --file f`).
- **Hub.** `PUT /v1/workspace/doctree/{doc}/assets/{path}` takes the bytes,
  and the type sniffed from them must match the extension (no SVG). It keeps
  them in the object store bucket at `t/<tenant>/files/<sha256>`, tenant
  `system` for the repo tree, and maps the path to that sha256 in the doc
  root's `attrs.assets`. `GET` on the same route serves them. A blob that any
  doc's `attrs.assets` names is kept by the file retention sweep and by an
  attachment's removal, which delete only what no message and no doc holds.
- **Export** (`do_spl_doctree_export_md`). It writes each picture in
  `attrs.assets` back to `<md dir>/<path>`, byte for byte, through
  `spool doctree asset-get` (base64 in JSON, since the desk action prints
  text). A file whose bytes are unchanged is not rewritten.
- **Qto view.** A `![..](<doc>.assets/NN-name.ext)` token in a section's text
  renders as a picture, read from the asset route, with its alt text under
  it. It is no numbered figure: both exports (the CLI's and the WUI's) write
  it back as written, so the md round trip stays byte-stable.
- **Distribution hygiene.** The import adds no picture to the repo, and the
  export writes back only the pictures the md already linked.

<!-- version: 0.4.0 · updated: 2026-10-16 -->
