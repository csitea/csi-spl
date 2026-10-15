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
// HUM-10 (t1 89b0200d): "we should be able to open even archived msg from
// their link". /m/<id> of an archived topic's card, of the topic itself and of
// a reply in it opens the channel with the topic on the right, the message
// marked and the topic shown archived; the topic stays open.
//
// The mock feed is lengthened through localStorage `spool.mock.extra-messages`
// (id-links.test.mjs does the same); a row with archived_at is an archived card.
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
/* archived topic 1: a card alone, in no feed; topic 2: a card and one reply */
const ARCH1_CARD = 'f5060000-0000-4000-8000-000000000001'
const ARCH1_TASK = 'f5070000-0000-4000-8000-000000000001'
const ARCH2_CARD = 'f5060000-0000-4000-8000-000000000002'
const ARCH2_TASK = 'f5070000-0000-4000-8000-000000000002'
const ARCH2_REPLY = 'f5080000-0000-4000-8000-000000000002'

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
  const archived = { parent_task_id: undefined, is_parent: 1, archived_at: '2026-12-01T09:00:00Z', archived_by: 'HUM-1' }
  out.push(row({ ...archived, msg_id: ARCH1_CARD, task_id: ARCH1_TASK, body: 'archived topic one', ts: '2026-11-01T09:00:00Z' }))
  out.push(row({ ...archived, msg_id: ARCH2_CARD, task_id: ARCH2_TASK, body: 'archived topic two', ts: '2026-11-02T09:00:00Z' }))
  out.push(row({ msg_id: ARCH2_REPLY, task_id: ARCH2_TASK, parent_task_id: undefined, body: 'a reply in the archived topic', ts: '2026-11-02T09:05:00Z' }))
  return out
}

/* a cold /m/<id> of an archived topic: the channel with the topic open, the
   archived badge in the pane, no failure notice; still open 2.5 s later. A
   reply is shown and marked in the pane. The card itself is not checked: the
   mock pane shows the channel store's rows and never reads the topic (the
   live pane reads it, and the hub's read keeps the archived card). */
async function openedArchived(p, base, id, markId, task) {
  const needMark = markId === id && id !== ARCH1_CARD
  await p.goto(`${base}/m/${id}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  const state = () => p.evaluate((markId, task) => {
    const pane = document.querySelector('aside.live-pane')
    const el = pane && pane.querySelector(`article.msg[data-msg-id="${markId}"]`)
    const notice = document.querySelector('[data-testid="open-msg-notice"]')
    return {
      path: location.pathname + location.search + location.hash,
      place: location.pathname.endsWith('/channel/lobby') && new URLSearchParams(location.search).get('topic') === task,
      shown: Boolean(el && el.getBoundingClientRect().height > 0),
      lit: Boolean(el && (el.classList.contains('open-focus') || el.classList.contains('search-focus'))),
      badge: Boolean(pane && pane.querySelector('[data-test="archived-badge"]')),
      notice: notice ? notice.getAttribute('data-reason') : '',
    }
  }, markId, task)
  const start = Date.now()
  let lit = false
  let last = null
  while (Date.now() - start < 20000) {
    last = await state()
    lit = lit || last.lit
    if (last.notice || ((lit || !needMark) && last.place && (last.shown || !needMark) && last.badge)) break
    await sleep(100)
  }
  await sleep(2500)
  const later = await state()
  const marked = !needMark || (lit && last.shown && later.shown)
  return { ok: marked && last.place && last.badge && !last.notice && later.place && later.badge, needMark, lit, last, later }
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
  /* the scroll has landed: the carrier is on screen and the pane holds still */
  let key = ''
  for (let t = 0; t < 30; t++) {
    const k = await p.evaluate((sel) => {
      const el = document.querySelector(sel)
      const sc = el && el.closest('.feed-body')
      return sc ? `${Math.round(sc.scrollTop)} ${Math.round(el.getBoundingClientRect().top)}` : ''
    }, CARRIER_SEL)
    if (k && k === key) break
    key = k
    await sleep(100)
  }
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
      /* let the highlight end before the next form (JUMP_FOCUS_MS, 2 s from
         the jump), so the next form's highlight is its own */
      for (let t = 0; t < 40 && await p.evaluate(() => Boolean(document.querySelector('aside.live-pane article.msg.open-focus, aside.live-pane article.msg.search-focus'))); t++) await sleep(100)
    }

    for (const [label, id, markId, task] of [
      ['archived card /m/<card>', ARCH1_CARD, ARCH1_CARD, ARCH1_TASK],
      ['archived topic /m/<task> (id-links archived form)', ARCH1_TASK, ARCH1_CARD, ARCH1_TASK],
      ['reply in an archived topic /m/<reply>', ARCH2_REPLY, ARCH2_REPLY, ARCH2_TASK],
    ]) {
      const got = await openedArchived(p, srv.base, id, markId, task)
      ok(`${vp.name} ${label}: opens in its channel${got.needMark ? ', marked' : ''}, shown archived, stays open`, got.ok, got)
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
