# Costs: a cost assigned or split to workspaces by hand (SPL-5291)

Status: **Draft v0.1, the design sent to the dispatch holder; nothing built.**
Issue: SPL-5291 (epic SPL-2373). Discussion: t1 `41a74806` (#spool-hub-ui,
owner HUM-10). Sibling: `c002-refactor-reporting-costs-four-labels` builds
the four labels (Total, Persons, Cloud, Tokens) per workspace (answer A);
this page is answer B.

Owner HUM-10, t1 41a74806: "and each workspace should have those settable
and allocate-able separately for them". Asked what that means (poll
`0c5e94b4`), the 05:48Z answer was **C, "Both A and B"**; B reads: "A cost
(e.g. a shared cloud bill, a person's hours) can be assigned or split to
workspaces by hand, and each workspace's page shows its share".

Read on origin/master `f6c253f35` (2026-11-11): the estate's costs are
operator scope (`cost_lines` rows with `tenant_id` NULL, rdb 0245
`cost_entries`, the paid AI items of rdb 0205), and only the operator
workspace's admin reads them (`hub/cost_read.go`, `readsOperatorEstate`). A
customer workspace reads its own rows, its lanes' token burn and its
automatic AI share ([costs-redesign.md](costs-redesign.md) 3.3.1). Nothing
assigns a cloud bill or an hr entry to a workspace today.

## 1. What is allocated: an item, per label

An **item** is one estate part of the month answer, keyed the way the hub
already sums it: `(source, project_or_vendor, kind)`. The key is stable
across months, so a monthly bill entered again each month keeps its split.

| label | items (today's sources) | example key |
|---|---|---|
| Persons | the `hr` cost entries (the estate answer's `human` list) | `cost_entry / <entry label> / hr` |
| Cloud | the GCP parts of `cost_lines`, the `cloud` cost entries | `<gcp source> / <project> / <service>`, `cost_entry / <invoice label> / cloud` |
| Tokens | the paid AI items, `ai_paid` | `ai_paid / <agent type> / <plan>` |

The label follows from the source (the sibling lane's mapping) and is never
stored, so an item cannot sit in two labels.

## 2. Storage: rdb `0275_cost_allocations.sql`

Operator scope, like `cost_entries`: no `tenant_id`, RLS policy
`operator_scope`; the workspace a share goes to is a column, not the row's
tenant.

| column | rule |
|---|---|
| `id` | uuid |
| `source`, `project_or_vendor`, `kind` | the item key (section 1), each 1..200 characters |
| `from_month` | the first month the split holds, stored as its 1st day (CHECK); it holds until a later `from_month` of the same item |
| `workspace_id` | uuid, FK `tenants(id)`; the operator workspace itself is allowed (the estate keeps that share); NULL only in a removal row |
| `share_bp` | basis points, 1..10000 (0 only in a removal row) |
| `created_by`, `created_at` | the operator caller's hub id, the insert time |

UNIQUE `(source, project_or_vendor, kind, from_month, workspace_id)`. One
**split** is every row of one `(item, from_month)`; their `share_bp` sum to
10000. The hub writes a split in one transaction (delete that item's rows of
that month, insert the new ones), so a half-written split is never read.
Earlier months keep the split that held then: a change never rewrites a
closed month (spec 123 4.5).

**Assign** is a split of one row at 10000. **Remove** is a split with no
share from that month on, stored as one removal row (`workspace_id` NULL,
`share_bp` 0).

## 3. Who may set it

Only the **operator workspace's admin** (or the operator service account),
behind the door of `GET /v1/operator/cost-entries` (403
`operator.workspaces` otherwise). A split moves an estate cost into customer
workspaces' totals, so no customer workspace's admin may set or change one,
not even its own share. A customer workspace's members with `costs.read`
see their share, read only.

## 4. Hub API

| route | answer |
|---|---|
| `GET /v1/operator/cost-allocations?month=YYYY-MM` | `{month, items, workspaces}`: every estate item of that month (the month answer's parts and `human` rows, with their USD, EUR and second micros) and, per item, the split in force (`from_month`, `shares: [{workspace_id, name, share_bp}]`, empty when none); `workspaces` lists where a share may go |
| `PUT /v1/operator/cost-allocations` `{source, project_or_vendor, kind, from_month: YYYY-MM, shares: [{workspace_id, share_bp}]}` | 200, the split; `shares: []` removes it from that month on; a sum other than 10000, a duplicate or unknown workspace, a share outside 1..10000 or a month not started is 400 `bad_cost_allocation` |

**The workspace read** (`GET /v1/tenant/costs`, scope `workspace`) adds one
part per item allocated to it: source `allocated`, the item's
`project_or_vendor` and `kind`, `allocated_source` (the item's own source,
so the Web UI files it under its label), `share_bp`, and its money
`floor(item_money * share_bp / 10000)` per currency; the rounding remainder
stays with the estate. It counts in that workspace's total and `pct`. The
estate answer keeps the full amounts (a share is an attribution, never
subtracted, as in 3.3.1); each estate part gains `allocation` (its shares),
so the operator admin sees the split on the Costs page.

## 5. How it is shown

- **Settings -> Cost allocation** (`tenant_settings.cost_allocation`), in the
  operator workspace only, shown when the probe `GET
  /v1/operator/cost-allocations` answers 200 (the Fleet load section's rule,
  `csi-spl-wui/src/utils/tenant-settings-nav.ts`). A month picker, then the
  items under Persons, Cloud and Tokens, each with its amount and its split
  ("Workspace A 60 % · Workspace B 40 %", or "Not allocated"). **Edit**
  opens one row per workspace with a percentage; the sum shows live and
  Save stays disabled until it is 100 %. Assigning to one workspace is the
  same form with one row at 100 %. The split holds from the picked month on.
- **A workspace's Costs page** (only after the sibling lane lands, through
  its per-workspace function): each allocated item is a row under its
  label, marked "Allocated: 40 % of <item>", and is in that label's pie and
  table.
- **The estate's Costs page**: an allocated item's row names its split; the
  totals do not change.
- Help: a `csi-spl-doc/doc/help/` page for Settings -> Cost allocation.

## 6. Tokens: the automatic share and a hand split

A customer workspace already gets an automatic share of the paid AI items
by its lanes' tokens (`ai_share`, 3.3.1). **Proposed**: a hand split of an
`ai_paid` item replaces the automatic share of that item from its
`from_month` on (no double count); an item without a hand split keeps the
automatic share (question 1).

## 7. Tests

- Store (Memory and Postgres): a split's write and read by month, the
  replace in one transaction, the sum check; RLS: no scope and a workspace
  scope read and write no row, the operator scope does (control).
- Hub: the 403s, the 400s (a sum of 9999, a duplicate workspace), a split
  read back; the workspace answer's `allocated` part with floor rounding
  (red control: the floor removed, three shares of 3333 bp plus one of 1
  exceed the item); a workspace outside a split sees no share of it.
- Web UI: unit (the sum check, the request body), e2e on the mock bundle at
  1440 and 390 px: set a 60/40 split, Save disabled at 90 %, the share on
  the workspace's page; every new string in all locales, the agy review
  last.

## 8. Questions for the holder (answer, or ask the owner)

1. Tokens (section 6): may a hand split replace the automatic token share
   of a paid AI item, or are Tokens left out of hand allocation?
2. Months: a split holds from a picked month on (proposed), or for every
   month, past ones too?
3. Who sets a split: only the operator workspace's admin (proposed,
   section 3), or may a customer workspace's admin also set splits among
   workspaces it administers?

<!-- version: 0.1.0 · updated: 2026-11-11 -->
