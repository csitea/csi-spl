// SPL-2024 (Qto gaps G3, G4): a section keeps the number its md author gave
// it. The md import stores a number the doc would not derive (a section 0, a
// gap, a restart) in attrs.outline_author, and the hub's read answers it as
// the item's outline (store authorOutline; the mock tenant the same through
// -doc-outline.ts). The doc view shows it beside each heading and the bar's
// Export to Markdown writes it; an item with no such attr keeps its derived
// number. Red before: the view showed the derived 1, 2, 2.1, 3, 4, 4.1, 4.2.
//
//   BASE_URL=<generated bundle> SHOT_DIR=/tmp/shots node tests/e2e/workspace-doc-author-outline.test.mjs
import { createRequire } from 'node:module'
import { join } from 'node:path'
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
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** the mock hub's raw call (not the page's copy) */
const hub = (p, method, path, body) => p.evaluate((m, x, b) => window.__wsDocTreeCall(m, x, b), method, path, body)

/* the page as the md import writes it: [title, depth, attrs.outline_author ('' = none: the derived number is the author's)] */
const PAGE = [
  ['The order, verbatim', 1, '0'],
  ['The job', 1, '1'],
  ['Read', 2, '1.1'],
  ['Peer mesh', 1, '3.1'],
  ['Picks', 1, '4'],
  ['First', 2, '1'],
  ['Second', 2, '2'],
  ['Traps', 1, ''],
]
const WANT = ['0', '1', '1.1', '3.1', '4', '1', '2', '5']

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=ws-docs-new]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => typeof window.__wsDocTreeCall === 'function', { timeout: STEP })

  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', 'E2E author numbers')
  await p.click('[data-test=ws-docs-create]')
  await p.waitForSelector('[data-test=ws-doc-row]', { visible: true, timeout: STEP })
  const doc = (await hub(p, 'GET', '')).docs.find((d) => d.title === 'E2E author numbers')
  let head = await hub(p, 'GET', '/' + doc.id)

  /* the starter outline out, then one heading per section */
  for (const it of (await hub(p, 'GET', `/${doc.id}/subtree`)).items.filter((x) => x.depth === 1)) {
    await hub(p, 'DELETE', `/${doc.id}/items/${it.id}?rev=${head.rev}`)
    head = await hub(p, 'GET', '/' + doc.id)
  }
  const last = []
  for (const [title, depth, own] of PAGE) {
    const anchor = depth === 1 ? head.root : last[depth - 1]
    const r = await hub(p, 'POST', `/${doc.id}/items`, { rev: head.rev, anchor, where: 'child', ord: 0, title, body: `Text of ${title}.` })
    head = await hub(p, 'GET', '/' + doc.id)
    last[depth] = r.item
    if (own) await hub(p, 'PATCH', `/${doc.id}/items/${r.item}`, { field: 'attrs', value: JSON.stringify({ outline_author: own }), rev: 1 })
  }

  /* the view mounted again, as after an import */
  await p.click('[data-test=ws-docs-view-grid]')
  await p.waitForSelector('[data-test=ws-grid-view]', { visible: true, timeout: STEP })
  await p.click('[data-test=ws-docs-view-doc]')
  await p.waitForFunction((n) => document.querySelectorAll('[data-test=ws-doc-row]').length === n, { timeout: STEP }, PAGE.length).catch(() => null)
  const shown = await p.$$eval('[data-test=ws-doc-row]', (rows) => rows.map((r) => ({
    outline: r.dataset.outline,
    num: r.querySelector('[data-test=ws-doc-num]')?.textContent?.trim() ?? '',
  })))
  ok('the doc view shows each section\'s number as the author wrote it (0, a gap, a restart); one with no attr is derived',
    JSON.stringify(shown.map((s) => s.num)) === JSON.stringify(WANT) && shown.every((s) => s.outline === s.num), shown)
  if (process.env.SHOT_DIR) {
    await p.evaluate(() => window.scrollTo(0, 0))
    await p.screenshot({ path: join(process.env.SHOT_DIR, 'qto-author-outline.png'), fullPage: true })
  }

  /* the file menu's Export to Markdown (SPL-3233) writes the same numbers */
  await p.evaluate(() => {
    window.__exports = []
    const make = URL.createObjectURL
    URL.createObjectURL = (b) => { b.text().then((t) => window.__exports.push(t)); return make.call(URL, b) }
    HTMLAnchorElement.prototype.click = function () { if (this.download) window.__exportNames = [...(window.__exportNames || []), this.download] }
  })
  await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
  await p.click('[data-test=ws-doc-file-menu-export_md]').catch(() => null)
  await p.waitForFunction(() => window.__exports.length === 1, { timeout: STEP }).catch(() => null)
  const md = await p.evaluate(() => window.__exports[0] || '')
  const heads = md.split('\n').filter((l) => l.startsWith('#'))
  ok('Export to Markdown writes the author\'s numbers', JSON.stringify(heads) === JSON.stringify([
    '# 0 The order, verbatim', '# 1 The job', '## 1.1 Read', '# 3.1 Peer mesh', '# 4 Picks', '## 1 First', '## 2 Second', '# 5 Traps',
  ]), heads)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `workspace-doc-author-outline: ${failed} FAILED` : `workspace-doc-author-outline: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
