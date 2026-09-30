// spec 021 — the auth copy's catalogue keys render exactly the canonical
// English of utils/auth-client.mjs. The components show t(key); the English
// functions stay the source, so en.json may never drift from them.
// CONTROL: a key the helper returns but en.json lacks fails "key present".
// Run: node tests/unit/auth-i18n-keys.test.mjs
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  authErrorKey, authErrorMessage, nativeErrorKey, nativeErrorMessage, retryAfterKey, retryAfterMessage,
} from '../../src/utils/auth-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }

/** vue-i18n named interpolation, enough for `{name}` tokens. */
function render(k) {
  if (!k) return ''
  const v = k.key.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), en)
  if (typeof v !== 'string') { fail('key present ' + k.key, 'missing in en.json'); return null }
  return v.replace(/\{(\w+)\}/g, (_, p) => String(k.params[p]))
}
function same(label, key, english) {
  const got = render(key)
  if (got === null) return
  got === english ? pass(label) : fail(label, `${JSON.stringify(got)} != ${JSON.stringify(english)}`)
}

console.log('auth-i18n-keys')
for (const c of ['cancelled', 'invalid_state', 'exchange_failed', 'email_unverified', 'not_allowed', 'invite_expired', 'unavailable', 'weird', '']) {
  same('authError ' + JSON.stringify(c), authErrorKey(c), authErrorMessage(c))
}
const outs = [
  { error: 'invalid_credentials' }, { error: 'email_unverified' }, { error: 'not_allowed' }, { error: 'invite_expired' },
  { error: 'verification_token_invalid' }, { error: 'verification_token_expired' }, { error: 'reset_token_invalid' },
  { error: 'email_delivery_unavailable' }, { error: 'rate_limited' }, { error: 'rate_limited', retryAfter: 30 },
  { error: 'rate_limited', retryAfter: 300 }, { error: 'unauthenticated' }, { error: 'unavailable' }, { error: 'network' },
  { error: 'bad_request', detail: 'password_too_short: min 12' }, { error: 'bad_request', detail: 'password_too_short' },
  { error: 'bad_request', detail: 'email' }, { error: 'bad_request', detail: 'x' }, { error: 'weird' }, { error: '' }, null,
]
for (const o of outs) same('nativeError ' + JSON.stringify(o), nativeErrorKey(o), nativeErrorMessage(o))
for (const s of [0, 'x', 30, 61, 600]) same('retryAfter ' + s, retryAfterKey(s), retryAfterMessage(s))

// CONTROL: an unknown key must be reported, not rendered as ''.
const before = failed
render({ key: 'auth.native_error.__control_missing__', params: {} })
if (failed === before + 1) { failed--; pass('CONTROL: a missing key fails') } else fail('CONTROL: a missing key fails', 'not detected')

if (failed) { console.error(`\n${failed} failure(s)`); process.exit(1) }
console.log('\nAll auth-i18n-keys checks passed.')
