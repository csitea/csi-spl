// CLE-77840 (owner, t1 topic bc1fd547): "one should be able to delete any
// msg or topic level msg by cycling with the keyboard and when the msg is
// selected pressing the delete button, the same do you want to delete should
// occur only on the is_parent=1 msgs for the others they should be just
// deleted, but a small undo snackbar at the end should appear similarly on
// how it does for the archiving".
//
// Runs against the lde mock (no hub). Desktop 1440x900, a topic with two
// replies open in the right pane:
//   1  ArrowDown / ArrowUp on a focused (= selected) reply walk the feed
//   2  Delete on a reply: NO dialog, the reply leaves the pane at once, the
//      "Deleted · Undo" snackbar shows - with every NEW /_nuxt/ fetch answered
//      404 (a tab older than the last deploy) and without a reload
//   3  Undo: the reply is back, selected again (CLE-77871), and the hub
//      (mock) never deleted it
//   4  Delete again and let the snackbar close: the DELETE is sent (the reply
//      stays gone after the topic is read again)
//   5  Delete on the topic-level card (is_parent 1), reached with a click: the
//      existing "Delete this topic?" confirm, again on a stale tab; Esc closes
//      it, nothing deleted
//   6  CONTROL: Delete typed in the composer deletes nothing
//
// Run:
//   node tests/e2e/kbd-delete-undo.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/kbd-delete-undo.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'cle-77840-kbd'

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
const paneRow = (id) => `.topic article.msg[data-msg-id="${id}"]`
const focused = (p) => p.evaluate(() => document.activeElement?.getAttribute('data-msg-id') || '')
const dialogOpen = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=ui-dialog]')))
const hasToast = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=delete-toast]')))
const focusRow = (p, sel) => p.evaluate((sel) => { const e = document.querySelector(sel); e?.focus(); return document.activeElement === e }, sel)

/** Seed a channel, one own topic card and two replies; open the topic. */
const seed = (p) => p.evaluate(async ({ A }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const top = await ch.send('CLE-77840 topic', undefined, undefined, undefined, 1)
  const r1 = await ch.send('CLE-77840 reply one', top.task_id, undefined, undefined, 0)
  await new Promise((r) => setTimeout(r, 50))
  const r2 = await ch.send('CLE-77840 reply two', top.task_id, undefined, undefined, 0)
  return { top: { msg_id: top.msg_id, task_id: top.task_id }, r1: r1.msg_id, r2: r2.msg_id }
}, { A })

/** From here the build "was redeployed": every new /_nuxt/ fetch 404s. */
async function staleTab(p) {
  const gone = []
  await p.setRequestInterception(true)
  const on = (r) => {
    if (r.isInterceptResolutionHandled()) return
    if (new URL(r.url()).pathname.startsWith('/_nuxt/')) {
      gone.push(new URL(r.url()).pathname)
      return r.respond({ status: 404, contentType: 'text/plain', body: 'gone after a deploy' })
    }
    return r.continue()
  }
  p.on('request', on)
  await p.evaluate(() => { window.__cle77840 = 'same page' })
  return {
    gone,
    samePage: () => p.evaluate(() => window.__cle77840 === 'same page').catch(() => false),
    async off() { p.off('request', on); await p.setRequestInterception(false) },
  }
}

/* The page's idle warm-ups (useChannelOrder loads its edit chunk 3 s after
   mount) are not the Delete path: let them land before staleTab, or one that
   fires inside its window 404s and chunk-reload reloads the tab (wf10 run
   37579375848). Quiet = no /_nuxt/ request for `ms`. */
async function chunksQuiet(p, ms = 3500, max = 20000) {
  let last = Date.now()
  const on = (r) => { if (new URL(r.url()).pathname.startsWith('/_nuxt/')) last = Date.now() }
  p.on('request', on)
  const end = Date.now() + max
  while (Date.now() - last < ms && Date.now() < end) await sleep(200)
  p.off('request', on)
}

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

  const s = await seed(p)
  await p.waitForSelector(midCard(s.top.msg_id), { timeout: 10000 })
  await p.evaluate((sel) => document.querySelector(sel)?.click(), midCard(s.top.msg_id))
  await p.waitForSelector(paneRow(s.r2), { timeout: 10000 })
  await sleep(400)

  /* ---- 1. arrows walk the selection ------------------------------------- */
  const order = await p.evaluate((ids) => {
    const rows = [...document.querySelectorAll('.topic article.msg')].map((e) => e.getAttribute('data-msg-id'))
    return ids.map((id) => rows.indexOf(id))
  }, [s.r1, s.r2])
  const [first, second] = order[0] < order[1] ? [s.r1, s.r2] : [s.r2, s.r1]
  await focusRow(p, paneRow(first))
  await p.keyboard.press('ArrowDown')
  const down = await focused(p)
  await p.keyboard.press('ArrowUp')
  const up = await focused(p)
  ok('1 ArrowDown selects the next message, ArrowUp the previous', down === second && up === first, { down, up })

  /* ---- 2. Delete on a reply: no dialog, gone at once, snackbar ---------- */
  await focusRow(p, paneRow(s.r2))
  await chunksQuiet(p)
  const stale = await staleTab(p)
  await p.keyboard.press('Delete')
  await p.waitForSelector('[data-testid=delete-toast]', { timeout: 5000 }).catch(() => {})
  /* the pointer goes to it, as a user reaching for Undo does: the hover HOLDS
     it past its 0.7 s (UndoSnackbar), so the checks below cannot race it */
  const tb = await p.evaluate(() => { const r = document.querySelector('[data-testid=delete-toast]')?.getBoundingClientRect(); return r ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : null })
  if (tb) await p.mouse.move(tb.x, tb.y)
  const text = await p.evaluate(() => document.querySelector('[data-testid=delete-toast-text]')?.textContent.trim() || '')
  ok('2 no "do you want to delete" dialog for a reply', !(await dialogOpen(p)))
  /* "at once" = before the 0.7 s snackbar is over; polled, because a slow CI
     runner can paint the removal a frame after the snackbar (wf11 36848069311) */
  ok('2 the reply leaves the pane at once', await until(p, (sel) => !document.querySelector(sel), paneRow(s.r2), 2000))
  ok('2 the snackbar says "Deleted" and offers Undo', text === 'Deleted' && Boolean(await p.$('[data-testid=delete-toast-undo]')), text)
  ok('2 ... on a tab older than the last deploy, without fetching a chunk or reloading', text === 'Deleted' && await stale.samePage(), stale.gone)
  await stale.off()
  await shot(p, '2-deleted')

  /* ---- 3. Undo brings it back ------------------------------------------- */
  await p.click('[data-testid=delete-toast-undo]')
  const back = await until(p, (sel) => Boolean(document.querySelector(sel)), paneRow(s.r2))
  ok('3 Undo brings the reply back', back)
  ok('3 the snackbar is gone after Undo', await until(p, () => !document.querySelector('[data-testid=delete-toast]'), null, 3000))
  /* CLE-77871: the reply that came back is selected (focused) again, as before Delete */
  ok('3 the reply that came back is selected again',
    await until(p, (id) => document.activeElement?.matches?.(`.topic article.msg[data-msg-id="${id}"]`), s.r2, 4000))
  await shot(p, '3-undone')

  /* ---- 4. let it close: the DELETE is sent ------------------------------ */
  await focusRow(p, paneRow(s.r2))
  await p.mouse.move(5, 5)
  await p.keyboard.press('Delete')
  await p.waitForSelector('[data-testid=delete-toast]', { timeout: 5000 }).catch(() => {})
  const closed = await until(p, () => !document.querySelector('[data-testid=delete-toast]'), null, 4000)
  ok('4 left alone, the snackbar closes on its own', closed)
  await sleep(300)
  await p.evaluate(async () => {
    const app = document.querySelector('#__nuxt').__vue_app__
    await app.config.globalProperties.$pinia._s.get('channel').catchUp().catch(() => {})
  })
  await sleep(500)
  ok('4 ... and the reply stays deleted after the feeds are read again', !(await p.$(paneRow(s.r2))))
  ok('4 control: the other reply is untouched', Boolean(await p.$(paneRow(s.r1))))

  /* ---- 5. Delete on the topic-level card asks first --------------------- */
  /* The reader goes to the card with a click, as a user does: step 4's Delete
     started holdPanel (HUM-10) on the topic pane, which puts a focus that
     leaves it back on a reply every 50 ms for 4 s and ends only on a key or a
     pointerdown. A bare focus() raced that tick and lost in CI, so Delete hit
     the reply (wf10 37238838654). Waiting past one tick keeps the race out. */
  await p.click(midCard(s.top.msg_id))
  await focusRow(p, midCard(s.top.msg_id))
  await sleep(150)
  ok('5 the topic-level card holds the focus', (await focused(p)) === s.top.msg_id, await focused(p))
  const stale2 = await staleTab(p)
  await p.keyboard.press('Delete')
  const asked = await until(p, () => Boolean(document.querySelector('[data-testid=topic-delete-body]')), null, 5000)
  ok('5 Delete on an is_parent=1 card shows the "Delete this topic?" confirm', asked)
  ok('5 ... on a stale tab too, without a reload', asked && await stale2.samePage(), stale2.gone)
  ok('5 ... and no Deleted snackbar', !(await hasToast(p)))
  await shot(p, '5-topic-confirm')
  await p.keyboard.press('Escape')
  await until(p, () => !document.querySelector('[data-testid=ui-dialog]'), null, 3000)
  ok('5 Esc closes it and the card stays', Boolean(await p.$(midCard(s.top.msg_id))))
  await stale2.off()

  /* ---- 6. CONTROL: Delete in the composer deletes nothing --------------- */
  const composer = await p.$('.composer textarea')
  if (composer) {
    await composer.click()
    await p.keyboard.type('abc')
    await p.keyboard.press('Backspace')
    await p.keyboard.press('Delete')
    await sleep(400)
  }
  ok('6 control: Delete / Backspace typed in the composer delete no message', Boolean(composer) && Boolean(await p.$(paneRow(s.r1))) && !(await hasToast(p)) && !(await dialogOpen(p)))

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nkbd-delete-undo: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
