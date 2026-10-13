// SPL-1646 (owner HUM-10, t1 9b966fe2): a ## heading inside a message card
// was rendering near page-heading size. In a card the heading stays bold and
// at most 1.15x the card's own body text (h1/h2 are 1.1em). A /docs h2 keeps
// the docs page size, which is larger than the card's.
//
// Mock bundle, one card seeded through spool.mock.extra-messages, measured
// at 390x844 and 1440x900.
//
// Run:
//   pnpm run test:e2e card-heading-size
//   BASE_URL=<generated bundle> pnpm run test:e2e card-heading-size
//   SHOT_DIR=/tmp/shots ...
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZES = [{ width: 390, height: 844 }, { width: 1440, height: 900 }]
const ROW = 'e1646001-0000-4000-8000-000000000001'
const FEATURE = 'csi-spl-doc/doc/md/csi-spl.feature.md'
const EXTRA = [{
  v: 1,
  msg_id: ROW,
  task_id: 'e1646002-0000-4000-8000-000000000001',
  ts: '2026-10-13T08:00:00Z',
  from: 'HUM-2',
  from_box: 'box-wui',
  to: '@channel',
  to_box: 'box-wui',
  kind: 'note',
  body: '## Title\n\nBody text stays at the card size.',
  files: [],
  channel: 'lobby',
  parent_task_id: null,
  is_parent: 1,
}]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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

const card = `article.msg[data-msg-id="${ROW}"]`
const cardMeasure = (p) => p.evaluate((sel) => {
  const root = document.querySelector(sel)
  const md = root && root.querySelector('[data-testid=md-block][data-rendered=true]')
  const h = md && md.querySelector('h2')
  const para = md && md.querySelector('p')
  if (!h || !para) return null
  const hs = getComputedStyle(h)
  const ps = getComputedStyle(para)
  const hPx = parseFloat(hs.fontSize)
  const pPx = parseFloat(ps.fontSize)
  return {
    hText: (h.textContent || '').trim(),
    pText: (para.textContent || '').trim(),
    hPx, pPx,
    ratio: pPx > 0 ? hPx / pPx : NaN,
    weight: Number(hs.fontWeight),
    marginTop: parseFloat(hs.marginTop),
    marginBottom: parseFloat(hs.marginBottom),
    vw: window.innerWidth,
    vh: window.innerHeight,
  }
}, card)

const docsMeasure = (p) => p.evaluate(() => {
  const doc = document.querySelector('[data-test=docs-content]')
  const h = doc && [...doc.querySelectorAll('h2')].find((el) => (el.textContent || '').trim() === 'Posting')
  if (!h) return null
  return { hPx: parseFloat(getComputedStyle(h).fontSize), text: h.textContent.trim() }
})

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}x${size.height}`
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.evaluateOnNewDocument((rows) => {
      try {
        localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
        localStorage.setItem('spool.mock.session', JSON.stringify({
          hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
        }))
      } catch { /* private mode */ }
    }, EXTRA)
    await setPageViewport(p, size)
    await p.goto(`${server.base}/lobby`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    const ready = await p.waitForFunction((sel) => {
      const root = document.querySelector(sel)
      const md = root && root.querySelector('[data-testid=md-block][data-rendered=true]')
      return Boolean(md && md.querySelector('h2') && md.querySelector('p'))
    }, { timeout: NAV_TIMEOUT }, card).then(() => true, () => false)
    const m = ready ? await cardMeasure(p) : null
    console.log(`  ${tag} card: ${JSON.stringify(m)}`)
    if (process.env.SHOT_DIR && size.width === 390) {
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, 'card-heading-390.png') })
    }
    ok(`${tag}: the card rendered ## Title`, Boolean(m) && m.hText === 'Title' && m.vw === size.width && m.vh === size.height, m)
    ok(`${tag}: the heading is at most 1.15x the card body`, Boolean(m) && m.ratio <= 1.15 && m.ratio >= 1.05, m && m.ratio)
    ok(`${tag}: the heading is bold`, Boolean(m) && m.weight >= 600, m && m.weight)
    ok(`${tag}: the heading margins are tight`, Boolean(m) && m.marginTop <= m.hPx * 0.25 && m.marginBottom <= m.hPx * 0.25, m && [m.marginTop, m.marginBottom, m.hPx])

    await p.goto(`${server.base}/docs/${FEATURE}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    const docsReady = await p.waitForFunction(() => {
      const doc = document.querySelector('[data-test=docs-content]')
      return Boolean(doc && [...doc.querySelectorAll('h2')].some((el) => (el.textContent || '').trim() === 'Posting'))
    }, { timeout: NAV_TIMEOUT }).then(() => true, () => false)
    const d = docsReady ? await docsMeasure(p) : null
    console.log(`  ${tag} docs: ${JSON.stringify(d)}`)
    ok(`${tag}: a /docs h2 stays larger than the card heading`, Boolean(m && d) && d.hPx > m.hPx, { card: m && m.hPx, docs: d && d.hPx })
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
