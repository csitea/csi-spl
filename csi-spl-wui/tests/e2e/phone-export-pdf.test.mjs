// SPL-6110 (owner HUM-10, t1 703f2ce5 msgs 4460aad7, 090cf7e2): "On mobile,
// at least, doesn't work." / "Does not work on the topic levels neither." The
// two exports of SPL-5888 (tests/e2e/msg-export-pdf.test.mjs, desktop) on a
// phone: 390x844, touch, the mock bundle.
//
// A phone's print may return at once and fire afterprint before the page is
// laid out for print, so the stubbed window.print here fires afterprint
// inside the call, then page.pdf (print media, as Save as PDF) is taken.
//
// Cases:
//   card   the card's ⋯ sheet lists Export to PDF; a tap on it prints once,
//          on a render that holds exactly that card, and the render is still
//          there for the print after afterprint fired
//   topic  a tap on the topic header's Export topic to PDF prints the cards
//          the pane shows, in order; the render outlives the early
//          afterprint and page.pdf is taken with it; the next touch on the
//          page removes it
//
// Red controls (each seen RED on origin/master 5f1e27bc7's code):
//   - msgMenuItems leaving export-pdf out on `touch`: "card: the phone sheet
//     lists Export to PDF" and every card line after it FAIL
//   - msg-print-run.ts ending the print on afterprint on a phone too:
//     "card/topic: the render outlives an early afterprint" FAIL
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/phone-export-pdf.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CH = 'phone-pdf-6110'

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 10000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

/* a finger on the element's centre; false when something else is on top of it */
async function tap(p, sel) {
  const at = await p.evaluate((s) => {
    const e = document.querySelector(s)
    if (!e) return null
    e.scrollIntoView({ block: 'center' })
    const r = e.getBoundingClientRect()
    const x = r.left + r.width / 2
    const y = r.top + r.height / 2
    const hit = document.elementFromPoint(x, y)
    return hit && e.contains(hit) ? { x, y } : null
  }, sel)
  if (at) await p.touchscreen.tap(at.x, at.y)
  return Boolean(at)
}

/* a channel with topic A and its reply, and topic B, the neighbour */
const seed = (p, tag) => p.evaluate(async ({ CH, tag }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  const a = await ch.send(`PHONE-PDF-A ${tag} the card to export`, undefined, [], CH, 1)
  const r = await ch.send(`PHONE-PDF-A-REPLY ${tag} a reply`, a.task_id, [], CH, 0)
  const b = await ch.send(`PHONE-PDF-B ${tag} the neighbour`, undefined, [], CH, 1)
  return { a: { msg_id: a.msg_id, task_id: a.task_id }, r: { msg_id: r.msg_id }, b: { msg_id: b.msg_id } }
}, { CH, tag })

/* the print render as the print saw it, and whether it is still there now */
const printed = (p) => p.evaluate(() => {
  const host = document.querySelector('[data-test=msg-print-host][data-ready=true]')
  return {
    calls: window.__printCalls,
    seen: window.__printSaw,
    now: host ? [...host.querySelectorAll('[data-test=msg-print-card]')].map((e) => e.getAttribute('data-msg-id')) : null,
    printing: document.documentElement.classList.contains('msg-printing'),
  }
})

const cardSel = (id) => `.spool-main article.msg[data-msg-id="${id}"]`

async function cardCase(p, ids) {
  await p.waitForSelector(cardSel(ids.a.msg_id), { timeout: 10000 })
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), cardSel(ids.a.msg_id))
  const opened = await until(p, () => document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]').length > 0)
  await sleep(400) /* the sheet's slide-up */
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  ok('card: the phone sheet lists Export to PDF', opened && items.includes('msg-menu-export-pdf'), items)
  await p.evaluate(() => { window.__printCalls = 0; window.__printSaw = null })
  const tapped = await tap(p, '[data-testid=msg-menu-export-pdf]')
  ok('card: a finger reaches it', tapped)
  await until(p, () => window.__printCalls > 0, undefined, 20000)
  const got = await printed(p)
  ok('card: print runs once, on exactly that card', got.calls === 1 && JSON.stringify(got.seen) === JSON.stringify([ids.a.msg_id]), got)
  ok('card: the render outlives an early afterprint', JSON.stringify(got.now) === JSON.stringify([ids.a.msg_id]) && got.printing, got)
}

async function topicCase(p, ids) {
  /* a sheet still open (no entry to pick) closes first; the next export replaces the card's render either way */
  if (await p.evaluate(() => Boolean(document.querySelector('[data-testid=msg-menu]')))) {
    /* as a finger does: the dimmed page above the sheet (phone-card-menu.test.mjs keeps 44 px of it) */
    await p.touchscreen.tap(195, 20)
    await until(p, () => !document.querySelector('[data-testid=msg-menu]'))
    await sleep(600) /* the overlay's Back settles before the topic opens */
  }
  await p.evaluate((task) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').openTopic(task), ids.a.task_id)
  const shown = await until(p, (id) => Boolean(document.querySelector(`[data-test=topic-root] article.msg[data-msg-id="${id}"]`)), ids.r.msg_id)
  await until(p, () => Boolean(document.querySelector('[data-test=topic-export-pdf]')))
  const want = await p.evaluate(() => [...document.querySelectorAll('[data-test=topic-root] article.msg[data-msg-id]')].map((e) => e.getAttribute('data-msg-id')))
  await p.evaluate(() => { window.__printCalls = 0; window.__printSaw = null })
  const tapped = await tap(p, '[data-test=topic-export-pdf]')
  ok('topic: the pane shows the reply and a finger reaches Export topic to PDF', shown && tapped)
  await until(p, () => window.__printCalls > 0, undefined, 20000)
  const got = await printed(p)
  ok('topic: print runs once, on the cards shown, in order', got.calls === 1 && want.length >= 2 && JSON.stringify(got.seen) === JSON.stringify(want), { want, got })
  ok('topic: the render outlives an early afterprint', JSON.stringify(got.now) === JSON.stringify(want) && got.printing, got)
  const pdf = Buffer.from(await p.pdf({ format: 'A4', printBackground: true }))
  ok('topic: page.pdf is written with the render in place', pdf.length > 0 && await p.evaluate(() => Boolean(document.querySelector('[data-test=msg-print-host][data-ready=true]'))))
  await p.touchscreen.tap(20, 300)
  ok('topic: the next touch on the page removes the render', await until(p, () => !document.querySelector('[data-test=msg-print-host]') && !document.documentElement.classList.contains('msg-printing')))
}

const srv = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  /* a phone's print: returns at once and fires afterprint inside the call */
  await p.evaluateOnNewDocument(() => {
    window.__printCalls = 0
    window.print = () => {
      window.__printCalls++
      const host = document.querySelector('[data-test=msg-print-host][data-ready=true]')
      window.__printSaw = host ? [...host.querySelectorAll('[data-test=msg-print-card]')].map((e) => e.getAttribute('data-msg-id')) : null
      window.dispatchEvent(new Event('afterprint'))
    }
  })
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  const tag = Math.random().toString(36).slice(2, 8)
  const ids = await seed(p, tag)
  await cardCase(p, ids)
  await topicCase(p, ids)
  ok('no page error', errors.length === 0, errors)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await srv.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nphone-export-pdf: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
