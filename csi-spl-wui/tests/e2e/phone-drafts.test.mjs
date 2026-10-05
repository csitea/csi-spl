// Spec 088 T003 (FR-002..FR-004): 080's per-place drafts at phone size.
// On a phone a place is left by Back (chevron, dock Back, edge swipe) and a
// tap on a level-1 row, not the desktop sidebar click drafts-per-place uses.
// Measured before 080 (spec §2 row 1): `abc` typed in #lobby was still in the
// box in #feedback after Back and a tap, ready to post there.
//
//   mock tenant, signed in as HUM-1, touch on, at 360x780 and 390x844:
//     AC1 #lobby: type `abc`, Back, tap #feedback -> the box is empty;
//         Back, tap #lobby -> `abc`. Once per Back: chevron, dock, edge swipe
//     AC3 #lobby: type `abc`, wait 400 ms, reload -> `abc`; open a topic,
//         type `xyz`, reload -> `xyz`
//     AC4 (087 T004 built: src/utils/last-place.mjs exists) a draft `abc` on
//         #feedback, close the page, open `/` -> 087 restores #feedback and
//         the box reads `abc`. Skipped, with its reason printed, before that
//     AC5 a draft on #feedback: at level 1 its row shows the pencil (>= 12 px,
//         accessible name "Draft"); a topic reply draft shows the pencil on
//         that topic's card
//
// A failing AC1 or AC3 is a bug in 080's place change (088 tasks.md T003);
// a failing AC5 is 088 T004 (the <= 820 px CSS of the pencil).
//
// Run:
//   pnpm run test:e2e phone-drafts
//   BASE_URL=<generated bundle> pnpm run test:e2e phone-drafts   # what CI does
//   Narrow: WIDTHS=390 METHODS=chevron
import { createRequire } from 'node:module'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const HUM = 'HUM-1'
const MEMBER = { hum: HUM, email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const BOX = 'form.composer.omnibox--global textarea'
/* a topic in the mock's #lobby (phone-back-matrix uses the same one) */
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const SIZES = { 360: 780, 390: 844 }
const ALL_METHODS = ['chevron', 'dock', 'edge']
const WIDTHS = (process.env.WIDTHS || '360,390').split(',').map(Number).filter((w) => SIZES[w])
const METHODS = process.env.METHODS ? process.env.METHODS.split(',').filter((m) => ALL_METHODS.includes(m)) : ALL_METHODS
/* the composer keeps a draft 300 ms after the last key (080 FR-002) */
const SAVE_WAIT = 400
/* the marks re-read `spool.drafts` once a second (composables/useDrafts.ts) */
const MARK_WAIT = 3000
const MIN_MARK = 12
const AC4_READY = existsSync(join(WUI, 'src/utils/last-place.mjs'))

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

/* before any app code, on every document: a signed-in mock member (drafts
   are kept per human id) */
function boot(member) {
  try { localStorage.setItem('spool.mock.session', JSON.stringify(member)) } catch { /* private mode */ }
}

const level = (p) => p.evaluate(() => Number(document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || 0)).catch(() => 0)
const boxText = (p) => p.$eval(BOX, (el) => el.value).catch(() => null)
const drafts = (p) => p.evaluate((hum) => {
  try { return JSON.parse(localStorage.getItem('spool.drafts') || '{}')[hum] || {} } catch { return null }
}, HUM).catch(() => null)

async function atLevel(p, lv, ms = 8000) {
  const t0 = Date.now()
  while ((await level(p)) !== lv && Date.now() - t0 < ms) await sleep(100)
  await sleep(350)
  return level(p)
}

async function open(p, base, path) {
  await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await sleep(500)
}

async function newPhone(browser, width) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width, height: SIZES[width], isMobile: true, hasTouch: true })
  await p.evaluateOnNewDocument(boot, MEMBER)
  return p
}

async function clearDrafts(p) {
  await p.evaluate(() => localStorage.removeItem('spool.drafts'))
}

async function type(p, text) {
  await p.focus(BOX)
  await p.type(BOX, text)
  await sleep(SAVE_WAIT)
}

const click = (p, sel) => p.evaluate((q) => {
  const e = [...document.querySelectorAll(q)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e || e.disabled) return false
  e.click()
  return true
}, sel)

async function swipe(p, x0) {
  const cdp = await p.target().createCDPSession()
  const t = (type, x) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y: 420 }] })
  await t('touchStart', x0)
  for (let i = 1; i <= 6; i++) { await t('touchMove', x0 + i * 25); await sleep(16) }
  await t('touchEnd', x0 + 150)
  await cdp.detach()
}

/** One Back by `method`; false when its control is not there to press. */
async function back(p, method) {
  if (method === 'chevron') return click(p, '[data-testid=mobile-back]')
  if (method === 'dock') return click(p, '[data-testid=dock-back]')
  await swipe(p, 8)
  return true
}

/** At level 1: the Channels list, then a tap on the channel's row (level 2). */
async function tapChannel(p, id) {
  await click(p, '[data-testid=sidebar-tab-channels]')
  await p.waitForSelector(`#sidebar-panel-channels a.nav-item[data-key="${id}"]`, { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate((key) => document.querySelector(`#sidebar-panel-channels a.nav-item[data-key="${key}"]`).click(), id)
  await p.waitForFunction((key) => location.pathname.endsWith(`/channel/${key}`), { timeout: NAV_TIMEOUT }, id)
  await atLevel(p, 2)
  await sleep(300)
}

/* the topic pinia store opens a topic the way a card tap does */
async function openTopic(p, id) {
  await p.evaluate((task) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    pinia?._s.get('topic')?.openTopic(task)
  }, id)
  await p.waitForFunction((task) => new URLSearchParams(location.search).get('topic') === task, { timeout: NAV_TIMEOUT }, id)
  await atLevel(p, 3)
}

/** The pencil under `sel`: shown, its box, its accessible name. */
async function mark(p, sel) {
  const shown = await p.waitForSelector(sel, { visible: true, timeout: MARK_WAIT }).then(() => true, () => false)
  if (!shown) return { shown }
  return p.$eval(sel, (el) => {
    const r = (el.querySelector('svg') || el).getBoundingClientRect()
    return { shown: true, w: Math.round(r.width), h: Math.round(r.height), name: el.getAttribute('aria-label') || el.getAttribute('title') || '' }
  })
}
const markOk = (m) => m.shown && m.w >= MIN_MARK && m.h >= MIN_MARK && m.name === 'Draft'

async function ac1(browser, base, width, method) {
  const p = await newPhone(browser, width)
  const tag = `${width} ${method}`
  try {
    await open(p, base, '/channel/lobby')
    await clearDrafts(p)
    await open(p, base, '/channel/lobby')
    await type(p, 'abc')
    const pressed = await back(p, method)
    const l1 = await atLevel(p, 1)
    if (!pressed || l1 !== 1) {
      ok(`AC1 ${tag}: Back from #lobby reaches level 1`, false, { pressed, level: l1 })
      return
    }
    await tapChannel(p, 'feedback')
    const onFeedback = await boxText(p)
    ok(`AC1 ${tag}: a draft typed on #lobby does not follow Back and a tap to #feedback`, onFeedback === '', { onFeedback })
    await back(p, method)
    const l1b = await atLevel(p, 1)
    await tapChannel(p, 'lobby')
    const onLobby = await boxText(p)
    ok(`AC1 ${tag}: Back and a tap on #lobby bring the draft back`, l1b === 1 && onLobby === 'abc', { level: l1b, onLobby, drafts: await drafts(p) })
  } catch (e) {
    ok(`AC1 ${tag}: ran`, false, { error: e.message })
  } finally {
    await p.close().catch(() => {})
  }
}

async function ac3(browser, base, width) {
  const p = await newPhone(browser, width)
  try {
    await open(p, base, '/channel/lobby')
    await clearDrafts(p)
    await open(p, base, '/channel/lobby')
    await type(p, 'abc')
    await open(p, base, '/channel/lobby')
    const afterReload = await boxText(p)
    ok(`AC3 ${width}: a reload on #lobby keeps the draft`, afterReload === 'abc', { afterReload, drafts: await drafts(p) })
    await openTopic(p, TASK)
    const inTopic = await boxText(p)
    await type(p, 'xyz')
    const url = p.url()
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
    await sleep(500)
    const topicAfter = await boxText(p)
    ok(`AC3 ${width}: a reload in a topic keeps the reply draft`, inTopic === '' && /[?&]topic=/.test(url) && topicAfter === 'xyz',
      { inTopic, url: url.replace(base, ''), topicAfter, drafts: await drafts(p) })
  } catch (e) {
    ok(`AC3 ${width}: ran`, false, { error: e.message })
  } finally {
    await p.close().catch(() => {})
  }
}

async function ac4(browser, base, width) {
  if (!AC4_READY) {
    console.log(`  SKIP AC4 ${width}: 087 T004 (src/utils/last-place.mjs, the restore at /) is not on this tree; it runs once that lands`)
    return
  }
  let p = await newPhone(browser, width)
  try {
    await open(p, base, '/channel/feedback')
    await clearDrafts(p)
    await open(p, base, '/channel/feedback')
    await type(p, 'abc')
    await p.close()
    p = await newPhone(browser, width)
    await open(p, base, '/')
    await p.waitForFunction(() => location.pathname.endsWith('/channel/feedback'), { timeout: 8000 }).catch(() => null)
    await sleep(500)
    const path = new URL(p.url()).pathname
    const restored = await boxText(p)
    ok(`AC4 ${width}: / restores #feedback with its draft in the box`, path.endsWith('/channel/feedback') && restored === 'abc', { path, restored })
  } catch (e) {
    ok(`AC4 ${width}: ran`, false, { error: e.message })
  } finally {
    await p.close().catch(() => {})
  }
}

async function ac5(browser, base, width) {
  const p = await newPhone(browser, width)
  try {
    await open(p, base, '/channel/feedback')
    await clearDrafts(p)
    await open(p, base, '/channel/feedback')
    await type(p, 'abc')
    await back(p, 'chevron')
    await atLevel(p, 1)
    await click(p, '[data-testid=sidebar-tab-channels]')
    const row = await mark(p, '#sidebar-panel-channels a.nav-item[data-key="feedback"] [data-testid=draft-mark]')
    ok(`AC5 ${width}: the #feedback row at level 1 shows the pencil (>= ${MIN_MARK} px, named "Draft")`, markOk(row), row)

    await open(p, base, '/channel/lobby')
    await openTopic(p, TASK)
    await type(p, 'xyz')
    await back(p, 'chevron')
    await atLevel(p, 2)
    const card = await mark(p, `.spool-main article.msg[data-task-id="${TASK}"] [data-testid=msg-draft]`)
    ok(`AC5 ${width}: the topic card with a reply draft shows the pencil (>= ${MIN_MARK} px, named "Draft")`, markOk(card), card)
  } catch (e) {
    ok(`AC5 ${width}: ran`, false, { error: e.message })
  } finally {
    await p.close().catch(() => {})
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const width of WIDTHS) {
    for (const method of METHODS) await ac1(browser, server.base, width, method)
    await ac3(browser, server.base, width)
    await ac4(browser, server.base, width)
    await ac5(browser, server.base, width)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
if (!results.length) {
  console.log('FAIL: no check selected')
  process.exit(1)
}
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
