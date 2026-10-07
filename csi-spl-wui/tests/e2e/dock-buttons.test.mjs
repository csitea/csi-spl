// Topic d4bc9db4 (owner): the phone composer dock's button row is
// Back | Attach | Send. The camera button is gone (a photo is taken through
// Attach: the OS picker offers the camera), Attach sits in the middle, and
// Back is the top bar's "<" (MobileBack) - the same stack.pop(), so a tap on
// either lands on the same route and level. Back stays in thumb reach while
// the omnibox is focused (owner, topic 35c70261: "much easier with the thumb
// to go back and forth"). The desktop row is unchanged (the control).
//
//   phone (390x844, hasTouch):
//     1 no camera button, no capture input; Back, Attach, Send left to right,
//       Attach 2 px left of the midpoint between them (t1 842e581f moved
//       Back's arrow 4 px right), each a 44 px target
//     2 level 1: Back is shown but disabled (nothing below to go back to)
//     3 level 3: the dock's Back lands where the top bar's "<" lands
//     4 level 2: the same, 2 -> 1
//     5b a topic open with a draft: no target chip in the dock (085 AC3,
//       owner msg b2e7c197), so the row keeps Back | Attach | Send only
//     5 the omnibox focused on a short (keyboard-up) viewport: Back is on
//       screen, the topmost element at its centre, and a tap steps back
//   desktop (1440x900): 6 no Back in the row, Attach + Send as before;
//     6b a draft on /lobby still draws the target chip ("#lobby")
//
// Run:
//   pnpm run test:e2e dock-buttons
//   BASE_URL=<generated bundle> pnpm run test:e2e dock-buttons   # what CI does
//   SHOTS=<dir> ... also writes the 390 px screenshots there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TAP = 44

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
/* Let the page finish what a tap started (a lazy page chunk) before the next
   goto tears the document down: an import cut off mid-flight surfaced once in
   CI as a page error (run 37020039069, n=1; 0 of 7 local generated-bundle runs) */
const settle = (p) => p.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {})

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

/** The omnibox's button row, left to right, and what each button is. */
const rowFacts = (p) => p.evaluate(() => {
  const f = document.querySelector('form.composer.omnibox--global')
  if (!f) return null
  const row = f.querySelector('.composer-row')
  const buttons = [...(row?.querySelectorAll('button') || [])]
    .filter((b) => b.getClientRects().length)
    .map((b) => {
      const r = b.getBoundingClientRect()
      return { id: b.getAttribute('data-testid'), cx: Math.round(r.left + r.width / 2), w: Math.round(r.width), h: Math.round(r.height), disabled: b.disabled, label: b.getAttribute('aria-label') }
    })
    .sort((a, b) => a.cx - b.cx)
  return {
    docked: f.getAttribute('data-docked') === 'true',
    buttons,
    camera: Boolean(f.querySelector('[data-testid=attach-camera], input[capture]')),
  }
})

/** The route and the level the shell is on. */
const where = (p) => p.evaluate(() => ({
  level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
  path: location.pathname + location.search,
}))

/** A topic, opened the way a card click opens it (as mobile-stack.test.mjs does). */
const openTopic = (p) => p.evaluate((id) => {
  const topic = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')
  if (!topic) return false
  topic.openTopic(id)
  return true
}, TASK)

async function toChannel(p) {
  await settle(p)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(800)
  await p.click('[data-testid=sidebar-tab-channels]')
  await sleep(400)
  await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
  await sleep(1200)
}

async function toTopic(p) {
  await toChannel(p)
  await openTopic(p)
  await sleep(1000)
}

const tapBack = async (p, sel) => {
  await p.tap(sel)
  await sleep(1000)
  await settle(p)
  return where(p)
}

async function phone(browser) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push({ at: p.url(), err: String(e.stack || e).slice(0, 600) }))
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })

  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=dock-back]', { timeout: NAV_TIMEOUT }).catch(() => {})
  await sleep(600)
  const r1 = await rowFacts(p)
  const ids = r1 ? r1.buttons.map((b) => b.id) : []
  const [back, attach, send] = r1 ? r1.buttons : []
  ok('390px 1 no camera; Back, Attach, Send left to right; Attach 2 px left of centre; 44 px targets',
    Boolean(r1 && r1.docked && !r1.camera && ids.join(',') === 'dock-back,attach,send'
      && Math.abs(attach.cx - (back.cx + send.cx) / 2 + 2) <= 1 && back.label
      && r1.buttons.every((b) => b.w >= TAP && b.h >= TAP)), r1)
  ok('390px 2 level 1: Back is shown and disabled', Boolean(back && back.id === 'dock-back' && back.disabled), back)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'dock-buttons-390-level1.png') })

  /* 3: level 3 -> the top bar's "<" and the dock's Back land on the same place */
  await toTopic(p)
  const at3 = await where(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'dock-buttons-390-level3.png') })
  const chevron3 = await tapBack(p, '.topic [data-testid=mobile-back]')
  await toTopic(p)
  const dock3 = await tapBack(p, '[data-testid=dock-back]')
  ok('390px 3 level 3: dock Back lands where the top-bar "<" lands',
    at3.level === '3' && chevron3.level === '2' && dock3.level === chevron3.level && dock3.path === chevron3.path,
    { at3, chevron3, dock3 })

  /* 4: level 2 -> 1, the same */
  await toChannel(p)
  const at2 = await where(p)
  const chevron2 = await tapBack(p, '.spool-main [data-testid=mobile-back]')
  await toChannel(p)
  const dock2 = await tapBack(p, '[data-testid=dock-back]')
  ok('390px 4 level 2: dock Back lands where the top-bar "<" lands',
    at2.level === '2' && chevron2.level === '1' && dock2.level === chevron2.level && dock2.path === chevron2.path,
    { at2, chevron2, dock2 })

  /* 5: the omnibox focused with the keyboard up (a short viewport): Back is
     in thumb reach, nothing covers it, and a tap steps back */
  await toTopic(p)
  await p.setViewport({ width: 390, height: 480, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await sleep(400)
  await p.focus('form.composer.omnibox--global textarea')
  await p.keyboard.type('draft')
  await sleep(400)
  const kb = await p.evaluate(() => {
    const b = document.querySelector('[data-testid=dock-back]')
    if (!b) return null
    const r = b.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    return {
      top: Math.round(r.top), bottom: Math.round(r.bottom), vh: innerHeight,
      onTop: Boolean(hit && b.contains(hit)),
      focused: document.activeElement?.tagName === 'TEXTAREA',
      disabled: b.disabled,
      chip: [...document.querySelectorAll('form.composer [data-test=composer-target-chip]')].some((e) => e.getClientRects().length > 0),
    }
  })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'dock-buttons-390-omnibox-focused.png') })
  const kbBack = await tapBack(p, '[data-testid=dock-back]')
  ok('390px 5 omnibox focused, short viewport: Back on screen, on top, and a tap steps 3 -> 2',
    Boolean(kb && kb.focused && kb.onTop && !kb.disabled && kb.top >= 0 && kb.bottom <= kb.vh && kb.bottom > kb.vh - 120 && kbBack.level === '2'),
    { kb, kbBack })
  ok('390px 5b a topic open with a draft: no target chip in the dock (085 AC3)', Boolean(kb && kb.focused && kb.chip === false), kb)
  ok('390px no page error', errors.length === 0, errors)
  await p.close()
}

async function desktop(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.composer.omnibox--global', { timeout: NAV_TIMEOUT })
  await sleep(400)
  const r = await rowFacts(p)
  ok('1440px 6 CONTROL: the desktop row is unchanged - Attach + Send, no Back, no camera',
    Boolean(r && !r.docked && !r.camera && r.buttons.map((b) => b.id).join(',') === 'attach,send'), r)
  await p.focus('form.composer.omnibox--global textarea')
  await p.keyboard.type('x')
  await sleep(300)
  const chip = await p.evaluate(() => {
    const el = [...document.querySelectorAll('form.composer.omnibox--global [data-test=composer-target-chip]')].find((e) => e.getClientRects().length > 0)
    return el ? el.textContent.trim() : null
  })
  ok('1440px 6b a draft on /lobby still draws the target chip "#lobby"', chip === '#lobby', { chip })
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await phone(browser)
  await desktop(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
