// SPL-993 (epic SPL-988, lane M5): settings, dialogs and the other pages on a
// phone, proved in a REAL browser at 360 and 820 px, plus the 1440 px desktop
// that must not change.
//
//   dialog  - at <= 600 px every UiDialog fills the viewport, with a top bar:
//             a Back chevron >= 44 px at the start edge (it closes the dialog)
//             and the title; the desktop X is hidden; inputs are >= 16 px so
//             iOS does not zoom. At 820 the dialog stays a card, its X a 44 px
//             target, inputs still >= 16 px; 1440 is the desktop, unchanged.
//   settings - at <= 820 px /settings is the LIST of sections (no redirect),
//             one >= 44 px row each; a tap opens the section alone (list
//             hidden, heading = the section), and Back (the MobileBack
//             chevron, browser Back) returns to the list. <= 480 px: the
//             profile facts stack label over value. 1440: /settings still
//             redirects to /settings/profile with the nav beside it.
//             Every button, link and select in every section is >= 44 px,
//             and a checkbox / radio has a label (or row) >= 44 px tall.
//   rail     - Settings -> Behaviour -> Left panel order reorders by TOUCH:
//             a finger drag on a row's grip (CDP touch events, not a mouse)
//             moves the row and PUTs the new rail_order once; grip and
//             up / down are >= 44 px targets at <= 820 px.
//   pages    - /events at <= 600 px: one card per event, its label beside each
//             value (no 6-column squeeze); /archive, /events, /login and
//             /reset-password never scroll sideways at 360 px.
//   keyboard - /login and /reset-password at 360 px with a field focused and
//             the viewport cut to 400 px (the keyboard open, as
//             interactive-widget=resizes-content does): the field is in
//             view, the submit button can be scrolled to, inputs >= 16 px.
//   users    - at <= 820 px a tap on a Users row opens the edit pane ALONE,
//             full width (level 3, list hidden, the X replaced by MobileBack),
//             and browser Back returns to the list. 1440: pane beside list.
//   search   - /search and /search?q= never scroll sideways at 360 px.
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
const puts = []
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
let signedOut = false
function answer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && signedOut) return json(401, { error: 'unauthenticated' })
  if (path === 'session' && req.method() === 'GET') {
    return json(200, {
      v: 1, p: 'password', sub: 'person@example.com', email: 'person.with.a.long.address@example.com', name: 'FirstName LastName',
      hum: 'HUM-4', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  if (path === 'preferences' && req.method() === 'PUT') {
    let body = {}
    try { body = JSON.parse(req.postData() || '{}') } catch { /* counted as {} */ }
    puts.push(body)
    return json(200, body)
  }
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

const shown = (p, sel) => p.$eval(sel, (e) => { const r = e.getBoundingClientRect(); return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0 }).catch(() => false)

async function checkSettings(browser, base, vp) {
  const p = await page(browser, vp)
  const tag = `settings@${vp.w}`
  try {
    await p.goto(base + '/settings', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=settings-nav]', { timeout: NAV_TIMEOUT })
    await sleep(300)
    const path0 = new URL(p.url()).pathname
    const rows = await p.$$eval('[data-test=settings-nav] a', (as) => as.map((a) => { const r = a.getBoundingClientRect(); return { w: r.width, h: r.height } }))
    const content0 = await shown(p, '[data-test=settings-content]')
    if (!vp.mobile) {
      ok(`${tag} CONTROL: /settings redirects to profile, nav beside the content`, path0.endsWith('/settings/profile') && content0 && await shown(p, '[data-test=settings-nav]'), { path0, content0 })
      return
    }
    const vw = vp.w
    ok(`${tag} /settings stays the list (no redirect), content hidden`, /\/settings\/?$/.test(path0) && !content0, { path0, content0 })
    ok(`${tag} 7 rows, each >= 44 px high and near full width`, rows.length === 7 && rows.every((r) => r.h >= 44 && r.w >= vw - 64), rows)
    let x = await noXScroll(p)
    ok(`${tag} list: no horizontal page scroll`, x.ok, x)

    await p.click('[data-test=settings-nav-keys]')
    await p.waitForFunction(() => location.pathname.endsWith('/settings/keys'), { timeout: 10000 }).catch(() => null)
    await sleep(300)
    const h = await p.$eval('#settings-h', (e) => e.textContent.trim()).catch(() => '')
    const navGone = !(await shown(p, '[data-test=settings-nav]'))
    ok(`${tag} a tap opens the section alone, heading = the section`, navGone && await shown(p, '[data-test=settings-content]') && h !== 'Settings' && h.length > 0, { h, navGone })
    ok(`${tag} the MobileBack chevron is shown`, await shown(p, '[data-testid=mobile-back]'))
    x = await noXScroll(p)
    ok(`${tag} section: no horizontal page scroll`, x.ok, x)

    await p.goBack({ waitUntil: 'networkidle2' }).catch(() => null)
    await sleep(400)
    ok(`${tag} browser Back returns to the list`, /\/settings\/?$/.test(new URL(p.url()).pathname) && await shown(p, '[data-test=settings-nav]'), { url: p.url() })

    await p.click('[data-test=settings-nav-profile]')
    await p.waitForFunction(() => location.pathname.endsWith('/settings/profile'), { timeout: 10000 }).catch(() => null)
    await sleep(300)
    const facts = await p.$$eval('.settings__facts dt, .settings__facts dd', (es) => es.slice(0, 2).map((e) => e.getBoundingClientRect().left))
    if (vp.w <= 480) ok(`${tag} profile facts stack label over value`, facts.length === 2 && Math.abs(facts[0] - facts[1]) < 1, facts)
    else ok(`${tag} CONTROL: profile facts keep two columns above 480 px`, facts.length === 2 && facts[1] > facts[0] + 20, facts)
    await p.click('[data-testid=mobile-back]').catch(() => null)
    await sleep(400)
    ok(`${tag} the Back chevron returns to the list`, /\/settings\/?$/.test(new URL(p.url()).pathname) && await shown(p, '[data-test=settings-nav]'), { url: p.url() })

    // every section: touch targets
    const small = []
    for (const id of ['profile', 'language', 'appearance', 'behaviour', 'notifications', 'security', 'keys']) {
      await p.goto(base + '/settings/' + id, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector('[data-test=settings-content]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
      await sleep(300)
      small.push(...await p.evaluate((sec) => {
        const out = []
        const box = (e) => e.getBoundingClientRect()
        for (const e of document.querySelectorAll('[data-test=settings-content] :is(a[href],button,select)')) {
          const r = box(e)
          if (r.width > 0 && (r.width < 44 || r.height < 44)) out.push(`${sec}: ${e.tagName} ${Math.round(r.width)}x${Math.round(r.height)} ${(e.textContent || '').trim().slice(0, 16)}`)
        }
        for (const e of document.querySelectorAll('[data-test=settings-content] input:is([type=checkbox],[type=radio])')) {
          const host = e.closest('label') || (e.id && document.querySelector(`label[for="${e.id}"]`)) || e.parentElement
          const r = box(host)
          if (box(e).width > 0 && r.height < 44) out.push(`${sec}: ${e.type} target ${Math.round(r.width)}x${Math.round(r.height)}`)
        }
        return out
      }, id))
    }
    ok(`${tag} every settings control is a >= 44 px touch target`, small.length === 0, small)

    // a deep link: no list entry below it in history, Back still lands on the list
    await p.goto(base + '/settings/behaviour', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-testid=mobile-back]', { visible: true, timeout: 10000 }).catch(() => null)
    await p.click('[data-testid=mobile-back]').catch(() => null)
    await sleep(500)
    ok(`${tag} deep link: Back lands on the list`, /\/settings\/?$/.test(new URL(p.url()).pathname) && await shown(p, '[data-test=settings-nav]'), { url: p.url() })
  } catch (e) {
    ok(`${tag} ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
}

async function checkRailTouch(browser, base, vp) {
  const p = await page(browser, vp)
  const tag = `rail@${vp.w}`
  try {
    await p.goto(base + '/settings/behaviour', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=rail-order-list] li', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    const ids = () => p.$$eval('[data-test=rail-order-list] li', (ls) => ls.map((l) => l.dataset.reorderId))
    const before = await ids()
    const g = await p.$$eval('[data-test=rail-order-list] li', (ls) => ls.map((l) => {
      const grip = l.querySelector('.rail-order__grip').getBoundingClientRect()
      const up = l.querySelector('.icon-btn').getBoundingClientRect()
      const r = l.getBoundingClientRect()
      return { gx: grip.left + grip.width / 2, gy: grip.top + grip.height / 2, gw: grip.width, gh: grip.height, uw: up.width, uh: up.height, cy: r.top + r.height / 2 }
    }))
    if (vp.mobile) ok(`${tag} grip and up / down are >= 44 px`, g.every((x) => x.gw >= 44 && x.gh >= 44 && x.uw >= 44 && x.uh >= 44), g[0])
    else ok(`${tag} CONTROL: desktop keeps the 32 px grip and buttons`, g[0].gw === 32 && g[0].uw === 32, g[0])
    if (!vp.mobile) return
    const n0 = puts.length
    await p.touchscreen.touchStart(g[0].gx, g[0].gy)
    const steps = 12
    for (let i = 1; i <= steps; i++) {
      await p.touchscreen.touchMove(g[0].gx, g[0].gy + ((g[2].cy + 4 - g[0].gy) * i) / steps)
      await sleep(16)
    }
    await p.touchscreen.touchEnd()
    await sleep(500)
    const after = await ids()
    const moved = before[0]
    ok(`${tag} a finger drag moves the first row to the third place`, after.indexOf(moved) === 2 && after.length === before.length, { before, after })
    const put = puts.slice(n0)
    ok(`${tag} the new order is PUT once`, put.length === 1 && JSON.stringify(put[0]?.rail_order) === JSON.stringify(after), { put })
    const x = await noXScroll(p)
    ok(`${tag} no horizontal page scroll`, x.ok, x)
  } catch (e) {
    ok(`${tag} ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
}

async function checkPages(browser, base, vp) {
  const p = await page(browser, vp)
  const tag = `pages@${vp.w}`
  try {
    for (const [path, wait] of [['/archive', '[data-test=archive-page]'], ['/events', '[data-test=events-table]']]) {
      await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector(wait, { timeout: NAV_TIMEOUT }).catch(() => null)
      await sleep(300)
      const x = await noXScroll(p)
      ok(`${tag} ${path}: no horizontal page scroll`, x.ok, x)
      if (path === '/events') {
        const m = await p.evaluate(() => {
          const tds = [...document.querySelectorAll('[data-test=events-row]:first-child td')]
          const tr = document.querySelector('[data-test=events-row]')?.getBoundingClientRect()
          const w = document.querySelector('.events-table-wrap')
          return {
            cells: tds.map((td) => { const r = td.getBoundingClientRect(); return { x: Math.round(r.left), w: Math.round(r.width), label: getComputedStyle(td, '::before').content } }),
            trW: tr ? Math.round(tr.width) : 0,
            wrapScroll: w ? w.scrollWidth - w.clientWidth : -1,
          }
        })
        if (vp.w <= 600) {
          const same = m.cells.length === 6 && m.cells.every((c) => c.x === m.cells[0].x && c.w === m.cells[0].w)
          ok(`${tag} /events: one card per event, every value on its own line with its label`, same && m.cells.every((c) => c.label && c.label !== 'none') && m.wrapScroll <= 0, m)
        } else {
          ok(`${tag} CONTROL: /events stays a table above 600 px`, m.cells.length === 6 && new Set(m.cells.map((c) => c.x)).size === 6, m)
        }
      }
    }
  } catch (e) {
    ok(`${tag} ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
}

async function checkUsers(browser, base, vp) {
  const p = await page(browser, vp)
  const tag = `users@${vp.w}`
  try {
    for (const q of ['/search', '/search?q=deploy']) {
      await p.goto(base + q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector('[data-test=search-page]', { timeout: NAV_TIMEOUT }).catch(() => null)
      await sleep(300)
      const x = await noXScroll(p)
      ok(`${tag} ${q}: no horizontal page scroll`, x.ok, x)
    }
    await p.goto(base + '/users', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=users-row]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    await p.click('[data-test=users-row]')
    await p.waitForSelector('[data-test=users-pane]', { visible: true, timeout: 10000 })
    await sleep(300)
    const m = await p.evaluate(() => {
      const pane = document.querySelector('[data-test=users-pane]').getBoundingClientRect()
      const col = document.querySelector('.users-col')
      const r = col.getBoundingClientRect()
      const close = document.querySelector('[data-test=users-pane-close]')
      return { paneW: Math.round(pane.width), vw: window.innerWidth, listShown: getComputedStyle(col).display !== 'none' && r.width > 0,
        closeShown: close ? getComputedStyle(close).display !== 'none' : false }
    })
    if (vp.mobile) {
      ok(`${tag} a tap opens the pane alone, full width`, !m.listShown && m.paneW >= m.vw - 2, m)
      ok(`${tag} MobileBack in the pane, no X`, !m.closeShown && await shown(p, '[data-test=users-pane] [data-testid=mobile-back]'), m)
      const x = await noXScroll(p)
      ok(`${tag} pane: no horizontal page scroll`, x.ok, x)
      await p.goBack().catch(() => null)
      await sleep(500)
      const back = await p.evaluate(() => ({ pane: Boolean(document.querySelector('[data-test=users-pane]')), path: location.pathname }))
      ok(`${tag} browser Back closes the pane, back on the list`, !back.pane && back.path.endsWith('/users') && await shown(p, '.users-col'), back)
    } else {
      ok(`${tag} CONTROL: desktop keeps the pane beside the list, with its X`, m.listShown && m.paneW < m.vw / 2 && m.closeShown, m)
    }
  } catch (e) {
    ok(`${tag} ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
}

async function checkKeyboard(browser, base, vp) {
  if (!vp.phone) return
  signedOut = true
  const p = await page(browser, vp)
  const tag = `keyboard@${vp.w}`
  try {
    for (const [path, field, submit] of [
      ['/login', '[data-test=native-auth-email]', '[data-test=native-auth-submit]'],
      ['/reset-password?token=' + 'a'.repeat(64), '[data-test=reset-password-new]', '[data-test=reset-password-submit]'],
    ]) {
      await p.setViewport({ width: vp.w, height: vp.h, isMobile: true, hasTouch: true })
      await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector(field, { visible: true, timeout: NAV_TIMEOUT })
      let x = await noXScroll(p)
      ok(`${tag} ${path.split('?')[0]}: no horizontal page scroll`, x.ok, x)
      await p.focus(field)
      await p.setViewport({ width: vp.w, height: 400, isMobile: true, hasTouch: true })
      await sleep(500)
      const m = await p.evaluate((f, sb) => {
        const el = document.querySelector(f)
        const r = el.getBoundingClientRect()
        const bar = document.querySelector('[data-test=login-bar]').getBoundingClientRect()
        const body = document.querySelector('.login-body')
        body.scrollTop = body.scrollHeight
        const b = document.querySelector(sb).getBoundingClientRect()
        return {
          focused: document.activeElement === el,
          fieldTop: Math.round(r.top), fieldBottom: Math.round(r.bottom), barBottom: Math.round(bar.bottom), vh: window.innerHeight,
          submitBottom: Math.round(b.bottom), px: parseFloat(getComputedStyle(el).fontSize),
        }
      }, field, submit)
      ok(`${tag} ${path.split('?')[0]}: the focused field is in view under the bar`, m.focused && m.fieldTop >= m.barBottom - 1 && m.fieldBottom <= m.vh, m)
      ok(`${tag} ${path.split('?')[0]}: the submit button scrolls into view`, m.submitBottom <= m.vh && m.submitBottom > m.barBottom, m)
      ok(`${tag} ${path.split('?')[0]}: inputs >= 16 px (no iOS zoom)`, m.px >= 16, { px: m.px })
      x = await noXScroll(p)
      ok(`${tag} ${path.split('?')[0]}: keyboard open, no horizontal page scroll`, x.ok, x)
    }
  } catch (e) {
    ok(`${tag} ran`, false, String(e.message || e))
  } finally {
    signedOut = false
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of WIDTHS) {
    await checkDialog(browser, server.base, vp)
    await checkSettings(browser, server.base, vp)
    await checkRailTouch(browser, server.base, vp)
    await checkPages(browser, server.base, vp)
    await checkKeyboard(browser, server.base, vp)
    await checkUsers(browser, server.base, vp)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
