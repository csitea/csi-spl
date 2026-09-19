// Spec 066 T011 / FR-010 — storefront i18n contract.
//
// One nested JSON file per locale under i18n/locales/<code>.json (19 locales).
// Identical leaf-key sets, no empty / non-string values. Complements the CI
// gate (validate-i18n.py in wui-build-deploy.yml) with an in-module unit test.
// Does not edit locale content.
//
// Run: node tests/unit/i18n-parity.test.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const LOCALES_DIR = join(WUI, 'i18n/locales')
const TOOLS_DIR = join(WUI, 'src/python/i18n')
const EXPECTED_COUNT = 19

let failed = 0
const pass = (name) => console.log(`  OK   ${name}`)
const fail = (name, msg) => { failed++; console.log(`  FAIL ${name}: ${msg}`) }

function flatten(d, prefix = '') {
  const out = {}
  if (d === null || typeof d !== 'object' || Array.isArray(d)) return out
  for (const [k, v] of Object.entries(d)) {
    const full = prefix ? `${prefix}.${k}` : k
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      Object.assign(out, flatten(v, full))
    } else {
      out[full] = v
    }
  }
  return out
}

console.log('i18n-parity')

if (!existsSync(LOCALES_DIR)) {
  fail('i18n/locales exists', 'missing')
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}

const files = readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json')).sort()
files.length === EXPECTED_COUNT
  ? pass(`${EXPECTED_COUNT} locale JSON files`)
  : fail(`${EXPECTED_COUNT} locale JSON files`, `found ${files.length}: ${files.join(',')}`)

const sets = {}
const empties = {}
for (const f of files) {
  const p = join(LOCALES_DIR, f)
  let data
  try {
    data = JSON.parse(readFileSync(p, 'utf8'))
  } catch (e) {
    fail(`${f} parses`, e.message)
    continue
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    fail(`${f} is object`, typeof data)
    continue
  }
  const flat = flatten(data)
  const keys = Object.keys(flat).sort()
  sets[f] = keys
  empties[f] = keys.filter((k) => {
    const v = flat[k]
    return typeof v !== 'string' || v.trim() === ''
  })
  empties[f].length === 0
    ? pass(`${f} no empty values (${keys.length} keys)`)
    : fail(`${f} no empty values`, empties[f].slice(0, 8).join(', '))
}

const codes = Object.keys(sets)
if (codes.length) {
  const union = new Set()
  for (const f of codes) for (const k of sets[f]) union.add(k)
  const unionList = [...union].sort()
  pass(`union is ${unionList.length} leaf keys`)
  for (const f of codes) {
    const have = new Set(sets[f])
    const missing = unionList.filter((k) => !have.has(k))
    missing.length === 0
      ? pass(`${f} key set matches union`)
      : fail(`${f} key set matches union`, `missing ${missing.length}: ${missing.slice(0, 8).join(', ')}`)
  }
}

// spec 021: values the vue-i18n compiler would reject or misread. HTML-like
// text ("<id>") fails `nuxt generate` outright; a bare "@" is linked-message
// syntax; a plural key must keep en's number of "|" forms in every locale.
// CONTROL: the three detectors are exercised on planted values below.
const HTML_RE = /<[A-Za-z\/!]/
const LINK_RE = /@(?:[.:a-z]|$)/
const forms = (v) => String(v).split('|').length
const enFlat = sets['en.json'] ? flatten(JSON.parse(readFileSync(join(LOCALES_DIR, 'en.json'), 'utf8'))) : {}
for (const f of Object.keys(sets)) {
  const flat = flatten(JSON.parse(readFileSync(join(LOCALES_DIR, f), 'utf8')))
  const html = [], link = [], plural = []
  for (const [k, v] of Object.entries(flat)) {
    if (HTML_RE.test(String(v))) html.push(k)
    if (LINK_RE.test(String(v))) link.push(k)
    if (k in enFlat && forms(v) !== forms(enFlat[k])) plural.push(k)
  }
  html.length === 0 ? pass(`${f} no HTML-like values`) : fail(`${f} no HTML-like values`, html.slice(0, 8).join(', '))
  link.length === 0 ? pass(`${f} no bare @ link syntax`) : fail(`${f} no bare @ link syntax`, link.slice(0, 8).join(', '))
  plural.length === 0 ? pass(`${f} plural forms match en`) : fail(`${f} plural forms match en`, plural.slice(0, 8).join(', '))
}
;(HTML_RE.test('open with ?tenant=<id>') && LINK_RE.test('ask @CLE-07') === false && LINK_RE.test('see @:nav.home') && forms('a | b') === 2)
  ? pass('CONTROL: detectors fire on planted values')
  : fail('CONTROL: detectors fire on planted values', 'a detector is blind')

const tools = [
  'export_locale.py',
  'splice_locales.py',
  'TRANSLATOR-BRIEF.template.txt',
  'README.md',
]
for (const name of tools) {
  existsSync(join(TOOLS_DIR, name))
    ? pass(`tool ${name} present`)
    : fail(`tool ${name} present`, 'missing')
}

const exportPy = existsSync(join(TOOLS_DIR, 'export_locale.py'))
  ? readFileSync(join(TOOLS_DIR, 'export_locale.py'), 'utf8')
  : ''
const splicePy = existsSync(join(TOOLS_DIR, 'splice_locales.py'))
  ? readFileSync(join(TOOLS_DIR, 'splice_locales.py'), 'utf8')
  : ''
;/argparse\.ArgumentParser/.test(exportPy)
  ? pass('export_locale.py uses argparse (--help)')
  : fail('export_locale.py uses argparse (--help)', 'no ArgumentParser')
;/argparse\.ArgumentParser/.test(splicePy)
  ? pass('splice_locales.py uses argparse (--help)')
  : fail('splice_locales.py uses argparse (--help)', 'no ArgumentParser')
;/--delta/.test(splicePy)
  ? pass('splice_locales.py has --delta')
  : fail('splice_locales.py has --delta', 'missing')
;/--codes/.test(exportPy) && /--codes/.test(splicePy)
  ? pass('both tools accept --codes')
  : fail('both tools accept --codes', 'missing')

// A4 — keys deleted as provably unreachable stay deleted in all 19 locales
// (src/python/one-off/2026-08-23-dead-i18n-keys-18-locales.py; re-derive the
// list with src/python/i18n/find_dead_keys.py). A rename that leaves the old
// key behind costs every translator 18 files for a string nobody renders.
const REMOVED_KEYS = [
  'account.details_title',
  'account.first_name',
  'account.last_name',
  'account.preferred_locale',
  'account.profile_email',
  'admin.products.form_b2b_only',
  'admin.users.created_ok',
  'admin.users.form_group',
  'admin.users.save_roles',
  'checkout.shipping.methodCourier',
  'checkout.shipping.methodPickup',
  'product.gallery.full_in_modal',
  'product.gallery.open_multi',
]
for (const f of codes) {
  const have = new Set(sets[f])
  const back = REMOVED_KEYS.filter((k) => have.has(k))
  back.length === 0
    ? pass(`${f} has no resurrected dead keys`)
    : fail(`${f} has no resurrected dead keys`, back.join(', '))
}

const inSuite = runsInUnitSuite(import.meta.url)
inSuite.ok
  ? pass('pnpm test runs i18n-parity.test.mjs')
  : fail('pnpm test runs i18n-parity.test.mjs', inSuite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll i18n-parity checks passed.')
