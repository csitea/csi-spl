// CLE-3433 — the signed-out feed routes offer a way IN, and only when the
// session probe has actually settled on 'out'.
//
// Anonymous is the honest half: load each route with no cookie and read what
// is on screen. The other three session states cannot be reached by loading a
// page, so they are driven on the SAME live build through the pinia session
// store (the shell reacts to that store, so a notice that appears for 'out'
// and not for 'loading'/'unknown'/'in' is the real gate, not a re-run of the
// unit test). 'unknown' matters most: it is an unreachable hub, and prompting
// a signed-in member to sign in because their hub blipped would be worse than
// the defect this fixes.
//
//   BASE=https://dev.<domain> OUT=/var/tmp/CLE-3433-proof \
//     [PATHS=/,/lobby,/channel/lobby,/dm/CLE-00] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/signed-out-notice.proof.mjs
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync } from 'node:fs'
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
const PATHS = (process.env.PATHS || '/,/lobby,/channel/lobby,/dm/CLE-00').split(',').filter(Boolean)

mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
let failed = 0
const step = (name, ok, ev = {}) => {
  if (!ok) failed++
  res.steps.push({ name, ok, ...ev })
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

/**
 * What the page shows right now, read from the DOM. It is passed to
 * page.evaluate() as a function VALUE, never as a string: the deployed CSP
 * carries no 'unsafe-eval', so a `new Function(...)` trampoline throws
 * EvalError against dev and prd while passing happily against a local build
 * that serves no CSP at all. Measured 2026-09-21 on dev.
 */
function readState() {
  const notice = document.querySelector('[data-test="signed-out-notice"]')
  const create = document.querySelector('[data-testid="create-channel"]')
  const link = notice ? notice.querySelector('a') : null
  return {
    shell: Boolean(document.querySelector('nav.sidebar')),
    notice: notice ? notice.innerText.trim() : null,
    href: link ? link.getAttribute('href') : null,
    createRow: Boolean(create),
  }
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
try {
  const ctx = await browser.createBrowserContext()
  for (const path of PATHS) {
    const page = await ctx.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    const resp = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 30000 })
    await new Promise((r) => setTimeout(r, 2500))
    const m = await page.evaluate(readState)
    /* the link must carry THIS route back, or signing in drops the visitor elsewhere */
    const carries = Boolean(m.href && m.href.includes('redirect=') && decodeURIComponent(m.href).includes(path))
    step(`anonymous ${path}: a sign-in notice, no dead create field`,
      (resp ? resp.status() < 400 : false) && m.shell && Boolean(m.notice) && carries && !m.createRow,
      { status: resp && resp.status(), ...m, carries })
    await page.screenshot({ path: `${OUT}/signed-out${path.replace(/\//g, '_')}.png` })
    await page.close()
  }

  /* the three states a page load cannot produce, driven on the same build */
  const page = await ctx.newPage()
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(BASE + PATHS[0], { waitUntil: 'networkidle2', timeout: 30000 })
  await new Promise((r) => setTimeout(r, 2000))
  for (const [state, wantNotice] of [['loading', false], ['unknown', false], ['out', true], ['in', false]]) {
    /* set, settle, then read — two calls, because puppeteer serializes an
       argument and a function passed as one does not arrive callable */
    const set = await page.evaluate((st) => {
      const app = document.querySelector('#__nuxt')?.__vue_app__ || document.body.__vue_app__
      const store = app?.config?.globalProperties?.$pinia?._s?.get('session')
      if (!store) return { err: 'session store unreachable' }
      store.state = st
      return { state: store.state }
    }, state)
    await new Promise((r) => setTimeout(r, 400))
    const m = set.err ? set : { ...set, ...(await page.evaluate(readState)) }
    step(`session '${state}' ${wantNotice ? 'SHOWS' : 'hides'} the notice`,
      !m.err && Boolean(m.notice) === wantNotice, m)
    await page.screenshot({ path: `${OUT}/session-${state}.png` })
  }
  await page.close()
} catch (e) {
  step('proof threw', false, { err: String((e && e.stack) || e) })
} finally {
  await browser.close().catch(() => {})
}
res.failed = failed
writeFileSync(`${OUT}/signed-out-notice.json`, JSON.stringify(res, null, 2))
console.log(failed === 0 ? `ALL PASS (${res.steps.length} steps)` : `${failed} FAIL of ${res.steps.length}`)
process.exit(failed === 0 ? 0 : 1)
