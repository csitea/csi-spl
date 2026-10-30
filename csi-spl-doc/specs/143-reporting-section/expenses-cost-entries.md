# Expenses: typed Cloud infra and HR cost entries (step B, SPL-4383)

Owner HUM-10, t1 4f48f878 (msg b0ccc0aa): "On this page there should be
different types for the INSERTION Of at least the following type of costs - AI
costs , cloud infra cost , HR costs", "so at least 3 different tabs on this
page" (msg 50d84663); the page is named **Expenses** (poll 9fbea87a, A).

Step A (SPL-4382) puts the page at `/expenses` with three tabs: `/expenses/ai`
(the paid AI items of rdb 0205, `/v1/operator/fleet-tokens/paid`),
`/expenses/cloud` and `/expenses/hr`. Step B, this page, is the storage and the
hub routes behind the Cloud and HR tabs; their entry forms follow once step A
has landed.

## 1. Storage: rdb 0245 `cost_entries`

One row is one cost of one month, operator scope only (no `tenant_id`, RLS
policy `operator_scope`, like `fleet_token_paid_items`).

| column | rule |
|---|---|
| `type` | `cloud` or `hr` (CHECK) |
| `label` | 1..100 characters; an HR row names the role or the contract |
| `amount` | `numeric(14,4)`, above 0 |
| `currency` | ISO 4217, `^[A-Z]{3}$` |
| `period` | the month, stored as its 1st day (CHECK) |
| `note` | at most 2000 characters |
| `created_by`, `created_at` | the operator caller's hub id, the insert time |

## 2. Hub routes

The door of `GET /v1/operator/fleet-tokens`: the operator workspace's admin
or the operator service account; anyone else is answered 403
`operator.workspaces` (`TestCostEntryRoutes`).

| route | answer |
|---|---|
| `GET /v1/operator/cost-entries?type=cloud\|hr&month=YYYY-MM` | `{entries}`, period then created_at order; an absent filter matches every row; a bad one is 400 |
| `POST /v1/operator/cost-entries` `{type, label, amount, currency, period: YYYY-MM, note?}` | 201, the entry; a bad one is 400 `bad_cost_entry` |
| `DELETE /v1/operator/cost-entries/{id}` | 204; an unknown id is 404 |

Code: `csi-spl-api/src/go/spool-hub-api/internal/store/cost_entries.go`
(Memory), `cost_entries_postgres.go`, `internal/hub/cost_entries.go`; the
operations in `internal/hub/openapi.json`.

## 3. Tests

- `TestCostEntryStoreCRUD` (Memory and Postgres): create, list by type and
  month, delete, a bad entry is never stored.
- `TestCostEntryRLS` (Postgres): no scope and a workspace scope read no row
  and may not insert one; the operator scope reads it (control).
- `TestCostEntryRoutes`: the 403s, then the admin's create, filters, delete.

<!-- version: 0.1.0 · updated: 2026-10-30 -->
