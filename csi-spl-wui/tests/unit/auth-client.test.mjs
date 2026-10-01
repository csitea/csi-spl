import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  authErrorMessage,
  authOrigin,
  createAuthClient,
  hintedProvider,
  loginHintOf,
  nativeErrorMessage,
  providerLabel,
  providerName,
  retryAfterMessage,
  safeRedirect,
  startHref,
} from '../../src/utils/auth-client.mjs'
import { hasProtocol } from 'ufo'

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
    for (const bad of ['https://evil.example', '//evil.example', '/\\evil', 'javascript:alert(1)', '', '/login?x',
      '/fi/login', '/he/login?x', '/sv/login/', '/FI/login#a']) {
      assert.equal(safeRedirect(bad), '/', bad)
    }
    // a locale-prefixed page that merely starts with "login" is a real page
    assert.equal(safeRedirect('/fi/loginx'), '/fi/loginx')
    assert.equal(safeRedirect('/fi/t/abc'), '/fi/t/abc')
  })

  it('CLE-34987: a control character or backslash anywhere cannot turn the redirect into another host', () => {
    // the URL parser drops TAB/CR/LF and reads a backslash as '/': each of these
    // was "//evil.example" to the browser, and ufo (NuxtLink) called it external
    const bad = ['/\t/evil.example', '/\n/evil.example', '/\r/evil.example', '/\t\\evil.example',
      '/x/\\..\\', '/\u0000/evil.example', '/\u007f/x', '/\u001f/evil.example']
    for (const b of bad) assert.equal(safeRedirect(b), '/', JSON.stringify(b))
    // every one-control-char splice into "//evil.example" stays on this origin
    const splice = [...Array(0x21).keys(), 0x7f, 0xa0, 0x2028, 0x3000, 0xfeff]
    for (const c of splice) {
      for (const probe of [`/${String.fromCharCode(c)}/evil.example`, `${String.fromCharCode(c)}//evil.example`]) {
        const out = safeRedirect(probe)
        assert.equal(hasProtocol(out, { acceptRelative: true }), false, JSON.stringify(probe))
        assert.equal(new URL(out, 'https://wui.example').host, 'wui.example', JSON.stringify(probe))
      }
    }
    // a percent-encoded tab is data in a path, not a separator: kept as a real page
    assert.equal(safeRedirect('/t/%09x'), '/t/%09x')
    assert.equal(safeRedirect('/channel/c1?thread=m1#x'), '/channel/c1?thread=m1#x')
  })

  it('builds a plain start link with redirect and an optional DNS-label tenant', () => {
    assert.equal(startHref('google', '/t/abc', 't1'), '/api/v1/auth/google/start?redirect=%2Ft%2Fabc&tenant=t1')
    assert.equal(startHref('facebook', 'https://x', 'Not_A_Label'), '/api/v1/auth/facebook/start?redirect=%2F')
  })

  it('SPL-1231: carries a plain invited address as login_hint, lower-cased; drops anything else', () => {
    assert.equal(startHref('google', '/', 't1', '', 'Invitee@Googlemail.com'), '/api/v1/auth/google/start?redirect=%2F&tenant=t1&login_hint=invitee%40googlemail.com')
    assert.equal(startHref('google', '/', 't1', '', 'not an address'), '/api/v1/auth/google/start?redirect=%2F&tenant=t1')
    assert.equal(startHref('google', '/', 't1'), '/api/v1/auth/google/start?redirect=%2F&tenant=t1')
    assert.equal(loginHintOf('  Office@Acme.BG '), 'office@acme.bg')
    for (const bad of ['', 'x', 'a@b', 'a b@c.d', null, undefined]) assert.equal(loginHintOf(bad), '')
  })

  it('SPL-1231: suggests Google for Gmail, Microsoft for the Outlook family, nothing for a work domain', () => {
    assert.equal(hintedProvider('p@googlemail.com'), 'google')
    assert.equal(hintedProvider('p@outlook.com'), 'microsoft')
    assert.equal(hintedProvider('p@hotmail.co.uk'), 'microsoft')
    assert.equal(hintedProvider('p@live.com'), 'microsoft')
    assert.equal(hintedProvider('office@acme.bg'), '')
    assert.equal(hintedProvider('not an address'), '')
  })
})

describe('auth client', () => {
  it('spec 021: sends NO x-locale unless sendLocale (a CORS preflight the hub refuses broke sign-in)', async () => {
    const off = stub(200, { providers: [] })
    await createAuthClient({ fetchFn: off.fn, locale: () => 'fi' }).providers()
    await createAuthClient({ fetchFn: off.fn, locale: () => 'fi' }).session()
    for (const c of off.calls) assert.equal(c.opts.headers['x-locale'], undefined, c.url)
    const on = stub(200, { providers: [] })
    await createAuthClient({ fetchFn: on.fn, locale: () => 'fi', sendLocale: true }).register({ email: 'a@example.com', password: 'x' })
    assert.equal(on.calls[0].opts.headers['x-locale'], 'fi')
  })
  it('CLE-34984: x-locale rides only writes, so GET /session and /providers need no CORS preflight', async () => {
    const on = stub(200, { providers: [] })
    const c = createAuthClient({ fetchFn: on.fn, locale: () => 'fi', sendLocale: true })
    await c.session()
    await c.providers()
    for (const call of on.calls) {
      assert.equal(call.opts.headers['x-locale'], undefined, call.url)
      /* a simple request: only CORS-safelisted headers */
      assert.deepEqual(Object.keys(call.opts.headers).filter((h) => !['accept', 'accept-language', 'content-language'].includes(h.toLowerCase())), [], call.url)
    }
  })
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

  it('CLE-35075: two clients mounting together read /providers ONCE; a later read asks again', async () => {
    const ok = stub(200, { providers: ['google'], native: true })
    const a = createAuthClient({ fetchFn: ok.fn })
    const b = createAuthClient({ fetchFn: ok.fn })
    const [x, y] = await Promise.all([a.loadProviders(), b.loadProviders()])
    assert.equal(ok.calls.length, 1)
    assert.deepEqual(x, { status: 'ok', reason: '', providers: ['google'], native: true })
    assert.deepEqual(y, x)
    assert.notEqual(x.providers, y.providers, 'each caller owns its list')
    await a.loadProviders()
    assert.equal(ok.calls.length, 2, 'settled: the next mount reads afresh')
    const other = createAuthClient({ fetchFn: ok.fn, base: 'https://api.example.com' })
    await Promise.all([a.loadProviders(), other.loadProviders()])
    assert.equal(ok.calls.length, 4, 'another auth origin is another read')
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
    await c.verifyEmail({ token: 't', password: 'p' })
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
      [(c) => c.verifyEmail({ token: 'ab12', password: 'pw' }), '/email/verify', { token: 'ab12', password: 'pw' }],
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
    assert.equal((await client(502, null, { badJson: true }).c.verifyEmail({ token: 't', password: 'p' })).error, 'unavailable')
    assert.equal((await client(0, null, { throws: true }).c.resetPassword({ token: 't', password: 'p' })).error, 'network')
  })

  it('§4 copy for every token, and 429 with Retry-After in minutes', () => {
    const copy = {
      invalid_credentials: 'Email or password is wrong.',
      email_unverified: 'Confirm your email first — we can send the link again.',
      not_allowed: 'This account has no access here yet — ask your admin for an invite.',
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
    assert.ok(src.includes(':href="startHref(p, redirect, tenant, authBase, loginHint)"'))
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
    // SPL-959: the social return carries ?tenant=<t> from a tenant host (socialRedirect)
    assert.ok(login.includes('<SocialAuthButtons class="idp" :redirect="socialRedirect" :tenant="tenant" :login-hint="invited" :suggested="hinted" />'))
  })
  it('renders Microsoft and LinkedIn marks only when those providers are advertised', () => {
    // Buttons exist only for registry entries (v-for="p in providers").
    assert.match(src, /v-for="p in providers"/)
    assert.match(src, /v-else-if="p === 'microsoft'"/)
    assert.match(src, /data-test="social-logo-microsoft"/)
    assert.match(src, /v-else-if="p === 'linkedin'"/)
    assert.match(src, /data-test="social-logo-linkedin"/)
    // Official Microsoft four-square (identity platform MS-SymbolLockup).
    assert.ok(src.includes('fill="#f25022"'))
    assert.ok(src.includes('fill="#00a4ef"'))
    assert.ok(src.includes('fill="#7fba00"'))
    assert.ok(src.includes('fill="#ffb900"'))
    assert.ok(src.includes('viewBox="0 0 21 21"'))
    // Official LinkedIn [in] Logo in current LinkedIn Blue.
    assert.ok(src.includes('#0A66C2'))
    assert.ok(src.includes('viewBox="0 0 72 72"'))
    // Letter fallback stays v-else: an unbranded IdP (xai) gets no brand mark.
    assert.ok(src.includes('<span v-else>{{ providerName(p).charAt(0) }}</span>'))
    assert.ok(src.includes("p === 'microsoft' || p === 'linkedin'"))

    // Parse the v-if chain: a provider list only yields a mark when that
    // provider has a gated SVG. An empty / unknown list yields none.
    const map = {}
    const re = /v-(?:else-)?if="p === '([^']+)'"[\s\S]*?data-test="(social-logo-[^"]+)"/g
    let m
    while ((m = re.exec(src))) map[m[1]] = m[2]
    assert.equal(map.google, 'social-logo-google')
    assert.equal(map.facebook, 'social-logo-facebook')
    assert.equal(map.microsoft, 'social-logo-microsoft')
    assert.equal(map.linkedin, 'social-logo-linkedin')
    assert.equal(map.xai, undefined)
    const marksFor = (list) => list.map((p) => map[p]).filter(Boolean)
    assert.deepEqual(marksFor(['google', 'facebook']), ['social-logo-google', 'social-logo-facebook'])
    assert.deepEqual(marksFor(['microsoft', 'linkedin']), ['social-logo-microsoft', 'social-logo-linkedin'])
    assert.deepEqual(marksFor(['google', 'microsoft', 'linkedin']), [
      'social-logo-google', 'social-logo-microsoft', 'social-logo-linkedin',
    ])
    assert.deepEqual(marksFor(['xai']), [])
    assert.deepEqual(marksFor([]), [])
    // Light-theme Microsoft colours (FR-011).
    assert.match(src, /\.social-auth__btn--microsoft[\s\S]*?border:\s*1px solid #8C8C8C/)
    assert.match(src, /\.social-auth__btn--microsoft[\s\S]*?color:\s*#5E5E5E/)
  })

  it('catalogues continue_microsoft and continue_linkedin in every locale', () => {
    const localesDir = join(WUI, 'i18n/locales')
    const files = readdirSync(localesDir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    const en = JSON.parse(readFileSync(join(localesDir, 'en.json'), 'utf8'))
    assert.equal(en.social_auth.continue_microsoft, 'Sign in with Microsoft')
    assert.equal(en.social_auth.continue_linkedin, 'Continue with LinkedIn')
    for (const f of files) {
      const d = JSON.parse(readFileSync(join(localesDir, f), 'utf8'))
      const ms = d.social_auth && d.social_auth.continue_microsoft
      const li = d.social_auth && d.social_auth.continue_linkedin
      assert.equal(typeof ms, 'string', f + ' continue_microsoft')
      assert.equal(typeof li, 'string', f + ' continue_linkedin')
      assert.ok(ms.trim(), f + ' continue_microsoft empty')
      assert.ok(li.trim(), f + ' continue_linkedin empty')
    }
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
    assert.ok(login.includes('<NativeAuthForm v-if="session.state !== \'in\'" :redirect="redirect" :tenant="tenant" :email="invited" />'))
    assert.ok(login.includes("session.claims?.p === 'password'"))
    assert.ok(login.includes('<ChangePasswordForm'))
    const form = read('src/components/NativeAuthForm.vue')
    assert.ok(form.includes("status.value = out.native ? 'on' : 'off'"), 'gated on providers.native')
    assert.ok(form.includes('v-if="status === \'on\'"'))
    assert.ok(form.includes(':data-native-auth="status"'))
    for (const fn of ['auth.login(', 'auth.register(', 'auth.forgotPassword(', 'nativeError(']) assert.ok(form.includes(fn), fn)
    const change = read('src/components/ChangePasswordForm.vue')
    assert.ok(change.includes('auth.changePassword('))
    assert.ok(change.includes('session.signedOut()'), '204 clears the cookie')
  })
})
