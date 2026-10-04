// HUM-10 (t1 topic 2627084c, owner: "the Shift + A , should arhive a topic
// from the topics view asewell"): on the Topics view (/t/:id), Shift + A on a
// focused topic row archives that topic through the row menu's archive path,
// and the row leaves the list. An "A" typed in a text field archives nothing,
// and a role the menu locks Archive for gets nothing. Desktop, 1440.
//
// Run:
//   node tests/e2e/topic-list-shift-a.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-list-shift-a.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const OTHER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const OUT = process.env.OUT || mkdtempSync(join(tmpdir(), 'topic-list-shift-a-'))
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

async function go(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      return
    } catch (e) {
      last = e
      await sleep(400)
    }
  }
  throw last
}


const rowSel = (id) => `[data-test=topic-browse-list] a.topic-row[data-key="${id}"]`

async function rowGone(p, id, tries = 30) {
  for (let i = 0; i < tries; i++) {
    if (await p.evaluate((sel) => !document.querySelector(sel), rowSel(id))) return true
    await sleep(150)
  }
  return false
}

async function openList(policy) {
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((pol) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', pol)
    localStorage.setItem('spool.mock.role', 'developer')
  }, policy)
  await p.setViewport({ width: 1440, height: 900 })
  /* a cold dev server aborts the first navigation; go() retries it */
  await go(p, `${srv.base}/t/${TOPIC}`)
  await p.waitForSelector(rowSel(OTHER), { timeout: NAV_TIMEOUT })
  await sleep(600)
  return p
}

async function shiftA(p) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Shift')
}

const errors = []
const srv = await startServer()
const browser = await launch()
try {
  const p = await openList('everyone')

  /* an "A" typed in a text field never archives, even with the row focused before */
  await p.focus(rowSel(OTHER))
  const field = await p.evaluate(() => {
    const el = [...document.querySelectorAll('textarea, input[type=text], input[type=search], input:not([type])')]
      .find((e) => e.offsetParent !== null && !e.disabled && !e.readOnly)
    if (!el) return ''
    el.setAttribute('data-shift-a-field', '1')
    return el.tagName
  })
  ok('a text field is on the page', Boolean(field), field)
  if (field) {
    await p.focus('[data-shift-a-field="1"]')
    await shiftA(p)
    const typed = await p.$eval('[data-shift-a-field="1"]', (e) => e.value)
    ok('Shift + A in a text field types "A" and archives nothing', typed.includes('A') && !(await rowGone(p, OTHER, 6)), { typed })
    await p.$eval('[data-shift-a-field="1"]', (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  }

  /* the focused row: Shift + A archives that topic and it leaves the list */
  await p.focus(rowSel(OTHER))
  const focused = await p.evaluate((sel) => document.activeElement === document.querySelector(sel), rowSel(OTHER))
  ok('the topic row takes the focus', focused)
  await shiftA(p)
  const gone = await rowGone(p, OTHER)
  const toast = await p.$('[data-testid=archive-toast]')
  ok('Shift + A on the focused row archives the topic and it leaves the list', gone && Boolean(toast), { gone, toast: Boolean(toast) })
  await p.screenshot({ path: `${OUT}/archived-1440.png` })
  await p.close()

  /* a role the row menu locks Archive for: the key does nothing */
  const q = await openList('admins')
  /* the row menu shows Archive locked for this viewer, so the check below is not vacuous */
  await q.click(`[data-test=topic-browse-list] [data-testid=topic-list-menu][data-menu-id="${OTHER}"]`)
  let items = []
  for (let i = 0; i < 40 && !items.length; i++) {
    items = await q.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => (
      e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : '')
    )))
    if (!items.length) await sleep(150)
  }
  ok('the row menu locks Archive for this role', items.includes('msg-menu-archive:off'), items)
  await q.keyboard.press('Escape')
  await sleep(200)
  await q.focus(rowSel(OTHER))
  await shiftA(q)
  ok('Shift + A does nothing when the role may not archive', !(await rowGone(q, OTHER, 10)))
  await q.close()

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-list-shift-a: ${results.length - failed.length}/${results.length} passed`)
console.log(`screenshots: ${OUT}`)
process.exit(failed.length ? 1 : 0)
