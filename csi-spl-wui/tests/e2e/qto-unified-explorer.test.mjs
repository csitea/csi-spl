// Spec 137 T023 (§4.1, owner HUM-10 t1 bed3ed0a msg 0e9d17b5: "combine the 2
// sections .. so that there will be one spool-hub file system"): the Qto
// explorer is one tree over both: the workspace's documents, then one
// Repository row holding the repository's docs (the /docs tree.json) as
// folders and files. A repo file opens in the explorer's right pane, a
// relative .md link in it opens the linked doc there too, a workspace row
// opens the Qto document again, and the Repository branch can be walked with
// the same keys. A fresh load of ?repo=<path> opens the branch down to it.
//
// SPL-1857 (owner HUM-10, t1 6b980c46 msg 4f8d5e43): the bar between the
// explorer and the content drags "the same ways as the panel for the
// channels, or the issues": the shared pane divider, the channel sidebar's
// clamp (180 px .. 35 % of the window), the width kept on this device over a
// reload. At 390 px the phone keeps its one pane: no tree column, no bar.
// Control: before it the tree is a fixed 260 px with no divider, so every
// drag check FAILS.
//
//   node tests/e2e/qto-unified-explorer.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/qto-unified-explorer.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const STEP = 15000
const TREE = '#qto-file-tree [data-test=qto-file-tree]'
const FEATURE = 'csi-spl-doc/doc/md/csi-spl.feature.md'
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

/** the tree's rows as "<level> <name>" */
const rowKeys = (p) => p.$$eval(`${TREE} [data-test=file-tree-row]`, (els) => els.map((el) => `${el.getAttribute('aria-level')} ${el.textContent.trim()}`)).catch(() => [])
/** the row named name, by its data-key prefix kind */
const rowSel = (key) => `${TREE} [data-test=file-tree-row][data-key="${key}"]`
const hasRow = (p, key) => p.waitForSelector(rowSel(key), { visible: true, timeout: STEP }).then(Boolean, () => false)
const repoPane = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-test=ws-repo-doc]')
  if (!el || el.getBoundingClientRect().width === 0) return null
  return { path: el.getAttribute('data-path'), state: el.getAttribute('data-state'), h1: el.querySelector('h1')?.textContent?.trim() ?? null, h1id: el.querySelector('h1')?.id ?? null }
})
const paneIs = (p, path) => p.waitForFunction((path) => {
  const el = document.querySelector('[data-test=ws-repo-doc]')
  return el && el.getAttribute('data-path') === path && el.querySelector('[data-testid=md-block][data-rendered=true] h1')
}, { timeout: STEP }, path).then(() => true, () => false)
const DIVIDER = '[data-test=ws-docs-layout] [data-testid=pane-divider-sidebar]'
const treeW = (p) => p.$eval('#qto-file-tree', (el) => Math.round(el.getBoundingClientRect().width)).catch(() => 0)
/** a mouse drag of the tree's divider by dx px, as issues.test.mjs drags the sidebar's */
async function drag(p, dx) {
  const box = await p.$eval(DIVIDER, (el) => {
    const b = el.getBoundingClientRect()
    return { x: b.x + b.width / 2, y: b.y + Math.min(220, b.height / 2) }
  }).catch(() => null)
  if (!box) return
  await p.mouse.move(box.x, box.y)
  await p.mouse.down()
  await p.mouse.move(box.x + dx, box.y, { steps: 10 })
  await p.mouse.up()
}
const qtoShown = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-test=ws-docs-page]')
  return Boolean(el && el.getBoundingClientRect().width > 0)
})

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1280x800 one explorer, two trees')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: STEP }).catch(() => null)
  await p.waitForSelector(`${TREE} [data-kind=doc]`, { visible: true, timeout: STEP }).catch(() => null)
  const first = await rowKeys(p)
  ok('the workspace documents come first, then one Repository row, closed', first[0] === '1 Handbook' && first.at(-1) === '1 Repository'
    && await p.$eval(rowSel('r:'), (el) => el.getAttribute('aria-expanded')).catch(() => null) === 'false', first)
  ok('CONTROL: the Qto document shows, no repo pane', await qtoShown(p) && !(await repoPane(p)))

  await p.click(rowSel('r:'))
  ok('Repository opens to the repo tree: its folders, then its files', await hasRow(p, 'rd:csi-spl-doc') && await hasRow(p, 'rf:README.md'), await rowKeys(p))
  const keys = await rowKeys(p)
  ok('... one level under it, in the same tree', keys.includes('2 csi-spl-doc') && keys.includes('2 README.md'), keys)

  await p.click(rowSel('rf:README.md'))
  const readme = await paneIs(p, 'README.md')
  ok('a repo file opens in the right pane, rendered, with its heading anchor', readme && JSON.stringify(await repoPane(p)) === JSON.stringify({ path: 'README.md', state: 'ready', h1: 'Spool', h1id: 'md-spool' }), await repoPane(p))
  ok('... the Qto page is hidden, the URL names it (?repo=)', !(await qtoShown(p)) && new URL(p.url()).searchParams.get('repo') === 'README.md', p.url())
  ok('... and its row is the active one', await p.$eval(`${TREE} [aria-selected=true]`, (el) => el.getAttribute('data-key')).catch(() => '') === 'rf:README.md')

  await p.click('[data-test=ws-repo-doc] a[href*="csi-spl.feature.md"]').catch(() => null)
  ok('a relative .md link opens the linked repo doc in the same pane', await paneIs(p, FEATURE) && new URL(p.url()).pathname === '/workspace/docs', p.url())
  ok('... and the tree opens down to it, marked', await hasRow(p, 'rf:' + FEATURE)
    && await p.$eval(`${TREE} [aria-selected=true]`, (el) => el.getAttribute('data-key')).catch(() => '') === 'rf:' + FEATURE, await rowKeys(p))
  ok('Open in Docs points at the doc on /docs', await p.$eval('[data-test=ws-repo-open-docs]', (a) => new URL(a.href).pathname).catch(() => '') === '/docs/' + FEATURE)

  await p.click(`${TREE} [data-kind=doc]`)
  await p.waitForFunction(() => !new URL(location.href).searchParams.has('repo'), { timeout: STEP }).catch(() => null)
  await p.waitForSelector('[data-test=ws-doc-view]', { visible: true, timeout: STEP }).catch(() => null)
  ok('a workspace document row opens the Qto document again', await qtoShown(p) && !(await repoPane(p)) && !new URL(p.url()).searchParams.has('repo'), p.url())
  ok('... its row is the active one again', await p.$eval(`${TREE} [aria-selected=true]`, (el) => el.getAttribute('data-kind')).catch(() => '') === 'doc')

  /* the keys walk across both: from the Repository row, Down then Enter opens the first repo row */
  await p.focus(rowSel('r:'))
  await p.keyboard.press('ArrowLeft')
  await p.waitForFunction((sel) => document.querySelector(sel)?.getAttribute('aria-expanded') === 'false', { timeout: STEP }, rowSel('r:')).catch(() => null)
  ok('Left closes the Repository branch', !(await p.$(rowSel('rf:README.md'))))
  await p.keyboard.press('ArrowRight')
  await hasRow(p, 'rd:csi-spl-doc')
  await p.keyboard.press('End')
  await p.keyboard.press('Enter')
  ok('Right opens it again; End + Enter opens its last file', await paneIs(p, 'README.md'), await repoPane(p))
  await p.close()

  console.log('-- 1280x800 a fresh load of ?repo=')
  const f = await browser.newPage()
  await f.setViewport({ width: 1280, height: 800 })
  await f.goto(server.base + '/workspace/docs?repo=' + FEATURE, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('the pane shows the doc', await paneIs(f, FEATURE), await repoPane(f))
  ok('the branch is open down to it, the row marked', await hasRow(f, 'rf:' + FEATURE)
    && await f.$eval(`${TREE} [aria-selected=true]`, (el) => el.getAttribute('data-key')).catch(() => '') === 'rf:' + FEATURE, await rowKeys(f))
  if (process.env.SHOT_DIR) await f.screenshot({ path: `${process.env.SHOT_DIR}/qto-unified-explorer.png` })
  await f.goto(server.base + '/workspace/docs?repo=no/such.md', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('CONTROL: a path tree.json does not have says so', await f.waitForSelector('[data-test=ws-repo-missing]', { visible: true, timeout: STEP }).then(Boolean, () => false))
  await f.close()

  /* SPL-1857 (owner HUM-10, t1 6b980c46 msg 4f8d5e43): the tree | doc bar
     drags like the channel and issue panes: the same PaneDivider, the same
     clamp as the channel sidebar, the width kept on this device. */
  console.log('-- 1440x900 the tree | doc divider')
  const d = await browser.newPage()
  await d.setViewport({ width: 1440, height: 900 })
  await d.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await d.evaluate(() => localStorage.removeItem('spool.pane-widths'))
  await d.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await d.waitForSelector(`${TREE} [data-kind=doc]`, { visible: true, timeout: STEP }).catch(() => null)
  const bar = await d.waitForSelector(DIVIDER, { visible: true, timeout: STEP }).catch(() => null)
  const w0 = await treeW(d)
  ok('a drag bar sits between the tree and the doc, the shared pane divider', Boolean(bar) && await d.$eval(DIVIDER, (el) => {
    const t = document.querySelector('#qto-file-tree').getBoundingClientRect()
    const b = el.getBoundingClientRect()
    return el.classList.contains('pane-divider') && Math.abs(b.left - t.right) <= 1 && getComputedStyle(el).cursor === 'col-resize'
  }).catch(() => false), w0)
  if (process.env.SHOT_DIR) await d.screenshot({ path: `${process.env.SHOT_DIR}/qto-divider-1440-before.png` })
  await drag(d, 80)
  const w1 = await treeW(d)
  ok('dragging it right widens the tree', w1 >= w0 + 60, { w0, w1 })
  if (process.env.SHOT_DIR) await d.screenshot({ path: `${process.env.SHOT_DIR}/qto-divider-1440-after.png` })
  await d.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await d.waitForSelector(DIVIDER, { visible: true, timeout: STEP }).catch(() => null)
  const w2 = await treeW(d)
  ok('... the width survives a reload (kept on this device)', Math.abs(w2 - w1) <= 1, { w1, w2 })
  const range = await d.$eval(DIVIDER, (el) => ({ min: Number(el.getAttribute('aria-valuemin')), max: Number(el.getAttribute('aria-valuemax')) })).catch(() => ({}))
  await drag(d, -1000)
  const wMin = await treeW(d)
  ok('... clamped at the channel sidebar min', range.min === 180 && Math.abs(wMin - range.min) <= 1, { range, wMin })
  await drag(d, 2000)
  const wMax = await treeW(d)
  ok('... clamped at the channel sidebar max (35 % of the window)', range.max === Math.round(1440 * 0.35) && Math.abs(wMax - range.max) <= 1, { range, wMax })
  await d.focus(DIVIDER).catch(() => null)
  await d.keyboard.press('Home')
  ok('... the keys move it too (Home = min)', Math.abs(await treeW(d) - range.min) <= 1, await treeW(d))
  await d.$eval(DIVIDER, (el) => el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true }))).catch(() => null)
  ok('... a double click resets it to the default', Math.abs(await treeW(d) - 260) <= 1, await treeW(d))
  await drag(d, 80)
  await d.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await d.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await d.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: STEP }).catch(() => null)
  if (process.env.SHOT_DIR) await d.screenshot({ path: `${process.env.SHOT_DIR}/qto-divider-390.png` })
  ok('390: the phone keeps its one pane: no tree column, no drag bar', await d.evaluate((sel) => {
    const shown = (el) => Boolean(el) && el.getBoundingClientRect().width > 0 && getComputedStyle(el).display !== 'none'
    return !shown(document.querySelector('#qto-file-tree')) && !shown(document.querySelector(sel)) && shown(document.querySelector('[data-test=ws-docs-page]'))
  }, DIVIDER))
  await d.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-unified-explorer: ${failed} FAILED` : `qto-unified-explorer: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
