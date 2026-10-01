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
  const titled = [...main.querySelectorAll('h1,h2')].filter(vis).filter((h) => h.textContent.trim() === title).length
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
    back: [...main.querySelectorAll('[data-testid=mobile-back]')].filter(vis).length,
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
