// Perf round 3, P3-06: a build splits each locale catalogue in two
// (src/node/i18n/split-catalogue.mjs): the messages the first screen can show
// load with the entry, the rest (src/plugins/i18n-more.client.ts) before any
// other page or ?settings=, and when the browser is idle. A missed key would
// render as its key, so this test reads every page for key-shaped text
// (`feed.unknown`, `settings.title`, ...) in its visible text and labels:
//
//   1. the second catalogue BLOCKED (its chunks fail): the first screen in
//      en, bg and fi still shows no key - core alone carries it;
//   2. control, still blocked: a page outside the first screen (/issues,
//      reached in-app) DOES show keys - the block bites and the reader sees
//      a key when there is one;
//   3. nothing blocked: the pages outside the first screen and the Settings
//      modal, in en, bg and fi, show no key.
//
// The blocked chunks are the ones holding a namespace that only the second
// catalogue has, read from i18n/.split (the build's own split). A build
// without the split (`nuxt dev`, NUXT_I18N_SPLIT=0) runs part 3 only.
//
// Run:
//   pnpm run test:e2e i18n-split
//   BASE_URL=<generated bundle> pnpm run test:e2e i18n-split
import { createRequire } from 'node:module'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const LOCALES = ['en', 'bg', 'fi']
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const catalogue = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
const NAMESPACES = Object.keys(catalogue)
const SPLIT = join(WUI, 'i18n/.split')
const split = existsSync(join(SPLIT, 'en.json'))
// Namespaces with no key in core, whose name is no nested key anywhere: a
// chunk holding two of them as object keys is a second catalogue.
const nested = new Set()
const walkKeys = (o) => { for (const [k, v] of Object.entries(o)) if (v && typeof v === 'object') { for (const c of Object.keys(v)) nested.add(c); walkKeys(v) } }
walkKeys(catalogue)
const coreNs = split ? Object.keys(JSON.parse(readFileSync(join(SPLIT, 'en.json'), 'utf8'))) : []
const markerNs = NAMESPACES.filter((n) => !coreNs.includes(n) && !nested.has(n) && /^[a-z_]+$/.test(n))
const isMoreChunk = (body) => markerNs.filter((n) => new RegExp(`(?:^|[{,])["']?${n}["']?:\\{`).test(body)).length >= 2

/** Key-shaped strings in the page's visible text and its labels. */
async function keysShown(p) {
  return p.evaluate((namespaces) => {
    const re = new RegExp(`(?:^|[^\\w./-])((?:${namespaces.join('|')})\\.[a-z0-9_]+(?:\\.[a-z0-9_]+)*)(?![\\w/-])`, 'g')
    const texts = [document.body.innerText]
    for (const el of document.querySelectorAll('[aria-label],[title],[placeholder]')) {
      for (const a of ['aria-label', 'title', 'placeholder']) {
        const v = el.getAttribute(a)
        if (v) texts.push(v)
      }
    }
    const found = new Set()
    for (const t of texts) for (const m of t.matchAll(re)) found.add(m[1])
    return [...found].slice(0, 12)
  }, NAMESPACES)
}

/** A page whose second-catalogue chunks fail to load. */
async function blockedPage(browser) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const s = await p.createCDPSession()
  const blocked = []
  await s.send('Fetch.enable', { patterns: [{ urlPattern: '*/_nuxt/*.js', requestStage: 'Response' }] })
  s.on('Fetch.requestPaused', async (e) => {
    try {
      const { body, base64Encoded } = await s.send('Fetch.getResponseBody', { requestId: e.requestId })
      const text = base64Encoded ? Buffer.from(body, 'base64').toString('utf8') : body
      if (isMoreChunk(text)) {
        blocked.push(e.request.url.replace(/.*\/_nuxt\//, ''))
        await s.send('Fetch.failRequest', { requestId: e.requestId, errorReason: 'BlockedByClient' })
      } else await s.send('Fetch.continueRequest', { requestId: e.requestId })
    } catch { /* the page went away */ }
  })
  await p.setViewport({ width: 1280, height: 800 })
  return { p, ctx, blocked }
}

const prefix = (code) => (code === 'en' ? '' : `/${code}`)
const railUp = (p) => p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: 20000 }).then(() => true, () => false)

const server = await startServer()
const browser = await launch()
try {
  if (split) {
    console.log(`-- second catalogue blocked (marker namespaces: ${markerNs.slice(0, 4).join(', ')}, ...)`)
    ok('the split leaves whole namespaces to the second catalogue', markerNs.length >= 2, markerNs)
    for (const code of LOCALES) {
      const { p, ctx, blocked } = await blockedPage(browser)
      for (const path of ['/', '/lobby']) {
        await p.goto(server.base + prefix(code) + (path === '/' ? '' : path), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
        const up = await railUp(p)
        await sleep(1500) // the idle load has been tried (and blocked)
        const keys = await keysShown(p)
        ok(`${code} ${path}: the first screen renders with core alone, no key shown`, up && keys.length === 0, { up, keys })
      }
      ok(`${code}: the idle load asked for the second catalogue and it was blocked`, blocked.length > 0, blocked)
      if (code === 'en') {
        /* in-app, as a click would: the route guard awaits the (blocked) load */
        await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/issues'))
        await p.waitForFunction(() => location.pathname.endsWith('/issues'), { timeout: 10000 }).catch(() => {})
        await sleep(1500)
        const keys = await keysShown(p)
        ok('control: /issues with the second catalogue blocked shows its keys', keys.length > 0, keys)
      }
      await ctx.close()
    }
  } else {
    console.log('-- not a split build (i18n/.split absent): parts 1 and 2 do not apply')
  }

  console.log('-- nothing blocked: pages outside the first screen')
  const LATE = ['/help', '/issues', '/search?q=deploy', '/events', '/people', '/agents', '/boxes', '/archive', '/tenant-settings', '/users', '/checkout', '/lobby?settings=profile', '/lobby?settings=notifications']
  for (const code of LOCALES) {
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.setViewport({ width: 1280, height: 800 })
    const bad = []
    for (const path of LATE) {
      await p.goto(server.base + prefix(code) + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await sleep(400)
      const keys = await keysShown(p)
      if (keys.length) bad.push({ path, keys })
    }
    ok(`${code}: ${LATE.length} pages outside the first screen show no key`, bad.length === 0, bad)
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `i18n-split: ${failed} FAILED` : `i18n-split: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
