// A URL of this app in a message renders as a short label, keeps the full
// URL as the href and the title, and still gets the link-preview card.
// An external URL and an unknown route stay the address.
// t1 9dec05c3: a calendar event link (Copy link) is a chip, `event: <title>
// · <day>`, that opens the event; an event the reader's calendar does not
// return reads `event: <day>`, never a title.
//
// Run: node tests/e2e/internal-link-labels.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { calIsoDay, calAddDays } from '../../src/utils/calendar-year.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PEER = 'CLE-07@box-a'
const TOPIC = '41261a3f-db05-4e2f-9af4-fceb716a557a'
const MSG = 'ab12cd34-db05-4e2f-9af4-fceb716a557a'
const DM_TASK = 'fe510000-0000-4000-8000-0000000000a1'
const TITLE = 'Release plan for the internal link'
/* the mock workspace's seeded c-007 event sits two days on (calendar-mock.mjs) */
const EVENT = '00000000-0000-4000-8000-000000000102'
const EVENT_TITLE = 'Database maintenance'
const EVENT_DAY = calAddDays(calIsoDay(Date.now()), 2)
const UNSEEN = '0badbeef-0000-4000-8000-000000000999'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function rows(base) {
  const topicUrl = `${base}/channel/feedback?topic=${TOPIC}`
  const msgUrl = `${base}/m/${MSG}`
  const channelUrl = `${base}/channel/feedback`
  const unknownUrl = `${base}/settings/appearance`
  const eventUrl = `${base}/calendar?d=${EVENT_DAY}&event=${EVENT}`
  const unseenUrl = `${base}/calendar?d=${EVENT_DAY}&event=${UNSEEN}`
  const plain = [topicUrl, msgUrl, channelUrl, 'https://example.com/nothing', unknownUrl, eventUrl, unseenUrl].join('\n')
  const md = `## note\n${topicUrl}`
  const baseRow = { v: 1, files: [], kind: 'note', is_parent: 1, parent_task_id: null }
  return [
    { ...baseRow, msg_id: 'fe520000-0000-4000-8000-0000000000a1', task_id: TOPIC, channel: 'feedback', from: 'HUM-2', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: `${TITLE}\nstep one\nstep two`, ts: '2026-09-10T08:00:00Z' },
    { ...baseRow, msg_id: MSG, task_id: 'fe530000-0000-4000-8000-0000000000a1', parent_task_id: TOPIC, is_parent: 0, channel: 'feedback', from: 'HUM-3', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: 'the message the link names', ts: '2026-09-10T08:01:00Z' },
    { ...baseRow, msg_id: 'fe540000-0000-4000-8000-0000000000a1', task_id: DM_TASK, channel: null, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body: plain, ts: '2026-12-31T23:59:00Z' },
    { ...baseRow, msg_id: 'fe550000-0000-4000-8000-0000000000a1', task_id: 'fe560000-0000-4000-8000-0000000000a1', parent_task_id: DM_TASK, is_parent: 0, channel: null, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body: md, ts: '2026-12-31T23:59:30Z' },
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

const look = (p) => p.evaluate((topic) => {
  const links = [...document.querySelectorAll('a.msg-link')].map((a) => ({
    text: (a.textContent || '').trim(),
    href: a.getAttribute('href') || '',
    title: a.getAttribute('title') || '',
    test: a.getAttribute('data-test') || '',
    target: a.getAttribute('target') || '',
    kind: a.getAttribute('data-kind') || '',
  }))
  const md = document.querySelector('[data-testid=md-block][data-rendered=true]')
  const mdTopic = !!(md && [...md.querySelectorAll('a.msg-link')].some((a) => (a.textContent || '').trim() === 'topic: ' + topic.slice(0, 8)))
  const card = document.querySelector(`[data-test=link-preview][data-id="${topic}"]`)
  return {
    links,
    mdTopic,
    card: card ? { kind: card.getAttribute('data-kind') || '', title: card.querySelector('[data-test=link-preview-title]')?.textContent || '' } : null,
  }
}, TOPIC)

async function waitFor(p, pred, ms = 20000) {
  const start = Date.now()
  let last = null
  while (Date.now() - start < ms) {
    last = await look(p).catch(() => null)
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
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
    await p.evaluateOnNewDocument((extra) => {
      try {
        localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
        localStorage.setItem('spool.mock.session', JSON.stringify({
          hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
        }))
      } catch { /* private mode */ }
    }, rows(srv.base))
    let shell = false
    for (let attempt = 0; attempt < 2 && !shell; attempt++) {
      await p.goto(`${srv.base}/dm/${encodeURIComponent(PEER)}?topic=${DM_TASK}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : 120000 }).then(() => true, () => false)
    }
    ok(`${label} the shell is up`, shell, errors.slice(0, 3))
    if (!shell) { await p.close(); continue }
    const topicLabel = 'topic: ' + TOPIC.slice(0, 8)
    const s = await waitFor(p, (x) => x.links.some((a) => a.text === topicLabel && a.test === 'app-link') && x.card && x.mdTopic, 45000)
    const topic = s && s.links.find((a) => a.text === topicLabel)
    const message = s && s.links.find((a) => a.text === 'message: ' + MSG.slice(0, 8))
    const channel = s && s.links.find((a) => a.text === 'channel: feedback')
    const external = s && s.links.find((a) => a.text === 'https://example.com/nothing')
    const unknown = s && s.links.find((a) => a.text.includes('/settings/appearance'))
    if (!(topic && topic.test === 'app-link')) console.log('  SNAP', label, JSON.stringify(s && { n: s.links.length, links: s.links.slice(0, 8), card: s.card, mdTopic: s.mdTopic }))
    ok(`${label} a same-workspace topic URL reads topic: <8 hex>`, !!(topic && topic.test === 'app-link'), topic)
    ok(`${label} the topic link keeps the full URL as href and title`, !!(topic && topic.href.includes(TOPIC) && topic.title === topic.href), topic)
    ok(`${label} a message URL reads message: <8 hex>`, !!message, message)
    ok(`${label} a channel URL reads channel: <name>`, !!channel, channel)
    ok(`${label} an external URL stays the address`, !!(external && external.test !== 'app-link' && external.target === '_blank'), external)
    ok(`${label} an unknown route stays the address`, !!(unknown && unknown.test !== 'app-link' && unknown.text.startsWith('http')), unknown)
    ok(`${label} the topic still has its preview card`, !!(s && s.card && s.card.kind === 'topic' && s.card.title === TITLE), s && s.card)
    ok(`${label} a markdown body shortens the same URL`, !!(s && s.mdTopic), s && s.mdTopic)
    const chipText = `event: ${EVENT_TITLE} \u00b7 ${EVENT_DAY}`
    const e = await waitFor(p, (x) => x.links.some((a) => a.text === chipText), 20000)
    const chip = e && e.links.find((a) => a.text === chipText)
    const unseen = e && e.links.find((a) => a.kind === 'event' && a.href.includes(UNSEEN))
    ok(`${label} an event link is a chip with its title and day`, !!(chip && chip.kind === 'event' && chip.href.includes(EVENT)), e && e.links.filter((a) => a.href.includes('/calendar')))
    ok(`${label} an event the reader's calendar lacks shows its day, never a title`, !!(unseen && unseen.text === `event: ${EVENT_DAY}`), unseen)
    if (label === '1440px' && chip) {
      await p.evaluate((want) => {
        const a = [...document.querySelectorAll('a[data-kind=event]')].find((el) => (el.textContent || '').trim() === want)
        if (a) a.setAttribute('data-pick-ev', '1')
      }, chipText)
      await p.click('[data-pick-ev="1"]')
      const opened = await p.waitForFunction((t) => document.querySelector('[data-test=calendar-event-title]')?.value === t, { timeout: 15000 }, EVENT_TITLE).then(() => true, () => false)
      ok('1440px clicking the chip opens the event', opened, await p.evaluate(() => location.pathname + location.search))
      await p.goBack({ waitUntil: 'domcontentloaded' }).catch(() => {})
      await waitFor(p, (x) => x.links.some((a) => a.text === 'topic: ' + TOPIC.slice(0, 8)), 20000)
    }
    if (label === '1440px' && topic) {
      await p.evaluate((want) => {
        const a = [...document.querySelectorAll('[data-test=app-link]')].find((el) => (el.textContent || '').trim() === want)
        if (a) a.setAttribute('data-pick', '1')
      }, topicLabel)
      await p.click('[data-pick="1"]')
      const start = Date.now()
      let path = ''
      while (Date.now() - start < 10000) {
        path = await p.evaluate(() => location.pathname + location.search)
        if (path.includes('/channel/feedback') && path.includes(TOPIC)) break
        await sleep(150)
      }
      ok('1440px clicking the label opens the topic in this tab', path.includes('/channel/feedback') && path.includes(TOPIC), { path })
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ninternal-link-labels: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log('FAILED:', failed.map((f) => f.name).join('; '))
  process.exit(1)
}
