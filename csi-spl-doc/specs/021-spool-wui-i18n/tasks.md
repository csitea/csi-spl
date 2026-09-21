# Tasks: Spool WUI + hub i18n (021)

**Feature**: `specs/021-spool-wui-i18n` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — WUI mechanism (donor copy)

- [x] T001 Spec (`spec.md` §2 donor measurement with file:line).
- [x] T002 (`2e2c601`) `nuxt.config.ts`: 19 locales, `prefix_except_default`, lazy, detection off, cnf default, root redirect script, per-locale prerender of `/` + `/login`. Check: `nuxi generate` → "Prerendered 78 routes".
- [x] T003 `rootLocaleRedirect.mjs`, `locale-cookie.client.ts`, `localeSearch.ts`, `LanguageSwitcher.vue`, `LocaleCombobox.vue` copied; `app.vue` lang/dir/hreflang. Check: `node tests/unit/root-locale-redirect.test.mjs`, `language-switcher.test.mjs`.
- [x] T004 Switcher in the app corner (before CLE-3402's user menu) and the sign-in frame corner; corner uses logical properties.
- [x] T005 `LanguageSetting.vue` in `/settings` (CLE-3402's section), `preferred-locale.client.ts`, auth client `savePreferences`. Check: `locale-combobox.test.mjs`.
- [x] T005a `X-Locale` on auth calls (re-enabled `ad17830` after hub 0.1.10): shipped in `2e2c601`, it broke EVERY cross-origin auth preflight (hub CORS allow-list lacks it; reported by CLE-3402) — sign-in down on dev + prd until `ecd9ad9` (opt-in `sendLocale`, off; unit test pins no header by default). Check (n=2 per env, headless Chrome `/login?tenant=t1`): CORS console errors 0, idp buttons 1. Re-enabled in `ad17830` once hub 0.1.10 (`c8dadef`) answered `allow-headers: Content-Type, X-Locale` on both api hosts; re-check n=2 per env: CORS errors 0, sign-in page healthy, auth calls carry `x-locale`.
- [x] T006 cnf `env.i18n` + `30_wui-build-deploy.yml` `NUXT_PUBLIC_DEFAULT_LOCALE` / `NUXT_PUBLIC_SITE_URL`.
- [x] T007 Donor i18n tools (`src/python/i18n`) + `add_keys.py`.

## Phase 2 — Every string, every locale

- [x] T010 (`c1130ef`) Externalise every WUI string (pages, components, utils copy), locale-aware links/dates/prices. Check: unit 28/28, `i18n-parity` (HTML / `@` / plural-form guards + CONTROL), generate 78 routes.
- [x] T011 (`24d3ce6`) Translate the 245 new keys into 18 locales: donor practice, LLM translator batches of 4-5 languages with `TRANSLATOR-BRIEF.template.txt` — machine drafts pending native review. CLE-3404's 2 `checkout.host.*` keys follow in the next commit. Check: `i18n-parity.test.mjs` all pass; per locale 7-21 values stay equal to en (brand, `#general`, `{name}`-only values).

## Phase 3 — Hub

- [x] T020 (`e586002`) Migration `0017_human_preferred_locale.sql` (`humans` + `password_credentials`). Check: `hub-pg.tst.sh` applies every file incl. 0017 (renumbered from 0015 at push: trunk took 0015/0016).
- [x] T021 (`e586002`) `internal/i18n`, `X-Locale` in the CORS allow-lists, `PUT /api/v1/auth/preferences`, session `preferred_locale`, `SPOOL_HUB_DEFAULT_LOCALE` (cnf `env.i18n.default_locale`). Check: `go test ./...` ok.
- [x] T022 (`e586002`, gap closed `6f00de3` CLE-3439) Mails (verify, reset, M2 claim) per locale, 19 locales, link prefix; English wording pinned. The M2 claim-mail gap is closed: rdb `0025_checkout_buyer_locale.sql` adds `payment_checkouts.buyer_locale` (NULL = never said, CHECK over the same 19 as 0017), `POST /api/v1/checkout` takes `locale` in the BODY (never a header: a preflight a CORS allow-list could refuse would kill the whole checkout, cf. 2e2c601), precedence `locale` > `X-Locale` > `Accept-Language` > `SPOOL_HUB_DEFAULT_LOCALE` at send time, and the WUI checkout page hands `start()` its active locale. `i18n.Normalize` gates the value in AND out, so it never reaches a template path or URL raw; the store refuses anything outside `i18n.Supported`. Check: `go test ./internal/payments/ -v | grep -c '^--- PASS'` -> 18 before, 21 after (`TestClaimMailFollowsBuyerLocale` asserts fi/sv-SE/HE/en land on the fi template and the `/fi/checkout/claim` link; `TestBuyerLocaleFromHeaders` the precedence; `TestClaimMailLocaleFallsBack` that `klingon`, `..`, `../../../etc/passwd` neither store nor sell-refuse); `go test ./internal/store/ -run CheckoutKeepsBuyerLocale -v` -> memory + postgres PASS; `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` -> `spool migrate applies 25 file(s)`, ALL CHECKS PASSED; `node --test tests/unit/*.test.mjs` -> 631 -> 633 pass / 0 fail, `pnpm typecheck` exit 0.
**lde proof** (hub 0.1.17 built from `89618df`, which carries `aac5e48`; `do_setup_app_inf` applied 25/25 migrations, all 5 checks PASS), n=1 each: the real WUI at `http://localhost:3000/fi/checkout` -> row `buyer_locale = fi` -> hub log `paid: claim-link mail sent locale=fi` + `mail.log_sink template=tenant_paid locale=fi`; the same form at `/checkout` (default locale) -> row `en`; `ENV=lde DRY_RUN=0 LOCALE=fi TENANT_ID=m1locfi ./run -a do_spl_checkout_fake_buy` -> `"locale":"fi"`, mail fi; CONTROL without LOCALE (`m1locnone`) -> row NULL, mail `locale=en`. **dev proof** (live dev hub `0.1.19` = `2e4c1ce`, which carries `aac5e48`; rdb 0025 applied to dev AND prd by `ENV=<env> DRY_RUN=0 ./run -a do_spl_db_bootstrap` -> `applied 0025_checkout_buyer_locale.sql`, `information_schema` shows `buyer_locale` nullable in both), Stripe TEST card rail, n=1 each: `ENV=dev DRY_RUN=0 LOCALE=fi TENANT_ID=m1devfi ... ./run -a do_spl_checkout_stripe_test_buy` -> paid by the REAL signed webhook in 3 s, §1.3 `"locale":"fi"`, dev log `paid: claim-link mail sent locale=fi delivered=true` (`co_wtikrr35vuxvkjhea4mmcq7tpq`); CONTROL without LOCALE (`m1deven`, `co_jt5tatz5f32spptwpiwrziwq4i`) -> §1.3 `""`, mail `locale=en delivered=true`. prd carries the code and the column but was NOT bought on: its rail is `card` with a `pk_live` key, so a buy moves real money (owner-gated). `ENV=<env> SHA=b829c50 ./run -a do_check_deploy_lag` -> hub and wui **current** on dev and prd, n=0.
- [x] T023 Hub deploy via CLE-3355 (done 2026-09-19 ~16:50Z: 0017 applied dev + prd, hub 0.1.10 `c8dadef` on both, `/version` n=1 each): `do_spl_db_bootstrap` (0017) on dev then prd, THEN a `hub.image.tag` bump containing `e586002` (asked 2026-09-19, CLE-3355 inbox). Then re-enable WUI `sendLocale`.

## Phase 4 — Proof

- [x] T030 Headless-Chrome switch proof, anonymous (`tests/e2e/locale-switch.proof.mjs`, n=1 per env, 2026-09-19T16:4xZ): dev build `ad3ed01`+ and prd build `12532b7` (both contain `5bbb421`) → 43/43 PASS each: `/` with a he browser → `/he` rtl; bg `/login` → fi via typed search, query kept, cookie `i18n_redirected=fi`; cookie beats browser on `/`; fi → en in the shell with query kept. Screenshots bg/fi/he/en desktop + mobile in `/var/tmp/CLE-3403-proof/{dev,prd}/`.: 3 locales incl. `he` → `/var/tmp/CLE-3403-proof/`.
- [x] T031 no-x-scroll at every locale: the same proof, all 19 locales × `/login` + `/lobby` at 390×844, lang tag + dir asserted (in the 43/43); `no-x-scroll.test.mjs` covers the 18 prefixed locales locally.
- [x] T032 WUI: dev + prd `build.json` carry `5bbb421` (via newer builds; 30 run 35455105725's own deploy jobs were superseded/cancelled). Signed-in proof on dev (`tests/e2e/language-setting-live.proof.mjs`, n=1, throwaway tenant-less native account): 6/6 PASS — save fi → session `preferred_locale: fi`, page stays en, status "Saved."; PUT `xx` → 400 `unsupported_locale`; next sign-in at `/login` opens `/fi/lobby` (`fi-FI`). Screenshots `/var/tmp/CLE-3403-proof/dev-signed-in/`. Not run on prd (no debug tokens there; a prd run needs an invited test member). CLE-3408 reran the locale-neutral `user-menu-live.proof.mjs` (`0e914a9`) on dev: 10/10.

## Phase 5 — Other lanes' keys

- [x] T040 Translations for keys other lanes add with `add_keys.py`: CLE-3404 `checkout.host.*` (2, `5bbb421`), CLE-3408 `settings.keys*` (39, this commit). Machine drafts like T011.
