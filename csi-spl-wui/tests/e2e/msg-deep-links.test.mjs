// Owner priority (t1 48d09034): a link to a message opens THAT message, also
// when it is in the topic the reader already has open. In a 60-reply thread
// the newest reply links back to the oldest one; a click (desktop) or a tap
// (phone) on each link form scrolls that reply into view in the thread pane
// and highlights it. The same link clicked a second time, after the reader
// scrolled away, jumps again.
//
// Link forms, as agents post them: the full place URL
// (<origin>/channel/<ch>?topic=<task>#<msg>), the deep link <origin>/m/<msg>,
// and the bare message id.
//
// The mock feed is lengthened through localStorage `spool.mock.extra-messages`
// (id-links.test.mjs does the same).
//
// Run: node tests/e2e/msg-deep-links.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const FROM = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLIES = 60
const TARGET = 'f5010000-0000-4000-8000-000000000000'
const CARRIER = 'f5030000-0000-4000-8000-000000000001'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function row(partial) {
  return {
    v: 1,
    files: [],
    channel: 'lobby',
    from: 'HUM-1',
    from_box: 'box-wui',
    to: '@channel',
    to_box: 'box-wui',
    kind: 'note',
    parent_task_id: FROM,
    is_parent: 0,
    ...partial,
  }
}

/* REPLIES replies; the first (oldest) is the target. The carrier is the
   newest reply and holds one line per link form. */
function threadRows(base) {
  const out = []
  for (let i = 0; i < REPLIES; i++) {
    const tail = i.toString(16).padStart(12, '0')
    out.push(row({
      msg_id: `f5010000-0000-4000-8000-${tail}`,
      task_id: `f5020000-0000-4000-8000-${tail}`,
      body: i === 0 ? 'the question the owner was asked' : `reply ${i}`,
      ts: `2026-12-20T10:${String(i).padStart(2, '0')}:00Z`,
    }))
  }
  out.push(row({
    msg_id: CARRIER,
    task_id: 'f5040000-0000-4000-8000-000000000001',
    body: [
      `place ${base}/channel/lobby?topic=${FROM}#${TARGET}`,
      `deep ${base}/m/${TARGET}`,
      `bare ${TARGET}`,
    ].join('\n'),
    ts: '2026-12-31T23:59:00Z',
  }))
  return out
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

const CARRIER_SEL = `aside.live-pane article.msg[data-msg-id="${CARRIER}"]`

async function openThread(p, base) {
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.evaluateOnNewDocument((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, threadRows(base))
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(`${base}/channel/lobby?topic=${FROM}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) throw new Error('no shell ' + JSON.stringify(errors.slice(0, 4)))
  await p.waitForSelector(`${CARRIER_SEL} a.msg-link`, { visible: true, timeout: 20000 })
  /* a generated bundle reloads once while the shell settles (id-links.test.mjs) */
  await p.evaluate(() => { window.__deepBoot = 1 })
  const reloaded = await p.waitForFunction(() => window.__deepBoot !== 1, { timeout: 2000 }).then(() => true, () => false)
  if (reloaded) {
    await p.waitForSelector('.spool-shell', { timeout: 15000 })
    await p.waitForSelector(`${CARRIER_SEL} a.msg-link`, { visible: true, timeout: 20000 })
  }
}

/* the thread pane scrolled so the carrier (the newest reply) is on screen and the target is not */
async function scrollToCarrier(p) {
  await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    const scroller = el && el.closest('.feed-body')
    if (!el || !scroller) return
    scroller.scrollTop += el.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 40
  }, CARRIER_SEL)
  await sleep(300)
}

const where = (p) => p.evaluate((id) => {
  const el = document.querySelector(`aside.live-pane article.msg[data-msg-id="${id}"]`)
  const scroller = el && el.closest('.feed-body')
  const path = location.pathname + location.search + location.hash
  if (!el || !scroller) return { present: false, inView: false, path }
  const r = el.getBoundingClientRect()
  const b = scroller.getBoundingClientRect()
  const inView = r.height > 0 && r.top >= b.top - 2 && r.top < Math.min(b.bottom, window.innerHeight) - 10
  return { present: true, inView, top: Math.round(r.top), boxTop: Math.round(b.top), boxBottom: Math.round(b.bottom), path }
}, TARGET)

/* a link that wraps has two boxes; its bounding-box centre can be the
   paragraph between them, so the tap goes to the first line's box */
async function tapOrClick(p, sel, phone) {
  const handle = await p.$(sel)
  if (!handle) return false
  const at = await handle.evaluate((a) => {
    const r = a.getClientRects()[0]
    const x = r.left + Math.min(r.width / 2, 20)
    const y = r.top + r.height / 2
    const hit = document.elementFromPoint(x, y)
    return { x, y, onLink: Boolean(hit && a.contains(hit)) }
  })
  if (!at.onLink) return false
  if (phone) await p.touchscreen.tap(at.x, at.y)
  else await p.mouse.click(at.x, at.y)
  return true
}

/* after a click: the target lands in view and carries the highlight */
async function jumped(p) {
  const start = Date.now()
  let lit = false
  let last = null
  while (Date.now() - start < 10000) {
    const s = await p.evaluate((id) => {
      const el = document.querySelector(`aside.live-pane article.msg[data-msg-id="${id}"]`)
      return Boolean(el && (el.classList.contains('open-focus') || el.classList.contains('search-focus')))
    }, TARGET)
    lit = lit || s
    last = await where(p)
    if (lit && last.inView) return { ok: true, ...last }
    await sleep(100)
  }
  return { ok: false, lit, ...last }
}

const srv = await startServer()
const browser = await launch()
try {
  for (const vp of [
    { name: '390px', phone: true, size: { width: 390, height: 844, isMobile: true, hasTouch: true } },
    { name: '1440px', phone: false, size: { width: 1440, height: 900 } },
  ]) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport(vp.size)
    await openThread(p, srv.base)
    /* the owner's case: the thread shows its newest window, the question is not on it */
    const first = await p.evaluate((id) => ({
      count: document.querySelectorAll('aside.live-pane article.msg').length,
      target: Boolean(document.querySelector(`aside.live-pane article.msg[data-msg-id="${id}"]`)),
    }), TARGET)
    ok(`${vp.name} the ${REPLIES}-reply thread opens without the old reply rendered`, first.count >= 20 && !first.target, first)

    const forms = [
      ['place link', `${CARRIER_SEL} a.msg-link[href*="topic=${FROM}#${TARGET}"]`],
      ['deep link /m/<id>', `${CARRIER_SEL} a.msg-link[href*="/m/${TARGET}"]`],
      ['bare message id', `${CARRIER_SEL} a.msg-link[href^="/"][href*="#${TARGET}"]`],
      ['place link, second click', `${CARRIER_SEL} a.msg-link[href*="topic=${FROM}#${TARGET}"]`],
    ]
    for (const [label, sel] of forms) {
      await scrollToCarrier(p)
      const before = await where(p)
      const clicked = await tapOrClick(p, sel, vp.phone)
      if (!clicked) {
        ok(`${vp.name} ${label}: the link is rendered and on top`, false, { sel })
        continue
      }
      const after = await jumped(p)
      ok(`${vp.name} ${label}: the target was off screen, now in view and highlighted`, !before.inView && after.ok, { before, after })
      /* let the highlight end before the next form */
      await sleep(2300)
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmsg-deep-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
