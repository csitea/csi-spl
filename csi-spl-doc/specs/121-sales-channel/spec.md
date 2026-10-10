# 121 Sales channel: selling Csitea.net services on spool-hub.ai

Version **v1.4** (2026-10-10): folded the owner's answers to Q-C1 and Q-C2 (msg 31913cc1, csitea ebfb10dc).
v1.3 (2026-10-10): the live credits counter (section 8.1, R9), from the owner's posts in csitea topic ebfb10dc (msgs 057db9f5 and 259e8711), written by c-876. 057db9f5 restates the price of section 7 and the top-up of section 8 (R6, R7) and confirms them; nothing there changes. New: where a member sees the balance, how often it refreshes, what it is computed from, its warning threshold, its cost in the first-paint bundle, its tests, and the owner's rule that the counter informs and never nudges spend. No owner question is open.

v1.2 (2026-10-10): the owner's answers to the two questions v1.1
left open (Q-N1 41925444, Q-N2 c2a30422) and the sales agent's model scope
(41925444), folded in by c-814 (section 1.4, 12.4). No owner question is
open.

v1.1 (4772552ba, 2026-10-10): the owner's answers to every section 12
question, and the price, fixed-cost and scaling rules given in the same
topic, folded in by the editor lane c-814 (section 1.4). No seat signed
v1.1 or v1.2: the 121 panel seats and the drafter had retired; the dispatch
holder accepted v1.1 without a fresh panel (c-002, msg 925bcc60: it folds
owner answers verbatim, no new design).

v1.0 (ec8defa54) was signed by all four seats and the drafter on rc1
5385b4665 (section 11): the panel fold by the editor (seat s121-claude,
c-801) of a-800's draft (6eded1d95, 89 lines). The seat files are under
[reviews/](reviews/); section 11 records what each one changed. Five owner
answers arrived during the review and are folded in (section 1.2). Section
12 held the questions then open; c-002 posted them to the owner as one
blocker (csitea e001c851, msg 5c92ad8c), and section 12 now records the
answers and what is still open.

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

| R6 | price = (measured tokens x 1.20 + other own cost + a slice of the fixed hub cost) + 29%, one rate for every workspace | cd2d25e3, acaed9ef, 55309d31, f5c0e3c7, 9e0c0dba |
| R7 | customers top up a balance by card; work stops at zero; no invoice | e38f9953 |
| R8 | above 80% capacity, hardware is added (spec 122) | 72b5ed23 |
| R9 | a live credits counter: tokens and money, near real time, refreshed once a minute; it informs and never nudges spend (section 8.1) | 057db9f5, 259e8711 |

The csitea.net pop-up (R1) is not a sale: it is customer #1 of the embed (R3),
with Csitea's own workspace paying for its usage.

### 1.4 Owner answers to section 12 and the price (csitea topic e001c851, HUM-10, verbatim)

Each answer, then the reading c-002 posted for it in the same topic. The
owner corrected none of these readings (topic read 2026-10-10 after msg
a798a19b, the owner's last post).

| msg | the owner's words | reading posted by c-002 | folded into |
|---|---|---|---|
| d515fcdb/97b94903 | "For now, the whole workspace only will be for sale." | v1 sells whole workspaces; paid channels later | R2, L1 (already in v1.0) |
| cd2d25e3 | "Yeah, it should be based on the margin and 29% on top of it." | Q-M1 = A, one rate for all: measured cost + 29% | 7, 12.1 |
| acaed9ef | "V1a, v2a, m1a" | Q-V1 = A, Q-V2 = A, Q-M1 = A (29%) | 4.3, 12.1, 12.2 |
| 55309d31 | "It is a bit tricky because we need to calculate how much the running of the spool hub costs as well, and how much capacity a single workspace channel would take. A gate to justify some slice for the whole spool hub infra as a fixed cost for the price of a workspace and a private channel" | a slice of the fixed hub cost in every price; no price until capacity is measured (post 4e2e378b) | 7 |
| b6a56949 | "The production environment and the hosts on which the workspace runs" | the fixed cost = prd + the hosts the workspace runs on; not dev, the satellite only if it hosts (spec 122 Q-5) | 7 |
| 2d9490e7 | "S4b, s5,s6a, q6yes, q7 yes," | spec 122 Q-6 = A: the slice is the fixed cost divided by the most workspaces the hub can hold (W_max, measured) | 7 |
| f5c0e3c7 | "Yeah, we need to have some kind of margin error for the tokens as well, because my gut feeling is that there should be some kind of +10%, +20% overall on the token count (because of how the spool hub works and overall, not being able to measure the total amount of tokens)." | a buffer on the token count, A or B asked (post 1099c002) | 7 |
| 9e0c0dba | "A" | buffer A: +20% at launch, lowered to the measured gap vs the provider's numbers | 7 |
| e38f9953 | "M2A" | Q-M2 = A: card top-up balance for everyone, work stops at zero, no invoice | 8, 12.1 |
| 8bb20332 | "M3 a" | Q-M3 = A: pay-per-token API keys for customer-facing agents; our own work stays on subscriptions | 7, 12.1 |
| e95a0695 | "Yes" | Q-T1 = A: our own bot check, no outside service (with spec 122 Q-2 = C); posted for correction as 51f088b6, none came | 6, 12.3 |
| 72b5ed23 | "The idea is that the service should be scalable. People are basically plugging in their credit cards, and as soon as we find out that we have more than 80% capacity filled in, we will spawn new hardware resources and we will add them to the spawn hub." | above 80% capacity, add hardware; its own spec | 7.1, [spec 122](../122-capacity-scale-out/spec.md) |

Spoken names: "spawn hub" = the spool hub.

Two later answers, to the questions v1.1 left open (12.4). Quoted as
relayed verbatim by the dispatch holder c-002@sat (spool msgs dfb256af and
707f501b, task a21617ab), who posted each reading back to the owner for
correction; this lane's box does not hold these two messages, so they
were not re-read from the hub here.

| msg | the owner's words | reading posted by c-002 | folded into |
|---|---|---|---|
| 41925444 | "Yeah, there should be some kind of cap. €5 seems okay. Plus, the scope of the tokens should be pretty constrained, aka we should teach the most cheap Mistral or a white AI agent on the stuff we are selling to be able to answer, and that's it." | Q-N1 = A: EUR 5 per day per embed for unpaid visitors. New: the sales agent runs on the cheapest model (the smallest Mistral or a similar small model; "white" read as dictation for "light"), knows only what we sell and declines anything else | 4.3, 6, 12.4 |
| c2a30422 | "Only the admin of the spool" | Q-N2 = B, narrowed: only the Spool Hub admin changes the +20% token buffer; the monthly action measures the gap and proposes, never applies | 7, 12.4 |

The credits counter (csitea topic ebfb10dc, HUM-10). 057db9f5 is quoted
from this lane's brief; 259e8711 as relayed verbatim by c-002@sat (spool
msg b5dd540b); neither was re-read from the hub here.

| msg | the owner's words | reading | folded into |
|---|---|---|---|
| 057db9f5 | "Ideally, we would be charging customers for the amount of money spent, based on the mixture of agents and everything else they have been using. That would be the ideal scenario, and they will have a once-a-minute counter which resets and shows their credits." | the first sentence confirms R6 and R7 as written; new: a counter of the credits, once a minute ("resets" read as "refreshes", Q-C1 = A, msg 31913cc1) | R9, 8.1, 12.5 |
| 259e8711 | "Yeah, the counter would be nice to be probably after one clicks the avatar, or why not even on the front page? I'm not sure what the best practice is for that. I don't want to trick the customers into consuming too many tokens. I want them to have a near-real-time understanding of what they are using and how many tokens they are consuming." | placement: top bar on every workspace page, the detail one click away, linked from the avatar menu (Q-C2 = A, msg 31913cc1); the rule of 8.1: transparency, never nudging spend | R9, 8.1, 12.5 |

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
3. **Agent answers and metering** (R4, R5): the sales agent (Q-V1 = A, Q-V2
   = A) and the `usage_events` ledger, model prices, token budgets.
4. **Workspace sale on metered pricing** (R2, R4, R6, R7): the existing
   buy-a-tenant checkout sells a workspace whose balance is drawn down by the
   price of 7; card top-up only. It opens only when spec 122's pricing gate
   holds (7.1).
5. **Fixed-cost slice** (R6) from spec 122's measurements; a second
   embedding customer. (v1.0's monthly invoice is dropped: M2 = A,
   e38f9953.)

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
- Who answers (Q-V1 = A, acaed9ef): the sales agent answers a visitor
  first and hands over to the owner when it is unsure.
- Who reads (Q-V2 = A, acaed9ef): one dedicated sales agent per selling
  workspace reads its visitor channels, and no other agent does.
- That agent runs on a pay-per-token API key (Q-M3 = A, 8bb20332), so each
  of its tokens has an exact cost (7).
- Its model and scope (41925444): the cheapest model that can do the job,
  the smallest Mistral or a similar small model, taught only what Csitea
  sells (the "sales facts" doc above). It answers questions about those
  services and declines anything else, handing over as Q-V1 says.

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
| token spend of unpaid traffic per embed | EUR 5 per day (Q-N1 = A, 41925444), cnf | 429, owner alerted |

- Bot gate on the FIRST post only (not the page load): a challenge the hub
  verifies server-side, plus a honeypot field. The challenge is our own
  check, a self-hosted proof-of-work: no outside service sees the visitor
  (Q-T1 = A, e95a0695 as read in 51f088b6).
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
- **Which model access**: agents that serve paying customers or visitors
  run on pay-per-token API keys, so the cost per token is exact; our own
  work stays on subscriptions (Q-M3 = A, 8bb20332).
- **Fixed cost, a slice in every price** (55309d31): the always-on part of
  the estate is charged to every workspace as a fixed-cost slice, its own
  `cloud_share` line.
  - Which cost counts (b6a56949, spec 122 Q-5): the prd environment (hub,
    database, hosting, network) plus the hosts the workspace runs on. Not
    dev; the satellite only if it hosts customer workspaces. With spec 122
    Q-2 = C (a shared pool of boxes), a box's cost is split among the
    workspaces on it.
  - The divisor (2d9490e7, spec 122 Q-6 = A): slice = the month's fixed
    cost / W_max, the most workspaces the hub can hold, as spec 122
    measures it. Not the active count, so an early customer's price does
    not carry an idle hub.
  - The source of the cost and of W_max, and the measurement steps, live in
    [spec 122](../122-capacity-scale-out/spec.md) section 9; this spec only
    uses them. The slice replaces v1.0's `agent_seconds` split for the fixed
    part, so one cost is never charged twice.
- **Token buffer** (f5c0e3c7, pick A 9e0c0dba): metered token counts are
  priced at x 1.20 at launch, for the tokens we cannot measure. The buffer
  is a setting, lowered to the measured gap between our count and the
  provider's numbers once spec 122's token-gap measurement (its M4) exists.
  Only the Spool Hub admin changes it (Q-N2, c2a30422): the monthly named
  action measures the gap and proposes the new value; it never applies it.
- **Price**, one formula for every workspace (posts 4e2e378b, 1099c002;
  margin cd2d25e3, acaed9ef):

  `price = (measured tokens x 1.20 + other own cost + fixed-cost slice) + 29%`

  - "other own cost": agent seats and storage the workspace uses
    (`agent_seconds`, `storage_bytes`).
  - The margin is 29%, one rate for all (Q-M1 = A). It stays a setting,
    `price_plans.margin_pct` = 29; the schema still allows a per-plan value
    later without a migration, but v1 sets none.
- **No price before the measurements** (55309d31, post 4e2e378b): no price
  is published, on `/services` (9) or at checkout (8), until spec 122's
  pricing gate holds (its section 9: a closed month of billing data, the
  capacity measurements, the token gap). Until then the checkout answers
  409 `pricing_not_ready`.
- **Unpaid visitors** are metered to the workspace that embeds them; for
  csitea.net that is Csitea's own workspace, so the owner sees what the sales
  channel costs.

### 7.1 Capacity: above 80%, add hardware (R8)

The owner (72b5ed23): above 80% capacity, new hardware is started and joins
the hub. This spec sets no capacity rule of its own: what "capacity"
measures, who starts a box, the money guard and when a box is removed are
[spec 122](../122-capacity-scale-out/spec.md). Selling a workspace (8)
depends on it only through the pricing gate above.

## 8. Selling a workspace (R2)

- The buyer uses the existing buy-a-tenant checkout (`internal/payments`,
  specs 006 / 009) with a new plan kind `metered`: no seat price; a prepaid
  card top-up that `token_budgets` draws down at the price of 7 (Q-M2 = A,
  e38f9953: the same for every customer, no invoice).
- The paid webhook, as today, makes the tenant and its owner; it also writes
  the workspace's `price_plans` row and its first budget.
- At zero balance agent turns are refused with "credit used up, top up here";
  the workspace itself stays readable.
- **No monthly invoice** (Q-M2 = A, e38f9953): v1.0's
  `do_spl_sales_invoice` is not built. The draw-down is the bill: every
  `usage_events` row already carries its unit cost, so what a balance was
  spent on is a `GROUP BY` of the ledger.

### 8.1 The credits counter (R9)

**The rule** (259e8711): the counter informs and never nudges spend. It
shows tokens as well as money, near real time. No dark patterns: the balance
is never hidden or rounded up; no auto top-up by default (an opt-in with its
cap shown, off for every new workspace); the top-up form preselects the
smallest amount; the counter shows EUR, never an invented credit unit; and
no warning colour appears before the threshold below.

- **Where**: on every workspace page, in the top bar just before the avatar (`TopBar.vue`, beside the hours timer), only in a workspace on the `metered` plan. The chip shows the balance in EUR; a click opens the detail: tokens in and out and their cost since the last top-up and today, the turns still pending, and the price line of 7. The avatar menu links the same detail. On a phone (<= 820 px) the chip shows the balance only (Q-C2 = A, msg 31913cc1).
- **Who** (`sed -n 133,148p csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go`,
  `sed -n 58p csi-spl-rdb/src/sql/postgres/spool-hub/0021_tenant_rbac.sql`):
  every member role of the workspace sees the balance and its own spend;
  `demo_user` and `channel_guest` never see it. The spend per member needs
  `costs.read` (`biz_owner`, `admin`, rdb 0166). Top-up needs
  `billing.manage`, which only `biz_owner` holds (0021: the admin runs the
  tenant "not billing"). Other members see "ask your workspace owner".
- **Refresh**: by push on the hub socket the WUI already holds, not a new
  poll. The WUI has no per-minute poll today (`grep -rn setInterval
  csi-spl-wui/src` shows none on a 60 s data timer; the one 60 s gate,
  `src/plugins/pwa.client.ts:111`, checks the service worker). The model is the
  `flow` frame (`internal/hub/flow.go:172`, `{"type": "flow", ...}`): a new
  `{"type": "credits"}` frame goes to the workspace's open sockets at most
  once a minute and only when the ledger moved. The chip reads
  `GET /v1/view/credits` once at load and again on `live.onReconnected`, so a
  dropped socket never leaves a stale number. The counter refreshes every minute (Q-C1 = A, msg 31913cc1).
- **Source**: the `token_budgets` balance, i.e. the last top-up minus the sum
  of the `usage_events` since it, priced by the formula of 7. A turn
  dispatched and not yet written to the ledger shows as "n pending", never
  as an estimated amount; an `unmetered` turn (7) shows as such. The counter
  never runs ahead of the ledger: what the chip shows is what the 429
  `token_quota` check reads.
- **Thresholds**: one cnf setting, `env.hub.sales.credits_low_pct` (default
  20: the balance is below 20% of the last top-up). It is the same point as
  7's 80% notice, not a second one. Below it the chip turns to the warning
  colour and the `billing.manage` holder gets 7's one notice. At zero the
  chip reads "credit used up, top up here" (8, R7).
- **Cost** (027: the 155 KB initial chunk,
  `grep -n ci_initial_gzip_kb csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`):
  the chip is in the first paint, so it stays a few hundred bytes: a number
  formatted with `Intl.NumberFormat` and no library. Like `LazyHoursTimer`
  (`csi-spl-wui/src/components/TopBar.vue:105`, spec 107), the detail panel is a
  lazy chunk loaded on the first click. A workspace that is not metered
  mounts nothing. `perf-budget.py` stays under 155 KB.

| test | asserts | planted control (must turn it red) |
|---|---|---|
| T-C1 counter = ledger | a metered workspace with seeded `usage_events` shows the top-up minus the priced sum, in EUR and tokens; a pending turn shows as "1 pending", the balance unchanged; a row in another workspace changes nothing (RLS) | a frame that subtracts the pending turn's estimate, i.e. runs ahead of the ledger |
| T-C2 roles and defaults | `biz_owner` sees "top up here" at zero, `developer` sees "ask your workspace owner", `demo_user` gets no `credits` frame; a new workspace has auto top-up off; the warning starts at `credits_low_pct` | auto top-up defaulted on, or the top-up link shown to `developer` |

## 9. What the catalogue shows

- The catalogue lists what Csitea sells: the workspace plan(s), the services
  the sales agent can talk about, and how the price is built (usage + margin),
  not fixed prices. Entry shape: name, short description, what is metered,
  margin plan, delivery note.
- It shows the formula of section 7 but no number until spec 122's pricing
  gate holds.
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
| bot challenge | claude, claude-2: self-hosted proof-of-work; agy, mistral: hosted invisible challenge | owner question Q-T1 (2 to 2); owner: A (e95a0695) |
| repeat offenders | mistral: challenge on every post after 3 limit hits in 24 h, IP ban 24 h after 5 | taken (6) |
| new-device recovery | claude, claude-2: optional e-mail; mistral: e-mail or phone | e-mail only (4.1): a phone adds an SMS processor and more personal data |
| embed CORS | claude, claude-2: none needed; mistral, the draft: allow csitea.net | none (5): the iframe calls from our own origin |
| embed token for a business user | claude, claude-2: 5 min JWT minted by the customer's server; mistral: 30-day JWT in the iframe query string | 5 min JWT (5): a query-string token lands in logs and `Referer`, and a long one outlives a lapsed subscription |
| loader source | claude, claude-2: this repo; mistral: csi-web | this repo (5): every customer gets fixes without a copy; csi-web holds only the tag |
| order writes | mistral: mark paid in csi-rel's `orders` table; agy: product references mapped from csi-rel | neither: csi-rel is never called or written; the hub's own copied `payments` (8) |
| each business customer = own workspace | all four | taken (4.2) |
| who answers first | claude, agy: agent first; claude-2: human approves agent drafts in phase 1 | owner question Q-V1; owner: A (acaed9ef) |
| margin shape | agy, claude-2: one fixed %; claude: per plan | schema per plan, start value Q-M1; owner: one rate, 29% (cd2d25e3) |
| payment rail | agy: card; claude: card + invoice for business; claude-2: invoice for business, card for single buyers | owner question Q-M2; owner: A, card only (e38f9953) |
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

v1.1 (editor lane c-814, unsigned) folds the owner's answers and nothing
else: the version line, 1.3 (R6 to R8), 1.4, phases 3 to 5, 4.3, 6, 7 and
7.1, 8, the owner column of the table above, and 12. No seat's position
was re-weighed.

v1.2 (c-814, unsigned) folds Q-N1, Q-N2 and the sales agent's model scope
(1.4, 4.3, 6, 7, 12.4) and nothing else.

## 12. Owner questions

All six v1.0 questions are answered (section 1.4); each is kept below as
asked, with the owner's pick on its first line. Settled, not asked again:
what v1 sells (97b94903: whole workspaces only), the paid private channel
(1a374b78, now later), price = cost + margin (294eb431), metering per
workspace (0137a1bd), and everything in section 1.4. Section 12.4 holds
what the fold left open.

| # | owner's pick | msg |
|---|---|---|
| Q-M1 | A, at 29% | cd2d25e3, acaed9ef |
| Q-M2 | A | e38f9953 |
| Q-M3 | A | 8bb20332 |
| Q-V1 | A | acaed9ef |
| Q-V2 | A | acaed9ef |
| Q-T1 | A (c-002's reading of "Yes", posted for correction as 51f088b6) | e95a0695 |

### 12.1 Money

- **Q-M1 The margin. Recommended: A. Owner: A, 29% (cd2d25e3, acaed9ef).** A: one percentage on metered cost for
  every workspace, its value yours. B: a percentage per plan. (The setting is
  per plan from day one, so A -> B later needs no migration.)
- **Q-M2 How customers pay. Recommended: C. Owner: A (e38f9953).** A: prepaid balance by card,
  work stops at zero. B: monthly invoice. C: A for everyone, B only for
  businesses you approve.
- **Q-M3 Which model access serves paying customers. Recommended: A. Owner: A (8bb20332).**
  A: customer-serving agents on pay-per-token API keys (cost per token exact);
  our own work stays on subscriptions. B: everything on subscriptions, priced
  at the model's list API price. (Reselling at cost needs a real cost per
  token, and a subscription's terms may not allow serving third parties.)

### 12.2 Visitors

- **Q-V1 Who answers a visitor first. Recommended: A. Owner: A (acaed9ef).** (claude, agy;
  claude-2 recommends B; mistral did not say). A: the sales agent, handing over to you when unsure.
  B: phase 1 a human approves each agent draft, then A. C: you only.
- **Q-V2 Which agents read a visitor's channel. Recommended: A. Owner: A (acaed9ef).** (claude,
  claude-2, agy; mistral did not say).
  A: one dedicated sales agent per selling workspace, nothing else. B: any
  agent you seat in it.

### 12.3 Tech

- **Q-T1 Bot check on the first question. Recommended: A. Owner: A (e95a0695, read in 51f088b6).** (the panel split
  2 to 2: claude seats A, agy and mistral B; the editor's tie-break is A
  because B sends every visitor to a third party). A: self-hosted proof-of-work, no third party sees the
  visitor. B: a hosted invisible challenge service.

### 12.4 Left open by the v1.1 fold, answered for v1.2

Both are answered; no owner question is open. Kept as asked, with the
owner's pick on its first line.

| # | owner's pick | msg |
|---|---|---|
| Q-N1 | A, EUR 5 per day | 41925444 |
| Q-N2 | B, narrowed: only the Spool Hub admin changes the buffer; the action proposes | c2a30422 |

- **Q-N1 The daily spend ceiling for unpaid visitors, per embed (section 6).
  Recommended: A. Owner: A, EUR 5 (41925444).** The spec had the ceiling
  but no value.
  A: a low ceiling set now (e.g. EUR 5 per day for csitea.net), raised by
  you once the sales channel's real cost is visible in the ledger. B: no
  ceiling until spec 122 has measured the token gap; the per-IP and
  per-visitor limits are the only stop. (A keeps the one hard stop on
  unpaid cost that section 6 relies on.)
- **Q-N2 Who lowers the token buffer from +20% (section 7). Recommended:
  A. Owner: only the Spool Hub admin (c2a30422), i.e. B.** The owner's pick A (9e0c0dba) says it is lowered to the measured gap;
  it does not say who applies the change.
  A: a named action sets the buffer to the measured gap each month, never
  above 20%, and posts the new value to you. B: the action proposes the
  value and it changes only with your go. (A follows the owner rule that
  if-else steps are code; a price change still reaches you as a post.)

### 12.5 The credits counter (v1.3, open)

| # | owner's pick | msg |
|---|---|---|
| Q-C1 | A | 31913cc1 |
| Q-C2 | A | 31913cc1 |

- **Q-C1 What "resets" means in "a once-a-minute counter which resets and
  shows their credits" (057db9f5). Recommended: A.** A: the counter
  refreshes every minute and shows the balance. B: a per-minute spend
  window: the amount spent in the last minute, back to 0 each minute,
  beside the balance. (A answers "how much is left". B shows the burn rate,
  which the detail panel can still show under A.)
- **Q-C2 Where the counter sits (259e8711). Recommended: A.** A: the top
  bar on every workspace page (the "front page"), with the detail one click
  away and linked from the avatar menu. B: inside the avatar menu only.
  (The owner's rule is near-real-time understanding and no tricks. A
  balance behind a click is a balance most people stop checking. Prepaid
  services such as phone and cloud credit show it where the spending
  happens, so A keeps the balance visible while agents run. A costs one
  small chip in the first paint, measured against the 155 KB budget.)
