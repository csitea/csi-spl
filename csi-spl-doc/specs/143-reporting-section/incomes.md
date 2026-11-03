# Incomes: the workspace's invoiced income, per month (SPL-4697)

Owner HUM-10, csitea #invoicing, topic 450418ab (msg e793f8d0): "use the mcp
to fetch all of those from my email for the 2026 years , we will add a new tab
i nthe reporting called incomes". "Those" are the self-billing invoices a
staffing agency issues to the workspace's company each month (one PDF per
month: hours, unit price, net, VAT, total).

Status: **Reviewed v0.2.0** (c-003, GO with notes N1-N4; design rule 0 added). Epic SPL-2400.

## 0. Design rule: analytics, not bookkeeping

Owner HUM-10, csitea topic 450418ab (msg 95d0a9e7): "идеята е NetVisor да си
продължава да си е счетоводната система , но spool-hub csitea workspace-a ще
е аналитиката на финансите" ("the idea is that Netvisor stays the accounting
system, while the spool-hub csitea workspace is the finance analytics").

- Netvisor (spec 125) stays the source of record. The Incomes tab reads and
  analyses copies of invoices that were already issued; it never issues,
  books, pays or corrects one, and nothing here writes back to Netvisor or a
  bank.
- A wrong row is fixed at the source and imported again (the upsert replaces
  it); the hub has no edit form.

## 1. What the tab shows

`/reporting/incomes`, a new tab of the Reporting section (spec 143 1.2,
`csi-spl-wui/src/utils/reporting-tabs.mjs`), after Marketing.

- A year picker (the years that have rows; the newest first).
- One row per month of that year (the month as `YYYY-MM`, dates are ISO
  everywhere in the WUI): the month, the invoice number, the issue
  date, the due date, the hours, the net, the VAT and the total, in the row's
  currency. A month with no invoice shows a dash, never a zero, so a missing
  invoice is visible.
- A year total row: the sum of hours, net, VAT and total. Rows of different
  currencies are summed per currency (one total row each); there is no FX
  conversion on this tab.
- An empty year shows one line, "No income recorded for <year>".

Figures are shown as stored; the tab computes only the sums.

## 2. Where the rows live: the hub DB, never git

rdb `<head+1>_income_invoices.sql`, a tenant table under FORCE RLS on
`tenant_id` like every tenant table (developer guide 2.6.4). One row is one
invoice.

| column | rule |
|---|---|
| `tenant_id` | the workspace |
| `invoice_no` | 1..64 characters; UNIQUE per workspace (the import's upsert key) |
| `payer` | 1..100 characters: who pays (the agency or the client) |
| `period` | the month worked, stored as its 1st day (CHECK) |
| `issue_date`, `due_date` | dates; `due_date >= issue_date` |
| `hours` | `numeric(8,2)`, >= 0 |
| `unit_price` | `numeric(14,4)`, >= 0 |
| `net`, `vat`, `total` | `numeric(14,2)`; CHECK `net + vat = total` |
| `vat_pct` | `numeric(5,2)`, 0..100 |
| `currency` | ISO 4217, `^[A-Z]{3}$` |
| `source` | `import` (later `email`) |
| `created_at`, `updated_at` | timestamps |

No PDF is stored; the invoice number is the reference back to it. csi-spl is a
public repository: no figure, payer name or invoice appears in git, a test
fixture, a log line or a commit message. Tests use synthetic rows
(`INV-0001`, `ACME`).

## 3. Who may see it: the workspace's owners only

`TenantOwner` in the workspace, the gate of `embed_admin.go` and
`marketing_posts.go` (`biz_owner` is the owner role). An admin, any other
member and the operator are answered 403 `tenant.owner`; the tab is not drawn for them (a new
`ownerOnly` flag in `reporting-tabs.mjs`, read from `who.owner`). The hub's
403 is the control; the hidden tab is only a courtesy.

## 4. Hub routes

| route | caller | answer |
|---|---|---|
| `GET /v1/reporting/incomes?year=YYYY` | the workspace owner (member session) | `{year, years, invoices}`; `years` = the years that have rows, newest first; no `year` = the newest of them (else this year); a bad year is 400 |
| `PUT /v1/operator/incomes` `{tenant, invoices: [...]}` | the operator service account (a Bearer id token) or the operator workspace's admin (a member session): `fleetLoadCaller`, the gate of the other operator doors | upsert by (`tenant`, `invoice_no`), `{inserted, updated}`; one bad row refuses the whole batch, 400 `bad_income_invoice` with its index |

The operator route is how rows get in; the owner's route only reads.
The admin's Reporting SQL tab (`POST /v1/reporting/sql`) does not open
`income_invoices`: it is on the store's owner-only list
(`reportingSQLOwnerOnly`, `internal/store/reporting_sql.go`), so an admin's
query naming it is 400 `forbidden_relation`. Without that list every
FORCE-RLS workspace table is open to the tab, and an admin would read the
rows the owner's route refuses them. Code:
`internal/store/income_invoices.go` (Memory), `income_invoices_postgres.go`,
`internal/hub/reporting_incomes.go`, `internal/hub/openapi.json`.

## 5. How rows get in

1. Now: `cd csi-spl-orc && ENV=<env> INCOMES_TENANT=<slug> INCOMES_FILE=<tsv> ./run -a do_spl_incomes_import`.
   It reads a TSV (the columns of section 2, one header line) from a path
   outside git, validates every row with the table's rules, prints the row
   count and the year span, and with `DRY_RUN=0` sends the batch to
   `PUT /v1/operator/incomes`. Running it twice changes nothing. It never
   prints a figure.
2. The TSV is made from the owner's mailbox by an agent with the mail
   connector (read only) and kept in that lane's private dispatch work dir on
   the finance box.
3. Later, not in this build: the hub fetches the invoices from the mailbox
   itself (`source = email`).

## 6. Tests

- `TestIncomeInvoiceStore` (Memory and Postgres): an upsert inserts, then
  updates; list by year; a row that breaks a CHECK is never stored.
- `TestIncomeInvoiceRLS` (Postgres): workspace A reads 0 rows of workspace B,
  and no scope reads none (control: A reads its own).
- `TestReportingIncomesRoutes`: owner 200; admin, member and operator 403;
  operator PUT 200, a non-operator PUT 403, a bad row 400.
- `csi-spl-orc/src/bash/tests/spl-incomes-import.tst.sh`: a bad TSV row is
  refused before any call; a dry run posts nothing; the batch body (stub hub).
- WUI: a `reporting-tabs` unit test (the tab only for `who.owner`); an e2e
  that draws the months, the dash for a missing month and the year total
  (mock hub, synthetic rows).

<!-- version: 0.2.0 · updated: 2026-11-03 -->
