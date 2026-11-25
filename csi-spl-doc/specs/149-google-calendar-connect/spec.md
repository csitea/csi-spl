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
Section 2.11 (delete a synced entry, in Google too; SPL-6453, v1.1-draft
revision SPL-6484) is a v1.1-draft plan incorporating the owner's answers to
Q15-Q18 (HUM-10, t1 d51a95c5, msg `5f7d0b5d`), not built and not signed.

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

SPL-5719: the Calendar page says it too. A connection that Google ended
(`revoked`, invalid_grant) or one in `error` shows a banner above the
calendar, desktop and phone (`wui/components/CalendarGcalBanner.vue`, one
lazy import in `wui/pages/calendar.vue`), with the status, the hub's reason
and a one-click Reconnect (the same connect route as the section). No
banner when the workspace is off (404), the hub has no gcal (503), the read
fails, or the connection is healthy or absent. It uses the section's own
keys, no new text. Why: on prd three of the owner's connections were revoked
and nobody saw it for up to 10 days, because only this settings section said
so ([google-review-submission.md](google-review-submission.md) section 6).
Test: `wui/tests/e2e/calendar-gcal-banner.test.mjs`,
`wui/tests/unit/settings-nav.test.mjs`.

SPL-5726: the section's states after the way back. The notice for
`gcal_error=<code>` shows only while it is true: not before the status is
read, and not once the status reads `connected` (`gcalReturnNotice(query,
view)` in `wui/utils/gcal-client.mjs`). Why: on prd (2026-11-16, 16:30 and
16:34Z) the browser requested the callback twice, 0.4 s apart; the first
request connected, the second found its code used (`invalid_grant`) and
sent `gcal_error=code_expired`, the redirect the browser followed last, so
the section said "was not connected" next to "Connected". Sync now: a 409
`sync_in_progress` says "A sync is already running." as information, not as
an error (the GET has no running-sync field to disable the button by), and
after Sync now the section re-reads the status quietly, up to 6 times 5 s
apart, until `last_synced_at` moves, so "Last sync" leaves "Not yet" once
the first sync ends. One run at a time (`gcalSyncFollower`): a second
Sync now or leaving the page ends the run, and a read already in flight
then is dropped, never re-arming. Test: `wui/tests/e2e/settings-calendar-google.test.mjs`
(N2..N4), `wui/tests/unit/settings-nav.test.mjs`.

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
- **B never reads a "Spool Hub" calendar** (SPL-5782): every hub calendar
  of the same Google account is skipped, matched by the stored
  `calendar_id` of each connection with that `google_email` in any
  workspace (`store.GcalHubCalendars`, never the title), so a member who
  connects several workspaces with one Google account does not get each
  workspace's events back as private copies in the others; a copy an
  older build made is trashed by the dropped-calendar sweep on the next
  cycle. Tests `TestGcalSourcesSkipOtherHubCalendars`,
  `TestGcalSourcesSweepOtherHubCopies`, `store/gcal_test.go`
  `TestGcalHubCalendars`.
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
- **Reversed for delete by 2.11** (owner HUM-10, t1 d51a95c5, poll
  10351c46 answer A): "Nothing is ever written to those calendars" no
  longer holds for a delete. A member who deletes their own import in
  spool-hub deletes it in that Google calendar too. Edits stay read-only.

<a id="s2-11-delete-synced"></a>
### 2.11 Delete a synced entry, in Google too (SPL-6453, v1.1-draft plan)

Status: **v1.1-draft plan (SPL-6484), not built, not signed.** Revised from
the initial Q15-Q18 option-A draft to incorporate the owner's answers to
form `a1df35e6` (HUM-10, t1 d51a95c5, msg `5f7d0b5d`, 2026-11-25 07:2xZ):
Q15 A, Q16 B, Q17 A, Q18 B (2.11.8). Every `file:line` below was read on
origin/master `208e5f757` with `sed -n` / `grep -n`. Paths as at the top of
this spec. A claim about Google that is not quoted from Google's pages is
marked "unchecked, I believe".

#### 2.11.0 The owner's words

HUM-10, t1 topic d51a95c5 (#spool-hub-bugs), 2026-11-24 and 2026-11-25:

- 2026-11-24 07:15:44Z, msg `af6dc376`, with a phone screenshot of the week
  23-29 Nov showing Google entries: "Cannot delete entries on the mobile
  calendar."
- msg `918b3792`: "But it should be possible to delete them from here, and
  while synced, they should delete the entries in the Google Calendar as
  well."
- poll `10351c46`, answer A (msg `da07685e`): "Delete it in Google too, so
  it goes away everywhere".
- 2026-11-25 07:2xZ, form `a1df35e6`, msg `5f7d0b5d`: Q15 A
  (`calendar.events`), Q16 B (also offer "only this occurrence", a later
  build), Q17 A (Google sends its usual cancellation to guests), Q18 B (a
  10 s Undo: the Google delete waits 10 s before it runs).

This reverses one sentence of 2.10 B, which came from poll d93654e1 (HUM-10
msg ce137fef): "Existing calendars in, read-only ... Nothing is ever written
to those calendars". Only deleting changes. Editing a synced entry stays
read-only (PATCH keeps its 409) unless the owner asks for it.

#### 2.11.1 In plain words

1. A member can delete a Google entry they see in spool-hub, on the phone
   and on the desktop. A question comes first, and it says the entry is
   also deleted in Google Calendar.
2. Once confirmed, the entry leaves spool-hub right away and a **10 s Undo
   bar** appears (Q18 B). The delete at Google waits 10 s before it runs.
   Clicking **Undo** within those 10 s cancels the Google delete (Google is
   never called, guests receive no cancellation) and puts the entry back
   with the same id.
3. If the member closes the tab or locks the phone without clicking Undo,
   spool-hub still runs the Google delete after the 10 s wait: the pending
   delete lives on the hub, not only in the browser.
4. Pre-flight refusals fail immediately before anything is removed:
   "reconnect Google Calendar to delete" or "this calendar is read-only for
   you in Google". If Google refuses later (after the 10 s wait, e.g., a
   revoked grant, a demoted read-only calendar, or persistent Google 5xx),
   spool-hub puts the entry back so the two calendars never drift apart.
5. Only the member who sees the entry can delete it: Google entries are
   private to the member who connected Google.
6. In v1, deleting a repeating Google entry removes the whole series. A
   later follow-up build (rows D7s-D7i, Q16 B) adds "only this occurrence".
7. Repo entries (goals, releases, specs) stay read-only, as today.

#### 2.11.2 What exists on master (`208e5f757`)

Three kinds of entries carry a `source_key`. The WUI makes every one of them
read-only, and the hub refuses to change any of them:

| kind | `source_key` | where it comes from | map row | delete on master |
|---|---|---|---|---|
| (a) an item of the member's "Spool Hub" calendar added in Google | `gcal:<connection>:<google id>` | the In half, `put` (`hub/gcal_sync_in.go:195`) | yes (`mapTo`, :205) | 409 `synced_read_only` |
| (b) an item of another calendar the member shows in Google | `gcal:<connection>:src.<12 hex of SHA-256(calendar id)>.<google id>` (`gcalSourceKey`, `hub/gcal_sync_sources.go:83`) | the read-only half, `sourceTake` (:239) | no | 409 `synced_read_only` |
| (c) a repo-synced entry (spec 112) | `goal:`, `spec:`, `release:`, `db:` | the roadmap sync | - | 409 `synced_read_only` (unchanged by 2.11) |

Each step of the path, as on master (`208e5f757`):

- Hub DELETE: `handleDeleteCalendarEvent` (`hub/calendar.go:1158`) reads the
  event and answers `calendarSyncedReadOnly()` (:1101-1104, 409
  `synced_read_only`) for any `source_key` (:1167-1169). PATCH does the same
  (`patchCalendarOnce`, :1067-1068). Restore (`handleRestoreCalendarEvent`,
  :1184) makes no `source_key` check. Calendar mutations broadcast no
  WebSocket frame (`hub/calendar.go:34`).
- WUI: `calSynced` = "has a `source_key`" (`wui/utils/calendar-event-form.mjs:166`)
  and `calEditable` = stored and not synced (:176). The phone peek shows
  Edit / Duplicate / Delete only when `editable`
  (`wui/components/CalendarPhonePeek.vue:113`). There, Delete shows a 10 s
  Undo bar (`UndoSnackbar` at `:125-138`, `UNDO_MS = 10000` at `:171`), and
  Undo calls `calendarRestore` (`POST /v1/calendar/events/{id}/restore`,
  `:330`). The desktop pop-over hides Edit for a synced entry
  (`wui/components/CalendarEventPopover.vue:61`); desktop Undo lives on
  `CalendarMainView.vue:209-222` (`useCalendarMenus.ts:25-46`,
  `CAL_UNDO_MS = 10000`, calling `calendarRestore` at `:37`). `UndoSnackbar`
  holds its visual timer while hovered or focused (WCAG 2.2.1,
  `wui/components/UndoSnackbar.vue:6-10`, `:108-113`). The mock refuses as
  the hub does (`wui/utils/calendar-mock.mjs:112`). The phone add / edit
  sheet (`CalendarPhoneSheet.vue`, Delete at `:318-323`) is reached only
  through Edit, so a synced entry never reaches it. The new Delete goes in
  the peek, not in the sheet.
- The cnf asks Google for `openid email .../calendar.app.created
  .../calendar.readonly` (`cnf/all.env.yaml:1198-1200`, one value for all
  envs; `grep -n gcal cnf/dev.env.yaml cnf/prd.env.yaml` -> none). There is
  no write scope on the member's other calendars. The hub reads the
  calendar list and those calendars with `calendar.readonly` or the full
  `calendar` (`GcalReadScopes`, `hub/gcal_sync_sources.go:51-54`).
- The grant each member gave is stored per connection
  (`GcalConnection.GrantedScopes`, `store/gcal.go:114`); `""` is a row
  connected before spec 154 B7 (`gcalCalendarGranted`,
  `hub/gcal_sync.go:237`).
- Google client: `DeleteEvent` (`gcal/client.go:180`) treats 404 and 410
  as done (`isGone`, `:228`); it sends no `sendUpdates`. A 403 comes back as
  `*HTTPError` with its status; there is no named 403 error
  (`gcal/oauth.go:37-57`, `(*HTTPError).Is` at `:411`). `Event` (`gcal/client.go:40-52`)
  has `RecurringEventID` (`:48`) but no `OriginalStartTime`, and `client.go`
  has no `events.instances` call yet.
- The calendar list carries the member's role on each calendar
  (`CalendarListEntry.AccessRole`, `gcal/client.go:82`: `freeBusyReader`,
  `reader`, `writer`, `owner`), read on every sync cycle (`ListCalendars`,
  `hub/gcal_sync_sources.go:170`), but today the hub stores only each
  calendar's sync token, keyed by calendar id (`gcal_connections.source_sync`,
  rdb 0233; `sources`, `hub/gcal_sync_sources.go:94`).
- An import is upserted with `deleted_at = NULL, deleted_by = NULL`
  (`store/gcal_import.go:141`). **An import trashed in spool-hub while
  Google still has the item would come back** on the next sync if Google
  lists it (an edit at Google, or a 410 full list), unless the pending
  delete guards the upsert during the 10 s wait (2.11.4).
- Background tickers start in `RunSweeper` (`hub/server.go:739`):
  `go s.runGcalSync(ctx)` (`:750`, ticking every `gcalSyncEvery = 60s`,
  `hub/gcal_sync.go:44`).
- Latest migration on `208e5f757`: `ls rdb/ | tail -1` ->
  `0323_fleet_ask_queue_order.sql`.

**Kind (a) and the 10 s Undo wait.** Today, the out half reads live events
(`events`, `hub/gcal_sync.go:461`) and calls `remove` (`:518-525`, `:578`)
for every map row not in `live` (`TestGcalSyncDeletesTrashedEvent`,
`hub/gcal_sync_test.go:230`). Under Q18 B, both kind (a) and kind (b) go
through the same 10 s pending-delete queue, and `out()` never calls `remove`
for a map row whose event is a `gcal:` import (`GcalEventMap.IsGcalImport`,
2.11.4), so a 60 s cycle or "Sync now" can neither jump ahead of the 10 s
wait nor delete an event after Undo.

**Kind (b) has no map row.** Its key holds a 12-hex SHA-256 hash of the
calendar id, not the id (`gcalSourceKey`, `hub/gcal_sync_sources.go:83`).
The hub finds the calendar id by hashing each key of the connection's
`source_sync` (the calendars it reads now) and matching the 12 hex. A live
import's calendar is always in it: a calendar dropped from it has its
imports trashed by `sweepSources` (`:251`).

#### 2.11.3 Who may delete

- The member route only, `DELETE /v1/calendar/events/{id}`, with every check
  `calendarWriter` makes today (membership, `notes.send`, not a demo
  visitor, the workspace may write). No operator or agent route gets this:
  `operatorCalendarSingle` (`hub/calendar_operator_write.go:141-142`) keeps
  its 409.
- **Only the member whose import it is.** An import is `private`, with the
  member as its creator and no guests (`GcalSpoolOf`,
  `hub/gcal_sync_in.go:286`). The private filter answers another member
  `not_found`, as it does today. The hub also checks that `cur.CreatorID`
  is the caller and that the key's `<connection>` is the caller's own
  connection in this workspace. Otherwise it answers 409
  `synced_read_only`, as today.
- Phone: the peek (`CalendarPhonePeek.vue`) shows a Delete for such an
  entry: no Edit, Duplicate as today. Desktop: the pop-over
  (`CalendarEventPopover.vue`) shows a Delete beside Duplicate. Both ask
  first, in place, as the sheet and the dialog do:
  - "Delete this entry? It is also deleted in Google Calendar."
  - On a repeating entry (v1): "Delete every occurrence? They are also
    deleted in Google Calendar." (Q16 B's follow-up row D7w later adds an
    "Only this occurrence" choice beside it.)
  - Buttons: "Delete everywhere" and Cancel.
  - **10 s Undo bar (Q18 B):** once confirmed and the hub answers 200 with
    `"google": "pending"`, the existing 10 s `UndoSnackbar` appears
    (`CalendarPhonePeek.vue:125-138` on phone, `CalendarMainView.vue:209-222`
    on desktop, `10000 ms`). Clicking **Undo** calls `POST
    /v1/calendar/events/{id}/restore` (no new Undo route). Because
    `UndoSnackbar` holds its visual timer on hover/focus (WCAG 2.2.1,
    `UndoSnackbar.vue:6-10`), a member who holds the bar past 10 s and then
    clicks Undo may hit the hub after the Google delete has already been
    claimed or run: the hub answers 409 `gcal_deleted_at_google` and the WUI
    announces "Already deleted in Google Calendar." (An orphan `"not_connected"`
    import was never deleted at Google and can still be undone/restored;
    `"calendar_not_read"` shows no Undo bar.)
- A repo-synced entry (c) shows no Delete, as today.

#### 2.11.4 The 10 s pending delete, order of writes, and every failure (Q18 B)

One new hub file (`hub/gcal_delete.go`) holds `gcalDeleteSynced` (called
from `handleDeleteCalendarEvent` at `hub/calendar.go:1167` when `source_key`
starts with `gcal:`) and the delayed-delete worker (`runGcalPendingDeletes`,
started from `RunSweeper` at `hub/server.go:750`, plus `GcalPendingDeleteOnce`
for deterministic fake-clock tests, mirroring `GcalSyncOnce` at
`hub/gcal_sync.go:110`).

**Where the pending delete lives (and why not only in the WUI).**
The pending delete lives in Postgres (and Memory store) in a new table
`gcal_pending_deletes` (additive migration `rdb/<next>_gcal_pending_deletes.sql`,
RLS `tenant_scope` + `operator_scope` matching `rdb/0217_google_calendar.sql:58-74`;
no `channel_id` column), NOT only in browser memory / `setTimeout`:

```sql
CREATE TABLE gcal_pending_deletes (
    event_id        uuid        NOT NULL,
    tenant_id       text        NOT NULL,
    connection_id   uuid        NOT NULL REFERENCES gcal_connections (connection_id) ON DELETE CASCADE,
    human_id        text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    kind            text        NOT NULL CHECK (kind IN ('hub', 'source')),
    calendar_id     text        NOT NULL CHECK (length(calendar_id) BETWEEN 1 AND 255),
    google_id       text        NOT NULL CHECK (length(google_id) BETWEEN 1 AND 1024),
    send_updates    text        NOT NULL DEFAULT 'all' CHECK (send_updates IN ('all', 'none')),
    run_after       timestamptz NOT NULL,
    claimed_at      timestamptz NULL,
    claimed_until   timestamptz NULL,
    attempts        int         NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error      text        NOT NULL DEFAULT '' CHECK (length(last_error) <= 500),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, event_id),
    FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE
);
CREATE INDEX gcal_pending_deletes_due ON gcal_pending_deletes (run_after);

ALTER TABLE gcal_connections
    ADD COLUMN source_roles jsonb NOT NULL DEFAULT '{}'::jsonb;
```

Why in the store/hub:
- **A closed tab or locked phone still deletes:** `DELETE` commits the soft
  delete and the `gcal_pending_deletes` row (`run_after = now + 10 s`) at
  once. If the member immediately closes the tab, backgrounds the phone app,
  or loses network, the hub still executes the Google delete once `run_after`
  passes. (A WUI-only timer would silently drop the delete on tab close and
  the entry would reappear.)
- **Undo works from any tab or device** during the 10 s window, because the
  pending row is shared in Postgres.
- **Multi-instance Cloud Run safe:** `030-cloud-run-hub` runs 1..2 instances
  (`cnf/prd/tf/030-cloud-run-hub.vars.tfvars:19-20`) with `cpu_idle = false`
  (`csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf:167`).
  Any instance can handle `DELETE`, any instance can handle `POST .../restore`,
  and any instance can claim due pending rows via `FOR UPDATE SKIP LOCKED` +
  `claimed_until`.
- **Cached read-only role pre-check (`source_roles`):** `sourceCalendars`
  (`hub/gcal_sync_sources.go:153`, `ListCalendars` at `:170`) already receives `CalendarListEntry.AccessRole`
  (`gcal/client.go:82`). Storing `calendar_id -> accessRole` in
  `gcal_connections.source_roles` lets `DELETE` refuse a known read-only
  calendar (`reader`, `freeBusyReader`) **synchronously** with 409
  `gcal_calendar_read_only` before trashing or showing Undo, with zero extra
  Google calls. If `source_roles` is stale or empty, the 403 path on the
  delayed worker still heals by restoring the entry.

**Whole series in v1 (W1).** A repeating entry is listed under occurrence
ids `<series id>_<YYYYMMDDTHHMMSSZ>` (`store/calendar_series.go:99`). The
store treats a DELETE with no `?scope=` on such an id as "this occurrence"
(`planCalendarDelete`, `:249-251`), and `TrashCalendarEvent` passes `scope
""` (`store/calendar_postgres.go:295-296`). So in v1 `gcalDeleteSynced`
always trashes with `CalendarScopeAll` for an omitted `?scope=` and for
`?scope=all`, on a series id and on an occurrence id alike, and queues the
top-level series `event_id` in `gcal_pending_deletes`. `this` and `following`
answer 400 `gcal_series_whole_only` in v1 (Q16 B's follow-up row D7h later
opens `this`).

**Step A: `DELETE /v1/calendar/events/{id}` (synchronous, no Google call, no sync lease).**
Runs for both kind (a) and kind (b):

1. **Checks, with no Google call and no write:**
   - Scope: `this` or `following` -> 400 `gcal_series_whole_only`.
   - `If-Match` (`want`, `hub/calendar.go:1163`) against the event read ->
     409 `edit_conflict` with the current event (`writeCalendarConflict`).
   - Hub has no Google client (`s.o.Gcal` nil or `!configured()`), or
     workspace off (`!s.o.Gcal.listed(tenant)`, 2.9) -> 503
     `gcal_not_configured`.
   - No connection, or the key's connection is not the member's current one
     (an orphan import kept by a disconnect with `remove_imported=0`) ->
     trash in spool-hub only (`CalendarScopeAll`), no pending row, answer
     200 `"google": "not_connected"`.
   - Connection `status == revoked` -> 409 `gcal_revoked`.
   - Kind (a) and `!gcalCalendarGranted` (`hub/gcal_sync.go:237`) -> 409
     `gcal_reconnect_to_delete`.
   - Kind (b): cnf `gcal.scopes` holds no write scope (2.11.5) -> 409
     `gcal_delete_not_enabled`.
   - Kind (b): member `GrantedScopes` holds no write scope, or is `""` ->
     409 `gcal_reconnect_to_delete`.
   - Kind (b): find calendar id by hashing `c.SourceSync` keys (2.11.2).
     None matches -> trash in spool-hub only, no pending row, answer 200
     `"google": "calendar_not_read"`.
   - Kind (b): `c.SourceRoles[calendarID]` is `"reader"` or `"freeBusyReader"`
     -> 409 `gcal_calendar_read_only` ("This calendar is read-only for you
     in Google. Hide it in Google Calendar to stop seeing it here."), nothing
     trashed.
2. **Atomic trash + queue (`TrashAndQueueGcalDelete`):** in ONE store
   transaction (`inTenant`), soft-delete the event / whole series
   (`CalendarScopeAll`, `deleted_at = now`, `deleted_by = member`, checking
   `If-Match` under `FOR UPDATE`) AND insert into `gcal_pending_deletes`
   with `kind = 'hub'` (a) or `'source'` (b), `calendar_id`, `google_id`,
   `send_updates = 'all'` (Q17 A), `run_after = now + 10s`
   (`gcalDeleteDelay = 10 * time.Second`). Because no Google call runs here,
   a running 60 s sync cycle does NOT block `DELETE` (no 409
   `sync_in_progress` to the user).
3. Answer `200` with `{"event": <trashed event>, "google": "pending", "undo_until": "<run_after RFC3339>"}`.

**Step B: Undo (`POST /v1/calendar/events/{id}/restore`, `hub/calendar.go:1184`).**
No new Undo route: phone peek (`CalendarPhonePeek.vue:330`), desktop snackbar
(`useCalendarMenus.ts:37`), and Trash (`CalendarTrash.vue:73`) all already
call `POST /v1/calendar/events/{id}/restore`.
Inside `RestoreCalendarEvent` (`store/calendar_postgres.go:339-374`,
`store/calendar_memory.go:204-227`), in ONE transaction:
- For any non-`gcal:` event: unchanged.
- For a `gcal:` event: lock the matching `gcal_pending_deletes` row
  (`SELECT ... FOR UPDATE`) if one exists:
  - **Pending row exists AND `claimed_at IS NULL`:** atomically
    `DELETE FROM gcal_pending_deletes` AND clear `deleted_at = NULL,
    deleted_by = NULL` on `calendar_events`. Return `200 {"event": ...}`.
    **Google was never called**; no guest cancellation was sent; kind (a)'s
    map row is untouched.
  - **No pending row, AND no live `gcal_connections` row matches the key's
    `<connection>` for `(tenant_id, viewer)`** (an orphan import from a
    disconnected connection — `"not_connected"`, where Google was never
    called): clear `deleted_at = NULL, deleted_by = NULL` and return
    `200 {"event": ...}` so a mis-click can be undone.
  - **Otherwise** (the connection still exists and either `claimed_at IS NOT
    NULL`, the pending delete already ran at Google, Google cancelled the
    item, or its calendar is no longer read): return
    `store.ErrGcalImportRestore` -> hub answers `409 gcal_deleted_at_google`
    without writing (the WUI shows "Removed from Google Calendar or no
    longer synced").
- **Race at `t = 10 s`:** both `RestoreCalendarEvent` and
  `ClaimGcalPendingDelete` lock the `gcal_pending_deletes` row `FOR UPDATE`.
  Either Undo wins first (pending row deleted, worker sees nothing, Google
  is never called) OR the worker wins first (`claimed_at` and `claimed_until`
  set, Undo gets `409 gcal_deleted_at_google`). Both can never run at once,
  and because `claimed_at` is never cleared, Undo can never revive an event
  whose Google call timed out after Google processed it.

**What a second device sees during those 10 s.**
- **A second spool-hub device** (e.g., desktop while the member deleted on
  the phone): `calendar_events.deleted_at` is set at `t = 0`, so the entry
  disappears on the second device's next calendar read
  (`store/calendar_postgres.go:197`, `:420`; calendar writes send no live
  WebSocket frame, `hub/calendar.go:34`). It appears in the member's
  Calendar Trash (`GET /v1/calendar/trash`, `:377`) right away, so the
  member can even click **Restore** from the second device within the 10 s
  window to cancel the pending Google delete (after 10 s, Restore in Trash
  answers 409 `gcal_deleted_at_google`). If Undo succeeds on either device,
  the entry is live again on the next read.
- **Google Calendar itself** (Google web/mobile app, or guests on a shared
  calendar): **still shows the event live** during those 10 s, and guests
  receive no cancellation yet. Once `run_after` passes and the worker runs
  (~10-12 s), Google removes it and notifies guests. If undone within 10 s,
  Google never sees any delete or flicker.
- **Another workspace member:** never saw the entry (imports are `private`,
  `store/gcal_import.go:59-62`).

**Sync-cycle protection during the 10 s wait and Undo (no early delete, no post-Undo delete, no revive).**
- **Kind (a) out half (`hub/gcal_sync.go:518-525`):** `GcalEventMaps`
  (`store/gcal_postgres.go:136-148`) joins `calendar_events` and populates
  `GcalEventMap.IsGcalImport` (`coalesce(e.source_key, '') LIKE 'gcal:%'`).
  In `out()`, any map row with `m.IsGcalImport == true` is **never** passed
  to `cy.remove`: the pending-delete worker is the sole path that deletes a
  trashed kind (a) import at Google (and removes its map row). Why not a
  pending-list read in `out()`? If a cycle ran `events()` at `t0+2 s` (event
  trashed), the member clicked Undo at `t0+3 s` (event restored, pending row
  deleted), and `out()` then checked the pending list (now empty), `out()`
  would still call `cy.remove` and delete at Google after Undo — leaving a
  permanent split (`push` skips an unmapped `gcal:` row, `hub/gcal_sync.go:534-536`).
  Skipping `m.IsGcalImport` in `out()` closes both races at once while
  keeping Spool-created events (`IsGcalImport == false`) on `cy.remove`
  (`TestGcalSyncDeletesTrashedEvent`, `hub/gcal_sync_test.go:230`).
- **Kind (a) and (b) in half (`store/gcal_import.go:141-142`, `:101-118`):**
  `PutGcalImported` refuses to update/revive a row that has an entry in
  `gcal_pending_deletes` (returning `store.ErrGcalPendingDelete`, which
  `sourceTake` at `hub/gcal_sync_sources.go:246` and `put` at
  `hub/gcal_sync_in.go:197` skip cleanly). Even a sync cycle already in
  flight when the member clicked Delete cannot revive the entry mid-wait.

**Step C: Asynchronous execution after 10 s (`runGcalPendingDeletes`).**
`RunSweeper` (`hub/server.go:750`) starts `go s.runGcalPendingDeletes(ctx)`
ticking every `gcalPendingPollEvery = 2 * time.Second` (no-op when
`s.o.Gcal == nil || len(s.o.Gcal.Workspaces) == 0 || !s.o.Gcal.configured()`).
Each tick loops up to `gcalPerTick` (50) calling `GcalPendingDeleteOnce(ctx)`:

1. **Claim:** `ClaimGcalPendingDelete(ctx, now, 2*time.Minute)` (operator
   scope, listed in `store/operator_scope_test.go:19`): one atomic `UPDATE
   gcal_pending_deletes SET claimed_at = COALESCE(claimed_at, $1),
   claimed_until = $2 WHERE (tenant_id, event_id) = (SELECT tenant_id,
   event_id FROM gcal_pending_deletes WHERE run_after <= $1 AND
   (claimed_until IS NULL OR claimed_until < $1) ORDER BY run_after FOR
   UPDATE SKIP LOCKED LIMIT 1) RETURNING ...` (same subquery pattern as
   `ClaimGcalConnection`, `store/gcal_postgres.go:157-161`).
2. **Connection status and sync lease:** read `GcalConnection` **before**
   `ClaimGcalMember` (`ClaimGcalMember` filters `status <> 'revoked'`,
   `store/gcal_postgres.go:179`, so calling it first would mistake a
   mid-wait revocation for a busy lease and defer forever):
   - `ErrNotFound` (member disconnected mid-wait): drop the pending row
     (`DeleteGcalPendingDelete`; `ON DELETE CASCADE` also removes it), no
     Google call, audit `"not_connected"`.
   - `c.Status == store.GcalRevoked` (revoked mid-wait, e.g., a 60 s cycle
     hit `invalid_grant` at `t0+5 s`): **heal immediately**
     (`HealGcalPendingDelete`: restore entry + delete pending row), log
     warning, no Google call.
   - Otherwise call `ClaimGcalMember` (`hub/gcal_sync.go:155`). If it
     returns `ErrNotFound`: re-read `GcalConnection` (if now `revoked`,
     heal immediately; if absent, drop); else a sync cycle holds the lease
     -> if `now.Sub(*pd.ClaimedAt) >= gcalLease` (5 min cap,
     `hub/gcal_sync.go:47`), **heal** and log warning so a stuck lease never
     loops forever; otherwise defer 5 s (`DeferGcalPendingDelete`, clearing
     `claimed_until` and pushing `run_after = now + 5s`; `claimed_at` stays
     set and `attempts` is unchanged).
   From here on, a `defer` releases the sync lease with
   `ReleaseGcalLease(l, nextDue)` (row D1s), never `FinishGcalSync`
   (`store/gcal_postgres.go:334-336` would stamp `last_synced_at = now`).
3. **Token:** get/refresh access token with `token` and `call`
   (`hub/gcal_sync.go:363`, `:400`).
4. **Google call:** `DeleteEventWith(ctx, access, pd.CalendarID, pd.GoogleID,
   pd.SendUpdates)` (`sendUpdates=all`, Q17 A).

**What happens on hub restart / crash mid-wait.**
- **Restart before `run_after` (mid-10 s wait):** the `gcal_pending_deletes`
  row is durable in Postgres with `claimed_at IS NULL, claimed_until IS
  NULL`. Undo still works on the restarted or surviving Cloud Run instance;
  once `now >= run_after`, `runGcalPendingDeletes` claims and runs the
  Google delete. Nothing is lost.
- **Crash after claim (mid-HTTP call to Google):** the row stays in
  `gcal_pending_deletes` with `claimed_at` set (so Undo stays refused) and
  `claimed_until = t + 2m`. Once `claimed_until` expires (2 min), another
  instance reclaims the row and calls `DeleteEventWith` again. Because
  `DeleteEventWith` treats `404` and `410` as done (`isGone`,
  `gcal/client.go:228`), a delete that had already reached Google before the
  crash finishes cleanly as `"gone"`; one that had not reached Google
  executes now as `"deleted"`.

**Every failure row.**

Synchronous (`DELETE /v1/calendar/events/{id}`, before any Google call):

| condition | hub answers | spool-hub state |
|---|---|---|
| `?scope=this` or `following` (v1) | 400 `gcal_series_whole_only` | unchanged |
| Stale `If-Match` | 409 `edit_conflict` with current event | unchanged |
| Hub has no Google client or workspace off | 503 `gcal_not_configured` | unchanged |
| Connection `revoked` | 409 `gcal_revoked` | unchanged |
| Kind (a) without calendar scope, or kind (b) grant lacks write scope / `""` | 409 `gcal_reconnect_to_delete` | unchanged |
| Kind (b), cnf lacks write scope | 409 `gcal_delete_not_enabled` | unchanged |
| Kind (b), cached `source_roles[calID]` is `reader` or `freeBusyReader` | 409 `gcal_calendar_read_only` | unchanged |
| Orphan import (`not_connected` / `calendar_not_read`) | 200 `"google": "not_connected" \| "calendar_not_read"` | trashed in spool-hub only; no pending row (`not_connected` keeps Undo/restore; `calendar_not_read` shows no Undo bar) |
| Already in trash / another member | 404 `not_found` | unchanged |

Asynchronous (after 10 s, in `runGcalPendingDeletes`):

| Google / store outcome | spool-hub does | member sees |
|---|---|---|
| 2xx from `events.delete` (`sendUpdates=all`) | kind (a): `DeleteGcalEventMap`; both: delete pending row; Workspace audit row `calendar.gcal_deleted` (`deleted`); `ReleaseGcalLease(l, now)` | stays deleted in both places |
| 404 or 410 (`isGone`) | same as 2xx; audit outcome `gone` | stays deleted in both places |
| Connection disconnected mid-wait (`ON DELETE CASCADE` or `ErrNotFound`) | pending row gone; no Google call; audit outcome `not_connected` | stays trashed in spool-hub |
| Connection `revoked` mid-wait (checked before `ClaimGcalMember`) | **heal** (`HealGcalPendingDelete`: restore entry + delete pending row); hub log warning; no Google call | entry returns; Calendar banner (`CalendarGcalBanner.vue:13-16`) shows revoked + Reconnect |
| Sync lease held by a running cycle | clear `claimed_until`, push `run_after = now + 5s` (`claimed_at` kept; `attempts` unchanged); capped at `gcalLease` (5 min past `claimed_at`), after which **heal** + log warning | transparent; executes once cycle ends (never loops forever) |
| 403 (`gcal.ErrForbidden`, stale `source_roles` or calendar became read-only; unchecked, I believe, that Google answers 403 there) | **heal** (`HealGcalPendingDelete`: atomically restore `deleted_at = NULL, deleted_by = NULL` and delete pending row); record `reader` in `source_roles`; hub log warning (no Workspace audit row); `ReleaseGcalLease(l, c.DueAt)` | entry returns on next calendar read (never split); next delete attempt refuses immediately with 409 `gcal_calendar_read_only` |
| 401 after the one refresh, or `invalid_grant` | `SetGcalStatus(..., store.GcalRevoked, ...)`; **heal** (restore entry + delete pending row); `ReleaseGcalLease(l, c.DueAt)` | entry returns; Calendar banner (`CalendarGcalBanner.vue:13-16`) shows revoked + Reconnect |
| 429, 5xx, timeout (`attempts < 5`) | increment `attempts`, set `last_error`, clear `claimed_until`, defer with backoff (`10s, 30s, 60s, 120s`); entry stays trashed (`claimed_at` keeps Undo refused); `ReleaseGcalLease(l, c.DueAt)` | retried automatically |
| 429, 5xx, timeout (`attempts >= 5`, exhausted) | **heal** (restore entry + delete pending row); `SetGcalStatus(..., store.GcalConnected, "google did not answer when deleting an entry: restored in spool-hub, try again")` (keeps `GcalConnected` like `hub/gcal_sync.go:218` so 60 s sync keeps running; `ClaimGcalConnection` only claims `connected`, `store/gcal_postgres.go:159`); hub log warning; `ReleaseGcalLease(l, c.DueAt)` | entry returns (nothing silently lost or split); detail shown in Settings -> Google Calendar (`settings/calendar-google.vue`) |

**Repeating entries (v1 and Q16 B follow-up D7).**
An import of a Google series is the series itself (its `RRULE:` line);
changed occurrences (`recurringEventId`) are skipped both ways today (2.5,
2.10 B, `hub/gcal_sync_in.go:156`, `hub/gcal_sync_sources.go:240`).
- **In v1 (D0-D6):** a synced repeating entry is deleted whole (`CalendarScopeAll`),
  and the WUI does not show the This / Following / All picker for it. That
  `events.delete` on the series id removes every occurrence is unchecked, I
  believe: Google's `events.delete` page says only "Deletes an event."
- **In the later build (Q16 B, rows D7s / D7h / D7w / D7i):** offer **"Only
  this occurrence"** alongside **"Every occurrence"** (still no "This and
  following": Google has no atomic split-series endpoint, unchecked, I
  believe). Google's
  recurring-events guide cancels one occurrence by setting `status:
  "cancelled"` on that specific instance (unchecked, I believe: looking up
  the opaque instance id via `GET /calendars/{calendarId}/events/{eventId}/instances`
  filtered by `originalStart`, then sending `PATCH` or `PUT` with `{"status":
  "cancelled"}` and `sendUpdates=all`, and Google returning cancelled
  instance items with `recurringEventId`, `originalStartTime` and `status:
  "cancelled"` on `events.list`). What spool-hub must newly track in D7:
  1. **Google client (`gcal/client.go`):** `OriginalStartTime EventTime` on
     `gcal.Event` (`:40-52`), `ListInstances(ctx, access, calendarID,
     seriesID, origStart)` (`events.instances`), and `CancelInstanceWith(ctx,
     access, calendarID, instanceID, sendUpdates)`.
  2. **Cancelled Google instances in Spool (`store/gcal_import.go`,
     `hub/gcal_sync_in.go:156`, `hub/gcal_sync_sources.go:240`):** stop
     dropping Google items with `it.RecurringEventID != ""` when
     `it.Status == "cancelled"` and `it.OriginalStartTime` is set. Store
     them as Spool cancelled exception rows (`calendar_events` with
     `recurring_event_id = series.ID`, `original_start = orig`, `status =
     'cancelled'`, `store/calendar_series.go:48-49`), via a new store helper
     `PutGcalCancelledOccurrence` (narrow exception to
     `normalizeGcalImport`'s `RecurringEventID != ""` ban at
     `store/gcal_import.go:61`). Without this, a subsequent sync or 410 full
     list would not preserve cancelled occurrences across devices.
  3. **Pending occurrence cancels (`rdb/<next>_gcal_occurrence_cancel.sql`):**
     add `scope text NOT NULL DEFAULT 'all' CHECK (scope IN ('all', 'this'))`
     and `original_start timestamptz NULL` (with `CHECK ((scope = 'this') =
     (original_start IS NOT NULL))`) to `gcal_pending_deletes`, plus a
     surrogate `pending_id uuid` PK and unique key `(tenant_id, event_id,
     coalesce(original_start, '-infinity'::timestamptz))` so two occurrences
     of the same series can be pending within the same 10 s window.
  4. **Same 10 s Undo + heal:** `DELETE /v1/calendar/events/{occ_id}?scope=this`
     atomically runs `planCalendarCancel` (`store/calendar_series.go:289-295`)
     + queues the pending row (`scope = 'this'`, `original_start = orig`).
     Undo (`POST /v1/calendar/events/{occ_id}/restore`,
     `store/calendar_postgres.go:349`, `store/calendar_memory.go:210`)
     cancels an unclaimed (`claimed_at IS NULL`) pending row for `(series,
     orig)` and runs `planCalendarRestore` (`store/calendar_series.go:309-317`);
     after claim it returns `409 gcal_deleted_at_google`. On delayed failure
     (403, revoked, exhausted retries), the worker heals via
     `planCalendarRestore`.
  5. **Open question for the holder:** the owner's Q16 B answer explicitly
     reads `(a later build: single Google occurrences are not tracked today)`,
     so this draft keeps v1 on whole-series delete (D0-D6) and puts
     single-occurrence cancel in D7s-D7i. If the holder judges the owner
     expects D7 before turning `calendar.events` on in prd (S9), confirm
     with the owner before placing S9.

Audit:
- One Workspace log row per delete Google accepted (`deleted`, `gone`), or
  per spool-hub-only orphan delete (`not_connected`, `calendar_not_read`),
  through `s.workspaceEvent` (`hub/rbac.go:96`). Written when the delete
  actually completes (not when queued: an undone delete writes no audit row).
- Kind `calendar.gcal_deleted`: a new constant in `store/log_events.go` and
  in `LogEventKinds` (`:71`), with `store/log_events_test.go`'s pinned list
  (`TestLogEventKinds`, `:23-34`) updated in the same row (D1s). It matches
  rdb 0240's kind check, `^[a-z]+(\.[a-z_]+)+$`
  (`rdb/0240_workspace_system_events.sql:41`).
- Actor: the member. Message: the kind (`hub` or `source`) and the Google
  outcome (`deleted`, `gone`, `not_connected`, `calendar_not_read`).
- **Never the title, the Google id or the calendar id.** The import is
  private to its member, and the Workspace log is read by the owner and
  admins (`hub/log_events.go:123`).
- Refusals (403, exhausted retries, revoked) and undone deletes are hub log
  lines only, not Workspace rows.

#### 2.11.5 Scope: which Google permission

Google's Calendar scopes page
(https://developers.google.com/workspace/calendar/api/auth, read 2026-11-25)
gives these meanings, and says to "choose the most narrowly focused scope
possible":

| scope | Google's meaning |
|---|---|
| `.../auth/calendar` | "See, edit, share, and permanently delete all the calendars you can access using Google Calendar." |
| `.../auth/calendar.events` | "View and edit events on all your calendars." |
| `.../auth/calendar.events.owned` | "See, create, change, and delete events on Google calendars you own." |
| `.../auth/calendar.readonly` | "See and download any calendar you can access using your Calendar." (today) |
| `.../auth/calendar.app.created` | "Make secondary Google calendars, and see, create, change, and delete events on them." (today) |

Google's `events.delete` page
(https://developers.google.com/workspace/calendar/api/v3/reference/events/delete)
accepts `calendar`, `calendar.events`, `calendar.app.created` or
`calendar.events.owned`. Google's `calendarList.list` page accepts
`calendar.readonly`, `calendar`, `calendar.calendarlist` or
`calendar.calendarlist.readonly`: `calendar.events` alone does not read the
calendar list.

**Decided (Q15 A, msg `5f7d0b5d`): add `calendar.events`, keep `calendar.readonly`.**
- It deletes in every calendar the member may edit, a shared team calendar
  included. It cannot share or delete whole calendars.
- `calendar.readonly` stays for the calendar list, so `GcalReadScopes` does
  not change.
- `calendar.events.owned` (Q15 B, not chosen) would refuse a team calendar
  the member may edit and does not own; full `calendar` (Q15 C, not chosen)
  can also share and delete whole calendars.

The hub gains `GcalWriteScopes = [calendar.events, calendar]`, beside
`GcalReadScopes` (`hub/gcal_sync_sources.go:51-54`). A member is allowed to
delete kind (b) entries when `gcal.HoldsAny(write, GrantedScopes)`
(`gcal/oauth.go:92`).

`GET /v1/me/google-calendar` (`hub/gcal_connect.go:366-391`) gains
`delete_scope`:
- `granted`: deletes work;
- `reconnect`: cnf has the scope, the member's grant does not;
- `off`: cnf has no write scope.

The settings section and the phone and desktop confirm show "Reconnect
Google Calendar to delete Google entries" with the existing Reconnect button
when it is `reconnect`. A member is never left with a Delete that fails
silently. Members reconnect once (`prompt=consent`,
`include_granted_scopes=true`, 2.2). Until they do, kind (a) deletes still
work and kind (b) answers `gcal_reconnect_to_delete`.

Google classes calendar scopes as sensitive and reviews them (2.10, S8).
That adding `calendar.events` needs a new review of the consent screen is
unchecked, I believe. It is the owner's steps S9-S11 (section 7), never a
lane.

#### 2.11.6 Routes, changed

| route | today (`208e5f757`) | after D1 (v1, Q18 B) | after D7h (later, Q16 B) |
|---|---|---|---|
| `DELETE /v1/calendar/events/{id}` on a `gcal:` import of the caller | 409 `synced_read_only` | 200 `{"event", "google": "pending", "undo_until"}` (kind (a) and (b): trashed locally, Google delete queued for `now + 10 s`, `sendUpdates=all`); or 200 `"google": "not_connected" \| "calendar_not_read"` (orphan, trashed locally only); or 409 `gcal_revoked`, `gcal_reconnect_to_delete`, `gcal_delete_not_enabled`, `gcal_calendar_read_only` (cached `source_roles`), stale `If-Match` (409 with current event); 400 `gcal_series_whole_only` (`this` / `following`); 503 `gcal_not_configured`. Omitted `?scope=` deletes the whole series, also on an occurrence id | also accepts `?scope=this` on an occurrence id (`"google": "pending"`, cancels that Google instance after 10 s); `following` still 400 |
| the same on a repo-synced entry (c), or another member's import | 409 / 404 | unchanged | unchanged |
| `PATCH /v1/calendar/events/{id}` on any synced entry | 409 `synced_read_only` | unchanged | unchanged |
| `POST /v1/calendar/events/{id}/restore` on a `gcal:` import | 200 (unconditional) | 200 if an unclaimed (`claimed_at IS NULL`) `gcal_pending_deletes` row exists (cancels the pending Google delete, puts the entry back), or if no live `gcal_connections` row matches the key's `<connection>` (`not_connected` orphan); else 409 `gcal_deleted_at_google` | same on an occurrence id `{series}_{orig}` when a `scope=this` pending row is still unclaimed |
| `GET /v1/me/google-calendar` | no `delete_scope` | `delete_scope`: `granted` \| `reconnect` \| `off` (row D1c) | unchanged |
| operator writes (`hub/calendar_operator_write.go:141-142`) | 409 | unchanged | unchanged |

`calendarSyncedReadOnly`'s message ("synced from the repo") stays for (c).
The `gcal:` refusals carry their own tokens.

#### 2.11.7 Build rows

Disjoint files per row. Author vendor per the fleet table; R7 reviewer
cross-vendor (`csi-spl-doc/doc/md/rounds-rulebook.md` 2.7.2). "api tests" and
"full tier" as in section 6.

| row | area | files (only these) | after | test (red on `208e5f757`, green on the row) | author | R7 reviewer |
|---|---|---|---|---|---|---|
| D0 client | api | `gcal/client.go` (new `DeleteEventWith(ctx, access, calendarID, eventID, sendUpdates)`; `DeleteEvent` keeps its signature and calls it with `""`, so its three callers, `hub/gcal_sync.go:580` and `hub/channel_move_steps.go:472`, `:480`, do not change), `gcal/oauth.go` (`ErrForbidden` beside `ErrUnauthorized`, `:37-57`, and its case in `(*HTTPError).Is`, `:411`), `gcal/client_test.go`, `gcal/oauth_test.go`, `gcal/fakegcal/fakegcal.go` (records `sendUpdates`; answers 403, 429 or 500 for a marked calendar) | - | `TestDeleteEventWithSendUpdates` (the fake saw `sendUpdates=all` and `none`; red: no such method); `TestDeleteEventForbidden` (`errors.Is(err, gcal.ErrForbidden)`; red: no such error); `DeleteEvent` with no `sendUpdates` sends none (C); the existing 404/410-is-done test unchanged; `go test ./internal/gcal/...`; api tests | claude | agy |
| D1s store + migration | rdb, api | new `rdb/<next>_gcal_pending_deletes.sql` (`gcal_pending_deletes` table + RLS `tenant_scope` / `operator_scope` + `gcal_connections.source_roles`; `<next>` claimed with `do_rdb_migration_next`, after `0323_fleet_ask_queue_order.sql`), `store/calendar.go` (`ErrGcalImportRestore`, `ErrGcalPendingDelete`), `store/calendar_postgres.go` and `store/calendar_memory.go` (`RestoreCalendarEvent`, `:339-374` / `:204-227`: restores a `gcal:` row when it cancels an unclaimed (`claimed_at IS NULL`) `gcal_pending_deletes` row in the same tx or when no live `gcal_connections` row matches the key's `<connection>`, else `ErrGcalImportRestore`), `store/gcal.go`, `store/gcal_postgres.go`, `store/gcal_memory.go` (`GcalConnection.SourceRoles`, `GcalSyncDone.SourceRoles` written in `FinishGcalSync` `:334-336` via `source_roles = coalesce($8::jsonb, source_roles)`, `GcalEventMap.IsGcalImport` populated by `GcalEventMaps` `:136-148` joining `calendar_events`, `ReleaseGcalLease(l, nextDue)`, `TrashAndQueueGcalDelete`, `ClaimGcalPendingDelete`, `DeferGcalPendingDelete`, `DeleteGcalPendingDelete`, `HealGcalPendingDelete`, `SetGcalSourceRole`), `store/gcal_import.go` (`PutGcalImported`, `:141-142` / `:101-118`: refuses to revive a row with a `gcal_pending_deletes` entry, returning `ErrGcalPendingDelete`), `store/log_events.go` and `store/log_events_test.go` (`calendar.gcal_deleted`, `:71` / `:23-34`), `store/crosstenant_test.go` (seed `gcal_pending_deletes`, `:787`, `:813`), `store/operator_scope_test.go` (`ClaimGcalPendingDelete` in `operatorCallers`, `:19`), `store/calendar_test.go`, `store/gcal_test.go`, `store/gcal_import_test.go` | - | memory and Postgres: `TestGcalPendingDeleteQueueAndUndo` (atomic trash + queue; `RestoreCalendarEvent` before claim cancels the pending row and restores the event; **red control**: no table / method); `TestCalendarRestoreRefusesClaimedOrFinalizedGcalImport` (after `ClaimGcalPendingDelete` or with no pending row on a live connection: `ErrGcalImportRestore`, still trashed; **red control**: on master a trashed `gcal:` row restores); `TestCalendarRestoreAllowsDisconnectedOrphanImport` (no matching connection row -> restores); twin: plain and `goal:` events still restore (C); `TestGcalPendingDeleteClaimRace` (two goroutines claim one due row: exactly one wins; `claimed_until` expiry lets a restarted worker reclaim while `claimed_at` stays set); `TestGcalImportSkipsPendingDelete` (`PutGcalImported` returns `ErrGcalPendingDelete` and leaves `deleted_at` set); `TestGcalEventMapsMarksImport` (`IsGcalImport` true for `gcal:`, false for Spool event); `TestGcalFinishSyncStoresSourceRoles`; `TestGcalPendingDeleteHeal` (restores `deleted_at = NULL` and deletes pending row atomically); `TestGcalReleaseLease` and `TestGcalReleaseLeaseFenced` (`last_synced_at` unchanged); `TestCrossTenantEveryTable`, `TestOperatorScope`, `TestLogEventKinds`; full tier | claude | agy |
| D1 hub | api | new `hub/gcal_delete.go`, new `hub/gcal_delete_test.go`; `hub/calendar.go` (DELETE branch at `:1167`; restore maps `ErrGcalImportRestore` to 409 `gcal_deleted_at_google` at `:1184`); `hub/server.go` (one line in `RunSweeper` beside `:750`: `go s.runGcalPendingDeletes(ctx)`); `hub/gcal_sync.go` (`out()` at `:518-525` skips `cy.remove` whenever `m.IsGcalImport` is true; passes `srcRoles` to `FinishGcalSync`, `:346`); `hub/gcal_sync_in.go` (`put` at `:197` skips `ErrGcalPendingDelete`); `hub/gcal_sync_sources.go` (`GcalWriteScopes` beside `:51-54`; `sourceCalendars` `:153` / `:176-180` records `AccessRole`; `sourceTake` `:246` skips `ErrGcalPendingDelete`) | D0, D1s | memory and Postgres (fake clock, zero `sleep`s per dev guide 2.12.6): `TestGcalDeleteQueuesAndExecutesAfter10s` (both kind (a) and (b): DELETE returns 200 `"google":"pending"` + `undo_until`, 0 Google calls before `now+10s`; advance fake clock +10 s and call `GcalPendingDeleteOnce`: fake saw 1 `events.delete` with `sendUpdates=all`, kind (a) map row gone, audit row written; **red control**: on master 409 `synced_read_only`); `TestGcalDeleteUndoWithin10s` (DELETE then `POST .../restore` at `+5s`: 200, entry live, advance clock +10 s + worker: 0 Google calls, 0 audit rows); `TestGcalDeleteUndoDuringSyncCycle` (kind (a): cycle reads `events()` at `+2s`, member clicks Undo at `+3s`, cycle finishes `out()`: 0 Google calls, map row kept, entry live; **red control**: removing the `m.IsGcalImport` skip calls `DeleteEvent`); `TestGcalDeleteUndoAfterClaimRefused` (advance +10 s, worker claims/runs, then `POST .../restore`: 409 `gcal_deleted_at_google`); `TestGcalDeleteSecondDeviceSeesTrashedAndCanUndo` (GET list hides event at `+2s`; Trash lists it; Restore brings it back); `TestGcalDeleteSurvivesRestartMidWait` (new `Server` on same store after `+10s` runs pending delete; also crash after claim -> reclaim after 2 m -> 404/410 treated as `"gone"`); `TestGcalDeleteSyncCycleDoesNotJumpOrRevive` (full `GcalSyncOnce` at `+3s` neither calls `remove` for kind (a) nor revives kind (b)); `TestGcalDeleteRevokedMidWaitHeals` (delete at `t0`, connection set `revoked` at `+5s`, worker at `+10s` heals immediately and restores entry, 0 Google calls, no defer loop); `TestGcalDeleteLeaseWaitCapHeals` (lease held past `gcalLease` 5 min -> heals); `TestGcalDeleteSeriesWholeOnly` (DELETE on occurrence id with no `?scope=` and `?scope=all` trashes series and queues series id; `this` / `following` -> 400); `TestGcalDeleteStaleIfMatch` (409 conflict, 0 pending rows, 0 Google calls); `TestGcalDeleteCachedReadOnlyRefusedSync` (cached `reader` role -> 409 `gcal_calendar_read_only` synchronously); `TestGcalDeleteDelayed403Heals` (stale role -> 403 after 10 s restores entry, caches `reader`, releases lease with `due_at` unchanged); `TestGcalDeleteDelayedInvalidGrantHeals` (sets `revoked`, restores entry, releases lease); `TestGcalDeleteDelayed5xxRetriesThenHeals` (500/429 retries up to 5 attempts with backoff, Undo refused during retry, 5th failure heals + sets `status_detail` keeping `GcalConnected`); `TestGcalDeleteDelayedWhileSyncRunsDefers` (lease held -> defers 5 s without burning retry budget, succeeds once released); `TestGcalDeleteDisconnectMidWaitCancels` (disconnect drops pending row, 0 Google calls); `TestGcalDeleteNeedsWriteGrant`, `TestGcalDeleteNotConfigured`, `TestGcalDeleteRevoked`, `TestGcalDeleteOrphanImport` (`not_connected` restores cleanly), `TestGcalDeleteKeepsLastSynced`, `TestGcalDeleteOtherMember`, `TestGcalDeleteAuditRowNoTitle`; (C) twins: PATCH import, DELETE `goal:`, operator DELETE still 409; api tests; full tier | claude | agy |
| D1c status | api | `hub/gcal_connect.go` (`delete_scope` on `GET /v1/me/google-calendar`, `:366-391`), `hub/gcal_connect_test.go` (`TestGcalStatusDeleteScope`) | D1 | `TestGcalStatusDeleteScope` (`granted` when cnf + grant hold `calendar.events`, `reconnect` when cnf holds it and grant lacks it or is `""`, `off` when cnf lacks it; **red control**: on master GET has no `delete_scope` field); api tests | claude | agy |
| D2 WUI | wui | `wui/utils/calendar-event-form.mjs` (`calGoogleDeletable(ev, viewer)`: `gcal:` key and viewer is creator; `calEditable` unchanged, `:176`), `wui/utils/calendar-events-api.mjs` (carry `google` and `undo_until` from DELETE alongside `event`, `:68-74`, keeping `err.token`), `wui/components/CalendarPhonePeek.vue` (Delete for `calGoogleDeletable` with in-place confirm; on `"google":"pending"` or `"not_connected"` shows 10 s `UndoSnackbar` `:125-138` calling `calendarRestore` `:330`; maps `gcal_deleted_at_google` on late Undo `:333` and `gcal_*` refusals on Delete; viewer id chain as `CalendarEventDialog.vue:314`), `wui/components/CalendarEventPopover.vue` (Delete beside Duplicate with same confirm; `:today` prop; emits `deleted` for Undo; "Change it in the repo" `:47-50` for repo-synced only, "From Google Calendar" for `gcal:`), `wui/components/CalendarMainView.vue` (pass `:today` and wire `@deleted="onDeleted"` on `CalendarEventPopover`, `:185`), `wui/composables/useCalendarMenus.ts` (`undoDelete` `:32-46` maps `gcal_deleted_at_google`), `wui/components/CalendarTrash.vue` (`gcal_deleted_at_google` message, `:77-78`), `wui/components/settings/calendar-google.vue` (`delete_scope` line + show `status_detail` when `connected` too, beside `:77`), `wui/utils/gcal-client.mjs`, `wui/utils/calendar-mock.mjs` (`gcal:` item deletes with `google: 'pending'` and 10 s mock Undo window; restore inside window succeeds, after window / finalized answers 409 `gcal_deleted_at_google`; read-only mock answers 409 `gcal_calendar_read_only`), `wui/types/calendar-shims.d.ts`, `csi-spl-wui/i18n/locales/en.json` (new keys only), `tests/unit/calendar-event-form.test.mjs`, `tests/e2e/calendar-phone-peek.test.mjs`, `tests/e2e/calendar-synced.test.mjs` | D1, D1c (their tokens; the mock lets D2 be tested first) | unit: `calGoogleDeletable` true for viewer's own `gcal:` import, false for `goal:` and another creator, `calEditable` still false for both (C). **Phone e2e** (`calendar-phone-peek.test.mjs`, 390 px): a Google entry's peek shows Delete, first tap asks with "also deleted in Google Calendar", second removes it and **shows the 10 s Undo bar**; tapping Undo restores it; clicking Undo after the mock window shows "Already deleted in Google Calendar"; repeating asks "every occurrence" with no This / Following / All; read-only mock shows the 403 message and stays (**red control**: on master the peek has no `calpeek-actions` for it). **Desktop e2e** (`calendar-synced.test.mjs`): pop-over Delete with the same confirm and 10 s Undo bar (and Undo restores it), no "Change it in the repo" on a Google entry; Trash shows the Google message on 409; repo-synced keeps no Delete and keeps that label (C). `pnpm run typecheck`; `BASE_URL=<mock bundle> pnpm run test:e2e`; `perf-budget.py` | claude | agy |
| D3 i18n | wui | `csi-spl-wui/i18n/locales/*.json` except `en.json` (D2's keys only) | D2 | `i18n-parity.test.mjs`, `i18n-untranslated.test.mjs` (baseline never raised; **red control**: after D2 alone, `i18n-parity.test.mjs` fails on the new `en.json` keys missing from the other locales); `do_spl_lang_review_gct` before land | agy | claude |
| D4 cnf text | cnf, iac | `csi-spl-cnf/csi-spl/dev.env.yaml` (a `gcal.scopes` override that adds `calendar.events`), its tpl-gen output; `csi-spl-iac/src/bash/tests/hub-gcal-030.tst.sh` (one more assertion); later the same in `all.env.yaml` for prd | D1 | `hub-gcal-030.tst.sh` (it already compares `SPOOL_HUB_GCAL_SCOPES` in each env's rendered 030 tfvars with the cnf, `:34-36`) gains: dev's rendered `030-cloud-run-hub.vars.tfvars` carries `https://www.googleapis.com/auth/calendar.events` (**red control**: on `208e5f757` dev's scopes lack it; green on D4); `ENV=dev ./run -a do_tpl_gen` then `git diff --exit-code`. That a nested `gcal.scopes` in `dev.env.yaml` overrides `all.env.yaml` is unchecked, I believe: the red control proves it | claude | agy |
| D5 docs | doc | this spec (2.11 status to built), `google-review-submission.md` (the added scope and why), the calendar help page through its qto doc (`csi-spl-doc/doc/help/calendar.md:3`) | D2 | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the qto doc drift check (**red control**: before D5, `spec.md` 2.11 reads `v1.1-draft plan, not built` and `google-review-submission.md` lacks `calendar.events`; both updated on D5) | agy | claude |
| D6 public pages | wui | `csi-spl-wui/src/public/about.html` (`:61-62`, "never writes to, changes or deletes anything in a calendar other than the one it created"), `csi-spl-wui/src/public/privacy.html` (`:62-63`, "It never writes to, changes or deletes anything in any other calendar of yours"), `tests/unit/legal-pages.test.mjs` | D1 | both pages say instead: spool-hub changes nothing in your other calendars, except that it deletes an entry there when you delete it in spool-hub and confirm; `legal-pages.test.mjs` asserts that sentence on both pages (**red control**: on master both pages carry the "never ... deletes" sentence); `do_spl_lang_review_gct` if the pages carry other languages. Must be live on prd before S11: Google's review reads these pages (12.1) | claude | agy |
| D7s later: occurrence client + store + migration (Q16 B) | rdb, api | new `rdb/<next>_gcal_occurrence_cancel.sql` (`scope`, `original_start`, surrogate `pending_id` PK + unique `(tenant_id, event_id, coalesce(original_start, '-infinity'))` on `gcal_pending_deletes`), `gcal/client.go` (`OriginalStartTime`, `ListInstances`, `CancelInstanceWith`), `gcal/client_test.go`, `gcal/fakegcal/fakegcal.go` (`instances` + instance cancel), `store/calendar_postgres.go`, `store/calendar_memory.go`, `store/calendar_series.go` (occurrence-level pending-delete Undo / 409 check on `RestoreCalendarEvent`, `:349` / `:210`), `store/gcal.go`, `store/gcal_postgres.go`, `store/gcal_memory.go` (scope + `original_start` on pending deletes), `store/gcal_import.go` (`PutGcalCancelledOccurrence`), and their tests | D0, D1s | memory and Postgres: `TestGcalClientListAndCancelInstance` (fake saw `events.instances` and `status: cancelled` with `sendUpdates=all`; red: no methods); `TestGcalPendingOccurrenceQueueUndoAndRefuse` (two occurrences of one series queued independently; Undo cancels one without touching the other; after claim -> `ErrGcalImportRestore`); `TestPutGcalCancelledOccurrence` (writes cancelled exception row for imported series, `ListCalendarEvents` omits that occurrence while keeping the rest); api tests; full tier | claude | agy |
| D7h later: occurrence hub (Q16 B) | api | `hub/gcal_delete.go`, `hub/gcal_delete_test.go` (`?scope=this` on occurrence id queues pending instance cancel, worker calls `ListInstances` + `CancelInstanceWith`, heals via `planCalendarRestore` on 403/revoked/exhausted), `hub/gcal_sync_in.go`, `hub/gcal_sync_in_test.go` and `hub/gcal_sync_sources.go`, `hub/gcal_sync_sources_test.go` (ingest cancelled `recurringEventId` items via `PutGcalCancelledOccurrence`) | D1, D7s | memory and Postgres (fake clock): `TestGcalDeleteSingleOccurrence` (`?scope=this` hides only that occurrence, after 10 s fake sees instance `status: cancelled` + `sendUpdates=all` and series stays live; **red control**: on D1 `?scope=this` answers 400 `gcal_series_whole_only`); `TestGcalDeleteSingleOccurrenceUndoWithin10s` (occurrence returns, 0 Google calls); `TestGcalDeleteSingleOccurrence403Heals`; `TestGcalSyncInTakesCancelledOccurrence` (Google cancelled instance stays hidden after 410 full list); `?scope=following` stays 400; api tests; full tier | claude | agy |
| D7w later: occurrence WUI (Q16 B) | wui | `wui/components/CalendarPhonePeek.vue`, `wui/components/CalendarEventPopover.vue` (two-choice picker on repeating `gcal:` entry: "Only this occurrence" / "Every occurrence", no "This and following", both with 10 s Undo), `wui/utils/calendar-events-api.mjs` (pass `?scope=` on `calendarDelete`), `wui/utils/calendar-mock.mjs` (mock single-occurrence cancel + Undo), `csi-spl-wui/i18n/locales/en.json`, `tests/e2e/calendar-phone-peek.test.mjs`, `tests/e2e/calendar-synced.test.mjs` | D2, D7h | phone and desktop e2e: repeating Google entry offers "Only this occurrence" and "Every occurrence" (no "This and following"); choosing "Only this occurrence" removes only that day and shows 10 s Undo (**red control**: on D2 repeating Google entry offers whole-series confirm only); `pnpm run typecheck`; `BASE_URL=<mock bundle> pnpm run test:e2e`; `perf-budget.py` | claude | agy |
| D7i later: occurrence i18n (Q16 B) | wui | `csi-spl-wui/i18n/locales/*.json` except `en.json` (D7w's keys only) | D3, D7w | `i18n-parity.test.mjs`, `i18n-untranslated.test.mjs` (**red control**: after D7w alone, `i18n-parity.test.mjs` fails on the new `en.json` keys missing from the other locales); `do_spl_lang_review_gct` before land | agy | claude |
Order:
- **v1 (whole-series delete + 10 s Undo):**
  - D0 and D1s at once, then D1, then D1c.
  - D2 after D1 and D1c (its mock may start at once), then D3.
  - D4 after D1; its 030 apply is the owner's S9.
  - D6 after D1, and live on prd before S11.
  - D5 after D2 (and updated again once D7w lands if D7 follows later).
- **Later follow-up (Q16 B, "only this occurrence"):**
  - D7s after D0 and D1s, then D7h after D1 and D7s, then D7w after D2 and D7h, then D7i after D3 and D7w.

D0, D1s and D1 alone make kind (a) deletable everywhere with the 10 s Undo,
before any owner step. Kind (b) needs D4, D6 and S9-S11, plus each member's
reconnect.

Which kind the owner's screenshot shows is unchecked: the picture does not
show the calendar. Entries from the member's primary Google calendar are
kind (b).

#### 2.11.8 Owner questions (answered)

Form `a1df35e6` in t1 `d51a95c5` (#spool-hub-bugs), answered by the owner
(HUM-10, msg `5f7d0b5d`, 2026-11-25 07:2xZ):

| # | question | owner's answer (msg `5f7d0b5d`) | design impact in v1.1-draft |
|---|---|---|---|
| Q15 | Which Google permission? | **A** — Edit events on all my calendars (`calendar.events`) | **No design change:** matches the initial draft (2.11.5, D4, S9-S11). |
| Q16 | Repeating Google entry: what does Delete remove? | **B** — Also offer "only this occurrence" (a later build: single Google occurrences are not tracked today) | v1 (D0-D6) keeps whole-series delete as written; later follow-up rows **D7s / D7h / D7w / D7i** add "only this occurrence" via Google's instance `status: cancelled` (2.11.4, 2.11.7). Open question for the holder: confirm whether D7 follows after S9 or gates it. |
| Q17 | Should Google send cancellation emails to guests? | **A** — Yes: Google sends its usual cancellation to the guests (`sendUpdates=all`) | **No design change:** matches the initial draft (2.11.4, D0). |
| Q18 | After deleting a Google entry, is there an Undo? | **B** — A 10 s Undo: the Google delete waits 10 s before it runs (more to build) | **Revised throughout 2.11:** replaced "no Undo" with a 10 s server-side pending-delete queue (`gcal_pending_deletes`, `runGcalPendingDeletes`), Undo via `POST /v1/calendar/events/{id}/restore` (409 `gcal_deleted_at_google` only after claim/run), cached `source_roles` read-only pre-check, delayed-failure healing, and updated D1s / D1 / D2 rows (2.11.3, 2.11.4, 2.11.6, 2.11.7). |

Original poll text (for the record):

```poll
Q15. Deleting Google entries from spool-hub needs one more Google permission. Which one?
(A) Edit events on all my calendars ("calendar.events"): deletes in every calendar you may edit, team calendars included; cannot share or delete whole calendars  [CHOSEN, msg 5f7d0b5d]
(B) Edit events only on calendars I own ("calendar.events.owned"): narrower; an entry of a team calendar you do not own cannot be deleted from spool-hub
(C) Full calendar access ("calendar"): also share and delete whole calendars, which spool-hub never does
```

```poll
Q16. A Google entry that repeats (a weekly meeting): what does Delete in spool-hub remove?
(A) Every occurrence, here and in Google; the question says so
(B) Also offer "only this occurrence" (a later build: spool-hub does not track single Google occurrences today)  [CHOSEN, msg 5f7d0b5d]
```

```poll
Q17. You delete a Google meeting you organised that has guests. Should Google tell them?
(A) Yes: Google sends its usual cancellation to the guests  [CHOSEN, msg 5f7d0b5d]
(B) No: the meeting goes from your calendar; guests get no message
```

```poll
Q18. After a Google entry is deleted from spool-hub, is there an Undo?
(A) No Undo: spool-hub asks first, and the entry is gone in both places
(B) A 10 s Undo: the Google delete waits 10 s before it runs (more to build)  [CHOSEN, msg 5f7d0b5d]
```
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
| `POST` / `GET /v1/me/google-calendar/connect?workspace=&want=` | member | `{authorize_url}` / 302; `want` = `calendar` (the default), `contacts` or `calendar,contacts` (spec 154 B7), else 400 `bad_want` |
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
| S9 | write scope (2.11, Q15) | after row D4 lands: the step-030 apply for dev with `calendar.events` (or Q15's answer) in `gcal.scopes` (owner go), members of dev reconnect and a delete is tried; then the same in `all.env.yaml` and the prd 030 apply. Dev first, prd after (dev equals or leads prd) |
| S10 | consent screen (2.11) | add the Q15 scope to the OAuth consent screen of each env's project (S0) |
| S11 | Google verification of the added scope (2.11) | after row D6 is live on prd (the public pages say spool-hub deletes there when asked), submit the consent screen again with the new scope and why (`google-review-submission.md`, row D5); until it passes only listed test users can grant it (unchecked, I believe, that the added scope reopens the review) |

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
| 2026-11-25 07:2x | HUM-10 (owner) | answered form `a1df35e6` (t1 `d51a95c5`, msg `5f7d0b5d`): Q15 A (`calendar.events`), Q16 B ("only this occurrence", later build), Q17 A (`sendUpdates=all`), Q18 B (10 s Undo, delayed Google delete) |
| 2026-11-25 | a-514 | revised section 2.11 to v1.1-draft on `208e5f757` (`d5ca55dbc`, SPL-6484): recorded Q15-Q18 answers, designed 10 s server-side pending delete + Undo for Q18 B, added later rows D7s/D7h/D7w/D7i for Q16 B; sent for cross-vendor review |
| 2026-11-25 | c-532 (claude) | cross-vendor review of `d5ca55dbc` (msg `d25d64b3`): FAIL with W1 (Undo-vs-sync-cycle race on kind (a) `out()`), W2 (`ClaimGcalMember` revoked mid-wait defer loop), W3 (mistral named as backup R7 reviewer against rulebook 2.7.2), and N1-N10 |
| 2026-11-25 | a-514 | folded `c-532` W1-W3 and N1-N10 (`GcalEventMap.IsGcalImport` skips `out()` `remove` for `gcal:` imports; `GcalConnection` checked before `ClaimGcalMember` + `gcalLease` defer cap; dropped mistral from R7 and aligned D3/D5/D7i authors to fleet table; valid subquery `UPDATE`, disconnected-orphan restore, D1c split, red controls, line fixes, N9 unchecked mark) |

## 11. Signatures

v1.0 is signed by each seat's own message on that sha.

| seat | vendor | signature |
|---|---|---|
| c-910@sat (editor) | claude | this commit |
| c-576 (second box) | claude | "SIGN v1.0 b84dec239" (msg `f42378fa`), with its own re-check of the v0.4 -> v1.0 diff; its note: on B1-B8 the named primary reviewer agy is not a panel seat and is out of quota, so the backup (mistral) covers it, said in each row brief |
| m-911@sat | mistral | none: voided by c-002 (msg `cb6c814b`); nothing of it is folded in |
| agy seat | agy | none: not placed before the owner's go (agy out of quota, c-002 msg `9ec38fd7`); it did not review |

Section 2.11 v1.1-draft (SPL-6484, Q15-Q18): authored by `a-514` (agy) on
`208e5f757`; unsigned, awaiting cross-vendor review and holder GO.

## 12. Google verification: the home page (SPL-6204)

Google's branding review of the OAuth app (owner HUM-10, topic
1d9ec3c5, msgs 8dde8db4 and 7bcccf80, 2026-11-21) said the home page
`https://<BASE_DOMAIN>` is "unresponsive" and "not registered to you", and
that a home page must identify the app, describe what it does and say why it
asks for Google data. Measured by c-002 before this change (n=1): `/`
answered 200 with `x-robots-tag: noindex, nofollow`, and its HTML without
JavaScript was only "Loading Spool… / Buy a workspace", with no link to
`/privacy` or `/terms`.

### 12.1 What the page set holds

| item | where |
|---|---|
| `/about`: static, no JavaScript; names spool-hub and Csitea, what it does, why it asks for Google Calendar (the one Spool Hub calendar, two ways; the shown calendars read-only as private events, section 2.10; once 2.11 is built, an entry the member deletes in spool-hub is deleted there too, which row D6 says on this page), the Limited Use line; links `/privacy`, `/terms`, `/login` | `csi-spl-wui/src/public/about.html` |
| Limited Use, in Google's words, with the policy link; the read of the shown calendars stated (it said "does not read ... any other calendar", which `calendar.readonly` made untrue) | `privacy.html` section 3 |
| `X-Robots-Tag: index, follow` on `/about`, `/privacy`, `/terms` on an indexable build (cnf `env.wui.seo_index`, prd); every other path keeps `noindex, nofollow`, `/` included | `STATIC_PUBLIC_SOURCES` in `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` = `STATIC_PUBLIC_PAGES` in `csi-spl-wui/src/utils/public-seo.mjs` |
| `Allow:` lines in robots.txt and one sitemap entry each | `buildRobotsTxt`, `sitemapEntries` (`public-seo.mjs`) |
| the home URL leads there: the prerendered shell at `/` (read without JavaScript) and the sign-in links row link `/about` and `/privacy` | `src/layouts/default.vue`, `src/components/LoginLinks.vue` |

Tests: `tests/unit/legal-pages.test.mjs`, `hosting-cache.test.mjs`,
`public-seo.test.mjs`, `tests/e2e/about-page.test.mjs` (`/about` read with
JavaScript off, its links, the shell at `/`, the sign-in links).

### 12.2 The owner's console steps (never a lane)

1. Search Console: verify the domain `<BASE_DOMAIN>` (a DNS TXT record) with
   the Google account that owns the OAuth project; that answers "not
   registered to you".
2. Google Auth Platform, Branding: home page `https://<BASE_DOMAIN>/about`
   (the app itself stays at `/`, `noindex`; that Google accepts a home page
   with a path is unchecked, I believe), privacy `https://<BASE_DOMAIN>/privacy`,
   terms `https://<BASE_DOMAIN>/terms`. Then ask for the review again.

### 12.3 Spec 116

`/about` is not spec 116's public front page and builds none of its design:
it is the smallest static page Google's review needs. When 116's front page
is built it can take this text or link it; `/about` stays as the page a
crawler reads without JavaScript.

<a id="s13-gcal-in-edits"></a>
## 13. Google edits by a member who may edit the event (SPL-6247, plan)

Status: **plan, not built, not signed.** An amendment to 2.5 "In" for the
requester of topic 1d9ec3c5 (HUM-5, poll cc419749 answer A, msg
604ab12e): "edits in Google to events she may edit in Spool Hub are taken
over". Every `file:line` below was read on origin/master `8604ad411` with
`sed -n` / `grep -n`. Paths as at the top of this spec.

### 13.0 In plain words

1. Today, when a member changes a workspace event in their phone's
   "Spool Hub" calendar, Spool keeps the change only if that member created
   the event; otherwise Spool puts the old values back within a minute.
2. After this change, Spool keeps the change whenever that member is
   allowed to edit the event in Spool Hub itself, exactly as if they had
   edited it in the web app.
3. Deleting such an event on the phone moves it to Spool's trash, as a
   delete in the web app does.
4. Everyone else who connected Google sees the change in their own
   "Spool Hub" calendar on their next sync (about a minute).
5. A NEW event added on the phone, and who may change a shared event at
   all, follow the three sharing kinds of 13.6 (private, workspace can
   read, workspace can edit), the requester's answer to Q13.

### 13.1 The rule

A Google edit of a mapped Spool event (an item of the member's "Spool Hub"
calendar with a `gcal_event_map` row whose Spool event has no `source_key`)
is written to Spool when the connected member **may edit that event in
Spool**: the same checks the member PATCH runs, not only when they created
it. The conflict rule of 2.5 is unchanged (13.2).

- Today: `hub/gcal_sync_in.go:261`
  `if cur.CreatorID != cy.c.Human || !it.Updated.After(cur.UpdatedAt) { return nil }`
  drops any edit of an event another member or an agent created, and the
  out half (`hub/gcal_sync.go:456` `push`) then writes Spool's values back
  over it at Google.
- The member PATCH: `hub/calendar.go:1121` `handlePatchCalendarEvent` ->
  `calendarWriter` (:938) -> `patchCalendarOnce` (:1060). Spec 097 4.5
  (`specs/097-calendar-full-editing/spec.md:354`): "Who may edit: unchanged
  from 089 (anyone with `notes.send` who can read the event)"; 097 Q4 kept
  it (:896).
- **A Google delete trashes it too**, under the same check. Today
  `hub/gcal_sync_in.go:245` (`case cur.CreatorID == cy.c.Human`) trashes
  only the member's own event; for any other event it drops the map row and
  the out half inserts the event at Google again, so the delete is undone.
  The member DELETE (`hub/calendar.go:1158` `handleDeleteCalendarEvent`)
  runs the same `calendarWriter` checks as PATCH and no creator check, so the
  sync follows it. A delete still beats an edit (2.5).
- An event with a `source_key` that is not this connection's `gcal:` key
  (a repo-synced event, spec 112) stays read-only, as on PATCH
  (`hub/calendar.go:1067` `calendarSyncedReadOnly`, :1167 for DELETE): its
  Google edit and delete are dropped and the out half writes Spool's values
  back. Today it is dropped only because the member did not create it.
- **"The out half writes Spool's values back" does not hold on master**
  for an event Spool did not change meanwhile (13.6.5, finding). Every
  refusal in this section writes back through 13.6.2's `revert`.
- The sync writes only title, description, start, end, all-day, time zone
  and rrule (`hub/gcal_sync_in.go:264-268`); it never changes audience,
  guests, kind or links. So `privateOwnerOnly` (`hub/calendar.go:1017`,
  only the owner sets or clears `private`) never applies, and nothing a
  Google edit carries can widen who reads the event.

### 13.2 The checks at sync time

The cycle has no HTTP request: it runs from the sweeper with the
connection's `tenant_id` and `human_id`. Today it makes no access check at
all (`grep -cE 's\.allowed\(|s\.access\(' hub/gcal_sync.go hub/gcal_sync_in.go`
-> 0 and 0). The PATCH checks, and how the sync makes each:

| check | on PATCH | at sync time | store / code call |
|---|---|---|---|
| membership | `humanTenant` (`hub/resolve.go:60`), then `access` (`hub/rbac.go:45`) answers `rbac.ErrNotMember` for a non-member | the same `s.access` through `s.allowed`; a non-member is refused | `s.o.Authorizer.Access` (`hub/rbac.go:53`); with no request the memo is nil (`hub/privacy.go:255`), so one store read per call |
| role grants `notes.send` | `s.permit(..., rbac.NotesSend)` (`hub/calendar.go:941`) | `s.allowed(ctx, hum, tenant, rbac.NotesSend)` (`hub/rbac.go:63`) | `rbac.Access.Can` (`internal/rbac/rbac.go:391`); roles without it: channel guest and the three accountant roles (`internal/rbac/rbac.go:292-295`) |
| not a demo visitor | `isDemoVisitor` (`hub/calendar.go:944`) | the same call (`hub/demo_quota.go:38`) | `s.access`, role `demo_user` |
| workspace may write | `billing.AllowsWrite(t.BillingStatus)` (`hub/calendar.go:948`) | the same, on `s.o.Store.GetTenant(ctx, tenant)` (as `hub/resolve.go:44`) | `store.GetTenant` |
| reads the event (private filter) | `GetCalendarEvent` (`store/calendar_postgres.go:176`) with `calendarPrivateSQL` (:35): a `private` event is read only by its creator and its guests (`mentions`) | unchanged: `hub/gcal_sync_in.go:176` already reads with the member as viewer; not found -> nothing written | `store.Calendar.GetCalendarEvent`; `UpdateCalendarEvent` (:238) and `TrashCalendarScope` (:301) lock with the same filter (`lockCalendarEvent`, :225) |
| guest-only event | nothing beyond the private filter: a guest of a `private` event may edit it in Spool (097 Q4: "owner-and-guests only") | the same: a guest's Google edit is taken | - |
| synced read-only | `cur.SourceKey != ""` (`hub/calendar.go:1067`) | the same (13.1) | - |

The four "who" checks (membership, `notes.send`, demo, billing) are made
**once per cycle**, the first time a mapped item needs them, and kept for
that cycle. A member who fails them keeps today's behaviour (Spool wins,
the out half writes back), with one log line per cycle naming the reason,
not one per item.

**Conflict rule: unchanged.** The newer side wins (Google `updated` vs
Spool `updated_at`), a tie goes to Spool, the write carries
`IfUpdatedAt: cur.UpdatedAt` (`hub/gcal_sync_in.go:265`) and an
`ErrEditConflict` drops the Google value for this cycle (:270).

### 13.3 Who is recorded, history and notifications

- **Edit.** `UpdateCalendarEvent` takes the member as `viewer` and sets
  `updated_at` (`store/calendar_postgres.go:273-277`); `calendar_events`
  has no editor column (`grep -n 'updated_by\|edited_by' store/calendar*.go`
  -> none), so an edit records who made it nowhere, the same as a PATCH from
  the web app. The creator and owner stay as they were.
- **Delete.** `TrashCalendarScope` writes `deleted_by` = the member
  (`store/calendar_postgres.go:327`). The trash list shows only events the
  viewer deleted (`calendarTrashSQL`, :335): the member who deleted it on
  the phone can restore it in Spool; the creator does not see it in their
  trash. Same as a web-app delete today.
- **History.** There is no event history: `grep -c workspaceEvent
  hub/calendar.go` -> 0 (no Workspace log row for a calendar write), and
  none is added.
- **Notifications.** The PATCH and DELETE handlers send none
  (`hub/calendar.go:1121-1180`; `notify_guests`, :229, is parsed but no
  hub code outside tests reads it). The sync sends none either. Every other
  connected member sees the change through their own out half on their next
  cycle (60 s), and the web app shows it on its next read.

### 13.4 Q13, answered: three sharing kinds

Q13 asked whether a NEW phone event stays private (A) or becomes a
workspace event every member may edit (B). The requester answered neither
alone (topic 1d9ec3c5, msg ce0b5455): "it should be possible to define
events to be workspace-readable , workspace editable and private". That
answer is section 13.6; the default for a new phone event is its Q14.

Today: an unmapped item is imported by `put` (`hub/gcal_sync_in.go:195`)
as `GcalSpoolOf` (:286): audience `private`, kind `other`,
`source_key gcal:<connection>:<google id>`; Google always wins on it
(:182). The member's other Google calendars (2.10 B) stay read-only
private imports either way; only deleting one is written to Google (2.11).

### 13.5 Rows, files, risks

| row | files (only these) | what | test (red on `8604ad411`, green on the row) | author | R7 reviewer |
|---|---|---|---|---|---|
| R1 edits and deletes by an editor | `hub/gcal_sync_in.go`, `hub/gcal_sync_in_test.go` | a per-cycle `mayEdit` (13.2); `patch` replaces `cur.CreatorID != cy.c.Human` with `!mayEdit`; `take` and `cancelled` skip an event with a non-`gcal:` `source_key`; `cancelled` trashes when `mayEdit` (an import as today); the header comment (:15-40) rewritten | new `TestGcalSyncInEditorEditsOthersEvent` (member B, `notes.send`, edits member A's `internal` event in Google, Google newer: Spool has B's title; **red control**: on master Spool keeps A's title, and Google keeps B's, unpatched (13.6.5)); `TestGcalSyncInEditorDeletesOthersEvent` (B cancels it: trashed, `deleted_by` B; red: on master it stays live and is inserted at Google again); twins that pass on both: `...NoNotesSendKeepsSpool` (B a channel guest), `...DemoVisitorKeepsSpool`, `...UnpaidKeepsSpool`, `...NonMemberKeepsSpool`, `...RepoSyncedStaysReadOnly`; `...GuestOfPrivateEdits` (B a guest of A's private event: taken; red on master); the existing C15-C19 tests unchanged; api tests; full tier | claude | agy (mistral) |
| R2 docs | `csi-spl-doc/specs/149-google-calendar-connect/spec.md` (2.5 "In": the creator rule replaced by 13.1; this section's status to built); the calendar help page through its qto doc (`csi-spl-doc/doc/help/calendar.md:3`), one paragraph | the text follows R1 | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the qto doc drift check | agy | claude |
| R3 | - | **replaced** by rows K1-K6 of 13.6.4 (three sharing kinds; a new phone event takes its kind from Google's `visibility`) | - | - | - |

R2 after R1. R1 is still no migration, no cnf, no WUI change; the
migration, the cnf value and the WUI change are 13.6's (K1, K3, K4).

Risks:

- **Two members edit the same event in Google.** Each cycle compares
  Google `updated` with Spool `updated_at`, and a sync write sets
  `updated_at` to the cycle's time, not to Google's. So if member A's cycle
  takes A's edit after member B made a later edit but before B's cycle
  runs, B's edit is older than Spool's `updated_at` and loses: B's phone is
  overwritten with A's values. The window is one cycle (60 s; push, B7, is
  not built: `ls hub/gcal_push.go` -> absent). Accepted for v1; the web
  app's own last-write-wins has the same shape.
- **A member who lost edit rights.** The check runs every cycle, so a role
  change or removal takes effect on the next cycle; their Google edits are
  then overwritten. Separate finding, not in R1: the out half makes no
  membership check either, and a connection is deleted only on disconnect
  (`store/gcal_postgres.go:116`) or when the human row goes
  (`rdb/0217_google_calendar.sql:20`, `ON DELETE CASCADE` on `humans`, not
  on membership). Whether a removed member's "Spool Hub" calendar keeps
  receiving workspace events is unchecked, I believe; it goes to the
  orchestrator as its own lane.
- **Recurring events.** A changed occurrence (`recurringEventId`) is still
  skipped both ways (`hub/gcal_sync_in.go:156`); an edit of a whole series
  is taken as today (the `RRULE:` line, :266). A member who edits one
  occurrence on the phone keeps seeing it reverted.
- **A delete by another member.** It lands in the deleter's trash only
  (13.3); the creator cannot undo it from their own trash. Same as the web
  app today.

### 13.6 Three sharing kinds: private, workspace can read, workspace can edit (SPL-6255, plan)

Status: **plan, not built, not signed.** The requester's answer to Q13
(topic 1d9ec3c5, msg ce0b5455): "it should be possible to define events to
be workspace-readable , workspace editable and private". It replaces Q13
(13.4) and row R3 (13.5). Every `file:line` below was read on origin/master
`0674db0a5` with `sed -n` / `grep -n`. Paths as at the top of this spec.

#### 13.6.0 In plain words

1. Every event has one of three kinds: **private** (only you and your
   guests), **workspace can read** (everyone sees it, only you and the
   workspace admins change it) or **workspace can edit** (everyone sees and
   changes it, as every shared event works today).
2. You pick the kind in the event dialog of the web app; events that exist
   today become "workspace can edit", so nothing changes for them.
3. On the phone, an event marked Private in Google becomes private, one
   marked Public becomes "workspace can read", and one left as it is takes
   the default the requester chooses (13.6.2, Q14).
4. A change on the phone to an event you may not change is undone: Spool
   puts its own version back on your phone within about a minute.

#### 13.6.1 The rule

The kind is two fields of the event, one that exists and one new:

| kind (UI) | `audience` (exists) | `edit_level` (new) | who reads | who edits and deletes |
|---|---|---|---|---|
| Private | `private` | `everyone` (ignored) | creator and guests (`store/calendar_postgres.go:35`, `calendarPrivateSQL`) | creator and guests, as today (13.2 "guest-only event") |
| Workspace can read | `workspace` or `internal` (or `public`) | `owner` | as the audience says today | the creator, and members holding `biz_owner` or `admin` in the workspace |
| Workspace can edit | `workspace` or `internal` (or `public`) | `everyone` | as the audience says today | anyone who reads it and holds `notes.send` (spec 097 4.5, unchanged) |

- **The field.** `calendar_events.edit_level text NOT NULL DEFAULT
  'everyone' CHECK (edit_level IN ('everyone', 'owner'))`, in a new
  migration `rdb/<next>_calendar_edit_level.sql` (number claimed with
  `do_rdb_migration_next` at build time; `ls rdb/ | tail -1` ->
  `0310_t1_issue_backlog_default.sql` today). The default keeps every
  existing row's behaviour: anyone who may edit it today still may.
- **Who is an admin here.** The same pair the roadmap approval uses,
  `roadmapApproverRoles = []string{rbac.BizOwner, rbac.Admin}`
  (`hub/calendar_sync.go:83`), read with `s.access(...).HasAny(...)`
  (`hub/calendar_sync.go:255`). One shared helper, `calendarEditAdmins`,
  so the two lists cannot drift apart.
- **Who may change `edit_level`.** The creator and those admins. Anyone
  else's PATCH that carries `edit_level` is 403 `edit_level_owner_only`,
  the twin of `privateOwnerOnly` (`hub/calendar.go:1017`). Moving to or
  from `private` stays the creator's alone (FR-010, unchanged), so an admin
  can lock or unlock an event but never make someone's event private.
- **Guests of an `owner` event** read it and answer it (RSVP,
  `hub/calendar.go:1251`); they do not edit it. A guest of a private event
  keeps today's rights (097 Q4).
- **Agents.** The operator writes (`hub/calendar_operator_write.go`) act for
  `ordered_by`: an `owner` event is written only when `ordered_by` is its
  creator or an admin; an agent with no `ordered_by` writes only an `owner`
  event it created itself.
- **Where the web app shows and sets it.** The event dialog
  (`wui/components/CalendarEventDialog.vue:168`, today the Private switch
  shown to the creator only, `calCanSetPrivate`,
  `wui/utils/calendar-event-form.mjs:194`) becomes one three-way choice
  "Private / Workspace can read / Workspace can edit", shown to whoever may
  change the kind; the Public switch (:182) stays as it is and is offered
  only with the two workspace kinds. The pop-over
  (`wui/components/CalendarEventPopover.vue`) shows the kind as a label and
  hides Edit, Delete, drag and resize when the viewer may not edit, the
  way a synced event is read-only today (`calEditable`,
  `wui/utils/calendar-event-form.mjs:176`).
- **The wire.** The event object gains `edit_level` (`everyone` | `owner`)
  and `can_edit` (bool, for this viewer), beside `source_key` in
  `calendarEventJSON` (`hub/calendar.go:70`, filled in `toCalendarJSON`,
  :146). `can_edit` is the hub's answer, so the web app never re-derives
  the rule; the list read makes one `s.access` call per request, not one per
  event. POST and PATCH accept `edit_level`; an unknown value is 400.

#### 13.6.2 The phone

Google Calendar has no "others may read but not edit" setting on an event
in one person's calendar; its per-event field is `visibility` (`default`,
`public`, `private`, `confidential`; `gcal/client.go:49` carries it). So
the kind rides on `visibility`, both ways:

| Google `visibility` on a NEW phone event | Spool kind |
|---|---|
| `private` or `confidential` | Private |
| `public` | Workspace can read |
| `default` or absent | **the default, Q14 below** |

- **Out (Spool -> Google).** `GcalEventOf` (`hub/gcal_map.go:49`) today
  writes `private` for a private event and `default` for any other. It
  writes `public` for an `owner` event too, so the member's phone shows the
  lock and a round trip keeps the kind. `visibility` joins the sync hash
  (`GcalSyncHash`, `hub/gcal_map.go:27`) so a kind change in Spool reaches
  Google; every mapped event is patched once after the build (one cycle per
  member, not a burst: the out half already pages by connection).
- **In, a new item.** An unmapped item of the "Spool Hub" calendar becomes a
  normal Spool event (no `gcal:` `source_key`, creator the member, kind
  `other`, then mapped), with the audience and `edit_level` of the table,
  when the member passes the 13.2 "who" checks; a member who fails them
  keeps today's private import (`GcalSpoolOf`, `hub/gcal_sync_in.go:286`).
  A workspace kind gets audience `workspace` (the create default, owner
  decision D2, `store/calendar.go:45-48`), never `public`. The member's
  other Google calendars (2.10 B) stay read-only private imports (a delete
  is the one write, 2.11).
- **In, an edit of a mapped event.** Taken when the member may edit the
  event under 13.6.1 (13.1's `mayEdit`, now with the `edit_level` term).
  A `visibility` change on the phone is not taken in v1: the kind is
  changed in the web app (risk below).
- **In, a refused edit or delete** (an `owner` event the member did not
  create and is no admin of, or any 13.2 refusal): Spool's version is
  written back to Google in the same cycle. Today nothing does that, see
  13.6.5: a new `revert` in `hub/gcal_sync_in.go` PATCHes the item with
  `GcalEventOf(cur)` and stores the new etag and `GcalSyncHash(cur)` on the
  map row. A refused delete drops the map row, and the out half inserts
  the event again, as today (`hub/gcal_sync_in.go:238-254` then
  `hub/gcal_sync.go:456` `push`, `!has`).

**Q14, the default of a new phone event left at Google's default
visibility.** The holder asked the requester (topic 1d9ec3c5, msg
0fec74f4): (P) private, (R) workspace can read, (E) workspace can read and
edit. **Chosen: pending, no answer on this lane's task yet.** The plan works
for each: the default is one cnf value, `env.gcal.new_event_kind`, beside `gcal.workspaces`,
(`private` | `read` | `edit`) in `cnf/all.env.yaml`, read by the in half,
so a later change of mind is a cnf change, not a build. When the answer
lands, this line names it and the cnf default is set to it.

#### 13.6.3 The checks in the hub

One function decides, and every writer calls it:
`calendarMayEdit(a rbac.Access, e store.CalendarEvent, actor string) bool`
in `hub/calendar.go`: true when `e.EditLevel != "owner"`, or `e.CreatorID ==
actor`, or `a.HasAny(calendarEditAdmins...)`. It runs after the event is
read (so the private filter has already answered "not found" to a stranger)
and after `notes.send`.

| writer | today, file:line | the new check |
|---|---|---|
| member PATCH | `patchCalendarOnce`, `hub/calendar.go:1060`: synced check :1067, `privateOwnerOnly` :1091 | after :1067: `!calendarMayEdit` -> 403 `edit_owner_only`; beside :1091: `editLevelOwnerOnly` for a patch that carries `edit_level` |
| member DELETE | `handleDeleteCalendarEvent`, `hub/calendar.go:1158`: synced check :1167, then `TrashCalendarScope` :1171 | at :1167, the same read: `!calendarMayEdit` -> 403 `edit_owner_only` |
| member POST | `handleCreateCalendarEvent`, `hub/calendar.go:973`, `q.newEvent` :985 | takes `edit_level` (default `everyone`); the creator is the actor, so no further check |
| operator PATCH / DELETE | `operatorCalendarSingle`, `hub/calendar_operator_write.go:129` (synced :141) | beside :141, with `ordered_by` (else the agent) as the actor |
| Google in half, edit | `patch`, `hub/gcal_sync_in.go:259`, creator test :261 (13.1 replaces it with `mayEdit`) | `mayEdit` = the 13.2 "who" checks, once per cycle, AND `calendarMayEdit(cycle access, cur, member)` per item; refused -> `revert` |
| Google in half, delete | `cancelled`, `hub/gcal_sync_in.go:238`, creator test :245 | the same `mayEdit`; refused -> map row dropped, the out half inserts it again |
| Google in half, new item | `put`, `hub/gcal_sync_in.go:195` | 13.6.2 "In, a new item" |
| restore | `handleRestoreCalendarEvent`, `hub/calendar.go:1184` | none: it restores only the caller's own deletion, and only someone who could edit could delete |

The store gains the column on every read and write
(`store/calendar_postgres.go:15` `calendarCols89`, the insert :147-155 and
the update :264-277, the import upserts :569-610) and in the memory store;
a database before the migration reads `everyone` (the store already probes
for newer columns, `store/calendar.go`, rdb 0139 note).

#### 13.6.4 Rows, files, tests

| row | files (only these) | what | test (red on master, green on the row) | author | R7 reviewer |
|---|---|---|---|---|---|
| K1 store + migration | `rdb/<next>_calendar_edit_level.sql`, `store/calendar.go`, `store/calendar_postgres.go`, `store/calendar_memory.go`, their tests | the column, its check, read and written everywhere; `CalendarEditEveryone` / `CalendarEditOwner` constants | `TestCalendarEditLevelRoundTrip` (create `owner`, read it back; red: no column); `TestCalendarEditLevelDefault` (an old row reads `everyone`); an `owner` value outside the check is `ErrInvalidCalendarEvent`; `PRE_PUSH_TIER=full` | claude | agy (mistral) |
| K2 hub rule | `hub/calendar.go`, `hub/calendar_operator_write.go`, `hub/calendar_sync.go` (the shared admin list), their tests | `calendarMayEdit`, `editLevelOwnerOnly`, `edit_level` + `can_edit` on the wire | `TestCalendarOwnerEventRefusesOtherMember` (PATCH and DELETE 403 `edit_owner_only`; **red control**: on master both are 200); twins that pass on master: creator edits, an admin edits, an `everyone` event edited by any member; `TestCalendarEditLevelOwnerOnly` (a non-creator, non-admin PATCH of `edit_level` is 403); `TestCalendarCanEditField`; operator twin; api tests, full tier | claude | agy (mistral) |
| K3 Google in + out | `hub/gcal_sync_in.go`, `hub/gcal_map.go`, `hub/gcal_sync_in_test.go`, `hub/gcal_map_test.go`, `cnf/all.env.yaml` (+ rendered twins) | after R1: the `edit_level` term in `mayEdit`, `revert`, the visibility mapping both ways, the new-item kind and the Q14 cnf default | `TestGcalSyncInRefusedEditWrittenBack` (member B edits A's `owner` event in Google: Spool keeps A's title AND Google shows A's title after the cycle; **red control**: on master Google keeps B's title, 13.6.5); `TestGcalSyncInNewEventKindFromVisibility` (private, public, default -> the three kinds; red: on master all three are private imports with a `gcal:` key); `TestGcalEventOfOwnerIsPublic`; the 2.10 source-calendar imports still private (and deletable only per 2.11) | claude | agy (mistral) |
| K4 WUI | `wui/components/CalendarEventDialog.vue`, `wui/components/CalendarEventPopover.vue`, `wui/components/CalendarMainView.vue`, `wui/utils/calendar-event-form.mjs`, `wui/utils/calendar-mock.mjs`, `wui/types/calendar-shims.d.ts`, unit and e2e tests | the three-way kind choice, the label, read-only by `can_edit` | unit: `calEditable` false when `can_edit` is false (red on master: true); e2e: another member opens an `owner` event, no Edit button, drag refused; `pnpm run typecheck`; `BASE_URL=<bundle> pnpm run test:e2e` | claude | agy (mistral) |
| K5 i18n | `csi-spl-wui/i18n/locales/*.json` (19 files) | the kind labels, hints and the two error tokens | `i18n-parity.test.mjs`, `i18n-untranslated.test.mjs` (baseline never raised); `do_spl_lang_review_gct` before land | claude | agy (language) |
| K6 docs | this spec (status to built, Q14's answer), spec 097 4.5, the calendar help page through its qto doc (`csi-spl-doc/doc/help/calendar.md:3`), one section | the text follows K1-K4 | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the qto doc drift check | agy | claude |

Order: K1, then K2 and R1 (R1 first: K3 builds on its `mayEdit`), then K3
and K4, then K5, then K6. K1 is the one migration; K3 the one cnf change.

#### 13.6.5 Risks and findings

- **Finding: a refused Google edit is not written back today.** 13.1 and
  13.2 say "the out half writes Spool's values back". On master it does not
  when Spool's event did not change: the in half drops the edit
  (`hub/gcal_sync_in.go:261`), and the out half skips the event because its
  `updated_at` is not after the out cursor and its hash still equals the map
  row's (`hub/gcal_sync.go:460-466`). The phone keeps the refused edit until
  Spool's event next changes, and the sync token means the in half never
  lists it again. Measured on `0674db0a5`, memory store, n=1 scenario
  over 3 cycles, with a throwaway test (not committed) in the
  `gcal_sync_in_test.go` env: member A's `internal` event pushed to member
  B's calendar, B edits its summary at Google, then `cycle 1..3: spool="A
  title" google="B edit" patches=0`. K3's `revert` fixes it for every refusal
  (13.2's included), so R1 should take `revert` too: this finding goes to
  the R1 lane through the holder.
- **A kind changed on the phone is not taken in v1** (13.6.2). The phone
  shows what the member set; Spool keeps its kind, and the next Spool
  change of that event writes `visibility` back. A follow-up may take it
  for the creator and admins only.
- **Two workspace kinds, one Google level.** `public` means "workspace
  can read" only in the member's own "Spool Hub" calendar; Google shows it
  to people the member shares that calendar with, which Spool does not
  control (unchecked, I believe, that Google's sharing honours `public`
  per event as described in its help).
- **An admin's edit of a locked event** is recorded nowhere (13.3: no editor
  column); the creator sees only the new values. Same as an edit today.
- **Existing events stay `everyone`.** A member who expected their shared
  events to be locked must lock them one by one; the help page says so.

## 14. Membership and sync (SPL-6250)

A connection belongs to a member of one workspace, but it is not tied to the
membership: it goes only on disconnect (`store/gcal_postgres.go:116`) or
when the human row goes (`rdb/0217_google_calendar.sql:20`, `ON DELETE
CASCADE` on `humans`). Measured on 5332dd943, before the fix
(`TestGcalSyncRemovedMemberPaused`, memory and Postgres, n=1 each): after
`RemoveMember`, one cycle wrote a workspace event added after the removal
to the removed member's "Spool Hub" calendar (`events.insert` 1) and took a
Google event of that calendar into the workspace as the member's private
event (1 imported). The out half reads with `SearchCalendarEvents`, which
filters by tenant and the private rule only, and the In half writes with no
access check.

The rule (`hub/gcal_sync.go`):

- **The gate.** Before any Google call, the cycle's `sync` (:245) asks
  `member` (:265): the connection's human must still hold `self.keys` in
  the workspace, read through the hub's authorizer (`hub/rbac.go:45`). It
  is the permission the connect, "Sync now" and disconnect routes ask for
  (`hub/gcal_connect.go:189`, `:398`, `hub/gcal_sync.go:134`). No role
  (`rbac.ErrNotMember`, also a disabled member) or a role without it is
  `errGcalNotMember`; any other error is a failed cycle as before, retried
  after 5 minutes.
- **Paused, not dropped at once.** `pause` (:283) makes no Google call and writes
  nothing into Spool: neither half runs. The row, its sealed tokens and
  its map rows are kept; `status_detail` reads "not a member of this
  workspace: sync paused" and the row is due again after an hour
  (`gcalOffRecheck`). A member admitted again syncs on from where it
  stopped, with no reconnect (`TestGcalSyncReadmittedMemberResumes`). A
  removal by mistake, undone, loses nothing.
- **The Google calendar is left as it is.** What it held at the removal
  stays (the member saw those events while a member); nothing new reaches
  it, and Google edits there no longer reach Spool. Emptying it would need
  Google calls made on the grant of someone who is no longer a member, and
  it holds the member's own Google events too, which are theirs.
- **Dropped after 30 days paused** (owner HUM-5, msg 08cec636, poll
  2c0013de answer A: "Revoke it at Google and delete it after 30 days
  paused"; SPL-6272). The first paused cycle records when the pause began
  (`gcal_connections.paused_at`, rdb 0312); the hourly rechecks keep it,
  and a cycle whose member passes the gate again clears it (`sync`,
  :245). Once a connection has been paused longer than cnf
  `gcal.paused_drop_after` (720h; the hub's fallback, also 30 days, is
  `gcalPausedDropAfter`, `hub/gcal_connect.go:69`), its next cycle
  `drop`s it (:308): the grant is revoked at Google first (`gcalRevoke`,
  `hub/gcal_connect.go:433`), then the row is deleted with its map rows and
  the imported events go to the member's trash (`gcalRemove`, :458, the
  end the disconnect route uses; as `remove_imported=1`). A revoke Google
  refuses keeps the row, paused, and the next hourly recheck tries again:
  a connection is never deleted while its grant may still be live. A
  member added back before the limit resumes with no reconnect. Tests:
  `TestGcalSyncPausedKeptBeforeLimit`,
  `TestGcalSyncPausedDroppedAfterLimit`,
  `TestGcalSyncPausedDropKeepsRowOnRevokeFailure`
  (`hub/gcal_sync_member_test.go`, memory and Postgres).

Tests (`hub/gcal_sync_member_test.go`, memory and Postgres under
`PRE_PUSH_TIER=full`): `TestGcalSyncRemovedMemberPaused` (0 Google calls,
"After" not at Google, nothing imported, the paused row; red with the gate
taken out of `sync`: 2 Google calls) and
`TestGcalSyncReadmittedMemberResumes`.

<!-- version: v1.1-draft (section 2.11 revised for Q15-Q18, SPL-6484; sections 13 and 13.6 a plan) · updated: 2026-11-25 -->
