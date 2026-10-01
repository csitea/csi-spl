// 714c7028 (SC-MERGE): drag a topic's opening card onto ANOTHER topic to
// MERGE the whole source topic into it - by the card's drag HANDLE, with the
// confirm dialog (message count from the hub), the Undo toast, and the
// refusal (a topic never merges into itself).
// Runs against the lde mock (no hub): mockMergeTopic mirrors the hub's
// refusals and the author-only gate (utils/move-mock.mjs).
//
// Desktop 1440x900, REAL mouse input (the drag is a pointer stream):
//   1  seed two own topics in #a; both cards have a handle
//   2  drag topic TWO onto topic ONE: only ONE lights up; the drop opens the
//      confirm naming a count; Cancel closes it and merges nothing
//   3  drag again and Confirm: the toast says "Merged", topic TWO leaves the
//      list; Undo brings it back
//   4  refusal: a topic dragged onto ITS OWN card never lights, opens no confirm
//   CLE-77840: step 2 runs on a tab "older than the last deploy" (every NEW
//   /_nuxt/ fetch answered 404): the confirm must still open, without the page
//   reloading (a lazy chunk 404s there and chunk-reload reloads the page
//   instead - the owner's "cannot see this snackbar at all"). Step 3 cannot:
//   the MOCK's merge is itself a lazy import (mock-merge.mjs), which a real
//   hub never needs; the toast's eagerness is pinned by
//   tests/unit/shell-eager-overlays.test.mjs and the live proof.
//
// Run:
//   node tests/e2e/merge-by-drag.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/merge-by-drag.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const OTHER_CARD = '66666666-6666-4666-8666-666666666666'
const A = 'merge-a'
const B = 'merge-b'

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
      const puppeteer = await import(pathToFileURL(require.resolve(spec)).href)
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

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const handleOf = (sel) => `${sel} [data-testid=move-handle]`
const centre = (p, sel) => p.evaluate((sel) => {
  const e = document.querySelector(sel)
  if (!e) return null
  const r = e.getBoundingClientRect()
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
}, sel)
const litCards = (p) => p.evaluate(() => [...document.querySelectorAll('article.msg.msg--move-over')].map((e) => e.getAttribute('data-msg-id')))
const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent.trim() || '')
const confirmOpen = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=merge-confirm-confirm]')))
const onScreen = (p, id) => p.evaluate((sel) => Boolean(document.querySelector(sel)), midCard(id))

/** Press on the source card's handle, walk to the target card, sampling the lit set, release. */
async function dragOnto(p, srcId, dstSel, { drop = true } = {}) {
  const from = await centre(p, handleOf(midCard(srcId)))
  const to = await centre(p, dstSel)
  await p.mouse.move(from.x, from.y)
  await p.mouse.down()
  let lit = []
  for (const pt of [{ x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 }, to, to]) {
    await p.mouse.move(pt.x, pt.y, { steps: 8 })
    await sleep(70)
    lit = await litCards(p)
  }
  if (drop) await p.mouse.up()
  else { await p.keyboard.press('Escape'); await p.mouse.up() }
  await sleep(200)
  return lit
}

const seed = (p) => p.evaluate(async ({ A, B }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(B)
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send('714c7028 topic one', undefined, undefined, undefined, 1)
  await new Promise((r) => setTimeout(r, 50))
  const two = await ch.send('714c7028 topic two', undefined, undefined, undefined, 1)
  await ch.send('714c7028 a reply on two', two.task_id, undefined, undefined, 0)
  return { one: { msg_id: one.msg_id, task_id: one.task_id }, two: { msg_id: two.msg_id, task_id: two.task_id } }
}, { A, B })

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector(midCard(OTHER_CARD), { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* ---- 1. seed two own topics ------------------------------------------- */
  const s = await seed(p)
  await p.waitForSelector(midCard(s.two.msg_id), { timeout: 10000 })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  ok('1 both own cards have a drag handle', await p.evaluate((ids) => ids.every((id) => document.querySelector(`.spool-main article.msg[data-msg-id="${id}"] [data-testid=move-handle]`)), [s.one.msg_id, s.two.msg_id]))

  /* CLE-77840: from here the build "was redeployed": new chunk fetches 404 */
  const goneChunks = []
  await p.setRequestInterception(true)
  const onRequest = (r) => {
    if (r.isInterceptResolutionHandled()) return
    if (new URL(r.url()).pathname.startsWith('/_nuxt/')) {
      goneChunks.push(new URL(r.url()).pathname)
      return r.respond({ status: 404, contentType: 'text/plain', body: 'gone after a deploy' })
    }
    return r.continue()
  }
  p.on('request', onRequest)
  await p.evaluate(() => { window.__cle77840 = 'same page' })

  /* ---- 2. drag TWO onto ONE, then Cancel -------------------------------- */
  const litOnOne = await dragOnto(p, s.two.msg_id, midCard(s.one.msg_id), { drop: true })
  ok('2 only the target topic lights up while dragging a topic', litOnOne.length === 1 && litOnOne[0] === s.one.msg_id, litOnOne)
  const asked = await confirmOpen(p)
  ok('2 the drop opens the merge confirm', asked)
  const count = await p.evaluate(() => document.querySelector('[data-testid=merge-confirm-text]')?.getAttribute('data-count') || '')
  ok('2 the confirm names a message count (read from the hub)', Number(count) >= 1, { count })
  await shot(p, '2-confirm')
  await p.evaluate(() => document.querySelector('[data-testid=merge-confirm-cancel]')?.click())
  await sleep(200)
  ok('2 Cancel closes it and merges nothing (topic two still on screen)', !(await confirmOpen(p)) && (await onScreen(p, s.two.msg_id)))
  ok('2 ... on a tab older than the last deploy, without fetching a chunk or reloading',
    asked && await p.evaluate(() => window.__cle77840 === 'same page').catch(() => false), goneChunks)
  p.off('request', onRequest)
  await p.setRequestInterception(false)

  /* ---- 3. drag again and Confirm; then Undo ----------------------------- */
  await dragOnto(p, s.two.msg_id, midCard(s.one.msg_id), { drop: true })
  ok('3 the confirm is open again', await confirmOpen(p))
  await p.evaluate(() => document.querySelector('[data-testid=merge-confirm-confirm]')?.click())
  await sleep(500)
  const merged = await toastText(p)
  ok('3 the toast reports the merge', /merge/i.test(merged), { merged })
  ok('3 the merged-away source topic leaves the list', !(await onScreen(p, s.two.msg_id)))
  await shot(p, '3-merged')
  const undo = await p.evaluate(() => { const b = document.querySelector('[data-testid=move-toast-undo]'); if (b) { b.click(); return true } return false })
  await sleep(600)
  ok('3 Undo restores the source topic', undo && (await onScreen(p, s.two.msg_id)))

  /* ---- 4. refusal: a topic never merges into itself --------------------- */
  const litSelf = await dragOnto(p, s.one.msg_id, midCard(s.one.msg_id), { drop: true })
  ok('4 a topic dragged onto its own card lights nothing and opens no confirm', litSelf.length === 0 && !(await confirmOpen(p)), litSelf)

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmerge-by-drag: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
