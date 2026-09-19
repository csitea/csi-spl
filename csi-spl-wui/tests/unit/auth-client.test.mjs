import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  authErrorMessage,
  authOrigin,
  createAuthClient,
  nativeErrorMessage,
  providerLabel,
  providerName,
  retryAfterMessage,
  safeRedirect,
  startHref,
} from '../../src/utils/auth-client.mjs'

function stub(status, body, { throws = false, badJson = false, headers = {} } = {}) {
  const calls = []
  const fn = async (url, opts) => {
    calls.push({ url, opts })
    if (throws) throw new Error('network')
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (k) => headers[String(k).toLowerCase()] ?? null },
      json: async () => {
        if (badJson) throw new Error('bad json')
        return body
      },
    }
  }
  return { fn, calls }
}

describe('auth-v1 helpers (spec 010)', () => {
  it('maps every §2 code and falls back for unknown ones', () => {
    for (const c of ['cancelled', 'invalid_state', 'exchange_failed', 'email_unverified', 'not_allowed', 'unavailable']) {
      assert.notEqual(authErrorMessage(c), 'Sign-in failed.', c)
    }
    assert.equal(authErrorMessage('weird'), 'Sign-in failed.')
    assert.equal(authErrorMessage(''), '')
  })

  it('labels providers', () => {
    assert.equal(providerLabel('google'), 'Continue with Google')
    assert.equal(providerLabel('facebook'), 'Continue with Facebook')
  })

  it('keeps redirects same-site', () => {
    assert.equal(safeRedirect('/t/abc?x=1'), '/t/abc?x=1')
    for (const bad of ['https://evil.example', '//evil.example', '/\\evil', 'javascript:alert(1)', '', '/login?x']) {
      assert.equal(safeRedirect(bad), '/', bad)
    }
  })

  it('builds a plain start link with redirect and an optional DNS-label tenant', () => {
    assert.equal(startHref('google', '/t/abc', 't1'), '/api/v1/auth/google/start?redirect=%2Ft%2Fabc&tenant=t1')
    assert.equal(startHref('facebook', 'https://x', 'Not_A_Label'), '/api/v1/auth/facebook/start?redirect=%2F')
  })
})

describe('auth client', () => {
  it('loadProviders tells auth-off apart from an unreachable registry', async () => {
    const load = (st, body, o) => createAuthClient({ fetchFn: stub(st, body, o).fn }).loadProviders()
    assert.deepEqual(await load(200, { providers: ['google'] }), { status: 'ok', reason: '', providers: ['google'], native: false })
    assert.deepEqual(await load(200, { providers: [] }), { status: 'ok', reason: '', providers: [], native: false })
    assert.deepEqual(await load(503, {}), { status: 'unavailable', reason: '503', providers: [], native: false })
    assert.deepEqual(await load(0, {}, { throws: true }), { status: 'unavailable', reason: 'network', providers: [], native: false })
    assert.deepEqual(await load(200, {}, { badJson: true }), { status: 'unavailable', reason: 'bad_json', providers: [], native: false })
    assert.equal(providerName('xai'), 'xAI')
    assert.equal(providerName('github'), 'Github')
  })

  it('providers: list in order, [] on off / error / network', async () => {
    const ok = stub(200, { providers: ['google', 'facebook'] })
    assert.deepEqual(await createAuthClient({ fetchFn: ok.fn }).providers(), ['google', 'facebook'])
    assert.equal(ok.calls[0].url, '/api/v1/auth/providers')
    assert.equal(ok.calls[0].opts.credentials, 'include')
    assert.deepEqual(await createAuthClient({ fetchFn: stub(200, { providers: [] }).fn }).providers(), [])
    assert.deepEqual(await createAuthClient({ fetchFn: stub(404, {}).fn }).providers(), [])
    assert.deepEqual(await createAuthClient({ fetchFn: stub(0, {}, { throws: true }).fn }).providers(), [])
  })

  it('session: 200 in, 401 out, everything else unknown', async () => {
    const claims = { v: 1, p: 'google', hum: 'HUM-1' }
    assert.deepEqual(await createAuthClient({ fetchFn: stub(200, claims).fn }).session(), { state: 'in', claims })
    assert.equal((await createAuthClient({ fetchFn: stub(401, {}).fn }).session()).state, 'out')
    assert.equal((await createAuthClient({ fetchFn: stub(503, {}).fn }).session()).state, 'unknown')
    assert.equal((await createAuthClient({ fetchFn: stub(0, {}, { throws: true }).fn }).session()).state, 'unknown')
    assert.equal((await createAuthClient({ fetchFn: stub(200, {}, { badJson: true }).fn }).session()).state, 'unknown')
  })

  it('logout POSTs and accepts 204', async () => {
    const s = stub(204, null)
    assert.equal(await createAuthClient({ fetchFn: s.fn }).logout(), true)
    assert.equal(s.calls[0].opts.method, 'POST')
    assert.equal(s.calls[0].url, '/api/v1/auth/logout')
  })
})

describe('cross-origin auth base (A7: the WUI host is not the hub host)', () => {
  const API = 'https://api.example.com'

  it('authOrigin keeps a bare http(s) origin and refuses the rest as same-origin', () => {
    assert.equal(authOrigin(API + '/'), API)
    assert.equal(authOrigin('http://localhost:58080'), 'http://localhost:58080')
    for (const bad of ['', null, 'api.example', 'https://x/api', 'javascript:alert(1)', '//evil.example', 'https://a b']) {
      assert.equal(authOrigin(bad), '', String(bad))
    }
  })

  it('start links go to the hub origin, the redirect stays a WUI path', () => {
    assert.equal(startHref('google', '/t/abc', 't1', API), `${API}/api/v1/auth/google/start?redirect=%2Ft%2Fabc&tenant=t1`)
    assert.equal(startHref('google', 'https://evil.example', '', API + '/'), `${API}/api/v1/auth/google/start?redirect=%2F`)
    assert.equal(startHref('google', '/', '', 'https://x/p'), '/api/v1/auth/google/start?redirect=%2F')
  })

  it('every call (probe, providers, native, logout) hits the base with credentials', async () => {
    const s = stub(200, { providers: [] })
    const c = createAuthClient({ fetchFn: s.fn, base: API })
    await c.loadProviders()
    await c.session()
    await c.login({ email: 'a@b.c', password: 'pw' })
    await c.verifyEmail('t')
    await c.resetPassword({ token: 't', password: 'p' })
    await c.logout()
    assert.deepEqual(s.calls.map((x) => x.url), [
      `${API}/api/v1/auth/providers`, `${API}/api/v1/auth/session`, `${API}/api/v1/auth/login`,
      `${API}/api/v1/auth/email/verify`, `${API}/api/v1/auth/password/reset`, `${API}/api/v1/auth/logout`,
    ])
    for (const x of s.calls) assert.equal(x.opts.credentials, 'include', x.url)
  })

  it('no WUI file builds a client or a start link without the auth base', () => {
    const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
    for (const f of ['src/stores/session.ts', 'src/components/NativeAuthForm.vue', 'src/components/ChangePasswordForm.vue',
      'src/components/SocialAuthButtons.vue', 'src/pages/verify-email.vue', 'src/pages/reset-password.vue']) {
      const src = readFileSync(join(WUI, f), 'utf8')
      assert.equal(/createAuthClient\(/.test(src), false, `${f} must use useAuthClient()`)
      assert.ok(src.includes('useAuthClient'), f)
    }
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    assert.ok(/process\.env\.NUXT_PUBLIC_AUTH_BASE/.test(cfg) && /\n\s+authBase,\n/.test(cfg), 'runtime key public.authBase')
  })
})

describe('native-auth-v1 client (spec 015)', () => {
  const client = (st, body, o) => {
    const s = stub(st, body, o)
    return { c: createAuthClient({ fetchFn: s.fn }), calls: s.calls }
  }

  it('loadProviders keeps the native flag, only for a literal true', async () => {
    assert.equal((await client(200, { providers: [], native: true }).c.loadProviders()).native, true)
    assert.deepEqual(await client(200, { providers: ['google'], native: true }).c.loadProviders(),
      { status: 'ok', reason: '', providers: ['google'], native: true })
    assert.equal((await client(200, { providers: [], native: 'true' }).c.loadProviders()).native, false)
    assert.equal((await client(200, { providers: [] }).c.loadProviders()).native, false)
  })

  it('every route POSTs JSON to its §2 path', async () => {
    const cases = [
      [(c) => c.register({ email: 'a@b.c', password: 'pw', name: 'N' }), '/register', { email: 'a@b.c', password: 'pw', name: 'N' }],
      [(c) => c.register({ email: 'a@b.c', password: 'pw' }), '/register', { email: 'a@b.c', password: 'pw' }],
      [(c) => c.verifyEmail('ab12'), '/email/verify', { token: 'ab12' }],
      [(c) => c.login({ email: 'a@b.c', password: 'pw', tenant: 't1', redirect: '/t/x' }), '/login', { email: 'a@b.c', password: 'pw', redirect: '/t/x', tenant: 't1' }],
      [(c) => c.login({ email: 'a@b.c', password: 'pw', tenant: 'Bad_T', redirect: 'https://evil' }), '/login', { email: 'a@b.c', password: 'pw', redirect: '/' }],
      [(c) => c.forgotPassword('a@b.c'), '/password/forgot', { email: 'a@b.c' }],
      [(c) => c.resetPassword({ token: 'ab12', password: 'pw2' }), '/password/reset', { token: 'ab12', password: 'pw2' }],
      [(c) => c.changePassword({ current: 'pw', next: 'pw2' }), '/password/change', { current_password: 'pw', new_password: 'pw2' }],
    ]
    for (const [fn, path, body] of cases) {
      const { c, calls } = client(204, null)
      const out = await fn(c)
      assert.equal(out.ok, true, path)
      assert.equal(calls[0].url, `/api/v1/auth${path}`)
      assert.equal(calls[0].opts.method, 'POST')
      assert.equal(calls[0].opts.credentials, 'include')
      assert.equal(calls[0].opts.headers['content-type'], 'application/json')
      assert.deepEqual(JSON.parse(calls[0].opts.body), body, path)
    }
  })

  it('success carries the body (202 register, 200 login claims)', async () => {
    const reg = await client(202, { status: 'verification_required', debug_token: 'tok' }).c.register({ email: 'a@b.c', password: 'pw' })
    assert.deepEqual(reg, { ok: true, status: 202, data: { status: 'verification_required', debug_token: 'tok' }, error: '', detail: '', retryAfter: 0 })
    const li = await client(200, { p: 'password', sub: 'a@b.c', redirect: '/' }).c.login({ email: 'a@b.c', password: 'pw' })
    assert.equal(li.ok, true)
    assert.equal(li.data.p, 'password')
  })

  it('failures surface the envelope token, detail and Retry-After; never throw', async () => {
    const bad = await client(401, { error: 'invalid_credentials', detail: '' }).c.login({ email: 'a', password: 'b' })
    assert.equal(bad.ok, false)
    assert.equal(bad.error, 'invalid_credentials')
    const short = await client(400, { error: 'bad_request', detail: 'password_too_short: min 12' }).c.register({ email: 'a', password: 'b' })
    assert.equal(short.detail, 'password_too_short: min 12')
    const rl = await client(429, { error: 'rate_limited' }, { headers: { 'retry-after': '120' } }).c.login({ email: 'a', password: 'b' })
    assert.equal(rl.error, 'rate_limited')
    assert.equal(rl.retryAfter, 120)
    const rlBare = await client(429, null, { badJson: true }).c.forgotPassword('a')
    assert.equal(rlBare.error, 'rate_limited')
    assert.equal(rlBare.retryAfter, 0)
    assert.equal((await client(502, null, { badJson: true }).c.verifyEmail('t')).error, 'unavailable')
    assert.equal((await client(0, null, { throws: true }).c.resetPassword({ token: 't', password: 'p' })).error, 'network')
  })

  it('§4 copy for every token, and 429 with Retry-After in minutes', () => {
    const copy = {
      invalid_credentials: 'Email or password is wrong.',
      email_unverified: 'Confirm your email first — we can send the link again.',
      not_allowed: 'This account has no access here yet — ask the owner for an invite.',
      verification_token_invalid: 'That link is not valid any more.',
      verification_token_expired: 'That link expired — we can send a new one.',
      reset_token_invalid: 'That reset link is not valid any more — ask for a new one.',
      email_delivery_unavailable: 'We cannot send email right now — try again later.',
    }
    for (const [k, v] of Object.entries(copy)) assert.equal(nativeErrorMessage({ error: k }), v, k)
    assert.equal(nativeErrorMessage({ error: 'rate_limited' }), 'Too many attempts — try again later.')
    assert.equal(nativeErrorMessage({ error: 'rate_limited', retryAfter: 300 }), 'Too many attempts — try again in 5 minutes.')
    assert.equal(retryAfterMessage(61), 'Too many attempts — try again in 2 minutes.')
    assert.equal(retryAfterMessage(30), 'Too many attempts — try again in a minute.')
    assert.equal(retryAfterMessage('x'), 'Too many attempts — try again later.')
    assert.equal(nativeErrorMessage({ error: 'bad_request', detail: 'password_too_short: min 12' }),
      'That password is too short — use at least 12 characters.')
    assert.equal(nativeErrorMessage({ error: 'bad_request', detail: 'password_too_short' }), 'That password is too short.')
    assert.equal(nativeErrorMessage({ error: 'bad_request', detail: 'email' }), 'Enter a valid email address.')
    assert.equal(nativeErrorMessage({ error: 'weird' }), 'Something went wrong — try again.')
    assert.equal(nativeErrorMessage({ error: '' }), '')
    assert.equal(nativeErrorMessage(null), '')
  })
})

describe('Hosting rewrite (spec 010 T016)', () => {
  it('/api/v1/auth/** goes to Cloud Run before the SPA fallback, which stays last', () => {
    const here = dirname(fileURLToPath(import.meta.url))
    const fb = JSON.parse(readFileSync(join(here, '../../firebase.json'), 'utf8'))
    const rw = fb.hosting.rewrites
    const i = rw.findIndex((r) => r.source === '/api/v1/auth/**')
    assert.ok(i >= 0, 'auth rewrite present')
    assert.ok(rw[i].run && rw[i].run.serviceId, 'rewrite targets Cloud Run')
    assert.equal(rw[rw.length - 1].source, '**')
    assert.ok(i < rw.length - 1)
  })
})

describe('SocialAuthButtons (auth-v1 §4, donor component)', () => {
  const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
  const src = readFileSync(join(WUI, 'src/components/SocialAuthButtons.vue'), 'utf8')

  it('is registry-driven plain links, no IdP SDK', () => {
    assert.ok(src.includes('loadProviders()'))
    assert.ok(src.includes(':href="startHref(p, redirect, tenant, authBase)"'))
    assert.equal(/<script[^>]+src=|accounts\.google\.com|connect\.facebook\.net/.test(src), false)
  })

  it('an empty social list with native sign-in on is not "unavailable yet"', () => {
    assert.ok(src.includes(`v-if="status === 'ok' && !providers.length && !native"`))
    assert.ok(src.includes('native.value = out.native === true'))
  })

  it('always publishes the registry state for monitors', () => {
    assert.ok(src.includes(':data-social-auth-status="status"'))
    assert.ok(src.includes(':data-social-auth-count="providers.length"'))
  })

  it('/login renders it, with the settled redirect and tenant', () => {
    const login = readFileSync(join(WUI, 'src/pages/login.vue'), 'utf8')
    assert.ok(login.includes('<SocialAuthButtons class="idp" :redirect="redirect" :tenant="tenant" />'))
  })
})

describe('native sign-in pages (spec 015 A4, native-auth-v1 §2–§4)', () => {
  const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
  const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

  for (const [page, call] of [['src/pages/verify-email.vue', '.verifyEmail('], ['src/pages/reset-password.vue', '.resetPassword(']]) {
    it(`${page}: settled token, POSTed, then dropped from the URL`, () => {
      const src = read(page)
      assert.ok(src.includes("useSettledQuery('token')"), 'reads token via useSettledQuery')
      assert.equal(/route\.query\.token\b(?!\s*!==)/.test(src), false, 'no raw route.query.token read')
      assert.ok(src.includes(call), call)
      assert.ok(src.includes('const { token: _drop, ...rest } = route.query'), 'drops token')
      assert.ok(src.includes('router.replace({ query: rest })'), 'replaceState')
      assert.ok(src.indexOf(call) < src.indexOf('router.replace({ query: rest })'), 'drop after the POST')
      assert.ok(src.includes("layout: 'login'"))
    })
  }

  it('/login renders the native form (auth off → invisible) and change-password for p:password only', () => {
    const login = read('src/pages/login.vue')
    assert.ok(login.includes('<NativeAuthForm v-if="session.state !== \'in\'" :redirect="redirect" :tenant="tenant" />'))
    assert.ok(login.includes("session.claims?.p === 'password'"))
    assert.ok(login.includes('<ChangePasswordForm'))
    const form = read('src/components/NativeAuthForm.vue')
    assert.ok(form.includes("status.value = out.native ? 'on' : 'off'"), 'gated on providers.native')
    assert.ok(form.includes('v-if="status === \'on\'"'))
    assert.ok(form.includes(':data-native-auth="status"'))
    for (const fn of ['auth.login(', 'auth.register(', 'auth.forgotPassword(', 'nativeErrorMessage(']) assert.ok(form.includes(fn), fn)
    const change = read('src/components/ChangePasswordForm.vue')
    assert.ok(change.includes('auth.changePassword('))
    assert.ok(change.includes('session.signedOut()'), '204 clears the cookie')
  })
})
