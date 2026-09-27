// SPL-993 (epic SPL-988, lane M5): settings, dialogs and the other pages on a
// phone, proved in a REAL browser at 360 and 820 px, plus the 1440 px desktop
// that must not change.
//
//   dialog  - at <= 600 px every UiDialog fills the viewport, with a top bar:
//             a Back chevron >= 44 px at the start edge (it closes the dialog)
//             and the title; the desktop X is hidden; inputs are >= 16 px so
//             iOS does not zoom. At 820 the dialog stays a card, its X a 44 px
//             target, inputs still >= 16 px; 1440 is the desktop, unchanged.
//
// CONTROL: every width asserts the OPPOSITE state at the other widths (a
// full-screen dialog at 1440 fails, a card at 360 fails), so a selector that
// matches nothing cannot read green.
//
// Run:
//   node tests/e2e/mobile-m5.test.mjs
//   BASE_URL=<generated mock bundle> node tests/e2e/mobile-m5.test.mjs   # CI
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const WIDTHS = [
  { w: 360, h: 740, mobile: true, phone: true },
  { w: 820, h: 1000, mobile: true, phone: false },
  { w: 1440, h: 900, mobile: false, phone: false },
]

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
      return (mod.default ?? mod).launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// One signed-in owner: the hub's auth routes only (display-name.test.mjs).
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
function answer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && req.method() === 'GET') {
    return json(200, {
      v: 1, p: 'password', sub: 'person@example.com', email: 'person.with.a.long.address@example.com', name: 'FirstName LastName',
      hum: 'HUM-4', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  if (path === 'events') {
    return json(200, {
      events: [
        { id: 2, error_id: 'e-2-0123456789abcdef', at: '2026-09-27T08:00:00Z', received_at: '2026-09-27T08:00:01Z', source: 'wui', status: 500,
          message: 'a long message that has to wrap on a phone and must never widen the page', route: '/channel/lobby?with=a-long-query-string-that-does-not-break' },
        { id: 1, error_id: 'e-1', at: '2026-09-27T07:00:00Z', received_at: '2026-09-27T07:00:01Z', source: 'hub', status: 404, message: 'not found', route: '/t/abc' },
      ],
      next_before: 0,
    })
  }
  return json(404, { error: 'not_found' })
}

async function page(browser, vp) {
  const p = await browser.newPage()
  await p.setViewport({ width: vp.w, height: vp.h, isMobile: vp.mobile, hasTouch: vp.mobile, deviceScaleFactor: 1 })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const a = answer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  return p
}

const noXScroll = (p) => p.evaluate(() => {
  const se = document.scrollingElement
  return { sw: se.scrollWidth, iw: window.innerWidth, ok: se.scrollWidth <= window.innerWidth }
})

async function openCreateChannel(p, base) {
  await p.goto(base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const visible = (sel) => p.$eval(sel, (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 }).catch(() => false)
  if (!(await visible('[data-testid=create-channel]'))) {
    await p.click('[data-testid=sidebar-tab-channels]').catch(() => null)
    await p.waitForFunction(() => {
      const e = document.querySelector('[data-testid=create-channel]')
      const r = e?.getBoundingClientRect()
      return r && r.width > 0
    }, { timeout: 10000 }).catch(() => null)
  }
  await p.click('[data-testid=create-channel]')
  await p.waitForSelector('[data-testid=ui-dialog]', { visible: true, timeout: 10000 })
  await sleep(200)
}

async function checkDialog(browser, base, vp) {
  const p = await page(browser, vp)
  const tag = `dialog@${vp.w}`
  try {
    await openCreateChannel(p, base)
    const m = await p.evaluate(() => {
      const box = (sel) => {
        const e = document.querySelector(sel)
        if (!e) return null
        const r = e.getBoundingClientRect()
        const cs = getComputedStyle(e)
        return { x: r.left, y: r.top, w: r.width, h: r.height, shown: cs.display !== 'none' && r.width > 0 }
      }
      const input = document.querySelector('[data-testid=ui-dialog-body] input')
      return {
        vw: window.innerWidth, vh: window.innerHeight,
        panel: box('[data-testid=ui-dialog]'),
        back: box('[data-testid=ui-dialog-back]'),
        close: box('[data-testid=ui-dialog-close]'),
        inputPx: input ? parseFloat(getComputedStyle(input).fontSize) : 0,
      }
    })
    const full = m.panel && Math.abs(m.panel.x) < 1 && Math.abs(m.panel.y) < 1 && Math.abs(m.panel.w - m.vw) < 1 && Math.abs(m.panel.h - m.vh) < 1
    if (vp.phone) {
      ok(`${tag} the dialog fills the viewport`, Boolean(full), m.panel)
      ok(`${tag} Back is shown at the start edge, >= 44 px`, Boolean(m.back?.shown && m.back.w >= 44 && m.back.h >= 44 && m.back.x < 16), m.back)
      ok(`${tag} the desktop X is hidden`, m.close?.shown === false, m.close)
      ok(`${tag} inputs are >= 16 px (no iOS zoom)`, m.inputPx >= 16, { inputPx: m.inputPx })
    } else {
      ok(`${tag} CONTROL: the dialog is a card, not full screen`, !full && Boolean(m.panel?.shown), m.panel)
      ok(`${tag} CONTROL: Back is hidden, the X is shown`, m.back?.shown === false && Boolean(m.close?.shown), { back: m.back, close: m.close })
      if (vp.mobile) {
        ok(`${tag} the X is a >= 44 px touch target`, m.close?.w >= 44 && m.close?.h >= 44, m.close)
        ok(`${tag} inputs are >= 16 px (no iOS zoom)`, m.inputPx >= 16, { inputPx: m.inputPx })
      } else {
        ok(`${tag} CONTROL: the desktop X keeps its 32 px`, m.close?.w === 32, m.close)
      }
    }
    const x = await noXScroll(p)
    ok(`${tag} no horizontal page scroll`, x.ok, x)
    await p.click(vp.phone ? '[data-testid=ui-dialog-back]' : '[data-testid=ui-dialog-close]')
    const gone = await p.waitForSelector('[data-testid=ui-dialog]', { hidden: true, timeout: 5000 }).then(() => true).catch(() => false)
    ok(`${tag} ${vp.phone ? 'Back' : 'X'} closes the dialog`, gone)
  } catch (e) {
    ok(`${tag} ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of WIDTHS) await checkDialog(browser, server.base, vp)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
