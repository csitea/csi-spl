// Spec 113 T006: the workspace document's two views over one tree. Drives
// add / move / delete in the doc view, reads the outline, reads the same
// outline in the grid, drives add / move / delete in the grid, and reads it
// back in a freshly mounted doc view. Then a 412: another writer moves the
// doc rev on (the mock's test hook), the next op shows the reload prompt and
// commits nothing. Then print branch renders one subtree for print CSS.
// The doc view is Qto's view-doc (t1 519a4ee9): one continuous document,
// titles and texts edited in place, a contents panel whose links scroll,
// no search box of its own (the omnibox is the only search, t1 3cf88d1c),
// and print (contents first, a page break, the document).
// The hub follow-up (owner go 33ced864): the document renamed in place (a
// cleared title is the default), a code block and an uploaded image added
// to a section and edited there, each read back from the hub.
// A new document (owner, t1 889e15d9): the page's + opens a modal with the
// title (required) and the meta description; Esc creates nothing; the
// description is read back from the hub's head. Desktop and phone.
// The grid's level and meta columns (t1 504fe47d): level = the item's depth
// ("1.1" = 2), sortable through the hub's depth sort; meta = its own attrs
// as key: value, read after the code block; on a phone meta is hidden.
// Spec 137 T010 / T011: the paragraph toolbar's Insert table and Insert
// quote, read back rendered, from the hub and from the Markdown export.
// Spec 138: a section link (the stable id, or a readable anchor through its
// id suffix) opens the document with that heading just below the sticky bar,
// desktop and phone; Copy link to section; an unknown anchor opens the top.
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

/** the + opens the new-document modal; title and meta description typed, Create */
async function newDoc(p, title, desc) {
  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', title)
  if (desc) await p.type('[data-test=ws-docs-new-desc]', desc)
  await p.click('[data-test=ws-docs-create]')
  await p.waitForFunction(() => !document.querySelector('[data-test=ws-docs-new-form]'), { timeout: STEP }).catch(() => null)
}

/** the hub's documents (the mock's raw call, not the page's copy) */
const hubDocs = (p) => p.evaluate(async () => (await window.__wsDocTreeCall('GET', '')).docs)

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

/** a section body opened for editing (owner HUM-10, t1 09a69b01): a body
    with text reads as rendered markdown, a click (tap) on it opens its
    textarea; an empty body is the textarea already */
async function editBody(q, row, tap = false) {
  const read = `${row} [data-test=ws-doc-para]`
  const box = `${row} [data-test=ws-doc-text]`
  const run = `${read} .wsdoc__run`
  const at = (await q.$(run)) ? run : (await q.$(read)) ? read : box
  if (tap) await q.tap(at).catch(() => null)
  else await q.click(at).catch(() => null)
  await q.waitForFunction((sel) => document.activeElement === document.querySelector(sel), { timeout: STEP }, box).catch(() => null)
}

/** a section body's text as the page shows it: the textarea while editing, else the read view */
const bodyText = (q, row) => q.evaluate((row) => {
  const box = document.querySelector(`${row} [data-test=ws-doc-text]`)
  return box ? box.value : document.querySelector(`${row} [data-test=ws-doc-para]`)?.textContent?.trim()
}, row)

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
  await p.waitForSelector('[data-test=ws-docs-new]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => typeof window.__wsDocTreeCall === 'function', { timeout: STEP })

  /* the + is the issues page's round + (owner t1 889e15d9): 2.5rem, round, accent; no inline title box */
  const plus = await p.evaluate(() => {
    const el = document.querySelector('[data-test=ws-docs-new]')
    const b = el.getBoundingClientRect()
    const cs = getComputedStyle(el)
    return { w: Math.round(b.width), h: Math.round(b.height), want: Math.round(2.5 * parseFloat(getComputedStyle(document.documentElement).fontSize)),
      round: cs.borderRadius === '50%', accent: cs.backgroundColor !== 'rgba(0, 0, 0, 0)', inline: Boolean(document.querySelector('.wsdocs-body [data-test=ws-docs-new-title]')) }
  })
  ok('the + is the issues page\'s round 2.5rem accent button and the page has no inline title box',
    plus.w === plus.want && plus.h === plus.want && plus.round && plus.accent && !plus.inline, plus)

  /* the modal: title required, Esc closes with nothing created */
  const before = (await hubDocs(p)).length
  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-testid=ui-dialog] [data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-desc]', 'no title yet')
  const noTitle = await p.$eval('[data-test=ws-docs-create]', (b) => b.disabled)
  await p.type('[data-test=ws-docs-new-title]', 'x')
  const withTitle = await p.$eval('[data-test=ws-docs-create]', (b) => b.disabled)
  ok('the + opens the modal; Create is disabled until a title is typed', noTitle === true && withTitle === false, { noTitle, withTitle })
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=ws-docs-new-form]'), { timeout: STEP }).catch(() => null)
  const afterEsc = { open: Boolean(await p.$('[data-test=ws-docs-new-form]')), n: (await hubDocs(p)).length }
  ok('Esc closes the modal and creates nothing', !afterEsc.open && afterEsc.n === before, { before, afterEsc })

  /* a new document never starts from nothing (t1 519a4ee9): its title, then
     the starter headings 1 / 1.1 / 1.1.1 as placeholders, a paragraph
     placeholder under levels 2 and 3 only */
  await newDoc(p, 'E2E outline', 'What the e2e outline is for')
  let got = await outlineIs(p, 'doc', ['1', '1.1', '1.1.1'])
  const starter = await p.evaluate(() => ({
    title: document.querySelector('[data-test=ws-doc-doctitle]')?.textContent?.trim(),
    rows: [...document.querySelectorAll('[data-test=ws-doc-row]')].map((r) => [
      r.querySelector('[data-test=ws-doc-title]').placeholder, r.querySelector('[data-test=ws-doc-text]').placeholder]),
  }))
  /* the meta description is stored: read back from the hub's head, not the page.
     The CONTROL: a document made with none (the mock's raw call) reads '' */
  const descOf = (id) => p.evaluate(async (id) => (await window.__wsDocTreeCall('GET', '/' + id)).description, id)
  const opened = new URL(p.url()).searchParams.get('doc')
  const desc = await descOf(opened)
  const bare = await p.evaluate(async () => (await window.__wsDocTreeCall('POST', '', { title: 'bare' })).id)
  const bareDesc = await descOf(bare)
  ok('the new document opens and its meta description is saved with it', desc === 'What the e2e outline is for', { opened, desc })
  ok('CONTROL: a document made without one has an empty description', bareDesc === '', { bareDesc })
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
  await editBody(p, titleOf('2'))
  await p.keyboard.type('A paragraph under Beta.')
  await p.evaluate(() => document.activeElement?.blur())
  await view(p, 'grid')
  await view(p, 'doc')
  await outlineIs(p, 'doc', ['1 Alpha', '1.1 Delta', '2 Beta edited', '3 Beta child'])
  const edited = {
    title: await p.$eval(`${titleOf('2')} [data-test=ws-doc-title]`, (e) => e.value),
    text: await bodyText(p, titleOf('2')),
  }
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

  /* no search box of its own: the omnibox is the only search, desktop and phone (the owner, t1 3cf88d1c) */
  const noSearch = {}
  for (const [w, h] of [[1440, 900], [390, 740]]) {
    await p.setViewport({ width: w, height: h })
    await p.waitForSelector('[data-test=ws-doc-doc]', { visible: true, timeout: STEP }).catch(() => null)
    noSearch[w] = await p.evaluate(() => ({
      doc: Boolean(document.querySelector('[data-test=ws-doc-doc]')),
      search: document.querySelectorAll('[data-test=ws-doc-search], [data-test=ws-doc-hits], [data-test=ws-doc-search-none]').length,
    }))
  }
  ok('the doc view has no search box at 1440 and 390', noSearch[1440].doc && noSearch[390].doc && noSearch[1440].search === 0 && noSearch[390].search === 0, noSearch)
  await p.setViewport({ width: 1280, height: 800 })

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

  /* create, update, delete, then a reload re-reads the document from the hub
     (the part Qto got wrong, t1 519a4ee9 msg 1ecb465b) */
  const titleSel = (n) => `[data-test=ws-doc-row][data-outline="${n}"]`
  const shoot = async (q, name) => {
    if (!process.env.SHOT_DIR) return
    const { mkdirSync } = await import('node:fs')
    mkdirSync(process.env.SHOT_DIR, { recursive: true })
    await q.screenshot({ path: `${process.env.SHOT_DIR}/ws-doctree-${name}.png` })
  }
  const typeInto = async (sel, text) => {
    const body = sel.endsWith(' [data-test=ws-doc-text]')
    if (body) await editBody(p, sel.slice(0, -' [data-test=ws-doc-text]'.length))
    else await p.click(sel)
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
  const texts = [await bodyText(p, titleSel('1')), await bodyText(p, titleSel('3'))]
  ok('CONTROL: before the reload the page still shows its own copy', beforeReload[0] === '1 Alpha', beforeReload)
  ok('after a reload every create, update and delete is still there (read from the hub)', JSON.stringify(got) === JSON.stringify(wantReloaded)
    && texts[0] === 'Level-1 paragraph, see https://example.com/qto' && texts[1] === 'Text edited in place.', { got, texts })

  /* the Qto doc's markdown (owner HUM-10, t1 09a69b01 msg 5092cd2d): a body
     READS as rendered markdown and EDITS as the raw text. Bold, a list and a
     link are <strong>, <li> and <a>; a click opens the textarea on the raw
     markdown; blur renders it again; focus opens it too. CONTROL: before this
     change the body is always a textarea, nothing is rendered (FAIL). */
  const mdRow = titleSel('4')
  const MD = 'Some **bold words** here\n\n- first item\n- second item\n\nSee [the site](https://example.com/md)'
  await editBody(p, mdRow)
  await p.keyboard.type(MD)
  await p.click('[data-test=ws-doc-doctitle]')
  const mdRead = () => p.waitForFunction((row) => document.querySelector(`${row} [data-test=ws-doc-para] [data-testid=md-block][data-rendered=true]`), { timeout: STEP }, mdRow)
    .catch(() => null).then(() => p.evaluate((row) => {
      const para = document.querySelector(`${row} [data-test=ws-doc-para]`)
      return {
        para: Boolean(para),
        textarea: Boolean(document.querySelector(`${row} [data-test=ws-doc-text]`)),
        strong: para?.querySelector('strong')?.textContent ?? null,
        lis: [...(para?.querySelectorAll('li') ?? [])].map((e) => e.textContent.trim()),
        link: para?.querySelector('a')?.getAttribute('href') ?? null,
        raw: (para?.textContent ?? '').includes('**'),
      }
    }, mdRow))
  const md1 = await mdRead()
  ok('a section body reads as rendered markdown: **bold**, a list and a link are <strong>, <li> and <a>',
    md1.para && !md1.textarea && md1.strong === 'bold words' && JSON.stringify(md1.lis) === JSON.stringify(['first item', 'second item'])
    && md1.link === 'https://example.com/md' && !md1.raw, md1)
  await shoot(p, 'md-read')
  await p.click(`${mdRow} [data-test=ws-doc-para] li`).catch(() => null)
  await p.waitForFunction((row) => document.activeElement === document.querySelector(`${row} [data-test=ws-doc-text]`), { timeout: STEP }, mdRow).catch(() => null)
  const mdEdit = await p.evaluate((row) => ({
    focused: document.activeElement === document.querySelector(`${row} [data-test=ws-doc-text]`),
    value: document.querySelector(`${row} [data-test=ws-doc-text]`)?.value ?? null,
    para: Boolean(document.querySelector(`${row} [data-test=ws-doc-para]`)),
  }), mdRow)
  ok('a click on the rendered body edits the raw markdown in its textarea', mdEdit.focused && mdEdit.value === MD && !mdEdit.para, mdEdit)
  await shoot(p, 'md-edit')
  await p.evaluate(() => document.activeElement?.blur())
  const md2 = await mdRead()
  ok('blur renders the body again', md2.para && !md2.textarea && md2.strong === 'bold words' && md2.lis.length === 2, md2)
  await p.focus(`${mdRow} [data-test=ws-doc-para]`).catch(() => null)
  await p.waitForFunction((row) => document.activeElement === document.querySelector(`${row} [data-test=ws-doc-text]`), { timeout: STEP }, mdRow).catch(() => null)
  const mdFocus = await p.evaluate((row) => document.activeElement === document.querySelector(`${row} [data-test=ws-doc-text]`), mdRow)
  await p.keyboard.press('Escape')
  const md3 = await mdRead()
  ok('keyboard focus on the rendered body opens the textarea; Esc reads it again', mdFocus && md3.para && md3.strong === 'bold words', { mdFocus, md3 })

  /* spec 137 T010 + T011 (owner HUM-10, t1 bed3ed0a msgs 2c82489a "tables in
     the paragraphs", b1661d1c "citates"): the paragraph toolbar's Insert
     table and Insert quote put a pipe table and a quote with its source line
     into the text at the cursor, the first placeholder selected to type over.
     Left, the paragraph reads as a <table> and a <blockquote> whose source
     line is p[data-cite] (upright, not the passage's italic); the hub keeps
     the markdown and the Markdown export carries it as written.
     CONTROL: before this change neither control exists (FAIL). */
  const blkRow = titleSel('5.1.1')
  const picked = () => p.evaluate((row) => {
    const el = document.querySelector(`${row} [data-test=ws-doc-text]`)
    return el && document.activeElement === el ? el.value.slice(el.selectionStart, el.selectionEnd) : null
  }, blkRow)
  await editBody(p, blkRow)
  const tools = await p.evaluate((row) => ['ws-doc-insert-table', 'ws-doc-insert-quote'].map((t) => Boolean(document.querySelector(`${row} [data-test=${t}]`))), blkRow)
  ok('T010/T011: the focused paragraph offers Insert table and Insert quote', tools[0] && tools[1], tools)
  await p.click(`${blkRow} [data-test=ws-doc-insert-table]`).catch(() => null)
  const tPick = await picked()
  await p.keyboard.type('Name')
  await p.keyboard.down('Control')
  await p.keyboard.press('End')
  await p.keyboard.up('Control')
  await p.click(`${blkRow} [data-test=ws-doc-insert-quote]`).catch(() => null)
  const qPick = await picked()
  await p.keyboard.type('To be, or not to be.')
  const typed = await p.$eval(`${blkRow} [data-test=ws-doc-text]`, (e) => e.value).catch(() => '')
  const WANT_BODY = '| Name | Header 2 | Header 3 |\n|---|---|---|\n| Cell 1 | Cell 2 | Cell 3 |\n\n> To be, or not to be.\n>\n> — [Author or source](https://)'
  ok('T010: Insert table puts the pipe table in and selects "Header 1"; T011: Insert quote adds the quote and selects its passage',
    tPick === 'Header 1' && qPick === 'Quoted passage' && typed === WANT_BODY, { tPick, qPick, typed })
  await p.click('[data-test=ws-doc-doctitle]')
  const blkId = await p.$eval(blkRow, (e) => e.dataset.id)
  await p.waitForFunction(async (d, id, want) => (await window.__wsDocTreeCall('GET', `/${d}/subtree`)).items.find((x) => x.id === id)?.body === want, { timeout: STEP, polling: 200 }, docOf, blkId, WANT_BODY).catch(() => null)
  const blkHub = (await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}/subtree`), docOf)).items.find((x) => x.id === blkId)?.body
  await p.waitForFunction((row) => document.querySelector(`${row} [data-test=ws-doc-para] [data-testid=md-block][data-rendered=true]`), { timeout: STEP }, blkRow).catch(() => null)
  const blkRead = await p.evaluate((row) => {
    const para = document.querySelector(`${row} [data-test=ws-doc-para]`)
    const q = para?.querySelector('blockquote')
    const cite = q?.querySelector('p[data-cite]')
    return {
      ths: [...(para?.querySelectorAll('table th') ?? [])].map((e) => e.textContent.trim()),
      tds: [...(para?.querySelectorAll('table td') ?? [])].map((e) => e.textContent.trim()),
      quote: q?.querySelector('p')?.textContent?.trim() ?? null,
      cite: cite?.textContent?.trim() ?? null,
      styles: q && cite ? [getComputedStyle(q).fontStyle, getComputedStyle(cite).fontStyle, getComputedStyle(q).borderLeftStyle] : null,
    }
  }, blkRow)
  ok('T010/T011: the hub keeps the markdown; the paragraph reads as a table and a styled quote with its source line',
    blkHub === WANT_BODY && JSON.stringify(blkRead.ths) === '["Name","Header 2","Header 3"]' && blkRead.tds.length === 3
    && blkRead.quote === 'To be, or not to be.' && blkRead.cite === '— Author or source'
    && JSON.stringify(blkRead.styles) === '["italic","normal","solid"]', { blkHub, blkRead })
  await shoot(p, 'table-quote-read')
  await p.evaluate(() => { window.__exports = [] })
  await menu(p, 'doc', 'New child', 'export_md')
  await p.waitForFunction(() => window.__exports.some((x) => x.startsWith('# ')), { timeout: STEP }).catch(() => null)
  const blkMd = await p.evaluate(() => window.__exports.find((x) => x.startsWith('# ')) || '')
  ok('T010/T011: the Markdown export carries the table and the quote as written', blkMd.includes(WANT_BODY), blkMd)

  /* spec 137 T019 gaps (SPL-1881; the prd proof's t019-desktop.png, owner
     t1 bed3ed0a 2026-10-13 "the tables should have the Table: <<table
     desc>>"): a "Table: <desc>" line under the table is its <caption>
     (first child, drawn under the rows), and a quote's source link is not
     listed again as a bare URL under the paragraph; a plain link still is.
     CONTROL: on the old bundle the Table: line is a table row and the
     source URL shows under the quote (FAIL). */
  const T019_BODY = '| Name | Header 2 | Header 3 |\n|---|---|---|\n| Cell 1 | Cell 2 | Cell 3 |\nTable: Results by run\n\n'
    + '> To be, or not to be.\n>\n> — [Hamlet](https://example.com/spec-137)\n\nSee https://example.com/plain'
  await typeInto(`${blkRow} [data-test=ws-doc-text]`, T019_BODY)
  await p.waitForFunction(async (d, id, want) => (await window.__wsDocTreeCall('GET', `/${d}/subtree`)).items.find((x) => x.id === id)?.body === want, { timeout: STEP, polling: 200 }, docOf, blkId, T019_BODY).catch(() => null)
  const t019Hub = (await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}/subtree`), docOf)).items.find((x) => x.id === blkId)?.body
  await p.waitForFunction((row) => document.querySelector(`${row} [data-test=ws-doc-para] [data-testid=md-block][data-rendered=true] table`), { timeout: STEP }, blkRow).catch(() => null)
  const t019 = await p.evaluate((row) => {
    const table = document.querySelector(`${row} [data-test=ws-doc-para] table`)
    const cap = table?.querySelector('caption')
    const rows = table?.querySelectorAll('tbody tr') ?? []
    return {
      caption: cap?.textContent?.trim() ?? null,
      first: table?.firstElementChild?.tagName ?? null,
      under: cap && rows.length ? Math.round(cap.getBoundingClientRect().top) >= Math.round(rows[rows.length - 1].getBoundingClientRect().bottom) : false,
      rows: rows.length,
      links: [...document.querySelectorAll(`${row} [data-test=ws-doc-links] a`)].map((a) => a.href),
      cite: document.querySelector(`${row} [data-test=ws-doc-para] blockquote p[data-cite] a`)?.href ?? null,
    }
  }, blkRow)
  ok('T019: the Table: line is the table\'s caption, under its rows; the hub keeps the line as typed',
    t019Hub === T019_BODY && t019.caption === 'Table: Results by run' && t019.first === 'CAPTION' && t019.under && t019.rows === 1, { t019Hub, t019 })
  ok('T019: the quote\'s source link shows once, in the quote; a plain link is still listed under the paragraph',
    t019.cite === 'https://example.com/spec-137' && JSON.stringify(t019.links) === JSON.stringify(['https://example.com/plain']), t019)
  await shoot(p, 't019-caption-cite')

  /* T019 gap: the heading menu's numbering switch PATCHes attrs.numbered
     (false off, the key dropped on); the siblings after it re-number at
     once. CONTROL: on the old bundle the menu has no such entry (FAIL). */
  const deltaId = await p.$eval(titleSel('2'), (e) => e.dataset.id)
  const numAttr = async () => (await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}/subtree`), docOf)).items.find((x) => x.id === deltaId)?.attrs?.numbered
  const wantUnnum = ['1 Alpha (other writer)', 'Delta', '2 Beta renamed', '3 After reload', '4 Beta child', '4.1 New parent', '4.1.1 New child']
  await menu(p, 'doc', 'Delta', 'numbered').catch(() => null)
  const unnum = await outlineIs(p, 'doc', wantUnnum)
  const offAttr = await numAttr()
  await menu(p, 'doc', 'Delta', 'numbered').catch(() => null)
  const renum = await outlineIs(p, 'doc', wantReloaded)
  const onAttr = await numAttr()
  ok('T019: "Turn numbering off" takes the heading\'s number away and the siblings after it re-number (attrs.numbered = false on the hub)',
    JSON.stringify(unnum) === JSON.stringify(wantUnnum) && offAttr === false, { unnum, offAttr })
  ok('T019: "Turn numbering on" gives it back (the key dropped on the hub)', JSON.stringify(renum) === JSON.stringify(wantReloaded) && onAttr === undefined, { renum, onAttr })

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
  await p.evaluate(() => document.activeElement?.blur())
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
    data: (document.querySelector(`${sel} [data-test=ws-doc-img]`)?.src || '').startsWith('data:image/png;base64,'),
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


  /* every deployed CSP is img-src 'self' data:, so a doc image's src is a data: URL, never blob: (blocked on prd) */
  ok('the section image is shown from a data: URL (the deployed CSP blocks blob:)', img.data, img)

  /* pictures inside a paragraph (owner HUM-10, t1 46d9c236): two pasted at
     the cursor and one from the Insert picture control, each uploaded through
     the images route and kept in the text as ![caption](<img_http_path>);
     read, the paragraph shows them inline with "Figure N: <caption>", N
     counted through the document with the section image after them; a token
     whose path is not this doc's images route stays text. CONTROL: before
     this change the paragraph is a plain textarea, no ws-doc-pic (FAIL). */
  const PNG1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=='
  const textSel = `${titleSel('2')} [data-test=ws-doc-text]`
  const bodyOf = async (id) => (await p.evaluate((d) => window.__wsDocTreeCall('GET', `/${d}/subtree`), docOf)).items.find((x) => x.id === id).body
  const tokens = (b) => [...(b || '').matchAll(/!\[([^\]\n]*)\]\((\/v1\/workspace\/doctree\/([^/\s()]+)\/images\/[0-9a-f]{64}\.png)\)/g)].filter((m) => m[3] === docOf).map((m) => m[1])
  const tokensAre = (n, last) => p.waitForFunction(async (d, id, n, last) => {
    const r = await window.__wsDocTreeCall('GET', `/${d}/subtree`)
    const b = r.items.find((x) => x.id === id)?.body || ''
    const caps = [...b.matchAll(/!\[([^\]\n]*)\]\(\/v1\/workspace\/doctree\/[^/\s()]+\/images\/[0-9a-f]{64}\.png\)/g)].map((m) => m[1])
    return caps.length === n && (!last || caps[n - 1] === last)
  }, { timeout: STEP, polling: 200 }, docOf, delta, n, last).catch(() => null)
  const pastePng = () => p.evaluate((sel, b64) => {
    const el = document.querySelector(sel)
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
    const dt = new DataTransfer()
    dt.items.add(new File([bytes], 'image.png', { type: 'image/png' }))
    el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
  }, textSel, PNG1)
  /* the insert leaves the caption selected: typing replaces it, then the cursor goes to the end */
  const captionThenEnd = async (caption) => {
    await p.waitForFunction((sel) => {
      const el = document.querySelector(sel)
      return el === document.activeElement && el.selectionEnd > el.selectionStart
    }, { timeout: STEP }, textSel).catch(() => null)
    await p.keyboard.type(caption)
    await p.keyboard.down('Control')
    await p.keyboard.press('End')
    await p.keyboard.up('Control')
  }
  await editBody(p, titleSel('2'))
  await p.keyboard.type('Before the pictures')
  await pastePng()
  await tokensAre(1)
  await captionThenEnd('Deploy step one')
  await p.keyboard.type('\nBetween them')
  await pastePng()
  await tokensAre(2)
  await captionThenEnd('Deploy step two')
  const bogus = '![x](https://example.com/a.png) ![y](/v1/workspace/doctree/other-doc/images/' + 'a'.repeat(64) + '.png)'
  await p.keyboard.type('\nAfter ' + bogus)
  await shoot(p, 'pics-edit')
  await p.evaluate(() => document.activeElement?.blur())
  await tokensAre(2, 'Deploy step two')
  const pasted = await bodyOf(delta)
  await p.waitForFunction((sel) => [...document.querySelectorAll(`${sel} [data-test=ws-doc-pic-img]`)].filter((i) => i.naturalWidth === 1).length === 2, { timeout: STEP }, titleSel('2')).catch(() => null)
  const readPics = () => p.evaluate((sel) => {
    const para = document.querySelector(`${sel} [data-test=ws-doc-para]`)
    return {
      para: Boolean(para),
      textarea: Boolean(document.querySelector(`${sel} [data-test=ws-doc-text]`)),
      imgs: [...(para?.querySelectorAll('[data-test=ws-doc-pic-img]') ?? [])].map((i) => ({ w: i.naturalWidth, alt: i.alt, lazy: i.loading, max: getComputedStyle(i).maxWidth, data: i.src.startsWith('data:image/png;base64,') })),
      nums: [...document.querySelectorAll(`${sel} [data-test=ws-doc-fig-num]`)].map((e) => e.textContent.trim()),
      caps: [...(para?.querySelectorAll('[data-test=ws-doc-pic-caption]') ?? [])].map((e) => e.value),
      text: [...(para?.querySelectorAll('.wsdoc__run') ?? [])].map((e) => e.textContent).join('|'),
      links: [...(para?.querySelectorAll('.wsdoc__run a') ?? [])].map((a) => a.href),
      md: [...(para?.querySelectorAll('.wsdoc__run') ?? [])].map((e) => e.querySelector('[data-testid=md-block]')?.dataset.rendered ?? 'none'),
    }
  }, titleSel('2'))
  await p.waitForFunction((sel) => [...document.querySelectorAll(`${sel} .wsdoc__run [data-testid=md-block]`)].some((e) => e.dataset.rendered === 'true'), { timeout: STEP }, titleSel('2')).catch(() => null)
  const read = await readPics()
  ok('paste puts two pictures at the cursor: uploaded, kept as ![caption](<images route>) tokens in the text, shown inline as Figure 1 and 2',
    JSON.stringify(tokens(pasted)) === JSON.stringify(['Deploy step one', 'Deploy step two'])
    && pasted.startsWith('Before the pictures\n![Deploy step one](/v1/workspace/doctree/') && pasted.includes('\nBetween them\n![Deploy step two](')
    && read.para && !read.textarea && read.imgs.length === 2 && read.imgs.every((i) => i.w === 1 && i.lazy === 'lazy' && i.max === '100%' && i.data)
    && read.imgs[0].alt === 'Deploy step one' && JSON.stringify(read.nums) === JSON.stringify(['Figure 1:', 'Figure 2:'])
    && JSON.stringify(read.caps) === JSON.stringify(['Deploy step one', 'Deploy step two']), { pasted, read })
  /* each text run between the figures renders as markdown (t1 09a69b01): such a token is a link to the picture, never a figure */
  ok('a picture token whose path is not this doc\'s images route is no figure: its text run renders it as markdown, a link',
    read.text.includes('Before the pictures') && read.text.includes('Between them') && read.md.length > 0 && read.md.every((x) => x === 'true')
    && read.links.includes('https://example.com/a.png') && !read.text.includes('![') && read.imgs.length === 2 && read.nums.length === 2, read)
  await shoot(p, 'pics-read')

  /* the caption edited in place under the picture rewrites its token */
  const caps = await p.$$(`${titleSel('2')} [data-test=ws-doc-pic-caption]`)
  await caps[1].click()
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.type('Rollback')
  await p.keyboard.press('Enter')
  await tokensAre(2, 'Rollback')
  const recap = tokens(await bodyOf(delta))
  ok('a figure caption is edited in place, its token rewritten', JSON.stringify(recap) === JSON.stringify(['Deploy step one', 'Rollback']), recap)

  /* a click on the text edits it again (the tokens as text); the Insert picture control adds a third at the cursor */
  await p.click(`${titleSel('2')} .wsdoc__run`)
  await p.waitForFunction((sel) => document.activeElement === document.querySelector(sel), { timeout: STEP }, textSel).catch(() => null)
  const editVal = await p.$eval(textSel, (e) => e.value).catch(() => '')
  const [fc3] = await Promise.all([p.waitForFileChooser({ timeout: STEP }), p.click(`${titleSel('2')} [data-test=ws-doc-insert-pic]`)])
  await fc3.accept([png])
  await tokensAre(3)
  await captionThenEnd('Picked')
  await p.evaluate(() => document.activeElement?.blur())
  await tokensAre(3, 'Picked')
  /* the section image after them is Figure 4: one sequence */
  await pick(png)
  await attrIs('img_name', `wsdoc-e2e-${process.pid}`)
  await p.waitForFunction((sel) => document.querySelectorAll(`${sel} [data-test=ws-doc-fig-num]`).length === 4, { timeout: STEP }, titleSel('2')).catch(() => null)
  const three = await readPics()
  ok('the Insert picture control adds a picture at the cursor; the section image continues the numbering',
    editVal === await bodyOf(delta).then((b) => b.replace(/\n?!\[Picked\]\([^)]*\)/, '')) && three.imgs.length === 3
    && JSON.stringify(three.nums) === JSON.stringify(['Figure 1:', 'Figure 2:', 'Figure 3:', 'Figure 4:']), { editVal, three })
  /* the export hook also sees the uploaded images' blobs: the Markdown is the one that starts with its heading */
  await p.evaluate(() => { window.__exports = [] })
  await menu(p, 'doc', 'Delta', 'export_md')
  await p.waitForFunction(() => window.__exports.some((x) => x.startsWith('# ')), { timeout: STEP }).catch(() => null)
  const md = await p.evaluate(() => window.__exports.find((x) => x.startsWith('# ')) || '')
  ok('the Markdown export keeps each picture token with its "Figure N:" caption',
    /!\[Deploy step one\]\(\/v1\/workspace\/doctree\/[^)]+\)\n\n\*Figure 1: Deploy step one\*/.test(md) && md.includes('*Figure 2: Rollback*')
    && md.includes('*Figure 3: Picked*') && md.includes(`*Figure 4: wsdoc-e2e-${process.pid}*`), md)
  await p.click(`${titleSel('2')} [data-test=ws-doc-img-remove]`)
  await attrIs('img_http_path', '')
  /* the grid's level and meta columns: every row's level is its outline's
     depth, Delta's meta is its code block; a click on Level sorts by depth.
     CONTROL: with the columns removed there is no level or meta cell (FAIL) */
  await view(p, 'grid')
  await p.waitForSelector('[data-test=ws-grid-row]', { visible: true, timeout: STEP }).catch(() => null)
  const gridCols = () => p.evaluate(() => [...document.querySelectorAll('[data-test=ws-grid-row]')].map((r) => ({
    id: r.dataset.id,
    outline: r.dataset.outline,
    level: r.querySelector('[data-test=ws-grid-level]')?.textContent?.trim() ?? null,
    meta: r.querySelector('[data-test=ws-grid-meta]')?.textContent?.trim() ?? null,
  })))
  const lv = await gridCols()
  const heads = await p.evaluate(() => [...document.querySelectorAll('.wsgrid__table thead th')].map((h) => h.textContent.trim()))
  const deltaRow = lv.find((r) => r.id === delta)
  ok('grid shows a Level column (the outline depth) and a Meta column (the item\'s attrs as key: value)',
    lv.length > 1 && lv.every((r) => r.level === String(r.outline.split('.').length)) && lv.some((r) => r.level === '2')
    && deltaRow?.meta === 'src: make deploy ENV=dev' && lv.filter((r) => r.id !== delta).every((r) => r.meta === '')
    && heads.includes('Level') && heads.includes('Meta'), { lv, heads })
  await p.click('[data-test=ws-grid-sort-level]')
  await p.click('[data-test=ws-grid-sort-level]')
  await p.waitForFunction(() => document.querySelector('[data-test=ws-grid-row] [data-test=ws-grid-level]')?.textContent?.trim() !== '1', { timeout: STEP }).catch(() => null)
  const byLevel = (await gridCols()).map((r) => Number(r.level))
  ok('grid sorts by level, descending on a second click', byLevel.length === lv.length && byLevel[0] > byLevel[byLevel.length - 1]
    && byLevel.every((n, i) => i === 0 || byLevel[i - 1] >= n), byLevel)
  await shoot(p, 'grid-level-meta')
  await view(p, 'doc')

  /* t1 b4dd79e2 ("on mobile, the showing of the omnibox while editing in QTO
     doc is obsolete"): on a phone the omnibox hides while a field of the
     document is in focus and comes back when it leaves; a desktop keeps it. Control: before e1f5f536a it never hides.
     SPL-2516 (qto reading panel row 02): on a phone's docs routes the dock is
     collapsed while reading too; the compact search button stands in for it. */
  const omnibox = (q) => q.evaluate(() => {
    /* on a phone the wrapper is display: contents (no box): measure its form */
    const el = document.querySelector('[data-test=top-bar-omnibox] form')
    if (!el) return 'none'
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden' ? 'shown' : 'hidden'
  })
  const settle = () => new Promise((r) => setTimeout(r, 300))
  await p.setViewport({ width: 1440, height: 900 })
  await p.click('[data-test=ws-doc-row] [data-test=ws-doc-text]')
  await settle()
  ok('desktop 1440: the omnibox stays while a section text is edited', await omnibox(p) === 'shown')
  await shoot(p, 'desktop-edit')
  await p.keyboard.press('Escape')

  const m = await browser.newPage()
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await m.waitForSelector('[data-test=ws-docs-new]', { visible: true, timeout: NAV_TIMEOUT })
  await newDoc(m, 'Phone doc')
  await outlineIs(m, 'doc', ['1', '1.1', '1.1.1'])
  await settle()
  const reading = await omnibox(m)
  const searchBtn = (q) => q.evaluate(() => !!document.querySelector('[data-test=docs-search-open]'))
  const readingBtn = await searchBtn(m)
  await shoot(m, 'phone-view')
  await m.tap('[data-test=ws-doc-row] [data-test=ws-doc-text]')
  await settle()
  const editingText = await omnibox(m)
  await shoot(m, 'phone-edit')
  await m.keyboard.press('Escape')
  await settle()
  const afterCancel = await omnibox(m)
  const afterCancelBtn = await searchBtn(m)
  await m.tap('[data-test=ws-doc-doctitle]')
  await settle()
  const editingTitle = await omnibox(m)
  await m.keyboard.press('Enter')
  await settle()
  const afterSave = await omnibox(m)
  const afterSaveBtn = await searchBtn(m)
  await shoot(m, 'phone-after')
  ok('phone: the dock is collapsed while the document is read, the search button shows (SPL-2516)', reading === 'hidden' && readingBtn, { reading, readingBtn })
  ok('phone: it hides while a section text is edited', editingText === 'hidden', editingText)
  ok('phone: after Esc (cancel) the dock stays collapsed, the search button shows', afterCancel === 'hidden' && afterCancelBtn, { afterCancel, afterCancelBtn })
  ok('phone: it hides while the document title is edited', editingTitle === 'hidden', editingTitle)
  ok('phone: after Enter (save) the dock stays collapsed, the search button shows', afterSave === 'hidden' && afterSaveBtn, { afterSave, afterSaveBtn })

  /* phone pictures (owner HUM-10, t1 46d9c236 msg 3c943bd0: "do it on mobile
     as well"): touch taps only. Tap a paragraph, the Insert picture control
     shows on screen (not under the top bar or the + and not lost when the
     textarea blurs as the picker opens) and a 44 px tap, tap it, choose a png:
     the picture is inline with "Figure 1" and an editable 44 px caption; a second one in the next
     section is Figure 2 (one sequence); the caption is edited by touch. */
  const mDoc = await m.$eval('[data-test=ws-docs-select]', (e) => e.value)
  const mText = (n) => `${titleSel(n)} [data-test=ws-doc-text]`
  const mCaps = (id) => m.evaluate(async (d, id) => {
    const b = (await window.__wsDocTreeCall('GET', `/${d}/subtree`)).items.find((x) => x.id === id)?.body || ''
    return [...b.matchAll(/!\[([^\]\n]*)\]\(\/v1\/workspace\/doctree\/[^/\s()]+\/images\/[0-9a-f]{64}\.png\)/g)].map((x) => x[1])
  }, mDoc, id)
  const mCapsAre = (id, want) => m.waitForFunction(async (d, id, want) => {
    const b = (await window.__wsDocTreeCall('GET', `/${d}/subtree`)).items.find((x) => x.id === id)?.body || ''
    return JSON.stringify([...b.matchAll(/!\[([^\]\n]*)\]\(\/v1\/workspace\/doctree\/[^/\s()]+\/images\/[0-9a-f]{64}\.png\)/g)].map((x) => x[1])) === JSON.stringify(want)
  }, { timeout: STEP, polling: 200 }, mDoc, id, want).catch(() => null)
  /* the control: on screen, and the topmost element at its centre (nothing covers it) */
  const picTool = (n) => m.evaluate((sel) => {
    const b = document.querySelector(`${sel} [data-test=ws-doc-insert-pic]`)
    if (!b) return { shown: false }
    const r = b.getBoundingClientRect()
    const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    return { shown: r.width > 0 && r.height > 0, inView: r.top >= 0 && r.bottom <= innerHeight, onTop: Boolean(top && b.contains(top)), h: Math.round(r.height) }
  }, titleSel(n))
  const mPicIn = async (n, caption) => {
    await m.tap(mText(n))
    await m.waitForFunction((sel) => document.activeElement === document.querySelector(sel), { timeout: STEP }, mText(n)).catch(() => null)
    await m.keyboard.type(`Phone text ${n}`)
    await m.waitForSelector(`${titleSel(n)} [data-test=ws-doc-insert-pic]`, { visible: true, timeout: STEP }).catch(() => null)
    const tool = await picTool(n)
    const [fc] = await Promise.all([m.waitForFileChooser({ timeout: STEP }).catch(() => null), m.tap(`${titleSel(n)} [data-test=ws-doc-insert-pic]`).catch(() => null)])
    if (!fc) return { tool, chooser: false }
    await fc.accept([png])
    await m.waitForFunction((sel) => {
      const el = document.querySelector(sel)
      return el === document.activeElement && el.selectionEnd > el.selectionStart
    }, { timeout: STEP }, mText(n)).catch(() => null)
    await m.keyboard.type(caption)
    await m.evaluate(() => document.activeElement?.blur())
    return { tool, chooser: true }
  }
  const mId = (n) => m.$eval(titleSel(n), (r) => r.dataset.id)
  const [id11, id111] = [await mId('1.1'), await mId('1.1.1')]
  const pic1 = await mPicIn('1.1', 'Phone pic one')
  await mCapsAre(id11, ['Phone pic one'])
  await shoot(m, 'phone-pics-edit')
  const pic2 = await mPicIn('1.1.1', 'Phone pic two')
  await mCapsAre(id111, ['Phone pic two'])
  await m.waitForFunction(() => [...document.querySelectorAll('[data-test=ws-doc-pic-img]')].filter((i) => i.naturalWidth === 1).length === 2, { timeout: STEP }).catch(() => null)
  const mRead = await m.evaluate(() => ({
    paras: document.querySelectorAll('[data-test=ws-doc-para]').length,
    imgs: [...document.querySelectorAll('[data-test=ws-doc-pic-img]')].map((i) => ({ w: i.naturalWidth, fits: i.getBoundingClientRect().right <= innerWidth })),
    nums: [...document.querySelectorAll('[data-test=ws-doc-pic] [data-test=ws-doc-fig-num]')].map((e) => e.textContent.trim()),
    caps: [...document.querySelectorAll('[data-test=ws-doc-pic-caption]')].map((e) => e.value),
    capH: [...document.querySelectorAll('[data-test=ws-doc-pic-caption]')].map((e) => Math.round(e.getBoundingClientRect().height)),
    fits: document.documentElement.scrollWidth <= innerWidth + 1,
  }))
  await shoot(m, 'phone-pics-read')
  /* CONTROL: before the coarse-pointer rule the control is 28 px tall (FAIL) */
  ok('phone: tapping a paragraph shows Insert picture on screen, uncovered and a 44 px tap', [pic1.tool, pic2.tool].every((t) => t.shown && t.inView && t.onTop && t.h >= 44), [pic1.tool, pic2.tool])
  ok('phone: a tap on Insert picture opens the picker and the picture lands in the text', pic1.chooser && pic2.chooser
    && JSON.stringify(await mCaps(id11)) === JSON.stringify(['Phone pic one']) && JSON.stringify(await mCaps(id111)) === JSON.stringify(['Phone pic two']), { pic1, pic2 })
  ok('phone: read, both pictures show inline as Figure 1 and Figure 2 with their captions, within the width',
    mRead.paras === 2 && mRead.imgs.length === 2 && mRead.imgs.every((i) => i.w === 1 && i.fits) && mRead.fits
    && JSON.stringify(mRead.nums) === JSON.stringify(['Figure 1:', 'Figure 2:'])
    && JSON.stringify(mRead.caps) === JSON.stringify(['Phone pic one', 'Phone pic two']) && mRead.capH.every((h) => h >= 44), mRead)
  await m.tap(`${titleSel('1.1.1')} [data-test=ws-doc-pic-caption]`)
  await m.evaluate((sel) => document.querySelector(sel).select(), `${titleSel('1.1.1')} [data-test=ws-doc-pic-caption]`)
  await m.keyboard.type('Phone rollback')
  await m.keyboard.press('Enter')
  await mCapsAre(id111, ['Phone rollback'])
  const mRecap = await mCaps(id111)
  ok('phone: a figure caption is edited by touch, its token rewritten', JSON.stringify(mRecap) === JSON.stringify(['Phone rollback']), mRecap)
  /* phone, the Qto doc's markdown (t1 09a69b01): a tap on a body with a picture
     opens its raw markdown; a list and bold typed there render after blur, the figure kept */
  await editBody(m, titleSel('1.1'), true)
  const mRaw = await m.$eval(mText('1.1'), (e) => e.value).catch(() => null)
  await m.keyboard.down('Control')
  await m.keyboard.press('End')
  await m.keyboard.up('Control')
  await m.keyboard.type('\n\n- phone **bold** item')
  await m.evaluate(() => document.activeElement?.blur())
  await m.waitForFunction((row) => document.querySelector(`${row} [data-test=ws-doc-para] li strong`), { timeout: STEP }, titleSel('1.1')).catch(() => null)
  const mMd = await m.evaluate((row) => {
    const para = document.querySelector(`${row} [data-test=ws-doc-para]`)
    return {
      li: para?.querySelector('li')?.textContent?.trim() ?? null,
      strong: para?.querySelector('li strong')?.textContent ?? null,
      pics: para?.querySelectorAll('[data-test=ws-doc-pic-img]').length ?? 0,
      fits: document.documentElement.scrollWidth <= innerWidth + 1,
    }
  }, titleSel('1.1'))
  await shoot(m, 'phone-md-read')
  ok('phone: a tap opens the raw markdown; a list with bold renders after blur, the figure kept',
    typeof mRaw === 'string' && mRaw.includes('![Phone pic one](') && mMd.li === 'phone bold item' && mMd.strong === 'bold' && mMd.pics === 1 && mMd.fits, { mRaw, mMd })
  await view(m, 'grid')
  await m.waitForSelector('[data-test=ws-grid-row]', { visible: true, timeout: STEP }).catch(() => null)
  const phoneGrid = await m.evaluate(() => {
    const shown = (el) => Boolean(el) && getComputedStyle(el).display !== 'none' && el.getBoundingClientRect().width > 0
    const sc = document.querySelector('.wsgrid__scroll')
    return {
      level: shown(document.querySelector('[data-test=ws-grid-row] [data-test=ws-grid-level]')),
      meta: shown(document.querySelector('[data-test=ws-grid-col-meta]')),
      fits: sc ? sc.scrollWidth <= sc.clientWidth + 1 : false,
    }
  })
  await shoot(m, 'phone-grid')
  ok('phone: the grid keeps Level, hides Meta and fits the width', phoneGrid.level && !phoneGrid.meta && phoneGrid.fits, phoneGrid)
  await m.close()

  /* phone: the + floats bottom right (the issues page's), the modal creates */
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=ws-docs-new]', { visible: true, timeout: NAV_TIMEOUT })
  const fab = await p.$eval('[data-test=ws-docs-new]', (b) => {
    const r = b.getBoundingClientRect()
    return { pos: getComputedStyle(b).position, right: Math.round(innerWidth - r.right), w: Math.round(r.width) }
  })
  ok('phone: the + floats bottom right, 56 px', fab.pos === 'fixed' && fab.right === 16 && fab.w === 56, fab)
  await newDoc(p, 'E2E phone doc', 'made on a phone')
  await p.waitForFunction(() => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent?.trim() === 'E2E phone doc', { timeout: STEP }).catch(() => null)
  const phoneDoc = (await hubDocs(p)).find((d) => d.title === 'E2E phone doc')
  ok('phone: the modal creates the document with its meta description', phoneDoc?.description === 'made on a phone', phoneDoc)

  /* spec 138 (SPL-1966, owner HUM-10, t1 topic 7c968b85): a link opens the
     document at one section. A document with a tall picture in section 2
     and the target, section 10, far below the fold; the deep link is opened
     in a fresh docs page (the router, so the picture uploaded here is still
     the hub's and loads AFTER the first scroll, growing the layout above).
     After the 2 s settle the heading's top is at the sticky bar's bottom
     (<= 2 px) and the hash is the one opened; the same at 390x844; a form D
     anchor with a stale number and title lands by its id suffix; the menu's
     Copy link to section and a long press of the '#' copy the stable id
     link; a bare number, a title slug and an unknown id open the top with
     the status line. CONTROL: without landOn's re-scroll (ResizeObserver)
     the desktop and phone checks FAIL (the picture pushes the heading down). */
  const { deflateSync } = await import('node:zlib')
  /** a w x h grey png, built here (no binary in the repo) */
  const tallPng = (w, h) => {
    const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 })
    const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0 }
    const chunk = (type, data) => {
      const t = Buffer.concat([Buffer.from(type), data])
      const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
      const c = Buffer.alloc(4); c.writeUInt32BE(crc(t))
      return Buffer.concat([len, t, c])
    }
    const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 0
    const raw = Buffer.alloc((w + 1) * h, 0x99)
    for (let y = 0; y < h; y++) raw[y * (w + 1)] = 0
    return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
  }
  const tall = pjoin(tmpdir(), `wsdoc-e2e-${process.pid}-tall.png`)
  writeFileSync(tall, tallPng(200, 1400))
  const UNKNOWN = 'The linked section was not found; the document is shown from the top.'
  const nav = (q, to) => q.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), to)
  /** a fresh docs page at the link: away to /, then the link (the uploaded picture stays the mock hub's) */
  const openLink = async (q, doc, hash) => {
    await nav(q, '/')
    await q.waitForFunction(() => !document.querySelector('[data-test=ws-doc-view]'), { timeout: STEP }).catch(() => null)
    await nav(q, `/workspace/docs?doc=${doc}&view=doc${hash}`)
    await q.waitForSelector('[data-test=ws-doc-row]', { visible: true, timeout: STEP }).catch(() => null)
    await new Promise((r) => setTimeout(r, 2500))
  }
  /** the heading's top against the sticky bar's bottom (on a desktop the header holding the bar, SPL-2094), the hash, the picture above, the scroller, the status line */
  const landed = (q, id) => q.evaluate((id) => {
    const h = document.getElementById('ws-doc-' + id)
    const tools = document.querySelector('[data-test=ws-doc-bar]')
    const bar = tools?.closest('.feed-header') ?? tools
    const img = document.querySelector('[data-test=ws-doc-img]')
    const toc = document.querySelector('[data-test=ws-doc-toc]')
    return {
      gap: h && bar ? Math.round((h.getBoundingClientRect().top - bar.getBoundingClientRect().bottom) * 10) / 10 : null,
      hash: decodeURIComponent(location.hash),
      img: img ? img.naturalHeight : 0,
      scroll: document.querySelector('.wsdocs-page .feed-body')?.scrollTop ?? -1,
      status: document.querySelector('[data-test=ws-doc-status]')?.textContent?.trim() ?? '',
      toc: Boolean(toc && toc.getBoundingClientRect().width > 0),
    }
  }, id)
  /** a document of 12 sections with text, a tall picture in section 2: its id and section 10's */
  const linkDoc = async (q) => {
    await q.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await q.waitForFunction(() => typeof window.__wsDocTreeCall === 'function', { timeout: NAV_TIMEOUT })
    const made = await q.evaluate(async () => {
      const call = window.__wsDocTreeCall
      const d = await call('POST', '', { title: 'E2E section links' })
      let rev = d.rev
      const ids = []
      for (let i = 1; i <= 12; i++) {
        const r = await call('POST', `/${d.id}/items`, { rev, anchor: d.root, where: 'child', ord: i, title: `Section ${i}`, body: `Text of section ${i}. `.repeat(30) })
        rev = r.rev
        ids.push(r.item)
      }
      return { doc: d.id, target: ids[9] }
    })
    await openLink(q, made.doc, '')
    const [fc] = await Promise.all([q.waitForFileChooser({ timeout: STEP }), menu(q, 'doc', 'Section 2', 'add_image', 'dots')])
    await fc.accept([tall])
    await q.waitForFunction(() => document.querySelector('[data-test=ws-doc-img]')?.naturalHeight > 0, { timeout: STEP }).catch(() => null)
    return made
  }
  const ld = await browser.newPage()
  await ld.setViewport({ width: 1280, height: 800 })
  const L = await linkDoc(ld)
  await openLink(ld, L.doc, '#ws-doc-' + L.target)
  const deskA = await landed(ld, L.target)
  await shoot(ld, 'link-desktop')
  ok('spec 138: a deep link puts its heading just below the sticky bar after the picture above loaded; the hash is kept',
    deskA.gap !== null && Math.abs(deskA.gap) <= 2 && deskA.hash === '#ws-doc-' + L.target && deskA.img === 1400 && deskA.scroll > 1400 && !deskA.status, deskA)
  const dHash = `#9.9-a-stale-title~${L.target.slice(0, 8)}`
  await openLink(ld, L.doc, dHash)
  const deskD = await landed(ld, L.target)
  ok('spec 138: a readable anchor with a stale number and title lands by its id suffix, the hash kept',
    deskD.gap !== null && Math.abs(deskD.gap) <= 2 && deskD.hash === dHash && !deskD.status, deskD)

  /* Copy link to section: the menu entry and a long press of the '#' write the stable id link */
  await ld.evaluate(() => {
    window.__copied = []
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async (t) => { window.__copied.push(t) } } })
  })
  await menu(ld, 'doc', 'Section 10', 'copy_link', 'dots')
  await ld.waitForFunction(() => window.__copied.length === 1, { timeout: STEP }).catch(() => null)
  const sayCopied = await ld.$eval('[data-test=ws-doc-status]', (e) => e.textContent.trim())
  const perma = await ld.$(`[data-id="${L.target}"] [data-test=ws-doc-permalink]`)
  const pb = await perma.boundingBox()
  await ld.mouse.move(pb.x + pb.width / 2, pb.y + pb.height / 2)
  await ld.mouse.down()
  await new Promise((r) => setTimeout(r, 800))
  await ld.mouse.up()
  await ld.waitForFunction(() => window.__copied.length === 2, { timeout: STEP }).catch(() => null)
  const copied = await ld.evaluate(() => window.__copied)
  const want = `${new URL(server.base).origin}/workspace/docs?doc=${L.doc}&view=doc#ws-doc-${L.target}`
  ok('spec 138: Copy link to section and a long press of the # put the stable id link on the clipboard',
    copied.length === 2 && copied.every((c) => c === want) && sayCopied === 'Link copied', { copied, want, sayCopied })

  /* a bare number (B), a title slug (C) and an unknown id open the top with one status line */
  const tops = {}
  for (const h of ['#10', '#10-section-10', '#ws-doc-00000000-0000-4000-8000-000000000000']) {
    await openLink(ld, L.doc, h)
    tops[h] = await landed(ld, L.target)
  }
  await shoot(ld, 'link-unknown')
  ok('spec 138: a bare number, a title slug or an unknown anchor opens the document at its top with the status line',
    Object.values(tops).every((x) => x.scroll === 0 && x.status === UNKNOWN), tops)
  await ld.close()

  /* the phone: the deep link opens the doc view (no phone list), the contents drawer closed, the heading below the phone's bar */
  const lm = await browser.newPage()
  await lm.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  const M = await linkDoc(lm)
  await openLink(lm, M.doc, '#ws-doc-' + M.target)
  const phoneA = await landed(lm, M.target)
  await shoot(lm, 'link-phone')
  ok('spec 138: phone 390x844: the deep link opens the section below the bar, the drawer closed, the hash kept',
    phoneA.gap !== null && Math.abs(phoneA.gap) <= 2 && phoneA.hash === '#ws-doc-' + M.target && phoneA.img === 1400 && !phoneA.toc && !(await lm.$('[data-test=ws-docs-page] [data-test=qto-file-tree]')), phoneA)
  await lm.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `workspace-doctree: ${failed} FAILED` : `workspace-doctree: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
