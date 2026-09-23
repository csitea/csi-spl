// Unit checks for language switcher (searchable combobox).
// No browser / Nuxt runtime required — guards component markers + i18n coverage.
// Run: node tests/unit/language-switcher.test.mjs
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const LOCALES = ['bg', 'fi', 'ru', 'en', 'sv', 'he', 'tr', 'mk', 'el', 'lt', 'et', 'lv', 'sr', 'ro', 'uk', 'sk', 'pl', 'es', 'nl']
const FLAGS = {
  bg: '🇧🇬',
  fi: '🇫🇮',
  sv: '🇸🇪',
  en: '🇬🇧',
  ru: '🇷🇺',
  he: '🇮🇱',
  tr: '🇹🇷',
  mk: '🇲🇰',
  el: '🇬🇷',
  lt: '🇱🇹',
  et: '🇪🇪',
  lv: '🇱🇻',
  sr: '🇷🇸',
  ro: '🇷🇴',
  uk: '🇺🇦',
  sk: '🇸🇰',
  pl: '🇵🇱',
  es: '🇪🇸',
  nl: '🇳🇱',
}

const NATIVE_NAMES = {
  bg: 'Български',
  fi: 'Suomi',
  ru: 'Русский',
  en: 'English',
  sv: 'Svenska',
  he: 'עברית',
  tr: 'Türkçe',
  mk: 'Македонски',
  el: 'Ελληνικά',
  lt: 'Lietuvių',
  et: 'Eesti',
  lv: 'Latviešu',
  sr: 'Srpski',
  ro: 'Română',
  uk: 'Українська',
  sk: 'Slovenčina',
  pl: 'Polski',
  es: 'Español',
  nl: 'Nederlands',
}
const ENGLISH_NAMES = {
  bg: 'Bulgarian',
  fi: 'Finnish',
  ru: 'Russian',
  en: 'English',
  sv: 'Swedish',
  he: 'Hebrew',
  tr: 'Turkish',
  mk: 'Macedonian',
  el: 'Greek',
  lt: 'Lithuanian',
  et: 'Estonian',
  lv: 'Latvian',
  sr: 'Serbian',
  ro: 'Romanian',
  uk: 'Ukrainian',
  sk: 'Slovak',
  pl: 'Polish',
  es: 'Spanish',
  nl: 'Dutch',
}

const ISO_TAGS = {
  bg: 'bg-BG',
  fi: 'fi-FI',
  ru: 'ru-RU',
  en: 'en-GB',
  sv: 'sv-SE',
  he: 'he-IL',
  tr: 'tr-TR',
  mk: 'mk-MK',
  el: 'el-GR',
  lt: 'lt-LT',
  et: 'et-EE',
  lv: 'lv-LV',
  sr: 'sr-RS',
  ro: 'ro-RO',
  uk: 'uk-UA',
  sk: 'sk-SK',
  pl: 'pl-PL',
  es: 'es-ES',
  nl: 'nl-NL',
}

let failed = 0
const pass = (name) => console.log(`  OK   ${name}`)
const fail = (name, msg) => { failed++; console.log(`  FAIL ${name}: ${msg}`) }

// --- LanguageSwitcher component markers ---
const swPath = join(WUI, 'src/components/LanguageSwitcher.vue')
if (!existsSync(swPath)) {
  fail('LanguageSwitcher.vue exists', swPath)
} else {
  pass('LanguageSwitcher.vue exists')
  const src = readFileSync(swPath, 'utf8')
  const markers = [
    'data-test="lang-switcher"',
    'data-test="lang-switcher-input"',
    'data-test="lang-switcher-options"',
    'lang-item-${loc.code}',
    // The navigation itself moved to composables/useLocaleSwitch (shared with
    // Settings -> Language); the markers for it are asserted on that file below.
    'useLocaleSwitch',
    'switchTo(loc.code)',
    'nav.lang_label',
    'nav.lang_note',
    'nav.lang_search_placeholder',
    'nav.lang_no_matches',
    '@headlessui/vue',
    'Combobox',
    'ComboboxInput',
    'ComboboxOptions',
    'ComboboxOption',
    '@/utils/localeSearch',
    'filterLocales',
    'normalizeLocaleQuery',
    '@focus="onFocus"',
    '@mouseup="onMouseUp"',
  ]
  for (const marker of markers) {
    src.includes(marker)
      ? pass('LanguageSwitcher has ' + marker)
      : fail('LanguageSwitcher has ' + marker, 'missing')
  }
  // Must be combobox, not bare native select or NuxtLink codes
  if (src.includes('Combobox') && !src.includes('<select')) {
    pass('LanguageSwitcher uses Combobox (not native select)')
  } else {
    fail('LanguageSwitcher uses Combobox (not native select)', 'select still present or Combobox missing')
  }
  // Regression: focusing must not leave the parked `display-value` in the
  // input, otherwise typing appends to it ("🇫🇮 Suomi" + "eng") and nothing matches.
  if (!/@focus="query = ''"/.test(src) && src.includes('input.select()')) {
    pass('LanguageSwitcher focus clears the parked display value')
  } else {
    fail('LanguageSwitcher focus clears the parked display value', 'focus still only resets the ref')
  }
  // The focus selection must survive the click that opened the switcher,
  // otherwise mouseup collapses the caret and backspace deletes one char.
  if (src.includes('keepFocusSelection') && src.includes('event.preventDefault()')) {
    pass('LanguageSwitcher keeps the focus selection on click')
  } else {
    fail('LanguageSwitcher keeps the focus selection on click', 'mouseup guard missing')
  }
  // The header control must not carry its own copy of the navigation any
  // more: two copies are how the two surfaces drifted apart in the first place.
  if (!src.includes('useSwitchLocalePath') && !src.includes('navigateTo')) {
    pass('LanguageSwitcher delegates the navigation to useLocaleSwitch')
  } else {
    fail('LanguageSwitcher delegates the navigation to useLocaleSwitch', 'inline switchLocalePath/navigateTo still present')
  }
  // Filtering is delegated to the shared, fold-aware matcher
  if (src.includes('filterLocales(availableLocales.value, query.value)')) {
    pass('LanguageSwitcher delegates filtering to filterLocales')
  } else {
    fail('LanguageSwitcher delegates filtering to filterLocales', 'inline filter still present')
  }
  for (const [code, flag] of Object.entries(FLAGS)) {
    src.includes(flag)
      ? pass('flag for ' + code)
      : fail('flag for ' + code, 'missing')
  }
}

// --- localeSearch util: markers ---
const utilPath = join(WUI, 'src/utils/localeSearch.ts')
if (!existsSync(utilPath)) {
  fail('localeSearch.ts exists', utilPath)
} else {
  pass('localeSearch.ts exists')
  const util = readFileSync(utilPath, 'utf8')
  for (const marker of [
    'LOCALE_ENGLISH_NAMES',
    'FILTER_MIN_CHARS = 2',
    'foldText',
    'normalizeLocaleQuery',
    'localeSearchTerms',
    'filterLocales',
    'entry.iso',
  ]) {
    util.includes(marker)
      ? pass('localeSearch has ' + marker)
      : fail('localeSearch has ' + marker, 'missing')
  }
  for (const [code, english] of Object.entries(ENGLISH_NAMES)) {
    util.includes(`${code}: '${english}'`)
      ? pass('English exonym for ' + code)
      : fail('English exonym for ' + code, 'missing ' + english)
  }
}

// --- localeSearch util: behaviour (inline port mirrors localeSearch.ts;
// node runs .mjs without a TS loader, Nuxt builds the real module) ---
const FILTER_MIN_CHARS = 2
const FLAG_RE = /[\u{1F1E6}-\u{1F1FF}\u{1F310}]/gu

function foldText(value) {
  return value.normalize('NFD').replace(/\p{Mn}/gu, '').toLowerCase().trim()
}

function normalizeLocaleQuery(raw, displayValue = '') {
  let query = raw
  if (displayValue && query.includes(displayValue)) {
    query = query.split(displayValue).join('')
  }
  return query.replace(FLAG_RE, '').trim()
}

function localeSearchTerms(entry) {
  const terms = [entry.name, entry.code]
  const english = ENGLISH_NAMES[entry.code]
  if (english) terms.push(english)
  if (entry.iso) {
    terms.push(entry.iso)
    const region = entry.iso.split('-')[1]
    if (region) terms.push(region)
  }
  return terms.filter(Boolean)
}

function filterLocales(entries, query) {
  const q = foldText(query)
  if (q.length < FILTER_MIN_CHARS) return entries
  return entries.filter(e => localeSearchTerms(e).some(term => foldText(term).includes(q)))
}

const ENTRIES = LOCALES.map(code => ({ code, name: NATIVE_NAMES[code], iso: ISO_TAGS[code] }))
const codesFor = (q) => filterLocales(ENTRIES, q).map(e => e.code)

// The reported bug: on /fi the input still holds "🇫🇮 Suomi", so the raw value
// after typing "eng" is "🇫🇮 Suomieng" and the old filter matched nothing.
const parked = '🇫🇮 Suomi'
normalizeLocaleQuery(parked + 'eng', parked) === 'eng'
  ? pass('normalizeLocaleQuery strips the parked display value')
  : fail('normalizeLocaleQuery strips the parked display value', normalizeLocaleQuery(parked + 'eng', parked))
codesFor(normalizeLocaleQuery(parked + 'eng', parked)).includes('en')
  ? pass('typing eng on the fi storefront surfaces en')
  : fail('typing eng on the fi storefront surfaces en', 'no match')
normalizeLocaleQuery('eng', parked) === 'eng'
  ? pass('normalizeLocaleQuery leaves a clean query untouched')
  : fail('normalizeLocaleQuery leaves a clean query untouched', normalizeLocaleQuery('eng', parked))
normalizeLocaleQuery('🇫🇮 eng', '') === 'eng'
  ? pass('normalizeLocaleQuery strips stray flag emoji')
  : fail('normalizeLocaleQuery strips stray flag emoji', normalizeLocaleQuery('🇫🇮 eng', ''))

for (const q of ['eng', 'engl', 'english', 'English', 'ENG', 'en', 'En']) {
  codesFor(q).includes('en')
    ? pass('filter ' + JSON.stringify(q) + ' includes en')
    : fail('filter ' + JSON.stringify(q) + ' includes en', codesFor(q).join(',') || 'none')
}

// Endonym, code and English exonym are all searchable for every locale.
for (const code of LOCALES) {
  const terms = [NATIVE_NAMES[code], code, ENGLISH_NAMES[code]]
  const missing = terms.filter(term => term.length >= FILTER_MIN_CHARS && !codesFor(term).includes(code))
  missing.length === 0
    ? pass('searchable by endonym/code/exonym: ' + code)
    : fail('searchable by endonym/code/exonym: ' + code, missing.join(','))
}

// IETF tag and region subtag are searchable: people type the country code
// they know ("se") rather than the language code ("sv").
for (const [q, code] of [['se', 'sv'], ['SE', 'sv'], ['sv-SE', 'sv'], ['sv', 'sv'], ['swedish', 'sv'], ['Svenska', 'sv'], ['sk', 'sk'], ['SK', 'sk'], ['slovak', 'sk'], ['sk-SK', 'sk'], ['en-GB', 'en'], ['gb', 'en'], ['bg-BG', 'bg'], ['es', 'es'], ['ES', 'es'], ['spanish', 'es'], ['espanol', 'es'], ['español', 'es'], ['es-ES', 'es'], ['nl', 'nl'], ['NL', 'nl'], ['dutch', 'nl'], ['nederlands', 'nl'], ['Nederlands', 'nl'], ['nl-NL', 'nl']]) {
  codesFor(q).includes(code)
    ? pass('filter ' + JSON.stringify(q) + ' includes ' + code)
    : fail('filter ' + JSON.stringify(q) + ' includes ' + code, codesFor(q).join(',') || 'none')
}

// Every configured IETF tag resolves to its own locale.
for (const code of LOCALES) {
  codesFor(ISO_TAGS[code]).includes(code)
    ? pass('IETF tag ' + ISO_TAGS[code] + ' includes ' + code)
    : fail('IETF tag ' + ISO_TAGS[code] + ' includes ' + code, 'no match')
}

// Diacritic-insensitive: "romana" must find "Română", "turkce" must find "Türkçe".
codesFor('romana').includes('ro')
  ? pass('filter romana includes ro')
  : fail('filter romana includes ro', 'no match')
codesFor('turkce').includes('tr')
  ? pass('filter turkce includes tr')
  : fail('filter turkce includes tr', 'no match')

// Empty / below-threshold query lists everything.
codesFor('').length === LOCALES.length
  ? pass('empty query lists all locales')
  : fail('empty query lists all locales', String(codesFor('').length))
codesFor('e').length === LOCALES.length
  ? pass('1-char query lists all locales')
  : fail('1-char query lists all locales', String(codesFor('e').length))

// A genuinely unknown term still yields the empty-state.
codesFor('zzqq').length === 0
  ? pass('unknown query yields no matches')
  : fail('unknown query yields no matches', codesFor('zzqq').join(','))

// --- app.vue sets html lang + dir (RTL for he) ---
const appSrc = readFileSync(join(WUI, 'src/app.vue'), 'utf8')
appSrc.includes('htmlAttrs') && appSrc.includes('dir') && appSrc.includes('he')
  ? pass('app.vue sets html lang/dir for RTL')
  : fail('app.vue sets html lang/dir for RTL', 'missing')

// --- The sign-in frame and the app top bar wire the switcher ---
// (the donor wires AppHeader + MobileMenu; the login layout carries it
// in its top bar, and since 022 the app shell's top bar (TopBar.vue, mounted by
// layouts/default.vue) carries it at its end, next to the user menu)
readFileSync(join(WUI, 'src/layouts/default.vue'), 'utf8').includes('<TopBar')
  ? pass('src/layouts/default.vue mounts TopBar')
  : fail('src/layouts/default.vue mounts TopBar', 'missing')
for (const rel of ['src/layouts/login.vue', 'src/components/TopBar.vue']) {
  const src = readFileSync(join(WUI, rel), 'utf8')
  src.includes('LanguageSwitcher')
    ? pass(rel + ' uses LanguageSwitcher')
    : fail(rel + ' uses LanguageSwitcher', 'missing')
}

// --- nuxt i18n: cookie persistence + locale names ---
const nuxtCfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
nuxtCfg.includes('i18n_redirected')
  ? pass('nuxt.config detectBrowserLanguage cookie')
  : fail('nuxt.config detectBrowserLanguage cookie', 'missing')
for (const name of Object.values(NATIVE_NAMES)) {
  nuxtCfg.includes(name)
    ? pass('locale name ' + name)
    : fail('locale name ' + name, 'missing')
}
// The searchable IETF tags must be the ones the module actually ships.
for (const [code, tag] of Object.entries(ISO_TAGS)) {
  (nuxtCfg.includes(`'${tag}'`) || nuxtCfg.includes(`"${tag}"`))
    ? pass('nuxt.config IETF tag for ' + code)
    : fail('nuxt.config IETF tag for ' + code, 'missing ' + tag)
}
if (nuxtCfg.includes("dir: 'rtl'") || nuxtCfg.includes('dir: "rtl"')) {
  pass('he locale has dir rtl')
} else {
  fail('he locale has dir rtl', 'missing')
}

// --- i18n keys in all locales ---
for (const code of LOCALES) {
  const p = join(WUI, 'i18n/locales', code + '.json')
  const data = JSON.parse(readFileSync(p, 'utf8'))
  const nav = data.nav || {}
  if (typeof nav.lang_label === 'string' && nav.lang_label.length > 0) {
    pass(code + ' nav.lang_label')
  } else {
    fail(code + ' nav.lang_label', JSON.stringify(nav.lang_label))
  }
  if (typeof nav.lang_note === 'string' && nav.lang_note.length > 0) {
    pass(code + ' nav.lang_note')
  } else {
    fail(code + ' nav.lang_note', JSON.stringify(nav.lang_note))
  }
  if (typeof nav.lang_search_placeholder === 'string' && nav.lang_search_placeholder.length > 0) {
    pass(code + ' nav.lang_search_placeholder')
  } else {
    fail(code + ' nav.lang_search_placeholder', JSON.stringify(nav.lang_search_placeholder))
  }
  if (typeof nav.lang_no_matches === 'string' && nav.lang_no_matches.length > 0) {
    pass(code + ' nav.lang_no_matches')
  } else {
    fail(code + ' nav.lang_no_matches', JSON.stringify(nav.lang_no_matches))
  }
}


// --- useLocaleSwitch: the one place a locale switch navigates ---
const lsPath = join(WUI, 'src/composables/useLocaleSwitch.ts')
if (!existsSync(lsPath)) {
  fail('useLocaleSwitch.ts exists', lsPath)
} else {
  pass('useLocaleSwitch.ts exists')
  const src = readFileSync(lsPath, 'utf8')
  for (const marker of [
    'useSwitchLocalePath',
    'navigateTo',
    'csi-spl-lang',
    'import.meta.client',
    'localeTargetPath',
    'isPathInLocale',
    "query: { ...route.query }",
  ]) {
    src.includes(marker)
      ? pass('useLocaleSwitch has ' + marker)
      : fail('useLocaleSwitch has ' + marker, 'missing')
  }
  // The regression this file exists for: switchLocalePath's answer is only
  // used when it actually lands in the target locale. Trusting it blind is
  // what made the switcher a silent no-op.
  if (/isPathInLocale\(offered/.test(src) && src.includes('localeTargetPath(route.path')) {
    pass('useLocaleSwitch checks switchLocalePath before trusting it')
  } else {
    fail('useLocaleSwitch checks switchLocalePath before trusting it', 'unchecked fallback')
  }
}

// --- Settings -> Language must switch the UI on save (owner 2026-09-23) ---
const setPath = join(WUI, 'src/components/LanguageSetting.vue')
if (!existsSync(setPath)) {
  fail('LanguageSetting.vue exists', setPath)
} else {
  pass('LanguageSetting.vue exists')
  const src = readFileSync(setPath, 'utf8')
  if (src.includes('useLocaleSwitch') && /await switchTo\(want, true\)/.test(src)) {
    pass('LanguageSetting switches the UI after a successful save')
  } else {
    fail('LanguageSetting switches the UI after a successful save', 'save does not switch')
  }
  // The hub write must be awaited first: never claim a preference it refused.
  const saveIdx = src.indexOf('auth.savePreferences')
  const switchIdx = src.indexOf('switchTo(want')
  if (saveIdx > -1 && switchIdx > saveIdx) {
    pass('LanguageSetting saves before it switches')
  } else {
    fail('LanguageSetting saves before it switches', 'switch is not after the hub write')
  }
}

// --- the hint copy must not still promise the old behaviour ---
for (const code of LOCALES) {
  const msgs = JSON.parse(readFileSync(join(WUI, 'i18n/locales/' + code + '.json'), 'utf8'))
  const hint = msgs?.settings?.language?.hint
  typeof hint === 'string' && hint.length > 0
    ? pass('settings.language.hint present for ' + code)
    : fail('settings.language.hint present for ' + code, 'missing')
}


if (failed > 0) {
  console.error('\n' + failed + ' check(s) failed')
  process.exit(1)
}
console.log('\nAll language-switcher checks passed.')
