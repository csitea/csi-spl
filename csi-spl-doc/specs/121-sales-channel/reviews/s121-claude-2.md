signed against 6eded1d95

# Spec 121 review, seat s121-claude-2 (c-802)

Reviewed: `csi-spl-doc/specs/121-sales-channel/spec.md` at 6eded1d95 (89 lines),
plus addendum 4 (owner msg 0ee6d8af, B2B embed) and the two owner answers the
editor relayed on dispatch-e001c851: the paid private channel is A (owner msg
1a374b78, settled, not an owner question here), the price is metered cost
plus a margin (owner msg 294eb431), metering of tokens, token limits and our
cost per token is in scope (owner msg 1f03918f), and the same metering covers
workspaces (owner msg 0137a1bd). Selling whole workspaces (owner msg 055ae092)
is still open with the owner; nothing below blocks any of its three options.

Every "today" claim below carries the command that shows it, run on this
worktree at 6eded1d95.

## 1. Verdict per section

| section | verdict | one line |
|---|---|---|
| 1. The owner's words | change | add 0ee6d8af (B2B embed), 1a374b78 (paid private channel = A) and 294eb431 (cost + margin); the spec is now "embed + metered sale", the csitea.net pop-up is customer #1 |
| 2. intro | change | "spool-hub.ai and csitea.net" becomes "spool-hub.ai and any embedding customer site; csitea.net first" |
| 2.1 Embed | change | `frame-ancestors` cannot be one static header: today every WUI response says `'none'` and the WUI is a static Firebase bundle (2.4 below); the embed is served by the hub with a per-customer allow-list |
| 2.2 Isolation | change | "enforced by RLS" is not true of today's schema: RLS is per tenant only, channel privacy is Go code (2.2 below); the spec must name the new policy that makes it true, and its negative test |
| 2.3 Abuse | change | spec 077's demo caps assume an IdP sign-in (`DemoProviders` = google, facebook, linkedin, "never password"); an anonymous visitor has no IdP account to count on, so the caps need a new key (2.3 below) |
| 2.4 Staff visibility | agree, extend | add the notification path and what the triage channel may carry (2.5 below) |
| 3. Catalogue | change | owner 294eb431 replaces "fixed price, hourly, retainer": a catalogue entry is a plan (what is metered, which margin), not a fixed price |
| 4. Where it shows | agree | `/services` as a spec 116 public page; a lazy route, outside the 160 KB initial chunk |
| 5. Order and payment | change | the hub already has payment rails (2.6 below); the flow ends in "payment adds the buyer as a member of one channel" (owner A) |
| 6. csi-rel reuse | change | the draft says the channel "will interact with the data models established there": csi-rel is context only, never code or a runtime dependency; the seam already ported is `internal/payments/provider.go` |
| 7. Owner questions | change | Q3 is replaced by "what margin" (owner 294eb431); the single-channel question is settled; Q4 changes shape because the rails exist; new questions in section 3 |
| missing | add | visitor identity, embed auth, metering, per-customer isolation, retention and erasure, tests and phases (section 2) |

## 2. Proposals for what is missing (each buildable)

### 2.1 Anonymous-visitor identity

Today a hub session is a signed cookie with a 12 h default TTL
(`grep -n '12 h default TTL' csi-spl-doc/specs/077-demo-users/spec.md` -> 237).
Inside an iframe on another site that cookie is third-party: Safari blocks it,
Chrome keeps it only as `SameSite=None; Secure; Partitioned` (CHIPS). So the
embed must not depend on the hub's sign-in cookie.

Proposal:
- **Visitor token**: on the first open, `POST /v1/embed/{customer}/visitor`
  mints a random 256-bit token; the hub stores only its sha256 in a new
  `embed_visitors` row (tenant_id, customer_id, visitor_id uuid, token_hash,
  channel_id, created_at, last_seen_at, expires_at, ip_hash).
- **Where it lives**: the iframe keeps it in its own `localStorage`. Browsers
  partition that storage by the top-level site, which is the scope we want:
  the same browser on csitea.net finds its channel again, another site
  embedding us does not. It travels as `Authorization: Bearer`, never a
  cookie, so no third-party-cookie rule applies.
- **Lifetime**: sliding 30 days from `last_seen_at`, hard cap 180 days; a
  sweep (the `SweepDemo` pattern) closes expired visitors and keeps their
  channel read-only for the owner until retention (Q8) deletes it.
- **New device**: no account, so no automatic recovery. The visitor may give
  an e-mail (optional, Q9); the hub mails a one-time link that binds the new
  device's token to the same visitor (the claim-mail pattern of
  `internal/payments`). Without an e-mail, a new device is a new visitor and a
  new channel; the owner can merge two visitor channels by hand.
- **Paying buyer** (owner A): on payment the visitor becomes a real human row
  (e-mail sign-in) with the channel-guest role in that one channel; the
  anonymous token keeps working until it expires.

### 2.2 Per-visitor and per-customer isolation, at the RLS level

Today: the RLS policies are `tenant_scope` and `operator_scope` only
(`grep -n 'CREATE POLICY' csi-spl-rdb/src/sql/postgres/spool-hub/0014_tenant_rls.sql`
-> 39, 42). Channel privacy is the Go read door
(`internal/hub/privacy.go`, rdb 0028: "every created channel is members-only").
So "a visitor reads only their channel" is NOT enforced by Postgres today.

Proposal:
- New GUC `app.visitor_id`, set with `SET LOCAL` by a new
  `inVisitor(tenant, visitor)` transaction helper beside the existing tenant
  and operator helpers.
- One **restrictive** policy per table a visitor can reach (`messages`,
  `channels`, `channel_humans`, the files table):
  `AS RESTRICTIVE USING (NULLIF(current_setting('app.visitor_id', true), '') IS NULL OR channel_id IN (SELECT channel_id FROM embed_visitors WHERE visitor_id = current_setting('app.visitor_id')::uuid))`.
  Restrictive, so it narrows `tenant_scope` and never widens it; staff
  sessions never set the GUC and are unchanged.
- The visitor path runs as the DML-only runtime role, never the owner role, so
  FORCE RLS applies.
- **Channel-guest role** (owner A): a new system role `channel_guest`, like
  `demo_user` NOT in `rbac.RoleIDs`
  (`grep -n 'var RoleIDs' csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go` -> 74),
  so no member route grants it. It grants read and post in the channels where
  it holds a `channel_humans` row, and nothing else in the tenant: no channel
  list, no people list, no docs, no search outside those channels. The same
  restrictive policy keys on a second GUC `app.guest_human_id`.
- **Per-customer isolation (B2B)**: each embedding business customer is its own
  tenant (spec 105 host), never a channel in ours. Their visitors' channels
  live in their tenant, so `tenant_scope` already separates customer from
  customer; the visitor policy separates visitor from visitor inside one.
- **Tests**, each refusal paired with the same read by someone allowed (the
  `channel_privacy_test.go` rule, so "nobody can read anything" cannot pass):
  1. RLS-negative on Postgres: as the runtime role with `app.visitor_id = A`,
     `SELECT` of visitor B's messages returns 0 rows; the control with
     `app.visitor_id = B` returns them.
  2. The same for a `channel_guest` on a channel they are not in, and for
     search (the search signature index must not leak word hits across
     channels).
  3. HTTP: visitor A's token on B's channel id = 404, not 403.
  4. Cross-customer: a token minted for customer X on customer Y's embed route = 404.

### 2.3 Abuse, spam, rate limits, bots

The demo caps exist and are the model
(`grep -n 'DemoPostsPerMinute int\|DemoAgentTurns int\|DemoSignupsPerIP int' csi-spl-api/src/go/spool-hub-api/internal/config/config.go`
-> defaults 10 per minute, 20 turns, 3 sign-ups per IP; counters in
`quota_counts`, rdb 0127). Proposal, cnf `embed.*` per customer, defaults:

| limit | default | refused as |
|---|---|---|
| new visitors per client IP per UTC day | 5 | 429 `embed_visitors` |
| posts per visitor per minute / per day | 6 / 100 | 429 `embed_quota` |
| message size | 4 KB text, no files until paid | 413 |
| agent turns per visitor per day (unpaid) | 10 | 429 `embed_quota` |
| live unpaid visitors per customer | 200 | 503 `embed_full` |
| token spend per customer per day (unpaid traffic) | cnf ceiling in EUR | 429, owner alerted |

- Counts reuse `quota_counts` (kinds `embed_post`, `embed_turn`; window =
  minute / day) and the client IP of 017 FR-SEC-006 (`TrustedProxyHops`).
- **Bots**: the first post (not the page load) carries a challenge token the
  hub verifies server-side; which challenge is Q7.
- Bans reuse `demo_bans` (rdb 0130) keyed on visitor_id and ip_hash, and the
  moderation path of `internal/hub/demo_moderation.go`.
- The per-customer daily spend ceiling is the hard stop: unpaid visitors can
  never cost more than that ceiling, whatever the per-IP caps miss.

### 2.4 What the customer site embeds; CSP, CORS; repo split

Today every WUI response sends `frame-ancestors 'none'`
(`git grep -c "frame-ancestors 'none'" -- csi-spl-wui/nuxt.config.ts csi-spl-wui/firebase.json`
-> 2 and 1) and a unit test pins it
(`csi-spl-wui/tests/unit/csp-policy.test.mjs:122`).

Proposal:
- **Embed = a small script tag that creates an iframe.** The customer pastes
  one `<script src="https://<<run-time>>.csitea.net/embed/v1/loader.js" data-customer="<id>" async>`
  (host from cnf); the loader draws the launcher button and opens an iframe to
  `/embed/v1/chat?c=<id>`. Script for the button, iframe for everything that
  touches data: the customer page never sees the visitor token or messages.
- **The embed page is served by the hub (Cloud Run), not Firebase.** A static
  host cannot vary `frame-ancestors` per customer; the hub reads the
  customer's allowed origins (`embed_customers.allowed_origins`, owner-set)
  and answers `Content-Security-Policy: frame-ancestors <those origins>`.
  Every other path keeps `'none'`; the csp test grows one case: `/embed/*`
  lists exactly the customer's origins, every other path stays `'none'`.
- **CORS**: the iframe calls the hub from the hub's own origin, so the API
  needs no `Access-Control-Allow-Origin` for customer sites (draft 2.1 asks
  for one: drop it). The loader is a static script served with
  `Cross-Origin-Resource-Policy: cross-origin`. Parent and iframe talk over
  `postMessage` with an exact `targetOrigin`, UI events only (open, close,
  unread count), never message text.
- **Repo split**: this repo owns the loader, the embed route, the hub API, the
  CSP and the tests. `csi-web` owns the one script tag and its own CSP
  (`script-src` and `frame-src` for our host). Hosts come from cnf
  (`BASE_DOMAIN`), never literals.
- **Embedded-user auth**: unpaid = visitor token (2.1). Paid = the buyer
  signs in by e-mail link inside the iframe; the session is a Bearer token in
  partitioned storage, not a cookie.

### 2.5 No personal data in tenant workspaces; where questions land

- A visitor's channel lives in the selling tenant only (csitea for customer
  #1), as a members-only created channel, so it never shows in `#lobby`,
  search or another member's channel list. Staff see visitor channels in a
  "Visitors" rail section listed to biz_owner and admin only.
- Personal data kept: the optional e-mail, `ip_hash` (salted sha256, rotated
  salt), the messages. No raw IP, no user-agent.
- The answering agent gets the visitor channel's text plus one curated
  "sales facts" doc the owner writes, nothing else. A test asserts the context
  built for a visitor channel holds no other channel's message ids.
- Retention per Q8; a visitor can delete their own channel from the pop-up
  (erasure on request).
- Notification: each new visitor channel, and each first post after 24 h of
  quiet, posts one line to a staff triage channel (`#sales`): a link only, no
  message text, so the triage channel carries no visitor content.

### 2.6 Metering, billing, order and payment

What exists: payment rails ported from csi-rel's provider seam
(`grep -n "csi-rel's provider seam" csi-spl-api/src/go/spool-hub-api/internal/payments/provider.go` -> 8),
with `stripe_payments.go` (card rail), `paypal_payments.go` (wallet rail) and a
credential-free fake-pay rail; `internal/billing` maps payment events onto
`tenants.billing_status`. What does not exist: token metering
(`git grep -l -i -E 'input_tokens|output_tokens|token_cost' -- csi-spl-api csi-spl-rdb`
-> no file). I believe, unchecked in this review, that the per-env service
accounts cannot read GCP billing today.

Proposal (owners 294eb431, 1f03918f, 0137a1bd: we resell cloud and token
usage at cost, plus a margin justified by the UI and the whole system):
- **Usage ledger**: new append-only table `usage_events` (tenant_id,
  workspace_id, channel_id NULL, agent_id NULL, human_id NULL, kind
  `llm_tokens_in|llm_tokens_out|llm_tokens_cache|agent_seconds|storage_bytes|egress_bytes|cloud_share`,
  provider, model, units, unit_cost_micros, at), tenant RLS. The workspace is
  always set, the channel when there is one: so one ledger answers per
  workspace, per channel, per agent and per human, and selling a seat, a whole
  workspace or both (055ae092, open) is only a different `GROUP BY`, never a
  schema change.
- **Where tokens are counted**: at the one place a model call returns its
  usage. Every agent turn the hub dispatches carries `turn_id`; the agent seat
  reports `{turn_id, provider, model, tokens_in, tokens_out, tokens_cache}`
  from the provider's usage field back to the hub (a new field on the result
  envelope), and the hub writes the row. A turn with no usage report is
  counted as `unmetered` and alerts: a gap must be visible, never read as zero.
- **Cost per token**: a `model_prices` table (provider, model, kind,
  micros_per_1k, valid_from), filled by a named action from cnf
  (`sales.model_prices`), each change a new row so an old invoice re-prices
  identically. `unit_cost_micros` is copied onto the event at write time.
- **Token limits**: per workspace and per paid channel, a monthly and a daily
  token budget (cnf default, per-plan override). The hub checks the running
  sum before it dispatches a turn (the `quota_counts` take pattern of rdb 0127:
  refuse BEFORE the work is built) and answers 429 `token_quota`; at 80 % the
  workspace owner gets one notice. Prepaid (Q5 A): the budget is the balance.
- **Subscription seats vs API keys**: an agent on a subscription login has a
  flat cost, not a per-token one, so a token it spends has no true unit cost
  (Q10). Metering still counts its tokens; only the price differs.
- **Cloud cost attribution**: the GCP billing export to BigQuery (a one-time
  owner bootstrap, as a named action); a daily named action allocates shared
  estate cost (hub CPU, DB) to customers by their share of `agent_seconds`
  and requests, written as `cloud_share`. Tokens are exact; shared cost is an
  allocation, and the invoice says so.
- **Margin**: cnf `sales.margin_pct` (default) with an optional per-plan
  override in `embed_plans`; the value is Q3.
- **Invoice**: monthly per customer, lines = `usage_events` summed by kind
  times unit cost, the margin as its own line; built by a named action
  (`do_spl_sales_invoice`, dry run by default), charged through the existing
  rails per Q4 and Q5.
- **Paid private channel (owner A)**: checkout line item `channel_seat`; the
  paid webhook adds the buyer as `channel_guest` to that one channel (a
  `channel_humans` row), idempotent on the checkout id. Refund or unpaid
  removes the row after the `billing` grace rule.

### 2.7 Phases (smallest first)

1. Visitor token, visitor channel, restrictive RLS and its negative tests; dev
   only, csitea tenant, staff answer by hand. No payment.
2. Embed loader and the hub-served `/embed` with per-customer
   `frame-ancestors`; csi-web adds the script tag; the caps of 2.3.
3. Agent answering (Q1) and `usage_events` metering of tokens and agent time.
4. `channel_guest` and the paid private channel checkout (owner A).
5. Cloud-cost allocation, monthly invoice with margin; a second customer tenant.

## 3. Owner questions (options and my recommendation; not decided)

Settled, not asked again: the paid private channel = A (1a374b78); price =
cost + margin (294eb431).

1. **Who answers the public questions?**
   - A. An agent first; a human takes over on request or when the agent is unsure.
   - B. Humans only; the agent drafts a reply a human approves.
   - C. Agent and human both in the channel from the start.
   - **Recommendation: B for phase 1, then A.** A wrong price or promise from an
     unreviewed agent to a stranger is costly; a draft costs staff one click.
2. **Which agents can see a visitor's channel?**
   - A. One dedicated sales agent per selling tenant, nothing else.
   - B. Any agent the owner adds to that channel.
   - **Recommendation: A.** One agent with a curated context is the only
     shape whose "sees nothing else" can be tested.
3. **What margin?** (replaces "what are the services and prices")
   - A. One fixed percentage on metered cost, for every customer.
   - B. A percentage per plan (e.g. lower for prepaid volume).
   - C. A fixed percentage plus a monthly base fee per embedding customer.
   - **Recommendation: A to start**, its value the owner's; the setting is per
     plan from day one, so moving to B needs no migration.
4. **Which payment rail?** (the hub already has card, wallet and fake rails)
   - A. The card rail only.
   - B. Card and wallet, as checkout does today.
   - C. Invoice and bank transfer for business customers; card for single buyers.
   - **Recommendation: C.** Businesses billed monthly on metered use expect an
     invoice; one paid channel is a card checkout.
5. **(new) Prepaid or postpaid?**
   - A. Prepaid balance; usage draws it down; work stops at zero.
   - B. Postpaid monthly invoice with a credit ceiling.
   - **Recommendation: A** for single buyers and new customers (no unpaid
     risk); B only for customers the owner approves.
6. **(new) Who pays for unpaid visitors' tokens?**
   - A. The embedding customer: unpaid visitor usage is metered to them.
   - B. The platform: pre-sales chat is free up to a ceiling.
   - **Recommendation: A**, with the per-customer daily ceiling of 2.3.
7. **(new) Bot challenge on the first post?**
   - A. Self-hosted proof-of-work (no third party sees the visitor).
   - B. A hosted challenge service.
   - **Recommendation: A** (no new processor of visitor data).
8. **(new) How long do unpaid visitor channels live?**
   - A. 30 days after the visitor's last message.
   - B. 180 days.
   - C. Until the owner deletes them.
   - **Recommendation: A**, and the owner can keep one (mark it a lead).
9. **(new) May a visitor leave an e-mail before paying?**
   - A. Optional field, used only to restore the channel on a new device and to reply.
   - B. No e-mail before payment.
   - **Recommendation: A**, opt-in, its purpose shown next to the field.
10. **(new) Which model access serves paying customers?**
    - A. Pay-per-token API keys for customer-serving agents: cost per token is exact.
    - B. The fleet's subscription logins, cost allocated per token from the flat fee.
    - C. A for customers, B for our own internal work.
    - **Recommendation: C.** Reselling at cost needs a real cost per token, and a
      subscription's terms may not allow serving third parties; internal work
      keeps the cheaper flat fee.
11. **(new) What happens when a customer hits their token limit?**
    - A. Hard stop: agent turns refused until the next period or a top-up.
    - B. Soft limit: work continues, the overage is billed with the margin.
    - **Recommendation: A** by default, B per customer the owner approves (the
      same split as Q5).

## 4. Seat summary

Agree with the draft's direction, with the corrections of section 1. The two
that matter most: isolation is NOT already RLS (a restrictive per-visitor
policy is new work, with its negative test), and the hub already has payment
rails but no token metering, so metering is the critical path for the owner's
price rule.
