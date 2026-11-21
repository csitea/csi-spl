// SPL-5836 (HUM-10, t1 0cd27035): while the Kind picker is open, one plain
// letter picks a kind (M message, N note, T task, B blocker, R result,
// J reject; spec 033 T025: F feature, U bug, A alert, Q question, I idea,
// D decision, O docs), and each item shows its letter on the right. With Keyboard
// shortcuts off (spec 081 FR-012) no letter shows and a letter picks nothing.
//
// Run: node tests/e2e/kind-picker-keys.test.mjs
// KIND_KEYS_SHOT=<file.png> also saves a screenshot of the open picker.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TOPIC = 'e47e0e7e-0bed-4de5-a362-b8349f3e5836'
const CARD = 'e47e0e7e-0bed-4de5-a362-b8349f3e5837'
const EXTRA = [{
  v: 1, msg_id: CARD, task_id: TOPIC, ts: '2026-12-01T10:00:00Z', from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body: 'kind picker letter keys', channel: 'alerts',
  parent_task_id: null, is_parent: 1, files: [],
}]

const results = []
const ok = (name, pass, ev) => {
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

/** Polls `fn` in the page until it is truthy (the event), capped at `ms`. */
async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await new Promise((r) => setTimeout(r, 100))
  }
  return false
}

const thread = `.topic-browse__thread article.msg[data-msg-id="${CARD}"]`
const pickerOpen = () => Boolean(document.querySelector('[data-testid="kind-picker"]')?.getClientRects().length)
const pickerShut = () => !document.querySelector('[data-testid="kind-picker"]')
const inPicker = () => Boolean(document.activeElement?.closest?.('[data-testid="kind-picker"]'))
const badgeKind = (sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') || ''
const hints = () => [...document.querySelectorAll('[data-testid="kind-picker"] .kind-picker__item')].map((el) => ({
  kind: el.getAttribute('data-kind'),
  key: el.querySelector('[data-testid="kind-picker-key"]')?.getAttribute('data-key') || '',
  shown: (() => {
    const k = el.querySelector('[data-testid="kind-picker-key"]')
    return k ? getComputedStyle(k, '::after').content : ''
  })(),
  aria: el.getAttribute('aria-keyshortcuts') || '',
}))

function setShortcuts(p, on) {
  return p.evaluate((v) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    s.claims = { ...(s.claims || {}), keyboard_shortcuts: v }
  }, on)
}

async function shiftK(p) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('K')
  await p.keyboard.up('Shift')
}

const focusCard = (p) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
  el.focus()
  return document.activeElement === el
}, thread)

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 240)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.setItem('spool.mock.role', 'admin')
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/t/${TOPIC}`, { waitUntil: 'networkidle2' })
  ok('the topic card is shown', await until(p, (sel) => Boolean(document.querySelector(sel)), thread, 15000))
  ok('its kind is note', await until(p, badgeKind, thread, 8000) && (await p.evaluate(badgeKind, thread)) === 'note')

  /* 1. Shift + K, the letters show, B picks blocker */
  ok('the card is focused', await focusCard(p))
  await shiftK(p)
  ok('Shift + K opens the picker', await until(p, pickerOpen, null, 5000))
  ok('the focus is in the picker', await until(p, inPicker, null, 3000))
  const want = [['msg', 'M'], ['note', 'N'], ['task', 'T'], ['blocker', 'B'], ['result', 'R'], ['reject', 'J'],
    ['feature', 'F'], ['bug', 'U'], ['alert', 'A'], ['question', 'Q'], ['idea', 'I'], ['decision', 'D'], ['docs', 'O']]
  const got = await p.evaluate(hints)
  ok('each item shows its letter on the right', JSON.stringify(got.map((h) => [h.kind, h.key])) === JSON.stringify(want), got)
  ok('the letter is drawn (CSS ::after), not text in the item', got.every((h) => h.shown === `"${h.key}"`), got.map((h) => h.shown))
  ok('aria-keyshortcuts names the letter', got.every((h) => h.aria === h.key), got.map((h) => h.aria))
  if (process.env.KIND_KEYS_SHOT) await p.screenshot({ path: process.env.KIND_KEYS_SHOT })
  await p.keyboard.press('b')
  ok('B closes the picker', await until(p, pickerShut, null, 4000))
  ok('B set the kind to blocker', await until(p, (sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') === 'blocker', thread, 8000), await p.evaluate(badgeKind, thread))

  /* 2. a non-letter key keeps the picker open; J picks reject */
  ok('the card is focused again', await focusCard(p))
  await shiftK(p)
  ok('Shift + K opens the picker again', await until(p, pickerOpen, null, 5000))
  await until(p, inPicker, null, 3000)
  await p.keyboard.press('x')
  ok('a letter with no kind (x) leaves the picker open', await p.evaluate(pickerOpen))
  await p.keyboard.press('j')
  ok('J closes the picker', await until(p, pickerShut, null, 4000))
  ok('J set the kind to reject', await until(p, (sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') === 'reject', thread, 8000), await p.evaluate(badgeKind, thread))

  /* 2b. spec 033 T025: U picks bug (B is blocker's), the badge draws its glyph */
  ok('the card is focused for U', await focusCard(p))
  await shiftK(p)
  ok('Shift + K opens the picker for U', await until(p, pickerOpen, null, 5000))
  await until(p, inPicker, null, 3000)
  await p.keyboard.press('u')
  ok('U closes the picker', await until(p, pickerShut, null, 4000))
  ok('U set the kind to bug', await until(p, (sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') === 'bug', thread, 8000), await p.evaluate(badgeKind, thread))
  const bugBadge = await p.evaluate((sel) => {
    const b = document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)
    const k = b?.querySelector('.kind') || b
    return { glyph: Boolean(b?.querySelector('svg path')), color: k ? getComputedStyle(k).color : '' }
  }, thread)
  ok('the bug badge draws a glyph in its own colour', bugBadge.glyph && /^rgb\(255, 138, 92\)$/.test(bugBadge.color), bugBadge)
  ok('the card is focused again for J', await focusCard(p))
  await shiftK(p)
  await until(p, pickerOpen, null, 5000)
  await until(p, inPicker, null, 3000)
  await p.keyboard.press('j')
  ok('J sets it back to reject', await until(p, (sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') === 'reject', thread, 8000), await p.evaluate(badgeKind, thread))

  /* 3. Keyboard shortcuts off: the badge opens the picker, no letter shows, N does nothing */
  await setShortcuts(p, false)
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.click(), thread)
  ok('setting off: the badge opens the picker', await until(p, pickerOpen, null, 5000))
  await until(p, inPicker, null, 3000)
  ok('setting off: no letter shows', (await p.evaluate(() => document.querySelectorAll('[data-testid="kind-picker-key"]').length)) === 0)
  ok('setting off: no aria-keyshortcuts', (await p.evaluate(() => document.querySelectorAll('[data-testid="kind-picker"] [aria-keyshortcuts]').length)) === 0)
  await p.keyboard.press('n')
  ok('setting off: N leaves the picker open', await p.evaluate(pickerOpen))
  ok('setting off: the kind stays reject', (await p.evaluate(badgeKind, thread)) === 'reject')
  await p.keyboard.press('Escape')
  ok('Esc still closes the picker', await until(p, pickerShut, null, 4000))
  await setShortcuts(p, null)

  const benign = (e) => /Failed to fetch dynamically imported module|ResizeObserver/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nkind-picker-keys: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
