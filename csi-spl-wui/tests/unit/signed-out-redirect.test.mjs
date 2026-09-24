// A settled 'out' on a product screen is a redirect to /login. 'loading' and
// 'unknown' are not: unknown is an unreachable hub, and a redirect there would
// trap someone whose cookie is still good. The mock tenant is never signed out.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SIGNED_OUT_LOCALE_CODES,
  isProductScreen,
  productPath,
  signedOutLoginTarget,
} from '../../src/utils/signed-out-redirect.mjs'
import { loginBarTitle } from '../../src/utils/login-title.mjs'

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
  it('the page shows the tagline, and no poster or signed-out continue link', () => {
    const login = src('src/pages/login.vue')
    assert.doesNotMatch(login, /login-landing\.(png|webp|avif)/)
    assert.doesNotMatch(login, /data-test="login-landing"/)
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

  it('the login poster files are gone', () => {
    for (const name of ['login-landing.png', 'login-landing.webp', 'login-landing.avif']) {
      assert.equal(existsSync(join(WUI, 'src/public', name)), false, name)
    }
  })

  it('every locale has the English tagline (no invented translation)', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      assert.equal(j.auth.login.where_humans_meet, 'where people meet with ai', f)
    }
  })

  it('the login frame drifts a full-bleed wallpaper and stops when motion is reduced', () => {
    const frame = src('src/layouts/login.vue')
    assert.match(frame, /class="login-wallpaper"/)
    assert.match(frame, /aria-hidden="true"/)
    assert.match(frame, /data-test="login-wallpaper"/)
    assert.match(frame, /url\('\/login-wallpaper\.webp'\)/)
    assert.match(frame, /url\('\/login-wallpaper\.avif'\) type\('image\/avif'\)/)
    assert.match(frame, /url\('\/login-wallpaper-chip\.webp'\)/)
    assert.match(frame, /url\('\/login-wallpaper-chip\.avif'\) type\('image\/avif'\)/)
    assert.match(frame, /url\('\/login-wallpaper-robot\.webp'\)/)
    assert.match(frame, /url\('\/login-wallpaper-robot\.avif'\) type\('image\/avif'\)/)
    assert.match(frame, /data-test="login-wallpaper-chip"/)
    assert.match(frame, /data-test="login-wallpaper-robot"/)
    assert.match(frame, /@keyframes login-wallpaper-drift/)
    assert.match(frame, /@keyframes login-wallpaper-hold-b/)
    assert.match(frame, /@keyframes login-wallpaper-hold-c/)
    assert.match(frame, /data-test="login-signal"/)
    assert.match(frame, /@keyframes login-signal\s*\{\s*0%,\s*64%\s*\{\s*opacity:\s*0/)
    assert.match(frame, /@media \(prefers-reduced-motion:\s*reduce\)[\s\S]*\.login-signal\s*\{[^}]*opacity:\s*0/)
    assert.match(frame, /animation:\s*login-wallpaper-drift\s+46s\s+ease-in-out\s+infinite\s+alternate/)
    assert.match(frame, /@media \(prefers-reduced-motion:\s*reduce\)\s*\{\s*\.login-wallpaper__drift\s*\{[^}]*animation:\s*none/)
    for (const name of ['login-wallpaper.avif', 'login-wallpaper-chip.avif', 'login-wallpaper-robot.avif']) {
      const buf = readFileSync(join(WUI, 'src/public', name))
      assert.ok(buf.length > 1000 && buf.length < 80_000, name)
      assert.equal(buf.subarray(4, 8).toString('ascii'), 'ftyp', name)
      assert.equal(buf.subarray(8, 12).toString('ascii'), 'avif', name)
    }
    for (const name of ['login-wallpaper.webp', 'login-wallpaper-chip.webp', 'login-wallpaper-robot.webp']) {
      const buf = readFileSync(join(WUI, 'src/public', name))
      assert.ok(buf.length > 1000 && buf.length < 120_000, name)
      assert.equal(buf.subarray(0, 4).toString('ascii'), 'RIFF', name)
      assert.equal(buf.subarray(8, 12).toString('ascii'), 'WEBP', name)
    }
  })

  it('the language switcher stays on the login frame', () => {
    const frame = src('src/layouts/login.vue')
    assert.match(frame, /<LanguageSwitcher/)
    assert.match(frame, /data-test="login-bar"/)
    assert.match(frame, /data-test="login-bar-title"/)
    assert.match(frame, /\.login-bar__title\s*\{[^}]*flex:\s*0\s+0\s+auto/)
    assert.match(frame, /\.login-bar :deep\(\.lang-switcher\)\s*\{[^}]*flex:\s*0\s+1\s+16rem/)
    assert.doesNotMatch(frame, /login-corner/)
  })

  it('the top-bar title is spool plus the build env', () => {
    assert.equal(loginBarTitle('dev', false), 'spool-dev')
    assert.equal(loginBarTitle('prd', false), 'spool-prd')
    assert.equal(loginBarTitle('', true), 'spool-dev')
    assert.equal(loginBarTitle('  ', true), 'spool-dev')
    assert.equal(loginBarTitle('', false), 'spool')
    assert.equal(loginBarTitle('not an env', false), 'spool')
  })
})
