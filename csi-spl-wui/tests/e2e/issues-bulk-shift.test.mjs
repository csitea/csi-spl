// Issues multi-select row 02 (plan issues-multiselect-panel-plan.md 3.3 and
// 7.1; owner HUM-10, t1 0f67a177 "Issues UI professional") in a real browser
// on the mock tenant.
//
// At 412x915 the first tick on a card must not move the list: the bulk bar
// takes the header bar's box in place (Gmail's selection bar), so card 1's
// top is the same within 1 px before and after the tick (the plan measured an
// 88 px jump), the bar is at most 56 px tall, on one row, and every control
// in it keeps a 44x44 tap target; it lies over the sort/filter bar, whose
// buttons it covers. At 1280x800 the desktop bar is unchanged:
// in the flow, one row, the text labels beside the icons.
//
//   pnpm run test:e2e issues-bulk-shift
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-bulk-shift
//   SHOT_DIR=<dir> ...   keep the 412x915 before/after captures (dark + light)
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { printPageLog, retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
}

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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function openIssues(p, vp) {
  await retryOnNetworkChanged(`/issues at ${vp.width} px`, async () => {
    await setPageViewport(p, vp)
    await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  })
  /* `nuxi dev` floats its devtools button over the bottom of a phone screen */
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `issues-bulk-shift-${name}.png`) })
}

const settle = () => new Promise((r) => setTimeout(r, 300))

const cardTop = (p) => p.evaluate(() => {
  const card = document.querySelector('[data-test=issues-card]')
  return card ? Math.round(card.getBoundingClientRect().top * 10) / 10 : null
})

const barBox = (p) => p.evaluate(() => {
  const bar = document.querySelector('[data-test=issues-bulk-bar]')
  if (!bar) return null
  const r = bar.getBoundingClientRect()
  const small = (sel) => {
    const out = []
    for (const el of bar.querySelectorAll(sel)) {
      const b = el.getBoundingClientRect()
      if (b.width && b.height && (b.width < 43.5 || b.height < 43.5)) out.push(`${el.getAttribute('data-test') || el.tagName} ${Math.round(b.width)}x${Math.round(b.height)}`)
    }
    return out
  }
  const tops = [...bar.querySelectorAll('button[data-test^=issues-bulk-], input[data-test^=issues-bulk-]')]
    .map((el) => { const b = el.getBoundingClientRect(); return Math.round(b.top + b.height / 2) })
  return {
    h: Math.round(r.height * 10) / 10,
    w: Math.round(r.width),
    smallButtons: small('button'),
    smallInputs: small('input'),
    rows: new Set(tops).size,
    labels: bar.querySelectorAll('.issues-bulk__label').length,
    /* the text's own width (a Range), not scrollWidth, which never reads below the box */
    count: (() => {
      const n = bar.querySelector('[data-test=issues-bulk-count]')
      if (!n) return null
      const r = document.createRange()
      r.selectNodeContents(n)
      return { need: Math.ceil(r.getBoundingClientRect().width), have: n.clientWidth }
    })(),
    /* inert drops the covered bar from hit testing: lift it to see what is on top */
    covered: (() => {
      const m = document.querySelector('[data-test=issues-mbar]')
      if (!m) return null
      const inert = m.inert
      m.inert = false
      const b = m.getBoundingClientRect()
      const hit = document.elementFromPoint(b.right - 22, b.top + 22)
      m.inert = inert
      return { onTop: !!hit && bar.contains(hit), inert }
    })(),
  }
})

const server = await startServer()
const browser = await launch()
try {
  const p = watchPage(await browser.newPage(), 'issues-bulk-shift')

  /* ---- 412x915: the phone card list ---- */
  const phone = { width: 412, height: 915 }
  await openIssues(p, phone)
  /* the mock tenant's issues live in the page: make two the phone way */
  for (const title of ['Zero shift card one', 'Zero shift card two']) {
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-title]', title)
    await p.click('[data-test=issues-create]')
    await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
    await p.click('[data-test=issues-detail-back]')
    await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: 10000 })
  }
  await p.evaluate(() => window.scrollTo(0, 0))

  for (const theme of ['dark', 'light']) {
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await settle()
    const before = await cardTop(p)
    await shot(p, `412-${theme}-before`)
    await p.click('.issues-check--card input')
    await p.waitForSelector('[data-test=issues-bulk-bar]', { visible: true, timeout: 10000 })
    /* the lazy bar's chunk and its first paint */
    await settle()
    const after = await cardTop(p)
    const bar = await barBox(p)
    await shot(p, `412-${theme}-after`)
    const shift = before === null || after === null ? null : Math.round(Math.abs(after - before) * 10) / 10
    ok(`1 412 ${theme}: card 1 does not move on the first tick (<= 1 px)`, shift !== null && shift <= 1, { before, after, shift })
    ok(`2 412 ${theme}: the bulk bar is <= 56 px tall`, !!bar && bar.h > 0 && bar.h <= 56, bar)
    ok(`3 412 ${theme}: every bulk bar control keeps a 44x44 tap target`, !!bar && bar.smallButtons.length === 0 && bar.smallInputs.length === 0, bar && [...bar.smallButtons, ...bar.smallInputs])
    ok(`4 412 ${theme}: the bulk bar is one row, its count not cut`, !!bar && bar.rows === 1 && !!bar.count && bar.count.need <= bar.count.have + 1, bar)
    ok(`4b 412 ${theme}: the bar lies over the sort/filter bar (on top of its last button, which is inert)`, !!bar && bar.covered?.onTop === true && bar.covered.inert === true, bar)
    const x = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(`5 412 ${theme}: no horizontal page scroll`, x <= 0, x)
    /* Clear gives the header back, and the list stays where it was */
    await p.click('[data-test=issues-bulk-clear]')
    await p.waitForFunction(() => !document.querySelector('[data-test=issues-bulk-bar]'), { timeout: 5000 })
    await settle()
    const back = await cardTop(p)
    ok(`6 412 ${theme}: Clear puts the list back where it was (<= 1 px)`, back !== null && before !== null && Math.abs(back - before) <= 1, { before, back })
  }

  /* ---- 1280x800: the desktop table and its bar, unchanged ---- */
  const desk = { width: 1280, height: 800 }
  await openIssues(p, desk)
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', 'Desktop bulk bar row')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=issues-row] input.issues-check', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-row] input.issues-check')
  await p.waitForSelector('[data-test=issues-bulk-bar]', { visible: true, timeout: 10000 })
  await settle()
  const d = await barBox(p)
  const dpos = await p.evaluate(() => {
    const bar = document.querySelector('[data-test=issues-bulk-bar]')
    return { position: getComputedStyle(bar).position, inHost: !!bar.closest('.issues-bulk-host'), mbar: !!document.querySelector('[data-test=issues-mbar]') }
  })
  ok('7 1280: the desktop bar shows the text labels (6), on one row', !!d && d.labels === 6 && d.rows === 1, d)
  ok('8 1280: the desktop bar stays in the flow, no phone bar', dpos.position === 'static' && dpos.inHost && !dpos.mbar, dpos)
  ok('9 1280: the desktop bar buttons keep 44 px', !!d && d.smallButtons.length === 0, d?.smallButtons)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-bulk-shift: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
