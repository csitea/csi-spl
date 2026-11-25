# Costs: a Taxes page, shown only in the tax workspace (SPL-6438)

Status: **v0.2 (2026-11-25), built (S1-S4) on a review branch, waiting
for R7 and the holder's GO.** Issue: SPL-6438 (epic SPL-2400). Discussion:
csitea topic `dc7c9c9a` (owner HUM-10). The owner answered section 9 (msg
`fc8f964e`): Q1 **A**, every person of csitea, agents never; Q2 **A**,
weekly, after the weekly tax check. Section 10 is what was built.

It adds one page to the Costs bar of [costs-redesign.md](costs-redesign.md)
(3.2, 3.9) and copies, on purpose, the shape of the one Reporting page that
is already limited to one workspace: the Finance tab of
[spec 125](../125-netvisor-integration/spec.md) (hub
`internal/hub/netvisor.go`, rdb `0255` / `0260`,
[netvisor-finance-store.md](../../doc/md/netvisor-finance-store.md)). Where
this page says "as Finance", that code is the reference and is not repeated.

## 1. The owner's words (HUM-10, csitea topic `dc7c9c9a`, verbatim)

- 2026-11-24 14:47:53Z: "go trough all of the messages in `<tax-portal>` ,
  download all of hte pdfs for 2026 and build the taxes tab in the csitea
  workspace - show that only in the csitea work[space]"
- 2026-11-24 22:39:42Z, msg `00441aed`: "continue with the creation of hte
  new tab for taxes in this one `https://<tenant>.<BASE_DOMAIN>/reporting/costs/project`"

`<tax-portal>` is the national tax authority's e-service; its name is not
written here (distribution hygiene).

The download is done elsewhere: SPL-6389 (the browser seat that reads the
tax portal) and SPL-6394 (done; a private csitea project that files the
2026 documents and writes a weekly report). That project lives on the main
box only and is read here, never changed. Its standing constraint binds this
page: tax documents are finance data, for HUM-10, and the documents stay on
the main box (owner, csitea topic `fc0119cd`, msgs `072a9990` and
`42924894`).

## 2. What is measured (2026-11-25)

| question | answer | how it was read |
|---|---|---|
| How a Costs page gets its data | the bar `pages/reporting/costs.vue` draws `COSTS_PAGES` of `utils/reporting-costs.mjs` (Project, Total, Persons, Cloud, Tokens); each label reads `GET /v1/tenant/costs*`, scoped to the session's workspace by the hub | `grep -n "v1/" csi-spl-wui/src/utils/costs-labels.mjs` |
| Is a Costs page limited to one workspace today | no: `visibleCostsPages` filters only `operatorsOnly`, and no page sets it since SPL-5312 | `csi-spl-wui/src/utils/reporting-costs.mjs` |
| Is any Reporting page limited to one workspace | yes, Finance: the hub answers `GET /v1/view/netvisor/forecast` only in cnf `SPOOL_HUB_NETVISOR_WORKSPACE` (`csitea`, dev and prd), 404 elsewhere; the WUI draws the tab only after that read answered 2xx (`netvisorReaderProbe`) | `grep -n NETVISOR_WORKSPACE csi-spl-cnf/csi-spl/all.env.yaml` -> 1 line; `netvisorReader` in `hub/netvisor.go` |
| The second wall | rdb `0255` + `0260`: RESTRICTIVE `tenant_scope` plus a person-seat read (`netvisor_person_seat()`); no `operator_scope`, so the ops psql and the Reporting SQL tab read 0 rows | `0260_netvisor_member_read.sql` |
| How main-box data reaches the hub | the main-box sync posts `POST /v1/operator/netvisor/snapshots` as the env's service account (operatorAuth), into the cnf workspace only | `netvisor-finance-store.md` 5.2 |
| What the private tax project holds | read for this lane on the main box by c-001 (field names only, private project at `3564617`, msg `fc27a9a3`): one `index.tsv` per year, one row per filed document, columns `arrival_date, kind, type, tax_type, period, due_date, category, sha256, file_name`; `category` is one of `decisions`, `payments`, `balance`, `msgs`. The weekly report is computed from that index: new this week; changed (same kind, type, tax_type, period, new sha256); due in the next 30 days; decisions; payments and balance; open questions (a decision with no due date). **It carries no amounts, by design.** | relayed; not read by this lane (the CI box has no shell on the main box) |
| What exists for 2026 today | the 2026 folder holds only the fetch staging: no filed document, no `index.tsv`, no weekly report yet | same message, directory names only |

## 3. The data path

```text
main box: private tax project --files--> <year>/index.tsv (unchanged, read only)
main box: do_spl_tax_sync (csi-spl-orc, new) --POST, env SA--> hub /v1/operator/tax/snapshots
hub: SPOOL_HUB_TAX_WORKSPACE (cnf: csitea) only --> rdb tax_snapshots, tax_documents (RLS)
browser of an allowed person of that workspace --GET /v1/view/tax/overview--> Costs -> Taxes
```

1. **Sync, on the main box.** `do_spl_tax_sync` (csi-spl-orc; `TAX_INDEX_FILE`
   required, the `<year>/index.tsv` path; a dry run unless `DRY_RUN=0`)
   reads the index, keeps only the columns of section 4 (the header must
   name exactly the nine columns above, else it refuses: a changed index
   never leaks a new column), and posts one snapshot as the env's service
   account (`do_gcp_account`, pinned). It sends neither `file_name` nor a
   PDF: the documents stay on the main box. It logs the row count and the
   snapshot id, never a value. It runs right after the private project's
   weekly check, from the main box's cron; the private project needs no
   change.
2. **Hub.** `POST /v1/operator/tax/snapshots` (operatorAuth) files one
   snapshot into `SPOOL_HUB_TAX_WORKSPACE` only; with the cnf empty every
   tax route is 404. The newest snapshot is the one shown; the one before
   it gives "new" and "changed"; snapshots older than 26 weeks are pruned.
3. **Store.** One migration (number claimed with `do_rdb_migration_next`):
   `tax_snapshots` and `tax_documents`, both with `tenant_id` and RLS as rdb
   `0260`: RESTRICTIVE `tenant_scope`, a read for the allowed reader of Q1
   only, insert only under the ingest scope, no `operator_scope`.
4. **Read.** `GET /v1/view/tax/overview`, from a person's own browser
   session, the doors of `netvisorReader`: 403 for any `Authorization`
   header, an act-as clone, an agent seat, a time accountant or a channel
   guest (Q1 A: every other person of the workspace reads); in every
   workspace but the cnf one the 404 of an unknown `/v1/view/*` route. The answer holds the report's six sections, computed by the
   hub from the two newest snapshots.

## 4. What is stored

No amount, business id, tax number, file name, personal name or address:
the tables have no column for them.

| table | columns | notes |
|---|---|---|
| `tax_snapshots` | `snapshot_id`, `tenant_id`, `tax_year`, `taken_at`, `row_count`, `filed_by` (the service account) | one per sync |
| `tax_documents` | `snapshot_id`, `tenant_id`, `arrival_date`, `kind`, `doc_type`, `tax_type`, `period`, `due_date` (nullable), `category` (`decisions`, `payments`, `balance`, `msgs`), `content_sha256` | one per index row; text columns capped at 80 chars; `content_sha256` only tells "changed" apart from "new" |

## 5. What the page shows

A new label, **Taxes**, last on the Costs bar, path `/reporting/costs/taxes`,
its own chunk, every string a translation key in every locale. The header's
month range and currency do not apply and are hidden on it. Three blocks,
newest snapshot, with "as of <taken_at>":

1. **Due in the next 30 days**: date, type, tax type, period; overdue marked.
2. **This week**: new documents, changed documents, decisions, payments and
   balance, open questions (a decision with no due date), the weekly
   report's sections.
3. **2026 documents**: every row, newest first, filters by category and tax
   type.

No amount is shown: the report has none, and the documents stay on the main
box. "Open the document" is not offered.

## 6. The gate that hides it everywhere else

| layer | rule | test (red first) |
|---|---|---|
| WUI bar | `COSTS_PAGES` gets `taxes` with `taxOnly: true`; `visibleCostsPages` draws it only when `who.taxReader` holds; `pages/reporting/costs.vue` sets it after one `GET /v1/view/tax/overview` answered 2xx (the Finance probe) | unit: no `taxReader` -> no `taxes`; e2e mock: the csitea reader sees `costs-page-taxes`, a reader of another workspace does not, and `/reporting/costs/taxes` there shows the empty "not in this workspace" state, never data |
| hub | 404 unless the session's workspace = `SPOOL_HUB_TAX_WORKSPACE`; 403 for token, act-as, agent, time accountant, guest | hub tests, one per door (`tax_test.go`) |
| store | RLS: another workspace's transaction reads 0 tax rows; the operator scope reads 0 | `TestRLSCoversEveryTenantTable` takes both tables; a PostgreSQL test reads csitea's rows as another workspace and gets 0 (`PRE_PUSH_TIER=full`) |
| cnf | `SPOOL_HUB_TAX_WORKSPACE: "csitea"` in `all.env.yaml`; empty = off | tpl-gen parity |

Another workspace never gets the label, the data, a count, or an error that
says the data exists: the 404 body is byte for byte the one `view.go`
answers an unknown `/v1/view/*` route (`{"error":"not_found","detail":"no
such view"}`), tested in `TestTaxHubOtherWorkspaces`.

## 7. Never

Real values in git, fixtures, logs, spool messages or screenshots: the
fixtures and the mock are invented. No MCP tool and no spool message carries
a row of these tables. The private tax project's code and data are read
only, and only on the main box.

## 8. Build slices (after the go)

| slice | what | gate |
|---|---|---|
| S1 | migration, store, RLS tests | `PRE_PUSH_TIER=full` |
| S2 | hub routes (view + operator ingest), cnf key | api `run-all-tests.sh` |
| S3 | WUI label, page, mock, i18n in every locale | `pnpm run typecheck`, unit, `test:e2e` |
| S4 | `do_spl_tax_sync` and its test (an invented index) | orc suite |
| S5 | the main box's cron line for S4, after the private project's weekly check | holder, on the main box |

The page shows data only once the private project has filed its first 2026
document; until then it says "no tax documents filed yet".

## 9. The owner's questions (one form, posted by the holder)

Recommended: **B** on Q1 (the standing finance rule), **A** on Q2.

```poll
Who sees the Taxes page in csitea?
(A) Every person of csitea, as Finance (agents never)
(B) Only HUM-10, by id (the finance rule of 2026-10-10)
How often does the page refresh?
(A) Weekly, after the weekly tax check
(B) Daily
```

## 10. As built (v0.2)

| slice | where | tests (n=1, this tree) |
|---|---|---|
| S1 | rdb `0324_tax_documents.sql`; store `tax.go`, `tax_postgres.go` | `tax_test.go` (read by every door, red control: `tax_read` dropped, writes, prune); the census, RLS and SQL-tab registries; Postgres 16 |
| S2 | hub `tax.go`, wire `tax.go`, `openapi.json`; cnf `SPOOL_HUB_TAX_WORKSPACE: "csitea"` | hub `tax_test.go` (doors, other workspaces, ingest, cnf off) on Postgres; `tax_internal_test.go` |
| S3 | WUI `utils/reporting-tax.mjs`, `pages/reporting/costs/taxes.vue`, the label in `utils/reporting-costs.mjs` (`taxOnly`), 19 locales | `tests/unit/reporting-tax.test.mjs`, `reporting-costs.test.mjs`; e2e `reporting-costs-taxes.test.mjs` |
| S4 | orc `do_spl_tax_sync` | `spl-tax-sync.tst.sh` (an invented index) |

What the hub computes for the page, from the newest snapshot of the year
and the one before it (`taxOverview`):

- **status**: `new` when the row's content hash was not in the snapshot
  before and its key (kind, type, tax type, period) was not either;
  `changed` when the key was there with another hash; empty when the hash
  was there, or when there is no snapshot before (the first sync marks
  nothing).
- **due_soon**: the due date is within 30 days of today, either way, so an
  overdue document stays in "Due" for 30 days; **overdue**: before today.
- **open_question**: a `decisions` row with no due date.
- Documents newest arrival first; `?year=YYYY` reads another filed year,
  `years` lists them.

The ingest: an unknown field (a file name, an amount) is 400; the same
snapshot id twice is 409; snapshots of a year older than 26 weeks before
the newest are pruned, the two newest always kept.

The sync (S4): `ENV=prd TAX_INDEX_FILE=<tax project>/<year>/index.tsv
DRY_RUN=0 ./run -a do_spl_tax_sync`, from the main box's checkout, after
the private project's weekly check; the cron line is S5, the holder's.
Dates in the index may be `YYYY-MM-DD` or `D.M.YYYY`.

The WUI mock plays the tax workspace only while the browser's
`spool.mock.tax_workspace` holds `here`; otherwise it plays any other
workspace (no label, the neutral line), so the other mock pages keep their
five labels.
