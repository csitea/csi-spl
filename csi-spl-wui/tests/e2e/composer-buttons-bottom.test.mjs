// Owner HUM-10, t1 topic 932eeefc (2026-10-03): "Move both the play button
// and the attachment to the bottom menu, 2 mm on the left" - "I mean the
// bottom bar where the omnibox is". In the bar that holds the omnibox at the
// bottom, Attach and GO (Send) lead the line: the first one 8 px (~2 mm at
// 96 dpi, 7.56 px) from the bar's left edge, GO next to it, then the field.
//
//   phone (390x844, hasTouch), in a channel, a topic and a DM:
//     1 Attach and Send are inside the dock, Attach starts 8 px (6..10) from
//       the bar's left edge, Send right after it, both left of the field;
//       Back stays after the field; each is the topmost element at its centre
//     2 Attach still opens the picker; Send still sends (the box clears)
//   desktop (1440x900), Settings -> "at the bottom" (composer_position):
//     3 the same order and the 8 px inset in the desktop dock
//     4 Enter still sends from there, and Attach still opens the picker
//   desktop, default (the omnibox in the TOP bar): 5 CONTROL - not a bottom
//     bar, so Attach + Send stay right of the field as before
//
// Run:
//   pnpm run test:e2e composer-buttons-bottom
//   BASE_URL=<generated bundle> pnpm run test:e2e composer-buttons-bottom   # what CI does
//   SHOTS=<dir> ... also writes a screenshot of each case there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const FORM = 'form.composer.omnibox--global'
const INSET = [6, 10]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { if (SHOTS) await p.screenshot({ path: join(SHOTS, `composer-buttons-bottom-${name}.png`) }) }

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

/** The bar that holds the omnibox, and where Attach, Send, the field and Back are in it. */
const layout = (p, barSel) => p.evaluate((FORM, barSel) => {
  const f = document.querySelector(FORM)
  const bar = barSel ? document.querySelector(barSel) : f
  if (!f || !bar) return null
  const r = (el) => {
    if (!el || !el.getClientRects().length) return null
    const b = el.getBoundingClientRect()
    const hit = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2)
    return { l: Math.round(b.left), r: Math.round(b.right), t: Math.round(b.top), b: Math.round(b.bottom), onTop: Boolean(hit && el.contains(hit)) }
  }
  const attach = f.querySelector('[data-testid=attach]')
  const send = f.querySelector('[data-testid=send]')
  return {
    bar: r(bar),
    attach: r(attach),
    send: r(send),
    field: r(f.querySelector('.omnibox-field')),
    back: r(f.querySelector('[data-testid=dock-back]')),
    inBar: Boolean(attach && send && bar.contains(attach) && bar.contains(send)),
    vh: innerHeight,
  }
}, FORM, barSel)

/** Attach, then Send, both first in the bar: the 8 px inset, the order, on top. */
const leads = (g) => Boolean(g && g.inBar && g.attach && g.send && g.field
  && g.attach.l - g.bar.l >= INSET[0] && g.attach.l - g.bar.l <= INSET[1]
  && g.attach.r <= g.send.l && g.send.r <= g.field.l
  && g.attach.onTop && g.send.onTop)

const opensPicker = async (p, tap) => {
  const [chooser] = await Promise.all([
    p.waitForFileChooser({ timeout: 5000 }).catch(() => null),
    tap ? p.tap(`${FORM} [data-testid=attach]`) : p.click(`${FORM} [data-testid=attach]`),
  ])
  if (chooser) await chooser.cancel()
  return Boolean(chooser)
}

/** Type a line and send it with `how`; true when the box clears. */
async function sends(p, how) {
  await p.focus(`${FORM} textarea`)
  await p.keyboard.type('c-107 bottom-bar send')
  await sleep(200)
  if (how === 'enter') await p.keyboard.press('Enter')
  else if (how === 'tap') await p.tap(`${FORM} [data-testid=send]`)
  else await p.click(`${FORM} [data-testid=send]`)
  for (let i = 0; i < 20; i++) {
    await sleep(250)
    if (await p.$eval(`${FORM} textarea`, (t) => t.value === '')) return true
  }
  return false
}

/** Adopt a member session with the composer position picked (omnibox-bottom.test.mjs's way). */
const setPosition = (p, pos) => p.evaluate((pos) => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ ...(session.claims || {}), hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', composer_position: pos })
  return true
}, pos)

const openTopic = (p) => p.evaluate((id) => {
  const topic = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')
  if (!topic) return false
  topic.openTopic(id)
  return true
}, TASK)

async function page(browser, vp, path) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.setViewport(vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${FORM} [data-testid=send]`, { timeout: NAV_TIMEOUT })
  await sleep(600)
  return { p, errors }
}

async function phone(browser) {
  const vp = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
  const { p, errors } = await page(browser, vp, '/channel/alerts')
  const where = {}
  where.channel = await layout(p)
  await shot(p, '390-channel')
  await openTopic(p)
  await sleep(1200)
  where.topic = await layout(p)
  await shot(p, '390-topic')
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await sleep(1000)
  const dm = await p.evaluate(() => [...document.querySelectorAll('a[href^="/dm/"]')].map((a) => a.getAttribute('href'))[0] || null)
  if (dm) {
    await p.goto(server.base + dm, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await sleep(1200)
  }
  where.dm = dm ? await layout(p) : null
  await shot(p, '390-dm')
  for (const [k, g] of Object.entries(where)) {
    ok(`390px 1 ${k}: Attach then Send lead the bottom bar, 8 px in, before the field; Back after it`,
      leads(g) && g.bar.b >= g.vh - 40 && Boolean(g.back && g.back.l >= g.field.r), g)
  }

  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await sleep(800)
  const picker = await opensPicker(p, true)
  const sent = await sends(p, 'tap')
  ok('390px 2 Attach opens the picker, Send sends from the new place', picker && sent, { picker, sent })
  ok('390px no page error', errors.length === 0, errors)
  await p.close()
}

async function desktop(browser) {
  const { p, errors } = await page(browser, { width: 1440, height: 900 }, '/channel/alerts')

  /* 5 CONTROL: the omnibox in the top bar is not a bottom bar */
  const top = await layout(p, 'header.top-bar')
  ok('1440px 5 CONTROL top bar: Attach + Send stay right of the field',
    Boolean(top && top.inBar && top.attach.l >= top.field.r && top.send.l >= top.attach.r), top)

  await setPosition(p, 'bottom')
  await p.waitForFunction(() => document.getElementById('spl-omnibox-dock')?.querySelector('form.composer.omnibox--bottom'), { timeout: 10000 }).catch(() => {})
  await sleep(600)
  const g = await layout(p, '#spl-omnibox-dock')
  await shot(p, '1440-bottom')
  ok('1440px 3 bottom dock: Attach then Send lead the bar, 8 px in, before the field', leads(g) && g.bar.b >= g.vh - 4, g)

  const picker = await opensPicker(p, false)
  const sent = await sends(p, 'enter')
  const clicked = await sends(p, 'click')
  ok('1440px 4 bottom dock: Attach opens the picker, Enter and a click on Send still send', picker && sent && clicked, { picker, sent, clicked })
  ok('1440px no page error', errors.length === 0, errors)
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
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
