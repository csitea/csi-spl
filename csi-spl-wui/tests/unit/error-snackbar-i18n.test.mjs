// GRK-3514 — event-log + snackbar catalogue keys (topic 4335f075).
// English values are the lead's specified strings; every other locale has
// the same leaf set (i18n-parity) and snackbar.repeat keeps the {n} token.
//
// Run: node tests/unit/error-snackbar-i18n.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const LOCALES = join(WUI, 'i18n/locales')

const EN = {
  'sidebar.events': 'Event log',
  'events.title': 'Event log',
  'events.empty': 'No errors recorded.',
  'events.clear': 'Clear log',
  'events.load_more': 'Load older',
  'events.col_when': 'When',
  'events.col_source': 'Source',
  'events.col_status': 'Status',
  'events.col_message': 'Message',
  'events.col_id': 'Error id',
  'events.col_route': 'Page',
  'events.signed_out': 'Sign in to see your event log.',
  'events.load_failed': 'The event log could not be read.',
  'snackbar.dismiss': 'Dismiss',
  'snackbar.region': 'Errors',
  'snackbar.repeat': 'x{n}',
}

function leaf(obj, dotted) {
  return dotted.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), obj)
}

let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }

console.log('error-snackbar-i18n')

const files = readdirSync(LOCALES).filter((f) => f.endsWith('.json')).sort()
files.length === 19
  ? pass('19 locale files')
  : fail('19 locale files', `found ${files.length}`)

const en = JSON.parse(readFileSync(join(LOCALES, 'en.json'), 'utf8'))
for (const [k, want] of Object.entries(EN)) {
  const got = leaf(en, k)
  got === want ? pass(`en ${k}`) : fail(`en ${k}`, JSON.stringify(got))
}

for (const f of files) {
  const data = JSON.parse(readFileSync(join(LOCALES, f), 'utf8'))
  for (const k of Object.keys(EN)) {
    const v = leaf(data, k)
    typeof v === 'string' && v.trim()
      ? pass(`${f} ${k} present`)
      : fail(`${f} ${k} present`, JSON.stringify(v))
  }
  const repeat = leaf(data, 'snackbar.repeat')
  typeof repeat === 'string' && repeat.includes('{n}')
    ? pass(`${f} snackbar.repeat keeps {n}`)
    : fail(`${f} snackbar.repeat keeps {n}`, JSON.stringify(repeat))
}

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll error-snackbar-i18n checks passed.')
