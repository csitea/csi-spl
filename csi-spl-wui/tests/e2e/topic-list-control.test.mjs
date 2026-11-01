// Spec 150 row B6 (owner HUM-10, t1 0344254d, msgs 0c33bce8 + f2bb53c9:
// "on the same row as the channel name we should have a small forw with
// more icons", "there should be the filter for new and all topics ... sort
// by time of last update, sort by amount of msgs ... sort by prio").
//
// The topic list's filter and sort control on the middle pane's header:
//   C101 the channel header holds it, just before the card-clip control
//   C102 the DM and lobby headers hold it too
//   C103 keyboard: opening lands on the filter's radio group, the arrows
//        move, Escape closes back to the button
//   C207 the "N topics loaded" line shows under a sort and under New only
//        while an older page exists
//   C209 the filter and the sort survive a reload in the same browser
// (C104, the initial chunk budget, is `python3 perf-budget.py` /
// `do_spl_perf_budget`, not a browser case.)
//
// Run:
//   pnpm run test:e2e topic-list-control
//   BASE_URL=<generated bundle> pnpm run test:e2e topic-list-control   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = '/channel/alerts'
const DM = '/dm/' + encodeURIComponent('CLE-11@box-desk')
const LOBBY = '/lobby'
/* the channel store draws 30 topics a window (stores/channel.ts WINDOW): more makes an older page */
const SEED_TOPICS = 35

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function goto(p, path) {
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=feed-header]', { timeout: NAV_TIMEOUT })
  /* the control is lazy: give its chunk a moment, then read what is there */
  await p.waitForSelector('[data-test=feed-header] [data-testid=topic-list-control]', { timeout: 10000 }).catch(() => {})
}

/* where the control sits in the header: in it, and before the card-clip control */
function placement() {
  const head = document.querySelector('[data-test=feed-header]')
  const ctl = head?.querySelector('[data-testid=topic-list-control]')
  const clip = head?.querySelector('[data-testid=card-clip-control]')
  return {
    inHeader: Boolean(ctl),
    beforeClip: Boolean(ctl && clip && (ctl.compareDocumentPosition(clip) & Node.DOCUMENT_POSITION_FOLLOWING)),
    buttons: ctl ? ctl.querySelectorAll('button[aria-haspopup]').length : 0,
  }
}

/* C101, C102 */
async function headerCase(p, path, tag) {
  await goto(p, path)
  const at = await p.evaluate(placement)
  ok(`${tag}: the topic-list control is in the feed header, before the card-clip control, two buttons`, at.inHeader && at.beforeClip && at.buttons === 2, at)
}

/* the focused element, its radio group and the control's state */
function focusNow() {
  const a = document.activeElement
  const group = a?.closest('[role=radiogroup]')
  const ctl = document.querySelector('[data-testid=topic-list-control]')
  return {
    tag: a?.tagName || '',
    type: a?.getAttribute('type') || '',
    value: a?.getAttribute('value') || '',
    testid: a?.getAttribute('data-testid') || '',
    group: group?.getAttribute('data-testid') || '',
    open: Boolean(document.querySelector('[data-testid=topic-list-filter-group]')),
    filter: ctl?.getAttribute('data-filter') || '',
  }
}

/* C103 */
async function keyboardCase(p) {
  await goto(p, CHANNEL)
  await p.focus('[data-testid=topic-list-filter]')
  await p.keyboard.press('Enter')
  await sleep(150)
  const opened = await p.evaluate(focusNow)
  ok('keyboard: Enter on Filter lands on the checked radio of its radio group', opened.open && opened.type === 'radio' && opened.value === 'all' && opened.group === 'topic-list-filter-group', opened)
  await p.keyboard.press('ArrowDown')
  await sleep(150)
  const moved = await p.evaluate(focusNow)
  ok('keyboard: an arrow moves to New and applies it', moved.value === 'new' && moved.group === 'topic-list-filter-group' && moved.filter === 'new', moved)
  await p.keyboard.press('Escape')
  await sleep(150)
  const closed = await p.evaluate(focusNow)
  ok('keyboard: Escape closes the popover back to the Filter button', !closed.open && closed.testid === 'topic-list-filter', closed)
  /* put the default back for the next case */
  await choose(p, 'filter', 'all')
}

async function choose(p, group, value) {
  const open = await p.$(`[data-testid=topic-list-${group}-group]`)
  if (!open) await p.click(`[data-testid=topic-list-${group}]`)
  await p.waitForSelector(`[data-testid=topic-list-${group}-${value}]`, { timeout: 5000 })
  await p.click(`[data-testid=topic-list-${group}-${value}]`)
  await p.keyboard.press('Escape')
  await sleep(150)
}

/* SEED_TOPICS topic cards in the open channel, kept over a reload (the mock's extra messages) */
function seedTopics(n) {
  return n && (() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const at = Date.now() - 86400000
    const rows = Array.from({ length: n }, (_, i) => ({ v: 1, msg_id: crypto.randomUUID(), task_id: crypto.randomUUID(), ts: new Date(at - i * 60000).toISOString(), from: 'CLE-07', to: '@channel', kind: 'note', body: `seed topic ${i}`, files: [], channel: channel.active || 'alerts', parent_task_id: null, is_parent: 1 }))
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, ...rows]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, ...rows]
    return channel.messages.length
  })()
}

function windowLine() {
  const el = document.querySelector('[data-testid=topic-list-window]')
  const channel = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  return { shown: Boolean(el), text: el?.textContent?.trim() || '', hasOlder: Boolean(channel.hasOlder), topics: channel.newestFirst.length }
}

/* C207 */
async function windowCase(p) {
  await goto(p, CHANNEL)
  const before = await p.evaluate(windowLine)
  await choose(p, 'sort', 'messages')
  const fewSorted = await p.evaluate(windowLine)
  ok('loaded-topics line: hidden under a sort while no older page exists', !before.hasOlder && !fewSorted.shown, { before, fewSorted })
  await choose(p, 'sort', 'last')
  await p.evaluate(seedTopics, SEED_TOPICS)
  await sleep(300)
  const plain = await p.evaluate(windowLine)
  ok('loaded-topics line: hidden under All + Last update with an older page', plain.hasOlder && !plain.shown, plain)
  await choose(p, 'sort', 'messages')
  const sorted = await p.evaluate(windowLine)
  ok('loaded-topics line: shown under a sort with an older page, naming the topics loaded', sorted.shown && sorted.text.includes(String(sorted.topics)) && !sorted.text.includes('feed.topic_list'), sorted)
  await choose(p, 'sort', 'last')
  await choose(p, 'filter', 'new')
  const fresh = await p.evaluate(windowLine)
  ok('loaded-topics line: shown under New with an older page, its own words', fresh.shown && fresh.text.includes(String(fresh.topics)) && fresh.text !== sorted.text, fresh)
  await choose(p, 'filter', 'all')
  const back = await p.evaluate(windowLine)
  ok('loaded-topics line: gone again under the defaults', !back.shown, back)
}

function choiceNow() {
  const ctl = document.querySelector('[data-testid=topic-list-control]')
  return {
    filter: ctl?.getAttribute('data-filter') || '',
    sort: ctl?.getAttribute('data-sort') || '',
    dots: document.querySelectorAll('[data-testid$=-dot]').length,
  }
}

/* C209 */
async function reloadCase(p) {
  await goto(p, CHANNEL)
  await choose(p, 'filter', 'new')
  await choose(p, 'sort', 'priority')
  const set = await p.evaluate(choiceNow)
  await goto(p, CHANNEL)
  await sleep(300)
  const after = await p.evaluate(choiceNow)
  ok('the filter and the sort survive a reload, both icons dotted', set.filter === 'new' && set.sort === 'priority' && after.filter === 'new' && after.sort === 'priority' && after.dots === 2, { set, after })
  await choose(p, 'filter', 'all')
  await choose(p, 'sort', 'last')
  const reset = await p.evaluate(choiceNow)
  ok('the defaults carry no dot', reset.filter === 'all' && reset.sort === 'last' && reset.dots === 0, reset)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await headerCase(p, CHANNEL, 'channel')
  await headerCase(p, DM, 'dm')
  await headerCase(p, LOBBY, 'lobby')
  await keyboardCase(p)
  await windowCase(p)
  await reloadCase(p)
  ok('no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
