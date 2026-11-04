# How to read cost mails: cloud, SaaS and infra bills from a mailbox

For an agent asked to find the operator's cloud, SaaS and infra costs in a
mailbox and register them as cost entries
([spec 143, expenses](../../specs/143-reporting-section/expenses-cost-entries.md)).
First done for one year of mails in SPL-4802 and SPL-4825 (epic SPL-2400).
This page holds the method only: no figure, invoice number, account id,
mailbox address or name ever goes into git.

## 1. Rules before the first call

1. **Read only.** The mailbox is reached through the claude.ai Gmail
   connector. Never send, reply, forward, label, move, trash, draft or mark a
   mail.
2. **Finance data is a secret-class lane**: claude only, on the box the brief
   names. Work files live in one private work dir outside git
   (`/var/spool-hub/dispatch/work/<slug>/`, dirs 0700, files 0600), never in
   `/tmp`, a log line, a chat or a public channel.
3. **Never write to the accounting system, a bank or a supplier**, and use no
   key of theirs.
4. **Register costs only through the hub's named action**: DRY_RUN first, the
   dispatcher's go, then a read-back. Never a direct DB write.

## 2. Find the mails

### 2.1 Start wide, then subtract

One wide query per year, then exclude each sender once you have classified
it, until what is left is noise:

```
after:<YYYY>/01/01 (invoice OR receipt OR lasku OR kuitti OR billing OR "payment received" OR renewal OR subscription)
```

- Run it with and without `has:attachment`: a bill whose amount sits only in
  a PDF often has no amount words in its text.
- Subtract with `-subject:(<word> OR <word>)` rather than `-from:`: a mail
  forwarded from another address carries the forwarder as its sender.
- Add a sender sweep for the usual suppliers (cloud, registrars, hosting, AI
  vendors, chat and dev tools):
  `(from:<domain> OR from:<domain> ...) (receipt OR invoice OR billing OR charged OR renewed)`.
- Page with `pageToken` until the end; `resultCountEstimate` is an estimate.
- A search returns at most 50 threads and does not always hand back a
  `pageToken`: when a day holds more (a bulk forward), split the query into
  `after:` / `before:` windows until each returns fewer than 50.

### 2.2 Copies and forwards

The same bill often sits in the mailbox three times: the supplier's
original, a forward from a second personal address, and a forward from the
owner to the accounting system's scan address.

- **Dedupe by the receipt or invoice number**, never by the mail id.
- Prefer the original; fall back to a forward when it is the only copy.
- **The mail date is not the charge date.** Receipts forwarded in bulk months
  later carry the forward's date; read the date inside the body. Search from
  a month before the year starts, then filter on the charge date.

### 2.3 What is in scope and what is not

| keep | drop |
|---|---|
| cloud and infra bills (compute, storage, billing statements of a cloud account) | budget alerts and "past due" notices: they are events, not bills |
| domains, DNS, hosting | travel, hotels, taxis, parking, EV charging |
| SaaS subscriptions (workspace suite, chat, code hosting, AI plans) | hardware shops, consultancy self-billing, the company's own shop mails |
| AI API credits and usage | app-store purchases that are not a service subscription |

Mark a borderline service (a digital-mail service, a social network premium
plan) `borderline` in the note and let the dispatcher decide.

## 3. Read the amount

### 3.1 Text first

`get_message` with `messageFormat: PLAIN_TEXT`. Card-processor receipts
(the "Receipt from X, amount, Paid <date>" shape) carry the total, the line
items and the service period in the text.

### 3.2 The PDF when the text has no amount

Suite and cloud invoices say only "your invoice is available"; the amount is
in the attached PDF. `PLAIN_TEXT` lists the attachment id but not its
content.

1. `get_message` with `messageFormat: RAW` returns the whole MIME message,
   base64url, the PDF inside. The result is too big for the context: the
   harness saves it to a file and prints the path.
2. Move that file into the work dir and decode it: base64url-decode `raw`,
   parse it with Python's `email` module, walk the parts, write each PDF part
   to disk (0600) and run `pdftotext -layout` on it. Keep the decoder in a dir
   of its own and run it with `python3 -I`, never from the dir that holds the
   mail data.
3. Read the text with `grep`; never paste a whole invoice into a chat.

### 3.3 Where the amount sits

| bill shape | net / VAT / total | period |
|---|---|---|
| card-processor receipt (most SaaS and AI plans) | text: "Total", "Amount paid"; the PDF repeats it with the tax column | the line item's date range |
| workspace suite invoice | PDF page 1 summary; page 2 repeats it (check they agree) | "Summary for <from> - <to>": one calendar month, dated its last day |
| cloud provider invoice and billing statement | PDF: subtotal, VAT, total in the invoice currency | the billing month; a statement may repeat an invoice, count it once |
| registrar invoice | PDF or e-invoice text | the registration term, often a year |

- An EU business buyer is often billed VAT 0 % on reverse charge: net =
  total.
- Keep the original currency; convert only where the registering step asks.
- Localised invoices (Finnish `Välisumma`, `Alv`, `Yhteissumma`) need their
  own patterns next to the English ones.

## 4. The work table

One row per unique bill, tab-separated, in the work dir:

```
supplier	category	msg_id	receipt_no	charge_date	period_from	period_to	period	net	vat_pct	vat	total	currency	source	note
```

`period` is the `YYYY-MM` of `period_from`, else of the charge date. The
report is built from it: supplier x month (found / missing), totals per
supplier and per month, the queries with their counts, the dropped senders
with the reason, and what could not be read.

## 5. Registering

A cost entry is `type`, `label` (the supplier), `amount`, `currency`,
`period` (`YYYY-MM`) and an optional `note`
(`POST /v1/operator/cost-entries`). Propose the rows to the dispatcher, run
the action with DRY_RUN=1, write only after its go, then read the entries
back and compare the count and the sum per month with the work table. AI
vendor plans may already sit in the paid AI items of the Expenses AI tab
(rdb 0205): check there first, so no cost is counted twice.

## 6. Pitfalls met so far

- A bulk forward of a year of receipts made every one of them look like the
  forward's month.
- A "payment failure" mail is not a missing invoice: the invoice exists, its
  payment is another question.
- A month's suite invoice arrives on its last day: the current month is
  missing by design, not by error.
- A plan change mid-month shows as an odd amount between the old and the new
  price.
- Parallel helper agents of one session share the harness's tool-results
  dir: each must move only the saved files it fetched, by exact name, or one
  agent sweeps up another's mails.
- A card-processor receipt can show a plan price less an applied balance;
  book the amount actually paid and say so in the note.

<!-- version: 0.1.0 · updated: 2026-11-04 -->
