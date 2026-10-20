# 149: per-user Google Calendar connect (bidirectional synchronization between Spool Hub calendar and Google Calendar)

**Feature ID**: `149-google-calendar-connect` · **Milestone**: M3 · **Status**: Planned (Spec Only) · **Version**: 0.1.0
**Created**: 2026-10-21 · **Epic**: SPL-2750 · **Issue**: SPL-2750 · **Lane**: a-658-spec-149-gcal-connect
**Authority**: this file for system architecture, dependency gap analysis, prerequisite contracts, database schema, OAuth 2.0 flow, token envelope encryption, synchronization engine, event mappings, conflict handling, and acceptance criteria. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, task lifecycle)
- [005 WUI](../005-spool-wui/spec.md) (Slack-like interface, layout, theming)
- [010 social auth](../010-spool-social-auth/spec.md) (Google OAuth 2.0 authorization-code flow, CSRF state verification, HttpOnly cookie nonce)
- [017 security hardening](../017-spool-security-hardening/spec.md) (DB owner/runtime split, envelope encryption, edge limits)
- [023 user settings & rail order](../023-spool-user-settings-keys/spec.md) (user settings tabs, Integrations section)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (workspace isolation, role boundaries)
- [027 spool performance](../027-spool-performance/spec.md) (155 KB initial gzip budget, lazy chunk loading)
- [089 calendar section](../089-calendar-section/spec.md) (calendar view, baseline event schema, audience, reminders)
- [090 marketing automation](../090-marketing-automation/spec.md) (per-user OAuth token envelope encryption with Cloud KMS AES-256-GCM data key, `seal.go`)
- [097 calendar full editing](../097-calendar-full-editing/spec.md) (extended calendar schema, recurrence RRULE, guests, props)
- [106 calendar phone rewrite](../106-calendar-phone-rewrite/spec.md) (mobile calendar layout and responsive dialogs)
- [112 calendar sync foundation](../112-goals-strategy-roadmap/spec.md) (`source_key` idempotency, partial unique index, upsert semantics)
- [148 local dev mode](../148-local-dev-mode/spec.md) (local dev compose profiles, offline testing with fake API stand-in)

`<BASE_DOMAIN>`, `<fqdn>`, `<workspace_id>`, `<tenant>`, `<human_id>`, `<connection_id>`, `<event_id>`, `<google_event_id>`, `<secret>`, `<token>`, `<client_id>`, and `<channel_id>` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, or API headers.

---

## 0. The Owner's Request & Business Intent (Verbatim, Binding)

Section 11 of folder `089-calendar-section` and section 9 of folder `097-calendar-full-editing` explicitly left general two-way Google, Outlook, and CalDAV sync out of scope for the core workspace calendar:
- `089-calendar-section/spec.md` §11: *"Two-way CalDAV / Google Calendar / Outlook synchronization."*
- `097-calendar-full-editing/spec.md` §9: *"Two-way sync with Google / Outlook / CalDAV, room and resource booking, working-hours and out-of-office events, appointment schedules... Each can get its own spec if the owner asks."*

The business reality that prompted this dedicated specification is that individual engineers and team members maintain their personal schedules, meetings, and external commitments inside Google Calendar. To ensure seamless time coordination between humans and autonomous agents without double-booking or scheduling blind spots, one person needs the ability to connect that person's Spool Hub calendar to that person's personal Google Calendar.

The mandate was formalized in topic `18e7d023-8eaa-4f19-8026-cb905b3ffcbc` on `spool-hub.ai` under tracking epic **SPL-2750** (*Spec 149 - per-user Google calendar connect*).

### Core Principles

1. **P1: Strictly Per-User Connection (No Domain-Wide Delegation)**: Each connection is initiated and authorized by an individual human member (`HUM-*`) for that member's own Google account. Spool Hub never requests Google Workspace domain-wide delegation or service account impersonation. A user can connect and disconnect at will without administrative intervention.
2. **P2: Strict Workspace & User Isolation via RLS**: Synchronization credentials, mapping tables, and sync tokens belong strictly to `(tenant_id, human_id)`. PostgreSQL Row Level Security (RLS) with `tenant_scope` and `operator_scope` guarantees that no workspace or user can ever read, modify, or sync another member's Google Calendar data.
3. **P3: Cloud KMS Envelope Encryption for Stored OAuth Tokens**: OAuth 2.0 refresh and access tokens are never persisted in plaintext or in readable environment variables. Following the proven pattern in `internal/marketing/seal.go` (Spec 090), each token is encrypted with a unique AES-256-GCM data key wrapped by Google Cloud KMS (`spool-kms-token-wrap`). The database stores only the sealed ciphertext blob and the KMS key version. In-memory representations use `Plaintext` wrappers that redact secrets from logs and traces.
4. **P4: Incremental Delta Synchronization with Push Webhooks**: Synchronization avoids expensive polling and quota exhaustion by pairing Google Calendar Push Notifications (watch channels) with incremental delta synchronization via Google's `syncToken`. Periodic polling is kept strictly as a low-frequency reconciliation fallback.
5. **P5: Deterministic Bidirectional Sync & Loop Prevention**: Changes made in Spool Hub reflect in Google Calendar, and changes made in Google Calendar reflect in Spool Hub. Every synchronized event carries a cryptographic content hash (`sync_hash`) and Google ETag to reliably suppress echo loops and prevent infinite update cycles.
6. **P6: Privacy & Audience Respect**: Spool Hub's audience model (`public`, `internal`, `private`) is strictly respected. Spool events marked `private` synchronize to Google Calendar with `visibility: "private"`. External Google Calendar events marked "private" or "busy" synchronize into Spool Hub as `private` events owned exclusively by that user.
7. **P7: Target Calendar Choice (Primary vs Dedicated "Spool Hub" Secondary Calendar)**: To prevent cluttering a user's primary personal calendar, the connect flow allows the user to choose between syncing into their primary Google Calendar or into an auto-provisioned secondary calendar named `Spool Hub (<workspace_name>)`.
8. **P8: Clean Revocation & Teardown**: Disconnecting immediately revokes the OAuth grant at Google, stops active push watch channels, securely zeroes out encrypted credentials, and gives the user the choice to retain or purge synced event copies.

---

## 1. Cloud & Integration Seam Inventory (Measured from Code)

Every seam between Spool Hub and Google Calendar was measured directly from the repository code.

### 1.1 Seams Breakdown by Dependency Area

#### 1. Google Calendar REST API v3 Integration
- **Cloud Reality**: Google Calendar exposes REST endpoints under `https://www.googleapis.com/calendar/v3/`. Key resources: `calendars`, `events`, `channels`.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/cloud/cloud.go:1` (GCP client factory)
  - `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go:200` (Hub API routing)
- **Requirements**:
  - `GET /calendars/{calendarId}/events`: listing events, initial sync, incremental sync via `syncToken`.
  - `POST /calendars/{calendarId}/events`: creating synced events.
  - `PATCH /calendars/{calendarId}/events/{eventId}`: updating existing events.
  - `DELETE /calendars/{calendarId}/events/{eventId}`: deleting events.
  - `POST /calendars/{calendarId}/events/watch`: creating push notification channels.
  - `POST /channels/stop`: stopping active push notification channels.
- **Quota & Rate Limits**: Google enforces a default quota of 500 requests per 100 seconds per user, and 1,000,000 requests per day per project. The sync engine must employ token bucket rate limiting and exponential backoff on HTTP 403 `rateLimitExceeded` and HTTP 429.

#### 2. OAuth 2.0 Authorization Flow & Scopes
- **Cloud Reality**: Google OAuth 2.0 authorization-code flow with PKCE and state protection.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go:102` (`GoogleClient` implementation)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/token.go:45` (CSRF state generation and validation)
  - `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:120` (OAuth callback handling)
- **Scope Distinction**:
  - Spool native sign-in uses OIDC scopes: `openid email profile` (`csi-spl-cnf/csi-spl/all.env.yaml:352`).
  - Google Calendar connect is an **incremental authorization grant** for an already authenticated workspace member:
    - Write access: `https://www.googleapis.com/auth/calendar.events` (read/write access to events only; does not grant permissions to delete full calendars or manage sharing access).
    - Optional Read-only access: `https://www.googleapis.com/auth/calendar.events.readonly`.
  - The authorization request uses `access_type=offline` and `prompt=consent` to obtain a long-lived `refresh_token`.

#### 3. Token Vaulting & Cloud KMS Envelope Encryption
- **Cloud Reality**: Storing third-party OAuth refresh and access tokens requires bank-grade envelope encryption to prevent credential leakage in database backups or dumps.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/marketing/seal.go:1-171` (`seal.go` envelope seal using AES-256-GCM data key wrapped by Cloud KMS CryptoKey)
  - `csi-spl-api/src/go/spool-hub-api/internal/marketing/seal_fake.go:10` (`FakeKMS` for local tests)
- **Design Pattern**:
  - The calendar connection package reuses the envelope encryption architecture defined in `internal/marketing/seal.go`:
    ```
    Token Plaintext -> AES-256-GCM Encrypt with unique Data Key -> Ciphertext
    Data Key -> Cloud KMS Encrypt (spool-kms-token-wrap) -> Wrapped Data Key
    Sealed Payload = v1:base64(WrappedKey):base64(Nonce):base64(Ciphertext)
    ```
  - At rest in Postgres: only the sealed string and the Cloud KMS key version are stored.
  - At runtime in memory: tokens are wrapped in `Plaintext` types whose `String()`, `GoString()`, and `MarshalJSON()` return `[redacted]`.

#### 4. Relational Persistence & Schema Additions
- **Cloud Reality**: PostgreSQL 16 on Cloud SQL with strict RLS (`0125_calendar.sql`, `0139_calendar_full_edit.sql`, `0156_calendar_source_key.sql`).
- **Code Citations**:
  - `csi-spl-rdb/src/sql/postgres/spool-hub/0125_calendar.sql:19` (`calendar_events` table)
  - `csi-spl-rdb/src/sql/postgres/spool-hub/0139_calendar_full_edit.sql:22` (`props jsonb`, `rrule`, `recurring_event_id`)
  - `csi-spl-rdb/src/sql/postgres/spool-hub/0156_calendar_source_key.sql:23` (`source_key text NULL`, partial unique index)
- **Gaps / What is Needed**:
  - A table tracking per-user Google connections: `user_google_calendar_connections`.
  - A table tracking bidirectional event mappings and sync metadata: `calendar_event_external_sync`.

#### 5. Sync Engine Architecture & Directionality
- **Cloud Reality**: Bidirectional synchronization between Spool Hub and Google Calendar.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/store/calendar_postgres.go:1` (Spool calendar persistence)
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/live.go:1` (WebSocket live broadcast of event mutations)
- **Supported Modes**:
  1. `bidirectional` (default): Spool <-> Google.
  2. `spool_to_google` (export-only): Spool events sync to Google; Google events are ignored.
  3. `google_to_spool` (import-only): Google events sync to Spool; Spool events remain local.

#### 6. Google Push Notification Webhooks (Watch Channels)
- **Cloud Reality**: Google delivers push notifications for calendar modifications via webhook HTTP POST.
- **Code Citations**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/server.go:150` (Public webhook routing)
  - `csi-spl-iac/src/terraform/031-gcp-hub-ingress/03-cloud-run.tf:1` (Cloud Run ingress)
- **Webhook Handshake & Verification**:
  - Incoming HTTP POST to `https://<BASE_DOMAIN>/api/v1/webhooks/google-calendar`.
  - Headers inspected:
    - `X-Goog-Channel-ID`: matches active connection `channel_id`.
    - `X-Goog-Resource-ID`: matches Google watch channel resource.
    - `X-Goog-Resource-State`: `sync` (handshake verification) or `exists` (change notification).
    - `X-Goog-Channel-Token`: HMAC-SHA256 signature containing tenant and human ID.
  - Return HTTP 200 within 200 ms to satisfy Google's webhook SLA; queue background sync task.

#### 7. Incremental Delta Sync via `syncToken`
- **Cloud Reality**: Google Calendar API provides incremental synchronization via `syncToken`.
- **Flow**:
  - On first sync: full list query with `timeMin` (e.g. 30 days back); retrieve events and store `nextSyncToken`.
  - On subsequent sync: call `events.list` passing `syncToken`. Google returns only items created, updated, or deleted since that token.
  - Expired tokens (`HTTP 410 Gone`): Google purges sync tokens after 7 days of inactivity. The sync engine catches 410, clears the invalid token, and transparently initiates a full re-sync.

#### 8. Loop Prevention & Echo Suppression
- **Problem**: When Spool updates Google, Google fires a webhook. Without echo suppression, Spool would treat Google's update as a new remote change and update Spool, creating an infinite feedback loop.
- **Mechanism**:
  - Spool computes a normalized content hash:
    `sync_hash = SHA256(title + "
" + starts_at + "
" + ends_at + "
" + all_day + "
" + location + "
" + rrule + "
" + status)`
  - When writing to Google, Spool stores the updated `sync_hash` and the Google `etag`.
  - When receiving a change from Google, Spool calculates the hash. If the incoming hash matches the stored `sync_hash`, the update was originated by Spool and is skipped.

#### 9. Conflict Resolution Matrix
- **Problem**: Simultaneous edits in both Spool Hub and Google Calendar within the sync window.
- **Rules**:
  - If Spool `updated_at` > Google `updated`: Spool wins; updates Google.
  - If Google `updated` > Spool `updated_at`: Google wins; updates Spool.
  - If timestamps are within 1 second: Spool Hub (system of record for the workspace) wins.
  - Deletion vs Edit: Deletion takes precedence unless configured otherwise by user preference.

#### 10. Event Model Mapping (Spool <-> Google)
- **Wire Mapping**:
  - `title` <-> `summary`
  - `description` <-> `description`
  - `starts_at` / `ends_at` / `all_day` <-> `start` / `end` (`dateTime` formatted in RFC 3339, or `date` formatted in `YYYY-MM-DD` for all-day)
  - `time_zone` <-> `timeZone`
  - `props.location` <-> `location`
  - `rrule` <-> `recurrence` array (RFC 5545 syntax: `RRULE:FREQ=...`)
  - `props.reminders` <-> `reminders.overrides` (method: `popup`, converted to whole minutes)
  - `audience` (`public`, `internal`, `private`) <-> `visibility` (`default`, `private`, `confidential`)
  - `calendar_guests` <-> `attendees` (matching email addresses)

#### 11. User Interface Surface (WUI)
- **Placement**:
  - Modal: **Settings -> Integrations -> Google Calendar** (lazy loaded chunk `~/components/settings/integrations.vue`).
  - Contextual: Calendar header dropdown menu contains **"Connect Google Calendar"** / **"Sync with Google"**.
  - Shows: Connection state, connected Google account email, target calendar name, sync direction toggle, last sync timestamp, "Sync now" manual trigger, and "Disconnect" button with data retention options.

#### 12. Local Dev Mode & Offline Test Stand-in (Spec 148 Alignment)
- **Local Dev Reality**: Per Spec 148 §2.3.1, cloud social providers are out of scope for local dev mode.
- **Stand-in**:
  - In `none` / `local` cloud provider mode, real Google OAuth endpoints and webhooks are unavailable.
  - The hub provides a local mock adapter (`internal/calendar/sync/fake_google_api.go`) and test harness.
  - Unit and integration tests verify the entire OAuth handshake, KMS envelope encryption, delta sync, echo suppression, and conflict resolution pipeline offline with zero external network calls.

---

### 1.2 Summary Gap Table

| # | Service Area | Production Reality | In-Tree Code Reference | Current Behavior | Spec 149 Target Design | Gap Status |
|---|---|---|---|---|---|---|
| **1** | **Google Calendar API** | Google Calendar v3 REST API | `internal/cloud/cloud.go:1` | None | Client library wrapper with rate-limiting & backoff | **Planned**: new client package |
| **2** | **OAuth Scopes** | Incremental `calendar.events` scope | `internal/auth/idp.go:102` | Sign-in only (`openid email profile`) | Dedicated user integration OAuth connect route | **Planned**: incremental auth |
| **3** | **Token Security** | Cloud KMS Envelope Encryption | `internal/marketing/seal.go:1` | Marketing tokens sealed | Reuses `seal.go` AES-256-GCM + Cloud KMS | **Ready**: proven pattern |
| **4** | **Persistence** | PostgreSQL 16 with RLS | `0125_calendar.sql`, `0139_calendar_full_edit.sql` | Workspace calendar events | Additive DDL: connections & sync mappings | **Planned**: migration required |
| **5** | **Sync Direction** | Bidirectional (Two-way) | `internal/store/calendar_postgres.go` | Local events only | Bidirectional sync engine with configurable direction | **Planned**: new sync engine |
| **6** | **Webhooks** | Google Watch Push Notifications | `internal/hub/server.go:150` | None | Dedicated webhook receiver `POST /api/v1/webhooks/google-calendar` | **Planned**: webhook ingress |
| **7** | **Delta Sync** | Google `syncToken` API | `0156_calendar_source_key.sql` | Sync foundation on master | Delta sync token tracking & 410 reset handling | **Planned**: incremental sync |
| **8** | **Echo Suppression** | Hash & ETag matching | `0156_calendar_source_key.sql` | Upsert by `source_key` | SHA-256 `sync_hash` + ETag loop suppression | **Planned**: deduplication engine |
| **9** | **Conflicts** | Last-Write-Wins with If-Match | `specs/097-calendar-full-editing` §4.2 | 409 edit_conflict on Spool | Timestamp LWW + ETag optimistic concurrency | **Planned**: conflict matrix |
| **10**| **Model Mapping** | RFC 5545 RRULE & RFC 3339 | `0139_calendar_full_edit.sql:27` | RRULE in Postgres | Lossless two-way mapping between schemas | **Planned**: mapping package |
| **11**| **WUI Surface** | Nuxt 3 Settings Dialog | `components/SettingsDialog.vue:74` | Profile, keys, security tabs | Async "Integrations" section & calendar action | **Planned**: WUI components |
| **12**| **Offline Tests** | In-memory Mock Google API | `internal/marketing/seal_fake.go:10` | FakeKMS available | Mock Google Calendar server for 100% offline tests | **Planned**: test harness |

---

## 2. Architecture & Topology

```
+─────────────────────────────────────────────────────────────────────────────────────────────────────────+
|                                           USER WORKSTATION (WUI)                                        |
|  - Settings -> Integrations -> Google Calendar                                                          |
|  - Connect Button / OAuth Consent Popup / Sync Status Badge / Manual Sync Trigger                       |
+────────────────────────────────────────────────────┬────────────────────────────────────────────────────+
                                                     │ HTTPS (Session Cookie)
                                                     ▼
+─────────────────────────────────────────────────────────────────────────────────────────────────────────+
|                                            SPOOL HUB API                                                |
|                                                                                                         |
|  ┌───────────────────────────────────────────────────────────────────────────────────────────────────┐  |
|  │ HTTP INGRESS & ROUTING (net/http ServeMux)                                                        │  |
|  │ - GET  /api/v1/user/integrations/google-calendar/connect   (Initiate OAuth flow, CSRF cookie)     │  |
|  │ - GET  /api/v1/user/integrations/google-calendar/callback  (Exchange code, seal tokens via KMS)   │  |
|  │ - GET  /api/v1/user/integrations/google-calendar/status    (Connection state, target cal, stats)  │  |
|  │ - POST /api/v1/user/integrations/google-calendar/sync      (Trigger on-demand reconciliation)     │  |
|  │ - DEL  /api/v1/user/integrations/google-calendar/disconnect(Revoke grant, stop watch, purge data) │  |
|  │ - POST /api/v1/webhooks/google-calendar                    (Receive Google push notifications)    │  |
|  └───────────────────┬───────────────────────────────────────────────────────┬───────────────────────┘  |
|                      │                                                       │                          |
|                      ▼                                                       ▼                          |
|  ┌──────────────────────────────────────────────┐        ┌───────────────────────────────────────────┐  |
|  │ TOKEN VAULT & KMS ENVELOPE ENCRYPTION        │        │ SYNCHRONIZATION ENGINE                    │  |
|  │ - internal/calendar/sync/seal.go             │        │ - Delta Sync Controller (syncToken)       │  |
|  │ - AES-256-GCM Data Key per Token             │        │ - Echo Suppressor (SHA-256 sync_hash)     │  |
|  │ - Cloud KMS Wrap: spool-kms-token-wrap       │        │ - Conflict Resolver (Timestamp LWW)       │  |
|  │ - Plaintext Redaction Wrapper [redacted]     │        │ - Event Model Mapper (RFC 5545 / RFC 3339)│  |
|  │ - Token Auto-Refresh on Expiry (401 catch)   │        │ - Channel Watch Renewer (Daily cron)      │  |
|  └───────────────────┬──────────────────────────┘        └───────────────────┬───────────────────────┘  |
+──────────────────────┼───────────────────────────────────────────────────────┼──────────────────────────+
                       │                                                       │
         SQL over TCP  │ (RLS: tenant_id, human_id)              HTTPS REST API│ (Bearer Access Token)
                       ▼                                                       ▼
+──────────────────────────────────────────────┐         +─────────────────────────────────────────────┐
|           POSTGRESQL 16 (CLOUD SQL)          |         |              GOOGLE CLOUD ESTATE            |
|                                              |         |                                             |
|  - calendar_events (0125, 0139, 0156)        |         |  ┌───────────────────────────────────────┐  |
|  - user_google_calendar_connections (New)    |         |  │ Cloud KMS: spool-kms-token-wrap       │  |
|  - calendar_event_external_sync (New)        |         |  └───────────────────────────────────────┘  |
|  - Strict Row Level Security Policies        |         |  ┌───────────────────────────────────────┐  |
|                                              |         |  │ Google Calendar REST API v3           │  |
|                                              |         |  │ - Primary / Secondary Calendars       │  |
|                                              |         |  │ - Push Notification Channels (Watch)  │  |
|                                              |         |  └───────────────────────────────────────┘  |
+──────────────────────────────────────────────+         +─────────────────────────────────────────────+
```

### 2.1 Per-User OAuth 2.0 Connect Handshake

The connect handshake follows RFC 6749 and RFC 7636 (PKCE):
1. **Initiation**: The signed-in user clicks **Connect Google Calendar** in the WUI. The browser requests `GET /api/v1/user/integrations/google-calendar/connect`.
2. **CSRF State & Nonce**:
   - The hub generates a cryptographically secure 32-byte random nonce.
   - The hub mints an HMAC-SHA256 signed `state` containing: `{tenant_id, human_id, nonce, exp: now + 15m}`.
   - The nonce is set as an `HttpOnly`, `SameSite=Lax`, `Path=/api/v1/user/integrations/google-calendar/` cookie named `spool_gcal_oauth_nonce`.
3. **Redirect to Google**: The hub responds with a `302 Found` redirecting the browser to Google's consent screen:
   - `client_id`: loaded from Secret Manager (`csi-spl-hub-auth-google-client-id`).
   - `redirect_uri`: `https://<BASE_DOMAIN>/api/v1/user/integrations/google-calendar/callback`.
   - `response_type`: `code`.
   - `scope`: `https://www.googleapis.com/auth/calendar.events`.
   - `access_type`: `offline` (required to obtain refresh token).
   - `prompt`: `consent` (ensures Google returns a refresh token on every connect).
   - `state`: signed state token.
4. **Consent & Callback**: The user consents; Google redirects back to the callback URL with `code` and `state`.
5. **State & Cookie Validation**:
   - The hub verifies the HMAC signature on `state` and confirms it has not expired.
   - The hub compares the `nonce` inside `state` with the value in `spool_gcal_oauth_nonce` cookie.
   - The hub asserts that `tenant_id` and `human_id` inside `state` match the caller's active session.
   - The cookie is immediately cleared.
6. **Token Exchange & Envelope Seal**:
   - The hub exchanges `code` with `https://oauth2.googleapis.com/token`.
   - The returned `refresh_token` and `access_token` are sealed using Cloud KMS envelope encryption.
   - The connection record is inserted or updated in `user_google_calendar_connections`.
   - The hub redirects the user back to the WUI settings view with `?gcal_status=connected`.

### 2.2 Token Vaulting & Secure Lifecycle

1. **Envelope Encryption Execution**:
   - Every token string is wrapped in `marketing.NewPlaintext(token)`.
   - A fresh 32-byte AES-256 data key is generated from `crypto/rand`.
   - The token is encrypted using AES-GCM with a 12-byte random IV and AAD `spool-gcal-token/v1`.
   - The data key is encrypted via Cloud KMS (`kms.Encrypt(ctx, "spool-kms-token-wrap", dataKey)`).
   - The sealed string stored in the database has format:
     `v1:<kms_key_version>:<base64(wrapped_data_key)>:<base64(iv)>:<base64(ciphertext_and_tag)>`
2. **Access Token Refresh Routine**:
   - Access tokens have a 1-hour TTL.
   - Prior to making Google API calls, the sync engine checks `token_expiry`.
   - If `time.Now().Add(5 * time.Minute).After(token_expiry)`, the engine unwraps the sealed `refresh_token`, calls `https://oauth2.googleapis.com/token` (`grant_type=refresh_token`), seals the new `access_token`, and updates `user_google_calendar_connections`.
3. **Revocation Handling**:
   - If Google returns `invalid_grant` during refresh (user revoked access from Google Account Settings), the connection is marked `sync_status = "revoked"`.
   - The user is notified in the WUI via a status banner: *"Google Calendar connection revoked. Please reconnect."*

### 2.3 Calendar Selection (Primary vs Secondary)

During connection setup (or via settings), the user chooses the target calendar:
1. **Option A: Dedicated Secondary Calendar (Default & Recommended)**:
   - The hub checks for an existing secondary calendar with title `Spool Hub (<workspace_name>)`.
   - If not present, the hub calls `POST /calendars` with `{summary: "Spool Hub (" + workspaceName + ")"}`.
   - Benefit: Clean separation; Spool events can be shown or hidden with a single checkbox in Google Calendar; deletion of Spool events does not risk personal events.
2. **Option B: Primary Calendar**:
   - The user explicitly selects their primary Google Calendar (`primary`).
   - Events are written directly into the main schedule.

### 2.4 Bidirectional Synchronization Engine & Echo Suppression

1. **Outbound Sync (Spool Hub -> Google Calendar)**:
   - Triggered by Spool event creation, update, or deletion.
   - The engine checks if the creator or guests have an active Google Calendar connection.
   - Translates the Spool event into Google Calendar JSON.
   - Calculates `sync_hash = SHA256(canonical(event))`.
   - Calls Google Calendar API:
     - New event: `POST /calendars/{id}/events` -> returns Google `id` and `etag`. Recorded in `calendar_event_external_sync`.
     - Update: `PATCH /calendars/{id}/events/{google_id}` with `If-Match: etag`.
     - Delete: `DELETE /calendars/{id}/events/{google_id}`.
   - Updates `calendar_event_external_sync` with new `etag`, `sync_hash`, and `last_synced_at`.
2. **Inbound Sync (Google Calendar -> Spool Hub)**:
   - Triggered by Google push notification webhook or scheduled reconciliation.
   - The engine calls `GET /calendars/{id}/events?syncToken={token}`.
   - For each returned item:
     - Check if `id` exists in `calendar_event_external_sync`:
       - If yes and incoming `etag` / computed `sync_hash` matches stored: **Echo detected -> Skip**.
       - If yes and remote `updated` is newer than Spool `updated_at`: update Spool event.
       - If item `status == "cancelled"`: soft-delete corresponding Spool event.
       - If not mapped: create new Spool event with `audience = "private"`, `creator_id = human_id`, and `source_key = "google:" + connection_id + ":" + google_event_id`.
   - Store the new `nextSyncToken` in `user_google_calendar_connections`.

### 2.5 Google Push Notification Webhooks & Channel Renewal

1. **Watch Channel Registration**:
   - Upon connection, the hub registers a push channel:
     ```json
     POST https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events/watch
     {
       "id": "<channel_uuid>",
       "type": "web_hook",
       "address": "https://<BASE_DOMAIN>/api/v1/webhooks/google-calendar",
       "token": "<hmac_signed_channel_token>",
       "params": { "ttl": "604800" }
     }
     ```
   - Google responds with `resourceId` and `expiration` timestamp (maximum 7 days).
   - Stored in `user_google_calendar_connections` (`channel_id`, `channel_resource_id`, `channel_expiry`).
2. **Channel Maintenance Cron**:
   - Google watch channels expire after 7 days.
   - A daily background job (`do_spl_gcal_channel_renew` or in-hub runner) identifies connections where `channel_expiry < now + 24 hours`.
   - The job stops the expiring channel (`POST /channels/stop`) and mints a fresh watch channel.

### 2.6 Conflict Resolution Matrix

| Scenario | Spool State | Google State | Resolution Rule | Action Taken |
|---|---|---|---|---|
| **Simultaneous Edit** | Modified at $T_1$ | Modified at $T_2$ ($T_2 > T_1$) | Google Newer | Google updates Spool; Spool `sync_hash` updated. |
| **Simultaneous Edit** | Modified at $T_1$ | Modified at $T_2$ ($T_1 > T_2$) | Spool Newer | Spool updates Google with `PATCH`; Google ETag updated. |
| **Simultaneous Edit** | Modified at $T_1$ | Modified at $T_1$ (Tie) | Spool Authoritative | Spool Hub wins; overwrites Google. |
| **Delete in Spool / Edit in Google** | Soft-deleted in Spool | Modified in Google | Deletion Precedence | Event deleted from Google; remains soft-deleted in Spool. |
| **Edit in Spool / Delete in Google** | Modified in Spool | Cancelled in Google | Deletion Precedence | Spool marks event soft-deleted (`deleted_at = now()`). |
| **Unmapped Event Created in Google**| Does not exist | Created in Google | Private Import | Created in Spool as `private` event owned by user. |

---

## 3. Database Schema & Relational Persistence

Additive, forward-only DDL following repository conventions (`0125_calendar.sql`, `0139_calendar_full_edit.sql`, `0156_calendar_source_key.sql`).

### 3.1 Additive DDL Migration Script (`0162_google_calendar_sync.sql`)

```sql
-- 0162_google_calendar_sync.sql - per-user Google calendar sync (specs/149, SPL-2750).
-- Forward-only, additive.

-- 1. Per-user Google calendar connections
CREATE TABLE user_google_calendar_connections (
    connection_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id             text        NOT NULL,
    google_account_email text        NOT NULL CHECK (length(google_account_email) BETWEEN 3 AND 255),
    calendar_id          text        NOT NULL DEFAULT primary CHECK (length(calendar_id) <= 255),
    calendar_title       text        NOT NULL DEFAULT  CHECK (length(calendar_title) <= 255),
    sync_direction       text        NOT NULL DEFAULT bidirectional
        CHECK (sync_direction IN (bidirectional, spool_to_google, google_to_spool)),
    sync_status          text        NOT NULL DEFAULT connected
        CHECK (sync_status IN (connected, syncing, error, revoked, paused)),
    sync_token           text        NULL,
    channel_id           uuid        NULL,
    channel_resource_id  text        NULL,
    channel_expiry       timestamptz NULL,
    sealed_access_token  text        NOT NULL,
    sealed_refresh_token text        NOT NULL,
    kms_key_version      text        NOT NULL,
    token_expiry         timestamptz NOT NULL,
    last_synced_at       timestamptz NULL,
    error_message        text        NOT NULL DEFAULT ,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_gcal_one_conn_per_human UNIQUE (tenant_id, human_id)
);

CREATE INDEX user_gcal_conn_tenant ON user_google_calendar_connections (tenant_id, human_id);
CREATE INDEX user_gcal_conn_channel ON user_google_calendar_connections (channel_id) WHERE channel_id IS NOT NULL;
CREATE INDEX user_gcal_conn_expiry ON user_google_calendar_connections (channel_expiry) WHERE channel_expiry IS NOT NULL;

-- 2. Row Level Security for user_google_calendar_connections
ALTER TABLE user_google_calendar_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_google_calendar_connections FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON user_google_calendar_connections
    USING (tenant_id = NULLIF(current_setting(app.tenant_id, true), ))
    WITH CHECK (tenant_id = NULLIF(current_setting(app.tenant_id, true), ));

CREATE POLICY operator_scope ON user_google_calendar_connections
    USING (current_setting(app.rls_scope, true) = operator)
    WITH CHECK (current_setting(app.rls_scope, true) = operator);

-- 3. External synchronization mapping table
CREATE TABLE calendar_event_external_sync (
    sync_id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           text        NOT NULL,
    event_id            uuid        NOT NULL,
    human_id            text        NOT NULL,
    external_system     text        NOT NULL DEFAULT google CHECK (external_system IN (google)),
    external_event_id   text        NOT NULL CHECK (length(external_event_id) BETWEEN 1 AND 512),
    external_etag       text        NOT NULL DEFAULT ,
    sync_hash           text        NOT NULL CHECK (length(sync_hash) = 64),
    last_synced_at      timestamptz NOT NULL DEFAULT now(),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE,
    CONSTRAINT calendar_external_sync_unique_event UNIQUE (tenant_id, event_id, human_id, external_system),
    CONSTRAINT calendar_external_sync_unique_remote UNIQUE (tenant_id, external_system, external_event_id)
);

CREATE INDEX cal_ext_sync_lookup ON calendar_event_external_sync (tenant_id, external_system, external_event_id);
CREATE INDEX cal_ext_sync_event ON calendar_event_external_sync (tenant_id, event_id);

-- 4. Row Level Security for calendar_event_external_sync
ALTER TABLE calendar_event_external_sync ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_event_external_sync FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON calendar_event_external_sync
    USING (tenant_id = NULLIF(current_setting(app.tenant_id, true), ))
    WITH CHECK (tenant_id = NULLIF(current_setting(app.tenant_id, true), ));

CREATE POLICY operator_scope ON calendar_event_external_sync
    USING (current_setting(app.rls_scope, true) = operator)
    WITH CHECK (current_setting(app.rls_scope, true) = operator);
```

### 3.2 Workspace & Human Isolation

- **Tenant Isolation**: Both tables enforce RLS using `tenant_scope` matching `NULLIF(current_setting(app.tenant_id, true), )`. Cross-tenant queries are blocked at the database engine level.
- **Human Isolation**: The unique constraint `user_gcal_one_conn_per_human` restricts each human in a workspace to exactly one Google Calendar connection. Endpoints in the hub authenticate the session, extract `session.HumanID`, and append `WHERE human_id = $session_human_id` to every query, preventing members from viewing or modifying peer credentials.
- **Referential Integrity**: `calendar_event_external_sync` uses the composite foreign key `FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE`. If a Spool event is permanently purged, its sync mapping row is automatically cascaded.

---

## 4. API & Webhook Specifications (The Calls)

All endpoints adhere to Spool Hub conventions: JSON bodies, RFC 3339 UTC timestamps, standard error structures `{"error": "<code>", "detail": "<msg>"}`, and session authentication.

### 4.1 Connection Management Endpoints

#### 1. Initiate Connect Flow
`GET /api/v1/user/integrations/google-calendar/connect`
- **Auth**: Authenticated human session (`HUM-*`).
- **Query Params**:
  - `redirect`: Optional path in WUI to return to upon completion (default: `/settings?section=integrations`).
  - `calendar_mode`: `secondary` (default, creates "Spool Hub") or `primary`.
- **Response**: `302 Found` with `Location: https://accounts.google.com/o/oauth2/v2/auth?...` and sets `spool_gcal_oauth_nonce` cookie.

#### 2. OAuth Callback
`GET /api/v1/user/integrations/google-calendar/callback`
- **Auth**: Public entrance; validates cookie and state.
- **Query Params**: `code`, `state`.
- **Response**: `302 Found` redirecting to `<APP_URL>/settings?section=integrations&gcal_status=connected` or `gcal_error=<code>`.

#### 3. Connection Status
`GET /api/v1/user/integrations/google-calendar/status`
- **Auth**: Authenticated human session.
- **Response**: `200 OK`
  ```json
  {
    "connected": true,
    "google_account_email": "engineer@example.com",
    "calendar_id": "c_188f9a2b...@group.calendar.google.com",
    "calendar_title": "Spool Hub (Dev Workspace)",
    "sync_direction": "bidirectional",
    "sync_status": "connected",
    "last_synced_at": "2026-10-21T00:15:00Z",
    "events_synced": 42
  }
  ```
  If not connected: `{"connected": false}`.

#### 4. Disconnect
`DELETE /api/v1/user/integrations/google-calendar/disconnect`
- **Auth**: Authenticated human session.
- **Request Body**:
  ```json
  {
    "purge_synced_events": false
  }
  ```
- **Behavior**: Calls Google `revoke` endpoint, stops watch channel, deletes connection row from `user_google_calendar_connections`, and optionally deletes events originated by Google.
- **Response**: `204 No Content`.

### 4.2 Synchronization Endpoints

#### 1. Trigger Manual Sync
`POST /api/v1/user/integrations/google-calendar/sync`
- **Auth**: Authenticated human session.
- **Response**: `200 OK`
  ```json
  {
    "status": "completed",
    "synced_outbound": 3,
    "synced_inbound": 1,
    "synced_at": "2026-10-21T00:15:30Z"
  }
  ```

#### 2. Update Sync Settings
`PATCH /api/v1/user/integrations/google-calendar/settings`
- **Auth**: Authenticated human session.
- **Request Body**:
  ```json
  {
    "sync_direction": "spool_to_google"
  }
  ```
- **Response**: `200 OK` with updated connection object.

### 4.3 Webhook Ingress Route

#### Google Push Notification Receiver
`POST /api/v1/webhooks/google-calendar`
- **Auth**: Public route; authenticated by headers:
  - `X-Goog-Channel-ID`: matches active channel.
  - `X-Goog-Channel-Token`: matches HMAC-SHA256 signature.
  - `X-Goog-Resource-State`: `sync` (returns 200 immediately) or `exists` (schedules sync).
- **Processing**:
  - Validates channel token.
  - Returns `200 OK` immediately (within 200 ms).
  - Enqueues background delta sync job for `connection_id`.

### 4.4 Refusal Tokens & Error Codes

| Error Code | HTTP Status | Meaning |
|---|---|---|
| `unauthorized` | 401 | Missing or invalid Spool session cookie. |
| `invalid_state` | 400 | OAuth state signature invalid, expired, or nonce mismatch. |
| `gcal_not_connected` | 404 | Operation requested on a non-existent connection. |
| `sync_in_progress` | 409 | Manual sync triggered while a sync operation is already running. |
| `gcal_token_revoked` | 403 | Google refresh token was revoked by user in Google Account. |
| `gcal_rate_limited` | 429 | Google Calendar API quota exceeded; backoff required. |
| `invalid_channel_token` | 403 | Webhook request failed HMAC channel token validation. |

---

## 5. Non-Cloud / Test Scenarios & End-to-End Acceptance

### 5.1 Measured End-to-End Scenarios

#### Scenario 1: Connection Authorization Handshake
- **Flow**: User navigates to Settings -> Integrations, clicks "Connect Google Calendar". The hub generates CSRF nonce cookie, signs state with HMAC, redirects to Google consent endpoint. Upon callback, hub verifies state and cookie, exchanges code for tokens, seals tokens via KMS envelope encryption, inserts row into `user_google_calendar_connections`, and registers a Google watch channel.
- **Verification**: Database holds sealed tokens with `kms_key_version`; cookie is cleared; connection status reads `connected`.

#### Scenario 2: Connection Status Query
- **Flow**: WUI queries `GET /api/v1/user/integrations/google-calendar/status`.
- **Verification**: Returns `200 OK` with Google account email, selected calendar title, sync status, and last synced timestamp.

#### Scenario 3: Initial Full Baseline Synchronization
- **Flow**: On initial connection, the sync engine queries Spool calendar events for the workspace where user is creator or guest, and queries Google Calendar via `events.list` with `timeMin = now - 30d`.
- **Verification**: Missing events are created on both sides; mapping table `calendar_event_external_sync` records pairs with `sync_hash`; initial `syncToken` saved.

#### Scenario 4: Outbound Sync — Event Created in Spool Hub
- **Flow**: User creates an event in Spool Hub ("Sprint Planning"). The calendar store trigger notifies the sync engine. Sync engine converts event, calls `POST /calendars/{id}/events`, receives Google event ID, and inserts mapping row.
- **Verification**: Event appears in Google Calendar with matching summary, start/end, and location.

#### Scenario 5: Outbound Sync — Event Updated in Spool Hub
- **Flow**: User drags "Sprint Planning" to a new time slot in Spool Hub. Sync engine calls `PATCH /calendars/{id}/events/{google_id}` with updated start/end.
- **Verification**: Google Calendar event reflects the updated time; mapping row `sync_hash` and `etag` updated.

#### Scenario 6: Outbound Sync — Event Soft-Deleted in Spool Hub
- **Flow**: User deletes an event in Spool Hub (`deleted_at = now()`).
- **Verification**: Sync engine calls `DELETE /calendars/{id}/events/{google_id}`; event is removed from Google Calendar.

#### Scenario 7: Inbound Sync — Google Calendar Push Notification & Delta Sync
- **Flow**: Google fires webhook POST to `/api/v1/webhooks/google-calendar` with `X-Goog-Resource-State: exists`. Hub validates headers, responds 200, and triggers delta sync using `syncToken`.
- **Verification**: Hub lists events with `syncToken`, processes remote changes, updates Spool calendar, and persists updated `nextSyncToken`.

#### Scenario 8: Inbound Sync — Event Created in Google Calendar
- **Flow**: User creates a personal appointment ("Dentist") in Google Calendar. Inbound delta sync receives the event.
- **Verification**: Spool Hub creates a calendar event with `audience = "private"`, `creator_id = human_id`, and `source_key = "google:" + connection_id + ":" + google_event_id`.

#### Scenario 9: Inbound Sync — Event Updated in Google Calendar
- **Flow**: User moves "Dentist" by 1 hour in Google Calendar. Inbound sync receives delta.
- **Verification**: Spool Hub updates the corresponding event's `starts_at` and `ends_at`.

#### Scenario 10: Inbound Sync — Event Deleted in Google Calendar
- **Flow**: User deletes "Dentist" in Google Calendar. Inbound delta sync receives item with `status = "cancelled"`.
- **Verification**: Spool Hub soft-deletes the event (`deleted_at = now()`).

#### Scenario 11: Echo Suppression & Loop Prevention Verification
- **Flow**: An event is updated in Spool Hub and pushed to Google. Google fires a push notification webhook. The hub executes delta sync and receives the updated Google event.
- **Verification**: The hub computes `sync_hash`. Because it matches `sync_hash` in `calendar_event_external_sync`, the hub recognizes the change originated locally and skips re-importing. Zero secondary updates occur.

#### Scenario 12: Token Refresh & Expiration Handling
- **Flow**: Sync engine attempts an API call with an expired access token (`token_expiry < now`).
- **Verification**: Sync engine unseals `refresh_token`, requests fresh tokens from `oauth2.googleapis.com`, seals the new `access_token`, updates `token_expiry`, and transparently completes the calendar API call.

#### Scenario 13: Revocation Detection
- **Flow**: User revokes Spool's access in their Google Account security dashboard. Sync engine receives HTTP 400 `invalid_grant` during refresh.
- **Verification**: Connection status transitions to `revoked`. WUI displays reconnect notification. No crashes or unhandled panics.

#### Scenario 14: Workspace & Member Isolation Proof (Multi-Tenant Test)
- **Flow**: Member $M_1$ in Workspace $W_1$ connects Google Calendar. Member $M_2$ in Workspace $W_2$ attempts to query or sync $M_1$'s connection.
- **Verification**: RLS blocks the query (`0 rows returned`). Direct API calls by $M_2$ return `404 gcal_not_connected`.

#### Scenario 15: Clean Disconnect & Teardown
- **Flow**: User clicks "Disconnect" in WUI. Hub stops watch channel via `POST /channels/stop`, calls Google token revocation endpoint, and removes connection row.
- **Verification**: Google watch channel stopped; database connection row purged; future webhooks rejected with 403.

---

### 5.2 Acceptance Walkthrough

```
1. PREREQUISITES & DATABASE MIGRATION
   -> Database migration 0162_google_calendar_sync.sql applied.
   -> Tables user_google_calendar_connections and calendar_event_external_sync present with RLS.

2. CONNECT INITIATION & OAUTH FLOW
   -> Signed-in user HUM-01 opens Settings -> Integrations -> Google Calendar.
   -> Clicks "Connect Google Calendar".
   -> Redirects to Google consent screen requesting calendar.events scope.
   -> User authorizes; Google returns code to /api/v1/user/integrations/google-calendar/callback.
   -> Hub exchanges code, seals tokens with Cloud KMS envelope encryption, registers watch channel.
   -> Browser lands back in Settings showing: "Connected to engineer@example.com (Spool Hub)".

3. OUTBOUND SYNCHRONIZATION
   -> User creates event "Agent Team Sync" (10:00 - 11:00 UTC) in Spool Hub.
   -> Sync engine pushes event to Google Calendar.
   -> Google Calendar displays "Agent Team Sync" in "Spool Hub" calendar.
   -> calendar_event_external_sync records mapping with sync_hash.

4. INBOUND SYNCHRONIZATION & ECHO SUPPRESSION
   -> Google delivers push notification webhook to /api/v1/webhooks/google-calendar.
   -> Hub processes delta sync: echo suppressor verifies sync_hash match and terminates cleanly.
   -> User edits event in Google Calendar (moves to 11:00 UTC).
   -> Google delivers push notification.
   -> Hub delta sync updates Spool event starts_at to 11:00 UTC.

5. DISCONNECTION & TEARDOWN
   -> User clicks "Disconnect" in WUI Settings.
   -> Hub unregisters watch channel, revokes Google grant, and removes connection row.
   -> Status returns to disconnected.
```

---

## 6. Rollout Plan (Build Rows)

The implementation is broken down into nine independent, strictly disjoint build rows:

| Row | Area | Deliverable / Task | Affected Files | Verification Command |
|---|---|---|---|---|
| **B1** | `rdb` | Additive DDL migration: `user_google_calendar_connections` and `calendar_event_external_sync` with RLS | `csi-spl-rdb/src/sql/postgres/spool-hub/0162_google_calendar_sync.sql` | `bash csi-spl-orc/src/bash/tests/test-db-migrations.tst.sh` |
| **B2** | `api` | Token envelope encryption & KMS seal wrapper for Google Calendar tokens | `csi-spl-api/src/go/spool-hub-api/internal/calendar/sync/seal.go` | `go test ./src/go/spool-hub-api/internal/calendar/sync/... -run TestSeal` |
| **B3** | `api` | Google Calendar REST API v3 client wrapper (rate limiter, retries, backoff) | `csi-spl-api/src/go/spool-hub-api/internal/calendar/sync/gcal_client.go` | `go test ./src/go/spool-hub-api/internal/calendar/sync/... -run TestClient` |
| **B4** | `api` | OAuth 2.0 connect, callback, disconnect, and status HTTP handlers | `csi-spl-api/src/go/spool-hub-api/internal/calendar/sync/handler.go` | `go test ./src/go/spool-hub-api/internal/calendar/sync/... -run TestHandlers` |
| **B5** | `api` | Bidirectional sync engine: delta sync, model mapper, echo suppression, conflict resolution | `csi-spl-api/src/go/spool-hub-api/internal/calendar/sync/engine.go` | `go test ./src/go/spool-hub-api/internal/calendar/sync/... -run TestSyncEngine` |
| **B6** | `api` | Google Calendar push notification webhook receiver & watch channel renewer | `csi-spl-api/src/go/spool-hub-api/internal/calendar/sync/webhook.go` | `go test ./src/go/spool-hub-api/internal/calendar/sync/... -run TestWebhook` |
| **B7** | `wui` | WUI Settings -> Integrations section & Google Calendar connection component | `csi-spl-wui/src/components/settings/integrations.vue` | `pnpm --dir csi-spl-wui test:unit` |
| **B8** | `doc` | User & operator documentation: connecting Google Calendar & security FAQ | `csi-spl-doc/doc/help/google-calendar-connect.md` | `cd csi-spl-iac && ./run -a do_check_dist_hygiene` |
| **B9** | `test`| End-to-end integration test suite exercising all 15 scenarios with mock Google API | `csi-spl-orc/src/bash/tests/test-gcal-sync-scenarios.tst.sh` | `bash csi-spl-orc/src/bash/tests/test-gcal-sync-scenarios.tst.sh` |

---

## 7. Architectural Decisions & Alignment

1. **Incremental User Scope vs Workspace-Wide Service Account**:
   - *Decision*: Strictly per-user incremental OAuth authorization (`calendar.events`).
   - *Rationale*: Workspace members frequently belong to different corporate Google domains or personal Google accounts. Domain-wide delegation is impossible across heterogeneous email domains and introduces extreme security risk. Per-user authorization adheres to the principle of least privilege and preserves user privacy.
2. **Dedicated Secondary Calendar vs Primary Calendar Default**:
   - *Decision*: Default to creating a dedicated secondary calendar named `Spool Hub (<workspace_name>)`, with an opt-in toggle to use the primary calendar.
   - *Rationale*: Writing hundreds of workspace and agent coordination events directly into a user's primary calendar creates clutter and increases the blast radius of accidental deletions. A dedicated secondary calendar can be toggled on/off in Google Calendar view and cleanly isolated.
3. **Echo Suppression via Content Hashing**:
   - *Decision*: Store SHA-256 `sync_hash` of canonical event fields alongside Google ETags.
   - *Rationale*: Webhooks fire on every modification, including those originated by Spool Hub itself. Content hashing reliably identifies local updates and suppresses infinite echo loops without relying on fragile timing heuristics.
4. **Push Webhooks with Polling Fallback**:
   - *Decision*: Google Watch push notifications as primary trigger; daily reconciliation as fallback.
   - *Rationale*: Polling Google Calendar for thousands of users exhausts project API quotas rapidly. Push webhooks deliver sub-second latency while keeping quota consumption minimal.

---

<!-- version: 0.1.0 · updated: 2026-10-21 · last-edit: 2026-10-21T00:15:00Z -->
