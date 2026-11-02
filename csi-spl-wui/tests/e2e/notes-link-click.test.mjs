// Spec 155 (SPL-4615, c-909 2f7a46ad): a saved topic link on a note, clicked
// through to its target, on the mock bundle at 1440 px and at a 390 px phone.
// add-to-note.test.mjs reads the links from the store and notes-link-left only
// reads the href: neither presses the link.
//
// A note gains two topic links through the store's addLink (the mock's own
// memory); each is pressed with a real click or tap, and the page must land on
// THAT topic: the address, the thread showing that topic's opening message, and
// no page reload (a link on this host goes through the router, NoteLinks open).
//
// Red control: with NoteLinks open() pushing any other path, or the anchor
// gone, the "lands on" checks FAIL (the output is in the commit body).
//
// Run:
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-link-click.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: Boolean(pass) })
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  return p
}

/* two mock topics with different opening messages, so a link that lands on
   the wrong topic reads differently (utils/mock-data.mjs) */
const TOPICS = [
  { id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', body: 'Review the spool WUI scaffold' },
  { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', body: 'This is the lde mock feed' },
]
const NOTE = 'mock-note-2'

const addTopicLink = (p, topic) => p.evaluate(async (note, ref) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  await store.addLink(note, { kind: 'topic', workspace_id: 't1', ref, label: '' })
}, NOTE, topic)

async function openNote(p) {
  await go(p, '/notes')
  await p.waitForSelector(`[data-note-id="${NOTE}"] [data-test=notes-open]`, { visible: true, timeout: NAV })
  await p.click(`[data-note-id="${NOTE}"] [data-test=notes-open]`)
  await p.waitForSelector(`[data-test=note-detail][data-note-id="${NOTE}"][data-state=ready]`, { visible: true, timeout: 15000 })
}

async function clickThrough(p, tag, touch, topic) {
  await openNote(p)
  const sel = `[data-test=note-link][data-kind=topic] a[href$="/t/${topic.id}"]`
  const link = await p.waitForSelector(sel, { visible: true, timeout: 15000 }).catch(() => null)
  check(`${tag}: the note shows the topic link as an anchor`, Boolean(link), topic.id)
  if (!link) return
  await p.evaluate(() => { window.__sameDocument = true })
  if (touch) await link.tap()
  else await link.click()
  const landed = await p.waitForFunction((want) => location.pathname === want, { timeout: 15000 }, `/t/${topic.id}`).then(() => true, () => false)
  check(`${tag}: the click lands on /t/${topic.id.slice(0, 8)}`, landed, await p.evaluate(() => location.pathname))
  const shown = await p.waitForFunction((body) => [...document.querySelectorAll('[data-test=topic-browse-thread] article.msg')].some((a) => a.textContent.includes(body)), { timeout: 15000 }, topic.body).then(() => true, () => false)
  check(`${tag}: the thread shows that topic's opening message`, shown, topic.body)
  check(`${tag}: no page reload`, await p.evaluate(() => window.__sameDocument === true))
}

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  for (const topic of TOPICS) await addTopicLink(p, topic.id)
  for (const topic of TOPICS) await clickThrough(p, tag, touch, topic)
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base, 1440, false)
  await run(browser, server.base, 390, true)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-link-click: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
