// SPL-1612: a Qto doc's preamble, the hidden root's body (the text before
// section 1), in the doc view. An empty one is a closed paragraph above
// section 1; a body set on the root (as the md import sets it) reads there
// as rendered markdown, before the first section and with no heading; a
// click edits it in place and the hub's root body is the typed text; a
// branch opened alone has no preamble; the bar's Export to Markdown opens
// with it, as `spool doctree export` does. Red before: the view read the
// document without its root, so nothing showed and the export started at 1.
//
//   BASE_URL=<generated bundle> node tests/e2e/workspace-doc-preamble.test.mjs
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

const PRE = '[data-test=ws-doc-preamble]'
/** the mock hub's raw call (not the page's copy) */
const hub = (p, method, path, body) => p.evaluate((m, x, b) => window.__wsDocTreeCall(m, x, b), method, path, body)
/** the preamble as the page shows it: where it sits, its read view, its textarea */
const preamble = (p) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  const row = document.querySelector('[data-test=ws-doc-row]')
  return {
    shown: Boolean(el),
    before: Boolean(el && row && el.compareDocumentPosition(row) & Node.DOCUMENT_POSITION_FOLLOWING),
    heading: Boolean(el?.querySelector('h3')),
    text: el?.querySelector('[data-test=ws-doc-para]')?.textContent?.trim() ?? null,
    strong: el?.querySelector('[data-test=ws-doc-para] strong')?.textContent ?? null,
    box: Boolean(el?.querySelector('[data-test=ws-doc-text]')),
  }
}, PRE)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=ws-docs-new]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => typeof window.__wsDocTreeCall === 'function', { timeout: STEP })

  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', 'E2E preamble')
  await p.click('[data-test=ws-docs-create]')
  await p.waitForSelector('[data-test=ws-doc-row]', { visible: true, timeout: STEP })
  const doc = (await hub(p, 'GET', '')).docs.find((d) => d.title === 'E2E preamble')
  const root = doc ? (await hub(p, 'GET', '/' + doc.id)).root : ''

  const empty = await preamble(p)
  ok('an empty preamble is a closed paragraph above section 1, no heading', empty.shown && empty.before && !empty.heading && empty.box && empty.text === null, empty)

  /* the root's body as the md import writes it, then the view mounted again */
  const rootRev = (await hub(p, 'GET', `/${doc.id}/subtree?item=${root}`)).items[0].rev
  await hub(p, 'PATCH', `/${doc.id}/items/${root}`, { field: 'body', value: 'For whoever holds the **seat**.', rev: rootRev })
  await p.click('[data-test=ws-docs-view-grid]')
  await p.waitForSelector('[data-test=ws-grid-view]', { visible: true, timeout: STEP })
  await p.click('[data-test=ws-docs-view-doc]')
  await p.waitForFunction((sel) => document.querySelector(`${sel} [data-test=ws-doc-para] strong`), { timeout: STEP }, PRE).catch(() => null)
  const read = await preamble(p)
  ok('the root body reads as rendered markdown before section 1', read.before && !read.heading && read.text === 'For whoever holds the seat.' && read.strong === 'seat', read)

  /* a click edits the raw text in place; leaving it saves the root body */
  await p.click(`${PRE} [data-test=ws-doc-para]`)
  await p.waitForFunction((sel) => document.activeElement === document.querySelector(`${sel} [data-test=ws-doc-text]`), { timeout: STEP }, PRE).catch(() => null)
  const raw = await p.$eval(`${PRE} [data-test=ws-doc-text]`, (e) => e.value).catch(() => null)
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.type('Read this first.')
  await p.evaluate(() => document.activeElement?.blur())
  await p.waitForFunction(async (d, r) => (await window.__wsDocTreeCall('GET', `/${d}/subtree?item=${r}`)).items[0].body === 'Read this first.', { timeout: STEP, polling: 200 }, doc.id, root).catch(() => null)
  const saved = (await hub(p, 'GET', `/${doc.id}/subtree?item=${root}`)).items[0].body
  ok('a click opens the raw markdown; leaving it saves the root body on the hub', raw === 'For whoever holds the **seat**.' && saved === 'Read this first.', { raw, saved })

  /* a branch opened alone has no preamble */
  await p.evaluate(() => document.querySelector('[data-test=ws-doc-row]').scrollIntoView({ block: 'center' }))
  await p.click('[data-test=ws-doc-row] [data-test=ws-doc-menu-btn]')
  const open = await p.waitForSelector('[data-testid="ws-doc-menu-open_branch"]', { visible: true, timeout: STEP })
  await open.click()
  await p.waitForSelector('[data-test=ws-doc-branch]', { visible: true, timeout: STEP }).catch(() => null)
  const inBranch = await preamble(p)
  await p.click('[data-test=ws-doc-branch-clear]')
  await p.waitForSelector(PRE, { timeout: STEP }).catch(() => null)
  ok('a branch opened alone has no preamble; the whole document has it again', !inBranch.shown && (await preamble(p)).shown, { inBranch })

  /* the bar's Export to Markdown: the preamble, then section 1 */
  await p.evaluate(() => {
    window.__exports = []
    const make = URL.createObjectURL
    URL.createObjectURL = (b) => { b.text().then((t) => window.__exports.push(t)); return make.call(URL, b) }
    HTMLAnchorElement.prototype.click = function () { if (this.download) window.__exportNames = [...(window.__exportNames || []), this.download] }
  })
  await p.click('[data-test=ws-doc-export-doc]').catch(() => null)
  await p.waitForFunction(() => window.__exports.length === 1, { timeout: STEP }).catch(() => null)
  const ex = await p.evaluate(() => ({ files: window.__exportNames, md: window.__exports[0] }))
  ok('Export to Markdown opens with the preamble, then section 1', JSON.stringify(ex.files) === JSON.stringify(['E2E-preamble.md'])
    && (ex.md || '').startsWith('Read this first.\n\n# 1 '), ex)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `workspace-doc-preamble: ${failed} FAILED` : `workspace-doc-preamble: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
