# 163: Marketing metrics in Spool Hub (one section per metric)

**Feature ID**: `163-marketing-metrics` · **Status**: Draft v0.3 · **Created**: 2026-10-28  
Epic: **SPL-2400**. Issue: **SPL-4028** (v0.1, lane c-418), **SPL-4047** (v0.2 owner decisions folded, lane a-526). Kind: **specs_and_docs**.  
**Topics**: overview `b13f7763-23c6-4599-ad47-5ee9c92bdc64` (metric list msg `623841cf`, discussion index msg `5763ad69`), owner decisions poll `337fb605` (msg `449350b3`), and the 26 "Metric N of 26" discussions linked in section 2.  
**Authority**: this file for what each metric needs. Status vocabulary: [README.md](../README.md) §2.3. Docs only: this spec builds nothing ([README.md](../README.md) §2.4); every change it needs is a row of section 3.

Builds on, and does not repeat:
- [090 marketing automation](../090-marketing-automation/spec.md): channels, OAuth delegation, token storage (§6), the post queue and `marketing_posts.platform_post_id`, the per-workspace switch (§15). 090 §10 item 9 deferred reach analytics; this spec is where they go.
- [123 cost tracking](../123-cost-tracking/spec.md): the `cost_lines` ledger (rdb `0166_cost_lines.sql`), the cost side of CPL, CPA, ROI and CAC.
- [143 reporting section](../143-reporting-section/spec.md): the Reporting page and its tab registry (`csi-spl-wui/src/utils/reporting-tabs.mjs`).
- [065 release notes table](../065-release-notes-table/spec.md): the release posts that carry links.

`<BASE_DOMAIN>`, `<workspace_id>` and `<env>` are placeholders. The term is **workspace** throughout (the store column stays `tenant_id`).

---

## 0. The owner's words and the state today

Owner HUM-10, overview `b13f7763`:
- msg `64a76de3`: "ok , so foreach one of those metrics we need a separate discusion on how-to start collecting those , what kind of features eahc one of them is needing in order to be a trustful partner to the Customers"
- the same post in 12 of the 26 metric discussions, 2026-10-27 16:22Z..16:24Z (e.g. msg `d28a6932` in `8a377ad2`): "what is hte status of this one  - we need to start planning how to implement those metrics into the functionalities of the spool-hub"
- owner answers (HUM-10, poll `337fb605`, final form msg `449350b3-4b25-4a8e-abf9-107e707a9835`, verbatim): Q1-Q8 decided in section 4, folded into v0.2.

State, checked on origin/master `dd3b55565` (2026-10-28):

| what | state | check |
|---|---|---|
| the 26 metrics | **Planned**: discussion only, nothing collected | the discussions say "none of these exist yet"; no metrics table: `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| grep -ciE 'metric\|insight'` -> 0 |
| posts keep their platform id | **Implemented** (LinkedIn, Facebook Page, Instagram) | `grep -c platform_post_id csi-spl-rdb/src/sql/postgres/spool-hub/0187_marketing.sql` -> 1 |
| cost ledger | **Implemented** (tokens, cloud) | `0166_cost_lines.sql` |
| Spool Hub's own sign-ups and payments | **Implemented** as records (`tenants`, `payment_checkouts`, `tenant_seat_periods`), no source attribution | `0003_payment.sql`, `0016_m4_seat_line_items.sql` |
| a home in the WUI | **Partial**: `/reporting/posts` is reserved by 143 §5.3 for spool posts, not marketing; `/reporting/marketing` tab planned for workspace admins and owner only (Q8) | `csi-spl-wui/src/pages/reporting/posts.vue` is a placeholder |
| blog page views | **Planned**: measured via GA4 on the site with a cookie consent banner (Q3, build B4) | `grep -rliE 'page_view\|pageview' csi-spl-rdb \| wc -l` -> 0 |

---

## 1. The shared groundwork (built once, used by most metrics)

The overview's last line (msg `5763ad69`): "Building that groundwork once serves most of the list." Each metric in section 2 names which of these it uses.

| id | piece | what it is |
|---|---|---|
| **G1** | metrics store | one append-only table of raw platform numbers per workspace, FORCE RLS in the 0091 shape with the NULLIF guard (as `0187_marketing.sql`). Proposed name `marketing_metric_samples`: `tenant_id`, `source` (`linkedin`, `meta`, `ga4`, `gsc`, `google_ads`, `meta_ads`, `linkedin_ads`, `email`, `hub`, ...), `object_type` (`post`, `page`, `campaign`, `site`, `landing_page`, `query`, `email`), `object_ref`, `post_id` (nullable, to `marketing_posts`), `metric`, `value` numeric, `unit`, `period_start`, `period_end`, `fetched_at`, `run_id`. A re-fetch adds a row; the newest per key wins in the read view. The value is the platform's number unchanged. |
| **G2** | definitions page | proposed `marketing_metric_definitions`: per workspace and metric, the formula text, its parameters (attribution rule: Last touch, window: 28 days decided Q7; period, what counts as "lost"), `signed_off_by`, `signed_off_at`, `version`. A changed definition is a new version, never an edit. A metric whose definition is not signed off shows "definition not agreed" instead of a number. |
| **G3** | read-only connectors | per workspace, the customer's own grant, in the shape of 090 §6 (KMS-sealed token rows, never in logs). One fetch job per source, run by the hub's scheduler, writing G1. Ad connectors (Google Ads, Meta Ads, LinkedIn Ads) built early (Q5). LinkedIn post analytics waits for the Community Management API grant (Q2; §1.1). Social-listening tools dropped (Q6). A connector that loses its grant shows "disconnected since <time>", never the last number as current. |
| **G4** | UTM tagger | every link Spool Hub posts (090 dispatcher, blog share row, email) gets `utm_source`, `utm_medium`, `utm_campaign` (the post id) from one naming scheme per workspace, published on the definitions page (G2). |
| **G5** | reporting tab | a new tab `/reporting/marketing` in the 143 registry, one card per metric, grouped by stage in the overview's order. Visibility is restricted to workspace admins and the owner only (decided Q8, msg `449350b3`); standard members have no access. Every number shows its source, fetch time, and the definition version. Per-post numbers also show on the post's own card in the publish view. |
| **G6** | cost lines for marketing | ad spend lands in `cost_lines` (123) with `source` `ads.<platform>`, its own currency, and the fx rate and day the ledger already carries; this needs one new `origin` value (`ad_platform`; today's list: `billing_export`, `metered`, `transcript`, `agent_run`, `invoice`, `hand`, `estimate`). Production cost (tokens, cloud) is already there. |
| **G7** | revenue and customer source | the records that say who paid and when. Spool Hub's own marketing and workspace first (decided Q1, msg `449350b3`): `payment_checkouts` and `tenant_seat_periods`. Customer shop and external CRM connectors deferred. |

Refresh, unless a metric says otherwise: post-level numbers every 6 h for the first 72 h after publishing, then daily until day 28, then frozen (the last sample stays). Site and account numbers daily at 04:00 UTC, one day back (GA4 and Search Console data settle late). Snapshots (rankings, backlinks, share of voice) weekly or monthly as stated.

Permission names below are the ones each platform publishes for read access as far as this draft knows them; they were **not** checked against the live platform docs on 2026-10-28. Each connector row (section 3) re-checks them first and corrects this file.

### 1.1 LinkedIn Community Management API application (Q2 decided: apply now)

Q2 decided to apply now for LinkedIn's Community Management API and build the connector (row B15) when access is granted (HUM-10, msg `449350b3`).

#### Application package requirements
- **LinkedIn Developer App**: An application created in the LinkedIn Developer Portal, associated with the verified organization Page.
- **Product requested**: **Community Management API** (provides read access for organization and member social metrics: impressions, reach, clicks, reactions, comments, reshares).
- **Permissions requested**: `r_organization_social`, `r_member_postAnalytics`, `rw_organization_admin` (or the current permission bundle for organic post analytics).
- **Submission assets**:
  - Business website URL (`https://<BASE_DOMAIN>`)
  - Privacy Policy URL (`https://<BASE_DOMAIN>/privacy`)
  - Terms of Service URL (`https://<BASE_DOMAIN>/terms`)
  - Screencast or screenshots showing where and how LinkedIn post metrics will appear in Spool Hub WUI (`/reporting/marketing` tab and post cards), verifying that data is strictly read-only and visible only to workspace admins.
- **Who must submit**: **A human with the company page admin role** (Super Admin on the LinkedIn Company Page). The LinkedIn Developer Portal generates an administrator verification URL that must be approved by that human admin. Automated agents cannot and must not submit the application.
- **Boundary**: Do NOT apply anywhere and do NOT log in to any vendor. The application must be submitted manually by a human administrator.

#### Draft use-case text (for the application form)
> "Spool Hub is an agent-collaboration and workspace messaging platform that enables organizations and teams to compose, schedule, and publish content to company LinkedIn Pages and authorized member profiles.
>
> We are requesting access to the Community Management API specifically to retrieve organic post performance metrics (impressions, unique member reach, clicks, reactions, comments, and reshares) for posts published through Spool Hub.
>
> These metrics are displayed in a read-only performance dashboard (`/reporting/marketing`) and on post cards, accessible exclusively to authorized workspace administrators and the business owner to measure content engagement.
>
> Spool Hub stores metric samples in an append-only store with strict workspace-level Row-Level Security (RLS). We do not aggregate or share data across workspaces, do not sell or broker platform data, and do not use LinkedIn data for advertising, targeting, or profiling. Data access is strictly confined to the authenticated workspace's own published content."

---

## 2. The 26 metrics, in the overview's order

Each section: the discussion it answers, then source / API and permission, what Spool Hub stores, where it shows, refresh, and its build row (section 3).

### 2.1 Reach stage

#### 2.1.1 Impressions (metric 1, topic `8a377ad2`)

| | |
|---|---|
| source / API | LinkedIn member post analytics (waits on API grant, Q2); Meta Page and Instagram insights per post; Google Ads campaign report; the site's GA4 view count for owned content (Q3) |
| permission | LinkedIn `r_member_postAnalytics` (Community Management API, app review); Meta `read_insights` + `pages_read_engagement`, `instagram_manage_insights`; Google Ads read-only access + developer token; GA4 `analytics.readonly` |
| stores | G1 rows `metric=impressions` per post / campaign, keyed to `marketing_posts.post_id` |
| shows | G5 Reach card (total per platform, per post) and the post card (admins and owner only, Q8) |
| refresh | post cadence (section 1) |
| build | B3 (ads), B4 (site GA4 + banner), B5 (GA4 connector), B14 (Meta), B15 (LinkedIn, waits on grant) |

Trust: the platform's number unchanged, with source and fetch time; no rounded estimate.

#### 2.1.2 Reach (metric 2, topic `19bad8f9`)

| | |
|---|---|
| source / API | the same calls as impressions: LinkedIn members reached (waits on API grant, Q2), Meta / Instagram reach, Google Ads unique users per campaign |
| permission | as 2.1.1 |
| stores | G1 `metric=reach` per post / campaign |
| shows | G5 Reach card, **per platform only**: the card has no total row, and says why (one person on two platforms counts twice) |
| refresh | post cadence |
| build | B3 (ads), B14 (Meta), B15 (LinkedIn, waits on grant) |

#### 2.1.3 Share of voice (metric 3, topic `025c62fc`)

| | |
|---|---|
| source / API | Google Ads search impression share only (our ads only) (decided Q6 B, msg `449350b3`; social listening dropped) |
| permission | Google Ads read-only access + developer token (via ad connector B3) |
| stores | G1 monthly snapshot `metric=share_of_voice` (Google Ads search impression share percentage) |
| shows | G5 Reach card, a monthly trend of search impression share |
| refresh | monthly |
| build | B9 (needs B3) |

### 2.2 Engagement stage

#### 2.2.1 CTR, click-through rate (metric 4, topic `05b53252`)

| | |
|---|---|
| source / API | platform clicks and impressions per post / ad (2.1.1 calls; LinkedIn waits on grant, Q2); for owned links, sessions arriving with the post's UTM tag (GA4) |
| permission | as 2.1.1; GA4 Data API `analytics.readonly`, the customer adds the workspace's service account as Viewer on the property |
| stores | G1 `clicks` and `impressions`; the ratio is computed at read time, never stored |
| shows | G5 Engagement card: clicks, impressions and the ratio side by side; G2 says which click counts (link click vs. any click) |
| refresh | post cadence; GA4 daily |
| build | B2 (UTM), B3 (ads), B4 (site GA4 + banner), B5 (GA4 connector), B14 (Meta), B15 (LinkedIn, waits on grant) |

#### 2.2.2 Engagement rate (metric 5, topic `b78cdcc1`)

| | |
|---|---|
| source / API | per-post reactions, comments, shares from the same calls as 2.1.1 (LinkedIn waits on grant, Q2) |
| permission | as 2.1.1 |
| stores | G1 counts per post; G2 one fixed formula per platform (e.g. interactions / impressions) |
| shows | G5 Engagement card and the post card, the formula named next to the number |
| refresh | post cadence |
| build | B14 (Meta), B15 (LinkedIn, waits on grant); formula fixed on definitions page (B1) |

#### 2.2.3 Time on page (metric 6, topic `856b4098`)

| | |
|---|---|
| source / API | GA4 average engagement time per landing page; for the Spool Hub blog, GA4 on the site with a cookie consent banner (decided Q3 A, msg `449350b3`) |
| permission | GA4 `analytics.readonly`, Viewer on the property; cookie consent banner on the measured site (B4) |
| stores | G1 `metric=engagement_time_s` per landing page, plus the consented share where the source gives it |
| shows | G5 Engagement card per landing page, with "only consenting visitors are measured" |
| refresh | daily |
| build | B4 (site GA4 + banner), B5 (GA4 connector) |

#### 2.2.4 Bounce rate (metric 7, topic `3471e409`)

| | |
|---|---|
| source / API | GA4 bounce rate (1 - engaged sessions / sessions) per landing page and per UTM campaign |
| permission | as 2.2.3 |
| stores | G1 `sessions` and `engaged_sessions`; the rate is computed at read time |
| shows | G5 Engagement card, with the GA4 definition and a note that it is not the old Universal Analytics bounce rate |
| refresh | daily |
| build | B4, B5, needs B2 for the per-post link |

### 2.3 Acquisition stage

#### 2.3.1 Sessions by channel (metric 8, topic `c3aa96cd`)

| | |
|---|---|
| source / API | GA4 sessions by default channel group and by session source / medium / campaign |
| permission | as 2.2.3 |
| stores | G1 `metric=sessions` per channel and per campaign, day by day |
| shows | G5 Acquisition card, a monthly table per channel; untagged traffic is its own row, "(not tagged)", never guessed |
| refresh | daily; the monthly table is a read-time sum |
| build | B4, B5, B2 (one published UTM scheme per workspace) |

#### 2.3.2 CPC, cost per click (metric 9, topic `17b656a6`)

| | |
|---|---|
| source / API | Google Ads, Meta Ads and LinkedIn Ads campaign reports: spend and clicks |
| permission | Google Ads read-only + developer token; Meta `ads_read`; LinkedIn `r_ads_reporting` |
| stores | spend into `cost_lines` (G6) in the account's own currency; clicks into G1 |
| shows | G5 Acquisition card: spend, clicks and the ratio; a converted figure shows its rate and day |
| refresh | daily, one day back |
| build | B3 (ad connectors built early per Q5) |

#### 2.3.3 CPM, cost per 1000 impressions (metric 10, topic `26c22dcd`)

| | |
|---|---|
| source / API | the same ad reports as CPC: spend and impressions |
| permission | as 2.3.2 |
| stores | as 2.3.2, impressions into G1 |
| shows | G5 Acquisition card, formula shown |
| refresh | daily |
| build | B3 (ad connectors built early per Q5) |

### 2.4 Conversion stage

#### 2.4.1 Conversion rate (metric 11, topic `e360359a`)

| | |
|---|---|
| source / API | GA4 key events per UTM source / campaign, over sessions; for Spool Hub itself (decided Q1), sign-ups (2.4.3) over GA4 sessions |
| permission | as 2.2.3 |
| stores | G2: which event counts as the conversion, signed off before any number shows; G1 `key_events` and `sessions` |
| shows | G5 Conversion card per channel and per campaign |
| refresh | daily |
| build | B5 (GA4 connector), B7 (sign-ups), B1 (sign-off) |

#### 2.4.2 Leads (metric 12, topic `ff2bfc12`)

| | |
|---|---|
| source / API | a form or demo request on the site with the UTM source in hidden fields, posted to the hub lead capture API; internal lead inbox inside Spool Hub (decided Q4 A, msg `449350b3`; external CRM connector deferred) |
| permission | none for the hub's own form and lead inbox |
| stores | proposed `marketing_leads` (FORCE RLS): source fields, consent text and timestamp, status (`new`, `duplicate`, `spam`, `qualified`), `erased_at`; the person's contact data only while consent stands. G1 a daily count |
| shows | G5 Conversion card (count per source) and a simple Lead Inbox inside Spool Hub (accessible to workspace admins and owner only, Q8); every count opens the rows behind it |
| refresh | live for the hub's form |
| build | B8 (lead capture API + Spool Hub Lead Inbox; GDPR erase and de-duplication rules are part of the row) |

#### 2.4.3 Sign-ups (metric 13, topic `d2f43cfa`)

| | |
|---|---|
| source / API | the product's own database. For Spool Hub (decided Q1): new workspaces (`tenants`) and new members per day |
| permission | none (the hub's own records) |
| stores | the first-touch UTM source kept with the new workspace and member at sign-up (new columns, set once); G1 daily count per source by a hub job |
| shows | G5 Conversion card, labelled "counted from Spool Hub's own records" |
| refresh | daily (the count); the source is stored live at sign-up |
| build | B7 (needs B1, B2) |

#### 2.4.4 CPL, cost per lead (metric 14, topic `08a14263`)

| | |
|---|---|
| source / API | cost: ad spend (G6, via B3 ad connectors) plus production cost already in `cost_lines` (tokens, cloud); leads: 2.4.2 (Spool Hub lead inbox) |
| permission | as its inputs |
| stores | nothing new: computed at read time per campaign and period using Last touch, 28 days attribution (decided Q7) |
| shows | G5 Conversion card with two figures, "ads only" and "ads + production", and the list of cost lines in each |
| refresh | daily |
| build | B10 (after B3, B8) |

#### 2.4.5 CPA, cost per acquisition (metric 15, topic `c3995287`)

| | |
|---|---|
| source / API | cost as CPL; won customers from Spool Hub `payment_checkouts` with `status='paid'` (decided Q1) |
| permission | none for the hub |
| stores | G2 the attribution rule: Last touch, 28 days (decided Q7, msg `449350b3`); nothing else new |
| shows | G5 Conversion card, "Last touch, 28d" written next to it; a customer counts once, when paid |
| refresh | daily |
| build | B10 (after B3, B7) |

### 2.5 Revenue stage

#### 2.5.1 ROAS, return on ad spend (metric 16, topic `d4537bf7`)

| | |
|---|---|
| source / API | revenue: Spool Hub `payment_checkouts` (decided Q1); spend: G6 (B3 ad connectors) |
| permission | none for hub checkout records; ad reads as 2.3.2 |
| stores | proposed `marketing_revenue_events` (FORCE RLS): checkout ref, amount, currency, time, attributed campaign; G2 attribution: Last touch, 28 days (decided Q7) |
| shows | G5 Revenue card, window "Last touch, 28d" written next to the number |
| refresh | daily |
| build | B11 (needs B10) |

#### 2.5.2 ROI, return on investment (metric 17, topic `27d70ace`)

| | |
|---|---|
| source / API | revenue as ROAS (`payment_checkouts`); cost = every `cost_lines` row tagged to the campaign or period: ads (B3), tokens, cloud, human time, agency fee |
| permission | as its inputs |
| stores | human time and fees as `cost_lines` with `origin='hand'` or `'invoice'`; attribution: Last touch, 28 days (decided Q7) |
| shows | G5 Revenue card with the full cost list open under it |
| refresh | daily |
| build | B11 (needs B10) |

#### 2.5.3 CAC, customer acquisition cost (metric 18, topic `45ec673a`)

| | |
|---|---|
| source / API | all sales and marketing cost in the period (`cost_lines`), new paying customers in the same period (`payment_checkouts`) (decided Q1) |
| permission | as its inputs |
| stores | nothing new |
| shows | G5 Revenue card per month, with the included cost sources listed |
| refresh | monthly, recomputed daily for the open month |
| build | B11 (needs B10) |

### 2.6 Retention stage

#### 2.6.1 LTV, customer lifetime value (metric 19, topic `ff309621`)

| | |
|---|---|
| source / API | for Spool Hub (decided Q1): `tenant_seat_periods` |
| permission | none for hub records |
| stores | G2 the formula and the history window; nothing else new |
| shows | G5 Retention card as an estimate with its inputs; under 12 months of history it says so |
| refresh | monthly |
| build | B12 (needs B11) |

#### 2.6.2 LTV:CAC ratio (metric 20, topic `bbcc57c1`)

| | |
|---|---|
| source / API | 2.6.1 and 2.5.3, same segment and period |
| permission | none beyond its inputs |
| stores | nothing |
| shows | G5 Retention card; "not enough data" whenever either input is |
| refresh | monthly |
| build | B12 (needs B11) |

#### 2.6.3 Churn (metric 21, topic `4b22b55a`)

| | |
|---|---|
| source / API | for Spool Hub (decided Q1): a workspace whose paid seat periods stop |
| permission | none for hub records |
| stores | G2 the definition of "lost" (e.g. no paid period for 60 days), versioned |
| shows | G5 Retention card, by customers and by revenue, the definition under it |
| refresh | monthly |
| build | B12 (needs B11) |

#### 2.6.4 Repeat purchase rate (metric 22, topic `b6c5cd6a`)

| | |
|---|---|
| source / API | the shop's order history by customer id (G7) |
| permission | the shop read key |
| stores | G2 the period (e.g. 90 days) |
| shows | G5 Retention card, the period stated |
| refresh | monthly |
| build | B12; deferred for Spool Hub's subscription model (Q1: Spool Hub workspace first); retained for customer workspace phase |

### 2.7 Content / SEO stage

#### 2.7.1 Organic traffic (metric 23, topic `fcbb9175`)

| | |
|---|---|
| source / API | GA4 organic search sessions; Search Console API clicks |
| permission | GA4 as 2.2.3; Search Console `webmasters.readonly`, the customer adds the service account as a restricted user of the property |
| stores | G1 `sessions` (channel organic) and `gsc_clicks` |
| shows | G5 SEO card, the two side by side with the note why they never match |
| refresh | daily, three days back for Search Console |
| build | B4, B5, B6 |

#### 2.7.2 Keyword rankings (metric 24, topic `e203c14c`)

| | |
|---|---|
| source / API | Search Console average position per query; or a rank-tracking tool for fixed keywords and locations |
| permission | as 2.7.1, or the tool's read key |
| stores | G2 the agreed keyword list; G1 a weekly snapshot per keyword with source, location and date |
| shows | G5 SEO card, a weekly table |
| refresh | weekly |
| build | B6, B13 |

#### 2.7.3 Backlinks (metric 25, topic `8b5d18c2`)

| | |
|---|---|
| source / API | a backlink tool's API. The Search Console links report has no API (believed, unchecked); its export would be a by-hand upload, marked as such |
| permission | the tool's read key |
| stores | G1 a monthly snapshot: linking domains, new and lost since the last one |
| shows | G5 SEO card, only links that exist and resolve |
| refresh | monthly |
| build | B13 |

#### 2.7.4 Email open and click rates (metric 26, topic `1b8d4b8e`)

| | |
|---|---|
| source / API | the email provider's reporting API (090 Phase 2) per send: delivered, opens, clicks |
| permission | the provider's read key, or the provider's webhooks into the hub |
| stores | G1 per send; UTM tags on every email link (G4) |
| shows | G5 SEO card: clicks first; opens with the warning that mail privacy features over-count them |
| refresh | daily for 7 days after a send |
| build | B16 (after 090 Phase 2 has a provider) |

---

## 3. Build order (one row = one lane)

Reach, engagement, and ads early: ad connectors (B3) move early (Q5 decided); Spool Hub's own workspace is served first (Q1 decided); blog measurement uses GA4 on site with a cookie consent banner (B4, Q3 decided); leads use an internal Spool Hub lead inbox (B8, Q4 decided); share of voice uses Google Ads impression share only (B9, Q6 decided); attribution uses last touch, 28 days (B10, B11, Q7 decided); visibility is restricted to workspace admins and the owner only (B1, B8, Q8 decided); and LinkedIn post analytics waits on its Community Management API grant (B15, Q2 decided). Status of every row: **Planned**, except B1 (**Partial**, below).

| row | builds | metrics served | needs | owner step before it |
|---|---|---|---|---|
| **B1** (**Partial**: built on branch `review/c-954-s163-b1`, not on master until its R7 review; SPL-4250, section 3.1) | G1 metrics store + G2 definitions table (one rdb migration, next free number at build time, FORCE RLS + NULLIF test; Q7 default: last-touch, 28-day window), G5 tab `/reporting/marketing` with empty cards visible to workspace admins and owner only (Q8) | all | none | none |
| **B2** | G4 UTM tagger in the 090 dispatcher and blog share row; the scheme published on the definitions page (G2) | 4, 7, 8, 11, 12, 13, 14, 15, 16 | B1 | none |
| **B3** | Ad-account connectors (Google Ads, Meta Ads, LinkedIn Ads) built early (Q5): campaign impressions, clicks, spend into `cost_lines` (new `origin` `ad_platform`) | 1, 2, 9, 10 | B1 | an ad account exists and grants read (Q5) |
| **B4** | Site GA4 tag + cookie consent banner (Q3): deploy GA4 measurement snippet and cookie consent banner on the site / blog front-end | 1, 6, 7, 8, 11, 23 | none | GA4 property created; cookie consent text agreed (Q3) |
| **B5** | GA4 connector: hub job pulling sessions by channel / source / campaign, engaged sessions, engagement time, key events via GA4 Data API | 4, 6, 7, 8, 11, 23 | B1, B2, B4 | service account added as Viewer to GA4 property |
| **B6** | Search Console connector: clicks, impressions, position per query | 23, 24 | B1 | the service account added as restricted user to the property |
| **B7** | First-touch source stored at Spool Hub sign-up; daily sign-ups per source (Spool Hub workspace first, Q1) | 13, 11 | B1, B2 | none |
| **B8** | Spool Hub lead capture API + simple Lead Inbox in WUI (Q4): proposed `marketing_leads` table (FORCE RLS), lead capture endpoint with UTM tracking, consent timestamping, de-dup, GDPR erase; WUI inbox restricted to admins + owner (Q8) | 12 | B1, B2 | none |
| **B9** | Share of voice monthly snapshot from Google Ads search impression share only (Q6) | 3 | B1, B3 | active Google Ads campaigns (Q5, Q6) |
| **B10** | CPL and CPA read-time join of costs (`cost_lines`) and leads (B8) / won customers (`payment_checkouts`), using Last touch, 28 days attribution (Q7) | 14, 15 | B3, B7, B8 | none (attribution model decided in Q7) |
| **B11** | Revenue events table (`marketing_revenue_events`, FORCE RLS) from hub `payment_checkouts` (Q1), ROAS, ROI, CAC with Last touch, 28 days attribution (Q7) | 16, 17, 18 | B10 | none (attribution window decided in Q7) |
| **B12** | Retention cards for Spool Hub subscriptions (Q1): LTV, LTV:CAC, churn from `tenant_seat_periods` (repeat purchase deferred) | 19, 20, 21 | B11 | definition of "lost" workspace signed off |
| **B13** | SEO snapshots: weekly keyword ranks from Search Console, monthly backlinks from selected tool | 24, 25 | B6 | keyword list agreed; backlink tool chosen |
| **B14** | Meta Page + Instagram insights connector, post impressions, reach, clicks, reactions, comments | 1, 2, 4, 5 | B1 | `read_insights`, `instagram_manage_insights` approved in Meta app review (090 §20.4) |
| **B15** | LinkedIn post analytics connector: impressions, reach, clicks, reactions, comments, reshares per published post (waits on API grant, Q2) | 1, 2, 4, 5 | B1 | LinkedIn Community Management API access granted (human page admin submits application, §1.1) |
| **B16** | Email provider stats: delivered, opens, clicks | 26 | B1, 090 Phase 2 provider | email provider selected in 090 Phase 2 |


### 3.1 B1 as built (SPL-4250)

| piece | where | what it does |
|---|---|---|
| G1 + G2 tables | `csi-spl-rdb/src/sql/postgres/spool-hub/0244_marketing_metrics.sql` | `marketing_metric_samples` (the G1 columns, `value` numeric, `post_id` without an FK as `marketing_post_events`) and `marketing_metric_definitions` (key `tenant_id, metric, version`; `attribution_rule` default `last_touch`, `attribution_window_days` default 28, Q7). Both append-only (a tenant delete's cascade is the one DELETE), FORCE RLS, `tenant_scope` with the NULLIF guard plus `operator_scope`. A sign-off is a new version, never an edit. |
| store | `csi-spl-api/.../internal/store/marketing_metrics.go`, `_postgres.go`, `_memory.go` | `AddMarketingMetricSample`, `AddMarketingMetricDefinition` (version = newest + 1), `ReadMarketingMetrics`: the newest sample per (source, object_type, object_ref, metric, period) and the newest definition per metric. The connector rows (B3..B16) write through it. |
| hub route | `csi-spl-api/.../internal/hub/reporting_marketing.go` | `GET /v1/reporting/marketing`: `{as_of, attribution {rule, window_days}, stages, samples, definitions}`. The workspace owner or an admin only (`TenantOwner || Has(rbac.Admin)`, Q8); anyone else 403 `reporting.marketing`. |
| WUI tab | `csi-spl-wui/src/utils/reporting-tabs.mjs` (`staff: true`), `src/pages/reporting/marketing.vue`, `src/utils/reporting-marketing.mjs` | One card per stage of section 2, in that order, each "No numbers yet"; the attribution line "Last touch, 28 days". Hidden from other members; opened by its path it shows the hub's refusal and no card. |
| tests | store `marketing_metrics_test.go` (Memory + Postgres; RLS scopes, append-only, the NULLIF red control, the Q7 column defaults), `crosstenant_test.go` seeds both tables; hub `reporting_marketing_test.go` (every role: biz_owner and admin 200, the rest 403); WUI `tests/unit/reporting-marketing.test.mjs`, `tests/e2e/reporting.test.mjs` | |

The tab is not behind the 090 marketing switch (spec 090 section 15): it reads numbers only, and none exist until a connector row is built.

---

## 4. Owner decisions (HUM-10, poll 337fb605, msg 449350b3)

The owner answered all eight questions in poll `337fb605` (final form msg `449350b3-4b25-4a8e-abf9-107e707a9835`, verbatim). Every question is **decided**; all poll blocks are resolved.

| Q | Topic | Decision | Verbatim Answer | Msg | Impacted Sections |
|---|---|---|---|---|---|
| **Q1** | Workspace scope | **(A) Spool Hub workspace first** | "A — Spool Hub's own marketing (the blog, the LinkedIn posts, Spool Hub sign-ups)" | `449350b3` | 1 (G7), 2.4.1, 2.4.3, 2.4.5, 2.5.1, 2.5.3, 2.6.1, 2.6.3, 3 (B7, B10, B11, B12) |
| **Q2** | LinkedIn API review | **(A) Apply now; build B2 when granted** | "A — Apply now; build B2 when it is granted" | `449350b3` | 1.1, 2.1.1, 2.1.2, 2.2.1, 2.2.2, 3 (B15) |
| **Q3** | Blog measurement | **(A) GA4 with cookie consent banner** | "A — Google Analytics on the site, with a cookie consent banner" | `449350b3` | 0, 2.1.1, 2.2.3, 3 (B4, B5) |
| **Q4** | Lead storage | **(A) Simple lead inbox in Spool Hub** | "A — A simple lead inbox inside Spool Hub" | `449350b3` | 2.4.2, 3 (B8) |
| **Q5** | Ad connectors timing | **(A) Build ad connectors early** | "A — Yes: build the ad connectors early" | `449350b3` | 1 (G3), 2.1.1, 2.3.2, 2.3.3, 3 (B3) |
| **Q6** | Share of voice source | **(B) Google Ads impression share only** | "B — Google Ads impression share only (needs ads)" | `449350b3` | 2.1.3, 3 (B9), 5 |
| **Q7** | Attribution rule & window | **(A) Last touch, 28 days** | "A — Last touch, 28 days" | `449350b3` | 1 (G2), 2.4.4, 2.4.5, 2.5.1, 2.5.2, 3 (B1, B10, B11) |
| **Q8** | Numbers visibility | **(B) Admins and owner only** | "B — Workspace admins and the owner only" | `449350b3` | 0, 1 (G5), 2.4.2, 3 (B1, B8) |

### Q1. Which workspace do the metrics serve first?
- **Status**: **Decided (A)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Spool Hub's own marketing (the blog, the LinkedIn posts, Spool Hub sign-ups).
- **Implementation**: Groundwork and early build rows prioritize Spool Hub's own marketing workspace (`payment_checkouts`, `tenant_seat_periods`, owned blog, and 090 posts). Customer shop and CRM connectors are deferred to a subsequent milestone.

### Q2. LinkedIn post numbers need LinkedIn's Community Management API (an app review, weeks). What do we do?
- **Status**: **Decided (A)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Apply now; build the connector when it is granted.
- **Implementation**: Section 1.1 defines the application package, products, permissions, and drafted use-case text for a human company page administrator to submit. The connector implementation (row B15) waits for LinkedIn approval; all other groundwork and connectors proceed independently.

### Q3. How do we measure the Spool Hub blog itself?
- **Status**: **Decided (A)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Google Analytics on the site, with a cookie consent banner.
- **Implementation**: Option B (cookie-less hub view count) is dropped. Build row B4 adds the GA4 measurement tag and cookie consent banner to the blog/site front-end. Hub row B5 pulls engagement time and page views via GA4 Data API.

### Q4. Where do leads live?
- **Status**: **Decided (A)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: A simple lead inbox inside Spool Hub.
- **Implementation**: Build row B8 implements lead capture with UTM tracking into a new `marketing_leads` table (FORCE RLS, GDPR erasure, consent timestamping) and adds a Lead Inbox view in the WUI. External CRM connectors are deferred.

### Q5. Paid ads: are any planned in the next 3 months?
- **Status**: **Decided (A)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Yes: build the ad connectors early.
- **Implementation**: Ad connectors (Google Ads, Meta Ads, LinkedIn Ads) moved early in the build sequence to row B3, directly after core groundwork and UTM tagging.

### Q6. Share of voice: which source?
- **Status**: **Decided (B)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Google Ads impression share only (needs ads).
- **Implementation**: Paid social-listening tool dropped. Share of voice is computed exclusively from Google Ads search impression share via connector B3 and stored in monthly snapshots (row B9).

### Q7. Which attribution rule and window do we use?
- **Status**: **Decided (A)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Last touch, 28 days.
- **Implementation**: G2 definitions table establishes Last touch with a 28-day lookback window as the default signed-off attribution model across CPL, CPA, ROAS, and ROI (rows B1, B10, B11).

### Q8. Who sees the marketing numbers in the workspace?
- **Status**: **Decided (B)** (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`).
- **Decision**: Workspace admins and the owner only.
- **Implementation**: Access to the `/reporting/marketing` tab (G5) and the Lead Inbox (B8) is restricted to workspace `admin` and `biz_owner` / owner roles only. Standard members cannot view marketing numbers or leads.

---

## 5. Not in scope

1. Building anything: every change is a row of section 3.
2. Numbers typed in by hand as if measured. A by-hand upload is labelled as one.
3. Summing reach across platforms.
4. Scraping a platform page instead of its API (090 §10 item 3 holds).
5. Paid social-listening tools (dropped per Q6: Google Ads impression share used for share of voice). Rank tracking and backlink tool selection remain for row B13.

---

## 6. Change log

- **v0.1** (2026-10-28, c-418, SPL-4028): Initial draft under epic SPL-2400. Mapped 26 metrics to shared groundwork G1-G7, build order B1-B16 (reach and engagement first), and 8 owner questions as polls.
- **v0.2** (2026-10-28, a-526, SPL-4047): Folded owner decisions from poll `337fb605` (HUM-10, msg `449350b3-4b25-4a8e-abf9-107e707a9835`):
  - **Q1 (A)**: Scope prioritizes Spool Hub's own marketing workspace first (`payment_checkouts`, `tenant_seat_periods`, owned blog, 090 posts); customer shop/CRM connectors deferred.
  - **Q2 (A)**: Added section 1.1 outlining LinkedIn Community Management API application requirements, roles, assets, and drafted use-case text for human submitter; LinkedIn connector (B15) waits on API grant.
  - **Q3 (A)**: Blog measurement uses GA4 on site with cookie consent banner (cookie-less hub view count dropped); dedicated build row B4 added for site GA4 tag and consent banner.
  - **Q4 (A)**: Leads managed in Spool Hub lead inbox (`marketing_leads` table with FORCE RLS, GDPR erasure, consent timestamps, WUI inbox; build row B8); external CRM connector deferred.
  - **Q5 (A)**: Ad connectors (Google Ads, Meta Ads, LinkedIn Ads) moved early in build order to B3.
  - **Q6 (B)**: Share of voice uses Google Ads impression share only (paid social-listening tool dropped); build row B9.
  - **Q7 (A)**: Attribution model and lookback window fixed to Last touch, 28 days across G2 definitions, CPL/CPA (B10), and revenue/ROI (B11).
  - **Q8 (B)**: Visibility of `/reporting/marketing` tab restricted to workspace admins and the owner only.
  - Section 3 re-ordered and updated into 16 disjoint buildable rows (B1-B16); Section 4 poll blocks replaced with decision records.

- **v0.3** (2026-10-29, c-954, SPL-4250): row B1 built (section 3.1): rdb 0244, the store, `GET /v1/reporting/marketing` (owner and admins, Q8), the `/reporting/marketing` tab with empty stage cards and the Q7 attribution line.

<!-- version: 0.3.0 · updated: 2026-10-29 · last-edit: 2026-10-29T15:00:00Z -->
