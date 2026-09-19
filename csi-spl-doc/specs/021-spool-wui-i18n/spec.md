# Spec: Spool WUI + hub i18n — the donor language switcher (021)

**Feature**: `specs/021-spool-wui-i18n` · **Created**: 2026-09-19 · **Lane**: CLE-3403

## 1. Owner orders (verbatim, 2026-09-19)

- "implement the language switcher - exactly the same functionality as in the
  csi-rel project for the same languages"
- "so the site should be truly international from the very beginning"
- "also make sure there is a language setting in the settings page of the user
  in the user settings ... when the user could select his preferred language"

## 2. The donor, measured (csi-rel `e4612828`)

| aspect | donor (file:line) | spool (this spec) |
|---|---|---|
| library | `@nuxtjs/i18n` v9 + `@headlessui/vue` Combobox (`csi-rel-wui/package.json`) | same |
| locales | 19: `bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl` (`csi-rel-wui/nuxt.config.ts:197-217`) | same list, same endonyms + BCP47 tags |
| default | `bg`, cnf `env.i18n.default_locale` → `NUXT_PUBLIC_DEFAULT_LOCALE` (`nuxt.config.ts:192`, `csi-rel-cnf/csi-rel/all.env.yaml:145`) | same mechanism, `bg` (OQ-1) |
| URL scheme | `prefix_except_default` (`nuxt.config.ts:360`): default unprefixed, others `/<code>/…` | same |
| detection | module detection OFF (`nuxt.config.ts:392`); a blocking `<head>` script on `/` only: cookie → `navigator.languages` → default, crawlers exempt (`src/utils/rootLocaleRedirect.mjs`) | copied verbatim |
| persistence | cookie `i18n_redirected` (1 y, `SameSite=Lax`) written on every switch (`src/plugins/locale-cookie.client.ts`); localStorage mirror `csi-rel-lang` (`src/components/LanguageSwitcher.vue`) | same; mirror key `csi-spl-lang` |
| switcher | `LanguageSwitcher.vue`: searchable combobox (flag + endonym + code; matches endonym, English exonym, code, IETF tag, region; fold-insensitive; filter from 2 chars; `src/utils/localeSearch.ts`), in `AppHeader` top-right and `MobileMenu`; switching = `navigateTo(switchLocalePath(code))` keeping query + hash | same component; sits top-right in the app corner (before the user menu, CLE-3402) and in the sign-in frame's corner (the spool has no header bar) |
| SEO | `useLocaleHead({dir,lang,seo})` → `<html lang dir>`, hreflang alternates; `he` = `dir: 'rtl'` (`src/app.vue`) | same (the WUI is noindex; hreflang kept for parity) |
| preferred language | `users.preferred_locale`, set at register from the UI locale, edited on `/account` with `LocaleCombobox` that does NOT switch the UI (`src/pages/account/index.vue:50-61`, `tests/unit/locale-combobox.test.mjs`) | `humans.preferred_locale`, edited on `/settings` with `LanguageSetting.vue` (`LocaleCombobox`, no UI switch); owner addition: applied once after sign-in (`plugins/preferred-locale.client.ts`) |
| API locale | `X-Locale` header wins over `Accept-Language` (`csi-rel-api/src/internal/i18n/i18n.go:60-72`) | same header, sent by the auth client |
| mails | per-locale templates `templates/<id>/<loc>.{subject,txt}`, `en` fallback, link carries the locale prefix (`internal/mail/templates.go:149-185`, `email_verification.go`); verify/reset use `COALESCE(u.preferred_locale,'')` | same, for verify, reset and the M2 claim mail, all 19 locales |
| catalogues | one nested JSON per locale `i18n/locales/<code>.json`, lazy chunks | same |
| translation | builder writes source values, LLM translator agents in batches of ~5 languages with `TRANSLATOR-BRIEF.template.txt`, `export_locale.py` / `splice_locales.py` (`src/python/i18n/README.md`) | same tools, copied; en is the source language here |
| tests | `i18n-parity`, `root-locale-redirect`, `language-switcher`, `locale-combobox` (`tests/unit/`) | copied and adapted, plus `auth-i18n-keys` |

## 3. Requirements

- FR-001 Every user-visible WUI string comes from the catalogues; all 19
  locales carry every key (parity test; CONTROL: a missing key fails).
- FR-002 Switching language keeps the page, its query and hash.
- FR-003 `/` resolves cookie → browser language → default before hydration.
- FR-004 `<html lang>` and `dir` follow the locale (`he` = rtl); the app
  corner and headers use logical (inline-start/end) properties.
- FR-005 A signed-in human stores a preferred language (Settings); the hub
  mails that human in it; the WUI opens in it once after sign-in.
- FR-006 Anonymous visitors: the donor's detection; the hub mails a
  registrant in the request's locale (`X-Locale` > `Accept-Language` > default).
- FR-007 No document x-scroll at any locale (long strings).
- FR-008 The default locale is one cnf value (`env.i18n.default_locale`)
  shared by the WUI build and the hub.

## 4. Open question for the owner

- **OQ-1 default locale.** The donor's default is `bg` (a Bulgarian shop).
  spool-hub.ai is an English-facing product. **Recommendation: `en`.** It is
  one cnf value (`csi-spl-cnf/csi-spl/all.env.yaml` `env.i18n.default_locale`),
  so the donor's `bg` ships until the owner says otherwise. Effect of `bg`:
  every unprefixed URL (`/login`, `/channel/general`, mailed links for a person
  with no preference) renders Bulgarian; browsers asking for another shipped
  language are redirected from `/` only.
