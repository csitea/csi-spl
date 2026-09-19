# Tasks: user settings + Keys (023)

**Feature**: `specs/023-spool-user-settings-keys` · **Created**: 2026-09-19 · **Lane**: CLE-3408

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — Spec

- [x] T001 `spec.md` (decisions 3.1-3.4, OQ-1/OQ-2) + `contracts/keys-v1.md`.

## Phase 2 — Hub

- [x] T010 rdb `0018_human_keys.sql` (0017 is held by CLE-3403's `human_preferred_locale`): hub-wide like `humans` (no tenant_id, outside RLS), one active key per human (partial unique index), `public_key` globally unique, history kept.
- [x] T011 `store.HumanKeys` (Memory + Postgres): add (replaces the active key in one transaction), list, get, revoke.
- [x] T012 `internal/hub/keys.go` + `internal/sign/pubkey.go` (fingerprint pinned to `ssh-keygen -lf` output): keys-v1 routes, Ed25519 validation (pin base64 + `ssh-ed25519`), private-key refusal, per-human write window, audit lines. Check: `go test ./internal/hub -run Keys` with CONTROLS (another human's key 404 on get and revoke; malformed, private-key and `private_key`-field uploads refused; duplicate across humans 409; anonymous 401); mutation-checked: dropping the human filter on get and dropping DisallowUnknownFields each fail a test. `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` → ALL HUB POSTGRES CHECKS PASSED (store/hub/auth under a non-superuser Postgres, 0018 applied).
- [ ] T013 Hub deploy via CLE-3355 (tag bump + 030 via make), migration applied first (`do_spl_db_bootstrap`).

## Phase 3 — WUI

- [ ] T020 `/settings` parent layout (left nav, right `<NuxtPage/>`), sections as child routes, `/settings` → `/settings/profile`; content moved out of the old page, not copied.
- [ ] T021 `utils/human-keys.mjs` (browser keygen via WebCrypto, spool + OpenSSH encodings, fingerprint, keys-v1 client) + `KeysSetting.vue`. Check: `node tests/unit/human-keys.test.mjs` (encodings cross-checked against Node's Ed25519).
- [ ] T022 i18n keys in all 19 locales (en placeholders; translation = 021 T011, CLE-3403).

## Phase 4 — Proof

- [ ] T030 Headless-Chrome proof on dev → `/var/tmp/CLE-3408-proof/`: open Settings → Keys, download both files, upload a new public key, see it active.
- [ ] T031 no-x-scroll + CSP e2e green; dev + prd `build.json` / `/version` carry the sha.

<!-- last-edit: 2026-09-19T16:40:00Z -->
