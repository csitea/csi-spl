// spec 021 T030/T031 live proof of the donor language switcher against a
// deployed (or local) WUI, anonymous visitor, headless Chrome:
//   1. `/` with a browser asking for he → the root script lands on /he,
//      <html lang="he-IL" dir="rtl">.
//   2. /login in the default locale → switch to fi through the combobox
//      (typed search "suo") → /fi/login, lang fi-FI, cookie i18n_redirected=fi.
//   3. `/` again in that context → the cookie wins over Accept-Language → /fi.
//   4. /fi/lobby → switch to en → /en/lobby with the query kept.
//   5. every shipped locale: /<code>/login and /<code>/lobby at 390x844 have
//      no document x-scroll, and <html lang> matches.
// Screenshots (default, fi, he, en; desktop + mobile) + results.json to OUT.
//
//   BASE=https://dev.<domain> OUT=<dir> [DEFAULT_LOCALE=bg] [CHROME_PATH=...] \
//     [PUPPETEER_CORE=<path>] node tests/e2e/locale-switch.proof.mjs
//
// Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const DEF = process.env.DEFAULT_LOCALE || 'bg'
const TAGS = {
  bg: 'bg-BG', fi: 'fi-FI', ru: 'ru-RU', en: 'en-GB', sv: 'sv-SE', he: 'he-IL', tr: 'tr-TR', mk: 'mk-MK', el: 'el-GR',
  lt: 'lt-LT', et: 'et-EE', lv: 'lv-LV', sr: 'sr-RS', ro: 'ro-RO', uk: 'uk-UA', sk: 'sk-SK', pl: 'pl-PL', es: 'es-ES', nl: 'nl-NL',
}
const pfx = (code) => (code === DEF ? '' : '/' + code)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, default_locale: DEF, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const html = (p) => p.evaluate(() => ({ lang: document.documentElement.lang, dir: document.documentElement.dir || 'ltr' }))
const xscroll = (p) => p.evaluate(() => {
  const r = document.scrollingElement || document.documentElement
  return r.scrollWidth - window.innerWidth
})
const settle = () => new Promise((r) => setTimeout(r, 600))
const path = (p) => new URL(p.url()).pathname
const shot = async (p, name) => {
  for (const [w, h, tag] of [[1280, 800, 'desktop'], [390, 844, 'mobile']]) {
    await p.setViewport({ width: w, height: h })
    await settle()
    await p.screenshot({ path: `${OUT}/${name}-${tag}.png` })
  }
  await p.setViewport({ width: 1280, height: 800 })
}

/** Pick a locale through the combobox the way a person does: focus, type, Enter. */
async function pick(p, query, code) {
  const input = await p.waitForSelector('[data-test=lang-switcher-input]', { visible: true, timeout: 20000 })
  await input.click()
  await p.keyboard.type(query, { delay: 40 })
  await p.waitForSelector(`[data-test=lang-item-${code}]`, { visible: true, timeout: 5000 })
  await Promise.all([
    p.waitForFunction((c) => document.documentElement.lang.startsWith(c), { timeout: 20000 }, code),
    p.click(`[data-test=lang-item-${code}]`),
  ])
  await settle()
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=he-IL'],
})
try {
  try { res.build = await (await fetch(BASE + '/build.json')).json() } catch { res.build = null }

  // 1. root redirect by browser language (he, rtl)
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setExtraHTTPHeaders({ 'accept-language': 'he-IL,he;q=0.9' })
  await p.evaluateOnNewDocument(() => {
    Object.defineProperty(navigator, 'languages', { get: () => ['he-IL', 'he'] })
  })
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await settle()
  let h = await html(p)
  step('/ with a he browser lands on /he, rtl', path(p).startsWith('/he') && h.lang === TAGS.he && h.dir === 'rtl',
    { path: path(p), ...h })
  await p.goto(BASE + '/he/login', { waitUntil: 'networkidle2' })
  await shot(p, 'he-login')

  // 2. default-locale /login → fi through the switcher
  await p.goto(BASE + pfx(DEF) + '/login?redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await settle()
  h = await html(p)
  step(`${DEF} /login is the default locale`, h.lang === TAGS[DEF] && h.dir === 'ltr', { path: path(p), ...h })
  await shot(p, `${DEF}-login`)
  await pick(p, 'suo', 'fi')
  h = await html(p)
  const cookies = await p.cookies()
  const ck = cookies.find((c) => c.name === 'i18n_redirected')
  step('switch to fi keeps page + query, sets lang + cookie',
    path(p) === '/fi/login' && new URL(p.url()).searchParams.get('redirect') === '/lobby' && h.lang === TAGS.fi && ck?.value === 'fi',
    { url: p.url().replace(BASE, ''), ...h, cookie: ck?.value })
  await shot(p, 'fi-login')

  // 3. the cookie beats the browser language on `/`
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await settle()
  step('/ again → cookie fi beats browser he', path(p).startsWith('/fi'), { path: path(p) })

  // 4. shell: /fi/lobby → en, query kept
  await p.goto(BASE + '/fi/lobby?x=1', { waitUntil: 'networkidle2' })
  await settle()
  await pick(p, 'eng', 'en')
  h = await html(p)
  step('switch fi → en in the shell keeps page + query',
    path(p) === pfx('en') + '/lobby' && new URL(p.url()).searchParams.get('x') === '1' && h.lang === TAGS.en,
    { url: p.url().replace(BASE, ''), ...h })
  await shot(p, 'en-lobby')
  await p.goto(BASE + '/he/lobby', { waitUntil: 'networkidle2' })
  await shot(p, 'he-lobby')
  await ctx.close()

  // 5. every locale: lang + no document x-scroll at 390 wide
  const q = await browser.newPage()
  await q.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  for (const code of Object.keys(TAGS)) {
    for (const pg of ['/login', '/lobby']) {
      await q.goto(BASE + pfx(code) + pg, { waitUntil: 'networkidle2' })
      await settle()
      const hh = await html(q)
      const xs = await xscroll(q)
      step(`${code}${pg} 390: lang + no x-scroll`, hh.lang === TAGS[code] && xs <= 0 &&
        hh.dir === (code === 'he' ? 'rtl' : 'ltr'), { ...hh, xscroll: xs })
    }
  }
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`\n${res.steps.length - bad}/${res.steps.length} steps PASS`)
process.exit(bad ? 1 : 0)
