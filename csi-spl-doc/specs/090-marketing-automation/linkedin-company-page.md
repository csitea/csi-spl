# 090 LinkedIn Company Page Publishing (Phase 4, T041) & Community Management API Owner Steps

**Feature ID**: `090-marketing-automation` · **Phase**: 4 (`T041`) · **Status**: Draft v0.1  
**Epic**: **SPL-2376** · **Issue**: **SPL-5252** · **Kind**: `specs_and_docs`  
**Topic**: `12d8a588-6bfd-4085-867a-c738aa916cbb` (msgs `ead122c7`, `9a818a96`, `04836282`, `f6c79bc2`)  
**Authority**: Companion specification and owner portal runbook to [`spec.md`](./spec.md) (§3, §7 Phase 4, §16.3, §20) and [`tasks.md`](./tasks.md) (`T041`). Status vocabulary: [`../README.md`](../README.md) §2.3. Docs only: this file builds no code (`../README.md` §2.4).

`<BASE_DOMAIN>`, `<WORKSPACE>`, `<HUMAN_ID>`, and `<ENV>` are placeholders. No credential, token, or key path appears in this document.

---

## 1. Context & How Team Members Publish in the Company's Name

In topic `12d8a588-6bfd-4085-867a-c738aa916cbb` (msg `ead122c7`), the owner (`HUM-10`) asked how a workspace member (`HUM-24`) can be added so she can publish on the company LinkedIn Page in the company's name, and approved starting the Phase 4 specification and the LinkedIn API access request (poll `9a818a96`, answer `04836282`).

Today, Phase 1 LinkedIn integration ([`linkedin-app-setup.md`](./linkedin-app-setup.md), `T015`) uses the self-serve **Share on LinkedIn** product (`w_member_social`) and posts strictly as a personal member profile (`author: "urn:li:person:<sub>"`). Publishing in the name of a **LinkedIn Organization (Company) Page** (`author: "urn:li:organization:<org_id>"`) is **Phase 4 (`T041`)** and requires LinkedIn's vetted **Community Management API**.

Once Phase 4 is enabled and connected, a workspace member such as `HUM-24` publishes in the company's name **without needing her own LinkedIn OAuth connection or a LinkedIn Page role**:

1. **Via Spool Hub (delegated Page channel)**: One LinkedIn Page **Super admin** or **Content admin** (who also holds `tenant.settings` in the workspace) connects the company LinkedIn Page once in `Tenant settings -> General -> Marketing`. From that moment, **any workspace `admin` or `biz_owner`** (same role gate as **SPL-5196**) can publish approved blog posts to the company LinkedIn Page from Spool Hub.
2. **Directly inside LinkedIn's own UI (optional, independent of Spool Hub)**: If the owner also wants a colleague to draft or post natively on `linkedin.com`, a LinkedIn Page **Super admin** adds that person on the LinkedIn Page under **Settings -> Manage admins** with the **Content admin** (or **Super admin**) role *(from LinkedIn's docs, unchecked)*.

---

## 2. Standalone App Constraint: Why a Second LinkedIn App Is Required

The existing LinkedIn developer app (`Spool Hub`, [`linkedin-app-setup.md`](./linkedin-app-setup.md)) already holds two self-serve products: **Share on LinkedIn** (`w_member_social`) and **Sign In with LinkedIn using OpenID Connect** (`openid profile email`).

According to LinkedIn's official Community Management API documentation on Microsoft Learn (`learn.microsoft.com/en-us/linkedin/marketing/community-management/community-management-overview`, read 2026-11-11):

- **Strict Standalone Product Rule**: LinkedIn requires that the **Community Management API** be the **only** API product provisioned on its developer application. If an app already holds or has requested any other product, LinkedIn disables the Community Management API request button *(from LinkedIn's docs, unchecked)*.
- **Clean Separation**: We do **not** remove products from the existing app (which would break live personal-profile sharing and LinkedIn OIDC sign-in). Instead, company-page publishing uses a **second, dedicated LinkedIn developer app** (`marketing.linkedin_org`) associated with the same verified company LinkedIn Page, with its own two Secret Manager slots created empty by terraform step `030` and shipped dark (`marketing.linkedin_org.inject: "false"`) until LinkedIn approves the app—matching the exact dark-launch pattern of [`x-app-setup.md`](./x-app-setup.md) (`SPL-5194`).

---

## 3. OAuth 2.0 Scopes & REST API Surface

### 3.1 Required OAuth 2.0 Scopes

The Community Management API OAuth flow (`marketing.LinkedInOrgScopes`) requests three organization scopes (no `openid profile`, because OpenID Connect is a separate product barred on a standalone Community Management app):

| Scope | Granted by | Purpose in Spool Hub |
|---|---|---|
| `rw_organization_admin` | Community Management API | Discover which LinkedIn Pages the authenticating member administers (`GET /rest/organizationAcls?q=roleAssignee&state=APPROVED`) and read each Page's name and vanity slug (`GET /rest/organizations/{id}`). |
| `w_organization_social` | Community Management API | Initialize and upload post thumbnail images owned by the organization (`POST /rest/images?action=initializeUpload` with `owner: "urn:li:organization:{id}"`) and publish organic feed posts as the organization (`POST /rest/posts` with `author: "urn:li:organization:{id}"`). |
| `r_organization_social` | Community Management API | Read back organization post metadata / verification on publish and support future reach and engagement metrics ([spec 163](../163-marketing-metrics/spec.md)) without requiring a second OAuth consent or app review. |

> [!NOTE]
> LinkedIn also documents a narrower `r_organization_admin` scope on some Marketing API surfaces; if LinkedIn's Community Management API portal provisions `r_organization_admin` alongside or in place of `rw_organization_admin` for read-only ACL lookup, cnf `marketing.linkedin_org.scopes` makes the scope string configurable without a code change. Spool Hub never mutates Page admin ACLs or Page profile settings.

### 3.2 Required LinkedIn REST Headers & Endpoints

Every call to `https://api.linkedin.com/rest/*` carries:
- `Authorization: Bearer <access_token>`
- `LinkedIn-Version: <YYYYMM>` (configured in cnf `marketing.linkedin_org.version`, e.g. active supported `YYYYMM` version, updated alongside `marketing.linkedin`)
- `X-Restli-Protocol-Version: 2.0.0`

Endpoints used:
1. **Authorization**: `GET https://www.linkedin.com/oauth/v2/authorization` (`response_type=code`, `client_id`, `redirect_uri`, `state`, `scope`). No PKCE (LinkedIn supports PKCE only for native mobile/public clients; this is a confidential web client with a client secret).
2. **Token Exchange & Refresh**: `POST https://www.linkedin.com/oauth/v2/accessToken` (`grant_type=authorization_code` on connect; `grant_type=refresh_token` before access token expiry).
3. **Organization Discovery**: `GET https://api.linkedin.com/rest/organizationAcls?q=roleAssignee&state=APPROVED` — returns the caller's approved organization role assignments (`organization` URN `urn:li:organization:<id>`, `role`, `state`, `roleAssignee` URN `urn:li:person:<id>`).
4. **Organization Metadata Lookup**: `GET https://api.linkedin.com/rest/organizations/{id}` (or batch `/rest/organizationsLookup?ids=List({id},...)`) — reads `localizedName` and `vanityName` for display in WUI settings and public Page links (`https://www.linkedin.com/company/<vanityName>`).
5. **Image Upload (Best-Effort Thumbnail)**: `POST https://api.linkedin.com/rest/images?action=initializeUpload` with `{"initializeUploadRequest": {"owner": "urn:li:organization:<id>"}}`, followed by `PUT <uploadUrl>` of the PNG/JPEG bytes (reusing `marketing.FetchBlogPicture`, which converts WEBP blog thumbnails to PNG; if image upload fails, the article card shares without a custom thumbnail, matching `shareOne` in `hub/marketing_share.go`).
6. **Organization Post Creation**: `POST https://api.linkedin.com/rest/posts` with:
   - `"author": "urn:li:organization:<id>"`
   - `"commentary"`: `EscapeLittleText` over `marketing.BlogArticle` (title, summary, link, and SPL-1855 leading emojis)
   - `"visibility": "PUBLIC"`
   - `"distribution": {"feedDistribution": "MAIN_FEED", "targetEntities": [], "thirdPartyDistributionChannels": []}`
   - `"content": {"article": {"source": "<blog_url>", "title": "...", "description": "...", "thumbnail": "<urn:li:image:...>"}}`
   - `"lifecycleState": "PUBLISHED"`
   - `"isReshareDisabledByAuthor": false`
   - Post URN read from response header `X-Restli-Id` (e.g. `urn:li:share:<id>` or `urn:li:ugcPost:<id>`), yielding permalink `https://www.linkedin.com/feed/update/<urn>`.

---

## 4. How the Hub Picks the Organization (Page Admin Roles)

1. **Eligible LinkedIn Page Roles**:
   When the connecting member completes OAuth consent, the hub filters the `elements` returned by `GET /rest/organizationAcls?q=roleAssignee&state=APPROVED` to entries where:
   - `state == "APPROVED"`, **and**
   - `role` is **`ADMINISTRATOR`** (LinkedIn Page *Super admin*) or **`CONTENT_ADMIN`** (LinkedIn Page *Content admin*).
   - Other LinkedIn Page roles—`ANALYST`, `CURATOR`, `LEAD_GEN_FORMS_MANAGER`, and `DIRECT_SPONSORED_CONTENT_POSTER` (which permits dark/ad posts only, not organic Page feed posts)—are ignored.
2. **Zero, One, or Multiple Pages**:
   - **Zero eligible Pages**: Nothing is stored; the callback HTML page (`connectPageBack`) tells the member that LinkedIn returned no Company Page where they hold an approved Super admin or Content admin role.
   - **One or more eligible Pages**: Mirroring Meta `T033` (`connectMeta` in `hub/marketing_meta_channels.go`), the hub upserts one `marketing_channels` row per eligible organization (`UNIQUE (tenant_id, platform, account_ref)` where `platform = 'linkedin_page'` and `account_ref = '<org_id>'`), sealing the token bundle for each connected Page channel and setting `auto_publish = false`.
   - **Selecting / Pruning Pages**: In `Tenant settings -> General`, `MarketingLinkedInPages.vue` lists every connected Company Page with its name, vanity handle, status, and **Disconnect** button (`DELETE /v1/marketing/channels/{channel_id}`). If a connector administers multiple Pages on LinkedIn and wants only one in the workspace, they disconnect the unwanted Page(s) in one click; publishing always targets an explicit `?channel=<channel_id>`.

---

## 5. Token Lifecycle, KMS Storage & Refresh Rotation

1. **Access & Refresh Token Lifetimes** (Microsoft Learn OAuth 2.0 docs, read 2026-11-11):
   - **Access token**: valid for **60 days** (`expires_in = 5184000` seconds).
   - **Refresh token**: issued to approved Community Management API apps, valid for **365 days** (`refresh_token_expires_in = 31536000` seconds) from initial authorization. Refreshing mints a fresh 60-day access token while keeping the original 365-day refresh expiry anchor.
   - **Graceful Fallback**: If LinkedIn omits `refresh_token` (for example in a restricted sandbox tier), the hub stores the access token alone and uses its 60-day `expires_at` seamlessly.
2. **Envelope-Encrypted Storage under FORCE RLS**:
   - Following `spec.md` §6 and X `T040` (`marketing.XToken`), the access token, its expiry timestamp, the optional refresh token, and the refresh expiry timestamp are serialized into a single JSON bundle (`LinkedInOrgToken`), wrapped in `marketing.Plaintext` (whose `String()` and `MarshalJSON()` emit `[redacted]`), and encrypted via `marketing.Sealer.Seal` (per-row AES-256-GCM data key wrapped by Cloud KMS key `marketing.kms_key`).
   - Only ciphertext and the KMS key resource name enter `marketing_channel_tokens` under PostgreSQL `FORCE ROW LEVEL SECURITY`. Plaintext tokens never touch logs, error strings, API responses, spool messages, or git.
3. **Compare-and-Swap Refresh Before Dispatch**:
   - Before a publish or retry sweep calls LinkedIn, if `access_expires_at` is within 5 minutes of `now` and an unexpired `refresh_token` is present, the hub calls `POST /oauth/v2/accessToken` (`grant_type=refresh_token`), seals the new bundle, and updates `marketing_channel_tokens` via `SwapMarketingToken` (compare-and-swap on the prior ciphertext, matching `xAccessToken` in `hub/marketing_x_dispatch.go`). If a concurrent hub instance won the swap first, the losing instance re-reads and opens the winner's freshly sealed bundle.
4. **Expiry Reminder & Revocation Handling**:
   - `marketing_channels.expires_at` stores the outer consent deadline (`refresh_expires_at` when present, ~365 days; else `access_expires_at`, ~60 days).
   - **7-day Reminder**: 7 days before `expires_at` (`marketingRemindBefore`), the sweep sends one email (`MarkMarketingReminded`) with the one-click re-connect URL (`/v1/marketing/linkedin-org/connect?workspace=<id>`).
   - **401 / Refresh Refusal**: If LinkedIn returns `401 Unauthorized`, `403` insufficient Page role (e.g. the connector was removed as Page admin on LinkedIn), or refuses the refresh token (`invalid_grant` / `400`), the hub marks the channel `expired`, emails the re-connect link to `delegated_by`, and keeps scheduled posts held (`Retry: true`) so nothing is lost and nothing is double-posted.

---

## 6. Data Model, Configuration & API Changes (Outline)

### 6.1 Database Migration (`csi-spl-rdb`)

One forward-only SQL migration `<next>_marketing_linkedin_page.sql` (continuing from `0272_marketing_x.sql`) widens `marketing_channels_platform_check`:

```sql
SET LOCAL lock_timeout = '5s';

ALTER TABLE marketing_channels DROP CONSTRAINT marketing_channels_platform_check;
ALTER TABLE marketing_channels ADD CONSTRAINT marketing_channels_platform_check
    CHECK (platform IN ('linkedin', 'facebook_page', 'instagram_business', 'x', 'linkedin_page'));
```

No other DDL is needed:
- `account_type = 'page'` is already permitted by `0236_marketing_meta.sql` (`CHECK (account_type IN ('personal', 'page', 'business'))`).
- `account_ref` holds the numeric LinkedIn organization ID (`<org_id>`); `account_name` holds `localizedName`.
- `metadata` (`jsonb` object from `0236`) holds `{"organization_urn": "urn:li:organization:<org_id>", "vanity_name": "<slug>", "role": "ADMINISTRATOR"|"CONTENT_ADMIN"}`—never a token.
- `auto_publish` is `false` (explicit human or authorized-agent publish only, per `spec.md` §16.3 & §17.1).
- Existing `FORCE ROW LEVEL SECURITY` policies (`0187_marketing.sql`), `marketing_posts` (`awaiting_approval`, `scheduled`, `dispatching`, `published`, `failed`, `skipped`), and append-only `marketing_post_events` apply unchanged.

### 6.2 Configuration & Terraform Step 030 (`csi-spl-cnf`, `csi-spl-iac`, `csi-spl-orc`)

1. **`csi-spl-cnf/csi-spl/all.env.yaml`** under `marketing:`:
   ```yaml
   linkedin_org:
     inject: "false"
     client_id_secret: csi-spl-hub-marketing-linkedin-org-client-id
     client_secret_secret: csi-spl-hub-marketing-linkedin-org-client-secret
     version: "202610"
     scopes: w_organization_social r_organization_social rw_organization_admin
   ```
2. **Step `030-cloud-run-hub`**: Creates the two empty Secret Manager secret slots (`csi-spl-hub-marketing-linkedin-org-client-id` and `csi-spl-hub-marketing-linkedin-org-client-secret`) with no secret version in Terraform state. Only when `marketing.linkedin_org.inject` is `"true"` (after versions exist and are pinned in `hub.secret_versions`) does `030` inject `SPOOL_HUB_MARKETING_LINKEDIN_ORG_CLIENT_ID`, `_CLIENT_SECRET`, `_VERSION`, and `_SCOPES`.
3. **Firebase Hosting Rewrite (`render-wui-firebase-json.sh`)**: Forwards `/api/v1/marketing/linkedin-org/callback` (`hub.LinkedInOrgCallbackPath`) to Cloud Run ahead of the SPA `**` fallback.

### 6.3 Hub API Routes (`csi-spl-api`)

| Method & Path | Gate | Behaviour |
|---|---|---|
| `GET /v1/marketing/linkedin-org/connect?workspace=<id>` | `marketingConnectMember` (`tenant.settings`) | `302` redirect to LinkedIn OAuth authorization URL on the Community Management app (`503 not_configured` while `inject: "false"`). |
| `POST /v1/marketing/linkedin-org/connect?workspace=<id>` | `marketingConnectMember` (`tenant.settings`) | Returns `{"authorize_url": "..."}` for the WUI (`OPTIONS` preflight supported). |
| `GET /v1/marketing/linkedin-org/callback` (and `/api/v1/...`) | Signed HMAC `state` (15 min TTL, domain-separated label `"spool-marketing-linkedin-org-state/v1"`) | Exchanges `code`, queries `organizationAcls` + `organizations`, seals token bundle via KMS, upserts `linkedin_page` channel(s) with `auto_publish = false`, renders `connectPageBack`. |
| `GET /v1/marketing/linkedin-org/pages` | `marketingRoute` (workspace member, marketing on) | Lists connected `linkedin_page` channels (`channel_id`, `organization_id`, `organization_urn`, `name`, `vanity_name`, `role`, `status`, `expires_at`, `delegated_by`; never a token). `503 not_configured` while `inject: "false"`. |
| `GET /v1/marketing/posts?channel=<channel_id>` | `linkedInOrgPublisher` (`tenant.settings`, §7) | Lists live blog posts from `blog-md/index.json` that have no row yet on that `linkedin_page` channel (`OPTIONS` preflight supported). |
| `POST /v1/marketing/posts/{id}/publish?channel=<channel_id>` | `linkedInOrgPublisher` (`tenant.settings` or agent via `X-Spool-Requester`, §7) | Records `awaiting_approval` -> `scheduled` (`post_held`, `post_approved`), claims under the rolling 24h 1-post cap (`ClaimMetaMarketingPosts`), uploads PNG/JPEG thumbnail for `urn:li:organization:<id>`, posts via `POST /rest/posts` as `urn:li:organization:<id>`, stores `platform_post_id` + permalink (`200`, `409` if already recorded, `503 not_configured` if dark). Without `?channel=`, existing personal-profile LinkedIn publish is unchanged. |
| `POST /v1/marketing/posts/{id}/manual-publish?channel=<channel_id>` | Existing `T036` gate | Marks a post `published` (`platform_post_id = 'manual'`, `post_handed_over`) when posted by hand. |
| `DELETE /v1/marketing/channels/{channel_id}` | `marketingConnectMember` (`tenant.settings`) | Existing `SPL-4496` disconnect: deletes the `linkedin_page` channel, its sealed token, and its post rows in one RLS transaction (`204`); `marketing_post_events` remains intact. |

Background retry & expiry sweep (`RunMarketingLinkedInOrgDispatch`, every minute when configured): fails stuck `dispatching` rows after 15 minutes, retries transient `429` / `503` / pre-send dial failures up to 3 attempts (never retrying unknown post-send outcomes or `500`/`502`/`504`), and runs the 7-day expiry reminder and expiry transition.

### 6.4 WUI & CLI (`csi-spl-wui`, `csi-spl-api/cmd/spool`)

- **WUI (`MarketingLinkedInPages.vue`)**: Lazy-loaded section in `Tenant settings -> General` (beside `MarketingAccounts.vue` and `MarketingXAccounts.vue`). On `503 not_configured`, displays one translated line ("LinkedIn company page publishing is not set up on this hub yet.") with no broken button. When configured, renders **Connect LinkedIn Page**, each connected Page's name, vanity link, status, expiry date, **Disconnect** confirmation (with instructions for revoking the app in LinkedIn settings), and **Publish** (opening `MarketingPublish.vue` with `?channel=<channel_id>` and button text naming the Company Page). All UI strings added to all 19 locale files (`i18n/locales/*.json`).
- **CLI / Desk Action**: `spool marketing-publish <post-id> --for <HUM-id> [--channel <channel-id>]` (and `do_spl_marketing_publish`) passes optional `CHANNEL_ID` as `?channel=<id>` so authorized agents can publish to a connected Company Page on a `biz_owner` or `admin`'s instruction (`SPL-1855`).

---

## 7. Role & Permission Rules (SPL-5196 Parity)

Company-page publishing enforces the exact workspace role rule established in **SPL-5196** (owner `HUM-10`, topic `19ef7d51` msg `8c73a054`, commit `03d8a7732`):

1. **Workspace Outer Gates**:
   - The workspace must be in cnf `marketing.workspaces` **and** have `tenants.marketing_enabled = true` (`404` otherwise, `T014`).
   - The demo workspace (`spec 077`) is unconditionally refused (`403`).
2. **Connecting & Disconnecting (`GET`/`POST .../connect`, `DELETE /v1/marketing/channels/{id}`)**:
   - Requires a signed-in workspace member holding `rbac.TenantSettings` (`biz_owner` or `admin` by the default roles in `internal/rbac/rbac.go`). Any other role (`product_owner`, `developer`, `tester`, `regular_user`, `guest`) gets `403` naming `tenant.settings`.
   - On LinkedIn's side, the connecting member must hold an `APPROVED` `ADMINISTRATOR` or `CONTENT_ADMIN` role on the target LinkedIn Page so LinkedIn issues a Page-capable token.
3. **Listing Unshared Posts & Publishing (`GET /v1/marketing/posts?channel=<id>`, `POST /v1/marketing/posts/{id}/publish?channel=<id>`)**:
   - **Any workspace `admin` or `biz_owner` (`rbac.TenantSettings`) may list and publish** on any active `linkedin_page` channel of that workspace—even if a different admin originally connected the Page. The post always goes out as the Company Page (`urn:li:organization:<id>`), never on the caller's personal profile.
   - **No Connector-Alone Bypass (SPL-5196 R7 W1)**: Holding `delegated_by` without currently holding `tenant.settings` is **refused (`403` naming `tenant.settings`)**. If the member who connected the Page is later demoted from `admin` / `biz_owner`, neither they nor an agent naming them can list or publish.
   - **Authorized Agent Door (`SPL-1855`)**: A box upload token calling `POST /v1/marketing/posts/{id}/publish?channel=<id>` with `X-Spool-Requester: <HUM-id>` succeeds only when `<HUM-id>` currently holds `tenant.settings` in that workspace **and** `seatActsFor` passes (a box joined `for_human` another member gets `403`).

---

## 8. Verification & Test Plan

Every implementation lane for `T041` ships with red-first controls (`developer-guide.md` §2.12.1):

1. **PostgreSQL Schema & Store (`PRE_PUSH_TIER=full`)**:
   - `lint-migration` on `<next>_marketing_linkedin_page.sql`.
   - `seedTenantAll` (`crosstenant_test.go`) updated with a `linkedin_page` row so `TestCrossTenantEveryTable` and `TestRLSPoliciesFailClosed` prove tenant isolation.
   - Store tests on real PostgreSQL: `TestMarketingLinkedInPageChannelRLS`, `SwapMarketingToken` race (two concurrent refreshes keep one winner), `ClaimMetaMarketingPosts` rolling 24h cap (1 post / 24h per Page channel, in-flight `dispatching` counted), append-only `marketing_post_events`.
   - *Red control*: inserting `platform = 'linkedin_page'` on the pre-migration schema fails `marketing_channels_platform_check`.
2. **LinkedIn Org Client & Hub Route Tests (`internal/marketing`, `internal/hub`, `httptest` fake LinkedIn)**:
   - OAuth authorize URL scopes (`w_organization_social r_organization_social rw_organization_admin`) and HMAC state domain separation (a personal LinkedIn state is rejected with `400 bad_state` on `/linkedin-org/callback`, and vice versa).
   - `organizationAcls` filtering: `APPROVED` `ADMINISTRATOR` and `CONTENT_ADMIN` create `linkedin_page` channels with `auto_publish = false`; `REQUESTED` / `REVOKED` states and `ANALYST` / `DIRECT_SPONSORED_CONTENT_POSTER` roles are ignored.
   - Token refresh before access expiry + CAS update; `401` / `invalid_grant` transitions channel to `expired`, holds post unsent, and mails one-click re-connect link; `429` / `503` retries up to 3 times; post-send connection drop (`ErrUnknownOutcome`) and `500` fail once without retry so a Company Page never double-posts.
   - Image upload (`owner: "urn:li:organization:<id>"`) + post payload (`author: "urn:li:organization:<id>"`, `EscapeLittleText`).
   - **SPL-5196 Role Gate Tests**: non-connector `admin` and `biz_owner` get `200` on list and publish; `developer` / `regular_user` get `403`; **demoted connector** gets `403` naming `tenant.settings` (member session and agent `X-Spool-Requester`); demo workspace gets `403`; dark config (`inject: "false"`) answers `503 not_configured` on all `/v1/marketing/linkedin-org/*` routes and `?channel=<linkedin_page>`; log-capture assertion proves plaintext tokens never appear in logs or JSON responses.
3. **IaC & Hosting Rewrite Tests (`csi-spl-iac`, `csi-spl-orc`)**:
   - `ENV=dev ./run -a do_tpl_gen` and `ENV=prd ./run -a do_tpl_gen` produce zero diff.
   - `hub-marketing-linkedin-org-030.tst.sh` verifies empty secret slots when `inject: "false"` and env/secret mounts when `inject: "true"` (with red control).
   - `wui-actions.tst.sh` verifies `/api/v1/marketing/linkedin-org/callback` precedes `**` in rendered `firebase.json`.
4. **WUI Unit, i18n & Playwright E2E Tests (`csi-spl-wui`)**:
   - `tests/unit/marketing-linkedin-page.test.mjs`, `i18n-parity.test.mjs` (all 19 locales), `i18n-untranslated.test.mjs`, `i18n-no-raw-text.test.mjs`, `pnpm run typecheck`.
   - `tests/e2e/marketing-linkedin-page.test.mjs` at `1440` and `390` px against mock bundle: dark `503` notice, Page list, publish as Company Page, disconnect dialog, non-admin `403` notice, with `PROVE_RED` controls.

---

## 9. What Stays Out of Scope

1. **Modifying or Replacing Personal Profile LinkedIn Publishing**: The existing app (`marketing.linkedin`, `w_member_social` + OIDC sign-in) and personal-profile publishing remain untouched; a workspace may use either or both.
2. **Unapproved Automatic Broadcasting**: `linkedin_page` channels ship with `auto_publish = false`; background sweeps never publish a new blog post without an explicit `admin` / `biz_owner` (or authorized agent) publish call, and never back-fill old blog posts.
3. **Free-Text Ad-Hoc Composer or `marketing.workspaces: [all]`**: Content remains strictly source-backed from the live blog index ("no source, no post", `spec.md` §4.2).
4. **Paid Ads, Dark Posts, Sponsored Content & Lead Gen Forms**: LinkedIn Advertising APIs (`r_ads`, `rw_ads`, `DIRECT_SPONSORED_CONTENT_POSTER`) are out of scope.
5. **Two-Way Social CRM**: Reading, replying to, or moderating inbound LinkedIn Page comments, reactions, or Page messages in the WUI is out of scope (`spec.md` §10 item 8).
6. **Analytics Dashboards in `T041`**: While `r_organization_social` is requested upfront to avoid a second LinkedIn review later, reach/impression ingestion and UI belong to [spec 163](../163-marketing-metrics/spec.md).
7. **Agent Portal Actions**: Agents never log in to LinkedIn, create developer apps, verify Company Pages, or submit partner review forms.

---

## 10. OWNER-ONLY: Applying for LinkedIn Community Management API Access

Creating the LinkedIn developer application, verifying organization ownership, and submitting the Community Management API access form require the owner's personal LinkedIn Super Admin session and legal company details. **These steps are strictly OWNER-ONLY; no agent may execute them.**

> [!IMPORTANT]
> None of the LinkedIn Developer Portal screens below were visited or tested by an agent. Every portal step, field name, tier rule, and review wait estimate below is **from LinkedIn's docs, unchecked** (`learn.microsoft.com/en-us/linkedin/marketing/community-management/community-management-overview`, read 2026-11-11). Portal labels may differ slightly in the live UI.

### 10.1 Expected Review Wait Times *(from LinkedIn's docs, unchecked)*

LinkedIn gates the Community Management API in two sequential tiers:

| Stage | What It Unlocks | What LinkedIn Reviews | Expected Wait *(from LinkedIn's docs, unchecked)* |
|---|---|---|---|
| **Stage A: Development Tier** (apply now) | OAuth scopes `w_organization_social`, `r_organization_social`, `rw_organization_admin` for testing and internal company Page use under daily call caps (~500 app calls/day, ~100 member calls/day). Sufficient to build and verify `T041` end-to-end on our own Company Page. | Registered legal business entity, corporate domain email, verified LinkedIn Company Page, privacy policy URL, and written use-case form. | Typically **10–14 business days** (up to **30 business days** during review backlogs). LinkedIn closes applications if follow-up emails go unanswered for **21 days**. |
| **Stage B: Standard Tier** (apply after `T041` is built & tested) | Full production rate limits for multi-workspace commercial use across customer Company Pages. | Working integration in Development Tier plus a **2–3 minute video screencast** demonstrating OAuth consent, Page selection, human approval, and live Page post creation. | Typically an additional **10–14 business days** (up to **30 business days**). |

### 10.2 Numbered Owner Steps in the LinkedIn Developer Portal

1. **Confirm Super Admin role on the Company LinkedIn Page** *(from LinkedIn's docs, unchecked)*:
   - Sign in to LinkedIn with the owner account and open the Csitea LinkedIn Company Page.
   - Ensure your account holds the **Super admin** role on the Page (required both to verify the developer app in Step 3 and to approve Community Management API organization access).
   - *(Optional, unrelated to the API request)*: If you want `HUM-24` to post manually inside LinkedIn's web UI right away while LinkedIn reviews the API request, open the Company Page -> **Settings** -> **Manage admins** -> **Add admin**, search for the member, and assign **Content admin** (or **Super admin**).

2. **Create a NEW, standalone LinkedIn Developer App** *(from LinkedIn's docs, unchecked)*:
   - Open `https://www.linkedin.com/developers/apps` and click **Create app**.
   - **Why a new app**: Do **not** edit the existing `Spool Hub` app (which holds *Share on LinkedIn* and *Sign In with LinkedIn*). LinkedIn requires Community Management API apps to hold **zero other API products**; on an app with existing products, the request button is disabled.
   - Fill in the Create App form:
     - **App name**: e.g. `Spool Hub Org Publishing` or `Csitea Spool Hub Pages` *(LinkedIn branding rule: never include "LinkedIn", "Linked", or "In" in the app name, or review is automatically rejected)*.
     - **LinkedIn Page**: select the official Csitea LinkedIn Company Page *(cannot be changed after creation)*.
     - **Privacy policy URL**: `https://<BASE_DOMAIN>/privacy` (replacing `<BASE_DOMAIN>` with the production domain).
     - **App logo**: upload the square 512x512 Spool Hub icon (`csi-spl-wui/src/public/icons/icon-512.png`).
     - Tick **I have read and agree to these terms** (API Terms of Use) and click **Create app**.
   - **Critical**: Do **not** add *Share on LinkedIn*, *Sign In with LinkedIn*, or *Advertising API* on the **Products** tab of this new app.

3. **Verify the Company Page on the new app** *(from LinkedIn's docs, unchecked)*:
   - In the new app, open the **Settings** tab.
   - Under **Company**, click **Verify** next to the associated Csitea LinkedIn Page.
   - Click **Generate URL**, open that verification URL in the browser signed in as the Page **Super admin**, and click **Verify** / **Approve**.
   - Refresh the **Settings** tab and confirm the Page displays **Verified** with the verification date.

4. **Register the OAuth 2.0 Authorized Redirect URLs** *(from LinkedIn's docs, unchecked)*:
   - Open the **Auth** tab -> **OAuth 2.0 settings** -> click the edit pencil next to **Authorized redirect URLs for your app**.
   - Add both exact callback URLs (substituting `<BASE_DOMAIN>` with the real apex domain, no trailing slash):
     - Production: `https://<BASE_DOMAIN>/api/v1/marketing/linkedin-org/callback`
     - Development: `https://dev.<BASE_DOMAIN>/api/v1/marketing/linkedin-org/callback`
   - Click **Update**. *(Do not copy or paste the Client ID or Client Secret into any chat or message yet; once the code lane adds the empty Secret Manager slots in step `030`, an agent will provide the out-of-band stdin pipe command with your go).*

5. **Request Community Management API (Development Tier)** *(from LinkedIn's docs, unchecked)*:
   - Open the **Products** tab on the new app.
   - Locate **Community Management API** and click **Request access** (or **Select** -> **Access request form**).
   - Complete the organization and compliance fields:
     - **Organization legal name & registered business address**: Csitea's official registered legal name and address.
     - **Business email address**: a corporate `@csitea.net` address (LinkedIn rejects personal/freemail domains such as Gmail/Outlook; check the inbox immediately for LinkedIn's email verification link if prompted).
     - **Company website URL**: `https://<BASE_DOMAIN>` (or corporate website URL).
     - **Privacy policy URL**: `https://<BASE_DOMAIN>/privacy`.
     - **Primary use case / solution category**: select **Page Management** / **Content Publishing** (organic Page content management, not Advertising).
     - **Application / Use-case description**: paste the draft text from §10.3 below (adjusting the legal company name / website URL if a separate field asks for it).
   - Tick the terms agreement and click **Submit**.

6. **Monitor Reviewer Follow-Up & Approval** *(from LinkedIn's docs, unchecked)*:
   - Watch the corporate email inbox associated with the application and the app's **Products** tab status (`Review in progress` -> `Approved` / `Added`).
   - If LinkedIn's review team asks a clarifying question by email, reply within **21 days** so the ticket is not auto-closed.
   - Once **Development Tier** shows approved on the **Products** tab (and the **Auth** tab lists `w_organization_social`, `r_organization_social`, `rw_organization_admin` under OAuth 2.0 scopes), post a short note in topic `12d8a588-6bfd-4085-867a-c738aa916cbb` so the implementation lane (`T041`) can wire step `030` and store the Client ID and Client Secret out of band.

7. **Later — Upgrade from Development Tier to Standard Tier** *(from LinkedIn's docs, unchecked)*:
   - Once `T041` is deployed and verified on our own Company Page under Development Tier, if multi-customer / higher-quota production access is needed, return to **Products** -> **Community Management API** -> **Upgrade to Standard Tier**, record a 2–3 minute screencast showing the live OAuth login, Page selection, human publish click in Spool Hub, and resulting post on the LinkedIn Company Page, and submit the upgrade form.

### 10.3 Draft Use-Case Text (Ready to Paste)

Paste the following text into the Community Management API use-case / application description field in Step 5 *(replace `<BASE_DOMAIN>` with the live domain before submitting)*:

```text
Spool Hub (https://<BASE_DOMAIN>), operated by Csitea, is a multi-tenant team collaboration and release-communication workspace for software and operations teams.

Use case — Delegated Organization Page Publishing with Human Approval:
Workspace administrators and business owners publish official product release announcements, engineering blog articles, and documentation tips to their organization's own LinkedIn Company Page directly from their Spool Hub workspace, without sharing personal LinkedIn credentials among team members.

How the integration uses the Community Management API:
1. OAuth 2.0 Authorization & Admin Discovery (rw_organization_admin):
   An authenticated workspace administrator connects their LinkedIn account via standard 3-legged OAuth 2.0. Spool Hub queries /rest/organizationAcls (q=roleAssignee, state=APPROVED) and /rest/organizations to list only the LinkedIn Company Pages where that member holds an approved ADMINISTRATOR or CONTENT_ADMIN role, so the workspace binds its official Company Page.
2. Human-Approved Organic Content Publishing (w_organization_social):
   When a new article or release note is published on the organization's verified blog, an authorized workspace administrator or business owner explicitly reviews the item in Spool Hub and triggers publication. Spool Hub uploads the article's thumbnail image via /rest/images (owner urn:li:organization:{id}) and publishes one organic article post via /rest/posts (author urn:li:organization:{id}). Automated posting is strictly rate-limited to at most 1 post per Company Page per 24 hours; there is no unapproved auto-posting, no bulk scheduling spam, and no paid/dark ad creation.
3. Post Verification & Page Content Metrics (r_organization_social):
   Spool Hub reads back publication status and basic organic post performance for the organization's own published updates inside the workspace.

Security, Privacy & Compliance:
- OAuth access and refresh tokens are envelope-encrypted at rest using Google Cloud KMS and isolated per workspace under PostgreSQL Row-Level Security.
- Users can disconnect a LinkedIn Company Page at any time in workspace settings, which immediately deletes stored tokens.
- Spool Hub never requests LinkedIn passwords, never scrapes LinkedIn pages, and never sells, shares, or transfers LinkedIn member or organization data to third parties.
```

<!-- version: 0.1.0 · updated: 2026-11-11 · issue: SPL-5252 -->
