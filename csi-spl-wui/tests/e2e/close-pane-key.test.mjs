// SPL-2552 (owner HUM-10, t1 7af14523 msg 5e6f0db8): Shift + W closes the
// rightmost pane, as Ctrl + W closes a tab (spec 081 FR-013).
//
// Against the mock tenant, a 1440x900 desktop, no touch:
//   - two panes open: the search results on the left and a topic on the
//     right; Shift + W closes the topic pane, the search list stays
//   - Shift + W again closes the search list
//   - with no pane beyond the conversation, Shift + W does nothing (same URL)
//   - a topic open, Shift + W in the composer types 'W' and closes nothing
//   - the Shift + ? list names Shift + W
//   - phone 390: Shift + W leaves the topic open
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/close-pane-key.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const Q = 'green'
const SEARCH = '[data-testid=sidebar-panel-search]'
const ENTRY = `${SEARCH} [data-testid=left-list][data-mode=search] [data-testid=left-entry][data-type=messages]`
const TOPIC = 'aside.live-pane'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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

const shown = (sel) => {
  const el = document.querySelector(sel)
  return Boolean(el && el.getClientRects().length > 0)
}
/* runs in the page, so it cannot call shown() */
const gone = (sel) => {
  const el = document.querySelector(sel)
  return !el || el.getClientRects().length === 0
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

async function shiftW(p) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('KeyW')
  await p.keyboard.up('Shift')
}

/** open the first middle card's topic on the right, as the feed's click does */
async function openTopic(p) {
  const id = await p.evaluate(() => {
    const tid = document.querySelector('.spool-main article.msg[data-task-id]')?.getAttribute('data-task-id') || ''
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    if (tid) void pinia._s.get('live-pane').open(tid)
    return tid
  })
  const open = await p.waitForSelector(TOPIC, { visible: true, timeout: 10000 }).then(() => true, () => false)
  await sleep(400)
  return Boolean(id) && open
}

/** a middle card holds the focus: not a text field */
const focusCard = (p) => p.evaluate(() => {
  const card = document.querySelector('.spool-main article.msg')
  card?.focus()
  return Boolean(card && document.activeElement === card)
})

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* private mode */ }
  })
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })

  /* ---- two panes: the search list (left) and a topic (right) ---- */
  await p.goto(`${srv.base}/search?q=${Q}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(ENTRY, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(ENTRY)
  await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  await p.waitForSelector('.spool-main article.msg[data-task-id]', { visible: true, timeout: 15000 })
  ok('the search list is open on the left', await p.evaluate(shown, ENTRY))
  ok('a topic opens on the right', await openTopic(p))
  ok('start: a card holds the focus', await focusCard(p))

  await shiftW(p)
  ok('Shift + W closes the rightmost pane (the topic)', await until(p, gone, TOPIC, 3000))
  /* waits, as the checks around it do: one hosted job read it gone, twice, the
     instant the topic left (run 39264153837); the next hosted run and the box
     read it kept (run 39266091119, same WUI code) */
  const kept = await until(p, shown, ENTRY, 3000)
  ok('... and leaves the search list open', kept, kept ? undefined : await p.evaluate((s) => ({
    url: location.pathname + location.search,
    panel: Boolean(document.querySelector(s)),
    mode: document.querySelector(`${s} [data-testid=left-list]`)?.getAttribute('data-mode') ?? null,
    entries: document.querySelectorAll(`${s} [data-testid=left-entry]`).length,
  }), SEARCH))

  await focusCard(p)
  await shiftW(p)
  ok('Shift + W again closes the next pane (the search list)', await until(p, gone, SEARCH, 3000))

  const before = p.url()
  await focusCard(p)
  await shiftW(p)
  await sleep(600)
  ok('with no pane beyond the conversation, Shift + W does nothing', p.url() === before && await p.evaluate(shown, '.spool-main article.msg'), p.url())

  /* ---- in the composer Shift + W types ---- */
  ok('a topic opens again', await openTopic(p))
  const focused = await p.evaluate(() => {
    const box = document.querySelector('textarea')
    box?.focus()
    return Boolean(box && document.activeElement === box)
  })
  ok('the composer holds the focus', focused)
  await shiftW(p)
  await sleep(400)
  const val = await p.evaluate(() => document.activeElement?.value ?? '')
  ok('Shift + W in the composer types W', /W$/.test(val), val)
  ok('... and closes nothing', await p.evaluate(shown, TOPIC))
  await p.evaluate(() => { const b = document.activeElement; if (b && 'value' in b) { b.value = ''; b.dispatchEvent(new Event('input', { bubbles: true })) } b?.blur() })

  /* ---- the Shift + ? list names it ---- */
  await focusCard(p)
  await p.keyboard.down('Shift'); await p.keyboard.press('Slash'); await p.keyboard.up('Shift')
  const listed = await until(p, () => {
    const dl = document.querySelector('[data-testid=msg-shortcuts-help]')
    return Boolean(dl && [...dl.querySelectorAll('dt')].some((dt) => dt.textContent.replace(/\s+/g, '') === '⇧W'))
  }, null, 4000)
  ok('the Shift + ? list names Shift + W', listed)
  await p.keyboard.press('Escape')
  await until(p, () => !document.querySelector('[data-testid=msg-shortcuts-help]'), null, 3000)
  ok('... and closing that list leaves the topic open', await p.evaluate(shown, TOPIC))

  /* ---- phone: not there ---- */
  const m = await browser.newPage()
  m.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await m.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* private mode */ }
  })
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await m.waitForSelector('.spool-main article.msg[data-task-id]', { timeout: 15000 })
  ok('phone: a topic opens', await openTopic(m))
  await m.evaluate(() => document.activeElement?.blur?.())
  await shiftW(m)
  await sleep(600)
  ok('phone: Shift + W leaves it open', await m.evaluate(shown, TOPIC))

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nclose-pane-key: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
