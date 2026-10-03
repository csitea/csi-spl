// Owner, t1 77540e6f (HUM-10): "7 new messages" over Direct messages while
// no DM row showed anything new. Proved in a REAL browser against the mock
// bundle: each section's red number is the sum of the unread badges on the
// rows it lists - Direct messages, Channels and Topics - because both read
// one map, the hub's Flow `keys` (the mock derives them from its feed).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e unread-sum
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZE = { width: 1440, height: 900 }
const SECTIONS = [
  { tab: 'dm', badge: '[data-test=dm-badge]' },
  { tab: 'channels', badge: '[data-testid=channel-unread]' },
  { tab: 'topics', badge: '[data-testid=topic-unread]' },
]

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

/* A section's rail number and the sum of its rows' badges ("2/7" reads 2). */
function section(page, tab, badge) {
  return page.evaluate((id, sel) => {
    const rail = document.querySelector(`[data-testid=sidebar-tab-${id}-count]`)?.textContent.trim() || ''
    const panel = document.querySelector(`[data-testid=sidebar-panel-${id}]`) || document.getElementById(`sidebar-panel-${id}`)
    const rows = panel ? [...panel.querySelectorAll(sel)].map((b) => parseInt(b.textContent.trim(), 10) || 0) : []
    return { rail: rail === '' ? 0 : parseInt(rail, 10), rows, sum: rows.reduce((a, b) => a + b, 0), panel: Boolean(panel) }
  }, tab, badge)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
  await setPageViewport(p, SIZE)
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, SIZE)
  /* the hub's (mock's) counts have landed: the Flow tab carries its number */
  await p.waitForSelector('[data-testid=sidebar-tab-flow-count]', { timeout: NAV_TIMEOUT }).catch(() => {})
  let any = 0
  for (const s of SECTIONS) {
    await p.click(`[data-testid=sidebar-tab-${s.tab}]`)
    await p.waitForSelector(`#sidebar-panel-${s.tab}`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
    await new Promise((r) => setTimeout(r, 300))
    const f = await section(p, s.tab, s.badge)
    any += f.rail
    ok(`${s.tab}: the section number is the sum of its rows' unread`, f.panel && f.rail === f.sum, f)
  }
  ok('the mock reader has something unread (the check is not vacuous)', any > 0, { any })
  ok('no page error', errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
