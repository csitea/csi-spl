# Costs: a cost assigned or split to workspaces by hand (SPL-5291)

Status: **v0.7 (SPL-6323, 2026-11-23): section 7.8, the route is safe by
default: a plain cloud run keeps a cost line already routed.** v0.6
(SPL-6301, 2026-11-23): section 7.7 adds a tokens split
of one vendor over a month range (split kind `tokens_vendor`), and section
7.8 routes one project prefix to one workspace without moving any other
item.** v0.5 (SPL-5768, 2026-11-17): section 7 adds the instance's
splits, tokens and per person, set by the operator workspace's admins and
business owners; it replaces answer 1 B for those two kinds only.** v0.4:
hub + store + Settings -> Cost allocation (SPL-5291). v0.2
was revised on the owner's answers (poll `01cbbdea`); v0.3 adds the
customer admin's partial body (section 3) and the settings page as built
(section 5.1). v0.4 takes the R7 review (c-580 `027c803f`): token burn
`fleet_tokens.<box>` stays Tokens (section 1), the nav label key (5.1), the
whole amount a share implies (3), an item no month holds is 400 (4).
Correction, R7 note N4: commit `04780c504`'s Docs line cites this file's
v0.2 as `d45a91d26`; that is the sha before the rebase, the commit on the
branch is `f7a293367` (history is not rewritten). Issue: SPL-5291 (epic
SPL-2373). Discussion: t1
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

**Tokens are never split by hand, item by item** (answer 1 B): the paid AI
items (`ai_paid`, `ai_share`) and the token burn (`fleet_tokens` per
workspace, `fleet_tokens.<box>` on the estate) keep the automatic share by
tokens (3.3.1). A split of a Tokens item on this route is refused, 400.
Since v0.5 the instance's **token split** (section 7) replaces the automatic
share of the paid AI items while it is set; the token burn stays automatic.

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
| the operator workspace's admin, the operator service account (never a live act-as clone of the admin: 403 `operator.workspaces`, `operatorWriteCaller`, SPL-5348) | set any split of any item among any live workspaces (`PUT /v1/operator/cost-allocations`) |
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

**The body names only `A`'s shares.** The admin never reads the shares
outside `A` (below), so their body cannot carry them: inside the
transaction the store completes it with every stored share of a workspace
outside `A` that the body does not name (`store.MergeCostAllocWithin`), then
judges the rules above, then checks the result as a whole split. A body that
does name an outside workspace is kept as sent and judged (rule 1 when it
differs, rule 2 when it is new). The hub's read of the body checks each
share (1..10000, no duplicate) but not the sum, which only the completed
split has.

So a customer admin can only move cost between workspaces they administer.
The check runs inside the write's transaction, the item's rows locked
(`SELECT ... FOR UPDATE`), so an operator change in between cannot be
overwritten by a stale read. A refusal is 403 `cost_allocation.outside`
naming the rule it broke.

What a customer admin sees (`GET /v1/tenant/cost-allocations?month=`): the
items that hold a share in `A`, each with its label, the share of each
workspace of `A` and its money in that month, and `held_bp` (the sum `A`
holds). Never the estate's total or the shares of workspaces outside `A`.
The item's whole amount is not sent, but a share's money and its `share_bp`
imply it (money x 10000 / share_bp), so a customer admin can compute the
whole amount of every item that holds a share in `A`; this is accepted,
not hidden (R7 note N2, 2026-11-11).

## 4. Hub API

| route | answer |
|---|---|
| `GET /v1/operator/cost-allocations?month=YYYY-MM` | `{month, items, workspaces}`: every Persons and Cloud estate item of that month (with its money) and its split (`shares: [{workspace_id, share_bp}]`, empty when none); `workspaces` lists where a share may go |
| `PUT /v1/operator/cost-allocations` `{source, project_or_vendor, kind, shares: [{workspace_id, share_bp}]}` | 200, the split; `shares: []` removes it; a Tokens item, a sum other than 10000, a duplicate or unknown workspace, a share outside 1..10000 or an item no month holds (no cost entry of that type and label, no live estate cost line of that source, project and kind on any day; R7 N3) is 400 `bad_cost_allocation`; a removal is never checked, so the split of an item that is gone can still be removed |
| `GET /v1/tenant/cost-allocations?month=YYYY-MM` | the customer admin's view (section 3) |
| `PUT /v1/tenant/cost-allocations` | the same body shape, `shares` naming only the admin's workspaces (section 3); 200, the completed split; the section 3 rules, 403 `cost_allocation.outside` |

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
- **As built** (5.1, `csi-spl-wui`): route `/tenant-settings/cost-allocation`,
  `components/CostAllocationCard.vue`, `utils/cost-allocations.mjs` (the
  checks, the body, the mock). The nav entry shows after
  `pages/tenant-settings.vue` probes the operator door (skipped when
  `/v1/view/me` says `operator_admin: false`) and then the tenant door
  (only with `tenant.settings`); the client reaches both over the existing
  `fleetPaid` stub (ops `alloc`, `alloc_put`), so the initial bundle gains
  no stub name. A percentage takes up to two decimals (basis points); every
  row empty removes an operator split. A product owner of the operator
  workspace reads the list (GET) but a Save answers 403 (PUT is admin only);
  the page shows the hub's words. Strings `tenant_settings.cost_alloc_*` in
  all 19 locales (agy review last); the nav label is
  `tenant_settings.section_cost_allocation`, a key that prefixes no other,
  so the first-screen catalogue keeps only that one (a nav label that
  prefixes the page's keys pulls them all into core). Help:
  `doc/help/user-settings.md` section 9.
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

## 7. Splits per instance: tokens and persons (v0.5, SPL-5768)

Owner HUM-10, csitea topic `f655b326`, 2026-11-16:

- msg `666ce94d`: "for the tokens costs we need to do a different division -
  the spool-hub workspace should take some 70% of the costs for the tokens
  and thre csitea should take 30%";
- poll `4b4dbf1a`, msg `202a45d1`: the tokens are "What was paid: the AI
  subscriptions and top-ups, from 2024-07";
- msg `0142ae24`: personnel costs, 70 % of person P1's gross costs and 30 %
  of person P2's to t1 (the rest to csitea, c-003's reply `c568e20f`);
- msg `3440bf12` (verbatim; "school hub" is read as "spool hub"): "the
  admin and the business owner should be able to define percentages for
  the division of the costs, both for the tokens and for the personnel
  costs, on a percentage basis, divided for each workspace. This should be
  done on a cloud-instance basis."

So answer 1 B ("Tokens stay automatic") no longer holds for the paid AI
items, and a person's costs get one split for the person, not one per hr
item. Every other part of 1 B and of sections 1-6 stands.

### 7.1 What a split is

A **split** is one set of rows per instance (one hub): a share per workspace
in basis points, 1..10000, that sum to 10000, for one of two kinds:

| kind | subject | applies to |
|---|---|---|
| `tokens` | none (`""`) | every paid AI item (`ai_paid`: the subscriptions and top-ups of every agent type), every month |
| `person` | the hr person's hub id (`hr_people.id`, rdb 0280) | every `hr` cost entry booked for that person, every month |

As in section 2, a split has no month: it holds for every month, past ones
too (answer 2 B), and a change re-attributes them. The owner's values
(tokens t1 70 % / csitea 30 %; P1 t1 70 % / csitea 30 %; P2 t1 30 % /
csitea 70 %) are the first data entered through the API, never constants
in code.

### 7.2 Storage: rdb `cost_splits`

Operator scope, no `tenant_id`, RLS `operator_scope` (the rdb 0275
pattern). Columns: `split_kind` (`tokens` | `person`), `subject` (`""` for
tokens, the person id for person), `workspace_id` (FK `tenants`, ON DELETE
CASCADE), `share_bp` (1..10000), `created_by`, `created_at`. PRIMARY KEY
`(split_kind, subject, workspace_id)`. The hub writes a split in one
transaction; `shares: []` removes it.

### 7.3 Who

The operator workspace's **admin** and **business owner** (`biz_owner`)
read and write, as does the operator service account; never a live act-as
clone. Anyone else: 403. There is no customer-admin door (section 3 does
not apply).

### 7.4 Hub API

| route | answer |
|---|---|
| `GET /v1/operator/cost-splits` | `{splits: [{split_kind, subject, shares, created_by, created_at}], people: [{id, code}], workspaces: [{id, name}]}` |
| `PUT /v1/operator/cost-splits` `{split_kind, subject, shares: [{workspace_id, share_bp}]}` | 200, the split; `shares: []` removes it; an unknown kind, a tokens split with a subject, a person split whose subject is no hr person, a sum other than 10000, a duplicate or not-live workspace, a share outside 1..10000: 400 `bad_cost_split` |

Data is entered through these routes and section 4's, never by SQL:
`cd csi-spl-orc && ENV=<env> ./run -a do_spl_cost_split_apply` allocates
every Cloud item of a month range (a cost line whose project starts with
`COST_SPLIT_CLOUD_PREFIX`, default `csi-spl-`, to the operator workspace;
every other line and every cloud cost entry to `COST_SPLIT_OTHER`) and sets
`COST_SPLIT_TOKENS` and `COST_SPLIT_PERSONS` (by hr person code). It is a
dry run unless `DRY_RUN=0` and prints counts only.

### 7.5 How the reads apply it

- **Tokens.** With a tokens split set, a customer workspace W's month read
  carries, in place of its automatic `ai_share` parts, one `ai_share` part
  per agent type (kind `share`, no plan, as the automatic one, so the Tokens
  label keeps it): `allocated_source` `ai_paid`, `share_bp` W's share, money
  the sum over that type's estate `ai_paid` parts of
  `floor(amount * share_bp / 10000)` (section 4's rounding; the remainder
  stays with the estate). `ai_share_from` is the month's first day. With no
  tokens split, the automatic share by tokens of 3.3.1 reads as before.
- **Persons.** A customer workspace W's Human rows add its share of the
  month's `hr` lines of every person whose split holds W: each line's
  amount at W's share, rounded down to the micro, then summed per
  component like the estate's rows (no report row is a person's, spec 123
  13.6): source `allocated`, `allocated_source` `cost_entry`, `share_bp`
  set only when every split person gives W the same share. An hr row
  whose estate item also has its own item split (section 2) keeps that
  split and takes no person share, so no cost counts twice.
- **The estate** keeps the full amounts (a share is an attribution); each
  `ai_paid` part names the tokens split in `allocation`, as in section 4.
  An hr row is a component's, so it names no person split.

### 7.6 Tests

Store (Memory and Postgres, RLS as in section 6); hub: the 403 for the
operator workspace's developer and another workspace's admin (the gate is
`estateReadCaller`, which refuses an act-as clone), the biz_owner write, the 400s (a sum of
9999, a tokens subject, an unknown person), a tokens split replacing
`ai_share` with floor rounding (red control: the split not applied, W
keeps its token share), a person split adding W's Human row, and an item
split winning over it.

The web UI screen for the splits is a later lane.

### 7.7 A share of one vendor over a month range (v0.6, SPL-6301)

Owner HUM-10, a customer workspace's topic `f3203933` (relayed by the seat
c-086, msg `a843a016`), msg `cfbd1832`: "take the claude code tokens costs
from 2026-01 till 2026-06, take 40% of them and set them as the claude
costs for this project". Issue SPL-6301, discussion issue SPL-6299.

The tokens split of 7.1 covers every vendor and every month, so "40 % of
one vendor's paid items over six months" cannot be said with it. The model
is a **third split kind**, not a view rule:

| kind | subject | applies to |
|---|---|---|
| `tokens_vendor` | `<vendor>:<from>:<to>`: a vendor of rdb 0205 (`claude`, `mistral`, `grok`, `agy`, `qwen`) and two months `YYYY-MM`, both included, `from <= to` | the paid AI items (`ai_paid`) of that vendor in the months `from..to`, in place of the tokens split for those parts only |

Why a split and not a view rule ([costs-workspace-views.md](costs-workspace-views.md)):
a view rule has no vendor and no month (3.1 there), its reads (row R4) are
not built, and a workspace with any view rule stops reading its item
splits (3.6 there), so a workspace given a rule for its tokens would lose
its Cloud allocations. The split is read today (7.5) and stays a
partition: the estate's money is attributed once.

The rules (the store's `CheckCostSplit` and the PUT of 7.4, 400
`bad_cost_split`):

- the shares sum to 10000 like every split; the rest of the vendor's
  months goes where the split says, so the data entry (below) fills it from
  the tokens split, pro rata, and nothing reaches a workspace twice;
- a `tokens_vendor` split refines the tokens split: its PUT is refused
  while no tokens split is stored, and the reads apply it only while one is
  (7.5 keeps the automatic share without a tokens split);
- two `tokens_vendor` splits of one vendor never cover the same month: a
  PUT whose range meets a stored one of the same vendor (another subject)
  is refused. A removal (`shares: []`) is never checked.

How the reads apply it (7.5, per part): a customer workspace W's
`ai_share` part of vendor V in month M takes W's share of the
`tokens_vendor` split of V that covers M, else W's share of the tokens
split. The estate's `ai_paid` part of V in M names that split in
`allocation` (section 4), else the tokens split. Every other vendor, every
month outside `from..to`, the persons and the items keep their meaning.
A forward-only rdb migration (`cost_splits_vendor`) widens rdb 0293's two
CHECKs to the new kind; the table and its RLS do not change.

Data entry, a dry run unless `DRY_RUN=0`, counts only:
`cd csi-spl-orc && ENV=<env> COST_SHARE_VENDOR=claude COST_SHARE_FROM=2026-01 COST_SHARE_TO=2026-06 COST_SHARE_WORKSPACE=<ws> COST_SHARE_BP=4000 ./run -a do_spl_cost_vendor_share`.
It reads the splits and the paid items (`GET /v1/operator/fleet-tokens/paid`),
logs the vendor's items per month of the range (a count, never an amount),
and PUTs the `tokens_vendor` split: `<ws>` at `COST_SHARE_BP`, the other
`10000 - bp` over the tokens split's shares pro rata (largest remainder;
a workspace of the tokens split that is `<ws>` itself adds its part of the
rest to its share). `COST_SHARE_REST='<ws>=<bp>,...'` names the rest
instead. It refuses without a stored tokens split, a range with no item of
the vendor, a workspace that is not live, or a bp outside 1..10000.

### 7.8 Routing one project prefix to one workspace (v0.6, SPL-6301)

Owner msg `ceb7f372` (same topic): the cloud costs of that customer's GCP
projects (one project prefix) belong in its workspace. The cloud step of 7.4's `do_spl_cost_split_apply`
knows two workspaces, so running it with another prefix would re-assign
every other item. `COST_SPLIT_ROUTE='<prefix>:<ws>'` adds a rule that wins
over both: every Cloud cost line item (not a cost entry) of the months
FROM..TO whose project starts with `<prefix>` gets `<ws>` at 10000, through
the item split of section 2 (no new storage).

- With `COST_SPLIT_ROUTE` and no `COST_SPLIT_CLOUD_PREFIX` in the
  environment, the action plans the routed items only: no other item is
  PUT.
- With both, the full cloud step runs and the routed items take the route
  (so a full run keeps them where they were routed).
- It refuses a prefix that matches no item of the range, a route whose
  workspace is not live, and a malformed spec. The dry run (the default)
  logs `PLAN cloud rule=line-route -> <ws>: items=<n> already=<n>`.
- **Safe by default (v0.7, SPL-6323).** The route lives in no file, so a
  later run without `COST_SPLIT_ROUTE` must not undo it. The cloud step
  keeps a cost line whose split is wholly (10000) one workspace that is
  neither `COST_SPLIT_OPERATOR` nor `COST_SPLIT_OTHER`: it was routed, and
  no PUT moves it. The dry run logs
  `PLAN cloud rule=line-kept: already routed=<n>`. The hub's split is the
  memory of the route, so no cnf names a customer's project prefix. To
  move such a line again, route it explicitly
  (`COST_SPLIT_ROUTE='<prefix>:<ws>'`, which wins over the kept rule).
  A cost entry is not a cost line and still goes by the cloud rules.

A workspace with view rules ([costs-workspace-views.md](costs-workspace-views.md),
SPL-6086, v0.1 draft) reads by its rules, and sections 2 and 7 are not
applied to it (that page, 3.6).

<!-- version: 0.7.0 · updated: 2026-11-23 -->
