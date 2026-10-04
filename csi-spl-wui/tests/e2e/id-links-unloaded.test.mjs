// HUM-10 (topic cd357c76, owner msg 61ecdc55): "the links conversion should
// work in the direct msgs too". A direct message quotes a topic id and a
// reply id from a channel this tab never opened: no store holds those rows,
// so only the hub lookup (POST /v1/view/ids; the mock client answers it from
// every mock row) can turn them into links. Each link carries its kind word
// and opens the channel with that card (or that reply in the right pane).
// The unknown uuid in the same body is the control: it stays text.
//
// The extra rows ride the e2e hook localStorage `spool.mock.extra-messages`.
//
// Run: node tests/e2e/id-links-unloaded.test.mjs
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
const FAR_TOPIC = 'fa000000-0000-4000-8000-00000000000a'
const FAR_CARD = 'fa100000-0000-4000-8000-00000000000a'
const FAR_REPLY = 'fa200000-0000-4000-8000-00000000000b'
const DM_TASK = 'fd000000-0000-4000-8000-00000000000d'
const UNKNOWN = '00000000-0000-4000-8000-000000000099'
const BODY = `the fix is in topic ${FAR_TOPIC}\nand the proof is reply ${FAR_REPLY}\nnot an id ${UNKNOWN}`

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const base = { v: 1, files: [], kind: 'note', is_parent: 1, parent_task_id: null }
const extra = [
  { ...base, msg_id: FAR_CARD, task_id: FAR_TOPIC, channel: 'feedback', from: 'HUM-2', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: 'a topic in a channel this tab never opens', ts: '2026-09-10T08:00:00Z' },
  { ...base, msg_id: FAR_REPLY, task_id: 'fa300000-0000-4000-8000-00000000000c', parent_task_id: FAR_TOPIC, is_parent: 0, channel: 'feedback', from: 'HUM-2', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: 'a reply there', ts: '2026-09-10T08:01:00Z' },
  { ...base, msg_id: 'fd100000-0000-4000-8000-00000000000d', task_id: DM_TASK, channel: null, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body: BODY, ts: '2026-12-31T23:59:00Z' },
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

async function openDm(p, srvBase) {
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.evaluateOnNewDocument((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, extra)
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(`${srvBase}/dm/${encodeURIComponent(PEER)}?topic=${DM_TASK}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) throw new Error('no shell ' + JSON.stringify({ url: p.url(), errors: errors.slice(0, 4) }))
  return errors
}

/* The page's view of the two far ids: their links, their kind words, and
   whether any store holds their rows (it must not: the hub answered them). */
const look = (p) => p.evaluate((ids) => {
  const links = [...document.querySelectorAll('a.msg-link')].map((a) => {
    /* the text right before the link: its kind word ("Topic: ") */
    const block = a.closest('p, li, div') || a.parentElement
    const r = document.createRange()
    r.setStart(block, 0)
    r.setEndBefore(a)
    return { text: a.textContent || '', href: a.getAttribute('href') || '', before: r.toString().slice(-24) }
  })
  let held = null
  try {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const all = JSON.stringify(pinia.state.value)
    held = { topicCard: all.includes(ids.card), reply: all.includes(ids.reply) }
  } catch { held = 'unreadable' }
  const topic = links.find((l) => l.text === ids.topic)
  const reply = links.find((l) => l.text === ids.reply)
  return { topic, reply, unknown: links.some((l) => l.text.includes(ids.unknown)), held, path: location.pathname }
}, { topic: FAR_TOPIC, reply: FAR_REPLY, card: FAR_CARD, unknown: UNKNOWN })

async function waitFor(p, pred, ms = 15000) {
  const start = Date.now()
  let last
  while (Date.now() - start < ms) {
    /* the DM route may still settle its address: a navigation drops the context */
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
    await openDm(p, srv.base)
    const s = await waitFor(p, (x) => x && x.topic && x.reply)
    ok(`${label} no store holds the far channel's rows`, s && s.held && s.held.topicCard === false, s && s.held)
    ok(`${label} the far topic id is a labelled link to its channel, card selected`,
      !!(s && s.topic && s.topic.href.includes('/channel/feedback') && s.topic.href.includes('topic=' + FAR_TOPIC) && /:\s*$/.test(s.topic.before)), s && s.topic)
    ok(`${label} the far reply id is a labelled link to its thread, reply in the right pane`,
      !!(s && s.reply && s.reply.href.includes('/channel/feedback') && s.reply.href.includes('topic=' + FAR_TOPIC) && s.reply.href.endsWith('#' + FAR_REPLY) && /:\s*$/.test(s.reply.before)), s && s.reply)
    ok(`${label} CONTROL: the unknown id stays text`, s && !s.unknown, s)
    if (SHOT_DIR) {
      mkdirSync(SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(SHOT_DIR, `id-links-unloaded-${label}.png`) })
    }
    if (label === '1440px') {
      await p.click(`a.msg-link[href*="topic=${FAR_TOPIC}"]:not([href*="#"])`)
      const start = Date.now()
      let path = ''
      while (Date.now() - start < 10000) {
        path = await p.evaluate(() => location.pathname + location.search)
        if (path.includes('/channel/feedback') && path.includes('topic=' + FAR_TOPIC)) break
        await sleep(150)
      }
      ok('1440px a click opens the far channel with that topic', path.includes('/channel/feedback') && path.includes('topic=' + FAR_TOPIC), { path })
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nid-links-unloaded: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
