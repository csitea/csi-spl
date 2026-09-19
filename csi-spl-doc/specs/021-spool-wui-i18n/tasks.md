# Tasks: Spool WUI + hub i18n (021)

**Feature**: `specs/021-spool-wui-i18n` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — WUI mechanism (donor copy)

- [x] T001 Spec (`spec.md` §2 donor measurement with file:line).
- [x] T002 `nuxt.config.ts`: 19 locales, `prefix_except_default`, lazy, detection off, cnf default, root redirect script, per-locale prerender of `/` + `/login`. Check: `nuxi generate` → "Prerendered 78 routes".
- [x] T003 `rootLocaleRedirect.mjs`, `locale-cookie.client.ts`, `localeSearch.ts`, `LanguageSwitcher.vue`, `LocaleCombobox.vue` copied; `app.vue` lang/dir/hreflang. Check: `node tests/unit/root-locale-redirect.test.mjs`, `language-switcher.test.mjs`.
- [x] T004 Switcher in the app corner (before CLE-3402's user menu) and the sign-in frame corner; corner uses logical properties.
- [x] T005 `LanguageSetting.vue` in `/settings` (CLE-3402's section), `preferred-locale.client.ts`, auth client `X-Locale` + `savePreferences`. Check: `locale-combobox.test.mjs`.
- [x] T006 cnf `env.i18n` + `30_wui-build-deploy.yml` `NUXT_PUBLIC_DEFAULT_LOCALE` / `NUXT_PUBLIC_SITE_URL`.
- [x] T007 Donor i18n tools (`src/python/i18n`) + `add_keys.py`.

## Phase 2 — Every string, every locale

- [ ] T010 Externalise every WUI string (pages, components, utils copy).
- [ ] T011 Translate all keys into 18 locales (translator batches). Check: `i18n-parity.test.mjs`.

## Phase 3 — Hub

- [ ] T020 Migration `0015_human_preferred_locale.sql`.
- [ ] T021 `internal/i18n`, `X-Locale` CORS, preference API, session field.
- [ ] T022 Mails (verify, reset, M2 claim) per locale, 19 locales, link prefix.
- [ ] T023 Hub deploy via CLE-3355 (tag bump + 030) after the migration is applied.

## Phase 4 — Proof

- [ ] T030 Headless-Chrome switch proof on dev: 3 locales incl. `he` → `/var/tmp/CLE-3403-proof/`.
- [ ] T031 no-x-scroll at every locale.
- [ ] T032 dev + prd `build.json` == the sha; switch on https://dev.spool-hub.ai and https://spool-hub.ai.
