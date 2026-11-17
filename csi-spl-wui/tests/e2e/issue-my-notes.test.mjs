// Spec 155 2.12 (SPL-5769, HUM-24 topic bc7c22e1): the open issue lists the
// person's own notes that link it, under the comment box, at 1440 px and at
// a 390 px phone, on the mock bundle.
//
// Cases:
//   an issue no note links shows no "My notes" list
//   Add to note from the open issue: the note shows in "My notes" at once,
//       under the comment box and above the discussions, by its title
//   a note with no title shows the first line of its text
//   an archived note leaves the list
//   a row opens its note (/notes?note=<id>)
// SHOTS_DIR=<dir> saves the issue dialog with the list at 1440 and 390 px.
//
// Red control: against a bundle of master before SPL-5769 the list checks
// FAIL (no issue-my-notes).
//
// Run:
//   BASE_URL=http://127.0.0.1:4321 node tests/e2e/issue-my-notes.test.mjs
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const visible = (p, sel, timeout = 15000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true, () => false)
const gone = (p, sel, timeout = 5000) => p.waitForFunction((s) => !document.querySelector(s), { timeout }, sel).then(() => true, () => false)
/* the notes store's own calls (the mock answers from memory) */
const notes = (p, fn, arg) => p.evaluate(async (fn, arg) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  return store ? store[fn](...arg) : null
}, fn, arg)
const rows = (p) => p.$$eval('[data-test=issue-my-note]', (els) => els.map((e) => ({ id: e.getAttribute('data-note-id'), text: e.textContent.trim() })))

async function openPage(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  return p
}

/* the mock workspace starts with no issue: make one (the New issue row), its key */
async function newIssue(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  return p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
}

/* the open issue's Add to note, then pick note `id` */
async function addToNote(p, id) {
  await p.evaluate(() => [...document.querySelectorAll('[data-test=issues-detail-note]')].find((e) => e.offsetParent)?.click())
  if (!(await visible(p, '[data-test=note-picker][data-state=ready] [data-test=note-picker-row]'))) return false
  await p.click(`[data-test=note-picker-row][data-note-id="${id}"]`)
  await gone(p, '[data-test=note-picker]')
  return true
}

async function openIssue(p, key, width) {
  await p.setViewport({ width, height: width < 600 ? 844 : 900 })
  await go(p, '/issues')
  await visible(p, '[data-test=issues-page]')
  await go(p, `/issues?issue=${key}`)
  await visible(p, '[data-test=issues-comment-input]')
}

async function run(browser, base) {
  /* the New issue row is a wide-screen form: make the issues at 1440 px */
  const p = await openPage(browser, base)
  await go(p, '/issues')
  await visible(p, '[data-test=issues-page]')
  const key = await newIssue(p, 'Fix the invoice import')
  const other = await newIssue(p, 'Another issue')
  for (const width of [1440, 390]) {
    const tag = `${width}px`
    await openIssue(p, other, width)
    await visible(p, '[data-test=issue-discussions]')
    await sleep(500)
    check(`${tag}: an issue no note links shows no My notes list`, !(await p.$('[data-test=issue-my-notes]')))
    await openIssue(p, key, width)
    const note = width === 1440 ? 'mock-note-1' : 'mock-note-3'
    check(`${tag}: Add to note picks ${note}`, await addToNote(p, note))
    const up = await visible(p, `[data-test=issue-my-note][data-note-id="${note}"]`, 10000)
    const got = await rows(p)
    const want = width === 1440 ? 'Release checklist' : 'Call back about the invoice'
    check(`${tag}: the note shows in My notes at once, by its ${width === 1440 ? 'title' : 'first line (no title)'}`, up && got.some((r) => r.id === note && r.text === want), got)
    const order = await p.evaluate(() => {
      const box = document.querySelector('[data-test=issues-comment-field]')
      const mine = document.querySelector('[data-test=issue-my-notes]')
      const disc = document.querySelector('[data-test=issue-discussions]')
      const before = (a, b) => Boolean(a && b && (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING))
      return { heading: mine?.querySelector('h3')?.textContent.trim() || '', order: before(box, mine) && before(mine, disc) }
    })
    check(`${tag}: "My notes" sits under the comment box, above the discussions`, order.heading === 'My notes' && order.order, order)
    if (process.env.SHOTS_DIR) {
      await gone(p, '[data-testid=note-added-text]', 10000)
      await p.evaluate(() => document.querySelector('[data-test=issue-my-notes]')?.scrollIntoView({ block: 'center' }))
      await sleep(300)
      await p.screenshot({ path: `${process.env.SHOTS_DIR}/issue-my-notes-${width}.png` })
    }
  }
  /* an archived note leaves the list; a row opens its note */
  const tag = '1440px'
  await openIssue(p, key, 1440)
  await visible(p, '[data-test=issue-my-note][data-note-id="mock-note-3"]', 10000)
  await notes(p, 'patch', ['mock-note-3', { archived: true }])
  await notes(p, 'load', [])
  const left = await p.waitForFunction(() => !document.querySelector('[data-test=issue-my-note][data-note-id="mock-note-3"]'), { timeout: 10000 }).then(() => true, () => false)
  check(`${tag}: an archived note leaves the list, the other stays`, left && (await rows(p)).some((r) => r.id === 'mock-note-1'), await rows(p))
  await p.evaluate(() => document.querySelector('[data-test=issue-my-note][data-note-id="mock-note-1"] [data-test=issue-my-note-link]')?.click())
  check(`${tag}: a row opens its note`, await visible(p, '[data-test=note-detail][data-note-id="mock-note-1"]'))
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
console.log(`\nissue-my-notes: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
