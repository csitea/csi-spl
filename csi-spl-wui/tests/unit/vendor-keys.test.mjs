// Spec 159 T7 on spec 127 W1 (SPL-3745): the Agent keys page's reading of
// the hub's write-only vendor key routes, and the mock hub the e2e drives.
// The browser half (biz_owner sees, developer does not, exhausted retry,
// the key cleared after save) is tests/e2e/agent-keys.test.mjs.
// Run: node tests/unit/vendor-keys.test.mjs
import {
  VENDOR_KEY_KINDS,
  VENDOR_KEYS_MOCK_AVAILABLE,
  VENDOR_KEYS_MOCK_KEY,
  VENDOR_KEYS_MOCK_UNCONFIRMED_KEY,
  VENDOR_KEYS_PERM,
  mockDeleteVendorKey,
  mockPutVendorKey,
  mockRetryVendorKey,
  mockVendorKeys,
  normalizeVendorKeys,
  vendorKeyPutBody,
  vendorKeyState,
  vendorKeysErrorKey,
} from '../../src/utils/vendor-keys.mjs'
import { MOCK_ME_KEY } from '../../src/utils/act-as-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const raises = (fn, status, token) => { try { fn(); return false } catch (e) { return e.status === status && e.token === token } }
const memStore = (seed = {}) => {
  const m = new Map(Object.entries(seed))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), dump: () => [...m.values()].join('\n') }
}
const FAKE = 'sk-test-0000'

console.log('vendor-keys')
ok('five kinds, in page order', VENDOR_KEY_KINDS.join(',') === 'claude,grok,agy,mistral,qwen')
ok('the permission is the hub\'s vendor_keys.manage', VENDOR_KEYS_PERM === 'vendor_keys.manage')

/* the GET body of spec 127 4.3 as the hub answers it (T1) */
const v = normalizeVendorKeys({
  confirmed: true,
  kinds: [
    { kind: 'claude', available: true, set: true, last4: '0000', set_by: 'HUM-1', set_at: '2026-10-27T07:00:00Z' },
    { kind: 'qwen', available: true, set: true, last4: 'abcd', base_url: 'https://llm.example.com/v1', exhausted: true },
    { kind: 'grok', available: false, set: false },
  ],
})
ok('one row per kind, in page order, whatever the body lists', v.rows.map((r) => r.kind).join() === VENDOR_KEY_KINDS.join())
ok('a kind the body leaves out reads as not available', vendorKeyState(v.rows.find((r) => r.kind === 'agy')) === 'not_available')
ok('states: set, exhausted, not available', [vendorKeyState(v.rows[0]), vendorKeyState(v.rows[4]), vendorKeyState(v.rows[1])].join() === 'set,exhausted,not_available')
ok('an available kind with no key is not set', vendorKeyState({ available: true, set: false, exhausted: true }) === 'not_set')
ok('confirmed defaults to true; false is kept', normalizeVendorKeys({}).confirmed === true && normalizeVendorKeys({ confirmed: false }).confirmed === false)
ok('no field of the body other than the listed ones reaches a row', !('key' in normalizeVendorKeys({ kinds: [{ kind: 'claude', key: FAKE }] }).rows[0]))

/* the PUT body: the hub's bad_key and bad_base_url, checked first */
ok('a key is trimmed at its ends', vendorKeyPutBody('claude', ` ${FAKE} `).body?.key === FAKE)
ok('CONTROL a key with a space inside is refused', vendorKeyPutBody('claude', 'sk-test 0000').error === 'tenant_settings.agent_keys.error.bad_key')
ok('CONTROL an empty key is refused', Boolean(vendorKeyPutBody('claude', '   ').error))
ok('non-qwen sends no base_url', !('base_url' in (vendorKeyPutBody('claude', FAKE, 'https://x.example.com').body || {})))
ok('qwen sends its https base_url', vendorKeyPutBody('qwen', FAKE, 'https://llm.example.com/v1').body?.base_url === 'https://llm.example.com/v1')
ok('CONTROL qwen over http is refused', vendorKeyPutBody('qwen', FAKE, 'http://llm.example.com').error === 'tenant_settings.agent_keys.error.bad_base_url')
ok('known refusals have their own line; others are generic', vendorKeysErrorKey({ token: 'admin_unconfirmed' }).endsWith('.admin_unconfirmed') &&
  vendorKeysErrorKey({ token: 'teapot' }).endsWith('.generic') && vendorKeysErrorKey(null).endsWith('.generic'))

/* the mock hub: as the routes answer, and it keeps last4 only */
const st = memStore()
ok('mock: only the kinds the hub takes today are available', mockVendorKeys(st).kinds.filter((k) => k.available).map((k) => k.kind).join() === VENDOR_KEYS_MOCK_AVAILABLE.join())
mockPutVendorKey('claude', { key: FAKE }, st)
const after = mockVendorKeys(st).kinds.find((k) => k.kind === 'claude')
ok('mock: PUT sets the row with last4', after.set && after.last4 === '0000')
ok('mock: the stored rows never hold the key', !st.dump().includes(FAKE) && st.getItem(VENDOR_KEYS_MOCK_KEY).includes('0000'))
ok('CONTROL mock: a kind waiting for its terms is 409 kind_not_available', raises(() => mockPutVendorKey('grok', { key: FAKE }, st), 409, 'kind_not_available'))
ok('CONTROL mock: qwen without base_url is 422 bad_base_url', raises(() => mockPutVendorKey('qwen', { key: FAKE }, st), 422, 'bad_base_url'))
st.setItem(VENDOR_KEYS_MOCK_KEY, JSON.stringify({ claude: { last4: '0000', exhausted: true } }))
ok('mock: an exhausted key reads exhausted', mockVendorKeys(st).kinds[0].exhausted === true)
mockRetryVendorKey('claude', st)
ok('mock: retry clears exhausted, keeps the key', mockVendorKeys(st).kinds[0].exhausted === false && mockVendorKeys(st).kinds[0].set)
st.setItem(VENDOR_KEYS_MOCK_UNCONFIRMED_KEY, '1')
ok('mock: an unconfirmed manager reads, confirmed false', mockVendorKeys(st).confirmed === false)
ok('CONTROL mock: an unconfirmed manager cannot write (403 admin_unconfirmed)', raises(() => mockDeleteVendorKey('claude', st), 403, 'admin_unconfirmed'))
st.removeItem(VENDOR_KEYS_MOCK_UNCONFIRMED_KEY)
mockDeleteVendorKey('claude', st)
ok('mock: DELETE leaves the row not set', mockVendorKeys(st).kinds[0].set === false)
st.setItem(MOCK_ME_KEY, JSON.stringify({ role: 'developer', permissions: ['topics.read'] }))
ok('CONTROL mock: a role without vendor_keys.manage is 403', raises(() => mockVendorKeys(st), 403, 'forbidden'))

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll vendor-keys checks passed.')
