// Owner HUM-10 (t1 a1b42c34, msg 02749694): the "Documents" title is
// unneeded, the icons go up into one small bar at the top. Qto reading panel plan v1.0 row 01 (SPL-2515): at <= 820 px
// with a document open the /workspace/docs header is ONE strip: it does not
// wrap (<= 46 px tall), the "Documents" heading takes no room (kept for
// screen readers) and the + sits inside the strip instead of floating
// (position: static, not fixed). A desktop keeps its header (one
// <= 70 px row, heading shown: 58..128 px on master c5e1fa432; the plan's
// 115 px is the /docs page).
// Control: on the earlier master at 412x915 and 800x915 the header wraps to
// 2+ rows (>= 88 px), the heading is visible and .wsdocs-fab is fixed, so
// every phone check FAILS.
//
// SPL-3233 (owner t1 a1b42c34, msg 7caac933: "Remove the bar with the
// export and export to PDF. The icon add those as a separate menu somewhere
// at the top."): at 360, 412 and 1440 px the doc view draws no row of its own
// above the document (no Print / Export to Markdown buttons anywhere); one
// dots button in the header row (>= 44 px) opens a menu holding both, by
// Enter, closed by Escape with the focus back on the button, and each entry
// fires its old handler (window.print, a .md download).
// Control: on master f41679966 the phone draws the bar inside the doc view
// with ws-doc-print-doc / ws-doc-export-doc and no ws-doc-file-btn, so every
// SPL-3233 check FAILS there.
//
// SPL-6083 (owner t1 60bf4e56, msgs ce88082a, 55440858): with a document
// open, on every width, the header holds no document picker, no + and no
// Outline / Grid pills, and the "Documents" heading takes no room (kept for
// screen readers); the menu button wears the three bars, the contents
// toggle an open book, and the menu holds Print, Export to Markdown, then
// Outline and Grid, the current view checked. Grid from the menu shows the
// grid with the same menu in the header, and Outline brings the document
// back. Control: on master cbbc11996 the picker, the + and the pills are in
// the header and the menu has two entries, so every SPL-6083 check FAILS.
//
//   node tests/e2e/qto-mobile-docs-head.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/qto-mobile-docs-head.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const STEP = 15000
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

/** the header's geometry with a document open */
const measure = (p) => p.evaluate(() => {
  const head = document.querySelector('[data-test=ws-docs-page] .wsdocs-head')
  const h2 = document.querySelector('[data-test=ws-docs-heading]')
  const seen = (sel) => [...document.querySelectorAll(sel)].some((el) => el.getBoundingClientRect().width > 1)
  if (!head || !h2) return null
  const hb = head.getBoundingClientRect()
  return {
    headTop: Math.round(hb.top),
    headBottom: Math.round(hb.bottom),
    headH: Math.round(hb.height),
    headOverflow: head.scrollWidth - head.clientWidth,
    pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
    h2H: Math.round(h2.getBoundingClientRect().height),
    h2Pos: getComputedStyle(h2).position,
    h2Text: h2.textContent.trim(),
    /* SPL-6083: none of these is drawn with a document open */
    gone: { plus: seen('[data-test=ws-docs-new]'), pick: seen('[data-test=ws-docs-select]'), pills: seen('[data-test^=ws-docs-view-]') },
    icons: {
      file: document.querySelector('[data-test=ws-doc-file-btn] [data-icon]')?.getAttribute('data-icon') ?? '',
      toc: document.querySelector('[data-test=ws-doc-toc-toggle] [data-icon]')?.getAttribute('data-icon') ?? '',
    },
  }
})

async function openDoc(p, vp) {
  await p.setViewport(vp)
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  /* the first page of a cold dev server compiles for a while */
  await p.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const id = await p.waitForFunction(() => window.__wsDocTreeCall?.('GET', '').then((r) => r.docs?.[0]?.id || ''), { timeout: STEP })
    .then((h) => h.jsonValue(), () => '')
  ok(`${vp.width}: the mock lists a document`, Boolean(id), id)
  await p.goto(`${server.base}/workspace/docs?doc=${id}&view=doc`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return p.waitForSelector('[data-test=ws-doc-view]', { visible: true, timeout: STEP }).then(Boolean, () => false)
}

/* a phone's sheet slides in and out: wait until no menu is left, open it, wait until the entry stops moving, click it */
async function menuPick(p, id) {
  await p.waitForFunction(() => !document.querySelector('[data-test=ws-doc-file-menu]'), { timeout: STEP }).catch(() => null)
  await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
  const sel = `[data-test=ws-doc-file-menu-${id}]`
  await p.waitForFunction((sel) => new Promise((done) => {
    const el = document.querySelector(sel)
    if (!el) return done(false)
    const a = el.getBoundingClientRect()
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const b = el.getBoundingClientRect()
      done(a.width > 0 && a.top === b.top && a.left === b.left)
    }))
  }), { timeout: STEP }, sel).catch(() => null)
  await p.click(sel).catch(() => null)
}

/* SPL-6139: Background… sits after Export to Markdown, in the doc view only */
const VIEW_ITEMS = ['ws-doc-file-menu-print', 'ws-doc-file-menu-export_md', 'ws-doc-file-menu-background', 'ws-doc-file-menu-view_doc', 'ws-doc-file-menu-view_grid']

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ width: 412, height: 915 }, { width: 800, height: 915 }]) {
    console.log(`-- ${vp.width}x${vp.height} phone, a document open`)
    const p = await browser.newPage()
    ok(`${vp.width}: the document view is open`, await openDoc(p, vp))
    const m = await measure(p)
    ok(`${vp.width}: the header is measured`, Boolean(m), m)
    if (m) {
      ok(`${vp.width}: the header is one strip, <= 46 px tall`, m.headH <= 46, m.headH)
      ok(`${vp.width}: nothing in the strip runs past its edge`, m.headOverflow <= 0 && m.pageOverflow <= 0, { head: m.headOverflow, page: m.pageOverflow })
      /* the sr-only pattern: out of the flow, a 1 px box */
      ok(`${vp.width}: the "Documents" heading takes no room`, m.h2Pos === 'absolute' && m.h2H <= 1, { h: m.h2H, pos: m.h2Pos })
      ok(`${vp.width}: ... and stays for screen readers`, m.h2Text.length > 0, m.h2Text)
      ok(`${vp.width}: no +, no document picker, no view pills in the strip`, Object.values(m.gone).every((v) => !v), m.gone)
      ok(`${vp.width}: the menu wears the three bars, the contents toggle an open book`, m.icons.file === 'menu' && m.icons.toc === 'book-open', m.icons)
    }
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-mobile-head-${vp.width}.png` })
    await p.close()
  }

  console.log('-- 1280x800 desktop, a document open')
  const d = await browser.newPage()
  const vp = { width: 1280, height: 800 }
  ok('1280: the document view is open', await openDoc(d, vp))
  const m = await measure(d)
  ok('1280: the header is measured', Boolean(m), m)
  if (m) {
    /* master c5e1fa432 measured 58..128 (a 70 px row); the row 01 change is phone only */
    ok('1280: the header row is unchanged, one row <= 70 px', m.headH <= 70, { top: m.headTop, bottom: m.headBottom, h: m.headH })
    ok('1280: the "Documents" heading takes no room (SPL-6083)', m.h2Pos === 'absolute' && m.h2H <= 1, { h: m.h2H, pos: m.h2Pos })
    ok('1280: ... and stays for screen readers', m.h2Text.length > 0, m.h2Text)
    ok('1280: no +, no document picker, no view pills in the header (SPL-6083)', Object.values(m.gone).every((v) => !v), m.gone)
    ok('1280: the menu wears the three bars, the contents toggle an open book', m.icons.file === 'menu' && m.icons.toc === 'book-open', m.icons)
  }
  await d.close()

  for (const vp of [{ width: 360, height: 740 }, { width: 412, height: 915 }, { width: 1440, height: 900 }]) {
    console.log(`-- SPL-3233 ${vp.width}x${vp.height}: no export bar, one file menu in the header`)
    const p = await browser.newPage()
    ok(`${vp.width}: the document view is open`, await openDoc(p, vp))
    await p.waitForSelector('[data-test=ws-doc-row]', { visible: true, timeout: STEP }).catch(() => null)
    const g = await p.evaluate(() => {
      const box = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) } }
      const view = document.querySelector('[data-test=ws-doc-view]')
      const head = document.querySelector('[data-test=ws-docs-page] .wsdocs-head')
      const btn = document.querySelector('[data-test=ws-doc-file-btn]')
      return {
        oldButtons: document.querySelectorAll('[data-test=ws-doc-print-doc], [data-test=ws-doc-export-doc]').length,
        barInView: Boolean(view?.querySelector('[data-test=ws-doc-bar]')),
        view: box(view), title: box(document.querySelector('[data-test=ws-doc-doctitle]')), head: box(head), btn: box(btn),
        btnInHead: Boolean(btn && head?.contains(btn)),
        popup: btn?.getAttribute('aria-haspopup') ?? '', name: btn?.getAttribute('aria-label') ?? '',
        /* the header's controls, left to right: none may overlap the next one */
        overlaps: [...(head?.querySelectorAll('select, [role=radio], button') ?? [])]
          .filter((e) => e.getBoundingClientRect().width > 1)
          .map((e) => ({ id: e.dataset.test || e.tagName, ...box(e) }))
          .sort((a, b) => a.x - b.x)
          .filter((b, i, all) => i > 0 && b.x < all[i - 1].x + all[i - 1].w - 0.5)
          .map((b) => b.id),
      }
    })
    ok(`${vp.width}: no Print / Export to Markdown button left on the page`, g.oldButtons === 0, g.oldButtons)
    ok(`${vp.width}: no bar row inside the doc view; it starts with its title`, !g.barInView && g.view && g.title && g.title.y - g.view.y < 40, { view: g.view, title: g.title })
    ok(`${vp.width}: the file menu button sits in the header row`, g.btnInHead && g.btn && g.head && g.btn.y >= g.head.y - 0.5 && g.btn.y + g.btn.h <= g.head.y + g.head.h + 0.5, { btn: g.btn, head: g.head })
    ok(`${vp.width}: no two header controls overlap`, g.overlaps.length === 0, g.overlaps)
    ok(`${vp.width}: the button is a 44 px tap with a name and a menu popup`, g.btn && g.btn.w >= 44 && g.btn.h >= 44 && g.popup === 'menu' && g.name.length > 0, g)
    /* R7 W1: the menu holds the views too, so it is named for the document, not "Download" (en locale) */
    ok(`${vp.width}: the menu button is named Document actions`, g.name === 'Document actions', g.name)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-export-menu-${vp.width}.png` })

    /* the keyboard: Enter opens it, both entries are in it, Escape closes it, the focus is back on the button */
    await p.focus('[data-test=ws-doc-file-btn]').catch(() => null)
    await p.keyboard.press('Enter')
    await p.waitForSelector('[data-test=ws-doc-file-menu]', { visible: true, timeout: STEP }).catch(() => null)
    const m = await p.evaluate(() => ({
      items: [...document.querySelectorAll('[data-test=ws-doc-file-menu] [role=menuitem]')].map((e) => ({ id: e.dataset.test, h: Math.round(e.getBoundingClientRect().height), icon: e.querySelector('[data-icon]')?.getAttribute('data-icon') })),
      expanded: document.querySelector('[data-test=ws-doc-file-btn]')?.getAttribute('aria-expanded'),
    }))
    ok(`${vp.width}: Enter opens the menu with Print, Export to Markdown, Background, Outline and Grid`, m.expanded === 'true'
      && JSON.stringify(m.items.map((i) => i.id)) === JSON.stringify(VIEW_ITEMS), m)
    ok(`${vp.width}: ... Outline is checked`, m.items.find((i) => i.id === 'ws-doc-file-menu-view_doc')?.icon === 'check', m.items)
    if (vp.width <= 820) ok(`${vp.width}: each entry is a 44 px tap`, m.items.length === VIEW_ITEMS.length && m.items.every((i) => i.h >= 44), m.items)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-export-menu-${vp.width}-open.png` })
    await p.keyboard.press('Escape')
    await p.waitForFunction(() => !document.querySelector('[data-test=ws-doc-file-menu]'), { timeout: STEP }).catch(() => null)
    const esc = await p.evaluate(() => ({ open: Boolean(document.querySelector('[data-test=ws-doc-file-menu]')), focus: document.activeElement?.dataset?.test ?? '' }))
    ok(`${vp.width}: Escape closes it and gives the focus back to the button`, !esc.open && esc.focus === 'ws-doc-file-btn', esc)

    /* a desktop popover: a second click on the button closes it (on a phone the sheet's backdrop covers the button) */
    if (vp.width > 820) {
      await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
      await p.waitForSelector('[data-test=ws-doc-file-menu]', { visible: true, timeout: STEP }).catch(() => null)
      await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
      await new Promise((r) => setTimeout(r, 300))
      const again = await p.evaluate(() => Boolean(document.querySelector('[data-test=ws-doc-file-menu]')))
      ok(`${vp.width}: a second click on the button closes the menu`, !again, again)
    }

    /* each entry fires its old handler: Print = the browser's print, Export = a .md download */
    await p.evaluate(() => {
      window.__printed = 0
      window.print = () => { window.__printed++ }
      window.__downloads = []
      HTMLAnchorElement.prototype.click = function () { if (this.download) window.__downloads.push(this.download) }
    })
    await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
    await p.click('[data-test=ws-doc-file-menu-print]').catch(() => null)
    await p.waitForFunction(() => window.__printed === 1, { timeout: STEP }).catch(() => null)
    await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))
    await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
    await p.click('[data-test=ws-doc-file-menu-export_md]').catch(() => null)
    await p.waitForFunction(() => window.__downloads.length === 1, { timeout: STEP }).catch(() => null)
    const fired = await p.evaluate(() => ({ printed: window.__printed, downloads: window.__downloads, focus: document.activeElement?.dataset?.test ?? '' }))
    ok(`${vp.width}: Print prints, once`, fired.printed === 1, fired)
    ok(`${vp.width}: Export to Markdown saves one .md file`, fired.downloads.length === 1 && /\.md$/.test(fired.downloads[0]), fired)
    ok(`${vp.width}: after a choice the focus is back on the button`, fired.focus === 'ws-doc-file-btn', fired)

    /* SPL-6083: Grid from the menu; the grid keeps the menu, Grid checked, no export; Outline brings the document back */
    await menuPick(p, 'view_grid')
    const grid = await p.waitForSelector('[data-test=ws-grid-view]', { visible: true, timeout: STEP }).then(Boolean, () => false)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-view-grid-${vp.width}.png` })
    await p.waitForFunction(() => !document.querySelector('[data-test=ws-doc-file-menu]'), { timeout: STEP }).catch(() => null)
    await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
    await p.waitForSelector('[data-test=ws-doc-file-menu]', { visible: true, timeout: STEP }).catch(() => null)
    const inGrid = await p.evaluate(() => [...document.querySelectorAll('[data-test=ws-doc-file-menu] [role=menuitem]')]
      .map((e) => `${e.dataset.test}:${e.querySelector('[data-icon]')?.getAttribute('data-icon')}`))
    ok(`${vp.width}: Grid from the menu shows the grid, view=grid`, grid && new URL(p.url()).searchParams.get('view') === 'grid', p.url())
    ok(`${vp.width}: ... its menu holds Print, Outline, Grid (checked)`, inGrid.join() === 'ws-doc-file-menu-print:file-text,ws-doc-file-menu-view_doc:list,ws-doc-file-menu-view_grid:check', inGrid)
    await p.keyboard.press('Escape')
    await menuPick(p, 'view_doc')
    ok(`${vp.width}: Outline from the menu brings the document back`, await p.waitForSelector('[data-test=ws-doc-view]', { visible: true, timeout: STEP }).then(Boolean, () => false))
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-mobile-docs-head: ${failed} FAILED` : `qto-mobile-docs-head: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
