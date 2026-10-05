// 085 (phone composer target and search), T002, AC4: at <= 820 px the docked
// composer's placeholder is the destination only - "Message #alerts",
// "Message @<peer>", "Reply" - with no key hints.
// Spec: csi-spl-doc/specs/085-phone-composer-target-and-search/spec.md §3.2,
// FR-003; the desktop placeholder does not change (FR-008).
//
//   phone (390x844 and 360x780, touch):
//     1 /channel/alerts (level 2): placeholder "Message #alerts"
//     2 tap a card (level 3, its thread): placeholder "Reply"
//     3 /lobby: placeholder "Message #lobby"
//     4 a DM: placeholder "Message @<peer>"
//     each: the textarea's scrollWidth <= clientWidth (AC4, as the spec
//     writes it)
//     on #alerts: the phone string laid out in the field takes less than half
//     the height the desktop key-hint string takes there (the shortening is
//     real, not just a different string)
//     INFO, not asserted: whether the string is clipped by the one-line field.
//     A textarea does not scroll its placeholder sideways, so AC4 cannot see a
//     clip; measured on the first run (tree ddc59252 + this change, n = 1):
//     "Reply" fits at 390 and 360, "Message #alerts" / "#lobby" / "@<peer>"
//     are cut ("Message #a" at 360). Reported to the orchestrator (topic
//     c893c3a9) - the fix is the composer's CSS or the spec's strings.
//   desktop (1440x900): /channel/alerts keeps the key-hint placeholder.
//
// Run:
//   pnpm run test:e2e phone-composer-target
//   BASE_URL=<generated bundle> pnpm run test:e2e phone-composer-target   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const DM = '/dm/CLE-07%40box-a'
const TA = 'form.composer.omnibox--global textarea'

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

/** The docked field's placeholder and whether it fits: the AC4 scroll check,
 *  and whether the string, laid out in the field itself (same font, width and
 *  indent), stays inside the field's height - i.e. no part of it is clipped.
 *  The value is swapped in and restored with no input event, so the box does
 *  not grow to meet it. `probe` lays out another string the same way. */
function field(p, probe = '') {
  return p.evaluate((sel, extra) => {
    const ta = [...document.querySelectorAll(sel)].find((el) => el.getClientRects().length > 0)
    if (!ta) return null
    const keep = ta.value
    const shown = (s) => {
      ta.value = s
      const r = { h: ta.scrollHeight, fits: ta.scrollHeight <= ta.clientHeight + 1 }
      ta.value = keep
      return r
    }
    return {
      level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
      placeholder: ta.placeholder,
      scroll: ta.scrollWidth <= ta.clientWidth,
      height: ta.clientHeight,
      text: shown(ta.placeholder),
      probe: extra ? shown(extra) : null,
    }
  }, TA, probe)
}
const ac4 = (f) => Boolean(f && f.scroll)
const info = (name, f) => console.log(`  INFO ${name}: ${f && f.text.fits ? 'not clipped' : 'CLIPPED by the field'} ${JSON.stringify(f && f.text)}`)

async function open(browser, vp, path, wait = '.spool-shell') {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(wait, { timeout: NAV_TIMEOUT })
  await p.waitForSelector(TA, { timeout: NAV_TIMEOUT })
  await sleep(500)
  return { p, errors }
}

async function firstCard(p) {
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
}

async function phoneCase(browser, width, height) {
  const tag = `${width}px`
  const vp = { width, height, isMobile: true, hasTouch: true }
  const errors = []

  const a = await open(browser, vp, '/channel/alerts', '.spool-main article.msg[data-msg-id]')
  const desk = 'Message #alerts — Enter sends · Shift+Enter adds a line · /search to search everything'
  const f1 = await field(a.p, desk)
  if (SHOTS) await a.p.screenshot({ path: join(SHOTS, `phone-composer-target-${width}-channel.png`) })
  ok(`${tag} 1 #alerts (level 2): placeholder is "Message #alerts", AC4 scroll check`, Boolean(f1 && f1.level === '2' && f1.placeholder === 'Message #alerts' && ac4(f1)), f1)
  ok(`${tag} 1 the phone string takes < half the desktop string's height in the same field`, Boolean(f1 && f1.probe && f1.text.h * 2 < f1.probe.h), f1)
  info(`${tag} 1 #alerts`, f1)

  const card = await firstCard(a.p)
  await a.p.touchscreen.tap(card.x, card.y)
  await sleep(700)
  const f2 = await field(a.p)
  if (SHOTS) await a.p.screenshot({ path: join(SHOTS, `phone-composer-target-${width}-topic.png`) })
  ok(`${tag} 2 a topic open (level 3): placeholder is "Reply", AC4 scroll check`, Boolean(f2 && f2.level === '3' && f2.placeholder === 'Reply' && ac4(f2)), f2)
  info(`${tag} 2 Reply`, f2)
  errors.push(...a.errors)
  await a.p.close()

  const l = await open(browser, vp, '/lobby')
  const f3 = await field(l.p)
  ok(`${tag} 3 /lobby: placeholder is "Message #lobby", AC4 scroll check`, Boolean(f3 && f3.placeholder === 'Message #lobby' && ac4(f3)), f3)
  info(`${tag} 3 #lobby`, f3)
  errors.push(...l.errors)
  await l.p.close()

  const d = await open(browser, vp, DM)
  const f4 = await field(d.p)
  if (SHOTS) await d.p.screenshot({ path: join(SHOTS, `phone-composer-target-${width}-dm.png`) })
  ok(`${tag} 4 a DM: placeholder is "Message @CLE-07@box-a", AC4 scroll check`, Boolean(f4 && f4.placeholder === 'Message @CLE-07@box-a' && ac4(f4)), f4)
  info(`${tag} 4 DM`, f4)
  errors.push(...d.errors)
  await d.p.close()

  ok(`${tag} no page error`, errors.length === 0, errors)
}

async function desktopCase(browser) {
  const { p, errors } = await open(browser, { width: 1440, height: 900 }, '/channel/alerts', '.spool-main article.msg[data-msg-id]')
  const f = await field(p)
  ok('1440px the desktop placeholder keeps its key hints (FR-008)', Boolean(f && f.placeholder.startsWith('Message #alerts — ') && f.placeholder.includes('/search')), f)
  ok('1440px no page error', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 }, '/channel/alerts')).p.close()
  await phoneCase(browser, 390, 844)
  await phoneCase(browser, 360, 780)
  await desktopCase(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
