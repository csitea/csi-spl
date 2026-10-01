// CLE-77816 (owner, topic 4365c545): "there is no edit epic/feature on the
// issues interface … it should be in the right-click menu", and it "should
// allow the edition of the epic / feature … the same way the issues modal
// dialog is done". So Edit is the first context-menu item everywhere, it opens
// the same issue dialog for a level-1 row (Kind editable epic<->feature, no
// Parent, Level read-only), a double-click on the Epics-sidebar row opens it,
// and the plain issue menu carries Edit too.
//
//   pnpm run test:e2e issues-epic-edit
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-epic-edit
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

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
const menuUp = (p) => p.$('[data-test=issues-ctxmenu]').then(Boolean)
const modalUp = (p) => p.$('[data-test=issues-detail]').then(Boolean)
/* the open issue's key: the modal's title (> 820 px) or the phone header */
const openKey = (p) => p.evaluate(() => {
  const dlg = document.querySelector('[data-test=issues-detail]')?.closest('[data-testid=ui-dialog]')?.querySelector('.ui-dialog__title')?.textContent.trim()
  return dlg || document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || null
})
async function rightClick(p, selector) {
  const box = await p.$eval(selector, (el) => { const b = el.getBoundingClientRect(); return { x: b.x + Math.min(40, b.width / 2), y: b.y + b.height / 2 } })
  await p.mouse.click(box.x, box.y, { button: 'right' })
  return box
}
const items = (p) => p.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test')))
async function closeModal(p) {
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 }).catch(() => {})
}

const shot = process.env.SHOT_DIR || '/tmp'
const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // specs/054: the mock is signed-OUT by default; opt into a session so the
  // Issues page renders signed-in (the act-as / mobile-m5 fix pattern).
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=sidebar-epic][data-key="SPL-1"]', { visible: true, timeout: 5000 })

  // 1) right-click the Epics-sidebar epic: Edit is the FIRST item
  await rightClick(p, '[data-testid=sidebar-epic][data-key="SPL-1"]')
  await p.waitForSelector('[data-test=issues-ctxmenu-edit]', { visible: true, timeout: 5000 })
  const epicItems = await items(p)
  ok('1 the epic menu leads with Edit, then open/copy/archive/delete',
    epicItems[0] === 'issues-ctxmenu-edit' && ['issues-ctxmenu-open', 'issues-ctxmenu-copy', 'issues-ctxmenu-archive', 'issues-ctxmenu-delete'].every((k) => epicItems.includes(k)), epicItems)

  // 2) Edit opens the same issue dialog, for a level-1 row: Kind is editable
  //    (a button), Parent is hidden, Level is read-only
  await p.click('[data-test=issues-ctxmenu-edit]')
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
  const key = await openKey(p)
  const l1 = await p.evaluate(() => {
    const dlg = document.querySelector('[data-test=issues-detail]')
    return {
      kindBtn: dlg.querySelector('button[data-test=issues-kind]')?.getAttribute('data-kind') || null,
      parent: Boolean(dlg.querySelector('[data-test=issues-epic], [data-test=issues-parent]')),
      levelReadonly: Boolean(dlg.querySelector('span[data-test=issues-level]')) && !dlg.querySelector('button[data-test=issues-level-btn]'),
    }
  })
  l1.key = key
  await p.screenshot({ path: `${shot}/CLE-77816-epic-edit-1440.png` })
  ok('2 Edit opens the dialog for the level-1 row: Kind is a button (epic), no Parent row, Level read-only',
    l1.key === 'SPL-1' && l1.kindBtn === 'epic' && !l1.parent && l1.levelReadonly, l1)

  // 3) edit the title and description in the dialog; both save
  await p.$eval('[data-test=issues-detail-title]', (el) => { el.focus(); el.select() })
  await p.type('[data-test=issues-detail-title]', 'Authentication epic')
  await p.click('[data-test=issues-detail-rendered]')
  await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-detail-body]', 'the epic, edited from the right-click menu')
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => document.querySelector('[data-test=issues-detail-rendered]')?.textContent.trim() === 'the epic, edited from the right-click menu', { timeout: 5000 }).catch(() => {})
  const edited = await p.evaluate(() => ({
    title: document.querySelector('[data-test=issues-detail-title]')?.value,
    desc: document.querySelector('[data-test=issues-detail-rendered]')?.textContent.trim(),
  }))
  ok('3 the epic title and description are edited in the dialog', edited.title === 'Authentication epic' && edited.desc === 'the epic, edited from the right-click menu', edited)

  // 4) Kind toggles epic <-> feature in the dialog and saves
  await p.click('button[data-test=issues-kind]')
  await p.waitForFunction(() => document.querySelector('button[data-test=issues-kind]')?.getAttribute('data-kind') === 'feature', { timeout: 5000 }).catch(() => {})
  const toFeat = await p.$eval('button[data-test=issues-kind]', (el) => el.getAttribute('data-kind'))
  await p.click('button[data-test=issues-kind]')
  await p.waitForFunction(() => document.querySelector('button[data-test=issues-kind]')?.getAttribute('data-kind') === 'epic', { timeout: 5000 }).catch(() => {})
  const toEpic = await p.$eval('button[data-test=issues-kind]', (el) => el.getAttribute('data-kind'))
  ok('4 Kind toggles epic <-> feature in the dialog', toFeat === 'feature' && toEpic === 'epic', { toFeat, toEpic })

  // 5) the edit persisted: close and re-open Edit; the dialog reloads the saved title
  await closeModal(p)
  await rightClick(p, '[data-testid=sidebar-epic][data-key="SPL-1"]')
  await p.waitForSelector('[data-test=issues-ctxmenu-edit]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-ctxmenu-edit]')
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
  const reloaded = await p.$eval('[data-test=issues-detail-title]', (el) => el.value)
  ok('5 the saved title is reloaded when the epic is edited again', reloaded === 'Authentication epic', { reloaded })
  await closeModal(p)

  // 6) a double-click on the Epics-sidebar row opens Edit. headless Chrome
  //    drops mouse.click{clickCount:2} dblclick events, so dispatch a synthetic
  //    one on the row (the e2e-harness note's pattern).
  await p.waitForSelector('[data-testid=sidebar-epic][data-key="SPL-1"]', { visible: true, timeout: 5000 })
  await p.$eval('[data-testid=sidebar-epic][data-key="SPL-1"]', (el) => el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, button: 0 })))
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 }).catch(() => {})
  const dblKey = await openKey(p)
  ok('6 a double-click on the sidebar epic opens the dialog', dblKey === 'SPL-1', { dblKey })
  await closeModal(p)

  // 7) the plain issue menu also leads with Edit, and it opens the dialog
  await p.goto(server.base + '/issues?epic=SPL-1', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  const childKey = await newIssue(p, 'A plain issue to edit')
  await rightClick(p, `[data-test=issues-row][data-key="${childKey}"]`)
  await p.waitForSelector('[data-test=issues-ctxmenu-edit]', { visible: true, timeout: 5000 })
  const rowItems = await items(p)
  ok('7 the plain issue menu leads with Edit', rowItems[0] === 'issues-ctxmenu-edit', rowItems)
  await p.click('[data-test=issues-ctxmenu-edit]')
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 }).catch(() => {})
  const rowOpened = await openKey(p)
  ok('8 Edit on a plain issue opens its dialog', rowOpened === childKey, { rowOpened, childKey })

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('9 no page errors', mine.length === 0, mine)
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
