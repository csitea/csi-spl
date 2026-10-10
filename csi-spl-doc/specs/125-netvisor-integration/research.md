# Research: a Netvisor API link for the csitea workspace

Feature: `125-netvisor-integration` · Date: 2026-10-10 · Version v1.2 (owner rules C6..C9 folded in) · Status: research only
(no code, no sign-up, no vendor contact, no call that needs credentials).

The owner's ask (csitea topic 67c25538): "some kind of API between the Spool
Hub workspace (this one) and Netvisor to fetch some data and get reports ...
programmatically" (msg 9f6e0d59); "Investigate what the options are for the
NetVisor API, as well as the costs and the possible technical means"
(msg dc5d1be3). First use case, the end-of-month cash balance: "I would like
to see how much money I will have at the end of the month" (msg 8f52f9a6).
Second, card payments and their cost structure (msg 2a339876). Later: the
balance sheet and cost items feeding spec 123 cost tracking (msg bb460926).
The company's bank APIs are out of scope here: they have their own lane
(spec 126), and the owner chose to take the balance from Netvisor instead
(section 4).

Every claim cites a public vendor page, all read on **2026-10-10**. Source
keys like `[S1]` resolve in section 9. A figure with no source is written
"not found"; a price that is not published is written "not public".

## 0. Summary

| question | answer |
|---|---|
| Can a company that already uses Netvisor build its OWN integration? | Yes, but every request needs BOTH the company's API identifiers (CustomerId + CustomerKey) AND software-partner credentials (PartnerId + PartnerKey), "including for self-implemented integrations" [S2]. Partner credentials come from Netvisor partner support after the integration is validated in their test environment [S3]. |
| What does the API cost? | The software interface is included in the Professional, Premium and Palkat packages [S4][S5]. Reading data costs nothing extra; only three WRITE resources carry transaction fees (accounting data with attachment, purchase invoice import, eScan import) [S5]. The partner programme is free [S3]. |
| What is the API like? | XML over HTTPS, GET to read and POST to write, at `https://isvapi.netvisor.fi/<resource>.nv` [S6]. Each request is signed with an HMAC-SHA256 MAC [S2]. One call at a time per customer environment [S6]. No webhooks were found: polling only [S6]. |
| Cash forecast (chosen route C) | Bank balance = `accountbalance.nv` on the bookkeeping account behind the one bank account [S14][S17]; + open sales invoices (`salesinvoicelist.nv`: `OpenSum`, `InvoiceDueDate`) [S9]; - open purchase invoices (`purchaseinvoicelist.nv` + `getpurchaseinvoice.nv`: `PurchaseInvoiceDueDate`, `InvoiceStatus`, `ApprovalStatus`) [S10][S11]; - payslips (`getpayrollpaycheckbatchlist.nv`) [S12]; - VAT and employer contributions from ledger balances [S14]. No API resource reads Netvisor's own cash-flow forecast screen [S16]. |
| Card payments | Arrive as card-provider e-invoices with receipts [S27], as bank statement lines booked with posting rules [S28], or as travel expense reports; once booked they are ledger lines with account and cost centre, readable with `accountingledger.nv` [S15]. |
| Recommendation | Option B (section 6): a read-only fetch action on the main box (`<DEV_BOX>`), keys in a 0600 file there only (owner msgs 072a9990, c0bcb7b1); it posts the fetched data through an operator endpoint into HUM-10-only hub tables (owner msg 42924894); a simple WUI screen for HUM-10 answers the questions by code, agents never see figures (owner msg 9a9e0802). Option D adds the balance sheet and P&L as a generated Qto document (owner msg adc2981c), which needs a per-person doc lock that does not exist yet. Effort L in total (section 6). |

## 1. Access options

### 1.1 The three routes

| route | what it is | keys needed | fits us? | source |
|---|---|---|---|---|
| **Own-use integration** (we build it) | the company writes its own client against the API | CustomerId/CustomerKey (made by the company's admin) + PartnerId/PartnerKey (from Netvisor partner support) | **yes**: the owner asked for exactly this | [S1][S2][S3] |
| **Software partnership** (we sell it) | the same build, then listed on the vendor marketplace for other Netvisor customers | the same four keys | not now; the same technical path, so it stays open | [S3] |
| **Third-party connector / unified API** | a vendor's hosted API in front of Netvisor (example found: a "unified accounting API" listing nine Netvisor resources: customers, invoices, vendors, credit notes, purchase orders, products, purchase invoices, journal entries, payments) | the connector holds the keys | **no**: no account balances or payroll in its list, a monthly fee, and the keys and finance data would sit with a third party, which the owner's rules C2, C6 and C7 (section 8.1) rule out | [S19][S20] |

Netvisor's vendor does not build integrations for customers: per a search
snippet of the integrations FAQ, "a developer is needed as Visma Solutions Oy
does not make or subcontract integrations" [S21] (snippet only, see section 9).

### 1.2 The own-use path, step by step

| # | step | who | source |
|---|---|---|---|
| 1 | Check the company is on **Professional, Premium or Palkat**. Enabling the interface "does not automatically update the company to Professional or Premium package"; upgrading is a separate order in the vendor's store. | company admin | [S4][S5] |
| 2 | Order a **test environment** by registering on the partner form. It is "the same as the Netvisor training environment" (`koulutus.netvisor.fi`), delivered "completely empty"; partner support can load test data "with a ready-made script". | developer | [S3] |
| 3 | Build and test against the test environment. | developer | [S3] |
| 4 | Partner support **validates** the integration and **delivers the production partner credentials** (PartnerId + PartnerKey) "via email". | partner support | [S2][S3] |
| 5 | In production Netvisor, the admin opens **Company menu > Access rights for interface resources** and allows the resources the integration uses. A custom integration gets "an access rights key from the implementer". | company admin | [S7] |
| 6 | The admin opens **Company menu > Api identifiers > Create new api identifier**. That gives the user identifier (= **CustomerId**) and key (= **CustomerKey**). | company admin | [S1][S7] |

### 1.3 The keys

| key | sent in a header? | issued by | lifetime | source |
|---|---|---|---|---|
| CustomerId | yes, `X-Netvisor-Authentication-CustomerId` | the company's Netvisor admin (step 6) | valid "as long as the user who created them has access rights" | [S2][S7] |
| CustomerKey | **no**: used only to compute the MAC | the same | the same | [S2][S7] |
| PartnerId | yes, `X-Netvisor-Authentication-PartnerId` | Netvisor partner support, by email | not found | [S2] |
| PartnerKey | **no**: used only to compute the MAC | the same | not found | [S2] |

Consequence: the CustomerId/CustomerKey pair stops working when the Netvisor
user who created it loses their rights. Create it under a dedicated
integration user, not a person's account (owner question 4).

### 1.4 Authentication scheme [S2]

Headers on every request:

| header | value |
|---|---|
| `X-Netvisor-Authentication-Sender` | free-form name of the integration |
| `X-Netvisor-Authentication-CustomerId` | CustomerId |
| `X-Netvisor-Authentication-PartnerId` | PartnerId |
| `X-Netvisor-Authentication-Timestamp` | ANSI time, GMT+0, e.g. `2023-05-04 12:00:00.000` |
| `X-Netvisor-Authentication-TimestampUnix` | seconds since 1970-01-01 UTC |
| `X-Netvisor-Interface-Language` | `FI`, `SE` or `EN` |
| `X-Netvisor-Organisation-ID` | business id of the target company |
| `X-Netvisor-Authentication-TransactionId` | a new GUID per request; a reused one is rejected, and uniqueness is checked across every customer of the same PartnerId |
| `X-Netvisor-Authentication-MAC` | HMAC-SHA256 (below) |

MAC input, joined with `&`, in this order: URI, Sender, CustomerId,
Timestamp, Language, Organisation-ID, TransactionId, TimestampUnix,
CustomerKey, PartnerKey. A string with umlauts is encoded as ISO-8859-15
before hashing. The two keys never travel in a request.

## 2. Costs

### 2.1 Netvisor's own fees

| item | price (excl. VAT) | source |
|---|---|---|
| Software interface (API) itself | included in Professional, Premium and Palkat | [S4][S5] |
| Reading data (every GET resource this research needs) | no transaction fee found; "the use of other interface resources is included in the pricing of the Professional, Premium, or Pay packages" | [S5][S7] |
| Fees on WRITES only: `accounting.nv` with attachment, `purchaseinvoice.nv`, `eScan.nv` | per transaction; an imported purchase invoice is always charged an e-invoice fee; e-invoice reception is 0.87 to 0.34 € per item by monthly volume band; eScan document 0.59 to 0.54 € | [S5][S10b][S22] |
| Professional package, turnover under 0.1 M€ | 81 €/mo | [S22] (price list in force 1.10.2026) |
| Professional, 0.1 to 0.2 M€ / 0.2 to 0.5 M€ / 0.5 to 1.0 M€ | 108 / 161 / 249 €/mo | [S22] |
| Premium, the same four bands | 118 / 145 / 202 / 300 €/mo | [S22] |
| Core (no interface), the same four bands | 46 / 67 / 112 / 176 €/mo | [S22] |
| Payroll and work-time, per employee | 6.5 €/mo for employees 1 to 5, 4.0 € for 6 to 100 | [S22] |
| Electronic receipt service for payment cards (listed as ReceiptHero) | 2.50 €/card/mo for cards 1 to 5 | [S22] |
| "Retrieval of account balance" (bank transaction fee) | 0.57 to 0.28 € per item by monthly volume band | [S22] |
| Vendor's onboarding / "integrations and other consulting" | 160 €/h | [S22] |
| Reservation in the price list | "Visma Solutions Oy reserves the option of pricing the interface according to the materials transferred on a transaction-by-transaction basis. The pricing is based on the price of the e-invoice." [S5] charges no such fee on read resources today. | [S22] |
| Software partnership | "Free access to the partner program" | [S3] |
| Partner credentials, test environment | no fee found | [S3] |

So: if the company already runs Professional or Premium, a read-only
integration adds **no Netvisor fee** we could find. If it runs Core, the extra
cost is the difference to Professional for its turnover band (e.g. 81 - 46 =
35 €/mo under 0.1 M€) [S22]. Which package the company runs is owner question 5.

### 2.2 Third-party connector (route 3, for comparison)

| item | price | source |
|---|---|---|
| Unified API vendor, entry plan | €599/mo, "starts at 25 active consumers" | [S20] |
| The same, next plan | €1,299/mo | [S20] |

That pricing is for a vendor reselling to many customers. For one company's
own data it costs more than all the other lines in this section combined.

### 2.3 Our side

Small: the fetch runs on the main box (section 6), a nightly poll of a few
XML lists; the hub gains one operator endpoint, a few HUM-10-only tables of
one company's invoices and balances, and one screen. Not measured; the spec
measures it.

## 3. Technical means

### 3.1 The API's shape [S6]

| property | value |
|---|---|
| Base | `https://isvapi.netvisor.fi/<resource>.nv`, HTTPS only, production and test |
| Format | XML requests and responses (DTD/XSD per write resource); not JSON |
| Methods | GET reads, POST writes |
| Response | `ResponseStatus` with `Status` OK/FAILED, `TimeStamp`, `Details` |
| Errors | `AUTHENTICATION_FAILED`, `INVALID_DATA`, `INVALID_DATA_SIZE`, `DUPLICATE_DATA`, `REQUEST_NOT_UNIQUE`, `PERIOD_LOCK`, `SERVICE_ACCESS_ERROR`, `SYSTEM_MAINTENANCE`, `TECHNICAL_ERROR` |
| Concurrency | "Send one call at a time and wait for a response before sending the next call. Overlapping calls to the same customer environment cause various error situations." Timeout at least 120,000 ms. |
| Rate limit | no number published (not found); the rule above is the limit |
| Frequency advice | large reads "outside office hours"; "transfers once a day or once a month are sufficient" in many cases |
| Push / webhooks | none found: polling only. Incremental reads use `lastmodifiedstart`/`lastmodifiedend` (invoice lists) and `changedsince` (ledger) [S9][S10][S15] |
| Sandbox | yes: the training environment, ordered by a partner [S3] |

### 3.2 What can be READ

| data | resource (GET) | key fields | source |
|---|---|---|---|
| Sales invoice list | `salesinvoicelist.nv` | `InvoiceDueDate`, `OpenSum` (incl. VAT), `InvoiceStatus` (+ substatus); filter `invoicestatus=open`, invoice dates, last-modified dates | [S9] |
| Sales invoice detail | `getsalesinvoice.nv` | `SalesInvoiceDueDate`, `InvoiceStatus` (open, paid, unsent, overdue, reminded, requested, collected, creditloss, rejected), `SalesInvoiceAmount`, `PaymentPlan` (`DueDate` + `Sum` per instalment) | [S23] |
| Sales payments | `salespaymentlist.nv` | received payments | [S24] |
| Contract invoicing forecast | `contractinvoicingreport.nv` | "Sales and cash flow projections" for recurring contract invoices | [S24] |
| Purchase invoice list | `purchaseinvoicelist.nv` | `Sum`, `Payments`, `OpenSum`; filters `invoicestatus` (open, approved, accepted), paid/unpaid, dates | [S10] |
| Purchase invoice detail | `getpurchaseinvoice.nv` | `PurchaseInvoiceDueDate`, `PurchaseInvoiceValueDate`, `InvoiceStatus` (open, due for payment, paid), `ApprovalStatus` (open, in factual verification, approved, accepted/rejected), `PurchaseInvoiceAmount`, `PurchaseInvoicePaidAmount` | [S11] |
| Purchase payments made | `paymentlist.nv` | `Date` (payment date), `HomeCurrencySum`, `Reference`, linked invoice key/number; executed payments only | [S29] |
| Bank transfers sent through the API | `unprocessedoutgoingpayments.nv` | `Identifier`, `Status` (2 = OK, 3 = error), `StatusDescription`; only "payments sent via API" | [S30] |
| Vendors | `getvendor.nv` | vendor record | [S10b] |
| Ledger (vouchers) | `accountingledger.nv` | `VoucherDate`, `VoucherDescription`, `AccountNumber`, `LineSum`, VAT percent/code, line description, dimensions (cost centres); filters by date, account range, status; up to 500 keys per call | [S15] |
| Account balances | `accountbalance.nv` | per account: number, name, then per date `Date`, `Debet`, `Kredit`, `Balance`; `balancedates` + `intervaltype` (day, week, month, year); no account filter = every account | [S14] |
| Dimensions / cost centres | `dimensionlist.nv`, `getaccountdimensionlist.nv` | dimension names and items; accounting follow-up objects with their accounts | [S25][S26] |
| Payslips | `getpayrollpaycheckbatchlist.nv`, `getpayrollpaycheckbatch.nv` | payslips by payment date; lines, debit/credit accounts, dimensions, status Open/Confirmed/Paid | [S12][S13] |
| Customers, products, payment terms | customer and product resources, `paymenttermlist.nv` | registers | [S1][S24] |

**Not found as an API resource** (each checked on the pages cited):

| data | what the docs say | source |
|---|---|---|
| Bank statements (lines) | "bank statements can only be printed from Netvisor in pdf or html format" | [S17] |
| The cash-flow forecast screen | the feature exists in the UI; no export or API mentioned | [S16] |
| VAT return / periodic tax return | UI only (Financial management > Company obligations > Self-initiated taxes); body not read first-hand | [S18] |
| A scheduled payment date on a purchase invoice | no such field in `getpurchaseinvoice.nv` | [S11] |
| Ready P&L or balance sheet report | not found; it can be built from `accountbalance.nv` + the chart of accounts | [S14] |

### 3.3 What can be WRITTEN (not needed for either use case)

Sales invoices and orders (`salesinvoice.nv`), sales payments
(`salespayment.nv`), payment matching, purchase invoices
(`purchaseinvoice.nv`, fee), bank transfers (`payment.nv`), vouchers
(`accounting.nv`, fee with attachment), travel expenses (`tripexpense.nv`),
vendors, purchase orders [S24][S10b][S31][S5]. A read-only version needs none
of them, and none of their access rights (section 1.2 step 5).

## 4. Use case 1: end-of-month cash, route C (CHOSEN)

**Owner decision, csitea topic fc0119cd, msg 70b69575: "C"** (option C of the
spec 126 research): the cash balance comes from the bank data Netvisor
already imports. No bank API.

### 4.1 The bank balance from Netvisor

| question | answer | source |
|---|---|---|
| How does the bank data get into Netvisor? | electronic bank statements over the payments-traffic service (a payments-traffic agreement with the bank; statements in KTO format) | [S17] |
| How fresh? | "Netvisor retrieves material from the bank every half hour"; "Usually, the previous day's material has arrived by six o'clock the next morning at the latest, depending on the bank." Daily or weekly statements are a company setting; daily is advised with many transactions. | [S17] |
| Which resource gives the balance? | **`accountbalance.nv`**, on the bookkeeping account "set behind the bank account", with `balancedates=<date>` | [S14][S17] |
| As of when? | the balance of **posted** vouchers on that account. Statement lines are "not automatically booked to the ledger": a user links them to vouchers (by automatic matching or by hand). So the figure is as of the last processed statement, normally yesterday's if statements are daily and processed. | [S17] |
| Can the statement's own closing balance be read? | no: statements are PDF/HTML only, no API resource | [S17] |
| Lag check | Netvisor's statement view shows "Difference" = statement closing balance - bookkeeping balance; zero means caught up. The forecast shows the date of the newest voucher on the bank account (from `accountingledger.nv` with that account range) so a stale balance is visible. | [S17][S15] |

### 4.2 Does route C need a bank account id?

**No bank account number (IBAN) is needed.** `accountbalance.nv` is keyed by
the bookkeeping account, not the bank account: called with no `netvisorkey`
it returns every account with its number and name [S14]. The connector needs
one value, the **bookkeeping account number** behind the one bank account
(from the company's chart of accounts; owner question 6). The bank account
number itself is never sent, stored or read by option C.

That bookkeeping account number is company configuration and finance data
under the owner's rules (section 8.1). It lives with the fetch action's
settings in the 0600 file on the main box (C6), or as a setting row in the
HUM-10-only hub tables (C7), never in git, cnf, specs, logs or chat. The
owner's offer to send "the account ID" (msg aa3a837e) is therefore not
needed for route C. If it is sent anyway, it goes into that file, not into a
topic.

### 4.3 Netvisor's own cash-flow forecast

Netvisor has a **cash flow forecast** screen, included in the Basic, Core,
Professional and Premium packages. It uses "the balance of the ledger and
bank statement", open receivables, unpaid expenses, "salaries due during the
current month", tax-account payments, and manual events the user adds [S16].
No export and no API for it were found [S16]. The connector rebuilds the same
sum from the resources below. Its first acceptance check: our month-end
figure matches that screen on the same day.

### 4.4 The month-end sum

Owner (msg c45c7cb0): "Almost everything is paid via" Netvisor. So the
outgoing side is Netvisor's purchase invoices.

| term | Netvisor source | how | source |
|---|---|---|---|
| Bank balance | `accountbalance.nv`, bank bookkeeping account, `balancedates=<today>` | section 4.1 | [S14] |
| + receivables due by month end | `salesinvoicelist.nv?invoicestatus=open` | sum `OpenSum` where `InvoiceDueDate <= month end`; overdue ones shown apart (they may not arrive) | [S9] |
| - payables due by month end | `purchaseinvoicelist.nv` (unpaid) for `OpenSum`; `getpurchaseinvoice.nv` per open invoice for `PurchaseInvoiceDueDate`, `InvoiceStatus` (open / due for payment / paid) and `ApprovalStatus` | sum `OpenSum` where due date <= month end; split approved vs not yet approved | [S10][S11] |
| scheduled payment date | not exposed: `getpurchaseinvoice.nv` has no scheduled-date field, `paymentlist.nv` lists executed payments only, `unprocessedoutgoingpayments.nv` covers API-sent transfers only | use `PurchaseInvoiceDueDate` as the expected pay date (owner question 8) | [S11][S29][S30] |
| paid since the last statement | `paymentlist.nv` (`Date`, `HomeCurrencySum`, invoice key) | a payment dated after the bank balance's date is subtracted from the balance once, and its invoice is not counted again as open | [S29] |
| - salaries | `getpayrollpaycheckbatchlist.nv` for payment dates in the month, status Open/Confirmed/Paid; lines via `getpayrollpaycheckbatch.nv` | net pay by line account; withholding and employer contributions fall due later, through the tax account | [S12][S13] |
| - VAT due | no resource; `accountbalance.nv` on the VAT payable account(s) | which period's VAT falls due this month follows the company's tax schedule, which the API does not expose (not found); which accounts is owner question 6 | [S14][S18] |
| - employer contributions, withholding | no resource; `accountbalance.nv` on the tax-account / liability accounts | the same | [S14] |
| + recurring contract sales (optional) | `contractinvoicingreport.nv` | only if contract invoicing is used | [S24] |

Calls per refresh, sequential (one at a time [S6]): 1 balance + 1 sales list
+ 1 purchase list + one `getpurchaseinvoice.nv` per open purchase invoice +
1 payment list + 1 payslip list + 1 balance call for the tax accounts. For a
small company that is tens of calls, well inside one nightly run.

## 5. Use case 2: card payments and their cost structure

Owner (msg 2a339876): "integrate the payments that are paid through the bank
card and see the cost of their structures as well". Whether the card is a
debit card on the one account or a separate credit card is being asked by
the dispatcher; both routes are below.

### 5.1 How card purchases reach Netvisor

| route | what arrives | how it is booked | source |
|---|---|---|---|
| **Debit card on the one bank account** | each purchase is a line of the imported bank statement | a user links the line to a voucher; **posting rules** create a posting proposal automatically for similar lines (e.g. the same merchant) | [S17][S28] |
| **Card provider's e-invoice** (credit or charge card) | "Several service providers can deliver invoices and their receipts made with the card directly to Netvisor electronically as e-invoices", to the company's e-invoice address given when applying for the card | a purchase invoice with its receipts; from the receipt data Netvisor creates "either a voucher or a travel expense report" | [S27] |
| **Electronic receipts per card** (price list: ReceiptHero) | digital receipts from linked cards | 2.50 €/card/mo; how the receipt is booked is not documented on the pages read | [S22] |
| **Travel and expense reports** | the employee's expense lines with receipts (mobile scan / eScan) | lines go through statuses open, confirmed, verified, accepted, paid | [S31][S22] |

### 5.2 Can costs be broken down by vendor and cost type?

| breakdown | available? | from | source |
|---|---|---|---|
| By cost type (account) | **yes**, once booked: every ledger line has `AccountNumber` and `LineSum` with VAT code | `accountingledger.nv` | [S15] |
| By cost centre | **yes**, if the company uses dimensions: each ledger line carries its dimensions | `accountingledger.nv`, `dimensionlist.nv` | [S15][S25] |
| By vendor, e-invoice route | **yes**: a purchase invoice has a vendor (name, business id) | `purchaseinvoicelist.nv`, `getpurchaseinvoice.nv` | [S10][S11] |
| By vendor, debit-card statement route | **partly**: no vendor record; the merchant is only in the voucher or line description, as the statement text gave it (not verified field by field) | `accountingledger.nv` `VoucherDescription` / line description | [S15] |
| Unbooked card lines | **no**: statement lines are not readable by API until booked | — | [S17] |

So the e-invoice route gives the cleanest vendor breakdown; the debit-card
route gives account and cost centre, and vendor only as text. The more
posting rules the company has, the less a booked card line lags its purchase
[S28].

### 5.3 How it feeds spec 123 cost tracking

Spec 123 (`csi-spl-doc/specs/123-cost-tracking/spec.md`, read, not edited):

- Every reader sits behind one cost-source contract (`name`,
  `read(day) -> cost_lines rows + one cost_coverage row`, registered in cnf
  `cost.sources`), so a Netvisor reader is one more implementation with no
  change to the rollup (123 section 4.6).
- `cost_lines.origin` is one of `billing_export | metered | transcript |
  agent_run | invoice | hand | estimate` (123 section 4.1). Purchase invoices
  and card-provider e-invoices fit `invoice`. Booked card lines from the
  statement may need a new value (e.g. `ledger`); that is 123's decision.
  `project_or_vendor` = the vendor (or the description text on the
  debit-card route); `kind` = the account's cost type.
- **Double-count risk**: GCP and AI-vendor bills are read by 123 from their
  own sources (billing export, transcripts) AND are paid by card or invoice
  and booked in Netvisor. The Netvisor reader must skip vendors another
  source already covers, or 123 sums them twice. To be agreed with spec 123's
  owner before any build.
- Privacy: 123's `cost_lines` is per workspace with tenant RLS (123 test
  "Tenant isolation"), and 123 shows costs to holders of `costs.read`. The
  owner's rule C7 is narrower: Netvisor figures are for HUM-10 only. So
  Netvisor rows cannot go into the shared `cost_lines` page as it is
  specified; either 123 adds an owner-only class of rows checked by
  HUM-10's id, or the Netvisor costs stay in spec 125's HUM-10-only tables
  and screen. 123's owner decides; spec 125 must not widen access.

## 6. Fit for Spool Hub: architecture options

Rules for every option, from the owner (section 8.1):

- **Finance keys on the main box only** (C6, msgs 072a9990 and c0bcb7b1):
  the four Netvisor values (and the bank's, spec 126) live in one 0600 file
  under the harness user's `$HOME` on the main box, read only by the
  main-box fetch action. Not on the satellite, **not in GCP Secret
  Manager**, not in git, cnf, terraform state, logs, spool posts or CI
  output. The scope is the finance keys only: the GCP keys may stay on the
  satellite (c0bcb7b1). Every lane that handles the finance keys is placed
  on the main box.
- **HUM-10 only** (C7, msg 42924894): the keys and ALL finance data and
  reports are for HUM-10 alone: no other csitea member, no admin role, no
  other workspace. The hub checks HUM-10's human id on every read, never by
  hiding UI. Red control: a csitea admin who is not HUM-10 gets 403.
- **Simple UI, agents never see figures** (C8, msg 9a9e0802): the data is
  stored first and analysed later by code over the stored data. A simple WUI
  screen answers the owner's questions. Agents build and run the pipeline;
  they never receive figures (no MCP tool, no post with amounts, no agent
  session that can read the tables).

| | **A. Hub connector** | **B. Main-box fetch + HUM-10 tables + simple screen** (recommended) | **C. MCP tool for agents** | **D. Balance sheet as a Qto doc** (add-on to B) |
|---|---|---|---|---|
| What | the hub (Cloud Run) signs and sends the Netvisor calls | `./run -a do_spl_netvisor_read` on the main box (nightly cron + on demand) reads Netvisor and posts the rows through an **operator endpoint** (the spec 123 transcript-reader pattern) into HUM-10-only hub tables; a **simple WUI screen** for HUM-10 shows cash today, the month-end forecast (section 4) and card costs by vendor and type (section 5), computed by code from the stored rows | an MCP tool agents call for the figures | after each fetch, code writes the balance sheet and P&L as a hierarchical Qto document (account groups -> accounts, one month per column or per revision), from the stored balances (C9, msg adc2981c) |
| Keys live | would need Secret Manager or the hub's environment | the 0600 file on the main box (C6) | n/a | none (reads B's stored rows) |
| Allowed? | **no**: the keys would leave the main box (C6) | **yes** | **no, out** (C8): agents never receive figures. Not "later". | **only after a per-person doc lock is built** (gap below) |
| Who sees it | n/a | HUM-10 only, by human id at the hub + RLS on the tables (C7) | n/a | must be HUM-10 only, no agent |
| Effort | n/a | **L**: signer + XML client + ~10 read resources (M); operator endpoint, DDL with RLS and the HUM-10 check, tests and controls (M); one simple screen (S/M) | n/a | **M**: the generator (S) + the per-person, no-agent doc lock (M) |
| Risk | n/a | the main box down or asleep = no fetch that night (the next run catches up); the operator endpoint must refuse any workspace but csitea | n/a | until the lock exists, every csitea member with `docs.read`, agents included, could read the document |
| Stays out of git/logs | n/a | keys and settings (main-box file), raw XML (never logged; only counts and status), amounts (hub tables only; never in a log, topic or DM) | n/a | amounts only inside the locked document |

A notification may tell HUM-10 that a new fetch is ready (a DM with no
figures, a link to the screen); the figures stay on the screen.

Why B: it is the only option the owner's rules C6..C8 all allow. The keys
stay on the main box; the data lands where the owner wants analysis to run
("after the data exists in our database", msg 9a9e0802); the screen is the
only place figures are shown, and only to HUM-10.

### 6.1 Option D's gap: Qto documents are private per workspace, not per person

Measured on origin/master (2026-10-10):

- `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql` lines
  86-108: `workspace_doc`, `workspace_doc_item` and `workspace_doc_rev_log`
  carry only two RLS policies, `tenant_scope` (`tenant_id =
  app.tenant_id`) and `operator_scope`. `0165_workspace_doc_node.sql` lines
  85-89: the same two for `workspace_doc_node`. No column or policy names a
  member.
- `csi-spl-rdb/src/sql/postgres/spool-hub/0123_docs_permissions.sql` lines
  20-21: access inside a workspace is the role permission `docs.read` /
  `docs.write`, not a person.
- Spec 114 section 1: "Out of scope: per-member access inside one workspace
  (every member of a workspace sees its documents, as today)".

So a HUM-10-only, no-agent document **does not exist and must be built**:
e.g. a per-document `restricted_to_human` column with a policy that adds
`AND (restricted_to_human IS NULL OR restricted_to_human =
app.human_id)`, set only by the generator, with agent (desk) sessions never
carrying that human id. Tests: HUM-10 reads it; a csitea admin who is not
HUM-10 gets 403 and 0 rows; an agent session gets 0 rows; each with a control
that drops the policy and sees the rows. Until that lands, option D stays
off and the balance sheet is shown on B's screen.

Per-env note: the dev run talks to the Netvisor **training environment**,
the prd run to production, each with its own key file on the main box. That
keeps test traffic out of the real books.

## 7. Later scope: balance sheet, cost items

| want | Netvisor source | source |
|---|---|---|
| Balance sheet / P&L by month | `accountbalance.nv`, all accounts, `intervaltype=3` (month), grouped by the chart of accounts; shown on B's screen, or as option D's Qto document once the lock exists (section 6.1) | [S14] |
| Cost items per account | `accountingledger.nv` lines (`AccountNumber`, `LineSum`, VAT code) by date range; incremental with `changedsince` | [S15] |
| Cost items per cost centre | the dimensions on each ledger line; `dimensionlist.nv` for names | [S15][S25] |
| Supplier costs | `purchaseinvoicelist.nv` / `getpurchaseinvoice.nv` | [S10][S11] |

The spec 123 link is the same as in section 5.3.

## 8. Owner constraints and questions

### 8.1 Answered (constraints for the spec)

| # | owner's words | rule for spec 125 |
|---|---|---|
| C1 | "C" (fc0119cd, msg 70b69575) | the cash balance comes from Netvisor's imported bank data (section 4); no bank API |
| C2 | "Anything related to the finances of [Csitea] should be private to this workspace." (fc0119cd, msg 873f6f84) | **superseded by C7** for who sees the data. Still stands: no figures, account numbers, ids or keys in git, specs, logs, CI output or other repos. |
| C3 | "The company has only one account." (fc0119cd, msg aa3a837e) | one bank bookkeeping account in the forecast; no bank account number needed (section 4.2) |
| C4 | "Almost everything is paid via" Netvisor (fc0119cd, msg c45c7cb0) | outgoing payments = Netvisor purchase invoices (section 4.4) |
| C5 | card payments and "the cost of their structures" (fc0119cd, msg 2a339876) | use case 2 (section 5) |
| C6 | "Keys and secrets should stay only on the [main] box, not on [the satellite]." (fc0119cd, msg 072a9990); scoped by msg c0bcb7b1: only the financial keys (bank and Netvisor) stay on the [main] box, "The Google keys could go on the SAT box as well." | the Netvisor and bank keys live only in a 0600 file on the main box, read by the main-box fetch action; not on the satellite and not in GCP Secret Manager; GCP keys are not affected; option B (section 6) |
| C7 | no access to the keys or the information for "any other member other than me" (fc0119cd, msg 42924894) | keys and all finance data and reports for HUM-10 only: no other csitea member, no admin role, no other workspace; delivery only to HUM-10; enforced by HUM-10's human id at the hub, never by UI hiding; red control: a csitea admin who is not HUM-10 gets 403 (dispatcher's reading, posted to the owner for correction) |
| C8 | "We should strive to build a simple UI which will answer my questions and not actually give too much information to the agents (because the aim is to have the available data and create the analysis after the data exists in our database ...)" (fc0119cd, msg 9a9e0802) | the fetched data is stored in the hub DB first; a simple WUI screen for HUM-10 answers the questions by code; agents never receive figures, so option C (MCP for agents) is out (section 6) |
| C9 | "Also, I would like to enable the usage of the QTRO docs as a balance sheet statement because of its hierarchical structure capabilities." (fc0119cd, msg adc2981c; QTRO = the Qto workspace docs, specs 113/114/120) | option D: balance sheet and P&L generated by code as a hierarchical Qto document on each fetch, after a per-person, no-agent doc lock is built (section 6.1) |

### 8.2 Open (before a spec)

1. **Which reports first?** The end-of-month cash forecast alone (section 4),
   or also the card-cost breakdown (section 5), open receivables/payables
   lists, the monthly P&L and balance sheet?
2. **Read-only, or also write?** Read-only needs no write access rights and no
   transaction fees. Writing (e.g. sending sales invoices from the workspace)
   adds fees and risk.
3. *(dropped: answered by C7 and C8: HUM-10 only, agents never see
   figures; the figures live on one screen.)*
4. **Who obtains the keys?** Partner registration and the test environment
   (section 1.2 steps 2 to 4) need a contact person; the CustomerId/CustomerKey
   need a Netvisor admin, ideally under a dedicated integration user so they do
   not expire with a person's account. Whoever obtains them puts them into the
   the main box file directly (C6), never through a chat post.
5. **Which Netvisor package does the company run?** Professional or Premium:
   no extra fee. Core or lower: the API needs an upgrade (section 2.1).
6. **Which bookkeeping accounts** hold the bank balance, VAT payable and the
   tax-account liabilities? Your accountant knows. These go into the the main box
   file with the keys, never into a topic (section 4.2).
7. **How fresh?** Nightly is the vendor's advice; is a "refresh now" button
   enough, or do you need intraday? The balance itself only moves when a
   statement is processed (section 4.1).
8. **Are bills paid on their due date?** Netvisor exposes no scheduled
   payment date, so the forecast assumes the due date.
9. **Debit card on the one account, or a separate credit card?** (being asked
   by the dispatcher) It decides whether card costs carry a vendor record
   (section 5.2).

## 9. Sources (all read 2026-10-10)

| key | page | URL |
|---|---|---|
| S1 | How Netvisor API works | https://support.netvisor.fi/en/articles/766845-how-netvisor-api-works |
| S2 | API authentication | https://support.netvisor.fi/en/articles/766842-api-authentication |
| S3 | Implementing new integration and Netvisor software partnership | https://support.netvisor.fi/en/articles/766840-implementing-new-integration-and-netvisor-software-partnership |
| S4 | How Netvisor API works (packages line) | https://support.netvisor.fi/en/articles/766845-how-netvisor-api-works |
| S5 | API pricing | https://support.netvisor.fi/en/articles/766838-api-pricing |
| S6 | Resources general | https://support.netvisor.fi/en/articles/766841-resources-general |
| S7 | Checklist for new integration: how to enable the integration | https://support.netvisor.fi/en/articles/766833-checklist-for-new-integration-how-to-enable-the-integration |
| S9 | salesinvoicelist.nv | https://support.netvisor.fi/en/support/solutions/articles/77000554148-get-sales-invoice-or-order-list-salesinvoicelist-nv |
| S10 | purchaseinvoicelist.nv | https://support.netvisor.fi/en/support/solutions/articles/77000554199 |
| S10b | Purchase invoices, orders, payments and vendors in general | https://support.netvisor.fi/en/articles/766853-purchase-invoices-orders-payments-and-vendors-in-general |
| S11 | getpurchaseinvoice.nv | https://support.netvisor.fi/en/articles/769735-get-purchaseinvoice-getpurchaseinvoice-nv |
| S12 | getpayrollpaycheckbatchlist.nv | https://support.netvisor.fi/en/support/solutions/articles/77000554269-get-payroll-paycheckbatchlist-getpayrollpaycheckbatchlist-nv |
| S13 | getpayrollpaycheckbatch.nv | https://support.netvisor.fi/en/articles/769785-get-payroll-paycheckbatch-getpayrollpaycheckbatch-nv |
| S14 | accountbalance.nv | https://support.netvisor.fi/en/articles/766898-get-account-balances-accountbalance-nv |
| S15 | accountingledger.nv | https://support.netvisor.fi/en/articles/766887-get-accounting-data-accountingledger-nv |
| S16 | Cash flow forecast | https://support.netvisor.fi/en/articles/766503-cash-flow-forecast |
| S17 | Retrieving bank statements | https://support.netvisor.fi/en/articles/766558-retrieving-bank-statements |
| S18 | VAT declaration / self-initiated taxes | https://support.netvisor.fi/en/articles/766571-vat-declaration |
| S19 | Unified API connector listing for Netvisor | https://www.apideck.com/integrations/visma-netvisor |
| S20 | The same vendor's pricing | https://www.apideck.com/pricing |
| S21 | Integrations FAQ | https://support.netvisor.fi/en/articles/766834-integrations-faq |
| S22 | Netvisor Pricing 2026 (PDF, in force 1.10.2026) | https://netvisor.fi/netvisor-pricelist.pdf |
| S23 | getsalesinvoice.nv | https://support.netvisor.fi/en/articles/769731-get-sales-invoice-details-getsalesinvoice-nv-getorder-nv |
| S24 | Sales invoices, orders and payments in general | https://support.netvisor.fi/en/articles/766852-sales-invoices-orders-and-payments-in-general |
| S25 | dimensionlist.nv | https://support.netvisor.fi/en/articles/766895-get-dimension-list-dimensionlist-nv |
| S26 | getaccountdimensionlist.nv | https://support.netvisor.fi/en/articles/766902-get-accounting-dimensions-getaccountdimensionlist-nv |
| S27 | Payment cards and payment card fee processing | https://support.netvisor.fi/en/articles/766561-payment-cards-and-payment-card-fee-processing |
| S28 | Using posting rules (search snippet) | https://support.netvisor.fi/en/support/solutions/articles/77000466651-using-posting-rules |
| S29 | paymentlist.nv | https://support.netvisor.fi/en/support/solutions/articles/77000554233-get-purchase-payment-list-paymentlist-nv |
| S30 | unprocessedoutgoingpayments.nv (search snippet) | https://support.netvisor.fi/en/articles/769745-get-unprocessed-outgoing-payments-unprocessedoutgoingpayments-nv |
| S31 | tripexpense.nv (search snippet) | https://support.netvisor.fi/en/support/solutions/articles/77000554279 |

Read from a search snippet only, not first-hand: S18's VAT page body, S21,
S28, S30, S31. Re-read them before the spec relies on their exact wording.
S8 is not used.
