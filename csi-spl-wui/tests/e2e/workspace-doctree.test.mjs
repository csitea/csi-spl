// Spec 113 T006: the workspace document's two views over one tree. Drives
// add / move / delete in the doc view, reads the outline, reads the same
// outline in the grid, drives add / move / delete in the grid, and reads it
// back in a freshly mounted doc view. Then a 412: another writer moves the
// doc rev on (the mock's test hook), the next op shows the reload prompt and
// commits nothing. Then print branch renders one subtree for print CSS.
//
//   node tests/e2e/workspace-doctree.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/workspace-doctree.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const STEP = 10000
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

/** the visible outline of a view ('doc' | 'grid'): "<number> <title>" per row */
function outline(p, v) {
  return p.evaluate((v) => [...document.querySelectorAll(`[data-test=ws-${v}-row]`)].map((r) => {
    const num = r.querySelector(`[data-test=ws-${v}-num]`)?.textContent?.trim() ?? ''
    const title = r.querySelector(`[data-test=ws-${v}-title]`)?.textContent?.trim() ?? '(editing)'
    return `${num} ${title}`
  }), v)
}

/** wait until the view's outline equals want; returns what it last read */
async function outlineIs(p, v, want) {
  await p.waitForFunction((v, want) => {
    const got = [...document.querySelectorAll(`[data-test=ws-${v}-row]`)].map((r) => {
      const num = r.querySelector(`[data-test=ws-${v}-num]`)?.textContent?.trim() ?? ''
      const title = r.querySelector(`[data-test=ws-${v}-title]`)?.textContent?.trim() ?? '(editing)'
      return `${num} ${title}`
    })
    return JSON.stringify(got) === JSON.stringify(want)
  }, { timeout: STEP }, v, want).catch(() => null)
  return outline(p, v)
}

/** open the item menu of the row titled title and choose op */
async function menu(p, v, title, op) {
  const idx = await p.evaluate((v, title) => [...document.querySelectorAll(`[data-test=ws-${v}-row]`)]
    .findIndex((r) => r.querySelector(`[data-test=ws-${v}-title]`)?.textContent?.trim() === title), v, title)
  if (idx < 0) throw new Error(`no ${v} row titled ${title}`)
  const btns = await p.$$(`[data-test=ws-${v}-row] [data-test=ws-${v}-menu-btn]`)
  await btns[idx].click()
  const item = await p.waitForSelector(`[data-testid="ws-${v}-menu-${op}"]`, { visible: true, timeout: STEP })
  await item.click()
}

/** type a title into the cell the add just opened, and commit it */
async function name(p, v, title) {
  const sel = v === 'doc' ? '[data-test=ws-doc-title-input]' : '[data-test=ws-grid-input-title]'
  await p.waitForSelector(sel, { visible: true, timeout: STEP })
  await p.waitForFunction((sel) => document.activeElement === document.querySelector(sel), { timeout: STEP }, sel)
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.type(title)
  await p.keyboard.press('Enter')
  await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: STEP }, sel)
}

async function del(p, v, title) {
  await menu(p, v, title, 'delete')
  const yes = await p.waitForSelector(`[data-testid=ws-${v}-delete-confirm]`, { visible: true, timeout: STEP })
  await yes.click()
}

async function view(p, v) {
  await p.click(`[data-test=ws-docs-view-${v}]`)
  await p.waitForSelector(`[data-test=ws-${v}-view]`, { visible: true, timeout: STEP })
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: NAV_TIMEOUT })

  /* a new, empty document */
  await p.type('[data-test=ws-docs-new-title]', 'E2E outline')
  await p.click('[data-test=ws-docs-create]')
  const empty = await p.waitForSelector('[data-test=ws-doc-add-first]', { visible: true, timeout: STEP }).catch(() => null)
  ok('a new document opens empty in the doc view', Boolean(empty))
  await empty.click()
  await name(p, 'doc', 'Alpha')

  /* doc view: add sibling / child, move up, indent, delete */
  await menu(p, 'doc', 'Alpha', 'add_sibling')
  await name(p, 'doc', 'Beta')
  await menu(p, 'doc', 'Beta', 'add_sibling')
  await name(p, 'doc', 'Gamma')
  await menu(p, 'doc', 'Beta', 'add_child')
  await name(p, 'doc', 'Beta child')
  let got = await outlineIs(p, 'doc', ['1 Alpha', '2 Beta', '2.1 Beta child', '3 Gamma'])
  ok('doc view: add sibling and add child', JSON.stringify(got) === JSON.stringify(['1 Alpha', '2 Beta', '2.1 Beta child', '3 Gamma']), got)

  await menu(p, 'doc', 'Gamma', 'up')
  await outlineIs(p, 'doc', ['1 Alpha', '2 Gamma', '3 Beta', '3.1 Beta child'])
  await menu(p, 'doc', 'Gamma', 'indent')
  await menu(p, 'doc', 'Beta', 'add_sibling')
  await name(p, 'doc', 'Doomed')
  await del(p, 'doc', 'Doomed')
  const afterDoc = ['1 Alpha', '1.1 Gamma', '2 Beta', '2.1 Beta child']
  got = await outlineIs(p, 'doc', afterDoc)
  ok('doc view: move up, indent and delete branch', JSON.stringify(got) === JSON.stringify(afterDoc), got)

  /* the grid shows the same outline */
  await view(p, 'grid')
  got = await outlineIs(p, 'grid', afterDoc)
  ok('grid view reads the same outline back', JSON.stringify(got) === JSON.stringify(afterDoc), got)

  /* grid: outdent, add child, delete */
  await menu(p, 'grid', 'Beta child', 'outdent')
  await menu(p, 'grid', 'Alpha', 'add_child')
  await name(p, 'grid', 'Delta')
  await del(p, 'grid', 'Gamma')
  const afterGrid = ['1 Alpha', '1.1 Delta', '2 Beta', '3 Beta child']
  got = await outlineIs(p, 'grid', afterGrid)
  ok('grid view: outdent, add child and delete branch', JSON.stringify(got) === JSON.stringify(afterGrid), got)

  /* grid filter and sort (the hub's grid read) */
  await p.type('[data-test=ws-grid-filter]', 'beta')
  got = await outlineIs(p, 'grid', ['2 Beta', '3 Beta child'])
  ok('grid filter keeps the matching rows', JSON.stringify(got) === JSON.stringify(['2 Beta', '3 Beta child']), got)
  await p.focus('[data-test=ws-grid-filter]')
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  await outlineIs(p, 'grid', afterGrid)
  await p.click('[data-test=ws-grid-sort-title]')
  await p.click('[data-test=ws-grid-sort-title]')
  const byTitleDesc = ['1.1 Delta', '3 Beta child', '2 Beta', '1 Alpha']
  got = await outlineIs(p, 'grid', byTitleDesc)
  ok('grid sorts by title, descending on a second click', JSON.stringify(got) === JSON.stringify(byTitleDesc), got)

  /* a fresh doc view: lazy (a collapsed node's children are not loaded), then the same outline */
  await view(p, 'doc')
  got = await outlineIs(p, 'doc', ['1 Alpha', '2 Beta', '3 Beta child'])
  ok('doc view loads the top level only', JSON.stringify(got) === JSON.stringify(['1 Alpha', '2 Beta', '3 Beta child']), got)
  const toggles = await p.$$('[data-test=ws-doc-row] [data-test=ws-doc-toggle]')
  await toggles[0].click()
  got = await outlineIs(p, 'doc', afterGrid)
  ok('doc view reads the grid\'s outline back after an expand', JSON.stringify(got) === JSON.stringify(afterGrid), got)

  /* a 412: another writer moved the doc rev on; the op shows the reload prompt */
  await p.evaluate(() => window.__wsDocTreeBump())
  await menu(p, 'doc', 'Beta', 'add_sibling')
  const stale = await p.waitForSelector('[data-test=ws-docs-stale]', { visible: true, timeout: STEP }).catch(() => null)
  ok('a 412 shows the reload prompt', Boolean(stale))
  got = await outline(p, 'doc')
  ok('the refused op added nothing', !got.some((r) => r.includes('Untitled')), got)
  await p.click('[data-test=ws-docs-reload]')
  await p.waitForFunction(() => !document.querySelector('[data-test=ws-docs-stale]'), { timeout: STEP }).catch(() => null)
  await menu(p, 'doc', 'Beta', 'add_sibling')
  await name(p, 'doc', 'After reload')
  got = await outlineIs(p, 'doc', ['1 Alpha', '2 Beta', '3 After reload', '4 Beta child'])
  ok('after reload the next op commits', JSON.stringify(got) === JSON.stringify(['1 Alpha', '2 Beta', '3 After reload', '4 Beta child']), got)

  /* print branch: one subtree, the browser's print */
  await p.evaluate(() => { window.__printed = 0; window.print = () => { window.__printed++ } })
  await menu(p, 'doc', 'Alpha', 'print')
  await p.waitForFunction(() => window.__printed === 1, { timeout: STEP }).catch(() => null)
  const printed = await p.evaluate(() => ({
    calls: window.__printed,
    cls: document.documentElement.classList.contains('ws-doc-printing'),
    items: [...document.querySelectorAll('[data-test=ws-doc-print-item]')].map((e) => e.textContent.replace(/\s+/g, ' ').trim()),
  }))
  ok('print branch prints the item and its subtree', printed.calls === 1 && printed.cls && JSON.stringify(printed.items) === JSON.stringify(['1 Alpha', '1.1 Delta']), printed)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `workspace-doctree: ${failed} FAILED` : `workspace-doctree: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
