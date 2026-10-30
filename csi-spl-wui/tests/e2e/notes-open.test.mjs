// Spec 155 row B6 (SPL-4186): the open note, on the mock bundle.
//
// Owner HUM-10 (prd t1 topic cb9d7bdc, msg cc1a052f): "I cannot edit notes
// on mobile." (msg cb6d4ba3): "It should be possible to create, update, and
// delete them from the UI. Add: archive them as well." Before B6 a row linked
// to /notes?note=<id> and nothing opened it, on any width.
//
// Cases (spec 155 section 7):
//   C20 a click opens the note, a reload of /notes?note=<id> reopens it, Back
//       closes it; an unknown id shows "Note not found"
//   C21 Delete, then Undo within 10 s: no DELETE sent, the note stays; no
//       Undo: one DELETE (counted as calls of the store's `remove`, the one
//       place that sends it; the mock bundle has no hub to count requests at)
//   C22 Pin moves the note into the Pinned group
// plus the owner's report at a 390 px phone: open full screen with Back, edit,
// archive, delete; and the order (Alt+Down) and the checklist on a desktop.
//
// Row B7 (SPL-4330), the links, at 1440 px and at 390 px: a url link opens in
// a new tab with rel="noopener noreferrer" (C25, as served); a pasted
// topic:<uuid> and SPL-12 become a topic and an issue link of this workspace
// that open in this tab (C23); "hello" is "Not a link"; a remove takes one
// link off and the list row's count follows.
//
// Run:
//   node tests/e2e/notes-open.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-open.test.mjs
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
const rows = (p, group = '') => p.$$eval(`${group ? `[data-test=notes-group-${group}] ` : ''}[data-test=notes-row]`, (els) => els.map((e) => e.getAttribute('data-note-id')))
const noteQuery = (p) => p.evaluate(() => new URL(location.href).searchParams.get('note') || '')
const detail = (p) => p.$('[data-test=note-detail][data-state=ready]')
const waitDetail = (p, id) => p.waitForSelector(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
const waitGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).then(() => true, () => false)
/* a reload of the list as the page does on window focus (2.1) */
const refetch = async (p) => { await p.evaluate(() => window.dispatchEvent(new Event('focus'))); await sleep(400) }
/* every call of the store's remove(), the one place that sends DELETE */
const countDeletes = (p) => p.evaluate(() => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  window.__noteDeletes = 0
  store.$onAction(({ name }) => { if (name === 'remove') window.__noteDeletes++ })
})
const deletes = (p) => p.evaluate(() => window.__noteDeletes)

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  await countDeletes(p)
  return p
}
const clickRow = (p, id) => p.click(`[data-note-id="${id}"] [data-test=notes-open]`)

async function desktop(browser, base) {
  const tag = '1440px'
  const p = await openPage(browser, base, 1440, false)
  await clickRow(p, 'mock-note-2')
  check(`${tag} C20: a click opens the note`, await waitDetail(p, 'mock-note-2'))
  check(`${tag}: it is a modal above 820 px`, await p.$eval('[data-test=note-detail]', (e) => e.getAttribute('data-modal') === 'true' && Boolean(e.closest('[role=dialog]'))))
  check(`${tag} C20: the address holds ?note=<id>`, (await noteQuery(p)) === 'mock-note-2', await noteQuery(p))
  await p.goBack()
  check(`${tag} C20: browser Back closes it`, await waitGone(p))
  check(`${tag} C20: and drops ?note=`, (await noteQuery(p)) === '', await noteQuery(p))
  await p.goto(`${base}/notes?note=mock-note-1`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  check(`${tag} C20: a load of /notes?note=<id> opens it`, await waitDetail(p, 'mock-note-1'))
  check(`${tag}: the title is in the editor`, (await p.$eval('[data-test=note-title]', (e) => e.value)) === 'Release checklist')
  check(`${tag}: the checklist shows its 5 lines, 2 ticked`, same(await p.$$eval('[data-test=note-item]', (els) => [els.length, els.filter((e) => e.dataset.done === 'true').length]), [5, 2]))
  await p.click('[data-test=note-item]:nth-child(3) [data-test=note-item-tick]')
  await p.type('[data-test=note-item-new]', 'Tag the release')
  await p.click('[data-test=note-item-add]')
  await sleep(600)
  const meta = await p.$eval('[data-note-id=mock-note-1] .notes-row__meta', (e) => e.textContent)
  check(`${tag}: a tick and an added line are saved (the row reads 3/6)`, meta.includes('3/6'), meta)
  await p.keyboard.press('Escape')
  check(`${tag}: Esc closes it`, await waitGone(p))
  await p.goto(`${base}/notes?note=no-such-note`, { waitUntil: 'networkidle2', timeout: NAV })
  const nf = await p.waitForSelector('[data-test=note-not-found]', { visible: true, timeout: 15000 }).then((e) => e.evaluate((x) => x.textContent.trim()), () => '')
  check(`${tag} C20 twin: an unknown id shows "Note not found"`, nf === 'Note not found', nf)
  await p.close()
}

const linkRows = (p) => p.$$eval('[data-test=note-link]', (els) => els.map((e) => {
  const a = e.querySelector('[data-test=note-link-open]')
  return { kind: e.dataset.kind, href: a?.getAttribute('href') || '', target: a?.getAttribute('target') || '', rel: a?.getAttribute('rel') || '', text: (a || e).textContent.trim() }
}))
const TOPIC = '0b7f2c3e-1d2a-4b5c-8d9e-0f1a2b3c4d5e'
async function paste(p, text) {
  await p.$eval('[data-test=note-link-new]', (e) => { e.focus(); e.select() })
  await p.type('[data-test=note-link-new]', text)
  await p.click('[data-test=note-link-add]')
  await sleep(400)
}

/* B7: the links of mock-note-1 (3 url links), add, refuse, remove */
async function links(browser, base, width, touch) {
  const tag = `${width}px B7`
  const p = await openPage(browser, base, width, touch)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  const first = await linkRows(p)
  check(`${tag}: the note shows its 3 links`, first.length === 3, first.length)
  check(`${tag} C25: a url link opens in a new tab, rel="noopener noreferrer"`, first[0]?.kind === 'url' && first[0].href === 'https://example.com/1' && first[0].target === '_blank' && first[0].rel === 'noopener noreferrer', first[0])
  await paste(p, 'hello')
  const err = await p.$eval('[data-test=note-link-error]', (e) => e.textContent.trim()).catch(() => '')
  check(`${tag} C23: "hello" is refused as Not a link`, err === 'Not a link' && (await linkRows(p)).length === 3, err)
  await paste(p, `topic:${TOPIC}`)
  const topic = (await linkRows(p))[3]
  check(`${tag} C23: topic:<uuid> becomes a topic link that opens /t/<uuid> in this tab`, topic?.kind === 'topic' && topic.href.endsWith(`/t/${TOPIC}`) && !topic.target, topic)
  check(`${tag}: the error went with the good paste`, !(await p.$('[data-test=note-link-error]')))
  await paste(p, 'SPL-12')
  const issue = (await linkRows(p))[4]
  check(`${tag} C23: SPL-12 becomes an issue link`, issue?.kind === 'issue' && issue.href.endsWith('/issues?issue=SPL-12') && issue.text === 'SPL-12', issue)
  if (touch) {
    const tap = await p.$eval('[data-test=note-link-remove]', (e) => { const r = e.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)] })
    check(`${tag}: the remove x is a 44 px tap target`, tap[0] >= 44 && tap[1] >= 44, tap)
    check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-links-390.png` })
  }
  await p.click('[data-test=note-link]:first-child [data-test=note-link-remove]')
  await sleep(400)
  const left = await linkRows(p)
  check(`${tag}: remove takes that one link off`, left.length === 4 && left[0].href === 'https://example.com/2', left.map((l) => l.href))
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  await waitGone(p)
  const meta = await p.$eval('[data-note-id=mock-note-1] .notes-row__meta', (e) => e.textContent).catch(() => '')
  check(`${tag}: the list row counts 4 links`, meta.includes('Links: 4'), meta)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  check(`${tag}: reopened, the note keeps the 4 links`, (await linkRows(p)).length === 4)
  await p.close()
}

async function desktopActions(browser, base) {
  const tag = '1440px'
  const p = await openPage(browser, base, 1440, false)
  check(`${tag}: the rest starts in its own order`, same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), await rows(p, 'rest'))
  await p.focus('[data-note-id=mock-note-2] [data-test=notes-open]')
  await p.keyboard.down('Alt')
  await p.keyboard.press('ArrowDown')
  await p.keyboard.up('Alt')
  await sleep(300)
  check(`${tag}: Alt+Down moves a note one place down`, same(await rows(p, 'rest'), ['mock-note-3', 'mock-note-2']), await rows(p, 'rest'))
  await clickRow(p, 'mock-note-2')
  await waitDetail(p, 'mock-note-2')
  await p.click('[data-test=note-pin]')
  await sleep(300)
  check(`${tag} C22: Pin moves it to the Pinned group`, (await rows(p, 'pinned')).includes('mock-note-2'), await rows(p, 'pinned'))
  await p.click('[data-test=note-delete]')
  check(`${tag}: Delete closes the note`, await waitGone(p))
  check(`${tag}: the toast says Note deleted`, (await p.$eval('[data-testid=notes-delete-toast-text]', (e) => e.textContent.trim()).catch(() => '')) === 'Note deleted')
  check(`${tag}: the note is off the list at once`, !(await rows(p)).includes('mock-note-2'))
  await p.click('[data-testid=notes-delete-toast-undo]')
  await sleep(300)
  await refetch(p)
  check(`${tag} C21: Undo puts the note back`, (await rows(p)).includes('mock-note-2'), await rows(p))
  check(`${tag} C21: after Undo no DELETE was sent`, (await deletes(p)) === 0, await deletes(p))
  await clickRow(p, 'mock-note-2')
  await waitDetail(p, 'mock-note-2')
  await p.click('[data-test=note-delete]')
  await waitGone(p)
  await p.waitForFunction(() => !document.querySelector('[data-testid=notes-delete-toast]'), { timeout: 20000 }).catch(() => {})
  await refetch(p)
  check(`${tag} C21 twin: no Undo -> one DELETE when the toast ends`, (await deletes(p)) === 1, await deletes(p))
  check(`${tag} C21 twin: the note stays gone after a reload of the list`, !(await rows(p)).includes('mock-note-2'), await rows(p))
  await p.close()
}

/* the owner's report: at 390 px open a note, edit it, archive it, delete it */
async function phone(browser, base) {
  const tag = '390px'
  const p = await openPage(browser, base, 390, true)
  await clickRow(p, 'mock-note-2')
  check(`${tag}: a tap opens the note`, await waitDetail(p, 'mock-note-2'))
  const box = await p.$eval('[data-test=note-detail]', (e) => {
    const r = e.closest('.note-detail').getBoundingClientRect()
    return { modal: e.getAttribute('data-modal'), w: Math.round(r.width), vw: window.innerWidth, dialog: Boolean(e.closest('[role=dialog]')) }
  })
  check(`${tag}: full screen, not a modal`, box.modal === 'false' && !box.dialog && box.w === box.vw, box)
  check(`${tag}: it has a Back control`, Boolean(await p.$('[data-test=note-detail] [data-testid=mobile-back]')))
  await p.$eval('[data-test=note-body]', (e) => { e.focus(); e.select() })
  await p.type('[data-test=note-body]', 'Edited on a phone')
  await p.waitForSelector('[data-test=note-saving]', { hidden: true, timeout: 5000 }).catch(() => {})
  await sleep(1200)
  await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  check(`${tag}: Back closes it`, await waitGone(p))
  const text = await p.$eval('[data-note-id=mock-note-2] [data-test=notes-row-text]', (e) => e.textContent.trim()).catch(() => '')
  check(`${tag}: the edit is saved (the row shows the new text)`, text === 'Edited on a phone', text)
  await clickRow(p, 'mock-note-2')
  check(`${tag}: it opens again with the edit`, (await waitDetail(p, 'mock-note-2')) && (await p.$eval('[data-test=note-body]', (e) => e.value)) === 'Edited on a phone')
  await p.click('[data-test=note-archive]')
  check(`${tag}: Archive closes the note`, await waitGone(p))
  check(`${tag}: the archived note leaves the list`, !(await rows(p)).includes('mock-note-2'), await rows(p))
  await p.click('[data-test=notes-archived]')
  await sleep(300)
  check(`${tag}: Archived shows it`, (await rows(p)).includes('mock-note-2'), await rows(p))
  await clickRow(p, 'mock-note-2')
  await waitDetail(p, 'mock-note-2')
  check(`${tag}: its button reads Unarchive`, (await p.$eval('[data-test=note-archive]', (e) => e.getAttribute('aria-label'))) === 'Unarchive')
  await p.click('[data-test=note-delete]')
  check(`${tag}: Delete closes it`, await waitGone(p))
  check(`${tag}: the Undo toast shows`, Boolean(await p.waitForSelector('[data-testid=notes-delete-toast]', { visible: true, timeout: 5000 }).catch(() => null)))
  await p.click('[data-testid=notes-delete-toast-close]')
  await sleep(400)
  await refetch(p)
  check(`${tag}: closing the toast sends the one DELETE`, (await deletes(p)) === 1, await deletes(p))
  check(`${tag}: the note is gone`, !(await rows(p)).includes('mock-note-2'), await rows(p))
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-open-390.png` })
  await p.goto(`${base}/notes?note=mock-note-1`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  check(`${tag} C20: a load of /notes?note=<id> opens it full screen`, await waitDetail(p, 'mock-note-1'))
  await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  check(`${tag} C20: Back from the deep link closes it`, await waitGone(p))
  check(`${tag}: and the list is on screen`, Boolean(await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: 5000 }).catch(() => null)))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await desktop(browser, server.base)
  await desktopActions(browser, server.base)
  await phone(browser, server.base)
  await links(browser, server.base, 1440, false)
  await links(browser, server.base, 390, true)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-open: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
