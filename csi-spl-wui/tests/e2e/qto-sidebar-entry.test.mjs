// Owner HUM-10 (t1 4296200d, msg ed921572): "where this qto ui can be
// accessed from". The rail carries a "Docs (Qto)" entry for a signed-in
// member, next to Docs; one click opens /workspace/docs (spec 113 T006),
// the workspace documents. A phone strip carries it too. Signed out it is
// absent while Docs stays.
//
// Control: before the entry there is no [data-testid=qto-open], so every
// signed-in check FAILS on the earlier master.
//
//   node tests/e2e/qto-sidebar-entry.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/qto-sidebar-entry.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { MOCK_SIGNED_OUT_KEY } from '../../src/utils/act-as-mock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const STEP = 15000
const PUBLIC_DOC = 'csi-spl-doc/doc/help/getting-started.md'
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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const onPage = (p) => p.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: STEP }).then(Boolean, () => false)

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1280x800 signed in')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const open = await p.waitForSelector('[data-testid=qto-open]', { visible: true, timeout: STEP }).catch(() => null)
  ok('the rail carries a Docs (Qto) entry', Boolean(open))
  if (open) {
    ok('it is named for assistive tech', (await open.evaluate((el) => el.getAttribute('aria-label'))) === 'Docs (Qto)')
    ok('it sits right after Docs', await p.evaluate(() => document.querySelector('[data-testid=docs-open]')?.nextElementSibling?.getAttribute('data-testid') === 'qto-open'))
    await open.click()
    await p.waitForFunction(() => location.pathname === '/workspace/docs', { timeout: STEP }).catch(() => {})
    ok('one click lands on /workspace/docs', new URL(p.url()).pathname === '/workspace/docs', p.url())
    ok('the workspace documents render', await onPage(p))
    ok('the entry is marked active there', await p.$eval('[data-testid=qto-open]', (el) => el.classList.contains('router-link-active')).catch(() => false))
  }
  await p.close()

  console.log('-- 390x740 phone')
  const m = await browser.newPage()
  await m.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('the phone strip carries Docs (Qto)', Boolean(await m.waitForSelector('[data-testid=qto-open]', { timeout: STEP }).catch(() => null)))
  /* the strip rolls endlessly (CLE-77886): swipe until an entry is in view, tap it */
  const spot = () => m.evaluate(() => {
    const rail = document.querySelector('[data-testid=sidebar-rail]')
    const rb = rail.getBoundingClientRect()
    for (const h of document.querySelectorAll('.sidebar-rail__qto')) {
      const r = h.getBoundingClientRect()
      if (r.width && r.left >= Math.max(rb.left, 0) && r.right <= Math.min(rb.right, window.innerWidth)) {
        return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }
      }
    }
    return null
  })
  let at = await spot()
  for (let i = 0; !at && i < 60; i++) {
    await m.evaluate(() => { document.querySelector('[data-testid=sidebar-rail]').scrollLeft += 40 })
    await new Promise((r) => setTimeout(r, 50))
    at = await spot()
  }
  ok('a swipe brings it into view, a 44 px target', Boolean(at && at.w >= 44 && at.h >= 44), at)
  if (at) await m.touchscreen.tap(at.x, at.y)
  await m.waitForFunction(() => location.pathname === '/workspace/docs', { timeout: STEP }).catch(() => {})
  ok('one tap lands on /workspace/docs', new URL(m.url()).pathname === '/workspace/docs', m.url())
  await m.close()

  console.log('-- signed out')
  const o = await browser.newPage()
  await o.setViewport({ width: 1280, height: 800 })
  await o.evaluateOnNewDocument((key) => { try { localStorage.setItem(key, 'true') } catch { /* no storage: the checks below fail */ } }, MOCK_SIGNED_OUT_KEY)
  await o.goto(server.base + '/docs/' + PUBLIC_DOC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const docs = await o.waitForSelector('[data-testid=docs-open]', { timeout: STEP }).catch(() => null)
  ok('signed out: CONTROL the rail is drawn (Docs is there)', Boolean(docs))
  ok('signed out: no Docs (Qto) entry', !(await o.$('[data-testid=qto-open]')) && !(await o.$('.sidebar-rail__qto')))
  await o.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-sidebar-entry: ${failed} FAILED` : `qto-sidebar-entry: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
