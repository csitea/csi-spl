// SPL-2087: with the 5-row card setting, every card is the same height (bug).
// A 1-row card and an 8-row card under the 5-row setting must have equal heights.
// The 1-row card gets white space below its text to match the 5-row height.
//
// Run:
//   pnpm run test:e2e card-height-rows
//   BASE_URL=<generated bundle> pnpm run test:e2e card-height-rows   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per state there

import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'
const ROWS = 5
const SLACK_PX = 1

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

const SHORT_BODY = 'Short message: 1 row.'
const LONG_BODY = 'Long message: 8 rows.\n'.repeat(8).trim()

async function open(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    const session = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  })
  return { p, errors }
}

/* Seed a short and a long card in the channel */
function seedCards(p) {
  return p.evaluate((shortBody, longBody) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const shortRow = {
      v: 1, 
      msg_id: crypto.randomUUID(), 
      task_id: crypto.randomUUID(), 
      ts: new Date().toISOString(), 
      from: 'CLE-07', 
      to: '@channel', 
      kind: 'note', 
      body: shortBody, 
      files: [], 
      channel: channel.active || 'alerts', 
      parent_task_id: null, 
      is_parent: 1
    }
    const longRow = {
      v: 1, 
      msg_id: crypto.randomUUID(), 
      task_id: crypto.randomUUID(), 
      ts: new Date().toISOString(), 
      from: 'CLE-07', 
      to: '@channel', 
      kind: 'note', 
      body: longBody, 
      files: [], 
      channel: channel.active || 'alerts', 
      parent_task_id: null, 
      is_parent: 1
    }
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, shortRow, longRow]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, shortRow, longRow]
    return { shortId: shortRow.msg_id, longId: longRow.msg_id }
  }, SHORT_BODY, LONG_BODY)
}

/* Set the clip mode to 'rows' (5 rows) */
async function setClipMode(p) {
  await p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const prefs = pinia._s.get('prefs')
    prefs.setCardClipMode('rows')
  })
}

/* Get the height of a card's body box */
function cardHeight(p, sel) {
  return p.evaluate((sel) => {
    const card = document.querySelector(sel)
    if (!card) return null
    const body = card.querySelector('[data-testid=card-body]')
    if (!body) return null
    const b = body.getBoundingClientRect()
    return {
      height: Math.round(b.height),
      clip: body.dataset.clip || '',
      grip: Boolean(card.querySelector('[data-testid=card-grip]')),
    }
  }, sel)
}

/* The page at rest: the card reads the same for 12 frames in a row */
async function rest(p, sel) {
  const t0 = Date.now()
  let last = ''
  let still = 0
  while (Date.now() - t0 < NAV_TIMEOUT) {
    const now = JSON.stringify(await cardHeight(p, sel))
    still = now === last && now !== 'null' ? still + 1 : 0
    if (still >= 12) return JSON.parse(now)
    last = now
    await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())))
  }
  throw new Error(`the card did not come to rest in ${NAV_TIMEOUT} ms`)
}

async function heightCase(browser, vp, tag) {
  const { p, errors } = await open(browser, vp)
  const { shortId, longId } = await seedCards(p)
  await setClipMode(p)
  
  const shortSel = `.spool-main article.msg[data-msg-id="${shortId}"]`
  const longSel = `.spool-main article.msg[data-msg-id="${longId}"]`
  
  await p.waitForSelector(`${shortSel} [data-testid=card-body]`, { timeout: 15000 })
  await p.waitForSelector(`${longSel} [data-testid=card-body]`, { timeout: 15000 })
  
  await p.evaluate((shortSel, longSel) => {
    document.querySelector(shortSel).scrollIntoView({ block: 'center' })
    document.querySelector(longSel).scrollIntoView({ block: 'center' })
  }, shortSel, longSel)
  
  const shortCard = await rest(p, shortSel)
  const longCard = await rest(p, longSel)
  
  if (SHOTS) {
    await p.screenshot({ path: join(SHOTS, `card-height-rows-${tag}-short.png`) })
    await p.screenshot({ path: join(SHOTS, `card-height-rows-${tag}-long.png`) })
  }
  
  const maxDiff = SLACK_PX
  const heightDiff = Math.abs(shortCard.height - longCard.height)
  
  ok(`${tag}: 1-row and 8-row cards have equal heights (±${maxDiff}px)`, heightDiff <= maxDiff, {
    shortHeight: shortCard.height, 
    longHeight: longCard.height, 
    diff: heightDiff
  })
  
  ok(`${tag}: 8-row card is clipped and shows the grip`, longCard.clip === 'cut' && longCard.grip, {
    clip: longCard.clip, 
    grip: longCard.grip
  })
  
  ok(`${tag}: 1-row card is not clipped and has no grip`, shortCard.clip === 'fits' && !shortCard.grip, {
    clip: shortCard.clip, 
    grip: shortCard.grip
  })
  
  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESKTOP = { width: 1440, height: 900 }
const server = await startServer()
const browser = await launch()
try {
  await heightCase(browser, DESKTOP, '1440px')
  await heightCase(browser, PHONE, '390px')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)