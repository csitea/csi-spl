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

### 3.3 The callback does not reach the hub

The hub builds its redirect URI as the WUI origin plus
`GcalCallbackPath = "/v1/me/google-calendar/callback"`
(`csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_connect.go:60`,
`cmd/spool/hub_gcal.go`). On the WUI host that path is not the hub:

- `curl -s -o /dev/null -w '%{http_code}' https://dev.<BASE_DOMAIN>/v1/me/google-calendar/callback` -> 404.
- `csi-spl-wui/firebase.json` sends only `/api/v1/auth/**` and
  `/api/v1/marketing/linkedin/callback` to the hub; LinkedIn's callback is
  `LinkedInCallbackPath = "/api/v1/marketing/linkedin/callback"`
  (`internal/hub/marketing_channels.go:54`) with its rewrite.

So after S5 a connect would send the member to Google and come back to a
404. The fix (a `/api/v1/me/google-calendar/callback` path, its route and
its Firebase rewrite, as LinkedIn's) is an api + wui change in another
lane, reported to the dispatcher. S3 below registers the URI that fix
chooses.

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
2. Add `https://dev.<BASE_DOMAIN>` plus the callback path the fix of
   section 3.3 lands (today the hub sends
   `/v1/me/google-calendar/callback`, which 404s). Keep the sign-in URIs.
3. The same on prd with `https://<BASE_DOMAIN>`.

### 4.4 The submission (O2 = A)

Only after sections 3.2 and 3.3 are fixed and the connect works on dev:

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
| 3.3 fixed | api + wui lane: the `/api/v1/...` callback, its route and rewrite |
| 3.2 | wui lane: a calendar paragraph in `privacy.html` |
| 4.2 | cnf lane: `gcal.scopes` (section 1.2), re-render, 030 apply with the owner's go |
| S1 / S5 cnf | landed with SPL-3331: `calendar-json.googleapis.com` in the 001 list, `gcal.workspaces: ["all"]`, `SPOOL_HUB_GCAL_*` in the 030 tfvars; the 001 and 030 applies wait on the owner's go |
