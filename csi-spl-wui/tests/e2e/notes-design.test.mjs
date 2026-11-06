// SPL-4893 (epic SPL-2400, spec 155): the Notes design round, on the mock bundle.
//
// Owner HUM-10, prd t1 topic ba784026 (msg 037cedef): "the priority should be
// on the right of the note title, or if the note title is too long, on the
// right on the next row". Topic 2f4311d9 (msg 65341de0, poll 1de5c599 PH): on a
// phone the list shows no P1..P5; on a computer the chip stays right of the
// title.
//
// Cases, at 1440 px and at 390 px:
//   title row, short title: the priority chooser is on the title's row, right
//     of it, its right edge at the row's right edge
//   title row, long title: the chooser wraps to the next row, still right-aligned
//   list: 1440 px the chip is right after the title (8 px), not at the far
//     edge; 390 px the chip is not drawn
//   plus: New note is the round +; 390 px it is 16..24 px above the composer's
//     go button on its right edge, and hidden while a note is open
//   editor (msgs de86531f, e6a8148b; poll 2fefe460 UP): the text box is 6
//     rows; Bold / Underline / Numbered / Bullets write **, ++, "1. ", "- "
//     into the plain text (no HTML); View draws them (strong, u, ol, ul) and
//     Wiki code shows the raw text again
//   links (msg a9f94922): an address typed in the text is a link in View
//     (the discussions' renderer)
// CONTROL: with the head row's flex-wrap / margin-inline-start: auto off, or
// the list title back to flex: 1 1 auto, the checks of titleRow() and
// listChip() FAIL; with the box back at rows 8, editor() FAILS.
//
// Run:
//   node tests/e2e/notes-design.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-design.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const LONG = 'A very long note title that does not fit on one row with its priority beside it at all'

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const waitDetail = (p, id) => p.waitForSelector(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
const waitGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).then(() => true, () => false)
const setTitle = (p, id, title) => p.evaluate((id, title) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').patch(id, { title }), id, title)

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  /* a phone's page slides in: measure once it has stopped */
  if (touch) await p.waitForFunction(() => Math.round(document.querySelector('[data-test=notes-page]').getBoundingClientRect().left) === 0, { timeout: 5000 })
  return p
}
async function closeNote(p, touch) {
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  await waitGone(p)
}

/* the title, the chooser and their row, as drawn */
const headShape = (p) => p.$eval('[data-test=note-head]', (head) => {
  const r = (e) => e.getBoundingClientRect()
  const h = r(head), t = r(head.querySelector('[data-test=note-title]')), c = r(head.querySelector('[data-test=note-priority]'))
  return {
    sameRow: c.top < t.bottom && c.bottom > t.top,
    below: c.top >= t.bottom - 1,
    rightOfTitle: c.left >= t.right,
    rightEdge: Math.round(h.right - c.right),
    fits: h.right <= window.innerWidth + 1,
  }
})

async function titleRow(browser, base, width, touch) {
  const tag = `${width}px title row`
  const p = await openPage(browser, base, width, touch)
  await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
  await waitDetail(p, 'mock-note-2')
  await sleep(300)
  const short = await headShape(p)
  check(`${tag}: a short title has the priority on its row, right of it`, short.sameRow && short.rightOfTitle, short)
  check(`${tag}: the priority is right-aligned`, short.rightEdge <= 1, short)
  await closeNote(p, touch)
  await setTitle(p, 'mock-note-2', LONG)
  await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
  await waitDetail(p, 'mock-note-2')
  await sleep(300)
  const long = await headShape(p)
  check(`${tag}: a long title pushes the priority to the next row`, long.below && !long.sameRow, long)
  check(`${tag}: still right-aligned there`, long.rightEdge <= 1, long)
  check(`${tag}: no sideways scroll`, long.fits && (await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)), long)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-title-row-long-${width}.png` })
  await p.close()
}

async function listChip(browser, base, width, touch) {
  const tag = `${width}px list chip`
  const p = await openPage(browser, base, width, touch)
  const shape = await p.$eval('[data-note-id="mock-note-2"]', (row) => {
    const t = row.querySelector('.notes-row__title').getBoundingClientRect()
    const c = row.querySelector('[data-test=notes-row-priority]')
    const cr = c.getBoundingClientRect()
    return { drawn: c.getClientRects().length > 0, gap: Math.round(cr.left - t.right), farEdge: Math.round(row.getBoundingClientRect().right - cr.right) }
  })
  if (touch) check(`${tag}: a phone shows no P1..P5`, !shape.drawn, shape)
  else check(`${tag}: the chip follows the title, 8 px after it, not at the far edge`, shape.drawn && shape.gap === 8 && shape.farEdge > 100, shape)
  await p.close()
}

/* owner t1 2f4311d9 (msgs b182efa5, 7c54e6f7): New note is the standard round
   +; on a phone it sits over the composer's go button, about 5 mm
   (16 px over the dock, ~21 px to the button) above it, on the same right edge, and it is gone
   while a note is open */
async function plusButton(browser, base, width, touch) {
  const tag = `${width}px plus`
  const p = await openPage(browser, base, width, touch)
  const shape = await p.evaluate(() => {
    const r = (e) => e && e.getBoundingClientRect()
    const fab = document.querySelector('[data-test=notes-new]')
    const go = [...document.querySelectorAll('.composer-go')].find((e) => e.getClientRects().length > 0)
    const f = r(fab), g = r(go)
    return {
      round: !!fab && getComputedStyle(fab).borderRadius === '50%' && Math.round(f.width) === Math.round(f.height),
      icon: !!fab?.querySelector('svg') && !fab.textContent.trim(),
      label: fab?.getAttribute('aria-label') || '',
      gap: go ? Math.round(g.top - f.bottom) : null,
      rightDiff: go ? Math.round(Math.abs(g.right - f.right)) : null,
    }
  })
  check(`${tag}: New note is the round + with a label, no text`, shape.round && shape.icon && shape.label.length > 0, shape)
  if (touch) {
    check(`${tag}: it sits 16..24 px above the go button`, shape.gap !== null && shape.gap >= 16 && shape.gap <= 24, shape)
    check(`${tag}: on the go button's right edge`, shape.rightDiff !== null && shape.rightDiff <= 1, shape)
    await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
    await waitDetail(p, 'mock-note-2')
    const hidden = await p.$eval('[data-test=notes-new]', (e) => e.getClientRects().length === 0)
    check(`${tag}: no + while a note is open`, hidden)
  }
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-plus-${width}.png` })
  await p.close()
}

/* SPL-4893: the note text editor, wiki marks in, formatted View out */
async function editor(browser, base, width, touch) {
  const tag = `${width}px editor`
  const p = await openPage(browser, base, width, touch)
  await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
  await waitDetail(p, 'mock-note-2')
  if ((await p.$eval('[data-test=note-editor]', (e) => e.dataset.mode)) === 'view') await p.click('[data-test=note-ed-mode]')
  await p.waitForSelector('[data-test=note-body]', { visible: true, timeout: NAV })
  check(`${tag}: the text box is 6 rows`, (await p.$eval('[data-test=note-body]', (e) => e.rows)) === 6)
  const set = (v, a, b) => p.$eval('[data-test=note-body]', (e, v, a, b) => {
    e.value = v
    e.dispatchEvent(new Event('input', { bubbles: true }))
    e.focus()
    e.setSelectionRange(a, b)
  }, v, a, b)
  const val = () => p.$eval('[data-test=note-body]', (e) => e.value)
  await set('make it bold', 8, 12)
  await p.click('[data-test=note-ed-bold]')
  check(`${tag}: Bold writes **`, (await val()) === 'make it **bold**', await val())
  await set('under', 0, 5)
  await p.click('[data-test=note-ed-underline]')
  check(`${tag}: Underline writes ++`, (await val()) === '++under++', await val())
  await set('one\ntwo', 0, 7)
  await p.click('[data-test=note-ed-number]')
  check(`${tag}: Numbered writes 1. 2.`, (await val()) === '1. one\n2. two', await val())
  await set('a\nb', 0, 3)
  await p.click('[data-test=note-ed-bullet]')
  check(`${tag}: Bullets write "- "`, (await val()) === '- a\n- b', await val())
  await set('**B** ++U++\n\n1. one\n2. two\n\n- x\n- y', 0, 0)
  check(`${tag}: the stored text has no HTML`, !/[<>]/.test(await val()))
  await p.click('[data-test=note-ed-mode]')
  await p.waitForSelector('[data-test=note-body-view]', { visible: true, timeout: NAV })
  /* View draws through MessageBody's lazy MarkdownBlock: wait for its lists */
  await p.waitForFunction(() => document.querySelectorAll('[data-test=note-body-view] .md-block ol li').length > 0, { timeout: NAV }).catch(() => {})
  const view = await p.$eval('[data-test=note-body-view]', (e) => ({
    b: e.querySelector('strong')?.textContent, u: e.querySelector('u')?.textContent,
    ol: e.querySelectorAll('ol li').length, ul: e.querySelectorAll('ul li').length,
  }))
  check(`${tag}: View draws bold, underline, numbers and bullets`, view.b === 'B' && view.u === 'U' && view.ol === 2 && view.ul === 2, view)
  await p.click('[data-test=note-ed-mode]')
  check(`${tag}: Wiki code shows the raw text`, (await val()).startsWith('**B** ++U++'))
  await set('see https://example.com/z', 0, 0)
  await p.click('[data-test=note-ed-mode]')
  await p.waitForSelector('[data-test=note-body-view]', { visible: true, timeout: NAV })
  const a = await p.waitForSelector('[data-test=note-body-view] a[href="https://example.com/z"]', { timeout: NAV }).then((e) => e.evaluate((x) => x.getAttribute('target')), () => null)
  check(`${tag}: an address typed in the text is a link in View, new tab`, a === '_blank', a)
  await p.click('[data-test=note-ed-mode]')
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notes-editor-${width}.png` })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [390, true]]) {
    await listChip(browser, server.base, w, touch)
    await titleRow(browser, server.base, w, touch)
    await plusButton(browser, server.base, w, touch)
    await editor(browser, server.base, w, touch)
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-design: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
