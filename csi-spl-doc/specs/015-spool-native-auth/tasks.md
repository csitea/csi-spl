# Tasks: Spool native sign-in (015)

Status words: `../README.md` §2.3. Each ticked task cites the sha and a check command.
Paths below are relative to `csi-spl-api/src/go/spool-hub-api/` unless they start with `csi-spl-`.
Check commands run from that module dir with `PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod GOPROXY=off`.

## Phase 1 — spec

- [x] T001 Implemented (`fe92ec5`, amended in the tasks-tick commit) — spec, plan, `contracts/native-auth-v1.md`, tasks. OQ-N1..N6 with recommended defaults. Check: `ls csi-spl-doc/specs/015-spool-native-auth/contracts/` → `native-auth-v1.md`.

## Phase 2 — core

- [x] T002 Implemented (`2521ff1`) — `internal/auth/password.go`: argon2id PHC hash/verify ported from the donor; params travel in the hash. FR-001. Check: `command grep -rn argon2 internal/auth/ | wc -l` → non-zero; `go test -run 'TestPassword' ./internal/auth/` → ok.
- [x] T003 Implemented (`3ed4b64`) — `internal/auth/native_config.go`: `SPOOL_HUB_AUTH_NATIVE_*`, off by default; debug tokens refused outside lde/dev, verify-off refused outside lde, argon2 below m=19456,t=2 refused in dev/prd; `EnableNative` refuses a missing session key. FR-004, FR-011, FR-013. Check: `go test -run TestNativeConfigFailFast ./internal/auth/` → ok.
- [x] T004 Implemented (`3ed4b64`) — `csi-spl-rdb/src/sql/postgres/spool-hub/0009_native_credentials.sql`: `password_credentials` (PK provider+subject, no FK to `human_identities`, FR-007), `email_verification_tokens` (carries the minting call's password hash, FR-015), `password_reset_tokens`; sha256-only, single-use, expiring. FR-002. Check: `spool migrate` on 0001..0009 → `applied 0009_native_credentials.sql` (docker postgres:16-alpine, n=1).
- [x] T005 Implemented (`3ed4b64`) — `CredStore`: `MemoryCredStore` + `PgCredStore`, one contract suite on both. FR-002, FR-006a, FR-015. Check: `SPOOL_TEST_PG_DSN=<migrated db> go test -v -run TestCredStoreContract ./internal/auth/` → `PASS …/memory`, `PASS …/postgres`.
- [x] T006 Implemented (`3ed4b64`) — `internal/auth/ratelimit.go`: per-IP / per-email sliding window, `429` + `Retry-After` before any lookup; `clientIP` with trusted-proxy hops. FR-006b. Check: `go test -run 'TestNativeLoginRateLimited|TestClientIPHops' ./internal/auth/` → ok.
- [x] T007 Implemented (`3ed4b64`) — `internal/auth/native.go`: register, email/verify, login, password/forgot, password/reset, password/change; enumeration-safe; Registrar only for a verified credential; session = the 010 cookie with `p=password`. FR-003..FR-009, FR-012, FR-014, FR-015. Check: `go test -run TestNative ./internal/auth/` → ok (18 tests).
- [x] T008 Implemented (`2521ff1`) — `internal/mail`: `SMTP` requiring STARTTLS before AUTH and never sending credentials in cleartext to a non-loopback host (the donor's recorded bug), `Log` (template + recipient digest, never the link), `None`, `Recorder`; `SPOOL_HUB_MAIL_*` with no default host; two text templates. FR-010. Check: `go test ./internal/mail/` → ok (`TestSMTPStartTLSBeforeAuth`, `TestSMTPRefusesAuthWithoutTLS`, `TestMailConfigFailFast`, `TestLogSinkNeverLogsTheLink`).
- [x] T009 Implemented (`3ed4b64`) — controls of spec §4 green. Check: `go test -race -count=1 ./internal/auth/` → ok.
- [x] T010 Implemented (`3ed4b64`) — `internal/auth/handler.go` seam: `native` field, `Register` mounts the routes when enabled, `/providers` adds `"native":true` only when on (the 010 body is unchanged when off). Check: `go test -run 'TestNativeOffNotMounted|TestAuthOffServesEmptyList' ./internal/auth/` → ok.
- [x] T011 Implemented (`3ed4b64`) — `csi-spl-api/src/bash/tests/hub-pg.tst.sh` runs `./internal/auth/` against the migrated Postgres. Check: `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` → `ok   - internal/store + internal/hub + internal/auth (015 CredStore) suites green against Postgres`.

## Phase 3 — wiring and environments

- [x] T012 Implemented (`e0f7e7e`) — `cmd/spool/hub.go`: `auth.LoadNative` + `EnableNative` with `PgCredStore` (memory store for `memory:`) and the `SPOOL_HUB_MAIL_*` sender, after HUMANS' `AuthHooks` wiring (`a74640b`); the session-door guard accepts native. Check (real binary, lde, `memory:`, native + debug tokens + mail `log`): register → `202` + debug_token, verify → `204`, login → `200` with `hum:"HUM-1"`, wrong password → `401 invalid_credentials`; the token appears 0 times in the hub log (n=1).
- [ ] T013 Planned — cnf `env.auth.native` + `env.mail` names; Secret Manager slot `spool-hub-mail-smtp-password`; render into Cloud Run 030. Owner: DEPLOY (cnf, 030 render) / IDP (secret slots); asked in the lane report.
- [ ] T014 Planned — dev: native ON with `SPOOL_HUB_MAIL_TRANSPORT=log` + debug tokens (or a real relay once T013 lands); measure the `X-Forwarded-For` shape and set `SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS` (OQ-N6); live register → verify → login on the dev hub. Blocked on T013.
- [ ] T015 Planned — prd: stays OFF (OQ-N1 (a)); needs the owner's go and a mail relay secret version (OQ-N5). prd cannot send mail today.
