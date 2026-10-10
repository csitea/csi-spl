// Spec 113 T006: the workspace document's two views over one tree. Drives
// add / move / delete in the doc view, reads the outline, reads the same
// outline in the grid, drives add / move / delete in the grid, and reads it
// back in a freshly mounted doc view. Then a 412: another writer moves the
// doc rev on (the mock's test hook), the next op shows the reload prompt and
// commits nothing. Then print branch renders one subtree for print CSS.
// The doc view is Qto's view-doc (t1 519a4ee9): one continuous document,
// titles and texts edited in place, a contents panel whose links scroll,
// a search box, and print (contents first, a page break, the document).
// The hub follow-up (owner go 33ced864): the document renamed in place (a
// cleared title is the default), a code block and an uploaded image added
// to a section and edited there, each read back from the hub.
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
    return `${num} ${title}`.trim()
  }), v)
}

/** wait until the view's outline equals want; returns what it last read */
async function outlineIs(p, v, want) {
  await p.waitForFunction((v, want) => {
    const got = [...document.querySelectorAll(`[data-test=ws-${v}-row]`)].map((r) => {
      const num = r.querySelector(`[data-test=ws-${v}-num]`)?.textContent?.trim() ?? ''
      const el = r.querySelector(`[data-test=ws-${v}-title]`)
      const title = el ? (el.tagName === 'TEXTAREA' ? el.value : el.textContent).trim() : '(editing)'
      return `${num} ${title}`.trim()
    })
    return JSON.stringify(got) === JSON.stringify(want)
  }, { timeout: STEP }, v, want).catch(() => null)
  return outline(p, v)
}

/** open the item menu of the row titled title and choose op. The doc
    view's menu opens as the owner asked (t1 519a4ee9, msg dd291fb8): a
    right-click on the title; how = 'dots' clicks Qto's dots control instead. */
async function menu(p, v, title, op, how = v === 'doc' ? 'right' : 'dots') {
  const idx = await p.evaluate((v, title) => [...document.querySelectorAll(`[data-test=ws-${v}-row]`)]
    .findIndex((r) => {
      const el = r.querySelector(`[data-test=ws-${v}-title]`)
      return (el?.tagName === 'TEXTAREA' ? el.value : el?.textContent)?.trim() === title
    }), v, title)
  if (idx < 0) throw new Error(`no ${v} row titled ${title}`)
  /* clear of the sticky tool bar, which would take the click */
  await p.evaluate((v, idx) => document.querySelectorAll(`[data-test=ws-${v}-row]`)[idx].scrollIntoView({ block: 'center' }), v, idx)
  if (how === 'right') {
    const titles = await p.$$(`[data-test=ws-${v}-row] [data-test=ws-${v}-title]`)
    await titles[idx].click({ button: 'right' })
  } else {
    const btns = await p.$$(`[data-test=ws-${v}-row] [data-test=ws-${v}-menu-btn]`)
    await btns[idx].click()
  }
  const item = await p.waitForSelector(`[data-testid="ws-${v}-menu-${op}"]`, { visible: true, timeout: STEP }).catch(async (e) => {
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/ws-doctree-menu-${op}.png`, fullPage: true })
    throw e
  })
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

  /* a new document never starts from nothing (t1 519a4ee9): its title, then
     the starter headings 1 / 1.1 / 1.1.1 as placeholders, a paragraph
     placeholder under levels 2 and 3 only */
  await p.type('[data-test=ws-docs-new-title]', 'E2E outline')
  await p.click('[data-test=ws-docs-create]')
  let got = await outlineIs(p, 'doc', ['1', '1.1', '1.1.1'])
  const starter = await p.evaluate(() => ({
    title: document.querySelector('[data-test=ws-doc-doctitle]')?.textContent?.trim(),
    rows: [...document.querySelectorAll('[data-test=ws-doc-row]')].map((r) => [
      r.querySelector('[data-test=ws-doc-title]').placeholder, r.querySelector('[data-test=ws-doc-text]').placeholder]),
  }))
  ok('a new document opens with its title and the starter outline', JSON.stringify(got) === JSON.stringify(['1', '1.1', '1.1.1'])
    && starter.title === 'E2E outline' && JSON.stringify(starter.rows) === JSON.stringify([['Heading 1', ''], ['Heading 1.1', 'Paragraph text'], ['Heading 1.1.1', 'Paragraph text']]), { got, starter })

  /* every section action is on the title's right-click, and on Qto's dots */
  const opsOf = () => p.$$eval('[data-testid^="ws-doc-menu-"][role=menuitem]', (l) => l.map((e) => e.dataset.testid.replace('ws-doc-menu-', '')))
  const titles = await p.$$('[data-test=ws-doc-row] [data-test=ws-doc-title]')
  await titles[0].click({ button: 'right' })
  await p.waitForSelector('[data-testid="ws-doc-menu-add_paragraph"]', { visible: true, timeout: STEP }).catch(() => null)
  const rightOps = await opsOf()
  await p.keyboard.press('Escape')
  const dots = await p.$$('[data-test=ws-doc-row] [data-test=ws-doc-menu-btn]')
  await dots[1].click({ button: 'right' })
  await p.waitForSelector('[data-testid="ws-doc-menu-delete"]', { visible: true, timeout: STEP }).catch(() => null)
  const dotOps = await opsOf()
  const labels = await p.$$eval('[data-testid^="ws-doc-menu-"][role=menuitem]', (l) => l.map((e) => e.textContent.trim()))
  await p.keyboard.press('Escape')
  ok('right-click on a title opens the section menu, Add paragraph first on level 1', rightOps[0] === 'add_paragraph' && rightOps.includes('outdent') && rightOps.includes('indent') && rightOps.includes('delete'), rightOps)
  ok('Qto\'s dots open the same menu; Promote / Demote are the labels', dotOps.includes('add_child') && !dotOps.includes('add_paragraph') && labels.some((l) => l.startsWith('Promote')) && labels.some((l) => l.startsWith('Demote')), { dotOps, labels })

  /* the starter is the user's to overwrite or remove: delete it, then the empty state */
  await del(p, 'doc', '')
  const empty = await p.waitForSelector('[data-test=ws-doc-add-first]', { visible: true, timeout: STEP }).catch(() => null)
  ok('deleting the starter branch leaves the empty document', Boolean(empty))
  await empty.click()
  await name(p, 'doc', 'Alpha')

  /* doc view: add sibling / child, move up, indent, delete */
  await menu(p, 'doc', 'Alpha', 'add_sibling')
  await name(p, 'doc', 'Beta')
  await menu(p, 'doc', 'Beta', 'add_sibling')
  await name(p, 'doc', 'Gamma')
  await menu(p, 'doc', 'Beta', 'add_child')
  await name(p, 'doc', 'Beta child')
  got = await outlineIs(p, 'doc', ['1 Alpha', '2 Beta', '2.1 Beta child', '3 Gamma'])
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
  await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))

  /* Qto parity: open the branch alone, export it to Markdown and CSV, '/' focuses the search, Enter searches every document */
  await menu(p, 'doc', 'Alpha', 'open_branch')
  got = await outlineIs(p, 'doc', ['1 Alpha', '1.1 Delta'])
  const chip = await p.$('[data-test=ws-doc-branch]')
  ok('open branch shows that branch alone', JSON.stringify(got) === JSON.stringify(['1 Alpha', '1.1 Delta']) && Boolean(chip), got)
  await p.click('[data-test=ws-doc-branch-clear]')
  await outlineIs(p, 'doc', afterReload)
  await menu(p, 'doc', 'Alpha', 'open_list')
  await p.waitForSelector('[data-test=ws-grid-view]', { visible: true, timeout: STEP }).catch(() => null)
  got = await outlineIs(p, 'grid', ['1 Alpha', '1.1 Delta'])
  const gq = await p.evaluate(() => ({ filter: document.querySelector('[data-test=ws-grid-filter]')?.value, q: new URL(location.href).searchParams.get('q') }))
  ok('open as list opens the grid on that branch', JSON.stringify(got) === JSON.stringify(['1 Alpha', '1.1 Delta']) && gq.filter === '1' && gq.q === '1', { got, gq })
  await view(p, 'doc')
  await outlineIs(p, 'doc', afterReload)

  await p.evaluate(() => {
    window.__exports = []
    const make = URL.createObjectURL
    URL.createObjectURL = (b) => { b.text().then((t) => window.__exports.push(t)); return make.call(URL, b) }
    HTMLAnchorElement.prototype.click = function () { if (this.download) window.__exportNames = [...(window.__exportNames || []), this.download] }
  })
  await menu(p, 'doc', 'Alpha', 'export_md')
  await p.waitForFunction(() => window.__exports.length === 1, { timeout: STEP }).catch(() => null)
  await menu(p, 'doc', 'Alpha', 'export_csv')
  await p.waitForFunction(() => window.__exports.length === 2, { timeout: STEP }).catch(() => null)
  const ex = await p.evaluate(() => ({ files: window.__exportNames, md: window.__exports[0], csv: window.__exports[1] }))
  ok('export to Markdown and CSV carry the branch', JSON.stringify(ex.files) === JSON.stringify(['E2E-outline-1.md', 'E2E-outline-1.csv'])
    && /^# 1 Alpha\n/.test(ex.md || '') && (ex.md || '').includes('## 1.1 Delta') && !(ex.md || '').includes('Beta')
    && (ex.csv || '').split('\r\n').filter(Boolean).length === 3, ex)

  const wasOn = await p.evaluate(() => { document.activeElement?.blur(); return document.activeElement?.tagName })
  await p.keyboard.press('/')
  const slash = await p.evaluate(() => document.activeElement?.dataset?.test || document.activeElement?.tagName)
  ok("'/' focuses the search box", slash === 'ws-doc-search', { wasOn, slash })
  await p.keyboard.type('introduction')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=ws-doc-hit]', { visible: true, timeout: STEP }).catch(() => null)
  const hit = await p.$$eval('[data-test=ws-doc-hit]', (l) => l.map((e) => e.textContent.replace(/\s+/g, ' ').trim()))
  ok('Enter searches every document', hit.length === 1 && hit[0].includes('Handbook') && hit[0].includes('Introduction'), hit)
  await p.click('[data-test=ws-doc-hits-close]')
  await p.focus('[data-test=ws-doc-search]')
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  await outlineIs(p, 'doc', afterReload)

  /* create, update, delete, then a reload re-reads the document from the hub
     (the part Qto got wrong, t1 519a4ee9 msg 1ecb465b) */
  const titleSel = (n) => `[data-test=ws-doc-row][data-outline="${n}"]`
  const typeInto = async (sel, text) => {
    await p.click(sel)
    await p.keyboard.down('Control')
    await p.keyboard.press('KeyA')
    await p.keyboard.up('Control')
    await p.keyboard.type(text)
    await p.click('[data-test=ws-doc-doctitle]')
  }
  /* a level-1 section has no paragraph until "Add paragraph" (msgs 9debc0df, ab5b890e) */
  await menu(p, 'doc', 'Alpha', 'add_paragraph')
  await p.waitForFunction(() => document.activeElement?.dataset?.test === 'ws-doc-text', { timeout: STEP }).catch(() => null)
  await p.keyboard.type('Level-1 paragraph, see https://example.com/qto')
  await p.click('[data-test=ws-doc-doctitle]')
  await menu(p, 'doc', 'Beta child', 'add_child')
  await name(p, 'doc', 'New child')
  await menu(p, 'doc', 'New child', 'add_parent')
  await name(p, 'doc', 'New parent')
  await menu(p, 'doc', 'After reload', 'add_sibling')
  await name(p, 'doc', 'New sibling')
  await menu(p, 'doc', 'Delta', 'outdent')
  await typeInto(`${titleSel('3')} [data-test=ws-doc-title]`, 'Beta renamed')
  await typeInto(`${titleSel('3')} [data-test=ws-doc-text]`, 'Text edited in place.')
  await del(p, 'doc', 'New sibling')
  const wantCrud = ['1 Alpha', '2 Delta', '3 Beta renamed', '4 After reload', '5 Beta child', '5.1 New parent', '5.1.1 New child']
  got = await outlineIs(p, 'doc', wantCrud)
  ok('add sibling / child / parent, promote, edit and delete in one session', JSON.stringify(got) === JSON.stringify(wantCrud), got)
  const links = await p.$$eval(`${titleSel('1')} [data-test=ws-doc-links] a`, (l) => l.map((a) => a.href))
  ok('a link in a text is clickable under it (Qto lnkMayBe)', JSON.stringify(links) === JSON.stringify(['https://example.com/qto']), links)

  /* the CONTROL: another writer renames Alpha behind the page; only a real re-read shows it */
  const docOf = await p.$eval('[data-test=ws-docs-select]', (e) => e.value)
  const alpha = await p.$eval(titleSel('1'), (e) => e.dataset.id)
  const sub = await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}/subtree`), docOf)
  const alphaRev = sub.items.find((x) => x.id === alpha).rev
  await p.evaluate((d, id, rev) => window.__wsDocTreeCall('PATCH', `/${d}/items/${id}`, { field: 'title', value: 'Alpha (other writer)', rev }), docOf, alpha, alphaRev)
  const beforeReload = await outline(p, 'doc')
  const otherDoc = await p.$$eval('[data-test=ws-docs-select] option', (o, d) => o.map((x) => x.value).find((v) => v !== d), docOf)
  await p.select('[data-test=ws-docs-select]', otherDoc)
  await p.waitForFunction((d) => new URL(location.href).searchParams.get('doc') === d, { timeout: STEP }, otherDoc).catch(() => null)
  await p.select('[data-test=ws-docs-select]', docOf)
  const wantReloaded = ['1 Alpha (other writer)', ...wantCrud.slice(1)]
  got = await outlineIs(p, 'doc', wantReloaded)
  const texts = await p.evaluate((a, b) => [document.querySelector(`${a} [data-test=ws-doc-text]`)?.value, document.querySelector(`${b} [data-test=ws-doc-text]`)?.value], titleSel('1'), titleSel('3'))
  ok('CONTROL: before the reload the page still shows its own copy', beforeReload[0] === '1 Alpha', beforeReload)
  ok('after a reload every create, update and delete is still there (read from the hub)', JSON.stringify(got) === JSON.stringify(wantReloaded)
    && texts[0] === 'Level-1 paragraph, see https://example.com/qto' && texts[1] === 'Text edited in place.', { got, texts })

  /* rename in place (the hub's PATCH /{doc}); cleared, it is the default title.
     The CONTROL reads the title back from the hub, not from the page */
  const renameTo = async (text) => {
    await p.click('[data-test=ws-doc-doctitle]')
    await p.keyboard.down('Control')
    await p.keyboard.press('KeyA')
    await p.keyboard.up('Control')
    if (text) await p.keyboard.type(text)
    else await p.keyboard.press('Backspace')
    await p.keyboard.press('Enter')
  }
  const docTitles = async () => ({
    h: await p.$eval('[data-test=ws-doc-doctitle]', (e) => e.textContent.trim()),
    sel: await p.$eval('[data-test=ws-docs-select]', (e) => e.selectedOptions[0]?.textContent?.trim()),
    hub: (await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}`), docOf)).title,
  })
  await renameTo('Renamed doc')
  await p.waitForFunction(() => document.querySelector('[data-test=ws-docs-select]').selectedOptions[0]?.textContent?.trim() === 'Renamed doc', { timeout: STEP }).catch(() => null)
  const named = await docTitles()
  await renameTo('')
  await p.waitForFunction(() => document.querySelector('[data-test=ws-docs-select]').selectedOptions[0]?.textContent?.trim() === 'Untitled document', { timeout: STEP }).catch(() => null)
  const cleared = await docTitles()
  ok('rename the document in place; clearing the title brings "Untitled document" back (read from the hub)',
    named.h === 'Renamed doc' && named.sel === 'Renamed doc' && named.hub === 'Renamed doc'
    && cleared.h === 'Untitled document' && cleared.sel === 'Untitled document' && cleared.hub === 'Untitled document', { named, cleared })
  /* back to a title of its own: the Create check below waits for "Untitled document"
     on the NEW document, which this one must not already show */
  await renameTo('E2E outline')
  await p.waitForFunction(() => document.querySelector('[data-test=ws-docs-select]').selectedOptions[0]?.textContent?.trim() === 'E2E outline', { timeout: STEP }).catch(() => null)

  /* a code block: the menu adds it to the section, edited in place, kept on the item */
  const attrsOf = async (id) => (await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}/subtree`), docOf)).items.find((x) => x.id === id).attrs
  const delta = await p.$eval(titleSel('2'), (e) => e.dataset.id)
  /* wait until the hub holds attrs[k] === v for Delta (the blur's save is async) */
  const attrIs = (k, v) => p.waitForFunction(async (d, id, k, v) => {
    const r = await window.__wsDocTreeCall('GET', `/${d}/subtree`)
    return (r.items.find((x) => x.id === id)?.attrs?.[k] ?? '') === v
  }, { timeout: STEP, polling: 200 }, docOf, delta, k, v).catch(() => null)
  await menu(p, 'doc', 'Delta', 'add_code')
  await p.waitForFunction(() => document.activeElement?.dataset?.test === 'ws-doc-src', { timeout: STEP }).catch(() => null)
  await p.keyboard.type('make deploy ENV=dev')
  await p.click('[data-test=ws-doc-search]')
  await attrIs('src', 'make deploy ENV=dev')
  const code = await attrsOf(delta)
  await p.click(`${titleSel('2')} [data-test=ws-doc-title]`, { button: 'right' })
  await p.waitForSelector('[data-testid="ws-doc-menu-delete"]', { visible: true, timeout: STEP }).catch(() => null)
  const opsWithCode = await opsOf()
  await p.keyboard.press('Escape')
  ok('Add code block puts an editable code block on the section, saved to the hub', code.src === 'make deploy ENV=dev' && !opsWithCode.includes('add_code') && opsWithCode.includes('add_image'), { code, opsWithCode })

  /* an image: the file picker, the upload, the caption, then remove; an svg is refused */
  const { writeFileSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { join: pjoin } = await import('node:path')
  const png = pjoin(tmpdir(), `wsdoc-e2e-${process.pid}.png`)
  writeFileSync(png, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64'))
  const svg = pjoin(tmpdir(), `wsdoc-e2e-${process.pid}.svg`)
  writeFileSync(svg, '<svg xmlns="http://www.w3.org/2000/svg"></svg>')
  const pick = async (file) => {
    const [fc] = await Promise.all([p.waitForFileChooser({ timeout: STEP }), menu(p, 'doc', 'Delta', 'add_image')])
    await fc.accept([file])
  }
  await pick(svg)
  const refused = await p.waitForSelector('[data-test=ws-docs-error]', { visible: true, timeout: STEP }).then((e) => e.evaluate((x) => x.textContent.trim())).catch(() => '')
  const afterSvg = await attrsOf(delta)
  await pick(png)
  await p.waitForFunction((sel) => document.querySelector(`${sel} [data-test=ws-doc-img]`)?.naturalWidth === 1, { timeout: STEP }, titleSel('2')).catch(() => null)
  const img = await p.evaluate((sel) => ({
    shown: document.querySelector(`${sel} [data-test=ws-doc-img]`)?.naturalWidth ?? 0,
    caption: document.querySelector(`${sel} [data-test=ws-doc-img-name]`)?.value,
  }), titleSel('2'))
  const withImg = await attrsOf(delta)
  ok('Add image uploads the file and shows it on the section; an svg is refused and writes nothing',
    img.shown === 1 && img.caption === `wsdoc-e2e-${process.pid}` && String(withImg.img_http_path).startsWith('/v1/workspace/doctree/')
    && withImg.src === 'make deploy ENV=dev' && refused.startsWith('That image was refused') && !afterSvg.img_http_path, { img, withImg, refused, afterSvg })
  await p.click(`${titleSel('2')} [data-test=ws-doc-img-name]`)
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.type('Deploy diagram')
  await p.keyboard.press('Enter')
  await attrIs('img_name', 'Deploy diagram')
  const captioned = await attrsOf(delta)
  await p.click(`${titleSel('2')} [data-test=ws-doc-img-remove]`)
  await p.waitForFunction((sel) => !document.querySelector(`${sel} [data-test=ws-doc-fig]`), { timeout: STEP }, titleSel('2')).catch(() => null)
  const removed = await attrsOf(delta)
  ok('the caption is edited in place and the image is removed, the code block kept',
    captioned.img_name === 'Deploy diagram' && !removed.img_http_path && !removed.img_name && removed.src === 'make deploy ENV=dev', { captioned, removed })

  /* a document always has a title: Create with none typed uses the default */
  await p.click('[data-test=ws-docs-create]')
  await p.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent?.trim() === 'Untitled document', { timeout: STEP }).catch(() => null)
  const dflt = await p.evaluate(() => ({
    h: document.querySelector('[data-test=ws-doc-doctitle]')?.textContent?.trim(),
    sel: document.querySelector('[data-test=ws-docs-select]').selectedOptions[0]?.textContent?.trim(),
    rows: document.querySelectorAll('[data-test=ws-doc-row]').length,
  }))
  ok('Create with no title makes "Untitled document" with the starter outline', dflt.h === 'Untitled document' && dflt.sel === 'Untitled document' && dflt.rows === 3, dflt)

  /* t1 b4dd79e2 ("on mobile, the showing of the omnibox while editing in QTO
     doc is obsolete"): on a phone the omnibox hides while a field of the
     document is in focus and comes back when it leaves; the search box is
     not editing; a desktop keeps it. Control: before e1f5f536a it never hides. */
  const omnibox = (q) => q.evaluate(() => {
    /* on a phone the wrapper is display: contents (no box): measure its form */
    const el = document.querySelector('[data-test=top-bar-omnibox] form')
    if (!el) return 'none'
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden' ? 'shown' : 'hidden'
  })
  const settle = () => new Promise((r) => setTimeout(r, 300))
  const shoot = async (q, name) => {
    if (!process.env.SHOT_DIR) return
    const { mkdirSync } = await import('node:fs')
    mkdirSync(process.env.SHOT_DIR, { recursive: true })
    await q.screenshot({ path: `${process.env.SHOT_DIR}/ws-doctree-${name}.png` })
  }
  await p.setViewport({ width: 1440, height: 900 })
  await p.click('[data-test=ws-doc-row] [data-test=ws-doc-text]')
  await settle()
  ok('desktop 1440: the omnibox stays while a section text is edited', await omnibox(p) === 'shown')
  await shoot(p, 'desktop-edit')
  await p.keyboard.press('Escape')

  const m = await browser.newPage()
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await m.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: NAV_TIMEOUT })
  await m.type('[data-test=ws-docs-new-title]', 'Phone doc')
  await m.click('[data-test=ws-docs-create]')
  await outlineIs(m, 'doc', ['1', '1.1', '1.1.1'])
  await settle()
  const reading = await omnibox(m)
  await shoot(m, 'phone-view')
  await m.tap('[data-test=ws-doc-row] [data-test=ws-doc-text]')
  await settle()
  const editingText = await omnibox(m)
  await shoot(m, 'phone-edit')
  await m.keyboard.press('Escape')
  await settle()
  const afterCancel = await omnibox(m)
  await m.tap('[data-test=ws-doc-doctitle]')
  await settle()
  const editingTitle = await omnibox(m)
  await m.keyboard.press('Enter')
  await settle()
  const afterSave = await omnibox(m)
  await shoot(m, 'phone-after')
  await m.tap('[data-test=ws-doc-search]')
  await settle()
  const searching = await omnibox(m)
  ok('phone: the omnibox shows while the document is read', reading === 'shown', reading)
  ok('phone: it hides while a section text is edited', editingText === 'hidden', editingText)
  ok('phone: it comes back after Esc (cancel)', afterCancel === 'shown', afterCancel)
  ok('phone: it hides while the document title is edited', editingTitle === 'hidden', editingTitle)
  ok('phone: it comes back after Enter (save)', afterSave === 'shown', afterSave)
  ok('phone: CONTROL the search box is not editing, the omnibox stays', searching === 'shown', searching)
  await m.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `workspace-doctree: ${failed} FAILED` : `workspace-doctree: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
