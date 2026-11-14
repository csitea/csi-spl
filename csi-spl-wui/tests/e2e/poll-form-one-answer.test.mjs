// SPL-5517 (csitea 48d75e5f item 3): a multi-question poll form sends ONE
// answer when it locks, not one post per click. Poll 05640e4b, a radio form
// of 7 questions, took 8 answer posts in about 72 s on 2026-11-09, each one
// re-read and re-relayed by the dispatcher.
//
// In Chrome, on the mock tenant, a form is seeded into the feed:
//   1. a radio form of 3 questions, each answered with one click: no answer
//      is posted before the last question; the third click posts exactly ONE
//      answer, holding all three (red on master before SPL-5517: 3 posts)
//   2. the same form, one question answered, then its Send: one answer
//   3. control: a one-question radio form still posts on the click, and
//      has no Send
//
// Run:
//   pnpm run test:e2e poll-form-one-answer
//   BASE_URL=<generated bundle> pnpm run test:e2e poll-form-one-answer   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PATH = '/channel/alerts'
/* longer than the hold an answer takes to land in the mock store */
const SETTLE_MS = 1500

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

const radio = (n) => Array.from({ length: n }, (_, i) => `Question ${i + 1}: which way?\n(A) The first way\n(B) The second way`).join('\n')
const POLL = (n) => `${n} question(s)\n\n\`\`\`poll\n${radio(n)}\n\`\`\``

async function open(browser) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    const session = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  })
  return { p, errors }
}

/* the form as a topic root in the feed; -> the form's selector and its id */
async function seedPoll(p, body) {
  const id = await p.evaluate((body) => {
    const channel = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    const id = crypto.randomUUID()
    const row = { v: 1, msg_id: id, task_id: crypto.randomUUID(), ts: new Date(Date.now() - 60e3).toISOString(), from: 'CLE-07', to: '@channel', kind: 'note', body, files: [], channel: channel.active || 'alerts', parent_task_id: null, is_parent: 1 }
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, row]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, row]
    return id
  }, body)
  const form = `.spool-main article.msg[data-msg-id="${id}"] [data-testid=poll-form]`
  await p.waitForSelector(form, { timeout: 15000 })
  await p.evaluate((form) => document.querySelector(form).scrollIntoView({ block: 'center' }), form)
  return { id, form }
}

/* the answers posted to form `id`: their bodies, oldest first */
function answers(p, id) {
  return p.evaluate((id) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    return (pinia.state.value.channel.messages || []).map((m) => String(m.body || '')).filter((b) => b.includes(`Poll: ${id}`) && !/^Chat:/m.test(b))
  }, id)
}

function pick(p, form, qi, key) {
  return p.evaluate((form, qi, key) => {
    const q = document.querySelectorAll(`${form} [data-testid=poll-question]`)[qi]
    q.querySelector(`[data-testid=poll-option][data-poll-key=${key}] input`).click()
  }, form, qi, key)
}

const hasSend = (p, form) => p.evaluate((form) => Boolean(document.querySelector(`${form} [data-testid=poll-send]`)), form)

async function threeClicks(browser) {
  const { p, errors } = await open(browser)
  const { id, form } = await seedPoll(p, POLL(3))
  await pick(p, form, 0, 'A')
  await sleep(SETTLE_MS)
  const n1 = (await answers(p, id)).length
  await pick(p, form, 1, 'B')
  await sleep(SETTLE_MS)
  const n2 = (await answers(p, id)).length
  const send = await hasSend(p, form)
  await pick(p, form, 2, 'A')
  await sleep(SETTLE_MS)
  const list = await answers(p, id)
  ok('3-question radio form: no answer is posted while a question is open (after click 1 and 2: 0)', n1 === 0 && n2 === 0, { n1, n2 })
  ok('3-question radio form: it has a Send while it waits', send)
  ok('3-question radio form: answering all 3 questions posts exactly 1 answer message', list.length === 1, { n: list.length, list })
  ok('3-question radio form: that one answer holds all three picks', /Answer 1: A\b/.test(list[0] || '') && /Answer 2: B\b/.test(list[0] || '') && /Answer 3: A\b/.test(list[0] || ''), list[0])
  ok('3-question radio form: no page error', errors.length === 0, errors)
  await p.close()
}

async function sendEarly(browser) {
  const { p, errors } = await open(browser)
  const { id, form } = await seedPoll(p, POLL(3))
  await pick(p, form, 1, 'B')
  await p.evaluate((form) => document.querySelector(`${form} [data-testid=poll-send]`).click(), form)
  await sleep(SETTLE_MS)
  const list = await answers(p, id)
  ok('3-question radio form, one pick then Send: exactly 1 answer, with that pick only', list.length === 1 && /Answer 2: B\b/.test(list[0]) && !/Answer [13]:/.test(list[0]), { n: list.length, list })
  ok('3-question radio form, Send: no page error', errors.length === 0, errors)
  await p.close()
}

async function oneQuestion(browser) {
  const { p, errors } = await open(browser)
  const { id, form } = await seedPoll(p, POLL(1))
  const send = await hasSend(p, form)
  await pick(p, form, 0, 'B')
  await sleep(SETTLE_MS)
  const list = await answers(p, id)
  ok('control: a one-question radio form has no Send and posts its answer on the click', !send && list.length === 1 && /^Answer: B\b/m.test(list[0]), { send, n: list.length, list })
  ok('control: no page error', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await threeClicks(browser)
  await sendEarly(browser)
  await oneQuestion(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
