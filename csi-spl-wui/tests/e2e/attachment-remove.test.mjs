// SPL-1560 (owner HUM-10, t1 d74ecae5): "some kind of X that appears either
// on the left side or on the right side to actually remove the attachment
// from the system" - "The position of the X should be decided based on the
// user settings: Mac or Windows, left or right side."
//
// In a real browser on the mock tenant, 1440 px, once per close_buttons value:
//   M1/W1 a picture pasted into an issue comment shows a file card with ONE X,
//         on the left with Mac (the default) and on the right with Windows
//   M2/W2 the X asks first (the destructive confirm), and Remove takes the
//         file off the comment card
//   D1    (Windows) a file in the issue description has the X too; Remove
//         takes the card and its link out of the description
//   CONTROL: on the build before this change no file card has an X, so every
//   M, W and D check fails.
//
// Run:
//   node tests/e2e/attachment-remove.test.mjs
//   BASE_URL=<generated bundle> OUT=/tmp/shots node tests/e2e/attachment-remove.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const COMMENT = '[data-test=issues-comment]'
const INPUT = '[data-test=issues-comment-input]'
const DESC = '[data-test=issues-detail-body]'
const DESC_VIEW = '[data-test=issues-detail-rendered]'
const X = '[data-testid=file-remove]'
/* a real 1x1 PNG: the card previews it only when the magic bytes say picture */
const PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true, defaultViewport: { width: 1440, height: 900 }, args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Ctrl+V of a clipboard that holds one file, on the element `sel`. */
const pasteFile = (p, sel, name) => p.evaluate((sel, name, b64) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.focus()
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
  const dt = new DataTransfer()
  dt.items.add(new File([bytes], name, { type: 'image/png' }))
  return !el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
}, sel, name, PNG_B64)

/* the issues page, signed in as the mock owner with this close_buttons value */
async function openIssues(p, base, mode) {
  await p.goto(base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((mode) => localStorage.setItem('spool.mock.session', JSON.stringify({
    hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', close_buttons: mode,
  })), mode)
  await p.goto(base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  await sleep(400)
}

async function createIssue(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 8000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  const key = await p.waitForFunction((want) => {
    const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
    return r ? r.getAttribute('data-key') : false
  }, { timeout: 8000 }, title).then((h) => h.jsonValue())
  await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  await p.waitForSelector(INPUT, { timeout: 8000 })
  await sleep(400)
}

/* where the X of the file card named `name` (inside `scope`) sits */
const xGeometry = (p, scope, name) => p.waitForFunction((scope, name, X) => {
  const card = [...document.querySelectorAll(`${scope} .file-card`)].find((c) => c.innerText.includes(name))
  const xs = card ? [...card.querySelectorAll(X)] : []
  if (xs.length !== 1) return false
  const c = card.getBoundingClientRect()
  const x = xs[0].getBoundingClientRect()
  return { side: xs[0].getAttribute('data-close-side'), left: Math.round(x.left - c.left), right: Math.round(c.right - x.right), w: Math.round(x.width) }
}, { timeout: 15000 }, scope, name, X).then((h) => h.jsonValue()).catch(() => null)

async function removeVia(p, scope, name) {
  await p.evaluate((scope, name, X) => {
    const card = [...document.querySelectorAll(`${scope} .file-card`)].find((c) => c.innerText.includes(name))
    card?.querySelector(X)?.click()
  }, scope, name, X)
  const asked = await p.waitForSelector('[data-testid=file-remove-confirm]', { visible: true, timeout: 5000 }).then(() => true).catch(() => false)
  if (OUT) await p.screenshot({ path: `${OUT}/attachment-remove-confirm.png` }).catch(() => {})
  if (asked) await p.click('[data-testid=file-remove-confirm]')
  const gone = await p.waitForFunction((scope, name) => ![...document.querySelectorAll(`${scope} .file-card`)].some((c) => c.innerText.includes(name)),
    { timeout: 8000 }, scope, name).then(() => true).catch(() => false)
  return { asked, gone }
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))

  for (const [tag, mode, want] of [['M', 'mac', 'start'], ['W', 'windows', 'end']]) {
    await openIssues(p, server.base, mode)
    await createIssue(p, `Attachment X ${mode} ${Date.now()}`)
    const shot = `x-${mode}-${Date.now()}.png`
    await pasteFile(p, INPUT, shot)
    await p.waitForFunction((n) => [...document.querySelectorAll('[data-test=issues-comment-file]')].some((c) => c.textContent.includes(n)),
      { timeout: 5000 }, shot).catch(() => {})
    await p.focus(INPUT).catch(() => {})
    await p.keyboard.press('Enter')
    const g = await xGeometry(p, COMMENT, shot)
    const onSide = !!g && g.side === want && (want === 'start' ? g.left < g.right : g.right < g.left)
    ok(`${tag}1 ${mode}: one X on the ${want === 'start' ? 'left' : 'right'} of the comment's file card`, onSide, g)
    if (OUT) await p.screenshot({ path: `${OUT}/attachment-x-${mode}.png` }).catch(() => {})
    const r = g ? await removeVia(p, COMMENT, shot) : { asked: false, gone: false }
    ok(`${tag}2 ${mode}: the X asks first, and Remove takes the file off the comment`, r.asked && r.gone, r)

    if (mode !== 'windows') continue
    /* ---- D1: the description's file ---- */
    await p.focus(DESC_VIEW).catch(() => {})
    await p.keyboard.press('Enter')
    await p.waitForSelector(DESC, { visible: true, timeout: 5000 }).catch(() => {})
    const dshot = `desc-x-${Date.now()}.png`
    await pasteFile(p, DESC, dshot)
    await p.waitForFunction((sel, n) => (document.querySelector(sel)?.value || '').includes(`[${n}](`), { timeout: 8000 }, DESC, dshot).catch(() => {})
    await p.$eval(DESC, (el) => el.blur()).catch(() => {})
    const dg = await xGeometry(p, '[data-test=issues-desc-file]', dshot)
    ok('D1 the description\'s file card has the X on the right (Windows)', !!dg && dg.side === 'end', dg)
    const dr = dg ? await removeVia(p, '[data-test=issues-desc-file]', dshot) : { asked: false, gone: false }
    const linkGone = await p.waitForFunction((sel, n) => !(document.querySelector(sel)?.innerText || '').includes(n),
      { timeout: 8000 }, DESC_VIEW, dshot).then(() => true).catch(() => false)
    ok('D1 Remove takes the card and its link out of the description', dr.asked && dr.gone && linkGone, { ...dr, linkGone })
  }

  const realErrors = errors.filter((e) => !/dynamically imported module|Importing a module script failed/.test(e))
  ok('no page error', realErrors.length === 0, realErrors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `attachment-remove: ${results.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
