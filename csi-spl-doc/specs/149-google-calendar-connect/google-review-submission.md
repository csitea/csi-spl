# Spec 149: the Google review submission (O1 = A, O2 = A)

Issue SPL-3331, epic SPL-2750. The owner answered O1 = A (msg `aa5f42a0`:
both ways, through one "Spool Hub" calendar the app creates) and O2 = A
(msg `fcb7a15a`: submit for Google's review now). This page holds the text
the owner pastes into Google's forms and the console clicks for S0, S2, S3
and the submission ([spec](spec.md) section 7). Every console step is the
owner's; no lane does one.

Checked 2026-10-25 on `52c83fdd5`; each claim carries its command or says
it is unchecked.

## 1. The scope

### 1.1 The scope string

```
https://www.googleapis.com/auth/calendar.app.created
```

Google's text for it: "Make secondary Google calendars, and see, create,
change, and delete events on them" (Google's scope list,
https://developers.google.com/workspace/calendar/api/auth, read
2026-10-25).

It is the narrowest Calendar scope that covers O1 = A: the app creates the
one "Spool Hub" calendar, writes Spool events to it and reads its events
back, and sees no other calendar. The wider ones are not needed:
`calendar.events` ("View and edit events on all your calendars") and
`calendar` reach every calendar of the member.

Unchecked, I believe: Google lists `calendar.app.created` as a sensitive
scope (not restricted), so the review is the sensitive-scope verification,
without a security assessment. The scope page above does not state the
class; the console shows it when the scope is added (step 4.2.3).

Unchecked, I believe: push notifications (`events.watch`, row B7) on the
app-created calendar work under this scope. If B7's first watch call is
refused for scope, that is a new owner question, never a wider scope added
by a lane.

### 1.2 The cnf string after S2

After S2, cnf `gcal.scopes` (`csi-spl-cnf/csi-spl/all.env.yaml`) becomes:

```
openid email https://www.googleapis.com/auth/calendar.app.created
```

That is a cnf change, a re-render and a step-030 apply (owner go). It waits
on S2: asking Google for a scope the consent screen does not list fails the
connect.

## 2. The scope justification (Google's form)

Google's form asks why the app needs each sensitive scope and how it uses
the data. The text:

> Spool Hub is a team workspace with a shared calendar. A member may connect
> their own Google Calendar so their Spool events also appear in Google.
> When they connect, Spool Hub creates one secondary calendar named "Spool
> Hub" in their Google account, writes their Spool events to it, and reads
> back the events of that one calendar, so a change made in Google (a moved
> or deleted event) is shown in Spool as their private event. Spool Hub
> never reads, changes or lists any other calendar of the member, which is
> why we ask for calendar.app.created and not calendar.events or calendar.
> The tokens are stored encrypted (Cloud KMS) and are used only for this
> sync. The member can disconnect at any time in Settings; disconnecting
> revokes the token at Google and stops the sync. No calendar data is sold,
> shared with third parties or used for advertising.

The demo video Google asks for (unchecked, I believe: required for
sensitive scopes) shows: sign in, Settings, Calendar (Google), Connect, the
consent screen with this scope, the "Spool Hub" calendar in Google with a
synced event, and Disconnect. It can be recorded only once B8 (the Settings
section) is live and the connect completes (section 3.3).

## 3. The public pages

### 3.1 They answer 200

| page | URL | `curl -s -o /dev/null -w '%{http_code}' -L <URL>` |
|---|---|---|
| home, prd | `https://<BASE_DOMAIN>/` | 200 |
| privacy, prd | `https://<BASE_DOMAIN>/privacy` | 200 |
| home, dev | `https://dev.<BASE_DOMAIN>/` | 200 |
| privacy, dev | `https://dev.<BASE_DOMAIN>/privacy` | 200 |

`BASE_DOMAIN` is cnf `env.dns.BASE_DOMAIN` (`all.env.yaml`). Both privacy
pages are the policy itself, not the app shell:
`curl -sL https://<BASE_DOMAIN>/privacy | grep -o '<h1>[^<]*</h1>'` ->
`<h1>Privacy policy</h1>` (dev the same).

### 3.2 The privacy page does not name calendar data

`curl -sL https://<BASE_DOMAIN>/privacy | grep -ci calendar` -> 0 (dev: 0).
Its "what we keep" list names the account, how you sign in ("for Google,
Facebook, Microsoft or LinkedIn, the provider's id for you and the email
address it confirmed"), what you post and security records; nothing about
Google Calendar. Google's review checks that the policy says how the
scope's data is used (unchecked, I believe), so the page needs a calendar
paragraph before the submission. That is a separate fix
(`csi-spl-wui/src/public/privacy.html`), reported to the dispatcher; this
lane does not make it.

### 3.3 The callback reaches the hub; it answers 404 until gcal is on

The hub builds its redirect URI as the WUI origin plus
`GcalCallbackPath = "/v1/me/google-calendar/callback"`
(`csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_connect.go:60`,
`cmd/spool/hub_gcal.go`). On the WUI host that path already reaches the
hub (Hosting's `/v1/**` rewrite,
`csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`). Before 030:
measured 2026-10-25 on tree 9add9470b, n=1 per path per host, dev and prd
alike:

| path | answer |
|---|---|
| `/v1/me/google-calendar/callback` | 404 `application/json` `{"error":"not_found","detail":"google calendar is not available in this workspace"}` |
| `/v1/me/google-calendar` | 401 `application/json` `view_door` (the hub) |
| `/api/v1/me/google-calendar/callback` | 200 SPA HTML (not routed to the hub) |

After 030 (applied on dev and prd 2026-10-25 17:19-17:23Z, SPL-3384): a
bare request to the callback answers 400 `text/html`, the hub's
`invalid_state` connect page (17:54Z, n=1 per host).

- The 404 is the hub's own answer:
  `grep -rn "not available in this workspace" csi-spl-api/src/go` -> 1 hit,
  `writeGcalOff` (`internal/hub/gcal_connect.go`). The callback returns it
  while gcal is off for the workspace, so it answers 404 until the step-030
  apply of S5 turns it on.
- The nonce cookie path `/v1/me/google-calendar/` (`gcal_connect.go`)
  covers this callback; a callback under `/api/` would not get the cookie.

So no path change is needed (SPL-3381): S3 below registers
`/v1/me/google-calendar/callback` as it is. An earlier version of this
section read the 404 as the SPA's and asked for an `/api/` path; that was
wrong.

## 4. The owner's console steps

All in the Google Cloud console, dev first, then prd. The menu names are
as I believe them, unchecked.

### 4.1 S0: name the project

1. Open APIs & Services, Credentials in project `csi-spl-dev`.
2. Find the OAuth 2.0 client whose id is cnf
   `SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID` (`csi-spl-cnf/csi-spl/dev.env.yaml`).
   If it is there, the project is `csi-spl-dev`; if not, say which project
   holds it: the API and the scope go on that project, and S1's cnf (the
   001 step of `csi-spl-<env>`) is then the wrong place.
3. The same for prd (`prd.env.yaml`, project `csi-spl-prd`).

### 4.2 S2: the consent screen

1. Google Auth Platform (or OAuth consent screen), project of 4.1.
2. Branding: app name, support email, home page `https://<BASE_DOMAIN>/`,
   privacy policy `https://<BASE_DOMAIN>/privacy`, terms
   `https://<BASE_DOMAIN>/terms`, authorised domain `<BASE_DOMAIN>`.
3. Data access, Add or remove scopes: add
   `https://www.googleapis.com/auth/calendar.app.created` (section 1.1);
   it shows under the sensitive scopes. Save.
4. Audience: while in testing, add the members who test it as test users.
5. Tell the dispatcher: a lane then sets cnf `gcal.scopes` (section 1.2).

### 4.3 S3: the redirect URI

1. Credentials, the OAuth client of 4.1, Authorised redirect URIs.
2. Add `https://dev.<BASE_DOMAIN>/v1/me/google-calendar/callback`, the
   path the hub sends (section 3.3). Keep the sign-in URIs.
3. The same on prd with `https://<BASE_DOMAIN>`.

### 4.4 The submission (O2 = A)

Only after section 3.2 is fixed, S5 is applied and the connect works on dev:

1. Google Auth Platform, Verification centre (or the consent screen's
   Prepare for verification), project of 4.1, prd first if Google reviews
   per project (unchecked).
2. Paste section 2 as the justification for `calendar.app.created`.
3. Add the demo video link (section 2) and confirm the home and privacy
   URLs (section 3.1).
4. Submit; Google answers by email to the project's contacts.
5. Post the submission date to the dispatcher, so the issue records it.

## 5. What a lane does next

| after | lane step |
|---|---|
| 3.2 | wui lane: a calendar paragraph in `privacy.html` |
| 4.2 | cnf lane: `gcal.scopes` (section 1.2), re-render, 030 apply with the owner's go |
| S1 / S5 cnf | landed with SPL-3331: `calendar-json.googleapis.com` in the 001 list, `gcal.workspaces: ["all"]`, `SPOOL_HUB_GCAL_*` in the 030 tfvars; the 001 and 030 applies wait on the owner's go |

## 6. The 7-day expiry (SPL-5719, 2026-11-16)

### 6.1 What happened

Every one of the owner's connections on prd was revoked by Google 7 days
after it was made. The hub logs `gcal: connected` on the connect and
`gcal: grant revoked at google` when a refresh answers invalid_grant
(`internal/hub/gcal_connect.go`, `internal/hub/gcal_sync.go`); read with
`ENV=prd FRESHNESS=30d FILTER='jsonPayload.message:"gcal: connect" OR jsonPayload.message:"gcal: grant revoked"' ./run -a do_gcp_tail_logs`
(csi-spl-iac), n=4 revokes:

| workspace | connection | connected (UTC) | revoked (UTC) | after |
|---|---|---|---|---|
| t1 | `9d0a6272` | 2026-10-28 06:24:25 | 2026-11-04 06:24:34 | 7 d 0 h 0 m 9 s |
| a private workspace | `8643d95a` | 2026-10-30 06:37:58 | 2026-11-06 06:38:13 | 7 d 0 h 0 m 15 s |
| csitea | `9869bdd7` | 2026-11-03 10:22:56 | 2026-11-10 10:22:58 | 7 d 0 h 0 m 2 s |
| t1 | `9d0a6272` | 2026-11-07 11:17:37 | 2026-11-14 11:19:18 | 7 d 0 h 1 m 41 s |

Each revoke falls within 2 minutes of its own connect plus 7 days (the
sync runs every minute). A scope change, a client secret rotation or a
password change would revoke every connection at one moment, not each at
its own 7-day mark. The pattern is Google's rule for an OAuth app whose
publishing status is Testing with external users: its refresh tokens
expire after 7 days. The console state itself is unchecked (no lane reads
the console); the owner sees it in step 6.2.1.

The `gcal_connections` row keeps `created_at` across a reconnect
(`ON CONFLICT ... DO UPDATE`, `internal/store/gcal_postgres.go`), so the
row alone reads t1 as 17 days; the log has the reconnect.

csitea was reconnected 2026-11-16 16:30:39Z; unless 6.2 is done first, it
is due to be revoked again around 2026-11-23 16:31Z.

### 6.2 The owner's steps to end it

1. Google Cloud console, the project of the prd sign-in client (S0,
   `csi-spl-prd`): Google Auth Platform, Audience. If the publishing
   status says Testing, press Publish app and confirm. From then on
   refresh tokens no longer expire after 7 days. Until the review of
   step 4 passes, members see Google's "unverified app" page on connect
   (Advanced, then continue), and (unchecked, I believe) at most 100 users
   may grant the calendar scopes. Sign-in asks only `openid email`, which
   are not sensitive scopes, so sign-in is unchanged (unchecked, I
   believe).
2. The same in `csi-spl-dev`.
3. Reconnect each workspace once after step 1: Calendar page, Reconnect
   (the banner of spec section 2.7), or Settings, Google Calendar,
   Reconnect. Unchecked, I believe: a token minted while in Testing keeps
   its 7-day life, so only a new connect gets the longer one.
4. For good, without the warning: submit the review of section 4.4. cnf
   `gcal.scopes` now also asks `calendar.readonly` (S7), so the form needs
   a second justification, below.

### 6.3 The justification for calendar.readonly

> Spool Hub shows the events of a member's existing Google calendars (the
> ones they show in Google Calendar) inside Spool as that member's private
> events, so their Spool calendar shows everything they are booked for. No
> other member sees them. Spool Hub only reads those calendars and never
> changes, creates or deletes anything on them; only the one "Spool Hub"
> calendar it created (calendar.app.created) is written. The member chooses
> to connect and can disconnect at any time in Settings; disconnecting
> revokes the token at Google, stops the sync and, if the member ticks
> "remove imported events", removes the copied events. The data is not
> sold, shared with third parties or used for advertising.

The text follows `internal/hub/gcal_sync_sources.go` (the header comment:
read-only, audience private, nothing written back) and the Disconnect of
spec section 2.7.

Unchecked, I believe: Google asks for this text per scope on the same form
as section 2.
