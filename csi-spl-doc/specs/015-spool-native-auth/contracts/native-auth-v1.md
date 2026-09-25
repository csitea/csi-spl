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
  anything is looked up (per IP; per email on `login`). The client IP is the
  `SPOOL_HUB_TRUSTED_PROXY_HOPS`-th `X-Forwarded-For` entry from the right (017
  FR-SEC-006; the native-only `SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` is
  retired, spec OQ-N6). Render "Too many attempts —
  try again in N minutes."
- Responses carry `Cache-Control: no-store`.
- **Resend = register again.** There is no separate resend route: posting
  `register` again with the same email + password mails a fresh link (subject
  to the per-account floor of 1 per 60 s, 5 per 24 h). Each link carries the
  password of the call that minted it and only the newest link verifies
  (spec FR-015), so the form must resend with the password the person typed.
- `debug_token` shows up only when the hub runs with
  `SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=true` (lde/dev only, never prd). A WUI may
  show it in a dev banner and must never depend on it.

## 2. Routes

| Method + path | Body | Answers |
|---|---|---|
| `POST /api/v1/auth/register` | `{"email","password","name"?}` | `202 {"status":"verification_required","debug_token"?}` for **every** well-formed request (new, existing, verified or not). `400 bad_request` + `detail` `email` / `password_too_short` (min in `detail`). `503 email_delivery_unavailable` when the hub cannot mail the link (spec FR-012). When verification is off (`SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED=false`) the status is `"registered"`. No session is set in either case. |
| `POST /api/v1/auth/email/verify` | `{"token","password"}` | `204` verified (also on a repeat click); `401 verification_token_invalid` (unknown, consumed, or superseded by a newer link); `410 verification_token_expired`; `401 invalid_credentials` when `password` is missing, over 1024 bytes, or not the one sent with the `register` call that minted this link - nothing is consumed then, the person may retry. The password that becomes active is that register call's. No session. Why the password (CLE-34986): the click proves the mailbox, not who chose the password - without it, anyone could register someone else's address with their own password and have the owner's click verify it, and Admit then links that sign-in to the owner's existing human. Implemented: hub `internal/auth/native.go` handleVerify + `ConsumeVerification(..., accept)`, WUI `/verify-email` password field; test `TestNativeVerifyNeedsTheRegisteredPassword`. |
| `POST /api/v1/auth/login` | `{"email","password","tenant"?,"redirect"?}` | `200` + the session claims (010 §3, `p:"password"`, `sub` = the lower-cased email, `hum` when the Registrar is wired) and `Set-Cookie: spool_session`. `401 invalid_credentials` (unknown email, wrong password — identical); `403 email_unverified` (right password, email not confirmed); `403 not_allowed` (Registrar refused: not invited); `503 unavailable` (store down). |
| `POST /api/v1/auth/password/forgot` | `{"email"}` | always `204` (`200 {"debug_token"}` when debug is on and a **reset** token was issued). See §2.1: what is mailed depends on the address, the status never does. |
| `POST /api/v1/auth/password/reset` | `{"token","password"}` | `204` (password set, email marked verified, all reset links for the account dead, **no session**: sign in); `400 bad_request` `password_too_short`; `401 reset_token_invalid` (unknown, used or expired — identical). |
| `POST /api/v1/auth/password/change` | `{"current_password","new_password"}` | needs a `spool_session` with `p:"password"`. `204` + cookie cleared; `401 unauthenticated` (no/other-provider session); `401 invalid_credentials` (wrong current); `400 bad_request` `password_too_short`. |
| `POST /api/v1/auth/logout` | — | 010, unchanged: `204`, cookie cleared. |

`tenant` follows 010's rule (DNS label, else dropped); the Registrar decides
admission for that tenant. `redirect` is echoed back as `"redirect"` after the
same-site guard (`/` when unsafe), so the page knows where to go next.

### 2.1 `password/forgot` on an address with no password (CLE-3451)

Amends FR-005 for ONE case. The status on the wire is `204` in all three rows
below; only what lands in the inbox differs, and the person who gets it is the
one who already owns that address.

| the address | mailed | logged |
|---|---|---|
| has a password credential | `password_reset` (subject to the per-account floor) | as before |
| has NO password but a **verified** identity with an IdP | `federated_signin` — names the provider(s) and the sign-in page, carries **no token** | `auth.native_forgot_federated` |
| is not known at all | nothing | nothing — no line distinguishes it from any other miss |

The third row is the one FR-005 is about and it is **unchanged**: a stranger
cannot tell a real address from an invented one, because neither the status,
the body nor the log says anything. What changed is the second row, which
before CLE-3451 was byte-identical to the third: a Google-only address got a
204, no mail and no recovery path at all, which reads as a broken site.

`federated_signin` is rate-limited to one per address per
`SPOOL_HUB_AUTH_NATIVE_RATE_WINDOW`, so an unauthenticated always-204 route
cannot be used as a mail amplifier. The refusal is silent, like the credential
floor.

The mail tells the person they may also register a password for that address.
That is safe and true since CLE-3451: a new identity whose **provider-verified**
address matches an existing human's **verified** identity joins that human
instead of minting a second one. Both sides must be verified — an unverified
address on either side never merges, because that would be an account
takeover. The WUI needs no change for this; the mail is the whole signal.

## 3. Links the mail carries

| template | link |
|---|---|
| `email_verification` | `<SPOOL_HUB_AUTH_APP_URL>[/<locale>]/verify-email?token=<hex64>` |
| `password_reset` | `<SPOOL_HUB_AUTH_APP_URL>[/<locale>]/reset-password?token=<hex64>` |
| `federated_signin` | `<SPOOL_HUB_AUTH_APP_URL>[/<locale>]/login` — no token, no tenant |

The WUI pages read `token` from the query and POST it; they must drop it from
the URL (`history.replaceState`) once posted.

## 4. Error tokens (the forms render these)

| token | copy |
|---|---|
| `invalid_credentials` | "Email or password is wrong." |
| `email_unverified` | "Confirm your email first — we can send the link again." (resend = `register` with the same email + password) |
| `not_allowed` | "This account has no access here yet — ask the owner for an invite." |
| `verification_token_invalid` | "That link is not valid any more." |
| `verification_token_expired` | "That link expired — we can send a new one." (via `register`) |
| `reset_token_invalid` | "That reset link is not valid any more — ask for a new one." |
| `email_delivery_unavailable` | "We cannot send email right now — try again later." |
| `rate_limited` | "Too many attempts — try again later." |

<!-- version: 0.1.2 · updated: 2026-09-25 · last-edit: 2026-09-25T19:40:00Z -->
