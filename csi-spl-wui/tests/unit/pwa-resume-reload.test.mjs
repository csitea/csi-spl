// HUM-10 fb8d109f: a reopened phone app reloads into a new build and keeps
// the session (utils/build-watch.mjs resume rules, utils/session-recover.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { RESUME_AFTER_MS } from '../../src/utils/build-watch.mjs'
import { RETRY_DELAYS_MS, decide, isResume, pageBusy, retryDelay } from '../../src/utils/build-watch-rules.mjs'
import {
  RECOVER_DELAYS_MS, RECOVER_EVERY_MS, WAS_SIGNED_IN_KEY,
  markSignedIn, recoverDelay, reprobeOnReturn, unsettled, wasSignedIn,
} from '../../src/utils/session-recover.mjs'
import { signedOutLoginHref, signedOutLoginTarget } from '../../src/utils/signed-out-redirect.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const A = '0123456789abcdef0123456789abcdef01234567'
const B = 'fedcba9876543210fedcba9876543210fedcba98'

function el(props = {}) {
  return { getAttribute: () => null, tagName: 'INPUT', type: 'text', value: '', disabled: false, readOnly: false, isContentEditable: false, textContent: '', closest: () => null, getClientRects: () => [{}], ...props }
}
function doc({ fields = [], dialogs = [], pending = false, active = null } = {}) {
  return {
    activeElement: active,
    querySelectorAll: (sel) => (sel.includes('role=dialog') ? dialogs : fields),
    querySelector: (sel) => (sel === '[data-pending=true]' && pending ? {} : null),
  }
}
function memStore() {
  const m = new Map()
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

describe('resume: what counts as one', () => {
  it('hidden RESUME_AFTER_MS or more is a resume; less, or never hidden, is not', () => {
    const now = 10_000_000
    assert.equal(isResume(now - RESUME_AFTER_MS, now), true)
    assert.equal(isResume(now - 3_600_000, now), true)
    assert.equal(isResume(now - RESUME_AFTER_MS + 1, now), false)
    assert.equal(isResume(0, now), false)
  })
})

describe('resume: an empty focused field no longer holds the old build', () => {
  const box = el({ tagName: 'TEXTAREA' })
  it('CONTROL: without a resume the focused empty box is busy (HUM-27 keyboard)', () => {
    assert.equal(pageBusy(doc({ fields: [box], active: box })), true)
    assert.equal(decide({ running: A, live: B, busy: true }), 'prompt')
  })
  it('on a resume it is idle, so a newer build reloads', () => {
    const busy = pageBusy(doc({ fields: [box], active: box }), { resumed: true })
    assert.equal(busy, false)
    assert.equal(decide({ running: A, live: B, busy }), 'reload')
  })
  it('a resume still keeps a typed draft, an open dialog and a pending send', () => {
    const typed = el({ tagName: 'TEXTAREA', value: 'half a thought' })
    assert.equal(pageBusy(doc({ fields: [typed], active: typed }), { resumed: true }), true)
    assert.equal(pageBusy(doc({ dialogs: [el({ tagName: 'DIV' })] }), { resumed: true }), true)
    assert.equal(pageBusy(doc({ pending: true }), { resumed: true }), true)
  })
  it('the per-commit reload guard still holds on a resume (no loop)', () => {
    assert.equal(decide({ running: A, live: B, busy: false, guard: B }), 'prompt')
  })
})

describe('resume: a failed /build.json read is asked again', () => {
  it('retries on the listed delays, then gives up to the 5-minute tick', () => {
    RETRY_DELAYS_MS.forEach((ms, i) => assert.equal(retryDelay(i + 1), ms))
    assert.equal(retryDelay(0), -1)
    assert.equal(retryDelay(RETRY_DELAYS_MS.length + 1), -1)
    assert.ok(RETRY_DELAYS_MS.reduce((a, b) => a + b, 0) < 60_000)
  })
})

describe('session: an unanswered probe is asked again', () => {
  it('unknown and loading are unsettled; in and out are not', () => {
    assert.equal(unsettled('unknown'), true)
    assert.equal(unsettled('loading'), true)
    assert.equal(unsettled('in'), false)
    assert.equal(unsettled('out'), false)
  })
  it('backs off on the listed delays, then every RECOVER_EVERY_MS for good', () => {
    RECOVER_DELAYS_MS.forEach((ms, i) => assert.equal(recoverDelay(i), ms))
    assert.equal(recoverDelay(RECOVER_DELAYS_MS.length), RECOVER_EVERY_MS)
    assert.equal(recoverDelay(500), RECOVER_EVERY_MS)
    assert.equal(recoverDelay(-3), RECOVER_DELAYS_MS[0])
  })
  it('a return to the tab re-probes an unsettled session at once', () => {
    assert.equal(reprobeOnReturn({ state: 'unknown', hiddenMs: 0 }), true)
    assert.equal(reprobeOnReturn({ state: 'loading', hiddenMs: 0 }), true)
  })
  it('a signed-in session is re-checked only after a real resume', () => {
    assert.equal(reprobeOnReturn({ state: 'in', hiddenMs: RESUME_AFTER_MS }), true)
    assert.equal(reprobeOnReturn({ state: 'in', hiddenMs: 2_000 }), false)
    assert.equal(reprobeOnReturn({ state: 'out', hiddenMs: 3_600_000 }), false)
  })
})

describe('session ended: the sign-in page says so', () => {
  it('the marker is set while signed in and cleared by hand', () => {
    const s = memStore()
    assert.equal(wasSignedIn(s), false)
    markSignedIn(true, s)
    assert.equal(s.getItem(WAS_SIGNED_IN_KEY), '1')
    assert.equal(wasSignedIn(s), true)
    markSignedIn(false, s)
    assert.equal(wasSignedIn(s), false)
  })
  it('blocked storage reads as never signed in and never throws', () => {
    const bad = { getItem() { throw new Error('blocked') }, setItem() { throw new Error('blocked') }, removeItem() { throw new Error('blocked') } }
    assert.equal(wasSignedIn(bad), false)
    assert.doesNotThrow(() => markSignedIn(true, bad))
  })
  it('the redirect adds ended=1 only for a session that ended', () => {
    assert.deepEqual(signedOutLoginTarget('/t/abc', 'out', false, true), { path: '/login', query: { redirect: '/t/abc', ended: '1' } })
    assert.deepEqual(signedOutLoginTarget('/t/abc', 'out', false), { path: '/login', query: { redirect: '/t/abc' } })
    assert.equal(signedOutLoginTarget('/t/abc', 'unknown', false, true), null)
  })
  it('the hydrating hard redirect carries it too', () => {
    assert.equal(signedOutLoginHref('/login', '/t/abc', true), '/login?redirect=%2Ft%2Fabc&ended=1')
    assert.equal(signedOutLoginHref('/login', '/t/abc'), '/login?redirect=%2Ft%2Fabc')
    assert.equal(signedOutLoginHref('/login', '', true), '/login?ended=1')
    assert.equal(signedOutLoginHref('/login', ''), '/login')
  })
})

describe('wiring', () => {
  it('build-watch: a resume skips the gap and retries; online asks again', () => {
    const src = read('src/utils/build-watch-run.ts')
    for (const s of ['isResume(hiddenAt)', 'retryDelay(++failed)', "'online'", 'pageBusy(document, { resumed })']) assert.ok(src.includes(s), s)
  })
  it('session-recover: backoff, a return to the tab and online re-probe; live builds only', () => {
    const src = read('src/plugins/session-recover.client.ts')
    for (const s of ['recoverDelay(attempt)', 'reprobeOnReturn(', "'online'", "'visibilitychange'", 'useSpoolApi().mock', 'markSignedIn(true)']) assert.ok(src.includes(s), s)
  })
  it('a sign-out by hand clears the marker before the state flips', () => {
    const src = read('src/stores/session.ts')
    const logout = src.slice(src.indexOf('async function logout'))
    assert.ok(logout.indexOf('markSignedIn(false)') > 0 && logout.indexOf('markSignedIn(false)') < logout.indexOf("state.value = 'out'"))
  })
  it('the middleware passes the marker; the login page shows the message', () => {
    const mw = read('src/middleware/signed-out-redirect.global.ts')
    assert.equal(mw.split('wasSignedIn()').length - 1, 2)
    const login = read('src/pages/login.vue')
    assert.match(login, /data-test="session-ended"/)
    assert.match(login, /auth\.native_error\.unauthenticated/)
  })
})
