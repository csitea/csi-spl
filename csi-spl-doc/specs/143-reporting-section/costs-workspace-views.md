# Costs: each workspace's view rules, their legend, and no Google Cloud double count (SPL-6086)

Status: **v0.1 (2026-11-20), design only, on a review branch; nothing is
built.** Issue: SPL-6086 (epic SPL-2373). Discussion: csitea topic
`bc9956bf` (#csi-fina, owner HUM-10). It changes the allocation of
[costs-allocation.md](costs-allocation.md) (sections 1-7) for the
workspaces that carry a view rule, and the Google Cloud reading of
[spec 123](../123-cost-tracking/spec.md) section 15.6.

**Why spec 143 and not 123.** Spec 123 is how a cost gets into the hub (the
readers, the export, the invoice import, the hr entries). What a workspace
reads of the stored costs, and how the Costs pages show it, is spec 143's:
its four labels (costs-redesign.md 3.9) and the hand allocation
(costs-allocation.md) live here, and this page replaces part of the latter.
The one ingest-side change, how a Google Cloud invoice entry and the billing
export are read together (section 4), is written here because it is a read
rule, not an ingest rule; spec 123 15.6 gets a one-line pointer.

## 1. The owner's words (HUM-10, csitea topic `bc9956bf`, 2026-11-20, verbatim)

- `b27d7ba8`: "пренареждане на отчитането на разходите" (rearranging the
  cost reporting).
- `3046f23e`: "https://spool-hub.ai/reporting/costs/cloud?month=2026-10 is
  it the case that the manual amount for the google costs is duplicateing
  the actual amount - if that is the case remove it"
- `3183590c`: "Also I would prefer all of the costs for human resources to
  be shown in the csitea workspace and the spool-hub workspace to get only
  30% of the total human costs as well as ONLY the cloud costs from the
  csi-spl-* gcp projects"
- `7616b11a`: "and 70% of the total tokens"
- `5d7912cd`: "the csitea workspace should have all of the costs for all of
  the gcp projects , all of the human costs and all of the tokens"
- `2e5347e9`: "and there should be a legend which displayes those rules
  inthe diagrams windows"

Read together: csitea shows **everything**; spool-hub (workspace `t1`, the
operator workspace) shows **a part of the same costs**. The two pages
overlap by design: 100 % + 30 % of the human costs and 100 % + 70 % of the
tokens. This is a **view**, not a **partition**, and that is the one thing
today's model cannot express (section 2.4).

## 2. Today: where each cost kind is read, and how a workspace scopes it

Read on `cbbc11996` (origin/master, 2026-11-20) and in prd (read only, as
the prd project service account, 2026-11-20 ~16:30Z; counts and days only,
no amount is written here).

### 2.1 The one read

`GET /v1/tenant/costs?month=` (`csi-spl-api/src/go/spool-hub-api/internal/hub/cost_read.go:161`,
`handleCostRead`) answers every Costs page. It decides one thing first:

- `estate` (`cost_read.go:185`, `readsCostEstate` in `hub/operator_read.go:58`):
  true for an admin or product owner of the operator workspace (`t1`) and
  its accountants, never for an act-as clone. The estate reads every cost
  with `tenant_id` NULL, under the operator RLS scope
  (`store/cost_read.go:172`, `asOperator`).
- otherwise the caller's own workspace, under its tenant RLS scope
  (`store/cost_read.go:174`, `inTenant`), plus what is allocated to it.

So the operator workspace's admin reads the whole estate on `t1`, and
`csitea`, a customer workspace, reads only what was allocated to it.

### 2.2 Each cost kind

| kind | stored in | estate read (t1 admin) | a customer workspace (csitea) |
|---|---|---|---|
| GCP billing-export lines | `cost_lines` source `gcp`, origin `billing_export`, `tenant_id` NULL (written by `do_spl_estate_cost_read`, `csi-spl-iac/src/bash/run/spl-estate-cost-read.func.sh:218`) | all, `store/cost_read.go:163` `CostMonthRead` | the items allocated to it, `hub/cost_allocations.go:367` `costAllocatedParts`, each at `floor(amount * share_bp / 10000)` (`costAllocShare`, `:401`) |
| cloud cost entries (an invoice by hand: Google Cloud, Google Workspace, AWS, an app) | `cost_entries` type `cloud` (rdb 0245) | all, `hub/cost_read.go:299` `costEntryMonthParts` (the `spend` list) | the allocated ones, as above |
| hr cost entries and components | `cost_entries` type `hr`, `hr_people` (rdb 0280) | all, `costEntryMonthParts` (the `human` list), summed per component by `hrReportEntries` (`cost_read.go:422`) | a person split's share, `costPersonSplitParts` (`hub/cost_splits.go:203`, costs-allocation.md 7.5), or an item split |
| paid AI (tokens money) | `ai_paid` items | all, `aiCostParts` (`cost_read.go:339`) | the tokens split when set (`costSplitAIParts`, `hub/cost_splits.go:168`), else the automatic share by tokens (costs-redesign.md 3.3.1) |
| token burn (counts and list price, never added to money) | `fleet_tokens` per workspace | every workspace (`workspaceTokenParts`, `hub/workspace_tokens.go:145`) | its own (`costBurnOf`, `cost_read.go:288`) |

The month answer's `total` adds every part (`cost_read.go:386-388`), the
hand-entered ones included, because `costReadBody` appends them to the cost
lines first (`cost_read.go:268`).

### 2.3 Where the Cloud sum is made (the page /reporting/costs/cloud)

The page is `csi-spl-wui/src/components/reporting/costs/CostsLabel.vue`;
its rows come from `costsLabelRows` (`csi-spl-wui/src/utils/costs-labels.mjs:123`):

- `costLabelOf` (`costs-labels.mjs:37`) puts both a `cost_entry` part of
  kind other than `hr` and a `gcp` part under **Cloud**;
- `cloudItemOf` (`costs-labels.mjs:71`) makes a Google Cloud invoice entry
  its own row (`entry:<label>`) beside one row per GCP project;
- `withShares` (`costs-labels.mjs:150`) and `costsColumnTotals`
  (`costs-labels.mjs:176`, the table footer, `CostsLabel.vue:137`) add them.

Nothing in the hub or the WUI knows that the invoice entry and the export
lines are the same money. The hub adds them in `total` (2.2), the WUI adds
them in the Cloud rows, the pie and the footer.

### 2.4 Measured in prd (2026-11-20, read only)

| fact | how it was read | result |
|---|---|---|
| cloud cost entries of 2026-10 | `cd csi-spl-orc && ENV=prd COST_TYPE=cloud COST_MONTH=2026-10 ./run -a do_spl_hub_cost_entries` | 5 entries; one is a Google Cloud invoice entry for one billing account, for the whole month |
| months with a Google Cloud entry | the same, no month | 15 entries in 2026-01..10, of two billing accounts (account A every month, account B 2026-05..09) |
| billing-export lines of 2026-10 | `cost_lines` source `gcp`, read only, operator scope (`count(DISTINCT day)`) | days 2026-10-23..31 only: **9 of 31 days**, 26 projects |
| billing-export lines of 2026-11 | the same | days 2026-11-01..19, 19 of 19 so far, 26 projects |
| `cost_coverage` rows of source `gcp`, 2026-10 | the same | **27** days marked read, while lines exist on 9: coverage is "the day was read", not "the day has the export" |
| estate items of 2026-10 and their splits | `GET /v1/operator/cost-allocations?month=2026-10` | 147 gcp items: 117 allocated `csitea` 10000, 30 (the `csi-spl-*` projects) `t1` 10000; 5 cloud entries `csitea` 10000; the hr items no split |
| the instance splits | `GET /v1/operator/cost-splits` | tokens `csitea` 3000 / `t1` 7000; no person split |

So, for 2026-10:

- **The Google Cloud figure is counted twice for 23-31 October**: in the
  invoice entry (the whole month) and in the export lines (those 9 days).
  For 1-22 October only the invoice entry holds it. The duplication is
  partial, not whole (section 4.4).
- Today's prd allocation is a partition (every item 100 % to one
  workspace; tokens 30 / 70): csitea sees the non-`csi-spl-*` projects,
  t1 the `csi-spl-*` ones, and the estate (t1's admin) everything. The
  owner's rules need csitea to see everything and t1 a part, which a split
  summing to 10000 cannot say.

What was not checked: which billing account the export table carries
(`spl-estate-cost-read.func.sh:106` takes the first `gcp_billing_export_v1_*`
table in the dataset, so it reads one account). Section 4.2 makes that a
precondition instead of an assumption.

## 3. The rules as data: a workspace's view

### 3.1 What a view rule is

A **view rule** says what part of the estate's costs one workspace shows,
for one label. A workspace with at least one view rule reads its Costs
pages through its rules only; a workspace with none reads as today
(2.1-2.2: its own rows and its allocations).

| field | rule |
|---|---|
| `workspace_id` | FK `tenants(tenant_id)` ON DELETE CASCADE; any live workspace, the operator workspace too |
| `label` | `cloud`, `persons` or `tokens` (the labels of costs-redesign.md 3.9; Total is their sum and has no rule) |
| `match` | Cloud only: which GCP projects; `*` = every project and every cloud cost entry, `<prefix>*` = the GCP projects whose id starts with `<prefix>` (`[a-z0-9-]{1,60}` then `*`), no cost entry. `""` for Persons and Tokens |
| `share_bp` | basis points, 1..10000 |
| `created_by`, `created_at` | the caller's hub id, the write time |

PRIMARY KEY `(workspace_id, label, match)`. A label with no rule shows
nothing for that workspace ("not part of this workspace's view", section
5). A workspace's Cloud rules may not overlap: a second `<prefix>*` that is
a prefix of, or has as prefix, one already stored, or any second rule
beside `*`, is refused (400), so one project counts once in one workspace.

The owner's rules as the first data (entered through the API, never
literals in code, section 3.4):

| workspace | cloud | persons | tokens |
|---|---|---|---|
| `csitea` | `*` 10000 | 10000 | 10000 |
| `t1` (spool-hub) | `csi-spl-*` 10000 | 3000 | 7000 |

A view, not a partition: **the shares of one label across workspaces need
not sum to 10000**, and the reads never subtract one workspace's view from
another's. The estate's own amounts never change.

### 3.2 Where they live: a table, not the cnf

rdb `cost_view_rules`, operator scope, no `tenant_id`, RLS policy
`operator_scope` (the rdb 0275 `cost_allocations` pattern). Not the cnf,
because:

- the owner asked that the admin and the business owner set the shares
  "on a cloud-instance basis" (csitea `f655b326`, msg `3440bf12`,
  costs-allocation.md 7): a cnf value needs a commit, a review and a
  deploy for each change;
- workspace ids are per instance (dev and prd hold different tenants);
- costs-allocation.md 7.1 already ruled that the owner's percentages are
  data, "never constants in code".

### 3.3 Who may change them

The operator workspace's **admin** and **business owner** (`biz_owner`) and
the operator service account; never a live act-as clone (the
`estateReadCaller` gate of costs-allocation.md 7.3). Anyone else: 403. A
customer workspace's admin has no door: a view rule reveals estate money,
so only the operator may grant one.

| route | answer |
|---|---|
| `GET /v1/operator/cost-view-rules` | `{rules: [{workspace_id, label, match, share_bp, created_by, created_at}], workspaces: [{id, name}]}` |
| `PUT /v1/operator/cost-view-rules` `{workspace_id, rules: [{label, match, share_bp}]}` | 200, that workspace's rules, replaced whole in one transaction; `rules: []` removes them (the workspace reads as today again). An unknown label, a `match` on Persons or Tokens, a bad pattern, an overlap (3.1), a share outside 1..10000, a duplicate or not-live workspace: 400 `bad_cost_view_rule` |

### 3.4 Data entry

`cd csi-spl-orc && ENV=<env> ./run -a do_spl_cost_view_apply` (new, the
`do_spl_cost_split_apply` pattern): `COST_VIEW_RULES='<ws>:cloud=<match>@<bp>,persons=<bp>,tokens=<bp>;<ws>:...'`,
a dry run unless `DRY_RUN=0`, as the env's project service account
(`do_gcp_pin_account`, never the owner account), through the PUT above,
never by SQL; it prints counts only, never an amount.

### 3.5 How a rule applies

For a workspace W with rules, the month read builds W's parts from the
**estate's** parts of the month (the same read the estate uses, 2.2, after
the Google Cloud rule of section 4):

| label | the estate parts it takes | W's part |
|---|---|---|
| Cloud `*` | every `gcp` part and every non-`hr` cost entry part, the Google Cloud rest part (4.1) included | each at `share_bp` |
| Cloud `<prefix>*` | the `gcp` parts whose project (the id before `/box=`, `cloudProjectOf`) starts with `<prefix>`; no cost entry, no rest part | each at `share_bp` |
| Persons | every `hr` part, after `hrReportEntries` (one row per component and group, never a person: spec 123 13.6) | each at `share_bp` |
| Tokens | every `ai_paid` part (the money: subscriptions and top-ups, owner poll `4b4dbf1a`) | each at `share_bp` |

W's token **burn** (`fleet_tokens`, a count and a list price, never money)
stays as today: its own for any workspace, every workspace's on a workspace
whose Tokens rule is 10000 (csitea). An `other` part (agent hours, a count)
follows the same: csitea, whose rules are all 10000, shows the estate's; t1
shows its own.

**Per part, not per month total.** The share applies to each estate part:
`floor(amount * share_bp / 10000)` in micro units, per currency, for USD,
EUR and the second currency alike (`store.CostAllocShareOf`, as
costs-allocation.md 4), and the parts keep their item keys. Then each row,
the pie slice, the footer and Total are sums of the shown parts, so the
table adds up to its footer exactly. A share of the month total was
rejected: the rows (one per project or component) would not add up to it,
and the pie needs an amount per item. The floor loses less than 1 micro
(0.000001 of the currency) per part; it is not carried anywhere, because a
view takes nothing from anyone.

A part W gets is source `allocated`, `allocated_source` the estate part's
source, `share_bp` the rule's, `view: true`, so the WUI's `costLabelOf`
(`costs-labels.mjs:37`) files it under the right label unchanged.

### 3.6 Precedence over the hand splits

For a workspace with view rules, the item splits (`cost_allocations`,
costs-allocation.md 2) and the instance splits (`cost_splits`, 7) are **not
applied**: W reads its rules only, so no cost reaches W both ways. They stay
stored and keep applying to every workspace without rules. Settings -> Cost
allocation shows, on an item whose split names a workspace with rules,
"<workspace> reads by its view rules; this share is not applied". Deleting
the inert split rows is a separate owner call (form question 4).

### 3.7 Who reads a view

- **The workspace's page reads its rules for every reader**, the operator
  workspace's admin included, when that workspace has rules (form question
  1, recommended A). So on prd the t1 page shows t1's share, and the whole
  estate is csitea's page (its rules are all 10000). The `estate` scope of
  2.1 stays for the reads that need the unscoped estate: Settings -> Cost
  allocation, Expenses and the accountants (`costEstateReaders`), and for a
  t1 without rules.
- **Persons money in a view** follows spec 123 13.6 and costs-allocation.md
  7.5: a reader with `costs.read` in W sees W's Persons rows. csitea's
  rules (10000 for Persons and Cloud `*`) then show every hr component and
  every GCP project of the estate, other customers' projects included, to
  every `costs.read` holder of csitea. That is what the owner asked; who
  holds `costs.read` in csitea decides who sees it (form question 3).

## 4. Google Cloud: never counted twice

### 4.1 The rule

For a month M of N days, a GCP invoice entry E (a cloud cost entry marked
as covering source `gcp`, 4.2) and the export lines L of M (source `gcp`,
origin `billing_export`), with n the number of days of M that hold at least
one line of L (the line days, never `cost_coverage`, which marked 27 days of
October read while lines exist on 9, 2.4):

| case | the read shows | E itself |
|---|---|---|
| n = 0 (no export yet, every month before 2026-10) | E | unchanged |
| n = N (the export holds the month; 2026-11 on, if it stays whole) | L only | stored, not read; marked "replaced by the billing export" |
| 0 < n < N (2026-10: 9 of 31) | L, plus one **rest part**: `max(0, E - sum(L))` in E's currency, item "Google Cloud: days before the billing export" | stored, not read; its rest part shown instead |

The rest part is the invoice net minus what the export already shows, so
the month's Google Cloud total equals the invoice, and the days the export
holds keep their split per project and service. Pro rata by days
(`E * (N - n) / N`) was rejected: the cost of a day is not flat (a project
created on the 20th, a month-end charge), and it guesses where the
subtraction is exact. Taking E alone for a partial month was rejected too:
it drops the per-project lines, and t1's `csi-spl-*` rule (3.5) would have
nothing to read for that month.

A rest below 0 (the export above the invoice: credits, a currency rate, a
second account) shows 0 and the legend's source line says "the export is
above the invoice for this month"; it is never negative.

Synthetic example (numbers made up): N = 31, n = 9, E = 1000.00 EUR, the
export lines of those 9 days sum 300.00 EUR. The read shows the 300.00 of
lines, per project, plus a rest part of 700.00; Cloud's Google Cloud total
is 1000.00, not 1300.00. In t1's view (`csi-spl-*` 10000) only the
`csi-spl-*` lines count, say 90.00, and no rest part: the days before the
export are not split per project, so no project rule can take them.

### 4.2 Which entry covers the export: a field, not the label

`cost_entries` gains `covers_source` (NULL, or `gcp`): this entry is the
invoice of what that source exports. It is set only through
`PATCH /v1/operator/cost-entries/{id}` (`{covers_source}`; operator admin,
biz owner and the accountants, the writers of the entry), or in the
create body of `do_spl_hub_cost_invoice_import`'s rows. Matching on the
label (`Google Cloud`, `GCP`, as the import's conflict check does today)
was rejected for the read: a label is free text in 19 languages
(spec 123 16.5) and a rename would silently double count again.

Preconditions, each a 409 `cost_entry.covers` at the PATCH:

1. at most one entry of a month covers `gcp`;
2. the entry's billing account is the one the export reads. The export
   table's name ends with the account id; the hub stores its last 4 on
   each ingest run (`cost_coverage`, a new nullable `account_last4`), and
   the entry's label or note must hold the same last 4. An entry of another
   account (account B, 2.4) cannot be marked, so its money is never taken
   for the export's.

### 4.3 Where it is computed

One function in the hub, `costGCPInvoiceRest` (`hub/cost_read.go`, beside
`costEntryMonthParts`), run on the estate's parts before anything else
reads them: the estate answer, every view (3.5) and `costEstateItems`
(costs-allocation.md 4) see the same parts. The WUI keeps adding rows as
today (2.3): the double count is removed at its source, not hidden on the
page. The estate answer names it: the rest part carries
`replaces_entry: <id>` and `export_days: n`, and the covering entry is
listed in a new `replaced` array of the answer (id, label), so the
Expenses list can still show and edit it.

### 4.4 The owner's "if that is the case remove it"

The evidence (2.4): the 2026-10 invoice entry and the export lines both
hold 23-31 October; 1-22 October is only in the entry. So the case is
**partly** so. Deleting the entry would lose 22 of 31 days of the month's
Google Cloud cost: the remedy of 4.1 removes the duplicated days and keeps
the rest. No row is deleted, and nothing is changed without the owner's
go.

The rows that would change, on the owner's go (form question 2):

| table | rows | change |
|---|---|---|
| `cost_entries` | the one 2026-10 cloud entry of account A | `covers_source = 'gcp'`; amount, label and note untouched |
| `cost_entries` | the 14 other Google Cloud entries (2026-01..09, both accounts) | none: no export line in those months, n = 0 |
| `cost_lines` | none | none |
| `cost_coverage` | the gcp rows from the next ingest run on | `account_last4` filled |

## 5. The legend in the diagram windows

### 5.1 What it shows

Under each label's pie (`CostsLabel.vue`, after `MonitoringCostsPie`),
on every label, Total included, a box **"What this workspace shows"**,
from the month answer (never computed in the WUI):

1. **The rules**, one line per label, in the label order:
   - Cloud `*` 10000: "Cloud: every GCP project and every cloud invoice";
   - Cloud `<prefix>*` b: "Cloud: GCP projects `<prefix>*`, {pct} %";
   - Persons b: "Persons: {pct} % of all human costs";
   - Tokens b: "Tokens: {pct} % of the paid AI costs";
   - a label with no rule: "{label}: not part of this workspace's view".
   On the page of a label, its own line is shown first and bold.
2. **The sources** of the label in that period: "GCP billing export
   ({n} of {days} days)", "Cloud invoices entered by hand ({count})",
   "Google Cloud before the billing export: the invoice minus the export"
   (when a rest part is in), "Human costs entered by the accountant",
   "Paid AI subscriptions and top-ups".
3. **The overlap note**, once, when the workspace has rules: "A view of
   the estate's costs: another workspace may show the same costs, so the
   workspaces' totals do not add up to the estate."

A workspace without rules shows line 1 as "This workspace's own costs and
the shares allocated to it" and its sources; the estate scope shows "The
estate: every cost of this instance". The box is a `<section>` with a
heading (`aria-labelledby`), text only, no colour carries meaning, and it
wraps at 390 px.

### 5.2 Where its data comes from

The month answer gains `view`: `{rules: [{label, match, share_bp}],
sources: [{label, source, days_with_lines, days, entries, rest}]}` (counts
and flags only, no amount beyond the parts). Present on every answer: an
empty `rules` means "no view rules".

### 5.3 Strings

New keys `reporting.costs.rules.*` (title, the five rule forms, the five
sources, the overlap note, `none`, `estate`, `own`) in **all 19 locales**
(`csi-spl-wui/i18n/locales/*.json`; parity: `i18n-parity.test.mjs`),
placeholders `{pct}`, `{prefix}`, `{n}`, `{days}`, `{count}`, `{label}`.
An **agy review is the last step before the land** (the language rule,
global CLAUDE.md "Spawn an agent"). The reviewer gets only the en strings
and the 18 translations, the keys and their placeholders: **no cost data,
no workspace name, no project id, no amount leaves the box for it**.

## 6. Rows to build

One row = one lane, rounds-rulebook format. Every row: its tests green,
`cd csi-spl-iac && ./run -a do_check_pre_push` (store rows
`PRE_PUSH_TIER=full`), deployed on dev and prd.

| row | what | files | after | done test | red control |
|---|---|---|---|---|---|
| R1 | rdb `cost_view_rules` (3.1-3.2) and `cost_entries.covers_source`, `cost_coverage.account_last4` (4.2); store reads and writes, Memory and Postgres | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_cost_view_rules.sql`, `<next+1>_cost_entry_covers.sql` (numbers from `do_rdb_migration_next`), `csi-spl-api/.../internal/store/cost_view_rules*.go` | - | a workspace's rules replaced whole in one transaction; RLS: no scope and a tenant scope read and write no row, the operator scope does | the RLS policy dropped: the tenant scope reads a row (`TestRLSCoversEveryTenantTable` fails) |
| R2 | the routes of 3.3, the overlap and pattern checks | `hub/cost_view_rules.go` + test | R1 | the 403s (operator developer, another workspace's admin, an act-as clone), the biz_owner write, the 400s (a `match` on Persons, `csi-*` beside `csi-spl-*`, a share of 10001) | the overlap check removed: `csi-*` and `csi-spl-*` both stored |
| R3 | the Google Cloud rule (4.1-4.3), the PATCH of `covers_source` and its two 409s, `account_last4` on ingest | `hub/cost_read.go` (`costGCPInvoiceRest`), `hub/cost_entries.go`, `csi-spl-iac/src/bash/run/spl-estate-cost-read.func.sh` + tests | R1 | synthetic month of 31 days: n = 0 shows E; n = 31 shows L only; n = 9, E 1000, L 300 shows L + rest 700, total 1000; L above E shows rest 0; an entry of account B refused 409 | the rule off: the n = 9 total reads 1300 |
| R4 | a workspace with rules reads by its rules (3.5-3.7), the precedence over the splits (3.6), the `view` object (5.2) | `hub/cost_read.go` (`costReadGather`), `hub/cost_view_read.go` + test | R2, R3 | the owner's table of 3.1 on synthetic data: csitea's total = the estate's; t1's Cloud = the `csi-spl-*` lines only and no rest part; t1's Persons = floor(30 %) per component; t1's Tokens = floor(70 %) per `ai_paid` part; a split naming t1 not applied; a workspace without rules unchanged | precedence removed: a cost split to t1 reaches t1 twice |
| R5 | `do_spl_cost_view_apply` (3.4) | `csi-spl-orc/src/bash/run/spl-cost-view-apply.func.sh` + `src/bash/tests/spl-cost-view-apply.tst.sh` | R2 | dry run prints the PUTs, counts only; DRY_RUN=0 sends them (hub stubbed); a bad spec refused before any call | an amount printed: the test's no-amount grep fails |
| R6 | the legend (5.1) and its strings (5.3), Settings -> Cost allocation's "not applied" note (3.6) | `csi-spl-wui/src/components/reporting/costs/CostsRulesLegend.vue`, `CostsLabel.vue`, `utils/costs-rules.mjs`, `i18n/locales/*.json` (19), mock bundle | R4 | unit: the lines from a synthetic `view`; e2e at 1440 and 390 px on the mock bundle: csitea's and t1's legends, the bold own line, no horizontal scroll; `i18n-parity`; agy PASS last | the `view` rules dropped from the mock: the e2e's rule lines fail |
| R7 | docs: `csi-spl-doc/doc/help/` Costs page (the legend, the view rules), spec 123 15.6 pointer kept true | `csi-spl-doc/doc/help/*.md` | R6 | the help text names every legend line | - |
| R8 | the owner's data (on the owner's go per env, dev first): the rules of 3.1 through R5, the `covers_source` of the 2026-10 entry (4.4) through R3's PATCH | none (data through the API) | R3, R4, R5 | `GET /v1/tenant/costs?month=2026-10` on csitea: the Google Cloud total equals the invoice; on t1: the `csi-spl-*` lines only; both legends shown | - |

## 7. Questions for the owner

One form; the first option is the one recommended.

```poll
1. On the spool-hub (t1) Costs page, what do you yourself see once t1 has its rules?
(A) t1's share by its rules, like every reader; the whole estate is the csitea page
(B) the whole estate as today; only the other t1 members see the share
2. The October Google Cloud entry overlaps the billing export on 23-31 Oct only (9 of 31 days). What do we do?
(A) Keep the entry, mark it as the export's invoice: October shows the export lines plus the invoice minus the export, so the total equals the invoice
(B) Delete the entry: October then shows only the 9 days of the export
(C) Keep the entry and drop the export lines of October
3. csitea will show every GCP project and every human cost of the estate. Who in csitea may read that?
(A) Whoever holds costs.read in csitea, as on any workspace
(B) Only csitea's admins, business owners and accountants
4. The hand splits already in prd (each GCP project to csitea or t1, tokens 30/70) stop applying to csitea and t1. What happens to them?
(A) Keep them stored, unused while the view rules exist
(B) Delete them once the view rules are live
```

## 8. Gates for this section

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` and `./run -a
do_check_pre_push` before the push of this file. No amount, billing account
id, person or customer project is written here: section 2.4 gives days and
counts only, section 4.1's numbers are synthetic.

<!-- version: 0.1.0 · updated: 2026-11-20 -->
