# Tasks — `032-spool-message-edit`

Ground rules: `../README.md` §2. Specs are docs; every code change is a task
here. Status: **Implemented** (cite the sha or the command), **Partial** (name
the missing part), **Planned**.

Two lanes: **HUB/DB (CLE-3443, this dir)** and **BROWSER (CLE-3445, under
`../005-spool-wui`)**. The seam between them is
`./contracts/message-edit-v1.md`, and neither lane invents a name the other
must consume.

## T001 — publish the contract before building against it

**Status**: Implemented — `db78443` (first publish), moved to this dir in
`2dad1df`.

The browser lane was blocked on five answers (request, response, frame,
authorisation, failure codes) and was landing its contract-free parts
meanwhile. The contract went out first, then the implementation.

## T002 — the append-only register (DDL)

**Status**: Implemented — `d8ecb2a`,
`csi-spl-rdb/src/sql/postgres/spool-hub/0026_message_revisions.sql`.

`message_revisions` (`tenant_id`, `msg_id`, `revision`, `body`, `edited_by`,
`edited_at`), PK `(tenant_id, msg_id, revision)`, FK to `messages`
`ON DELETE CASCADE`, plus `messages.edited_at` / `.edited_by`. RLS in 0021's
fail-closed `NULLIF` form with the operator policy beside it.

No extra index: the primary key's btree already answers both questions the
table gets — every revision of one message in order, and its highest revision.

FR-ED-002, FR-ED-010, FR-ED-011.

## T003 — the store layer, both drivers

**Status**: Implemented — `d8ecb2a`, `internal/store/message_edit.go`,
`internal/store/message_edit_postgres.go`.

`GetEditable` / `ApplyEdit` / `MessageRevisions` on the `Store` interface,
implemented for Memory and Postgres. `ApplyEdit` runs in ONE transaction with
`SELECT … FOR UPDATE` on the message row, so two concurrent edits queue instead
of racing the primary key, and revision 1 is captured in that same transaction.

FR-ED-002, FR-ED-003.

## T004 — the endpoint

**Status**: Implemented — `d8ecb2a`, `internal/hub/edit.go`,
route in `internal/hub/server.go`.

`PATCH /v1/messages/{msg_id}` and its `OPTIONS` preflight. Contract §4's seven
rules in order; the response is the view element the WUI already normalises,
plus `task_id` and the marker.

FR-ED-001, FR-ED-004, FR-ED-005, FR-ED-006, FR-ED-009.

## T005 — the live frame

**Status**: Implemented — `d8ecb2a`, `fanoutEdited` in `internal/hub/edit.go`.

`message_edited`, to the same audience as the message's own `message` frame
(`wuiConn.wants`), the editor's own other tabs included.

FR-ED-008.

## T006 — the marker on the read path

**Status**: Implemented — `d8ecb2a`, `internal/hub/view.go`,
`internal/store/view_postgres.go`.

`edited_at` / `edited_by` / `revision` on the `/v1/view/threads/{task_id}`
element, **omitted entirely** while the message has never been edited, so a
reload renders exactly what the live frame rendered. The register probe is
inside a `CASE WHEN edited_at IS NULL`, so an unedited row — the overwhelming
majority — pays nothing for it.

FR-ED-007.

## T007 — the refusals, each watched refusing

**Status**: Implemented — `d8ecb2a`, `internal/hub/edit_test.go`.

Nine tests. The three guards CLE-00 named were each deleted and the test
watched to go red, rather than asserted to exist:

| guard removed | what the endpoint then did |
|---|---|
| rule 6 (`not_author`) | `200` with `edited_by:HUM-2` on HUM-1's message |
| `empty_body` | `200` with `body:""` stored — the CLE-3433 shape, in the dev store once already |
| rule 7 (`not_editable`) | `200` with `sig:not-verified-here` over `body:rewritten`: a stored envelope that no longer verifies against its own pin |

SC-002.

## T008 — the register in the cross-tenant suite

**Status**: Implemented — `d8ecb2a`,
`internal/store/crosstenant_test.go` `seedTenantAll`.

`TestCrossTenantEveryTable` fails a `tenant_id` table it finds in the catalogue
and cannot find a seed for, so a new tenant table cannot ship unseeded. One
`ApplyEdit` per tenant writes revisions 1 and 2.

`bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` ->
`ok - cross-tenant suite (store): 2 TestCrossTenant PASS against Postgres`,
`ok - RLS: 8 TestRLS PASS - every tenant_id table (from the catalogue) …`.

FR-ED-010.

## T009 — apply the migration, then roll the image

**Status**: Planned — owner-gated. The DDL apply is a GCP mutation and is not
this lane's to run unasked.

Order is fixed by contract §8: `0026` on dev and prd FIRST, the image that
serves the endpoint SECOND. Backwards is a 500 on an absent table; forwards is
safe at every intermediate moment, because the running image reads and writes
neither the new table nor the new columns.

SC-003.

## T010 — the browser half

**Status**: Not this lane's. `../005-spool-wui`, lane CLE-3445: the selection
model, the `e` binding, the inline editor pre-filled with the current body,
Enter to save and Escape to cancel, the `(edited)` marker and its i18n string,
the three normaliser pass-throughs and the `message_edited` handler
(contract §6), and the browser e2e.

## Not a task here

**The compare feature.** The owner named it as the reason for the register, not
as part of this request. The rows it will read exist; its endpoint is
deliberately unspecified (contract §7, last paragraph).

<!-- version: 0.1.0 · updated: 2026-09-22 · last-edit: 2026-09-22T08:02:00Z -->
