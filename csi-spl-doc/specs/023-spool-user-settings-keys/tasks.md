# Tasks: user settings + Keys (023)

**Feature**: `specs/023-spool-user-settings-keys` · **Created**: 2026-09-19 · **Lane**: CLE-3408

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — Spec

- [x] T001 (FR-001..FR-010) `spec.md` (decisions 3.1-3.4, OQ-1/OQ-2) + `contracts/keys-v1.md`.

## Phase 2 — Hub

- [x] T010 (FR-004, FR-006, FR-008) rdb `0018_human_keys.sql` (0017 is held by CLE-3403's `human_preferred_locale`): hub-wide like `humans` (no tenant_id, outside RLS), one active key per human (partial unique index), `public_key` globally unique, history kept.
- [x] T011 (FR-004, FR-005) `store.HumanKeys` (Memory + Postgres): add (replaces the active key in one transaction), list, get, revoke.
- [x] T012 (FR-004..FR-008) `internal/hub/keys.go` + `internal/sign/pubkey.go` (fingerprint pinned to `ssh-keygen -lf` output): keys-v1 routes, Ed25519 validation (pin base64 + `ssh-ed25519`), private-key refusal, per-human write window, audit lines. Check: `go test ./internal/hub -run Keys` with CONTROLS (another human's key 404 on get and revoke; malformed, private-key and `private_key`-field uploads refused; duplicate across humans 409; anonymous 401); mutation-checked: dropping the human filter on get and dropping DisallowUnknownFields each fail a test. `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` → ALL HUB POSTGRES CHECKS PASSED (store/hub/auth under a non-superuser Postgres, 0018 applied).
- [x] T013 (FR-007) Hub deploy: 0018 applied on dev + prd by CLE-3411's `do_spl_db_bootstrap` (16:34Z); CLE-3355 rolled hub 0.1.10 (`c8dadef`, contains `c4b61d8`) to dev + prd: `curl https://dev.api.spool-hub.ai/version` and `https://api.spool-hub.ai/version` -> 0.1.10 `c8dadef`; anonymous `GET /api/v1/auth/keys` on dev -> 401.

## Phase 3 — WUI

- [x] T020 (FR-001) `/settings` parent layout (left nav, right `<NuxtPage/>`), sections as child routes, `/settings` → `/settings/profile`; content moved out of the old page, not copied.
- [x] T021 (FR-002, FR-003, FR-010) `utils/human-keys.mjs` (browser keygen via WebCrypto, spool + OpenSSH encodings, fingerprint, keys-v1 client) + `KeysSetting.vue`. Check: `node tests/unit/human-keys.test.mjs` (encodings cross-checked against Node's Ed25519; fingerprints pinned to `ssh-keygen -lf`); `nuxi typecheck` clean; `tests/e2e/no-x-scroll.test.mjs` 52/52 incl. `/settings/keys` at 390 + 1280; live proof script `tests/e2e/settings-keys-live.proof.mjs`.
- [x] T022 (FR-009) i18n keys in all 19 locales (`add_keys.py`, 39 keys; `i18n-parity` green). Translations closed by T032 (021 T011 / T040).

## Phase 4 — Proof

- [x] T030 (FR-001..FR-007) Headless-Chrome proof on dev → `/var/tmp/CLE-3408-proof/` (2026-09-19 ~16:52Z, WUI build `a820b68` ⊇ `2e7170b`, hub 0.1.10, n=1, member HUM-4): `node tests/e2e/settings-keys-live.proof.mjs` -> 12/12 PASS: user menu → /settings/profile with the 5-section nav, Keys generated the default pair in the browser, `.pub` (pin form), `.openssh.pub` and `.key` downloaded (64 bytes, seed‖pub, signs for the .pub; private file deleted after the check), no POST body carried the private key, an uploaded ssh-ed25519 key became active (fingerprint = node's), history shows the replaced key, CONTROL pasted private key refused and not posted, mobile x-scroll 0, deep link works.
- [x] T031 (FR-010) `tests/e2e/no-x-scroll.test.mjs` 52/52 (lde mock, incl. /settings/keys); `BASE_URL=https://dev.spool-hub.ai node tests/e2e/csp-violations.test.mjs` -> 0 violations on 8 routes incl. /settings/keys, control blocked; `build.json` on dev.spool-hub.ai and spool-hub.ai -> `2e7170b` after run 35455674920 (deploy dev + prd success).
- [x] T032 (FR-009) Implemented (GRK-3380, 2026-09-21) — all 19 locales carried all 58 `settings` leaves (71 on trunk `28442ef6`, every locale 71, el 1/71 identical); identical-to-English is 0 for es/ru/tr/uk/he/sv/nl (and bg/et/fi/lt/lv/mk/pl/ro/sk/sr) and 1/58 for el (`settings.email` = `Email`). Check: python walk of `csi-spl-wui/i18n/locales/*.json` settings leaves (n=1). 021 T011 / T040.

## Phase 5 — Font size (CLE-3495, 3.5)

- [x] T040 (FR-011) `utils/font-size.mjs` + `composables/useFontSize.ts` + `plugins/font-size.client.ts` + `components/FontSizeSetting.vue` on `/settings/appearance`; `--font-root` in `assets/css/base.css`; 67 `font-size: Npx` converted to rem. Check: `node --test tests/unit/font-size.test.mjs` (clamp at 1 and 5, ± steps, default, persistence, CSS contract, px audit); `nuxi typecheck` exit 0 (a planted TS2322 in `FontSizeSetting.vue` -> exit 2, reverted).
- [x] T041 (FR-011) i18n: `settings.font_size.*` (5 keys) in all 19 locales; `i18n-parity` green.
- [x] T042 (FR-011) Live proof `tests/e2e/font-size-live.proof.mjs` on dev and prd (2026-09-25 ~12:25Z, WUI build `9b66287` ⊇ `7f08678`, n=1 per env; dev t1 member, prd tenant `e2e`): 22/22 PASS each — fresh browser opens at level 3 (body 18px, was 16px), radios 1..5 give body 14/16/18/20/22 px, − and + move one level and are disabled at 1 and 5, level 2 survives a reload and holds on /lobby.
- [ ] T043 (FR-011) Convert the px font sizes left in other lanes' files (`MessageBody.vue` 1, `ChannelSidebar.vue` 7, `ChannelPropertiesDialog.vue` 2) once those lanes land; drop them from the allow-list in `font-size.test.mjs`.

## Phase 6 — Behaviour → Text fields (SPL-976, 3.7)

- [x] T044 (FR-012, FR-014) Hub: rdb 0062 `humans.submit_key`, `PUT preferences submit_key`, session + login answer, `do_spl_human_behaviour`; hub 0.9.3 `af883284`; 0062 applied on dev and prd with `do_spl_db_bootstrap`.
- [x] T045 (FR-012, FR-013) WUI: `utils/submit-key.mjs`, `composables/useSubmitKey.ts`, `/settings/behaviour` + `SubmitKeySetting.vue`, fields wired, placeholders per mode, 19 locales.
- [x] T050 (FR-012, FR-013) Live proof `tests/e2e/submit-key-live.proof.mjs` on dev (t1 test member) and prd (tenant `e2e`), WUI `82ae1017` + hub 0.9.3 `af883284`, n=1 per env, 2026-09-26 ~19:23Z: 11/11 PASS each - both modes stored and survive a reload, placeholders follow the mode, each mode's CONTROL key adds a line and sends nothing, its send key sends; the account restored to never-picked (PUT 200).

<!-- version: 1.2.0 · updated: 2026-09-26 · last-edit: 2026-09-26T19:30:00Z -->
