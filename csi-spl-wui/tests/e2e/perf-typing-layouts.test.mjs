// Perf round 19 row 01 (SPL-6418): typing into the top-bar field must not
// force a layout per key it does not need. `fitGlobalBox` collapsed the field
// to `height: auto` and read `scrollHeight` again on every key of a draft that
// still fit: two forced layouts per key (plan perf-round-19-plan.md row 01,
// editor 2.7 / 2.11: 41 + 41 per 41 keys, n=3). Row 02 (SPL-6654) lowered the
// ceiling: the draft's width came from a hidden span read with
// getBoundingClientRect on every key, one more forced layout per key.
//
//   desktop (1440x900), the mock, /lobby, a fresh page per run:
//     1 40 typed characters cost at most CEILING layouts (CDP
//       Performance.getMetrics LayoutCount delta), every run (n=RUNS)
//     2 CONTROL: the field still grows when the text wraps to a second line
//       and shrinks back to its one-line height when that text is deleted
//     3 CONTROL (R7 c-317 case A): a 4-line draft, select all, a longer
//       one-line text inserted over it: the field goes back to one line
//     4 CONTROL (R7 c-317 case B): the same draft, one line break replaced
//       by a space (same length, 3 lines): the field shrinks
//
// Run:
//   pnpm run test:e2e perf-typing-layouts
//   BASE_URL=<generated bundle> pnpm run test:e2e perf-typing-layouts   # what CI does
//   PERF_TYPING_RUNS=5 ...   # the A/B of plan section 3.3 (n>=5 per arm)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RUNS = Number(process.env.PERF_TYPING_RUNS ?? 3)
/* row 02's after-arm, 44 in 5 of 5 (before, row 01's tree: 86 in 5 of 5), + 10% */
const CEILING = Number(process.env.PERF_TYPING_CEILING ?? 48)
const BOX = 'form.composer.omnibox--global textarea'
const TYPED = 'the quick brown fox jumps over a lazy do'
/* enough to wrap the 1440 px top-bar field onto a second line */
const WRAP = ' and then some more words'.repeat(12)

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

/** Two frames and a task after the last key: its fit (nextTick) and frame are done. */
const settle = (p) => p.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 50)))))
const height = (p) => p.$eval(BOX, (ta) => Math.round(ta.getBoundingClientRect().height))

async function openLobby(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.focus(BOX)
  await settle(p)
  return p
}

/** LayoutCount delta of TYPED, one key at a time, the fits after each key included. */
async function typeCount(browser) {
  const p = await openLobby(browser)
  const cdp = await p.createCDPSession()
  await cdp.send('Performance.enable')
  const layouts = async () => (await cdp.send('Performance.getMetrics')).metrics.find((m) => m.name === 'LayoutCount').value
  const before = await layouts()
  for (const ch of TYPED) {
    await p.keyboard.type(ch)
    await settle(p)
  }
  const n = (await layouts()) - before
  const typed = await p.$eval(BOX, (ta) => ta.value)
  await p.close()
  return { n, typed: typed === TYPED }
}

async function growShrink(browser) {
  const p = await openLobby(browser)
  await p.keyboard.type(TYPED)
  await settle(p)
  const one = await height(p)
  await p.keyboard.type(WRAP)
  await settle(p)
  const grown = await height(p)
  /* delete the wrapped tail: the field goes back to one line */
  await p.$eval(BOX, (ta, n) => ta.setSelectionRange(n, ta.value.length), TYPED.length)
  await p.keyboard.press('Backspace')
  await settle(p)
  const shrunk = await height(p)
  await p.close()
  ok('1440px 2 CONTROL: the field grows on a second line and shrinks back on delete', grown > one && shrunk === one, { one, grown, shrunk })
}

/** Insert text the way a paste or a key does (an input event), over the selection. */
const insert = (p, text) => p.$eval(BOX, (ta, t) => { ta.focus(); document.execCommand('insertText', false, t) }, text)
const DRAFT = 'a\nb\nc\nd'

/* the grow-only path is for text added at one place; a replacement that
   keeps or grows the length with fewer lines must still shrink the field */
async function replaceShrinks(browser) {
  let p = await openLobby(browser)
  const one = await height(p)
  await insert(p, DRAFT)
  await settle(p)
  const tall = await height(p)
  await p.$eval(BOX, (ta) => ta.select())
  await insert(p, 'abcdefgh')
  await settle(p)
  const replaced = await height(p)
  await p.close()
  ok('1440px 3 CONTROL: a 4-line draft replaced by a longer one-line text goes back to one line', tall > one && replaced === one, { one, tall, replaced })

  p = await openLobby(browser)
  await insert(p, DRAFT)
  await settle(p)
  const four = await height(p)
  await p.$eval(BOX, (ta) => ta.setSelectionRange(1, 2))
  await insert(p, ' ')
  await settle(p)
  const three = await height(p)
  await p.close()
  ok('1440px 4 CONTROL: one line break replaced by a space (same length) shrinks the field', three < four, { four, three })
}

const server = await startServer()
const browser = await launch()
try {
  const counts = []
  for (let run = 1; run <= RUNS; run++) {
    const { n, typed } = await typeCount(browser)
    counts.push(n)
    ok(`1440px 1 run ${run}/${RUNS}: ${TYPED.length} typed keys cost <= ${CEILING} layouts`,
      typed && n <= CEILING, { layouts: n, typed })
  }
  console.log(`  layouts per ${TYPED.length} keys: ${counts.join(' ')} (min ${Math.min(...counts)}, max ${Math.max(...counts)})`)
  await growShrink(browser)
  await replaceShrinks(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
