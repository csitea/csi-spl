// SPL-1873 (owner HUM-10, t1 1a9a14b6 msg 32d5ea87: "enable drag and drop
// aka re-order of files within folders in the qto file explorer"): a row of
// the Qto tree drags onto the gap between two rows of its kind, a line marks
// where it lands, and the order is the hub's (nodes/{node}/move with before /
// after), so it survives a reload. Onto a folder row it goes into the folder.
// Escape cancels; Alt+Up / Alt+Down move the focused row within its folder.
// On a phone a long press opens the menu and a drag after it moves the row;
// a long press alone still only opens the menu.
// Control: before it the rows have no drag, so no drop line shows and every
// order check FAILS.
// SPL-1892 (owner t1 089630f7 msg fcf24997): a document's section rows drag
// the same way within that document: between two sections (a re-order) or
// onto a section (its child); the open document shows the new order and
// numbers; another document refuses it; a stale rev (412) reads the document
// again and says so. Control: before it section rows have no drag.
//
//   node tests/e2e/qto-tree-reorder.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/qto-tree-reorder.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
/* the desktop side panel's tree, or the phone's list (the page's own) */
const DESK = '#qto-file-tree [data-test=qto-file-tree]'
const LIST = '[data-test=ws-docs-page] [data-test=qto-file-tree]'
/** the names of the rows at one aria-level, in order */
const level = (p, tree, n) => p.$$eval(`${tree} [data-test=file-tree-row][aria-level="${n}"]`, (els) => els.map((el) => el.textContent.trim())).catch(() => [])
const levelIs = (p, tree, n, want) => p.waitForFunction((sel, want) => [...document.querySelectorAll(sel)].map((el) => el.textContent.trim()).join('|') === want.join('|'),
  { timeout: STEP }, `${tree} [data-test=file-tree-row][aria-level="${n}"]`, want).then(() => true, () => false)
/** a point on the row named name: x into the row, y at frac of its height */
const at = (p, tree, name, frac = 0.5) => p.evaluate((sel, name, frac) => {
  const el = [...document.querySelectorAll(sel)].find((e) => e.textContent.trim() === name)
  if (!el) return null
  const r = el.getBoundingClientRect()
  return { x: r.left + 60, y: r.top + r.height * frac }
}, `${tree} [data-test=file-tree-row]`, name, frac)
/** the row a drop would land on now, and where: "Name:before" */
const dropShown = (p, tree) => p.$eval(`${tree} [data-drop]`, (el) => `${el.textContent.trim()}:${el.getAttribute('data-drop')}`).catch(() => '')

/** a new document through the page's + and its modal */
async function newDoc(p, title) {
  await p.click('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', title)
  await p.click('[data-test=ws-docs-create]')
  return p.waitForFunction((t) => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent.trim() === t, { timeout: STEP }, title).then(() => true, () => false)
}

/** a folder at the top level from the `/` row's menu */
async function newFolder(p, name) {
  const b = await at(p, DESK, '/')
  await p.mouse.click(b.x, b.y, { button: 'right' })
  await p.waitForSelector('[data-testid=qto-root-menu-new_folder]', { visible: true, timeout: STEP })
  await p.click('[data-testid=qto-root-menu-new_folder]')
  const input = await p.waitForSelector('[data-test=qto-new-folder-name]', { visible: true, timeout: STEP })
  await input.type(name)
  await p.click('[data-test=qto-new-folder-create]')
  await p.waitForFunction(() => !document.querySelector('[data-test=qto-new-folder-form]'), { timeout: STEP }).catch(() => null)
}

/** a mouse drag of the row named from to frac of the row named to; release = false holds it there */
async function mouseDrag(p, from, to, frac, release = true) {
  const a = await at(p, DESK, from)
  const b = await at(p, DESK, to, frac)
  if (!a || !b) return false
  await p.mouse.move(a.x, a.y)
  await p.mouse.down()
  await p.mouse.move(b.x, b.y, { steps: 12 })
  if (release) await p.mouse.up()
  return true
}

const shot = async (p, name) => { if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/${name}.png` }) }

/** the open document's sections as the right pane shows them: "1 Introduction|1.1 Scope|..." */
const DOC_ROWS = '[data-test=ws-doc-view] [data-test=ws-doc-row]'
const docIs = (p, want) => p.waitForFunction((sel, want) => [...document.querySelectorAll(sel)]
  .map((el) => `${el.querySelector('[data-test=ws-doc-num]')?.textContent.trim()} ${el.querySelector('[data-test=ws-doc-title]')?.value}`).join('|') === want.join('|'),
{ timeout: STEP }, DOC_ROWS, want).then(() => true, () => false)
const docRows = (p) => p.$$eval(DOC_ROWS, (els) => els.map((el) => `${el.querySelector('[data-test=ws-doc-num]')?.textContent.trim()} ${el.querySelector('[data-test=ws-doc-title]')?.value}`)).catch(() => [])
const SEED = ['1 Introduction', '1.1 Scope', '1.1.1 In scope', '1.1.2 Out of scope', '1.2 Audience', '2 Operations', '2.1 Deploy', '3 Glossary']

/** SPL-1892: the sections of one document, in a fresh tab (the mock's seed again) */
async function sections() {
  console.log('-- 1280x800 sections within one document')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${DESK} [data-kind=section]`, { visible: true, timeout: STEP }).catch(() => null)
  ok('start: the seed document, its sections in the tree and the page', await levelIs(p, DESK, 3, ['Introduction', 'Operations', 'Glossary']) && await docIs(p, SEED), [await level(p, DESK, 3), await docRows(p)])

  await mouseDrag(p, 'Glossary', 'Introduction', 0.15, false)
  ok('a section over the top of a sibling marks the gap before it', await dropShown(p, DESK) === 'Introduction:before', await dropShown(p, DESK))
  await shot(p, 'qto-sections-1280-drag')
  await p.mouse.up()
  ok('the drop re-orders the sections in the tree', await levelIs(p, DESK, 3, ['Glossary', 'Introduction', 'Operations']), await level(p, DESK, 3))
  ok('... and the open document shows the new order and numbers, no reload', await docIs(p, ['1 Glossary', '2 Introduction', '2.1 Scope', '2.1.1 In scope', '2.1.2 Out of scope', '2.2 Audience', '3 Operations', '3.1 Deploy']), await docRows(p))
  await shot(p, 'qto-sections-1280-dropped')

  await mouseDrag(p, 'Glossary', 'Operations', 0.5, false)
  ok('the middle of a section row marks the section itself', await dropShown(p, DESK) === 'Operations:into', await dropShown(p, DESK))
  await p.mouse.up()
  ok('the drop makes it the section\'s last child, opened', await levelIs(p, DESK, 3, ['Introduction', 'Operations']) && await levelIs(p, DESK, 4, ['Deploy', 'Glossary']), [await level(p, DESK, 3), await level(p, DESK, 4)])
  const RE_PARENTED = ['1 Introduction', '1.1 Scope', '1.1.1 In scope', '1.1.2 Out of scope', '1.2 Audience', '2 Operations', '2.1 Deploy', '2.2 Glossary']
  ok('... the open document too', await docIs(p, RE_PARENTED), await docRows(p))

  const glossary = await p.$$eval(`${DESK} [data-test=file-tree-row]`, (els) => els.find((el) => el.textContent.trim() === 'Glossary')?.getAttribute('data-key')).catch(() => '')
  await p.focus(`${DESK} [data-key="${glossary}"]`)
  await p.keyboard.down('Alt')
  await p.keyboard.press('ArrowUp')
  await p.keyboard.up('Alt')
  ok('Alt+Up moves a section before its previous sibling', await levelIs(p, DESK, 4, ['Glossary', 'Deploy']) && await docIs(p, [...RE_PARENTED.slice(0, 6), '2.1 Glossary', '2.2 Deploy']), await level(p, DESK, 4))
  await p.keyboard.down('Alt')
  await p.keyboard.press('ArrowDown')
  await p.keyboard.up('Alt')
  ok('Alt+Down moves it back', await levelIs(p, DESK, 4, ['Deploy', 'Glossary']) && await docIs(p, RE_PARENTED), await level(p, DESK, 4))

  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${DESK} [data-kind=section]`, { visible: true, timeout: STEP }).catch(() => null)
  ok('the order survives a reload', await levelIs(p, DESK, 3, ['Introduction', 'Operations']) && await docIs(p, RE_PARENTED), await docRows(p))

  await p.evaluate((sel) => [...document.querySelectorAll(sel)].find((el) => el.textContent.trim() === 'Introduction')?.querySelector('[data-test=file-tree-toggle]')?.click(), `${DESK} [data-test=file-tree-row]`)
  await levelIs(p, DESK, 4, ['Scope', 'Audience', 'Deploy', 'Glossary'])
  await mouseDrag(p, 'Introduction', 'Scope', 0.5, false)
  ok('CONTROL: a section over its own subsection shows no drop', await dropShown(p, DESK) === '', await dropShown(p, DESK))
  await p.keyboard.press('Escape')
  await p.mouse.up()

  await p.evaluate(() => window.__wsDocTreeBump())
  await mouseDrag(p, 'Operations', 'Introduction', 0.15)
  ok('a stale rev (412): nothing is overwritten, the tree says so', await p.waitForFunction(() => document.querySelector('[data-test=qto-tree-status]')?.textContent.trim().length > 0, { timeout: STEP }).then(() => true, () => false)
    && await levelIs(p, DESK, 3, ['Introduction', 'Operations']) && await docIs(p, RE_PARENTED), [await p.$eval('[data-test=qto-tree-status]', (el) => el.textContent.trim()).catch(() => ''), await level(p, DESK, 3)])
  await mouseDrag(p, 'Operations', 'Introduction', 0.15)
  ok('... the document was read again: the next drop lands', await levelIs(p, DESK, 3, ['Operations', 'Introduction'])
    && await docIs(p, ['1 Operations', '1.1 Deploy', '1.2 Glossary', '2 Introduction', '2.1 Scope', '2.1.1 In scope', '2.1.2 Out of scope', '2.2 Audience']), await docRows(p))

  await newDoc(p, 'Gamma')
  await mouseDrag(p, 'Audience', 'Gamma', 0.5, false)
  const other = await dropShown(p, DESK)
  const root = await at(p, DESK, '/')
  await p.mouse.move(root.x, root.y, { steps: 8 })
  ok('CONTROL: a section over another document or `/` shows no drop', other === '' && await dropShown(p, DESK) === '', other)
  await p.mouse.up()
  await sleep(300)
  const handbook = await p.$$eval(`${DESK} [data-test=file-tree-row]`, (els) => els.find((el) => el.textContent.trim() === 'Handbook')?.getAttribute('data-key')).catch(() => '')
  ok('... and the release moves nothing', await p.$$eval(`${DESK} [data-test=file-tree-row]`, (els, k) => {
    const i = els.findIndex((el) => el.getAttribute('data-key') === k)
    return els.slice(i + 1).filter((el) => el.getAttribute('aria-level') === '3').map((el) => el.textContent.trim()).slice(0, 2).join('|')
  }, handbook).catch(() => '') === 'Operations|Introduction', handbook)

  console.log('-- 390x844 sections on the phone')
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  const doc = await p.evaluate((k) => k?.slice(2), handbook)
  await p.goto(server.base + '/workspace/docs?in=d:' + doc, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('390: the document\'s level lists its sections', await levelIs(p, LIST, 1, ['Operations', 'Introduction']), await level(p, LIST, 1))
  const a = await at(p, LIST, 'Introduction')
  const b = await at(p, LIST, 'Operations', 0.15)
  await p.touchscreen.touchStart(a.x, a.y)
  await sleep(800)
  await p.touchscreen.touchMove(a.x, a.y - 15)
  await p.touchscreen.touchMove(b.x, b.y)
  const lit = await dropShown(p, LIST)
  await shot(p, 'qto-sections-390-drag')
  await p.touchscreen.touchEnd()
  ok('390: a long press, then a drag re-orders the sections', lit === 'Operations:before' && await levelIs(p, LIST, 1, ['Introduction', 'Operations']), { lit, rows: await level(p, LIST, 1) })
  await shot(p, 'qto-sections-390-dropped')
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1280x800 the desktop tree')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${DESK} [data-kind=doc]`, { visible: true, timeout: STEP }).catch(() => null)
  await newDoc(p, 'Alpha')
  await newDoc(p, 'Beta')
  await newFolder(p, 'Plans')
  ok('start: folders first, then the documents in the order made', await levelIs(p, DESK, 2, ['Plans', 'Handbook', 'Alpha', 'Beta']), await level(p, DESK, 2))
  ok('CONTROL: the rows that move are marked, `/` is not', await p.$eval(`${DESK} [data-key="/"]`, (el) => el.classList.contains('ftree__row--drag')) === false)

  await mouseDrag(p, 'Beta', 'Handbook', 0.15, false)
  ok('a drag over the top of a row marks the gap before it', await dropShown(p, DESK) === 'Handbook:before', await dropShown(p, DESK))
  ok('... the dragged row is dimmed', await p.$eval(`${DESK} .ftree__row--drag`, (el) => el.textContent.trim()).catch(() => '') === 'Beta')
  await shot(p, 'qto-reorder-1280-drag')
  await p.mouse.up()
  ok('the drop re-orders: Beta before Handbook', await levelIs(p, DESK, 2, ['Plans', 'Beta', 'Handbook', 'Alpha']), await level(p, DESK, 2))
  await shot(p, 'qto-reorder-1280-dropped')

  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${DESK} [data-kind=doc]`, { visible: true, timeout: STEP }).catch(() => null)
  ok('the order survives a reload', await levelIs(p, DESK, 2, ['Plans', 'Beta', 'Handbook', 'Alpha']), await level(p, DESK, 2))

  await mouseDrag(p, 'Alpha', 'Beta', 0.15, false)
  const lit = await dropShown(p, DESK)
  await p.keyboard.press('Escape')
  ok('Escape during a drag clears the drop line', lit === 'Beta:before' && await dropShown(p, DESK) === '', lit)
  await p.mouse.up()
  await sleep(300)
  ok('... and the release moves nothing', await levelIs(p, DESK, 2, ['Plans', 'Beta', 'Handbook', 'Alpha']), await level(p, DESK, 2))

  await mouseDrag(p, 'Alpha', 'Plans', 0.15, false)
  ok('CONTROL: a document over the gap before a folder shows no line (folders stay first)', await dropShown(p, DESK) !== 'Plans:before', await dropShown(p, DESK))
  await p.keyboard.press('Escape')
  await p.mouse.up()

  const alpha = await p.$$eval(`${DESK} [data-test=file-tree-row]`, (els) => els.find((el) => el.textContent.trim() === 'Alpha')?.getAttribute('data-key')).catch(() => '')
  await p.focus(`${DESK} [data-key="${alpha}"]`)
  await p.keyboard.down('Alt')
  await p.keyboard.press('ArrowUp')
  await p.keyboard.up('Alt')
  ok('Alt+Up moves the focused row before its previous sibling', await levelIs(p, DESK, 2, ['Plans', 'Beta', 'Alpha', 'Handbook']), await level(p, DESK, 2))
  await p.keyboard.down('Alt')
  await p.keyboard.press('ArrowDown')
  await p.keyboard.up('Alt')
  ok('Alt+Down moves it back after its next sibling', await levelIs(p, DESK, 2, ['Plans', 'Beta', 'Handbook', 'Alpha']), await level(p, DESK, 2))

  await mouseDrag(p, 'Handbook', 'Plans', 0.5, false)
  ok('the middle of a folder row marks the folder itself', await dropShown(p, DESK) === 'Plans:into', await dropShown(p, DESK))
  await p.mouse.up()
  const inPlans = () => p.$$eval(`${DESK} [data-test=file-tree-row]`, (els) => {
    const i = els.findIndex((el) => el.textContent.trim() === 'Plans')
    return i < 0 ? '' : `${els[i].getAttribute('aria-expanded')} ${els[i + 1]?.getAttribute('aria-level')} ${els[i + 1]?.textContent.trim()}`
  }).catch(() => '')
  ok('the drop moves the document into the folder, opened', await levelIs(p, DESK, 2, ['Plans', 'Beta', 'Alpha'])
    && await p.waitForFunction((sel) => {
      const els = [...document.querySelectorAll(sel)]
      const i = els.findIndex((el) => el.textContent.trim() === 'Plans')
      return i >= 0 && els[i].getAttribute('aria-expanded') === 'true' && els[i + 1]?.getAttribute('aria-level') === '3' && els[i + 1]?.textContent.trim() === 'Handbook'
    }, { timeout: STEP }, `${DESK} [data-test=file-tree-row]`).then(() => true, () => false), [await level(p, DESK, 2), await inPlans()])

  console.log('-- 390x844 the phone list, same tab (the mock keeps the tab\'s state)')
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('390: the list keeps the order', await levelIs(p, LIST, 2, ['Plans', 'Beta', 'Alpha']), await level(p, LIST, 2))
  const a = await at(p, LIST, 'Alpha')
  const b = await at(p, LIST, 'Beta', 0.15)
  await p.touchscreen.touchStart(a.x, a.y)
  await sleep(800)
  const menu = await p.$('[data-testid=qto-doc-menu]').then(Boolean)
  await p.touchscreen.touchMove(a.x, a.y - 15)
  await p.touchscreen.touchMove(b.x, b.y)
  const phoneLit = await dropShown(p, LIST)
  await shot(p, 'qto-reorder-390-drag')
  await p.touchscreen.touchEnd()
  ok('390: a long press opens the menu, a drag after it closes it and marks the gap', menu && phoneLit === 'Beta:before' && !(await p.$('[data-testid=qto-doc-menu]')), { menu, phoneLit })
  ok('390: ... the drop re-orders', await levelIs(p, LIST, 2, ['Plans', 'Alpha', 'Beta']), await level(p, LIST, 2))
  await shot(p, 'qto-reorder-390-dropped')
  const c = await at(p, LIST, 'Beta')
  await p.touchscreen.touchStart(c.x, c.y)
  await sleep(800)
  await p.touchscreen.touchEnd()
  ok('390: CONTROL: a long press alone opens the menu and moves nothing', await p.waitForSelector('[data-testid=qto-doc-menu]', { visible: true, timeout: STEP }).then(Boolean, () => false)
    && await levelIs(p, LIST, 2, ['Plans', 'Alpha', 'Beta']), await level(p, LIST, 2))
  await p.close()
  await sections()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-tree-reorder: ${failed} FAILED` : `qto-tree-reorder: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
