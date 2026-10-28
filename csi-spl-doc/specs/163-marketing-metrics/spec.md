# 163: Marketing metrics in Spool Hub (one section per metric)

**Feature ID**: `163-marketing-metrics` · **Status**: Draft v0.1 · **Created**: 2026-10-28  
Epic: **SPL-2400**. Issue: **SPL-4028**. Kind: **specs_and_docs**. Lane: c-418.  
**Topics**: overview `b13f7763-23c6-4599-ad47-5ee9c92bdc64` (metric list msg `623841cf`, discussion index msg `5763ad69`), and the 26 "Metric N of 26" discussions linked in section 2.  
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

State, checked on origin/master `dd3b55565` (2026-10-28):

| what | state | check |
|---|---|---|
| the 26 metrics | **Planned**: discussion only, nothing collected | the discussions say "none of these exist yet"; no metrics table: `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| grep -ciE 'metric\|insight'` -> 0 |
| posts keep their platform id | **Implemented** (LinkedIn, Facebook Page, Instagram) | `grep -c platform_post_id csi-spl-rdb/src/sql/postgres/spool-hub/0187_marketing.sql` -> 1 |
| cost ledger | **Implemented** (tokens, cloud) | `0166_cost_lines.sql` |
| Spool Hub's own sign-ups and payments | **Implemented** as records (`tenants`, `payment_checkouts`, `tenant_seat_periods`), no source attribution | `0003_payment.sql`, `0016_m4_seat_line_items.sql` |
| a home in the WUI | **Partial**: `/reporting/posts` is reserved by 143 §5.3 for spool posts, not marketing; no marketing tab | `csi-spl-wui/src/pages/reporting/posts.vue` is a placeholder |
| blog page views | **Planned**: nothing counts them | `grep -rliE 'page_view\|pageview' csi-spl-rdb \| wc -l` -> 0 |

---

## 1. The shared groundwork (built once, used by most metrics)

The overview's last line (msg `5763ad69`): "Building that groundwork once serves most of the list." Each metric in section 2 names which of these it uses.

| id | piece | what it is |
|---|---|---|
| **G1** | metrics store | one append-only table of raw platform numbers per workspace, FORCE RLS in the 0091 shape with the NULLIF guard (as `0187_marketing.sql`). Proposed name `marketing_metric_samples`: `tenant_id`, `source` (`linkedin`, `meta`, `ga4`, `gsc`, `google_ads`, `meta_ads`, `linkedin_ads`, `email`, `hub`, ...), `object_type` (`post`, `page`, `campaign`, `site`, `landing_page`, `query`, `email`), `object_ref`, `post_id` (nullable, to `marketing_posts`), `metric`, `value` numeric, `unit`, `period_start`, `period_end`, `fetched_at`, `run_id`. A re-fetch adds a row; the newest per key wins in the read view. The value is the platform's number unchanged. |
| **G2** | definitions page | proposed `marketing_metric_definitions`: per workspace and metric, the formula text, its parameters (attribution rule, window, period, what counts as "lost"), `signed_off_by`, `signed_off_at`, `version`. A changed definition is a new version, never an edit. A metric whose definition is not signed off shows "definition not agreed" instead of a number. |
| **G3** | read-only connectors | per workspace, the customer's own grant, in the shape of 090 §6 (KMS-sealed token rows, never in logs). One fetch job per source, run by the hub's scheduler, writing G1. A connector that loses its grant shows "disconnected since <time>", never the last number as current. |
| **G4** | UTM tagger | every link Spool Hub posts (090 dispatcher, blog share row, email) gets `utm_source`, `utm_medium`, `utm_campaign` (the post id) from one naming scheme per workspace, published on the definitions page (G2). |
| **G5** | reporting tab | a new tab `/reporting/marketing` in the 143 registry, one card per metric, grouped by stage in the overview's order. Every number shows its source, fetch time, and the definition version. Per-post numbers also show on the post's own card in the publish view. |
| **G6** | cost lines for marketing | ad spend lands in `cost_lines` (123) with `source` `ads.<platform>`, its own currency, and the fx rate and day the ledger already carries; this needs one new `origin` value (`ad_platform`; today's list: `billing_export`, `metered`, `transcript`, `agent_run`, `invoice`, `hand`, `estimate`). Production cost (tokens, cloud) is already there. |
| **G7** | revenue and customer source | the records that say who paid and when. For the Spool Hub workspace: `payment_checkouts` and `tenant_seat_periods`. For a customer workspace: a shop or CRM connector (G3). |

Refresh, unless a metric says otherwise: post-level numbers every 6 h for the first 72 h after publishing, then daily until day 28, then frozen (the last sample stays). Site and account numbers daily at 04:00 UTC, one day back (GA4 and Search Console data settle late). Snapshots (rankings, backlinks, share of voice) weekly or monthly as stated.

Permission names below are the ones each platform publishes for read access as far as this draft knows them; they were **not** checked against the live platform docs on 2026-10-28. Each connector row (section 3) re-checks them first and corrects this file.

---

## 2. The 26 metrics, in the overview's order

Each section: the discussion it answers, then source / API and permission, what Spool Hub stores, where it shows, refresh, and its build row (section 3).

### 2.1 Reach stage

#### 2.1.1 Impressions (metric 1, topic `8a377ad2`)

| | |
|---|---|
| source / API | LinkedIn member post analytics; Meta Page and Instagram insights per post; Google Ads campaign report; the blog's own view count for owned content |
| permission | LinkedIn `r_member_postAnalytics` (Community Management API, app review); Meta `read_insights` + `pages_read_engagement`, `instagram_manage_insights`; Google Ads read-only access + developer token |
| stores | G1 rows `metric=impressions` per post / campaign, keyed to `marketing_posts.post_id` |
| shows | G5 Reach card (total per platform, per post) and the post card |
| refresh | post cadence (section 1) |
| build | B2 (LinkedIn), B3 (Meta), B9 (ads), B6 (blog) |

Trust: the platform's number unchanged, with source and fetch time; no rounded estimate.

#### 2.1.2 Reach (metric 2, topic `19bad8f9`)

| | |
|---|---|
| source / API | the same calls as impressions: LinkedIn members reached, Meta / Instagram reach, Google Ads unique users per campaign |
| permission | as 2.1.1 |
| stores | G1 `metric=reach` per post / campaign |
| shows | G5 Reach card, **per platform only**: the card has no total row, and says why (one person on two platforms counts twice) |
| refresh | post cadence |
| build | B2, B3, B9 |

#### 2.1.3 Share of voice (metric 3, topic `025c62fc`)

| | |
|---|---|
| source / API | either Google Ads search impression share (our ads only), or a paid social-listening tool's API (mentions of the workspace vs. 3-5 named competitors) |
| permission | Google Ads read-only; the listening tool's read API key (G3) |
| stores | G2: the agreed competitor list and keyword set (signed off); G1 monthly snapshot `metric=share_of_voice` with the counts it is made of |
| shows | G5 Reach card, a monthly trend with the competitor list and source under it |
| refresh | monthly |
| build | B15; the source is open question Q6 |

### 2.2 Engagement stage

#### 2.2.1 CTR, click-through rate (metric 4, topic `05b53252`)

| | |
|---|---|
| source / API | platform clicks and impressions per post / ad (2.1.1 calls); for owned links, sessions arriving with the post's UTM tag (GA4) |
| permission | as 2.1.1; GA4 Data API `analytics.readonly`, the customer adds the workspace's service account as Viewer on the property |
| stores | G1 `clicks` and `impressions`; the ratio is computed at read time, never stored |
| shows | G5 Engagement card: clicks, impressions and the ratio side by side; G2 says which click counts (link click vs. any click) |
| refresh | post cadence; GA4 daily |
| build | B2, B3, B4 (UTM), B5 (GA4) |

#### 2.2.2 Engagement rate (metric 5, topic `b78cdcc1`)

| | |
|---|---|
| source / API | per-post reactions, comments, shares from the same calls as 2.1.1 |
| permission | as 2.1.1 |
| stores | G1 counts per post; G2 one fixed formula per platform (e.g. interactions / impressions) |
| shows | G5 Engagement card and the post card, the formula named next to the number |
| refresh | post cadence |
| build | B2, B3; the formula is fixed on the definitions page (B1) and never switched mid-contract |

#### 2.2.3 Time on page (metric 6, topic `856b4098`)

| | |
|---|---|
| source / API | GA4 average engagement time per landing page; for the Spool Hub blog, the site's own analytics (Q3) |
| permission | GA4 `analytics.readonly`, Viewer on the property; a consent banner on the measured site |
| stores | G1 `metric=engagement_time_s` per landing page, plus the consented share where the source gives it |
| shows | G5 Engagement card per landing page, with "only consenting visitors are measured" |
| refresh | daily |
| build | B5 (GA4), B6 (own blog) |

#### 2.2.4 Bounce rate (metric 7, topic `3471e409`)

| | |
|---|---|
| source / API | GA4 bounce rate (1 - engaged sessions / sessions) per landing page and per UTM campaign |
| permission | as 2.2.3 |
| stores | G1 `sessions` and `engaged_sessions`; the rate is computed at read time |
| shows | G5 Engagement card, with the GA4 definition and a note that it is not the old Universal Analytics bounce rate |
| refresh | daily |
| build | B5, needs B4 for the per-post link |

### 2.3 Acquisition stage

#### 2.3.1 Sessions by channel (metric 8, topic `c3aa96cd`)

| | |
|---|---|
| source / API | GA4 sessions by default channel group and by session source / medium / campaign |
| permission | as 2.2.3 |
| stores | G1 `metric=sessions` per channel and per campaign, day by day |
| shows | G5 Acquisition card, a monthly table per channel; untagged traffic is its own row, "(not tagged)", never guessed |
| refresh | daily; the monthly table is a read-time sum |
| build | B5, B4 (one published UTM scheme per workspace) |

#### 2.3.2 CPC, cost per click (metric 9, topic `17b656a6`)

| | |
|---|---|
| source / API | Google Ads, Meta Ads and LinkedIn Ads campaign reports: spend and clicks |
| permission | Google Ads read-only + developer token; Meta `ads_read`; LinkedIn `r_ads_reporting` |
| stores | spend into `cost_lines` (G6) in the account's own currency; clicks into G1 |
| shows | G5 Acquisition card: spend, clicks and the ratio; a converted figure shows its rate and day |
| refresh | daily, one day back |
| build | B9 |

#### 2.3.3 CPM, cost per 1000 impressions (metric 10, topic `26c22dcd`)

| | |
|---|---|
| source / API | the same ad reports as CPC: spend and impressions |
| permission | as 2.3.2 |
| stores | as 2.3.2, impressions into G1 |
| shows | G5 Acquisition card, formula shown |
| refresh | daily |
| build | B9 |

### 2.4 Conversion stage

#### 2.4.1 Conversion rate (metric 11, topic `e360359a`)

| | |
|---|---|
| source / API | GA4 key events per UTM source / campaign, over sessions; for Spool Hub itself, sign-ups (2.4.3) over sessions |
| permission | as 2.2.3 |
| stores | G2: which event counts as the conversion, signed off before any number shows; G1 `key_events` and `sessions` |
| shows | G5 Conversion card per channel and per campaign |
| refresh | daily |
| build | B5, B1 (sign-off) |

#### 2.4.2 Leads (metric 12, topic `ff2bfc12`)

| | |
|---|---|
| source / API | a form or demo request on the site with the UTM source in hidden fields, posted to the hub; or a CRM's read API (contacts with source) |
| permission | the CRM's read-only API key (G3); for the hub's own form, none |
| stores | proposed `marketing_leads` (FORCE RLS): source fields, consent text and time, status (`new`, `duplicate`, `spam`, `qualified`), `erased_at`; the person's contact data only while consent stands. G1 a daily count |
| shows | G5 Conversion card (count per source) and a lead inbox per workspace; every count opens the rows behind it |
| refresh | live for the hub's form; daily for a CRM |
| build | B10; GDPR erase and the de-duplication rule are part of the row, not later |

#### 2.4.3 Sign-ups (metric 13, topic `d2f43cfa`)

| | |
|---|---|
| source / API | the product's own database. For Spool Hub: new workspaces (`tenants`) and new members per day |
| permission | none (the hub's own records) |
| stores | the first-touch UTM source kept with the new workspace and member at sign-up (new columns, set once); G1 daily count per source by a hub job |
| shows | G5 Conversion card, labelled "counted from Spool Hub's own records" |
| refresh | daily (the count); the source is stored live at sign-up |
| build | B8 |

#### 2.4.4 CPL, cost per lead (metric 14, topic `08a14263`)

| | |
|---|---|
| source / API | cost: ad spend (G6) plus production cost already in `cost_lines` (tokens, cloud); leads: 2.4.2 |
| permission | as its inputs |
| stores | nothing new: computed at read time per campaign and period |
| shows | G5 Conversion card with two figures, "ads only" and "ads + production", and the list of cost lines in each |
| refresh | daily |
| build | B11 (after B9, B10) |

#### 2.4.5 CPA, cost per acquisition (metric 15, topic `c3995287`)

| | |
|---|---|
| source / API | cost as CPL; won customers from the CRM (deals marked won) or, for Spool Hub, `payment_checkouts` with `status='paid'` |
| permission | the CRM read key; none for the hub |
| stores | G2 the attribution rule (first or last touch); nothing else new |
| shows | G5 Conversion card, the rule written next to it; a customer counts once, when won |
| refresh | daily |
| build | B11 (after B9, B12) |

### 2.5 Revenue stage

#### 2.5.1 ROAS, return on ad spend (metric 16, topic `d4537bf7`)

| | |
|---|---|
| source / API | revenue: shop orders or CRM deals with source (G7); spend: G6 |
| permission | the shop / CRM read key; ad reads as 2.3.2 |
| stores | proposed `marketing_revenue_events` (FORCE RLS): order or deal ref, amount, currency, time, attributed campaign; G2 the attribution window (7 or 28 days) |
| shows | G5 Revenue card, window written next to the number |
| refresh | daily |
| build | B12 |

#### 2.5.2 ROI, return on investment (metric 17, topic `27d70ace`)

| | |
|---|---|
| source / API | revenue as ROAS; cost = every `cost_lines` row tagged to the campaign or period: ads, tokens, cloud, human time, agency fee |
| permission | as its inputs |
| stores | human time and fees as `cost_lines` with `origin='hand'` or `'invoice'` (both exist) |
| shows | G5 Revenue card with the full cost list open under it |
| refresh | daily |
| build | B12 |

#### 2.5.3 CAC, customer acquisition cost (metric 18, topic `45ec673a`)

| | |
|---|---|
| source / API | all sales and marketing cost in the period (`cost_lines`), new customers in the same period (G7) |
| permission | as its inputs |
| stores | nothing new |
| shows | G5 Revenue card per month, with the included cost sources listed |
| refresh | monthly, recomputed daily for the open month |
| build | B12 |

### 2.6 Retention stage

#### 2.6.1 LTV, customer lifetime value (metric 19, topic `ff309621`)

| | |
|---|---|
| source / API | order or billing history (G7); for Spool Hub, `tenant_seat_periods` |
| permission | the shop / billing read key; none for the hub |
| stores | G2 the formula and the history window; nothing else new |
| shows | G5 Retention card as an estimate with its inputs; under 12 months of history it says so |
| refresh | monthly |
| build | B13 |

#### 2.6.2 LTV:CAC ratio (metric 20, topic `bbcc57c1`)

| | |
|---|---|
| source / API | 2.6.1 and 2.5.3, same segment and period |
| permission | none beyond its inputs |
| stores | nothing |
| shows | G5 Retention card; "not enough data" whenever either input is |
| refresh | monthly |
| build | B13 |

#### 2.6.3 Churn (metric 21, topic `4b22b55a`)

| | |
|---|---|
| source / API | subscription or billing data (G7); for Spool Hub, a workspace whose paid seat periods stop |
| permission | the billing read key; none for the hub |
| stores | G2 the definition of "lost" (e.g. no paid period for 60 days), versioned |
| shows | G5 Retention card, by customers and by revenue, the definition under it |
| refresh | monthly |
| build | B13 |

#### 2.6.4 Repeat purchase rate (metric 22, topic `b6c5cd6a`)

| | |
|---|---|
| source / API | the shop's order history by customer id (G7) |
| permission | the shop read key |
| stores | G2 the period (e.g. 90 days) |
| shows | G5 Retention card, the period stated |
| refresh | monthly |
| build | B13; only for a workspace that sells repeat orders (not Spool Hub's own subscriptions) |

### 2.7 Content / SEO stage

#### 2.7.1 Organic traffic (metric 23, topic `fcbb9175`)

| | |
|---|---|
| source / API | GA4 organic search sessions; Search Console API clicks |
| permission | GA4 as 2.2.3; Search Console `webmasters.readonly`, the customer adds the service account as a restricted user of the property |
| stores | G1 `sessions` (channel organic) and `gsc_clicks` |
| shows | G5 SEO card, the two side by side with the note why they never match |
| refresh | daily, three days back for Search Console |
| build | B5, B7 |

#### 2.7.2 Keyword rankings (metric 24, topic `e203c14c`)

| | |
|---|---|
| source / API | Search Console average position per query; or a rank-tracking tool for fixed keywords and locations |
| permission | as 2.7.1, or the tool's read key |
| stores | G2 the agreed keyword list; G1 a weekly snapshot per keyword with source, location and date |
| shows | G5 SEO card, a weekly table |
| refresh | weekly |
| build | B14 |

#### 2.7.3 Backlinks (metric 25, topic `8b5d18c2`)

| | |
|---|---|
| source / API | a backlink tool's API. The Search Console links report has no API (believed, unchecked); its export would be a by-hand upload, marked as such |
| permission | the tool's read key |
| stores | G1 a monthly snapshot: linking domains, new and lost since the last one |
| shows | G5 SEO card, only links that exist and resolve |
| refresh | monthly |
| build | B14 |

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

Reach and engagement first: they need the fewest new grants and reuse the post ids 090 already keeps. Status of every row: **Planned**.

| row | builds | metrics served | needs | owner step before it |
|---|---|---|---|---|
| **B1** | G1 metrics store + G2 definitions table (one rdb migration, next free number at build time, FORCE RLS + NULLIF test), G5 tab `/reporting/marketing` with empty cards | all | none | none |
| **B2** | LinkedIn post analytics connector: impressions, reach, clicks, reactions, comments, reshares per published post | 1, 2, 4, 5 | B1 | LinkedIn Community Management API access for the app (Q2) |
| **B3** | Meta Page + Instagram insights connector, same metrics | 1, 2, 4, 5 | B1 | `read_insights`, `instagram_manage_insights` added to the Meta app review package (090 §20.4) |
| **B4** | G4 UTM tagger in the 090 dispatcher and blog share row; the scheme on the definitions page | 4, 7, 8 and every later attribution | none | none |
| **B5** | GA4 connector: sessions by channel / source / campaign, engaged sessions, engagement time, key events | 4, 6, 7, 8, 11, 23 | B1, B4 | the measured site has GA4 and a consent banner (Q3) |
| **B6** | own-blog view count for owned content | 1, 6 | B1 | Q3 |
| **B7** | Search Console connector: clicks, impressions, position per query | 23, 24 | B1 | the service account added to the property |
| **B8** | first-touch source stored at Spool Hub sign-up; daily sign-ups per source | 13, 11 | B1, B4 | none |
| **B9** | ad-account connectors (Google Ads, Meta Ads, LinkedIn Ads), spend into `cost_lines` (new `origin` `ad_platform`) | 1, 2, 9, 10 | B1 | an ad account exists and grants read (Q5) |
| **B10** | lead capture with source fields + lead inbox + CRM connector; consent, erase, de-dup rule | 12 | B1, B4 | Q4 |
| **B11** | CPL and CPA read-time join of costs and leads / won customers | 14, 15 | B10; B9 for the "ads" figure (production cost alone works without it) | attribution rule signed off (Q7) |
| **B12** | revenue events (hub `payment_checkouts` first; shop / CRM connector for a customer), ROAS, ROI, CAC | 16, 17, 18 | B11 | attribution window signed off (Q7) |
| **B13** | retention cards: LTV, LTV:CAC, churn, repeat purchase | 19, 20, 21, 22 | B12 | definitions of "lost" and the period signed off |
| **B14** | SEO snapshots: weekly keyword ranks, monthly backlinks | 24, 25 | B7 | keyword list agreed; backlink tool chosen |
| **B15** | share of voice monthly snapshot | 3 | B1; B9 or a listening tool | Q6 |
| **B16** | email provider stats | 26 | 090 Phase 2 provider | none beyond 090 |

---

## 4. Open questions for the owner (as polls)

The dispatch holder can post each block as it stands (how-to-post §7).

```poll
Q1. Which workspace do the metrics serve first?
(A) Spool Hub's own marketing (the blog, the LinkedIn posts, Spool Hub sign-ups)
(B) A customer workspace from day one
```

```poll
Q2. LinkedIn post numbers need LinkedIn's Community Management API (an app review, weeks). What do we do?
(A) Apply now; build B2 when it is granted
(B) Skip LinkedIn numbers for now; start with the blog and GA4
```

```poll
Q3. How do we measure the Spool Hub blog itself?
(A) GA4 on the site, with a cookie consent banner
(B) A cookie-less view count kept by the hub (no banner, fewer numbers)
(C) Both
```

```poll
Q4. Where do leads live?
(A) A simple lead inbox inside Spool Hub
(B) An external CRM, read by a connector
```

```poll
Q5. Paid ads: are any planned in the next 3 months?
(A) Yes: build the ad connectors (B9) early
(B) No: build them last; cost metrics use production cost only
```

```poll
Q6. Share of voice: which source?
(A) A paid social-listening tool
(B) Google Ads impression share only (needs ads)
(C) Leave share of voice out for now
```

```poll
Q7. Which attribution rule and window do we use?
(A) Last touch, 28 days
(B) First touch, 28 days
(C) Last touch, 7 days
```

```poll
Q8. Who sees the marketing numbers in the workspace?
(A) Every member
(B) Workspace admins and the owner only
```

---

## 5. Not in scope

1. Building anything: every change is a row of section 3.
2. Numbers typed in by hand as if measured. A by-hand upload is labelled as one.
3. Summing reach across platforms.
4. Scraping a platform page instead of its API (090 §10 item 3 holds).
5. Paid tool choices (listening, rank tracking, backlinks): the owner picks when the row starts.

<!-- version: 0.1.0 · updated: 2026-10-28 · last-edit: 2026-10-28T13:40:00Z -->
