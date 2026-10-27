# 149 Per-user Google Calendar connect

Version v1.0 (2026-10-23), the panel's signed spec. Step 2 of the owner
rule for a big change: the written spec, then the panel, then the build.
v0.1 (`ef6adfcf3`, lane a-658, 2026-10-21), the editor's re-measure (v0.2,
`9acbb6efe`), the claude seat c-576's review of v0.2 (msg `842249e3`) and
its re-check of v0.3 (msg `1f8697a5`) (section 10). The owner gave the go
to build on 2026-10-23 21:42Z ("Go, implement", msg `40744f59`, relayed by
c-002 msg `a9c444bf`), so v1.0 did not wait for the agy seat, which had
not been placed (agy out of quota); it did not review and does not sign
(section 11). Build rows B1-B5 are landed on master (B1: 3d88cca60, B2: 2e3c1534c, B3: b02cd72bc, B4: bf5a169e4, B5: 01e3724d4); rows B6a-B10 not yet built.

Source: prd topic in the owner's workspace,
`topic:838e3484-d09c-4cd8-b06a-0c211d00e535`. Issue: SPL-3098 (this panel),
epic SPL-2750. Each build row in section 6 gets its own issue when it is
placed.

Paths used below:

- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`, `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `wui/` = `csi-spl-wui/src/`
- `cnf/` = `csi-spl-cnf/csi-spl/`

Every `file:line` was read on origin/master `dff1b61d6` (the panel sha) by
the editor and re-read on `19a6be809` for the v0.3 changes (`git diff --stat
9acbb6efe 19a6be809 -- csi-spl-api csi-spl-rdb csi-spl-cnf csi-spl-wui/src`
touches none of the cited paths, per the seat) and checked again for
v1.0 on `72a60c102` (`git diff --stat dff1b61d6 72a60c102 -- csi-spl-api
csi-spl-rdb csi-spl-cnf csi-spl-wui/src` -> 11 files, under
`internal/hubclient/`, `internal/lockkey/`, two help pages, `utils/poll.mjs`
and two `src/bash` scripts: none of them cited; `ls rdb/ | tail -1` ->
`0214_topic_priorities.sql`, so `<next>` is still 0215), with `git show`, `git grep -n`, `grep -n` or `sed -n` on that
tree. Nothing was read from prd or GCP: no GCP call was made. A claim about
Google's own behaviour that the editor did not test is marked "unchecked,
I believe".

Builds on, and does not repeat: [010 social auth](../010-spool-social-auth/spec.md),
[023 user settings](../023-spool-user-settings-keys/spec.md),
[089 calendar](../089-calendar-section/spec.md),
[090 marketing automation](../090-marketing-automation/spec.md) (the LinkedIn
connect: the one per-member OAuth connect on master, and this spec's
template), [097 calendar full editing](../097-calendar-full-editing/spec.md),
[112 roadmap sync](../112-goals-strategy-roadmap/spec.md) (`source_key`),
[148 local dev mode](../148-local-dev-mode/spec.md).
(`test -f <dir>/spec.md` for each: all 7 present.)

Per the owner's wording rule this spec says **workspace**; **tenant**
appears only in code identifiers and columns.

## 0. The owner's ask, verbatim

HUM-10, prd t1 topic `838e3484`, 2026-10-20 20:20:44Z, msg `ef9dea71` (and
`2dec5907` before it):

> "Each user should be an Ble to connect their spool hub calendar with their google one"

2026-10-23 15:55Z: "what is the status of this one".

What it opens: 089 section 11 and 097 section 9 left two-way Google sync
out of scope ("Each can get its own spec if the owner asks"); he asked.

Principles kept from v0.1: a member connects their own Google account (no
domain-wide delegation, no service account impersonation); tokens are
stored only sealed (KMS envelope); a member's connection and its rows are
invisible to every other member and workspace; disconnect revokes at Google.

## 1. What exists on master (re-measured)

### 1.1 Nothing of the feature is built

`git grep -nIiE 'googleapis.com/(calendar|auth/calendar)|calendar\.events|text/calendar|\.ics\b|webcal' dff1b61d6 -- csi-spl-api csi-spl-wui/src csi-spl-cnf csi-spl-iac csi-spl-rdb`
-> no Google Calendar or iCalendar code (the only hits are the
`WebCalendarEvent` type names and one `calendar.events_n` locale key). So
every case in section 5 is red on master today unless marked (C).

### 1.2 v0.1 section 1 claims, checked

| # | v0.1 claim | measured on `dff1b61d6` | verdict |
|---|---|---|---|
| 1 | `internal/cloud/cloud.go:1` is a "GCP client factory" for Calendar | `api/internal/cloud/cloud.go:1-5`: the hub's cloud provider switch (spec 076, `SPOOL_CLOUD_PROVIDER` gcp/none/aws); it knows nothing of Calendar | WRONG: not a seam; a new `api/internal/gcal/` package is |
| 2 | `cmd/spool/hub.go:200` is the hub routing | routes are registered per area in `hub/server.go:411-450` (`s.routeMe(mux)` :440, `s.routeWorkItems(mux)` :450 -> `routeCalendar`, `hub/calendar.go:1196-1206`); member routes are `/v1/...` | WRONG |
| 3 | `internal/hub/live.go:1` broadcasts calendar mutations | `git cat-file -e dff1b61d6:api/internal/hub/live.go` -> missing; `hub/calendar.go:34` "sends nothing: no frame, no spool message, no notification" | WRONG: no frame exists; none is needed (2.5) |
| 4 | `internal/hub/server.go:150` routes public webhooks | `server.go:145-152` is the Options struct; its comment names the one webhook precedent, `/api/v1/webhooks/payment` (`api/internal/payments/handler.go:30-31`); no Google push route exists | WRONG line; v0.1's path `/api/v1/webhooks/google-calendar` matches the precedent and is kept |
| 5 | `csi-spl-iac/src/terraform/031-gcp-hub-ingress/03-cloud-run.tf` is the ingress | `ls csi-spl-iac/src/terraform` has no 031; `csi-spl-iac/src/bash/tests/wui-hosting-019-031.tst.sh:87` asserts it stays gone | WRONG |
| 6 | `internal/auth/idp.go:102` "GoogleClient" | `type Google struct` is `auth/idp.go:129`; `AuthCodeURL` :140 sends `access_type=online` (:146) and `prompt=select_account` (:147); scopes from `SPOOL_HUB_AUTH_GOOGLE_SCOPES` (`auth/config.go:83`, cnf `all.env.yaml:704` "openid email profile") | WRONG line; and sign-in can never return a refresh token: the connect needs its own flow (P1) |
| 7 | `auth/token.go:45` is the CSRF state | `statePayload` is `auth/token.go:82-89`; the nonce cookie is set at `auth/handler.go:367` with `Path: RoutePrefix` (`/api/v1/auth/`, `handler.go:26`), read at :468 | WRONG line; the cookie path keeps the sign-in nonce away from any other route |
| 8 | `auth/handler.go:120` is the callback | `func (h *Handler) callback` is `auth/handler.go:449` | WRONG line |
| 9 | the cnf scopes are at `all.env.yaml:352` | `cnf/all.env.yaml:704` | WRONG line |
| 10 | `marketing/seal.go:1-171`, a per-token AES-256-GCM key wrapped by KMS | `seal.go` is 171 lines; `Seal` :96, `Open` :120 | OK |
| 11 | KMS key `spool-kms-token-wrap` | no such name (`git grep -c spool-kms` -> 0). The key is cnf `marketing.kms_key` = ring `csi-spl-marketing`, key `channel-tokens` (`cnf/all.env.yaml:921-931`, step `055-gcp-kms-marketing`), injected as `SPOOL_HUB_MARKETING_KMS_KEY` (`api/internal/config/config.go:455`) | WRONG |
| 12 | sealed text `v1:<kms_key_version>:<b64 key>:<b64 iv>:<b64 ct>`, AAD `spool-gcal-token/v1` | `seal.go:115` writes `v1.<wrapped>.<nonce+ciphertext>` (base64url, dots); the key version comes back apart and has its own column (`kms_key_id`, `rdb/0187_marketing.sql:50-56`); the AAD is a package constant `spool-marketing-seal/v1` (`seal.go:31`), not a parameter | WRONG: reuse needs a purpose parameter (B3) |
| 13 | `marketing/seal_fake.go:10` FakeKMS | `type FakeKMS` at `seal_fake.go:12`, `NewFakeKMS` :18 | OK (line off by 2) |
| 14 | `marketing.NewPlaintext` redacts | `seal.go:51-72`: String, GoString, Format, MarshalJSON, MarshalText, LogValue all `[redacted]` | OK |
| 15 | calendar DDL is `0125`, `0139`, `0156` | present; since then also `0158`-`0161` (the audience rename) | GAP |
| 16 | audience is `public, internal, private` | `rdb/0161_calendar_web_to_public.sql:20-21`: `CHECK (audience IN ('public', 'workspace', 'internal', 'private'))` | WRONG: four audiences |
| 17 | FK `(tenant_id, event_id) REFERENCES calendar_events` | the target exists: `rdb/0139_calendar_full_edit.sql:42` `UNIQUE (tenant_id, event_id)` | OK |
| 18 | soft delete `deleted_at` | `rdb/0139_calendar_full_edit.sql:36` | OK |
| 19 | `calendar_guests` <-> Google `attendees` by email | `calendar_guests.guest_id` is a HUM-/agent id (`rdb/0139_calendar_full_edit.sql:57-58`), no email column | GAP: attendees are out of v1 (P5) |
| 20 | migration `0162_google_calendar_sync.sql` | `ls rdb/ \| tail -1` -> `0214_topic_priorities.sql`; 0162 is taken | WRONG: `<next>`, 0215 today, fixed at build time |
| 21 | the DDL of v0.1 section 3.1 | its quotes are lost (`DEFAULT primary`, `IN (bidirectional, ...)`, `current_setting(app.tenant_id, true), )`): it does not parse | WRONG: rewritten in section 3 |
| 22 | private filter for imported events | `store/calendar_postgres.go:30`: a private event is read by its creator or a mentioned viewer only | OK: an import written with `creator_id = <HUM>`, audience `private` is the member's alone |
| 23 | `source_key` idempotency | `rdb/0156_calendar_source_key.sql:23-27`: partial unique `(tenant_id, source_key)`; roadmap sync owns the families `goal:`, `release:`, `spec:`, `db:` (`hub/calendar_sync.go:19-40`) | OK: `gcal:` is a free family |
| 24 | settings: `components/SettingsDialog.vue:74`, new `components/settings/integrations.vue` | sections are listed in `wui/utils/settings-nav.mjs:6-14` (7 ids) and lazily imported at `wui/components/SettingsDialog.vue:75-81`; the deep link is `?settings=<id>` (`settings-nav.mjs:37`) | OK; the nav list was missed |
| 25 | `do_spl_gcal_channel_renew` cron or an in-hub runner | the hub has one in-process sweeper, `hub/server.go:585` `RunSweeper`, every `SweepInterval` 10 min (`api/cmd/spool/timeouts.go:8`); Cloud Run keeps CPU (`cpu_idle = false`, `csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf:82`), `min_instances 1`, `max_instances 2` (`cnf/prd/tf/030-cloud-run-hub.vars.tfvars:16-17`) | GAP: in-hub works, but two instances need a per-connection lock (P8) |
| 26 | the Calendar API is there to call | the project API list (`cnf/all.env.yaml:60-85`) has `cloudkms` (:85) but no `calendar-json.googleapis.com` (`grep -c calendar-json cnf/*.env.yaml` -> 0 each) | GAP: owner step S1 |
| 27 | a Google OAuth client | one per env already, for sign-in: client id `cnf/dev.env.yaml:391`, `cnf/prd.env.yaml:386`; secret slot `csi-spl-hub-auth-google-client-secret` (`cnf/all.env.yaml:735`), injected on both envs (`cnf/{dev,prd}/tf/030-cloud-run-hub.vars.tfvars:25`) | GAP: v0.1 never said which client (P2) |
| 28 | (not in v0.1) the 090 LinkedIn connect | `hub/marketing_channels.go:16-56` (connect GET/POST, callback, a 15 min signed state, the token sealed before the store sees it), `marketing/linkedin_oauth.go:87-135` (`State`, `NewState`, `VerifyState`) | GAP: the template v0.1 missed |

## 2. The design

### 2.1 Scope

In: one Google account per member per workspace; Spool events the member
can read and created or is a guest of go to one Google calendar; Google
events of that calendar come back as the member's own `private` events;
"Sync now"; disconnect. Which way it flows is the owner's O1.

Out (each can get its own spec): attendees and guest mapping (P5), Outlook
and CalDAV, an iCalendar feed URL, domain-wide delegation, a workspace-wide
shared Google calendar.

### 2.2 The connect flow

It mirrors 090 (`hub/marketing_channels.go`) with 010's nonce cookie added
(P3):

1. `POST /v1/me/google-calendar/connect?workspace=<id>` (member session)
   answers `{authorize_url}`; `GET` of the same path answers 302 (a plain
   link). The hub signs a state `{tenant, member, nonce, exp = now + 15 min}`
   with an HMAC key derived from the client secret, as
   `marketing/linkedin_oauth.go:94-110` does, under its own label
   (`spool-gcal-connect-state/v1`), and sets the nonce as a cookie named by
   `SPOOL_HUB_AUTH_STATE_COOKIE_NAME` (`__session` on prd,
   `cnf/prd.env.yaml:383`: the one cookie Hosting forwards) with
   `Path=/v1/me/google-calendar/` and the auth `CookieDomain`.
2. Google's URL carries the scope `openid email <O1 calendar scope>` (cnf
   `gcal.scopes`; `openid email` so the userinfo call answers the Google
   email that `google_email` stores; B5 reads the value from cnf and does
   not hard-code it, so B5 does not wait for O1: the calendar scope is
   written into cnf with S2, from O1's answer), `access_type=offline`,
   `include_granted_scopes=true`, `prompt=consent`, `state`.
   A consent that grants the sign-in but not every non-identity scope of
   `gcal.scopes` (Google's granular consent lets the member untick the
   calendar box) is refused at the callback: the grant is revoked, nothing
   is stored, and the member lands on `gcal_error=scope_missing`
   (SPL-3815). Kept, such a connection answered 403 on every sync.
3. `GET /v1/me/google-calendar/callback?code&state` on the WUI origin
   (Hosting's `/v1/**` rewrite reaches the hub,
   `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh:297`; no new
   rewrite). It checks the MAC and expiry, then nonce == cookie, clears the
   cookie, exchanges the code, seals both tokens, stores the connection and
   creates the target calendar (2.3); the watch channel is B7's (2.6). It
   then 302s to the state's workspace host, built from
   `SPOOL_HUB_TENANT_HOST_PATTERN` (dev tfvars: `{tenant}.dev.spool-hub.ai`,
   apex workspace `SPOOL_HUB_WUI_APEX_TENANT`), path
   `/?settings=calendar-google&gcal=connected` (or `gcal_error=<code>`): the
   redirect URI is one fixed host, so without this a member who connected
   from their own workspace host would land in another workspace.
4. A refused or expired state answers the 090 page
   (`hub/marketing_channels.go:213` `connectPage`), never a stack trace.

The redirect URI is `https://<WUI host>/v1/me/google-calendar/callback`,
registered by the owner on the client (S3).

Known and accepted: dev and prd use the same cookie name and domain
(`__session`, `spool-hub.ai`; `cnf/dev.env.yaml:385`, `cnf/prd.env.yaml:383`),
so a connect started on dev and on prd at once overwrites the other's nonce;
the later one fails with `invalid_state` and is retried. Sign-in has the
same property today.

### 2.3 Target calendar

A secondary calendar the hub creates, `Spool Hub (<workspace name>)` (P4).
Its id is stored; it is created again if Google answers 404 for it.
Writing into `primary` is not offered in v1.

### 2.4 Tokens

- Sealed with the 090 sealer (`marketing.Sealer`) under the same KMS key
  (`channel-tokens`, step 055), with a purpose AAD `spool-gcal-token/v1`.
  B3 adds the parameter; the marketing AAD stays the default, so every
  sealed marketing row still opens (P6).
- The access token is refreshed when it expires within 5 min; `invalid_grant`
  on refresh sets `status = 'revoked'` and stops syncing that connection.
- Disconnect: stop the watch channel, `POST https://oauth2.googleapis.com/revoke`,
  delete the connection row (its map rows cascade). Imported events stay as
  the member's private events unless the member ticks "remove imported
  events" (soft delete, `deleted_by = 'gcal-sync'`).

### 2.5 Sync

All sync runs in the hub, on its own ticker started from `RunSweeper`
(`hub/server.go:585`), every 60 s, plus on demand ("Sync now", a push).
A connection is claimed with a lease, not a held row lock (P8): one short
statement `UPDATE gcal_connections SET sync_lease_until = now() + interval '5 minutes'
WHERE connection_id = (SELECT connection_id FROM gcal_connections WHERE due_at <= now()
AND status = 'connected' AND (sync_lease_until IS NULL OR sync_lease_until < now())
ORDER BY due_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING ...`, then the
Google calls run outside any transaction, and the lease is cleared at the
end. The claimed `sync_lease_until` value is the cycle's fencing token:
every write the cycle makes to the connection or its map rows, and the
final clear, carry `WHERE sync_lease_until = <the claimed value>`; a write
that matches no row means another instance took the lease after 5 min, and
the cycle stops at once. The cycle renews the lease (a new token, same
check) after each page of Google results, so a long first sync keeps it. The pool is 4 connections (`SPOOL_HUB_DB_MAX_CONNS` "4" in
`cnf/{dev,prd}/tf/030-cloud-run-hub.vars.tfvars`): a row lock held across
Google HTTP calls would hold one of them for the whole sync.

- Out (Spool -> Google): events of the workspace with
  `GREATEST(updated_at, COALESCE(deleted_at, updated_at))` after the
  connection's `out_cursor` (a trash leaves `updated_at` as it was,
  `store/calendar_postgres.go:269`, so `updated_at` alone never sees a
  delete) that the member reads under the private filter
  (`store/calendar_postgres.go:30`): every workspace event, not only the
  ones the member created or is a guest of (owner poll d93654e1 A, section
  2.10; before SPL-3852 it was only those): insert,
  patch or delete on the target calendar; the map row keeps the Google id,
  etag and `sync_hash`. Rows with `recurring_event_id` (097's occurrence
  exceptions, kept as their own rows, `store/calendar_postgres.go:76`) are
  skipped in v1, or they would reach Google as stand-alone duplicates. No
  hook in the calendar write handlers (`hub/calendar.go:939`, :1074, :1111)
  (P7).
- In (Google -> Spool, if O1 is A or C): `events.list` with the stored
  `syncToken`; a 410 clears it and lists in full from now - 30 days. An
  unmapped item is inserted with `creator_type 'human'`, `creator_id <HUM>`,
  audience `private`, kind `other`, `source_key 'gcal:<connection_id>:<google id>'`;
  a mapped one is patched; `status cancelled` soft-deletes. Items with
  `recurringEventId` (a changed occurrence of a Google series; unchecked, I
  believe, that `events.list` without `singleEvents` returns them as their
  own items) are skipped in v1. An empty Google summary is stored as a fixed
  placeholder title (an i18n key), because `title` must be 1-200 chars
  (`rdb/0125_calendar.sql:22`).
- Echo: `sync_hash` = SHA-256 of title, description, starts_at, ends_at,
  all_day, time_zone, rrule, status, joined by newlines. An incoming item
  whose hash equals the stored one is skipped; so is an outgoing write whose
  hash did not change.
- Conflict: the newer side wins (Spool `updated_at` vs Google `updated`); a
  tie goes to Spool; a delete beats an edit on either side.
- Mapping: title <-> summary (Spool allows 200 chars,
  `rdb/0125_calendar.sql:22`: a longer Google title is cut), description
  (4000, :23), start/end (`date` when all-day), `time_zone` <-> `timeZone`,
  `rrule` <-> `recurrence` (only `RRULE:` lines; `EXDATE`/`RDATE` and 097's
  occurrence exceptions are out of v1), audience `private` -> visibility
  `private`, any other -> `default`.

### 2.6 Push

`POST /api/v1/webhooks/google-calendar` on the hub's API origin, beside the
payment webhooks (`api/internal/payments/handler.go:30-31`). The hub finds
the connection by `X-Goog-Channel-ID`, compares `X-Goog-Channel-Token` (an
HMAC of the connection id) in constant time, answers 200 at once and marks
the connection due; state `sync` answers 200 and does nothing. Any mismatch
is 403 with no detail. A channel lives at most about 7 days (unchecked, I
believe, from Google's docs); the ticker renews those ending within 24 h.
Without pushes the 60 s cycle still syncs: a lost push costs only latency.
The channel is B7's alone: B7 adds one call in B6's sync cycle
(`hub/gcal_sync.go`, after the lease is taken) to `s.gcalWatchTick`, which
creates a channel for a connected row that has none and renews one ending
within 24 h; disconnect stops it; before B7 lands no
channel exists, so nothing pushes to a route that is not there yet.

### 2.7 WUI

A new settings section `calendar-google` (`wui/utils/settings-nav.mjs`, one
lazy import in `wui/components/SettingsDialog.vue`), shown in every
workspace (P10): a workspace outside `gcal.workspaces` gets 404 from
`GET /v1/me/google-calendar` and the section says it is not available
there. Inside: not connected -> one
Connect button; connected -> the Google email, the target calendar name,
the last sync time and status, Sync now, Disconnect (with the "remove
imported events" tick). A `revoked` or `error` status shows its reason and a
Reconnect button. The section is its own chunk: it does not raise
`ci_initial_gzip_kb`.

### 2.8 Local dev and tests

`SPOOL_CLOUD_PROVIDER=none` (spec 148): the connect answers 503
`gcal_not_configured` unless a fake Google base URL is set. Tests run against
`api/internal/gcal/fakegcal` (an `httptest` server for token, revoke,
calendars, events, watch and stop) and `marketing.NewFakeKMS`. No test
reaches Google.

### 2.9 Kill switch

cnf `gcal.workspaces` (per env, `[]` = off), as `marketing.workspaces`
(`cnf/all.env.yaml:921-922`): outside it every `/v1/me/google-calendar*`
route answers 404 and the section says "not available" (2.7). Turning it on
in an env is an owner go (S5).

### 2.10 Owner poll d93654e1: workspace events out, existing calendars in

The owner answered poll d93654e1 (HUM-10 msg ce137fef) with A and B
(SPL-3852; C, refusing a connect whose grant lacks a scope, is SPL-3815):

- **A. Workspace events out.** The out half (2.5) sends every live event
  of the workspace the member reads, no longer only their own or those
  naming them. The private filter still applies: another member's private
  event and every Google import (always private to its member) stay out.
  An event another member turns private is deleted from this member's
  "Spool Hub" calendar on the next cycle. Code: `hub/gcal_sync.go` `events`;
  test `TestGcalSyncSendsWorkspaceEvents`.
- **B. Existing calendars in, read-only.** Besides the two-way "Spool Hub"
  calendar, each calendar the member shows in Google Calendar (calendarList
  `selected`, not hidden or deleted: their primary calendar, a team
  calendar they made or subscribed to) comes in as the member's private
  events, kind `other`, `source_key gcal:<connection>:src.<12 hex of
  SHA-256(calendar id)>.<google id>`. Nothing is ever written to those
  calendars and the imports never go back out (no map row; the out half
  skips an unmapped `gcal:` event). Each calendar keeps its own sync token
  in `gcal_connections.source_sync` (rdb 0233, a JSON object), a 410 lists
  it in full from now - 30 days, a cancelled item trashes its import, a
  changed occurrence (`recurringEventId`) is skipped as in 2.5, and a
  calendar the member stops showing has its imports trashed. Disconnect
  with `remove_imported=1` trashes them too. Code:
  `hub/gcal_sync_sources.go`; tests `hub/gcal_sync_sources_test.go`,
  `store/gcal_test.go` `TestGcalSourceSync`.
- **Scope.** B runs only when cnf `gcal.scopes` holds
  `https://www.googleapis.com/auth/calendar.readonly` (or the full
  `.../auth/calendar`): `hub.GcalReadsCalendars`, wired in
  `cmd/spool/hub_gcal.go`. Without it nothing changes (no calendarList
  call). A member whose grant predates the scope gets a 403 from Google; the
  cycle still syncs the "Spool Hub" calendar and `status_detail` says to
  reconnect. `calendar.readonly` is a sensitive scope: until Google
  verifies the app only listed test users can grant it (owner steps S7, S8).
- Known limit: the sweep of a dropped calendar reads at most 2000 imports
  (`ErrCalendarTooMany`); past that it is the status detail and is retried.

## 3. Data

One additive migration, `rdb/<next>_google_calendar.sql` (`<next>` = the
next free number at build time; 0215 on the panel sha). RLS in the 0187
shape (`rdb/0187_marketing.sql:105-122`). `humans (human_id)` is the FK
target as in `rdb/0169_embed_channel_scope.sql:89` (table at
`rdb/0006_users_and_memberships.sql:19`).

```sql
CREATE TABLE gcal_connections (
    connection_id   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id        text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    google_email    text        NOT NULL CHECK (length(google_email) BETWEEN 3 AND 320),
    calendar_id     text        NOT NULL DEFAULT '' CHECK (length(calendar_id) <= 255),
    status          text        NOT NULL DEFAULT 'connected'
        CHECK (status IN ('connected', 'error', 'revoked')),
    status_detail   text        NOT NULL DEFAULT '' CHECK (length(status_detail) <= 500),
    access_sealed   text        NOT NULL,
    refresh_sealed  text        NOT NULL,
    kms_key_id      text        NOT NULL,
    access_expiry   timestamptz NOT NULL,
    sync_token      text        NULL,
    out_cursor      timestamptz NULL,
    due_at          timestamptz NOT NULL DEFAULT now(),
    sync_lease_until timestamptz NULL,
    watch_channel_id  uuid      NULL,
    watch_resource_id text      NULL,
    watch_expiry      timestamptz NULL,
    last_synced_at  timestamptz NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, human_id)
);
CREATE INDEX gcal_connections_due ON gcal_connections (due_at) WHERE status = 'connected';
CREATE UNIQUE INDEX gcal_connections_watch ON gcal_connections (watch_channel_id) WHERE watch_channel_id IS NOT NULL;

CREATE TABLE gcal_event_map (
    connection_id   uuid        NOT NULL REFERENCES gcal_connections (connection_id) ON DELETE CASCADE,
    tenant_id       text        NOT NULL,
    event_id        uuid        NOT NULL,
    google_id       text        NOT NULL CHECK (length(google_id) BETWEEN 1 AND 1024),
    etag            text        NOT NULL DEFAULT '',
    sync_hash       text        NOT NULL CHECK (length(sync_hash) = 64),
    synced_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (connection_id, event_id),
    UNIQUE (connection_id, google_id),
    FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE
);

ALTER TABLE gcal_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE gcal_connections FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON gcal_connections
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON gcal_connections
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
-- the same two policies on gcal_event_map
```

The Google push channel's columns are named `watch_*`, never `channel_id`:
`store/channel_scope_rls_test.go:381` lists every table with a `channel` or
`channel_id` column that lacks a restrictive `channel_scope` policy, and
these tables hold no Spool channel.

Member isolation inside a workspace is the store's job: every store method
takes `(tenant, human)` and every query names both (C3). The sync cycle
picks due connections under `operator` scope, then writes each under its
own tenant.

## 4. Routes

| route | who | answer |
|---|---|---|
| `GET /v1/me/google-calendar` | member | `{connected:false}` or `{connected, google_email, calendar_title, status, status_detail, last_synced_at}`; never a token |
| `POST` / `GET /v1/me/google-calendar/connect?workspace=` | member | `{authorize_url}` / 302 |
| `GET /v1/me/google-calendar/callback` | Google's redirect (state + nonce cookie, no session needed) | 302 to the WUI |
| `POST /v1/me/google-calendar/sync` | member | 202; 409 `sync_in_progress` while `sync_lease_until > now()` |
| `DELETE /v1/me/google-calendar?remove_imported=0\|1` | member | 204 |
| `POST /api/v1/webhooks/google-calendar` | Google | 200 / 403 |
| `OPTIONS` on `/v1/me/google-calendar`, `/connect`, `/sync` | browser preflight | as every `/v1/me` route (`hub/channel_order.go:115`, `hub/hours_me.go:750`): the WUI calls the hub cross-origin |

Errors: `{"error":"<code>"}`: `gcal_not_configured` 503, `not_found` 404
(workspace off, or no connection), `invalid_state` 400, `sync_in_progress`
409, `gcal_revoked` 409, `invalid_channel` 403.

## 5. Cases

Every case is **planned**. "Master today" is `dff1b61d6`. Each red control
fails on master today and passes once its row lands; (C) marks a control
that must pass on both. "n/a" = the route or table does not exist yet; the
control then carries its twin.

| # | row | case | master today | expected | red control |
|---|---|---|---|---|---|
| C1 | B1 | the migration applies on a test DB after `0214` | table absent | both tables, 4 policies | rdb test: `\d gcal_connections` errors today |
| C2 | B1 | as tenant A, read a tenant B row of `gcal_connections` | n/a | 0 rows | Postgres test; twin: the same row as tenant B is read |
| C3 | B2 | store: member M1 reads member M2's connection, same workspace | n/a | not found | Go test, memory and Postgres; twin: M2 reads it |
| C4 | B3 | `Seal` with purpose `spool-gcal-token/v1`, `Open` with the marketing default | no option (`marketing/seal.go:83` `NewSealer(kms, keyName)`) | `ErrOpen` | Go test: red = does not compile on master; twin: the same purpose opens |
| C5 | B3 | a text sealed with the marketing default still opens | opens | opens (C) | the existing `marketing/seal_test.go`, unchanged |
| C6 | B4 | fake Google: token exchange, refresh, revoke, events list with `syncToken`, a 410 | n/a | parsed; 410 is `ErrSyncTokenGone` | Go test on `fakegcal` |
| C7 | B5 | `POST /v1/me/google-calendar/connect` as a member of a `gcal.workspaces` workspace | 404 (no route) | 200 `{authorize_url}` with `access_type=offline`, `include_granted_scopes=true`, `state`, the scope string read from cnf `gcal.scopes` | Go test |
| C8 | B5 | the same in a workspace not on the list | 404 | 404 (C) | Go test |
| C9 | B5 | callback with a valid state and no nonce cookie | n/a | 400 `invalid_state`, nothing stored | Go test; twin: with the cookie, a row is stored |
| C10 | B5 | callback with a state older than 15 min | n/a | 400, nothing stored | Go test, fake clock |
| C11 | B5 | after a connect, neither fake token appears in the stored row or in any log line | n/a | true | Go test greps the row and the captured log |
| C12 | B5 | `GET /v1/me/google-calendar` JSON | n/a | no key containing `token` or `sealed` | Go test |
| C1b | B1 | `TestCrossTenantEveryTable` and `TestRLSChannelScopeCatalogue` with the new tables | pass | pass (C) | the two Postgres tests: B1 seeds both tables in `store/crosstenant_test.go` and names no `channel_id` column |
| C13 | B6a | a Spool event the member created: one cycle | not in Google | inserted in the target calendar; a map row with its hash | Go test on `fakegcal` |
| C14 | B6a | the same event edited in Spool | n/a | one PATCH; a second cycle with no change makes 0 calls | Go test counts the fake's calls |
| C13b | B6a | the C13 event moved to trash in Spool | n/a | one DELETE at Google, map row gone | Go test; twin: an `updated_at`-only cursor misses it (the test asserts the call) |
| C13c | B6a | a Spool series with one changed occurrence (a `recurring_event_id` row) | n/a | the series goes once; the exception row is not sent | Go test counts the fake's inserts |
| C15 | B6b | a new event on the Google side | n/a | a Spool event, `private`, creator the member, `source_key gcal:<conn>:<id>` | Go test |
| C15b | B6b | a Google event with an empty summary | n/a | stored with the placeholder title; the cycle completes | Go test |
| C15c | B6b | a Google item with `recurringEventId` | n/a | skipped, no Spool row | Go test |
| C16 | B6b | another member of the same workspace lists the calendar | n/a | does not see C15's event | Go test through `GET /v1/calendar/events` (`hub/calendar.go:1197`); twin: the connecting member does see it (else the check passes on an empty import) |
| C17 | B6b | echo: after C13 the fake returns the same item in the next list | n/a | 0 Spool writes | Go test |
| C18 | B6b | conflict: both sides edited, Google later | n/a | Google's values in Spool; the next cycle makes no PATCH | Go test, fake clock |
| C19 | B6b | 410 on `syncToken` | n/a | token cleared, full list, no duplicate events | Go test |
| C20 | B6a | refresh answers `invalid_grant` | n/a | status `revoked`, no further calls | Go test |
| C21 | B6a | two cycles at once (two goroutines, Postgres) | n/a | each connection synced once; no transaction open during a fake Google call | Postgres test counts lease claims and the fake's calls; twin: a fake clock past 5 min lets the second cycle claim, and the first cycle's next write matches no row and it stops (no write after that) |
| C22 | B7 | push with a wrong channel token | 404 (no route) | 403, connection not due | Go test; twin: the right token marks it due |
| C23 | B7 | a channel ending in 12 h; a connected row with no channel | n/a | stopped and created again; created | Go test, fake clock |
| C23b | B7 | disconnect with a channel | n/a | the fake saw `channels/stop` | Go test |
| C24 | B5 | disconnect | n/a | the fake saw `revoke`; the row is gone; imported events kept unless `remove_imported=1` | Go test |
| C24b | B5 | callback for a member who started on workspace `w2`'s host | n/a | 302 `Location` on `w2`'s host | Go test; twin: the apex workspace lands on the apex |
| C24c | B5 | `OPTIONS /v1/me/google-calendar` from the WUI origin | 404 | 204 with the CORS headers of `/v1/me/hours` | Go test |
| C25 | B8 | `SETTINGS_SECTIONS` ids | 7 | 8, `calendar-google` last | a new wui unit test on `settings-nav.mjs` (none exists today) |
| C25b | B8 | the section in a workspace outside `gcal.workspaces` (mock 404) | absent | "not available here", no Connect button | wui unit or e2e test |
| C26 | B8 | the section on the mock bundle: not connected shows Connect; connected shows the email and Disconnect | absent | as stated | e2e on the mock bundle |
| C27 | B8 | initial JS budget | - | not raised (C) | `csi-spl-orc/src/bash/scripts/perf-budget.py` |
| C28 | B9 | the new keys in every locale; the `i18n-untranslated` and `i18n-no-raw-text` counts not raised | missing | present | the two ratchet tests |

## 6. Build rows

Disjoint files per row. Data, then API, then sync, then WUI; i18n with the
agy review last. Author vendor per the fleet table (`complex_coding` and
`tests`: claude; `i18n` and `specs_and_docs`: agy; no mistral coding,
owner 2026-10-17). R7 reviewer (`csi-spl-doc/doc/md/rounds-rulebook.md`
2.7.2): cross-vendor, named in the row brief before spawn, primary then
backup. "api tests" = `bash csi-spl-api/src/bash/tests/run-all-tests.sh`;
"full tier" = `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`
(a store or migration change, on Postgres).

| row | area | files (only these) | after | cases | test (red on master, green on the row) | author | R7 reviewer (backup) |
|---|---|---|---|---|---|---|---|
| B1 data (Implemented, 3d88cca60) | rdb, api | new `rdb/<next>_google_calendar.sql`; `store/crosstenant_test.go` (`seedTenantAll`: both tables, same commit, or `TestCrossTenantEveryTable` goes red) | - | C1-C2, C1b | the rdb apply + Postgres tests of C1, C2, C1b; full tier | claude | agy (mistral) |
| B2 store (Implemented, 2e3c1534c) | api | new `store/gcal.go`, `store/gcal_memory.go`, `store/gcal_postgres.go`, `store/gcal_test.go`; one field in `store/memory.go` (as `marketing *memMarketing`, :72) | B1 | C3 | `store/gcal_test.go` (memory and Postgres); api tests; full tier | claude | agy (mistral) |
| B3 seal purpose (Implemented, b02cd72bc) | api | `api/internal/marketing/seal.go` (an AAD option on `NewSealer`, default unchanged), `seal_test.go` | - | C4-C5 | `go test ./internal/marketing/`; api tests | claude | agy (mistral) |
| B4 Google client (Implemented, bf5a169e4) | api | new `api/internal/gcal/` (`client.go`, `oauth.go`, `fakegcal/fakegcal.go`, tests) | - | C6 | `go test ./internal/gcal/...`; api tests | claude | agy (mistral) |
| B5 connect routes (Implemented, 01e3724d4) | api, cnf | new `hub/gcal_connect.go` + `_test.go`; new `api/cmd/spool/hub_gcal.go`; one opts line in `api/cmd/spool/hub.go` (as :284); one block in `api/internal/config/config.go`; `hub/server.go`: one Options field (as :225-227) and one route line (:411-450); a `gcal:` block in `cnf/all.env.yaml` (`workspaces: []`, `scopes` holding only `openid email` until S2) and its tpl-gen output | B2, B3, B4 | C7-C12, C24-C24c | `hub/gcal_connect_test.go`; api tests; `ENV=<env> ./run -a do_tpl_gen` + `git diff --exit-code` | claude | agy (mistral) |
| B6a sync out | api | new `hub/gcal_sync.go` + `_test.go` (claim, lease, refresh, the Spool -> Google half); new `hub/gcal_map.go` (mapping, hash) + test; one line in `hub/server.go` `RunSweeper` (:585) | B5 | C13-C13c, C14, C20, C21 | `hub/gcal_sync_test.go`, `hub/gcal_map_test.go`; api tests; full tier | claude | agy (mistral) |
| B6b sync in | api | new `hub/gcal_sync_in.go` + `_test.go` (the Google -> Spool half, called from B6a's cycle by one line in `hub/gcal_sync.go`) | B6a, **O1 = A or C** | C15-C19 | `hub/gcal_sync_in_test.go`; api tests; full tier | claude | agy (mistral) |
| B7 push | api | new `hub/gcal_push.go` + `_test.go` (the route registered from `gcal_connect.go`'s route func: no new `server.go` line); channel create, renew and stop live here; one call to `s.gcalWatchTick` in `hub/gcal_sync.go` (a B6a file, B7 runs after it) and one in the disconnect path of `hub/gcal_connect.go` (a B5 file) | B6a (B6b too if placed) | C22-C23b | `hub/gcal_push_test.go`; api tests | claude | agy (mistral) |
| B8 WUI | wui | `wui/utils/settings-nav.mjs`; one import in `wui/components/SettingsDialog.vue`; new `wui/components/settings/calendar-google.vue`; new `wui/utils/gcal-client.mjs`; `csi-spl-wui/i18n/locales/en.json` (new keys only, the placeholder title of 2.5 included); a new `tests/unit/settings-nav.test.mjs` and its e2e | B5 | C25-C27 | `pnpm run typecheck`; the new unit test; `BASE_URL=<mock bundle> pnpm run test:e2e`; `perf-budget.py` | claude | agy (mistral) |
| B9 i18n | wui | `csi-spl-wui/i18n/locales/*.json` except `en.json` (new keys only); the agy review of the text is the last step before it ships (`LANE_MIX_KIND=i18n`) | B8 | C28 | the `i18n-untranslated` and `i18n-no-raw-text` ratchet tests | agy | claude (mistral) |
| B10 help | doc | a new help page: how to connect, what is shared, how to disconnect; written in its qto doc and exported (`do_spl_doctree_export_md`), as every `csi-spl-doc/doc/help/*.md` is (`csi-spl-doc/doc/help/calendar.md:3`); agy review | B8 | - | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the qto doc drift check | agy | claude (mistral) |

Order: B1, B3 and B4 may run at once; B2 after B1; B5 after B2, B3 and B4;
B6a after B5; B6b after B6a and only once O1 is answered A or C (on B it is
not placed); B7 after B6a, and after B6b when B6b is placed (both edit
`hub/gcal_sync.go`); B8 after B5; B9 and B10 after B8. B5 (two hunks) and
B6a (one line) both edit `hub/server.go`: B6a rebases onto B5. If O1 is C,
the busy-time view of the member's main calendar is one more row after B6b,
written into this spec first (it needs a wider scope and is not specified
here).

What waits on the owner: only B6b (O1). O2 and S0-S6 gate switching the
feature on for members (S5), not any row: every row is tested on the fake
Google (2.8) and lands behind `gcal.workspaces: []`.

## 7. Owner steps (never a lane)

A lane prepares the cnf text; the owner does each step, or gives the go for
it, per env (dev first, then prd).

| # | step | what |
|---|---|---|
| S0 | name the project | the owner confirms which GCP project owns each env's sign-in client (`cnf/dev.env.yaml:391`, `cnf/prd.env.yaml:386`; the project is not in cnf): the API and the consent scope go on that project; S1 assumes it is `csi-spl-<env>` |
| S1 | enable the Calendar API | add `calendar-json.googleapis.com` to the API list (`cnf/all.env.yaml:60-85`), then the 001 step apply (owner go; terraform only through the tf-runner) |
| S2 | OAuth consent screen | add the O1 scope to that project's consent screen; Google's review is O2 |
| S3 | redirect URI | add `https://<WUI host>/v1/me/google-calendar/callback` to each env's Google OAuth client (the sign-in client, P2) |
| S4 | no new key or secret | the KMS key and the client secret exist (`cnf/all.env.yaml:921-931`, :735); nothing new unless the panel changes P2 or P6 |
| S5 | switch on | `gcal.workspaces` per env, dev first, after B8 is live; the hub's env comes from the 030 tfvars and the hub deploy sets none (`grep -cE 'set-env\|update-env' .github/workflows/20_hub-build-deploy.yml` -> 0), so each flip is a step-030 apply (owner go) |
| S6 | push domain, if Google asks | unchecked, I believe: Google may require the push address's domain to be verified; if B7's first watch call is refused for that, verifying the API host's domain is an owner step |
| S7 | read scope (poll d93654e1 B) | append `https://www.googleapis.com/auth/calendar.readonly` to cnf `gcal.scopes` per env (dev first), `do_tpl_gen`, then a step-030 apply (owner go); add the scope to the consent screen; members reconnect |
| S8 | Google app verification for `calendar.readonly` | submit the consent screen for Google's review (O2); until it passes only listed test users can grant the scope |

## 8. Panel decisions

Editor and the claude seat c-576. The agy seat did not review (section 11),
so it recorded no dissent; if it reviews after v1.0, its findings go to the
dispatcher as a change to this spec, not into this table.

| # | question | decision | reason | dissent |
|---|---|---|---|---|
| P1 | reuse 010's sign-in flow for the grant | no: a separate connect flow in the hub | sign-in asks `access_type=online` (`auth/idp.go:146`) and its nonce cookie is scoped to `/api/v1/auth/` (`auth/handler.go:367`); folding calendar into sign-in would ask every sign-in for calendar consent | - |
| P2 | which OAuth client | each env's existing sign-in client, with its own scope string in cnf | it exists on both envs with its secret injected (1.2 row 27); a separate client later is a cnf change | c-576, conditional: consent screen and review are per project (unchecked), so a sensitive calendar scope puts sign-in's consent screen under the review too, and a second client in the same project changes nothing; keep P2, but O2 must say so. Folded into O2 |
| P3 | the state | 090's signed state plus 010's nonce cookie | 090 trusts the state alone (`marketing_channels.go:28-31`); a leaked calendar state would let another person's Google account receive a member's private events; the cookie closes that | - |
| P4 | target calendar | a hub-created secondary calendar only, in v1 | deletes and imports stay inside one calendar the member can hide; `primary` can come later as an option | - |
| P5 | attendees | out of v1 | `calendar_guests` has no email (1.2 row 19); sending members' emails to Google is its own privacy question | - |
| P6 | KMS key | the 055 key with a purpose AAD | no new terraform or owner step; the AAD keeps a calendar token from opening as a marketing token | - |
| P7 | outbound trigger | the 60 s cycle reads `GREATEST(updated_at, deleted_at)` past a cursor; no hook in the calendar handlers | no edit to `hub/calendar.go` (disjoint rows), and a failing Google call never fails a Spool write | c-576: v0.2's `updated_at` alone missed deletes (`store/calendar_postgres.go:269`); fixed in v0.3 |
| P8 | where sync runs | in the hub (`RunSweeper`), claimed by a lease column (`sync_lease_until`) set in one short statement | CPU is always allocated, 1-2 instances (1.2 row 25); no new cron or service; the pool is 4 connections, so no transaction stays open across Google calls | c-576: v0.2's held row lock; changed to the lease in v0.3 |
| P9 | push route | `/api/v1/webhooks/google-calendar` on the API origin | the payment webhooks' precedent (1.2 row 4); Google calls the hub directly, no Hosting rewrite | c-576: OK; possible domain verification is owner step S6 |
| P10 | the kill switch in the WUI | the section shows in every workspace and says "not available here" on a 404 | `SETTINGS_SECTIONS` is a static list read by the dialog and the command palette (`git grep -ln SETTINGS_SECTIONS -- csi-spl-wui/src` -> `SettingsDialog.vue`, `usePaletteItems.ts`, `settings-nav.mjs`, `tenant-settings-nav.ts`); hiding it per workspace would put those files into B8 | c-576: none |

## 9. Owner questions

Only the owner can answer these. The dispatcher posts them after v1.0,
one form per post (`csi-spl-doc/doc/help/how-to-post.md` section 7, rule 1).
O1 decides whether B6b is placed; O2 decides only how S2 is done. Neither
holds back B1-B6a or B7-B10.

```poll
O1. What should a member's Google Calendar connection do?
(A) Both ways: Spool events go to a "Spool Hub" calendar in their Google account, and that calendar's events come back into Spool as their private events
(B) One way only: Spool events go to a "Spool Hub" calendar in Google; nothing comes back
(C) Both ways as in A, and also show the busy times of their main Google calendar in Spool (needs read access to all their Google calendars)
```

```poll
O2. Calendar access is a scope Google reviews. Until Google approves our app, only listed test users can connect, and they see an "unverified app" warning. The review covers the app's consent screen, which our Google sign-in shares, and can take weeks (all unchecked, I believe). What do we do?
(A) Submit the app for Google's review now; until it passes, only listed test users connect
(B) Do not submit for now: only members we list as test users can connect, and (unchecked, I believe) Google ends their connection every 7 days, so they reconnect weekly
```

## 10. Panel record

| when (UTC) | who | what |
|---|---|---|
| 2026-10-21 00:16 | a-658 | v0.1 landed, `ef6adfcf3` |
| 2026-10-23 19:12 | c-910@sat | panel sha `dff1b61d6` to the mistral seat m-911@sat (msg `64e78c1a`) |
| 2026-10-23 19:1x | c-910@sat | v0.2 landed, `9acbb6efe`: section 1 re-measured (28 rows), sections 2-9 rewritten |
| 2026-10-23 19:1x-19:2x | m-911@sat (mistral seat) | msgs `bc25da14`, `f8d1d54a`, `6c2a6169`, `44c06c51`: no command or output in any row, after one send-back; voided by c-002 (msg `cb6c814b`); nothing folded in |
| 2026-10-23 19:24 | c-910@sat | v0.2 sha to the claude seat c-576 (second box), replacing m-911 (msg `b738f767`) |
| 2026-10-23 19:28 | c-576 (second box) (claude seat) | review (msg `842249e3`): 12 rows of 1.2 and 2.x re-checked OK (one line fix: `prompt` is :147); 2 WRONG (the `channel_id` column vs `store/channel_scope_rls_test.go:381`; deletes missed by an `updated_at` cursor) and 12 GAPs; folded in as the `watch_*` columns, the lease (P8), the delete cursor (P7), the scope with `openid email`, the workspace-host redirect, `OPTIONS` preflights, B1's `crosstenant_test.go`, B2's `memory.go`, B5's `hub.go` and Options field, channel work moved to B7, empty titles, occurrence exceptions both ways, P10, S0, S5's 030 apply, S6, the O2 text; cases C1b, C13b, C13c, C15b, C15c, C23b, C24b, C24c, C25b and the C4/C16 controls. The editor re-checked its two WRONG rows and the pool, preflight, seed, `memory.go` and `hub.go` claims on `19a6be809` |
| 2026-10-23 19:3x | c-910@sat | v0.3 landed, `dc9c1b346`; to c-576 for re-check (msg `36d9da8c`) |
| 2026-10-23 19:4x | c-576 (second box) | re-check of v0.3 (msg `1f8697a5`): every fold present; ran the lease statement verbatim on a throwaway Postgres 16 (claims one of two rows); 1 WRONG (section 4 still said "row is locked") and 2 minor GAPs (a sync past the 5 min lease; where B7's ticker starts); P10 no dissent; would sign once the wording is fixed. Folded in as v0.4: the fencing token and per-page renewal (2.5), the 409 wording (4), the `gcalWatchTick` hook and B7's honest file list, the C21 twin |
| - | agy seat | held for agy quota (c-002 msg `9ec38fd7`); never placed before v1.0 |
| 2026-10-23 21:42 | HUM-10 (owner) | "Go, implement" (msg `40744f59`), relayed by c-002 (msg `a9c444bf`): build without waiting for the agy seat |
| 2026-10-23 21:46 | c-910@sat | v1.0 (`b84dec239`): re-checked on `72a60c102` (no cited path changed), B6 split into B6a / B6b so that only B6b waits on O1, each row's test, author and R7 reviewer, signatures; sent to c-576 to sign |
| 2026-10-23 21:5x | c-576 (second box) | signed v1.0 on `b84dec239` (msg `f42378fa`) |

## 11. Signatures

v1.0 is signed by each seat's own message on that sha.

| seat | vendor | signature |
|---|---|---|
| c-910@sat (editor) | claude | this commit |
| c-576 (second box) | claude | "SIGN v1.0 b84dec239" (msg `f42378fa`), with its own re-check of the v0.4 -> v1.0 diff; its note: on B1-B8 the named primary reviewer agy is not a panel seat and is out of quota, so the backup (mistral) covers it, said in each row brief |
| m-911@sat | mistral | none: voided by c-002 (msg `cb6c814b`); nothing of it is folded in |
| agy seat | agy | none: not placed before the owner's go (agy out of quota, c-002 msg `9ec38fd7`); it did not review |

<!-- version: 1.0 · updated: 2026-10-23 -->
