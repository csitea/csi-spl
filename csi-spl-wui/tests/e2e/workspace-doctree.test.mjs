// Spec 113 T006: the workspace document's two views over one tree. Drives
// add / move / delete in the doc view, reads the outline, reads the same
// outline in the grid, drives add / move / delete in the grid, and reads it
// back in a freshly mounted doc view. Then a 412: another writer moves the
// doc rev on (the mock's test hook), the next op shows the reload prompt and
// commits nothing. Then print branch renders one subtree for print CSS.
// The doc view is Qto's view-doc (t1 519a4ee9): one continuous document,
// titles and texts edited in place, a contents panel whose links scroll,
// a search box, and print (contents first, a page break, the document).
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

/** the visible outline of a view ('doc' | 'grid'): "<number> <title>" per row
    (the doc view's titles are textareas, edited in place: their value) */
function outline(p, v) {
  return p.evaluate((v) => [...document.querySelectorAll(`[data-test=ws-${v}-row]`)].map((r) => {
    const num = r.querySelector(`[data-test=ws-${v}-num]`)?.textContent?.trim() ?? ''
    const el = r.querySelector(`[data-test=ws-${v}-title]`)
    const title = el ? (el.tagName === 'TEXTAREA' ? el.value : el.textContent).trim() : '(editing)'
    return `${num} ${title}`
  }), v)
}

/** wait until the view's outline equals want; returns what it last read */
async function outlineIs(p, v, want) {
  await p.waitForFunction((v, want) => {
    const got = [...document.querySelectorAll(`[data-test=ws-${v}-row]`)].map((r) => {
      const num = r.querySelector(`[data-test=ws-${v}-num]`)?.textContent?.trim() ?? ''
      const el = r.querySelector(`[data-test=ws-${v}-title]`)
      const title = el ? (el.tagName === 'TEXTAREA' ? el.value : el.textContent).trim() : '(editing)'
      return `${num} ${title}`
    })
    return JSON.stringify(got) === JSON.stringify(want)
  }, { timeout: STEP }, v, want).catch(() => null)
  return outline(p, v)
}

/** open the item menu of the row titled title and choose op (the doc
    view's menu is on the item's number, as Qto's) */
async function menu(p, v, title, op) {
  const idx = await p.evaluate((v, title) => [...document.querySelectorAll(`[data-test=ws-${v}-row]`)]
    .findIndex((r) => {
      const el = r.querySelector(`[data-test=ws-${v}-title]`)
      return (el?.tagName === 'TEXTAREA' ? el.value : el?.textContent)?.trim() === title
    }), v, title)
  if (idx < 0) throw new Error(`no ${v} row titled ${title}`)
  const btns = await p.$$(`[data-test=ws-${v}-row] [data-test=ws-${v}-${v === 'doc' ? 'num' : 'menu-btn'}]`)
  await btns[idx].click()
  const item = await p.waitForSelector(`[data-testid="ws-${v}-menu-${op}"]`, { visible: true, timeout: STEP })
  await item.click()
}

/** type a title into the cell the add just opened, and commit it */
async function name(p, v, title) {
  if (v === 'doc') {
    /* the new item's title is focused in place; Enter commits and leaves it */
    await p.waitForFunction(() => document.activeElement?.dataset?.test === 'ws-doc-title', { timeout: STEP })
    await p.keyboard.down('Control')
    await p.keyboard.press('KeyA')
    await p.keyboard.up('Control')
    await p.keyboard.type(title)
    await p.keyboard.press('Enter')
    await p.waitForFunction(() => document.activeElement?.dataset?.test !== 'ws-doc-title', { timeout: STEP })
    return
  }
  const sel = '[data-test=ws-grid-input-title]'
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

  /* a fresh doc view: one continuous document, the grid's outline */
  await view(p, 'doc')
  got = await outlineIs(p, 'doc', afterGrid)
  ok('doc view reads the grid\'s outline back as one document', JSON.stringify(got) === JSON.stringify(afterGrid), got)

  /* the contents panel: the same numbered outline, indented by level */
  const toc = await p.evaluate(() => [...document.querySelectorAll('[data-test=ws-doc-toc-item]')].map((li) => ({
    text: li.textContent.replace(/\s+/g, ' ').trim(), pad: parseFloat(getComputedStyle(li).paddingInlineStart),
  })))
  ok('contents list the outline, a child indented', JSON.stringify(toc.map((x) => x.text)) === JSON.stringify(afterGrid) && toc[1].pad > toc[0].pad, toc)

  /* edit in place: a title and a text, committed on leave, read back after a remount */
  const titleOf = (t) => `[data-test=ws-doc-row][data-outline="${t}"]`
  await p.click(`${titleOf('2')} [data-test=ws-doc-title]`)
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.type('Beta edited')
  await p.keyboard.press('Enter')
  await p.click(`${titleOf('2')} [data-test=ws-doc-text]`)
  await p.keyboard.type('A paragraph under Beta.')
  await p.click('[data-test=ws-doc-search]')
  await view(p, 'grid')
  await view(p, 'doc')
  await outlineIs(p, 'doc', ['1 Alpha', '1.1 Delta', '2 Beta edited', '3 Beta child'])
  const edited = await p.evaluate((sel) => ({
    title: document.querySelector(`${sel} [data-test=ws-doc-title]`)?.value,
    text: document.querySelector(`${sel} [data-test=ws-doc-text]`)?.value,
  }), titleOf('2'))
  ok('title and text are edited in place and saved', edited.title === 'Beta edited' && edited.text === 'A paragraph under Beta.', edited)

  /* a contents link scrolls its heading in and puts its anchor in the URL */
  await p.setViewport({ width: 1280, height: 360 })
  const last = await p.$$('[data-test=ws-doc-toc-item] a')
  await last[last.length - 1].click()
  await new Promise((r) => setTimeout(r, 300))
  const scrolled = await p.evaluate(() => {
    const row = [...document.querySelectorAll('[data-test=ws-doc-row]')].at(-1)
    const h = row.querySelector('h3')
    const r = h.getBoundingClientRect()
    return { top: r.top, bottom: r.bottom, vh: innerHeight, hash: location.hash, id: h.id, scroller: document.querySelector('.wsdocs-page .feed-body')?.scrollTop ?? 0 }
  })
  ok('a contents click scrolls to the heading', scrolled.hash === '#' + scrolled.id && scrolled.scroller > 0 && scrolled.top >= 0 && scrolled.bottom <= scrolled.vh, scrolled)
  await p.setViewport({ width: 1280, height: 800 })

  /* the search box keeps the matching items, in the document and the contents */
  await p.type('[data-test=ws-doc-search]', 'beta')
  got = await outlineIs(p, 'doc', ['2 Beta edited', '3 Beta child'])
  const tocHits = await p.$$eval('[data-test=ws-doc-toc-item]', (l) => l.length)
  ok('search filters the items', JSON.stringify(got) === JSON.stringify(['2 Beta edited', '3 Beta child']) && tocHits === 2, { got, tocHits })
  await p.focus('[data-test=ws-doc-search]')
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  got = await outlineIs(p, 'doc', ['1 Alpha', '1.1 Delta', '2 Beta edited', '3 Beta child'])
  ok('an empty search shows the whole document again', got.length === 4, got)

  /* a 412: another writer moved the doc rev on; the op shows the reload prompt */
  await p.evaluate(() => window.__wsDocTreeBump())
  await menu(p, 'doc', 'Beta edited', 'add_sibling')
  const stale = await p.waitForSelector('[data-test=ws-docs-stale]', { visible: true, timeout: STEP }).catch(() => null)
  ok('a 412 shows the reload prompt', Boolean(stale))
  got = await outline(p, 'doc')
  ok('the refused op added nothing', !got.some((r) => r.includes('Untitled')), got)
  await p.click('[data-test=ws-docs-reload]')
  await p.waitForFunction(() => !document.querySelector('[data-test=ws-docs-stale]'), { timeout: STEP }).catch(() => null)
  await menu(p, 'doc', 'Beta edited', 'add_sibling')
  await name(p, 'doc', 'After reload')
  const afterReload = ['1 Alpha', '1.1 Delta', '2 Beta edited', '3 After reload', '4 Beta child']
  got = await outlineIs(p, 'doc', afterReload)
  ok('after reload the next op commits', JSON.stringify(got) === JSON.stringify(afterReload), got)

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
  await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))

  /* print document: the contents first, a page break, then every item */
  await p.click('[data-test=ws-doc-print-doc]')
  await p.waitForFunction(() => window.__printed === 2, { timeout: STEP }).catch(() => null)
  const whole = await p.evaluate(() => {
    const art = document.querySelector('[data-test=ws-doc-print]')
    const kids = art ? [...art.children].map((e) => e.dataset.test || e.tagName) : []
    const brk = document.querySelector('[data-test=ws-doc-print-break]')
    return {
      calls: window.__printed,
      order: kids.filter((k) => k !== 'H1').slice(0, 2),
      toc: [...document.querySelectorAll('[data-test=ws-doc-print-toc-item]')].map((e) => e.textContent.replace(/\s+/g, ' ').trim()),
      items: [...document.querySelectorAll('[data-test=ws-doc-print-item]')].length,
      breakRule: brk ? [...document.styleSheets].flatMap((s) => { try { return [...s.cssRules] } catch { return [] } })
        .some((r) => r.media && [...r.cssRules].some((x) => x.selectorText === '.ws-doc-print__break' && x.style.breakAfter === 'page')) : false,
    }
  })
  ok('print document: contents first, a page break, then the document', whole.calls === 2 && JSON.stringify(whole.order) === JSON.stringify(['ws-doc-print-toc', 'ws-doc-print-break'])
    && JSON.stringify(whole.toc) === JSON.stringify(afterReload) && whole.items === afterReload.length && whole.breakRule, whole)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `workspace-doctree: ${failed} FAILED` : `workspace-doctree: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
