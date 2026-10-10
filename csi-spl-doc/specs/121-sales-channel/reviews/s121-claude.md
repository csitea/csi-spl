signed against 6eded1d95

# Spec 121 review: seat s121-claude (EDITOR), lane c-801

Reviewed `csi-spl-doc/specs/121-sales-channel/spec.md` at `6eded1d95` (89
lines), against trunk code at the same sha. Every claim about the code below
carries the command that shows it. Brief: `20261010-s121-panel-claude.md`, with
addendum 4 (owner msg 0ee6d8af, the B2B iframe embed) and two owner answers
that arrived during the review, relayed by c-001@sat:

- msg 1a374b78 (csitea topic ebfb10dc), verbatim: "Yeah, let's pick A." It
  picks **A, the paid private channel**: a buyer gets access to one channel
  inside a workspace and sees nothing else there. B (paid workspace) is not
  chosen; subscriptions (C) come later and are out of scope. Settled, not an
  owner question any more.
- msg 294eb431 (same topic), verbatim: "And the way to sell it will be based
  on cloud expenses, token usage, and then a margin above a pure technical
  one." Price = metered cost (cloud + LLM tokens) + a margin. It replaces the
  draft's question 3 ("services and prices"); the new question is the margin.
- msg 1f03918f (same topic, relayed by c-002), verbatim: "We need to gain the
  technical capability to somehow count the tokens and the token limits, and
  what our costs per token are, so that we are just resellers of cloud
  resource token usage. Of course, we provide the UI service, but we will just
  gain a margin on top of all of those. The justification for the margin is
  the usage of the UI of our systems. And, of course, the usage of the whole
  thing combined". Metering is in scope: tokens counted per customer, channel
  and agent; token limits enforced; our cost per token known per model and
  provider.

## 1. Section by section

| § | verdict | one line |
|---|---|---|
| 1 owner's words | change | add 0ee6d8af (B2B embed), 1a374b78 (paid private channel) and 294eb431 (cost + margin); keep the misspellings verbatim, but state once that "spoolhop.ai" = spool-hub.ai and "SiteNet"/"citia.net" = Csitea.net |
| 2 intro | change | the scope is now a B2B embed with csitea.net as customer #1, plus the paid private channel; say so in the first paragraph |
| 2.1 embed | change | the frame-ancestors header is served by the WUI hosting, not the hub: today `grep -c "frame-ancestors 'none'" csi-spl-wui/nuxt.config.ts csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` -> 2 and 1, and `X-Frame-Options: DENY` too. The embed needs its own route with its own per-customer header (proposal 3.4); one static `https://csitea.net` literal also breaks the "no literal host" rule |
| 2.2 isolation | change | wrong about today: RLS is tenant-scoped only (`0014_tenant_rls.sql`, policy `tenant_id = current_setting('app.tenant_id')`); channel membership (`0028_channel_humans.sql`) is enforced in Go, not by a policy. "RLS verifies the visitor's session id" is new DDL, not reuse (proposal 3.2) |
| 2.3 abuse | change | right pattern, but name the real parts: `quota_counts` (rdb 0127, per-human counters that survive a redeploy) and the demo caps in `internal/config/config.go` (`DemoPostsPerMinute`, `DemoMaxStay`); add per-IP and per-size limits and a bot gate (proposal 3.3) |
| 2.4 staff visibility | agree | add: a visitor channel is never in lobby/tasks/alerts; the owner sees it in a "Customers" rail group |
| 3 catalogue | change | the owner set the price rule (cost + margin), so a catalogue entry carries a margin plan, not a price; fixed-price services stay possible only as an owner question (Q3 below) |
| 4 where it shows | agree | spec 116's public pages; add that `/services` is static (prerendered), no hub call for a signed-out visitor |
| 5 order/payment | change | the hub already has the rails: `internal/payments` (a copy of csi-rel's code, `grep -n "never imports it" internal/payments/config.go` -> 1), Stripe card + optional PayPal + fake-pay. The new parts are the channel SKU and the metered invoice (proposals 3.6, 3.7) |
| 6 csi-rel reuse | change | "interact with the data models established there" contradicts the hub's rule: csi-rel is read-only reference, never imported or called. Reword to "the hub's own `payments` package, already copied from csi-rel" |
| 7 owner questions | change | Q3 is replaced by the margin question; Q4 is half-answered by the code (Stripe is live); the single-channel question is settled by 1a374b78. New questions below (section 4) |
| — missing | missing | identity for an anonymous visitor; RLS at channel level; the embed's auth; metering; the channel-guest role; tests; rollout order; data retention (sections 3.1 to 3.9) |

## 2. The shape I propose

One mechanism serves all three owner asks: a **channel guest**, a HUM row that
is a member of exactly one channel of one workspace and of nothing else.

- An **anonymous visitor** on csitea.net is a channel guest made on the first
  question, in its own new channel of the `csitea` workspace.
- A **paying buyer** (1a374b78, A) is a channel guest added to the channel
  they paid for, in any workspace.
- A **B2B customer** (0ee6d8af) is a workspace; its own visitors become
  channel guests of that workspace through its embed.

The same role, the same RLS policy and the same tests cover all three; the
only differences are how the guest is made (first question, paid webhook,
customer's signed token) and who pays (Csitea, the buyer, the B2B customer).

## 3. Proposals for what is missing (each buildable)

### 3.1 Anonymous-visitor identity

- First question -> the hub makes a HUM row with `kind = 'channel_guest'` (no
  email, no password, no identity provider), a tenant membership with the new
  role `channel_guest`, one new channel, and one `channel_humans` row.
- The browser holds a **guest token**: 32 random bytes, stored hashed on the
  hub (sha256, as the existing session tokens), sent as a cookie on the embed
  origin with `SameSite=None; Secure; HttpOnly; Partitioned` (CHIPS). Today's
  session cookie is `SameSite=Lax` (`grep -c SameSiteLaxMode
  internal/auth/handler.go` -> 3), which a browser never sends inside a
  third-party iframe, so the embed cannot reuse it.
- Lifetime: **30 days sliding**, renewed on each visit; the channel and its
  messages outlive the token (retention, 3.9).
- Returning visitor, same browser and same embedding site: the partitioned
  cookie finds the channel. **New device or cleared cookies**: the visitor
  gives an email ("send me a link to continue"), the hub mails a one-time
  resume link (15 min, single use) that binds a new token to the same guest.
  Without an email the channel is unreachable from the new device; the owner
  still sees it.
- The guest may later be upgraded to a real account (a buyer), keeping the
  channel: the owner or the paid webhook flips `kind`, never a new HUM.

### 3.2 Per-visitor isolation at RLS level

- New GUC `app.channel_scope`, set transaction-local by a new
  `store.inChannel(tenant, channel)` (the same form as `inTenant`). A guest's
  request runs ONLY under `inChannel`; the hub never calls `inTenant` for a
  `channel_guest`.
- New policy on `messages`, `channels`, `channel_humans`, reactions,
  revisions, files and every table a channel reader touches (the list is
  `git grep -l "channel" csi-spl-rdb/src/sql` filtered by hand, and the spec
  lists the tables it adds the policy to):
  `USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '') AND
  (NULLIF(current_setting('app.channel_scope', true), '') IS NULL OR
  channel = current_setting('app.channel_scope', true)))`
  in the 0021 NULLIF fail-closed form. Policies are permissive and OR'd, so
  this one REPLACES `tenant_scope` on those tables instead of being added
  beside it (else the tenant policy alone admits the row).
- The three default channels (lobby, tasks, alerts) are tenant-wide by owner
  rule (0028): a guest never sees them, because the policy above admits only
  the scoped channel, and DMs (`channel IS NULL`) are not admitted either.
- The owner (biz_owner) and the agents the owner seats read all channels
  under `inTenant`, as today.
- **RLS-negative test** (Postgres, `PRE_PUSH_TIER=full`): two guests G1, G2
  in the same tenant; under `inChannel(t, c1)` a raw `SELECT count(*) FROM
  messages WHERE channel = 'c2'` -> 0, the lobby -> 0, a DM -> 0, an INSERT
  into c2 -> refused by WITH CHECK; the same statements under `inTenant(t)`
  -> the real counts (the control). Plus a hub-level test: G1's token on
  G2's thread id -> 404, never 403 (no existence leak).

### 3.3 Abuse, spam, rate limits, bots

All counters in `quota_counts` (rdb 0127), so a hub redeploy resets none:

| limit | default | why |
|---|---|---|
| new guests per IP | 5 per hour, 20 per day | stops channel farming |
| posts per guest | 6 per minute, 60 per day | as the demo caps |
| message size | 4 KB, no file upload for an anonymous guest | cost and malware |
| agent turns per guest | 20 per day (as demo T013) | caps our token spend on a stranger |
| open anonymous guests per workspace | 200 | caps the blast radius |

- Bot gate: a proof-of-work or a privacy-first challenge on the FIRST
  question only (no tracking cookie, no third-party script on Csitea's own
  page; which one is an owner question, Q7). A honeypot field rejects the
  dumb bots for free.
- Every limit is cnf per workspace (`env.hub.embed.*` in
  `csi-spl-cnf/csi-spl/<env>.env.yaml`), and a refused unit writes nothing.
- The owner can block a guest (and its IP /24 for 24 h) from the channel
  header; blocked = the guest token is revoked, the channel stays readable to
  the owner.

### 3.4 What a customer embeds, CSP and CORS, and what lives where

- **An iframe, not a script that renders the chat in the host page.** The
  host page then never sees a message and our DOM never runs in their
  origin. The customer pastes one small script tag that only creates the
  iframe and the launcher button (no data access); csitea.net is the first
  user of that same snippet.
- Route: `/embed/<embed-id>` on the WUI hosting, a minimal Nuxt layout (no
  rail, no topics, one channel). Its own response headers:
  `Content-Security-Policy: frame-ancestors <the customer's allowed origins>`;
  every other route keeps `frame-ancestors 'none'` and `X-Frame-Options:
  DENY`. Firebase Hosting serves static headers per glob, so per-customer
  origins need either one rendered header block per customer (rebuilt and
  deployed on change) or the embed page served by the hub (Cloud Run), which
  can answer the header per request from the database. I recommend **the hub
  serves `/embed/*`**: a new customer is a database row, not a WUI deploy.
- CORS: the iframe calls the hub from the WUI origin, as every page does
  today, so the existing allow-list holds; the CUSTOMER's origin never calls
  the hub directly. The `postMessage` between the snippet and the iframe
  checks `event.origin` against the embed's allowed origins.
- **csi-web repo**: only the snippet tag and the launcher style on
  csitea.net. **This repo**: the embed route, the guest auth, RLS, the
  embed admin page, metering, billing. The snippet's source lives here and is
  served from the WUI host, so every customer gets fixes without a copy.
- Embedded user auth for a B2B customer whose users are already signed in on
  their site: the customer's server signs a short JWT (5 min, `sub` = their
  user id, `aud` = the embed id) with a per-embed key the customer generated
  in the embed admin page; the hub maps (embed, sub) to one channel guest.
  Without a JWT, the visitor is anonymous (3.1). The key is the customer's;
  it never enters this repo, terraform or a log.

### 3.5 No personal data in tenant workspaces; where questions land

- A guest exists only in its one channel: it is not in the member list, not
  in lobby fan-out, not in search for other members, not in the public
  dataset export (spec 091 grants on `messages`; add `channel_guest` channels
  to the export's exclusion and test it), not in RUM.
- An email given for the resume link (3.1) is stored hub-wide like
  `human_identities`, never in a tenant table, and is shown only to the
  workspace owner.
- Csitea staff: each new guest channel posts one line in a private
  `sales-triage` channel of `csitea` ("new visitor question in #v-<short>"),
  no message body, so a triage reader learns that a question exists without
  reading it unless seated in that channel.

### 3.6 The paid private channel (owner 1a374b78, A)

- A workspace owner marks a created channel **for sale**: a price plan (3.7)
  and a short public description.
- Checkout goes through `internal/payments` with a new SKU kind `channel`
  (line items as `payment_checkouts` already carries seats, rdb 0016). The
  paid webhook, as operator, in one transaction: makes or reuses the buyer's
  HUM, gives it `channel_guest` in that tenant, writes the `channel_humans`
  row, and stamps `access_until` (`internal/store/access_until.go` exists for
  timed access).
- The buyer then signs in normally (Google, password) and sees exactly one
  workspace with exactly one channel, under `inChannel` (3.2).
- Refund or lapse -> the row goes, the guest is out on the next request.

### 3.7 Metering and billing (owner 294eb431)

What exists: nothing that counts LLM tokens per channel (`git grep -n -i
"input_tokens" -- csi-spl-api csi-spl-rdb` -> 0 lines), and the per-env SAs
cannot read GCP billing (Cloud Billing API disabled). So:

- **Token cost**: every agent turn in a metered channel reports its usage
  (input, output, cache read, cache write tokens and the model) with the
  reply; the box reads it from the agent's own turn record. The hub writes one
  `usage_events` row (tenant, channel, guest, agent, model, tokens, ts) and
  prices it with a `model_prices` table (per million tokens, per model,
  effective-dated, cnf-loaded). Caveat for the spec: agents on a flat
  subscription have no per-token invoice, so the price is the list API price
  of that model, a notional cost (owner question Q6).
- **Token limits** (1f03918f): a `token_budgets` row per customer and per
  channel (tokens per day and per month, and a credit balance). The hub
  checks it BEFORE it hands a turn to an agent, as `quota_counts` takes a
  unit (refused = nothing built), and the reply reports the actual use after
  the turn. A turn may overrun the last few tokens of a budget; the next one
  is refused. The owner sees per customer: used, limit, cost, price.
- **Cost per token** (1f03918f): `model_prices` keyed by (provider, model,
  token kind), effective-dated, so a provider's price change is a new row and
  old invoices keep the old price.
- **Cloud cost**: allocated, not measured. A monthly figure per env (from the
  billing export, read by the owner or a billing-reader SA the owner
  creates) split across channels by their share of a driver: messages + agent
  seconds. The spec states the driver and keeps it one function, so it can
  change.
- **Price** = (token cost + allocated cloud cost) x (1 + margin). The margin
  is a setting: `margin_pct` on a `price_plans` row (a workspace default plus
  an optional per-channel override), never a constant in Go.
- **Invoice**: monthly per buyer / B2B customer, from `usage_events` summed
  in the UTC calendar month (the 006 period), with a prepaid credit option:
  the buyer tops up through the existing rails, usage draws it down, the
  agent stops answering at zero ("credit used up, top up here"). Prepaid
  keeps us from carrying an anonymous stranger's debt.
- The csitea.net anonymous visitors are not billed; their usage is metered
  all the same and charged to Csitea's own workspace, so the owner sees what
  the sales channel costs.

### 3.8 Tests the build must carry

- RLS-negative + control (3.2), on Postgres.
- Embed header: `/embed/<id>` answers `frame-ancestors` with exactly that
  embed's origins; `/` still `'none'` (extend `csp-policy.test.mjs`).
- Limits: the 6th guest from one IP in an hour is refused and writes no row.
- Token limit: a customer at its daily budget -> the next turn is refused
  before any agent is called, and the visitor sees why.
- Metering: a fake turn of N tokens -> one `usage_events` row -> the invoice
  line = N x price x (1 + margin), to the cent.
- Paid channel: fake-pay webhook -> buyer sees 1 channel, lobby 404.

### 3.9 Rollout and retention

- Order: DDL (role, GUC policies) -> hub with `inChannel` behind a cnf flag
  `env.hub.embed.enabled` (off) -> csitea.net embed on dev -> prd -> paid
  channel -> B2B embeds.
- Retention: a guest channel with no message for 90 days is archived; its
  guest token is revoked at 30 days idle. Messages follow the hub's existing
  retention.

## 4. Owner questions (options + my recommendation; not decided here)

1. **Who answers a visitor first?** A: an agent, escalating to the owner when
   unsure. B: only a human. C: agent and human both from the start.
   **Rec: A**, with the escalation posting in `sales-triage`.
2. **Which agents may read a visitor's channel?** A: one dedicated sales
   agent per workspace. B: any agent the owner seats in it. **Rec: A** as the
   default, the owner may still seat another by hand (B stays possible).
3. **The margin (replaces "services and prices", owner 294eb431).**
   A: one fixed % for everything (e.g. 30 %). B: a % per price plan, with a
   workspace default. C: B plus a minimum monthly fee per paid channel.
   **Rec: B**: one number to start, room for a plan later, no new code then.
   The value itself is the owner's.
4. **Payment provider.** The hub already runs Stripe (card) with PayPal off
   (`internal/payments/config.go`). A: Stripe only. B: Stripe + PayPal.
   C: bank transfer / manual invoice for B2B. **Rec: A** now, C added for B2B
   customers who need an invoice.
5. **Billing mode.** A: prepaid credit, agent stops at zero. B: postpaid
   monthly invoice. **Rec: A** for single buyers, B only for B2B customers
   with a contract.
6. **Token cost basis for agents on a flat subscription.** A: the model's
   list API price. B: the subscription fee split by usage share. **Rec: A**:
   stable, auditable, independent of how many seats we run.
7. **Bot gate on the first question.** A: a self-hosted proof-of-work. B: a
   third-party challenge widget. **Rec: A**: no third-party script and no
   tracking on the customer's page.
8. **Does an anonymous visitor need an email to continue on another
   device?** A: optional, offered after the first answer. B: required before
   the first question. **Rec: A**: the owner asked for "public (aka
   unauthenticated)" questions.

Settled, not asked: the single paid channel (1a374b78, A).

Open elsewhere, not asked again here: selling access to whole workspaces
(owner topic d515fcdb, msg 055ae092, verbatim: "Let's discuss the
possibility for Cydia to be able to sell access to different workspaces in
the Spoolhub AI."; c-002 posted A seat / B own workspace / C both). The
channel-guest shape (section 2) does not block any of the three: a workspace
seat is today's tenant membership sold on the same rails and metered by the
same `usage_events`. Owner msg 0137a1bd (same topic), verbatim: "Same as
the previous discussion for the selling of private channels, we should also
discuss the possibility of counting the tokens for the usage of the
workspaces as well." Metering in 3.7 already keys every `usage_events` row
by tenant, so a per-workspace total is a sum, and a `token_budgets` row may
name a workspace with no channel: one table, three scopes (workspace,
channel, guest).
