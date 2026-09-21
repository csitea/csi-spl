// 013 US7 FR-012 (CLE-3412): in a real browser (mock tenant, nuxi dev), a
// reader scrolled down in #lobby keeps the row they look at in place when
// rows are prepended, and gets the "new" pill; at the top, rows just enter.
// Rows are injected through the page's own Pinia store, as a live frame would.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const fails = []
const ok = (name, pass, ev) => { console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name} ${JSON.stringify(ev)}`); if (!pass) fails.push(name) }
const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  for (const height of [480, 800]) {
    await p.setViewport({ width: 1280, height })
    await p.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('.live-rows > article.msg', { timeout: 60000 })
    /* enough rows to scroll, then scroll the real scroller down */
    /* seeds sit in the past, later injections after everything held (newest first = on top) */
    let clock = Date.now() - 3600e3
    const inject = (n, tag) => p.evaluate((n, tag, base) => {
      const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
      const s = pinia._s.get('live-main')
      const rows = []
      for (let i = 0; i < n; i++) {
        const ts = new Date(base + i * 1000).toISOString()
        rows.push({ v: 1, msg_id: `${tag}-${i}-${Date.now()}`, task_id: s.taskId, ts, received_at: ts, from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: `${tag} ${i}\nsecond line\nthird line`, files: [] })
      }
      s.messages = [...s.messages, ...rows]
    }, n, tag, (clock += 120e3))
    await inject(30, 'seed')
    await new Promise((r) => setTimeout(r, 500))
    const before = await p.evaluate(() => {
      const sc = (() => {
        for (let n = document.querySelector('.live-feed'); n; n = n.parentElement) {
          const oy = getComputedStyle(n).overflowY
          if ((oy === 'auto' || oy === 'scroll') && n.scrollHeight > n.clientHeight + 1) return n
        }
        return document.scrollingElement
      })()
      window.__sc = sc
      sc.scrollTop = 400
      const edge = sc === document.scrollingElement ? 0 : sc.getBoundingClientRect().top
      const row = [...document.querySelectorAll('.live-rows > article.msg')].find((r) => r.getBoundingClientRect().top >= edge + 60)
      window.__anchor = row
      return { page: sc === document.scrollingElement, top: sc.scrollTop, y: row.getBoundingClientRect().top }
    })
    await new Promise((r) => setTimeout(r, 300))
    await inject(2, 'live')
    await new Promise((r) => setTimeout(r, 1200))
    const after = await p.evaluate(() => ({ top: window.__sc.scrollTop, y: window.__anchor.getBoundingClientRect().top, pill: !!document.querySelector('[data-testid=new-pill]') }))
    ok(`${height}px (${before.page ? 'page' : 'feed-body'} scrolls): the row in view stays put, pill shown`, Math.abs(after.y - before.y) < 2 && after.pill && after.top > before.top, { before, after })
    /* CLE-3425: "shown" has to mean ON SCREEN AND HITTABLE. This test used to
       assert only that the element exists, and it did exist - at y = -379 px,
       scrolled out of view, because `position: sticky` resolved against
       .feed-body (overflow-y: auto) which never scrolls here. The click below
       then threw "Node is either not clickable" instead of failing a check. */
    const seen = await p.evaluate(() => {
      const el = document.querySelector('[data-testid=new-pill]')
      if (!el) return { pill: false }
      const r = el.getBoundingClientRect()
      const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
      return { pill: true, top: r.top, bottom: r.bottom, vh: window.innerHeight, hit: at === el || (at ? el.contains(at) : false) }
    })
    ok(`${height}px: the pill is on screen and hittable, not just present`,
      seen.pill && seen.top >= 0 && seen.bottom <= seen.vh && seen.hit, seen)
    if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/scroll-anchor-${height}.png` })
    await p.click('[data-testid=new-pill]')
    await new Promise((r) => setTimeout(r, 1000))
    const back = await p.evaluate(() => ({ top: window.__sc.scrollTop, pill: !!document.querySelector('[data-testid=new-pill]') }))
    ok(`${height}px: the pill jumps to the newest and goes away`, back.top <= 80 && !back.pill, back)
    await inject(1, 'attop')
    await new Promise((r) => setTimeout(r, 800))
    const top = await p.evaluate(() => ({ top: window.__sc.scrollTop, pill: !!document.querySelector('[data-testid=new-pill]') }))
    ok(`${height}px: at the top a new row just enters (no pill, no scroll)`, top.top <= 80 && !top.pill, top)
  }
} finally {
  await browser.close()
  await srv.stop()
}
console.log(fails.length ? `\n${fails.length} failed` : '\nall scroll-anchor checks passed')
process.exit(fails.length ? 1 : 0)
