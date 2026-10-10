# 121 Sales channel: selling Csitea.net services on spool-hub.ai

Version **v1.0** (2026-10-10), signed by all four seats and the drafter on
rc1 5385b4665 (section 11). The panel fold by the editor (seat
s121-claude, c-801) of a-800's draft (6eded1d95, 89 lines). The seat files are
under [reviews/](reviews/); section 11 records what each one changed. Five
owner answers arrived during the review and are folded in (section 1.2).
Section 12 holds the questions still open, grouped, with the panel's
recommendations first; c-002 posted them to the owner as one blocker
(csitea e001c851, msg 5c92ad8c).

## 1. The owner's words

### 1.1 The ask (HUM-10, workspace csitea, topic e001c851, verbatim)

- msg b667a87b: "We need to make spoolhop.ai a kind of digital distribution channel for the selling of the services of the SiteNet."
- msg 8bc8d70f: "Csitea.net"
- msg 3cf34194: "That is, public (aka unauthenticated) customers should be able to ask questions about our services."
- msg 84910839: "Some kind of pop-up in the .net site, which will allow a public user to connect to a strictly restricted channel dedicated to that new customer, so nobody else could see what this customer has been chatting about, except, of course, me as the owner of citia.net"

The spoken names read as: "spoolhop.ai" = spool-hub.ai, "SiteNet" and
"citia.net" = Csitea.net.

### 1.2 Owner answers during the review (HUM-10, csitea, verbatim)

- topic 75a7075a, msg 0ee6d8af: "That is, the business model will be such that the business users will get the capability to integrate, in their iframe, part of the Spool Hub interface. There, against payment, they will be able to use the resources of our tokens and of our AGI agents."
- topic ebfb10dc, msg 1a374b78: "Yeah, let's pick A." (A = the paid private channel.)
- topic ebfb10dc, msg 294eb431: "And the way to sell it will be based on cloud expenses, token usage, and then a margin above a pure technical one."
- topic ebfb10dc, msg 1f03918f: "We need to gain the technical capability to somehow count the tokens and the token limits, and what our costs per token are, so that we are just resellers of cloud resource token usage. Of course, we provide the UI service, but we will just gain a margin on top of all of those. The justification for the margin is the usage of the UI of our systems. And, of course, the usage of the whole thing combined"
- topic d515fcdb, msg 055ae092: "Let's discuss the possibility for Cydia to be able to sell access to different workspaces in the Spoolhub AI." ("Cydia" = Csitea.)
- topic d515fcdb, msg 0137a1bd: "Same as the previous discussion for the selling of private channels, we should also discuss the possibility of counting the tokens for the usage of the workspaces as well."
- topic d515fcdb, msg 97b94903: "For now, the whole workspace only will be for sale."

### 1.3 What they add up to

| # | requirement | from |
|---|---|---|
| R1 | a signed-out visitor asks questions in a pop-up on csitea.net, in a channel only they and the owner see | 3cf34194, 84910839 |
| R2 | v1 sells **whole workspaces** only: the buyer gets their own workspace | 97b94903 |
| R3 | a business that bought a workspace embeds part of the Spool Hub UI in its own site, in an iframe | 0ee6d8af |
| R4 | price = metered cost (cloud + LLM tokens) + a margin; we resell usage, the margin pays for the UI and the whole system | 294eb431, 1f03918f |
| R5 | tokens counted, limited and costed, per workspace too | 1f03918f, 0137a1bd |
| L1 | **later, not v1**: the paid private channel (one channel inside someone else's workspace) | 1a374b78, deferred by 97b94903 |

The csitea.net pop-up (R1) is not a sale: it is customer #1 of the embed (R3),
with Csitea's own workspace paying for its usage.

## 2. Today, measured (trunk at 6eded1d95)

Paths under `csi-spl-api/src/go/spool-hub-api/` unless named.

| fact | the command that shows it |
|---|---|
| RLS is per tenant only: `tenant_scope` + `operator_scope` | `grep -n "CREATE POLICY" csi-spl-rdb/src/sql/postgres/spool-hub/0014_tenant_rls.sql` -> 39, 42 |
| channel membership (`channel_humans`, rdb 0028) is enforced in Go, not by a policy | `internal/hub/privacy.go`; rdb 0028 header |
| the default channels (lobby, tasks, alerts) are tenant-wide by owner rule | rdb 0028 header, "SCOPE" |
| the sign-in cookie is `SameSite=Lax`, which a browser never sends inside a third-party iframe | `grep -c SameSiteLaxMode internal/auth/handler.go` -> 3 |
| every WUI page refuses framing | `git grep -c "frame-ancestors 'none'" -- csi-spl-wui/nuxt.config.ts csi-spl-wui/firebase.json` -> 2 and 1; pinned by `csi-spl-wui/tests/unit/csp-policy.test.mjs` |
| the WUI is a static Firebase bundle: one header set per path glob, not per customer | `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` |
| the hub already sells a workspace (M2 buy-a-tenant) on card, wallet and fake rails, code copied from csi-rel, never imported | `grep -n "never imports it" internal/payments/config.go` -> 1 |
| per-human counters that survive a redeploy | `quota_counts`, rdb 0127 |
| the demo caps and bans to copy | `DemoPostsPerMinute`, `DemoMaxStay` in `internal/config/config.go`; `demo_bans` rdb 0130 |
| nothing counts LLM tokens | `git grep -l -i -E 'input_tokens\|output_tokens\|token_cost' -- csi-spl-api csi-spl-rdb` -> no file |
| the per-env SAs cannot read GCP billing (Cloud Billing API disabled) | I believe, unchecked in this fold, that this still holds (measured 2026-09-28 for spec 047) |

## 3. Scope and phases

v1, smallest first; each phase ships alone, dev then prd:

1. **Visitor channel** (R1): visitor token, one channel per visitor in the
   `csitea` workspace, the channel-scope RLS policy and its negative tests.
   Staff answer by hand. Behind cnf `env.hub.embed.enabled` (off).
2. **Embed** (R1, R3): the loader script and the hub-served `/embed/<id>` with
   per-customer `frame-ancestors`; csitea.net adds the script tag; the limits
   of section 6.
3. **Agent answers and metering** (R4, R5): the sales agent (Q-V1, Q-V2) and
   the `usage_events` ledger, model prices, token budgets.
4. **Workspace sale on metered pricing** (R2, R4): the existing buy-a-tenant
   checkout sells a workspace whose bill is usage + margin; prepaid balance.
5. **Cloud cost allocation and the monthly invoice** (R4); a second embedding
   customer.

Later (L1): the paid private channel. Section 10 keeps it buildable on the
same parts.

## 4. The visitor

### 4.1 Identity: a visitor token, no account

- On the first question the iframe calls `POST /v1/embed/<embed-id>/visitor`;
  the hub mints a random 256-bit token and stores only its sha256 in a new
  `embed_visitors` row (tenant_id, embed_id, visitor_id uuid, token_hash,
  channel_id, ip_hash, created_at, last_seen_at, expires_at).
- The hub makes, in the same transaction, a HUM row of kind `channel_guest`
  (no e-mail, no password, no identity provider), a tenant membership with the
  system role `channel_guest`, a new created channel, and its
  `channel_humans` row.
- The token lives in the iframe's own `localStorage` and travels as
  `Authorization: Bearer`, never as a cookie, so no third-party-cookie rule
  applies. Browsers partition that storage by the top-level site: the same
  browser on csitea.net finds its channel again; another site embedding us
  does not.
- Lifetime: 30 days sliding from `last_seen_at`, hard cap 180 days. A sweep
  (the `SweepDemo` pattern) expires the token; the channel stays readable to
  the owner until retention (4.4) removes it.
- New device or cleared storage: the visitor may give an e-mail (optional,
  offered after the first answer, its purpose shown beside the field); the hub
  mails a one-time link (15 min, single use) that binds a new token to the
  same visitor. Without an e-mail, a new device is a new visitor and a new
  channel; the owner can merge two visitor channels by hand.
- Safari (from s121-claude-2's signature, unchecked): Safari may clear
  script-written storage in a third-party iframe after about 7 days without
  a first-party visit, so there the 30-day token may last ~7 days in
  practice and the e-mail link is the recovery path. The build measures it
  before it promises a lifetime.

### 4.2 Isolation at the RLS level

- New GUC `app.channel_scope`, set transaction-local by a new
  `store.inChannel(tenant, channel)` beside `inTenant` and `asOperator`. A
  visitor request runs only under `inChannel`; the hub never calls
  `inTenant` for a `channel_guest`.
- One **restrictive** policy on every table a channel reader reaches
  (`messages`, `channels`, `channel_humans`, reactions, revisions, files, the
  search signature index; the build lists them by name):
  `AS RESTRICTIVE USING (NULLIF(current_setting('app.channel_scope', true), '') IS NULL OR channel = current_setting('app.channel_scope', true))`,
  with the same `WITH CHECK`. Restrictive, so it narrows `tenant_scope` and
  never widens it; staff sessions never set the GUC and are unchanged.
- DMs (`channel IS NULL`) and the default channels fail the policy, so a
  visitor never reads lobby, tasks, alerts or a DM.
- The visitor path runs as the DML-only runtime role (`spool_hub_rt`), never
  the owner role, so FORCE RLS binds it.
- `channel_guest` is a system role like `demo_user`, kept out of
  `rbac.RoleIDs`, so no member route grants it. It may read and post in its
  channel and nothing else: no channel list, no people list, no docs, no
  search outside the channel.
- Per-customer isolation: each embedding business is its own workspace
  (tenant), never a channel in ours, so `tenant_scope` already separates one
  customer from another; the channel policy separates visitor from visitor
  inside one.

### 4.3 No personal data in the wrong place

- A visitor exists only in its one channel: not in the member list, not in
  lobby fan-out, not in another member's search, not in the public dataset
  export (spec 091: the export excludes `channel_guest` channels, with a
  test), not in RUM.
- Kept: the messages, the optional e-mail (hub-wide, like
  `human_identities`, shown only to the workspace owner), `ip_hash` (salted
  sha256, salt rotated). No raw IP, no user agent.
- The answering agent gets the visitor channel's text plus one owner-written
  "sales facts" doc, nothing else; a test asserts the context built for a
  visitor channel holds no other channel's message ids.

### 4.4 Where questions land, and retention

- Staff (biz_owner, admin) see visitor channels in a "Visitors" rail group.
- A new visitor channel, and a first post after 24 h of quiet, post one line
  to a private `#sales` triage channel: a link only, never the message text.
- Retention: a visitor channel is removed 30 days after its last message,
  unless the owner marks it a lead. The visitor can delete their own channel
  from the pop-up (erasure on request).

## 5. The embed

- **A script tag that creates an iframe.** The customer pastes one tag; the
  loader (`/embed/v1/loader.js`, host from cnf `BASE_DOMAIN`, never a literal)
  draws the launcher button and opens an iframe to `/embed/v1/chat?e=<embed-id>`.
  The host page never sees the token or a message.
- **The hub serves `/embed/*`, not Firebase.** A static host cannot vary
  `frame-ancestors` per customer; the hub reads `embed_customers.allowed_origins`
  (set by the workspace owner on an embed admin page) and answers
  `Content-Security-Policy: frame-ancestors <those origins>`. Every other path
  keeps `'none'` and `X-Frame-Options: DENY`. A new customer is a row, not a
  WUI deploy.
- **CORS**: the iframe calls the hub from our own origin, so the API needs no
  `Access-Control-Allow-Origin` for a customer site (the draft's 2.1 asked for
  one: dropped). The loader is served with
  `Cross-Origin-Resource-Policy: cross-origin`. Parent and iframe exchange
  `postMessage` with an exact `targetOrigin` and check `event.origin`: UI
  events only (open, close, unread count), never message text.
- **Embedded user who is signed in on the customer's site** (R3): the
  customer's server signs a short JWT (5 min, `sub` = their user id, `aud` =
  the embed id) with a per-embed key the customer makes on the embed admin
  page; the hub maps (embed, sub) to one `channel_guest`. Without a JWT the
  visitor is anonymous (4.1). The key is the customer's: never in this repo,
  terraform or a log.
- **Repo split**: this repo owns the loader, the embed route, the hub API, the
  CSP, the admin page and the tests. `csi-web` owns only the script tag on
  csitea.net and its own CSP (`script-src`, `frame-src` for our host).

## 6. Abuse, spam, rate limits, bots

Counters in `quota_counts` (rdb 0127; kinds `embed_visitor`, `embed_post`,
`embed_turn`), client IP as 017 FR-SEC-006 (`TrustedProxyHops`). No new
store: there is no Redis in the estate. Every limit is cnf per embed
(`env.hub.embed.*`), and a refused unit writes nothing.

| limit | default | refused as |
|---|---|---|
| new visitors per client IP | 5 per hour, 20 per UTC day | 429 `embed_visitors` |
| posts per visitor | 6 per minute, 100 per day | 429 `embed_quota` |
| message size | 4 KB text, no file upload for a visitor | 413 |
| agent turns per visitor (unpaid) | 10 per day | 429 `embed_quota` |
| live unpaid visitors per embed | 200 | 503 `embed_full` |
| token spend of unpaid traffic per embed | cnf daily ceiling in EUR | 429, owner alerted |

- Bot gate on the FIRST post only (not the page load): a challenge the hub
  verifies server-side (Q-T1), plus a honeypot field.
- Bans reuse `demo_bans` (rdb 0130), keyed on visitor_id and ip_hash; the
  owner blocks a visitor from the channel header (token revoked, channel kept).
- Repeat offenders (from mistral): a visitor that hits a limit 3 times in
  24 h solves the challenge on every post; 5 times bans its ip_hash for 24 h.
- The per-embed daily spend ceiling is the hard stop: unpaid visitors never
  cost more than it, whatever the per-IP caps miss.

## 7. Metering, cost and price (R4, R5)

- **Ledger**: append-only `usage_events` (tenant_id, channel_id NULL,
  agent_id NULL, human_id NULL, kind, provider, model, units,
  unit_cost_micros, at), tenant RLS. Kinds: `llm_tokens_in`,
  `llm_tokens_out`, `llm_tokens_cache_read`, `llm_tokens_cache_write`,
  `agent_seconds`, `storage_bytes`, `cloud_share`. The workspace is always
  set; channel, agent and human when known. Per workspace, channel, agent or
  visitor is a `GROUP BY`; selling a seat or a channel later (L1) needs no
  schema change.
- **Where tokens are counted**: every agent turn the hub dispatches carries a
  `turn_id`; the agent's seat reports `{turn_id, provider, model, tokens_in,
  tokens_out, cache_read, cache_write}` from the model's own usage record on
  the result envelope, and the hub writes the row. A turn with no usage report
  is written as `unmetered` and alerts: a gap is visible, never read as zero.
- **Cost per token**: `model_prices` (provider, model, kind, micros per
  million, valid_from), filled from cnf by a named action; a price change is a
  new row, and `unit_cost_micros` is copied onto the event at write time, so
  an old invoice re-prices the same.
- **Token limits**: `token_budgets` per workspace (and optionally per channel
  or visitor): tokens per day and per month, or a prepaid balance. The hub
  checks before it dispatches a turn (the `quota_counts` take: refuse BEFORE
  the work is built) and answers 429 `token_quota`; at 80 % the owner of the
  workspace gets one notice. Default: hard stop; a soft limit (overage billed)
  only for a customer the owner approves.
- **Cloud cost**: allocated, not measured. The GCP billing export (a one-time
  owner bootstrap, as a named action) gives the monthly estate cost; a daily
  named action splits shared cost (hub CPU, DB) across workspaces by their
  share of `agent_seconds` and requests, written as `cloud_share`. Tokens are
  exact; shared cost is an allocation, and the invoice says so.
- **Price** = metered cost x (1 + margin). The margin is a setting:
  `price_plans.margin_pct`, a platform default with an optional per-plan
  value (the schema allows per plan from day one; Q-M1 picks the start).
- **Unpaid visitors** are metered to the workspace that embeds them; for
  csitea.net that is Csitea's own workspace, so the owner sees what the sales
  channel costs.

## 8. Selling a workspace (R2)

- The buyer uses the existing buy-a-tenant checkout (`internal/payments`,
  specs 006 / 009) with a new plan kind `metered`: no seat price; a prepaid
  top-up (Q-M2) that `token_budgets` draws down.
- The paid webhook, as today, makes the tenant and its owner; it also writes
  the workspace's `price_plans` row and its first budget.
- At zero balance agent turns are refused with "credit used up, top up here";
  the workspace itself stays readable.
- **Monthly invoice** per workspace by a named action
  (`do_spl_sales_invoice`, dry run by default): lines = `usage_events` summed
  by kind times unit cost, the margin as its own line, the UTC calendar month
  (the 006 period). Charged through the rails of Q-M2.

## 9. What the catalogue shows

- The catalogue lists what Csitea sells: the workspace plan(s), the services
  the sales agent can talk about, and how the price is built (usage + margin),
  not fixed prices. Entry shape: name, short description, what is metered,
  margin plan, delivery note.
- Shown to signed-out visitors as spec 116 public pages: the front page
  (`/login`), the blog, and a new `/services` route, prerendered, lazy (out of
  the 160 KB initial chunk), no hub call for a signed-out visitor.

## 10. Later: the paid private channel (L1)

Kept buildable, not built in v1: the owner of a workspace marks a created
channel for sale; checkout line item `channel_seat`; the paid webhook adds the
buyer as `channel_guest` with a `channel_humans` row, idempotent on the
checkout id, `access_until` stamped. The same role, policy (4.2) and ledger
(7) serve it.

## 11. Panel and consensus

Seats, each signed against 6eded1d95:

| seat | lane | file | commits |
|---|---|---|---|
| s121-claude (editor) | c-801 | [reviews/s121-claude.md](reviews/s121-claude.md) | 04311e1f3 |
| s121-claude-2 | c-802 | [reviews/s121-claude-2.md](reviews/s121-claude-2.md) | 84d9caf49 |
| s121-agy | a-804 | [reviews/s121-agy.md](reviews/s121-agy.md) | c3a1a5d2f, 7caf8171d, 467dae81b |
| s121-mistral | m-803 | [reviews/s121-mistral.md](reviews/s121-mistral.md) | 7ee0e50dd |

What the panel agreed (4 of 4 seats):

- The draft's isolation claim was not true of the code: RLS is per tenant
  only. A new channel-scope policy and its negative test are the core of v1.
- The embed is an iframe, served by the hub with per-customer
  `frame-ancestors`; the static WUI cannot do it.
- Payments exist; token metering does not and is the critical path for the
  owner's price rule.
- csi-rel stays context only; the draft's "interact with the data models
  established there" is dropped.
- Price = metered cost + margin, the margin a setting; tokens counted per
  workspace with channel and agent detail.

Where the seats differed, and what the fold took:

| point | seats | fold |
|---|---|---|
| visitor token storage | claude: partitioned cookie; claude-2: Bearer in iframe storage; agy: HttpOnly cookie; mistral: `SameSite=Lax` cookie | Bearer (4.1): a `Lax` cookie is never sent in a third-party iframe (section 2), and Bearer needs no third-party-cookie rule, Safari included |
| RLS form | claude: replace tenant_scope; claude-2: restrictive policy; agy: `visitor_id` column + JWT claim GUC | restrictive (4.2): narrows, never widens; no new column on `messages` |
| rate-limit store | claude, claude-2: `quota_counts`; agy, mistral: Redis | `quota_counts` (6): no Redis in the estate |
| bot challenge | claude, claude-2: self-hosted proof-of-work; agy, mistral: hosted invisible challenge | owner question Q-T1 (2 to 2) |
| repeat offenders | mistral: challenge on every post after 3 limit hits in 24 h, IP ban 24 h after 5 | taken (6) |
| new-device recovery | claude, claude-2: optional e-mail; mistral: e-mail or phone | e-mail only (4.1): a phone adds an SMS processor and more personal data |
| embed CORS | claude, claude-2: none needed; mistral, the draft: allow csitea.net | none (5): the iframe calls from our own origin |
| embed token for a business user | claude, claude-2: 5 min JWT minted by the customer's server; mistral: 30-day JWT in the iframe query string | 5 min JWT (5): a query-string token lands in logs and `Referer`, and a long one outlives a lapsed subscription |
| loader source | claude, claude-2: this repo; mistral: csi-web | this repo (5): every customer gets fixes without a copy; csi-web holds only the tag |
| order writes | mistral: mark paid in csi-rel's `orders` table; agy: product references mapped from csi-rel | neither: csi-rel is never called or written; the hub's own copied `payments` (8) |
| each business customer = own workspace | all four | taken (4.2) |
| who answers first | claude, agy: agent first; claude-2: human approves agent drafts in phase 1 | owner question Q-V1 |
| margin shape | agy, claude-2: one fixed %; claude: per plan | schema per plan, start value Q-M1 |
| payment rail | agy: card; claude: card + invoice for business; claude-2: invoice for business, card for single buyers | owner question Q-M2 |
| retention | claude: 90 days; claude-2: 30 days | 30 days, owner may keep a lead (4.4) |

Signatures on rc1 5385b4665 (dispatch-e001c851, 2026-10-10):

| who | answer | msg |
|---|---|---|
| s121-claude (editor, c-801) | signed (author of the fold) | — |
| s121-claude-2 (c-802) | signed 5385b4665, with the Safari note now in 4.1 | 2dd8288a |
| s121-mistral (m-803) | signed 5385b4665 | 2d0d8d96 |
| s121-agy (a-804) | signed 5385b4665 | 791a430c |
| drafter (a-800) | signed 5385b4665 | 18debe23 |

v1.0 differs from rc1 only in this table, the version line and the Safari
note in 4.1.

## 12. Owner questions

Answer "all recommended" to take every recommendation, or name the ones you
change. Settled, not asked again: what v1 sells (97b94903: whole workspaces
only), the paid private channel (1a374b78, now later), price = cost + margin
(294eb431), metering per workspace (0137a1bd).

### 12.1 Money

- **Q-M1 The margin. Recommended: A.** A: one percentage on metered cost for
  every workspace, its value yours. B: a percentage per plan. (The setting is
  per plan from day one, so A -> B later needs no migration.)
- **Q-M2 How customers pay. Recommended: C.** A: prepaid balance by card,
  work stops at zero. B: monthly invoice. C: A for everyone, B only for
  businesses you approve.
- **Q-M3 Which model access serves paying customers. Recommended: A.**
  A: customer-serving agents on pay-per-token API keys (cost per token exact);
  our own work stays on subscriptions. B: everything on subscriptions, priced
  at the model's list API price. (Reselling at cost needs a real cost per
  token, and a subscription's terms may not allow serving third parties.)

### 12.2 Visitors

- **Q-V1 Who answers a visitor first. Recommended: A** (claude, agy;
  claude-2 recommends B; mistral did not say). A: the sales agent, handing over to you when unsure.
  B: phase 1 a human approves each agent draft, then A. C: you only.
- **Q-V2 Which agents read a visitor's channel. Recommended: A** (claude,
  claude-2, agy; mistral did not say).
  A: one dedicated sales agent per selling workspace, nothing else. B: any
  agent you seat in it.

### 12.3 Tech

- **Q-T1 Bot check on the first question. Recommended: A** (the panel split
  2 to 2: claude seats A, agy and mistral B; the editor's tie-break is A
  because B sends every visitor to a third party). A: self-hosted proof-of-work, no third party sees the
  visitor. B: a hosted invisible challenge service.
