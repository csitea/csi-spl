// Spec 155 B10 (SPL-4331): Settings -> Notes in a real browser, mock tenant
// signed in. The mock bundle keeps the notes in the notes store's memory
// (stores/notes.ts), so every step stays in one page: a reload would bring
// the four mock notes back.
//   C31-1 1440: ?settings=notes opens the section; the nav lists Notes, active,
//         or, while the Notes rail tab is off (NOTES_RAIL_ON), leaves it out
//   C31-2 Export hands the browser notes-<date>.json holding every note, the
//         archived one too (the file is read back from its object URL)
//   C31-3 CONTROL (the twin): a wrong word keeps Erase off; pressing Enter in
//         the box erases nothing (the list still holds 4 notes)
//   C31-4 the word "erase" turns Erase on; Erase says "All notes erased."
//   C31-5 the Notes list is empty after Erase (notes-empty, 0 rows)
//   U     SPL-4390: a note deleted on the Notes page and waiting on its real
//         Undo toast is erased too (the mock memory no longer holds it), and
//         when the toast then ends no note is DELETEd twice (one remove() per id)
//   P     390 px phone: the section opens full width, no sideways scroll,
//         every button and the word box >= 44 px tall, Erase works by touch
// Red control: on origin/master before B10 there is no such section: C31-1
// fails and the run stops.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/settings-notes.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { importTs } from '../unit/lib/load-ts.mjs'
/* spec 155 B10: the nav lists Notes only while its rail tab is on (NOTES_RAIL_ON) */
const { settingsSectionListed } = await importTs('src/utils/rail-order.ts')

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const results = []
const ok = (name, pass, ev) => {
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const PHONE = { name: '390', width: 390, height: 844, isMobile: true, hasTouch: true }
const SECTION = '[data-testid=ui-dialog] [data-test=snotes]'
const SETTINGS = '/channel/general?settings=notes'

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* opaque origin on the very first document */ }
    /* every <a download> click (utils/save-blob.ts): its name and href, no file written */
    window.__downloads = []
    const click = HTMLAnchorElement.prototype.click
    HTMLAnchorElement.prototype.click = function () {
      if (this.hasAttribute('download')) { window.__downloads.push({ name: this.download, href: this.href }); return }
      return click.call(this)
    }
  })

  const load = async (vp, path) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(400)
  }
  const shown = () => p.waitForSelector(SECTION, { visible: true, timeout: 15000 }).then(() => true, () => false)
  const has = (test) => p.evaluate((t) => {
    const e = document.querySelector(`[data-testid=ui-dialog] [data-test="${t}"]`)
    return Boolean(e && e.getBoundingClientRect().width > 0)
  }, test)
  const off = (test) => p.$eval(`[data-testid=ui-dialog] [data-test="${test}"]`, (e) => e.disabled).catch(() => null)
  const text = (test) => p.$eval(`[data-testid=ui-dialog] [data-test="${test}"]`, (e) => e.textContent.trim()).catch(() => '')
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-notes-${name}.png` }) }
  const store = () => p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
    return s ? { state: s.state, n: s.notes.length } : null
  })
  const typeWord = async (word) => {
    /* empty the box the way v-model hears it, then type like a person */
    await p.$eval(`${SECTION} [data-test=snotes-erase-word]`, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
    if (word) await p.type(`${SECTION} [data-test=snotes-erase-word]`, word)
    const now = await p.$eval(`${SECTION} [data-test=snotes-erase-word]`, (e) => e.value)
    if (now !== word) throw new Error(`the word box holds ${JSON.stringify(now)}, not ${JSON.stringify(word)}`)
  }
  const result = () => p.waitForSelector(`${SECTION} [data-test=snotes-result]`, { visible: true, timeout: 10000 }).then(() => text('snotes-result'), () => '')
  const toNotes = () => p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/notes'))

  /* C31-1 */
  await load(DESKTOP, SETTINGS)
  const open = await shown()
  ok('C31-1 ?settings=notes opens the section', open && await has('snotes-export') && await has('snotes-erase'))
  if (!open) throw new Error('no Settings -> Notes section: stop')
  if (settingsSectionListed('notes')) ok('C31-1 the nav lists Notes, active', await p.$eval('[data-test=settings-nav-notes]', (a) => a.getAttribute('aria-current') === 'page' && a.textContent.trim() === 'Notes').catch(() => false))
  else ok('C31-1 the nav leaves Notes out while its rail tab is off', !(await has('settings-nav-notes')) && await has('settings-nav-keys'))
  await shot('1440')

  /* C31-2 */
  await p.click(`${SECTION} [data-test=snotes-export]`)
  await p.waitForFunction(() => window.__downloads.length > 0, { timeout: 10000 }).catch(() => null)
  const file = await p.evaluate(async () => {
    const d = window.__downloads[0]
    if (!d) return null
    const body = JSON.parse(await (await fetch(d.href)).text())
    return { name: d.name, n: body.notes.length, archived: body.notes.filter((x) => x.archived).length, items: body.notes.some((x) => Array.isArray(x.items) && x.items.length), at: body.exported_at }
  })
  const today = new Date().toISOString().slice(0, 10)
  ok('C31-2 Export hands over notes-<date>.json', file && file.name === `notes-${today}.json`, file)
  ok('C31-2 it holds every note whole, the archived one too', file && file.n === 4 && file.archived === 1 && file.items && Boolean(file.at), file)

  /* C31-3 the twin: a wrong word erases nothing */
  ok('C31-3 CONTROL: Erase is off with no word', (await off('snotes-erase')) === true)
  await typeWord('delete')
  ok('C31-3 CONTROL: Erase stays off with a wrong word', (await off('snotes-erase')) === true)
  await p.keyboard.press('Enter')
  await sleep(600)
  const kept = await store()
  ok('C31-3 CONTROL: Enter with a wrong word erases nothing', kept && kept.n === 4 && !(await has('snotes-result')), kept)

  /* U: a note is deleted on the Notes page and waits on its real Undo toast
     (pages/notes.vue D2); Settings -> Notes opens over that page */
  await toNotes()
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: 15000 })
  const heldId = await p.$eval('[data-test=notes-row]', (e) => e.getAttribute('data-note-id')).catch(() => '')
  await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
    window.__removes = {}
    s.$onAction(({ name, args }) => { if (name === 'remove') window.__removes[args[0]] = (window.__removes[args[0]] || 0) + 1 })
  })
  await p.click(`[data-note-id="${heldId}"] [data-test=notes-open]`)
  await p.waitForSelector(`[data-test=note-detail][data-note-id="${heldId}"][data-state=ready]`, { visible: true, timeout: 15000 })
  await p.click('[data-test=note-delete]')
  const toast = await p.waitForSelector('[data-testid=notes-delete-toast]', { visible: true, timeout: 5000 }).then(() => true, () => false)
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/notes?settings=notes'))
  ok('U Delete on /notes holds the note on its Undo toast, Settings -> Notes opens over it', Boolean(heldId) && toast && await shown(), { heldId, toast })

  /* C31-4 */
  await typeWord('erase')
  ok('C31-4 the word turns Erase on', (await off('snotes-erase')) === false)
  await p.click(`${SECTION} [data-test=snotes-erase]`)
  const said = await result()
  ok('C31-4 Erase says all notes are erased', said === 'All notes erased.', { said })
  /* the toast ends (its Close; the dialog sits over it) */
  await p.evaluate(() => document.querySelector('[data-testid=notes-delete-toast-close]')?.click())
  await sleep(400)
  const undone = await p.evaluate(async (id) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
    const got = await s.get(id)
    return { held: s.hidden.length, n: s.notes.length, missing: Boolean(got && got.missing), removes: window.__removes }
  }, heldId)
  ok('U the note held for Undo is erased too', Boolean(heldId) && undone.held === 0 && undone.n === 0 && undone.missing, { heldId, undone })
  ok('U no note is DELETEd twice: the toast ending after Erase sends nothing', Object.keys(undone.removes).length === 4 && Object.values(undone.removes).every((c) => c === 1), undone.removes)
  ok('C31-4 the box is cleared, Erase off again', (await p.$eval(`${SECTION} [data-test=snotes-erase-word]`, (e) => e.value)) === '' && (await off('snotes-erase')) === true)

  /* C31-5 */
  await toNotes()
  const empty = await p.waitForSelector('[data-test=notes-empty]', { visible: true, timeout: 15000 }).then(() => true, () => false)
  const rows = await p.$$eval('[data-test=notes-row]', (els) => els.length)
  ok('C31-5 the Notes list is empty after Erase', empty && rows === 0, { empty, rows, store: await store() })

  /* P: phone 390, a fresh page: the mock notes are back */
  await load(PHONE, SETTINGS)
  ok('P1 390: the section opens', await shown())
  const phone = await p.evaluate(() => ({
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    short: [...document.querySelectorAll('[data-testid=ui-dialog] [data-test=snotes] button, [data-testid=ui-dialog] [data-test=snotes] input')]
      .filter((b) => b.getBoundingClientRect().width > 0 && b.getBoundingClientRect().height < 44).map((b) => b.dataset.test),
    wide: (() => { const e = document.querySelector('[data-testid=ui-dialog] [data-test=settings-notes]'); return e ? Math.round(e.getBoundingClientRect().width) : 0 })(),
  }))
  ok('P2 390: no sideways scroll, every button and the box >= 44 px', phone.over <= 0 && phone.short.length === 0 && phone.wide > 300, phone)
  await shot('390')
  await p.tap(`${SECTION} [data-test=snotes-erase-word]`)
  await p.type(`${SECTION} [data-test=snotes-erase-word]`, 'erase')
  await p.tap(`${SECTION} [data-test=snotes-erase]`)
  const phoneSaid = await result()
  const after = await store()
  ok('P3 390: Erase by touch empties the notes', phoneSaid === 'All notes erased.' && after && after.n === 0, { phoneSaid, after })

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
