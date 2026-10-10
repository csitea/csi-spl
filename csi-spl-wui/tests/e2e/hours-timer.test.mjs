// Spec 107 Q7 = B (T019): the header timer in a REAL browser, against the
// mock bundle (utils/hours-timer.mjs plays the hub: it logs each written
// interval and answers 409 period_frozen while spool.mock.hours-frozen is 1).
// At 1440x900 and at 390x844 (phone), each:
//   1  the header shows a plain timer button; the timer chunk is not mounted
//   2  a click opens the target picker (topics, issues, channels); a pick
//      starts the timer and the header shows the running time
//   3  a reload keeps it running: the timer mounts without a click and its
//      clock counts from the stored start (moved 90 minutes back here)
//   4  Stop writes the interval once (~90 minutes) and says so; the button is
//      idle again and the stored timer is gone
//   5  a stop the hub refuses (409 period_frozen) is shown in words, keeps
//      the interval (Retry / Discard), and writes nothing; Discard clears it
//   6  (phone) no sideways scroll with the timer running
//   7  (desktop, 1440 / 1280 / 1024 wide) the running time, seconds
//      included, ends left of the avatar (owner, t1 d8e5c8b7: the seconds
//      went under the avatar icon)
//
// Plant the defect and watch step 3 go red (the stored timer is wiped
// before the reload, as if it lived in memory only):
//   PROVE_RED=no-persist node tests/e2e/hours-timer.test.mjs
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e hours-timer
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const KEY = 'spool.hours-timer'
const LOG = 'spool.mock.hours-timer-log'
const FROZEN = 'spool.mock.hours-frozen'

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const visible = (p, sel, ms = 10000) => p.waitForSelector(sel, { visible: true, timeout: ms }).then(() => true, () => false)
const stored = (p) => p.evaluate((k) => localStorage.getItem(k), KEY)
const mockLog = (p) => p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '[]'), LOG)

/** a fresh signed-in member page (the session seeded once, not on every load) */
async function open(browser, vp) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument(() => {
    try {
      if (!sessionStorage.getItem('e2e.seeded')) {
        localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }))
        sessionStorage.setItem('e2e.seeded', '1')
      }
    } catch { /* about:blank */ }
  })
  await setPageViewport(p, vp)
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx, errors }
}

/* the dialog's strings are in the second catalogue: wait for the dialog body */
async function openDialog(p) {
  await p.click('[data-test=hours-timer-button]')
  return visible(p, '[data-test=hours-timer-dialog]')
}

/* the running time's last digit and the timer button vs the avatar trigger */
const timerEdges = (p) => p.evaluate(() => {
  const clock = document.querySelector('[data-test=hours-timer-clock]')
  const btn = document.querySelector('[data-test=hours-timer-button]')
  const avatar = document.querySelector('[data-test=user-menu-trigger]')
  const node = clock?.firstChild
  if (!node || !btn || !avatar) return null
  const r = document.createRange()
  r.setStart(node, node.length - 1)
  r.setEnd(node, node.length)
  const digit = r.getBoundingClientRect().right
  const right = Math.max(digit, btn.getBoundingClientRect().right)
  const left = avatar.getBoundingClientRect().left
  return { digit: Math.round(digit), right: Math.round(right), avatar: Math.round(left), overlap: Math.round(right - left) }
})

const sideways = (p) => p.evaluate(() => {
  const d = document.documentElement
  const bar = document.querySelector('[data-test=top-bar]')
  return { doc: d.scrollWidth - d.clientWidth, docLeft: document.scrollingElement?.scrollLeft || 0, bar: bar ? bar.scrollWidth - bar.clientWidth : -1 }
})

async function run(browser, vp, tag) {
  const { p, ctx, errors } = await open(browser, vp)
  try {
    const plain = await visible(p, '[data-test=hours-timer-open]', NAV_TIMEOUT)
    const mounted = await p.$('[data-test=hours-timer]')
    ok(`1 ${tag}: the header shows a plain timer button, the timer chunk not mounted`, plain && !mounted, { plain, mounted: !!mounted })

    await p.click('[data-test=hours-timer-open]')
    const picker = await visible(p, '[data-test=hours-picker-row]', 20000)
    const kinds = await p.$$eval('[data-test=hours-picker-row]', (els) => [...new Set(els.map((e) => e.getAttribute('data-kind')))])
    const target = await p.$eval('[data-test=hours-picker-row]', (e) => e.getAttribute('data-target')).catch(() => '')
    await p.click('[data-test=hours-picker-row]')
    const running = await visible(p, '[data-test=hours-timer-clock]')
    const row = JSON.parse((await stored(p)) || '{}')['mock/HUM-1'] || {}
    ok(`2 ${tag}: the picker lists targets and a pick starts the timer`, picker && kinds.length >= 2 && running && row.target === target && !!target, { kinds, target, row })

    /* a run of 90 minutes: move the stored start back, then reload */
    await p.evaluate((k) => {
      const all = JSON.parse(localStorage.getItem(k) || '{}')
      all['mock/HUM-1'].start = new Date(Date.now() - 90 * 60000).toISOString()
      localStorage.setItem(k, JSON.stringify(all))
    }, KEY)
    if (RED === 'no-persist') await p.evaluate((k) => localStorage.removeItem(k), KEY)
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    const back = await visible(p, '[data-test=hours-timer-clock]', 20000)
    const clock = await text(p, '[data-test=hours-timer-clock]')
    ok(`3 ${tag}: a reload keeps it running from the stored start`, back && /^1:3[01]:\d\d$/.test(clock), { back, clock })

    if (vp.width > 820) {
      for (const width of [1440, 1280, 1024]) {
        await applyViewport(p, { ...vp, width })
        await sleep(300)
        const edge = await timerEdges(p)
        if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/hours-timer-${width}.png` })
        ok(`7 ${tag}: at ${width} the running time, seconds included, ends left of the avatar`, !!edge && edge.overlap < 0, edge)
      }
      await applyViewport(p, vp)
    }
    if (vp.width < 820) {
      const sx = await sideways(p)
      ok(`6 ${tag}: no sideways scroll with the timer running`, sx.doc <= 1 && sx.docLeft === 0 && sx.bar <= 1, sx)
    }

    const dlg = await openDialog(p)
    await p.click('[data-test=hours-timer-stop]')
    const done = await visible(p, '[data-test=hours-timer-done]')
    const doneText = await text(p, '[data-test=hours-timer-done]')
    const log = await mockLog(p)
    const minutes = (log[0]?.written || []).reduce((n, w) => n + w.minutes, 0)
    const gone = (await stored(p)) === null
    ok(`4 ${tag}: Stop writes the interval once and says so; the timer is cleared`,
      dlg && done && /^Logged 1:3[01] to /.test(doneText) && log.length === 1 && log[0].target === target && minutes >= 90 && minutes <= 91 && gone,
      { doneText, log, gone })
    await p.keyboard.press('Escape')
    await until(p, () => document.querySelector('[data-test=hours-timer]')?.getAttribute('data-state') === 'idle', null, 5000)

    /* a frozen day: the hub refuses the stop */
    await openDialog(p)
    await visible(p, '[data-test=hours-picker-row]', 20000)
    await p.click('[data-test=hours-picker-row]')
    await visible(p, '[data-test=hours-timer-clock]')
    await p.evaluate((k) => localStorage.setItem(k, '1'), FROZEN)
    await openDialog(p)
    await p.click('[data-test=hours-timer-stop]')
    const err = await visible(p, '[data-test=hours-timer-error]')
    const errText = await text(p, '[data-test=hours-timer-error]')
    const state = await p.$eval('[data-test=hours-timer]', (e) => e.getAttribute('data-state')).catch(() => '')
    const retry = await text(p, '[data-test=hours-timer-stop]')
    const held = JSON.parse((await stored(p)) || '{}')['mock/HUM-1']
    ok(`5a ${tag}: a 409 period_frozen is said in words, the interval is kept, nothing written`,
      err && /frozen/.test(errText) && state === 'refused' && retry === 'Try again' && !!held?.stopped && (await mockLog(p)).length === 1,
      { errText, state, retry, held })
    await p.click('[data-test=hours-timer-discard]')
    const cleared = await until(p, () => document.querySelector('[data-test=hours-timer]')?.getAttribute('data-state') === 'idle', null, 5000)
    ok(`5b ${tag}: Discard clears it`, cleared && (await stored(p)) === null)
    ok(`${tag}: no unexpected page errors`, errors.length === 0, errors)
  } finally {
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  await run(browser, { width: 1440, height: 900 }, '1440')
  await run(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '390')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nhours-timer: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
