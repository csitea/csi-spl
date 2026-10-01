// SPL-980 (owner 2026-09-27, topic 72773b61): "check the selected entry in
// the tenants drop down, it needs 2 px in front and 2 px after it within the
// drop down control, the dropping list borders that is".
//
// The native popup ignores padding, so the selected row touched both list
// borders. HUM-10: the switcher is a combobox and the page always draws the
// open list (its listbox): 2 px of the list between every row and its
// border, each name 4 px inside its row. At 1440 px, light and dark, with
// several synthetic tenants (the longest one selected), the list is opened
// and measured:
//   - the list is drawn by the page (a listbox, aria-expanded), padding 2 px
//   - every row, the selected one too, starts >= 2 px inside the list's
//     inner edge on the left and ends >= 2 px inside it on the right
//     (elementFromPoint 1 px outside a row still hits the list, not the page)
//   - each name sits 4 px inside its row, no name is clipped
//   - the selected row is highlighted, Esc closes the list
// And the closed box is unchanged: the widest name, 2 px, the arrow 7 px on.
//
// Run:
//   node tests/e2e/tenant-list-inset.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/tenant-list-inset.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const TENANTS = [
  { tenant_id: 't1', name: 'northwind-trading' },
  { tenant_id: 't2', name: 'globex' },
  { tenant_id: 't3', name: 'initech' },
  { tenant_id: 't4', name: 'umbrella' },
]
const results = []
function check(name, pass, ev) {
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const measureOpen = (p) => p.evaluate(() => {
  const sel = document.querySelector('[data-testid=tenant-switcher-select]')
  const list = document.querySelector('[data-testid=tenant-switcher-list]')
  const pk = getComputedStyle(list)
  const rows = [...list.querySelectorAll('[role=option]')].map((o) => {
    const r = o.getBoundingClientRect()
    const range = document.createRange()
    range.selectNodeContents(o)
    const t = range.getBoundingClientRect()
    const mid = r.top + r.height / 2
    const hit = (x) => { const e = document.elementFromPoint(x, mid); return e === list }
    return {
      text: o.textContent.trim(), selected: o.getAttribute('aria-selected') === 'true',
      left: +r.left.toFixed(2), right: +r.right.toFixed(2), w: +r.width.toFixed(2), h: +r.height.toFixed(2),
      textIn: +(t.left - r.left).toFixed(2), textOut: +(r.right - t.right).toFixed(2),
      clipped: o.scrollWidth > o.clientWidth + 1,
      bg: getComputedStyle(o).backgroundColor,
      listLeftOf: hit(r.left - 1), listRightOf: hit(r.right + 1),
    }
  })
  return {
    role: list.getAttribute('role'),
    open: sel.getAttribute('aria-expanded') === 'true' && pk.display !== 'none',
    pad: [pk.paddingLeft, pk.paddingRight, pk.paddingTop, pk.paddingBottom],
    border: [pk.borderLeftWidth, pk.borderRightWidth],
    rows,
  }
})

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const theme of ['light', 'dark']) {
    const tag = `1440 ${theme}`
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 })
    await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.evaluate((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private */ } }, theme)
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-testid=tenant-switcher-select]', { timeout: NAV_TIMEOUT })
    const seeded = await p.evaluate((tenants) => {
      const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
      if (!session) return false
      session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', tenants })
      return true
    }, TENANTS)
    const countRows = () => document.querySelectorAll('[data-testid=tenant-switcher-option]').length
    await p.waitForFunction((n) => document.querySelectorAll('[data-testid=tenant-switcher-option]').length === n, { timeout: 15000 }, TENANTS.length).catch(() => null)
    await sleep(400)
    const n = await p.evaluate(countRows)
    check(`${tag}: ${TENANTS.length} tenants in the list, the longest selected`, seeded && n === TENANTS.length, { seeded, n })
    await p.click('[data-testid=tenant-switcher-select]')
    await sleep(400)
    const m = await measureOpen(p)
    check(`${tag}: the page draws the open list (a listbox)`, m.role === 'listbox' && m.open, { role: m.role, open: m.open })
    check(`${tag}: the list has 2 px between its border and the rows`, m.pad[0] === '2px' && m.pad[1] === '2px' && parseFloat(m.border[0]) >= 1, { pad: m.pad, border: m.border })
    const sel = m.rows.find((r) => r.selected)
    check(`${tag}: the selected row is the longest name`, sel?.text === 'northwind-trading', sel)
    check(`${tag}: every row, the selected one too, has list on both sides (not touching the border)`, m.rows.length === TENANTS.length && m.rows.every((r) => r.listLeftOf && r.listRightOf), m.rows.map((r) => ({ t: r.text, l: r.listLeftOf, r: r.listRightOf })))
    check(`${tag}: each name 4 px inside its row, none clipped`, m.rows.every((r) => r.textIn >= 3.5 && r.textOut >= 3.5 && !r.clipped), m.rows.map((r) => ({ t: r.text, in: r.textIn, out: r.textOut, clipped: r.clipped })))
    check(`${tag}: the selected row is highlighted`, Boolean(sel) && !/rgba\(0, 0, 0, 0\)|transparent/.test(sel.bg) && m.rows.filter((r) => !r.selected).every((r) => r.bg !== sel.bg), m.rows.map((r) => ({ t: r.text, bg: r.bg })))
    if (OUT) {
      const box = await p.evaluate(() => {
        const rs = [...document.querySelectorAll('[data-testid=tenant-switcher-option]')].map((o) => o.getBoundingClientRect())
        const f = document.querySelector('[data-testid=tenant-switcher-box]').getBoundingClientRect()
        const left = Math.min(f.left, ...rs.map((r) => r.left)) - 16
        const right = Math.max(f.right, ...rs.map((r) => r.right)) + 16
        return { x: Math.max(0, left), y: Math.max(0, f.top - 8), width: right - Math.max(0, left), height: Math.max(...rs.map((r) => r.bottom)) - f.top + 24 }
      })
      await p.screenshot({ path: `${OUT}/tenant-list-open-1440-${theme}.png`, clip: box })
    }
    await p.keyboard.press('Escape')
    await sleep(300)
    check(`${tag}: Esc closes the list`, await p.evaluate(() => document.querySelector('[data-testid=tenant-switcher-select]').getAttribute('aria-expanded') === 'false'
      && getComputedStyle(document.querySelector('[data-testid=tenant-switcher-list]')).display === 'none'))
    await ctx.close()
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntenant-list-inset: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
