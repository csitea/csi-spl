// Owner HUM-10 (t1 4296200d, msg ed921572): "where this qto ui can be
// accessed from". The rail carries a "Docs (Qto)" entry for a signed-in
// member, next to Docs; one click opens /workspace/docs (spec 113 T006),
// the workspace documents. A phone strip carries it too. Signed out it is
// absent while Docs stays.
// Owner HUM-10 (t1 efde25bb): on /workspace/docs the left panel is a VS
// Code-like file tree of the documents, not the channel list: the sidebar
// keeps its icon rail only; the tree's rows expand, collapse, open a
// document or a section, and answer the arrow keys. No visible heading
// above the tree (msg 8471b818); control: the <h3> restored -> that check
// FAILS.
//
// Owner t1 8bf89f96 (msgs dfe000c1, c09ae88e, d8a12bb3): a phone drills
// down as Channels -> channel -> topic: the first screen lists the top level
// only; a row with rows under it opens a screen of its rows, its path as the
// title; Back (the chevron) walks up; any other row opens the document.
// Control: before the drill-down the phone folds the whole tree (sections
// included) behind a Documents button and the page has no list, so the
// top-level-only check FAILS.
//
// Owner HUM-10 (t1 91289b0a, msgs 635c2125, 500ca8f5): each DOCUMENT row
// has a right-click menu (a long press on a phone, Shift+F10 / the
// context-menu key): Edit, Rename, Copy link, Open in a new tab, Delete
// (confirmed; the hub's DELETE /v1/workspace/doctree/{doc}). Control:
// before the menu a right-click draws no [data-testid=qto-doc-menu], so
// every menu check FAILS.
//
// Owner HUM-10 (t1 ed2e3583, msg 407fc16f): a right-click in the Qto file
// system opens a matching menu for the directories as well. A FOLDER row's menu: New document here, New folder here, Rename,
// Copy path, Delete (confirmed; a folder that holds anything shows its
// counts and a second confirm deletes it with them). A SECTION row's: Open,
// Copy link, Open in a new tab. Same keys and long press as the document's.
// Control: before it a right-click on a folder or a section draws no
// [data-testid=qto-folder-menu] / [data-testid=qto-section-menu], so those
// checks FAIL.
//
// Owner t1 3b8891e0 (msgs 62c51def, 411480f9, e3b5a06a): a + New folder,
// "the same type and shape" as the page's + New document. At 1440 px it
// shares the page header row with the view buttons and + New document (no
// Documents heading); a folder made there lists first, and a folder picked,
// the page's + New document lands inside it. At 390 px it stays above each
// drill-down level and makes the folder in the level shown. Control: before
// the button there is no [data-test=qto-new-folder], so every folder check FAILS.
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

/** t1 ed2e3583: a section row's menu: Open, Copy link, Open in a new tab, never the document's */
async function sectionMenu(p) {
  const SEC = '[data-testid=qto-section-menu]'
  ok('a right-click on a section row opens the section menu', await rightClick(p, 'Introduction') && await p.waitForSelector(SEC, { visible: true, timeout: STEP }).then(Boolean, () => false))
  const ids = await p.$$eval(`${SEC} [role=menuitem]`, (els) => els.map((el) => el.getAttribute('data-testid').replace('qto-section-menu-', ''))).catch(() => [])
  ok('the section menu: Open, Copy link, Open in a new tab', ids.join(',') === 'open,copy_link,new_tab', ids)
  ok('... not the document\'s menu', !(await p.$(MENU)))
  ok('... named', await p.$eval(`${SEC} [role=menu]`, (el) => el.getAttribute('aria-label')).catch(() => '') === 'Section actions')
  await p.click(`[data-testid=qto-section-menu-open]`).catch(() => {})
  ok('Open opens that section', await p.waitForFunction(() => location.hash.startsWith('#ws-doc-'), { timeout: STEP }).then(() => true, () => false), p.url())
}

/** t1 91289b0a: the document row's menu */
async function docMenu(p, browser) {
  await sectionMenu(p)
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

const FOLDER_NEW = '[data-test=qto-new-folder]'
/** the + buttons' look: the folder one must match the page's document one */
const look = (p, sel) => p.$eval(sel, (el) => {
  const c = getComputedStyle(el)
  return [c.width, c.height, c.borderRadius, c.backgroundColor, el.querySelector('svg') ? 'icon' : 'none'].join(' ')
}).catch(() => '')

/** the folder dialog from the + in scope (the side tree, or the phone's list): a name, Create; '' = it closed */
async function newFolder(p, name, scope = '#qto-file-tree') {
  await p.click(`${scope} ${FOLDER_NEW}`)
  const input = await p.waitForSelector('[data-test=qto-new-folder-name]', { visible: true, timeout: STEP }).catch(() => null)
  if (!input) return 'no dialog'
  await input.type(name)
  await p.click('[data-test=qto-new-folder-create]')
  return p.waitForFunction(() => !document.querySelector('[data-test=qto-new-folder-form]') || document.querySelector('[data-test=ws-docs-new-error]'), { timeout: STEP })
    .then(() => p.$eval('[data-test=ws-docs-new-error]', (el) => el.textContent.trim()).catch(() => ''), () => 'still open')
}

/** a new document through the page's + and its modal */
async function newDoc(p, title) {
  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', title)
  await p.click('[data-test=ws-docs-create]')
  return p.waitForFunction((t) => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === t, { timeout: STEP }, title).then(() => true, () => false)
}

/** the screenshot pair the lane reports: light, then dark */
async function shots(p, name) {
  if (!process.env.SHOT_DIR) return
  for (const theme of ['light', 'dark']) {
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await new Promise((r) => setTimeout(r, 200))
    await p.screenshot({ path: `${process.env.SHOT_DIR}/${name}-${theme}.png` })
  }
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }])
  await p.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'))
}

/** t1 3b8891e0 at 1440 px: the + New folder tops the tree; a folder, then a document inside it */
async function desktopFolders(p) {
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await onPage(p)
  await p.waitForSelector('[data-test=qto-file-tree] [data-test=file-tree-row]', { visible: true, timeout: STEP }).catch(() => null)
  ok('1440: no Documents heading, and the views and both + buttons share the header row', await p.waitForFunction(() => {
    const box = (sel) => {
      const el = document.querySelector(sel)
      if (!el) return null
      const r = el.getBoundingClientRect()
      return r.width > 0 && r.height > 0 ? r : null
    }
    const views = box('.wsdocs-head .wsdocs-views')
    const doc = box('.wsdocs-head [data-test=ws-docs-new]')
    const folder = box('.wsdocs-head [data-test=qto-new-folder]')
    const head = box('.wsdocs-head')
    const heading = document.querySelector('[data-test=ws-docs-heading]')
    const shownHeading = heading && heading.getBoundingClientRect().height > 0 && /\bDocuments\b/.test(heading.textContent || '')
    if (!views || !doc || !folder || !head || shownHeading) return false
    const same = (a, b) => a.top < b.bottom - 1 && b.top < a.bottom - 1
    return same(views, doc) && same(views, folder) && views.left >= head.left + head.width / 3
  }, { timeout: STEP }).then(() => true, () => false))
  ok('1440: ... named New folder', await p.$eval(FOLDER_NEW, (el) => el.getAttribute('aria-label')).catch(() => '') === 'New folder')
  const want = await look(p, '[data-test=ws-docs-new]')
  ok('1440: ... the same type and shape as + New document', Boolean(want) && await look(p, FOLDER_NEW) === want, [await look(p, FOLDER_NEW), want])
  ok('1440: a folder is made', await newFolder(p, 'Plans', '.wsdocs-head') === '')
  ok('1440: ... and listed first in the tree, a folder row', await p.waitForFunction(() => {
    const first = document.querySelector('#qto-file-tree [data-test=file-tree-row]')
    return first?.textContent.trim() === 'Plans' && first.getAttribute('data-kind') === 'folder'
  }, { timeout: STEP }).then(() => true, () => false), await rowKeys(p))
  ok('1440: the same name again is refused, saying why', await newFolder(p, 'plans', '.wsdocs-head') === 'A folder with that name is already here.')
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=qto-new-folder-form]'), { timeout: STEP }).catch(() => {})
  const plans = await treeRow(p, 'Plans')
  const folderId = await plans.evaluate((el) => el?.getAttribute('data-key')?.slice(2) || '')
  await plans.click()
  ok('1440: a click picks the folder', await p.$eval('#qto-file-tree [aria-selected=true]', (el) => el.textContent.trim()).catch(() => '') === 'Plans')
  ok('1440: + New document makes a document', await newDoc(p, 'Roadmap'))
  ok('1440: ... inside the picked folder, one level under it', await p.waitForFunction(() => {
    const rows = [...document.querySelectorAll('#qto-file-tree [data-test=file-tree-row]')].map((el) => `${el.getAttribute('aria-level')} ${el.textContent.trim()}`)
    const i = rows.indexOf('1 Plans')
    return i >= 0 && rows[i + 1] === '2 Roadmap'
  }, { timeout: STEP }).then(() => true, () => false), await rowKeys(p))
  const inside = await p.evaluate((id) => window.__wsDocTreeCall?.('GET', '/nodes?parent=' + id).then((r) => r.nodes.map((n) => n.title || n.name)), folderId)
  ok('1440: ... and the hub has it there', Array.isArray(inside) && inside.join() === 'Roadmap', inside)
  await shots(p, 'qto-new-folder-1440')
  await folderMenu(p, folderId)
}

const FMENU = '[data-testid=qto-folder-menu]'
const fmenuShown = (p) => p.waitForSelector(FMENU, { visible: true, timeout: STEP }).then(Boolean, () => false)
async function chooseFolder(p, name, id) {
  await rightClick(p, name)
  if (!(await fmenuShown(p))) return false
  await p.click(`[data-testid=qto-folder-menu-${id}]`)
  return true
}

/** t1 ed2e3583 at 1440 px: the folder row's menu, each entry driven */
async function folderMenu(p, folderId) {
  ok('1440: a right-click on a folder row opens the folder menu', await rightClick(p, 'Plans') && await fmenuShown(p))
  const ids = await p.$$eval(`${FMENU} [role=menuitem]`, (els) => els.map((el) => el.getAttribute('data-testid').replace('qto-folder-menu-', ''))).catch(() => [])
  ok('1440: ... New document, New folder, Rename, Copy path, Delete', ids.join(',') === 'new_doc,new_folder,rename,copy_path,delete', ids)
  ok('1440: ... Delete is a danger entry, the menu is named', await p.$eval(`${FMENU} [data-testid=qto-folder-menu-delete]`, (el) => el.classList.contains('point-menu__item--danger')).catch(() => false) &&
    await p.$eval(`${FMENU} [role=menu]`, (el) => el.getAttribute('aria-label')).catch(() => '') === 'Folder actions')
  await shots(p, 'qto-folder-menu-1440')
  await p.keyboard.press('Escape')
  await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: STEP }, FMENU).catch(() => {})
  const row = await treeRow(p, 'Plans')
  await row.evaluate((el) => el.focus())
  await p.keyboard.down('Shift')
  await p.keyboard.press('F10')
  await p.keyboard.up('Shift')
  ok('1440: Shift+F10 on the focused folder row opens it', await fmenuShown(p))
  await p.keyboard.press('Escape')
  await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: STEP }, FMENU).catch(() => {})

  /* New folder here: the dialog makes it inside, whatever folder was picked before */
  await chooseFolder(p, 'Plans', 'new_folder')
  const input = await p.waitForSelector('[data-test=qto-new-folder-name]', { visible: true, timeout: STEP }).catch(() => null)
  if (input) {
    await input.type('Q4')
    await p.click('[data-test=qto-new-folder-create]')
  }
  const kids = () => p.evaluate((id) => window.__wsDocTreeCall?.('GET', '/nodes?parent=' + id).then((r) => r.nodes.map((n) => n.title || n.name)), folderId)
  ok('1440: New folder here makes it inside the folder', await p.waitForFunction(() => !document.querySelector('[data-test=qto-new-folder-form]'), { timeout: STEP }).then(() => true, () => false) && (await kids())?.join() === 'Q4,Roadmap', await kids())

  /* Rename: the name filled in, then the row and the hub show the new one; a sibling's name is refused */
  await chooseFolder(p, 'Plans', 'rename')
  const name = await p.waitForSelector('[data-test=qto-rename-title]', { visible: true, timeout: STEP }).catch(() => null)
  ok('1440: Rename asks for the folder name, the current one filled in', (await name?.evaluate((el) => el.value)) === 'Plans')
  if (name) {
    await name.click({ count: 3 })
    await p.keyboard.type('Plans 2026')
    await p.click('[data-test=qto-rename-save]')
  }
  ok('1440: Rename: the row shows the new name', await p.waitForFunction(() => [...document.querySelectorAll('#qto-file-tree [data-kind=folder]')].some((el) => el.textContent.trim() === 'Plans 2026'), { timeout: STEP }).then(() => true, () => false), await rowKeys(p))
  const top = await p.evaluate(() => window.__wsDocTreeCall?.('GET', '/nodes').then((r) => r.nodes.filter((n) => n.kind === 'folder').map((n) => n.name)))
  ok('1440: Rename: the hub has it', Array.isArray(top) && top.includes('Plans 2026'), top)

  /* Copy path: the folder's path from the top */
  await chooseFolder(p, 'Q4', 'copy_path')
  ok('1440: Copy path says so', await p.waitForFunction(() => document.querySelector('[data-test=qto-tree-status]')?.textContent.trim() === 'Path copied', { timeout: STEP }).then(() => true, () => false))
  const clip = await p.evaluate(() => navigator.clipboard.readText().catch(() => ''))
  ok('1440: Copy path copies "Plans 2026 / Q4"', clip === 'Plans 2026 / Q4', clip)

  /* New document here: the page's dialog, the document lands in the folder */
  await chooseFolder(p, 'Q4', 'new_doc')
  const t = await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP }).catch(() => null)
  if (t) {
    await t.type('Budget')
    await p.click('[data-test=ws-docs-create]')
  }
  const q4 = await p.evaluate(() => window.__wsDocTreeCall?.('GET', '/nodes').then(async (r) => {
    const plans = r.nodes.find((n) => n.name === 'Plans 2026')
    const inner = await window.__wsDocTreeCall('GET', '/nodes?parent=' + plans.id)
    const q = inner.nodes.find((n) => n.name === 'Q4')
    return (await window.__wsDocTreeCall('GET', '/nodes?parent=' + q.id)).nodes.map((n) => n.title)
  }))
  ok('1440: New document here lands in that folder', await p.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === 'Budget', { timeout: STEP }).then(() => true, () => false) && q4?.join() === 'Budget', q4)

  /* Delete: confirm, the folder holds things, its counts shown, confirm again: gone with them */
  await chooseFolder(p, 'Plans 2026', 'delete')
  ok('1440: Delete asks first, naming the folder', await p.waitForSelector('[data-testid=qto-folder-delete-body]', { visible: true, timeout: STEP }).then((el) => el.evaluate((e) => e.textContent.includes('Plans 2026')), () => false))
  await p.click('[data-testid=qto-folder-delete-confirm]').catch(() => {})
  const held = await p.waitForSelector('[data-test=qto-folder-delete-held]', { visible: true, timeout: STEP }).then((el) => el.evaluate((e) => e.textContent.trim()), () => '')
  ok('1440: ... a folder that holds things shows its counts first', held === 'It holds folders: 1, documents: 2. They will be deleted with it.', held)
  await p.click('[data-testid=qto-folder-delete-confirm]').catch(() => {})
  ok('1440: Delete: the row is gone', await p.waitForFunction(() => ![...document.querySelectorAll('#qto-file-tree [data-test=file-tree-row]')].some((el) => ['Plans 2026', 'Roadmap', 'Budget'].includes(el.textContent.trim())), { timeout: STEP }).then(() => true, () => false), await rowKeys(p))
  const listed = await p.evaluate(() => window.__wsDocTreeCall?.('GET', '').then((r) => r.docs.map((d) => d.title)))
  ok('1440: Delete: the hub lists neither of its documents', Array.isArray(listed) && !listed.includes('Roadmap') && !listed.includes('Budget'), listed)
}

/** t1 3b8891e0 at 390 px: the + New folder tops each drill-down level and makes the folder there */
async function phoneFolders(m) {
  await m.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await onPage(m)
  await listIs(m, ['Handbook'])
  ok('390: a + New folder tops the list', await m.evaluate((sel) => {
    const b = document.querySelector(sel)?.getBoundingClientRect()
    const r = document.querySelector('[data-test=ws-docs-page] [data-test=qto-file-tree] [data-test=file-tree-row]')?.getBoundingClientRect()
    return Boolean(b && r && b.width > 0 && b.bottom <= r.top + 1)
  }, `${LIST} ${FOLDER_NEW}`))
  /* the page's + floats bottom right on a phone at 56 px; the folder one keeps the round accent + at the top */
  const [w, h, radius, ...rest] = (await look(m, `${LIST} ${FOLDER_NEW}`)).split(' ')
  const fab = (await look(m, '[data-test=ws-docs-new]')).split(' ')
  ok('390: ... a round + of 40 px or more, the page\'s colour', parseFloat(w) >= 40 && w === h && radius === '50%' && rest.join(' ') === fab.slice(3).join(' '), [w, h, radius, rest.join(' '), fab.join(' ')])
  ok('390: a folder made at the top level lists there, first', await newFolder(m, 'Plans', LIST) === '' && await listIs(m, ['Plans', 'Handbook']), await listRows(m))
  const held = await m.$eval(`${LIST} [data-kind=folder]`, (el) => { const r = el.getBoundingClientRect(); return { x: r.left + 60, y: r.top + r.height / 2 } }).catch(() => null)
  if (held) {
    await m.touchscreen.touchStart(held.x, held.y)
    await new Promise((r) => setTimeout(r, 800))
    await m.touchscreen.touchEnd()
  }
  ok('390: a long press on a folder opens its menu as a sheet', await m.waitForSelector('[data-testid=qto-folder-menu]', { visible: true, timeout: STEP }).then((el) => el.evaluate((e) => e.classList.contains('touch-sheet')), () => false))
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-folder-menu-390.png` })
  /* a phone closes the sheet with a tap on the dimmed page above it */
  await m.touchscreen.tap(195, 120)
  ok('390: a tap above the sheet closes it', await m.waitForFunction(() => !document.querySelector('[data-testid=qto-folder-menu]'), { timeout: STEP }).then(() => true, () => false))
  await tapRow(m, 'Plans')
  ok('390: a tap on the folder drills into it, titled with its name', await m.waitForFunction(() => new URL(location.href).searchParams.get('in')?.startsWith('f:'), { timeout: STEP }).then(() => true, () => false) && await heading(m) === 'Plans', m.url())
  ok('390: ... the + New folder tops that level too', await shown(m, `${LIST} ${FOLDER_NEW}`))
  ok('390: ... and a folder level offers no Edit (it is no document)', !(await m.$('[data-test=ws-docs-drill-open]')))
  ok('390: a folder made there lands in the level shown', await newFolder(m, '2026', LIST) === '' && await listIs(m, ['2026']), await listRows(m))
  if (process.env.SHOT_DIR) await shots(m, 'qto-new-folder-390')
  ok('390: + New document makes a document in that level', await newDoc(m, 'Roadmap'))
  await back(m)
  ok('390: Back: the level lists the folder, then the document', await listIs(m, ['2026', 'Roadmap']) && await heading(m) === 'Plans', await listRows(m))
}

/* the phone's list: the page's own tree (the side panel's is not drawn there) */
const LIST = '[data-test=ws-docs-page] [data-test=qto-file-tree]'
const listRows = (p) => p.$$eval(`${LIST} [data-test=file-tree-row]`, (els) => els.map((el) => `${el.getAttribute('aria-level')} ${el.textContent.trim()}`)).catch(() => [])
const heading = (p) => p.$eval('[data-test=ws-docs-heading]', (el) => el.textContent.trim()).catch(() => '')
const listIs = (p, names) => p.waitForFunction((sel, want) => {
  const got = [...document.querySelectorAll(sel)].map((el) => el.textContent.trim())
  return got.join('|') === want.join('|')
}, { timeout: STEP }, `${LIST} [data-test=file-tree-row]`, names).then(() => true, () => false)
async function tapRow(p, name) {
  const row = await p.evaluateHandle((sel, name) => [...document.querySelectorAll(sel)].find((el) => el.textContent.trim() === name) || null, `${LIST} [data-test=file-tree-row]`, name)
  if (!(await row.evaluate((el) => Boolean(el)))) return false
  await row.tap()
  return true
}
async function back(p) {
  await p.tap('[data-test=ws-docs-page] [data-testid=mobile-back]').catch(() => {})
}

/** t1 8bf89f96: the phone drills down, one level a screen, Back walks up */
async function drillDown(m) {
  ok('phone: no side tree and no Documents button', !(await shown(m, '#qto-file-tree')) && !(await m.$('[data-test=qto-file-tree-toggle]')))
  ok('phone: the first screen lists the top level only', await listIs(m, ['Handbook']) && (await listRows(m)).every((r) => r.startsWith('1 ')), await listRows(m))
  ok('phone: ... no Documents heading, with the Back chevron', !(await m.$('[data-test=ws-docs-heading]')) && await shown(m, '[data-test=ws-docs-page] [data-testid=mobile-back]'))
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-drill-phone-top.png` })
  await tapRow(m, 'Handbook')
  ok('phone: a tap on a document drills into its sections', await listIs(m, ['Introduction', 'Operations', 'Glossary']), await listRows(m))
  ok('phone: ... its path is the title, one history entry deeper', await heading(m) === 'Handbook' && new URL(m.url()).searchParams.get('in')?.startsWith('d:'), m.url())
  await tapRow(m, 'Introduction')
  ok('phone: a section with sections drills one level more', await listIs(m, ['Scope', 'Audience']) && await heading(m) === 'Handbook / Introduction', await listRows(m))
  const level = m.url()
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-drill-phone-folder.png` })
  await back(m)
  ok('phone: Back walks up one level', await listIs(m, ['Introduction', 'Operations', 'Glossary']) && await heading(m) === 'Handbook', await listRows(m))
  await tapRow(m, 'Glossary')
  await m.waitForFunction(() => new URL(location.href).searchParams.get('doc') && location.hash.startsWith('#ws-doc-'), { timeout: STEP }).catch(() => {})
  ok('phone: a row with nothing under it opens the document there', await m.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === 'Handbook', { timeout: STEP }).then(() => true, () => false) && !(await m.$(LIST)), m.url())
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-drill-phone-doc.png` })
  await back(m)
  ok('phone: Back from the document returns to its level', await listIs(m, ['Introduction', 'Operations', 'Glossary']), await listRows(m))
  await back(m)
  ok('phone: Back again, the top level', await listIs(m, ['Handbook']) && !(await m.$('[data-test=ws-docs-heading]')), await listRows(m))
  return level
}

const headingIs = (p, want) => p.waitForFunction((want) => document.querySelector('[data-test=ws-docs-heading]')?.textContent.trim() === want, { timeout: STEP }, want).then(() => true, () => false)

/* t1 3b8891e0 (c-983's finding): a level loaded fresh - a new tab, a reload,
   a shared link - has no history entry of ours below it. Back goes up one
   level a tap to the top of Documents, and only then leaves Documents.
   Control: before the fix the first Back left Documents for the section
   chooser, so the up-one-level checks FAIL. The in-app path is drillDown's. */
async function freshBack(browser, url) {
  const n = await browser.newPage()
  await n.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true })
  await n.goto(url, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await onPage(n)
  ok('390 fresh: a fresh load opens that level', await listIs(n, ['Scope', 'Audience']) && await headingIs(n, 'Handbook / Introduction'), [n.url(), await listRows(n)])
  await back(n)
  ok('390 fresh: Back goes up one level, to the document', await listIs(n, ['Introduction', 'Operations', 'Glossary']) && await headingIs(n, 'Handbook'), [n.url(), await listRows(n)])
  if (process.env.SHOT_DIR) await n.screenshot({ path: `${process.env.SHOT_DIR}/qto-fresh-back-390.png` })
  await back(n)
  ok('390 fresh: Back again, the top level has no Documents heading', await listIs(n, ['Handbook']) && await n.waitForFunction(() => !document.querySelector('[data-test=ws-docs-heading]'), { timeout: STEP }).then(() => true, () => false) && !new URL(n.url()).searchParams.has('in'), [n.url(), await listRows(n)])
  await back(n)
  ok('390 fresh: only from the top does Back leave Documents', await n.waitForFunction(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') === '1', { timeout: STEP }).then(() => true, () => false), n.url())
  await n.close()
}

/** a list panel of the sidebar that takes up room, by test id */
const panelShown = (p, id) => p.waitForFunction((sel) => {
  const el = document.querySelector(sel)
  return Boolean(el && el.getBoundingClientRect().width > 0)
}, { timeout: STEP }, `[data-testid=sidebar-panel-${id}]`).then(() => true, () => false)

/** open Docs (Qto) from a conversation, then one rail tab */
async function fromQto(p, tab) {
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=qto-open]', { visible: true, timeout: STEP })
  await p.click('[data-testid=qto-open]')
  await p.waitForFunction(() => location.pathname === '/workspace/docs', { timeout: STEP }).catch(() => {})
  await onPage(p)
  if (tab === 'channels' && process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-rail-1440-docs.png` })
  await p.click(`[data-testid=sidebar-tab-${tab}]`)
  return p.waitForFunction(() => location.pathname !== '/workspace/docs', { timeout: STEP }).then(() => true, () => false)
}

/* Owner (t1 777d6c9a): once in Docs (Qto) on a desktop one cannot get
   back to the channels; the left-most sections strip
   freezes. On a desktop /workspace/docs keeps the rail only, so a tab that
   only switched the hidden list changed nothing. Control: before the fix
   Channels, Direct messages and Flow stay on /workspace/docs with no list
   panel, so those checks FAIL. */
async function railLeavesQto(p) {
  ok('1440: Channels leaves Docs (Qto)', await fromQto(p, 'channels'), p.url())
  ok('1440: ... back to the conversation, the Channels list shown', new URL(p.url()).pathname === '/lobby' && await panelShown(p, 'channels'), p.url())
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-rail-1440-channels.png` })
  ok('1440: Direct messages leaves Docs (Qto), its list shown', await fromQto(p, 'dm') && await panelShown(p, 'dm'), p.url())
  ok('1440: Flow leaves Docs (Qto), its list shown', await fromQto(p, 'flow') && await panelShown(p, 'flow'), p.url())
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

  console.log('-- 1440x900 the rail leaves Docs (Qto)')
  const d = await browser.newPage()
  await d.setViewport({ width: 1440, height: 900 })
  await railLeavesQto(d)
  await d.close()

  console.log('-- 1440x900 folders')
  const f = await browser.newPage()
  await f.setViewport({ width: 1440, height: 900 })
  await desktopFolders(f)
  await f.close()

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
  const level = await drillDown(m)
  ok('phone: a tree row is a 44 px target', await m.$eval(`${LIST} [data-test=file-tree-row]`, (el) => el.getBoundingClientRect().height >= 44).catch(() => false))
  const held = await m.$eval(`${LIST} [data-kind=doc]`, (el) => { const r = el.getBoundingClientRect(); return { x: r.left + 60, y: r.top + r.height / 2 } }).catch(() => null)
  if (held) {
    await m.touchscreen.touchStart(held.x, held.y)
    await new Promise((r) => setTimeout(r, 800))
    await m.touchscreen.touchEnd()
  }
  ok('phone: a long press on a document opens its menu as a sheet', await menuShown(m) && await m.$eval(MENU, (el) => el.classList.contains('touch-sheet')).catch(() => false))
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-doc-menu-phone.png` })
  await m.keyboard.press('Escape')
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-file-tree-phone.png` })
  await phoneFolders(m)
  await m.close()

  console.log('-- 390x740 phone, a level loaded fresh')
  await freshBack(browser, level)

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
