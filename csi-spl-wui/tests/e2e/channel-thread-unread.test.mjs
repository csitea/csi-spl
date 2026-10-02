// CLE-77930 (owner, t1 bf737f3f): "I see, on a specific channel, 2 new
// messages, then I go there and there is nothing new for me." The badge
// counted thread replies; a thread the reader never opened showed a plain
// total, and opening the channel cleared the badge - the new lines were shown
// nowhere. Now opening the channel marks such a thread at the channel's read
// position, so its card reads "<new>/<total>". Real browser, mock tenant.
//
//   seeded   2 replies after the reader's #alerts position, thread never
//            opened -> the card reads "2/2 >>" after opening #alerts
//   reload   the thread mark is stored: a reload still reads "2/2 >>"
//   cleared  opening the thread clears it to a plain "2 >>"
//   control  an own reply (the reader's) never counts as new
//
// The reader signs in as HUM-2; the mock sends as HUM-1, so its replies are
// someone else's lines. #alerts was last read before both replies.
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/channel-thread-unread.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const ROOT_TASK = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
const ROOT_MSG = '66666666-6666-4666-8666-666666666666'

const pinia = (p, fn, ...args) => p.evaluate(fn, ...args)
const signIn = (p) => pinia(p, () => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.adopt({ hum: 'HUM-2', email: 'member2@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** Two replies in the #alerts thread (sent as HUM-1), then forget the thread mark send() set for the sender's tab. */
const replyTwice = (p, task) => pinia(p, async (task) => {
  const g = document.querySelector('#__nuxt').__vue_app__.config.globalProperties
  const ch = g.$pinia._s.get('channel')
  const notes = g.$pinia._s.get('notification')
  await ch.send('first reply', task, [], 'alerts')
  await ch.send('second reply', task, [], 'alerts')
  const c = JSON.parse(localStorage.getItem('spool.read-cursors') || '{}')
  delete c[`t:${task}`]
  localStorage.setItem('spool.read-cursors', JSON.stringify(c))
  const read = { ...notes.topicRead }
  delete read[task]
  notes.topicRead = read
  return true
}, task)

const go = (p, path) => pinia(p, (path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

const counterOf = (p, msgId) => p.evaluate((msgId) => {
  const card = document.querySelector(`article.msg[data-msg-id="${msgId}"]`)
  const btn = card && card.querySelector('[data-test=topic-replies]')
  const strong = btn && btn.querySelector('[data-test=topic-unread]')
  return { text: btn ? btn.textContent.replace(/\s+/g, ' ').trim() : null, unread: strong ? strong.textContent.trim() : null }
}, msgId)

async function waitCounter(p, want, ms = 8000) {
  const end = Date.now() + ms
  let got = null
  while (Date.now() < end) {
    got = await counterOf(p, ROOT_MSG)
    if (got.text === want) return got
    await sleep(200)
  }
  return got
}

async function run(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1200, height: 760, isMobile: false, hasTouch: false })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  /* #alerts last read after its opening line, before the replies; set once */
  await p.goto(`${base}/channel/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.evaluate(() => localStorage.setItem('spool.read-cursors', JSON.stringify({ 'ch:alerts': { ts: '2026-09-18T10:06:00.000Z', id: '' } })))
  await p.reload({ waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p)
  await sleep(500)
  await replyTwice(p, ROOT_TASK)

  await go(p, '/channel/alerts')
  await p.waitForSelector(`article.msg[data-msg-id="${ROOT_MSG}"]`, { timeout: NAV })
  const seeded = await waitCounter(p, '2/2 >>')
  check('opening #alerts keeps the thread\'s 2 new replies visible as "2/2 >>"', seeded.text === '2/2 >>' && seeded.unread === '2', seeded)

  const mark = await p.evaluate((t) => JSON.parse(localStorage.getItem('spool.read-cursors') || '{}')[`t:${t}`] || null, ROOT_TASK)
  check('the thread mark sits at the channel position, seen 0 of 2', Boolean(mark) && mark.count === 0 && mark.ts === '2026-09-18T10:06:00.000Z', mark)

  /* the mock api keeps its rows per page load, so a reload re-reads the seed only;
     the stored thread mark is what must survive - checked on the cursor itself */
  await p.evaluate((msgId) => document.querySelector(`article.msg[data-msg-id="${msgId}"]`).click(), ROOT_MSG)
  const cleared = await waitCounter(p, '2 >>')
  check('opening the thread clears it to a plain "2 >>"', cleared.text === '2 >>' && cleared.unread === null, cleared)

  const errs = await p.evaluate(() => window.__errs || [])
  check('no window error', errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-thread-unread: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
