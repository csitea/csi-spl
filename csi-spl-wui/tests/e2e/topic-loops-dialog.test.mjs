// Spec 182 v0.11 (HUM-10, t1 6e8c1cdb; SPL-6580..6589, 6592, 6593): the
// Discussion loops dialog after the owner's changes, in Chrome on the mock.
//
//   1  1440 px: the dialog is 70% of the viewport wide and its top is 10%
//      down the screen (changes 5, msg ac0a7377)
//   2  Add loop: the triggers are ONE radio group, none picked; each pick is
//      the form's title at once, with its parameter, and only one stays
//      checked (changes 1 and 3, msgs 543a5bde, a04bba37, febf1db4)
//   2b "Every day at" is a 24-hour HH:MM text field (change 10, e4cb57a6)
//   2c the file trigger is two radios, an agent post and a human post with
//      files (change 9, msg d8e02722)
//   3  the prompt is left and Run it right (change 11, msg 534340d9); the
//      prompt box is about 17% of the screen high and still resizable
//      (change 7, msg ae3a2d5c)
//   4  saved: the row's first line is the title, the prompt's line under it
//      (change 2, msgs 7f3ebb17, 9e3161d9); its Edit, Pause and Delete are
//      icon buttons, the label on hover and on aria-label (change 6, 1822fb67)
//   5  the header drags the dialog, and a drag past the edge keeps it on
//      screen (change 4, msg e68509d5)
//   7  no text in the form or the list is smaller than the omnibox's
//      (change 12, --omnibox-fs)
//   8  three saved loops reorder: Arrow Down on a focused grip moves its
//      row one place and keeps the focus; a pointer drag of a grip moves a
//      row; a new open shows the stored order (change 8, SPL-6587)
//   6  a 390 px window: no break (desktop only, msg 5c03fa45): full width,
//      no page x-scroll, the radios are there
//
// Run:
//   node tests/e2e/topic-loops-dialog.test.mjs
//   BASE_URL=<generated bundle> OUT=<dir> node tests/e2e/topic-loops-dialog.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const CH = 'spl-6580-loops'
if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const near = (a, b, tol = 2) => Math.abs(a - b) <= tol

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const DLG = '[data-testid=ui-dialog]'

/** Signed in as HUM-1 on a workspace whose archive setting lets everyone set loops. */
async function signIn(p, path) {
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', 'everyone')
    localStorage.setItem('spool.mock.role', 'developer')
  })
  await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(800)
}

/** A channel with one own topic card; its msg id. */
const seed = (p) => p.evaluate(async ({ CH }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH)
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send('SPL-6580 a topic with loops', undefined, undefined, undefined, 1)
  return one.msg_id
}, { CH })

/** The card's ⋯ menu, then Discussion loops…; true once the dialog is up. */
async function openLoops(p, msgId) {
  for (let i = 0; i < 3; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), midCard(msgId))
    await sleep(300)
    await p.evaluate(() => document.querySelector('[data-testid=msg-menu-topic-loops]')?.click())
    try {
      await p.waitForSelector('[data-testid=topic-loops-add]:not([disabled])', { timeout: 5000 })
      return true
    } catch { /* the menu was not up yet */ }
  }
  return false
}

const rect = (p, sel) => p.evaluate((sel) => {
  const r = document.querySelector(sel)?.getBoundingClientRect()
  return r ? { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height } : null
}, sel)
const text = (p, sel) => p.evaluate((sel) => document.querySelector(sel)?.textContent?.trim() ?? null, sel)
/* the smallest font of the dialog's own text (every element with a text
   node, the list rows, labels, radios, fields and notes) against the
   omnibox's (change 12): each composer textarea on the page */
const fonts = (p) => p.evaluate((sel) => {
  const px = (e) => parseFloat(getComputedStyle(e).fontSize)
  const body = document.querySelector(sel)
  const own = [...body.querySelectorAll('*')].filter((e) => e.offsetParent && ([...e.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim()) || /^(INPUT|TEXTAREA)$/.test(e.tagName)))
  const min = own.reduce((m, e) => (px(e) < m.px ? { px: px(e), el: e.className || e.tagName } : m), { px: 99, el: '' })
  const omni = [...document.querySelectorAll('.composer textarea')].map(px)
  return { min, omni }
}, '[data-testid=topic-loops-form], [data-testid=topic-loops-list]')
const clickTrigger = (p, k) => p.evaluate((k) => document.querySelector(`[data-testid=topic-loops-trigger-${k}]`)?.click(), k)

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  /* warm a throwaway page: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  await signIn(p, '/channel/alerts')
  const card = await seed(p)
  await p.waitForSelector(midCard(card), { timeout: 10000 })
  await sleep(400)

  /* ---- 1. 70% wide, 10% from the top ------------------------------------ */
  ok('1 the dialog opens from the topic menu', await openLoops(p, card))
  await sleep(300)
  const box = await rect(p, DLG)
  ok('1 its width is 70% of the viewport', box && near(box.width, 1440 * 0.7), box)
  ok('1 its top is 10% down the viewport', box && near(box.top, 900 * 0.1), box)

  /* ---- 2. one radio group; the pick is the title ------------------------- */
  await p.click('[data-testid=topic-loops-add]')
  await p.waitForSelector('[data-testid=topic-loops-form]')
  const radios = await p.evaluate(() => [...document.querySelectorAll('[data-testid^=topic-loops-trigger-]')].map((e) => ({ id: e.dataset.testid, type: e.type, name: e.name, on: e.checked })))
  ok('2 twelve triggers, each a radio of one group, none picked', radios.length === 12 && radios.every((r) => r.type === 'radio' && r.name === radios[0].name && !r.on), radios.length)
  const fileIds = radios.map((r) => r.id).filter((id) => id.includes('post_has_file'))
  ok('2c the file trigger is two: an agent post and a human post with files (change 9)',
    fileIds.join() === 'topic-loops-trigger-post_has_file_agent,topic-loops-trigger-post_has_file_human', fileIds)
  ok('2 no title before a pick', (await text(p, '[data-testid=topic-loops-form-title]')) === null)
  await clickTrigger(p, 'before_agent_reply')
  await sleep(100)
  ok('2 a click on "Before each agent reply" is the title at once', (await text(p, '[data-testid=topic-loops-form-title]')) === 'Before each agent reply')
  await clickTrigger(p, 'every_n_minutes')
  await sleep(100)
  ok('2 every n minutes names its n', (await text(p, '[data-testid=topic-loops-form-title]')) === 'Every 30 minutes')
  await clickTrigger(p, 'post_has_keyword')
  await p.type('[data-testid=topic-loops-keyword]', 'deploy')
  await sleep(100)
  ok('2 a post that contains names its word', (await text(p, '[data-testid=topic-loops-form-title]')) === 'A post that contains “deploy”')
  const checked = await p.evaluate(() => [...document.querySelectorAll('[data-testid^=topic-loops-trigger-]')].filter((e) => e.checked).map((e) => e.value))
  ok('2 only the last pick stays checked', checked.length === 1 && checked[0] === 'post_has_keyword', checked)

  /* ---- 2b. "Every day at" is a 24-hour HH:MM field (SPL-6589) ------------ */
  await clickTrigger(p, 'daily_at')
  await sleep(100)
  const at = await p.evaluate(() => { const e = document.querySelector('[data-testid=topic-loops-daily-at]'); return e && { type: e.type, value: e.value, ph: e.placeholder } })
  ok('2b the time is a text field, 09:00 by default, HH:MM hint', at && at.type === 'text' && at.value === '09:00' && at.ph === 'HH:MM', at)
  await p.evaluate(() => { const e = document.querySelector('[data-testid=topic-loops-daily-at]'); e.focus(); e.select() })
  await p.type('[data-testid=topic-loops-daily-at]', '21:30')
  await sleep(100)
  const dt = await text(p, '[data-testid=topic-loops-form-title]')
  ok('2b 21:30 stays 21:30 in the title, no AM/PM', /^every day at 21:30\b/i.test(dt ?? '') && !/[AP]M/.test(dt ?? ''), dt)

  /* ---- 3. two columns; the prompt box size --------------------------------- */
  const prompt = await rect(p, '[data-testid=topic-loops-prompt]')
  const run = await rect(p, '.topic-loops__triggers')
  ok('3 the prompt is the left column, Run it the right', prompt && run && prompt.right <= run.left && near(prompt.top, run.top, 40), { prompt, run })
  ok('3 the prompt box is about 17% of the screen high', prompt && near(prompt.height, 900 * 0.17, 4), prompt?.height)
  const resize = await p.evaluate(() => getComputedStyle(document.querySelector('[data-testid=topic-loops-prompt]')).resize)
  ok('3 the prompt box is still resizable', resize === 'vertical', resize)
  const ff = await fonts(p)
  ok('7 the smallest form text is at least the omnibox size', ff.omni.length > 0 && ff.min.px >= Math.max(...ff.omni) - 0.01, ff)
  await shot(p, '1440-form')

  /* ---- 4. saved: the title on the row ----------------------------------- */
  await clickTrigger(p, 'before_agent_reply')
  await p.type('[data-testid=topic-loops-prompt]', 'say hello')
  await p.click('[data-testid=topic-loops-save]')
  await p.waitForSelector('[data-testid=topic-loops-row]', { timeout: 5000 })
  ok('4 the row is titled by its trigger', (await text(p, '[data-testid=topic-loops-row-title]')) === 'Before each agent reply')
  ok('4 the prompt line is under it', (await text(p, '[data-testid=topic-loops-row-prompt]')) === 'say hello')
  await shot(p, '1440-list')

  /* ---- 4b. the row's Edit / Pause / Delete are icon buttons (SPL-6585) --- */
  const btns = await p.evaluate(() => ['edit', 'pause', 'delete'].map((k) => {
    const b = document.querySelector(`[data-testid=topic-loops-${k}]`)
    return { k, icon: b?.classList.contains('icon-btn'), svg: !!b?.querySelector('svg'), text: b?.textContent.trim(), aria: b?.getAttribute('aria-label'), title: b?.title }
  }))
  ok('4b edit, pause, delete: an icon, no text, the label on aria-label and title',
    btns.every((b) => b.icon && b.svg && b.text === '' && b.aria && b.aria === b.title)
      && btns.map((b) => b.aria).join('|') === 'Edit|Pause|Delete', btns)
  const lf = await fonts(p)
  ok('7 the smallest list text is at least the omnibox size', lf.omni.length > 0 && lf.min.px >= Math.max(...lf.omni) - 0.01, lf)

  /* ---- 8. reorder the saved loops (SPL-6587) ----------------------------- */
  for (const [k, words] of [['after_human_reply', 'second'], ['blocker_posted', 'third']]) {
    await p.click('[data-testid=topic-loops-add]')
    await p.waitForSelector('[data-testid=topic-loops-form]')
    await clickTrigger(p, k)
    await p.type('[data-testid=topic-loops-prompt]', words)
    await p.click('[data-testid=topic-loops-save]')
    await p.waitForSelector('[data-testid=topic-loops-list]', { timeout: 5000 })
    await sleep(200)
  }
  const order = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=topic-loops-row-prompt]')].map((e) => e.textContent.trim()))
  ok('8 three loops, in the order they were added', (await order()).join('|') === 'say hello|second|third', await order())
  const grips = await p.evaluate(() => [...document.querySelectorAll('[data-testid=topic-loops-grip]')].map((b) => ({ dis: b.disabled, svg: !!b.querySelector('svg'), aria: b.getAttribute('aria-label') })))
  ok('8 each row has an enabled grip with an icon and a label', grips.length === 3 && grips.every((g) => !g.dis && g.svg && g.aria), grips)
  await p.focus('[data-testid=topic-loops-grip]')
  await p.keyboard.press('ArrowDown')
  await sleep(400)
  ok('8 Arrow Down on the first grip moves it one place down', (await order()).join('|') === 'second|say hello|third', await order())
  const focused = await p.evaluate(() => document.activeElement?.closest('[data-testid=topic-loops-row]')?.querySelector('[data-testid=topic-loops-row-prompt]')?.textContent.trim())
  ok('8 the keyboard stays on the moved row\'s grip', focused === 'say hello', focused)
  const rows = await p.evaluate(() => [...document.querySelectorAll('[data-testid=topic-loops-grip]')].map((b) => { const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } }))
  await p.mouse.move(rows[2].x, rows[2].y)
  await p.mouse.down()
  await p.mouse.move(rows[2].x, rows[0].y - 20, { steps: 8 })
  await p.mouse.up()
  await sleep(400)
  ok('8 dragging the last grip above the first moves that row to the top', (await order()).join('|') === 'third|second|say hello', await order())
  await p.keyboard.press('Escape')
  await sleep(300)
  await openLoops(p, card)
  await p.waitForSelector('[data-testid=topic-loops-row]', { timeout: 5000 })
  ok('8 a new open shows the stored order', (await order()).join('|') === 'third|second|say hello', await order())
  await shot(p, '1440-reordered')

  /* ---- 5. drag by the header; it stays on screen ------------------------ */
  const head = await rect(p, '[data-testid=ui-dialog-head]')
  const before = await rect(p, DLG)
  const grab = { x: head.left + head.width / 2, y: head.top + head.height / 2 }
  await p.mouse.move(grab.x, grab.y)
  await p.mouse.down()
  await p.mouse.move(grab.x - 150, grab.y + 80, { steps: 5 })
  await p.mouse.up()
  const moved = await rect(p, DLG)
  ok('5 the header drags the dialog', moved && near(moved.left, before.left - 150) && near(moved.top, before.top + 80), { before, moved })
  const head2 = await rect(p, '[data-testid=ui-dialog-head]')
  await p.mouse.move(head2.left + 40, head2.top + head2.height / 2)
  await p.mouse.down()
  await p.mouse.move(-2000, -2000, { steps: 5 })
  await p.mouse.up()
  const edge = await rect(p, DLG)
  ok('5 a drag past the corner stops at the screen edge', edge && near(edge.left, 0) && near(edge.top, 0), edge)
  await p.keyboard.press('Escape')
  await sleep(300)
  ok('5 a new open starts at its place again', (await openLoops(p, card)) && near((await rect(p, DLG)).top, 90))
  await shot(p, '1440-dialog')

  /* ---- 6. 390 px: no break ----------------------------------------------- */
  /* the open dialog in a window narrowed to 390 px: the phone layout's card
     sheet has no Discussion loops entry (msg-menu.mjs, `if (!touch)`), so
     this is the only way the dialog meets a phone width today */
  await p.setViewport({ width: 390, height: 844 })
  await sleep(500)
  const pbox = await rect(p, DLG)
  const xs = await p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)
  ok('6 390 px: the dialog is the full width, no page x-scroll', pbox && near(pbox.width, 390) && near(pbox.left, 0) && !xs, { pbox, xs })
  await p.evaluate(() => document.querySelector('[data-testid=topic-loops-add]')?.click())
  await sleep(300)
  const n = await p.evaluate(() => document.querySelectorAll('input[type=radio][data-testid^=topic-loops-trigger-]').length)
  const cols = await p.evaluate(() => getComputedStyle(document.querySelector('[data-testid=topic-loops-cols]')).gridTemplateColumns.split(' ').length)
  ok('6 390 px: the radios are there, in one column under the prompt', n === 12 && cols === 1, { n, cols })
  await shot(p, '390-form')
  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
