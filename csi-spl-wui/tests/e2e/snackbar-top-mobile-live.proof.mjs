// e3e9ca61 - live proof, signed in, on a PHONE (390x844, touch): the owner's
// empty file picker no longer freezes the app, and the snackbars sit at the
// TOP. The mock twin is snackbar-top-mobile.test.mjs; this one runs the same
// checks on a deployed WUI. It writes NOTHING to the tenant (an empty picker
// and a page-raised error), so it is safe on any tenant.
//
//   E1 an empty picker shows "No file attached" as a TOP snackbar, not in the dock
//   E2 the page stays usable while it shows (a feed point is the feed)
//   E3 a tap on the feed dismisses it AND collapses the Omnibox (blurred)
//   F1 an error shows at the TOP with its text, the feed stays usable
//   F2 a tap on the feed dismisses it
//
//   BASE=https://<wui host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=t1] node tests/e2e/snackbar-top-mobile-live.proof.mjs
//
// The password is read from PW_FILE and never printed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const TOP_BAND = 80
const BOX = '.composer--dock textarea'
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }
async function until(p, fn, arg, ms = 6000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(150)
  }
  return false
}
const geometry = (p, sel) => p.evaluate((sel) => {
  const el = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!el) return null
  const r = el.getBoundingClientRect()
  const dock = document.querySelector('.composer--dock')
  const hit = document.elementFromPoint(Math.round(innerWidth / 2), Math.round(innerHeight / 2))
  return {
    top: Math.round(r.top), bottom: Math.round(r.bottom), vw: innerWidth, vh: innerHeight,
    inDock: Boolean(dock && dock.contains(el)),
    text: el.textContent.trim().slice(0, 160),
    feedPointIsSnackbar: Boolean(hit && el.contains(hit)),
  }
}, sel)
const boxState = (p) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  return el ? { focused: document.activeElement === el, h: Math.round(el.getBoundingClientRect().height) } : null
}, BOX)
const tapFeed = async (p) => p.touchscreen.tap(195, Math.round(844 * 0.3))

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  const p = await browser.newPage()
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.tap('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector(BOX, { visible: true, timeout: 45000 }).then(() => true, () => false)
  step('native sign-in on a phone, the Omnibox is docked', signed, { url: p.url() })
  if (!signed) throw new Error('not signed in')
  /* the served build, read by the page itself (node's own fetch from the box
     can take longer than undici's 10 s connect timeout) */
  res.build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json(), () => null))
  await sleep(1500)
  await shot(p, '0-signed-in')

  await p.tap(BOX)
  await p.keyboard.type('draft')
  const open = await boxState(p)
  step('E0 the Omnibox is open (focused)', Boolean(open && open.focused), open)
  const chooser = p.waitForFileChooser({ timeout: 4000 }).catch(() => null)
  await p.evaluate(() => document.querySelector('[data-testid=attach]')?.click())
  const fc = await chooser
  if (fc) await fc.cancel()
  else await p.evaluate(() => document.querySelector('[data-testid=attach-input]')?.dispatchEvent(new Event('cancel')))
  const up = await until(p, () => Boolean(document.querySelector('[data-testid=attach-nothing]')), null, 4000)
  await sleep(400)
  const e = up ? await geometry(p, '[data-testid=attach-nothing]') : null
  await shot(p, '1-attach-nothing-top')
  step(`E1 the empty picker shows a TOP snackbar (top <= ${TOP_BAND}px), not in the dock`, Boolean(e && e.top >= 0 && e.top <= TOP_BAND && !e.inDock), e)
  step('E2 the page stays usable: a feed point is the feed', Boolean(e && !e.feedPointIsSnackbar), e)
  await tapFeed(p)
  const gone = await until(p, () => !document.querySelector('[data-testid=attach-nothing]'), null, 3000)
  await sleep(400)
  const closed = await boxState(p)
  await shot(p, '2-after-outside-tap')
  step('E3 a tap on the feed dismisses it and collapses the Omnibox', gone && Boolean(closed && !closed.focused), { gone, closed })

  /* the deployed CSP refuses a blob: script, so the error is thrown from the
     proof's own evaluate: it reaches the page as "Script error." with its id */
  await p.evaluate(() => { setTimeout(() => { throw new Error('e3e9ca61 live proof') }, 0) })
  const errUp = await until(p, () => Boolean(document.querySelector('[data-test=error-snackbar-item]')), null, 4000)
  await sleep(500)
  const f = errUp ? await geometry(p, '[data-test=error-snackbar-item]') : null
  await shot(p, '3-error-snackbar-top')
  step(`F1 an error shows at the TOP (top <= ${TOP_BAND}px) with its text; the feed stays usable`, Boolean(f && f.top >= 0 && f.top <= TOP_BAND && f.text && !f.feedPointIsSnackbar), f)
  await tapFeed(p)
  step('F2 a tap on the feed dismisses it', await until(p, () => !document.querySelector('[data-test=error-snackbar-item]'), null, 3000))
  await shot(p, '4-after-error-dismiss')
} catch (err) {
  step('proof ran to the end', false, { error: String(err).slice(0, 300) })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
console.log(`\nsnackbar-top-mobile-live: ${res.steps.length - failed}/${res.steps.length} passed (n=1) build=${res.build && res.build.commit}`)
process.exit(failed ? 1 : 0)
