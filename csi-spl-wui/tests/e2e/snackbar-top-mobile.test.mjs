// Owner, t1 topic e3e9ca61 (on a phone): "When I tried to upload the file, I
// didn't find the file. I got this error message and this snack bar basically
// froze so I couldn't do anything." / "the position of the snack bar on mobile
// should not be at the bottom but it should be on the top." / "whenever I
// click somewhere else, the snack bar and the omnibar should disappear."
//
// Why it froze (old code): Attach keeps the focus in the Omnibox
// (@mousedown.prevent), so after an empty file picker the docked box stayed
// open at 40% of the screen, keyboard up, with the "No file attached" notice
// INSIDE the dock: no close, no timeout, cleared only by the next attach. A tap
// on the feed did nothing to either.
//
// Runs against the lde mock (no hub). 390x844, isMobile + hasTouch. Checks:
//   E1 an empty file picker shows the notice as a TOP snackbar, under the
//      safe-area inset, not in the dock, worded for a finger
//   E2 the page stays usable while it shows: a point on the feed is the feed
//   E3 a tap on the feed dismisses it AND collapses the Omnibox (blurred,
//      back to one line)
//   F1 an error raises the error snackbar at the TOP with its text
//   F2 a tap on the feed dismisses it, and the feed under it took the tap
//
// Run:
//   node tests/e2e/snackbar-top-mobile.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/snackbar-top-mobile.test.mjs   # what CI does
//   OUT=<dir> ... also writes phone-size screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
/* "at the top": the snackbar starts within this many px of the screen top */
const TOP_BAND = 80

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const BOX = '.composer--dock textarea'

/** Where the snackbar `sel` sits, and what a point in the middle of the feed is. */
const geometry = (p, sel) => p.evaluate((sel) => {
  const el = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!el) return null
  const r = el.getBoundingClientRect()
  const dock = document.querySelector('.composer--dock')
  const fx = Math.round(window.innerWidth / 2)
  const fy = Math.round(window.innerHeight / 2)
  const hit = document.elementFromPoint(fx, fy)
  return {
    top: Math.round(r.top), bottom: Math.round(r.bottom), vh: window.innerHeight,
    inDock: Boolean(dock && dock.contains(el)),
    text: el.textContent.trim().slice(0, 160),
    feedPoint: { x: fx, y: fy },
    feedPointIsSnackbar: Boolean(hit && el.contains(hit)),
    feedPointBlocked: Boolean(hit && getComputedStyle(hit).pointerEvents === 'none'),
  }
}, sel)

const boxState = (p) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  return el ? { focused: document.activeElement === el, h: Math.round(el.getBoundingClientRect().height) } : null
}, BOX)

/** A finger on a point of the feed well clear of the top band and the dock. */
async function tapFeed(p) {
  const pt = await p.evaluate(() => ({ x: Math.round(window.innerWidth / 2), y: Math.round(window.innerHeight * 0.3) }))
  await p.touchscreen.tap(pt.x, pt.y)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  /* warm a throwaway load: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
  await sleep(600)
  ok('the page is a phone (390 wide, pointer: coarse)', await p.evaluate(() => window.innerWidth === 390 && matchMedia('(pointer: coarse)').matches))

  /* ---- E. an empty file picker ------------------------------------------ */
  await p.focus(BOX)
  await p.keyboard.type('a draft that opens the box\nline two\nline three\nline four')
  await sleep(300)
  const open = await boxState(p)
  ok('E0 the Omnibox is open (focused, keyboard up)', open && open.focused, open)

  /* the paperclip: the native picker comes back empty (puppeteer's cancel
     fires the input's `cancel`, as Chrome does for an empty close) */
  const chooser = p.waitForFileChooser({ timeout: 4000 }).catch(() => null)
  await p.evaluate(() => document.querySelector('[data-testid=attach]')?.click())
  const fc = await chooser
  if (fc) await fc.cancel()
  else await p.evaluate(() => document.querySelector('[data-testid=attach-input]')?.dispatchEvent(new Event('cancel')))

  const shown = await until(p, () => Boolean(document.querySelector('[data-testid=attach-nothing]')), null, 4000)
  ok('E1 the empty picker is not silent', shown)
  const e = shown ? await geometry(p, '[data-testid=attach-nothing]') : null
  await shot(p, 'e1-attach-nothing-top')
  ok(`E1 the notice is a TOP snackbar (top <= ${TOP_BAND}px), not inside the dock`, e && e.top >= 0 && e.top <= TOP_BAND && !e.inDock, e)
  ok('E1 it is worded for a finger (no double-click, no drag)', e && !/double|drag/i.test(e.text), e && e.text)
  ok('E1 it has a close button', await p.evaluate(() => Boolean(document.querySelector('[data-testid=attach-nothing-close]'))))
  ok('E2 the page stays usable: a point on the feed is the feed, not the snackbar', e && !e.feedPointIsSnackbar && !e.feedPointBlocked, e)

  await tapFeed(p)
  ok('E3 a tap on the feed dismisses the notice', await until(p, () => !document.querySelector('[data-testid=attach-nothing]'), null, 3000))
  await sleep(300)
  const closed = await boxState(p)
  ok('E3 ... and collapses the Omnibox (blurred, one line)', closed && !closed.focused && closed.h <= 50, closed)
  await shot(p, 'e3-after-outside-tap')

  /* ---- F. an error ------------------------------------------------------- */
  /* a page script, so the window error carries its message (an evaluate's
     throw reaches the page as a cross-origin "Script error.") */
  await p.evaluate(() => {
    const s = document.createElement('script')
    s.src = URL.createObjectURL(new Blob(["setTimeout(() => { throw new Error('e3e9ca61 e2e: upload failed') }, 0)"], { type: 'text/javascript' }))
    document.head.appendChild(s)
  })
  const errUp = await until(p, () => Boolean(document.querySelector('[data-test=error-snackbar-item]')), null, 4000)
  ok('F1 an error raises the error snackbar', errUp)
  await sleep(500) /* past the 0.28 s slide-in */
  const f = errUp ? await geometry(p, '[data-test=error-snackbar-item]') : null
  await shot(p, 'f1-error-snackbar-top')
  ok(`F1 it is at the TOP (top <= ${TOP_BAND}px) with the error text`, f && f.top >= 0 && f.top <= TOP_BAND && /upload failed/.test(f.text), f)
  ok('F1 the page stays usable: a point on the feed is the feed', f && !f.feedPointIsSnackbar, f)
  await tapFeed(p)
  ok('F2 a tap on the feed dismisses the error snackbar', await until(p, () => !document.querySelector('[data-test=error-snackbar-item]'), null, 3000))

  const benign = (e) => /Failed to fetch dynamically imported module|e3e9ca61 e2e/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsnackbar-top-mobile: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
