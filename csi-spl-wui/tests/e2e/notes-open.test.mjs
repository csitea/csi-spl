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
  const counted = await summary(p, 'mock-note-1')
  check(`${tag}: the list counts 4 links`, counted.link_count === 4, counted)
  await clickRow(p, 'mock-note-1')
  await waitDetail(p, 'mock-note-1')
  check(`${tag}: reopened, the note keeps the 4 links`, (await linkRows(p)).length === 4)
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
  await p.$eval('[data-test=note-body]', (e) => { e.focus(); e.select() })
  await p.type('[data-test=note-body]', 'Edited on a phone')
  await p.waitForSelector('[data-test=note-saving]', { hidden: true, timeout: 5000 }).catch(() => {})
  await sleep(1200)
  await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  check(`${tag}: Back closes it`, await waitGone(p))
  const text = (await summary(p, 'mock-note-2')).snippet
  check(`${tag}: the edit is saved (the list holds the new text)`, text === 'Edited on a phone', text)
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

/* SPL-4651: a row is one line, the title alone */
async function oneLine(browser, base, width, touch) {
  const tag = `${width}px one line`
  const p = await openPage(browser, base, width, touch)
  /* a phone's page slides in: measure the row once it has stopped */
  if (touch) await p.waitForFunction(() => Math.round(document.querySelector('[data-test=notes-page]').getBoundingClientRect().left) === 0, { timeout: 5000 })
  const long = 'A very long note title that goes on and on, '.repeat(8).trim()
  await p.evaluate((id, title) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').patch(id, { title }), 'mock-note-2', long)
  await p.waitForFunction((id, title) => document.querySelector(`[data-note-id="${id}"]`)?.textContent.trim() === title, { timeout: 5000 }, 'mock-note-2', long).catch(() => {})
  const shape = (id) => p.$eval(`[data-note-id="${id}"]`, (row) => {
    const t = row.querySelector('.notes-row__title')
    const css = getComputedStyle(t)
    const box = row.getBoundingClientRect()
    return {
      text: row.textContent.trim(),
      title: t.textContent.trim(),
      spans: row.querySelectorAll('[data-test=notes-open] *').length,
      previewOrMeta: Boolean(row.querySelector('[data-test=notes-row-text], .notes-row__text, .notes-row__meta')),
      lines: Math.round(t.getBoundingClientRect().height / parseFloat(css.lineHeight === 'normal' ? parseFloat(css.fontSize) * 1.2 : css.lineHeight)),
      cut: t.scrollWidth > t.clientWidth,
      ellipsis: css.textOverflow === 'ellipsis' && css.whiteSpace === 'nowrap',
      fits: box.right <= window.innerWidth + 1 && box.left >= -1,
    }
  })
  const longRow = await shape('mock-note-2')
  check(`${tag}: the row holds the title alone`, longRow.text === long && longRow.spans === 1 && !longRow.previewOrMeta, longRow)
  check(`${tag}: a long title stays on one line`, longRow.lines === 1, longRow.lines)
  check(`${tag}: it is cut with an ellipsis`, longRow.cut && longRow.ellipsis, longRow)
  check(`${tag}: inside the screen`, longRow.fits, longRow)
  const titled = await shape('mock-note-1')
  check(`${tag}: a note with text, a checklist and links shows only its title`, titled.text === 'Release checklist' && !titled.previewOrMeta, titled)
  const untitled = await shape('mock-note-3')
  check(`${tag}: an untitled note shows its first line and nothing more`, untitled.text === 'Call back about the invoice' && !untitled.previewOrMeta, untitled)
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-list-one-line-${width}.png` })
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
  await p.click('[data-test=notes-archived]')
  await sleep(300)
  const old = await shape('mock-note-4')
  check(`${tag}: the archived view has the same one line`, same(await rows(p), ['mock-note-4']) && old.text === 'Old plan' && !old.previewOrMeta, old)
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await oneLine(browser, server.base, 1440, false)
  await oneLine(browser, server.base, 390, true)
  await desktop(browser, server.base)
  await desktopActions(browser, server.base)
  await phone(browser, server.base)
  await links(browser, server.base, 1440, false)
  await links(browser, server.base, 390, true)
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
