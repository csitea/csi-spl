# Tasks: Spool WUI + hub i18n (021)

**Feature**: `specs/021-spool-wui-i18n` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — WUI mechanism (donor copy)

- [x] T001 Spec (`spec.md` §2 donor measurement with file:line).
- [x] T002 (`2e2c601`) `nuxt.config.ts`: 19 locales, `prefix_except_default`, lazy, detection off, cnf default, root redirect script, per-locale prerender of `/` + `/login`. Check: `nuxi generate` → "Prerendered 78 routes".
- [x] T003 `rootLocaleRedirect.mjs`, `locale-cookie.client.ts`, `localeSearch.ts`, `LanguageSwitcher.vue`, `LocaleCombobox.vue` copied; `app.vue` lang/dir/hreflang. Check: `node tests/unit/root-locale-redirect.test.mjs`, `language-switcher.test.mjs`.
- [x] T004 Switcher in the app corner (before CLE-3402's user menu) and the sign-in frame corner; corner uses logical properties.
- [x] T005 `LanguageSetting.vue` in `/settings` (CLE-3402's section), `preferred-locale.client.ts`, auth client `savePreferences`. Check: `locale-combobox.test.mjs`.
- [~] T005a `X-Locale` on auth calls: shipped in `2e2c601`, it broke EVERY cross-origin auth preflight (hub CORS allow-list lacks it; reported by CLE-3402) — sign-in down on dev + prd until `ecd9ad9` (opt-in `sendLocale`, off; unit test pins no header by default). Check (n=2 per env, headless Chrome `/login?tenant=t1`): CORS console errors 0, idp buttons 1. Re-enable after T023 puts the hub's `X-Locale` CORS on dev + prd.
- [x] T006 cnf `env.i18n` + `30_wui-build-deploy.yml` `NUXT_PUBLIC_DEFAULT_LOCALE` / `NUXT_PUBLIC_SITE_URL`.
- [x] T007 Donor i18n tools (`src/python/i18n`) + `add_keys.py`.

## Phase 2 — Every string, every locale

- [x] T010 (`c1130ef`) Externalise every WUI string (pages, components, utils copy), locale-aware links/dates/prices. Check: unit 28/28, `i18n-parity` (HTML / `@` / plural-form guards + CONTROL), generate 78 routes.
- [x] T011 (`24d3ce6`) Translate the 245 new keys into 18 locales: donor practice, LLM translator batches of 4-5 languages with `TRANSLATOR-BRIEF.template.txt` — machine drafts pending native review. CLE-3404's 2 `checkout.host.*` keys follow in the next commit. Check: `i18n-parity.test.mjs` all pass; per locale 7-21 values stay equal to en (brand, `#general`, `{name}`-only values).

## Phase 3 — Hub

- [x] T020 (`e586002`) Migration `0017_human_preferred_locale.sql` (`humans` + `password_credentials`). Check: `hub-pg.tst.sh` applies every file incl. 0017 (renumbered from 0015 at push: trunk took 0015/0016).
- [x] T021 (`e586002`) `internal/i18n`, `X-Locale` in the CORS allow-lists, `PUT /api/v1/auth/preferences`, session `preferred_locale`, `SPOOL_HUB_DEFAULT_LOCALE` (cnf `env.i18n.default_locale`). Check: `go test ./...` ok.
- [~] T022 (`e586002`) Mails (verify, reset, M2 claim) per locale, 19 locales, link prefix; English wording pinned. Gap: the M2 claim mail goes out in the default locale (the buyer's locale is not stored on the checkout; needs a column).
- [ ] T023 Hub deploy via CLE-3355: `do_spl_db_bootstrap` (0017) on dev then prd, THEN a `hub.image.tag` bump containing `e586002` (asked 2026-09-19, CLE-3355 inbox). Then re-enable WUI `sendLocale`.

## Phase 4 — Proof

- [~] T030 Headless-Chrome switch proof on dev (`tests/e2e/locale-switch.proof.mjs`: 43/43 PASS on `2e2c601`, anonymous): 3 locales incl. `he` → `/var/tmp/CLE-3403-proof/`.
- [ ] T031 no-x-scroll at every locale.
- [ ] T032 dev + prd `build.json` == the sha; switch on https://dev.spool-hub.ai and https://spool-hub.ai.
