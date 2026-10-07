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

async function goto(p, url) {
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) throw new Error('no shell at ' + url)
  /* a generated bundle reloads once while the shell settles (id-links.test.mjs) */
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
  while (Date.now() < deadline) {
    const at = await p.evaluate((sel, i) => {
      const cards = [...document.querySelectorAll(`article.msg[data-msg-id="${sel}"]`)]
        .filter((c) => { const r = c.getBoundingClientRect(); return r.width > 0 && r.height > 0 })
      for (const card of cards) {
        const links = [...card.querySelectorAll('a.msg-link')]
        if (links.length <= i) continue
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
    }, CARRIER, i)
    if (at) return at
    await sleep(200)
  }
  return null
}

/* where the app landed: the route, the rail tab, and the highlighted target */
const landing = (p, target) => p.evaluate((id) => {
  const sel = (t) => document.querySelector(`#sidebar-tab-${t}[aria-selected="true"]`)
  const tab = ['dm', 'channels', 'topics', 'flow', 'search'].find(sel) || ''
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

/* the post read with the Flow tab on the left (desktop) or in its thread (phone) */
async function fromFlow(p, base, phone) {
  await goto(p, `${base}/channel/alerts?topic=${CARRIER_TASK}`)
  if (!phone) {
    await p.waitForSelector('#sidebar-tab-flow', { visible: true, timeout: 15000 })
    await p.click('#sidebar-tab-flow')
    await p.waitForSelector('#sidebar-tab-flow[aria-selected="true"]', { timeout: 5000 })
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
