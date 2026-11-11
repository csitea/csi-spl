# Costs: a cost assigned or split to workspaces by hand (SPL-5291)

Status: **Draft v0.2, revised on the owner's answers (poll `01cbbdea`);
nothing landed.** Issue: SPL-5291 (epic SPL-2373). Discussion: t1
`41a74806` (#spool-hub-ui, owner HUM-10). Sibling:
`c002-refactor-reporting-costs-four-labels` builds the four labels (Total,
Persons, Cloud, Tokens) per workspace (answer A); this page is answer B.

Owner HUM-10, t1 41a74806: "and each workspace should have those settable
and allocate-able separately for them". Asked what that means (poll
`0c5e94b4`), the 05:48Z answer was **C, "Both A and B"**; B reads: "A cost
(e.g. a shared cloud bill, a person's hours) can be assigned or split to
workspaces by hand, and each workspace's page shows its share".

The design questions (v0.1 section 8), answered by the owner in poll
`01cbbdea`, msg `9e3e49f9` (09:28:14Z), verbatim:

> Answer 1: B — No: Tokens stay automatic; only Persons and Cloud can be split by hand
> Answer 2: B — Every month, past ones too
> Answer 3: B — Also a customer workspace's admin, among the workspaces they administer

Read on origin/master `f6c253f35` (2026-11-11): the estate's costs are
operator scope (`cost_lines` rows with `tenant_id` NULL, rdb 0245
`cost_entries`), and only the operator workspace's admin reads them
(`hub/cost_read.go`, `readsOperatorEstate`). A customer workspace reads its
own rows, its lanes' token burn and its automatic AI share
([costs-redesign.md](costs-redesign.md) 3.3.1). Nothing assigns a cloud bill
or an hr entry to a workspace today.

## 1. What is allocated: an item of Persons or Cloud

An **item** is one estate part of the month answer, keyed the way the hub
already sums it: `(source, project_or_vendor, kind)`. The key is stable
across months.

| label | items (today's sources) | example key |
|---|---|---|
| Persons | the `hr` cost entries (the estate answer's `human` list) | `cost_entry / <entry label> / hr` |
| Cloud | the estate GCP parts of `cost_lines`, the `cloud` cost entries | `<gcp source> / <project> / <service>`, `cost_entry / <invoice label> / cloud` |

**Tokens are never split by hand** (answer 1 B): the paid AI items
(`ai_paid`) and the token burn (`fleet_tokens`) keep the automatic share by
tokens (3.3.1). A split of a Tokens item is refused, 400.

## 2. Storage: rdb `0275_cost_allocations.sql`

Operator scope, like `cost_entries`: no `tenant_id`, RLS policy
`operator_scope`; the workspace a share goes to is a column, not the row's
tenant.

| column | rule |
|---|---|
| `source`, `project_or_vendor`, `kind` | the item key (section 1), each 1..200 characters |
| `workspace_id` | FK `tenants(tenant_id)` ON DELETE CASCADE; the operator workspace itself is allowed (the estate keeps that share) |
| `share_bp` | basis points, 1..10000 |
| `created_by`, `created_at` | the caller's hub id, the write time |

PRIMARY KEY `(source, project_or_vendor, kind, workspace_id)`. One **split**
is every row of one item; their `share_bp` sum to 10000. The hub writes a
split in one transaction, so a half-written split is never read.

**Every month, past ones too** (answer 2 B): a split has no month. It holds
for every month the item appears in, and a change re-attributes the past
months as well. Nothing is stored per month: the month answer applies the
split in force when it is read. (The estate's totals never change, so a
closed month's estate total still reads the same; only its attribution to
workspaces moves.)

**Assign** is a split of one row at 10000. **Remove** deletes the item's
rows.

## 3. Who may set it (answer 3 B)

| caller | may |
|---|---|
| the operator workspace's admin, the operator service account | set any split of any item among any live workspaces (`PUT /v1/operator/cost-allocations`) |
| a customer workspace's admin | re-split, among the workspaces **they administer**, only the share those workspaces already hold (`PUT /v1/tenant/cost-allocations`) |
| anyone else | nothing (403); members with `costs.read` see their workspace's share, read only |

**"The workspaces they administer"**, in the hub's role model: the set
`A(person)` of workspaces W where the **signed-in person** (a `HUM-*` of a
signed session, never an agent seat, an act-as clone or a service account)
has a membership (`Memberships(hum)`, rdb 0006 / 0201) whose role set holds
`admin`, and W is live (not suspended, not archived). It is read from the
membership rows at the request, never from a header or the body. The
caller must also be an admin of the workspace they call from.

**What a customer admin can never do** (the security rule). For their PUT,
with `old` the item's split in force and `new` the body:

1. every share of a workspace outside `A` is the same in `new` as in
   `old` (not added, not removed, not changed);
2. `new` names no workspace outside `A` that `old` does not;
3. the sum of `A`'s shares is the same in `new` as in `old` (no cost moved
   back to the estate or out to a workspace outside `A`);
4. `old` holds a share in at least one workspace of `A` (an item nobody
   gave them is not theirs to split).

So a customer admin can only move cost between workspaces they administer.
The check runs inside the write's transaction, the item's rows locked
(`SELECT ... FOR UPDATE`), so an operator change in between cannot be
overwritten by a stale read. A refusal is 403 `cost_allocation.outside`
naming the rule it broke.

What a customer admin sees (`GET /v1/tenant/cost-allocations?month=`): the
items that hold a share in `A`, each with its label, the share of each
workspace of `A` and its money in that month, and `held_bp` (the sum `A`
holds). Never the item's whole amount, the estate's total, or the shares of
workspaces outside `A`.

## 4. Hub API

| route | answer |
|---|---|
| `GET /v1/operator/cost-allocations?month=YYYY-MM` | `{month, items, workspaces}`: every Persons and Cloud estate item of that month (with its money) and its split (`shares: [{workspace_id, share_bp}]`, empty when none); `workspaces` lists where a share may go |
| `PUT /v1/operator/cost-allocations` `{source, project_or_vendor, kind, shares: [{workspace_id, share_bp}]}` | 200, the split; `shares: []` removes it; a Tokens item, a sum other than 10000, a duplicate or unknown workspace or a share outside 1..10000 is 400 `bad_cost_allocation` |
| `GET /v1/tenant/cost-allocations?month=YYYY-MM` | the customer admin's view (section 3) |
| `PUT /v1/tenant/cost-allocations` | the same body; the section 3 rules, 403 `cost_allocation.outside` |

**The workspace read** (`GET /v1/tenant/costs`, scope `workspace`) adds one
part per item allocated to it: source `allocated`, the item's
`project_or_vendor`, `kind` and origin, `allocated_source` (the item's own
source), `share_bp`, and its money `floor(item_money * share_bp / 10000)`
per currency; the rounding remainder stays with the estate. A Cloud share
counts in that workspace's total and `pct`; a Persons share is a row of its
`human` list (the estate's SPL-4840 rule). The estate answer keeps the full
amounts (a share is an attribution, never subtracted, as in 3.3.1); each
estate part gains `allocation` (its shares).

## 5. How it is shown

- **Settings -> Cost allocation** (`tenant_settings.cost_allocation`). In
  the operator workspace (probe `GET /v1/operator/cost-allocations` 200,
  the Fleet load section's rule): a month picker (for the amounts only: a
  split holds for every month), the items under Persons and Cloud, each with
  its amount and its split ("Workspace A 60 % · Workspace B 40 %", or "Not
  allocated"). **Edit** opens one row per workspace with a percentage; the
  sum shows live and Save stays disabled until it is 100 %. In a customer
  workspace whose admin administers two or more workspaces holding a share
  (probe `GET /v1/tenant/cost-allocations` with at least one item): the
  same list with only their workspaces, Save disabled until their rows sum
  to what they hold.
- **A workspace's Costs page** (only after the sibling lane lands, through
  its per-workspace function): each allocated item is a row under Persons
  or Cloud, marked "Allocated: 40 % of <item>", and is in that label's pie
  and table.
- **The estate's Costs page**: an allocated item's row names its split; the
  totals do not change.
- Help: a `csi-spl-doc/doc/help/` page for Settings -> Cost allocation.

## 6. Tests

- Store (Memory and Postgres): a split's write and read, the replace in one
  transaction, the sum check, a removal; RLS: no scope and a workspace scope
  read and write no row, the operator scope does (control).
- The customer admin rules (Postgres and Memory): a person admin of W1 and
  W2 moves 60/40 to 30/70 (allowed); adds W3 where they are a developer
  (refused, rule 2); changes W3's share (rule 1); lowers W1 + W2's sum
  (rule 3); splits an item with no share in W1 or W2 (rule 4); an agent
  seat, an act-as clone and a developer of W1 (403). Red control: rule 1
  removed, the W3 case is stored.
- Hub: the 403s, the 400s (a Tokens item, a sum of 9999), a split read back;
  the workspace answer's `allocated` part with floor rounding (red control:
  the floor removed, three shares of 3333 bp plus one of 1 exceed the
  item); a past month carries the split too (answer 2 B); a workspace
  outside a split sees no share of it.
- Web UI: unit (the sum check, the request body), e2e on the mock bundle at
  1440 and 390 px: set a 60/40 split, Save disabled at 90 %, the share on
  the workspace's page; every new string in all locales, the agy review
  last.

<!-- version: 0.2.0 · updated: 2026-11-11 -->
