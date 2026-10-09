// SPL-1146: the sidebar footer (the tenant-settings gear, the connection
// dot, the bell, the note, the version) is its OWN bar and never covers the
// last row of a sidebar list. Owner (prd t1 topic 8d562b94): "check the
// latest snapshot on the box" - 1.9.9 drew the footer over the last epic
// row of /issues and its progress bar; "it shows how the panel with the
// version is not visible properly".
//
// For every list above the footer (Channels, Direct messages, Issues epics,
// Topics, Flow) at 1440, 1280 and 1024 px and on the phone level-1 screen
// (390 px, the footer above the dock, SPL-1005): scroll the list to the
// bottom, then
//   - the last row's rect ends above the footer's (no overlap, not clipped under it)
//   - elementFromPoint at the last row's centre hits the row
//   - the footer is opaque (alpha 1 background), has a top border, sits
//     inside the viewport and its version is really painted
// and the version card still opens, painted, above the version (SPL-999/1023).
// The epics list is padded to 40 rows so it always overflows; the other
// lists are measured as the mock draws them, on a short viewport.
//
// Control: on 1.9.9 (the epics had no scroller) the Issues checks go red.
//
// Run:
//   pnpm run test:e2e sidebar-footer
//   BASE_URL=<generated bundle> pnpm run test:e2e sidebar-footer
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const VIEWPORTS = [
  { name: '1440', width: 1440, height: 560, mobile: false },
  { name: '1280', width: 1280, height: 520, mobile: false },
  { name: '1024', width: 1024, height: 480, mobile: false },
  /* no phone: since t1 3c298fd9 (CLE-77888) a phone draws no footer row -
     its dot / bell / note / version are the bottom status strip
     (mobile-status-strip.test.mjs) */
]
const TABS = ['channels', 'dm', 'issues', 'topics', 'flow']

const SHA = '0123456789abcdef0123456789abcdef01234567'
const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

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

/* 40 level-1 rows in the shared state the Issues page fills (useState
   'issue-epics'), so the epics list overflows at every size */
const padEpics = (p) => p.evaluate(() => {
  const state = document.querySelector('#__nuxt')?.__vue_app__?.$nuxt?.payload?.state
  if (!state) return 0
  const rows = []
  for (let i = 1; i <= 40; i++) {
    rows.push({ key: `SPL-${9000 + i}`, kind: i % 3 ? 'epic' : 'feature', title: `Spec ${String(i).padStart(3, '0')} - a long epic title that ellipsizes`, status: 'open', total: 19, done: i % 19, canceled: 0 })
  }
  state['$sissue-epics'] = rows
  return rows.length
})

const measure = (p, tab) => p.evaluate((tab) => {
  const panel = document.getElementById('sidebar-panel-' + tab)
  const sidebar = panel?.closest('.sidebar')
  const foot = sidebar?.querySelector('.sidebar-foot')
  if (!panel || !foot || panel.offsetParent === null) return { missing: !panel ? 'panel' : !foot ? 'foot' : 'hidden' }
  const rows = [...panel.querySelectorAll('.nav-row, .epic-row, [data-testid=left-entry]')].filter((e) => e.getClientRects().length)
  const row = rows.at(-1)
  if (!row) return { rows: 0 }
  const scroller = panel.querySelector('.sidebar-scroll')
  if (scroller) scroller.scrollTop = scroller.scrollHeight
  const box = (r) => ({ t: Math.round(r.top), b: Math.round(r.bottom), l: Math.round(r.left), r: Math.round(r.right) })
  const rr = row.getBoundingClientRect()
  const fr = foot.getBoundingClientRect()
  const hit = document.elementFromPoint(rr.left + rr.width / 2, rr.top + rr.height / 2)
  const cs = getComputedStyle(foot)
  const bg = cs.backgroundColor
  const alpha = /rgba?\(([^)]+)\)/.exec(bg)?.[1].split(/[ ,/]+/).filter(Boolean)[3]
  const ver = sidebar.querySelector('[data-test=app-version]')
  const vr = ver?.getBoundingClientRect()
  const vhit = vr ? document.elementFromPoint(vr.left + Math.min(vr.width / 2, 12), vr.top + vr.height / 2) : null
  return {
    rows: rows.length,
    overflow: scroller ? scroller.scrollHeight > scroller.clientHeight + 1 : panel.scrollHeight > panel.clientHeight + 1,
    row: box(rr),
    foot: box(fr),
    /* fully above the footer: on 1.9.9 the last epic sat under it or below it, clipped */
    /* 1 px: a fractional scroller height against an integer scrollTop;
       the scroller clips that sliver, it never paints under the footer */
    clear: rr.bottom <= fr.top + 1,
    rowHit: Boolean(hit && row.contains(hit)),
    hitClass: hit ? String(hit.className || hit.tagName).slice(0, 40) : null,
    opaque: alpha === undefined || Number(alpha) === 1,
    bg,
    border: parseFloat(cs.borderTopWidth) || 0,
    footInView: fr.top >= 0 && fr.bottom <= window.innerHeight + 0.5,
    versionPainted: Boolean(vhit && foot.contains(vhit)),
  }
}, tab)

const server = await startServer()
const browser = await launch()
try {
  for (const vp of VIEWPORTS) {
    console.log(`-- ${vp.name}x${vp.height}`)
    const p = await browser.newPage()
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    /* a build.json so the version card has a commit to show (lde has none) */
    await p.setRequestInterception(true)
    p.on('request', (req) => {
      if (new URL(req.url()).pathname === '/build.json') {
        return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: SHA, built_at: '2026-09-28T10:30:00Z', run: '1' }) })
      }
      req.continue()
    })
    /* phone: / is level 1, the sidebar full width (SPL-989); /lobby is level 2 */
    await p.goto(server.base + (vp.mobile ? '/' : '/lobby'), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('.sidebar-foot', { visible: true, timeout: NAV_TIMEOUT })
    await signIn(p)
    await p.waitForSelector('[data-testid=sidebar-tab-channels]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(1000)
    for (const tab of TABS) {
      const btn = await p.waitForSelector(`[data-testid=sidebar-tab-${tab}]`, { visible: true, timeout: 15000 }).catch(() => null)
      if (!btn) { ok(`${vp.name} ${tab}: the tab exists`, false); continue }
      await btn.click()
      await sleep(250)
      if (tab === 'issues') {
        /* on a phone the tab opens the list (level 2) under the section
           strip; a tap on the selected Issues control shows the section's
           epics at level 1 (SPL-992, CLE-77886) */
        if (vp.mobile) {
          await p.waitForSelector('.spool-shell[data-mobile-section="1"] [data-testid=sidebar-tab-issues]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
          await p.click('[data-testid=sidebar-tab-issues]').catch(() => null)
        }
        await p.waitForSelector('[data-testid=sidebar-epics-h]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
        await padEpics(p)
        await sleep(300)
      }
      /* CLE-77886: on a phone a section with a page of its own (Topics) shows
         it under the section strip; a tap on its selected control shows the
         section's list at level 1 */
      if (vp.mobile && tab !== 'issues' && await p.$('.spool-shell[data-mobile-section="1"]')) {
        await p.click(`[data-testid=sidebar-tab-${tab}]`).catch(() => null)
        await sleep(400)
      }
      /* spec 109 T008: on a desktop Topics opens `/`, whose centre is the
         topic list; panel 1 shows the Channels list there */
      const shown = !vp.mobile && tab === 'topics' ? 'channels' : tab
      await p.waitForFunction((t) => document.getElementById('sidebar-panel-' + t)?.offsetParent, { timeout: 10000 }, shown).catch(() => null)
      await sleep(150)
      const m = await measure(p, shown)
      if (!m.rows) { ok(`${vp.name} ${tab}: the list draws rows`, false, m); continue }
      if (tab === 'issues') ok(`${vp.name} issues: the padded epics list overflows (the case that matters)`, m.overflow, { rows: m.rows })
      ok(`${vp.name} ${tab}: last row fully above the footer`, m.clear, { row: m.row, foot: m.foot, rows: m.rows, overflow: m.overflow })
      ok(`${vp.name} ${tab}: elementFromPoint at the last row's centre hits the row`, m.rowHit, { hit: m.hitClass })
      ok(`${vp.name} ${tab}: footer is its own bar (opaque, top border, in view, version painted)`, m.opaque && m.border >= 1 && m.footInView && m.versionPainted, { bg: m.bg, border: m.border, inView: m.footInView, version: m.versionPainted })
    }
    /* SPL-999/1023: the version card still opens above the footer, painted */
    await p.click('[data-test=app-version-wrap]').catch(() => null)
    await sleep(300)
    const card = await p.evaluate(() => {
      const c = document.querySelector('[data-test=app-version-card]')
      const v = document.querySelector('[data-test=app-version]')
      if (!c || !v) return { none: true }
      const r = c.getBoundingClientRect()
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
      return { visible: getComputedStyle(c).visibility === 'visible', painted: Boolean(hit && c.contains(hit)), above: r.bottom <= v.getBoundingClientRect().top + 1 }
    })
    ok(`${vp.name}: the version card opens, painted, directly above the version`, !card.none && card.visible && card.painted && card.above, card)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop?.()
}
const failed = results.filter((r) => !r.ok)
console.log(`${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
