// perf round 4 W10 (round-3 P3-28): the root-locale head script when the edge
// (Firebase Hosting i18n) already served a localized document at `/`.
// One document when the edge and the visitor agree; the cookie still beats
// Accept-Language; the default-locale reload can never loop.
import vm from 'node:vm'
import {
  buildRootLocaleRedirectScript,
  EDGE_LOCALE_COOKIE,
  readCookie,
} from '../../src/utils/rootLocaleRedirect.mjs'

let failed = 0
const pass = (n) => console.log(`  OK   ${n}`)
const fail = (n, d) => { failed++; console.log(`  FAIL ${n}: ${d}`) }
const eq = (got, want, n) => (JSON.stringify(got) === JSON.stringify(want) ? pass(n) : fail(n, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`))
console.log('root-locale-edge')

const COOKIE = 'i18n_redirected'
const script = buildRootLocaleRedirectScript({ supported: ['en', 'fi', 'ru', 'bg'], defaultLocale: 'en', cookieKey: COOKIE })

function run({ pathname = '/', lang = '', cookie = '', languages = [], ua = 'Mozilla/5.0 (X11; Linux x86_64) Chrome/128.0', search = '', hash = '', session = {} }) {
  const out = { replaced: null, renamed: null, written: [], leaving: false }
  const document = { documentElement: { lang } }
  Object.defineProperty(document, 'cookie', { get: () => cookie, set: (v) => { out.written.push(v) } })
  const window = {}
  const ctx = {
    window,
    document,
    location: { pathname, search, hash, protocol: 'https:', replace: (u) => { out.replaced = u; out.leaving = !!window.__spoolLeaving } },
    history: { replaceState: (_s, _t, u) => { out.renamed = u } },
    navigator: { languages, language: languages[0], userAgent: ua },
    sessionStorage: { getItem: (k) => session[k] ?? null, setItem: (k, v) => { session[k] = v } },
  }
  vm.runInNewContext(script, ctx)
  return out
}

// 1) edge and visitor agree: one document, the URL becomes /<code>
let r = run({ lang: 'fi-FI', languages: ['fi'], search: '?a=1', hash: '#x' })
eq([r.replaced, r.renamed], [null, '/fi?a=1#x'], 'edge served fi to a fi browser: rename only, no second document')
r = run({ lang: 'en-GB', languages: ['en-US', 'fi'] })
eq([r.replaced, r.renamed], [null, null], 'default document for an en browser: nothing to do')
r = run({ lang: 'fi-FI', cookie: `${COOKIE}=fi; ${EDGE_LOCALE_COOKIE}=fi`, languages: ['ru'] })
eq([r.replaced, r.renamed, r.written], [null, '/fi', []], 'edge honoured the mirrored cookie: rename only, no cookie write')

// 2) the cookie wins over what the edge served from Accept-Language
r = run({ lang: 'fi-FI', cookie: `${COOKIE}=ru`, languages: ['fi'] })
eq([r.replaced, r.renamed, r.leaving], ['/ru', null, true], 'ru cookie beats an fi document: replace(/ru), later head scripts stay home')
const session = {}
r = run({ lang: 'fi-FI', cookie: `${COOKIE}=en`, languages: ['fi'], session })
eq(r.replaced, '/', 'en (default) cookie beats an fi document: reload /')
r.written.some((w) => w.startsWith(`${EDGE_LOCALE_COOKIE}=en;`)) ? pass('edge cookie set to en before the reload') : fail('edge cookie set to en before the reload', JSON.stringify(r.written))
r = run({ lang: 'fi-FI', cookie: `${COOKIE}=en`, languages: ['fi'], session })
eq(r.replaced, null, 'second time in the same tab: no reload (a host ignoring the cookie cannot loop)')

// 3) the mirror runs on every page
r = run({ pathname: '/fi/login', cookie: `${COOKIE}=fi` })
eq(r.written.length === 1 && r.written[0].startsWith(`${EDGE_LOCALE_COOKIE}=fi; Path=/;`) && /; Secure$/.test(r.written[0]), true, 'locale cookie mirrored to the edge cookie on any path')
eq(r.replaced, null, 'non-root path never navigates')
r = run({ pathname: '/fi', cookie: `${COOKIE}=xx` })
eq(r.written, [], 'unknown locale cookie is not mirrored')

// 4) crawlers keep what they were served
r = run({ lang: 'fi-FI', languages: ['en-US'], ua: 'Mozilla/5.0 (compatible; Googlebot/2.1)' })
eq([r.replaced, r.renamed], [null, '/fi'], 'crawler: keeps the edge document, never navigates')

// 5) helpers + robustness
eq(readCookie(`a=1; ${COOKIE}=${encodeURIComponent('fi')}; b=2`, COOKIE), 'fi', 'readCookie exact name')
eq(readCookie(`not_${COOKIE}=fi`, COOKIE), '', 'readCookie ignores a suffix match')
try {
  vm.runInNewContext(script, { location: { pathname: '/' }, document: { documentElement: { lang: 'fi' } }, navigator: { languages: ['fi'] } })
  pass('no history API: never throws')
} catch (e) {
  fail('no history API: never throws', e.message)
}

if (failed) { console.log(`root-locale-edge: ${failed} failed`); process.exit(1) }
console.log('root-locale-edge: all good')
