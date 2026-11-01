// Spec 155 row B8 (SPL-4578): "Add to note" everywhere and the note picker,
// on the mock bundle, at 1440 px and at a 390 px phone.
//
// Owner HUM-10 (prd t1 topic 5586fe0e, msg 6aae6e3e): "one will be able to
// quickly link anything within the system to the notes". Default D3: "Add to
// note" opens a picker of the person's notes, latest first, with New note on
// top; one click adds the link and the toast says "Added to <title>".
//
// Cases (spec 155 section 7):
//   C26 the message menu has "Add to note"; Shift + N on the selected
//       message opens the picker (desktop)
//   C27 "Add to note" on a topic card, an issue (its row menu and the open
//       issue's button), a calendar entry and a channel row: pick a note, the
//       note gains a link of that kind and workspace, labelled by the
//       object's title; twin: New note makes a note holding that one link
//   section 6 / B8: with the notes off (the hub's 404 notes_off, read by the
//       store as `off`) the items hide
// The links are read back through the notes store's own get(), the one
// place the note page reads them from (the mock bundle has no hub).
//
// Red control: against a bundle of master before B8 every "Add to note"
// check FAILs (no msg-menu-add-to-note, no issues-detail-note, ...).
//
// Run:
//   BASE_URL=http://127.0.0.1:4321 node tests/e2e/add-to-note.test.mjs
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
const WS = 't1'

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const visible = (p, sel, timeout = 15000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true, () => false)
const gone = (p, sel, timeout = 5000) => p.waitForFunction((s) => !document.querySelector(s), { timeout }, sel).then(() => true, () => false)
const clickSel = (p, sel) => p.evaluate((s) => { const el = document.querySelector(s); el?.click(); return Boolean(el) }, sel)

/* a note's links, read through the notes store (the mock answers from memory) */
const linksOf = (p, id) => p.evaluate(async (id) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  if (!store) return null
  const got = await store.get(id)
  return got.note ? got.note.links.map((l) => ({ kind: l.kind, ws: l.workspace_id || '', ref: l.ref, day: l.day || '', label: l.label })) : null
}, id)
const lastLink = async (p, id) => (await linksOf(p, id) || []).at(-1) || null
const noteIds = (p) => p.evaluate(() => (document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')?.notes || []).map((n) => n.id))

/* the picker is up and listed the notes; pick one, wait for the toast */
async function pickNote(p, id) {
  const up = await visible(p, '[data-test=note-picker][data-state=ready] [data-test=note-picker-row]')
  if (!up) return { up, toast: '' }
  await p.click(`[data-test=note-picker-row][data-note-id="${id}"]`)
  const toast = await p.waitForSelector('[data-testid=note-added-text]', { visible: true, timeout: 10000 }).then((e) => e.evaluate((x) => x.textContent.trim()), () => '')
  await gone(p, '[data-test=note-picker]')
  return { up, toast }
}

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  return p
}

/* the #alerts card of the mock: `/` renders the lobby card first, so a bare
   article.msg right after go() can still be the lobby's, unmounted under the
   click by the route change (1440 px flake, 2026-11-01) */
const ALERTS_CARD = 'article.msg[data-msg-id="66666666-6666-4666-8666-666666666666"]'

const menuIds = (p, sel) => p.$$eval(`${sel} [role=menuitem]`, (els) => els.map((e) => e.getAttribute('data-testid')))

/* C26 + C27: a topic card's menu in a channel */
async function messageMenu(browser, base, width, touch) {
  const tag = `${width}px message`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/channel/alerts')
  await visible(p, ALERTS_CARD)
  const card = await p.evaluate((sel) => {
    const a = document.querySelector(sel)
    return a ? { id: a.getAttribute('data-msg-id') || '', text: a.querySelector('.msg-body, .body, [data-testid=msg-body]')?.textContent?.trim() || '' } : null
  }, ALERTS_CARD)
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), ALERTS_CARD)
  await visible(p, '[data-testid=msg-menu]')
  const items = await menuIds(p, '[data-testid=msg-menu]')
  check(`${tag} C26: the menu has Add to note`, items.includes('msg-menu-add-to-note'), items)
  await clickSel(p, '[data-testid=msg-menu-add-to-note]')
  const { up, toast } = await pickNote(p, 'mock-note-2')
  check(`${tag} C27: the picker opens and lists the notes`, up)
  check(`${tag} C27: the toast says "Added to Ideas"`, toast === 'Added to Ideas', toast)
  const link = await lastLink(p, 'mock-note-2')
  check(`${tag} C27: a topic card adds its topic, of this workspace, labelled`, link?.kind === 'topic' && link.ws === WS && link.ref.length > 0 && link.label.length > 0, { link, card })
  await p.close()
}

/* C26: Shift + N on the selected message; twin of C27: New note holds that one link */
async function shiftN(browser, base) {
  const tag = '1440px Shift+N'
  const p = await openPage(browser, base, 1440, false)
  await go(p, '/channel/alerts')
  await visible(p, ALERTS_CARD)
  await p.focus(ALERTS_CARD)
  await p.keyboard.down('Shift')
  await p.keyboard.press('KeyN')
  await p.keyboard.up('Shift')
  const up = await visible(p, '[data-test=note-picker][data-state=ready]')
  check(`${tag} C26: Shift + N opens the picker`, up)
  const before = await noteIds(p)
  await clickSel(p, '[data-test=note-picker-new]')
  const toast = await p.waitForSelector('[data-testid=note-added-text]', { visible: true, timeout: 10000 }).then((e) => e.evaluate((x) => x.textContent.trim()), () => '')
  const after = await noteIds(p)
  const fresh = after.find((id) => !before.includes(id)) || ''
  const links = fresh ? await linksOf(p, fresh) : null
  check(`${tag} C27 twin: New note makes one note`, Boolean(fresh) && after.length === before.length + 1, { before: before.length, after: after.length })
  check(`${tag} C27 twin: holding that one link`, links?.length === 1 && links[0].ws === WS && ['topic', 'msg'].includes(links[0].kind), links)
  check(`${tag} C27 twin: titled by the link's label`, toast === `Added to ${links?.[0]?.label}`, toast)
  await clickSel(p, '[data-testid=note-added-undo]')
  check(`${tag}: Open on the toast opens the new note`, await visible(p, `[data-test=note-detail][data-note-id="${fresh}"]`))
  /* Shift + N is a desktop key: the menu is the phone's way (messageMenu at 390 px) */
  await p.close()
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

/* the open issue's Add to note (the visible one: the dialog's tools or the phone's top bar) */
async function detailNote(p, tag, noteId, title, key) {
  const btns = await p.$$eval('[data-test=issues-detail-actions]', (groups) => {
    const g = groups.find((e) => e.offsetParent)
    return g ? [...g.querySelectorAll('button')].map((b) => b.getAttribute('data-test')) : []
  })
  const at = btns.indexOf('issues-detail-note')
  check(`${tag} C27: the open issue has Add to note, right before Archive`, at >= 0 && btns[at + 1] === 'issues-detail-archive', btns)
  await p.evaluate(() => [...document.querySelectorAll('[data-test=issues-detail-note]')].find((e) => e.offsetParent)?.click())
  const { up, toast } = await pickNote(p, noteId)
  check(`${tag} C27: the picker opens from the open issue`, up)
  check(`${tag} C27: the toast says "Added to ${title}"`, toast === `Added to ${title}`, toast)
  const link = await lastLink(p, noteId)
  check(`${tag} C27: the note gains that issue, labelled by its title`, link?.kind === 'issue' && link.ws === WS && link.ref === key && link.label === 'Fix the login', link)
}

/* C27: an issue, from its row menu and from the open issue's button (1440 px, then the same page at 390 px) */
async function issues(browser, base) {
  const tag = '1440px issue'
  const p = await openPage(browser, base, 1440, false)
  await go(p, '/issues')
  await visible(p, '[data-test=issues-page]')
  const key = await newIssue(p, 'Fix the login')
  const row = `[data-test=issues-row][data-key="${key}"]`
  const box = await p.$eval(row, (el) => { const b = el.getBoundingClientRect(); return { x: b.x + Math.min(40, b.width / 2), y: b.y + b.height / 2 } })
  await p.mouse.click(box.x, box.y, { button: 'right' })
  await visible(p, '[data-test=issues-ctxmenu]')
  const items = await p.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test')))
  const at = items.indexOf('issues-ctxmenu-add-to-note')
  check(`${tag} C27: the row menu has Add to note, right before Archive`, at >= 0 && items[at + 1] === 'issues-ctxmenu-archive', items)
  await clickSel(p, '[data-test=issues-ctxmenu-add-to-note]')
  const { up, toast } = await pickNote(p, 'mock-note-3')
  check(`${tag} C27: the picker opens from the row menu`, up)
  check(`${tag} C27: the toast names the note (no title: its first line)`, toast === 'Added to Call back about the invoice', toast)
  const link = await lastLink(p, 'mock-note-3')
  check(`${tag} C27: the note gains the issue, of this workspace, labelled by its title`, link?.kind === 'issue' && link.ws === WS && link.ref === key && link.label === 'Fix the login', { link, key })
  await go(p, `/issues?issue=${key}`)
  await visible(p, '[data-test=issues-detail]')
  await detailNote(p, tag, 'mock-note-1', 'Release checklist', key)
  /* a phone width: the open issue's top bar */
  await p.setViewport({ width: 390, height: 844 })
  await sleep(600)
  await detailNote(p, '390px issue', 'mock-note-2', 'Ideas', key)
  await p.close()
}

/* C27: a calendar entry */
async function calendar(browser, base, width, touch) {
  const tag = `${width}px calendar`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/calendar')
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV }).catch(() => {})
  /* the week's entry (the phone's week list) */
  const sel = touch ? '[data-test=calweek-event]' : '[data-test=calendar-item]'
  await visible(p, sel)
  const item = await p.evaluate((sel) => {
    const li = [...document.querySelectorAll(sel)].find((e) => e.getAttribute('data-source') !== 'issue' && e.offsetParent)
    if (!li) return null
    li.click()
    return { id: li.getAttribute('data-id') || '' }
  }, sel)
  /* a desktop: the pop-over's Edit, then the entry dialog's button; a phone: the peek's own */
  if (!touch) {
    await visible(p, '[data-test=calendar-popover-edit]', 5000)
    await clickSel(p, '[data-test=calendar-popover-edit]')
  }
  const add = touch ? '[data-test=calpeek-add-to-note]' : '[data-test=calendar-event-add-to-note]'
  check(`${tag} C27: ${touch ? 'the entry\'s peek' : 'a stored entry\'s dialog'} has Add to note`, await visible(p, add), item)
  await clickSel(p, add)
  const { up, toast } = await pickNote(p, 'mock-note-2')
  check(`${tag} C27: the picker opens over the entry`, up)
  check(`${tag} C27: the toast says "Added to Ideas"`, toast === 'Added to Ideas', toast)
  const link = await lastLink(p, 'mock-note-2')
  check(`${tag} C27: the note gains the entry with its day, labelled`, link?.kind === 'event' && link.ws === WS && (!item?.id || link.ref === item.id) && /^\d{4}-\d{2}-\d{2}$/.test(link.day) && link.label.length > 0, { link, item })
  await p.close()
}

/* C27: a channel row's menu in the sidebar */
async function channelRow(browser, base, width, touch) {
  const tag = `${width}px channel`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/channel/alerts')
  await visible(p, '[data-testid=sidebar-row-menu][data-menu-id^="ch:"]')
  await sleep(1500)
  const menuId = await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-testid=sidebar-row-menu]')].find((e) => String(e.getAttribute('data-menu-id')).startsWith('ch:'))
    b?.click()
    return b?.getAttribute('data-menu-id') || ''
  })
  await visible(p, '[data-testid=sidebar-row-menu-panel]')
  const items = await p.$$eval('[data-testid=sidebar-row-menu-panel] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid')))
  const at = items.indexOf('sidebar-row-menu-add-to-note')
  check(`${tag} C27: a channel row has Add to note, right after Copy link`, at > 0 && items[at - 1] === 'sidebar-row-menu-copy', { menuId, items })
  await clickSel(p, '[data-testid=sidebar-row-menu-add-to-note]')
  const { up, toast } = await pickNote(p, 'mock-note-2')
  check(`${tag} C27: the picker opens from the row`, up)
  check(`${tag} C27: the toast says "Added to Ideas"`, toast === 'Added to Ideas', toast)
  const link = await lastLink(p, 'mock-note-2')
  check(`${tag} C27: the note gains the channel, labelled by its name`, link?.kind === 'channel' && link.ws === WS && `ch:${link.ref}` === menuId && link.label.length > 0, { link, menuId })
  await p.close()
}

/* section 6: notes off (the store reads the hub's 404 notes_off as `off`): the items hide */
async function notesOff(browser, base) {
  const tag = '1440px notes off'
  const p = await openPage(browser, base, 1440, false)
  await go(p, '/channel/alerts')
  await visible(p, ALERTS_CARD)
  /* CONTROL: with the notes on, the item is there */
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), ALERTS_CARD)
  await visible(p, '[data-testid=msg-menu]')
  check(`${tag} CONTROL: notes on, the message menu has Add to note`, (await menuIds(p, '[data-testid=msg-menu]')).includes('msg-menu-add-to-note'))
  await clickSel(p, '[data-testid=msg-menu-add-to-note]')
  await visible(p, '[data-test=note-picker][data-state=ready]')
  /* the hub answers 404 notes_off: the store's state is `off` */
  await p.evaluate(() => { document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').state = 'off' })
  check(`${tag}: the open picker says the notes are off`, await visible(p, '[data-test=note-picker-off]', 5000))
  await p.keyboard.press('Escape')
  await gone(p, '[data-test=note-picker]')
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), ALERTS_CARD)
  await visible(p, '[data-testid=msg-menu]')
  const items = await menuIds(p, '[data-testid=msg-menu]')
  check(`${tag}: the message menu hides Add to note`, items.length > 0 && !items.includes('msg-menu-add-to-note'), items)
  await p.keyboard.press('Escape')
  await go(p, '/issues')
  await visible(p, '[data-test=issues-page]')
  const key = await newIssue(p, 'Fix the login')
  await go(p, `/issues?issue=${key}`)
  await visible(p, '[data-test=issues-detail-archive]')
  check(`${tag}: the open issue hides Add to note`, !(await p.$('[data-test=issues-detail-note]')))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await messageMenu(browser, server.base, 1440, false)
  await messageMenu(browser, server.base, 390, true)
  await shiftN(browser, server.base)
  await issues(browser, server.base)
  await calendar(browser, server.base, 1440, false)
  await calendar(browser, server.base, 390, true)
  await channelRow(browser, server.base, 1440, false)
  await channelRow(browser, server.base, 390, true)
  await notesOff(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nadd-to-note: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
