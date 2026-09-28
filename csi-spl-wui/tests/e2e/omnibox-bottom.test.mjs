// Topic c6994436 lane B: the Omnibox at the bottom on tablet and desktop.
//
// Owner (prd t1, topic c6994436, 2026-09-27 17:21Z): "the omnibox at the
// bottom and not at the top on tablet and desktop", a per-user setting in
// Settings -> Behaviour (hub pref composer_position, default top). Every
// geometry risk the three evaluations named is a check here, on the mock
// tenant with the session adopted through pinia (the submit-key e2e way):
//
//   default     - the box is in the top bar and the dock takes no room
//   B6 / width  - bottom: the box sits under the MIDDLE pane only, flush with
//                 the window's bottom, not over the rail or the thread
//   B1          - the feed ends at the dock's top edge (not covered), also
//                 after the box grows with a long draft
//   one box     - a draft typed at the top is still there after the switch
//                 (one composer moved, not a second one mounted)
//   B3          - the @ list and the /search syntax help open UPWARD, inside
//                 the window
//   B2          - dragging the grip UP makes the box taller
//   search      - the top bar's search button puts `/search ` in the box
//   B6 focus    - a click in the dock does not choose the middle pane
//   <= 1100 px  - the overlaying thread pane ends above the dock
//   phones      - at 820 px the phone dock (SPL-1005) is used in either
//                 setting, the desktop dock stays empty
//   the page never scrolls, no page error
//
// Run:
//   node tests/e2e/omnibox-bottom.test.mjs
//   BASE_URL=http://127.0.0.1:3000 SHOTS=/tmp/shots node tests/e2e/omnibox-bottom.test.mjs
//   FULL=1 ... also repeats the desktop pass at 1280 and 900 px
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'
const TA = 'form.composer.omnibox--global textarea'

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Adopt a member session; `pos` undefined = never picked (claim absent). */
const setPosition = (p, pos) => p.evaluate((pos) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  const c = { ...(session.claims || {}), hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (pos === undefined) delete c.composer_position
  else c.composer_position = pos
  session.adopt(c)
  return true
}, pos)

/** Where everything is drawn. */
function geometry(p) {
  return p.evaluate(() => {
    const r = (el) => {
      if (!el || !el.getClientRects().length) return null
      const b = el.getBoundingClientRect()
      return { l: Math.round(b.left), t: Math.round(b.top), r: Math.round(b.right), b: Math.round(b.bottom), h: Math.round(b.height) }
    }
    const box = document.querySelector('[data-test=top-bar-omnibox]')
    const dock = document.getElementById('spl-omnibox-dock')
    const main = document.querySelector('.spool-main')
    const feed = [...document.querySelectorAll('.spool-main .feed-body, .spool-main [role=feed]')].find((el) => el.getClientRects().length)
    return {
      vw: window.innerWidth,
      vh: window.innerHeight,
      inBar: Boolean(box && box.closest('header.top-bar')),
      inDock: Boolean(box && dock && dock.contains(box)),
      boxes: document.querySelectorAll('form.composer.omnibox--global').length,
      bar: r(document.querySelector('header.top-bar')),
      box: r(box),
      form: r(document.querySelector('form.composer.omnibox--global')),
      dock: r(dock),
      dockOn: dock ? dock.getAttribute('data-on') : null,
      main: r(main),
      rail: r(document.querySelector('.spool-shell > .sidebar')),
      thread: r(document.querySelector('aside.live-pane, .spool-shell > .topic')),
      feed: r(feed),
      search: r(document.querySelector('[data-test=top-bar-search]')),
      phoneDock: Boolean(document.querySelector('form.composer--dock')),
      docScroll: document.scrollingElement.scrollHeight - window.innerHeight,
    }
  })
}

async function open(browser, vp, path = PATH) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  try {
    await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  } catch (e) {
    await shot(p, `${vp.width}-no-feed`)
    console.log('no feed', p.url(), JSON.stringify(await p.evaluate(() => document.body.innerText.slice(0, 400))), errors)
    throw e
  }
  await sleep(400)
  return { p, errors }
}

const shot = async (p, name) => { if (SHOTS) await p.screenshot({ path: join(SHOTS, `omnibox-bottom-${name}.png`) }) }

async function typeInBox(p, text) {
  await p.$eval(TA, (el) => { el.focus(); el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(TA, text)
  await sleep(250)
}

async function desktopCase(browser, width, height) {
  const tag = `${width}px`
  const { p, errors } = await open(browser, { width, height })
  await setPosition(p, undefined)
  await sleep(300)
  const g0 = await geometry(p)
  await shot(p, `${width}-top`)
  ok(`${tag} default: the box is in the top bar, the dock is empty and takes no room`,
    g0.inBar && !g0.inDock && g0.dock === null && g0.dockOn === null && g0.search === null && g0.boxes === 1, g0)

  /* a draft typed at the top survives the move: ONE composer */
  await typeInBox(p, 'draft c6994436')
  await p.$eval(TA, (el) => el.blur())
  await setPosition(p, 'bottom')
  await sleep(500)
  const g1 = await geometry(p)
  const draft = await p.$eval(TA, (el) => el.value)
  await shot(p, `${width}-bottom`)
  ok(`${tag} bottom: the same box moved into the dock (the draft is still in it, one composer)`,
    g1.inDock && !g1.inBar && g1.boxes === 1 && draft === 'draft c6994436', { inDock: g1.inDock, boxes: g1.boxes, draft })
  ok(`${tag} bottom: the dock is under the MIDDLE pane only and flush with the window bottom`,
    Boolean(g1.dock && g1.main && g1.dock.l >= g1.main.l - 1 && g1.dock.r <= g1.main.r + 1
      && Math.abs(g1.dock.b - g1.vh) <= 1 && (!g1.rail || g1.dock.l >= g1.rail.r - 1)
      && (!g1.thread || g1.dock.r <= g1.thread.l + 1)), { dock: g1.dock, main: g1.main, rail: g1.rail, thread: g1.thread, vh: g1.vh })
  ok(`${tag} bottom: the top bar keeps its height and gets the search button`,
    Boolean(g1.bar && g0.bar && g1.bar.h === g0.bar.h && g1.search), { bar: g1.bar, search: g1.search })
  ok(`${tag} bottom: the feed ends at the dock (nothing under the box)`,
    Boolean(g1.feed && g1.dock && g1.feed.b <= g1.dock.t + 1), { feed: g1.feed, dock: g1.dock })

  /* B1: a long draft grows the box UP and pushes the feed, never over it */
  /* set, not typed: Enter sends by default (SPL-976) */
  await p.$eval(TA, (el, v) => { el.focus(); el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })) },
    Array.from({ length: 14 }, (_, i) => `line ${i}`).join('\n'))
  await sleep(300)
  const g2 = await geometry(p)
  await shot(p, `${width}-bottom-tall`)
  ok(`${tag} B1 a tall draft: the dock grows up, stays at the bottom, the feed still ends at its top`,
    Boolean(g2.dock && g2.dock.h > g1.dock.h + 40 && Math.abs(g2.dock.b - g2.vh) <= 1 && g2.feed && g2.feed.b <= g2.dock.t + 1 && g2.docScroll <= 0),
    { before: g1.dock, after: g2.dock, feed: g2.feed, docScroll: g2.docScroll })

  /* B3: the @ list opens upward, inside the window */
  await typeInBox(p, '@')
  await p.waitForSelector('[data-test=mention-list]', { timeout: 5000 }).catch(() => null)
  const at = await p.evaluate(() => {
    const l = document.querySelector('[data-test=mention-list]')
    const f = document.querySelector('form.composer.omnibox--global .omnibox-field')
    if (!l || !f) return null
    const a = l.getBoundingClientRect(), b = f.getBoundingClientRect()
    return { listTop: Math.round(a.top), listBottom: Math.round(a.bottom), fieldTop: Math.round(b.top) }
  })
  await shot(p, `${width}-bottom-mention`)
  ok(`${tag} B3 the @ list opens UP over the feed, inside the window`,
    Boolean(at && at.listBottom <= at.fieldTop + 1 && at.listTop >= 0), at)
  await p.keyboard.press('Escape')

  /* B3: the /search syntax help opens upward */
  await typeInBox(p, '/search ')
  await p.click('form.composer.omnibox--global [data-test=search-syntax-help]')
  await sleep(250)
  const help = await p.evaluate(() => {
    const l = document.querySelector('[data-test=search-syntax-panel]')
    const f = document.querySelector('form.composer.omnibox--global .omnibox-field')
    if (!l || !f) return null
    const a = l.getBoundingClientRect(), b = f.getBoundingClientRect()
    return { top: Math.round(a.top), bottom: Math.round(a.bottom), fieldTop: Math.round(b.top) }
  })
  await shot(p, `${width}-bottom-syntax`)
  ok(`${tag} B3 the search syntax help opens UP, inside the window`,
    Boolean(help && help.bottom <= help.fieldTop + 5 && help.top >= 0), help)
  await p.keyboard.press('Escape')

  /* B2: the grip on the top edge, dragged UP, makes the box taller */
  await typeInBox(p, 'grip')
  const grip = await p.evaluate(() => {
    const g = document.querySelector('form.composer.omnibox--global [data-test=omnibox-resize]')
    const t = document.querySelector('form.composer.omnibox--global textarea')
    if (!g || !t) return null
    const b = g.getBoundingClientRect()
    return { x: Math.round(b.left + b.width / 2), y: Math.round(b.top + b.height / 2), h: Math.round(t.getBoundingClientRect().height), fieldTop: Math.round(document.querySelector('form.composer.omnibox--global .omnibox-field').getBoundingClientRect().top) }
  })
  if (grip) {
    await p.mouse.move(grip.x, grip.y)
    await p.mouse.down()
    await p.mouse.move(grip.x, grip.y - 60, { steps: 6 })
    await p.mouse.move(grip.x, grip.y - 120, { steps: 6 })
    await p.mouse.up()
    await sleep(200)
  }
  const h2 = await p.$eval(TA, (el) => Math.round(el.getBoundingClientRect().height))
  ok(`${tag} B2 the grip sits on the field's top edge and dragging it UP grows the box`,
    Boolean(grip && Math.abs(grip.y - grip.fieldTop) <= 8 && h2 >= grip.h + 80), { grip, h2 })

  /* the top bar's search button */
  await typeInBox(p, '')
  await p.click('[data-test=top-bar-search]')
  await sleep(250)
  const s = await p.evaluate(() => ({ v: document.querySelector('form.composer.omnibox--global textarea').value, focused: document.activeElement === document.querySelector('form.composer.omnibox--global textarea') }))
  ok(`${tag} the top bar's search button puts "/search " in the bottom box, focused`, s.v === '/search ' && s.focused, s)
  await typeInBox(p, '')

  /* B6: a click in the dock does not choose the middle pane */
  await p.evaluate(() => { document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('pane-focus').set('right') })
  await p.click(TA)
  await sleep(150)
  const last = await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('pane-focus').last)
  ok(`${tag} B6 a click in the dock does not choose the middle pane`, last === 'right', { last })

  /* back to the top: the box returns to the bar, the dock is empty again */
  await setPosition(p, 'top')
  await sleep(400)
  const g3 = await geometry(p)
  ok(`${tag} back to top: the box is in the bar again and the dock takes no room`,
    g3.inBar && !g3.inDock && g3.dock === null && g3.search === null && g3.boxes === 1, { inBar: g3.inBar, dock: g3.dock })
  ok(`${tag} the page never scrolls`, g1.docScroll <= 0 && g3.docScroll <= 0, { g1: g1.docScroll, g3: g3.docScroll })
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

/* <= 1100 px the thread pane overlays the middle one: it ends above the dock */
async function overlayCase(browser) {
  const { p, errors } = await open(browser, { width: 1000, height: 800 })
  await setPosition(p, 'bottom')
  await sleep(300)
  const card = await p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    const b = (el.querySelector('.msg-body') || el).getBoundingClientRect()
    return { x: Math.round(b.left + Math.min(40, b.width / 2)), y: Math.round(b.top + Math.min(10, b.height / 2)) }
  })
  await p.mouse.click(card.x, card.y)
  await sleep(700)
  const g = await geometry(p)
  const pane = await p.evaluate(() => {
    const el = document.querySelector('aside.live-pane')
    if (!el || !el.getClientRects().length) return null
    const b = el.getBoundingClientRect()
    return { b: Math.round(b.bottom), pos: getComputedStyle(el).position }
  })
  await shot(p, '1000-bottom-thread')
  ok('1000px a thread open over the middle pane ends above the bottom dock',
    Boolean(pane && g.dock && (pane.pos !== 'fixed' || pane.b <= g.dock.t + 1)), { pane, dock: g.dock })
  ok('1000px no page error', errors.length === 0, errors)
  await p.close()
}

/* the Teleport mounts the box after the bar: a /search?q= deep link must
   still land in it, at the top (the default) and in the bottom dock */
async function deepLinkCase(browser) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/search?q=deploy', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(TA, { timeout: NAV_TIMEOUT })
  await sleep(600)
  const top = await p.$eval(TA, (el) => el.value)
  ok('1440px a /search?q= deep link shows its query in the box (default, top)', top === '/search deploy', { top })
  await setPosition(p, 'bottom')
  await sleep(400)
  const g = await geometry(p)
  const bottom = await p.$eval(TA, (el) => el.value)
  ok('1440px ... and still after the box moved to the bottom dock', g.inDock && bottom === '/search deploy', { inDock: g.inDock, bottom })
  await p.goto(server.base + '/search?q=release', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(TA, { timeout: NAV_TIMEOUT })
  await setPosition(p, 'bottom')
  await sleep(600)
  const g2 = await geometry(p)
  const fresh = await p.$eval(TA, (el) => el.value)
  ok('1440px a deep link opened with the box at the bottom shows its query there', g2.inDock && fresh === '/search release', { inDock: g2.inDock, fresh })
  ok('1440px deep link: no page error', errors.length === 0, errors)
  await p.close()
}

/* phones keep the SPL-1005 dock in either setting */
async function phoneCase(browser, width, height) {
  const { p, errors } = await open(browser, { width, height, isMobile: true, hasTouch: true })
  for (const pos of ['top', 'bottom']) {
    await setPosition(p, pos)
    await sleep(400)
    const g = await geometry(p)
    await shot(p, `${width}-${pos}`)
    ok(`${width}px ${pos}: the phone dock as before, the desktop dock empty, no bar search button`,
      g.phoneDock && !g.inDock && g.dock === null && g.search === null && g.boxes === 1, { phoneDock: g.phoneDock, inDock: g.inDock, dock: g.dock })
  }
  ok(`${width}px no page error`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 })).p.close()
  const only = process.env.ONLY || ''
  if (!only || only === 'desktop') {
    await desktopCase(browser, 1440, 900)
    /* the CI wui-e2e job runs every suite in one 45-minute budget: the full
       desktop pass once (1440) there; FULL=1 repeats it at 1280 and 900 */
    if (process.env.FULL === '1') {
      await desktopCase(browser, 1280, 800)
      await desktopCase(browser, 900, 1180)
    }
    await overlayCase(browser)
    await deepLinkCase(browser)
  }
  if (only === 'deeplink') await deepLinkCase(browser)
  if (!only || only === 'phone') {
    await phoneCase(browser, 820, 1180)
    await phoneCase(browser, 390, 844)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
