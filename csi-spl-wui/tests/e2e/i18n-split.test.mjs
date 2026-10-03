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
    for (const t of texts) {
      for (const m of t.matchAll(re)) found.add(m[1])
      /* a message function that returned a vnode array where text was due (P3-20) */
      if (t.includes('[object Object]')) found.add('[object Object]')
    }
    return [...found].slice(0, 12)
  }, NAMESPACES)
}

/**
 * A page whose second-catalogue chunks fail to load.
 *
 * A failed chunk is what a stale tab sees after a deploy, so the app answers
 * its `vite:preloadError` with a page reload (src/plugins/chunk-reload.client.ts,
 * once per 10 s). Here that reload lands at a random point of the steps below -
 * mid-goto, mid rail wait, or under the control's in-app push - and those runs
 * failed (wf10 37087180918, 37089147099). A listener that runs before the
 * app's own takes the event first: it keeps the app's preventDefault (the load
 * resolves undefined and i18n-more shows keys, as without the reload), stops
 * the reload, and counts the events so the test can show the block bit.
 */
async function blockedPage(browser) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument(() => {
    window.__i18nSplitPreloadErrors = 0
    window.addEventListener('vite:preloadError', (ev) => {
      window.__i18nSplitPreloadErrors++
      ev.preventDefault()
      ev.stopImmediatePropagation()
    })
  })
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
    } catch {
      /* never leave it paused: a paused chunk hangs the page (the page may have gone away) */
      await s.send('Fetch.continueRequest', { requestId: e.requestId }).catch(() => {})
    }
  })
  await p.setViewport({ width: 1280, height: 800 })
  const failed = []
  p.on('requestfailed', (r) => failed.push(`${r.url().replace(/.*\/_nuxt\//, '')} ${r.failure()?.errorText}`))
  return { p, ctx, blocked, failed }
}

const prefix = (code) => (code === 'en' ? '' : `/${code}`)
/** The document the step started on is still there: no reload under it. */
const markDoc = (p) => p.evaluate(() => { window.__i18nSplitDoc = true })
const sameDoc = (p) => p.evaluate(() => window.__i18nSplitDoc === true).catch(() => false)
const railUp = (p) => p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: 20000 }).then(() => true, () => false)

const server = await startServer()
const browser = await launch()
try {
  if (split) {
    console.log(`-- second catalogue blocked (marker namespaces: ${markerNs.slice(0, 4).join(', ')}, ...)`)
    ok('the split leaves whole namespaces to the second catalogue', markerNs.length >= 2, markerNs)
    /*
     * One locale's checks on its own blocked page. Docker veth churn on a
     * shared runner makes Chrome abort in-flight loads (net::ERR_NETWORK_CHANGED):
     * a page chunk then never arrives and the rail stays down. Such a run is
     * retried ONCE, every check again, and says so; any other failure stands.
     */
    async function blockedLocale(code) {
      const checks = []
      const check = (name, pass, ev) => checks.push([name, pass, ev])
      const { p, ctx, blocked, failed } = await blockedPage(browser)
      try {
        for (const path of ['/', '/lobby']) {
          await p.goto(server.base + prefix(code) + (path === '/' ? '' : path), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
          await markDoc(p)
          const up = await railUp(p)
          await sleep(1500) // the idle load has been tried (and blocked)
          const keys = await keysShown(p)
          const noReload = await sameDoc(p)
          const pass = up && keys.length === 0 && noReload
          check(`${code} ${path}: the first screen renders with core alone, no key shown`, pass, pass ? { up, keys, noReload } : { up, keys, noReload, failed })
        }
        const preloadErrors = await p.evaluate(() => window.__i18nSplitPreloadErrors).catch(() => 0)
        check(`${code}: the idle load asked for the second catalogue and it was blocked`, blocked.length > 0 && preloadErrors > 0, { blocked, preloadErrors })
        if (code === 'en') {
          /* in-app, as a click would: the route guard awaits the (blocked) load */
          await markDoc(p)
          await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/issues'))
          await p.waitForFunction(() => location.pathname.endsWith('/issues'), { timeout: 10000 }).catch(() => {})
          let keys = []
          for (let i = 0; i < 40 && !keys.length; i++) {
            await sleep(250)
            keys = await keysShown(p)
          }
          const noReload = await sameDoc(p)
          const pass = keys.length > 0 && noReload
          check('control: /issues with the second catalogue blocked shows its keys', pass, pass ? { keys, noReload } : { keys, noReload, failed })
        }
      } catch (e) {
        check(`${code}: the blocked steps ran to the end`, false, { error: String(e.message).slice(0, 200), failed })
      } finally {
        await ctx.close()
      }
      const churn = failed.some((f) => f.endsWith('net::ERR_NETWORK_CHANGED'))
      return { checks, churn }
    }

    for (const code of LOCALES) {
      let run = await blockedLocale(code)
      if (run.churn && run.checks.some(([, pass]) => !pass)) {
        console.log(`  RETRY ${code}: the page saw net::ERR_NETWORK_CHANGED (runner network churn); first attempt failed ${JSON.stringify(run.checks.filter(([, pass]) => !pass).map(([name]) => name))}`)
        run = await blockedLocale(code)
      }
      for (const [name, pass, ev] of run.checks) ok(name, pass, ev)
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
