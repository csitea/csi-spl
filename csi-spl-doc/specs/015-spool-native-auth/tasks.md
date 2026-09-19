# Tasks: Spool native sign-in (015)

Status words: `../README.md` §2.3. Each ticked task cites the sha and a check command.
Paths below are relative to `csi-spl-api/src/go/spool-hub-api/` unless they start with `csi-spl-`.

## Phase 1 — spec

- [ ] T001 Planned — spec, plan, `contracts/native-auth-v1.md`, tasks (this dir). OQ-N1..N5 written with recommended defaults.

## Phase 2 — core

- [ ] T002 Planned — `internal/auth/password.go`: argon2id PHC hash/verify ported from the donor. FR-001.
- [ ] T003 Planned — `internal/auth/native_config.go`: `SPOOL_HUB_AUTH_NATIVE_*`, fail-fast (debug tokens refused in prd, verify-off refused outside lde, argon2 floor in dev/prd, session key required). FR-004, FR-011, FR-013.
- [ ] T004 Planned — `csi-spl-rdb/src/sql/postgres/spool-hub/0009_native_credentials.sql`: `password_credentials` (PK provider+subject), `email_verification_tokens`, `password_reset_tokens` (sha256, single-use, expiring). FR-002, FR-007.
- [ ] T005 Planned — `CredStore`: memory + Postgres implementations, one contract suite run on both. FR-002, FR-006a.
- [ ] T006 Planned — `internal/auth/ratelimit.go`: per-IP / per-email sliding window, `429` + `Retry-After` before lookup. FR-006b.
- [ ] T007 Planned — `internal/auth/native.go`: register, email verify/resend, login, forgot, reset, change; enumeration-safe; Registrar only for verified credentials; session = 010 cookie. FR-003..FR-009, FR-012, FR-014.
- [ ] T008 Planned — `internal/mail`: `Sender` (SMTP with required STARTTLS before AUTH, `Log`, `Recorder`, `None`), `SPOOL_HUB_MAIL_*` config with no default host, verification + reset templates. FR-010.
- [ ] T009 Planned — controls (spec §4) green.
- [ ] T010 Planned — `internal/auth/handler.go` seam: `EnableNative`, `Register` mounts the native routes, `/providers` reports `"native"`.
- [ ] T011 Planned — `csi-spl-api/src/bash/tests/hub-pg.tst.sh` runs `./internal/auth/` against Postgres so the pg `CredStore` and 0009 are gated.

## Phase 3 — wiring and environments

- [ ] T012 Planned — `cmd/spool/hub.go`: `ah.EnableNative(auth.LoadNative(hc.Env), store, mail)`; after HUMANS' Registrar/Membership wiring commit (one owner per edit).
- [ ] T013 Planned — cnf `env.auth.native` + `env.mail` names; Secret Manager slot `spool-hub-mail-smtp-password`; render into Cloud Run 030. Owner: DEPLOY / IDP secret-slot lanes (asked).
- [ ] T014 Planned — dev: native ON with `SPOOL_HUB_MAIL_TRANSPORT=log` + debug tokens; live register → verify → login on the dev hub.
- [ ] T015 Planned — prd: stays OFF (OQ-N1 (a)); needs the owner's go and a mail relay secret version (OQ-N5).
