# google-calendar-connect.ISG — install & setup guide (Google console, Calendar connect)

> **Partly verified.** Checked 2026-10-26 on the tree of SPL-3494, n=1 per
> env: `ENV=<env> ./run -a do_gcp_gcal_connect_check` (csi-spl-iac, read only)
> read the Calendar API enabled on `csi-spl-dev` and `csi-spl-prd`, the
> sign-in redirect URI registered on both, and the Calendar redirect URI
> registered on prd and NOT on dev (Google answered `redirect_uri_mismatch`).
> The console menu names are as Google showed them to the owner; the scope and
> test-user steps were not measured by any script (no API reads them).

The Google side of a member's Calendar connect ([spec 149](../../../specs/149-google-calendar-connect/spec.md)).
Every console step is the owner's; no lane does one. The texts for Google's
review form are in
[google-review-submission.md](../../../specs/149-google-calendar-connect/google-review-submission.md),
the source of truth for the steps below (its sections 4.2 and 4.3).

<a id="isg-gcal-1"></a>
## 1. What this sets up

<a id="isg-gcal-1-1"></a>
### 1.1 The steps and what automates them

| step | what | automation |
|---|---|---|
| 3 | the Calendar API on the project | scripted: terraform step 001 (cnf list), and `do_gcp_gcal_connect_check` lists it and, with `DRY_RUN=0`, enables it |
| 4 (S0) | which project holds the sign-in OAuth client | console only; the check reads the client through Google's authorize endpoint (5.3) |
| 5 (S3) | the Calendar redirect URI on the sign-in OAuth client | console only, no public API (section 9); CHECKED by `do_gcp_gcal_connect_check` |
| 6.1 (S2) | the scope `calendar.app.created` on the consent screen | console only, no public API (section 9); not checkable before a sign-in |
| 6.2 (S2) | the test users | console only, no public API (section 9) |
| 6.3 | the branding (home, privacy, terms URLs) | console only; `gcloud iap oauth-brands` is IAP-only and deprecated (section 9) |
| 7 | cnf `gcal.scopes` and the step-030 apply | another lane and the owner's go, not this guide |

<a id="isg-gcal-1-2"></a>
### 1.2 The values, and where cnf keeps them

| value | cnf (merged `all.env.yaml` under `<env>.env.yaml`) |
|---|---|
| `<app host>` | `env.dns.fqdn`, derived by `do_spl_merged_cnf`: prd `<BASE_DOMAIN>`, dev `dev.<BASE_DOMAIN>` (`env.dns.BASE_DOMAIN` + `env.dns.env_subdomain`) |
| `<client id>` | `env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID` in `<env>.env.yaml` |
| the sign-in redirect URI | `env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI`: `https://<app host>/api/v1/auth/google/callback` |
| the Calendar redirect URI | `https://<app host>/v1/me/google-calendar/callback` (the hub's `GcalCallbackPath`, `csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_connect.go`) |
| the scope | `https://www.googleapis.com/auth/calendar.app.created` |
| the project | `env.gcp.gcp_project`: `csi-spl-dev`, `csi-spl-prd` |

Never write the client id or the host into a doc or a post; the check prints
`<client id>` in its place.

<a id="isg-gcal-2"></a>
## 2. Before you start

<a id="isg-gcal-2-1"></a>
### 2.1 Run the check, dev

Read only (the default `DRY_RUN=1`): one `gcloud services list` as the env's
service account and two requests to Google's public authorize endpoint (cnf
`env.gcal.auth_url`). Returns 0 when every scripted check holds, 3 when one
does not; the `MANUAL` lines are the console steps left.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ENV=dev ./run -a do_gcp_gcal_connect_check
```

<a id="isg-gcal-2-2"></a>
### 2.2 Run the check, prd

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ENV=prd ./run -a do_gcp_gcal_connect_check
```

<a id="isg-gcal-2-3"></a>
### 2.3 Order

Dev first, then prd (repo rule: dev always equals or leads prd). Each step
below is done once per env.

<a id="isg-gcal-3"></a>
## 3. The Calendar API

<a id="isg-gcal-3-1"></a>
### 3.1 Where

Terraform step 001 enables `calendar-json.googleapis.com` from cnf
`env.steps.001-enable-gcp-services.gcp_services` (`all.env.yaml`). Its apply
is the owner's go.

<a id="isg-gcal-3-2"></a>
### 3.2 Check

The check prints `OK step 1: calendar-json.googleapis.com is enabled on csi-spl-<env>`.

<a id="isg-gcal-3-3"></a>
### 3.3 If it is off, outside terraform

Only with the owner's go for that call: the same idempotent enable as the
env's service account.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ENV=dev DRY_RUN=0 ./run -a do_gcp_gcal_connect_check
```

<a id="isg-gcal-4"></a>
## 4. S0: the project of the sign-in client

<a id="isg-gcal-4-1"></a>
### 4.1 Where to click

Google Cloud console, project `csi-spl-<env>`, APIs & Services, Credentials,
OAuth 2.0 Client IDs. The Web client whose id is `<client id>` (1.2) is the
one the Calendar connect uses: the hub asks for the Calendar scope with the
sign-in client (`ClientID` from the sign-in config,
`csi-spl-api/src/go/spool-hub-api/cmd/spool/hub_gcal.go`). On prd it is
named `spool-hub-prd` (the owner's screenshot).

<a id="isg-gcal-4-2"></a>
### 4.2 Check

If the client is not in that project, stop: the API (3) and the scope (6)
go on the project that holds it, and the 001 cnf of `csi-spl-<env>` is the
wrong place. Tell the dispatcher.

<a id="isg-gcal-5"></a>
## 5. S3: the redirect URI

<a id="isg-gcal-5-1"></a>
### 5.1 Where to click

Project `csi-spl-<env>`, APIs & Services, Credentials, the Web client of 4.1,
**Authorised redirect URIs** (NOT Authorised JavaScript origins), Add URI.

<a id="isg-gcal-5-2"></a>
### 5.2 The exact value

| env | add |
|---|---|
| dev | `https://dev.<BASE_DOMAIN>/v1/me/google-calendar/callback` |
| prd | `https://<BASE_DOMAIN>/v1/me/google-calendar/callback` |

Keep the sign-in line `https://<app host>/api/v1/auth/google/callback`: it
is how members sign in. Save. Google's console notes the change may take 5
minutes or more to apply.

<a id="isg-gcal-5-3"></a>
### 5.3 Check

Re-run 2.1 (or 2.2) after 5 minutes. Done when it prints
`OK step S3: https://<app host>/v1/me/google-calendar/callback is an authorised redirect URI of <client id>`
and still `OK the sign-in redirect URI is on <client id>`.

How it knows, without an account: Google's authorize endpoint sends a listed
URI on to its sign-in page (`/v3/signin/identifier`) and an unlisted one to
`/signin/oauth/error`, whose `authError` names `redirect_uri_mismatch`
(measured 2026-10-26, n=1 per URI per env). A member who hits the unlisted
case sees Google's "Error 400: redirect_uri_mismatch"; its "error details"
link shows the `redirect_uri` the hub sent, which is the value to add.

<a id="isg-gcal-6"></a>
## 6. S2: the consent screen

<a id="isg-gcal-6-1"></a>
### 6.1 The scope

Google Auth Platform (older console: OAuth consent screen), project of 4.1,
Data access, Add or remove scopes. Add
`https://www.googleapis.com/auth/calendar.app.created` (paste it under
"Manually add scopes" if the list does not show it; menu name unchecked), Update, Save. It shows
under the sensitive scopes.

Check: the console's Data access page lists it. No script can: Google's
authorize endpoint answers the same for a scope the consent screen lists and
for one it does not (measured 2026-10-26: a `drive` scope it does not list
passed, n=1), so the proof is a test user's connect (8.1), whose consent
screen names "Make secondary Google calendars".

<a id="isg-gcal-6-2"></a>
### 6.2 The test users

While the app is in testing: Google Auth Platform, Audience, Test users, Add
users, each tester's Google address. Save.

Check: the address is in the list. A Google account not in it gets Google's
"access blocked" page at the connect (unchecked, I believe).

<a id="isg-gcal-6-3"></a>
### 6.3 The branding

Google Auth Platform, Branding: home `https://<BASE_DOMAIN>/`, privacy
policy `https://<BASE_DOMAIN>/privacy`, terms `https://<BASE_DOMAIN>/terms`,
authorised domain `<BASE_DOMAIN>`. The check prints these URLs as a `MANUAL`
line, from cnf.

<a id="isg-gcal-6-4"></a>
### 6.4 Tell the dispatcher

When 6.1 and 6.2 are saved, tell the dispatcher: a lane then sets cnf
`gcal.scopes` (7).

<a id="isg-gcal-7"></a>
## 7. After the console: cnf and step 030

Not this guide's steps, listed so the order is clear: cnf `gcal.scopes`
becomes `openid email https://www.googleapis.com/auth/calendar.app.created`
(google-review-submission.md 1.2), re-rendered, then the step-030 apply with
the owner's go. The check prints `INFO cnf gcal.scopes is ...` before and
`OK cnf gcal.scopes asks for ...` after.

<a id="isg-gcal-8"></a>
## 8. The end-to-end check

<a id="isg-gcal-8-1"></a>
### 8.1 A test user connects

A test user (6.2) opens Settings, Calendar (Google), Connect, accepts the
consent screen, and lands back on the settings section with
`settings=calendar-google&gcal=connected` in the address (`gcalSettingsPath`,
`gcal_connect.go`). The hub logs `gcal: connected` with the tenant, member and
connection.

<a id="isg-gcal-8-2"></a>
### 8.2 What a failure looks like

| seen | means |
|---|---|
| Google "Error 400: redirect_uri_mismatch" | 5 not done for this env, or not applied yet |
| Google "access blocked" / app not verified for this user | 6.2: the account is not a test user |
| back on Settings with `gcal_error=cancelled` | the member declined the consent screen |
| back on Settings with `gcal_error=exchange_failed`; hub log `gcal: connect failed` | the code exchange failed; the log line carries the error |
| hub page `invalid_state` (400) | the connect link expired or was opened in another browser; start again |
| hub 404 `google calendar is not available in this workspace` | cnf `gcal.workspaces` does not list the workspace |

<a id="isg-gcal-9"></a>
## 9. Why these steps are console only (sources checked 2026-10-26)

<a id="isg-gcal-9-1"></a>
### 9.1 The OAuth client's redirect URIs

`gcloud iam oauth-clients create --help` (Google Cloud SDK 585.0.0) is the
only gcloud command with `--allowed-redirect-uris`, and it is for a
different client: "The following scopes are currently supported:
cloud-platform, openid, email, groups" ("a federated identity's email
address"), i.e. workforce identity federation clients, not the Web client of
Google sign-in. No gcloud command or public API lists or edits a standard
Web client's redirect URIs; a Google developer forum thread says the same
("redirect URLs are not configurable programmatically",
https://discuss.google.dev/t/oauth-consent-screen-and-oauth-client-automation-limitations/134485,
community, not Google's documentation).

<a id="isg-gcal-9-2"></a>
### 9.2 The consent screen, scopes and test users

`gcloud iap oauth-brands --help` (SDK 585.0.0): "(DEPRECATED) ... will be
non-functional after the IAP OAuth Admin APIs are turned down. Jan 19, 2026:
Google will discontinue support for the IAP OAuth Admin APIs. New projects
will not be able to use these APIs. March 19, 2026: The IAP OAuth Admin APIs
will be permanently shut down." It only ever made an internal IAP brand, with
no scopes or test users. The forum thread of 9.1: "Scopes and other
configurations like test user addition and URLs are not configurable through
Terraform or gCloud SDK."

<a id="isg-gcal-9-3"></a>
### 9.3 What the script does instead

For each console-only step `do_gcp_gcal_connect_check` prints the exact
`MANUAL` step from cnf, and checks it where Google's public endpoints let it
(5.3); it never claims a step it cannot read. Code:
`csi-spl-iac/src/bash/run/gcp-gcal-connect-check.func.sh`, test
`csi-spl-iac/src/bash/tests/gcp-gcal-connect-check.tst.sh` (gcloud and curl
stubbed).
