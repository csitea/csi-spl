// A settled 'out' on a product screen is a redirect to /login. 'loading' and
// 'unknown' are not: unknown is an unreachable hub, and a redirect there would
// trap someone whose cookie is still good. The mock tenant is never signed out.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SIGNED_OUT_LOCALE_CODES,
  isProductScreen,
  productPath,
  signedOutLoginTarget,
} from '../../src/utils/signed-out-redirect.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const PRODUCT = [
  '/',
  '/lobby',
  '/search',
  '/search?q=from%3Aalice',
  '/channel/general',
  '/dm/GRK-1@box',
  '/t/abc',
  '/settings',
  '/settings/keys',
  '/fi/lobby',
  '/fi/settings/profile',
  '/en/channel/general',
]

describe('signedOutLoginTarget', () => {
  it("a settled 'out' on a product path redirects to /login and keeps that path", () => {
    for (const path of PRODUCT) {
      const dest = signedOutLoginTarget(path, 'out', false)
      assert.ok(dest, path)
      assert.equal(dest.path, '/login')
      assert.equal(dest.query.redirect, path)
    }
  })

  it("'loading' and 'unknown' are not redirects, on any product path", () => {
    for (const state of ['loading', 'unknown', 'in', undefined, null, '']) {
      for (const path of PRODUCT) {
        assert.equal(signedOutLoginTarget(path, state, false), null, `${state} ${path}`)
      }
    }
  })

  it('the mock tenant is never a signed-out visitor', () => {
    assert.equal(signedOutLoginTarget('/lobby', 'out', true), null)
    assert.equal(signedOutLoginTarget('/', 'out', true), null)
  })

  it('login, reset, verify and checkout do not redirect (no loop)', () => {
    for (const path of [
      '/login',
      '/login?redirect=%2Flobby',
      '/fi/login',
      '/he/login?x=1',
      '/reset-password',
      '/fi/reset-password',
      '/verify-email',
      '/verify-email?token=abc',
      '/checkout',
      '/checkout/success',
      '/checkout/claim',
      '/fi/checkout/claim',
    ]) {
      assert.equal(isProductScreen(path), false, path)
      assert.equal(signedOutLoginTarget(path, 'out', false), null, path)
    }
  })

  it('a /dm path is a product screen, not a locale prefix', () => {
    assert.equal(productPath('/dm/GRK-1@box'), '/dm/GRK-1@box')
    assert.equal(isProductScreen('/dm/GRK-1@box'), true)
    assert.equal(productPath('/fi'), '/')
    assert.equal(isProductScreen('/fi'), true)
  })

  it('locale codes match the shipped catalogues', () => {
    const files = readdirSync(join(WUI, 'i18n/locales')).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort()
    assert.deepEqual([...SIGNED_OUT_LOCALE_CODES].sort(), files)
  })
})

describe('the redirect lives in one middleware, not on each page', () => {
  const pages = [
    'src/pages/index.vue',
    'src/pages/lobby.vue',
    'src/pages/search.vue',
    'src/pages/channel/[name].vue',
    'src/pages/dm/[peer].vue',
    'src/pages/t/[task_id].vue',
    'src/pages/settings.vue',
  ]

  it('the global middleware probes only in the browser and sends product screens to /login', () => {
    const s = src('src/middleware/signed-out-redirect.global.ts')
    assert.match(s, /import\.meta\.server/)
    assert.match(s, /api\.mock/)
    assert.match(s, /signedOutLoginTarget/)
    assert.match(s, /isProductScreen/)
    assert.match(s, /session\.probe\(\)/)
    assert.match(s, /localePath\('\/login'\)/)
  })

  for (const page of pages) {
    it(`${page} does not paint SignedOutNotice or redirect on its own`, () => {
      const s = src(page)
      assert.doesNotMatch(s, /<SignedOutNotice/)
      assert.doesNotMatch(s, /navigateTo\([^)]*login/)
      assert.doesNotMatch(s, /signedOutLoginTarget/)
    })
  }
})

describe('login landing', () => {
  it('the page shows the picture, the tagline, and no signed-out continue link', () => {
    const login = src('src/pages/login.vue')
    assert.match(login, /src="\/login-landing\.png"/)
    assert.match(login, /data-test="login-landing"/)
    assert.match(login, /:alt="t\('auth\.login\.where_humans_meet'\)"/)
    assert.match(login, /<h1>\{\{ t\('auth\.login\.where_humans_meet'\) \}\}<\/h1>/)
    assert.match(login, /\.login-landing-card\s*\{[^}]*text-align:\s*center/)
    assert.match(login, /<SocialAuthButtons class="idp" :redirect="redirect" :tenant="tenant" \/>/)
    assert.match(login, /<NativeAuthForm v-if="session\.state !== 'in'"/)
    assert.match(login, /data-test="password-changed"/)
    assert.match(login, /class="login-error"/)
    assert.doesNotMatch(login, /<p><NuxtLink :to="redirect">\{\{ t\('auth\.login\.continue'\) \}\}<\/NuxtLink><\/p>/)
    const continueAt = login.indexOf("t('auth.login.continue')")
    const signedInAt = login.indexOf("session.state === 'in'")
    assert.ok(continueAt > signedInAt && signedInAt >= 0, 'continue stays inside the signed-in branch')
  })

  it('the picture is the generated PNG in the WUI public dir', () => {
    const buf = readFileSync(join(WUI, 'src/public/login-landing.png'))
    assert.ok(buf.length > 1000)
    assert.equal(buf.subarray(0, 8).toString('hex'), '89504e470d0a1a0a')
  })

  it('every locale has the English tagline (no invented translation)', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      assert.equal(j.auth.login.where_humans_meet, 'where humans meet', f)
    }
  })

  it('the language switcher stays on the login frame', () => {
    assert.match(src('src/layouts/login.vue'), /<LanguageSwitcher/)
  })
})
