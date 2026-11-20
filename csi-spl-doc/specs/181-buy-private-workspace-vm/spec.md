# Spec 181: buy a private workspace and a private VM, pick the agents

**Feature ID**: `181-buy-private-workspace-vm` · **Status**: Draft v0.2
(4 of 13 answered, 1.0; Q-4..Q-12 open) · **Epic**: SPL-2398 · **Issue**: SPL-5997 ·
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
  **replaced** by this spec (0.2); R7 (card top-up, stop at zero) is not.
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

**Note.** The `$9 per month per seat` line is in the dispatcher's
recording, not in the owner's own words, which say "cloud costs + 33% ...
and nothing else" (`4f17f3da`). Q-6 asks the owner to confirm it.

## 1. Questions for the owner (forms)

Each is a poll the holder can post as it stands; the first option is the
recommended one. Every part of sections 3 to 6 that depends on an answer
names its question as **[Q-n]**.

### 1.0 The owner's answers

Owner HUM-10, t1 topic `b12055b5`, relayed verbatim by the dispatch holder
c-002@sat (msgs `20218211`, `64f641dd`, `94ddb2c5`, `b585876f`, `fc5c25e8`, `502db57e`). An answered question's **[Q-n]**
marks in sections 2 to 6 now read as that answer.

| q | answer | owner msg | when (UTC) |
|---|---|---|---|
| Q-1 | A: ours, one VM per private workspace in our GCP; we pay Google and bill its cost + 33% | `f05a0825` | 2026-11-19 22:05:17Z |
| Q-2 | A: private VM, shared hub; messages on our hub, isolated per workspace by row-level security | `105ffbb4` | 2026-11-19 22:05:37Z |
| Q-3 | A: we hold root, for upkeep only; no fleet lane and no other workspace runs there; the page says so | `695e7abf` | 2026-11-19 |
| Q-13 | **B** (not the recommended A): checkout first, the private-workspace product in Stripe, then provisioning | `2b118136` | 2026-11-19 |
| Q-5 | none of A, B, C: **both** subscription sign-in and API keys; the sign-in is driven from the web UI only, and we relay the buyer's inputs to the CLI's terminal login on their VM | `fd1af997` | 2026-11-20 |
| Q-10 | A, as a binding rule: no metered fall-back, **we never resell tokens**; customers buy their own tokens, we sell the GCP infrastructure and the spool-hub interface | `504cb94f` | 2026-11-20 |
| Q-14 | A: build the relay now; switch it on per vendor after that vendor's written OK (O1, O2, O3); the relay hands the login inputs straight to the VM and stores them nowhere on the hub; API keys work meanwhile | `375f9b8e` | 2026-11-20 |

Q-13 is mapped by its answer text, which is form Q-13's option B word for
word; its poll id `35df3e5f` could not be read from c-625's seat.

Q-5 and Q-10 were answered in chat on form `976aad13`. Q-5's web-UI relay
met spec 159 4.3's switch (claude's sign-in off until Anthropic answers in
writing, O1); Q-14 (below, poll `3190dcc9`) keeps that gate per vendor.
Q-10 removes 159 section 9 (the metered fall-back on our API keys) and
confirms 121 R6's replacement (no AI tokens sold). It does not decide Q-11:
127 7.1's 50% is charged on own cost, the fixed slice and hosts, its token
term is already 0, so 33% against 50% on infrastructure stays open.

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

- **121 R6** (price = tokens x 1.20 + own cost + fixed slice, + 29%) is
  replaced for every workspace by 0.2 (form `b97a036d`). 121 R7 (card
  top-up, stop at zero) is not touched; Q-9 asks whether the VM cost uses
  it. 121's `metered` plan and its token buffer have no price left to
  apply to (P5); their removal is a row of 6, not done here.
- **127 K4 / 7.1** (byok, +50%): Q-11.
- **159 9** (metered fall-back on our API keys): Q-10.
- **159 5.1** (keys on our fleet boxes as per-workspace OS users, owner
  Q-1 B) stays for shared workspaces. A private workspace's keys run only
  on its own VM [Q-2, Q-3].
- **byo-gcp**: becomes Q-1 B / C. Its "later" status stands until Q-1 is
  answered.

## 3. Today, measured

On origin/master `17f0d7b00`, 2026-11-19, n = 1 per command.

| piece | state | command -> result |
|---|---|---|
| checkout and paid webhook make a tenant and its owner | Implemented | `ls csi-spl-api/src/go/spool-hub-api/internal/payments/` -> `handler.go`, `stripe_payments.go`, `m4_test.go`, ...; `ls csi-spl-wui/src/pages/checkout` -> `claim.vue index.vue success.vue` |
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
| a `byok` or private-VM plan kind, `price_plans` | Planned | `git grep -l "'byok'"` and `git grep -l price_plans` (api, orc, iac, rdb, wui, cnf) -> no file |
| the pricing gate (`pricing_not_ready`) | Planned | `git grep -l pricing_not_ready` (same trees) -> no file |
| reading cost from the billing export | Partial | `csi-spl-iac/src/bash/run/gcp-billing-export-setup.func.sh` (DRY_RUN=0 is the owner's), `spl-estate-cost-read.func.sh`; no per-VM-of-a-workspace read |

Paths under `internal/` and `cmd/` are in `csi-spl-api/src/go/spool-hub-api/`.
Not measured: what prd serves, and which switches are on there.

## 4. The flow, end to end

### 4.1 Buy

1. A signed-in person opens "Private workspace" on the checkout. They pick
   the workspace name, the number of seats [Q-6] and the VM size (one
   standard size in the first slice, as 122 S3) [Q-13].
2. The page shows the price of 0.2: seats x 9 [Q-6, Q-7] and the VM's
   estimated monthly cost + 33% [Q-8], and the agents they can pick [Q-4].
   It shows no token price (P5).
3. Payment [Q-9]. A: a first top-up by card, through today's
   payment-intent rail; B: a card on file and a charge in arrears, which the
   rail cannot do today (3: no recurring charge).
4. The paid webhook makes the tenant and its owner (006, built), sets the
   seat caps (009, built), turns `box_join_enabled` on for it, and writes a
   **provisioning order** (new, gap G3).

### 4.2 Provision

- **[Q-1 A]** One VM in our GCP per order: a terraform step with one entry
  per private VM (122 4 point 2's shape, labelled `workspace=<tenant>` so the
  billing export can price it), applied in the tf-runner. In the first slice
  the apply is the owner's go per order (repo CLAUDE.md); automatic only
  after a later owner decision (122 3.1).
- **[Q-1 B]** byo-gcp's grant checklist; the same step in the customer's
  project.
- **[Q-2 B]** the VM also runs a hub and a database: the marketplace VM
  package is the nearest start. 4.3 to 4.5 then talk to that hub, not ours.
- The VM gets the customer box role set of 122 4 point 4: no estate key, no
  GitHub token, no AI login of ours.
- `do_spl_box_workspace_setup` makes `<W>`'s OS user and spool root; the box
  joins with a join token bound to `<W>` and `<vm>` (073; an operator mint
  path, 122 4 point 5, not built). The pin is `dedicated` (108 3.8).
- The 127 5.3 desk start checks run on the VM; on a VM no fleet lane uses,
  the one exception 159 5.2 made for fleet boxes is not needed [Q-3].

### 4.3 Pick the agents

- The biz owner or an admin opens Agent keys (built) and adds a key per
  kind [Q-4, Q-5]. The hub leases each key only to `<W>`'s dedicated pin
  on `<vm>` (127 H2, built).
- Claude subscription: the self sign-in (159 4.3) runs on `<vm>` as
  `<W>`'s OS user, behind its switch [Q-5].
- The workspace's agent split (`internal/hub/agent_split.go`) weights a
  vendor with no key at 0 (127 7.3, 127's owner answer Q-1 A).

### 4.4 Use

- Seats on `<vm>` start through `spool key-exec`; messages go through the
  hub [Q-2]. Every turn writes `usage_events` with `key_source =
  'workspace'`, never charged (127 7.2).
- No fleet lane of ours runs on `<vm>`, and no seat on `<vm>` runs on our
  AI logins (P3, P5). A brief with `Workspace: <W>` for a private workspace
  places only on `<vm>` (159 5.3, with `<vm>` as W's only key host).
- A key that runs out: the task waits [Q-10].
- The VM's daily cost + 33% is drawn from the balance [Q-8, Q-9]; at zero
  the agents stop and the workspace stays readable (121 R7).

### 4.5 Cancel

- [Q-12] The agents stop at once: leases end (127 5.2), the pin is revoked
  (108 3.7, T012 not built).
- The VM is stopped, its disk kept, and deleted by a named action [Q-12];
  the delete is a GCP mutation, so it waits for the owner's go in the
  first slice.
- Keys: the workspace's keys are removed with the workspace; the vendor
  side is the customer's.

## 5. Gaps

| # | gap | blocks | depends on |
|---|---|---|---|
| G1 | a terraform step with one VM per private workspace, labelled by workspace | 4.2 | Q-1, Q-13 |
| G2 | the customer box role set (no estate keys) and an operator join-token mint path | 4.2 | Q-3 |
| G3 | a provisioning order written by the paid webhook, and a named action that takes it to a plan | 4.1, 4.2 | Q-13 |
| G4 | a price plan: seat cents, VM cost + 33%; the `price_plans` table of 121 is not built | 4.1 | Q-6..Q-9, Q-11 |
| G5 | the VM's cost per day from the billing export, by its label | 4.4 | Q-8 |
| G6 | draw-down of the balance by the VM cost (or a charge in arrears) | 4.4 | Q-9 |
| G7 | the checkout page for the private workspace, its texts in every locale, agy last | 4.1 | Q-4, Q-6, Q-7 |
| G8 | revoke (108 T012) and a cancel action that stops, keeps and later deletes the VM | 4.5 | Q-12 |
| G9 | removal of 121's token pricing (`metered`, the x 1.20 buffer) and 159's metered fall-back | 2 | Q-10, Q-11 |
| G10 | a private hub per workspace | 4.2 | Q-2 B only |

## 6. Build order (rows a later lane can take)

Each row is one small lane with its red control. Order as recommended by
Q-13 A; a different answer reorders it.

| # | lane | task | red control | waits on |
|---|---|---|---|---|
| B1 | iac (claude) | step for per-workspace VMs: `for_each` over a cnf map `<tenant> -> machine type`, labels `workspace`, `box`; plan only | an entry without a `workspace` label -> the step's check refuses the plan | Q-1, Q-3 |
| B2 | iac (claude) | customer box role set: no estate key, no AI login of ours; `do_spl_box_workspace_setup` and the 127 5.3 checks run | the role set given an estate key file -> its test fails | Q-3 |
| B3 | hub (claude) | operator-only join-token mint bound to `<tenant>` and `<vm>`, named in `TestOperatorScopeCallers`, audited | a token for `<vm>` redeemed by another box -> refused | B1 |
| B4 | orc (claude) | a named provisioning action (dry run): order -> cnf entry -> tfvars -> plan printed; apply only with `DRY_RUN=0` and the owner's go | `DRY_RUN` unset -> nothing applied | B1..B3 |
| B5 | iac/orc (claude) | per-VM cost per day from the billing export by label (spec 123's reader) | a fixture row with another workspace's label -> not counted | Q-8 |
| B6 | rdb + hub (claude) | the private-workspace price: seat cents, VM cost + 33%, the draw-down or charge | a plan with a token line -> refused (P5) | Q-6..Q-9, Q-11 |
| B7 | hub (claude) | paid webhook: tenant, seats, `box_join_enabled` on, the provisioning order | webhook replayed -> one order, not two | B6 |
| B8 | wui (claude) | the private-workspace checkout and its price lines; locale texts, agy review last | the page shows a token price -> e2e fails | B6, Q-4 |
| B9 | hub + orc (claude) | cancel: leases end, pin revoked (108 T012), VM stop, delayed delete (owner's go) | a cancelled workspace's seat asks a lease -> 403 | Q-12 |
| B10 | doc (agy) | 121, 127 and 159 edited by their editors for G9, as the answers say | `grep -c 'x 1.20' csi-spl-doc/specs/121-sales-channel/spec.md` -> found only in history lines | Q-10, Q-11 |

Not in this spec: a private hub (Q-2 B) is its own spec if the owner picks
it; listing on Cloud Marketplace stays spec 156.

## 7. Owner actions

- The answers to section 1.
- A go per VM apply and per VM delete in the first slice (repo CLAUDE.md:
  nothing mutates GCP without the owner).
- 159's O1 (Anthropic), O2 (xAI) and O3 (Mistral) still decide which
  subscriptions and kinds can be offered [Q-4, Q-5].

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

<!-- version: 0.2.1 · updated: 2026-11-20 · last-edit: 2026-11-20T15:13:42Z -->
