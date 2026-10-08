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
//       placeholder "Message #alerts - ..." (unchanged), one line in the bar,
//       NO hash glyph in front of it (HUM-10: a glyph plus "#alerts" reads
//       "# #alerts" on the desktop the same way it did on the phone)
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
//   t1 3558e416, /channel/alerts (dark and light): `foobar` and an unclosed
//     ``` look like code while typing (codeCase), and once posted
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
      /* the chip after a typed line: "#alerts", never a second hash */
      targetChip: (() => {
        const el = [...f.querySelectorAll('[data-test=composer-target-chip]')].find(vis)
        return el ? el.textContent.trim() : null
      })(),
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
  /* HUM-10: the placeholder already contains "#alerts". A hash glyph in
     front of it is a leading "#" plus the field's start gap. CONTROL: return
     'hash' for an undocked new topic and shown becomes "# Message #alerts". */
  const shown1 = (c1 && c1.glyph && c1.glyph.kind === 'hash' ? '# ' : '') + (c1 ? c1.placeholder : '')
  ok(`${tag} 1 HUM-10: no hash glyph before "#alerts"; the channel hash appears once`,
    Boolean(c1 && c1.glyph === null && c1.placeholder.startsWith('Message #alerts') && (c1.placeholder.match(/#/g) || []).length === 1 && !/^#\s+/.test(shown1)),
    { placeholder: c1 && c1.placeholder, glyph: c1 && c1.glyph, shown: shown1 })
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
  ok(`${tag} 2 option A: the tree (upside-down F) inside the box, named "Replying in the open thread"`,
    Boolean(c2 && c2.glyph && c2.glyph.kind === 'thread-tree' && c2.glyph.name === 'Replying in the open thread' && c2.glyph.inBox && Math.abs(c2.glyph.dy) <= 3 && c2.glyph.clear >= 2), { reply: c2 && c2.glyph })
  ok(`${tag} 2 GO says "Send reply", the placeholder says reply`, Boolean(c2 && c2.go === 'Send reply' && c2.placeholder.startsWith('Reply')), c2)
  ok(`${tag} 2 the reply box has the very same single border as a new topic`, Boolean(c1 && c2 && c2.single && c1.edge === c2.edge), { new: c1 && c1.edge, reply: c2 && c2.edge })

  await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-test=topic-pane-close],[data-test=live-topic-close]')].find((el) => el.getClientRects().length > 0)
    b && b.click()
  })
  await waitMode(p, 'new')
  const c3 = await cue(p)
  ok(`${tag} 3 the thread closed: back to a new topic, still no hash glyph`, Boolean(c3 && c3.mode === 'new' && c3.chip === null && c3.glyph === null), c3)
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

/** HUM-10 at the widths the owner named. A new topic shows "#alerts"
 *  once. CONTROL: today's master still returns the hash glyph on the desktop
 *  (1280), so the empty box reads "# Message #alerts" and a typed line reads
 *  "# #alerts". Both checks go red there. 390 already dropped the glyph. */
async function newTopicOnce(browser, width, height, mobile) {
  const tag = String(width)
  const { p, errors } = await open(
    browser,
    mobile ? { width, height, isMobile: true, hasTouch: true } : { width, height },
    '/channel/alerts',
  )
  await firstCard(p)
  await waitMode(p, 'new')
  const empty = await cue(p)
  await shot(p, `hash-empty-${width}`)
  const emptyShown = (empty && empty.glyph && empty.glyph.kind === 'hash' ? '# ' : '') + (empty ? empty.placeholder : '')
  const hashes = empty && empty.placeholder ? (empty.placeholder.match(/#/g) || []).length : 0
  ok(`${tag} HUM-10 empty: "#alerts" once, no hash glyph in front of it`,
    Boolean(empty && empty.mode === 'new' && empty.glyph === null && empty.placeholder.includes('#alerts') && hashes === 1 && !/^#\s+/.test(emptyShown)),
    { placeholder: empty && empty.placeholder, glyph: empty && empty.glyph, shown: emptyShown, hashes })
  const box = await p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    const ta = f && f.querySelector('textarea')
    if (!ta) return null
    const r = ta.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(48, r.width / 2)), y: Math.round(r.top + r.height / 2) }
  })
  if (mobile) await p.touchscreen.tap(box.x, box.y)
  else await p.mouse.click(box.x, box.y)
  await p.keyboard.type('hello')
  await sleep(300)
  const typed = await cue(p)
  await shot(p, `hash-once-${width}`)
  const chipShown = (typed && typed.glyph && typed.glyph.kind === 'hash' ? '# ' : '') + (typed && typed.targetChip ? typed.targetChip : '')
  /* 085 AC3 (owner msg b2e7c197): the phone dock draws no target chip at all */
  if (mobile) {
    ok(`${tag} HUM-10 typed: no hash glyph and no target chip on the phone (085 AC3)`,
      Boolean(typed && typed.mode === 'new' && typed.glyph === null && typed.targetChip === null),
      { chip: typed && typed.targetChip, glyph: typed && typed.glyph })
  } else {
    ok(`${tag} HUM-10 typed: the target is exactly "#alerts", no hash glyph and no space before it`,
      Boolean(typed && typed.mode === 'new' && typed.glyph === null && typed.targetChip === '#alerts' && chipShown === '#alerts' && !/^#\s+#/.test(chipShown)),
      { chip: typed && typed.targetChip, glyph: typed && typed.glyph, shown: chipShown })
  }
  ok(`${tag} HUM-10 no page error`, errors.length === 0, errors)
  await p.close()
}

/** t1 3558e416 (owner HUM-10): code looks like code - in the composer WHILE
 *  TYPING, then in the posted body.
 *  - `foobar` typed: a mark (ComposerCodeMarks) sits exactly over the span,
 *    a box the plain text does not have
 *  - ``` + two lines, no closer typed: ONE block mark over all of it at once;
 *    GO posts it as ONE code block (the composer adds the closer)
 *  - the posted `foobar`: mono, its own tint, its own box and edge, unlike
 *    the paragraph around it
 *  CONTROL: before the fix there is no mark (the composer checks fail) and
 *  the posted span had the paragraph's colour and no edge (the last check). */
async function codeCase(browser, theme) {
  const tag = `1440 ${theme} code`
  const { p, errors } = await open(browser, { width: 1440, height: 900 }, '/channel/alerts', theme)
  await firstCard(p)
  await waitMode(p, 'new')
  const TA = 'form.composer.omnibox--global textarea'
  const clear = async () => {
    await p.focus(TA)
    await p.keyboard.down('Control'); await p.keyboard.press('a'); await p.keyboard.up('Control')
    await p.keyboard.press('Backspace')
  }
  const marks = () => p.evaluate((sel) => {
    const ta = [...document.querySelectorAll(sel)].find((el) => el.getClientRects().length > 0)
    const ts = getComputedStyle(ta)
    const ctx = document.createElement('canvas').getContext('2d')
    ctx.font = `${ts.fontStyle} ${ts.fontWeight} ${ts.fontSize} ${ts.fontFamily}`
    const r = ta.getBoundingClientRect()
    const x0 = r.left + parseFloat(ts.borderLeftWidth) + parseFloat(ts.paddingLeft)
    return {
      value: ta.value,
      inCode: ta.classList.contains('in-code'),
      taBg: ts.backgroundColor,
      lineH: parseFloat(ts.lineHeight) || parseFloat(ts.fontSize) * 1.4,
      /* where the textarea draws "see " ends, by its own font */
      expectLeft: x0 + ctx.measureText('see ').width,
      expectW: ctx.measureText('`foobar`').width,
      marks: [...document.querySelectorAll('[data-test=composer-code-mark]')].map((m) => {
        const cs = getComputedStyle(m)
        const rs = [...m.getClientRects()]
        const b = m.getBoundingClientRect()
        return { kind: m.dataset.kind, text: m.textContent, bg: cs.backgroundColor, ring: cs.boxShadow, left: rs[0] ? rs[0].left : 0, w: rs[0] ? rs[0].width : 0, h: b.height }
      }),
    }
  }, TA)

  await clear()
  await p.keyboard.type('see `foobar` here')
  await p.waitForSelector('[data-test=composer-code-mark]', { timeout: 15000 }).catch(() => null)
  const a = await marks()
  await shot(p, `code-inline-composer-${theme}`)
  const m = a.marks[0]
  ok(`${tag} composer: \`foobar\` gets ONE inline mark while typing`,
    Boolean(a.marks.length === 1 && m.kind === 'inline' && m.text === '`foobar`'), a)
  ok(`${tag} composer: the mark lies over the typed span (<= 2 px off)`,
    Boolean(m && Math.abs(m.left - a.expectLeft) <= 2 && Math.abs(m.w - a.expectW) <= 2), { left: m && m.left, expect: a.expectLeft, w: m && m.w, expectW: a.expectW })
  ok(`${tag} composer: the mark has a box the plain text has not (fill + edge)`,
    Boolean(m && m.bg !== 'rgba(0, 0, 0, 0)' && m.bg !== a.taBg && m.ring !== 'none'), { bg: m && m.bg, ta: a.taBg, ring: m && m.ring })

  await clear()
  await p.keyboard.type('```line one')
  await p.keyboard.down('Shift'); await p.keyboard.press('Enter'); await p.keyboard.up('Shift')
  await p.keyboard.type('line two')
  await sleep(300)
  const b = await marks()
  await shot(p, `code-block-composer-${theme}`)
  const blk = b.marks[0]
  ok(`${tag} composer: \`\`\` + two lines, no closer: ONE block mark over both lines at once`,
    Boolean(b.marks.length === 1 && blk.kind === 'block' && blk.text === '```line one\nline two' && blk.h >= 1.5 * b.lineH && b.inCode), b)

  const before = await p.evaluate(() => document.querySelectorAll('.spool-main .msg-body .code-block').length)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  let posted = null
  for (let i = 0; i < 40 && !posted; i++) {
    await sleep(250)
    posted = await p.evaluate((n) => {
      const bs = [...document.querySelectorAll('.spool-main .msg-body')].filter((x) => x.textContent.includes('line one'))
      const all = document.querySelectorAll('.spool-main .msg-body .code-block').length
      if (!bs.length || all <= n) return null
      const body = bs[bs.length - 1]
      return { blocks: body.querySelectorAll('.code-block').length, code: (body.querySelector('.code-block pre') || {}).textContent || '', ticks: body.textContent.includes('```') }
    }, before)
  }
  ok(`${tag} posted: the unclosed block sends as ONE code block, no stray fence`,
    Boolean(posted && posted.blocks === 1 && posted.code.includes('line one') && posted.code.includes('line two') && !posted.ticks), posted)

  await clear()
  await p.keyboard.type('for example this one "`foobar`" , plain words')
  await p.click('form.composer.omnibox--global [data-testid=send]')
  let look = null
  for (let i = 0; i < 40 && !look; i++) {
    await sleep(250)
    look = await p.evaluate(() => {
      const bodies = [...document.querySelectorAll('.spool-main .msg-body')].filter((x) => x.textContent.includes('plain words'))
      const code = bodies.length ? bodies[bodies.length - 1].querySelector('code') : null
      if (!code) return null
      const c = getComputedStyle(code)
      const q = getComputedStyle(code.parentElement)
      return { tag: code.tagName, font: c.fontFamily, pFont: q.fontFamily, color: c.color, pColor: q.color, bg: c.backgroundColor, edge: c.borderTopWidth, edgeColor: c.borderTopColor, size: c.fontSize }
    })
  }
  await shot(p, `code-inline-posted-${theme}`)
  ok(`${tag} posted: \`foobar\` is mono on a fill, unlike its paragraph`,
    Boolean(look && look.font !== look.pFont && /mono/i.test(look.font) && look.bg !== 'rgba(0, 0, 0, 0)'), look)
  ok(`${tag} posted: \`foobar\` has its own tint and a 1px edge (CONTROL: the old look had neither)`,
    Boolean(look && look.color !== look.pColor && look.edge === '1px'), look)
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 }, '/channel/alerts')).p.close()
  await newTopicOnce(browser, 1280, 800, false)
  await newTopicOnce(browser, 390, 844, true)
  await desktopCase(browser, 'dark')
  await desktopCase(browser, 'light')
  await dmCase(browser)
  await editCase(browser)
  await phoneCase(browser)
  await codeCase(browser, 'dark')
  await codeCase(browser, 'light')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
