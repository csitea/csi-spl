// Owner HUM-10, t1 topic 932eeefc (2026-10-03): Attach and GO (Send) stay at
// the RIGHT end of the bottom bar that holds the omnibox, moved "just a bit
// 2 mm on the left to align with the scroll till bottom button". 8 px (~2 mm
// at 96 dpi) further in than the bar's own padding, so on a phone GO's right
// edge is the right edge of the thread's round scroll-to-bottom arrow
// (LiveFeed .thread-jump, phone only; a desktop has no such arrow).
//
//   phone (390x844, hasTouch):
//     1 a long thread: the arrow is shown, and GO's right edge lines up with
//       the arrow's right edge (within 1 px); Back, Attach, GO right of the
//       field in that order, Back reaching 2 px under Attach (t1 842e581f
//       moved Back's arrow 4 px right) with Attach on top
//     2 channel, topic, DM: the same place - GO's right edge 16 px (15..17)
//       from the bar's right edge (8 px padding + the 8 px move), every
//       button the topmost element at its centre
//     3 Attach still opens the picker; Send still sends (the box clears)
//   desktop (1440x900), Settings -> "at the bottom" (composer_position):
//     4 Attach then GO right of the field, GO's right edge 20 px (19..21)
//       from the bar's right edge (12 px padding + the 8 px move)
//     5 Enter still sends from there, and Attach still opens the picker
//   desktop, default (the omnibox in the TOP bar): 6 CONTROL - not a bottom
//     bar, so Attach + Send stay right of the field with no extra move
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
/* GO's right edge, px in from the bar's right edge */
const PHONE_END = 16
const DESKTOP_END = 20

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const near = (a, b, tol = 1) => typeof a === 'number' && typeof b === 'number' && Math.abs(a - b) <= tol
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

/** The bar that holds the omnibox, and where Attach, Send, the field, Back and the thread arrow are. */
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
    jump: r(document.querySelector('[data-testid=thread-jump]')),
    inBar: Boolean(attach && send && bar.contains(attach) && bar.contains(send)),
    vh: innerHeight,
  }
}, FORM, barSel)

/** Attach then Send at the bar's right end, right of the field, GO `end` px in, on top. */
const trails = (g, end) => Boolean(g && g.inBar && g.attach && g.send && g.field
  && g.field.r <= g.attach.l && g.attach.r <= g.send.l
  && near(g.bar.r - g.send.r, end)
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
  await p.keyboard.type('c-110 bottom-bar send')
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

/** A thread long enough for the scroll arrow (thread-jump.test.mjs's seed), then open it. */
const seedLongThread = (p) => p.evaluate((task) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const rows = []
  for (let i = 0; i < 24; i++) {
    const ts = new Date(Date.UTC(2026, 0, 1, 0, 0, i)).toISOString()
    rows.push({
      v: 1, msg_id: `c110-${i}`, task_id: task, parent_task_id: task, ts, received_at: ts,
      from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: 'a long reply line\nsecond line\nthird line\nfourth line', files: [],
    })
  }
  pinia._s.get('channel').messages = rows
  pinia._s.get('topic').openTopic(task)
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

  await seedLongThread(p)
  await p.waitForFunction(() => document.querySelector('[data-testid=thread-jump]'), { timeout: 5000 }).catch(() => {})
  await sleep(600)
  const t = await layout(p)
  await shot(p, '390-thread-arrow')
  ok('390px 1 long thread: GO\'s right edge lines up with the scroll-to-bottom arrow (1 px); Back, Attach, GO after the field, Back 2 px under Attach',
    Boolean(t && t.jump && t.send && near(t.send.r, t.jump.r) && t.back && t.attach && t.field.r <= t.back.l
      && near(t.back.r - t.attach.l, 2) && t.attach.onTop && t.attach.r <= t.send.l),
    t && { send: t.send, jump: t.jump, attach: t.attach, back: t.back, field: t.field })

  const where = {}
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await sleep(800)
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
    ok(`390px 2 ${k}: Attach then GO at the bottom bar's right end, GO ${PHONE_END} px in`,
      trails(g, PHONE_END) && g.bar.b >= g.vh - 40, g)
  }

  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await sleep(800)
  const picker = await opensPicker(p, true)
  const sent = await sends(p, 'tap')
  ok('390px 3 Attach opens the picker, Send sends', picker && sent, { picker, sent })
  ok('390px no page error', errors.length === 0, errors)
  await p.close()
}

async function desktop(browser) {
  const { p, errors } = await page(browser, { width: 1440, height: 900 }, '/channel/alerts')

  /* 6 CONTROL: the omnibox in the top bar is not a bottom bar */
  const top = await layout(p, 'header.top-bar')
  const topEnd = await p.evaluate((FORM) => {
    const row = document.querySelector(`${FORM} .composer-row`)
    return row ? getComputedStyle(row).marginInlineEnd : null
  }, FORM)
  ok('1440px 6 CONTROL top bar: Attach + Send right of the field, no extra move',
    Boolean(top && top.inBar && top.attach.l >= top.field.r && top.send.l >= top.attach.r && topEnd === '0px'), { top, topEnd })

  await setPosition(p, 'bottom')
  await p.waitForFunction(() => document.getElementById('spl-omnibox-dock')?.querySelector('form.composer.omnibox--bottom'), { timeout: 10000 }).catch(() => {})
  await sleep(600)
  const g = await layout(p, '#spl-omnibox-dock')
  await shot(p, '1440-bottom')
  ok(`1440px 4 bottom dock: Attach then GO at the bar's right end, GO ${DESKTOP_END} px in`, trails(g, DESKTOP_END) && g.bar.b >= g.vh - 4, g)

  const picker = await opensPicker(p, false)
  const sent = await sends(p, 'enter')
  const clicked = await sends(p, 'click')
  ok('1440px 5 bottom dock: Attach opens the picker, Enter and a click on Send still send', picker && sent && clicked, { picker, sent, clicked })
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
