// P3-03 (perf audit round 3): the session probe leaves from the document head
// and the app adopts it instead of sending its own. This suite runs the exact
// inline script nuxt.config embeds against a fake window, then hands the
// parked fetch through takeParkedSession and the auth client's session(),
// plus static guards on the wiring.
// Run: node tests/unit/early-session-script.test.mjs
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'
import { buildEarlySessionScript, EARLY_SESSION_KEY } from '../../src/utils/early-session-script.mjs'
import { takeParkedSession } from '../../src/utils/early-session.mjs'
import { createAuthClient, sessionProbeUrl } from '../../src/utils/auth-client.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }
const eq = (got, want, n) => (got === want ? pass(n) : fail(n, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`))

const BASE = 'https://api.example.com'
const URL_ = sessionProbeUrl(BASE)
eq(URL_, 'https://api.example.com/api/v1/auth/session', 'sessionProbeUrl joins the auth origin and the §4 path')
eq(sessionProbeUrl(''), '/api/v1/auth/session', "sessionProbeUrl('') is same-origin (lde)")
eq(sessionProbeUrl('javascript:alert(1)'), '/api/v1/auth/session', 'a non-origin base is refused, as authOrigin does')

function run(script, fetchImpl) {
  const calls = []
  const win = {}
  win.window = win
  win.fetch = fetchImpl ? (u, init) => { calls.push({ u, init }); return fetchImpl(u, init) } : undefined
  vm.runInNewContext(script, win)
  return { win, calls }
}

const res = (status, body) => ({ status, json: async () => body })

{
  const script = buildEarlySessionScript({ authBase: BASE })
  const { win, calls } = run(script, async () => res(401))
  eq(calls.length, 1, 'the head script sends one probe')
  eq(calls[0].u, URL_, 'to the auth client\'s address')
  eq(calls[0].init.credentials, 'include', 'with the cookie')
  eq(calls[0].init.cache, 'no-store', 'never from the HTTP cache')
  eq(JSON.stringify(calls[0].init.headers), '{"accept":"application/json"}', 'and only a simple header (no CORS preflight)')
  eq(win[EARLY_SESSION_KEY].u, URL_, 'parks the address with the promise')

  const p = takeParkedSession(win, URL_)
  eq(typeof (p && p.then), 'function', 'takeParkedSession hands over the parked fetch')
  eq(takeParkedSession(win, URL_), null, 'once: a Response body is read only once')
}

{
  const { win } = run(buildEarlySessionScript({ authBase: BASE }), async () => res(401))
  eq(takeParkedSession(win, 'https://other.example.com/api/v1/auth/session'), null, 'another address is not adopted')
  eq(win[EARLY_SESSION_KEY], undefined, 'and is dropped all the same')
}

{
  const { win, calls } = run(buildEarlySessionScript({ authBase: BASE }), undefined)
  eq(calls.length, 0, 'no fetch in the browser: the script does nothing')
  eq(takeParkedSession(win, URL_), null, 'and nothing is parked')
}

eq(takeParkedSession(undefined, URL_), null, 'no window: null')

// session(pending): the parked answer decides, with no second request.
async function session(pending, ownAnswer) {
  let own = 0
  const auth = createAuthClient({ base: BASE, fetchFn: async () => { own++; return ownAnswer } })
  const out = await auth.session(pending)
  return { out, own }
}
{
  let r = await session(Promise.resolve(res(401)), res(200, {}))
  eq(r.out.state, 'out', 'a parked 401 reads signed out')
  eq(r.own, 0, 'without asking again')
  r = await session(Promise.resolve(res(200, { sub: 'h1' })), res(401))
  eq(r.out.state, 'in', 'a parked 200 reads signed in')
  eq(r.out.claims && r.out.claims.sub, 'h1', 'with its claims')
  eq(r.own, 0, 'without asking again (200)')
  r = await session(Promise.resolve(res(503)), res(200, {}))
  eq(r.out.state, 'unknown', 'a parked 5xx is unknown, as the app\'s own probe reads it')
  const rejected = Promise.reject(new TypeError('Failed to fetch'))
  rejected.catch(() => {})
  r = await session(rejected, res(200, { sub: 'h2' }))
  eq(r.own, 1, 'a parked fetch that failed is sent again')
  eq(r.out.state, 'in', 'and the fresh answer decides')
  r = await session(undefined, res(401))
  eq(r.own, 1, 'no parked fetch: the client probes itself')
}

// Wiring guards.
const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
eq(/buildEarlySessionScript\(\{ authBase \}\)/.test(cfg), true, 'nuxt.config inlines the script with the build\'s auth base')
eq(/wuiUseMock\(\) === "0"\s*\?\s*\[[^\]]*innerHTML: buildEarlySessionScript/.test(cfg), true, 'only in a non-mock build')
const plugin = readFileSync(join(WUI, 'src/plugins/0.boot-early.client.ts'), 'utf8')
eq(/takeParkedSession\(window, sessionProbeUrl\(useAuthBase\(\)\)\)/.test(plugin), true, 'the boot plugin adopts the parked probe for its own address')

if (failed) { console.log(`\n${failed} failed`); process.exit(1) }
console.log('\nall passed')
