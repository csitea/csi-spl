# 125 Netvisor integration: test company first, then production

Version v0.3 (2026-11-04, `SPL-4812`): every answer of `msg:91a1bc9a` as a
decision with its msg id (section 1.5); what each card type gives (section
4.3); the spec-123 check names where each workspace records a cost (section
4.2 item 3); the Qto visibility gap per workspace and row B11 (section 5.3);
section 8 answered; the owner's steps in order (section 10); the questions
for the accountants ([accountant-questions.md](accountant-questions.md)); the
build plan ([plan.md](plan.md)) and task rows ([tasks.md](tasks.md)).

Version v0.2 (2026-11-04): C7 rewritten for READING: every person of the
`csitea` workspace reads the figures, agents never (section 1.4, `SPL-4792`);
several credit cards plus debit cards (section 4); the spec-123 check looks
in both workspaces before a Netvisor cost is added (section 4.2); the report
order and row B10 (section 7); the accountant questions go with production
(section 9).

Version v0.1 (2026-11-03): initial specification derived from
[research.md](research.md) v1.3 and the owner's orders of 2026-11-03 in
`topic:fc0119cd-f4ea-4b9f-ada8-4c65d41a82cd` (`msg:7c8e6ced`, `msg:84dc795a`,
`msg:1ea0a8f0`).

Source: owner `HUM-10` in the `csitea` workspace,
`topic:fc0119cd-f4ea-4b9f-ada8-4c65d41a82cd` (earlier research asks in
`topic:67c25538` and poll `d19c1e1d`, `msg:125a5387`, `msg:11ca00a3`).
Issue: `SPL-4712` (`csitea` mirror: `CSI-67`). Epic: `SPL-2380`.

Data and placement rules:
- Every build row that handles Netvisor API responses, credentials or finance
  schema runs on a lane permitted by the fleet data rule (`claude`, `grok` or
  `mistral`, never `agy` or `qwen`).
- Every lane or cron job that reads the Netvisor credentials file runs on the
  main box only (C6).
- Any WUI translation keys added by a WUI build row are reviewed by `agy` under
  the fleet language rule (translation keys and locale strings only, never
  finance figures or account identifiers).
- No figures, identifiers, partner identifiers, customer identifiers, keys,
  bookkeeping account numbers, credential hostnames or credential file paths
  ever appear in this spec, in git commits, in logs, in CI output or in spool
  posts (C2, C7).

---

## 1. Owner's orders and constraints

### 1.1 Owner orders (2026-11-03)

In `topic:fc0119cd-f4ea-4b9f-ada8-4c65d41a82cd` (`HUM-10`, `msg:7c8e6ced`,
`msg:84dc795a`, `msg:1ea0a8f0`):

1. "so we need to first build the integrations of our functionalities according
   to our specs against the dev env" (the Netvisor test company).
2. "and than request some access to prod".
3. "take over the tasks of this sole ad-hoc session and put it on the lanes".
4. Code location rule (2026-11-03): "should you write any code it must be
   stored in the csi-int-nvs private project on the github" (`csitea/csi-int-nvs`
   for the Netvisor client and fetch actions; hub storage, hub routes and the
   `HUM-10` WUI screen in `csitea/csi-spl`, section 2.1).

### 1.2 Owner constraints C1..C9 (verbatim from research section 8.1)

| # | owner's words | rule for spec 125 |
|---|---|---|
| C1 | "C" (fc0119cd, msg 70b69575) | the cash balance comes from Netvisor's imported bank data (section 4); no bank API |
| C2 | "Anything related to the finances of [Csitea] should be private to this workspace." (fc0119cd, msg 873f6f84) | **superseded by C7** for who sees the data. Still stands: no figures, account numbers, ids or keys in git, specs, logs, CI output or other repos. |
| C3 | "The company has only one account." (fc0119cd, msg aa3a837e) | one bank bookkeeping account in the forecast; no bank account number needed (section 4.2) |
| C4 | "Almost everything is paid via" Netvisor (fc0119cd, msg c45c7cb0) | outgoing payments = Netvisor purchase invoices (section 4.4) |
| C5 | card payments and "the cost of their structures" (fc0119cd, msg 2a339876) | use case 2 (section 5) |
| C6 | "Keys and secrets should stay only on the [main] box, not on [the satellite]." (fc0119cd, msg 072a9990); scoped by msg c0bcb7b1: only the financial keys (bank and Netvisor) stay on the [main] box, "The Google keys could go on the SAT box as well." | the Netvisor and bank keys live only in a 0600 file on the main box, read by the main-box fetch action; not on the satellite and not in GCP Secret Manager; GCP keys are not affected; option B (section 6) |
| C7 | no access to the keys or the information for "any other member other than me" (fc0119cd, msg 42924894) | **rewritten for reading on 2026-11-04 (section 1.4)**: every person seated in the `csitea` workspace READS the figures and reports (cash forecast and card costs now, the B9 balance sheet / P&L later); no agent seat, act-as clone, token, operator service account or other workspace ever reads them. Still for `HUM-10`, the workspace's Netvisor owner, alone: the keys (main box, C6), the settings (bookkeeping accounts, vendor exclusions) and "Refresh now". Enforced at the hub and in PostgreSQL RLS, never by UI hiding. Red controls: an agent seat gets 403; reverting rdb 0260 hides the figures from a member |
| C8 | "We should strive to build a simple UI which will answer my questions and not actually give too much information to the agents (because the aim is to have the available data and create the analysis after the data exists in our database ...)" (fc0119cd, msg 9a9e0802) | the fetched data is stored in the hub DB first; a simple WUI screen for HUM-10 answers the questions by code; agents never receive figures, so option C (MCP for agents) is out (section 6) |
| C9 | "Also, I would like to enable the usage of the QTRO docs as a balance sheet statement because of its hierarchical structure capabilities." (fc0119cd, msg adc2981c; QTRO = the Qto workspace docs, specs 113/114/120) | option D: balance sheet and P&L generated by code as a hierarchical Qto document on each fetch, after a per-person, no-agent doc lock is built (section 6.1) |

### 1.3 Owner poll decisions (2026-10-16, poll `d19c1e1d`, `msg:125a5387`, `msg:11ca00a3`)

- **First build**: month-end cash forecast first (section 3); card-cost
  structure (section 4) and balance-sheet Qto export (section 5.3) follow in
  numbered rows.
- **Access mode**: strictly read-only (`GET` resources only; no write
  resources, no write permissions, no transaction fees).
- **Refresh cadence**: one nightly cron run on the main box plus an on-demand
  "Refresh now" button on `HUM-10`'s WUI screen.
- **Payables timing**: bills are assumed paid on their due date
  (`PurchaseInvoiceDueDate`).
- **Cards in use**: both a debit card on the single bank account and a separate
  credit card (widened on 2026-11-04, section 1.4: several credit cards and
  debit cards).
- **Product readiness**: keep workspace identifier, credentials source and
  bookkeeping account numbers parameterized so nothing in code hardcodes
  workspace literals ([research.md](research.md) section 6.2).

### 1.4 Owner decisions (2026-11-04, `csitea` topic `67c25538`)

- **Who reads the figures (poll `2a767008`, answer `msg:cfa78746`)**: "WS —
  Every member of the csitea workspace". In the same post (`msg:91a1bc9a`):
  "this is ok to be visible only for the csitea workspace, no need to
  restrict it for me only for now"; "agents never see the figures" still
  holds. C7 is rewritten for reading (section 1.2); built by `SPL-4792`: rdb
  `0260_netvisor_member_read.sql`, the hub's `netvisorReader` door and the
  Finance tab for every person of the workspace
  (`csi-spl-doc/doc/md/netvisor-finance-store.md`).
- **Cards**: "We have both debit cards, and credit cards (several of them)"
  (section 4).
- **Costs already in spec 123**: "you have to be able to identify wheather a
  cost was added to the csitea workspace or to the spool-hub workspace before
  adding one from the NetVisor integration" (section 4.2 item 3).
- **Report order**: cash forecast, card costs, P&L, balance sheet, open
  invoice lists (section 7, row B10).
- **Bookkeeping accounts**: the questions for the accountants go with the
  production step (section 9, step P5).

### 1.5 Every answer of 2026-11-04 as a decision (`msg:91a1bc9a`, poll answer `msg:cfa78746`)

The owner answered the questions of [research.md](research.md) inline in
`msg:91a1bc9a` (`csitea` topic `67c25538`). Each answer is a decision:

| # | decision | owner's words | source | where in this spec |
|---|---|---|---|---|
| D1 | **Design B**: a job on the main box alone fetches the Netvisor data into the hub database; agents never see the figures | "agents never see the figures" | `msg:91a1bc9a` | 5.1, 5.2 |
| D2 | The screen (cash today, cash at month end, card costs by vendor and type) is read by **every person of the `csitea` workspace**, "for now" | "this is ok to be visible only for the csitea workspace, no need to restrict it for me only for now" | `msg:91a1bc9a`; poll `2a767008`, answer `msg:cfa78746` ("WS — Every member of the csitea workspace") | 1.2 C7, 5.2 |
| D3 | **Design D**: the balance sheet and the P&L are written by code as a Qto document tree after each fetch, read by every person of `csitea`, no agent | the same sentence, given again under the Qto gap | `msg:91a1bc9a`, `msg:cfa78746` | 5.3, B9, B11 |
| D4 | Build order: 1 month-end cash forecast, 2 card costs, 3 monthly P&L, 4 balance sheet, 5 open invoice lists | "this one first", "this one second", "3rd", "4th", "5th" | `msg:91a1bc9a` | 7, [tasks.md](tasks.md) |
| D5 | **Read-only** (`GET` resources only) | "for now read-oly" | `msg:91a1bc9a` | 1.3, 9 P3 |
| D6 | Freshness: one nightly fetch plus a "Refresh now" button | "Nightly + reresh now if needed" | `msg:91a1bc9a` | 1.3, B6, B7 |
| D7 | Bills are paid on their due date; the forecast assumes the due date | "Yes. ALWAYS." and "YES" | `msg:91a1bc9a` | 3.1 |
| D8 | The keys go to the owner on the main box (the main-box file), never into a chat | "Keys to me on the [main] box" | `msg:91a1bc9a` | 5.2 item 1, 10 |
| D9 | Netvisor package: unknown; the owner buys `Professional` if the API needs it | "IDK. If needed I will purchase the Professional one" | `msg:91a1bc9a` | 8 Q1, 9 P1, [accountant-questions.md](accountant-questions.md) |
| D10 | Bank, VAT and tax-account bookkeeping accounts: unknown; found by asking the accountants | "WE CAN FIND OUT by asking the Accountants the right questions" | `msg:91a1bc9a` | 8 Q2, 9 P5, [accountant-questions.md](accountant-questions.md) |
| D11 | Several debit cards AND several credit cards | "We have both debig cards , and credit cards ( several of them )" | `msg:91a1bc9a` | 4, 4.3 |
| D12 | Before a Netvisor cost is added, the integration knows whether spec 123 already recorded it in the `csitea` workspace or in the `spool-hub` workspace | "you have to be able to identify wheather a cost was added to the csitea workspace or to the spool-hub workspace before adding one from the NetVisor integration" | `msg:91a1bc9a` | 4.2 item 3 |
| D13 | Card costs: the ledger's breakdown by account and cost centre, and the vendor named by e-invoices, are accepted as the sources | "ok", "ok" | `msg:91a1bc9a` | 4.1 |

---

## 2. Where code lives and what already works (2026-11-03)

### 2.1 Repository split: `csitea/csi-int-nvs` vs `csitea/csi-spl`

Per the owner's rule of 2026-11-03 and rules C6..C9:

1. **Private repository `csitea/csi-int-nvs`** holds all Netvisor API client
   code, HMAC-SHA256 request signing, XML response parsing, cash-forecast and
   card-cost extraction logic, and the main-box `./run` fetch actions.
   - Already on `csitea/csi-int-nvs` `master` at `837fe08`:
     - `./run -a do_nvs_api_call --resource <x>.nv [--query ..] [--env test|prd]`
       in `csi-int-nvs-utl` (authenticated, sequential `GET` caller reading the
       mode-`0600` credentials on the main box),
     - setup documentation in `csi-int-nvs-doc/setup.md`,
     - offline HMAC-SHA256 signing test suite (`8/8` passing).
   - Every `csitea/csi-int-nvs` build row starts from `837fe08`, never from
     scratch.
2. **Public repository `csitea/csi-spl`** holds the hub PostgreSQL tables and
   RLS policies (`csi-spl-rdb`), the hub ingest and `HUM-10`-only view routes
   (`csi-spl-api`), the per-person Qto document lock (`csi-spl-rdb` +
   `csi-spl-api`), and the `HUM-10` WUI screen (`csi-spl-wui`). No Netvisor
   credentials, raw Netvisor XML or company account numbers ever enter
   `csitea/csi-spl`.

| component | repository | sub-project | build rows |
|---|---|---|---|
| Netvisor signed API caller (`do_nvs_api_call`, baseline `837fe08`) | `csitea/csi-int-nvs` (private) | `csi-int-nvs-utl`, `csi-int-nvs-doc` | already built (`837fe08`) |
| Remaining GET resource probes and XML parsers (balances, ledger, payments, payroll, dimensions) | `csitea/csi-int-nvs` (private) | `csi-int-nvs-utl` | B1 |
| Month-end cash forecast computation (route C) | `csitea/csi-int-nvs` (private) | `csi-int-nvs-utl` | B2 |
| Card payments and cost-structure extractor (by vendor, account, cost centre) | `csitea/csi-int-nvs` (private) | `csi-int-nvs-utl` | B3 |
| Hub DB schema + `FORCE ROW LEVEL SECURITY` (`HUM-10`-only tables) | `csitea/csi-spl` | `csi-spl-rdb`, `csi-spl-api/internal/store` | B4 |
| Hub operator ingest endpoint + `HUM-10`-only view and refresh routes | `csitea/csi-spl` | `csi-spl-api/internal/hub`, `internal/wire` | B5 |
| Main-box sync action (`do_nvs_sync --env test|prd`), cron wrapper and refresh poller | `csitea/csi-int-nvs` (private) | `csi-int-nvs-utl` | B6 |
| Simple WUI finance screen for `HUM-10` (cash forecast, card costs, "Refresh now") | `csitea/csi-spl` | `csi-spl-wui` | B7 |
| Per-person, no-agent Qto document lock (`restricted_to_human`) | `csitea/csi-spl` | `csi-spl-rdb`, `csi-spl-api` | B8 |
| Hierarchical balance sheet & P&L Qto generator | `csitea/csi-int-nvs` + `csitea/csi-spl` | `csi-int-nvs-utl`, `csi-spl-api` | B9 |

### 2.2 What already works in the Netvisor test company (2026-11-03)

In the Netvisor test company (`--env test`), the integration is registered and
enabled with all API resource access rights switched on. Verified on 2026-11-03
with `./run -a do_nvs_api_call --env test` at `csitea/csi-int-nvs` `837fe08`:

| resource | method | verified result in test company (no figures) |
|---|---|---|
| `customerlist.nv` | `GET` | `ResponseStatus` `Status` = `OK` |
| `salesinvoicelist.nv` | `GET` | `ResponseStatus` `Status` = `OK` |
| `purchaseinvoicelist.nv` | `GET` | `ResponseStatus` `Status` = `OK` |
| `productlist.nv` | `GET` | `ResponseStatus` `Status` = `OK` |
| `accountlist.nv` | `GET` | `ResponseStatus` `Status` = `OK` |
| `getpurchaseinvoice.nv` | `GET` | `ResponseStatus` `Status` = `OK` |
| `getcustomer.nv` | `GET` | `ResponseStatus` `Status` = `OK` |

All build rows `B1..B9` use this working test company as their starting state.

---

## 3. Use case 1: month-end cash forecast (route C)

Chosen by the owner (`msg:70b69575`, C1, C3, C4; [research.md](research.md)
section 4): rebuild the end-of-month cash position solely from Netvisor's
bookkeeping and invoice resources, with no bank API and no bank account number
(IBAN).

### 3.1 Inputs and Netvisor resources

| term in the month-end sum | sign | Netvisor GET resource | fields used | rules and edge cases |
|---|---|---|---|---|
| **Booked bank balance today** | start | `accountbalance.nv` | `AccountNumber` (the single bank bookkeeping account, C3), `balancedates=<today>`, `Balance` | Keyed by bookkeeping account number from `accountlist.nv` / settings, never IBAN ([research.md](research.md) 4.2). |
| **Bank statement booking freshness** | metadata | `accountingledger.nv` | newest `VoucherDate` on the bank bookkeeping account | Shown beside the bank balance so `HUM-10` sees immediately if bank statement matching lags today ([research.md](research.md) 4.1). |
| **Open sales receivables due by month end** | `+` | `salesinvoicelist.nv` (`invoicestatus=open`), optional detail `getsalesinvoice.nv` | `InvoiceDueDate`, `OpenSum` (incl. VAT), `InvoiceStatus` | Sum `OpenSum` where `InvoiceDueDate <= month_end`. Overdue receivables (`InvoiceDueDate < today`) are totalled both in the sum and in a separate "of which overdue" line ([research.md](research.md) 4.4). |
| **Open purchase payables due by month end** | `-` | `purchaseinvoicelist.nv` (unpaid) + `getpurchaseinvoice.nv` per open invoice | `PurchaseInvoiceDueDate`, `OpenSum`, `InvoiceStatus`, `ApprovalStatus` | Bills are assumed paid on `PurchaseInvoiceDueDate` (owner poll answer 8). Split into **approved** vs **not yet approved** so unapproved bills are visible ([research.md](research.md) 4.4). |
| **Payments made after the bank balance voucher date** | `-` (deduped) | `paymentlist.nv` | `Date`, `HomeCurrencySum`, linked purchase invoice key | Any payment with `Date > newest_bank_voucher_date` is subtracted once from the starting balance, and its linked purchase invoice is excluded from open payables so it is never subtracted twice ([research.md](research.md) 4.4). |
| **Salaries and payslips in the month** | `-` | `getpayrollpaycheckbatchlist.nv` + `getpayrollpaycheckbatch.nv` | payment date in current month, status `Open`/`Confirmed`/`Paid`, net pay lines | Net pay due in the current month; employer contributions and withholding fall on the tax liability accounts below ([research.md](research.md) 4.4). |
| **VAT payable and employer/tax-account liabilities** | `-` | `accountbalance.nv` | configured VAT payable and tax-liability bookkeeping accounts, `balancedates=<today>` | Balances on the configured tax and VAT liability accounts ([research.md](research.md) 4.4, 8.2 item 6). |
| **Recurring contract sales (when used)** | `+` (optional) | `contractinvoicingreport.nv` | projected contract invoices for the month | Included only when contract invoicing rows exist and are not yet issued as open sales invoices ([research.md](research.md) 4.4). |

### 3.2 Concurrency, logging and acceptance rules

- **Sequential requests only**: `do_nvs_api_call` and every multi-resource
  action send one HTTP request at a time and wait for its response before the
  next call, with a timeout of at least 120 s ([research.md](research.md) 3.1).
- **Zero-amount logging**: actions log only the resource name, HTTP/Netvisor
  status (`OK` / error code) and element counts; XML payloads, invoice numbers,
  counterparty names, account numbers and monetary amounts are never written to
  stdout, stderr or log files (C2, C6, C8).
- **Acceptance proof**: the month-end total computed by code matches Netvisor's
  own UI cash-flow forecast screen for the same company on the same day, or
  explains any delta by item category (e.g. manual UI-only cash-flow events).

---

## 4. Use case 2: card payments and cost structure by vendor and cost type

Requested by the owner (`msg:2a339876`, C5; poll answer 9: the company uses
both a debit card on the single bank account and a separate credit card;
[research.md](research.md) section 5). Widened on 2026-11-04 (section 1.4):
"We have both debit cards, and credit cards (several of them)". The routes
below hold for any number of cards: each credit card arrives as its own
card-provider purchase invoice and each debit card as its own bank statement
lines; the card cost lines say which route they came by, and the screen sums
all cards of a route together unless a later row names the card.

### 4.1 How card purchases are read from Netvisor

| card route | how it reaches Netvisor | Netvisor GET resources | vendor field | cost type (account) & cost centre (dimension) |
|---|---|---|---|---|
| **Credit / charge card e-invoice** (with electronic receipts; one per credit card) | Arrives as a card-provider purchase invoice with receipts; booked to a voucher or travel expense report | `purchaseinvoicelist.nv`, `getpurchaseinvoice.nv`, `accountingledger.nv` | Structured vendor record on the purchase invoice + line descriptions | `AccountNumber` (named via `accountlist.nv`), `LineSum`, VAT code, and dimension items (`dimensionlist.nv`, `getaccountdimensionlist.nv`) |
| **Debit cards on the single bank account** (each debit card's lines) | Arrives as a bank statement line; booked to a ledger voucher via posting rules or manual matching | `accountingledger.nv`, `accountlist.nv`, `dimensionlist.nv`, `getaccountdimensionlist.nv` | Merchant text from `VoucherDescription` / ledger line description (no separate vendor record) | `AccountNumber`, `LineSum`, VAT code, and dimension items on the booked voucher line |
| **Travel and expense reports** (card receipts via mobile/eScan) | Booked as expense vouchers once verified/accepted | `accountingledger.nv` | Line / voucher description | `AccountNumber`, `LineSum`, VAT code, dimension items |

Unbooked bank statement lines are not exposed by Netvisor's API until matched
to a voucher ([research.md](research.md) 5.2); the screen shows the newest
booked voucher date so the user knows the cutoff.

### 4.2 Breakdowns and spec 123 boundary

1. **Three slices on the Finance screen** (every person of the workspace, C7 as rewritten):
   - **By cost type**: grouped by bookkeeping `AccountNumber` and account name
     per calendar month.
   - **By vendor / merchant**: grouped by purchase-invoice vendor (credit-card
     e-invoice route) and normalized merchant description (debit-card voucher
     route) per calendar month.
   - **By cost centre (dimension)**: grouped by Netvisor dimension and
     dimension item where present.
2. **Privacy boundary with spec 123 (C7, C8)**:
   - Spec 123's `cost_lines` table is visible to any workspace member holding
     `costs.read`, and its rows can be read by a seated agent. Netvisor rows
     stay in spec 125's own tables (rdb `0255`, read rule rdb `0260`: persons
     of the workspace only, never an agent) and are never written into
     shared `cost_lines` rows ([research.md](research.md) 5.3).
3. **Double-count guard with spec 123**:
   - Cloud and AI vendor bills already ingested by spec 123 (GCP billing
     export, AI subscription invoices) also appear as card charges or purchase
     invoices in Netvisor. Today a configurable vendor-exclusion list in the
     settings marks or skips those vendors (section 8, Q4).
   - **Owner, 2026-11-04 (section 1.4)**: a fixed vendor list is not enough.
     Before a cost from Netvisor is added, the integration checks whether
     spec 123 already recorded that cost, in the `csitea` workspace OR in the
     `spool-hub` workspace, and leaves it out (marked, never silently
     dropped) when it did. The vendor list stays as the fallback. No figure
     of either workspace leaves the hub for the check.
   - **Where spec 123 records a cost, per workspace** (read 2026-11-04 on
     `origin/master` `504cafd15`; prd `tenants`: `t1` is the workspace named
     `spool-hub`, the operator workspace; `csitea` is `csitea`):

     | the cost is in | table (rdb) | rows that count | read under |
     |---|---|---|---|
     | `csitea` | `cost_lines` (`0166`) | `tenant_id = 'csitea'`, live (`superseded_by IS NULL`) | the `csitea` tenant scope |
     | `spool-hub` | `cost_lines` (`0166`) | `tenant_id = 't1'`, and the estate rows `tenant_id IS NULL` (GCP projects, fleet tokens), live | the operator scope |
     | `spool-hub` | `cost_entries` (`0245`) | `type` `cloud` or `hr`, the month `period` | the operator scope |
     | `spool-hub` | `fleet_token_paid_items` (`0205`) | AI vendor subscriptions and top-ups whose `period_start..period_end` covers the month | the operator scope |

   - **The check (row B3b, [tasks.md](tasks.md) T5)**: the hub runs it at
     ingest, for each Netvisor card or purchase cost line, through one
     `SECURITY DEFINER` SQL function that returns only a label, never an
     amount: `csitea`, `spool-hub` or none. A line matches a spec-123 record
     when all three agree: (a) the vendor, through a vendor map in
     `netvisor_settings` (a Netvisor vendor or merchant text -> a spec-123
     `project_or_vendor` / `vendor` / `label`; a vendor with no map entry
     never matches); (b) the calendar month; (c) the amount and currency,
     equal within a tolerance kept in `netvisor_settings` (default 0, exact).
     A matched line is stored with `excluded = true` and a new
     `recorded_in` column (`csitea` | `spool-hub`), shown on the screen as
     "already in Costs (`<workspace>`)" and left out of the totals. A line
     whose vendor is mapped but whose amount does not match is kept and
     shown as "check: vendor also in Costs" so a person decides.
   - The check reads the other workspace's rows only inside that function;
     a person of `csitea` sees the label `spool-hub`, never the `spool-hub`
     figure.

### 4.3 What each card type gives (D11)

Netvisor sees a card purchase only once it is booked. What it can show
depends on the card type and on how the purchase is booked:

| card type | what reaches Netvisor | vendor per purchase | cost type per purchase | what the screen can show |
|---|---|---|---|---|
| **Debit card** (on the bank account) | each purchase is its own bank statement line; once matched it is its own ledger voucher line | only as the merchant free text of the line | yes, the account the line is booked to | every purchase, with its merchant text and account; nothing before the line is booked |
| **Credit card, settlement bill only** | ONE purchase invoice per card per month from the card issuer: the monthly settlement | no: the vendor is the card issuer | one line, usually one account | one total per card per month; no breakdown by vendor |
| **Credit card, booked per line** | the same monthly bill, but its rows (from the issuer's e-invoice with receipts, or split by the bookkeeper) are booked line by line | yes, from the e-invoice rows or the line text | yes, per booked line | every purchase, like a debit card |
| **Expense report** (a card receipt filed by a person) | an expense voucher once accepted | the line text | yes | every accepted receipt |

Consequences:
- Whether a credit card is booked per line or as one settlement total is
  a question for the accountants
  ([accountant-questions.md](accountant-questions.md) Q4). Until it is
  answered, B3 reads both: a settlement-only card shows as one line
  "card issuer, settlement" per month.
- A per-line-booked credit card must never ALSO count its settlement
  payment as a cost: the settlement is a payment of the card debt, not a
  new cost. B3 leaves out the settlement purchase invoice of a card whose
  lines are booked (its account is the card liability account, accountant
  question Q4), and the cash forecast (section 3) still counts the open
  settlement bill as an outgoing payment on its due date.
- Debit card purchases not yet matched to a voucher are invisible
  (section 4.1); the screen shows the newest booked voucher date.

---

## 5. Architecture and security gates (Option B + Option D)

### 5.1 Option B data flow (`csitea/csi-int-nvs` -> `csitea/csi-spl`)

```
[Netvisor API: isvapi.netvisor.fi]
        ^
        |  1. Sequential HMAC-SHA256 signed GETs (do_nvs_api_call)
        |     Keys & bookkeeping account settings in mode-0600 file on main box only (C6)
[Main box: csi-int-nvs do_nvs_sync (--env test | --env prd)]
        |
        |  2. HTTPS POST (operator ingest, csitea workspace only)
        |     Structured JSON snapshot (no raw XML, no keys, no logs with figures)
        v
[Spool Hub API (csi-spl-api) -> PostgreSQL (csi-spl-rdb)]
        |  FORCE RLS tenant_scope + person-seat read / owner write (C7, rdb 0260)
        |
        |  3. GET /v1/view/netvisor/* (any person's session in csitea; 403 for act-as
        |     clones, operator SA, agent seats and all agent/desk sessions; no MCP tool, C8)
        |     POST /v1/netvisor/refresh, GET|PUT /v1/netvisor/settings: HUM-10 only
        v
[Spool WUI (csi-spl-wui): Finance screen of every person of csitea]
```

### 5.2 Access control and privacy invariants (C2, C6, C7, C8)

1. **Main-box key residency (C6)**:
   - `CustomerId`, `CustomerKey`, `PartnerId`, `PartnerKey`, the target
     organisation business identifier, and the configured bookkeeping account
     numbers live only in the mode-`0600` file on the main box, separate per
     environment (`test` vs `prd`).
   - The file path and contents are never committed to git, never placed in
     `csi-spl-cnf`, never uploaded to GCP Secret Manager, and never copied to
     satellite boxes.
2. **Hub gates (C7 as rewritten, section 1.4)**:
   - The view routes (`GET /v1/view/netvisor/forecast`,
     `GET /v1/view/netvisor/card-costs`) check:
     1. caller has an authenticated human member session in the target
        workspace (`csitea`; every other workspace `404`),
     2. caller is **not** an act-as clone (`readerIsActAsClone` -> `403`),
     3. caller is **not** an operator service account, box session or agent
        desk session (any `Authorization` header -> `403`),
     4. caller's seat in the workspace is a person's: not an agent's, a time
        accountant's or a channel guest's (`403`).
   - The owner routes (`POST /v1/netvisor/refresh`, `GET` / `PUT
     /v1/netvisor/settings`) check the same, plus: caller's authenticated
     `human_id` equals the workspace's Netvisor owner (`HUM-10`, data in
     `netvisor_settings`, never a code constant, per section 1.3), else
     `403 forbidden`.
   - At the PostgreSQL layer (`csi-spl-rdb`), every `netvisor_*` table enables
     `FORCE ROW LEVEL SECURITY` with `tenant_scope` and RESTRICTIVE policies:
     writes only by the owner (`app.human_id` = `owner_human_id`) or the
     operator-ingest scope; reads by the owner or a person seated in the
     workspace (rdb `0260` `member_read`), never by the operator scope or a
     statement without a person.
3. **No agent access to figures (C8)**:
   - No MCP tool, no `spool` CLI read subcommand, and no spool message payload
     ever returns Netvisor figures. A refresh notification to `HUM-10` may state
     only that a new snapshot is ready and link to the WUI screen, with zero
     numbers ([research.md](research.md) section 6).

### 5.3 Option D: hierarchical balance sheet and P&L in Qto docs (C9)

Per C9 (`msg:adc2981c`) and [research.md](research.md) section 6.1:

- Today `workspace_doc`, `workspace_doc_item`, `workspace_doc_node` and
  `workspace_doc_rev_log` (`0157_workspace_docs.sql`,
  `0165_workspace_doc_node.sql`) are scoped to the whole workspace (`docs.read`
  / `docs.write`), so any workspace member or seated agent can read them.
- **Row B8** adds a nullable `restricted_to_human text` column on
  `workspace_doc` and enforces `(restricted_to_human IS NULL OR
  restricted_to_human = NULLIF(current_setting('app.human_id', true), ''))` across
  every read, search and export path of `workspace_doc*`, with agent/desk
  sessions and act-as clones never setting `app.human_id`.
- **Row B9** reads monthly account balances (`accountbalance.nv` with
  `intervaltype=3`) and the chart of accounts (`accountlist.nv`) and writes
  the hierarchical P&L and balance sheet into a Qto document of the `csitea`
  workspace. Since 2026-11-04 (section 1.4, C7 as rewritten) these documents
  are for every person of the workspace, so B9 no longer needs
  `restricted_to_human`; agents still never read them. B8's
  `restricted_to_human` stays as a feature for documents that are one
  person's alone.

**Qto visibility per workspace: the gap (D3)**. Read 2026-11-04 on
`origin/master` `504cafd15`:

| who may read a Qto document | built? | where |
|---|---|---|
| every seat of the workspace with `docs.read`, **agent seats included** | yes, the default | rdb `0157`, `0165`; `pure_agent` holds `DocsRead` (`csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go:247`) |
| one person only (no other member, no agent, no act-as clone) | yes, B8 (`SPL-4723`) | rdb `0256_workspace_doc_restricted_to_human.sql` |
| a grant per user, agent or role on a node | table only | rdb `0192_workspace_doc_acl.sql`; no read path calls `workspace_doc_acl_effect` (`grep -rn workspace_doc_acl_effect csi-spl-api/src/go --include=*.go` outside tests -> 0 lines) |
| **every person of the workspace, no agent** | **no** | the gap |

D3 needs the last line: the balance sheet and the P&L for every person of
`csitea`, never an agent. **Row B11** closes it: a document-level mode
`restricted_to = 'persons'` beside B8's one-person lock, enforced by a
RESTRICTIVE policy that reuses rdb `0260`'s `netvisor_person_seat()` test
(a live seat that is neither `pure_agent` nor `time_accountant`, not an
act-as clone, not a channel guest) on `workspace_doc`, `workspace_doc_item`,
`workspace_doc_node`, `workspace_doc_rev_log` and the search path. B9 writes
only into a document in that mode and refuses any other. The mode is per
workspace by construction (the tenant scope still applies), so the same
document type in another workspace reads only that workspace's persons.

---

## 6. Test and security cases

Every build row ships with automated tests and a red control proving the test
fails when the gate or logic is defective.

| case | row | what is proven | red control |
|---|---|---|---|
| C-NVS-1 | B1 | `do_nvs_api_call --env test` and the XML parsers read `accountbalance.nv`, `accountingledger.nv`, `paymentlist.nv`, `getpayrollpaycheckbatchlist.nv`, `dimensionlist.nv`, `getaccountdimensionlist.nv` sequentially against the test company (`Status` = `OK`) and emit zero monetary figures or account numbers to stdout/stderr/logs | plant an amount/account-number print in the parser: the log-hygiene assertion fails |
| C-NVS-2 | B2 | `do_nvs_cash_forecast --env test` computes the route-C month-end sum from fixture and test-company XML: subtracts a post-balance `paymentlist.nv` item once and drops its invoice from open payables; splits overdue receivables and unapproved payables; reports `newest_bank_voucher_date` | disable `paymentlist.nv` deduplication: the paid invoice is subtracted twice and the unit/fixture test fails |
| C-NVS-3 | B3 | `do_nvs_card_costs --env test` groups credit-card e-invoice purchase invoices by vendor and booked debit/credit card ledger lines by `AccountNumber` cost type and dimension cost centre, and skips/marks vendors on the spec-123 exclusion list | clear the exclusion list in the control run: excluded vendor lines enter the net card-cost total and fail the assertion |
| C-NVS-4 | B4 | Every `netvisor_*` table in `csi-spl-rdb` has `FORCE ROW LEVEL SECURITY` (`TestRLSCoversEveryTenantTable`); a query with `app.tenant_id` set to `csitea` but `app.human_id` unset or set to another human reads `0` rows | run with `app.human_id` policy clause removed in the control test: non-owner read returns rows and fails |
| C-NVS-5 | B5 | (the view routes: superseded by C-NVS-5b since D2; still holds for the owner routes) On all `/v1/view/netvisor/*` and `/v1/netvisor/*` routes: `HUM-10` gets `200`; another `csitea` admin (`HUM-20`), an act-as clone of `HUM-10`, the operator service account, a box session, and an agent desk session all get `403`; a caller in another workspace gets `404` | replace the `HUM-10` human-id check with a workspace `admin` role check: `HUM-20` gets `200` and the test fails |
| C-NVS-6 | B6 | `do_nvs_sync --env test` on the main box fetches the test-company forecast and card costs and ingests them into `dev` hub; a modes check refuses a credentials file whose mode is not `0600` | `chmod 0644` on a temporary test credentials file: `do_nvs_sync` refuses with exit non-zero before any HTTP call |
| C-NVS-7 | B7 | WUI e2e in Chrome: `HUM-10` opens the Finance screen, sees the forecast breakdown, newest voucher date, card costs by vendor/type/cost centre, and triggers "Refresh now"; a non-`HUM-10` admin sees `403` / no figures; all i18n keys pass `i18n-parity` and `i18n-no-raw-text` | omit a key in one non-English locale or render a raw label: `i18n-parity.test.mjs` / `i18n-no-raw-text.test.mjs` fails |
| C-NVS-5b | B5 (SPL-4792) | a person seated in `csitea` who is not `HUM-10` reads the view routes `200` with the figures; an agent seat, an act-as clone, a token and another workspace get `403` / `404`; the owner routes stay `403` for that person (`TestNetvisorHubRBAC`, `TestNetvisorStoreMemberRead`) | rdb `0255`'s `owner_scope` put back in place of `0260`'s policies: the member's read is empty and the test fails |
| C-NVS-8 | B8 | A `workspace_doc` row with `restricted_to_human = 'HUM-10'` is readable (`200`) by `HUM-10` and invisible (`403` / `0` rows in list, tree, node read and global `/s` search) to another `csitea` admin, an act-as clone of `HUM-10`, and any agent session | drop the `restricted_to_human` predicate in the control: the other admin or agent sees the document in list/search |
| C-NVS-9 | B9 | The balance-sheet & P&L generator creates/updates the hierarchical Qto doc from test-company `accountbalance.nv` (`intervaltype=3`) + `accountlist.nv` only into a document in B11's `persons` mode (v0.3; was `restricted_to_human = 'HUM-10'` before D2/D3); refuses to write into any other document | stub the mode check to return "workspace": generator aborts with fatal error and writes no node |
| C-NVS-11 | B11 | A `workspace_doc` in `persons` mode is readable by every person seated in `csitea` (admins and non-admins) and invisible (`403` / `0` rows in list, tree, node read, rev log and `/s` search) to an agent seat, a time accountant, an act-as clone, a channel guest and another workspace | drop the persons predicate from one read path (search): the agent seat finds the document and the test fails |
| C-NVS-12 | B3b | a Netvisor line whose mapped vendor, month and amount match a live `cost_lines` row of `csitea` is stored `excluded`, `recorded_in = 'csitea'`; one matching a `spool-hub` row (`cost_lines` `t1` / estate, `cost_entries`, `fleet_token_paid_items`) gets `recorded_in = 'spool-hub'`; an unmapped vendor is kept; the function returns no amount | make the function look in `csitea` only: the `spool-hub` match is kept in the totals and the test fails |

---

## 7. Build order, test company first (B1..B9)

Per the owner's order (section 1.1), every build row is small enough for a
single lane and is built, tested and proven against the **Netvisor test
company (`--env test`)** before any production access is requested or configured
(section 9).

| row | repo | scope (one lane) | done-proof (test company first) | red control |
|---|---|---|---|---|
| **B1** | `csitea/csi-int-nvs` (private) | Extend `csi-int-nvs-utl` (starting from `837fe08` `do_nvs_api_call`) with XML parsers and test-company probes for `accountbalance.nv`, `accountingledger.nv`, `paymentlist.nv`, `getpayrollpaycheckbatchlist.nv`, `getpayrollpaycheckbatch.nv`, `dimensionlist.nv`, and `getaccountdimensionlist.nv`, enforcing sequential calls and zero-figure log output. | Offline parser unit tests green + live `--env test` probe action against the Netvisor test company returns `Status` = `OK` for every resource with zero figures or ids in logs (case C-NVS-1). | Plant a figure/account-number log line or concurrent call in the test harness: the log-hygiene and sequential-call tests fail. |
| **B2** | `csitea/csi-int-nvs` (private) | Build `./run -a do_nvs_cash_forecast --env test` in `csi-int-nvs-utl`: implements route C (section 3.1: bank balance on configured bank bookkeeping account, newest bank voucher date from `accountingledger.nv`, open sales receivables + overdue split, unpaid purchase invoices + `getpurchaseinvoice.nv` due-date & approval split, post-balance `paymentlist.nv` deduplication, payroll batches, VAT/tax account balances) and emits a schema-validated JSON snapshot to a local file/fd (counts only on stdout). | Fixture unit tests + `--env test` run against the Netvisor test company exits `0` and produces a valid forecast JSON structure matching the test company's accounts (case C-NVS-2). | Remove `paymentlist.nv` post-balance deduplication or `PurchaseInvoiceDueDate` month-end filter: the fixture test fails on double-subtracted payment / wrong month total. |
| **B3** | `csitea/csi-int-nvs` (private) | Build `./run -a do_nvs_card_costs --env test` in `csi-int-nvs-utl`: implements section 4 (credit-card e-invoice purchase invoices by vendor, booked debit/credit card ledger lines from `accountingledger.nv` by `AccountNumber` cost type, dimension cost centre and merchant description, plus the spec-123 vendor exclusion list). | Fixture unit tests + `--env test` run against the Netvisor test company exits `0` and produces a valid card-cost JSON breakdown by vendor, cost type and cost centre (case C-NVS-3). | Disable the spec-123 vendor exclusion filter or account mapping: excluded vendor rows enter the net total and the test fails. |
| **B4** | `csitea/csi-spl` | Hub PostgreSQL migration (`csi-spl-rdb/src/sql/postgres/spool-hub/<next>_netvisor_finance.sql`) and store package (`csi-spl-api/src/go/spool-hub-api/internal/store/netvisor*.go`) for `netvisor_settings`, `netvisor_snapshots`, `netvisor_forecast_items` and `netvisor_card_cost_lines`, with `FORCE ROW LEVEL SECURITY` (`tenant_scope` + `owner_human_id` check). | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` green on PostgreSQL 16; `TestRLSCoversEveryTenantTable` and `TestNetvisorStoreRLS` green; deployed to `dev` and `prd` (case C-NVS-4). | Drop `FORCE ROW LEVEL SECURITY` or the `app.human_id` predicate in the control test: a tenant read without `HUM-10` returns rows and fails. |
| **B5** | `csitea/csi-spl` | Hub wire types and HTTP routes (`internal/wire/netvisor.go`, `internal/hub/netvisor.go`, `openapi.json`): operator ingest endpoint `POST /v1/operator/netvisor/snapshots` (`csitea` tenant only), `HUM-10`-only view/settings routes (`GET /v1/view/netvisor/forecast`, `GET /v1/view/netvisor/card-costs`, `POST /v1/netvisor/refresh`, `PUT /v1/netvisor/settings`), no MCP tool. Since 2026-11-04 (`SPL-4792`, section 1.4) the two view routes answer every person of `csitea`; refresh and settings stay `HUM-10`'s. | Go unit + Postgres integration tests (`TestNetvisorHubRBAC`, `TestNetvisorCrossTenant`) and pre-push gate green; deployed to `dev` and `prd` (case C-NVS-5). | Widen the route guard from `human_id == owner_human_id` to `Has(rbac.Admin)`: another `csitea` admin or act-as clone gets `200` instead of `403` and the test fails. |
| **B6** | `csitea/csi-int-nvs` (private) | Build `./run -a do_nvs_sync --env test` and its main-box nightly cron + refresh-queue poller in `csi-int-nvs-utl`: checks mode `0600` on the main-box credentials file, runs `B2` and `B3` against `--env test`, and posts the snapshot to `B5`'s ingest endpoint on `dev`. | Automated test with mock/dev hub + live `--env test` run on the main box ingests a test-company snapshot into `dev` with HTTP `200` and zero figures in the cron log (case C-NVS-6). | Set test credentials file mode to `0644` or target a non-`csitea` workspace: `do_nvs_sync` refuses before making any Netvisor call. |
| **B7** | `csitea/csi-spl` | Build the Finance screen in `csi-spl-wui` (for `HUM-10`; since 2026-11-04, `SPL-4792`, for every person of `csitea`, with "Refresh now" and the settings form `HUM-10`'s alone) (lazy route chunk, month-end cash forecast card + item table, newest bank voucher date badge, "Refresh now" button, card costs by vendor / cost type / cost centre, and bookkeeping-account settings form), with all locale translations reviewed by `agy`. | `pnpm run typecheck`, `i18n-parity`, `i18n-no-raw-text`, `i18n-untranslated`, and Chrome `pnpm run test:e2e` green against mock and `dev` test-company snapshot; deployed to `dev` and `prd` (case C-NVS-7). | Render the nav item or page data for a non-`HUM-10` admin or leave an untranslated key: e2e 403 check and `i18n-parity.test.mjs` fail. |
| **B8** | `csitea/csi-spl` | Add per-person, no-agent Qto document lock (`restricted_to_human` column on `workspace_doc` in `csi-spl-rdb` and enforcement across `workspace_doc*` store/hub read, tree and search routes in `csi-spl-api`, section 5.3). | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` green; `TestWorkspaceDocRestrictedToHuman` proves `HUM-10` reads `200` while another `csitea` admin, act-as clone and agent session get `403` / `0` rows in doc read and `/s` search (case C-NVS-8). | Bypass the `restricted_to_human` filter on doc tree or search: non-`HUM-10` admin or agent session sees the locked doc and the test fails. |
| **B9** | `csitea/csi-int-nvs` + `csitea/csi-spl` | Build Option D (C9): `do_nvs_balance_sheet_qto --env test` in `csitea/csi-int-nvs` reads monthly `accountbalance.nv` (`intervaltype=3`) and `accountlist.nv` from the test company and pushes a hierarchical P&L and balance sheet tree into a Qto document of the `csitea` workspace via `csi-spl-api` (workspace scope, section 5.3: every person reads it, no agent). | Proven against `--env test` on `dev`: a person of `csitea` opens the generated hierarchical Qto P&L and balance sheet; agents see `0` rows (case C-NVS-9). | Generate into a document an agent seat can read: the ingest handler refuses with `400` and writes nothing. |
| **B10** | `csitea/csi-int-nvs` + `csitea/csi-spl` | The open invoice lists (open sales invoices and open purchase invoices, with due dates and the overdue split) and the report order of the Finance screen (owner, 2026-11-04, section 1.4): cash forecast, card costs, P&L, balance sheet, open invoice lists. Workspace scope like B9. | The Finance screen shows the five reports in that order on `dev` against the test company; agents see `0` rows. | Reorder or drop a report: the e2e order check fails. |
| **B3b** | `csitea/csi-spl` | The spec-123 check of section 4.2 item 3 (D12): rdb migration adds `recorded_in` to `netvisor_card_cost_lines` and the vendor map + tolerance to `netvisor_settings`; one `SECURITY DEFINER` function returns `csitea`, `spool-hub` or none for a line; the ingest (B5) calls it per line. | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` green on PostgreSQL; case C-NVS-12. | Make the function look in `csitea` only: a `spool-hub` match stays in the totals and the test fails. |
| **B11** | `csitea/csi-spl` | Qto `persons` mode (section 5.3, D3): a document every person of the workspace reads and no agent seat does; RESTRICTIVE policies on `workspace_doc*` and the search path, reusing `netvisor_person_seat()`. B9's prerequisite. | `PRE_PUSH_TIER=full` green; case C-NVS-11. | Drop the predicate from the search path: the agent seat finds the document. |

**Batching**:
- Batch 1 (parallel): **B1** (`csitea/csi-int-nvs`) and **B4** (`csitea/csi-spl`), plus **B8** (`csitea/csi-spl`, independent `workspace_doc` lock).
- Batch 2 (parallel, after Batch 1): **B2** and **B3** (`csitea/csi-int-nvs`, after B1), and **B5** (`csitea/csi-spl`, after B4).
- Batch 3 (parallel, after Batch 2): **B6** (`csitea/csi-int-nvs`, after B2, B3, B5) and **B7** (`csitea/csi-spl`, after B5).
- Batch 4 (after B6): **B3b** (after B3 and B5) and **B11** (`csitea/csi-spl`, independent).
- Batch 5 (after B6 and B11): **B9** (`csitea/csi-int-nvs` + `csitea/csi-spl`; B8 is no longer a prerequisite since 2026-11-04, B11 is).
- Batch 6 (after B9): **B10**.
- The owner's order (D4) is the order the reports SHIP in: 1 cash forecast (B1, B2, B4..B7), 2 card costs (B3, B3b), 3 P&L and 4 balance sheet (B11, B9), 5 open invoice lists (B10). [tasks.md](tasks.md) lists them as T rows in that order; [plan.md](plan.md) says what is already on `master`.

---

## 8. Questions for the owner: answered on 2026-11-04

[research.md](research.md) section 8.2 left four choices open; `msg:91a1bc9a`
answered or redirected each:

1. **Q1 — Production Netvisor package**: unknown; the owner buys
   `Professional` if the API needs it (D9). Asked of the accountants
   ([accountant-questions.md](accountant-questions.md) Q6) before P1.
2. **Q2 — Production bookkeeping account numbers**: unknown; asked of the
   accountants (D10, [accountant-questions.md](accountant-questions.md)
   Q1..Q3). The numbers go into the main-box `0600` settings file with the
   keys (D8) or the owner's settings form (B7); never into git, a spec or a
   chat (C2).
3. **Q3 — When to ask Netvisor partner support for production**: still
   open; the default, unless the owner says otherwise, is after the first
   report (the cash forecast: B1, B2, B4..B7) works against the test
   company, because the owner put it first (D4).
4. **Q4 — Spec-123 vendor bills**: decided by D12 (section 4.2 item 3):
   matched by vendor map, month and amount in both workspaces; a matched
   line is marked "already in Costs (`<workspace>`)" and left out of the
   totals.

---

## 9. Production access (after test-company proof)

Production work begins **only after** the test-company build rows in section 7
are verified green against `--env test` and the owner gives the go.

| step | action | who | needs owner (`HUM-10`)? |
|---|---|---|---|
| **P1** | Confirm the production company is on a Netvisor package that includes the API (`Professional`, `Premium`, or `Palkat`, section 8 Q1). | Company admin (`HUM-10` / accountant) | **Yes (owner)** |
| **P2** | Submit the test-proven integration (`csitea/csi-int-nvs` against `--env test`) to **Netvisor partner support** for validation; partner support validates the integration and sends the production partner credentials (`PartnerId` + `PartnerKey`) by email ([research.md](research.md) 1.2 step 4). | Developer + Netvisor partner support | **Yes (owner / partner contact receives the production partner credentials)** |
| **P3** | In the **production** Netvisor company, open **Company menu > Access rights for interface resources** (the same "API resource access rights" page used in the test company) and allow the read-only (`GET`) resources used by `B1..B3` (`accountlist.nv`, `accountbalance.nv`, `accountingledger.nv`, `salesinvoicelist.nv`, `getsalesinvoice.nv`, `purchaseinvoicelist.nv`, `getpurchaseinvoice.nv`, `paymentlist.nv`, `getpayrollpaycheckbatchlist.nv`, `getpayrollpaycheckbatch.nv`, `dimensionlist.nv`, `getaccountdimensionlist.nv`, `contractinvoicingreport.nv`); keep all write resources disabled ([research.md](research.md) 1.2 step 5, 3.3). | Company admin in production Netvisor | **Yes (owner / company admin)** |
| **P4** | In the **production** Netvisor company, under a dedicated integration user, open **Company menu > Api identifiers > Create new api identifier** to mint the production `CustomerId` and `CustomerKey` ([research.md](research.md) 1.2 step 6, 1.3). | Company admin in production Netvisor | **Yes (owner / company admin)** |
| **P5** | Place the production credentials and production bookkeeping account numbers into the main-box mode-`0600` production credentials/settings file (or the `HUM-10` settings form for account numbers, Q2); never in git, chat or logs (C2, C6). The questions for the accountants about the bookkeeping accounts (which accounts hold the bank, VAT, tax and card costs) are asked here, with the production step (owner, 2026-11-04, section 1.4). | Owner / main-box operator, with the accountants | **Yes (owner)** |
| **P6** | Verify the production read path from the main box with `./run -a do_nvs_api_call --resource accountlist.nv --env prd` and `./run -a do_nvs_sync --env prd` (checking `ResponseStatus` `Status` = `OK` and comparing the resulting month-end forecast on `HUM-10`'s `prd` screen against Netvisor's production cash-flow forecast screen), then enable the nightly `--env prd` schedule on the main box. | Main-box lane (after owner go) + `HUM-10` verification on screen | **Yes (owner go before running `--env prd`, and owner visual check on screen)** |

---

## 10. What the owner does, in order

Each line is one step for `HUM-10`; the dispatcher turns them into forms.
Nothing here is done by an agent, and no key, number or file path is
written into a chat.

1. Forward [accountant-questions.md](accountant-questions.md) to the
   accountants and keep their answers off chat (they go into the main-box
   file in step 5).
2. Confirm the production company's Netvisor package; buy `Professional` if
   the API needs it (D9, P1).
3. Name the contact person for the Netvisor partner registration (the
   person partner support writes to for the production partner keys, P2).
4. In production Netvisor, create a dedicated integration user and, under
   it, the API identifier (customer keys), with only the read resources of
   P3 switched on (P3, P4).
5. Put the partner keys, the customer keys and the accountants' account
   numbers into the `0600` file on the main box yourself (D8, P5).
6. Give the go for the first `--env prd` run and check its month-end figure
   against Netvisor's own cash-flow screen (P6).
