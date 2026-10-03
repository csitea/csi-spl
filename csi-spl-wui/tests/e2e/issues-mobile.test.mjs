// Issues on phones (SPL-992, epic SPL-988, the mobile revamp) in a real
// browser on the mock tenant.
//
// At <= 820 px the sheet becomes a card list (key, title, status, prio,
// assignee, deadline), the filters sit in a collapsible filter sheet, the sort
// in a menu, the epics in a chip strip, the + a floating action button bottom
// right, and an issue opens full screen with its pickers as bottom sheets.
// Checked at 360 and 820 px. At 1440 px nothing of that is in the tree: the
// sheet, the header + and the side detail are the desktop ones, and
// ISSUES_SHOTS_DESKTOP=<dir> writes the 1440 px screenshots (list, detail)
// with every time masked, so a before / after pair can be compared pixel for
// pixel.
//
//   pnpm run test:e2e issues-mobile
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-mobile
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { printPageLog, retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.ISSUES_SHOTS || mkdtempSync(join(tmpdir(), 'spool-issues-mobile-'))
mkdirSync(SHOTS, { recursive: true })
const DESKTOP_SHOTS = process.env.ISSUES_SHOTS_DESKTOP || ''
const ONLY_DESKTOP = process.env.ISSUES_ONLY_DESKTOP === '1'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* the desktop way in: header +, the new top row's title, Enter (SPL-1027;
   the mock tenant starts empty) */
async function createDesktop(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  await p.waitForFunction((want) => [...document.querySelectorAll('[data-test=issues-row] .issues-title')].some((e) => e.textContent === want), { timeout: 5000 }, title)
}

/* every clock on screen reads the same in both runs (no addStyleTag: the
   deployed CSP refuses injected styles, so set them inline) */
async function maskTimes(p) {
  await p.evaluate(() => {
    for (const el of document.querySelectorAll('time, .issues-meta')) el.style.visibility = 'hidden'
  })
}

/* runner network churn gets one more try; the page errors it caused go */
async function openIssues(p, vp, errors) {
  const before = errors.length
  await retryOnNetworkChanged(`/issues at ${vp.width} px`, async () => {
    await setPageViewport(p, vp)
    await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  }, { onRetry: () => errors.splice(before) })
  /* `nuxi dev` floats its devtools button over the bottom of a phone screen, where the sheets are */
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}

/* the document never scrolls sideways */
async function xScroll(p) {
  return p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
}

/* every visible control in the area is at least 44 x 44 */
async function smallTargets(p, root) {
  return p.evaluate((sel) => {
    const out = []
    for (const el of document.querySelectorAll(`${sel} button, ${sel} select, ${sel} a[href], ${sel} [role=button], ${sel} input`)) {
      const r = el.getBoundingClientRect()
      const st = getComputedStyle(el)
      if (!r.width || !r.height || st.visibility === 'hidden') continue
      if (r.width < 43.5 || r.height < 43.5) out.push(`${el.getAttribute('data-test') || el.className || el.tagName} ${Math.round(r.width)}x${Math.round(r.height)}`)
    }
    return out
  }, root)
}

const server = await startServer()
const browser = await launch()
try {
  const p = watchPage(await browser.newPage(), 'issues')
  const errors = []
  /* a phone viewport reloads the page (puppeteer, isMobile); under `nuxi dev`
     that cuts vite's in-flight dynamic imports. Only there is that noise. */
  const devNoise = (m) => !process.env.BASE_URL && /Failed to fetch dynamically imported module/.test(m)
  p.on('pageerror', (e) => { const m = String(e && e.message); if (!devNoise(m)) errors.push(m) })

  /* ---- 1440 px: the desktop page, unchanged ---- */
  const desk = { width: 1440, height: 900 }
  await openIssues(p, desk, errors)
  await createDesktop(p, 'Rotate the relay key')
  await createDesktop(p, 'Mobile issues card list')
  /* SPL-1027: a desktop create leaves no issue open (the row stays in the sheet) */
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 })
  const d = await p.evaluate(() => ({
    table: !!document.querySelector('[data-test=issues-table]'),
    cards: !!document.querySelector('[data-test=issues-cards]'),
    bar: !!document.querySelector('[data-test=issues-mbar]'),
    fabPos: getComputedStyle(document.querySelector('[data-test=issues-new]')).position,
    inHeader: !!document.querySelector('.issues-head [data-test=issues-new]'),
    shortcuts: !!document.querySelector('[data-test=issues-shortcuts]'),
  }))
  ok('1 at 1440 px the sheet is the table, no card list, no phone bar; the + sits in the header, not floating',
    d.table && !d.cards && !d.bar && d.inHeader && d.fabPos !== 'fixed' && d.shortcuts, d)
  await p.mouse.move(1, 1)
  await maskTimes(p)
  if (DESKTOP_SHOTS) { mkdirSync(DESKTOP_SHOTS, { recursive: true }); await p.screenshot({ path: join(DESKTOP_SHOTS, 'issues-1440-list.png') }) }
  const keys = await p.$$eval('[data-test=issues-row]', (els) => els.map((e) => e.getAttribute('data-key')))
  ok('1a the two new issues are SPL-2 and SPL-3', keys.slice().sort().join() === 'SPL-2,SPL-3', keys)
  await p.click('[data-test=issues-row][data-key="SPL-2"] .issues-c-key')
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
  await sleep(300)
  const dd = await p.evaluate(() => {
    const r = document.querySelector('[data-test=issues-detail]').getBoundingClientRect()
    return { w: Math.round(r.width), full: Math.round(r.width) >= window.innerWidth - 1, back: !!document.querySelector('[data-test=issues-detail-back]') }
  })
  ok('2 at 1440 px the issue opens in the side pane, not full screen, with no Back button', !dd.full && !dd.back, dd)
  await p.mouse.move(1, 1)
  await maskTimes(p)
  if (DESKTOP_SHOTS) await p.screenshot({ path: join(DESKTOP_SHOTS, 'issues-1440-detail.png') })

  if (!ONLY_DESKTOP) {
    for (const vp of [{ width: 360, height: 780 }, { width: 820, height: 1180 }]) {
      const w = vp.width
      /* a phone viewport (isMobile, touch) reloads the page, and the mock
         tenant's issues live in the page: make two the phone way */
      await openIssues(p, vp, errors)
      for (const title of ['Rotate the relay key', 'Mobile issues card list']) {
        await p.click('[data-test=issues-new]')
        await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
        await p.type('[data-test=issues-detail-title]', title)
        await p.click('[data-test=issues-create]')
        await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
        await p.click('[data-test=issues-detail-back]')
        await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 })
      }
      ok(`2b ${w}: the FAB opens the new-issue form full screen, Create makes it, Back returns to the list`, true, '')

      /* level 1: a tap on the selected Issues control of the section strip
         (CLE-77886: the list has no Back / title of its own on a phone)
         shows the Issues section's epics; a tap on one opens its list */
      await p.click('[data-testid=sidebar-tab-issues]')
      await p.waitForSelector('[data-testid=sidebar-epic]', { visible: true, timeout: 5000 }).catch(() => {})
      const l1 = await p.evaluate(() => {
        const row = document.querySelector('[data-testid=sidebar-epic]')
        const r = row?.getBoundingClientRect()
        const title = row?.querySelector('.epic-row__title')?.getBoundingClientRect()
        return { level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'), h: r ? Math.round(r.height) : 0, titleW: title ? Math.round(title.width) : 0 }
      })
      ok(`2c ${w}: Back from the list is level 1, the epic rows show their titles and are >= 44 px`, l1.level === '1' && l1.h >= 44 && l1.titleW > 40, l1)
      await p.click('[data-testid=sidebar-epic][data-key="SPL-1"]')
      await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: 5000 }).catch(() => {})
      const l2 = await p.evaluate(() => ({
        level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'),
        epic: new URL(location.href).searchParams.get('epic'),
        chip: document.querySelector('[data-test=issues-epic-chip][aria-pressed=true]')?.getAttribute('data-key'),
      }))
      ok(`2d ${w}: a tap on an epic opens its card list (level 2, ?epic=, its chip on)`, l2.level === '2' && l2.epic === 'SPL-1' && l2.chip === 'SPL-1', l2)
      const seen = await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
      if (!seen) {
        ok(`3- ${w}: the card list shows`, false, await p.evaluate(() => ({ iw: innerWidth, mq: matchMedia('(max-width: 820px)').matches, table: !!document.querySelector('[data-test=issues-table]'), ul: document.querySelector('[data-test=issues-cards]')?.outerHTML.slice(0, 300) })))
        continue
      }
      const list = await p.evaluate(() => {
        const card = document.querySelector('[data-test=issues-card][data-key="SPL-2"]')
        const fab = document.querySelector('[data-test=issues-new]')
        const fr = fab.getBoundingClientRect()
        return {
          table: !!document.querySelector('[data-test=issues-table]'),
          cards: document.querySelectorAll('[data-test=issues-card]').length,
          fields: card ? ['issues-card-key', 'issues-card-title', 'issues-card-status', 'issues-card-priority', 'issues-card-assignee'].filter((t) => card.querySelector(`[data-test=${t}]`)) : [],
          key: card?.querySelector('[data-test=issues-card-key]')?.textContent.trim(),
          fabFixed: getComputedStyle(fab).position === 'fixed',
          /* SPL-1005: the composer dock is on this page too - the + sits just above it */
          fabBottomRight: (() => {
            const dock = document.querySelector('.composer--dock')
            const floor = dock ? dock.getBoundingClientRect().top : window.innerHeight
            return window.innerWidth - fr.right < 40 && floor - fr.bottom >= 0 && floor - fr.bottom < 40
          })(),
          fab: [Math.round(fr.width), Math.round(fr.height)],
          filterSheetOpen: !!document.querySelector('[data-test=issues-filter-sheet]'),
          shortcuts: !!document.querySelector('[data-test=issues-shortcuts]'),
          chips: document.querySelectorAll('[data-test=issues-epic-chip]').length,
        }
      })
      ok(`3 ${w}: the list is cards (key, title, status, prio, assignee), no table, no shortcut line`,
        !list.table && list.cards === 2 && list.fields.length === 5 && list.key === 'SPL-2' && !list.shortcuts, list)
      ok(`4 ${w}: + is a floating action button bottom right, >= 44 px`, list.fabFixed && list.fabBottomRight && list.fab[0] >= 44 && list.fab[1] >= 44, list)
      ok(`5 ${w}: epics are a chip strip (All + the one epic), the filter sheet starts closed`, list.chips === 2 && !list.filterSheetOpen, list)
      /* CONTROL-able: a chip keeps its full 44 px even when the list is long (prd e2e, 23 cards, clipped the strip) */
      const strip = await p.evaluate(() => {
        const nav = document.querySelector('[data-test=issues-epic-chips]')
        return { shrink: getComputedStyle(nav).flexShrink, h: Math.round(nav.getBoundingClientRect().height) }
      })
      ok(`5a ${w}: the chip strip never shrinks under the list`, strip.shrink === '0' && strip.h >= 44, strip)
      const small = await smallTargets(p, '[data-test=issues-page]')
      ok(`6 ${w}: every control on the list is >= 44 px`, small.length === 0, small)
      ok(`7 ${w}: no horizontal page scroll on the list`, (await xScroll(p)) <= 0, await xScroll(p))
      await p.screenshot({ path: join(SHOTS, `issues-${w}-list.png`) })

      /* the filter sheet: open, filter, close */
      await p.click('[data-test=issues-filters-open]')
      await p.waitForSelector('[data-test=issues-filter-sheet]', { visible: true, timeout: 5000 })
      await sleep(250)
      const sheet = await p.evaluate(() => {
        const s = document.querySelector('[data-test=issues-filter-sheet]')
        const r = s.getBoundingClientRect()
        return {
          controls: ['issues-filter-status-m', 'issues-filter-priority', 'issues-filter-level', 'issues-filter-assignee', 'issues-filter-label', 'issues-filter-deadline-date', 'issues-filter-clear'].filter((t) => s.querySelector(`[data-test=${t}]`)),
          bottom: Math.round(window.innerHeight - r.bottom),
          width: Math.round(r.width),
        }
      })
      ok(`8 ${w}: Filters opens a bottom sheet with every filter of the sheet's filter row`, sheet.controls.length === 7 && sheet.bottom <= 1 && sheet.width >= w - 1, sheet)
      await p.screenshot({ path: join(SHOTS, `issues-${w}-filters.png`) })
      await p.select('[data-test=issues-filter-priority]', '1')
      await p.waitForFunction(() => document.querySelectorAll('[data-test=issues-card]').length === 0, { timeout: 5000 }).catch(() => {})
      const filtered = await p.$$eval('[data-test=issues-card]', (els) => els.length)
      const badge = await p.$eval('[data-test=issues-filters-open]', (el) => el.getAttribute('data-active'))
      await p.click('[data-test=issues-filter-clear]')
      await p.waitForFunction(() => document.querySelectorAll('[data-test=issues-card]').length > 0, { timeout: 5000 }).catch(() => {})
      const cleared = await p.$$eval('[data-test=issues-card]', (els) => els.length)
      const all = list.cards
      ok(`9 ${w}: a filter in the sheet filters the cards, the Filters button shows it is on, Clear brings them back`, filtered === 0 && badge === 'true' && cleared === all, { filtered, badge, cleared })
      await p.click('[data-test=issues-filter-sheet-close]')
      await p.waitForFunction(() => !document.querySelector('[data-test=issues-filter-sheet]'), { timeout: 5000 })

      /* sort is a menu */
      await p.click('[data-test=issues-sort-open]')
      await p.waitForSelector('[data-test=issues-sort-sheet]', { visible: true, timeout: 5000 })
      const sortOpts = await p.$$eval('[data-test=issues-sort-opt]', (els) => els.map((e) => e.getAttribute('data-value')))
      await p.click('[data-test=issues-sort-opt][data-value="key:asc"]')
      await p.waitForFunction(() => !document.querySelector('[data-test=issues-sort-sheet]'), { timeout: 5000 })
      const sorted = await p.$$eval('[data-test=issues-card]', (els) => els.map((e) => e.getAttribute('data-key')))
      const q = new URL(p.url()).searchParams
      ok(`10 ${w}: Sort is a menu; Key A-Z orders the cards and lands in ?sort=&dir=`,
        sortOpts.includes('key:asc') && sortOpts.includes(':') && sorted.join() === 'SPL-2,SPL-3' && q.get('sort') === 'key' && q.get('dir') === 'asc', { sortOpts, sorted, q: String(q) })

      /* level 3: the issue full screen */
      await p.click('[data-test=issues-card][data-key="SPL-2"]')
      await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
      await sleep(250)
      const det = await p.evaluate(() => {
        const r = document.querySelector('[data-test=issues-detail]').getBoundingClientRect()
        const fab = document.querySelector('[data-test=issues-new]')
        return {
          full: Math.round(r.left) <= 0 && Math.round(r.right) >= window.innerWidth,
          back: !!document.querySelector('[data-test=issues-detail-back]'),
          subs: !!document.querySelector('[data-test=issues-subtask-open]'),
          talk: !!document.querySelector('[data-test=issues-talk]'),
          fabHidden: !fab || fab.getBoundingClientRect().width === 0,
          url: location.search,
        }
      })
      ok(`11 ${w}: an issue opens full screen with Back, the subtask + and the discussion; no FAB over it`,
        det.full && det.back && det.subs && det.talk && det.fabHidden && det.url.includes('issue=SPL-2'), det)
      const smallD = await smallTargets(p, '[data-test=issues-detail] [data-test=issues-props]')
      ok(`12 ${w}: the pickers are >= 44 px`, smallD.length === 0, smallD)
      ok(`13 ${w}: no horizontal page scroll on the issue`, (await xScroll(p)) <= 0, await xScroll(p))
      await p.screenshot({ path: join(SHOTS, `issues-${w}-detail.png`) })

      /* a picker is a bottom sheet */
      for (const [btn, kind] of [['issues-status', 'status'], ['issues-priority-btn', 'priority'], ['issues-level-btn', 'level'], ['issues-assignee', 'assign']]) {
        await p.click(`[data-test=${btn}]`)
        await p.waitForSelector('[data-test=issues-menu]', { visible: true, timeout: 5000 })
        await sleep(250)
        const m = await p.evaluate(() => {
          const el = document.querySelector('[data-test=issues-menu]')
          const r = el.getBoundingClientRect()
          return { kind: el.getAttribute('data-kind'), bottom: Math.round(window.innerHeight - r.bottom), left: Math.round(r.left), width: Math.round(r.width), scrim: !!document.querySelector('[data-test=issues-sheet-scrim]'), opts: el.querySelectorAll('[data-test=issues-menu-option]').length }
        })
        ok(`14 ${w}: ${kind} opens as a bottom sheet over a scrim`, m.kind === kind && m.bottom <= 1 && m.left <= 0 && m.width >= w - 1 && m.scrim && m.opts > 0, m)
        if (kind === 'status') {
          await p.screenshot({ path: join(SHOTS, `issues-${w}-status-sheet.png`) })
          await p.click('[data-test=issues-menu-option][data-value="wip"]')
          await p.waitForFunction(() => !document.querySelector('[data-test=issues-menu]'), { timeout: 5000 })
          const st = await p.$eval('[data-test=issues-status] .issues-status-code', (e) => e.textContent.trim())
          ok(`15 ${w}: picking wip in the sheet sets it`, /wip/i.test(st), st)
        } else {
          await p.click('[data-test=issues-sheet-scrim]')
          await p.waitForFunction(() => !document.querySelector('[data-test=issues-menu]'), { timeout: 5000 })
        }
      }

      /* back: the Back button and the browser back both go 3 -> 2 */
      await p.click('[data-test=issues-detail-back]')
      await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 }).catch(() => {})
      ok(`16 ${w}: Back closes the issue to the card list`, !(await p.$('[data-test=issues-detail]')) && !!(await p.$('[data-test=issues-card]')) && !new URL(p.url()).searchParams.get('issue'), p.url())
      await p.click('[data-test=issues-card][data-key="SPL-3"]')
      await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
      await p.goBack()
      await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 }).catch(() => {})
      ok(`17 ${w}: browser back closes the issue and stays on Issues`, !(await p.$('[data-test=issues-detail]')) && new URL(p.url()).pathname.endsWith('/issues'), p.url())

    }
  }
  ok('19 no page errors', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}
console.log(`shots: ${SHOTS}${DESKTOP_SHOTS ? ' desktop: ' + DESKTOP_SHOTS : ''}`)
const failed = results.filter((r) => !r.ok)
console.log(`${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
