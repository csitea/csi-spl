// SPL-5410 (owner HUM-10, t1 e791b8a2, 2026-11-12): two bugs of the Docs view
// (/docs/<repo path>):
//   1 "the vertical bar is not resizeable": the tree | doc bar is the shell's
//     PaneDivider (useDocsTreeWidth, the Qto doc view's): a drag widens the
//     tree, the keys step it, a double click resets it, the width survives a
//     reload (spool.pane-widths docsTree), and a phone (<= 820 px) shows no bar.
//   2 the "vertical sections triangles" do not work the way they do in the
//     Topics view (holder c-002, msg 458287ec: reading B): the tree pane gets
//     its own spec 050 bottom-corner triangle, like the channels panel: open
//     it points to inline-start (the way it moves), a click collapses the tree
//     to the 24 px strip and it then points to inline-end, the state survives a
//     reload, a second click expands it; it does not sit on the middle
//     panel's triangle, and it leaves the shell's collapse flags alone.
// Control: on master 500be8c0f the bar is a border (no separator in the docs
// page) and the tree has no triangle, so every check of 1 and 2 FAILS.
//
// Run:
//   pnpm run test:e2e docs-tree-pane
//   BASE_URL=<generated bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e docs-tree-pane
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const DOC = '/docs/README.md'
const BAR = '[data-test=docs] [data-testid=pane-divider-sidebar]'
const TRI = '[data-test=docs-tree-collapse]'
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `docs-tree-pane-${name}.png`) })
}

async function until(read, want, max = 4000) {
  const end = Date.now() + max
  let s = await read()
  while (!want(s) && Date.now() < end) {
    await sleep(80)
    s = await read()
  }
  return s
}

/* the tree's and the doc's boxes, the bar, the triangle and the stored prefs */
const geo = (p) => p.evaluate((bar, tri) => {
  const box = (el) => {
    if (!el || getComputedStyle(el).display === 'none') return null
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 ? { left: Math.round(r.left), right: Math.round(r.right), top: Math.round(r.top), bottom: Math.round(r.bottom), width: Math.round(r.width) } : null
  }
  const t = document.querySelector(tri)
  let panes = null
  let tree = null
  try { panes = JSON.parse(localStorage.getItem('spool.pane-widths') || 'null') } catch { /* none */ }
  try { tree = JSON.parse(localStorage.getItem('spool.docs-tree-collapsed') || 'null') } catch { /* none */ }
  return {
    tree: box(document.querySelector('[data-test=docs-tree]')),
    doc: box(document.querySelector('[data-test=docs-content]')),
    bar: box(document.querySelector(bar)),
    tri: box(t),
    expanded: t ? t.getAttribute('aria-expanded') : null,
    pointsEnd: t ? t.classList.contains('pane-collapse--point-end') : null,
    rows: document.querySelectorAll('[data-test=docs-tree] [data-test=docs-dir]').length,
    rowsShown: [...document.querySelectorAll('[data-test=docs-tree] [data-test=docs-dir]')].filter((e) => e.getClientRects().length).length,
    mid: box(document.querySelector('[data-test=pane-collapse-topic]')),
    docsTree: panes && panes.docsTree,
    collapsedPref: tree,
    shell: localStorage.getItem('spool.pane-collapsed'),
  }
}, BAR, TRI)

async function open(p) {
  await p.goto(p.__base + DOC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=docs-tree] [data-test=docs-dir]', { timeout: 15000 }).catch(() => null)
  await sleep(300)
}

const overlap = (a, b) => Boolean(a && b && a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom)

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1440x900: the bar drags')
  const p = await browser.newPage()
  p.__base = server.base
  await p.setViewport({ width: 1440, height: 900 })
  await open(p)
  await p.evaluate(() => { localStorage.removeItem('spool.docs-tree-collapsed'); const r = JSON.parse(localStorage.getItem('spool.pane-widths') || '{}'); delete r.docsTree; localStorage.setItem('spool.pane-widths', JSON.stringify(r)) })
  await open(p)
  let g = await geo(p)
  ok('the tree | doc bar is a separator between the tree and the doc', Boolean(g.bar && g.tree && g.doc && g.bar.left >= g.tree.right - 2 && g.bar.right <= g.doc.left + 2), g)
  const w0 = g.tree?.width ?? 0
  if (g.bar) {
    const x = (g.bar.left + g.bar.right) / 2
    const y = (g.bar.top + g.bar.bottom) / 2
    await p.mouse.move(x, y)
    await p.mouse.down()
    for (let i = 1; i <= 6; i++) await p.mouse.move(x + i * 20, y)
    await p.mouse.up()
  }
  g = await until(() => geo(p), (s) => (s.tree?.width ?? 0) > w0 + 100)
  ok('a drag of 120 px widens the tree by about 120 px', Math.abs((g.tree?.width ?? 0) - w0 - 120) <= 8, { w0, w: g.tree?.width })
  ok('the doc gives the room up (it starts after the bar)', Boolean(g.doc && g.bar && g.doc.left >= g.bar.right - 2), g.doc)
  ok('the width is kept on this device (spool.pane-widths docsTree)', Math.abs((g.docsTree ?? 0) - (g.tree?.width ?? 0)) <= 2, { stored: g.docsTree })
  await open(p)
  const kept = await geo(p)
  ok('a reload draws the dragged width', Math.abs((kept.tree?.width ?? 0) - (g.tree?.width ?? 0)) <= 2, { before: g.tree?.width, after: kept.tree?.width })
  await p.focus(BAR).catch(() => {})
  await p.keyboard.press('ArrowLeft')
  g = await until(() => geo(p), (s) => (s.tree?.width ?? 0) < (kept.tree?.width ?? 0))
  ok('ArrowLeft on the bar narrows the tree by a step (16 px)', Math.abs((kept.tree?.width ?? 0) - (g.tree?.width ?? 0) - 16) <= 2, { before: kept.tree?.width, after: g.tree?.width })
  await p.focus(BAR).catch(() => {})
  await p.keyboard.press('Home')
  g = await until(() => geo(p), (s) => (s.tree?.width ?? 0) < 200)
  ok('Home clamps it to the minimum (180 px, the channel sidebar\'s)', Math.abs((g.tree?.width ?? 0) - 180) <= 2, g.tree)
  const bar = await p.$(BAR)
  if (bar) await bar.click({ count: 2 })
  g = await until(() => geo(p), (s) => Math.abs((s.tree?.width ?? 0) - w0) <= 2)
  ok('a double click resets it to the default width', Math.abs((g.tree?.width ?? 0) - w0) <= 2, { w0, w: g.tree?.width })
  await shot(p, 'desktop-dragged')

  console.log('-- 1440x900: the tree\'s triangle')
  await open(p)
  g = await geo(p)
  const shell0 = g.shell
  ok('the tree has its own collapse triangle, open (aria-expanded=true)', g.expanded === 'true', g.expanded)
  ok('it sits in the tree\'s bottom corner', Boolean(g.tri && g.tree && g.tri.left >= g.tree.left - 2 && g.tri.right <= g.tree.right + 2 && g.tree.bottom - g.tri.bottom < 40), { tri: g.tri, tree: g.tree })
  ok('open, it points to inline-start (the way the tree collapses)', g.pointsEnd === false)
  ok('it does not sit on the middle panel\'s triangle', !overlap(g.tri, g.mid), { tri: g.tri, mid: g.mid })
  await shot(p, 'desktop-open')
  const docW = g.doc?.width ?? 0
  const tri = await p.$(TRI)
  if (tri) await tri.click()
  g = await until(() => geo(p), (s) => s.expanded === 'false')
  ok('a click collapses the tree to the 24 px strip', Boolean(g.tree && Math.abs(g.tree.width - 24) <= 2), g.tree)
  ok('its folders are hidden', g.rows > 0 && g.rowsShown === 0, { rows: g.rows, shown: g.rowsShown })
  ok('collapsed, it points to inline-end (the way it expands)', g.pointsEnd === true)
  ok('a strip has no resize bar', !g.bar)
  ok('the doc takes the room', (g.doc?.width ?? 0) > docW + 150, { before: docW, after: g.doc?.width })
  ok('the triangle stays in the strip', Boolean(g.tri && g.tree && g.tri.left >= g.tree.left - 2 && g.tri.right <= g.tree.right + 2), { tri: g.tri, tree: g.tree })
  ok('the collapsed triangle does not sit on the middle panel\'s', !overlap(g.tri, g.mid), { tri: g.tri, mid: g.mid })
  ok('the shell\'s collapse flags are untouched', g.shell === shell0, { before: shell0, after: g.shell })
  await shot(p, 'desktop-collapsed')
  await open(p)
  g = await geo(p)
  ok('a reload keeps it collapsed (this device)', g.expanded === 'false' && Boolean(g.tree && g.tree.width <= 26), { expanded: g.expanded, tree: g.tree })
  const tri2 = await p.$(TRI)
  if (tri2) await tri2.click()
  g = await until(() => geo(p), (s) => s.expanded === 'true')
  ok('a second click expands it to its width again', g.expanded === 'true' && Math.abs((g.tree?.width ?? 0) - w0) <= 2 && g.rowsShown > 0, { tree: g.tree, shown: g.rowsShown })
  ok('the bar is back', Boolean(g.bar))
  await p.close()

  console.log('-- 412x915: a phone shows neither')
  const m = await browser.newPage()
  m.__base = server.base
  await m.setViewport({ width: 412, height: 915, isMobile: true, hasTouch: true })
  await open(m)
  g = await geo(m)
  ok('CONTROL no resize bar on a phone', !g.bar)
  ok('CONTROL no tree triangle on a phone', !g.tri)
  await m.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `docs-tree-pane: ${failed} FAILED` : `docs-tree-pane: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
