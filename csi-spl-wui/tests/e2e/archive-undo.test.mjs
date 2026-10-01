// SPL-1264 (CLE-77809): the "Archived · Undo" snackbar after archiving a card.
// Runs against the lde mock (no hub): the mock client archives / unarchives
// (utils/spool-client.mjs archiveTopic) and the card leaves / rejoins the feed.
//
// Desktop 1440x900:
//   1  archive a card from its menu -> the card leaves the feed (control) and
//      the snackbar says "Archived" and offers Undo. CLE-77840 (owner, t1 topic
//      f20c6052: "cannot see this snackbar at all"): this first archive runs
//      with every NEW /_nuxt/ fetch answered 404 - a tab opened before the
//      last deploy, whose lazy chunks are gone - and the snackbar must still
//      show WITHOUT the page reloading (a lazy snackbar chunk 404s there and
//      chunk-reload.client.ts reloads the page instead)
//   2  Undo -> the card is back in the feed
//   3  keyboard: after archiving, Tab reaches the Undo button; Esc closes the
//      snackbar (and the card stays archived)
//   4  hover HOLDS it open past the 0.7 s window (control: left alone it
//      auto-dismisses)
//
// Run:
//   node tests/e2e/archive-undo.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/archive-undo.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'spl-1264-a'

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
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=archive-toast-text]')?.textContent.trim() || '')
const hasToast = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=archive-toast]')))

/** Open a middle card's ⋯ menu and return its item testids. */
async function openMenu(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}

/** Seed a channel and one own topic card, return its ids. */
const seed = (p) => p.evaluate(async ({ A }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send('SPL-1264 archive me', undefined, undefined, undefined, 1)
  return { one: { msg_id: one.msg_id, task_id: one.task_id } }
}, { A })

/** Click the Archive item in an already-open menu. */
const clickArchive = (p) => p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  /* warm a throwaway page: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  const seeded = await seed(p)
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 10000 })
  await sleep(400)

  /* ---- 1. archive from the menu: card leaves, snackbar offers Undo -------- */
  const menu = await openMenu(p, midCard(seeded.one.msg_id))
  ok('1 the card menu offers Archive', menu.includes('msg-menu-archive'), menu)
  /* the stale window must start on a quiet network: a fetch (a prefetch, a
     tab's chunk) still in flight from the steps above would 404 inside it and
     reload the page for a reason that is not the overlay (CI, run 36839510064) */
  await p.waitForNetworkIdle({ idleTime: 750, timeout: 15000 }).catch(() => {})
  /* CLE-77840: from here the build "was redeployed": new chunk fetches 404 */
  let deployed = true
  const goneChunks = []
  await p.setRequestInterception(true)
  const onRequest = (r) => {
    if (r.isInterceptResolutionHandled()) return
    if (deployed && new URL(r.url()).pathname.startsWith('/_nuxt/')) {
      goneChunks.push(new URL(r.url()).pathname + (goneChunks.length ? '' : ` (first; initiator ${r.initiator()?.type || '?'}${r.initiator()?.url ? ' ' + r.initiator().url : ''})`))
      return r.respond({ status: 404, contentType: 'text/plain', body: 'gone after a deploy' })
    }
    return r.continue()
  }
  p.on('request', onRequest)
  await p.evaluate(() => { window.__cle77840 = 'same page' })
  await clickArchive(p)
  const gone = await until(p, (sel) => !document.querySelector(sel), midCard(seeded.one.msg_id))
  ok('1 the archived card leaves the feed', gone)
  await p.waitForSelector('[data-testid=archive-toast]', { timeout: 5000 }).catch(() => {})
  const t1 = await toastText(p)
  ok('1 the snackbar says "Archived" and offers Undo', t1 === 'Archived' && Boolean(await p.$('[data-testid=archive-toast-undo]')), t1)
  ok('1 ... on a tab older than the last deploy, without fetching a chunk or reloading',
    t1 === 'Archived' && await p.evaluate(() => window.__cle77840 === 'same page').catch(() => false), goneChunks)
  deployed = false
  p.off('request', onRequest)
  await p.setRequestInterception(false)
  await shot(p, '1-archived')

  /* ---- 2. Undo brings the card back -------------------------------------- */
  await p.click('[data-testid=archive-toast-undo]')
  const back = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(seeded.one.msg_id))
  ok('2 Undo brings the card back to the feed', back)
  ok('2 the snackbar is gone after Undo', !(await hasToast(p)))
  await shot(p, '2-undone')

  /* ---- 3. keyboard: Tab reaches Undo, Esc closes ------------------------- */
  await openMenu(p, midCard(seeded.one.msg_id))
  await clickArchive(p)
  await p.waitForSelector('[data-testid=archive-toast]', { timeout: 5000 }).catch(() => {})
  /* Tab from the document until the Undo button holds focus (it is a plain
     button in the snackbar, so it is in the tab order). The snackbar HOLDS
     while focus is inside it, so the walk cannot race the 0.7 s dismiss. */
  let reached = false
  for (let i = 0; i < 40 && !reached; i++) {
    await p.keyboard.press('Tab')
    reached = await p.evaluate(() => document.activeElement?.getAttribute('data-testid') === 'archive-toast-undo')
  }
  ok('3 Tab reaches the Undo button', reached)
  await p.keyboard.press('Escape')
  const closed = await until(p, () => !document.querySelector('[data-testid=archive-toast]'), null, 3000)
  ok('3 Esc closes the snackbar', closed)
  ok('3 ... and the card stays archived (Esc is not Undo)', !(await p.$(midCard(seeded.one.msg_id))))

  /* ---- 4. hover HOLDS the snackbar past the 0.7 s window ----------------- */
  /* recreate a fresh card, archive it, and hover -> it must outlive 0.7 s */
  const seeded2 = await seed(p)
  await p.waitForSelector(midCard(seeded2.one.msg_id), { timeout: 10000 })
  await sleep(300)
  await openMenu(p, midCard(seeded2.one.msg_id))
  await clickArchive(p)
  await p.waitForSelector('[data-testid=archive-toast]', { timeout: 5000 }).catch(() => {})
  const box = await p.evaluate(() => {
    const e = document.querySelector('[data-testid=archive-toast]')
    if (!e) return null
    const r = e.getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  })
  if (box) await p.mouse.move(box.x, box.y)
  await sleep(1400) /* twice the 0.7 s window */
  ok('4 hover holds the snackbar open past 0.7 s', box && await hasToast(p))
  /* leave -> it dismisses on its own within another window */
  await p.mouse.move(10, 10)
  const auto = await until(p, () => !document.querySelector('[data-testid=archive-toast]'), null, 3000)
  ok('4 leaving lets it auto-dismiss', auto)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\narchive-undo: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
