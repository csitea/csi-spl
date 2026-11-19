// SPL-5954 (owner HUM-10, csitea 51150550, msgs 834974be d110f8f8 3c0c6b4a):
// a poll form's answered state is the same for every reader and survives a
// reload. The answers are replies in the form's topic, stored in the hub;
// the feed around the form holds only a window of them.
//
// In Chrome, on the mock tenant, reader HUM-1 opens a channel holding two
// forms whose replies the mock hub stores (localStorage seed, then a reload).
// The replies are older than the channel feed's window (60 newer lines in
// the channel, the feed reads 30), so no loaded feed holds them:
//   1. a Go-button form that reader HUM-2 answered: HUM-1 sees it done and
//      HUM-2 among its answers (red on master: only the reader's own answer
//      set the Go button, and only from the loaded window)
//   2. a radio form on which HUM-1 chose "Chat about this": it shows picked
//      (red on master: the chat is outside the window)
//
// Run:
//   pnpm run test:e2e poll-state-shared
//   BASE_URL=<generated bundle> pnpm run test:e2e poll-state-shared   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PATH = '/channel/alerts'
const WAIT_MS = 15000

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const GO = 'Approve the draft?\n\n```poll\nApprove the draft?\n(GO) Approve\n```'
const RADIO = 'Which way?\n\n```poll\nWhich way?\n(A) The first way\n(B) The second way\n```'

/* two forms and their replies as the mock hub's stored rows: HUM-2 answered
   the Go form, HUM-1 chose "Chat about this" on the radio form. The mock
   lists a channel's last rows as stored, so the replies come first, then 60
   other lines, then the two forms: the feed's window holds the forms only */
function seedRows(channel, go, radio) {
  const at = (s) => new Date(Date.now() - s * 1000).toISOString()
  const ids = { go: crypto.randomUUID(), radio: crypto.randomUUID(), goTask: crypto.randomUUID(), radioTask: crypto.randomUUID() }
  const root = (id, task, body, s) => ({ v: 1, msg_id: id, task_id: task, ts: at(s), from: 'CLE-07', to: '@channel', kind: 'note', body, files: [], channel, parent_task_id: null, is_parent: 1 })
  const reply = (task, from, body, s) => ({ v: 1, msg_id: crypto.randomUUID(), task_id: task, ts: at(s), from, to: '@channel', kind: 'note', body, files: [], channel, parent_task_id: task, is_parent: 0 })
  const filler = Array.from({ length: 60 }, (_, i) => { const t = crypto.randomUUID(); return root(t, t, `Line ${i + 1}`, 80 - i) })
  const rows = [
    reply(ids.goTask, 'HUM-2', `Poll: ${ids.go}\nAnswer: GO — Approve`, 100),
    reply(ids.radioTask, 'HUM-1', `Chat: wants to discuss\nPoll: ${ids.radio}\n> Which way?\n\nlet us talk`, 90),
    ...filler,
    root(ids.go, ids.goTask, go, 10),
    root(ids.radio, ids.radioTask, radio, 5),
  ]
  return { ids, rows }
}

async function openAs(p, hum) {
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.evaluate((hum) => {
    const session = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    session.adopt({ hum, email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  }, hum)
}

/* what form `id` shows: Go done, the chat option picked, the answerers */
function shows(p, id) {
  return p.evaluate((id) => {
    const f = document.querySelector(`.spool-main article.msg[data-msg-id="${id}"] [data-testid=poll-form]`)
    if (!f) return null
    return {
      goDone: Boolean(f.querySelector('[data-testid=poll-go-done]')),
      chat: Boolean(f.querySelector('[data-testid=poll-chat] input')?.checked),
      from: [...f.querySelectorAll('[data-testid=poll-answer]')].map((a) => a.getAttribute('data-from')),
    }
  }, id)
}

/* how many marker replies of the two forms any loaded feed holds */
function loadedMarkers(p, ids) {
  return p.evaluate((ids) => {
    let n = 0
    for (const [, st] of document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s) {
      for (const v of Object.values(st)) {
        if (Array.isArray(v)) n += v.filter((m) => m && ids.some((id) => String(m.body || '').includes(`Poll: ${id}`))).length
      }
    }
    return n
  }, ids)
}

async function waitShows(p, ids) {
  try {
    await p.waitForFunction((go, radio) => {
      const f = (id) => document.querySelector(`.spool-main article.msg[data-msg-id="${id}"] [data-testid=poll-form]`)
      return f(go)?.querySelector('[data-testid=poll-go-done]') && f(radio)?.querySelector('[data-testid=poll-chat] input')?.checked
    }, { timeout: WAIT_MS }, ids.go, ids.radio)
  } catch { /* the checks below say what is missing */ }
}

async function sharedState(browser) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await openAs(p, 'HUM-1')
  const channel = await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').active || 'alerts')
  const { ids, rows } = await p.evaluate(`(${seedRows.toString()})(${[channel, GO, RADIO].map((x) => JSON.stringify(x)).join(', ')})`)
  await p.evaluate((rows) => localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)), rows)
  /* a reload: the state must come back from what the hub stores */
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await openAs(p, 'HUM-1')
  await p.waitForSelector(`.spool-main article.msg[data-msg-id="${ids.go}"] [data-testid=poll-form]`, { timeout: WAIT_MS })
  await waitShows(p, ids)
  const go = await shows(p, ids.go)
  const radio = await shows(p, ids.radio)
  const loaded = await loadedMarkers(p, [ids.go, ids.radio])
  ok('the two replies are outside the loaded feeds (0 marker rows held)', loaded === 0, { loaded })
  ok('reader HUM-1 sees the Go form done after reader HUM-2 answered it', Boolean(go?.goDone), go)
  ok('reader HUM-1 sees HUM-2 among the Go form\'s answers', Boolean(go?.from.includes('HUM-2')), go)
  ok('reader HUM-1\'s own "Chat about this" shows picked after the reload', Boolean(radio?.chat), radio)
  ok('no page error', errors.length === 0, errors)
  await p.evaluate(() => localStorage.removeItem('spool.mock.extra-messages'))
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await sharedState(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
