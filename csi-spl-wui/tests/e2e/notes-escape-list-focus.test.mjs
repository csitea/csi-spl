// Spec 155 2.6 + spec 103 (SPL-6063): Escape out of an open note leaves the
// focus on the notes list, on the row of the note just closed, so j / k and
// ArrowDown / ArrowUp move up and down the list at once, without a click.
//
// Owner HUM-10 (t1 3858d264, msg 7bd1c224): "Once I have writen a note, when
// I click escape to clsoe the note I would expect that I could move with the
// arrows or the hklm as vim up and down on the interface , but instread the
// focus goes on the section".
//
// Cases, at 1440 px (vim keys are off on a phone width, spec 103):
//   opened by a click on its row: type in the title, Esc, then j / k /
//   ArrowDown / ArrowUp step the rows;
//   opened by the + (New note): type, Esc, the focus is on the new note's
//   row, not on the +, and j steps to the row below it.
// CONTROL: with the fix out (pages/notes.vue: no data-vim-item on the row
// link, no focusRow after close) the checks below FAIL on origin/master.
//
// Run:
//   node tests/e2e/notes-escape-list-focus.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-escape-list-focus.test.mjs
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
/* every row's note id, in the order drawn (Pinned, then the rest) */
const order = (p) => p.$$eval('[data-test=notes-row]', (els) => els.map((e) => e.getAttribute('data-note-id')))
const waitDetail = (p, id) => p.waitForSelector(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
const waitGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).then(() => true, () => false)
/* where the focus is: the note row it sits in, else the element's tag / test id */
const focusAt = (p) => p.evaluate(() => {
  const a = document.activeElement
  const row = a?.closest?.('[data-test=notes-row]')
  if (row && a.matches('[data-test=notes-open]')) return row.getAttribute('data-note-id')
  return `${a?.tagName || 'none'}${a?.getAttribute?.('data-test') ? '[' + a.getAttribute('data-test') + ']' : ''}${a?.className ? '.' + String(a.className).split(' ')[0] : ''}`
})
/* the focus settles a frame or two after the dialog goes */
const focusSettles = (p, want) => p.waitForFunction((want) => {
  const a = document.activeElement
  return a?.matches?.('[data-test=notes-open]') && a.closest('[data-test=notes-row]')?.getAttribute('data-note-id') === want
}, { timeout: 3000 }, want).then(() => true, () => false)
const press = async (p, key, want) => {
  await p.keyboard.press(key)
  return focusSettles(p, want)
}

async function openPage(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  const vim = await p.waitForFunction(() => document.documentElement.getAttribute('data-vim-nav') === 'on', { timeout: 15000 }).then(() => true, () => false)
  check('the vim key layer is mounted', vim)
  return p
}

async function typeInTitle(p, text) {
  await p.click('[data-test=note-title]')
  await p.keyboard.press('End')
  await p.keyboard.type(text)
}

/* opened by a click on its row */
async function fromRow(browser, base) {
  const p = await openPage(browser, base)
  const ids = await order(p)
  check('the list has 3 rows or more', ids.length >= 3, ids)
  const [first, second, third] = ids
  await p.click(`[data-note-id="${second}"] [data-test=notes-open]`)
  check('a click opens the note', await waitDetail(p, second))
  await typeInTitle(p, ' edited')
  await p.keyboard.press('Escape')
  check('Esc closes the note', await waitGone(p))
  check('Esc: the focus is on the closed note\'s row', await focusSettles(p, second), await focusAt(p))
  check('j: the focus steps to the row below', await press(p, 'j', third), await focusAt(p))
  check('k: back up to the closed note\'s row', await press(p, 'k', second), await focusAt(p))
  check('ArrowUp: the row above', await press(p, 'ArrowUp', first), await focusAt(p))
  check('ArrowDown: down again', await press(p, 'ArrowDown', second), await focusAt(p))
  await p.close()
}

/* opened by the + (New note): the focus does not go back to the + */
async function fromNew(browser, base) {
  const p = await openPage(browser, base)
  const before = await order(p)
  await p.click('[data-test=notes-new]')
  const made = await p.waitForFunction((before) => {
    const ids = [...document.querySelectorAll('[data-test=notes-row]')].map((e) => e.getAttribute('data-note-id'))
    return ids.find((id) => !before.includes(id)) || false
  }, { timeout: 15000 }, before).then((h) => h.jsonValue(), () => '')
  check('the + makes a note and opens it', Boolean(made) && await waitDetail(p, made), made)
  await typeInTitle(p, 'Escape test')
  await p.keyboard.press('Escape')
  check('Esc closes the new note', await waitGone(p))
  check('Esc: the focus is on the new note\'s row, not on the +', await focusSettles(p, made), await focusAt(p))
  const ids = await order(p)
  const below = ids[ids.indexOf(made) + 1] || ''
  const above = ids[ids.indexOf(made) - 1] || ''
  if (below) check('j: the row below the new note', await press(p, 'j', below), await focusAt(p))
  else check('k: the row above the new note', await press(p, 'k', above), await focusAt(p))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await fromRow(browser, server.base)
  await fromNew(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-escape-list-focus: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
