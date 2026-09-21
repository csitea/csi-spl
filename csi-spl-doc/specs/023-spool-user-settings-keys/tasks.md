# Tasks: user settings + Keys (023)

**Feature**: `specs/023-spool-user-settings-keys` · **Created**: 2026-09-19 · **Lane**: CLE-3408

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — Spec

- [x] T001 `spec.md` (decisions 3.1-3.4, OQ-1/OQ-2) + `contracts/keys-v1.md`.

## Phase 2 — Hub

- [x] T010 rdb `0018_human_keys.sql` (0017 is held by CLE-3403's `human_preferred_locale`): hub-wide like `humans` (no tenant_id, outside RLS), one active key per human (partial unique index), `public_key` globally unique, history kept.
- [x] T011 `store.HumanKeys` (Memory + Postgres): add (replaces the active key in one transaction), list, get, revoke.
- [x] T012 `internal/hub/keys.go` + `internal/sign/pubkey.go` (fingerprint pinned to `ssh-keygen -lf` output): keys-v1 routes, Ed25519 validation (pin base64 + `ssh-ed25519`), private-key refusal, per-human write window, audit lines. Check: `go test ./internal/hub -run Keys` with CONTROLS (another human's key 404 on get and revoke; malformed, private-key and `private_key`-field uploads refused; duplicate across humans 409; anonymous 401); mutation-checked: dropping the human filter on get and dropping DisallowUnknownFields each fail a test. `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` → ALL HUB POSTGRES CHECKS PASSED (store/hub/auth under a non-superuser Postgres, 0018 applied).
- [x] T013 Hub deploy: 0018 applied on dev + prd by CLE-3411's `do_spl_db_bootstrap` (16:34Z); CLE-3355 rolled hub 0.1.10 (`c8dadef`, contains `c4b61d8`) to dev + prd: `curl https://dev.api.spool-hub.ai/version` and `https://api.spool-hub.ai/version` -> 0.1.10 `c8dadef`; anonymous `GET /api/v1/auth/keys` on dev -> 401.

## Phase 3 — WUI

- [x] T020 `/settings` parent layout (left nav, right `<NuxtPage/>`), sections as child routes, `/settings` → `/settings/profile`; content moved out of the old page, not copied.
- [x] T021 `utils/human-keys.mjs` (browser keygen via WebCrypto, spool + OpenSSH encodings, fingerprint, keys-v1 client) + `KeysSetting.vue`. Check: `node tests/unit/human-keys.test.mjs` (encodings cross-checked against Node's Ed25519; fingerprints pinned to `ssh-keygen -lf`); `nuxi typecheck` clean; `tests/e2e/no-x-scroll.test.mjs` 52/52 incl. `/settings/keys` at 390 + 1280; live proof script `tests/e2e/settings-keys-live.proof.mjs`.
- [x] T022 i18n keys in all 19 locales (`add_keys.py`, 39 keys; `i18n-parity` green). Translations closed by T032 (021 T011 / T040).

## Phase 4 — Proof

- [x] T030 Headless-Chrome proof on dev → `/var/tmp/CLE-3408-proof/` (2026-09-19 ~16:52Z, WUI build `a820b68` ⊇ `2e7170b`, hub 0.1.10, n=1, member HUM-4): `node tests/e2e/settings-keys-live.proof.mjs` -> 12/12 PASS: user menu → /settings/profile with the 5-section nav, Keys generated the default pair in the browser, `.pub` (pin form), `.openssh.pub` and `.key` downloaded (64 bytes, seed‖pub, signs for the .pub; private file deleted after the check), no POST body carried the private key, an uploaded ssh-ed25519 key became active (fingerprint = node's), history shows the replaced key, CONTROL pasted private key refused and not posted, mobile x-scroll 0, deep link works.
- [x] T031 `tests/e2e/no-x-scroll.test.mjs` 52/52 (lde mock, incl. /settings/keys); `BASE_URL=https://dev.spool-hub.ai node tests/e2e/csp-violations.test.mjs` -> 0 violations on 8 routes incl. /settings/keys, control blocked; `build.json` on dev.spool-hub.ai and spool-hub.ai -> `2e7170b` after run 35455674920 (deploy dev + prd success).
- [x] T032 Implemented (GRK-3380, 2026-09-21) — all 19 locales carry all 58 `settings` leaves; identical-to-English is 0 for es/ru/tr/uk/he/sv/nl (and bg/et/fi/lt/lv/mk/pl/ro/sk/sr) and 1/58 for el (`settings.email` = `Email`). Check: python walk of `csi-spl-wui/i18n/locales/*.json` settings leaves (n=1). 021 T011 / T040.

<!-- last-edit: 2026-09-19T16:40:00Z -->
