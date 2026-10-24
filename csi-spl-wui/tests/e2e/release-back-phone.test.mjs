// SPL-3211 (owner HUM-10, t1 bca76ead msg 3b0917bb: "In this view, the All
// Versions links should be in the bottom left on the screen on mobile"):
// the release notes' "All versions" link (release_notes.back) on a phone.
//
// Against the mock tenant, the note /releases/<sha prefix> (the owner's
// screenshot; a version opened alone is desktop only, its keys are off on a
// phone):
//   1 at 360 and 412 px the link's box is within 24 px of the screen's
//     bottom-left corner, and it is still there after the body scrolls
//   2 scrolled to the end, the note's last line ends above the link
//   3 the link is still the first focusable thing in the dialog body (Tab
//     order unchanged)
//   4 at 1440 px the link is where it was: in the flow, above the note,
//     at the body's top left
//   5 no page error
//
// Run:
//   pnpm run test:e2e release-back-phone
//   BASE_URL=<generated bundle> pnpm run test:e2e release-back-phone   # what CI does
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
if (SHOT_DIR) mkdirSync(SHOT_DIR, { recursive: true })
/* the mock's commit j has sha (j + 1) as 8 hex digits, five times */
const mockSha = (j) => (j + 1).toString(16).padStart(8, '0').repeat(5)
const NEAR = 24
const VIEWPORTS = [
  { width: 360, height: 740, mobile: true },
  { width: 412, height: 915, mobile: true },
  { width: 1440, height: 900, mobile: false },
]
const VIEWS = [
  { name: 'note', path: () => '/releases/' + mockSha(9).slice(0, 8), back: 'release-note-back', last: '[data-test=release-note]' },
]

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** The link's box, the screen, the body and the last content's bottom. */
const facts = (p, view) => p.evaluate(({ back, last }) => {
  const b = document.querySelector(`[data-test=${back}]`)
  const body = document.querySelector('[data-testid=ui-dialog-body]')
  const content = document.querySelector(last)
  if (!b || !body || !content) return null
  const r = b.getBoundingClientRect()
  const br = body.getBoundingClientRect()
  const focusables = [...body.querySelectorAll('a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])')].filter((e) => e.getClientRects().length)
  return {
    l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom),
    vw: window.innerWidth, vh: window.innerHeight,
    bodyL: Math.round(br.left), bodyT: Math.round(br.top),
    position: getComputedStyle(b).position,
    contentTop: Math.round(content.getBoundingClientRect().top),
    contentBottom: Math.round(content.getBoundingClientRect().bottom),
    scrollable: body.scrollHeight - body.clientHeight,
    scrollTop: Math.round(body.scrollTop),
    firstFocus: focusables[0] === b,
  }
}, view)

const atCorner = (f) => Boolean(f && f.l >= 0 && f.l <= NEAR && f.b <= f.vh && f.vh - f.b <= NEAR)

const server = await startServer()
const browser = await launch()
try {
  for (const vp of VIEWPORTS) {
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    for (const view of VIEWS) {
      const tag = `${vp.width} ${view.name}`
      await p.goto(server.base + view.path(), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await signIn(p)
      const shown = await until(p, (sel) => Boolean(document.querySelector(sel)), `[data-test=${view.back}]`, 15000)
      await sleep(400)
      const f0 = await facts(p, view)
      if (SHOT_DIR) await p.screenshot({ path: `${SHOT_DIR}/release-back-${view.name}-${vp.width}.png` })
      if (vp.mobile) {
        ok(`${tag} 1a the link is within ${NEAR} px of the bottom-left corner`, shown && atCorner(f0), f0)
        await p.evaluate(() => { const b = document.querySelector('[data-testid=ui-dialog-body]'); b.scrollTop = b.scrollHeight })
        await sleep(300)
        const f1 = await facts(p, view)
        ok(`${tag} 1b scrolled, the link stays at the bottom-left corner`, atCorner(f1), f1 && { l: f1.l, b: f1.b, scrollTop: f1.scrollTop })
        ok(`${tag} 2 at the end the content ends above the link`, f1 && f1.contentBottom <= f1.t, f1 && { contentBottom: f1.contentBottom, linkTop: f1.t })
      } else {
        ok(`${tag} 4 desktop: the link is in the flow above the content, at the body's top left`,
          shown && f0 && f0.position === 'static' && f0.b <= f0.contentTop && f0.t - f0.bodyT <= 40 && f0.l - f0.bodyL <= 40, f0)
      }
      ok(`${tag} 3 the link is still the first focusable thing in the body`, f0?.firstFocus, f0?.firstFocus)
    }
    ok(`${vp.width} 5 no page error`, errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nrelease-back-phone: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
