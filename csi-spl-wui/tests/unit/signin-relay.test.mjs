// Spec 181 row B11: the web-UI sign-in relay's reading of the hub's
// /v1/signin-relay routes (components/SigninRelayPanel.vue), and the mock
// hub. The hub half (switch off -> 403, the input in no table or log) is
// csi-spl-api internal/hub/signin_relay_test.go.
// Run: node tests/unit/signin-relay.test.mjs
import {
  SIGNIN_RELAY_KINDS,
  SIGNIN_RELAY_MOCK_KINDS_KEY,
  mockSigninRelay,
  normalizeSigninRelay,
  signinInputOK,
  signinRelayErrorKey,
  signinSafeUrl,
} from '../../src/utils/signin-relay.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const raises = (fn, status, token) => { try { fn(); return false } catch (e) { return e.status === status && e.token === token } }
const memStore = (seed = {}) => {
  const m = new Map(Object.entries(seed))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) }
}
const INPUT = 'relay-input-0000-fake'

console.log('signin-relay')
ok('the kinds with a subscription login: claude, grok, mistral (159 4.2)', SIGNIN_RELAY_KINDS.join() === 'claude,grok,mistral')

ok('one line of text is an input', signinInputOK(INPUT))
ok('CONTROL an empty input is refused', !signinInputOK(''))
ok('CONTROL two lines are refused (the VM presses Enter itself)', !signinInputOK('a\nb'))
ok('CONTROL over 512 bytes is refused', !signinInputOK('x'.repeat(513)) && signinInputOK('x'.repeat(512)))

ok('an https URL becomes a link', signinSafeUrl('https://example.com/oauth?a=1') === 'https://example.com/oauth?a=1')
ok('CONTROL a javascript: URL never becomes a link', signinSafeUrl('javascript:alert(1)') === '')
ok('CONTROL an http URL never becomes a link', signinSafeUrl('http://example.com/') === '')
ok('a view with a bad URL keeps no URL', normalizeSigninRelay({ relay: 'r', state: 'url', url: 'data:text/html,x' }).url === '')
ok('a body with no state reads as failed', normalizeSigninRelay({}).state === 'failed')

ok('known refusals have their own line', signinRelayErrorKey({ token: 'signin_relay_off' }).endsWith('.error.signin_relay_off') &&
  signinRelayErrorKey({ token: 'no_private_vm' }).endsWith('.error.no_private_vm'))
ok('others are generic', signinRelayErrorKey({ token: 'internal' }).endsWith('.error.generic') && signinRelayErrorKey(null).endsWith('.error.generic'))

/* the mock hub: off as the hub ships it; on when the store names the kind */
ok('mock: switch off -> 403 signin_relay_off', raises(() => mockSigninRelay('start', null, { kind: 'claude' }, memStore()), 403, 'signin_relay_off'))
const on = memStore({ [SIGNIN_RELAY_MOCK_KINDS_KEY]: 'claude' })
const started = mockSigninRelay('start', null, { kind: 'claude' }, on)
ok('mock: switch on -> started', started.state === 'starting' && started.relay !== '')
const got = mockSigninRelay('get', started.relay, null, on)
ok('mock: the VM shows its vendor URL', got.state === 'url' && signinSafeUrl(got.url) !== '')
ok('mock: a two-line input -> 400 bad_input', raises(() => mockSigninRelay('input', started.relay, { input: 'a\nb' }, on), 400, 'bad_input'))
mockSigninRelay('input', started.relay, { input: INPUT }, on)
const after = mockSigninRelay('get', started.relay, null, on)
ok('mock: after the input, signed in', after.state === 'signed_in')
ok('mock: the input is kept nowhere in the relay', !JSON.stringify(after).includes(INPUT))
ok('mock: an unknown relay -> 404', raises(() => mockSigninRelay('get', 'nope', null, on), 404, 'not_found'))

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll signin-relay checks passed.')
