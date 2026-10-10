// Owner HUM-10 (t1 4296200d, msg ed921572): "where this qto ui can be
// accessed from". The rail carries a "Docs (Qto)" entry for a signed-in
// member, next to Docs; one click opens /workspace/docs (spec 113 T006),
// the workspace documents. A phone strip carries it too. Signed out it is
// absent while Docs stays.
// Owner HUM-10 (t1 efde25bb): on /workspace/docs the left panel is a VS
// Code-like file tree of the documents, not the channel list: the sidebar
// keeps its icon rail only; the tree's rows expand, collapse, open a
// document or a section, and answer the arrow keys. A phone folds the tree
// behind its Documents button. No visible heading above the tree
// (msg 8471b818); control: the <h3> restored -> that check FAILS.
//
// Owner HUM-10 (t1 91289b0a, msgs 635c2125, 500ca8f5): each DOCUMENT row
// has a right-click menu (a long press on a phone, Shift+F10 / the
// context-menu key): Edit, Rename, Copy link, Open in a new tab, Delete
// (confirmed; the hub's DELETE /v1/workspace/doctree/{doc}). A section row
// has none. Control: before the menu a right-click draws no
// [data-testid=qto-doc-menu], so every menu check FAILS.
//
// Control: before the entry there is no [data-testid=qto-open], so every
// signed-in check FAILS on the earlier master. The channel list check has
// its control on / (the same selector finds the list there); before the
// tree there is no [data-test=qto-file-tree], so the tree checks FAIL.
//
//   node tests/e2e/qto-sidebar-entry.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/qto-sidebar-entry.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { MOCK_SIGNED_OUT_KEY } from '../../src/utils/act-as-mock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const STEP = 15000
const PUBLIC_DOC = 'csi-spl-doc/doc/help/getting-started.md'
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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const onPage = (p) => p.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: STEP }).then(Boolean, () => false)

/** true when the selector matches an element that takes up room */
const shown = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  const r = el.getBoundingClientRect()
  return r.width > 0 && r.height > 0
}, sel)

const rowKeys = (p) => p.$$eval('[data-test=qto-file-tree] [data-test=file-tree-row]', (els) => els.map((el) => `${el.getAttribute('aria-level')} ${el.textContent.trim()}`))

/* the sidebar's list panels: channels, DMs, issues, ... (whichever tab was last) */
const PANELS = '[data-testid^=sidebar-panel-]'

/** t1 efde25bb: the Qto left panel is the file tree; the channel list is gone */
async function fileTree(p) {
  ok('CONTROL: the sidebar list panel shows on /', await (async () => {
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    return p.waitForFunction((sel) => [...document.querySelectorAll(sel)].some((el) => el.getBoundingClientRect().width > 0), { timeout: STEP }, PANELS).then(() => true, () => false)
  })())
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await onPage(p)
  ok('the left panel is the file tree', await p.waitForSelector('[data-test=qto-file-tree] [data-test=file-tree-row]', { visible: true, timeout: STEP }).then(Boolean, () => false))
  ok('no channel (or any sidebar list) panel beside it', await p.$$eval(PANELS, (els) => !els.some((el) => el.getBoundingClientRect().width > 0)))
  ok('the sidebar keeps its icon rail only', (await p.$eval('nav.sidebar', (el) => el.getAttribute('data-docs-rail')).catch(() => null)) === '1' && await shown(p, '[data-testid=sidebar-rail]'))
  /* msg 8471b818: "Remove the documents label, not needed." The tree keeps its name for assistive tech only */
  ok('no heading above the tree', await p.$eval('[data-test=qto-file-tree]', (el) => !el.querySelector('h1, h2, h3, h4, h5, h6, [role=heading]') && el.getAttribute('aria-label') === 'Documents').catch(() => false))
  ok('the tree sits left of the document', await p.evaluate(() => {
    const t = document.querySelector('[data-test=qto-file-tree]')?.getBoundingClientRect()
    const d = document.querySelector('[data-test=ws-docs-page]')?.getBoundingClientRect()
    return Boolean(t && d && t.right <= d.left + 1)
  }))
  await p.waitForSelector('[data-test=qto-file-tree] [aria-level="2"]', { timeout: STEP }).catch(() => null)
  const rows = await rowKeys(p)
  ok('the open document is the active row, expanded to its sections', rows[0] === '1 Handbook' && rows.includes('2 Introduction') && rows.includes('2 Glossary'), rows)
  ok('the active row is marked', await p.$eval('[data-test=qto-file-tree] [aria-selected=true]', (el) => el.textContent.trim()).catch(() => '') === 'Handbook')
  /* a section with sections under it starts closed; its chevron opens it */
  const intro = await p.evaluateHandle(() => [...document.querySelectorAll('[data-test=qto-file-tree] [data-test=file-tree-row]')].find((el) => el.textContent.trim() === 'Introduction'))
  if (!(await intro.evaluate((el) => Boolean(el)))) {
    ok('the Introduction row is there', false)
    return
  }
  ok('a section with sections is collapsed', (await intro.evaluate((el) => el.getAttribute('aria-expanded'))) === 'false')
  await (await intro.$('[data-test=file-tree-toggle]'))?.click()
  await p.waitForFunction(() => [...document.querySelectorAll('[data-test=qto-file-tree] [data-test=file-tree-row]')].some((el) => el.textContent.trim() === 'Scope'), { timeout: STEP }).catch(() => {})
  ok('its chevron expands it', (await rowKeys(p)).includes('3 Scope'), await rowKeys(p))
  /* the keyboard: Left closes the open row, Down moves, Enter opens */
  await intro.evaluate((el) => el.focus())
  await p.keyboard.press('ArrowLeft')
  await p.waitForFunction(() => ![...document.querySelectorAll('[data-test=qto-file-tree] [data-test=file-tree-row]')].some((el) => el.textContent.trim() === 'Scope'), { timeout: STEP }).catch(() => {})
  ok('Left collapses it', !(await rowKeys(p)).includes('3 Scope'))
  await p.keyboard.press('ArrowRight')
  await p.keyboard.press('ArrowRight')
  ok('Right expands, Right again steps into it', await p.evaluate(() => document.activeElement?.textContent?.trim()) === 'Scope')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => location.hash.startsWith('#ws-doc-'), { timeout: STEP }).catch(() => {})
  const hash = await p.evaluate(() => location.hash)
  ok('Enter opens that section in the document', Boolean(hash) && await p.evaluate((h) => {
    const el = document.getElementById(h.slice(1))
    return Boolean(el && el.textContent.includes('Scope') || el?.querySelector('textarea')?.value === 'Scope')
  }, hash), hash)
  ok('the section row is now the active one', await p.$eval('[data-test=qto-file-tree] [aria-selected=true]', (el) => el.textContent.trim()).catch(() => '') === 'Scope')
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-file-tree-desktop.png` })
}

const MENU = '[data-testid=qto-doc-menu]'
const menuShown = (p) => p.waitForSelector(MENU, { visible: true, timeout: STEP }).then(Boolean, () => false)
const menuGone = (p) => p.waitForFunction((sel) => !document.querySelector(sel), { timeout: STEP }, MENU).then(() => true, () => false)
/** the tree row named name (a document's title, a section's heading) */
const treeRow = (p, name) => p.evaluateHandle((name) => [...document.querySelectorAll('[data-test=qto-file-tree] [data-test=file-tree-row]')].find((el) => el.textContent.trim() === name) || null, name)
async function rightClick(p, name) {
  const row = await treeRow(p, name)
  if (!(await row.evaluate((el) => Boolean(el)))) return false
  const b = await row.evaluate((el) => { const r = el.getBoundingClientRect(); return { x: r.left + 40, y: r.top + r.height / 2 } })
  await p.mouse.click(b.x, b.y, { button: 'right' })
  return true
}
async function chooseOn(p, name, id) {
  await rightClick(p, name)
  if (!(await menuShown(p))) return false
  await p.click(`[data-testid=qto-doc-menu-${id}]`)
  return true
}

/** t1 91289b0a: the document row's menu */
async function docMenu(p, browser) {
  ok('CONTROL: a section row opens no menu', await rightClick(p, 'Introduction') && !(await p.waitForSelector(MENU, { visible: true, timeout: 1500 }).then(Boolean, () => false)))
  ok('a right-click on a document row opens its menu', await rightClick(p, 'Handbook') && await menuShown(p))
  const ids = await p.$$eval(`${MENU} [role=menuitem]`, (els) => els.map((el) => el.getAttribute('data-testid').replace('qto-doc-menu-', '')))
  ok('the menu: Edit, Rename, Copy link, Open in a new tab, Delete', ids.join(',') === 'edit,rename,copy_link,new_tab,delete', ids)
  ok('Delete is drawn as a danger entry', await p.$eval(`${MENU} [data-testid=qto-doc-menu-delete]`, (el) => el.classList.contains('point-menu__item--danger')).catch(() => false))
  ok('the menu is named', await p.$eval(`${MENU} [role=menu]`, (el) => el.getAttribute('aria-label')).catch(() => '') === 'Document actions')
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-doc-menu-desktop.png` })
  await p.keyboard.press('Escape')
  ok('Escape closes it', await menuGone(p))
  /* the keyboard: Shift+F10 and the context-menu key on the focused row */
  const hb = await treeRow(p, 'Handbook')
  await hb.evaluate((el) => el.focus())
  await p.keyboard.down('Shift')
  await p.keyboard.press('F10')
  await p.keyboard.up('Shift')
  ok('Shift+F10 on the focused row opens it', await menuShown(p))
  await p.keyboard.press('Escape')
  await menuGone(p)
  await hb.evaluate((el) => el.focus())
  await p.keyboard.press('ContextMenu')
  ok('the context-menu key opens it', await menuShown(p))
  await p.keyboard.press('Escape')
  await menuGone(p)
  const docId = await hb.evaluate((el) => el.getAttribute('data-key').slice(2))
  const link = `${server.base}/workspace/docs?doc=${docId}&view=doc`

  await browser.defaultBrowserContext().overridePermissions(server.base, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  await chooseOn(p, 'Handbook', 'copy_link')
  ok('Copy link says so', await p.waitForFunction(() => document.querySelector('[data-test=qto-tree-status]')?.textContent.trim() === 'Link copied', { timeout: STEP }).then(() => true, () => false))
  const clip = await p.evaluate(() => navigator.clipboard.readText().catch(() => ''))
  ok('Copy link copies the document\'s address', clip === link, clip)

  const tab = new Promise((resolve) => browser.once('targetcreated', (t) => resolve(t)))
  await chooseOn(p, 'Handbook', 'new_tab')
  const target = await Promise.race([tab, new Promise((r) => setTimeout(() => r(null), STEP))])
  ok('Open in a new tab opens the document\'s address', target?.url() === link, target?.url())
  await (await target?.page().catch(() => null))?.close()

  await chooseOn(p, 'Handbook', 'rename')
  const input = await p.waitForSelector('[data-test=qto-rename-title]', { visible: true, timeout: STEP }).catch(() => null)
  ok('Rename asks for the title, the current one filled in', (await input?.evaluate((el) => el.value)) === 'Handbook')
  if (!input) return
  await input.click({ count: 3 })
  await p.keyboard.type('Handbook Guide')
  await p.click('[data-test=qto-rename-save]')
  ok('Rename: the row shows the new title', await p.waitForFunction(() => [...document.querySelectorAll('[data-test=qto-file-tree] [data-test=file-tree-row]')].some((el) => el.textContent.trim() === 'Handbook Guide'), { timeout: STEP }).then(() => true, () => false))
  const head = await p.evaluate((id) => window.__wsDocTreeCall?.('GET', '/' + id), docId)
  ok('Rename: the hub has it', head?.title === 'Handbook Guide', head?.title)
  ok('Rename: the open document shows it', await p.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === 'Handbook Guide', { timeout: STEP }).then(() => true, () => false))

  /* Edit: from another open document, it opens this one */
  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', 'Notes')
  await p.click('[data-test=ws-docs-create]')
  await p.waitForFunction(() => document.querySelector('[data-test=qto-file-tree] [aria-selected=true]')?.textContent.trim() === 'Notes', { timeout: STEP }).catch(() => {})
  await chooseOn(p, 'Handbook Guide', 'edit')
  await p.waitForFunction((id) => new URL(location.href).searchParams.get('doc') === id, { timeout: STEP }, docId).catch(() => {})
  ok('Edit opens the document', new URL(p.url()).searchParams.get('doc') === docId && await p.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === 'Handbook Guide', { timeout: STEP }).then(() => true, () => false), p.url())

  /* Delete: it asks first; Cancel keeps the document */
  const names = () => p.$$eval('[data-test=qto-file-tree] [data-kind=doc]', (els) => els.map((el) => el.textContent.trim()))
  await chooseOn(p, 'Handbook Guide', 'delete')
  ok('Delete asks first, naming the document', await p.waitForSelector('[data-testid=qto-delete-body]', { visible: true, timeout: STEP }).then((el) => el.evaluate((e) => e.textContent.includes('Handbook Guide')), () => false))
  await p.click('[data-testid=qto-delete-cancel]').catch(() => {})
  await p.waitForFunction(() => !document.querySelector('[data-testid=qto-delete-body]'), { timeout: STEP }).catch(() => {})
  ok('Cancel keeps it', (await names()).includes('Handbook Guide'), await names())
  /* confirmed, the open document goes; the one left opens */
  await chooseOn(p, 'Handbook Guide', 'delete')
  await p.waitForSelector('[data-testid=qto-delete-confirm]', { visible: true, timeout: STEP }).catch(() => null)
  await p.click('[data-testid=qto-delete-confirm]').catch(() => {})
  ok('Delete: the row is gone', await p.waitForFunction(() => ![...document.querySelectorAll('[data-test=qto-file-tree] [data-kind=doc]')].some((el) => el.textContent.trim() === 'Handbook Guide'), { timeout: STEP }).then(() => true, () => false), await names())
  const listed = await p.evaluate(() => window.__wsDocTreeCall?.('GET', '').then((r) => r.docs.map((d) => d.title)))
  ok('Delete: the hub no longer lists it', Array.isArray(listed) && !listed.includes('Handbook Guide') && listed.includes('Notes'), listed)
  ok('Delete: the document left opens', await p.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === 'Notes', { timeout: STEP }).then(() => true, () => false))
}

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1280x800 signed in')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const open = await p.waitForSelector('[data-testid=qto-open]', { visible: true, timeout: STEP }).catch(() => null)
  ok('the rail carries a Docs (Qto) entry', Boolean(open))
  if (open) {
    ok('it is named for assistive tech', (await open.evaluate((el) => el.getAttribute('aria-label'))) === 'Docs (Qto)')
    ok('it sits right after Docs', await p.evaluate(() => document.querySelector('[data-testid=docs-open]')?.nextElementSibling?.getAttribute('data-testid') === 'qto-open'))
    await open.click()
    await p.waitForFunction(() => location.pathname === '/workspace/docs', { timeout: STEP }).catch(() => {})
    ok('one click lands on /workspace/docs', new URL(p.url()).pathname === '/workspace/docs', p.url())
    ok('the workspace documents render', await onPage(p))
    ok('the entry is marked active there', await p.$eval('[data-testid=qto-open]', (el) => el.classList.contains('router-link-active')).catch(() => false))
    await fileTree(p)
    await docMenu(p, browser)
  }
  await p.close()

  console.log('-- 390x740 phone')
  const m = await browser.newPage()
  await m.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('the phone strip carries Docs (Qto)', Boolean(await m.waitForSelector('[data-testid=qto-open]', { timeout: STEP }).catch(() => null)))
  /* the strip rolls endlessly (CLE-77886): swipe until an entry is in view, tap it */
  const spot = () => m.evaluate(() => {
    const rail = document.querySelector('[data-testid=sidebar-rail]')
    const rb = rail.getBoundingClientRect()
    for (const h of document.querySelectorAll('.sidebar-rail__qto')) {
      const r = h.getBoundingClientRect()
      if (r.width && r.left >= Math.max(rb.left, 0) && r.right <= Math.min(rb.right, window.innerWidth)) {
        return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }
      }
    }
    return null
  })
  let at = await spot()
  for (let i = 0; !at && i < 60; i++) {
    await m.evaluate(() => { document.querySelector('[data-testid=sidebar-rail]').scrollLeft += 40 })
    await new Promise((r) => setTimeout(r, 50))
    at = await spot()
  }
  ok('a swipe brings it into view, a 44 px target', Boolean(at && at.w >= 44 && at.h >= 44), at)
  if (at) await m.touchscreen.tap(at.x, at.y)
  await m.waitForFunction(() => location.pathname === '/workspace/docs', { timeout: STEP }).catch(() => {})
  ok('one tap lands on /workspace/docs', new URL(m.url()).pathname === '/workspace/docs', m.url())
  await onPage(m)
  ok('phone: the tree is folded', !(await shown(m, '[data-test=qto-file-tree]')))
  await m.tap('[data-test=qto-file-tree-toggle]').catch(() => {})
  ok('phone: the Documents button unfolds the tree', await m.waitForFunction(() => {
    const el = document.querySelector('[data-test=qto-file-tree]')
    return Boolean(el && el.getBoundingClientRect().height > 0)
  }, { timeout: STEP }).then(() => true, () => false))
  ok('phone: a tree row is a 44 px target', await m.$eval('[data-test=file-tree-row]', (el) => el.getBoundingClientRect().height >= 44).catch(() => false))
  const held = await m.$eval('[data-test=qto-file-tree] [data-kind=doc]', (el) => { const r = el.getBoundingClientRect(); return { x: r.left + 60, y: r.top + r.height / 2 } }).catch(() => null)
  if (held) {
    await m.touchscreen.touchStart(held.x, held.y)
    await new Promise((r) => setTimeout(r, 800))
    await m.touchscreen.touchEnd()
  }
  ok('phone: a long press on a document opens its menu as a sheet', await menuShown(m) && await m.$eval(MENU, (el) => el.classList.contains('touch-sheet')).catch(() => false))
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-doc-menu-phone.png` })
  await m.keyboard.press('Escape')
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-file-tree-phone.png` })
  await m.close()

  console.log('-- signed out')
  const o = await browser.newPage()
  await o.setViewport({ width: 1280, height: 800 })
  await o.evaluateOnNewDocument((key) => { try { localStorage.setItem(key, 'true') } catch { /* no storage: the checks below fail */ } }, MOCK_SIGNED_OUT_KEY)
  await o.goto(server.base + '/docs/' + PUBLIC_DOC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const docs = await o.waitForSelector('[data-testid=docs-open]', { timeout: STEP }).catch(() => null)
  ok('signed out: CONTROL the rail is drawn (Docs is there)', Boolean(docs))
  ok('signed out: no Docs (Qto) entry', !(await o.$('[data-testid=qto-open]')) && !(await o.$('.sidebar-rail__qto')))
  await o.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-sidebar-entry: ${failed} FAILED` : `qto-sidebar-entry: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
