// HUM-10 (t1 36ea84a6): every link to a topic or a message opens the channel
// view of its channel - or, for a direct message, the private messages view -
// with that topic or message jumped to and highlighted. No link opens the
// Topics view or leaves the Flow list on the left.
//
// Link forms in a post: the full place URL, the deep link /m/<id>, the bare
// message id, the topic-page URL /t/<task>#<msg> (the old Copy link), the
// topic link /t/<task> and the bare topic id. Entry points: a link in a post
// read from the Flow tab, the same link read in the Topics view, a
// notification tap, a cold /m/<id>, and a search result. Each at 1440 and
// 390 px, for a channel reply and for a DM reply.
//
// The mock feed is lengthened through localStorage `spool.mock.extra-messages`
// (id-links.test.mjs does the same).
//
// SPL-2150: a deep-linked topic near the end of a long list still sits at the
// top of the topics pane after the window is resized (1440x900 <-> 1440x600,
// phone portrait <-> landscape): the room left after the last card follows
// the pane's height instead of the height it had when the link opened.
//
// Run: node tests/e2e/links-open-channel-view.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* a channel topic in #lobby and one reply in its thread */
const CH_TASK = 'f6020000-0000-4000-8000-000000000000'
const CH_ROOT = 'f6010000-0000-4000-8000-000000000000'
const CH_REPLY = 'f6010000-0000-4000-8000-000000000001'
/* the mock DM with GRK-03 (mock-data.mjs): its card and the reply in its thread */
const DM_TASK = '99999999-9999-4999-8999-999999999999'
const DM_ROOT = '77777777-7777-4777-8777-777777777777'
const DM_REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const DM_PEER = 'GRK-03@box-a'
/* the post carrying the links, a card in #alerts */
const CARRIER = 'f6030000-0000-4000-8000-000000000001'
const CARRIER_TASK = 'f6040000-0000-4000-8000-000000000001'
const SEARCH_WORD = 'zebracrossing'

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
    from: 'HUM-1',
    from_box: 'box-wui',
    to: '@channel',
    to_box: 'box-wui',
    kind: 'note',
    parent_task_id: null,
    is_parent: 1,
    ...partial,
  }
}

/* one line per link form; each line holds exactly one link, so the n-th
   anchor of the carrier is the n-th form */
const FORMS = [
  { label: 'channel place URL', line: (b) => `${b}/channel/lobby?topic=${CH_TASK}#${CH_REPLY}`, place: 'channel', target: CH_REPLY },
  { label: 'channel /m/<id>', line: (b) => `${b}/m/${CH_REPLY}`, place: 'channel', target: CH_REPLY },
  { label: 'channel bare message id', line: () => CH_REPLY, place: 'channel', target: CH_REPLY },
  { label: 'channel /t/<task>#<msg>', line: (b) => `${b}/t/${CH_TASK}#${CH_REPLY}`, place: 'channel', target: CH_REPLY },
  { label: 'channel topic link /t/<task>', line: (b) => `${b}/t/${CH_TASK}`, place: 'channel', target: CH_ROOT },
  { label: 'channel bare topic id', line: () => CH_TASK, place: 'channel', target: CH_ROOT },
  { label: 'DM place URL', line: (b) => `${b}/dm/${DM_PEER}?topic=${DM_TASK}#${DM_REPLY}`, place: 'dm', target: DM_REPLY },
  { label: 'DM /m/<id>', line: (b) => `${b}/m/${DM_REPLY}`, place: 'dm', target: DM_REPLY },
  { label: 'DM bare message id', line: () => DM_REPLY, place: 'dm', target: DM_REPLY },
  { label: 'DM /t/<task>#<msg>', line: (b) => `${b}/t/${DM_TASK}#${DM_REPLY}`, place: 'dm', target: DM_REPLY },
  { label: 'DM topic link /t/<task>', line: (b) => `${b}/t/${DM_TASK}`, place: 'dm', target: DM_ROOT },
]

function extraRows(base) {
  return [
    row({ msg_id: CH_ROOT, task_id: CH_TASK, channel: 'lobby', body: 'the channel topic', ts: '2026-12-20T10:00:00Z' }),
    row({
      msg_id: CH_REPLY,
      task_id: 'f6020000-0000-4000-8000-000000000001',
      parent_task_id: CH_TASK,
      is_parent: 0,
      channel: 'lobby',
      body: `the ${SEARCH_WORD} reply in the channel thread`,
      ts: '2026-12-20T10:01:00Z',
    }),
    row({
      msg_id: CARRIER,
      task_id: CARRIER_TASK,
      channel: 'alerts',
      body: FORMS.map((f, i) => `${i + 1}. ${f.line(base)}`).join('\n\n'),
      ts: '2026-12-31T23:59:00Z',
    }),
  ]
}

/* SPL-2150: a long #lobby whose OLDEST topic is the one linked, so it is the
   last card and needs the room after the list to reach the top of the pane */
const LAND_TASK = 'f6060000-0000-4000-8000-000000000000'
const LAND_ROOT = 'f6050000-0000-4000-8000-000000000000'
function landRows() {
  const rows = []
  for (let i = 0; i < 14; i++) {
    const n = String(i).padStart(2, '0')
    rows.push(row({
      msg_id: `f6050000-0000-4000-8000-0000000001${n}`,
      task_id: `f6060000-0000-4000-8000-0000000001${n}`,
      channel: 'lobby',
      body: `filler topic ${n}\n\nsecond line of filler ${n}`,
      ts: `2026-12-2${Math.floor(i / 10)}T1${i % 10}:00:00Z`,
    }))
  }
  rows.push(row({ msg_id: LAND_ROOT, task_id: LAND_TASK, channel: 'lobby', body: 'the oldest topic, linked', ts: '2020-01-01T00:00:00Z' }))
  return rows
}

/* where the linked card sits against the top of its topics pane (px; 0 =
   landed), or 'pane' on a phone in portrait, where the topic's own pane
   covers the list */
const landGap = (p) => p.evaluate((task, root) => {
  const card = [...document.querySelectorAll(`.spool-main article.msg[data-task-id="${task}"]`)]
    .find((c) => c.getBoundingClientRect().height > 0)
  const scroller = card && card.closest('.feed-body')
  if (scroller && scroller.clientHeight > 0) return Math.round(card.getBoundingClientRect().top - scroller.getBoundingClientRect().top)
  const inPane = [...document.querySelectorAll(`aside.live-pane article.msg[data-msg-id="${root}"]`)]
    .some((c) => { const r = c.getBoundingClientRect(); return r.height > 0 && r.top < window.innerHeight && r.bottom > 0 })
  return inPane ? 'pane' : null
}, LAND_TASK, LAND_ROOT)
const landedAt = (g) => g === 'pane' || (typeof g === 'number' && Math.abs(g) <= 2)

/* the gap once it has kept one value for 600 ms (or after 8 s) */
async function settledGap(p) {
  const deadline = Date.now() + 8000
  let last = null
  let since = Date.now()
  while (Date.now() < deadline) {
    const g = await landGap(p)
    if (g !== last) { last = g; since = Date.now() } else if (g !== null && Date.now() - since >= 600) return g
    await sleep(100)
  }
  return last
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

/* tabs whose one boot reload has been waited for */
const booted = new WeakSet()

async function goto(p, url) {
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) throw new Error('no shell at ' + url)
  /* a generated bundle reloads once while the shell settles (id-links.test.mjs).
     That reload is build-watch's, guarded once per tab and build in
     sessionStorage, which a goto in the same tab keeps, so only a tab's first
     goto waits for it (chunk-reload fires only on a missing chunk). Waiting
     on every goto ran the 2 s out 56 times: 112 of the file's 161 s locally
     (spec 133 round 16). */
  if (booted.has(p)) return
  booted.add(p)
  await p.evaluate(() => { window.__lovBoot = 1 })
  const reloaded = await p.waitForFunction(() => window.__lovBoot !== 1, { timeout: 2000 }).then(() => true, () => false)
  if (reloaded) await p.waitForSelector('.spool-shell', { timeout: 15000 })
}

async function newPage(browser, vp, base) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport(vp.size)
  await p.evaluateOnNewDocument((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, extraRows(base))
  return p
}

/* the carrier's links as the reader sees them: the thread pane (or the topic
   page's pane) shows the carrier; the n-th visible link is the n-th form */
const LINKS_SEL = `article.msg[data-msg-id="${CARRIER}"] a.msg-link`

async function visibleLink(p, i) {
  const deadline = Date.now() + 20000
  let prev = null
  while (Date.now() < deadline) {
    const at = await p.evaluate((sel, i, n) => {
      const cards = [...document.querySelectorAll(`article.msg[data-msg-id="${sel}"]`)]
        .filter((c) => { const r = c.getBoundingClientRect(); return r.width > 0 && r.height > 0 })
      for (const card of cards) {
        /* a bare id turns into a link a moment after the card renders: count
           the n-th link only once every form's link is there */
        const links = [...card.querySelectorAll('a.msg-link')]
        if (links.length < n) continue
        const a = links[i]
        /* only the link's own feed scrolls: scrollIntoView would move the document too */
        const scroller = a.closest('.feed-body')
        if (scroller) scroller.scrollTop += a.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 80
        const r = a.getClientRects()[0]
        if (!r) continue
        const x = r.left + Math.min(r.width / 2, 20)
        const y = r.top + r.height / 2
        const hit = document.elementFromPoint(x, y)
        if (hit && a.contains(hit)) return { x, y, href: a.getAttribute('href') }
      }
      return null
    }, CARRIER, i, FORMS.length)
    /* links still reflow as they resolve: a tap on a moving link lands on its
       neighbour, so tap only where the same link sat on the last poll too */
    if (at && prev && at.href === prev.href && Math.abs(at.x - prev.x) < 1 && Math.abs(at.y - prev.y) < 1) return at
    prev = at
    await sleep(200)
  }
  return null
}

/* where the app landed: the route, the rail tab, and the highlighted target */
const landing = (p, target) => p.evaluate((id) => {
  const sel = (t) => document.querySelector(`#sidebar-tab-${t}[aria-selected="true"]`)
  const tab = ['dm', 'channels', 'flow', 'search'].find(sel) || ''
  const lit = [...document.querySelectorAll(`.msg[data-msg-id="${id}"]`)].some((el) => {
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && (el.classList.contains('open-focus') || el.classList.contains('search-focus'))
  })
  const shown = [...document.querySelectorAll(`.msg[data-msg-id="${id}"]`)].some((el) => {
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && r.top < window.innerHeight && r.bottom > 0
  })
  return { path: decodeURIComponent(location.pathname), search: decodeURIComponent(location.search), tab, lit, shown }
}, target)

function placeOk(l, form, phone) {
  const want = form.place === 'channel' ? '/channel/lobby' : `/dm/${DM_PEER}`
  const tab = form.place === 'channel' ? 'channels' : 'dm'
  return l.path === want && (phone || l.tab === tab)
}

/* poll until the place, the rail tab and the highlight all agree (or 10 s) */
async function settle(p, form, phone) {
  const start = Date.now()
  let lit = false
  let last = null
  while (Date.now() - start < 10000) {
    last = await landing(p, form.target)
    lit = lit || last.lit
    if (placeOk(last, form, phone) && lit && last.shown) return { ok: true, ...last, lit }
    await sleep(100)
  }
  return { ok: false, ...last, lit }
}

async function clickAt(p, at, phone) {
  if (phone) await p.touchscreen.tap(at.x, at.y)
  else await p.mouse.click(at.x, at.y)
}

/* the post read with the Flow tab on the left (desktop) or in its thread (phone).
   SPL-2765 (owner, 2026-10-21): a rail click closes the reply panel, so on a
   desktop Flow is picked first and the topic opened after it, in-app (the
   Flow list stays: holdFlow) */
async function fromFlow(p, base, phone) {
  const at = `${base}/channel/alerts?topic=${CARRIER_TASK}`
  await goto(p, at)
  if (!phone) {
    await p.waitForSelector('#sidebar-tab-flow', { visible: true, timeout: 15000 })
    await p.click('#sidebar-tab-flow')
    await p.waitForSelector('#sidebar-tab-flow[aria-selected="true"]', { timeout: 5000 })
    await p.evaluate(async (to) => {
      const router = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
      await router.push(to.split('?')[0])
      await router.push(to)
    }, at.slice(base.length))
    await p.waitForFunction((t) => location.search.includes(t), { timeout: 15000 }, CARRIER_TASK)
    await p.waitForSelector('#sidebar-tab-flow[aria-selected="true"]', { timeout: 5000 })
    /* the pane opening narrows the feed: a link sampled before it stops
       moving was clicked on the text beside it */
    await p.waitForFunction((id) => {
      const card = document.querySelector(`aside[data-pane=topic] article.msg[data-msg-id="${id}"]`)
      const r = card && card.getBoundingClientRect()
      const at = r && r.width > 0 ? `${r.left},${r.top},${r.width},${r.height}` : ''
      const still = at && at === window.__lovAt && performance.now() - window.__lovSince > 500
      if (at !== window.__lovAt) { window.__lovAt = at; window.__lovSince = performance.now() }
      return still
    }, { timeout: 15000, polling: 100 }, CARRIER)
  }
}

/* the post read in the Topics view (its topic page) */
async function fromTopics(p, base) {
  await goto(p, `${base}/t/${CARRIER_TASK}`)
}

const srv = await startServer()
const browser = await launch()
const only = process.env.LOV_ONLY || ''
try {
  /* SPL-2150: the deep-linked topic lands, then the window is resized */
  for (const c of [
    { name: '1440x900 -> 1440x600', from: { width: 1440, height: 900 }, to: { width: 1440, height: 600 } },
    { name: '1440x600 -> 1440x900', from: { width: 1440, height: 600 }, to: { width: 1440, height: 900 } },
    { name: '390 portrait -> landscape', from: { width: 390, height: 844, isMobile: true, hasTouch: true }, to: { width: 844, height: 390, isMobile: true, hasTouch: true, isLandscape: true } },
    { name: '390 landscape -> portrait', from: { width: 844, height: 390, isMobile: true, hasTouch: true, isLandscape: true }, to: { width: 390, height: 844, isMobile: true, hasTouch: true } },
  ]) {
    const name = `resize ${c.name}: the deep-linked topic stays at the top of the pane`
    if (only && !name.includes(only)) continue
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport(c.from)
    await p.evaluateOnNewDocument((rows) => {
      try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
    }, landRows())
    await goto(p, `${srv.base}/channel/lobby?topic=${LAND_TASK}`)
    const before = await settledGap(p)
    await p.setViewport(c.to)
    const after = await settledGap(p)
    ok(name, landedAt(before) && landedAt(after), { before, after })
    await p.close()
  }

  for (const vp of [
    { name: '1440px', phone: false, size: { width: 1440, height: 900 } },
    { name: '390px', phone: true, size: { width: 390, height: 844, isMobile: true, hasTouch: true } },
  ]) {
    const p = await newPage(browser, vp, srv.base)
    for (const [ctx, open] of [['Flow', fromFlow], ['Topics', fromTopics]]) {
      for (const [i, form] of FORMS.entries()) {
        const name = `${vp.name} link in a post read from ${ctx}: ${form.label}`
        if (only && !name.includes(only)) continue
        await open(p, srv.base, vp.phone)
        const at = await visibleLink(p, i)
        if (!at) {
          ok(`${name}: the link is rendered and on top`, false)
          continue
        }
        await clickAt(p, at, vp.phone)
        const l = await settle(p, form, vp.phone)
        ok(`${name} -> ${form.place === 'dm' ? 'private messages' : 'channel'} view, target highlighted`, l.ok, { href: at.href, ...l })
      }
    }

    for (const form of [FORMS[1], FORMS[7]]) {
      const name = `${vp.name} notification tap: ${form.place === 'dm' ? 'DM' : 'channel'} reply`
      if (only && !name.includes(only)) continue
      await fromFlow(p, srv.base, vp.phone)
      await p.evaluate((url) => {
        const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
        pinia._s.get('notification').openTarget({ url })
      }, `/m/${form.target}`)
      const l = await settle(p, form, vp.phone)
      ok(`${name} -> ${form.place === 'dm' ? 'private messages' : 'channel'} view, target highlighted`, l.ok, l)
    }

    for (const form of [FORMS[1], FORMS[7]]) {
      const name = `${vp.name} cold /m/<id>: ${form.place === 'dm' ? 'DM' : 'channel'} reply`
      if (only && !name.includes(only)) continue
      await goto(p, `${srv.base}/m/${form.target}`)
      const l = await settle(p, form, vp.phone)
      ok(`${name} -> ${form.place === 'dm' ? 'private messages' : 'channel'} view, target highlighted`, l.ok, l)
    }

    for (const [form, q] of [[FORMS[1], SEARCH_WORD], [FORMS[7], 'Mock DM reply']]) {
      const name = `${vp.name} search result: ${form.place === 'dm' ? 'DM' : 'channel'} reply`
      if (only && !name.includes(only)) continue
      await goto(p, `${srv.base}/search?q=${encodeURIComponent(q)}`)
      const hit = await p.waitForFunction((id) => {
        const rows = [...document.querySelectorAll('[data-test="search-row"]')]
        const row = rows.find((r) => (r.getAttribute('data-key') || '').includes(id) || r.innerHTML.includes(id)) || rows[0]
        if (!row) return null
        const b = row.getBoundingClientRect()
        /* the row's right side: the left holds the author's name, which opens the person */
        return b.width > 0 && b.height > 0 ? { x: b.left + b.width * 0.75, y: b.top + b.height / 2 } : null
      }, { timeout: 20000 }, form.target).then((h) => h.jsonValue(), () => null)
      if (!hit) {
        ok(`${name}: a result row is shown`, false)
        continue
      }
      await clickAt(p, hit, vp.phone)
      /* the search list stays on the left by design (CLE-77884): only the place and the mark are asked */
      const l = await settle(p, form, true)
      ok(`${name} -> ${form.place === 'dm' ? 'private messages' : 'channel'} view, target highlighted`, l.ok, l)
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nlinks-open-channel-view: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
