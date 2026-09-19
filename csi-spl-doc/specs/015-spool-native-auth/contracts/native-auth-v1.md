# Contract: hub native sign-in routes `native-auth-v1` (spec 015)

Owner: 015 (CLE-3352). Consumers: the WUI login/register pages (lane spawned
after this contract lands), the hub mount (003). Sits beside 010
`../../010-spool-social-auth/contracts/auth-v1.md` under the same prefix, the same
session cookie and the same error envelope `{"error":"<token>","detail":"…"}`
(`wire.ErrorBody`). Code: `csi-spl-api/src/go/spool-hub-api/internal/auth/native*.go`.

The routes are mounted only when `SPOOL_HUB_AUTH_NATIVE_ENABLED=true`
(otherwise `404`). Discover that with `GET /api/v1/auth/providers`: when native
is on, the answer carries `"native": true` next to the social list.

## 1. Common rules

- Every `POST` needs `Content-Type: application/json`, else `415 unsupported_media_type`.
- Bodies are JSON objects; an unparsable body is `400 bad_request`.
- Emails are trimmed and lower-cased server-side.
- A body over 8 KiB is `400 bad_request`.
- `429 rate_limited` + `Retry-After: <seconds>` can come from any route **before**
  anything is looked up (per IP; per email on `login`). Render "Too many attempts —
  try again in N minutes."
- Responses carry `Cache-Control: no-store`.
- `debug_token` shows up only when the hub runs with
  `SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=true` (lde/dev only, never prd). A WUI may
  show it in a dev banner and must never depend on it.

## 2. Routes

| Method + path | Body | Answers |
|---|---|---|
| `POST /api/v1/auth/register` | `{"email","password","name"?}` | `202 {"status":"verification_required","debug_token"?}` for **every** well-formed request (new, existing, verified or not). `400 bad_request` + `detail` `email` / `password_too_short` (min in `detail`). `503 email_delivery_unavailable` when the hub cannot mail the link (spec FR-012). When verification is off (`SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED=false`) the status is `"registered"`. No session is set in either case. |
| `POST /api/v1/auth/email/verify` | `{"token"}` | `204` verified (also on a repeat click); `401 verification_token_invalid` (unknown/consumed); `410 verification_token_expired`. No session. |
| `POST /api/v1/auth/email/resend` | `{"email"}` | always `204` (`200 {"debug_token"}` when debug is on and a mail was issued). |
| `POST /api/v1/auth/login` | `{"email","password","tenant"?,"redirect"?}` | `200` + the session claims (010 §3, `p:"password"`, `sub` = the lower-cased email, `hum` when the Registrar is wired) and `Set-Cookie: spool_session`. `401 invalid_credentials` (unknown email, wrong password — identical); `403 email_unverified` (right password, email not confirmed); `403 not_allowed` (Registrar refused: not invited); `503 unavailable` (store down). |
| `POST /api/v1/auth/password/forgot` | `{"email"}` | always `204` (`200 {"debug_token"}` when debug is on and a mail was issued). |
| `POST /api/v1/auth/password/reset` | `{"token","password"}` | `204` (password set, email marked verified, all reset links for the account dead, **no session**: sign in); `400 bad_request` `password_too_short`; `401 reset_token_invalid` (unknown, used or expired — identical). |
| `POST /api/v1/auth/password/change` | `{"current_password","new_password"}` | needs a `spool_session` with `p:"password"`. `204` + cookie cleared; `401 unauthenticated` (no/other-provider session); `401 invalid_credentials` (wrong current); `400 bad_request` `password_too_short`. |
| `POST /api/v1/auth/logout` | — | 010, unchanged: `204`, cookie cleared. |

`tenant` follows 010's rule (DNS label, else dropped); the Registrar decides
admission for that tenant. `redirect` is echoed back as `"redirect"` after the
same-site guard (`/` when unsafe), so the page knows where to go next.

## 3. Links the mail carries

| template | link |
|---|---|
| `email_verification` | `<SPOOL_HUB_AUTH_APP_URL>/verify-email?token=<hex64>` |
| `password_reset` | `<SPOOL_HUB_AUTH_APP_URL>/reset-password?token=<hex64>` |

The WUI pages read `token` from the query and POST it; they must drop it from
the URL (`history.replaceState`) once posted.

## 4. Error tokens (the forms render these)

| token | copy |
|---|---|
| `invalid_credentials` | "Email or password is wrong." |
| `email_unverified` | "Confirm your email first — we can send the link again." (offer resend) |
| `not_allowed` | "This account has no access here yet — ask the owner for an invite." |
| `verification_token_invalid` | "That link is not valid any more." |
| `verification_token_expired` | "That link expired — we can send a new one." |
| `reset_token_invalid` | "That reset link is not valid any more — ask for a new one." |
| `email_delivery_unavailable` | "We cannot send email right now — try again later." |
| `rate_limited` | "Too many attempts — try again later." |
