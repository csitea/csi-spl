// Spec 181 row B13 (gap G14): Monitoring -> Invoices, the owner's overdue
// list, in a real browser against the mock bundle, in English and Finnish:
//   - done test: the mock holds two invoices, one paid -> the list shows one
//     row; Mark paid, confirmed -> the list is empty and says so;
//   - Mark paid, dismissed -> nothing is marked, the row stays;
//   - CONTROL: a reader who is not the operator admin sees the 403 sentence,
//     never a table, and no Invoices tab;
//   - no sideways scroll on a phone (412x915) or the desktop (1280x800).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-invoices
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { INVOICES_MOCK_PAID_KEY } from '../../src/utils/monitoring-invoices.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

const SIZES = [{ width: 412, height: 915 }, { width: 1280, height: 800 }]
const LOCALES = [{ code: 'en', prefix: '' }, { code: 'fi', prefix: '/fi' }]

const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
const rows = (p) => p.$$eval('[data-test=invoices-row]', (els) => els.map((e) => e.getAttribute('data-workspace') + '/' + e.getAttribute('data-month')))
const sideways = (p) => p.evaluate(() => {
  const page = document.querySelector('[data-test=invoices-page]')
  return Math.max(document.documentElement.scrollWidth - document.documentElement.clientWidth, page ? page.scrollWidth - page.clientWidth : 0)
})

/** A fresh signed-in mock reader on /monitoring/invoices; operator = the operator admin. */
async function invoicesPage(browser, base, size, prefix, operator) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ ...size, isMobile: size.width < 800, hasTouch: size.width < 800 })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((opKey, paidKey, op) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem('spool.mock.me')
    localStorage.removeItem(paidKey)
    if (op) localStorage.setItem(opKey, '1')
    else localStorage.removeItem(opKey)
  }, TOKENS_MOCK_OPERATOR_KEY, INVOICES_MOCK_PAID_KEY, operator)
  await p.goto(base + prefix + '/monitoring/invoices', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  return { ctx, p }
}

const server = await startServer()
const browser = await launch()
try {
  for (const loc of LOCALES) {
    for (const size of SIZES) {
      const tag = `${loc.code} ${size.width}x${size.height}`
      {
        const { ctx, p } = await invoicesPage(browser, server.base, size, loc.prefix, true)
        ok(`${tag}: the list renders`, await waitFor(p, '[data-test=invoices-row]'))
        ok(`${tag}: two invoices, one paid -> one row`, JSON.stringify(await rows(p)) === '["ws-north/2026-10"]', await rows(p))
        const total = await p.$eval('[data-test=invoices-total]', (e) => e.textContent.trim()).catch(() => '')
        ok(`${tag}: the total is money (24.65 EUR), never micros`, /24[.,]65/.test(total) && /€|EUR/.test(total), total)
        ok(`${tag}: 0 px sideways`, (await sideways(p)) === 0, await sideways(p))
        const tab = await p.$('[data-test=monitoring-tab-invoices], a[href$="/monitoring/invoices"]')
        ok(`${tag}: the operator admin sees the Invoices tab`, tab !== null)
        /* dismissed: nothing is marked */
        p.once('dialog', (d) => { void d.dismiss() })
        await p.click('[data-test=invoices-mark-paid]')
        await p.waitForNetworkIdle({ idleTime: 300, timeout: 5000 }).catch(() => {})
        ok(`${tag}: a dismissed confirm marks nothing`, (await rows(p)).length === 1, await rows(p))
        /* confirmed: the row leaves the list */
        let asked = ''
        p.once('dialog', (d) => { asked = d.message(); void d.accept() })
        await p.click('[data-test=invoices-mark-paid]')
        const empty = await waitFor(p, '[data-test=invoices-empty]')
        ok(`${tag}: the confirm names the workspace and the month`, asked.includes('North') && asked.includes('2026-10'), asked)
        ok(`${tag}: mark paid -> the list is empty`, empty && (await rows(p)).length === 0, await rows(p))
        ok(`${tag}: the notice says it is marked paid`, await waitFor(p, '[data-test=invoices-notice]'))
        await ctx.close()
      }
      {
        const { ctx, p } = await invoicesPage(browser, server.base, size, loc.prefix, false)
        ok(`${tag}: CONTROL a reader who is not the operator admin gets the 403 sentence`, await waitFor(p, '[data-test=invoices-forbidden]'))
        ok(`${tag}: CONTROL and never a table`, (await p.$('[data-test=invoices-table]')) === null)
        await ctx.close()
      }
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `monitoring-invoices: ${failed} FAILED` : `monitoring-invoices: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
