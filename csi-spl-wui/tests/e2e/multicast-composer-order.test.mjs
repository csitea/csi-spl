// SPL-6603 (owner HUM-10, t1 c9b86153, 2026-11-26): "the multicast prompt
// should be on top of the topics to multicast to based on the pre-pend or
// append order of the person in his personal settings". The Multicast
// dialog against the lde mock, at 1280x800 and on a 390 px phone:
//   newest first (prepend, also the default when never picked): the prompt
//            box is ABOVE the target list, in the DOM and on screen
//   newest last (append): the prompt box stays BELOW the list
//   live:    flipping Settings -> Behaviour "Message order" while the dialog
//            is open moves the prompt, and the text typed in it stays
// Spec 186 section 4.1 step 2, item 1.
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/multicast-composer-order.test.mjs   # what CI does
//   node tests/e2e/multicast-composer-order.test.mjs                                 # nuxi dev
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CH = 'spl6603-order'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const signIn = (p) => p.evaluateOnNewDocument(() => {
  try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
})
const pinia = () => document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia
/** Settings -> Behaviour "Message order", as the session store applies it; '' = never picked. */
const setOrder = (p, order) => p.evaluate((order) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
  if (order) s.setViewPref('message_order', order)
}, order)

/** Two topics in CH, ticked through the select store; the bar's Multicast opens the dialog. */
async function openDialog(p) {
  await p.evaluate(async (ch) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    const ps = app.config.globalProperties.$pinia._s
    const store = ps.get('channel')
    await store.createChannel(ch).catch(() => {})
    await app.config.globalProperties.$router.push('/channel/' + ch)
    await new Promise((r) => setTimeout(r, 500))
    const picks = []
    for (const n of [1, 2]) {
      const m = await store.send(`order topic ${n}`, undefined, undefined, undefined, 1)
      picks.push({ task_id: m.task_id || m.msg_id, channel: ch, title: `order topic ${n}` })
    }
    ps.get('topicSelect').add(picks)
  }, CH)
  await p.waitForSelector('[data-test=topic-select-act-multicast]', { visible: true, timeout: 10000 })
  await p.click('[data-test=topic-select-act-multicast]')
  return until(p, () => [...document.querySelectorAll('[data-test=multicast-dialog] [data-test=multicast-target]')].filter((e) => e.getClientRects().length).length === 2, null, 10000)
}

/** Where the dialog's prompt box sits against its target list: DOM order and on screen. */
const place = (p) => p.evaluate(() => {
  const d = document.querySelector('[data-test=multicast-dialog]')
  const box = d?.querySelector('[data-test=multicast-composer] textarea')
  const rows = [...(d?.querySelectorAll('[data-test=multicast-target]') || [])]
  if (!box || !rows.length) return { found: false }
  const b = box.getBoundingClientRect()
  const first = rows[0].getBoundingClientRect()
  const last = rows[rows.length - 1].getBoundingClientRect()
  return {
    found: true,
    domBefore: Boolean(box.compareDocumentPosition(rows[0]) & Node.DOCUMENT_POSITION_FOLLOWING),
    above: b.bottom <= first.top + 0.5,
    below: b.top >= last.bottom - 0.5,
    prompt: d.getAttribute('data-prompt'),
  }
})

async function run(browser, base, label, viewport, order) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(p)
  await p.setViewport(viewport)
  await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await until(p, () => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia?._s.get('channel')), null, NAV_TIMEOUT)
  await setOrder(p, order)
  const name = `${label} ${order || 'never picked'}`
  ok(`${name}: the dialog opens with both targets`, await openDialog(p))
  const top = order !== 'newest-last'
  const at = await place(p)
  if (top) ok(`${name}: the prompt box is above the target list (DOM and screen)`, at.found && at.domBefore && at.above, at)
  else ok(`${name}: the prompt box stays below the target list (DOM and screen)`, at.found && !at.domBefore && at.below, at)
  if (order) {
    /* live: flip the setting with text in the box; the prompt moves and keeps it */
    await p.type('[data-test=multicast-composer] textarea', 'kept')
    await setOrder(p, top ? 'newest-last' : 'newest-first')
    const flipped = await until(p, (want) => document.querySelector('[data-test=multicast-dialog]')?.getAttribute('data-prompt') === want, top ? 'bottom' : 'top', 3000)
    const again = await place(p)
    const text = await p.evaluate(() => document.querySelector('[data-test=multicast-composer] textarea')?.value)
    ok(`${name}: a flip of the setting moves the prompt ${top ? 'below' : 'above'} the list at once`, flipped && again.found && (top ? again.below && !again.domBefore : again.above && again.domBefore), again)
    ok(`${name}: the text typed before the flip stays in the box`, text === 'kept', { text })
  }
  ok(`${name}: no page errors`, errors.length === 0, errors)
  await p.close()
}

const DESK = { width: 1280, height: 800 }
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }

const srv = await startServer()
const browser = await launch()
try {
  for (const [label, vp] of [['desktop 1280', DESK], ['phone 390', PHONE]]) {
    for (const order of ['newest-first', 'newest-last', '']) await run(browser, srv.base, label, vp, order)
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmulticast-composer-order: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
