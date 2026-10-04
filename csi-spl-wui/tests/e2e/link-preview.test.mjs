// Topic e1f8f797 (owner): "each internal link to an object ... topic, msg
// etc. if the user has a setting for it - it should present as small slack
// like 3 lines excerpt of what it was all about .. the first 100 chars of
// the title", and "the users should be able to turn this off, from their
// individual settings".
//
// A direct message links a topic and a reply of a channel this tab never
// opened (the mock client answers POST /v1/view/previews from every mock
// row, as the hub answers a reader who may read them). With the person's
// link_previews setting on (never picked = on) each link gets a card under
// the message: kind, title, excerpt lines, author; a click opens the link.
// The link to an unknown topic is the control: it stays a plain link, no
// card. With the setting off there is no card and the links stay.
//
// The extra rows ride the e2e hook localStorage `spool.mock.extra-messages`;
// the signed-in person (and their setting) `spool.mock.session`.
//
// Run: node tests/e2e/link-preview.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const PEER = 'CLE-07@box-a'
const FAR_TOPIC = 'fb000000-0000-4000-8000-00000000000a'
const FAR_CARD = 'fb100000-0000-4000-8000-00000000000a'
const FAR_REPLY = 'fb200000-0000-4000-8000-00000000000b'
const DM_TASK = 'fe000000-0000-4000-8000-00000000000d'
const UNKNOWN = '00000000-0000-4000-8000-000000000098'
const TITLE = 'Release plan for the link previews'
const BODY = `the plan is [here](/t/${FAR_TOPIC})\nthe proof is /t/${FAR_TOPIC}#${FAR_REPLY} -> [reply](/t/${FAR_TOPIC}#${FAR_REPLY})\nnothing at [this one](/t/${UNKNOWN})`

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const base = { v: 1, files: [], kind: 'note', is_parent: 1, parent_task_id: null }
const extra = [
  { ...base, msg_id: FAR_CARD, task_id: FAR_TOPIC, channel: 'feedback', from: 'HUM-2', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: `${TITLE}\nstep one: the hub\nstep two: the cards\nstep three: the switch\nstep four: never shown`, ts: '2026-09-10T08:00:00Z' },
  { ...base, msg_id: FAR_REPLY, task_id: 'fb300000-0000-4000-8000-00000000000c', parent_task_id: FAR_TOPIC, is_parent: 0, channel: 'feedback', from: 'HUM-3', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: 'the reply that proves it', ts: '2026-09-10T08:01:00Z' },
  { ...base, msg_id: 'fe100000-0000-4000-8000-00000000000d', task_id: DM_TASK, channel: null, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body: BODY, ts: '2026-12-31T23:59:00Z' },
]

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

async function openDm(p, srvBase, linkPreviews) {
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.evaluateOnNewDocument((rows, lp) => {
    try {
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
      localStorage.setItem('spool.mock.session', JSON.stringify({
        hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', link_previews: lp,
      }))
    } catch { /* private mode */ }
  }, extra, linkPreviews)
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(`${srvBase}/dm/${encodeURIComponent(PEER)}?topic=${DM_TASK}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) throw new Error('no shell ' + JSON.stringify({ url: p.url(), errors: errors.slice(0, 4) }))
  return errors
}

/* the DM line's links and the cards under it */
const look = (p) => p.evaluate((ids) => {
  /* the body's own anchors (plain or markdown-rendered), never a card */
  const links = [...document.querySelectorAll('a[href]:not([data-test=link-preview])')].map((a) => a.getAttribute('href') || '')
  const cards = [...document.querySelectorAll('[data-test=link-preview]')].map((c) => ({
    id: c.getAttribute('data-id'),
    kind: c.getAttribute('data-kind'),
    href: c.getAttribute('href') || '',
    title: c.querySelector('[data-test=link-preview-title]')?.textContent || '',
    excerpt: c.querySelector('[data-test=link-preview-excerpt]')?.textContent || '',
    text: c.textContent || '',
    /* on screen and not under a clip: the point in its title row hits the card */
    seen: (() => {
      c.scrollIntoView({ block: 'center' })
      const t = c.querySelector('[data-test=link-preview-title]') || c
      const r = t.getBoundingClientRect()
      const el = r.width > 0 ? document.elementFromPoint(r.left + Math.min(8, r.width / 2), r.top + r.height / 2) : null
      return !!el && c.contains(el)
    })(),
    excerptLines: (() => {
      const e = c.querySelector('[data-test=link-preview-excerpt]')
      if (!e) return 0
      const lh = parseFloat(getComputedStyle(e).lineHeight) || 16
      return Math.round(e.getBoundingClientRect().height / lh)
    })(),
  }))
  return {
    topicLink: links.some((h) => h.endsWith('/t/' + ids.topic)),
    unknownLink: links.some((h) => h.endsWith('/t/' + ids.unknown)),
    cards,
  }
}, { topic: FAR_TOPIC, unknown: UNKNOWN })

async function waitFor(p, pred, ms = 15000) {
  const start = Date.now()
  let last
  while (Date.now() - start < ms) {
    last = await look(p).catch(() => last)
    if (last && pred(last)) return last
    await sleep(200)
  }
  return last
}

const srv = await startServer()
const browser = await launch()
try {
  for (const [label, vp] of [['1440px', { width: 1440, height: 900 }], ['390px', { width: 390, height: 844, isMobile: true, hasTouch: true }]]) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport(vp)
    await openDm(p, srv.base, null)
    const s = await waitFor(p, (x) => x && x.cards.length >= 2 && x.topicLink && x.unknownLink)
    /* a phone shows one pane: the topic card of the pane on screen */
    const topic = s && (s.cards.find((c) => c.id === FAR_TOPIC && c.seen) || s.cards.find((c) => c.id === FAR_TOPIC))
    const reply = s && s.cards.find((c) => c.id === FAR_REPLY)
    ok(`${label} setting never picked: the linked topic shows a card with its title`, !!(topic && topic.kind === 'topic' && topic.title === TITLE), s && s.cards)
    ok(`${label} the topic card's excerpt is its next three lines, never the fourth`,
      !!(topic && topic.excerpt === 'step one: the hub\nstep two: the cards\nstep three: the switch' && !topic.text.includes('never shown') && topic.excerptLines <= 3), topic)
    ok(`${label} the topic card is visible: the 5-row card clip does not cut it`, !!(topic && topic.seen), topic)
    ok(`${label} the card names who wrote it`, !!(topic && /HUM-2|FirstName|LastName/.test(topic.text)), topic && topic.text)
    ok(`${label} the linked reply shows a message card: its topic's title over its own line`,
      !!(reply && reply.kind === 'message' && reply.title === TITLE && reply.excerpt === 'the reply that proves it'), reply)
    ok(`${label} CONTROL: the unknown topic's link stays a plain link, no card`, !!(s && s.unknownLink && !s.cards.some((c) => c.id === UNKNOWN)), s)
    if (SHOT_DIR) {
      mkdirSync(SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(SHOT_DIR, `link-preview-${label}.png`) })
    }
    if (label === '1440px' && topic) {
      await p.click(`[data-test=link-preview][data-id="${FAR_TOPIC}"]`)
      const start = Date.now()
      let path = ''
      while (Date.now() - start < 10000) {
        path = await p.evaluate(() => location.pathname + location.search)
        if (!path.startsWith('/dm/')) break
        await sleep(150)
      }
      ok('1440px a click on the card opens the linked topic', path.includes(FAR_TOPIC) || path.includes('/channel/feedback'), { path })
    }
    await p.close()

    const q = await browser.newPage()
    q.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await q.setViewport(vp)
    await openDm(q, srv.base, 'off')
    const off = await waitFor(q, (x) => x && x.topicLink, 15000)
    await sleep(2500)
    const after = await look(q).catch(() => off)
    ok(`${label} setting off: the links stay links and no card is shown`, !!(after && after.topicLink && after.cards.length === 0), after)
    await q.close()
  }

  /* the switch: Settings -> Behaviour, the person's own box, sends only
     {"link_previews": "off"} and flips back on */
  const s = await browser.newPage()
  s.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await s.setViewport({ width: 1440, height: 900 })
  await s.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', link_previews: null }))
    } catch { /* private mode */ }
  })
  const puts = []
  const cors = { 'access-control-allow-origin': new URL(srv.base).origin, 'access-control-allow-credentials': 'true' }
  await s.setRequestInterception(true)
  s.on('request', (req) => {
    if (req.method() === 'PUT' && req.url().includes('/api/v1/auth/preferences')) {
      const body = JSON.parse(req.postData() || '{}')
      puts.push(body)
      return req.respond({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(body) })
    }
    return req.continue()
  })
  await s.goto(`${srv.base}/settings/behaviour`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  const box = await s.waitForSelector('[data-testid=settings-link-previews]', { timeout: NAV_TIMEOUT }).catch(() => null)
  ok('Settings -> Behaviour shows the Link previews box, on when never picked', !!box && await s.$eval('[data-testid=settings-link-previews]', (el) => el.checked), { box: !!box })
  if (box) {
    await box.click()
    const start = Date.now()
    while (Date.now() - start < 5000 && !puts.length) await sleep(100)
    ok('one click sends {"link_previews":"off"} alone, and the box unticks',
      puts.some((b) => b.link_previews === 'off' && Object.keys(b).length === 1) && !(await s.$eval('[data-testid=settings-link-previews]', (el) => el.checked)), puts)
  }
  await s.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nlink-preview: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log('FAILED:', failed.map((f) => f.name).join('; '))
  process.exit(1)
}
