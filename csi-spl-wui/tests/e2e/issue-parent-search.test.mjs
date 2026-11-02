// SPL-4610 (HUM-10, t1 b52769e4, msg d1bbdea4): "the praent drop down should be
// a dropbox with case insensitive search". The issue's Parent and the two level
// moves (epic, move-epic, move-parent) open a focused search box above the list;
// the other pickers stay plain. At 1440 and on the 390 phone sheet.
//
//   pnpm run test:e2e issue-parent-search
//   BASE_URL=<generated bundle> pnpm run test:e2e issue-parent-search
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const SEARCH = '[data-test=issues-parent-search]'
const OPTION = '[data-test=issues-menu-option]'
const MIXED = 'Mixed Case Release Train'
const CYRILLIC = 'Отчет за Месеца'
const GREEK = 'ΑΣΤΕΡΙ Παρατηρητήριο'

/* the new-issue form, the way this width makes one; the mock hub lives in the tab */
async function createDesktop(p, title, kindClicks) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  for (let i = 0; i < kindClicks; i++) await p.click('[data-test=issues-newrow] [data-test=issues-kind]')
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-newrow]'), { timeout: 5000 })
}
async function createPhone(p, title, kindClicks) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  for (let i = 0; i < kindClicks; i++) await p.click('[data-test=issues-kind]')
  await p.type('[data-test=issues-detail-title]', title)
  await p.click('[data-test=issues-create]')
  await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
  await p.click('[data-test=issues-detail-back]')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 })
}
/* a sheet row at 1440, a card on the phone */
const rowKey = (p, title) => p.waitForFunction((want) => {
  const row = [...document.querySelectorAll('[data-test=issues-row], [data-test=issues-card]')].find((r) => r.querySelector('.issues-title, [data-test=issues-card-title]')?.textContent.trim() === want)
  return row ? row.getAttribute('data-key') : false
}, { timeout: 5000 }, title).then((h) => h.jsonValue())
const openRow = (p, phone, key) => (phone ? p.click(`[data-test=issues-card][data-key="${key}"] [data-test=issues-card-title]`) : p.click(`[data-test=issues-row][data-key="${key}"] .issues-title`))
async function openDetail(p, phone, key) {
  await openRow(p, phone, key)
  await p.waitForSelector('[data-test=issues-epic]', { visible: true, timeout: 5000 })
}
async function closeDetail(p, phone) {
  if (phone) await p.click('[data-test=issues-detail-back]')
  else await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-epic]'), { timeout: 5000 })
}
const options = (p) => p.$$eval(OPTION, (els) => els.filter((e) => e.offsetParent !== null).map((e) => ({ v: e.getAttribute('data-value'), t: e.textContent.trim(), on: e.getAttribute('aria-selected') === 'true' })))
async function search(p, text) {
  await p.$eval(SEARCH, (el) => { el.focus(); el.select() })
  await p.keyboard.press('Backspace')
  if (text) await p.keyboard.type(text)
  return options(p)
}
async function openParent(p) {
  await p.click('[data-test=issues-epic]')
  await p.waitForSelector(SEARCH, { visible: true, timeout: 5000 })
}
const parentShows = (p, want) => p.waitForFunction((w) => !document.querySelector('[data-test=issues-menu]') && document.querySelector('[data-test=issues-epic]')?.textContent.includes(w), { timeout: 5000 }, want).then(() => true, () => false)

async function runWidth(p, vp, shot, errors) {
  const w = vp.width
  const phone = w < 800
  await setPageViewport(p, vp)
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  const create = phone ? createPhone : createDesktop
  /* Kind cycles issue -> epic -> feature */
  for (const title of [MIXED, CYRILLIC, GREEK]) await create(p, title, 1)
  await create(p, 'The child issue', 0)
  await create(p, 'The other issue', 0)
  const child = await rowKey(p, 'The child issue')

  await openDetail(p, phone, child)
  await openParent(p)
  /* the epic list refreshes a moment after a create */
  await p.waitForFunction((o, n) => document.querySelectorAll(o).length >= n, { timeout: 5000 }, OPTION, 5).catch(() => {})
  const focused = await p.$eval(SEARCH, (el) => document.activeElement === el)
  const above = await p.evaluate((s, o) => document.querySelector(s).getBoundingClientRect().bottom <= document.querySelector(o).getBoundingClientRect().top + 1, SEARCH, OPTION)
  ok(`${w} 1 opening Parent focuses the search box, above the list`, focused && above, { focused, above })
  await p.screenshot({ path: join(shot, `issue-parent-search-${w}.png`) })

  const all = await options(p)
  const mixedKey = all.find((o) => o.t.endsWith(MIXED))?.v
  const cyrKey = all.find((o) => o.t.endsWith(CYRILLIC))?.v
  ok(`${w} 2 "No epic" is the first row, then every epic`, all[0]?.v === '' && Boolean(mixedKey && cyrKey), all.map((o) => o.t))

  const lower = await search(p, MIXED.toLowerCase().slice(0, 12))
  ok(`${w} 3 lower-case typing finds the mixed-case title`, lower.length === 1 && lower[0].v === mixedKey, lower)
  const byKey = await search(p, mixedKey.toLowerCase())
  ok(`${w} 4 a key in lower case finds its row`, byKey.some((o) => o.v === mixedKey) && byKey.every((o) => o.v.startsWith(mixedKey)), byKey)
  const cyr = await search(p, 'МЕСЕЦ')
  ok(`${w} 5 Cyrillic upper case finds a mixed-case title`, cyr.length === 1 && cyr[0].v === cyrKey, cyr)
  const greek = await search(p, 'ασ')
  ok(`${w} 6 Greek: lower case finds an upper-case title`, greek.some((o) => o.t.endsWith(GREEK)), greek)
  const sigma = await search(p, 'ΑΣ')
  ok(`${w} 7 Greek: an upper-case sigma ending the query still matches inside a word`, sigma.some((o) => o.t.endsWith(GREEK)), sigma)
  const none = await search(p, 'zzzqqq')
  const line = await p.$eval('[data-test=issues-parent-search-empty]', (el) => el.textContent.trim()).catch(() => '')
  ok(`${w} 8 no match: no rows and a line says so`, none.length === 0 && line === 'Nothing matches.', { none, line })
  const noEpic = await search(p, 'no ep')
  ok(`${w} 9 "No epic" stays reachable by typing`, noEpic.length === 1 && noEpic[0].v === '', noEpic)

  await search(p, '')
  await p.keyboard.press('ArrowDown')
  const before = (await options(p)).findIndex((o) => o.on)
  await p.keyboard.press('ArrowDown')
  const after = (await options(p)).findIndex((o) => o.on)
  ok(`${w} 10 the arrows move the highlight`, after === before + 1, { before, after })
  await p.keyboard.press('Escape')
  const closed = await p.waitForFunction(() => !document.querySelector('[data-test=issues-menu]'), { timeout: 3000 }).then(() => true, () => false)
  const stillOpen = await p.$('[data-test=issues-epic]').then(Boolean)
  ok(`${w} 11 Esc closes the picker, the issue stays open`, closed && stillOpen, { closed, stillOpen })

  await openParent(p)
  await search(p, 'mixed case')
  await p.keyboard.press('Enter')
  ok(`${w} 12 Enter picks: the parent is saved and shown`, await parentShows(p, mixedKey))
  await openParent(p)
  await search(p, 'отчет')
  await p.click(`${OPTION}[data-value="${cyrKey}"]`)
  ok(`${w} 13 a click picks: the parent is saved and shown`, await parentShows(p, cyrKey))
  await openParent(p)
  const current = (await options(p)).find((o) => o.on)
  ok(`${w} 14 the current parent is the highlighted row`, current?.v === cyrKey, current)
  await search(p, 'no ep')
  await p.keyboard.press('Enter')
  ok(`${w} 15 "No epic" saves as before`, await parentShows(p, 'No epic'))

  /* the level moves choose a parent through the same box; the other pickers stay plain */
  await p.click('[data-test=issues-status]')
  await p.waitForSelector('[data-test=issues-menu][data-kind=status]', { visible: true, timeout: 5000 })
  ok(`${w} 16 the status picker has no search box`, !(await p.$(SEARCH)))
  await p.click('[data-test=issues-menu-option][data-value="done"]')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-menu]'), { timeout: 5000 })
  await closeDetail(p, phone)
  await runMoves(p, w, phone, child)
  ok(`${w} 19 no page errors`, errors.length === 0, errors)
  errors.length = 0
}

async function openMove(p, phone, key, want) {
  if (phone) {
    await openRow(p, phone, key)
    await p.waitForSelector('[data-test=issues-level-btn]', { visible: true, timeout: 5000 })
    await p.click('[data-test=issues-level-btn]')
    await p.waitForSelector(`${OPTION}[data-value="${want}"]`, { visible: true, timeout: 5000 })
    await p.click(`${OPTION}[data-value="${want}"]`)
  } else {
    await p.select(`[data-test=issues-row][data-key="${key}"] [data-test=issues-row-level]`, want)
  }
  await p.waitForSelector(SEARCH, { visible: true, timeout: 5000 })
}

async function runMoves(p, w, phone, child) {
  await openMove(p, phone, child, '3')
  const kind = await p.$eval('[data-test=issues-menu]', (el) => el.getAttribute('data-kind'))
  const found = await search(p, 'THE OTHER ISSUE')
  ok(`${w} 17 the move-parent picker searches in any case`, kind === 'move-parent' && found.length === 1, { kind, found })
  await p.keyboard.press('Enter')
  const moved = await p.waitForFunction(() => !document.querySelector('[data-test=issues-menu]'), { timeout: 5000 }).then(() => true, () => false)
  ok(`${w} 18 a move-parent pick closes the picker`, moved)
}

const shot = process.env.SHOT_DIR || mkdtempSync(join(tmpdir(), 'spl-e2e-'))
mkdirSync(shot, { recursive: true })
const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => { const m = String(e && e.message); if (!/Failed to fetch dynamically imported module/.test(m)) errors.push(m) })
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) await runWidth(p, vp, shot, errors)
  console.log(`  screenshots: ${shot}`)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
