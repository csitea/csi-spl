# 126 - Cash forecast from the company bank: research

Status: research only (no code, no sign-up, no contact with the bank).
Owner topic: fc0119cd (owner msgs 9d265b38, dc5d1be3, 8f52f9a6). Sibling:
spec 125 (accounting system, open invoices). Together they feed one view:
"cash today, and how much at the end of the month".

## 0. Naming and sources

The repository's distribution-hygiene gate bans the bank's name and its
domains in every tracked file. So this page writes:

| placeholder | means |
|---|---|
| `<BANK>` | the company's bank, as named by the owner in topic fc0119cd |
| `<BANK-OB-HELP>` | the bank's open-banking support centre host (a help-centre site) |
| `<BANK-OB-DOC>` | the bank's open-banking API documentation host |
| `<BANK-COM>` | the bank group's international site |
| `<BANK-FI>` | the bank's Finnish site |

The real hosts are in the lane's report on dispatch-fc0119cd (spool, not
git). Every path below is the real path on that host. All pages were read
on **2026-10-10**; "upd." is the page's own last-updated date where it has one.

## 1. Access options

A Finnish company reading its OWN balances and transactions has four routes.

### 1.1 Premium API "Instant Reporting" (the bank's corporate API)

- "Instant reporting makes it possible for you as a corporate customer to
  retrieve real-time account information data from your own accounts ...
  updated available balances can be retrieved at any time"
  (`<BANK-OB-HELP>/hc/en-us/articles/360002203179`, upd. 2023-11-02).
- Prerequisite: "We require a signed Corporate Netbank agreement from you.
  Contact your cash management advisor" (same page).
- **Not for the bank's SME netbank**: "Does Instant Reporting API support my
  accounts from [the bank's] Business? Not yet, our Premium APIs for
  [the bank's] Business customers are still under investigation" (same page).
  Which netbank the company uses decides whether this route exists at all.
- Agreements and certificates (`<BANK-OB-HELP>/hc/en-us/articles/21416905431068`,
  upd. 2026-06-22): Instant Reporting runs under a "Corporate Cash Management
  Agreement / Corporate Netbank Service" with a self-signed certificate or a
  Corporate Access SignerID certificate; "Trusted PKI x509 Signing
  Certificates issued by others than [the bank], will not be approved".
- REST + JSON only, no XML (`.../360002203179`).
- History: up to 24 months, at most 7 days per request in API v4.0
  (`<BANK-OB-HELP>/hc/en-us/articles/7767693814044`, upd. 2026-07-03).

### 1.2 PSD2 account information (AIS)

- **Direct, as our own TPP: not realistic.** The Business Accounts API is for
  "PSD2-regulated TPPs with the 'AISP' role", production needs an "eIDAS
  QSealC" certificate (`<BANK-OB-DOC>/compliance/business/overview`). That
  means registering with the Finnish FSA as an account information service
  provider, holding professional indemnity insurance (PSD2 art. 5(3)-(4);
  EBA guidelines EBA/GL/2017/08,
  https://www.eba.europa.eu/sites/default/files/documents/10180/1901998/6411f24d-e430-4e05-ab03-1393a3f865cb/Final%20Guidelines%20on%20PII%20under%20PSD2%20%28EBA-GL-2017-08%29.pdf)
  and buying a qualified eIDAS certificate. A licence to read one company's
  own account is out of proportion.
- **Via a licensed aggregator: realistic.** The aggregator is the TPP; the
  company consents once per 180 days (section 3.4). Examples, all
  quote-based (section 2.2): Enable Banking (Finnish, licensed AISP; it has
  a "restricted" production mode where "only linked accounts would be
  accessible through the application", https://enablebanking.com/docs/faq/),
  Tink. GoCardless Bank Account Data (ex-Nordigen, once free) is closed to
  new sign-ups (bankaccountdata.gocardless.com/new-signups-disabled, as
  reported by https://dev.to/johnfrandsen/gocardless-bank-account-data-alternatives-what-to-use-when-signups-are-disabled-326d;
  not verified first hand).
- For a Corporate Netbank customer, PSD2 access through a provider needs a
  Corporate Cash Management Agreement and a netbank administrator who grants
  access with the bank's ID app (`<BANK-OB-HELP>/hc/en-us/articles/360020095599`,
  upd. 2026-01-07). For SME customers "consent can be provided to a TPP for
  PSD2 scope without any additional agreement" (bank developer docs, as
  summarised by search; not read first hand).

### 1.3 File-based statements (camt.053 over a bank connection)

- "Corporate Access ... Our global file-based bank-to-customer account
  reporting service": camt.053e (statement extended), camt.054c (credit
  notification), camt.053s (statement standard); channels AS2, SFTP,
  SWIFTNet, "Corporate Access Web Service", Finland included
  (`<BANK-COM>/en/our-services/corporate-access`).
- Format spec: `<BANK-COM>/en/doc/caar-camt-053-001-02-account-statement-standard-v1.80.pdf`
  (found, not read in full).
- Statements are end-of-day; intraday (camt.052) was not found on the pages read.
- A signed Corporate Access / Web Service agreement and the bank's own
  certificate (Corporate Access SignerID or Web Service LogonID,
  `.../21416905431068`) are needed. Sign-up: "contact Cash Management" (no
  self-service).

### 1.4 Through the accounting system

If the accounting system already pulls the bank statements (the usual
Finnish setup), the booked balance may come from there with no bank
integration at all. Not researched here: see spec 125.

## 2. Costs

### 2.1 The bank

| item | price | source |
|---|---|---|
| Instant Reporting / Premium API | **not public**: "When access to production data is offered, we will start to charge ... Contact your cash management advisor" | `<BANK-OB-HELP>/.../360002203179` |
| Sandbox | free: "Using the APIs in sandbox is free of charge" | same |
| Corporate Access / Web Service agreement | **not public**; not on the corporate tariff page | `<BANK-COM>/en/our-services/corporate-access` |
| Netbank company connection | EUR 7.50 / month | `<BANK-FI>/en/business/tariff-for-corporates.html` |
| File transfer (netbank) | EUR 2.00 / month | same |
| Electronic account statement | EUR 0.99 (unit not stated on the page) | same |
| Electronic transaction statement | EUR 0.30 (unit not stated) | same |
| Electronic balance query | EUR 5.00 per account per month | same |
| PSD2 AIS via a TPP | no bank fee found | not found as a line on the tariff |

The tariff page shows no "valid from" date. How to get the missing prices:
ask the company's cash-management advisor for a written offer covering
Instant Reporting and Corporate Access account reporting.

### 2.2 Aggregators

| provider | price | source |
|---|---|---|
| Enable Banking | **not public**: "volume based ... number of accounts accessed and payments made per month"; production after a contract and KYB | https://enablebanking.com/docs/faq/ |
| Tink | **not public**: "New prospects ... should contact our sales team" | https://tink.com/pricing/ |
| GoCardless Bank Account Data | closed to new sign-ups (secondary source) | section 1.2 |

A third-party blog quotes Tink at EUR 0.50 per user per month
(https://blog.finexer.com/tink-pricing/); not first-hand, do not plan on it.

## 3. Technical means

### 3.1 Balances

The bank's Business/Corporate Accounts APIs return `available_balance`
(includes the credit limit), `booked_balance` ("completed bookings at the
time of query"; "updated at the end of the day"), `value_dated_balance`
("booked balance ... minus all the transactions with a future value_date")
and `opening_balance` (`<BANK-OB-HELP>/hc/en-us/articles/16054771071900`,
upd. 2026-06-15). For "cash today" use `available_balance` minus the credit
limit, or `value_dated_balance`.

### 3.2 Transactions

- Business Accounts (PSD2): up to 18 months, default 2 months, 200 per page.
- Corporate Accounts (PSD2): up to 15 months, to be limited to 7 days per call.
- Instant Reporting: up to 24 months, 7 days per call (v4.0).

(`<BANK-OB-HELP>/.../7767693814044`.) Through a TPP, without fresh SCA,
only the last 90 days (`<BANK-OB-HELP>/hc/en-us/articles/8666971090972`).

### 3.3 Scheduled outgoing payments

Not found in any page read: PSD2 AIS covers accounts, balances and booked
transactions; the bank's Corporate Payout API initiates payments. The
month-end forecast should take outgoing items from the accounting system
(spec 125: purchase invoices due) rather than from the bank.

### 3.4 Auth, consent, refresh

- OAuth access token valid 3600 s, refreshed without the user while the
  consent is valid (`<BANK-OB-HELP>/hc/en-us/articles/115001726024`, upd. 2026-04-14).
- Consent: max 180 days, then a person must re-authenticate
  (`.../8666971090972`, upd. 2026-04-07; Delegated Regulation (EU) 2018/389
  art. 10a as amended by 2022/2360, https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:02018R0389-20230725).
- Refresh: an AISP may poll "no more than four times in a 24-hour period"
  when the user is not actively requesting (same regulation, art. 36(5)).
  Enough for a daily view.
- Premium API: agreement-bound certificate (section 1.1); no 180-day consent
  found in the pages read.
- Sandbox: Instant Reporting sandbox with API keys and Postman collections
  (`.../360002203179`); PSD2 sandbox with a demo certificate
  (`<BANK-OB-DOC>/compliance/business/overview`).

## 4. Fit for Spool Hub

The view: per account, cash today (bank) + incoming open invoices due by
month end - outgoing invoices due by month end (spec 125) = forecast.

| | A. Aggregator AIS | B. Bank Premium API | C. Accounting system only |
|---|---|---|---|
| How | hub job calls the aggregator daily, stores balance + 90 d transactions | hub job calls Instant Reporting with the agreement certificate | balance from the bank statements the accounting system already imports (spec 125) |
| Secrets | aggregator API key on the main box only (owner msg 072a9990), never Secret Manager | certificate private key + client id/secret on the main box only (owner msg 072a9990), never Secret Manager | only the spec 125 credentials, on the main box only |
| Human step | a person renews consent every 180 days (link from the view, reminder 14 days before) | sign the Corporate Netbank agreement once; rotate the certificate before expiry | none extra |
| Freshness | up to 4 polls/day, available balance | real time | as fresh as the statement import (typically D-1) |
| Blocker | aggregator contract + KYB, price unknown | needs Corporate Netbank (not the SME netbank); price unknown | depends on spec 125 findings |
| Effort | M | M | S |
| Risk | consent lapses silently; a third party sees the data | agreement + certificate lifecycle; API changes | balance a day late |

**Recommendation:** start with C (cheapest, may need no bank work at all),
add A only if a same-day balance matters; B only if the company is already
on Corporate Netbank.

Rules for any option: no key, certificate, token, account number or IBAN in
git, terraform state or a log; secrets only in a 0600 file on the main box,
read by a main-box action, not on the satellite and not in Secret Manager
(owner msg 072a9990; spec 125 section 6); the hub stores amounts and dates,
never more counterparty detail than the view shows; access for HUM-10 only,
checked by HUM-10's id, never by UI hiding (owner msg 42924894).

## 5. Owner questions

1. Which accounts belong in the forecast (all company accounts, or named ones), and in which currencies?
2. Who in the workspace may see the balances: only you, or named members? *Answered by owner msg 42924894: HUM-10 only, no other member or role (spec 125 section 8.1, C7).*
3. Does the company use the bank's Corporate Netbank or its SME netbank (Business)? Option B needs Corporate Netbank.
4. Who signs a bank or aggregator agreement for the company, and do you accept a third-party aggregator seeing the account data?
5. Is a balance as of yesterday (option C) enough, or do you need today's available balance?
6. Shall we ask the cash-management advisor for a written price offer for Instant Reporting and Corporate Access reporting?
