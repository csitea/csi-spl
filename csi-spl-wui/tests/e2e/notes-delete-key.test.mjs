// Spec 155 2.10 (SPL-6542), on the mock bundle at 1440 px and at 390 px.
//
// Owner HUM-10 (t1 7a01494a, msg 3ece009b): "it should be possible to delete
// notes by having them selected and clicking the delete button the keyboard
// on the desktop wui".
//
// Cases:
//   K1 1440 px: Delete on a focused row takes it off the list at once, no
//      confirm, and shows the Undo snackbar; Undo brings it back and no
//      DELETE was sent (the same path as the row menu's Delete)
//   K2 Ctrl+click checks a row, Shift+click checks the run up to the row,
//      Shift+J checks the next row and moves to it: 3 rows checked, each
//      marked (data-checked, the selected fill and marker bar); Esc clears them
//   K3 Delete with 3 checked: all 3 go, ONE snackbar ("Notes deleted: 3"),
//      one Undo brings all 3 back, no DELETE sent; 2 deleted and the
//      snackbar closed, the 2 DELETEs go
//   K4 Delete / Backspace while typing in the filter box deletes nothing,
//      a row checked or not
//   K5 390 px: Delete on a focused row deletes nothing
// CONTROL: on origin/master (no row keydown for Delete, no selection) K1,
// K2 and K3 FAIL; with the `phone` guard taken out of onRowKey, K5 FAILs.
//
// Run:
//   node tests/e2e/notes-delete-key.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-delete-key.test.mjs
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
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const ALL = ['mock-note-1', 'mock-note-2', 'mock-note-3']

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const rows = (p) => p.$$eval('[data-test=notes-row]', (els) => els.map((e) => e.getAttribute('data-note-id')).sort())
const checked = (p) => p.$$eval('[data-test=notes-row][data-checked=true]', (els) => els.map((e) => e.getAttribute('data-note-id')).sort())
const openLink = (id) => `[data-note-id="${id}"] [data-test=notes-open]`
const focusRow = (p, id) => p.$eval(openLink(id), (a) => a.focus())
const ctrlClick = async (p, id) => {
  await p.keyboard.down('Control')
  await p.click(openLink(id))
  await p.keyboard.up('Control')
}
const countDeletes = (p) => p.evaluate(() => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  window.__noteDeletes = 0
  store.$onAction(({ name }) => { if (name === 'remove') window.__noteDeletes++ })
})
const deletes = (p) => p.evaluate(() => window.__noteDeletes)
const toast = (p) => p.waitForSelector('[data-testid=notes-delete-toast]', { visible: true, timeout: 3000 }).then(() => true, () => false)
const toastText = (p) => p.$eval('[data-testid=notes-delete-toast-text]', (e) => e.textContent.trim()).catch(() => '')
const noToast = async (p) => !(await p.$('[data-testid=notes-delete-toast]'))
/* each checked row's link carries the marker bar (an inset shadow) */
const bars = (p) => p.$$eval('[data-test=notes-row]', (els) => els.map((e) => [e.getAttribute('data-checked') === 'true', getComputedStyle(e.querySelector('[data-test=notes-open]')).boxShadow]))
const shot = (p, name) => (process.env.SHOT_DIR ? p.screenshot({ path: `${process.env.SHOT_DIR}/notes-delete-key-${name}.png` }) : null)
const noConfirm = async (p) => (await p.evaluate(() => window.__dialogs || 0)) === 0 && !(await p.$('[role=alertdialog]'))

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  p.on('dialog', (d) => { void p.evaluate(() => { window.__dialogs = (window.__dialogs || 0) + 1 }).catch(() => {}); void d.dismiss() })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  await countDeletes(p)
  return p
}

async function oneRow(p) {
  await focusRow(p, 'mock-note-2')
  await p.keyboard.press('Delete')
  await sleep(300)
  check('K1: Delete on a focused row asks no confirmation', await noConfirm(p))
  check('K1: the row leaves the list at once', same(await rows(p), ['mock-note-1', 'mock-note-3']), await rows(p))
  check('K1: the Undo snackbar shows', await toast(p))
  check('K1: it says "Note deleted"', (await toastText(p)) === 'Note deleted', await toastText(p))
  await p.click('[data-testid=notes-delete-toast-undo]').catch(() => {})
  await sleep(400)
  check('K1: Undo brings it back', same(await rows(p), ALL), await rows(p))
  check('K1: and no DELETE was sent', (await deletes(p)) === 0, await deletes(p))
}

async function select(p) {
  await ctrlClick(p, 'mock-note-1')
  await sleep(150)
  check('K2: Ctrl+click checks the row and opens nothing', same(await checked(p), ['mock-note-1']) && !(await p.$('[data-test=note-detail]')), await checked(p))
  await p.keyboard.press('Escape')
  await sleep(150)
  check('K2: Esc clears the checked rows', same(await checked(p), []), await checked(p))
  await ctrlClick(p, 'mock-note-1')
  await p.keyboard.down('Shift')
  await p.click(openLink('mock-note-2'))
  await p.keyboard.up('Shift')
  await sleep(150)
  check('K2: Shift+click checks the run to the row', same(await checked(p), ['mock-note-1', 'mock-note-2']), await checked(p))
  await focusRow(p, 'mock-note-2')
  await p.keyboard.down('Shift')
  await p.keyboard.press('J')
  await p.keyboard.up('Shift')
  await sleep(150)
  check('K2: Shift+J checks the next row too', same(await checked(p), ALL), await checked(p))
  const focused = await p.evaluate(() => document.activeElement?.closest('[data-test=notes-row]')?.getAttribute('data-note-id') || '')
  check('K2: and the focus moves to it', focused === 'mock-note-3', focused)
  const b = await bars(p)
  check('K2: each checked row is marked (the bar)', b.length === 3 && b.every(([on, sh]) => on && sh.includes('inset')), b)
}

async function threeRows(p) {
  await p.keyboard.press('Delete')
  await sleep(300)
  await shot(p, 'deleted')
  check('K3: Delete with 3 checked takes all 3 off the list', same(await rows(p), []), await rows(p))
  check('K3: one Undo snackbar', (await toast(p)) && (await p.$$('[data-testid=notes-delete-toast]')).length === 1)
  check('K3: it says "Notes deleted: 3"', (await toastText(p)) === 'Notes deleted: 3', await toastText(p))
  await p.click('[data-testid=notes-delete-toast-undo]').catch(() => {})
  await sleep(400)
  await shot(p, 'undone')
  check('K3: one Undo brings all 3 back', same(await rows(p), ALL), await rows(p))
  check('K3: and no DELETE was sent', (await deletes(p)) === 0, await deletes(p))
  check('K3: nothing stays checked', same(await checked(p), []), await checked(p))
  await ctrlClick(p, 'mock-note-1')
  await ctrlClick(p, 'mock-note-3')
  await focusRow(p, 'mock-note-3')
  await p.keyboard.press('Delete')
  await sleep(300)
  check('K3: Delete with 2 checked takes those 2', same(await rows(p), ['mock-note-2']), await rows(p))
  await p.click('[data-testid=notes-delete-toast-close]').catch(() => {})
  await sleep(400)
  check('K3: the snackbar closed, both DELETEs go', (await deletes(p)) === 2, await deletes(p))
}

async function typing(p) {
  await ctrlClick(p, 'mock-note-2')
  await p.click('[data-test=notes-filter]')
  await p.keyboard.type('Ide')
  await p.keyboard.press('Backspace')
  await p.keyboard.press('Delete')
  await sleep(300)
  const q = await p.$eval('[data-test=notes-filter]', (e) => e.value)
  check('K4: Backspace / Delete in the filter box edit the filter', q === 'Id', q)
  check('K4: and delete no note', (await noToast(p)) && same(await rows(p), ['mock-note-2']), await rows(p))
}

async function phone(browser, base) {
  const p = await openPage(browser, base, 390, true)
  await focusRow(p, 'mock-note-2')
  await p.keyboard.press('Delete')
  await sleep(300)
  check('K5 390px: Delete on a focused row deletes nothing', (await noToast(p)) && same(await rows(p), ALL), await rows(p))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await openPage(browser, server.base, 1440, false)
  await oneRow(p)
  await select(p)
  await shot(p, 'selected')
  await threeRows(p)
  await typing(p)
  await p.close()
  await phone(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-delete-key: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
