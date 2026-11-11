// Spec 155 2.10 (SPL-5255), on the mock bundle at 1440 px and at 390 px.
//
// Owner HUM-10 (t1 b7eb7c9a, 2026-11-10): "Each of the notes should have a
// right-click menu button so that one could archive the note, delete it, or
// turn it into a discussion." Then (msgs 79092e0b + ac509205): "No need to
// have a confirmation for the delete or archive." "Just the small undo snack
// bar at the bottom of mobile and at the top of the desktop".
//
// Cases:
//   M1 1440 px: a right-click on a list row opens the note menu with Archive,
//      Turn into a discussion and Delete, in that order
//   M2 Archive acts at once (no confirm: no dialog event, no alertdialog), the
//      row leaves the list, the snackbar sits at the TOP on a desktop and at
//      the BOTTOM on a phone; Undo puts the note back, not archived
//   M3 Delete acts at once (no confirm), the snackbar sits as in M2; Undo puts
//      the note back and no DELETE was sent (the store's remove() never ran)
//   M4 Turn into a discussion: a new topic in the lobby whose first post is
//      the note's text; the note stays in the list and gains a topic link to
//      it; the snackbar's Open goes to /t/<that topic>
//   M5 the open note: its More button (and, at 1440 px, a right-click on the
//      note outside its text boxes) opens the same menu; Archive from there
//      closes the note and shows the snackbar
//   M6 390 px: the row's menu button (a phone has no right-click) opens the
//      menu as a sheet; Archive, Delete and Undo as in M2, M3
// CONTROL: with `flip` taken off the notes' UndoSnackbar (pages/notes.vue),
// the placement checks of M2/M3 FAIL at both widths; with the row's
// @contextmenu taken out, M1 FAILs.
//
// Run:
//   node tests/e2e/notes-menu.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-menu.test.mjs
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

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const rows = (p) => p.$$eval('[data-test=notes-row]', (els) => els.map((e) => e.getAttribute('data-note-id')))
const waitDetail = (p, id) => p.waitForSelector(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
const waitGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).then(() => true, () => false)
const MENU = '[data-testid=note-actions-menu]'
const menuIds = (p) => p.$$eval(`${MENU} [role=menuitem]`, (els) => els.map((e) => e.getAttribute('data-testid').replace('note-actions-menu-', '')))
const waitMenu = (p) => p.waitForSelector(MENU, { visible: true, timeout: 5000 }).then(() => true, () => false)
const pick = async (p, id) => { await p.click(`${MENU} [data-testid=note-actions-menu-${id}]`); await sleep(300) }
/* what the store holds for a note */
const summary = (p, id) => p.evaluate((id) => JSON.stringify(document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').notes.find((n) => n.id === id) || null), id).then((n) => JSON.parse(n))
const countDeletes = (p) => p.evaluate(() => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  window.__noteDeletes = 0
  store.$onAction(({ name }) => { if (name === 'remove') window.__noteDeletes++ })
})
const deletes = (p) => p.evaluate(() => window.__noteDeletes)
/* where a snackbar sits: its middle above or below the middle of the window */
const toastAt = (p, testid) => p.waitForSelector(`[data-testid=${testid}]`, { visible: true, timeout: 5000 })
  .then((el) => el.evaluate((e) => { const r = e.getBoundingClientRect(); return (r.top + r.bottom) / 2 < window.innerHeight / 2 ? 'top' : 'bottom' }), () => 'none')
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

/* the row's menu: a right-click on a desktop, the menu button on a phone */
async function rowMenu(p, id, touch) {
  if (touch) await p.click(`[data-note-id="${id}"] [data-test=notes-row-menu]`)
  else await p.click(`[data-note-id="${id}"] [data-test=notes-open]`, { button: 'right' })
  return waitMenu(p)
}

async function archiveAndDelete(p, tag, touch) {
  const want = touch ? 'bottom' : 'top'
  check(`${tag} M1: the row's ${touch ? 'menu button' : 'right-click'} opens the note menu`, await rowMenu(p, 'mock-note-2', touch))
  check(`${tag} M1: Archive, Turn into a discussion, Delete`, same(await menuIds(p), ['archive', 'discuss', 'delete']), await menuIds(p))
  await pick(p, 'archive')
  check(`${tag} M2: Archive asks no confirmation`, await noConfirm(p))
  check(`${tag} M2: the note leaves the list at once`, !(await rows(p)).includes('mock-note-2'), await rows(p))
  check(`${tag} M2: the Undo snackbar sits at the ${want}`, (await toastAt(p, 'notes-archive-toast')) === want, await toastAt(p, 'notes-archive-toast'))
  await p.click('[data-testid=notes-archive-toast-undo]')
  await sleep(400)
  check(`${tag} M2: Undo puts it back, not archived`, (await rows(p)).includes('mock-note-2') && (await summary(p, 'mock-note-2'))?.archived === false, await summary(p, 'mock-note-2'))

  await rowMenu(p, 'mock-note-3', touch)
  await pick(p, 'delete')
  check(`${tag} M3: Delete asks no confirmation`, await noConfirm(p))
  check(`${tag} M3: the note leaves the list at once`, !(await rows(p)).includes('mock-note-3'), await rows(p))
  check(`${tag} M3: the Undo snackbar sits at the ${want}`, (await toastAt(p, 'notes-delete-toast')) === want, await toastAt(p, 'notes-delete-toast'))
  await p.click('[data-testid=notes-delete-toast-undo]')
  await sleep(400)
  check(`${tag} M3: Undo puts it back`, (await rows(p)).includes('mock-note-3'), await rows(p))
  check(`${tag} M3: and no DELETE was sent`, (await deletes(p)) === 0, await deletes(p))
}

async function discuss(p, tag, touch) {
  const before = (await summary(p, 'mock-note-1')).link_count
  await rowMenu(p, 'mock-note-1', touch)
  await pick(p, 'discuss')
  check(`${tag} M4: the snackbar says the discussion started`, (await toastAt(p, 'notes-discuss-toast')) !== 'none')
  const n = await summary(p, 'mock-note-1')
  check(`${tag} M4: the note stays in the list, not archived`, (await rows(p)).includes('mock-note-1') && n.archived === false, n)
  check(`${tag} M4: the note gains one link`, n.link_count === before + 1, [before, n.link_count])
  const link = await p.evaluate(async () => {
    const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
    const got = await store.get('mock-note-1')
    return got.note ? got.note.links.at(-1) : null
  })
  check(`${tag} M4: a topic link labelled with the note's title`, link?.kind === 'topic' && link?.label === 'Release checklist' && Boolean(link?.ref), link)
  await p.click('[data-testid=notes-discuss-toast-undo]')
  await p.waitForFunction((id) => location.pathname.endsWith('/t/' + id), { timeout: 15000 }, link?.ref || 'none').catch(() => {})
  const path = await p.evaluate(() => location.pathname)
  check(`${tag} M4: Open goes to that topic`, Boolean(link?.ref) && path.endsWith('/t/' + link.ref), path)
  const shown = await p.waitForFunction(() => document.body.innerText.includes('Tests green'), { timeout: 15000 }).then(() => true, () => false)
  check(`${tag} M4: its first post holds the note's text and checklist`, shown)
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
}

async function openView(p, tag, touch) {
  await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
  await waitDetail(p, 'mock-note-2')
  if (!touch) {
    /* the note's own padding: not a text box, not a link */
    await p.click('[data-test=note-detail]', { button: 'right', offset: { x: 4, y: 4 } }).catch(() => {})
    await sleep(200)
    const viaRight = await waitMenu(p)
    check(`${tag} M5: a right-click on the open note opens its menu`, viaRight && same(await menuIds(p), ['archive', 'discuss', 'delete']), await menuIds(p).catch(() => []))
    await p.keyboard.press('Escape')
    await sleep(200)
  }
  await p.click('[data-test=note-menu]')
  check(`${tag} M5: the open note's More button opens its menu`, await waitMenu(p))
  await pick(p, 'archive')
  check(`${tag} M5: Archive from the open note closes it`, await waitGone(p))
  check(`${tag} M5: asks no confirmation and shows the snackbar at the ${touch ? 'bottom' : 'top'}`, (await noConfirm(p)) && (await toastAt(p, 'notes-archive-toast')) === (touch ? 'bottom' : 'top'))
  await p.click('[data-testid=notes-archive-toast-undo]')
  await sleep(400)
  check(`${tag} M5: Undo puts it back`, (await rows(p)).includes('mock-note-2'), await rows(p))
}

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await openPage(browser, base, width, touch)
  await archiveAndDelete(p, tag, touch)
  await openView(p, tag, touch)
  await discuss(p, tag, touch)
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-menu-${width}.png` })
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
console.log(`\nnotes-menu: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
