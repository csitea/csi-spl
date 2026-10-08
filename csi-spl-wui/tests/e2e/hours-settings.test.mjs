// Spec 107 T016: the hours settings in a REAL browser, against the mock
// bundle (the mock plays an admin, tenant-settings-mock.mjs keeps the four
// registered keys with the hub's ranges).
//
// Desktop:
//   1  Tenant settings -> General shows the Hours block at the defaults
//   2  set the period to month, save, leave the page and come back: month
//   3  CONTROL: an idle cutoff of 99 is refused (out of range), nothing saved;
//      the hub's 400 bad_setting rule is tests/unit/hours-settings.test.mjs
//   4  Settings -> Behaviour: "Count my reading time" is on by default;
//      clicking it saves hours_reading false and the box clears
// Phone, 360x780 and 390x844, dark and light, font levels 1, 3, 5, on the
// Hours block and on the reading switch:
//   5  no sideways scroll (document and every element: scrollLeft == 0)
//   6  every control 44..48 px tall
//
// The recorder half of T016 ("toggle off stops the recorder") waits for
// T012, the tab recorder; it is not in this file.
//
// Plant the defect and watch step 2 go red (the save is never clicked):
//   PROVE_RED=no-save node tests/e2e/hours-settings.test.mjs
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e hours-settings
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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

const HOURS = '[data-test=tenant-hours]'
const READING = '[data-test=hours-reading-setting]'
const value = (p, sel) => p.$eval(sel, (e) => e.value).catch(() => '')
const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)

/** a fresh signed-in admin page; PUT /preferences answered as the hub would, bodies kept in `saved` */
async function open(browser, vp, path, { theme = 'dark', level = 3 } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  const saved = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.setRequestInterception(true)
  p.on('request', (r) => {
    if (r.isInterceptResolutionHandled()) return
    if (r.method() === 'PUT' && /\/preferences$/.test(new URL(r.url()).pathname)) {
      saved.push(r.postData() || '')
      return r.respond({ status: 200, contentType: 'application/json', body: '{}' })
    }
    return r.continue()
  })
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
    } catch { /* about:blank */ }
  }, { theme, level })
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx, errors, saved }
}

/* step 5: the document and every element under root */
const sideways = (p, root) => p.evaluate((r) => {
  const wide = []
  for (const el of document.querySelector(r)?.querySelectorAll('*') || []) {
    if (el.scrollLeft !== 0) wide.push(`scrollLeft ${el.tagName}.${el.className}`)
  }
  const d = document.documentElement
  return { doc: d.scrollWidth - d.clientWidth, docLeft: document.scrollingElement?.scrollLeft || 0, wide }
}, root)
const flat = (s) => s.doc <= 1 && s.docLeft === 0 && s.wide.length === 0

/* step 6: the visible controls' heights */
const heights = (p, sel) => p.$$eval(sel, (els) => els.filter((e) => e.offsetParent !== null)
  .map((e) => ({ id: e.getAttribute('data-test') || e.getAttribute('data-testid') || e.tagName, h: Math.round(e.getBoundingClientRect().height * 10) / 10 })))
const tapOk = (hs) => hs.length > 0 && hs.every((c) => c.h >= 44 && c.h <= 48)

const server = await startServer()
const browser = await launch()
try {
  /* ---- desktop ---- */
  const desk = { width: 1280, height: 800 }
  const d = await open(browser, desk, '/tenant-settings/general')
  const p = d.p
  await p.waitForSelector(`${HOURS} [data-test=tenant-hours-period]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const defaults = { period: await value(p, '[data-test=tenant-hours-period]'), grace: await value(p, '[data-test=tenant-hours-grace]'), idle: await value(p, '[data-test=tenant-hours-idle]'), tz: await value(p, '[data-test=tenant-hours-tz]') }
  ok('1 General shows the Hours block at the hub defaults', defaults.period === 'week' && defaults.grace === '2' && defaults.idle === '10' && defaults.tz === 'UTC', defaults)

  await p.select('[data-test=tenant-hours-period]', 'month')
  if (RED !== 'no-save') await p.click('[data-test=tenant-hours-save]')
  const notice = await until(p, (s) => Boolean(document.querySelector(s)), '[data-test=tenant-hours-notice]', 5000)
  await p.click('[data-test=tenant-settings-nav-performance]')
  await until(p, () => location.pathname.endsWith('/tenant-settings/performance'), null, 10000)
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector('[data-test=tenant-hours-period]', { visible: true, timeout: 10000 }).catch(() => null)
  await until(p, (s) => document.querySelector(s)?.value === 'month', '[data-test=tenant-hours-period]', 5000)
  const back = await value(p, '[data-test=tenant-hours-period]')
  ok('2 the period set to month is saved and reads back as month', notice && back === 'month', { notice, back })

  await p.$eval('[data-test=tenant-hours-idle]', (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type('[data-test=tenant-hours-idle]', '99')
  await p.click('[data-test=tenant-hours-save]')
  const overflow = await p.$eval('[data-test=tenant-hours-idle]', (e) => e.validity.rangeOverflow).catch(() => false)
  await sleep(300)
  await p.click('[data-test=tenant-settings-nav-performance]')
  await until(p, () => location.pathname.endsWith('/tenant-settings/performance'), null, 10000)
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector('[data-test=tenant-hours-idle]', { visible: true, timeout: 10000 }).catch(() => null)
  await sleep(300)
  const idle = await value(p, '[data-test=tenant-hours-idle]')
  ok('3 CONTROL: an idle cutoff of 99 is refused (out of range) and nothing is saved', overflow && idle === '10', { overflow, idle })

  await p.goto(server.base + '/lobby?settings=behaviour', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const sw = '[data-testid=settings-hours-reading]'
  ok('4a Settings -> Behaviour shows "Count my reading time", on by default', await until(p, (s) => document.querySelector(s)?.checked === true, sw, 10000))
  await p.click(sw)
  const off = await until(p, (s) => document.querySelector(s)?.checked === false, sw, 4000)
  ok('4b clicking it turns it off and saves hours_reading false', off && d.saved.some((b) => /"hours_reading":false/.test(b)), d.saved)
  ok('desktop: no unexpected page errors', d.errors.length === 0, d.errors)
  await d.ctx.close()

  /* ---- phone matrix ---- */
  for (const vp of [{ width: 360, height: 780 }, { width: 390, height: 844 }]) {
    const spec = { ...vp, isMobile: true, hasTouch: true }
    for (const theme of ['dark', 'light']) {
      for (const level of [1, 3, 5]) {
        const tag = `${vp.width}x${vp.height} ${theme} L${level}`
        const g = await open(browser, spec, '/tenant-settings/general', { theme, level })
        const shown = await g.p.waitForSelector(`${HOURS} [data-test=tenant-hours-save]`, { timeout: NAV_TIMEOUT }).then(() => true, () => false)
        await g.p.$eval(HOURS, (e) => e.scrollIntoView({ block: 'start' })).catch(() => {})
        await sleep(200)
        const sx = await sideways(g.p, '[data-test=tenant-settings]')
        ok(`5 ${tag}: Hours, no sideways scroll`, shown && flat(sx), sx)
        const hs = await heights(g.p, `${HOURS} select, ${HOURS} input, ${HOURS} button`)
        ok(`6 ${tag}: Hours controls 44..48 px`, tapOk(hs), hs)
        await g.ctx.close()

        const b = await open(browser, spec, '/settings/behaviour', { theme, level })
        const on = await b.p.waitForSelector(READING, { timeout: NAV_TIMEOUT }).then(() => true, () => false)
        await b.p.$eval(READING, (e) => e.scrollIntoView({ block: 'center' })).catch(() => {})
        await sleep(200)
        const bx = await sideways(b.p, 'body')
        ok(`5 ${tag}: reading switch, no sideways scroll`, on && flat(bx), bx)
        const rh = await heights(b.p, `${READING} label`)
        ok(`6 ${tag}: reading switch row 44..48 px`, tapOk(rh), rh)
        ok(`${tag}: no unexpected page errors`, g.errors.length === 0 && b.errors.length === 0, [...g.errors, ...b.errors])
        await b.ctx.close()
      }
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nhours-settings: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
