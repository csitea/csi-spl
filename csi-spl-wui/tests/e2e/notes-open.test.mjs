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
// a new tab with rel="noopener noreferrer" (C25, as served); a remove takes
// one link off and the list row's count follows. SPL-4893 (owner t1 ba784026,
// msg a9f94922): the stored links are a compact list with no heading and no
// paste box (a link typed in the text is linked there, notes-design.test.mjs
// editor()); a note with no links shows no links section.
// SPL-5005: the no-links check reads only once mock-note-3 is up and ready, and
// says so; a wait that timed out used to fall through to it. CONTROL: with the
// click on mock-note-3 taken out, the absence check alone stays OK on an empty
// page, and "the note with no links opens" FAILS. A click on a row while the
// Esc's Back is still under way opens that note and keeps it (history.go held by
// the test). CONTROL: with open() not waiting for that Back
// (composables/useNoteOpen.ts), the checks of clickDuringBack() FAIL.
// Esc before the open's ?note= push commits (the router held by the test) stays
// closed, on the entry it was opened from. CONTROL: with close() not cancelling
// the push (composables/useNoteOpen.ts), the checks of escDuringPush() FAIL.
//
// Row B9 (SPL-4579), C29: `/note Plan` typed in the Omnibox over an open
// issue (390 px, the dock under the issue) makes a note "Plan" whose one link
// is that issue; at 1440 px an open issue is a modal over the Omnibox, so the
// same line runs over an open topic (?topic=<id>) and links that topic. The
// toast says "Note created" and its Open opens the note. Twin: the same line
// on a page that shows no object (/notes) makes a note with no link.
//
// SPL-4651 (owner HUM-10, t1 2a0b4d9e, msg a4c630a8: "only the titles should
// be visible in the listings"): a row is one line, the title alone, cut with an
// ellipsis at 1440 px and 390 px; drag, the current-row mark and the archived
// view still work. CONTROL: with the text and meta spans back in the row, or
// white-space: nowrap off the title, the checks of oneLine() FAIL.
//
// SPL-4652 (spec 155 2.9, the same owner msg: "notes should have priority"): the
// row shows the priority beside the title, 5 when nobody set one, and stays one
// line at 1440 px and 390 px; the chooser in the open note saves at once, and
// within a group the list orders by priority, 1 first. CONTROL: with the chip
// out of the row, or with compareNotes not reading the priority, the checks of
// notePriorityCase() FAIL.
//
// SPL-4701, D8 (owner HUM-10, msg 63fe839e: "Move it there and take that
// note's priority"): a P5 note dragged onto a P2 note lands in the P2 run as a
// P2, and stays so after the list is read again from the hub; Alt+Up past a
// neighbour of another priority does the same, and the open note's chooser
// follows a Move. Owner msg 1ae7a7f0: dragged up, the number gets smaller;
// dragged down onto a bigger one, it takes that. Owner msg ada4a8ff: within one
// priority the dragged order (the stored position) wins and is kept.
// N2: at dir=rtl the chip keeps its gap to the title.
// CONTROL: with the D8 rule out of note-order.mjs (a drop on another priority
// moves nothing), or margin-left back on the chip, the checks of d8Case() FAIL.
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

/* SPL-4893: a note with text opens in View; its Wiki code button shows the
   raw text box */
async function bodySource(p) {
  if ((await p.$eval('[data-test=note-editor]', (e) => e.dataset.mode)) === 'view') await p.click('[data-test=note-ed-mode]')
  await p.waitForSelector('[data-test=note-body]', { visible: true, timeout: 5000 })
}

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
/* what the list holds for a note: since SPL-4651 its row shows the title only */
const summary = (p, id) => p.evaluate((id) => JSON.stringify(document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').notes.find((n) => n.id === id)), id).then((n) => JSON.parse(n))

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
  const counts = await summary(p, 'mock-note-1')
  check(`${tag}: a tick and an added line are saved (the list holds 3/6)`, counts.items_done === 3 && counts.items_total === 6, counts)
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

/* B7: the links of mock-note-1 (3 url links), compact, remove */
async function links(browser, base, width, touch) {
  const tag = `${width}px B7`
  const p = await openPage(browser, base, width, touch)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  const first = await linkRows(p)
  check(`${tag}: the note shows its 3 links`, first.length === 3, first.length)
  check(`${tag} C25: a url link opens in a new tab, rel="noopener noreferrer"`, first[0]?.kind === 'url' && first[0].href === 'https://example.com/1' && first[0].target === '_blank' && first[0].rel === 'noopener noreferrer', first[0])
  const compact = await p.$eval('[data-test=note-links]', (e) => ({ head: !!e.querySelector('h3'), paste: !!e.querySelector('[data-test=note-link-new], form') }))
  check(`${tag} SPL-4893: the links are a compact list, no heading, no paste box`, !compact.head && !compact.paste, compact)
  if (touch) {
    const tap = await p.$eval('[data-test=note-link-remove]', (e) => { const r = e.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)] })
    check(`${tag}: the remove x is a 44 px tap target`, tap[0] >= 44 && tap[1] >= 44, tap)
    check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-links-390.png` })
  }
  await p.click('[data-test=note-link]:first-child [data-test=note-link-remove]')
  await sleep(400)
  const left = await linkRows(p)
  check(`${tag}: remove takes that one link off`, left.length === 2 && left[0].href === 'https://example.com/2', left.map((l) => l.href))
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  await waitGone(p)
  const counted = await summary(p, 'mock-note-1')
  check(`${tag}: the list counts 2 links`, counted.link_count === 2, counted)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  check(`${tag}: reopened, the note keeps the 2 links`, (await linkRows(p)).length === 2)
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  check(`${tag}: closed again, no note is up`, await waitGone(p))
  await clickRow(p, 'mock-note-3')
  check(`${tag} SPL-4893: the note with no links opens`, await waitDetail(p, 'mock-note-3'))
  /* which note is up and the url say whose links these are when it fails */
  const noLinks = await p.evaluate(() => ({ section: !!document.querySelector('[data-test=note-links]'), note: document.querySelector('[data-test=note-detail]')?.dataset.noteId || '', url: location.search }))
  check(`${tag} SPL-4893: a note with no links shows no links section`, !noLinks.section, noLinks)
  await p.close()
}

/* SPL-4893 (wf 10 run 42338524374): the mock note is ready before the push
   commits, and an Esc in that gap had the commit open the note again */
async function escDuringPush(browser, base) {
  const tag = '1440px SPL-4893 Esc during the push'
  const p = await openPage(browser, base, 1440, false)
  const entries = await p.evaluate(() => history.length)
  /* holds every navigation until the test lets it go, so no timing decides this */
  await p.evaluate(() => {
    window.__hold = true
    document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.beforeEach(() => (window.__hold ? new Promise((r) => { window.__let = r }) : undefined))
  })
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  check(`${tag}: the note is up before ?note= is written`, (await noteQuery(p)) === '')
  await p.keyboard.press('Escape')
  check(`${tag}: Esc closes it`, await waitGone(p))
  await p.evaluate(() => { window.__hold = false; window.__let?.() })
  await sleep(500)
  check(`${tag}: it stays closed once the push is let go`, !(await p.$('[data-test=note-detail]')))
  check(`${tag}: the url has no ?note=`, (await noteQuery(p)) === '')
  check(`${tag}: no history entry was left behind`, (await p.evaluate(() => history.length)) === entries)
  await clickRow(p, 'mock-note-3')
  check(`${tag}: the next note opens`, await waitDetail(p, 'mock-note-3'))
  await p.close()
}

/* SPL-5005: Esc on a pushed note is a router.back(), and a row clicked before it
   lands had its push cancelled by that Back: the clicked note closed itself */
async function clickDuringBack(browser, base, id) {
  const tag = `1440px SPL-5005 click ${id} during the Back`
  const p = await openPage(browser, base, 1440, false)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  await p.waitForFunction(() => new URL(location.href).searchParams.get('note') === 'mock-note-1', { timeout: 15000 })
  /* holds the Back itself, so no timing decides this */
  await p.evaluate(() => { const go = history.go.bind(history); history.go = (n) => { setTimeout(() => go(n), 400) } })
  await p.keyboard.press('Escape')
  check(`${tag}: Esc closes it`, await waitGone(p))
  await clickRow(p, id)
  check(`${tag}: the clicked note opens`, await waitDetail(p, id))
  await sleep(1000)
  check(`${tag}: it is still up once the Back landed`, Boolean(await p.$(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`)))
  check(`${tag}: the address holds its ?note=`, (await noteQuery(p)) === id, await noteQuery(p))
  await p.evaluate(() => { delete history.go })
  await p.goBack()
  check(`${tag}: browser Back closes it`, await waitGone(p))
  check(`${tag}: and drops ?note=`, (await noteQuery(p)) === '', await noteQuery(p))
  await widthDuringBack(p, tag, id)
  await p.close()
}

/* SPL-5005 (W1): the window narrows to a phone while the Back is under way. Its
   landing there has to end the wait: else, back on desktop, no row wrote ?note=
   again until a reload. Every history.go is held until the test lets it go */
async function widthDuringBack(p, tag, id) {
  const hold = () => p.evaluate(() => { const go = history.go.bind(history); window.__gos = []; history.go = (n) => { window.__gos.push(() => go(n)) } })
  const land = async () => {
    await p.setViewport({ width: 390, height: 900 })
    await p.evaluate(() => { delete history.go; for (const g of window.__gos) g() })
    await sleep(1000)
  }
  const upWithQuery = async (note) => {
    await clickRow(p, note)
    await waitDetail(p, note)
    await p.waitForFunction((n) => new URL(location.href).searchParams.get('note') === n, { timeout: 15000 }, note)
  }
  await upWithQuery('mock-note-1')
  await hold()
  await p.keyboard.press('Escape')
  await waitGone(p)
  await land()
  check(`${tag}: narrowed during the Back: no note is up`, !(await p.$('[data-test=note-detail]')))
  await p.setViewport({ width: 1440, height: 900 })
  await clickRow(p, id)
  check(`${tag}: back on desktop the next row opens`, await waitDetail(p, id))
  await sleep(500)
  check(`${tag}: and writes its ?note=`, (await noteQuery(p)) === id, await noteQuery(p))
  await p.keyboard.press('Escape')
  await waitGone(p)
  await sleep(500)
  await upWithQuery('mock-note-1')
  await hold()
  await p.keyboard.press('Escape')
  await waitGone(p)
  await clickRow(p, id)
  await waitDetail(p, id)
  await land()
  check(`${tag}: a row clicked before narrowing is dropped on the phone`, !(await p.$('[data-test=note-detail]')))
  check(`${tag}: and the url has no ?note=`, (await noteQuery(p)) === '', await noteQuery(p))
}

/* SPL-5005: a second Esc while that Back is under way drops the queued note */
async function escDuringBack(browser, base) {
  const tag = '1440px SPL-5005 Esc again during the Back'
  const p = await openPage(browser, base, 1440, false)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  await p.waitForFunction(() => new URL(location.href).searchParams.get('note') === 'mock-note-1', { timeout: 15000 })
  await p.evaluate(() => { const go = history.go.bind(history); history.go = (n) => { setTimeout(() => go(n), 400) } })
  await p.keyboard.press('Escape')
  await waitGone(p)
  await clickRow(p, 'mock-note-3')
  await waitDetail(p, 'mock-note-3')
  await p.keyboard.press('Escape')
  check(`${tag}: Esc closes it`, await waitGone(p))
  await sleep(1000)
  check(`${tag}: nothing opens when the Back lands`, !(await p.$('[data-test=note-detail]')))
  check(`${tag}: the url has no ?note=`, (await noteQuery(p)) === '', await noteQuery(p))
  await p.close()
}

/* B9: the Omnibox, docked at the bottom on a phone, is the same form */
const OMNI = 'form.composer.omnibox--global'
async function omniNote(p, text) {
  await p.focus(`${OMNI} textarea`)
  await p.type(`${OMNI} textarea`, text)
  await p.click(`${OMNI} [data-testid=send]`)
  const toast = await p.waitForSelector('[data-testid=omnibox-note-toast]', { visible: true, timeout: 10000 }).then(() => true, () => false)
  const said = toast ? await p.$eval('[data-testid=omnibox-note-toast-text]', (e) => e.textContent.trim()) : ''
  const box = await p.$eval(`${OMNI} textarea`, (e) => e.value)
  return { toast, said, box }
}

/* the mock tenant has no issues: make one and leave it open (?issue=<KEY>) */
async function openNewIssue(p, title) {
  await p.click('[data-test=issues-new]')
  let key
  if (await p.evaluate(() => window.innerWidth > 820)) {
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    key = await p.waitForFunction((want) => {
      const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
      return r ? r.getAttribute('data-key') : false
    }, { timeout: 5000 }, title).then((h) => h.jsonValue())
    await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  } else {
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-title]', title)
    await p.click('[data-test=issues-create]')
    await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 8000 })
    key = await p.$eval('[data-test=issues-detail-key]', (e) => e.textContent.trim())
  }
  await p.waitForFunction((k) => new URL(location.href).searchParams.get('issue') === k, { timeout: 8000 }, key).catch(() => {})
  await sleep(400)
  return key
}

/* the page's object: a new open issue on a phone, the first card's topic above 820 px */
async function openObject(p, touch) {
  if (touch) {
    await go(p, '/issues')
    await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    const key = await openNewIssue(p, 'B9 issue')
    return { kind: 'issue', tail: `/issues?issue=${key}` }
  }
  await p.waitForSelector('article.msg', { visible: true, timeout: NAV })
  await p.click('article.msg')
  const topic = await p.waitForFunction(() => new URL(location.href).searchParams.get('topic'), { timeout: 10000 }).then((h) => h.jsonValue())
  return { kind: 'topic', tail: `/t/${topic}` }
}

/* B9 C29: /note Plan over the page's object; twin: over /notes, no link */
async function omnibox(browser, base, width, touch) {
  const tag = `${width}px B9`
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  const obj = await openObject(p, touch)
  const made = await omniNote(p, '/note Plan')
  check(`${tag} C29: /note Plan says "Note created"`, made.toast && made.said === 'Note created', made)
  check(`${tag}: the Omnibox is empty after it`, made.box === '', made.box)
  check(`${tag}: nothing was posted`, !(await p.$$eval('[data-test=issues-comment], article.msg', (els) => els.some((e) => e.innerText.includes('/note')))))
  if (touch) {
    const tap = await p.$eval('[data-testid=omnibox-note-toast-undo]', (e) => { const r = e.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)] })
    check(`${tag}: Open is a 44 px tap target`, tap[0] >= 44 && tap[1] >= 44, tap)
    check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-omnibox-390.png` })
  }
  await p.click('[data-testid=omnibox-note-toast-undo]')
  const id = await p.waitForFunction(() => location.pathname.endsWith('/notes') && new URL(location.href).searchParams.get('note'), { timeout: 10000 }).then((h) => h.jsonValue(), () => '')
  check(`${tag} C29: Open opens the new note`, Boolean(id) && (await waitDetail(p, id)), id)
  check(`${tag} C29: its title is "Plan"`, (await p.$eval('[data-test=note-title]', (e) => e.value).catch(() => '')) === 'Plan')
  const ls = await linkRows(p)
  check(`${tag} C29: its one link is the open ${obj.kind}`, ls.length === 1 && ls[0].kind === obj.kind && ls[0].href.endsWith(obj.tail), { obj, ls })
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  await waitGone(p)
  const twin = await omniNote(p, '/note Loose')
  await p.click('[data-testid=omnibox-note-toast-undo]').catch(() => {})
  const id2 = await p.waitForFunction((was) => { const n = new URL(location.href).searchParams.get('note'); return n && n !== was ? n : false }, { timeout: 10000 }, id).then((h) => h.jsonValue(), () => '')
  const twinOk = twin.toast && Boolean(id2) && (await waitDetail(p, id2)) && (await p.$eval('[data-test=note-title]', (e) => e.value)) === 'Loose'
  check(`${tag} C29 twin: on /notes (no object) the note has no link`, twinOk && (await linkRows(p)).length === 0, { twin, id2 })
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
  await bodySource(p)
  await p.$eval('[data-test=note-body]', (e) => { e.focus(); e.select() })
  await p.type('[data-test=note-body]', 'Edited on a phone')
  await p.waitForSelector('[data-test=note-saving]', { hidden: true, timeout: 5000 }).catch(() => {})
  await sleep(1200)
  await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  check(`${tag}: Back closes it`, await waitGone(p))
  const text = (await summary(p, 'mock-note-2')).snippet
  check(`${tag}: the edit is saved (the list holds the new text)`, text === 'Edited on a phone', text)
  await clickRow(p, 'mock-note-2')
  const again = await waitDetail(p, 'mock-note-2')
  await bodySource(p)
  check(`${tag}: it opens again with the edit`, again && (await p.$eval('[data-test=note-body]', (e) => e.value)) === 'Edited on a phone')
  await p.click('[data-test=note-archive]')
  check(`${tag}: Archive closes the note`, await waitGone(p))
  check(`${tag}: the archived note leaves the list`, !(await rows(p)).includes('mock-note-2'), await rows(p))
  /* SPL-4897: an archived note is seen in the Archive section, not behind a Notes switch */
  await go(p, '/archive')
  await p.waitForSelector('[data-test=archive-note-row][data-note-id="mock-note-2"]', { visible: true, timeout: 15000 }).catch(() => null)
  check(`${tag}: the Archive shows it`, Boolean(await p.$('[data-test=archive-note-row][data-note-id="mock-note-2"]')))
  await p.click('[data-test=archive-note-row][data-note-id="mock-note-2"] [data-test=archive-note-open]')
  await waitDetail(p, 'mock-note-2')
  check(`${tag}: its button reads Unarchive`, (await p.$eval('[data-test=note-archive]', (e) => e.getAttribute('aria-label'))) === 'Unarchive')
  await p.click('[data-test=note-delete]')
  check(`${tag}: Delete closes it`, await waitGone(p))
  check(`${tag}: the Undo toast shows`, Boolean(await p.waitForSelector('[data-testid=notes-delete-toast]', { visible: true, timeout: 5000 }).catch(() => null)))
  await p.click('[data-testid=notes-delete-toast-close]')
  await sleep(400)
  await refetch(p)
  check(`${tag}: closing the toast sends the one DELETE`, (await deletes(p)) === 1, await deletes(p))
  check(`${tag}: the note is gone`, !(await rows(p)).includes('mock-note-2') && !(await p.$('[data-test=archive-note-row][data-note-id="mock-note-2"]')), await rows(p))
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

/* SPL-4651: a row is one line, the title alone */
async function oneLine(browser, base, width, touch) {
  const tag = `${width}px one line`
  const p = await openPage(browser, base, width, touch)
  /* a phone's page slides in: measure the row once it has stopped */
  if (touch) await p.waitForFunction(() => Math.round(document.querySelector('[data-test=notes-page]').getBoundingClientRect().left) === 0, { timeout: 5000 })
  const long = 'A very long note title that goes on and on, '.repeat(8).trim()
  await p.evaluate((id, title) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').patch(id, { title }), 'mock-note-2', long)
  await p.waitForFunction((id, title) => document.querySelector(`[data-note-id="${id}"] .notes-row__title`)?.textContent.trim() === title, { timeout: 5000 }, 'mock-note-2', long).catch(() => {})
  const shape = (id) => p.$eval(`[data-note-id="${id}"]`, (row) => {
    const t = row.querySelector('.notes-row__title')
    const css = getComputedStyle(t)
    const box = row.getBoundingClientRect()
    return {
      text: t.textContent.trim(),
      prio: row.querySelector('[data-test=notes-row-priority]')?.textContent.trim(),
      prioInLine: (() => { const c = row.querySelector('[data-test=notes-row-priority]')?.getBoundingClientRect(); return Boolean(c) && c.left >= t.getBoundingClientRect().right && c.right <= window.innerWidth + 1 && c.top < t.getBoundingClientRect().bottom && c.bottom > t.getBoundingClientRect().top })(),
      prioShown: (() => { const c = row.querySelector('[data-test=notes-row-priority]'); return Boolean(c) && c.getClientRects().length > 0 })(),
      spans: row.querySelectorAll('[data-test=notes-open] *').length,
      previewOrMeta: Boolean(row.querySelector('[data-test=notes-row-text], .notes-row__text, .notes-row__meta')),
      lines: Math.round(t.getBoundingClientRect().height / parseFloat(css.lineHeight === 'normal' ? parseFloat(css.fontSize) * 1.2 : css.lineHeight)),
      cut: t.scrollWidth > t.clientWidth,
      ellipsis: css.textOverflow === 'ellipsis' && css.whiteSpace === 'nowrap',
      fits: box.right <= window.innerWidth + 1 && box.left >= -1,
    }
  })
  const longRow = await shape('mock-note-2')
  check(`${tag}: the row holds the title and its priority, nothing more`, longRow.text === long && longRow.spans === 2 && longRow.prio === 'P5' && !longRow.previewOrMeta, longRow)
  /* SPL-4893 (owner t1 2f4311d9, poll 1de5c599 PH): a phone shows no P1..P5 */
  if (touch) check(`${tag}: a phone shows no priority chip`, !longRow.prioShown, longRow)
  else check(`${tag}: the priority sits beside the cut title, on the one line`, longRow.prioInLine, longRow)
  check(`${tag}: a long title stays on one line`, longRow.lines === 1, longRow.lines)
  check(`${tag}: it is cut with an ellipsis`, longRow.cut && longRow.ellipsis, longRow)
  check(`${tag}: inside the screen`, longRow.fits, longRow)
  const titled = await shape('mock-note-1')
  check(`${tag}: a note with text, a checklist and links shows only its title`, titled.text === 'Release checklist' && !titled.previewOrMeta, titled)
  const untitled = await shape('mock-note-3')
  check(`${tag}: an untitled note shows its first line and nothing more`, untitled.text === 'Call back about the invoice' && !untitled.previewOrMeta, untitled)
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-list-one-line-${width}.png` })
  if (touch) {
    /* the smallest font level: only the floor keeps the one line row tappable */
    const heights = await p.evaluate(() => {
      const root = document.documentElement
      const level = root.dataset.fontSize
      root.dataset.fontSize = '1'
      const h = [...document.querySelectorAll('[data-test=notes-open]')].map((e) => e.getBoundingClientRect().height)
      if (level === undefined) delete root.dataset.fontSize
      else root.dataset.fontSize = level
      return h
    })
    check(`${tag}: every row is 44 px tall or more at the smallest font`, heights.length > 0 && heights.every((h) => h >= 44), heights)
  }
  if (!touch) {
    const before = await rows(p)
    await p.evaluate(() => {
      const row = (id) => document.querySelector(`[data-note-id="${id}"]`)
      const dataTransfer = new DataTransfer()
      const fire = (el, type) => el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer }))
      fire(row('mock-note-3'), 'dragstart')
      fire(row('mock-note-2'), 'dragover')
      fire(row('mock-note-2'), 'drop')
      fire(row('mock-note-3'), 'dragend')
    })
    await sleep(300)
    check(`${tag}: a drag still reorders`, same(await rows(p), ['mock-note-1', 'mock-note-3', 'mock-note-2']), { before, after: await rows(p) })
  }
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  check(`${tag}: the open note's row keeps the current mark`, (await p.$eval('[data-note-id=mock-note-1] [data-test=notes-open]', (e) => e.getAttribute('aria-current'))) === 'true')
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  await waitGone(p)
  check(`${tag}: the list has no archived note and no Archived switch (SPL-4897)`, !(await rows(p)).includes('mock-note-4') && !(await p.$('[data-test=notes-archived]')), await rows(p))
  await p.close()
}

/* SPL-4652: the chooser in the open note, the chip on the row and the list order */
async function notePriorityCase(browser, base, width, touch) {
  const tag = `${width}px priority`
  const p = await openPage(browser, base, width, touch)
  const chip = (id) => p.$eval(`[data-note-id="${id}"] [data-test=notes-row-priority]`, (e) => e.textContent.trim())
  const closeNote = async () => {
    if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
    else await p.keyboard.press('Escape')
    await waitGone(p)
  }
  const stored = (id) => summary(p, id).then((n) => n.priority)
  check(`${tag}: a note nobody set reads P5`, (await chip('mock-note-3')) === 'P5' && (await stored('mock-note-3')) === 5)
  check(`${tag}: same priority, the own order`, same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), await rows(p, 'rest'))
  await clickRow(p, 'mock-note-3')
  await waitDetail(p, 'mock-note-3')
  check(`${tag}: the chooser shows the note's 5`, await p.$eval('[data-test=note-priority-5]', (e) => e.checked))
  check(`${tag}: it offers 1..5`, same(await p.$$eval('[data-test=note-priority] input[type=radio]', (els) => els.map((e) => e.value)), ['1', '2', '3', '4', '5']))
  if (touch) {
    const tap = await p.$eval('[data-test=note-priority-1]', (e) => { const r = e.closest('label').getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)] })
    check(`${tag}: a level is a 44 px tap target`, tap[0] >= 44 && tap[1] >= 44, tap)
    check(`${tag}: the open note has no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  }
  await p.click('[data-test=note-priority-1]')
  await p.waitForFunction(() => document.querySelector('[data-test=note-priority]')?.getAttribute('data-priority') === '1', { timeout: 5000 }).catch(() => {})
  check(`${tag}: a click checks 1`, await p.$eval('[data-test=note-priority-1]', (e) => e.checked))
  check(`${tag}: the store holds 1`, (await stored('mock-note-3')) === 1, await stored('mock-note-3'))
  await closeNote()
  check(`${tag}: the row follows, P1`, (await chip('mock-note-3')) === 'P1', await chip('mock-note-3'))
  check(`${tag}: the 1 goes above the 5 in its group`, same(await rows(p, 'rest'), ['mock-note-3', 'mock-note-2']), await rows(p, 'rest'))
  check(`${tag}: pinned stays first, P5 above the P1`, same(await rows(p), ['mock-note-1', 'mock-note-3', 'mock-note-2']), await rows(p))
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-list-priority-${width}.png` })
  await p.close()
}

/* D8 (SPL-4701): a drag or Move onto another priority takes that priority; N2 the chip gap at dir=rtl */
async function d8Case(browser, base) {
  const tag = '1440px D8'
  const p = await openPage(browser, base, 1440, false)
  const chip = (id) => p.$eval(`[data-note-id="${id}"] [data-test=notes-row-priority]`, (e) => e.textContent.trim())
  const stored = (id) => summary(p, id).then((n) => n.priority)
  const setPriority = (id, priority) => p.evaluate((id, priority) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').patch(id, { priority }), id, priority)
  const drag = (from, to) => p.evaluate((from, to) => {
    const row = (id) => document.querySelector(`[data-note-id="${id}"]`)
    const dataTransfer = new DataTransfer()
    const fire = (el, type) => el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer }))
    fire(row(from), 'dragstart')
    fire(row(to), 'dragover')
    fire(row(to), 'drop')
    fire(row(from), 'dragend')
  }, from, to)
  const altUp = async (id) => {
    await p.focus(`[data-note-id="${id}"] [data-test=notes-open]`)
    await p.keyboard.down('Alt')
    await p.keyboard.press('ArrowUp')
    await p.keyboard.up('Alt')
    await sleep(300)
  }
  const gap = () => p.$eval('[data-note-id=mock-note-2]', (row) => {
    const t = row.querySelector('.notes-row__title').getBoundingClientRect()
    const c = row.querySelector('[data-test=notes-row-priority]').getBoundingClientRect()
    return Math.round(document.documentElement.dir === 'rtl' ? t.left - c.right : c.left - t.right)
  })

  check(`${tag} N2: ltr, 8 px between the title and its chip`, (await gap()) === 8, await gap())
  await p.evaluate(() => { document.documentElement.dir = 'rtl' })
  await sleep(100)
  check(`${tag} N2: rtl, the same 8 px`, (await gap()) === 8, await gap())
  await p.evaluate(() => { document.documentElement.dir = 'ltr' })

  await setPriority('mock-note-3', 2)
  await sleep(200)
  check(`${tag}: the P2 note is drawn above the P5`, same(await rows(p, 'rest'), ['mock-note-3', 'mock-note-2']) && (await chip('mock-note-2')) === 'P5', await rows(p, 'rest'))
  await drag('mock-note-2', 'mock-note-3')
  await sleep(300)
  check(`${tag}: a P5 dropped on a P2 becomes P2`, (await chip('mock-note-2')) === 'P2' && (await stored('mock-note-2')) === 2, await chip('mock-note-2'))
  check(`${tag}: it lands in the P2 run, before the note it was dropped on`, same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), await rows(p, 'rest'))
  await refetch(p)
  check(`${tag}: after the list is read again, still P2 in the P2 run`, (await chip('mock-note-2')) === 'P2' && same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), [await chip('mock-note-2'), await rows(p, 'rest')])

  await setPriority('mock-note-2', 5)
  await sleep(200)
  check(`${tag}: twin, back to P5 below the P2`, same(await rows(p, 'rest'), ['mock-note-3', 'mock-note-2']), await rows(p, 'rest'))
  await altUp('mock-note-2')
  check(`${tag}: Alt+Up past the P2 makes it a P2 above it`, (await chip('mock-note-2')) === 'P2' && same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), [await chip('mock-note-2'), await rows(p, 'rest')])
  await refetch(p)
  check(`${tag}: Alt+Up kept after the list is read again`, (await stored('mock-note-2')) === 2 && same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), await rows(p, 'rest'))

  await setPriority('mock-note-3', 1)
  await sleep(200)
  await clickRow(p, 'mock-note-2')
  await waitDetail(p, 'mock-note-2')
  await p.click('[data-test=note-up]')
  await p.waitForFunction(() => document.querySelector('[data-test=note-priority]')?.getAttribute('data-priority') === '1', { timeout: 5000 }).catch(() => {})
  check(`${tag}: Move up in the open note takes the P1, and its chooser shows 1`, (await stored('mock-note-2')) === 1 && (await p.$eval('[data-test=note-priority-1]', (e) => e.checked)), await stored('mock-note-2'))
  await p.keyboard.press('Escape')
  await waitGone(p)

  /* owner msg ada4a8ff: within one priority the dragged order wins (position, stored by the hub) */
  check(`${tag}: two P1 notes, mock-note-3 the lower`, same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']) && (await chip('mock-note-3')) === 'P1', await rows(p, 'rest'))
  await drag('mock-note-3', 'mock-note-2')
  await sleep(300)
  await refetch(p)
  check(`${tag}: the lower P1 dragged to the top stays on top after the list is read again`, same(await rows(p, 'rest'), ['mock-note-3', 'mock-note-2']) && (await chip('mock-note-3')) === 'P1', await rows(p, 'rest'))

  /* owner msg 1ae7a7f0 mirrored: dragged down onto a bigger number, it takes the bigger number */
  await setPriority('mock-note-2', 4)
  await sleep(200)
  await drag('mock-note-3', 'mock-note-2')
  await sleep(300)
  await refetch(p)
  check(`${tag}: a P1 dragged down onto a P4 becomes P4, below it`, (await chip('mock-note-3')) === 'P4' && same(await rows(p, 'rest'), ['mock-note-2', 'mock-note-3']), [await chip('mock-note-3'), await rows(p, 'rest')])
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await oneLine(browser, server.base, 1440, false)
  await oneLine(browser, server.base, 390, true)
  await notePriorityCase(browser, server.base, 1440, false)
  await notePriorityCase(browser, server.base, 390, true)
  await d8Case(browser, server.base)
  await desktop(browser, server.base)
  await desktopActions(browser, server.base)
  await phone(browser, server.base)
  await links(browser, server.base, 1440, false)
  await links(browser, server.base, 390, true)
  await escDuringPush(browser, server.base)
  await clickDuringBack(browser, server.base, 'mock-note-3')
  await clickDuringBack(browser, server.base, 'mock-note-1')
  await escDuringBack(browser, server.base)
  await omnibox(browser, server.base, 1440, false)
  await omnibox(browser, server.base, 390, true)
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
