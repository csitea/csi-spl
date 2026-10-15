// SPL-979 follow-up: the default left-rail order for new members.
//
// Owner, 2026-09-27 (topic 116646c8): "the default order for new members
// should be channels, direct messages, issues, topics, flow and archive". The
// Event log, which he did not name, goes last. A person with a stored order
// (humans.rail_order) keeps it exactly. Owner HUM-10 (t1 e4bfddb1, msg
// a78e06c8): "Remove the whole topics view" - no Topics tab; a stored order
// that holds `topics` is drawn without it (noTopicsView below).
//
// In the mock tenant the session is adopted through the pinia store, once
// with no rail_order and once with the owner's stored order. Each time the
// rail and Settings -> Behaviour -> Left panel order must show the expected
// order. Runs at 1440 (desktop), 820 and 360 (touch).
//
// Run:
//   node tests/e2e/rail-order-default.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/rail-order-default.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
/* CLE-77794: the drawn order is parseRailOrder(claim) — a legacy stored order
   keeps its place and the tabs added since (people, agents) are appended, so the
   expected order tracks RAIL_IDS instead of a hardcoded list. */
import { parseRailOrder } from '../../src/utils/rail-order.mjs'

const results = []
function check(name, pass, ev) {
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
/* the owner's stored order on prd (humans.rail_order, measured 2026-09-27); a
   legacy seven-tab claim, drawn with people + agents appended (parseRailOrder). */
const STORED = ['channels', 'topics', 'issues', 'dm', 'events', 'flow', 'archive']
/* CLE-77916 (owner, t1 topic 5463df22): Archive is ALWAYS last and not
   draggable. A stored order with Archive first is drawn with it last. */
const ARCHIVE_FIRST = ['archive', 'channels', 'dm', 'issues', 'topics', 'flow', 'events', 'people', 'agents', 'boxes']

/** Sign in as a member; `order` undefined = never reordered (the claim is absent). */
const signIn = (p, order) => p.evaluate((order) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  const c = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (order !== undefined) c.rail_order = order
  session.adopt(c)
  return true
}, order)

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const railOf = (p) => p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))

/* CLE-77916: press a tab and move it one tab along the rail's own axis with the
   mouse (a desktop window at phone width is a row): the preview moves it ONE
   place - measured on the wrong axis it jumped to the first or last index.
   Pressing Archive and moving it previews nothing. Released with Escape-free
   pointercancel so nothing is saved. */
async function dragProbe(p, tag, rail) {
  const boxes = await p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => {
    const r = e.getBoundingClientRect()
    return { id: e.getAttribute('data-reorder-id'), x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }
  }))
  const row = Math.abs(boxes.at(-1).x - boxes[0].x) > Math.abs(boxes.at(-1).y - boxes[0].y)
  const a = boxes[1]
  const step = row ? { x: boxes[2].x - a.x + 4, y: 0 } : { x: 0, y: boxes[2].y - a.y + 4 }
  await p.mouse.move(a.x, a.y)
  await p.mouse.down()
  for (let i = 1; i <= 6; i++) await p.mouse.move(a.x + (step.x * i) / 6, a.y + (step.y * i) / 6)
  await sleep(100)
  const mid = await railOf(p)
  const expect = [rail[0], rail[2], rail[1], ...rail.slice(3)]
  check(`${tag}: a drag by one tab along the ${row ? 'row' : 'column'} moves it one place`, same(mid, expect), { mid })
  await p.evaluate(() => window.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 1, isPrimary: true, pointerType: 'mouse' })))
  await p.mouse.up()
  await sleep(100)
  const arch = boxes.find((b) => b.id === 'archive')
  await p.mouse.move(arch.x, arch.y)
  await p.mouse.down()
  for (let i = 1; i <= 6; i++) await p.mouse.move(arch.x - (row ? arch.w * i / 3 : 0), arch.y - (row ? 0 : arch.h * i / 3))
  await sleep(100)
  const still = await railOf(p)
  check(`${tag}: pressing and moving Archive moves nothing`, same(still, rail), { still })
  await p.mouse.up()
  await sleep(100)
}

async function run(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  for (const [who, order] of [['fresh user (never reordered)', undefined], ['stored order', STORED], ['stored order with Archive first', ARCHIVE_FIRST]]) {
    const tag = `${width}px ${who}`
    /* the rail draws parseRailOrder(claim): the 9-tab default for a fresh user,
       the stored order with people + agents appended for a legacy claim. */
    const want = parseRailOrder(order)
    /* phones: / is the sidebar level (the rail); desktop draws it on every page */
    await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
    if (!(await signIn(p, order))) throw new Error('no session store')
    await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
    await sleep(400)
    const rail = await railOf(p)
    check(`${tag}: the rail draws ${order ? 'the stored order, unchanged' : 'the new default'}`, same(rail, want), { rail })
    check(`${tag}: Archive is the last section`, rail.at(-1) === 'archive', { last: rail.at(-1) })
    /* CONTROL (red on master, where the tab exists): no Topics tab, also for
       a stored order that names it (STORED, ARCHIVE_FIRST hold 'topics') */
    check(`${tag}: no Topics tab${order ? ' (the stored order names topics)' : ''}`, !rail.includes('topics') && !(await p.$('#sidebar-tab-topics')) && (!order || order.includes('topics')), { rail })
    const pinned = await p.$$eval('[data-testid=sidebar-rail] [data-pinned=last]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    check(`${tag}: Archive, and only Archive, is not draggable`, same(pinned, ['archive']), { pinned })
    await dragProbe(p, tag, rail)
    await go(p, '/settings/behaviour')
    await p.waitForSelector('[data-test=rail-order-list] [data-reorder-id]', { timeout: NAV })
    await sleep(300)
    const list = await p.$$eval('[data-test=rail-order-list] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    check(`${tag}: Settings -> Behaviour lists the same order, no Topics`, same(list, want) && !list.includes('topics'), { list })
    const archiveCtl = await p.$$('[data-test=rail-order-up-archive], [data-test=rail-order-down-archive]')
    check(`${tag}: Settings offers no Move up / down for Archive`, archiveCtl.length === 0, { n: archiveCtl.length })
  }
  await p.close()
}

/* spec 109 T007 (FR-005): a rail tab that keeps the route keeps panel 2 (the
   centre, .spool-main) as it is - no DOM mutation there in the 600 ms after the
   click. On a topic's page (/t/<id>, the thread alone since the Topics view
   went) Channels / Direct messages / Flow only swap panel 1. CONTROL: Issues
   changes the route, so the same observer must count mutations. */
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
async function panel2Mutations(p, id) {
  return p.evaluate(async (id) => {
    const main = document.querySelector('.spool-main')
    let n = 0
    const what = []
    /* the mock thread appends live rows on its own timer (.live-rows): those
       are not panel 2 redrawn by the tab, which would replace the section */
    const own = (m) => !(m.target.nodeType === 1 ? m.target : m.target.parentElement)?.closest('.live-rows')
    const o = new MutationObserver((all) => {
      const list = all.filter(own)
      n += list.length
      for (const m of list.slice(0, 4)) what.push(`${m.type}:${m.target.nodeType === 1 ? m.target.className || m.target.tagName : '#text'}:${m.attributeName || ''}`)
    })
    o.observe(main, { subtree: true, childList: true, attributes: true, characterData: true })
    document.getElementById('sidebar-tab-' + id).click()
    await new Promise((r) => setTimeout(r, 600))
    o.disconnect()
    return { n, path: location.pathname, what: what.slice(0, 6) }
  }, id)
}

async function sameRouteTabs(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/t/${TOPIC}`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=topic-browse-thread] article.msg', { timeout: NAV })
  await sleep(800)
  for (const id of ['channels', 'dm', 'flow', 'channels']) {
    const r = await panel2Mutations(p, id)
    check(`1440px T007: ${id} tab on /t/<id> keeps the route and panel 2 (0 mutations)`, r.path === `/t/${TOPIC}` && r.n === 0, r)
  }
  const ctl = await panel2Mutations(p, 'issues')
  check('1440px T007 CONTROL: Issues from /t/<id> changes the route and panel 2 mutates', ctl.path === '/issues' && ctl.n > 0, ctl)
  await p.close()
}

/* Owner HUM-10 (t1 e4bfddb1, msg a78e06c8): "Remove the whole topics view
   ... and also remove all of the context menu links and buttons which point
   to it". `/` (the Topics list) lands on Channels: #lobby on a desktop, the
   Channels list (level 1) on a phone; `/?topic=<id>` still opens that topic.
   A topic's page (/t/<id>) is its thread with the Channels list beside it.
   No rail tab, strip entry or row-menu item names Topics. The asserts on the
   tab are red on master (CONTROL): there the tab exists. */
const shownPanels = (p) => p.$$eval('.sidebar-panel', (els) => els.filter((e) => e.checkVisibility({ visibilityProperty: true })).map((e) => e.id))
const railOn = (p) => p.$$eval('[data-testid=sidebar-rail] [aria-selected=true]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
const menuItems = (p) => p.$$eval('[data-testid=sidebar-row-menu-panel] [role=menuitem]', (els) => els.map((e) => `${e.getAttribute('data-testid')}:${e.textContent.trim()}`))
async function noTopicsView(browser, base) {
  for (const [width, touch] of [[1440, false], [390, true]]) {
    const tag = `${width}px no Topics view`
    const p = await browser.newPage()
    await p.setViewport({ width, height: 900, isMobile: touch, hasTouch: touch })
    await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
    await sleep(800)
    const home = {
      path: await p.evaluate(() => location.pathname),
      shown: await shownPanels(p),
      marked: await railOn(p),
      tab: Boolean(await p.$('#sidebar-tab-topics')),
      panel: Boolean(await p.$('[data-testid=sidebar-panel-topics]')),
      rows: await p.$$eval('.spool-main .topic-row', (els) => els.length),
    }
    if (!touch) {
      check(`${tag}: / opens #lobby with Channels marked and listed`, home.path === '/lobby' && same(home.shown, ['sidebar-panel-channels']) && same(home.marked, ['channels']), home)
    } else {
      check(`${tag}: / is the Channels list (level 1)`, home.path === '/' && same(home.shown, ['sidebar-panel-channels']) && same(home.marked, ['channels']), home)
    }
    check(`${tag}: CONTROL no Topics tab, no Topics panel, no topic list`, !home.tab && !home.panel && home.rows === 0, home)
    /* every row menu of the Channels list: no item names Topics */
    const btns = await p.$$('#sidebar-panel-channels [data-testid=sidebar-row-menu]')
    let topicItems = []
    let menus = 0
    for (const b of btns.slice(0, 3)) {
      await b.click()
      await p.waitForSelector('[data-testid=sidebar-row-menu-panel]', { visible: true, timeout: 5000 }).catch(() => null)
      const items = await menuItems(p)
      if (items.length) menus++
      topicItems = topicItems.concat(items.filter((x) => /topics/i.test(x)))
      await p.keyboard.press('Escape')
      await sleep(200)
    }
    check(`${tag}: no row-menu item points to Topics`, menus > 0 && topicItems.length === 0, { menus, topicItems })
    /* a /?topic=<id> deep link still opens that topic */
    await p.goto(`${base}/?topic=${TOPIC}`, { waitUntil: 'networkidle2', timeout: NAV })
    const deep = await p.waitForSelector(`[data-test=topic-section] article.msg, .topic article.msg`, { timeout: 15000 }).then(() => true).catch(() => false)
    check(`${tag}: /?topic=<id> opens #lobby with that topic open`, deep && (await p.evaluate(() => location.pathname)) === '/lobby', { deep, path: await p.evaluate(() => location.href) })
    /* a topic's own page: the thread alone, the Channels list beside it on a desktop */
    await p.goto(`${base}/t/${TOPIC}`, { waitUntil: 'networkidle2', timeout: NAV })
    const thread = await p.waitForSelector('[data-test=topic-browse-thread] article.msg', { timeout: 15000 }).then(() => true).catch(() => false)
    const t = { thread, list: Boolean(await p.$('[data-test=topic-browse-list]')), shown: await shownPanels(p) }
    check(`${tag}: /t/<id> is the thread alone${touch ? '' : ', Channels beside it'}`, thread && !t.list && (touch || same(t.shown, ['sidebar-panel-channels'])), t)
    await p.close()
  }
}

/* spec 109 T015 (FR-012): the desktop rail draws a divider wherever the talk
   group (Channels, DMs, Flow, Issues, Calendar) meets the workspace
   group (Event log, People, Agents, Boxes, Archive), and names its icons only
   when Settings -> Behaviour -> "Show labels" is on (default off). The phone
   strip is unchanged: no divider, its names always shown, the same boxes
   whether the setting is on or off. CONTROL: with the feature reverted the
   divider and labels-on asserts fail. */
const WORKSPACE = new Set(['events', 'people', 'agents', 'boxes', 'monitoring', 'archive'])
/* the divider is a ::before line on the tab below the boundary (main.css):
   a drawn one has content and a top border */
const railSeq = (p) => p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.flatMap((e) => {
  const b = getComputedStyle(e, '::before')
  const line = b.content !== 'none' && b.display !== 'none' && parseFloat(b.borderTopWidth) > 0
  return line ? ['|', e.getAttribute('data-reorder-id')] : [e.getAttribute('data-reorder-id')]
}))
const labelsShown = (p) => p.$$eval('[data-testid=sidebar-rail] .sidebar-rail__tabs .sidebar-tab__label', (els) => els.filter((e) => e.checkVisibility({ visibilityProperty: true }) && e.getBoundingClientRect().width > 0).length)
const railBoxes = (p) => p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)] }))
async function setLabels(p, on) {
  await go(p, '/settings/behaviour')
  await p.waitForSelector('[data-testid=settings-rail-labels]', { timeout: NAV })
  const now = await p.$eval('[data-testid=settings-rail-labels]', (e) => e.checked)
  if (now !== on) await p.click('[data-testid=settings-rail-labels]')
  await go(p, '/')
  await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
  await sleep(400)
}
async function railDividerLabels(browser, base) {
  for (const [width, touch] of [[1440, false], [360, true]]) {
    const tag = `${width}px T015`
    const p = await browser.newPage()
    await p.setViewport({ width, height: 900, isMobile: touch, hasTouch: touch })
    await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
    await p.evaluate(() => { try { localStorage.removeItem('spool.rail-labels') } catch {} })
    if (!(await signIn(p, undefined))) throw new Error('no session store')
    await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
    await sleep(400)
    const seq = await railSeq(p)
    const tabs = seq.filter((x) => x !== '|')
    const changes = tabs.filter((id, i) => i > 0 && WORKSPACE.has(id) !== WORKSPACE.has(tabs[i - 1])).length
    const between = seq.every((x, i) => x !== '|' || (i > 0 && i < seq.length - 1 && WORKSPACE.has(seq[i - 1]) !== WORKSPACE.has(seq[i + 1])))
    const dividers = seq.filter((x) => x === '|').length
    const offLabels = await labelsShown(p)
    const offBoxes = await railBoxes(p)
    if (!touch) {
      check(`${tag}: a divider wherever talk meets workspace, and only there`, changes > 0 && dividers === changes && between, { seq })
      /* owner HUM-10 (t1 2b61230c, msg a351c864, "A"): the default order keeps
         Calendar with the talk tabs, so the default rail draws ONE line. */
      check(`${tag}: the default rail draws exactly 1 divider`, dividers === 1, { seq })
      check(`${tag}: no labels while the setting is off (the default)`, offLabels === 0, { offLabels })
    }
    await setLabels(p, true)
    const onLabels = await labelsShown(p)
    const onBoxes = await railBoxes(p)
    const flag = await p.evaluate(() => document.documentElement.classList.contains('rail-labels'))
    if (!touch) {
      check(`${tag}: "Show labels" on names every rail icon`, onLabels === tabs.length && flag, { onLabels, n: tabs.length, flag })
      await setLabels(p, false)
      check(`${tag}: "Show labels" off again hides them`, (await labelsShown(p)) === 0)
    } else {
      check(`${tag}: the phone strip has no divider`, dividers === 0, { seq })
      check(`${tag}: the phone strip is unchanged by "Show labels" (names, boxes)`, offLabels === tabs.length && onLabels === tabs.length && flag && same(offBoxes, onBoxes), { offLabels, onLabels, flag })
    }
    await p.evaluate(() => { try { localStorage.removeItem('spool.rail-labels') } catch {} })
    await p.close()
  }
  /* a saved mixed order is drawn as saved (no reordering to group the tabs),
     so it keeps every line its own order makes: STORED is drawn
     channels issues dm | events | flow | people agents boxes | calendar | archive
     (topics, which STORED still names, is not drawn: t1 e4bfddb1) */
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p, STORED))) throw new Error('no session store')
  await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
  await sleep(400)
  const seq = await railSeq(p)
  const tabs = seq.filter((x) => x !== '|')
  const changes = tabs.filter((id, i) => i > 0 && WORKSPACE.has(id) !== WORKSPACE.has(tabs[i - 1])).length
  const dividers = seq.filter((x) => x === '|').length
  check('1440px T015: a saved mixed order keeps its own order and its own lines', same(tabs, parseRailOrder(STORED)) && changes > 1 && dividers === changes, { seq })
  await p.close()
}

/* SPL-1991 (owner HUM-10, t1 dbf2f39b, A on Q1-Q4): the Monitoring rail tab
   opens /monitoring, which lands on its Agents tab; Boxes is the second tab,
   each tab its own path, so Back walks them and a deep link opens one. The
   sidebar keeps the icon rail only; the reserved Tokens tab is not drawn;
   the old Agents and Boxes rail tabs stay (Q2 A). CONTROL: before SPL-1991
   there is no sidebar-tab-monitoring and every check here FAILs. */
async function monitoringSection(browser, base) {
  const path = (p) => new URL(p.url()).pathname
  const at = (p, want) => p.waitForFunction((w) => location.pathname === w, { timeout: 15000 }, want).then(() => true, () => false)
  const bar = (p) => p.$$eval('[data-test=monitoring-tabs] a', (els) => els.map((e) => [e.getAttribute('data-test'), e.getAttribute('aria-current') || '']))
  for (const [width, touch] of [[1440, false], [360, true]]) {
    const tag = `${width}px monitoring`
    const p = await browser.newPage()
    await p.setViewport({ width, height: 900, isMobile: touch, hasTouch: touch })
    await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
    if (!(await signIn(p, undefined))) throw new Error('no session store')
    await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
    await sleep(400)
    const rail = await railOf(p)
    check(`${tag}: the rail has Monitoring after Boxes, and keeps Agents and Boxes`, rail.includes('agents') && rail.includes('boxes') && rail.indexOf('monitoring') === rail.indexOf('boxes') + 1, { rail })
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-monitoring]')?.click())
    check(`${tag}: the rail tab lands on /monitoring/agents`, await at(p, '/monitoring/agents'), path(p))
    await p.waitForSelector('[data-test=monitoring-agents]', { visible: true, timeout: NAV }).catch(() => null)
    /* Costs (spec 123, SPL-2056) shows once /v1/view/me answered; the mock's me is unrestricted */
    await p.waitForSelector('[data-test=monitoring-tab-costs]', { timeout: NAV }).catch(() => null)
    check(`${tag}: the bar draws Agents (current), Boxes, then Costs, no Tokens`, same(await bar(p), [['monitoring-tab-agents', 'page'], ['monitoring-tab-boxes', ''], ['monitoring-tab-costs', '']]), await bar(p))
    check(`${tag}: the summary strip slot is there`, Boolean(await p.$('[data-test=monitoring-summary]')))
    check(`${tag}: the rail tab reads as selected`, (await p.$eval('[data-testid=sidebar-tab-monitoring]', (e) => e.getAttribute('aria-selected'))) === 'true')
    if (!touch) check(`${tag}: the sidebar keeps the icon rail only`, await p.$eval('nav.sidebar', (e) => e.classList.contains('sidebar--rail')))
    await p.click('[data-test=monitoring-tab-boxes]')
    check(`${tag}: the Boxes tab is its own path`, await at(p, '/monitoring/boxes'), path(p))
    check(`${tag}: the Boxes tab renders`, Boolean(await p.waitForSelector('[data-test=monitoring-boxes]', { visible: true, timeout: NAV }).catch(() => null)))
    await p.goBack()
    check(`${tag}: Back returns to the Agents tab`, await at(p, '/monitoring/agents'), path(p))
    await p.goto(`${base}/monitoring/boxes`, { waitUntil: 'networkidle2', timeout: NAV })
    check(`${tag}: a deep link opens the Boxes tab`, Boolean(await p.waitForSelector('[data-test=monitoring-boxes]', { visible: true, timeout: NAV }).catch(() => null)) && path(p) === '/monitoring/boxes', path(p))
    check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-${width}.png` })
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [360, true]]) await run(browser, server.base, w, touch)
  await sameRouteTabs(browser, server.base)
  await noTopicsView(browser, server.base)
  await railDividerLabels(browser, server.base)
  await monitoringSection(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nrail-order-default: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
