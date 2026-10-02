// P3-02 (perf audit round 3): a signed-out visitor goes to /login from the
// document head, before any JS loads, on the WUI's own hint cookie. This
// suite runs the exact inline script nuxt.config embeds against a fake
// browser, pins its product screens to the middleware's isProductScreen, and
// checks the hint's writer and the wiring.
// Run: node tests/unit/signed-out-redirect-script.test.mjs
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'
import { earlyLoginHref, buildSignedOutRedirectScript } from '../../src/utils/signed-out-redirect-script.mjs'
import {
  SIGNED_OUT_HINT_COOKIE, EARLY_LOGIN_FLAG, hintDomain, writeSignedOutHint, takeEarlyLoginFlag,
} from '../../src/utils/signed-out-hint.mjs'
import { isProductScreen, SIGNED_OUT_LOCALE_CODES } from '../../src/utils/signed-out-redirect.mjs'
import { safeRedirect } from '../../src/utils/auth-client.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }
const eq = (got, want, n) => (got === want ? pass(n) : fail(n, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`))

const LOCALES = [...SIGNED_OUT_LOCALE_CODES]
const HINT = `${SIGNED_OUT_HINT_COOKIE}=1`
const href = (path, cookie = HINT, search = '', hash = '') =>
  earlyLoginHref({ path, search, hash, cookie, cookieKey: SIGNED_OUT_HINT_COOKIE, locales: LOCALES, defaultLocale: 'en' })

// 1. the hint decides
eq(href('/lobby', ''), '', 'no hint: stay (today\'s path)')
eq(href('/lobby', `${SIGNED_OUT_HINT_COOKIE}=0`), '', 'a hint that is not 1: stay')
eq(href('/lobby', `x${SIGNED_OUT_HINT_COOKIE}=1`), '', 'another cookie\'s name: stay')
eq(href('/lobby', `a=b; ${HINT}; c=d`), '/login?redirect=%2Flobby', 'the hint among others: /login')

// 2. where it goes
eq(href('/'), '/login?redirect=%2F', '/ -> /login?redirect=/')
eq(href('/t/abc', HINT, '?x=1', '#m'), '/login?redirect=%2Ft%2Fabc%3Fx%3D1%23m', 'query and hash ride the redirect')
eq(href('/fi/lobby'), '/fi/login?redirect=%2Ffi%2Flobby', 'a locale route goes to that locale\'s login')
eq(href('/fi'), '/fi/login?redirect=%2Ffi', 'a locale home too')
eq(href('/channel/x/'), '/login?redirect=%2Fchannel%2Fx%2F', 'a trailing slash is the same screen')
eq(href('//evil.example/lobby'), '', 'a protocol-relative path: stay')
eq(href('/lobby\\x'), '', 'a backslash: stay')
for (const p of ['/lobby', '/', '/fi/t/abc', '/settings/profile', '/dm/x', '/search']) {
  const h = href(p)
  const red = decodeURIComponent(h.split('redirect=')[1] || '')
  eq(safeRedirect(red), red, `the redirect survives safeRedirect: ${p}`)
}

// 3. the same product screens as the middleware (isProductScreen), both ways
const PATHS = [
  '/', '/lobby', '/search', '/channel', '/channel/abc', '/dm', '/dm/x', '/t', '/t/1/2', '/settings', '/settings/a',
  '/login', '/login/x', '/reset-password', '/verify-email', '/checkout', '/checkout/done',
  '/issues', '/people', '/help', '/events', '/archive', '/users', '/tenant-settings', '/agents', '/boxes', '/m/x',
  '/fi', '/fi/lobby', '/fi/login', '/he/t/x', '/fi/issues', '/channelx', '/tt', '/lobby/x', '/dmx',
]
for (const p of PATHS) eq(Boolean(href(p)), isProductScreen(p), `parity with isProductScreen: ${p}`)

// 4. the inline script in a fake browser
function browse(path, cookie, extra = {}) {
  const replaced = []
  const store = new Map()
  const win = {
    location: { pathname: path, search: '', hash: '', replace: (u) => replaced.push(u) },
    document: { cookie },
    sessionStorage: { setItem: (k, v) => store.set(k, v), getItem: (k) => store.get(k) ?? null, removeItem: (k) => store.delete(k) },
    ...extra,
  }
  win.window = win
  vm.runInNewContext(buildSignedOutRedirectScript({ locales: LOCALES, defaultLocale: 'en' }), win)
  return { replaced, store, win }
}
{
  const b = browse('/lobby', HINT)
  eq(b.replaced.join(), '/login?redirect=%2Flobby', 'the script replaces the document with /login')
  eq(b.store.get(EARLY_LOGIN_FLAG), '1', 'and marks the tab for the login page')
  eq(b.win.__spoolLeaving, 1, 'and tells the later head scripts it is leaving')
}
eq(browse('/lobby', '').replaced.length, 0, 'no hint: the script does nothing')
eq(browse('/login', HINT).replaced.length, 0, 'on /login: nothing (no loop)')
eq(browse('/lobby', HINT, { __spoolLeaving: 1 }).replaced.length, 0, 'the root-locale script already left: nothing')

// 5. the hint's writer
eq(hintDomain('dev.example.com', 'https://dev.example.com'), 'dev.example.com', 'apex: the site domain')
eq(hintDomain('t2.dev.example.com', 'https://dev.example.com'), 'dev.example.com', 'a tenant host: the site domain')
eq(hintDomain('other.example.org', 'https://dev.example.com'), '', 'another host: host-only')
eq(hintDomain('t1.localhost', ''), '', 'no site url (lde): host-only')
{
  const writes = []
  const doc = { set cookie(v) { writes.push(v) } }
  writeSignedOutHint(doc, true, { hostname: 'dev.example.com', protocol: 'https:', siteUrl: 'https://dev.example.com' })
  eq(writes[0], `${SIGNED_OUT_HINT_COOKIE}=1; Max-Age=2592000; Domain=dev.example.com; Path=/; SameSite=Lax; Secure`, 'set: 30 days, site domain, Secure on https')
  writes.length = 0
  writeSignedOutHint(doc, false, { hostname: 'dev.example.com', protocol: 'https:', siteUrl: 'https://dev.example.com' })
  eq(writes.length, 2, 'clear: both the host-only and the domain cookie')
  eq(writes.every((w) => w.includes('Max-Age=0')), true, 'by expiring them')
  writeSignedOutHint(null, true)
  pass('no document: no throw')
}
{
  const m = new Map([[EARLY_LOGIN_FLAG, '1']])
  const s = { getItem: (k) => m.get(k) ?? null, removeItem: (k) => m.delete(k) }
  eq(takeEarlyLoginFlag(s), true, 'the early-login flag reads once')
  eq(takeEarlyLoginFlag(s), false, 'and is gone after')
  eq(takeEarlyLoginFlag({ getItem() { throw new Error('blocked') } }), false, 'storage blocked: false')
}

// 6. wiring
const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
const iRedirect = cfg.indexOf('buildSignedOutRedirectScript({')
const iSession = cfg.indexOf('buildEarlySessionScript({')
eq(iRedirect > 0 && iSession > iRedirect, true, 'nuxt.config inlines the redirect before the session probe')
const early = readFileSync(join(WUI, 'src/utils/early-session-script.mjs'), 'utf8')
eq(early.includes("'if(window.__spoolLeaving)return;'"), true, 'the session probe stays home when the document leaves')
const root = readFileSync(join(WUI, 'src/utils/rootLocaleRedirect.mjs'), 'utf8')
eq(/try\{window\.__spoolLeaving=1\}catch\(e\)\{\}location\.replace/.test(root), true, 'the root-locale redirect marks the document as leaving')
const store = readFileSync(join(WUI, 'src/stores/session.ts'), 'utf8')
eq(/writeSignedOutHint\(/.test(store), true, 'the session store writes the hint')
const social = readFileSync(join(WUI, 'src/components/SocialAuthButtons.vue'), 'utf8')
eq(/writeSignedOutHint\(/.test(social), true, 'a social sign-in clears the hint as it leaves')
const login = readFileSync(join(WUI, 'src/pages/login.vue'), 'utf8')
eq(/takeEarlyLoginFlag\(/.test(login), true, 'the login page continues a signed-in reader the hint sent there')

if (failed) { console.log(`\n${failed} failed`); process.exit(1) }
console.log('\nall passed')
