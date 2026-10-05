// CLE-77886 (owner, t1 topic ac0fa400): on a phone EVERY section keeps the
// one top bar and the one section strip (Channels, DMs, Issues, ... the
// rail's row at level 1). A section whose content is a page (Issues, People,
// Boxes, Agents, Event log, Help, Workspace settings) used to swap that strip
// for a bare "<  Issues" header; now the strip stays on top, the section is
// its selected control (1px in on each side, raised, darker, bold), and no
// title text and no Back chevron show. The strip rolls endlessly: a swipe
// never meets an end. An open issue (level 3) keeps its own header and its
// own actions; the top bar is the same everywhere. A tap on the selected
// control shows that section's list (the Issues epics) at level 1. At
// 1440 px nothing of it is in the tree.
//
// t1 topic 7b48293b (owner): "on scrolling ... they kind of reset". A
// finger swipe on the strip scrolls it: no reorder preview, no snap back
// (6 px in, a swipe used to become a drag). A long press still reorders.
//
// Checked at 390 px in the dark and the light scheme.
//
//   node tests/e2e/section-strip-mobile.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/section-strip-mobile.test.mjs
//   SECTION_STRIP_SHOTS=<dir> also writes a screenshot per section
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SECTION_STRIP_SHOTS || ''
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

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

/* every section the owner named; `sel` is its control in the strip. A
   section whose content is the strip's own list (`list`: People, Agents,
   Boxes - as Channels and DMs) shows it at level 1 under the strip; the
   rest are a page at level 2 under the same strip. */
const PAGES = [
  { name: 'Issues', path: '/issues', sel: '[data-testid=sidebar-tab-issues]' },
  { name: 'People', path: '/people', sel: '[data-testid=sidebar-tab-people]', list: 'people' },
  { name: 'Boxes', path: '/boxes', sel: '[data-testid=sidebar-tab-boxes]', list: 'boxes' },
  { name: 'Agents', path: '/agents', sel: '[data-testid=sidebar-tab-agents]', list: 'agents' },
  { name: 'Event log', path: '/events', sel: '[data-testid=sidebar-tab-events]' },
  { name: 'Archive', path: '/archive', sel: '[data-testid=sidebar-tab-archive]' },
  { name: 'Help', path: '/help', sel: '[data-testid=help-open]' },
  { name: 'Workspace settings', path: '/tenant-settings', sel: '[data-testid=tenant-settings-open]' },
]

/** the top bar as a reader sees it: its box and the controls in it */
const topBar = (p) => p.evaluate(() => {
  const bar = document.querySelector('[data-test=top-bar]')
  const r = bar.getBoundingClientRect()
  const shown = [...bar.querySelectorAll('[data-test],[data-testid]')].filter((e) => {
    const q = e.getBoundingClientRect()
    return q.width > 0 && q.height > 0 && getComputedStyle(e).visibility !== 'hidden'
  }).map((e) => e.getAttribute('data-test') || e.getAttribute('data-testid'))
    /* the glyph in the box says where THIS page's post goes (owner, t1
       3d6d945d "A"): "#" on a channel, none where there is no send target -
       it follows the page like the placeholder does, it is not bar layout */
    .filter((id) => id !== 'composer-mode-glyph')
  return JSON.stringify({ y: Math.round(r.y), h: Math.round(r.height), w: Math.round(r.width), shown })
})

const state = (p, sel, title, list) => p.evaluate((sel, title, list) => {
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  }
  const shell = document.querySelector('.spool-shell')
  const strip = document.querySelector('[data-testid=sidebar-rail]')
  const bar = document.querySelector('[data-test=top-bar]').getBoundingClientRect()
  const sr = strip.getBoundingClientRect()
  const ctl = document.querySelector(sel)
  const on = ctl && (ctl.getAttribute('aria-selected') === 'true' || ctl.classList.contains('router-link-active'))
  const others = [...strip.querySelectorAll('[role=tab][aria-selected=true]')].filter((e) => e !== ctl).length
  const cs = ctl ? getComputedStyle(ctl) : null
  const label = ctl?.querySelector('.sidebar-tab__label')
  const main = document.querySelector('.spool-main')
  /* E08: phone level 1 does not mount the middle pane. Titles and Back
     live in that pane, so a missing one is none of either. */
  const titled = main ? [...main.querySelectorAll('h1,h2')].filter(vis).filter((h) => h.textContent.trim() === title).length : 0
  return {
    level: shell.getAttribute('data-mobile-level'),
    section: shell.getAttribute('data-mobile-section'),
    strip: vis(strip),
    stripUnderBar: Math.abs(sr.top - bar.bottom) <= 1,
    on: Boolean(on),
    others,
    margin: cs ? cs.marginLeft : '',
    shadow: cs ? cs.boxShadow !== 'none' : false,
    bold: label ? Number(getComputedStyle(label).fontWeight) >= 700 : null,
    title: titled,
    back: main ? [...main.querySelectorAll('[data-testid=mobile-back]')].filter(vis).length : 0,
    xscroll: document.scrollingElement.scrollWidth > innerWidth,
    list: list ? vis(document.getElementById('sidebar-panel-' + list)) : null,
  }
}, sel, title, list)

const srv = await startServer()
const browser = await launch()
try {
  for (const scheme of ['dark', 'light']) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }])
    await p.evaluateOnNewDocument(() => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })))
    await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
    await p.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true })
    await sleep(1200)
    await p.click('[data-testid=sidebar-tab-channels]')
    await sleep(500)
    const home = await topBar(p)
    if (SHOTS) await p.screenshot({ path: join(SHOTS, `390-${scheme}-channels.png`) })

    /* the strip rolls: from its left end it is never at the left end */
    const roll = await p.evaluate(async () => {
      const strip = document.querySelector('[data-testid=sidebar-rail]')
      const copies = strip.querySelectorAll('[data-loop]').length
      const over = strip.scrollWidth > strip.clientWidth
      strip.scrollLeft = 0
      strip.dispatchEvent(new Event('scroll'))
      await new Promise((r) => setTimeout(r, 100))
      const afterLeft = strip.scrollLeft
      strip.scrollLeft = strip.scrollWidth
      strip.dispatchEvent(new Event('scroll'))
      await new Promise((r) => setTimeout(r, 100))
      const afterRight = strip.scrollWidth - strip.clientWidth - strip.scrollLeft
      const ids = [...strip.querySelectorAll('[data-loop] [data-testid], [data-loop] [id]')].length
      return { copies, over, afterLeft, afterRight, ids }
    })
    ok(`${scheme}: the strip overflows a portrait phone and rolls endlessly (a copy each side, never at an end)`, roll.over && roll.copies === 2 && roll.afterLeft > 0 && roll.afterRight > 0, roll)
    ok(`${scheme}: the strip's copies carry no ids or test ids`, roll.ids === 0, roll)

    /* t1 7b48293b: a finger swipe from a movable tab scrolls the strip */
    /* the roll check left a copy in view: bring the real row's start in */
    const realInView = () => p.evaluate(() => {
      const strip = document.querySelector('[data-testid=sidebar-rail]')
      const first = strip.querySelector('[data-reorder-id]')
      strip.scrollLeft += first.getBoundingClientRect().left - strip.getBoundingClientRect().left - 24
    })
    await realInView()
    await sleep(300)
    const railIds = () => p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    await p.evaluate(() => {
      const strip = document.querySelector('[data-testid=sidebar-rail]')
      const ids = () => [...strip.querySelectorAll('[data-reorder-id]')].map((e) => e.getAttribute('data-reorder-id')).join(',')
      window.__stripOrders = new Set([ids()])
      window.__stripObs?.disconnect()
      window.__stripObs = new MutationObserver(() => window.__stripOrders.add(ids()))
      window.__stripObs.observe(strip, { childList: true, subtree: true })
    })
    const order0 = await railIds()
    const tabAt = (id) => p.$eval(`[data-testid=sidebar-rail] [data-reorder-id="${id}"]`, (e) => {
      const r = e.getBoundingClientRect()
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), w: r.width }
    })
    const pick = await p.evaluate(() => {
      const strip = document.querySelector('[data-testid=sidebar-rail]')
      const b = strip.getBoundingClientRect()
      /* a movable tab inside the visible strip with a tab before it: a drag
         of the first one to the left would preview the same order */
      const t = [...strip.querySelectorAll('.sidebar-tab--movable[data-reorder-id]')].slice(1).find((e) => {
        const r = e.getBoundingClientRect()
        return r.left >= b.left + 20 && r.right <= b.right - 20
      })
      return t?.getAttribute('data-reorder-id') || ''
    })
    const from = await tabAt(pick)
    /* Chrome's own synthetic swipe sends the finger's first few px as
       pointermoves before the pan, as a phone does: on ddc59252 that was a
       drag (the tabs reshuffled, then snapped back). Headless, it scrolls
       nothing either way, so it checks the order only. */
    const cdp = await p.createCDPSession()
    await cdp.send('Input.synthesizeScrollGesture', { x: from.x, y: from.y, xDistance: -160, yDistance: 0, gestureSourceType: 'touch', speed: 600, preventFling: true })
    await sleep(500)
    const gesture = await p.evaluate(() => [...window.__stripOrders])
    ok(`${scheme}: a synthetic finger swipe on a strip tab previews no reorder (t1 7b48293b)`, gesture.length === 1 && same(await railIds(), order0), { orders: gesture })
    await cdp.detach()
    const sl0 = await p.$eval('[data-testid=sidebar-rail]', (e) => e.scrollLeft)
    /* CDP touch events, not synthesizeScrollGesture (it scrolls nothing
       headless). A finger moves a few px per event: 2 px steps first, so the
       6 px drag threshold comes before the browser's touch slop, as on a phone */
    await p.touchscreen.touchStart(from.x, from.y)
    const path = [...Array.from({ length: 10 }, (_, i) => 2 * (i + 1)), ...Array.from({ length: 10 }, (_, i) => 20 + 14 * (i + 1))]
    for (const dx of path) { await p.touchscreen.touchMove(from.x - dx, from.y); await sleep(16) }
    await p.touchscreen.touchEnd()
    await sleep(500)
    const swipe = await p.evaluate((sl0) => {
      const strip = document.querySelector('[data-testid=sidebar-rail]')
      const first = strip.querySelector('[data-reorder-id]')
      const twin = strip.querySelector('[data-loop="after"] > *')
      const set = first && twin ? Math.abs(twin.getBoundingClientRect().left - first.getBoundingClientRect().left) : 0
      /* a wrap jumps one copy width: the same picture, so count modulo it */
      const d = set > 0 ? ((((strip.scrollLeft - sl0) % set) + set) % set) : Math.abs(strip.scrollLeft - sl0)
      return { sl0, sl: strip.scrollLeft, set: Math.round(set), moved: Math.round(set > 0 ? Math.min(d, set - d) : d), orders: [...window.__stripOrders] }
    }, sl0)
    const order1 = await railIds()
    ok(`${scheme}: a finger swipe on the strip scrolls it (t1 7b48293b)`, swipe.moved >= 100, swipe)
    ok(`${scheme}: the swipe reorders nothing, not even for a moment (no snap back)`, swipe.orders.length === 1 && same(order1, order0), { order0, order1, orders: swipe.orders })

    /* a long press, then a move by one tab along the row: the preview moves it
       one place; moved back before the finger lifts, nothing is saved */
    await realInView()
    await sleep(300)
    const a = await tabAt(order0[1])
    const b2 = await tabAt(order0[2])
    await p.touchscreen.touchStart(a.x, a.y)
    await sleep(700)
    for (let i = 1; i <= 8; i++) { await p.touchscreen.touchMove(a.x + ((b2.x - a.x + 4) * i) / 8, a.y); await sleep(16) }
    await sleep(100)
    const held = await railIds()
    for (let i = 7; i >= 0; i--) { await p.touchscreen.touchMove(a.x + ((b2.x - a.x + 4) * i) / 8, a.y); await sleep(16) }
    await p.touchscreen.touchEnd()
    await sleep(300)
    const expect = [order0[0], order0[2], order0[1], ...order0.slice(3)]
    ok(`${scheme}: a long press on a strip tab still reorders it`, same(held, expect), { held, expect })
    ok(`${scheme}: moved back before the lift, the order stays`, same(await railIds(), order0), await railIds())
    await p.evaluate(() => window.__stripObs?.disconnect())

    for (const s of PAGES) {
      await p.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
      await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true })
      await sleep(600)
      /* the control may sit off screen in the rolling strip: click it in the page */
      await p.evaluate((sel) => document.querySelector(sel)?.click(), s.sel)
      if (!s.list) await p.waitForFunction((path) => location.pathname === path, { timeout: 15000 }, s.path).catch(() => null)
      await sleep(1200)
      const st = await state(p, s.sel, s.name, s.list)
      if (s.list) {
        ok(`${scheme} ${s.name}: its list at level 1 under the section strip, the section selected`,
          st.level === '1' && st.strip && st.stripUnderBar && st.on && st.others === 0 && st.list && !st.xscroll, st)
      } else {
        ok(`${scheme} ${s.name}: level 2 under the section strip, the section selected, no title, no Back`,
          st.level === '2' && st.section === '1' && st.strip && st.stripUnderBar && st.on && st.others === 0 && st.title === 0 && st.back === 0 && !st.xscroll, st)
      }
      if (st.bold !== null) ok(`${scheme} ${s.name}: the selected control is 1px in, raised and bold`, st.margin === '1px' && st.shadow && st.bold, st)
      ok(`${scheme} ${s.name}: the top bar is the same as on Channels`, (await topBar(p)) === home, { home, here: await topBar(p) })
      if (SHOTS) await p.screenshot({ path: join(SHOTS, `390-${scheme}-${s.path.slice(1)}.png`) })
    }

    /* Issues: a tap on the selected control shows its epics at level 1 */
    await p.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
    await sleep(600)
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-issues]')?.click())
    await p.waitForSelector('[data-test=issues-page]', { visible: true })
    await sleep(800)
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-issues]')?.click())
    await sleep(800)
    const l1 = await p.evaluate(() => ({ level: document.querySelector('.spool-shell').getAttribute('data-mobile-level'), panel: Boolean(document.getElementById('sidebar-panel-issues')?.offsetParent) }))
    ok(`${scheme}: a tap on the selected Issues control shows the Issues section at level 1`, l1.level === '1' && l1.panel, l1)

    /* an open issue keeps its own header and actions; the top bar stays */
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-issues]')?.click())
    await p.waitForSelector('[data-test=issues-new]', { visible: true })
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true })
    await p.type('[data-test=issues-detail-title]', 'Section strip check')
    await p.click('[data-test=issues-create]')
    await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 10000 }).catch(() => null)
    await sleep(600)
    const l3 = await p.evaluate(() => {
      const vis = (e) => Boolean(e) && getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0
      return {
        level: document.querySelector('.spool-shell').getAttribute('data-mobile-level'),
        back: vis(document.querySelector('[data-test=issues-detail-back]')),
        stripCovered: !vis(document.querySelector('.spool-shell > .sidebar')),
      }
    })
    ok(`${scheme}: an open issue is level 3 with its own Back, over the strip`, l3.level === '3' && l3.back && l3.stripCovered, l3)
    ok(`${scheme}: an open issue keeps the same top bar`, (await topBar(p)) === home, { home, here: await topBar(p) })
    if (SHOTS) await p.screenshot({ path: join(SHOTS, `390-${scheme}-issue-open.png`) })
    await p.close()
  }

  /* desktop: unchanged - no strip copies, no section flag, the Issues title shows */
  const d = await browser.newPage()
  await d.evaluateOnNewDocument(() => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })))
  await d.setViewport({ width: 1440, height: 900 })
  await d.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
  await d.waitForSelector('[data-test=issues-heading]', { visible: true })
  await sleep(800)
  const dd = await d.evaluate(() => ({
    copies: document.querySelectorAll('[data-loop]').length,
    section: document.querySelector('.spool-shell').getAttribute('data-mobile-section'),
    heading: document.querySelector('[data-test=issues-heading]')?.textContent.trim(),
  }))
  ok('1440px: no strip copies, no section flag, the Issues heading stays', dd.copies === 0 && dd.section === null && Boolean(dd.heading), dd)
  await d.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsection-strip-mobile: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
