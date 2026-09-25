// The tenant drop box hover copy, all 19 locales.
// EN is the lead's exact string. Every other locale differs, and every
// tenant_hint keeps the {name} placeholder.
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')
const KEYS = ['sidebar.tenant_hint', 'sidebar.tenant_hint_one', 'sidebar.tenant_hint_switch']
const EN = {
  'sidebar.tenant_hint': 'Tenant: {name}. A tenant is one organisation\'s workspace — its own channels, topics, members and agents.',
  'sidebar.tenant_hint_one': 'You are a member of this tenant only.',
  'sidebar.tenant_hint_switch': 'Pick another tenant here to switch to it.',
}

function flatten(d, prefix = '') {
  const out = {}
  for (const [k, v] of Object.entries(d)) {
    const full = prefix ? prefix + '.' + k : k
    if (v && typeof v === 'object' && !Array.isArray(v)) Object.assign(out, flatten(v, full))
    else out[full] = v
  }
  return out
}

let failed = 0
const pass = (n) => console.log('  OK   ' + n)
const fail = (n, m) => { failed++; console.log('  FAIL ' + n + ': ' + m) }

const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
files.length === 19 ? pass('19 locales') : fail('19 locales', String(files.length))

const flats = {}
for (const f of files) flats[f] = flatten(JSON.parse(readFileSync(join(dir, f), 'utf8')))

for (const f of files) {
  for (const k of KEYS) {
    const v = flats[f][k]
    typeof v === 'string' && v.trim() ? pass(f + ' ' + k) : fail(f + ' ' + k, 'missing')
  }
  const hint = flats[f]['sidebar.tenant_hint']
  hint && hint.includes('{name}') ? pass(f + ' {name}') : fail(f + ' {name}', String(hint))
  if (f !== 'en.json') {
    const same = KEYS.filter((k) => flats[f][k] === flats['en.json'][k])
    same.length === 0 ? pass(f + ' differs from en') : fail(f + ' differs from en', same.join(','))
  }
}
for (const [k, v] of Object.entries(EN)) {
  flats['en.json'][k] === v ? pass('en exact ' + k) : fail('en exact ' + k, JSON.stringify(flats['en.json'][k]))
}

if (failed) {
  console.error(failed + ' failure(s)')
  process.exit(1)
}
console.log('tenant-hint-i18n ok')
