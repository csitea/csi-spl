// Spec 096 (manual status, lane L3 / T003, test plan 10.2). Real browser,
// mock tenant, 1440 and 390:
//
//   seen      a member's Busy / Unavailable shows as a ring on their dot in
//             the DM list and the @ picker (with the note in grey), and in
//             words in the DM header in place of "online" / "offline"
//   composer  a DM to an Unavailable member, and an @mention of a Busy one,
//             put one inline line above the send ("... is unavailable until
//             HH:MM · On leave"); Busy in the softer colour
//   set       the reader sets Busy with a note from their own row (desktop) or
//             the avatar menu (phone: a bottom sheet, no horizontal scroll);
//             the ring shows, survives a reload; Clear status removes it
//   expiry    a status whose "until" passes clears without a reload
//
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/human-status.test.mjs
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const OMNI = 'form.omnibox--global textarea'
const AWAY = 'HUM-2@box-wui'
const BUSY = 'HUM-3@box-wui'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

const shot = async (p, name) => {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: `${SHOT_DIR}/human-status-${name}.png` })
}

/** The ring of one DM-list row's dot ('' when none, null when no row). */
const rowRing = (p, key) => p.evaluate((key) => {
  const dot = document.querySelector(`a.nav-item[data-key="${key}"] .dot`)
  return dot ? { ring: dot.getAttribute('data-status') || '', label: dot.getAttribute('aria-label') || '' } : null
}, key)

const selfRing = (p) => p.evaluate(() => {
  const d = document.querySelector('[data-test=self-status-dot]')
  return d ? { ring: d.getAttribute('data-status') || '', title: d.getAttribute('title') || '' } : null
})

/** An instant in the page's own zone as the WUI prints an "until": HH:MM
    today, YYYY-MM-DD HH:MM on another day (a run near midnight crosses it). */
const clock = (p, iso) => p.evaluate((iso) => {
  const pad = (n) => String(n).padStart(2, '0')
  const day = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
  const d = new Date(iso)
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  return day(d) === day(new Date()) ? hm : `${day(d)} ${hm}`
}, iso)

async function openDmList(p, base) {
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV })
  await p.click('[data-testid=sidebar-tab-dm]')
  await p.waitForSelector(`a.nav-item[data-key="${AWAY}"]`, { timeout: NAV })
  await sleep(400)
}

async function run(browser, base, width) {
  const phone = width < 600
  const p = await browser.newPage()
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  /* the mock's members: HUM-2 Unavailable for 2 h with a note, HUM-3 Busy */
  const until = new Date(Date.now() + 2 * 3600 * 1000).toISOString()
  await p.evaluateOnNewDocument((claims, until) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify(claims))
      if (!sessionStorage.getItem('hs-seeded')) {
        sessionStorage.setItem('hs-seeded', '1')
        localStorage.setItem('spool.mock.human-status', JSON.stringify({
          'HUM-2': { state: 'unavailable', note: 'On leave', until },
          'HUM-3': { state: 'busy', note: 'In a meeting' },
        }))
      }
    } catch { /* */ }
  }, CLAIMS, until)
  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  const at = await clock(p, until)

  /* seen: the DM list */
  await openDmList(p, base)
  const away = await rowRing(p, AWAY)
  check(`${width}: DM list - red ring on the Unavailable member, words as its label`, away?.ring === 'unavailable' && away.label === `Unavailable until ${at}`, away)
  const busy = await rowRing(p, BUSY)
  check(`${width}: DM list - amber ring on the Busy member`, busy?.ring === 'busy' && busy.label === 'Busy', busy)
  const plain = await rowRing(p, 'HUM-12@box-wui')
  check(`${width}: DM list - no ring on an available member`, plain?.ring === '', plain)
  await shot(p, `${width}-dm-list`)

  /* seen: the DM header, and the composer line on that DM */
  await p.evaluate((k) => document.querySelector(`a.nav-item[data-key="${k}"]`).click(), AWAY)
  await p.waitForSelector('[data-test=feed-header-status-text]', { timeout: NAV })
  await sleep(500)
  const head = await p.evaluate(() => ({
    text: document.querySelector('[data-test=feed-header-status-text]')?.textContent.trim(),
    ring: document.querySelector('[data-test=feed-header-status]')?.getAttribute('data-status') || '',
  }))
  check(`${width}: DM header - the status replaces "offline", ring on its dot`, head.text === `Unavailable until ${at} · On leave` && head.ring === 'unavailable', head)
  const line = await p.waitForSelector('[data-testid=composer-status-row]', { timeout: 8000 }).then(() => p.evaluate(() =>
    [...document.querySelectorAll('[data-testid=composer-status-row]')].map((r) => ({ state: r.getAttribute('data-state'), text: r.textContent.trim().replace(/\s+/g, ' ') }))), () => [])
  check(`${width}: composer - one line for the Unavailable DM peer, before sending`, line.length === 1 && line[0].state === 'unavailable' && line[0].text.endsWith(`is unavailable until ${at} · On leave`), line)
  const blocks = await p.evaluate(() => Boolean(document.querySelector('[role=dialog][data-testid=composer-status-line], [aria-modal=true] [data-testid=composer-status-line]')))
  check(`${width}: composer - the line is inline, not a dialog`, blocks === false)
  await shot(p, `${width}-dm-header`)

  /* seen: the @ picker, and the line for a mention (desktop: the top bar's omnibox) */
  if (!phone) {
    await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
    await p.waitForSelector(OMNI, { visible: true, timeout: NAV })
    await p.click(OMNI)
    await p.keyboard.type('@HUM-3')
    await p.waitForSelector('[data-test=mention-list]', { visible: true, timeout: 8000 }).catch(() => null)
    const opt = await p.evaluate(() => {
      const b = document.querySelector('[data-test=mention-option][data-id="HUM-3"]')
      return b ? { ring: b.querySelector('.dot')?.getAttribute('data-status') || '', note: b.querySelector('[data-testid=mention-status]')?.textContent.trim() } : null
    })
    check(`${width}: @ picker - amber ring and the status in grey after the name`, opt?.ring === 'busy' && opt.note === 'Busy · In a meeting', opt)
    await shot(p, `${width}-mention`)
    await p.keyboard.type(' ')
    await sleep(300)
    const mline = await p.evaluate(() => [...document.querySelectorAll('[data-testid=composer-status-row]')].map((r) => r.getAttribute('data-state')))
    check(`${width}: composer - an @mention of a Busy member shows the softer line`, mline.length === 1 && mline[0] === 'busy', mline)
    const soft = await p.evaluate(() => {
      const r = document.querySelector('[data-testid=composer-status-row]')
      const fg = getComputedStyle(document.body).color
      return r ? getComputedStyle(r).color !== fg : false
    })
    check(`${width}: composer - Busy reads softer than body text`, soft === true)
    await p.evaluate((sel) => { const t = document.querySelector(sel); if (t) { t.value = ''; t.dispatchEvent(new Event('input', { bubbles: true })) } }, OMNI)
  }

  /* set: from the self row (desktop) or the avatar menu (phone) */
  await openDmList(p, base)
  if (phone) {
    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector('[data-test=user-menu-status]', { visible: true, timeout: 8000 })
    await p.click('[data-test=user-menu-status]')
  } else {
    await p.click('[data-testid=status-open]')
  }
  await p.waitForSelector('[data-testid=status-picker]', { visible: true, timeout: 15000 })
  await p.click('[data-testid=status-state-busy]')
  await p.type('[data-testid=status-note]', 'Focus time')
  const sheet = await p.evaluate(() => {
    const r = document.querySelector('[data-testid=status-picker]').getBoundingClientRect()
    return {
      bottom: Math.round(r.bottom), left: Math.round(r.left), width: Math.round(r.width),
      vw: innerWidth, vh: innerHeight, scrollW: document.scrollingElement.scrollWidth,
      count: document.querySelector('[data-testid=status-note-count]')?.textContent.trim(),
      until: document.querySelector('[data-testid=status-until]')?.value,
      pause: Boolean(document.querySelector('[data-testid=status-pause-notify]')),
    }
  })
  check(`${width}: picker - counter, Busy defaults to no end, no pause box for Busy`, sheet.count === '10/80' && sheet.until === 'none' && sheet.pause === false, sheet)
  if (phone) check(`${width}: picker - a bottom sheet, full width, no horizontal scroll`, sheet.bottom === sheet.vh && sheet.left === 0 && sheet.width === sheet.vw && sheet.scrollW <= sheet.vw, sheet)
  else check(`${width}: picker - a centred card`, sheet.bottom < sheet.vh && sheet.left > 0, sheet)
  await p.click('[data-testid=status-state-unavailable]')
  const unav = await p.evaluate(() => ({
    until: document.querySelector('[data-testid=status-until]')?.value,
    pause: document.querySelector('[data-testid=status-pause-notify]')?.checked,
  }))
  check(`${width}: picker - Unavailable defaults to 1 hour, pause box shown and off`, unav.until === '1h' && unav.pause === false, unav)
  await p.click('[data-testid=status-state-busy]')
  await shot(p, `${width}-picker`)
  await p.click('[data-testid=status-save]')
  await p.waitForSelector('[data-testid=status-picker]', { hidden: true, timeout: 8000 }).catch(() => null)
  await sleep(300)
  if (!phone) {
    const mine = await selfRing(p)
    check(`${width}: set - my own dot carries the amber ring and the note`, mine?.ring === 'busy' && /Busy · Focus time/.test(mine.title), mine)
    await shot(p, `${width}-self-set`)
  }
  const stored = await p.evaluate(() => JSON.parse(localStorage.getItem('spool.mock.human-status') || '{}')['HUM-1'] || null)
  check(`${width}: set - the write reached the (mock) hub`, stored?.state === 'busy' && stored.note === 'Focus time', stored)
  await openDmList(p, base)
  if (!phone) {
    const again = await selfRing(p)
    check(`${width}: set - survives a reload (read back from the roster)`, again?.ring === 'busy', again)
    await p.click('[data-testid=status-open]')
  } else {
    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector('[data-test=user-menu-status]', { visible: true, timeout: 8000 })
    await p.click('[data-test=user-menu-status]')
  }
  await p.waitForSelector('[data-testid=status-clear]', { visible: true, timeout: 15000 })
  const note = await p.$eval('[data-testid=status-note]', (el) => el.value)
  check(`${width}: picker - reopens on the current status`, note === 'Focus time', note)
  await p.click('[data-testid=status-clear]')
  await p.waitForSelector('[data-testid=status-picker]', { hidden: true, timeout: 8000 }).catch(() => null)
  await sleep(300)
  const cleared = await p.evaluate(() => JSON.parse(localStorage.getItem('spool.mock.human-status') || '{}')['HUM-1'] || null)
  const ringGone = phone ? '' : (await selfRing(p))?.ring
  check(`${width}: clear - the status is gone`, cleared === null && ringGone === '', { cleared, ringGone })

  /* expiry: a status whose until passes clears without a reload */
  await p.evaluate(() => {
    const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('human-status')
    r.applyStatus({ type: 'status', peer: 'HUM-12@box-wui', state: 'busy', until: new Date(Date.now() + 1500).toISOString() })
  })
  await sleep(200)
  const before = await rowRing(p, 'HUM-12@box-wui')
  await sleep(2500)
  const after = await rowRing(p, 'HUM-12@box-wui')
  check(`${width}: expiry - the ring clears at its until, no reload`, before?.ring === 'busy' && after?.ring === '', { before, after })

  const errs = (await p.evaluate(() => window.__errs || [])).filter((e) => !/dynamically imported module/.test(e))
  check(`${width}: no window error`, errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [1440, 390]) {
    const ctx = await browser.createBrowserContext()
    await run(ctx, server.base, w)
    await ctx.close()
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nhuman-status: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
