// SPL-4624: the head script that hides a stale /login before the first paint.
// This runs the exact inline script nuxt.config embeds against a fake window.
// Run: node tests/unit/stale-login-hide-script.test.mjs
import vm from 'node:vm'
import { buildStaleLoginHideScript, STALE_LOGIN_HIDE_MAX_MS } from '../../src/utils/stale-login-hide-script.mjs'
import { WAS_SIGNED_IN_KEY } from '../../src/utils/session-recover.mjs'

let failed = 0
const eq = (got, want, n) => {
  if (got === want) return console.log('  OK  ', n)
  failed++
  console.log('  FAIL', n + ':', `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
}

function run({ type = 'back_forward', phone = true, path = '/login', hint = '1' } = {}) {
  const style = { visibility: '' }
  const timers = []
  vm.runInNewContext(buildStaleLoginHideScript(), {
    performance: { getEntriesByType: () => [{ type }] },
    matchMedia: () => ({ matches: phone }),
    location: { pathname: path },
    localStorage: { getItem: (k) => (k === WAS_SIGNED_IN_KEY ? hint : null) },
    document: { documentElement: { style } },
    setTimeout: (f, ms) => timers.push({ f, ms }),
  })
  return { style, timers }
}

eq(run().style.visibility, 'hidden', 'a Back reload of /login on a phone with a session is hidden')
eq(run({ path: '/fi/login/' }).style.visibility, 'hidden', 'a locale prefix is the same page')

const hidden = run()
eq(hidden.timers[0].ms, STALE_LOGIN_HIDE_MAX_MS, 'the failsafe timer is armed')
hidden.timers[0].f()
eq(hidden.style.visibility, '', 'the timer shows the page if the guard never comes')

for (const o of [{ type: 'navigate' }, { type: 'reload' }, { phone: false }, { path: '/' }, { path: '/login-help' }, { hint: null }]) {
  const r = run(o)
  eq(r.style.visibility + r.timers.length, '0', `paints as usual: ${JSON.stringify(o)}`)
}

if (failed) process.exit(1)
