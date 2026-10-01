// HUM-24 (CLE-77879, csitea topic 49fd65d9, 2026-10-01): "writing in the
// message box should be clearly distinguishable per situation; creating a new
// topic must look different from writing a reply in the chat".
//
// Every composer mode now shows its own cue - a label, an accent on the
// field's start edge, a placeholder and GO words of its own:
//
//   desktop 1440x900, /channel/alerts (dark and light):
//     1 the list: chip "New topic in #alerts", data-mode new, GO "Start topic",
//       placeholder "New topic in #alerts - ..."
//     2 click a card (its thread opens): chip "Reply in: <title>", data-mode
//       thread, GO "Send reply", a different start-edge colour than 1
//     3 close the thread: back to 1
//     4 /dm/CLE-07@box-a: chip "New topic with CLE-07@box-a", data-mode dm
//     5 /lobby, `e` on an own message: "Editing this message" over the box,
//       the composer's chip unchanged
//   phone 390x844 (touch), /channel/alerts:
//     6 the dock line says "New topic in #alerts", tap a card -> "Reply in: ..."
//     CONTROL: before HUM-24 the desktop had no chip and no data-mode (1-4
//     fail), the edit box had no label (5 fails).
//
// Run:
//   pnpm run test:e2e:composer-mode-cue
//   BASE_URL=<generated bundle> pnpm run test:e2e:composer-mode-cue   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
if (SHOTS) mkdirSync(SHOTS, { recursive: true })
/* specs/054: the mock is signed-out by default; HUM-1 authors OWN_MSG */
const MOCK_SESSION = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }
const OWN_MSG = '11111111-1111-4111-8111-111111111111'

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
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The visible composer's mode, label, accent, placeholder and GO words. */
function cue(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    if (!f) return null
    const chip = [...f.querySelectorAll('[data-test=composer-mode]')].find(vis)
    const line = [...f.querySelectorAll('[data-test=dock-target]')].find(vis)
    const field = f.querySelector('.omnibox-field')
    const go = f.querySelector('[data-testid=send]')
    const cs = field ? getComputedStyle(field) : null
    return {
      mode: f.getAttribute('data-mode'),
      chip: chip ? chip.textContent.trim() : null,
      chipMode: chip ? chip.getAttribute('data-mode') : null,
      line: line ? line.textContent.trim() : null,
      edge: cs ? cs.borderInlineStartColor : '',
      edgeW: cs ? cs.borderInlineStartWidth : '',
      fieldH: field ? Math.round(field.getBoundingClientRect().height) : 0,
      chipCut: chip ? chip.querySelector('.composer-mode__text').scrollWidth > chip.querySelector('.composer-mode__text').clientWidth : null,
      placeholder: f.querySelector('textarea')?.placeholder || '',
      go: go ? go.getAttribute('aria-label') : '',
    }
  })
}

async function open(browser, vp, path, theme = 'dark') {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((s, th) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
      localStorage.setItem('spool-theme', th)
    } catch { /* private mode */ }
  }, MOCK_SESSION, theme)
  await p.setViewport(vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return { p, errors }
}

async function firstCard(p) {
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
}

const shot = (p, name) => (SHOTS ? p.screenshot({ path: join(SHOTS, `composer-mode-${name}.png`) }) : null)
const waitMode = (p, mode) => p.waitForFunction((m) => {
  const f = [...document.querySelectorAll('form.composer.omnibox--global')].find((el) => el.getClientRects().length > 0)
  return f && f.getAttribute('data-mode') === m
}, { timeout: 15000 }, mode).then(() => true, () => false)

async function desktopCase(browser, theme) {
  const tag = `1440 ${theme}`
  const { p, errors } = await open(browser, { width: 1440, height: 900 }, '/channel/alerts', theme)
  await firstCard(p)
  await waitMode(p, 'new')
  const c1 = await cue(p)
  await shot(p, `new-1440-${theme}`)
  ok(`${tag} 1 the list: the chip says a new topic in #alerts, the form is mode new`,
    Boolean(c1 && c1.mode === 'new' && c1.chipMode === 'new' && c1.chip === 'New topic in #alerts'), c1)
  ok(`${tag} 1 GO says "Start topic", the placeholder says new topic, the start edge is 3px`,
    Boolean(c1 && c1.go === 'Start topic' && c1.placeholder.startsWith('New topic in #alerts') && c1.edgeW === '3px'), c1)
  /* the chip shrank to "New topic in #ale…" and the longer placeholder wrapped
     the field to two lines in the first cut (measured 70 px) */
  ok(`${tag} 1 the chip is not cut, the field stays one line in the bar (<= 50 px)`,
    Boolean(c1 && c1.chipCut === false && c1.fieldH > 0 && c1.fieldH <= 50), { chipCut: c1 && c1.chipCut, fieldH: c1 && c1.fieldH })

  const card = await firstCard(p)
  await p.mouse.click(card.x, card.y)
  await waitMode(p, 'thread')
  await sleep(300)
  const c2 = await cue(p)
  await shot(p, `reply-1440-${theme}`)
  ok(`${tag} 2 a thread open: the chip says "Reply in: <title>", the form is mode thread`,
    Boolean(c2 && c2.mode === 'thread' && c2.chipMode === 'thread' && /^Reply in: \S/.test(c2.chip || '')), c2)
  ok(`${tag} 2 GO says "Send reply", the placeholder says reply`, Boolean(c2 && c2.go === 'Send reply' && c2.placeholder.startsWith('Reply')), c2)
  ok(`${tag} 2 the reply accent differs from the new-topic accent`, Boolean(c1 && c2 && c1.edge && c2.edge && c1.edge !== c2.edge), { new: c1 && c1.edge, reply: c2 && c2.edge })

  await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-test=topic-pane-close],[data-test=live-topic-close]')].find((el) => el.getClientRects().length > 0)
    b && b.click()
  })
  await waitMode(p, 'new')
  const c3 = await cue(p)
  ok(`${tag} 3 the thread closed: back to a new topic`, Boolean(c3 && c3.mode === 'new' && c3.chip === 'New topic in #alerts'), c3)
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

async function dmCase(browser) {
  const { p, errors } = await open(browser, { width: 1440, height: 900 }, '/dm/CLE-07%40box-a')
  await waitMode(p, 'dm')
  const c = await cue(p)
  await shot(p, 'dm-1440-dark')
  ok('1440 4 a DM: the chip says a new topic with the peer, mode dm, GO "Start topic"',
    Boolean(c && c.mode === 'dm' && c.chip === 'New topic with CLE-07@box-a' && c.go === 'Start topic'), c)
  ok('1440 4 no page error', errors.length === 0, errors)
  await p.close()
}

async function editCase(browser) {
  const { p, errors } = await open(browser, { width: 1440, height: 900 }, '/lobby')
  await p.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"]`, { timeout: NAV_TIMEOUT })
  const focused = await p.evaluate((id) => {
    const r = document.querySelector(`article.msg[data-msg-id="${id}"]`)
    r.scrollIntoView({ block: 'center' })
    r.focus()
    return document.activeElement === r
  }, OWN_MSG)
  await p.keyboard.press('e')
  const shown = await p.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"] [data-test=msg-edit-mode]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
  const seen = await p.evaluate((id) => {
    const row = document.querySelector(`article.msg[data-msg-id="${id}"]`)
    const label = row && row.querySelector('[data-test=msg-edit-mode]')
    const box = row && row.querySelector('[data-test=msg-edit-box]')
    const cs = box ? getComputedStyle(box) : null
    return { label: label ? label.textContent.trim() : null, edgeW: cs ? cs.borderInlineStartWidth : '' }
  }, OWN_MSG)
  await shot(p, 'edit-1440-dark')
  ok('1440 5 `e` on an own message: "Editing this message" over the box, a 3px edit edge',
    focused && shown && seen.label === 'Editing this message' && seen.edgeW === '3px', { focused, shown, ...seen })
  ok('1440 5 no page error', errors.length === 0, errors)
  await p.close()
}

async function phoneCase(browser) {
  const { p, errors } = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '/channel/alerts')
  const card = await firstCard(p)
  await waitMode(p, 'new')
  const c1 = await cue(p)
  await shot(p, 'new-390-dark')
  ok('390 6 the dock line says a new topic in #alerts, mode new, no desktop chip',
    Boolean(c1 && c1.mode === 'new' && c1.line === 'New topic in #alerts' && c1.chip === null), c1)
  await p.touchscreen.tap(card.x, card.y)
  await waitMode(p, 'thread')
  await sleep(300)
  const c2 = await cue(p)
  await shot(p, 'reply-390-dark')
  ok('390 6 a thread open: the dock line says "Reply in: <title>", GO "Send reply"',
    Boolean(c2 && c2.mode === 'thread' && /^Reply in: \S/.test(c2.line || '') && c2.go === 'Send reply'), c2)
  ok('390 no page error', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 }, '/channel/alerts')).p.close()
  await desktopCase(browser, 'dark')
  await desktopCase(browser, 'light')
  await dmCase(browser)
  await editCase(browser)
  await phoneCase(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
