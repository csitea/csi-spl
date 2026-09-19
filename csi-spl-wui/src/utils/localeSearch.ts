/**
 * Search helpers for the language combobox (LanguageSwitcher.vue).
 *
 * Two defects this exists to prevent:
 *
 * 1. Headless UI parks the selected locale's `display-value` inside the input
 *    ("🇫🇮 Suomi"). Clicking into the box puts the caret after that text, so
 *    typing "eng" yields the raw input value "🇫🇮 Suomieng" — a naive filter
 *    then matches nothing at all. `normalizeLocaleQuery` strips the parked
 *    display value and any flag emoji before the query is used.
 * 2. Option labels are endonyms ("Suomi", "Български", "Ελληνικά"). A visitor
 *    on the Finnish UI searches for "eng" / "english", and a visitor
 *    looking for Romanian types "romana" without the diacritic. `foldText`
 *    folds case + combining marks, so every match is case- and
 *    diacritic-insensitive, and `filterLocales` matches the endonym, the
 *    English exonym, the locale code, the full IETF tag and its region
 *    subtag — so "sv", "sv-SE", "se", "swedish" and "Svenska" all find
 *    Swedish, and "sk" / "slovak" find Slovak.
 *
 * Keep in sync with tests/unit/language-switcher.test.mjs (inline port there —
 * node runs .mjs without a TS loader; Nuxt builds the real module).
 */

/** English exonym per configured locale — endonyms alone are not searchable. */
export const LOCALE_ENGLISH_NAMES: Record<string, string> = {
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

/** Filter only after this many characters; 0–1 shows the full locale list. */
export const FILTER_MIN_CHARS = 2

/** Regional-indicator pairs (flag emoji) plus the 🌐 fallback glyph. */
const FLAG_RE = /[\u{1F1E6}-\u{1F1FF}\u{1F310}]/gu

/** Case- and diacritic-insensitive fold: "Română" → "romana". */
export function foldText(value: string): string {
  return value
    .normalize('NFD')
    .replace(/\p{Mn}/gu, '')
    .toLowerCase()
    .trim()
}

/**
 * Turn the raw input value into the term the user actually typed.
 *
 * `displayValue` is what the combobox shows for the current selection; when it
 * is still present in the raw value the user typed around it rather than
 * replacing it, so it is not part of the search term.
 */
export function normalizeLocaleQuery(raw: string, displayValue = ''): string {
  let query = raw
  if (displayValue && query.includes(displayValue)) {
    query = query.split(displayValue).join('')
  }
  return query.replace(FLAG_RE, '').trim()
}

export interface LocaleSearchEntry {
  code: string
  name: string
  /** Full IETF tag from the i18n locale config, e.g. `sv-SE`. */
  iso?: string
}

/**
 * Every string a locale may be searched by: endonym, locale code, English
 * exonym, full IETF tag and its region subtag. The region subtag matters
 * because people type the country code they know ("se" for Swedish) rather
 * than the language code ("sv").
 */
export function localeSearchTerms(entry: LocaleSearchEntry): string[] {
  const terms = [entry.name, entry.code]
  const english = LOCALE_ENGLISH_NAMES[entry.code]
  if (english) terms.push(english)
  if (entry.iso) {
    terms.push(entry.iso)
    const region = entry.iso.split('-')[1]
    if (region) terms.push(region)
  }
  return terms.filter(Boolean)
}

/** Below FILTER_MIN_CHARS the full list is returned (empty query shows all). */
export function filterLocales<T extends LocaleSearchEntry>(entries: T[], query: string): T[] {
  const q = foldText(query)
  if (q.length < FILTER_MIN_CHARS) return entries
  return entries.filter(entry =>
    localeSearchTerms(entry).some(term => foldText(term).includes(q)),
  )
}
