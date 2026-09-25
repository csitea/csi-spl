# Feature Specification: Spool native sign-in (email + password)

**Feature ID**: `015-spool-native-auth` · **Milestone**: M3 (WUI login) · **Status**: Partial
**Created**: 2026-09-19 · **Lane**: CLE-3352 (NATIVE-AUTH) · **Owner ask**: 2026-09-19, "native auth beside social, csi-rel has it"
**Donor**: csi-rel `csi-rel-api/src/internal/auth/` (`password.go`, `password_reset.go`,
`email_verification.go`, `handlers.go`) and `src/internal/mail/mail.go`, tree `e4612828`;
specs csi-rel `018-iam-authentication`, `052-social-authentication-google-facebook`.
**Siblings**: 010 social sign-in (same session, same `Registrar`), 004 identity (`HUM-*`),
HUMANS lane (rdb `0006`, store `Registrar` / `Membership`, the view door).

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

---

## 0. Shape in one paragraph

A person registers with an email and a password. The hub stores an argon2id
hash of the password in `password_credentials` (rdb `0009`) and mails a
single-use confirmation link. After confirming, the person signs in with the
password. A good password produces the **same** `Identity` a social callback
produces — `{Provider:"password", Subject:<lower-cased email>, Email}` — and goes
through the **same** `Registrar` HUMANS implements (010 T012). The Registrar
decides admission (first human = tenant owner, later ones need an invite:
HUMANS' OQ-A3 policy); this spec invents no second policy. The session is the
existing stateless `spool_session` cookie (010 `auth-v1.md` §3), with `p="password"`.

## 1. Deliberate differences from the donor

| csi-rel | here | why |
|---|---|---|
| Fiber, JWT + revocation list, `users` table with `password_hash`, roles, locales, orders | `net/http` on the hub mux, the 010 HMAC session cookie, a separate `password_credentials` table; no roles, no locale, no business columns | spl humans are `HUM-*` with tenant membership (004, HUMANS). A credential is not a human: admission happens at the Registrar on first login. |
| `/register` answers `409 email_taken` | always `202 {"status":"verification_required"}` | enumeration-safe (FR-005). The donor leaks account existence there. |
| `method_policy.go` (staff Google-first, per-user method list) | not ported | spl has no staff role. Which methods a deployment offers is `SPOOL_HUB_AUTH_NATIVE_ENABLED` + the 010 provider list. |
| `debug_token` in the body in `lde` | in `lde` and `dev` only, behind `SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS`; **refused in prd** at boot | dev had no mail relay when this was written (FR-011); dev and prd now mail through the relay (`SPOOL_HUB_MAIL_TRANSPORT: smtp`, OQ-N5). |
| Reset TTL 24 h | 1 h (cnf) | a reset link is a bearer credential; 1 h is the OWASP default. |
| JWT revoked on password change | cookie cleared on the changing browser; other sessions live until their TTL | the session is stateless (OQ-N2). |
| argon2 params `0` → code default | env defaults `m=19456 KiB, t=2, p=1` (OWASP 2023 minimum); dev/prd refuse anything lower | Cloud Run memory; params from config (owner brief). |

## 2. User stories

### US1 — Register (P1)
**Given** the login page, **when** a person submits email + password
(≥ `SPOOL_HUB_AUTH_NATIVE_PASSWORD_MIN_LEN`, default 12), **then** the hub
answers `202` and mails a confirmation link to `<APP_URL>[/<locale>]/verify-email?token=…`.
The same `202` comes back whether or not the address already has a credential.

### US2 — Confirm email (P1)
**Given** the link, **when** the WUI posts the token, **then** the credential
becomes verified (`204`) with the password sent in the `register` call that
minted the link. A second click is `204` too; an unknown, consumed or
superseded token is `401 verification_token_invalid`; an expired one
`410 verification_token_expired`. A new link is requested by posting
`register` again (there is no separate resend route, FR-015).

### US3 — Sign in (P1)
**Given** a verified credential, **when** the person posts the right password,
**then** the Registrar returns a `HUM-*`, the hub sets `spool_session` and
answers `200` with the session claims. A wrong password, an unknown email and
a credential without a password all answer the **same** `401 invalid_credentials`.
A right password on an unverified credential answers `403 email_unverified`
(checked after the password, so it enumerates nothing). A Registrar refusal is
`403 not_allowed`.

### US4 — Forgot / reset password (P1)
`POST …/password/forgot` always answers `204`. When the address has a
credential and the per-account floor allows it, a link to
`<APP_URL>[/<locale>]/reset-password?token=…` is mailed. `POST …/password/reset` with a
live token sets the new hash, consumes **every** live reset token of that
credential, marks the email verified (the link proved the inbox), and answers
`204`. A reused, expired or unknown token is `401 reset_token_invalid`.

### US5 — Change password (P2)
A person signed in with `p="password"` posts current + new password. Wrong
current → `401 invalid_credentials`. Success → `204` and the cookie is cleared
(sign in again).

### US6 — Sign out (P1)
Already built: `POST /api/v1/auth/logout` (010).

## 3. Functional requirements

- **FR-001** Passwords are hashed with argon2id, PHC string
  `$argon2id$v=19$m=<KiB>,t=<iter>,p=1$<salt-b64>$<hash-b64>`, 16-byte salt, 32-byte key,
  constant-time compare. Params from `SPOOL_HUB_AUTH_NATIVE_ARGON2_MEMORY_KIB` /
  `_ITERATIONS`; a stored hash verifies with the params it carries, so raising them never locks anyone out.
- **FR-002** Verification and reset tokens are 32 random bytes (hex), stored as
  **sha256 only**, single-use (`consumed_at`), expiring (`expires_at`). The
  plaintext exists only in the mail (and in the `lde`/`dev` debug body, FR-011).
- **FR-003** Email is trimmed and lower-cased before every lookup; one credential per address.
- **FR-004** While `SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED` (default `true`) a
  credential cannot sign in until verified. The flag may be `false` only in
  `lde` (boot refuses it in dev/prd). Independently of the flag, the
  `Registrar` is called **only for a verified credential**: it treats
  `Identity.Email` as verified and matches invites on it (HUMANS, 2026-09-19),
  so an unverified login (lde, flag off) gets a session with no `hum` claim,
  which the view door refuses.
- **FR-005** Enumeration safety: `register` and `forgot` always answer
  the same status whatever the address; `login` answers one `401` for unknown
  email, no password and wrong password, and burns one argon2 hash on the
  unknown-email path so timing does not tell them apart.
- **FR-006** Rate limits, two layers (donor spec 100 T023/T024):
  (a) **per account, in the database**: at most one verification or reset mail
  per 60 s and 5 per 24 h per credential — refusals are the same `204`;
  (b) **per client IP and per email, in process**, decided **before** any lookup,
  answering `429 rate_limited` with `Retry-After`: login 10/15 min per email and
  30/15 min per IP; register/forgot/reset/verify 10/15 min per IP. The client
  IP is the `SPOOL_HUB_TRUSTED_PROXY_HOPS`-th `X-Forwarded-For` entry from
  the right (0 = TCP peer; OQ-N6). One value for every per-IP limit (017
  FR-SEC-006); the native-only `SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` is
  retired and the hub refuses to boot when it disagrees (`cmd/spool/hub.go`).
- **FR-007** Admission is the Registrar's (HUMANS, OQ-A3): the login hands it
  `Identity{Provider:"password", Subject:<lower-cased email>, Email}` plus the optional
  `tenant` from the body (HUMANS' key for a native account, rdb `0006` header,
  trunk `cf06dd5`). No native-only admission rule exists. The credential row is
  keyed `(provider, subject)` like `human_identities` but carries **no FK** to
  it: the identity row is created by the Registrar on the first admitted login,
  after the credential already exists (register → verify → login).
- **FR-008** The view door is unchanged: a native session reads a tenant only
  when `Membership` says yes (010 T013, `SessionForTenant`).
- **FR-009** Mutating routes require `Content-Type: application/json` (a
  cross-site form post cannot send it without a CORS preflight the hub does not grant).
- **FR-010** Mail goes through `internal/mail`: `SPOOL_HUB_MAIL_TRANSPORT` =
  `smtp` | `log` | `none` (default `none`). `smtp` requires host, port, from and
  (for a relay) user + password — **no default host in code**; the password is
  a Secret Manager slot. STARTTLS is **required** before AUTH on a non-loopback
  host (the donor's known bug). `log` records recipient-hash + template only, never the link.
- **FR-011** `SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=true` returns the plaintext
  token in the `register` / `forgot` body. Allowed in `lde` and
  `dev`; the hub **refuses to boot** with it in `prd`.
- **FR-012** Fail closed: with verification required and no way to deliver
  the link (transport `none`, and no debug tokens) `register` answers
  `503 email_delivery_unavailable` instead of creating an unusable credential.
- **FR-013** Native sign-in is **off** unless `SPOOL_HUB_AUTH_NATIVE_ENABLED=true`;
  off → the native routes are not mounted (404). ON in dev and prd
  (`SPOOL_HUB_AUTH_NATIVE_ENABLED: "true"`; prd `097e228`, T015; OQ-N1).
- **FR-014** No password, hash, token or full email in any log line; emails are
  logged as the 010 `digest()`.
- **FR-015** Pre-account takeover is closed (found while porting; the donor
  has it). Someone may register another person's address first. So: (a) a
  verification token stores the argon2id hash of the password of the
  `register` call that minted it, and consuming it installs that hash;
  (b) issuing a verification token retires every older live one, so only the
  newest link verifies; (c) there is no password-less resend. A squatter's
  password therefore never becomes active on an address whose owner
  registered after them. Residual: if the squatter registers again **after**
  the owner, the newest link (in the owner's inbox) carries the squatter's
  password; clicking it and failing to sign in leads the owner to `forgot`,
  whose reset replaces the password. Control: `TestNativePreAccountTakeover`.

## 4. Controls (tests that must refuse)

| control | test |
|---|---|
| wrong password refused, same 401 as unknown email | `TestNativeLoginWrongPasswordAndUnknownEmailSame401` |
| reused reset token refused | `TestNativeResetTokenSingleUse` |
| expired reset token refused | `TestNativeResetTokenExpired` |
| unverified email cannot log in | `TestNativeLoginUnverifiedRefused` |
| non-member refused by the view door | `TestNativeSessionNonMemberRefusedByDoor` |
| Registrar refusal = no session | `TestNativeLoginRegistrarRefuses` |
| unverified email never reaches the Registrar (invite claim) | `TestNativeUnverifiedNeverReachesRegistrar` |
| enumeration-safe register/forgot | `TestNativeRegisterEnumerationSafe`, `TestNativeForgotEnumerationSafe` |
| pre-account takeover (FR-015) | `TestNativePreAccountTakeover` |
| CredStore semantics on memory **and Postgres** | `TestCredStoreContract/{memory,postgres}` (postgres in `hub-pg.tst.sh`) |
| rate limits (both layers) | `TestNativeLoginRateLimited`, `TestNativeForgotAccountFloor` |
| debug tokens refused in prd | `TestNativeConfigFailFast` |
| no STARTTLS → no credentials sent | `TestSMTPRefusesAuthWithoutTLS` |

## 5. Open questions (owner)

- **OQ-N1 — native sign-in on prd. Answered (b): prd ON** (`097e228`, owner
  go, T015). Was: (a) ON in dev now, OFF in prd until a mail relay secret
  exists on prd and the owner says go; (b) ON in both at once.
- **OQ-N2 — sessions after a password change/reset.** (a) **recommended**:
  accept the stateless-session limit — other browsers keep their session until
  `SPOOL_HUB_AUTH_SESSION_TTL` (12 h); (b) add a per-credential `session_epoch`
  that the door checks (a store read per request). Implemented: (a).
- **OQ-N3 — admission at register time.** (a) **recommended**: anyone may hold
  a credential; admission to a tenant is decided at login by the Registrar (one
  policy, HUMANS OQ-A3); (b) require an invite token at `register`. Implemented: (a).
- **OQ-N4 — a social-only human adding a password.** (a) **recommended**: the
  person registers a password credential normally; because 0006 never links a
  new identity to an existing human by email alone (OQ-A3), it becomes a
  separate `HUM-*` unless an invite admits it; (b) a dedicated "add password"
  route behind a signed-in social session that links the identity to the same
  human. **(a) superseded by CLE-3451** (`5ebca8fb`, `internal/store/humans.go`
  `Admit`): a new identity joins the existing human when BOTH addresses are
  provider-verified, so a verified password credential on a verified social
  address is the same `HUM-*`; no (b) route was built.
- **OQ-N5 — prd mail relay. Answered (a): the relay**, per-env Secret
  Manager slot `csi-spl-hub-mail-smtp-password`; `SPOOL_HUB_MAIL_TRANSPORT:
  smtp` in dev and prd (prd `097e228`, T015; dev 010 T065). csi-rel relays
  through Google Workspace SMTP with an app password; (b) was a
  transactional provider.
- **OQ-N6 — client IP behind Cloud Run.** The per-IP limiter needs the real
  client address; behind Cloud Run (and a Hosting rewrite) the TCP peer is
  Google's front end, which would put every caller in one bucket.
  (a) **recommended**: measure the `X-Forwarded-For` shape
  (`do_spl_probe_client_ip`) and set `SPOOL_HUB_TRUSTED_PROXY_HOPS` (017
  FR-SEC-006; the native-only key is retired) per env in cnf;
  (b) drop the per-IP layer and keep only per-email + the DB floor.
  Partial: the knob, `SPOOL_HUB_TRUSTED_PROXY_HOPS: "0"` in `all.env.yaml`;
  missing: the measured per-env value.

<!-- version: 0.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T19:00:00Z -->
