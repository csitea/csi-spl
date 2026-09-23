// Unit checks for utils/localeTargetPath.mjs — the prefix arithmetic a locale
// switch falls back to when `switchLocalePath()` cannot answer.
//
// This is the half of the switch that can be proven without a browser: given
// a path and a target locale, there is exactly one right answer under
// `prefix_except_default`, and the one answer that must never come back is
// "the path you already had" — that is the silent no-op the owner reported.
//
// Run: node tests/unit/locale-target-path.test.mjs
import { localeTargetPath, localePrefixOf, isPathInLocale } from '../../src/utils/localeTargetPath.mjs'

const CODES = ['bg', 'fi', 'ru', 'en', 'sv', 'he', 'tr', 'mk', 'el', 'lt', 'et', 'lv', 'sr', 'ro', 'uk', 'sk', 'pl', 'es', 'nl']
const DEF = 'en'

let passed = 0
let failed = 0
const pass = (name) => { passed++; console.log(`  ok   ${name}`) }
const fail = (name, got, want) => { failed++; console.log(`  FAIL ${name}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`) }
const eq = (name, got, want) => (got === want ? pass(name) : fail(name, got, want))

// --- localePrefixOf -------------------------------------------------------
eq('no prefix on the default-locale root', localePrefixOf('/', CODES), '')
eq('no prefix on a default-locale page', localePrefixOf('/settings/language', CODES), '')
eq('reads the locale segment', localePrefixOf('/bg/settings/language', CODES), 'bg')
eq('a non-locale first segment is not a prefix', localePrefixOf('/lobby', CODES), '')
// `/es` is a locale, but `/est` is not — the segment must match whole.
eq('a locale-like segment is not a prefix', localePrefixOf('/estonia', CODES), '')

// --- localeTargetPath: default locale has no prefix -----------------------
eq('default locale drops the prefix', localeTargetPath('/bg/settings/language', 'en', CODES, DEF), '/settings/language')
eq('default locale root', localeTargetPath('/bg', 'en', CODES, DEF), '/')
eq('default locale stays put', localeTargetPath('/settings/language', 'en', CODES, DEF), '/settings/language')

// --- localeTargetPath: every other locale gets its own prefix -------------
eq('adds the prefix', localeTargetPath('/settings/language', 'bg', CODES, DEF), '/bg/settings/language')
eq('adds the prefix at the root', localeTargetPath('/', 'bg', CODES, DEF), '/bg')
eq('swaps one prefix for another', localeTargetPath('/fi/settings/language', 'bg', CODES, DEF), '/bg/settings/language')
eq('keeps a dynamic segment verbatim', localeTargetPath('/fi/channel/general', 'he', CODES, DEF), '/he/channel/general')
eq('keeps a deep path verbatim', localeTargetPath('/t/abc-123', 'sv', CODES, DEF), '/sv/t/abc-123')
eq('strips a query if one is passed in', localeTargetPath('/login?redirect=%2Flobby', 'fi', CODES, DEF), '/fi/login')

// --- the regression: the answer is never the path it was given ------------
// Measured on dev.<fqdn>, tree 021d706, 2026-09-22: the header switcher
// returned the current path on 1 of 13 runs and navigated nowhere.
for (const code of CODES) {
  for (const path of ['/', '/login', '/lobby', '/settings/language', '/bg/settings/language', '/fi/channel/general']) {
    const got = localeTargetPath(path, code, CODES, DEF)
    const already = isPathInLocale(path, code, CODES, DEF)
    if (!already && got === path) {
      fail(`switch ${path} -> ${code} moves somewhere`, got, 'a different path')
    } else if (!isPathInLocale(got, code, CODES, DEF)) {
      fail(`switch ${path} -> ${code} lands in ${code}`, got, `a /${code} path`)
    } else {
      passed++
    }
  }
}
pass(`every ${CODES.length} locales x 6 paths land in the target locale`)

// --- isPathInLocale -------------------------------------------------------
eq('default locale is the unprefixed one', isPathInLocale('/login', 'en', CODES, DEF), true)
eq('a prefixed path is not the default locale', isPathInLocale('/bg/login', 'en', CODES, DEF), false)
eq('a prefixed path is its own locale', isPathInLocale('/bg/login', 'bg', CODES, DEF), true)
eq('a prefixed path is not another locale', isPathInLocale('/bg/login', 'fi', CODES, DEF), false)

console.log(`\n${passed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
