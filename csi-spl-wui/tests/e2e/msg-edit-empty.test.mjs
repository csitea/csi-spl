// SPL-5057 (HUM-24, topic 4d98c1cf): a sent message edited down to no text
// left the box with no way out. "the field stays empty and can be neither
// deleted nor closed". The hub stays strict (empty_body), so the way out is
// the browser's: a visible Cancel that keeps the original text, and a Save on
// an empty box that asks to delete the message. Nothing is deleted unasked.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e msg-edit-empty
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { setPageViewport, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* a reply of HUM-1: a plain message (is_parent 0), so its delete is the message confirm */
const OWNER_TOPIC = '11111111-1111-4111-8111-111111111111'
const REPLY = '13131313-1313-4313-8313-131313131313'
const ORIGINAL = 'a reply line, about to be emptied'
const REPLY_ROW = {
  v: 1, msg_id: REPLY, task_id: REPLY, ts: '2026-10-06T10:06:00Z',
  from: 'HUM-1', from_box: 'box-wui', to: '@channel', to_box: 'box-wui',
  kind: 'note', body: ORIGINAL, channel: 'lobby',
  parent_task_id: OWNER_TOPIC, is_parent: 0, files: [],
}
const MOCK_SESSION = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }
const ROW = `article.msg[data-msg-id="${REPLY}"]`
const BOX = `${ROW} [data-test=msg-edit-box]`
const CANCEL = `${ROW} [data-test=msg-edit-cancel]`
const SAVE = `${ROW} [data-test=msg-edit-save]`
const DIALOG = '[data-testid=msg-delete-confirm]'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function until(read, want, ms = 5000) {
  const t0 = Date.now()
  let v = await read()
  while (!want(v) && Date.now() - t0 < ms) {
    await sleep(100)
    v = await read()
  }
  return v
}

async function launch() {
  const require = createRequire(import.meta.url)
  const mod = await import(pathToFileURL(process.env.PUPPETEER_CORE || require.resolve('puppeteer-core')).href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

const read = (p) => p.evaluate((ROW, BOX, CANCEL, SAVE, DIALOG) => {
  const box = document.querySelector(BOX)
  const body = document.querySelector(`${ROW} .msg-body`)
  const error = document.querySelector(`${ROW} [data-test=msg-edit-error]`)
  return {
    row: Boolean(document.querySelector(ROW)),
    editing: Boolean(box),
    value: box ? box.value : null,
    body: body ? body.textContent.trim() : '',
    error: error ? error.textContent.trim() : '',
    cancel: Boolean(document.querySelector(CANCEL)),
    save: Boolean(document.querySelector(SAVE)),
    dialog: Boolean(document.querySelector(DIALOG)),
  }
}, ROW, BOX, CANCEL, SAVE, DIALOG)

/** Open the editor on the reply and take all its text out, as a person would. */
async function openAndEmpty(p) {
  await p.evaluate((ROW) => document.querySelector(ROW)?.focus(), ROW)
  await p.keyboard.press('e')
  await p.waitForSelector(BOX, { timeout: 5000 })
  await p.focus(BOX)
  await p.keyboard.down('Control')
  await p.keyboard.press('a')
  await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  return until(() => read(p), (s) => s.value === '')
}

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await setPageViewport(page, { name: 'desktop 1280x800', width: 1280, height: 800 })
  await page.evaluateOnNewDocument((row, s) => {
    try {
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([row]))
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
    } catch { /* about:blank */ }
  }, REPLY_ROW, MOCK_SESSION)
  await page.goto(`${srv.base}/t/${OWNER_TOPIC}`, { waitUntil: 'networkidle2' })
  await page.waitForSelector(ROW, { timeout: NAV_TIMEOUT })

  /* ---- 1. Escape on an emptied box ------------------------------------ */
  let s = await openAndEmpty(page)
  ok('the box is open and empty', s.editing && s.value === '', s)
  await page.keyboard.press('Escape')
  s = await until(() => read(page), (v) => !v.editing)
  ok('Escape closes an emptied box', !s.editing, s)
  ok('Escape keeps the original text', s.body.includes(ORIGINAL), { body: s.body })

  /* ---- 2. a visible Cancel, the way out without a keyboard ------------ */
  s = await openAndEmpty(page)
  ok('an emptied box shows a Cancel button', s.cancel, s)
  if (s.cancel) {
    await page.click(CANCEL)
    s = await until(() => read(page), (v) => !v.editing)
    ok('Cancel closes the box', !s.editing, s)
    ok('Cancel keeps the original text', s.body.includes(ORIGINAL), { body: s.body })
  }
  if ((await read(page)).editing) await page.keyboard.press('Escape')

  /* ---- 3. Save on an empty box asks; declining changes nothing -------- */
  s = await openAndEmpty(page)
  ok('an emptied box shows a Save button', s.save, s)
  await page.keyboard.press('Enter')
  s = await until(() => read(page), (v) => v.dialog, 2000)
  ok('Enter on an empty box asks to delete', s.dialog, s)
  ok('nothing is deleted before the answer', s.row, s)
  if (s.dialog) {
    await page.keyboard.press('Escape')
    s = await until(() => read(page), (v) => !v.dialog)
    ok('declining leaves the row', s.row && !s.dialog, s)
    ok('declining leaves the editor open to carry on', s.editing, s)

    /* ---- 4. confirming deletes it, and only then -------------------- */
    await page.focus(BOX)
    await page.keyboard.press('Enter')
    await until(() => read(page), (v) => v.dialog)
    await page.click(DIALOG)
    s = await until(() => read(page), (v) => !v.row)
    ok('confirming deletes the message', !s.row, s)
  }
} catch (e) {
  ok('the proof ran to the end', false, String(e).slice(0, 300))
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length || !results.length ? 1 : 0)
