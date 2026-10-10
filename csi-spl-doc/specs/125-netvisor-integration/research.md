# Research: a Netvisor API link for the csitea workspace

Feature: `125-netvisor-integration` · Date: 2026-10-10 · Status: research only
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
| Recommendation | Option B (section 6): a read-only action on the main box (`<DEV_BOX>`), keys in a 0600 file there only (owner msg 072a9990), one run per night plus one on demand, results delivered to HUM-10 only (owner msg 42924894). Effort M. |

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

No new GCP cost: under the owner's key rule the run happens on the main box
(section 6), a nightly poll of a few XML lists, and the hub only carries one
DM. Not measured; the spec measures it.

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
under the owner's rules (section 8.1). It lives next to the keys, in the
0600 file on the main box (C6), never in git, cnf, specs, the hub DB, logs or
chat. The owner's offer to send "the account ID" (msg aa3a837e) is therefore
not needed for route C. If it is sent anyway, it goes into that file, not
into a topic.

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
  HUM-10's id, or the Netvisor costs stay in the main-box report. 123's
  owner decides; spec 125 must not widen access.

## 6. Fit for Spool Hub: architecture options

Rules for every option, from the owner (section 8.1):

- **Keys on the main box only** (C6, msg 072a9990: "Keys and secrets should stay only
  on the [main] box, not on [the satellite]."): the four Netvisor values live in one 0600
  file under the harness user's `$HOME` on the main box, read only by a
  main-box action. Not on the satellite, **not in GCP Secret Manager** (any
  box holding the project SA could read it), not in git, cnf, terraform
  state, logs, spool posts or CI output. Every lane that handles them is
  placed on the main box.
- **HUM-10 only** (C7, msg 42924894): the keys and ALL finance data and
  reports are for HUM-10 alone: no other csitea member, no admin role, no
  other workspace, no agent outside the one action. Delivery goes only to
  HUM-10 (a DM, or a members-only channel whose only human member is
  HUM-10). The check is enforced by HUM-10's id in the action and at the
  hub, never by hiding UI.

| | **A. Hub connector** | **B. Main-box action** (recommended) | **C. MCP tool** |
|---|---|---|---|
| What | the hub (Cloud Run) signs and sends the calls | `./run -a do_spl_netvisor_report` on the main box: reads Netvisor, computes the forecast and card-cost breakdown, posts the result as a DM to HUM-10 only | an MCP tool agents call for the figures |
| Keys live | would need Secret Manager or the hub's environment | the 0600 file on the main box (C6) | the same file, if it called Netvisor |
| Allowed by C6/C7? | **no**: the keys would leave the main box | **yes** | **no** as an open tool: any agent could read the figures (C7). Only a tool whose every call checks the requester is HUM-10 could be considered later |
| Effort | n/a | **M**: signer + XML client + ~10 read resources + the sum + one DM post; no WUI panel, no hub table | n/a now |
| Risk | n/a | the main box down or asleep = no report that night (the next run catches up); the file sits on a box shared with agents, so the action reads it as a fixed user and no lane brief names its path | n/a |
| Stays out of git/logs | n/a | keys and the account number (file only), raw XML (never logged; only counts and status), amounts (only in the DM to HUM-10, never in a log or topic) | n/a |
| Polling | n/a | one call at a time per company [S6]; nightly cron on the main box + on demand by HUM-10 | n/a |

Why B: it is the only option the owner's two rules allow. The hub carries
only the delivered DM, which its existing per-member DM access already
restricts to HUM-10; the new code adds a check that refuses any recipient
other than HUM-10's id, with a test whose control posts to another member
and must fail.

Per-env note: the dev run talks to the Netvisor **training environment**,
the prd run to production, each with its own key file on the main box. That keeps
test traffic out of the real books.

## 7. Later scope: balance sheet, cost items

| want | Netvisor source | source |
|---|---|---|
| Balance sheet / P&L by month | `accountbalance.nv`, all accounts, `intervaltype=3` (month), grouped by the chart of accounts | [S14] |
| Cost items per account | `accountingledger.nv` lines (`AccountNumber`, `LineSum`, VAT code) by date range; incremental with `changedsince` | [S15] |
| Cost items per cost centre | the dimensions on each ledger line; `dimensionlist.nv` for names | [S15][S25] |
| Supplier costs | `purchaseinvoicelist.nv` / `getpurchaseinvoice.nv` | [S10][S11] |

The spec 123 link is the same as in section 5.3.

## 8. Owner constraints and questions

### 8.1 Answered (constraints for the spec)

| # | owner's words | rule for spec 125 |
|---|---|---|
| C1 | "C" (fc0119cd, msg 70b69575) | the cash balance comes from Netvisor's imported bank data (section 4); no bank API |
| C2 | "Anything related to the finances of [Csitea] should be private to this workspace." (fc0119cd, msg 873f6f84) | all Netvisor data (balances, invoices, payroll, card costs) stays inside the csitea workspace, never another workspace or its agents; no figures, account numbers, ids or keys in git, specs, logs, CI output or other repos. Tightened by C7. |
| C3 | "The company has only one account." (fc0119cd, msg aa3a837e) | one bank bookkeeping account in the forecast; no bank account number needed (section 4.2) |
| C4 | "Almost everything is paid via" Netvisor (fc0119cd, msg c45c7cb0) | outgoing payments = Netvisor purchase invoices (section 4.4) |
| C5 | card payments and "the cost of their structures" (fc0119cd, msg 2a339876) | use case 2 (section 5) |
| C6 | "Keys and secrets should stay only on the [main] box, not on [the satellite]." (fc0119cd, msg 072a9990) | the Netvisor keys live only in a 0600 file on the main box, read by a main-box action; not on the satellite and not in GCP Secret Manager (dispatcher's reading, open to the owner's correction); option B (section 6) |
| C7 | no access to the keys or the information for "any other member other than me" (fc0119cd, msg 42924894) | keys and all finance data and reports for HUM-10 only: no other csitea member, no admin role, no other workspace; delivery only to HUM-10; enforced by HUM-10's id in the action and the hub, never by UI hiding (dispatcher's reading, posted to the owner for correction) |

### 8.2 Open (before a spec)

1. **Which reports first?** The end-of-month cash forecast alone (section 4),
   or also the card-cost breakdown (section 5), open receivables/payables
   lists, the monthly P&L and balance sheet?
2. **Read-only, or also write?** Read-only needs no write access rights and no
   transaction fees. Writing (e.g. sending sales invoices from the workspace)
   adds fees and risk.
3. *(answered by C7: HUM-10 only.)* **Delivery form**: a DM to you, or a
   members-only channel with you as its only human member?
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
