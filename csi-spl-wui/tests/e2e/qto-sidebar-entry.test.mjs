// Owner HUM-10 (t1 4296200d, msg ed921572): "where this qto ui can be
// accessed from". The rail carries a "Docs (Qto)" entry for a signed-in
// member, next to Docs; one click opens /workspace/docs (spec 113 T006),
// the workspace documents. A phone strip carries it too. Signed out it is
// absent while Docs stays.
// Owner HUM-10 (t1 efde25bb): on /workspace/docs the left panel is a VS
// Code-like file tree of the documents, not the channel list: the sidebar
// keeps its icon rail only; the tree's rows expand, collapse, open a
// document or a section, and answer the arrow keys. A phone folds the tree
// behind its Documents button.
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
  }
  await p.close()

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
  ok('phone: the tree is folded', !(await shown(m, '[data-test=qto-file-tree]')))
  await m.tap('[data-test=qto-file-tree-toggle]').catch(() => {})
  ok('phone: the Documents button unfolds the tree', await m.waitForFunction(() => {
    const el = document.querySelector('[data-test=qto-file-tree]')
    return Boolean(el && el.getBoundingClientRect().height > 0)
  }, { timeout: STEP }).then(() => true, () => false))
  ok('phone: a tree row is a 44 px target', await m.$eval('[data-test=file-tree-row]', (el) => el.getBoundingClientRect().height >= 44).catch(() => false))
  if (process.env.SHOT_DIR) await m.screenshot({ path: `${process.env.SHOT_DIR}/qto-file-tree-phone.png` })
  await m.close()

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
