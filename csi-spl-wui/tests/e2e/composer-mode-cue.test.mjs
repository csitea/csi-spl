// HUM-24 (CLE-77879, csitea topic 49fd65d9, 2026-10-01): "writing in the
// message box should be clearly distinguishable per situation; creating a new
// topic must look different from writing a reply in the chat".
//
// Every composer mode now shows its own cue - a label, an accent on the
// reply arrow, a placeholder and GO words of its own - and ONE ordinary
// border in every mode (owner, t1 76b356b2: "double bordering ... Remove the
// lilac one"):
//
//   desktop 1440x900, /channel/alerts (dark and light):
//     NO chip and no text anywhere outside the box (owner, t1 7d777e79: first
//     "reply : <<the title>> is a bug", then at 14:24Z "some kind of reply
//     button there in the wrong place" - the one-word "Reply" chip)
//     1 the list: data-mode new, one plain border, GO "Start topic",
//       placeholder "Message #alerts - ..." (unchanged), one line in the bar
//     2 click a card (its thread opens): data-mode thread, the same border, GO
//       "Send reply", placeholder "Reply - ..."
//     3 close the thread: back to 1
//     4 /dm/CLE-07@box-a: data-mode dm, GO "Start topic"
//     5 /lobby, `e` on an own message: "Editing this message" over the box,
//       the composer's chip unchanged
//   phone 390x844 (touch), /channel/alerts:
//     6 NO text line above the dock (owner, t1 dd98f8d7): mode new, placeholder
//       "#alerts" (085 T002) with NO hash glyph in front of it (HUM-10: a
//       glyph plus that placeholder reads "# #alerts"); tap a card -> mode
//       thread, the tree glyph, placeholder "Reply…"
//     CONTROL: before HUM-24 the desktop had no data-mode and one GO label
//     (1-4 fail), the edit box had no label (5 fails).
//
// Run:
//   pnpm run test:e2e composer-mode-cue
//   BASE_URL=<generated bundle> pnpm run test:e2e composer-mode-cue   # what CI does
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
    /* any leftover mode chip anywhere on the page */
    const chip = [...document.querySelectorAll('[data-test=composer-mode], .composer-mode')].find(vis)
    const line = [...f.querySelectorAll('[data-test=dock-target]')].find(vis)
    const field = f.querySelector('.omnibox-field')
    const go = f.querySelector('[data-testid=send]')
    const cs = field ? getComputedStyle(field) : null
    return {
      mode: f.getAttribute('data-mode'),
      chip: chip ? chip.textContent.trim() : null,
      line: line ? line.textContent.trim() : null,
      edge: cs ? cs.borderInlineStartColor : '',
      edgeW: cs ? cs.borderInlineStartWidth : '',
      /* one border: every side the same width and colour (no mode edge/ring) */
      single: cs ? (cs.borderInlineStartWidth === cs.borderTopWidth && cs.borderInlineStartColor === cs.borderTopColor && cs.borderTopWidth === '1px') : false,
      fieldH: field ? Math.round(field.getBoundingClientRect().height) : 0,
      /* owner, t1 3d6d945d: the reply arrow is gone; any leftover counts */
      mark: (() => {
        const m = [...f.querySelectorAll('[data-test=composer-reply-mark]')].find(vis)
        if (!m || !field) return null
        const a = m.getBoundingClientRect()
        const b = field.getBoundingClientRect()
        return { text: m.textContent.trim(), markGap: Math.round(b.left - a.right), w: Math.round(a.width) }
      })(),
      /* owner, t1 3d6d945d "A": the glyph in the box. dy = glyph centre - the
         first text line's centre; clear = text start - glyph end (>= 0) */
      glyph: (() => {
        const g = [...f.querySelectorAll('[data-test=composer-mode-glyph]')].find(vis)
        const ta = f.querySelector('textarea')
        if (!g || !ta || !field) return null
        const a = g.getBoundingClientRect()
        const t = ta.getBoundingClientRect()
        const ts = getComputedStyle(ta)
        const lh = parseFloat(ts.lineHeight) || parseFloat(ts.fontSize) * 1.5
        const lineMid = t.top + parseFloat(ts.paddingTop) + lh / 2
        const textStart = t.left + parseFloat(ts.paddingLeft)
        const fb = field.getBoundingClientRect()
        return {
          kind: g.getAttribute('data-glyph'),
          name: g.getAttribute('aria-label') || '',
          role: g.getAttribute('role'),
          color: getComputedStyle(g).color,
          dy: Math.round(a.top + a.height / 2 - lineMid),
          clear: Math.round(textStart - a.right),
          inBox: a.left >= fb.left && a.right <= fb.right && a.top >= fb.top && a.bottom <= fb.bottom,
          w: Math.round(a.width),
        }
      })(),
      /* the dock's own padding around the box (phone): form edge -> field border */
      gap: (() => {
        if (!field || f.getAttribute('data-docked') !== 'true') return null
        const a = f.getBoundingClientRect()
        const b = field.getBoundingClientRect()
        return { top: Math.round(b.top - a.top), left: Math.round(b.left - a.left) }
      })(),
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
  ok(`${tag} 1 the list: no chip anywhere, no reply arrow, the form is mode new`,
    Boolean(c1 && c1.mode === 'new' && c1.chip === null && c1.line === null && c1.mark === null), c1)
  ok(`${tag} 1 GO says "Start topic", the placeholder is the old "Message #alerts", ONE plain 1px border (no lilac edge)`,
    Boolean(c1 && c1.go === 'Start topic' && c1.placeholder.startsWith('Message #alerts') && c1.single), c1)
  /* a long chip squeezed the placeholder in the first cut (4.8.7) */
  ok(`${tag} 1 option A: "#" inside the box at its start, named "New topic in #alerts", centred on the text line, the text clear of it`,
    Boolean(c1 && c1.glyph && c1.glyph.kind === 'hash' && c1.glyph.role === 'img' && c1.glyph.name === 'New topic in #alerts' && c1.glyph.inBox && Math.abs(c1.glyph.dy) <= 3 && c1.glyph.clear >= 2 && c1.glyph.w === 16), c1 && c1.glyph)
  ok(`${tag} 1 the field stays one line in the bar (<= 50 px)`,
    Boolean(c1 && c1.fieldH > 0 && c1.fieldH <= 50), { fieldH: c1 && c1.fieldH })

  const card = await firstCard(p)
  await p.mouse.click(card.x, card.y)
  await waitMode(p, 'thread')
  await sleep(300)
  const c2 = await cue(p)
  await shot(p, `reply-1440-${theme}`)
  ok(`${tag} 2 a thread open: no chip, no text, no arrow (owner t1 3d6d945d: "remove this arrow")`,
    Boolean(c2 && c2.mode === 'thread' && c2.chip === null && c2.line === null && c2.mark === null), c2)
  ok(`${tag} 2 option A: the tree (upside-down F) inside the box, named "Replying in the open thread", in the reply colour, not the "#" colour`,
    Boolean(c2 && c2.glyph && c2.glyph.kind === 'thread-tree' && c2.glyph.name === 'Replying in the open thread' && c2.glyph.inBox && Math.abs(c2.glyph.dy) <= 3 && c2.glyph.clear >= 2 && c1.glyph && c2.glyph.color !== c1.glyph.color), { new: c1 && c1.glyph, reply: c2 && c2.glyph })
  ok(`${tag} 2 GO says "Send reply", the placeholder says reply`, Boolean(c2 && c2.go === 'Send reply' && c2.placeholder.startsWith('Reply')), c2)
  ok(`${tag} 2 the reply box has the very same single border as a new topic`, Boolean(c1 && c2 && c2.single && c1.edge === c2.edge), { new: c1 && c1.edge, reply: c2 && c2.edge })

  await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-test=topic-pane-close],[data-test=live-topic-close]')].find((el) => el.getClientRects().length > 0)
    b && b.click()
  })
  await waitMode(p, 'new')
  const c3 = await cue(p)
  ok(`${tag} 3 the thread closed: back to a new topic, the "#" again`, Boolean(c3 && c3.mode === 'new' && c3.chip === null && c3.glyph && c3.glyph.kind === 'hash'), c3)
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

async function dmCase(browser) {
  const { p, errors } = await open(browser, { width: 1440, height: 900 }, '/dm/CLE-07%40box-a')
  await waitMode(p, 'dm')
  const c = await cue(p)
  await shot(p, 'dm-1440-dark')
  ok('1440 4 a DM: no chip, mode dm, GO "Start topic"',
    Boolean(c && c.mode === 'dm' && c.chip === null && c.go === 'Start topic'), c)
  ok('1440 4 a DM: no glyph in the box (not a channel topic, not a thread)', Boolean(c && c.glyph === null), c && c.glyph)
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
    return { label: label ? label.textContent.trim() : null, single: cs ? (cs.borderInlineStartWidth === cs.borderTopWidth && cs.borderInlineStartColor === cs.borderTopColor) : false }
  }, OWN_MSG)
  await shot(p, 'edit-1440-dark')
  ok('1440 5 `e` on an own message: "Editing this message" over the box, which keeps ONE border',
    focused && shown && seen.label === 'Editing this message' && seen.single, { focused, shown, ...seen })
  ok('1440 5 no page error', errors.length === 0, errors)
  await p.close()
}

async function phoneCase(browser) {
  const { p, errors } = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '/channel/alerts')
  const card = await firstCard(p)
  await waitMode(p, 'new')
  const c1 = await cue(p)
  await shot(p, 'new-390-dark')
  ok('390 6 no text line above the dock, no chip, no arrow: mode new, ONE plain border, placeholder "#alerts" (085 T002)',
    Boolean(c1 && c1.mode === 'new' && c1.line === null && c1.chip === null && c1.mark === null && c1.single && c1.placeholder === '#alerts'), c1)
  /* HUM-10: the phone placeholder is already "#name". A hash glyph in front
     of it is a leading "#" plus the field's start gap, which draws
     "# #name". shown is that composition. CONTROL: put the hash glyph back
     on the phone dock and shown becomes "# #alerts" — this check goes red. */
  const shown = (c1 && c1.glyph && c1.glyph.kind === 'hash' ? '# ' : '') + (c1 ? c1.placeholder : '')
  ok('390 6 HUM-10: the channel is exactly "#alerts", no leading hash glyph and no space',
    Boolean(c1 && c1.glyph === null && shown === '#alerts' && !/^#\s+#/.test(shown)), { placeholder: c1 && c1.placeholder, glyph: c1 && c1.glyph, shown })
  /* owner, t1 be8fed75: "no more than 2 mm after the omnibox border" (~8 px) */
  ok('390 6 the dock leaves at most 8 px between its edge and the box border, above and at the side',
    Boolean(c1 && c1.gap && c1.gap.top <= 8 && c1.gap.left <= 8), c1 && c1.gap)
  await p.touchscreen.tap(card.x, card.y)
  await waitMode(p, 'thread')
  await sleep(300)
  const c2 = await cue(p)
  await shot(p, 'reply-390-dark')
  ok('390 6 a thread open: still no line, no arrow, the same single border, placeholder "Reply", GO "Send reply"',
    Boolean(c2 && c2.mode === 'thread' && c2.line === null && c2.mark === null && c2.placeholder.startsWith('Reply') && c2.single && c2.edge === c1.edge && c2.go === 'Send reply'), c2)
  ok('390 6 option A: the tree inside the dock box in a thread, named "Replying in the open thread"',
    Boolean(c2 && c2.glyph && c2.glyph.kind === 'thread-tree' && c2.glyph.name === 'Replying in the open thread' && c2.glyph.inBox && Math.abs(c2.glyph.dy) <= 3 && c2.glyph.clear >= 2), c2 && c2.glyph)
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
