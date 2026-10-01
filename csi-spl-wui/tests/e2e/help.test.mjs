// W14 (spec 047, SPL-1169): help reachable in 1 click. The ? at the foot of
// the left rail opens /help (the index of csi-spl-doc/doc/help, rendered);
// a sibling link opens the page in the app; an unknown page says so; the
// sign-in page links the help too; on a phone the ? ends the section strip.
//
// Control: before W14 there is no [data-testid=help-open] (0 clicks reach help).
//
// Run:
//   pnpm run test:e2e help
//   BASE_URL=<generated bundle> pnpm run test:e2e help
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

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

const rendered = (p) => p.waitForSelector('[data-test=help-content] [data-testid=md-block][data-rendered=true]', { timeout: 15000 }).then(() => true, () => false)
const content = (p) => p.$eval('[data-test=help-content]', (el) => ({ page: el.getAttribute('data-page'), h1: el.querySelector('h1')?.textContent || '', text: el.textContent || '' }))

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1280x800')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const open = await p.waitForSelector('[data-testid=help-open]', { visible: true, timeout: 15000 }).catch(() => null)
  ok('the left rail carries a Help entry', Boolean(open))
  if (open) {
    const label = await open.evaluate((el) => el.getAttribute('aria-label'))
    ok('it is named for assistive tech', label === 'Help', label)
    await open.click()
    await p.waitForFunction(() => location.pathname === '/help', { timeout: 10000 }).catch(() => {})
    ok('one click lands on /help', new URL(p.url()).pathname === '/help', p.url())
    ok('the help index renders as markdown', await rendered(p))
    const c = await content(p)
    ok('it is the doc/help index', c.page === 'index' && /Help Center/.test(c.h1), c.h1)
    const nav = await p.$$eval('[data-test=help-nav] a', (as) => as.map((a) => a.textContent.trim()))
    ok('the page list names every help page', nav.length >= 12 && nav.includes('Getting Started with Spool'), nav.length)
    /* a sibling link (./getting-started.md) opens in the app, same tab */
    const link = await p.$('[data-test=help-content] a[href="/help/getting-started"]')
    ok('a ./x.md link became the /help/x route', Boolean(link))
    if (link) {
      await link.click()
      await p.waitForFunction(() => location.pathname === '/help/getting-started', { timeout: 10000 }).catch(() => {})
      ok('it opens in this tab', new URL(p.url()).pathname === '/help/getting-started', p.url())
      await p.waitForFunction(() => document.querySelector('[data-test=help-content]')?.getAttribute('data-page') === 'getting-started', { timeout: 10000 }).catch(() => {})
      ok('the page renders', await rendered(p))
      const g = await content(p)
      ok('it is Getting Started', /Getting Started/.test(g.h1), g.h1)
      const host = new URL(server.base).host
      ok('the host is fixed: this site\'s own, no per-tenant address, no token left', !/<tenant/.test(g.text) && g.text.includes(host) && !g.text.includes('{{'), host)
      ok('it says to ask the admin for an invite', /ask your admin for an invite/.test(g.text))
    }
  }
  await p.goto(server.base + '/help/no-such-page', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('an unknown page says so', Boolean(await p.waitForSelector('[data-test=help-missing]', { timeout: 10000 }).catch(() => null)))

  await p.goto(server.base + '/login', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const lh = await p.waitForSelector('[data-test=login-help]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('the sign-in page links the help', Boolean(lh))
  if (lh) ok('to /help', (await lh.evaluate((a) => new URL(a.href).pathname)) === '/help')
  await p.close()

  console.log('-- 390x740 phone')
  const m = await browser.newPage()
  await m.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const mo = await m.waitForSelector('[data-testid=help-open]', { visible: true, timeout: 15000 }).catch(() => null)
  const box = mo ? await mo.boundingBox() : null
  ok('the phone strip carries Help, a 44 px target', Boolean(box && box.width >= 44 && box.height >= 44), box)
  if (mo) {
    await mo.tap()
    await m.waitForFunction(() => location.pathname === '/help', { timeout: 10000 }).catch(() => {})
    ok('one tap lands on /help', new URL(m.url()).pathname === '/help', m.url())
    ok('the index renders on a phone', await rendered(m))
    const sw = await m.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
    ok('no sideways scroll on a phone', sw)
  }
  await m.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `help: ${failed} FAILED` : `help: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
