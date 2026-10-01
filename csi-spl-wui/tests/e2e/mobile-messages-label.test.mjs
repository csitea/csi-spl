// CLE-77904 (owner, t1 topic cb12574f): "Change the name of the mobile app
// from Direct Messages to just Messages." At <= 820 px every label of the DM
// section - its strip control (text, aria-label, title) and the heading of
// its list - reads "Messages" in the reader's language; at 1440 px the
// section keeps "Direct messages" (phones only, as asked).
//
// Checked at 390 px in English, Bulgarian and Finnish, and at 1440 px.
//
//   node tests/e2e/mobile-messages-label.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/mobile-messages-label.test.mjs
//   MESSAGES_LABEL_SHOTS=<dir> also writes a screenshot per case
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.MESSAGES_LABEL_SHOTS || ''
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* the catalogue words, as the owner reads them */
const CASES = [
  { lang: 'en', prefix: '', phone: 'Messages', desktop: 'Direct messages' },
  { lang: 'bg', prefix: '/bg', phone: 'Съобщения', desktop: 'Лични съобщения' },
  { lang: 'fi', prefix: '/fi', phone: 'Viestit', desktop: 'Yksityisviestit' },
]

/** every name the DM section carries on screen and for assistive tech */
const names = (p) => p.evaluate(() => {
  const tab = document.querySelector('[data-testid=sidebar-tab-dm]')
  const heading = document.querySelector('[data-testid=sidebar-help-dm]')
  const own = (e) => (e ? [...e.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join('').trim() : null)
  const rail = document.querySelector('[role=tablist][aria-label]')
  return {
    text: tab?.querySelector('.sidebar-tab__label')?.textContent.trim() ?? null,
    aria: tab?.getAttribute('aria-label') ?? null,
    title: tab?.getAttribute('title') ?? null,
    heading: own(heading),
    copies: [...document.querySelectorAll('[data-loop] .sidebar-tab__label')].map((e) => e.textContent.trim()),
    railAria: rail?.getAttribute('aria-label') ?? '',
  }
})

const srv = await startServer()
const browser = await launch()
const session = () => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
try {
  for (const c of CASES) {
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.evaluateOnNewDocument(session)
    await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
    await p.goto(`${srv.base}${c.prefix}/`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-testid=sidebar-tab-dm]', { visible: true })
    await sleep(1200)
    await p.click('[data-testid=sidebar-tab-dm]')
    await sleep(600)
    const n = await names(p)
    if (SHOTS) await p.screenshot({ path: join(SHOTS, `390-${c.lang}.png`) })
    ok(`390px ${c.lang}: the strip control reads "${c.phone}"`, n.text === c.phone && n.aria === c.phone && n.title === c.phone, n)
    ok(`390px ${c.lang}: the DM list heading reads "${c.phone}"`, n.heading === c.phone, n.heading)
    ok(`390px ${c.lang}: the rolling copies say it too`, !n.copies.includes(c.desktop) && (n.copies.length === 0 || n.copies.includes(c.phone)), n.copies)
    ok(`390px ${c.lang}: the strip's own name lists "${c.phone}", not "${c.desktop}"`, n.railAria.includes(c.phone) && !n.railAria.includes(c.desktop), n.railAria)
    await ctx.close()
  }

  for (const c of CASES) {
    const ctx = await browser.createBrowserContext()
    const d = await ctx.newPage()
    d.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await d.evaluateOnNewDocument(session)
    await d.setViewport({ width: 1440, height: 900 })
    await d.goto(`${srv.base}${c.prefix}/`, { waitUntil: 'networkidle2' })
    await d.waitForSelector('[data-testid=sidebar-tab-dm]', { visible: true })
    await sleep(800)
    await d.click('[data-testid=sidebar-tab-dm]')
    await sleep(400)
    const n = await names(d)
    if (SHOTS) await d.screenshot({ path: join(SHOTS, `1440-${c.lang}.png`) })
    ok(`1440px ${c.lang}: desktop keeps "${c.desktop}"`, n.aria === c.desktop && n.title === c.desktop && n.heading === c.desktop, n)
    await ctx.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmobile-messages-label: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
