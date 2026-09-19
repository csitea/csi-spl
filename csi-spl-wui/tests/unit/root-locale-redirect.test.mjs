// spec 021 (donor suite, copied) — `/` must hydrate in the language the visitor lands in.
//
// The site is static (nuxt generate → Firebase Hosting), so `/` ships the
// default-locale markup and a blocking <head> script decides, BEFORE
// hydration, whether the visitor belongs on a prefixed locale instead:
// cookie → Accept-Language (navigator.languages) → default. This suite runs
// that exact inline script (the string nuxt.config embeds) against a fake
// browser, plus static guards on the wiring. The browser-level check is
// tests/e2e/locale-switch.test.mjs.
// Run: node tests/unit/root-locale-redirect.test.mjs
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'
import {
  resolveRootLocale,
  buildRootLocaleRedirectScript,
  CRAWLER_UA_RE,
} from '../../src/utils/rootLocaleRedirect.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }
const eq = (got, want, n) => (got === want ? pass(n) : fail(n, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`))

const SUPPORTED = ['bg', 'fi', 'ru', 'en', 'sv', 'he', 'tr', 'mk', 'el', 'lt', 'et', 'lv', 'sr', 'ro', 'uk', 'sk', 'pl', 'es', 'nl']
const COOKIE = 'i18n_redirected'
const base = { supported: SUPPORTED, defaultLocale: 'bg', cookieKey: COOKIE }

console.log('root-locale-redirect')

// ── 1) resolver: cookie → Accept-Language → default ─────────────────────────
eq(resolveRootLocale({ ...base, cookie: '', languages: [] }), 'bg', 'no signal → default')
eq(resolveRootLocale({ ...base, cookie: '', languages: ['ru-RU', 'ru', 'en-US'] }), 'ru', 'Accept-Language ru → ru')
eq(resolveRootLocale({ ...base, cookie: '', languages: ['en-US,en;q=0.9', 'ru'] }), 'en', 'q-weighted header tag → en')
eq(resolveRootLocale({ ...base, cookie: '', languages: ['zh-CN', 'ja', 'fi-FI'] }), 'fi', 'skips unsupported tags')
eq(resolveRootLocale({ ...base, cookie: '', languages: ['zh-CN'] }), 'bg', 'only unsupported → default')
eq(resolveRootLocale({ ...base, cookie: `${COOKIE}=bg`, languages: ['ru-RU'] }), 'bg', 'bg cookie beats Accept-Language ru')
eq(resolveRootLocale({ ...base, cookie: `foo=1; ${COOKIE}=fi; bar=2`, languages: ['ru'] }), 'fi', 'cookie among others')
eq(resolveRootLocale({ ...base, cookie: `${COOKIE}=xx`, languages: ['ru'] }), 'ru', 'unknown cookie value ignored')
eq(resolveRootLocale({ ...base, cookie: `not_${COOKIE}=fi`, languages: ['ru'] }), 'ru', 'cookie name is matched exactly')
eq(resolveRootLocale({ ...base, cookie: `${COOKIE}=${encodeURIComponent('he')}`, languages: [] }), 'he', 'URL-encoded cookie value')

// ── 2) the inline script itself, run in a fake browser ──────────────────────
const script = buildRootLocaleRedirectScript(base)
script.includes('location.replace') && script.includes(JSON.stringify(COOKIE))
  ? pass('inline script built')
  : fail('inline script built', script.slice(0, 120))
// It is shipped verbatim inside <script>…</script>: a closing tag in the
// source would terminate the element early.
;!/<\/script/i.test(script) ? pass('inline script is <script>-safe') : fail('inline script is <script>-safe', 'contains </script')

function runInline({ pathname = '/', cookie = '', languages = [], ua = 'Mozilla/5.0 (X11; Linux x86_64) Chrome/128.0', search = '', hash = '' }) {
  let replaced = null
  const ctx = {
    location: { pathname, search, hash, replace: (u) => { replaced = u } },
    document: { cookie },
    navigator: { languages, language: languages[0], userAgent: ua },
  }
  vm.runInNewContext(script, ctx)
  return replaced
}

eq(runInline({ languages: ['ru-RU', 'ru'] }), '/ru', 'Accept-Language ru → replace(/ru)')
eq(runInline({ cookie: `${COOKIE}=bg`, languages: ['ru-RU'] }), null, 'bg cookie + ru browser → stays on / (bg markup already correct)')
eq(runInline({ cookie: `${COOKIE}=fi`, languages: ['ru-RU'] }), '/fi', 'fi cookie wins over ru browser')
eq(runInline({ languages: ['bg-BG'] }), null, 'bg browser → no redirect')
eq(runInline({ languages: [] }), null, 'no languages → default, no redirect')
eq(runInline({ languages: ['ru'], search: '?utm=x', hash: '#top' }), '/ru?utm=x#top', 'query + hash preserved')
eq(runInline({ pathname: '/products', languages: ['ru'] }), null, 'only the exact root path is redirected')
eq(runInline({ pathname: '/en/', languages: ['ru'] }), null, 'prefixed routes untouched')
eq(runInline({ languages: ['en-US'], ua: 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' }), null, 'Googlebot is not redirected (indexable bg home + hreflang)')
eq(runInline({ languages: ['en-US'], ua: 'Mozilla/5.0 (compatible; bingbot/2.0)' }), null, 'bingbot is not redirected')
eq(runInline({ languages: ['en-US'], ua: 'Mozilla/5.0 HeadlessChrome/128.0.0.0' }), '/en', 'plain headless Chrome (the e2e harness) IS redirected')
CRAWLER_UA_RE.test('Chrome-Lighthouse') ? pass('Lighthouse exempt') : fail('Lighthouse exempt', 'regex')
// A broken environment (no navigator.languages, no document) must fail closed
// — render bg — never throw before Nuxt boots.
try {
  vm.runInNewContext(script, { location: { pathname: '/', replace() { throw new Error('boom') } }, document: {}, navigator: {} })
  pass('inline script never throws')
} catch (e) {
  fail('inline script never throws', e.message)
}

// ── 3) wiring guards ────────────────────────────────────────────────────────
// Line comments only: nuxt.config quotes glob/route strings such as
// `/api/v1/auth/*/start` that a naive block-comment stripper would eat.
const strip = (s) => s.replace(/(^|[^:'"`])\/\/.*$/gm, '$1')
const cfg = strip(readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8'))
cfg.includes('buildRootLocaleRedirectScript(')
  ? pass('nuxt.config embeds the root redirect script')
  : fail('nuxt.config embeds the root redirect script', 'missing')
;/detectBrowserLanguage:\s*false/.test(cfg)
  ? pass('nuxt.config: i18n detectBrowserLanguage is off (no in-place locale swap on /)')
  : fail('nuxt.config: i18n detectBrowserLanguage is off', 'module would swap locale before first render')
;!/alwaysRedirect:\s*true/.test(cfg) && !/redirectOn:/.test(cfg)
  ? pass('nuxt.config: no module-level root redirect left')
  : fail('nuxt.config: no module-level root redirect left', 'redirectOn/alwaysRedirect present')
;/NUXT_PUBLIC_DEFAULT_LOCALE \|\| ["']en["']/.test(cfg)
  ? pass('nuxt.config fallback default locale is en (spec 021 OQ-1)')
  : fail('nuxt.config fallback default locale is en', 'expected || "en" (cnf env.i18n.default_locale)')
(cfg.includes(`'${COOKIE}'`) || cfg.includes(`"${COOKIE}"`)) && cfg.includes('localeCookie')
  ? pass('nuxt.config exposes the locale cookie key to the client')
  : fail('nuxt.config exposes the locale cookie key', 'missing')

const plugin = join(WUI, 'src/plugins/locale-cookie.client.ts')
if (!existsSync(plugin)) {
  fail('locale cookie plugin exists', 'src/plugins/locale-cookie.client.ts missing')
} else {
  const src = strip(readFileSync(plugin, 'utf8'))
  src.includes('document.cookie') && src.includes('localeCookie') && src.includes('$i18n')
    ? pass('locale cookie plugin mirrors $i18n.locale into the cookie')
    : fail('locale cookie plugin mirrors $i18n.locale into the cookie', 'missing')
  src.includes("'app:suspense:resolve'")
    ? pass('locale cookie plugin waits for hydration')
    : fail('locale cookie plugin waits for hydration', 'must not run during first render')
}

// Firebase Hosting i18n rewrites key on Accept-Language/country only and
// cannot honour the cookie, so the hosting config must not carry one that
// would fight the in-page decision.
const tpl = join(WUI, '../csi-rel-orc/src/wui/firebase.json.tpl')
if (existsSync(tpl)) {
  const fb = JSON.parse(readFileSync(tpl, 'utf8'))
  !fb.hosting.i18n && !(fb.hosting.redirects || []).some((r) => r.source === '/')
    ? pass('firebase.json.tpl has no hosting-level locale redirect on /')
    : fail('firebase.json.tpl has no hosting-level locale redirect on /', 'hosting would fight the cookie decision')
}

if (failed) {
  console.log(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('root-locale-redirect: all good')
