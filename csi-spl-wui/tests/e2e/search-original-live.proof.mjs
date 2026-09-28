// 022 §10 live proof: "Open original" on a deployed WUI, signed
// in. Search Q -> the first message hit's menu (right-click) lists Open
// original / Show here / Copy link -> a click opens the DM or channel the hit
// was posted in (?topic= and #<msg_id>), the hit marked on screen -> Back
// returns to the results. Then the same on a 390 px phone (long press, sheet,
// Open original). Read-only: it writes nothing. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> OUT=<dir> EMAIL=<member> PW_FILE=<0600 file> \
//     [Q=deploy] [TENANT=t1] [CHROME_PATH=...] node tests/e2e/search-original-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW_FILE = need('PW_FILE')
const Q = process.env.Q || 'deploy'
const TENANT = process.env.TENANT || 't1'
const HIT = '[data-test=search-results] .search-row[data-type=messages]'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, q: Q, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
/** any copy of the hit that is marked AND has a box: on a phone the first copy
    in the DOM is the hidden middle-list card, and waitForSelector's `visible`
    tests only the first match (measured on prd e2e, d61ff191) */
const markedCopy = (p, msgId) => p.waitForFunction((id) => [...document.querySelectorAll(`.msg[data-msg-id="${CSS.escape(id)}"].search-focus`)]
  .some((el) => el.getBoundingClientRect().width > 0), { timeout: 15000 }, msgId).then(() => true).catch(() => false)
/** the hit's thread-pane copy (else any copy) is inside its scroller's viewport - "rendered" is not "on screen" */
async function hitOnScreen(p, msgId) {
  await sleep(1800)
  return p.evaluate((id) => {
    const sel = `.msg[data-msg-id="${CSS.escape(id)}"]`
    const el = document.querySelector(`aside.live-pane ${sel}`) || document.querySelector(sel)
    const sc = el && el.closest('.feed-body')
    if (!el || !sc) return false
    const r = el.getBoundingClientRect()
    const s = sc.getBoundingClientRect()
    return r.top >= s.top - 1 && r.top < s.bottom - 24 && r.top >= 0 && r.top < window.innerHeight
  }, msgId)
}

/** the original of a hit: its channel or DM with the topic open and the hit as the hash (or its topic page) */
function isOriginal(href, msgId) {
  const u = new URL(href)
  const place = /\/(channel|dm)\/[^/]+$/.test(u.pathname) && Boolean(u.searchParams.get('topic'))
  const page = /\/t\/[^/]+$/.test(u.pathname) || /\/issues$/.test(u.pathname)
  return (place || page) && (!msgId || u.hash === '#' + msgId || /\/issues$/.test(u.pathname))
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', readFileSync(PW_FILE, 'utf8').trim())
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForFunction(() => !location.pathname.includes('/login'), { timeout: 30000 }).then(() => true).catch(() => false)
  step('native sign-in', signed, { url: p.url().replace(/\?.*/, '') })
  if (!signed) throw new Error('sign-in failed (a 429 from /api/v1/auth/login is the rate limit)')

  const search = BASE + '/search?q=' + encodeURIComponent(Q)
  await p.goto(search, { waitUntil: 'networkidle2' })
  const hasHit = await p.waitForSelector(HIT, { visible: true, timeout: 20000 }).then(() => true).catch(() => false)
  step('a message hit for Q', hasHit)
  if (!hasHit) throw new Error('no message hit: pick another Q')
  const msgId = await p.$eval(HIT, (el) => String(el.getAttribute('data-key') || '').replace(/^messages:/, '').replace(/@.*$/, ''))

  await p.click(HIT, { button: 'right' })
  const ids = await p.waitForSelector('[data-testid=search-row-menu]', { visible: true, timeout: 5000 })
    .then(() => p.$$eval('[data-testid=search-row-menu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid').replace('search-row-menu-', ''))))
    .catch(() => [])
  step('right-click menu: original, here, copy', JSON.stringify(ids) === '["original","here","copy"]', { ids })
  await p.screenshot({ path: `${OUT}/1-menu-desktop.png` })
  await p.keyboard.press('Escape')

  await p.click(HIT)
  await p.waitForFunction(() => !location.pathname.endsWith('/search'), { timeout: 15000 }).catch(() => null)
  step('click opens the original', isOriginal(p.url(), msgId), { url: p.url(), msgId })
  const marked = await markedCopy(p, msgId)
  const onScreen = marked && await hitOnScreen(p, msgId)
  step('the hit is marked and ON SCREEN in its pane', Boolean(onScreen), { marked, onScreen })
  await p.screenshot({ path: `${OUT}/2-original-desktop.png` })
  await p.goBack()
  const back = await p.waitForSelector(HIT, { visible: true, timeout: 15000 }).then(() => true).catch(() => false)
  step('Back returns to the results', back && new URL(p.url()).searchParams.get('q') === Q, { url: p.url() })

  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(search, { waitUntil: 'networkidle2' })
  await p.waitForSelector(HIT, { visible: true, timeout: 20000 })
  /* on a phone the message section can sit below the fold (channels and topics come first) */
  await p.$eval(HIT, (el) => el.scrollIntoView({ block: 'center' }))
  await sleep(300)
  const box = await (await p.$(`${HIT} .search-row__snippet`)).boundingBox()
  await p.touchscreen.touchStart(box.x + 20, box.y + 5)
  await sleep(800)
  await p.touchscreen.touchEnd()
  const sheet = await p.waitForSelector('[data-testid=search-row-menu].touch-sheet', { visible: true, timeout: 5000 }).then(() => true).catch(() => false)
  step('phone: long press opens the sheet', sheet)
  await p.screenshot({ path: `${OUT}/3-sheet-phone.png` })
  if (sheet) {
    await p.tap('[data-testid=search-row-menu-original]')
    await p.waitForFunction(() => !location.pathname.endsWith('/search'), { timeout: 15000 }).catch(() => null)
    const phoneMarked = await markedCopy(p, msgId)
    const phoneOnScreen = phoneMarked && await hitOnScreen(p, msgId)
    step('phone: Open original, the hit marked and on screen', isOriginal(p.url(), msgId) && Boolean(phoneOnScreen), { url: p.url(), phoneMarked, phoneOnScreen })
    await p.screenshot({ path: `${OUT}/4-original-phone.png` })
  }
} catch (e) {
  step('run', false, { error: String(e && e.message) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
