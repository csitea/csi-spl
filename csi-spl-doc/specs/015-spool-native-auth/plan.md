# Implementation Plan: Spool native sign-in (015)

**Spec**: `./spec.md` · **Contract**: `./contracts/native-auth-v1.md` · **Tasks**: `./tasks.md`

## 1. Shape

```
WUI form ─POST /api/v1/auth/{register,login,…}─▶ hub internal/auth Native
                                                   │ argon2id (password.go)
                                                   │ CredStore ──▶ Postgres 0009 password_credentials
                                                   │               + email_verification_tokens + password_reset_tokens (sha256 only)
                                                   │ Mailer ─────▶ internal/mail  smtp (STARTTLS) | log | none
                                                   └ login ok ──▶ Registrar (HUMANS) → HUM-* → spool_session (010 cookie)
view door: SessionForTenant → Membership (HUMANS), unchanged
```

One new module import: `golang.org/x/crypto/argon2` (x/crypto is already in
`go.sum` as an indirect dependency; it is promoted to direct).

| File | Role |
|---|---|
| `internal/auth/password.go` | `HashPassword` / `VerifyPassword` (argon2id PHC), donor `password.go` |
| `internal/auth/native_config.go` | `SPOOL_HUB_AUTH_NATIVE_*` → `NativeConfig`, fail-fast |
| `internal/auth/native_store.go` | `CredStore` interface + in-memory implementation (tests, lde `memory:`) |
| `internal/auth/native_store_postgres.go` | `CredStore` on pgx against rdb `0009` |
| `internal/auth/native.go` | the seven routes, enumeration-safe answers, Registrar hand-off |
| `internal/auth/ratelimit.go` | in-process sliding-window limiter (per IP / per email) |
| `internal/auth/handler.go` | +`native` field, `Register` mounts it, `providers` reports it (3 small hunks) |
| `internal/mail/` | `Sender` (SMTP with required STARTTLS, `Log`, `Recorder`, `None`), config, two text templates |
| `csi-spl-rdb/.../0009_native_credentials.sql` | the three tables |

## 2. Lanes (who changes what)

| Change | Lane |
|---|---|
| everything above | NATIVE-AUTH (CLE-3352) |
| `Registrar` / `Membership` store + `cmd/spool/hub.go` wiring of both | HUMANS (CLE-3351) |
| the call `ah.EnableNative(...)` in `cmd/spool/hub.go` | NATIVE after HUMANS' wiring, or HUMANS (T012 below) |
| cnf `env.auth.native` + `env.mail`, Secret Manager slot `spool-hub-mail-smtp-password`, render into Cloud Run 030 | DEPLOY / IDP (secret slots); asked in the final report |
| WUI login / register / verify / reset pages | spawned after this contract lands |

## 3. Decisions taken here

- The credential is keyed `(provider='password', subject=lower(email))`, the key
  HUMANS fixed in 0006. No FK to `human_identities` (spec FR-007).
- Tokens: `sha256(hex)` in the DB, as in the donor; `UNIQUE(token_hash)`.
- The account-level mail floor (60 s, 5/24 h) is counted in the database, so it
  holds across Cloud Run instances. The IP/email limiter is per instance, which
  is the donor's split (spec 100 T023/T024).
- Login on an unknown email hashes a fixed dummy password with the configured
  params, so its latency matches a wrong password.
