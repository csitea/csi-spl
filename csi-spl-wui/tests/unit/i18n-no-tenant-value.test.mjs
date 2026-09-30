// Guard (CLE-77805, owner topic 6da1d88e): the user-facing word is "workspace",
// never "tenant". No LOCALE VALUE may contain the Latin substring "tenant".
//
// Scope: VALUES only. i18n KEYS stay "tenant" (sidebar.tenant, tenant_settings,
// tenant_host, per_tenant_note, …) — code, API paths and logs read them by name.
// Two things a value may legitimately carry are NOT the English word and are
// stripped before the check:
//   - the {tenant} interpolation placeholder (a code variable), and any {…} slot,
//   - the search operator tokens type:tenant / type:workspace / type:event, which
//     are query syntax the help text spells out literally.
// ALLOW below is the escape hatch for a value that must keep "tenant"; keep it
// EMPTY. A planted "tenant" value must fail this test (control at the bottom).
//
// Run: node tests/unit/i18n-no-tenant-value.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')

// key-paths (e.g. "some.key") whose value may contain "tenant". Keep empty.
const ALLOW = new Set([])

function flatten(d, prefix = '') {
  const out = {}
  for (const [k, v] of Object.entries(d)) {
    const full = prefix ? prefix + '.' + k : k
    if (v && typeof v === 'object' && !Array.isArray(v)) Object.assign(out, flatten(v, full))
    else out[full] = v
  }
  return out
}

// the offending "tenant" occurrences in one flattened locale, after stripping the
// {…} placeholders and the type:<word> operator tokens.
function offenders(flat) {
  const bad = []
  for (const [k, v] of Object.entries(flat)) {
    if (typeof v !== 'string' || ALLOW.has(k)) continue
    const stripped = v.replace(/\{[^}]*\}/g, '').replace(/\btype:\w+/g, '')
    if (/tenant/i.test(stripped)) bad.push(k + ' = ' + JSON.stringify(v))
  }
  return bad
}

let failed = 0
const pass = (n) => console.log('  OK   ' + n)
const fail = (n, m) => { failed++; console.log('  FAIL ' + n + ': ' + m) }

const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
files.length === 19 ? pass('19 locales') : fail('19 locales', String(files.length))

for (const f of files) {
  const bad = offenders(flatten(JSON.parse(readFileSync(join(dir, f), 'utf8'))))
  bad.length === 0 ? pass(f + ' has no "tenant" value') : fail(f, bad.join(' | '))
}

// CONTROL: a planted "tenant" value must be caught, and a {tenant}/type:tenant
// value must NOT be (so the guard cannot be silently defeated).
const control = flatten({ a: { b: 'Only an admin of this tenant can do that.' }, ok: 'Settings apply to {tenant}.', op: 'type:tenant still works' })
const caught = offenders(control)
caught.length === 1 && caught[0].startsWith('a.b') ? pass('control: planted tenant fails, {tenant}/type:tenant pass') : fail('control', JSON.stringify(caught))

if (failed) {
  console.error(failed + ' failure(s)')
  process.exit(1)
}
console.log('i18n-no-tenant-value ok')
