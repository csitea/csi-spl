# Spec 181: buy a private workspace and a private VM, pick the agents

**Feature ID**: `181-buy-private-workspace-vm` · **Status**: Decided v0.7
(Q-1..Q-20 answered; Q-21, standard VM machine type + monthly list price cnf source and spec 122 RQ-3, open; section 1.0; v0.6.1: row B2 implemented) · **Epic**: SPL-2398 · **Issue**: SPL-5997 ·
**Created**: 2026-11-19 · **Lead**: c-625 · **Placement slug**:
`c002-spec-buy-private-workspace-vm` · **Class**: feature
**Discussion**: t1 topic `b12055b5-d4dd-45b7-9682-74402d7c5164`
**Authority**: this file for the purchase of a private workspace with its own
VM, and for the price rule that replaces spec 121 R6. Status vocabulary:
[README.md](../README.md) §2.3. Docs only: this spec builds nothing.

Next-free check: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | sort | tail -3`
at `17f0d7b00` -> `179-...`, `180-outlook-calendar-import`, `README.md`:
`181` is free.

Builds on, and does not repeat:

- [108 workspace-owned boxes](../108-workspace-owned-boxes/spec.md): a box
  enrolled into one workspace (`dedicated`, 3.8), its OS user (3.5), the
  workspace switch `box_join_enabled`, revoke (3.7).
- [127 workspace vendor keys](../127-workspace-vendor-keys/spec.md) v1.4:
  storage, the write-only API, the lease to a box, the leak table, the
  `byok` plan (7).
- [159 BYO AI keys](../159-byo-ai-keys/spec.md) v0.2: who may add a key (3),
  vendor terms per kind (4.1, 4.2), the claude self sign-in (4.3), a key
  that runs out (9).
- [byo-gcp](../../doc/md/SPEC-spool-byo-gcp.md) (marked "later"): the
  customer pays Google, we provision in their project.
- [121 sales channel](../121-sales-channel/spec.md): R6 (the price) is
  **replaced** by this spec (0.2); from v0.4 R7 (card top-up, stop at
  zero) no longer applies to a private workspace either: it is invoiced
  monthly in arrears [Q-9 B, Q-16 B] (section 2).
- Also used, not changed: [009 M4 seats](../009-spool-m4/spec.md) (seat
  line items), [122 capacity scale-out](../122-capacity-scale-out/spec.md)
  section 4 (provisioning a box), [123 cost tracking](../123-cost-tracking/spec.md)
  (the billing export), [156 marketplace listing](../156-gcp-marketplace-listing/spec.md)
  (a customer-run VM package).

`<W>`, `<tenant>`, `<kind>` and `<vm>` are placeholders.

## 0. The owner's words

Owner HUM-10, t1 topic `b12055b5`, verbatim:

- 2026-11-18 12:43Z (msg `b3633d8d`): "the Users of the spool -hub should be
  able to use their own ai subscriptions for the agents ..."
- 12:44Z (msg `1b5dd12b`): "it should be possible for the users to buy their
  own fully private workspace , their own fully private vm and use different
  ai agents for it"
- 12:45Z (msg `4f17f3da`): "so that they will provide their own ai
  subscriptions for the command line agents , and we will just sell the
  service for using our software haness on the price of the cloud costs +
  33% ... and nothing else"
- 12:46Z, form `b97a036d`, answer A (msg `e6022e82`): "Everywhere: it
  replaces 121 R6 for every workspace"
- 12:49Z (msg `be43a039`): "yes , we do not want to become token reseller"
- 2026-11-19 20:54Z, form `ae56056d`, answer A (msg `daa40019`): "One spec
  lane: a "buy a private workspace + private VM, pick the agents" spec,
  built on 108, 127, 159 and byo-gcp; it starts with your questions as
  forms"

### 0.1 What they add up to

| id | requirement | from |
|---|---|---|
| P1 | a user buys a **private workspace with its own private VM** | `1b5dd12b` |
| P2 | the user **picks the agents** (several vendors) that run on it | `1b5dd12b` |
| P3 | the agents run on **the customer's own AI subscriptions** | `b3633d8d`, `4f17f3da` |
| P4 | we sell only the use of the harness, at **cloud cost + 33%, nothing else** | `4f17f3da` |
| P5 | **no AI tokens are sold**, anywhere | `be43a039` |
| P6 | P4 **replaces 121 R6 for every workspace**, private VM or not | `e6022e82` |

### 0.2 The price, as recorded in the topic

The dispatcher's reading, posted back in the topic (c-003, msg `b95db5a2`),
not corrected by the owner since:

| part | price |
|---|---|
| the VM | its cloud cost (compute + traffic, from the billing export) + 33% |
| the persons | $9 per month per seat |

**Note.** The `$9 per month per seat` line was the dispatcher's recording,
not the owner's own words ("cloud costs + 33% ... and nothing else",
`4f17f3da`). The owner then confirmed it: 9 per month per human member,
agents are not seats (Q-6 A), in EUR (Q-7 A), and the VM line is the VM
only, compute, disk and traffic (Q-8 A).

## 1. Questions for the owner (forms)

Each was posted as a poll; the first option is the recommended one. Q-1
to Q-20 are answered (1.0); Q-21, added in v0.7, is open. From v0.3 sections
2 to 7 are written as the answers say; a **[Q-n]** there names the answer
it comes from.

### 1.0 The owner's answers

Owner HUM-10, t1 topic `b12055b5`, relayed verbatim by the dispatch holder
c-002@sat (msgs `20218211`, `64f641dd`, `94ddb2c5`, `b585876f`, `fc5c25e8`,
`502db57e`, `884a85d8`); Q-17 and Q-18 by the owner's own post in the
topic (msg `43573325`), Q-19 by msg `67b12564`, relayed verbatim by
c-002@sat (msg `7d4f2c6c`), and Q-20 by msg `7b2f5cd3`, relayed verbatim
by the dispatch holder (c-002, msg `5a24d943`). An answered question's
**[Q-n]** marks in sections 2 to 6 now read as that answer.

| q | answer | owner msg | when (UTC) |
|---|---|---|---|
| Q-1 | A: ours, one VM per private workspace in our GCP; we pay Google and bill its cost + 33% | `f05a0825` | 2026-11-19 22:05:17Z |
| Q-2 | A: private VM, shared hub; messages on our hub, isolated per workspace by row-level security | `105ffbb4` | 2026-11-19 22:05:37Z |
| Q-3 | A: we hold root, for upkeep only; no fleet lane and no other workspace runs there; the page says so | `695e7abf` | 2026-11-19 |
| Q-13 | **B** (not the recommended A): checkout first, the private-workspace product in Stripe, then provisioning | `2b118136` | 2026-11-19 |
| Q-5 | none of A, B, C: **both** subscription sign-in and API keys; the sign-in is driven from the web UI only, and we relay the buyer's inputs to the CLI's terminal login on their VM | `fd1af997` | 2026-11-20 |
| Q-10 | A, as a binding rule: no metered fall-back, **we never resell tokens**; customers buy their own tokens, we sell the GCP infrastructure and the spool-hub interface | `504cb94f` | 2026-11-20 |
| Q-4 | A: claude and qwen on the customer's API key; agy after 127's B0c gate; grok and mistral off until the vendors answer (159 4.2, O2, O3) | `9beaf299` | 2026-11-20 |
| Q-6 | A: 9 per month per human member; agents are not seats | `9beaf299` | 2026-11-20 |
| Q-7 | A: EUR, the checkout's currency today | `9beaf299` | 2026-11-20 |
| Q-8 | A: the VM only, compute, disk and traffic, read from the billing export by the VM's label; the shared hub is paid by the seats | `9beaf299` | 2026-11-20 |
| Q-9 | **B** since v0.4 (was A, `9beaf299`): monthly in arrears; no prepaid balance (Q-16 B) | `09472141`, `fb5eebab`, `6768e241` | 2026-11-20 21:39Z.. |
| Q-11 | A: one rate, 33%, for every workspace; it replaces 127's byok 50% | `9beaf299` | 2026-11-20 |
| Q-12 | **C** (not the recommended A): the VM is deleted at once; only the hub data stays 30 days | `9beaf299` | 2026-11-20 |
| Q-14 | A: build the relay now; switch it on per vendor after that vendor's written OK (O1, O2, O3); the relay hands the login inputs straight to the VM and stores them nowhere on the hub; API keys work meanwhile | `375f9b8e` | 2026-11-20 |
| Q-15 | "The customers will be invoiced afterwards." (asked in chat: how are the seats paid?) | `09472141` | 2026-11-20 21:39Z |
| Q-16 | B: "Yes, everything: one monthly invoice in arrears for the seats and the VM cost + 33%; no prepaid balance (Q-9 changes to B)" (form `12d0d6f3`) | `6768e241` | 2026-11-20 |
| Q-17 | **B** (not the recommended A): a reminder only; the agents keep running, and the owner decides each case by hand | `43573325` | 2026-11-21 08:19:18Z |
| Q-18 | **C** (not the recommended A): an order only, and the workspace is created at once on submit; the invoice is paid by bank transfer | `43573325` | 2026-11-21 08:19:18Z |
| Q-19 | A: 14 days net from the invoice date; the reminder goes out on day 15 | `67b12564` | 2026-11-21 |
| Q-20 | A: new operator-scope hub endpoint(s): the orc action sends each private workspace's VM month cost, the hub counts human members and calls `IssueInvoice` (no DB password on the box, same path as the daily cost upload, one write and audit path) | `7b2f5cd3` | 2026-11-23 |
| Q-21 | open: the one standard private-VM machine type (also closing spec 122 RQ-3) and where its monthly list price lives under step `062-gcp-workspace-vms` in cnf (form below) | - | - |

Q-15, Q-16 and the change of Q-9 to B, verbatim (owner HUM-10, t1
`b12055b5`, 2026-11-20): Q-15, msg `09472141` (21:39Z), "The customers will
be invoiced afterwards."; msg `fb5eebab` (21:4xZ), "At the end of each
month, they will be forwarded with the cost from the GCP and then our
invoice."; Q-16, msg `6768e241`, form `12d0d6f3`, "B — Yes, everything: one
monthly invoice in arrears for the seats and the VM cost + 33%; no prepaid
balance (Q-9 changes to B)". The billing ruling they make, used in
sections 2 to 6:

- At the end of each month the customer gets the GCP cost of its VM
  forwarded, then our invoice: 9 EUR per human member + the VM cost + 33%.
- One invoice, in arrears, for the seats and the VM. No prepaid balance, no
  card top-up, no draw-down.
- A non-payment: a reminder only; the agents keep running, and the owner
  decides each case by hand [Q-17 B].
- The checkout takes an order only, the workspace is created at once on
  submit, and the invoice is paid by bank transfer [Q-18 C].

Q-17 and Q-18, verbatim (owner HUM-10, t1 `b12055b5`, msg `43573325`,
2026-11-21 08:19:18Z): "Poll: 22b9764f-c8fe-49ab-9c9d-1b0e30706f94 Answer
1: B — A reminder only; the agents keep running, and you decide each case
by hand Answer 2: C — An order only, and the workspace is created at once
on submit; the invoice is paid by bank transfer". The answer text says
"you" and "the workspace" where the forms below say "the owner" and "the
tenant"; the meaning is the same, and this spec writes "the owner".

The same post's poll `389e73c1`, answer B (msg `82b949e5`, 08:19:34Z):
"Keep it, drop only the token gap": spec 121 section 7's `pricing_not_ready`
gate keeps a closed month of billing data and the capacity measurements,
and drops the token gap, since no token is sold [Q-10 A] (121 v1.6).

The questions as they were asked (v0.4), kept as the record:

- Q-17. A private workspace's monthly invoice is not paid by its due date.
  What happens? (A) A reminder at the due date; 14 days later the agents
  stop and the workspace stays readable until it is paid; the VM is kept
  (Recommended: no work is lost, the cost stops growing). (B) A reminder
  only; the agents keep running, and the owner decides each case by hand.
  (C) 30 days after the due date the workspace is cancelled as Q-12 C (VM
  deleted at once, hub data kept 30 days).
- Q-18 (from the v0.4 review, m-626, W1: with nothing charged up front,
  today's paid webhook, section 3, never fires). Nothing is charged up
  front. What does the private-workspace checkout take, and which event
  creates the tenant? (A) A card on file: the checkout saves the card with
  the payment provider, no charge; the card-saved event creates the tenant
  and the provisioning order; each month-end invoice is charged to that
  card (Recommended). (B) An order only: name, seats and billing details;
  the tenant is created when the owner approves the order; the invoice is
  paid by bank transfer. (C) An order only, and the tenant is created at
  once on submit; the invoice is paid by bank transfer.

Q-19 was new in v0.5: Q-17 B sends a reminder "by its due date", and no
answer set how long after the invoice that date is. The owner answered A
(HUM-10, t1 `b12055b5`, msg `67b12564`, relayed by c-002@sat, msg
`7d4f2c6c`), verbatim: "Poll: c9f3edb6-4408-494e-993f-84ea1fc5968f Answer:
A — 14 days net from the invoice date (Recommended: a common business term;
the reminder goes out on day 15)". So an invoice is due 14 days after its
invoice date, and an unpaid one gets its one reminder on day 15 [Q-19 A].

The question as it was asked (v0.5, posted as form `c9f3edb6`), kept as
the record: Q-19. How long after the monthly invoice is it due (its
payment term)? (A) 14 days net from the invoice date (Recommended). (B) 30
days net. (C) 7 days net.

Q-20 was new in v0.7 (gap G15, row B14). B12 (SPL-6327, landed on
`origin/master` in `86da15a32`: rdb `0315_private_workspace_invoices.sql`,
`internal/store/invoices.go:58`, `internal/hub/invoice_reminder.go`) adds the
store method `IssueInvoice(ctx, tenant, month, humans, vmCostMicros, issuedOn)`
and the day-15 reminder tick, while the VM's cloud cost lives in GCP
BigQuery and is read by B4 (`do_spl_vm_cost_per_day`, `bbdbbe4da`); the
hub Go module has no BigQuery client (`grep -rni bigquery csi-spl-api/` ->
nothing), and no operator route today lists private workspaces with their
human-member counts (`tenant_memberships`, `store.Seats.CountMembers`).
The owner answered A (HUM-10, t1 `b12055b5`, msg
`7b2f5cd3-7407-4f93-98e2-a7141489da60`, relayed verbatim by c-002, msg
`5a24d943`), verbatim: "Poll: 45a715a3-dded-4c9d-9ab0-6bd0d65a7924 Answer:
A — A new admin-only hub endpoint: the box script sends the VM's month
cost, the hub counts the members and writes the invoice (Recommended: no
database password on the box, same path as the daily cost upload, one
place that writes and logs invoices)". In this spec's terms, the
"admin-only hub endpoint" is an `operatorAuth` route under `/v1/operator/`
called with `spl_hub_operator_call` (matching `POST /v1/operator/cost/day`
in `internal/hub/cost_ingest.go:41`), and the "box script" is row B14's orc
action `do_spl_private_ws_invoice_issue` [Q-20 A].

The question as it was asked (v0.7, posted as form `45a715a3`), kept as
the record: Q-20. How does the month-end invoice issuer (row B14) reach
B12's `IssueInvoice` and read each private workspace's human-member count?
(A) New operator-scope hub endpoints (`operatorAuth` Google ID token via
`spl_hub_operator_call`, store helpers in `TestOperatorScopeCallers`): the
orc action reads each VM's month cost with B4 and posts to the hub, which
reads the workspace's human-member count and calls `IssueInvoice`
(Recommended: no Cloud SQL proxy or DB credentials on the box, matches
`POST /v1/operator/cost/day`, keeps one hub write and audit path).
(B) New `spool` CLI subcommand called by the orc action over the Cloud SQL
Auth Proxy (`spl_via_proxy` + `SPOOL_HUB_DB_DSN`, as
`do_spl_token_burn_reprice` / `cmd/spool/fleet_tokens_reprice.go:24`):
reads private workspaces and human-member counts and calls `IssueInvoice`
directly on Postgres.
(C) Move the BigQuery billing-export read into a hub monthly tick beside
B12's reminder tick.

Q-21 is new and open in v0.7 (gap G16, row B15; added on c-001 GO
`63d7a7e9` / c-002 msg `4e4ff199`). c-826 (SPL-6339, msg `4959d0cf`) found
no honest source for section 4.1 step 2's VM monthly cost estimate: step
`062-gcp-workspace-vms` (`csi-spl-cnf/csi-spl/all.env.yaml:302-318`,
`csi-spl-iac/src/terraform/062-gcp-workspace-vms/02-variables.tf:38-49`)
takes `<tenant> -> machine_type` only at runtime via `TF_VAR_workspace_vms`,
neither code nor cnf holds a per-machine-type monthly list price
(`internal/payments/handler.go:431` returns `currency`, `seat_member_cents`,
`vm_margin_pct` only), and spec 122 RQ-3
(`csi-spl-doc/specs/122-capacity-scale-out/spec.md:604-611`: A
`e2-standard-16` / B smaller from M2, Recommended B) is still unanswered.
Q-21 asks both in one form so one owner answer closes spec 122 RQ-3 and
unblocks row B15; there is never a second question on the same standard
machine type:

```poll
Q-21. Which one standard machine type does a private workspace VM use (also closing spec 122 RQ-3), and where does its monthly list price live for the checkout estimate (row B15)?
(A) Pick a smaller standard type from spec 122 M2 (one-workspace measurement) before the first customer VM (closes spec 122 RQ-3 as B), and store both that machine type and its europe-north1 monthly list price in EUR (from the GCP Cloud Billing Catalog, date-stamped) in cnf under steps.062-gcp-workspace-vms in all.env.yaml (Recommended: keeps spec 122 RQ-3's recommendation so first customers are not priced on a 16-vCPU fleet box, and gives checkout one honest cnf source; checkout omits the VM estimate until M2 and cnf land)
(B) Use e2-standard-16 (the satellite's type, prd.env.yaml:230) until M2 runs (closes spec 122 RQ-3 as A), and store e2-standard-16 and its europe-north1 monthly list price in EUR (from the GCP Cloud Billing Catalog, date-stamped) in cnf under steps.062-gcp-workspace-vms now so row B15 can show the estimate immediately
(C) Pick a smaller fixed type now (e2-standard-2, matching dev.env.yaml:210; closes spec 122 RQ-3 without waiting for M2), and store it and its europe-north1 monthly list price in EUR (from the GCP Cloud Billing Catalog, date-stamped) in cnf under steps.062-gcp-workspace-vms now
```

Q-13 is mapped by its answer text, which is form Q-13's option B word for
word; its poll id `35df3e5f` could not be read from c-625's seat.

Q-5 and Q-10 were answered in chat on form `976aad13`. Q-5's web-UI relay
met spec 159 4.3's switch (claude's sign-in off until Anthropic answers in
writing, O1); Q-14 (below, poll `3190dcc9`) keeps that gate per vendor.
Q-10 removes 159 section 9 (the metered fall-back on our API keys) and
confirms 121 R6's replacement (no AI tokens sold). It did not decide Q-11
(127 7.1's 50% is charged on infrastructure; its token term is already 0);
the owner answered Q-11 separately, A. Q-4, Q-6..Q-9, Q-11 and Q-12 are
answers 1, 3..6, 8 and 9 of form `976aad13` (answer n = Q-(n+3)), mapped
by the relay; Q-12 is mapped by its text, form Q-12's option C word for
word.

```poll
Q-14. When does the web-UI sign-in relay go live, given spec 159 kept claude's sign-in off until Anthropic confirms in writing (O1)?
(A) Build the relay now; switch it on per vendor after that vendor's written OK (O1 Anthropic, O2 xAI, O3 Mistral); the relay hands the login inputs straight to the VM and stores them nowhere on the hub; API keys work meanwhile (Recommended: keeps spec 159's gate)
(B) Build it and switch it on now for every vendor with a terminal login, without waiting for written answers
(C) Build it now; switch it on for claude only, once Anthropic answers; the other vendors stay on API keys
```

```poll
Q-1. Whose cloud does the private VM run in?
(A) Ours: one VM per private workspace in our GCP; we pay Google and bill its cost + 33% (Recommended: a buyer needs no Google Cloud account, byo-gcp section 0)
(B) The customer's GCP (byo-gcp): their IT grants our deploy account, Google bills them for the VM; we bill seats only
(C) Both: ours first; the customer's GCP later, for buyers who already run GCP
```

```poll
Q-2. What does "fully private" mean for the hub?
(A) Private VM, shared hub: agents, worktrees and keys only on their VM; messages on our shared hub, isolated per workspace by row-level security (108 3.3) (Recommended: built today)
(B) Private VM and private hub: their own hub and database, nothing on our shared hub (closest package: spec 156's marketplace VM)
(C) As A, and our operator scope reads none of their hub rows (the personal.profile precedent, 127 section 2)
```

```poll
Q-3. Who holds root on the private VM?
(A) We do, for upkeep only; no fleet lane and no other workspace runs there; the page says so (Recommended: 108 3.5)
(B) The customer does; we keep no login on it after the install
```

```poll
Q-4. Which agents can a buyer pick at launch?
(A) Those whose vendor terms allow it today: claude and qwen on the customer's API key; agy after 127's B0c gate; grok and mistral stay off until the vendors answer (159 4.2, O2, O3) (Recommended)
(B) claude only at launch, the others one by one
(C) All five; the customer signs each CLI in on the VM and carries the vendor-terms risk
```

```poll
Q-5. How does a buyer attach an AI subscription?
(A) API keys on Agent keys now (127, built); the claude subscription self sign-in on their VM once Anthropic answers in writing (159 4.3, O1) (Recommended)
(B) API keys only, until each vendor confirms subscriptions in writing
(C) Subscription self sign-in now, without waiting for Anthropic's written answer
```

```poll
Q-6. The seat price ("$9 per month per seat", recorded by the dispatcher, msg b95db5a2)
(A) Yes: 9 per month per human member; agents are not seats (Recommended: "persons", msg b95db5a2)
(B) 9 per month per seat, humans and agents both (009's two seat kinds)
(C) No seat price: VM cost + 33% and nothing else
```

```poll
Q-7. Which currency for the seat price?
(A) EUR, the checkout's currency today (cnf SPOOL_HUB_PAYMENT_CURRENCY "eur") (Recommended)
(B) USD, as written in the topic
```

```poll
Q-8. What does "cloud cost" include for a workspace on a private VM?
(A) The VM only: compute, disk and traffic, read from the billing export by the VM's label; the shared hub is paid by the seats (Recommended)
(B) The VM plus a slice of the shared hub's cost (121 section 7's fixed-cost slice), all + 33%
```

Q-9 as asked in v0.1; answered A, then changed to B by Q-16 (1.0):

```poll
Q-9. How is the VM cost charged?
(A) Prepaid balance by card (121 R7, kept): the VM's daily cost + 33% is drawn down; at zero the agents stop, the workspace stays readable (Recommended)
(B) Monthly in arrears on a card on file
(C) A fixed monthly price per VM size, list price + 33%, set again each quarter
```

```poll
Q-10. Spec 159's metered fall-back sells our API tokens when a customer key runs out. Does it go?
(A) Yes: no fall-back; the task waits until the customer replaces the key (Recommended: msg be43a039)
(B) Keep it, charged at token cost with no margin
```

```poll
Q-11. Does "+33% everywhere" also replace spec 127's byok margin of 50% (127 7.1)?
(A) Yes: one rate, 33%, for every workspace (Recommended: form b97a036d "every workspace")
(B) No: byok keeps 50%
```

```poll
Q-12. When a private workspace is cancelled?
(A) Agents stop at once; the VM is stopped, its disk kept 30 days with an export link, then deleted (Recommended)
(B) Everything deleted at the end of the paid period
(C) The VM is deleted at once; only the hub data stays 30 days
```

```poll
Q-13. What is built first?
(A) Manual slice: an operator provisions one VM per paid order (owner go), enrols it as a dedicated box, the buyer adds keys; checkout comes second (Recommended: uses what is built, section 3)
(B) Checkout first: the private-workspace product in Stripe, then provisioning
(C) Cost first: the per-VM cost from the billing export, then the rest
```

## 2. Where this changes other specs

The edits are row B10 of section 6, made by each spec's editor; this spec
states what they are.

- **121 R6** (price = tokens x 1.20 + own cost + fixed slice, + 29%) is
  replaced for every workspace by 0.2 (form `b97a036d`). 121's `metered`
  plan and its x 1.20 token buffer go: we never resell tokens [Q-10 A].
  **121 R7** (card top-up, stop at zero, no invoice): from v0.4 it does
  not apply to a private workspace. The seats and the VM cost + 33% are
  one monthly invoice in arrears, the GCP cost forwarded first; there is no
  prepaid balance [Q-9 B, Q-16 B]. The invoice is paid by bank transfer
  [Q-18 C]; a non-payment gets a reminder only, the agents keep running,
  and the owner decides each case by hand [Q-17 B].
- **Where v0.4 differs from what is on master.** v0.3's line above said R7
  is kept and carries the VM cost [Q-9 A], and row B10 was briefed and
  landed on that reading (lane `c002-s181-b10-spec-121-127-159-edits`,
  commit `d6fc241f9`, 121 v1.5): 121's R7 row says "Kept by spec 181
  (Q-9 A): the balance carries the VM's daily cost + 33%", and its 4. says
  the balance is drawn down by spec 181's price. Both now differ from this
  spec. This lane edits no other spec; 121's R7, its 4. and its draw-down
  lines need a new B10 edit (row B10, section 6).
- **127 K4 / 7.1** (byok, +50%): the margin becomes 33%, one rate for
  every workspace [Q-11 A]. The rest of 127 7.1's formula stands.
- **159 9** (metered fall-back on our API keys) goes: a key that runs out
  makes the task wait until the customer replaces it [Q-10 A]. 159's L24
  and T5's fall-back part go with it.
- **159 4.3** (the claude self sign-in, off until O1): the sign-in is
  driven from the web UI and relayed to the CLI's terminal login on the
  buyer's VM [Q-5]; the relay is built now and switched on per vendor
  after that vendor's written OK (O1 Anthropic, O2 xAI, O3 Mistral); it
  stores the login inputs nowhere on the hub [Q-14 A]. 159's rule that the
  hub, the WUI and the desk never see the token stands.
- **159 5.1** (keys on our fleet boxes as per-workspace OS users) stays
  for shared workspaces. A private workspace's keys run only on its own VM
  [Q-2 A, Q-3 A].
- **byo-gcp** keeps its "later" status: the private VM runs in our GCP
  [Q-1 A].

## 3. Today, measured

On origin/master `17f0d7b00`, 2026-11-19, n = 1 per command.

| piece | state | command -> result |
|---|---|---|
| checkout and paid webhook make a tenant and its owner (not used by the private workspace from v0.5: Q-18 C, 4.1) | Implemented | `ls csi-spl-api/src/go/spool-hub-api/internal/payments/` -> `handler.go`, `stripe_payments.go`, `m4_test.go`, ...; `ls csi-spl-wui/src/pages/checkout` -> `claim.vue index.vue success.vue` |
| the payment rail on dev and prd | Implemented (cnf) | `grep -n PAYMENT_PROVIDER csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` -> `"stripe"` in both |
| Stripe charges are one-off payment intents; no recurring charge | Partial | `grep -c subscriptions internal/payments/stripe_payments.go` -> 0; line 110 posts `/v1/payment_intents` |
| seat line items (009 M4) | Implemented, not sold | `grep -n SEAT_USER_CENTS csi-spl-cnf/csi-spl/all.env.yaml` -> `"0"`; rdb `0016_m4_seat_line_items.sql` |
| a buy-time GCP project id (009, byo-gcp) | Implemented, off | `SPOOL_HUB_PAYMENT_DEDICATED: "false"` (all.env.yaml); `git grep -l StampBuy` -> `internal/store/seats.go` |
| the workspace switch for its own boxes | Implemented | `box_join_enabled`: rdb `0170_box_join_switch.sql`, `internal/hub/operator_workspaces.go`; action `csi-spl-orc/src/bash/run/spl-box-join-switch.func.sh` |
| enrol a box into one workspace (own OS user, spool root) | Implemented | `csi-spl-orc/src/bash/run/spl-box-workspace-setup.func.sh` (108 3.5) |
| 108's task list | Partial | `grep -cE '^- \[x\]' csi-spl-doc/specs/108-workspace-owned-boxes/tasks.md` -> 5 of 15; T009 (milestone), T011 (relay URLs), T012 (revoke), T013 (leave), T014 (Fleet page) `[ ]` |
| a VM per customer, by terraform | Planned | `git grep -l gcp-vm-pool origin/master` -> nothing (122 4's step `061-gcp-vm-pool` is not built); steps `060-*` and `061-*` each declare one `google_compute_instance` (061: `grep -c 'google_compute_instance"' csi-spl-iac/src/terraform/061-*/03-vm.tf` -> 1; 060: 122 4) |
| a customer-run VM package | Partial | `csi-spl-iac/src/terraform/marketplace-spool-vm/main.tf` (25d84fb0c, SPL-3363): "Customer Marketplace VM. Not an estate step." |
| workspace keys: tables, API, mails | Implemented | rdb `0174`, `0232`, `0234`; `internal/hub/vendor_keys.go`; `internal/vendorkey/vendorkey.go` |
| kinds that take a key | Partial | `grep -n 'VendorKeyAvailable =' internal/hub/vendor_keys.go` -> `{"claude", "qwen"}` |
| the key lease to a box and the seat wrapper | Implemented | `internal/hub/vendor_key_lease.go` (`POST /v1/vendor-keys/{kind}/lease`); `cmd/spool/key_exec.go` (`spool key-exec`, `spool key-helper`) |
| the Agent keys page | Implemented | `csi-spl-wui/src/pages/tenant-settings/agent-keys.vue` |
| the claude self sign-in | Implemented, behind its switch | `csi-spl-orc/src/bash/run/spl-ws-claude-signin.func.sh` (159 T8); test `csi-spl-orc/src/bash/tests/ws-claude-signin.tst.sh` |
| `key_source` on the ledger | Implemented | rdb `0174`, `0175_usage_key_source_no_default.sql`; `internal/store/usage_events.go` |
| a `byok` or private-VM plan kind, `price_plans` | Planned (v0.3.1: B1 builds `price_plans`, kind `private_vm`, rdb 0302) | `git grep -l "'byok'"` and `git grep -l price_plans` (api, orc, iac, rdb, wui, cnf) -> no file, measured before v0.3.1 (B1 adds rdb `0302_private_workspace_price.sql` and `internal/store/price_plans.go`) |
| the pricing gate (`pricing_not_ready`) | Planned | `git grep -l pricing_not_ready` (same trees) -> no file |
| the paid transition that makes the tenant | Implemented, for paid checkouts | `git grep -n 'paidTx(' origin/master -- csi-spl-api` -> `internal/store/payments_postgres.go:156` (call) and `:180` (func), measured on `f8667b9b0` |
| an overdue list or reminder for a hub-issued invoice | Planned | `git grep -liE overdue origin/master -- csi-spl-api csi-spl-wui/src csi-spl-orc/src csi-spl-rdb` on `f8667b9b0` -> 10 files: an accounting import's receivables flag (`internal/store/netvisor.go:87`), the ask queue's re-raise and the topic loop; none reads an invoice the hub issues |
| reading cost from the billing export | Partial | `csi-spl-iac/src/bash/run/gcp-billing-export-setup.func.sh` (DRY_RUN=0 is the owner's), `spl-estate-cost-read.func.sh`; no per-VM-of-a-workspace read |

Paths under `internal/` and `cmd/` are in `csi-spl-api/src/go/spool-hub-api/`.
Not measured: what prd serves, and which switches are on there.

## 4. The flow, end to end

### 4.1 Buy

1. A signed-in person opens "Private workspace" on the checkout. They pick
   the workspace name and the number of seats, one per human member
   (agents are not seats) [Q-6 A]. The VM is one standard size in the
   first slice (as 122 S3).
2. The page shows the price of 0.2: seats x 9 EUR per month [Q-6 A, Q-7 A]
   and the VM's estimated monthly cost (compute, disk, traffic) + 33%
   [Q-8 A], and the agents they can pick (4.3) [Q-4 A]. It shows no token
   price (P5, Q-10 A). The page says we hold root on the VM for upkeep
   only and run nothing else there [Q-3 A].
3. Payment: nothing is charged up front, and the checkout takes an order
   only: the workspace name, the seats and the billing details; no card
   [Q-18 C]. At the end of each month the customer gets the VM's GCP cost
   forwarded, then our invoice: seats x 9 EUR + the VM cost + 33%, in
   arrears [Q-9 B, Q-15, Q-16 B], paid by bank transfer [Q-18 C]. The page
   says so.
4. Submitting the order creates the workspace at once [Q-18 C]: no payment
   provider is called, and today's paid webhook (006, built) plays no part
   for this product. The submit makes the tenant and its owner, sets the
   seat caps (009, built), turns `box_join_enabled` on for it, and writes a
   **provisioning order** (new, gap G3). No GCP cost starts on the submit:
   the VM apply is still the owner's go per order (4.2, section 7).

The checkout is built first, then provisioning [Q-13 B]; section 6 is in
that order.

### 4.2 Provision

- One VM in our GCP per order [Q-1 A]: a terraform step with one entry
  per private VM (122 4 point 2's shape, labelled `workspace=<tenant>` so
  the billing export can price it), applied in the tf-runner. In the first
  slice the apply is the owner's go per order (repo CLAUDE.md); automatic
  only after a later owner decision (122 3.1).
- The hub stays our shared hub, isolated per workspace by row-level
  security (108 3.3) [Q-2 A]; no private hub.
- The VM gets the customer box role set of 122 4 point 4: no estate key, no
  GitHub token, no AI login of ours. We hold root for upkeep only; no fleet
  lane and no other workspace runs there [Q-3 A].
- `do_spl_box_workspace_setup` makes `<W>`'s OS user and spool root; the box
  joins with a join token bound to `<W>` and `<vm>` (073; an operator mint
  path, 122 4 point 5, not built). The pin is `dedicated` (108 3.8).
- The 127 5.3 desk start checks run on the VM; on a VM no fleet lane uses,
  the one exception 159 5.2 made for fleet boxes is not needed.

### 4.3 Pick the agents

- The kinds at launch [Q-4 A]: claude and qwen on the customer's API key;
  agy after 127's B0c gate; grok and mistral off until their vendors answer
  (159 4.2, O2, O3).
- API keys: the biz owner or an admin adds a key per kind on Agent keys
  (built). The hub leases each key only to `<W>`'s dedicated pin on `<vm>`
  (127 H2, built) [Q-5].
- Subscriptions: the buyer signs in from the web UI only; we relay their
  inputs to the CLI's terminal login on `<vm>`, run as `<W>`'s OS user
  [Q-5]. The relay hands the inputs straight to the VM and stores them
  nowhere on the hub; it is on per vendor only after that vendor's written
  OK (O1, O2, O3), and API keys work meanwhile [Q-14 A] (gap G11).
- The workspace's agent split (`internal/hub/agent_split.go`) weights a
  vendor with no key or sign-in at 0 (127 7.3, 127's owner answer Q-1 A).

### 4.4 Use

- Seats on `<vm>` start through `spool key-exec`; messages go through our
  shared hub [Q-2 A]. Every turn writes `usage_events` with `key_source =
  'workspace'`, never charged (127 7.2).
- No fleet lane of ours runs on `<vm>`, and no seat on `<vm>` runs on our
  AI logins (P3, P5). A brief with `Workspace: <W>` for a private workspace
  places only on `<vm>` (159 5.3, with `<vm>` as W's only key host).
- A key that runs out: the task waits until the customer replaces it; there
  is no fall-back on our keys, ever [Q-10 A].
- The VM's cost (compute, disk, traffic) is summed per month [Q-8 A]. At
  month end the customer gets that GCP cost forwarded, then our invoice:
  9 EUR per human member + the VM cost + 33% [Q-9 B, Q-16 B], paid by
  bank transfer [Q-18 C]. Work never stops on a balance, as there is none.
- A non-payment [Q-17 B]: when the invoice is not paid by its due date
  (14 days net from the invoice date [Q-19 A]), the workspace's biz owner
  gets one reminder, on day 15;
  the agents keep running; nothing stops, is cancelled or deleted
  automatically. The invoice goes on the owner's overdue list, and the
  owner decides each case by hand (a cancel is 4.5, on the owner's go).
  The owner marks an invoice paid when the bank transfer arrives.

### 4.5 Cancel

- The agents stop at once: leases end (127 5.2), the pin is revoked
  (108 3.7, T012 not built).
- The VM and its disk are deleted at once [Q-12 C], by a named action; the
  delete is a GCP mutation, so in the first slice it runs on the owner's go
  for that VM.
- The workspace's hub data stays 30 days, then is deleted [Q-12 C].
- Keys: the workspace's keys are removed with the workspace; the vendor
  side is the customer's.

## 5. Gaps

| # | gap | blocks | from |
|---|---|---|---|
| G1 | a terraform step with one VM per private workspace, labelled by workspace | 4.2 | Q-1 A |
| G2 | the customer box role set (no estate keys) and an operator join-token mint path | 4.2 | Q-3 A |
| G3 | a provisioning order written by the order submit that creates the workspace, and a named action that takes it to a plan | 4.1, 4.2 | Q-13 B, Q-18 C |
| G4 | a price plan: seat cents per human member in EUR, VM cost + 33%; the `price_plans` table of 121 is not built | 4.1 | Q-6..Q-9, Q-11 A |
| G5 | the VM's cost per day (compute, disk, traffic) from the billing export, by its label | 4.4 | Q-8 A |
| G6 | the monthly invoice in arrears: the VM's GCP cost of the month forwarded, then our invoice (seats x 9 EUR + VM cost + 33%), paid by bank transfer; an invoice row with its due date; today's rail has one-off payment intents only and is not used (section 3) | 4.1, 4.4 | Q-9 B, Q-16 B, Q-18 C, Q-19 A |
| G12 | the order submit: a private-workspace order creates the tenant at once, with no payment event; today a checkout's tenant is made by the paid transition (`paidTx`, section 3) | 4.1 | Q-18 C |
| G13 | the reminder: one mail to the workspace's biz owner when an invoice passes its due date unpaid; no stop, no cancel | 4.4 | Q-17 B, Q-19 A |
| G14 | the owner's overdue list: every unpaid invoice past its due date, and the owner's hand action to mark one paid on the bank transfer | 4.4 | Q-17 B, Q-18 C |
| G7 | the checkout page for the private workspace, its texts in every locale, agy last | 4.1 | Q-4 A, Q-6 A, Q-7 A |
| G8 | revoke (108 T012), a cancel action that deletes the VM at once, and the 30-day delete of the hub data | 4.5 | Q-12 C |
| G9 | removal of 121's token pricing (`metered`, the x 1.20 buffer) and 159's metered fall-back; 127's byok margin to 33% | 2 | Q-10 A, Q-11 A |
| G11 | the web-UI sign-in relay to the CLI's terminal login on the VM, one switch per vendor, nothing stored on the hub | 4.3 | Q-5, Q-14 A |
| G15 | nobody issues the month's invoice: B12 (SPL-6327, landed on `origin/master` in `86da15a32`: rdb `0315_private_workspace_invoices.sql`, `internal/store/invoices.go:58`, `internal/hub/invoice_reminder.go`) adds the invoice row, store `IssueInvoice(ctx, tenant, month, humans, vmCostMicros, issuedOn)` (one row per workspace per month, replay returns the same row), `MarkInvoicePaid` and the day-15 reminder tick, but no section 6 row calls `IssueInvoice` at month end. The VM's cost is in GCP BigQuery and read by B4's bash action `do_spl_vm_cost_per_day` (`csi-spl-iac/src/bash/run/spl-vm-cost-per-day.func.sh:41`, `bbdbbe4da`), which only reads the trailing `env.cost.reread_days` (`5` days, `csi-spl-cnf/csi-spl/all.env.yaml:1878`, `spl-vm-cost-per-day.func.sh:23,57`), not a full closed month; the hub never reads BigQuery (`grep -rni bigquery csi-spl-api/` -> nothing). Human members live in `tenant_memberships JOIN humans` (`csi-spl-rdb/src/sql/postgres/spool-hub/0006_users_and_memberships.sql:45-53`), counted per tenant in tenant scope by `store.Seats.CountMembers` (`internal/store/seats.go:24`, `internal/store/seats_postgres.go:56-62`: `NOT h.technical AND m.role <> rbac.ChannelGuest`); today `GET /v1/members` (`internal/hub/rbac.go:631`, `internal/hub/members_admin.go:103`) needs a member session of that workspace, `GET /v1/operator/workspaces` (`internal/hub/operator_workspaces.go:167,605`, `internal/store/operator_workspaces.go:122`) returns no member count and no `price_plans` filter, and `do_spl_hub_member_list` (`csi-spl-orc/src/bash/run/spl-hub-member-list.func.sh:25,62-72`) reads one tenant over `psql`. Nothing lists private workspaces (`price_plans.kind = 'private_vm'`, rdb `0302_private_workspace_price.sql:33`, `internal/store/price_plans.go:27`) with their month-end human-member counts and calls `IssueInvoice` | 4.4 | Q-9 B, Q-16 B, Q-19 A, Q-20 A |
| G16 | no honest source for the checkout VM monthly cost estimate (4.1 step 2): c-826 (SPL-6339, msg `4959d0cf`) measured that step `062-gcp-workspace-vms` (`csi-spl-cnf/csi-spl/all.env.yaml:302-318`, `csi-spl-iac/src/terraform/062-gcp-workspace-vms/02-variables.tf:38-49`) reads `<tenant> -> machine_type` only at runtime via `TF_VAR_workspace_vms` with no standard machine type and no per-type monthly list price in code or cnf (`internal/payments/handler.go:431` returns `currency`, `seat_member_cents`, `vm_margin_pct` only), while spec 122 RQ-3 (`csi-spl-doc/specs/122-capacity-scale-out/spec.md:604-611`) is unanswered | 4.1 | Q-8 A, Q-11 A, Q-21 |

G10 (a private hub per workspace) is gone: Q-2 A keeps the shared hub.

## 6. Build order (rows a later lane can take)

Each row is one small lane with its red control. Checkout first, then
provisioning [Q-13 B]. v0.3 renumbered the rows; v0.2's number is in
brackets.

| # | lane | task | red control | waits on |
|---|---|---|---|---|
| B1 [B6] | rdb + hub (claude) | the private-workspace price: seat cents per human member in EUR, VM cost + 33%, invoiced monthly in arrears | a plan with a token line -> refused (P5) | - |
| B2 [B7] | hub (claude) | the order submit [Q-18 C], gap G12: a private-workspace order (name, seats, billing details) creates at once the tenant, its owner, the seat caps, `box_join_enabled` on and the provisioning order, with no payment provider call; the paid webhook path (`internal/payments/handler.go` `stripeWebhook` / `paypalWebhook`, `internal/store/payments_postgres.go` `paidTx`) stays for the paid checkouts and is not reached. Files: `internal/payments/handler.go` (a submit route), `internal/store/payments_postgres.go` (the tenant creation shared with `paidTx`), their tests. Done test: a submit -> one tenant, one order, `box_join_enabled` true, zero provider calls | the submit replayed -> one tenant and one order, not two; a submit that reaches the provider stub -> its test fails | B1 |
| B3 [B8] | wui (claude) | the private-workspace checkout as an order form (no card field) and its price lines; it says the invoice comes monthly in arrears, paid by bank transfer [Q-18 C]; locale texts, agy review last | the page shows a token price, or a card field -> e2e fails | B1, B2 |
| B4 [B5] | iac/orc (claude) | per-VM cost per day (compute, disk, traffic) from the billing export by label (spec 123's reader) | a fixture row with another workspace's label -> not counted | - |
| B5 [B1] | iac (claude) | step for per-workspace VMs: `for_each` over a cnf map `<tenant> -> machine type`, labels `workspace`, `box`; plan only | an entry without a `workspace` label -> the step's check refuses the plan | - |
| B6 [B2] | iac (claude) | customer box role set: no estate key, no AI login of ours; `do_spl_box_workspace_setup` and the 127 5.3 checks run | the role set given an estate key file -> its test fails | - |
| B7 [B3] | hub (claude) | operator-only join-token mint bound to `<tenant>` and `<vm>`, named in `TestOperatorScopeCallers`, audited | a token for `<vm>` redeemed by another box -> refused | B5 |
| B8 [B4] | orc (claude) | a named provisioning action (dry run): order -> cnf entry -> tfvars -> plan printed; apply only with `DRY_RUN=0` and the owner's go | `DRY_RUN` unset -> nothing applied | B2, B5..B7 |
| B9 [B9] | hub + orc (claude) | cancel: leases end, pin revoked (108 T012), the VM deleted at once (owner's go), the hub data deleted after 30 days | a cancelled workspace's seat asks a lease -> 403 | B8 |
| B10 [B10] | doc (agy) | 121, 127 and 159 edited by their editors as section 2 says; from v0.4 also 121 R7 (no prepaid balance for a private workspace, monthly invoice in arrears) | `grep -c 'x 1.20' csi-spl-doc/specs/121-sales-channel/spec.md` -> found only in history lines; `grep -n 'Kept by spec 181' csi-spl-doc/specs/121-sales-channel/spec.md` -> nothing | - |
| B12 (v0.5) | rdb + hub (claude) | the monthly invoice row (gap G6) and the reminder (gap G13) [Q-17 B]: an invoice per private workspace per month (`QuoteMonth`'s sum, issue date, due date = issue date + 14 days [Q-19 A], paid_at NULL), and one reminder mail to the biz owner on day 15 when it is still unpaid; nothing stops. Files: a new rdb migration (number from `do_rdb_migration_next`), `internal/store/` (the invoice store, Memory and Postgres), a mail template under `internal/mail/templates/`, the tick that sends it. Done test: an invoice issued 14 days ago, unpaid -> no reminder; issued 15 days ago, unpaid -> one reminder, and a second tick -> still one | an unpaid invoice past due -> any lease refused or any seat stopped: the test fails; the reminder sent twice -> the test fails | B1 |
| B13 (v0.5) | hub + wui (claude) | the owner's overdue list (gap G14) [Q-17 B, Q-18 C]: an operator-scope read of every invoice past its due date and unpaid, and the operator's action to mark one paid on the bank transfer (audited); no automatic decision. Files: an operator endpoint in `internal/hub/` named in `TestOperatorScopeCallers`, a page under `csi-spl-wui/src/pages/monitoring/`, locale texts, agy review last. Done test: two invoices, one paid -> the list shows one; mark it paid -> the list is empty | a workspace's own member reads the list -> 403; marking paid with no audit row -> the test fails | B12 |
| B11 (new) | hub + wui + orc (claude) | the web-UI sign-in relay to the CLI's terminal login on `<vm>`, one switch per vendor, default off | a relayed input found in a hub table or log -> its test fails; the switch off -> the relay refuses | B8 |
| B14 (v0.7) | orc + hub (claude) | the month-end invoice issuer (gap G15) [Q-9 B, Q-16 B, Q-19 A, Q-20 A]: a named orc action (`do_spl_private_ws_invoice_issue`, dry run by default, `DRY_RUN=0` to write) for a closed UTC month (`MONTH=YYYY-MM`; refuses an open/future month) and every private workspace (`price_plans.kind = 'private_vm'`, rdb `0302`, or one named `WORKSPACE`). Reads the month's VM cost from B4 (`csi-spl-iac/src/bash/run/spl-vm-cost-per-day.func.sh`, `bbdbbe4da`), stepping across the month in `env.cost.reread_days` (5-day) chunks or widening B4 with a full-month window option, summing `total_eur_micros` and refusing if any day is `missing` or `partial` (never 0). Reaches the hub over new `operatorAuth` endpoints under `/v1/operator/` called via `spl_hub_operator_call` (matching `POST /v1/operator/cost/day` in `internal/hub/cost_ingest.go:41`; no DB credentials or Cloud SQL proxy on the box) [Q-20 A]: an operator read lists private workspaces (`price_plans.kind = 'private_vm'`) with each workspace's human-member count from `tenant_memberships JOIN humans` (`rdb 0006`) via `store.Seats.CountMembers` (`internal/store/seats_postgres.go:56-62`: `NOT h.technical AND m.role <> rbac.ChannelGuest`; agents excluded, Q-6 A) so `DRY_RUN=1` prints quotes with zero write calls, and an operator `POST` endpoint receives `(tenant, month, vmCostMicros)`, reads the workspace's human-member count on the hub side via the operator-scope store helper (listed in `TestOperatorScopeCallers`, `internal/store/operator_scope_test.go:188`), and calls B12's `IssueInvoice(ctx, tenant, month, humans, vmCostMicros, issuedOn)` (SPL-6327, landed on `origin/master` in `86da15a32`, `internal/store/invoices.go:58`) in one hub write and log/audit path. Replay of the same month issues nothing new (`IssueInvoice` returns the existing row). Files: `csi-spl-orc/src/bash/run/spl-private-ws-invoice-issue.func.sh`, `csi-spl-orc/src/bash/tests/spl-private-ws-invoice-issue.tst.sh`, `internal/store/` (private-workspace list + operator-scope member-count helper in `TestOperatorScopeCallers`), `internal/hub/operator_invoices.go` + test (`operatorAuth` endpoints); optionally `spl-vm-cost-per-day.func.sh` + test if widening B4's window. Done test: two private workspaces and one non-private workspace for a closed month with stubbed full-month B4 rows: `DRY_RUN=1` prints both quotes and writes zero rows (zero `POST` write calls); `DRY_RUN=0` issues two invoices (zero for the non-private workspace) with the exact summed `vmCostMicros` and `CountMembers` human count; a second `DRY_RUN=0` run for the same month issues zero new rows and returns the same invoices | a month with any `missing` or `partial` B4 day, or an open/future month -> refused, zero invoices written; `DRY_RUN` unset -> zero write calls; a non-operator caller -> 403; a replay creating a second row for the same `(tenant, month)` -> test fails | B4, B12 |
| B15 (v0.7) | cnf + hub + wui (claude) | the checkout VM monthly cost estimate (gap G16) [Q-8 A, Q-11 A, Q-21]: once Q-21 sets the one standard private-VM machine type (also closing spec 122 RQ-3) and its monthly list price with named source under `steps.062-gcp-workspace-vms` in `csi-spl-cnf/csi-spl/all.env.yaml`, expose the cnf-backed VM monthly estimate (+ 33% margin) on the private-workspace pricing endpoint and render it on the checkout page (4.1 step 2; separate from B3 / the CORS + `seat_member_cents`/`vm_margin_pct` row, which ships with no estimate field). Files: `csi-spl-cnf/csi-spl/all.env.yaml` (under `062-gcp-workspace-vms`, with named price source and date) + rendered configs via `do_tpl_gen`, `internal/payments/` (reads estimate from cnf/env, never hardcoded), `csi-spl-wui/src/pages/checkout/` + locale texts + tests. Done test: pricing endpoint returns the cnf-backed VM monthly estimate + 33% for the configured standard machine type and checkout renders it beside the 9 EUR seat line | cnf monthly list price unset or zero -> pricing endpoint omits or refuses the estimate rather than fabricating a number; hardcoded VM price in Go or WUI -> test fails | B3, B5, Q-21 |

Row status (v0.4.1):

- **B12: Implemented** (SPL-6327): rdb
  `0315_private_workspace_invoices.sql`, one invoice per workspace per
  month (primary key), in arrears (issued on or after the month's end) and
  due 14 days after its issue date, both held by CHECKs; no token column.
  Store `internal/store/invoices.go` (Memory and Postgres): `IssueInvoice`
  (the plan's `QuoteMonth` of the month's human members and VM cost; a
  replay returns the first row), `Invoice`, `MarkInvoicePaid` (for B13's
  operator action) and `ClaimInvoiceReminders` (operator scope, in
  `TestOperatorScopeCallers`: every unpaid invoice past its due date with
  no reminder yet, marked once). The hub tick (`internal/hub/invoice_reminder.go`,
  hourly) mails each claimed invoice's biz owners the mail template
  `invoice_reminder` (19 locales, checked with `do_spl_lang_review_gct`);
  a reminder that reached nobody is released for the next tick, and with no
  mail relay nothing is claimed. Nothing else happens: no lease is refused,
  no seat stops [Q-17 B]. Done test: `TestInvoiceReminderDay15Once`
  (`internal/hub/invoice_reminder_test.go`) and `TestInvoiceReminderOnce`
  (`internal/store/invoices_test.go`, both drivers). Red controls: a tick
  that marks the workspace's key exhausted fails the first (the lease after
  the reminder is refused); a claim that does not record `reminded_at`
  fails both (the reminder is sent twice). **Gap, not in B12**: no row
  writes a month's invoice yet; that caller (fed by B4's
  `do_spl_vm_cost_per_day` and the month's member count) is a separate row
  (dispatch holder, 2026-11-23).
- **B1: Implemented** (SPL-6095): rdb
  `0302_private_workspace_price.sql` makes `price_plans` (kind
  `private_vm`, currency `EUR` only) and `price_plan_lines` (exactly
  `seat_member`, cents per human member per month, and `vm_cost`, the
  margin; a token line is refused by its CHECKs); no existing table
  changes. Store `internal/store/price_plans.go`: `PrivateVMPlan` (900
  cents, 33 %), `PutPricePlan` / `PricePlan` (`ErrPlanTokenLine`, P5) and
  `QuoteMonth` (seats x cents + the VM's month cost x 1.33, exact), the
  sum the monthly invoice in arrears charges (Q-9 B). Nothing is drawn
  from a balance. Red control: `TestPricePlanTokenLineRefused`
  (`price_plans_test.go`). Writing the invoice (the month's VM cost from
  the billing export, `QuoteMonth`, an invoice row) is a later row, not B1.
- **B2: Implemented** (SPL-6322): `POST /api/v1/checkout/private-workspace`
  (`internal/payments/handler.go` `submitOrder`) takes a signed-in
  person's order only (4.1 step 1): 401 without a session (the hub's
  `auth.Handler.SessionFromRequest`, wired in `cmd/spool/hub.go`), and the
  biz_owner is the session's email (a body `email` that differs is 400
  `email_mismatch`). The order is the slug, `seats_users` (human members, 1..`SPOOL_HUB_PAYMENT_SEATS_MAX`)
  and `billing` (name, address, 2-letter country, optional VAT id); no card.
  One operator transaction (`SubmitWorkspaceOrder`, Memory and Postgres)
  makes the tenant with the paid transition's own insert
  (`insertTenantTx`, shared with `paidTx`), its biz_owner invite (the buyer
  signs in with that email, 047 W1), the seat caps, `box_join_enabled` on,
  the `private_vm` price plan (B1) and the provisioning order: new rdb
  `0314_workspace_orders.sql`, table `workspace_orders` (one per tenant,
  status `submitted` only; B8 adds its states; no machine type, B5's cnf
  map owns it). No payment provider is called and the paid webhook is not
  reached; nothing is mailed. 201 on the submit; the same order replayed
  answers 200 with the first order (`replayed: true`); another email on
  the slug, or a slug that is already a workspace, is 409 `tenant_taken`.
  Tests: `internal/payments/order_submit_test.go` (zero provider calls,
  red control: a submit that calls the provider stub fails it) and
  `internal/store/payments_order_test.go` (both drivers; red control: the
  replay answered as a second order fails it; a submit with no session,
  or one naming a stranger's email, fails `TestOrderSubmitNeedsSession` /
  `TestOrderSubmitEmailIsTheSessions`).
- **B3: Implemented in the WUI, its submit unproven on dev/prd** (SPL-6338):
  `/checkout/private-workspace` (`csi-spl-wui/src/pages/checkout/private-workspace.vue`)
  is an order form, no card field and no payment step [Q-18 C]: the
  workspace name, the seats (human members) and the billing details (name,
  address, 2-letter country, optional VAT id); it sends no email (B2 takes
  the session's). Its price lines are the seats x 9 EUR per month and the
  VM's Google Cloud cost (compute, disk, traffic) + 33 %, with no amount,
  as no route gives a VM estimate yet; never a token line [Q-10 A]. It says
  nothing is charged now and the invoice comes monthly in arrears, paid by
  bank transfer within 14 days [Q-9 B, Q-19 A], that we hold root for
  upkeep only [Q-3 A], and the agents at launch [Q-4 A]. The 9 EUR and
  33 % are one WUI copy of B1's constants
  (`csi-spl-wui/src/utils/private-workspace-order.mjs`), held to
  `internal/store/price_plans.go` by `tests/unit/private-workspace-order.test.mjs`,
  until a hub read of the private_vm plan and a VM estimate replaces it (an
  api row, placed by the dispatch holder). The submit goes to the api host
  with credentials, as the auth calls do (`useAuthBase`); on dev/prd it
  works only once that api row adds credentialed CORS on the order route,
  since the Hosting rewrite forwards no session cookie. Red control:
  `tests/e2e/checkout-private-workspace.test.mjs` (a token on the page or a
  card field fails it). Texts in all 19 locales, language-checked by
  `do_spl_lang_review_gct`.

- **B8: Implemented, a dry run by default; never applied** (SPL-6343):
  `cd csi-spl-orc && ENV=<env> TENANT_ID=<tenant> MACHINE_TYPE=<type> ./run -a do_spl_private_ws_vm_provision`
  (`csi-spl-orc/src/bash/run/spl-private-ws-vm-provision.func.sh`) takes
  one order to a printed plan of step `062-gcp-workspace-vms`: (1) the
  tenant's `workspace_orders` row (status `submitted`) with its
  `price_plans` kind `private_vm`, read with `do_spl_db_query` (read-only,
  operator scope) from that env's hub; (2) the entry `<tenant>` ->
  `MACHINE_TYPE` added to the box's runtime VM map
  (`$SPL_VAR_APP_DIR/062-gcp-workspace-vms/<env>.workspace-vms.json`, or
  `WS_VMS_MAP`), never the cnf: B5 as landed keeps tenant ids out of git,
  so the row's "cnf entry" is this runtime map; an entry with another type
  is refused (a resize is not this action's); (3) the rendered
  `<env>/tf/062-gcp-workspace-vms.vars.tfvars` must declare
  `# runtime-vars: workspace_vms` and carry no value for it; (4) `make
  do-tf-plan` with the whole map as `TF_VAR_workspace_vms`, printed, then a
  gate: an Error, a destroy, a replace, an in-place update, or a change
  that does not create this tenant's VM refuses the run. `make do-tf-plan`
  and `do-provision` did not hand `TF_VAR_workspace_vms` to the tf-runner
  (`csi-spl-orc/src/make/tf-tasks.func.mk`, 061's vars only), so B5's
  runtime map never reached terraform through make; they now forward it
  for step 062 only, and only when set. `DRY_RUN` unset or `1`: nothing is
  applied and the map file is not written. `DRY_RUN=0` also needs
  `OWNER_GO=<owner msg id>` (section 7), runs `make do-provision` with the
  same map, then writes the map (mode 0600). `MACHINE_TYPE` has no default
  while Q-21 is open. Not done here: `workspace_orders.status` stays
  `submitted` (no rdb or api change in this row), and `make
  do-tf-plan-pending` (the dev-leads-prd check) does not forward the map.
  Test: `csi-spl-orc/src/bash/tests/spl-private-ws-vm-provision.tst.sh`
  (stubbed `do_spl_db_query`, `make` and `docker`). Red control: the
  dry-run return planted off -> `FAIL: DRY_RUN unset ran do-provision`,
  `FAIL: DRY_RUN unset wrote the map`; the parent's `tf-tasks.func.mk` ->
  `FAIL: plan forward`. No orders on dev when measured (2026-11-24, n = 1:
  `workspace_orders` 0 rows), so no real plan was printed.

- **B11: Implemented, off for every vendor** (SPL-6345): the web-UI
  sign-in relay [Q-5, Q-14 A]. Hub (`internal/hub/signin_relay.go`):
  `POST /v1/signin-relay` `{kind, box?}`, `GET` and `DELETE
  /v1/signin-relay/{relay}`, `POST /v1/signin-relay/{relay}/input`
  `{input}`; a member with `vendor_keys.manage`, never under act-as; only
  the starter reads or feeds a relay; the box is the workspace's
  dedicated pin with a desk recipient (rdb 0235), else 409
  `no_private_vm` / `box_key_not_enrolled`. **The switch**, one per
  vendor, default off: hub env `SPOOL_HUB_SIGNIN_RELAY_KINDS` (unset in
  every cnf) and, on the VM, cnf `env.box.signin_relay_kinds` (absent =
  off); a kind it does not name is 403 `signin_relay_off` on the hub and
  rc 3 on the VM. **Nothing stored**: the relay lives in each hub
  instance's memory for 10 minutes, fed by the NOTIFY channel
  `spool_signin_relay` (`internal/store/signin_relay_wake.go`; two
  instances, the request on one, the VM's socket on the other); the input
  is sealed with age to the VM's desk recipient inside the input handler,
  so the event, the `signin_relay` frame (`internal/wire/signin_relay.go`)
  and every log carry ciphertext only; no table is written. Box: the
  sidecar says `signin_relay` in its hello only with
  `SPOOL_SIGNIN_RELAY_CMD` set (`cmd/spool/signin_relay.go`), opens the
  seal with its desk identity, drops a frame id seen before, and hands the
  input to the command on stdin only. VM: `cd csi-spl-orc &&
  TENANT_ID=<W> SIGNIN_RELAY_OP=start|input|end ./run -a
  do_spl_ws_signin_relay` (`csi-spl-orc/src/bash/run/spl-ws-signin-relay.func.sh`),
  run as W's OS user: start runs do_spl_ws_claude_signin's login in tmux
  and reports its https URL; input pastes stdin's line through `tmux
  load-buffer -` (never an argv), presses Enter, reports `signed_in` or
  `delivered`; only claude has a login wired (grok, mistral: `no_login`).
  WUI: the Agent keys page's claude, grok and mistral rows
  (`csi-spl-wui/src/components/SigninRelayPanel.vue`), texts in 19
  locales, checked with `do_spl_lang_review_gct`. Red controls:
  `TestSigninRelayNeverStoresInput` (the input searched in both
  instances' logs, the NOTIFY payloads, the answers, the frames and every
  store table; planted: the input logged -> red; the input written to
  `box_facts` -> red on Postgres, the table check of record, while the
  Memory walk misses that package-level map), `TestSigninRelaySwitchOff`
  (planted: the switch check skipped -> red), and
  `csi-spl-orc/src/bash/tests/ws-signin-relay.tst.sh` section 1 (the VM's
  switch). Not proven: a real CLI login on a real VM (no private VM
  exists; the sidecar's `TENANT_ID` comes from its environment, as
  `do_spl_desk_up` starts it, unchecked on a VM).

Not in this spec: a private hub (Q-2 B, not chosen); listing on Cloud
Marketplace stays spec 156.

## 7. Owner actions

- A go per VM apply and per VM delete in the first slice (repo CLAUDE.md:
  nothing mutates GCP without the owner).
- Q-21: the one standard private-VM machine type (also closing spec 122
  RQ-3) and its monthly list price source under step `062-gcp-workspace-vms`
  in cnf (1.0).
- Each overdue invoice: the owner decides the case by hand, and marks an
  invoice paid when its bank transfer arrives [Q-17 B, Q-18 C] (row B13).
- 159's O1 (Anthropic), O2 (xAI) and O3 (Mistral): each vendor's written
  answer switches its sign-in relay on, and decides whether grok and
  mistral are offered [Q-4 A, Q-14 A].

## 8. Version log

- v0.1 (2026-11-19, c-625, SPL-5997): first draft: the owner's words, 13
  questions as forms, the flow, what is built (measured on `17f0d7b00`),
  gaps and build order.
- v0.2 (2026-11-19, c-625, SPL-5997): section 1.0, the owner's answers so
  far: Q-1 A, Q-2 A, Q-3 A, Q-13 B (checkout first). Sections 4 and 6 are
  not yet reordered for Q-13 B; that and Q-4..Q-12 come with v0.3.
- v0.2.1 (2026-11-20, c-625, SPL-5997): 1.0 adds Q-5 (both sign-in and
  API keys, sign-in relayed from the web UI), Q-10 A (no fall-back, we
  never resell tokens) and the new form Q-14, answered A (relay built now,
  on per vendor after its written OK). Q-11 stays open: 127 7.1's margin is
  on infrastructure, not tokens.
- v0.3 (2026-11-20, c-625, SPL-5997): status Decided, every question
  answered. 1.0 adds Q-4 A, Q-6 A, Q-7 A, Q-8 A, Q-9 A, Q-11 A and Q-12 C
  (VM deleted at once, hub data 30 days). Sections 2 and 4 to 7 rewritten
  as the answers say; section 6 reordered checkout first (Q-13 B) and
  renumbered; new gap G11 and row B11 (the web-UI sign-in relay, Q-5,
  Q-14 A); G10 dropped (Q-2 A).
- v0.3.1 (2026-11-20, c-292, SPL-6095): row B1 implemented (section 6
  row status): rdb 0302, `internal/store/price_plans.go`.

- v0.4 (2026-11-21, c-515, SPL-6130): the owner's billing ruling (Q-15,
  Q-16 B, msgs `09472141`, `fb5eebab`, `6768e241`): everything is invoiced
  monthly in arrears, the GCP cost forwarded first, then our invoice (9 EUR
  per human member + the VM cost + 33%); no prepaid balance. Q-9 A -> B.
  4.1, 4.4, G6 and B1 rewritten; section 2 names where this differs from
  121 R7 and from row B10 as landed (`d6fc241f9`); new open form Q-17
  (non-payment). After review (m-626, W1): new open form Q-18 (what the
  checkout takes up front, which event creates the tenant); 4.1 step 4,
  G3 and B2 no longer name the paid webhook.
- v0.4.1 (2026-11-21, c-292, SPL-6095): row B1 status follows v0.4: the
  `vm_cost` ledger kind and the balance draw are cut; B1 is the plan and
  its month quote.
- v0.5 (2026-11-21, c-757, SPL-6169): the owner's answers Q-17 B and
  Q-18 C (msg `43573325`) and the 121 gate answer B (msg `82b949e5`).
  Non-payment: a reminder only, the agents keep running, the owner decides
  each case by hand. Checkout: an order only, the workspace created at once
  on submit, the invoice paid by bank transfer; no card, no paid webhook.
  1.0, 2, 3, 4.1, 4.4, 5 (G3, G6; new G12..G14), 6 (B2, B3; new B12, B13)
  and 7 rewritten; the two open poll blocks become the question record.
  New open form Q-19 (the invoice's payment term). Spec 121 v1.6 drops the
  token gap from its pricing gate.
- v0.6 (2026-11-21, c-757, SPL-6169): the owner's answer Q-19 A (msg
  `67b12564`, verbatim in 1.0): the invoice is due 14 days net from its
  invoice date, and the one reminder goes out on day 15. Status: every
  question answered. 1.0, 4.4, G6, G13, B12 and 7 follow; B12 no longer
  waits on Q-19.
- v0.6.1 (2026-11-23, c-261, SPL-6322): row B2 implemented (section 6
  row status): the order submit, rdb 0314 `workspace_orders`.
- v0.7 (2026-11-23, a-749, SPL-6328): month-end invoice issuer gap
  (reported by B12 lane c-279, msg `0c40cac3`; v0.6 last commit
  `0baac162d`, measured on `ef80e6a01`; B12 SPL-6327 landed on
  `origin/master` in `86da15a32`, rdb `0315_private_workspace_invoices.sql`,
  `internal/store/invoices.go:58`). Adds gap
  G15 (section 5: B4 `bbdbbe4da` reads BigQuery over 5-day
  `reread_days`, hub has no BigQuery client, `tenant_memberships` /
  `CountMembers` has no cross-workspace private-workspace reader), new
  row B14 [after B4, B12] (section 6), and the owner's answer Q-20 A
  (msg `7b2f5cd3`, verbatim in 1.0): new `operatorAuth` hub endpoint(s)
  called via `spl_hub_operator_call`, where the orc action sends each
  VM's month cost and the hub counts human members and calls
  `IssueInvoice`; B14 no longer waits on Q-20. Also adds (on c-001 GO
  `63d7a7e9`, c-002 msg `4e4ff199`, c-826 SPL-6339 msg `4959d0cf`) gap
  G16 (section 5: no standard machine type or per-type monthly list price
  under step `062-gcp-workspace-vms` in `all.env.yaml:302-318`), row B15
  [waits on B3, B5, Q-21] for the checkout VM monthly estimate (section
  6), and open poll form Q-21 (section 1, citing and closing spec 122
  RQ-3).

<!-- version: 0.7 · updated: 2026-11-23 · last-edit: 2026-11-23T21:55:00Z -->
