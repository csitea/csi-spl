// CLE-77786 (owner, prd t1 topic b6a7db19): deleting a card, then Tab to the
// Delete button and Enter, did nothing. The topic-delete confirm disabled its
// Delete button while the reply count loaded from the hub, and a disabled
// button drops out of UiDialog's focus trap - so a keyboard user could neither
// Tab to it nor activate it with Enter / Space.
//
// This drives the confirm from the keyboard in a real browser: Cancel is
// focused on open, one Tab reaches Delete, and Enter / Space delete the card.
// The message confirm (a thread row's Delete) is covered too.
//
// CONTROL: the topic checks use the mock's `spool-mock-topic-size-delay-ms`
// hook to replay the prd latency window. On the build before this fix the
// Delete button is disabled through that window, so `reached the Delete button`
// and `deleted` both fail. The message confirm has no such gate and passes on
// either build.
//
// Run:
//   node tests/e2e/delete-confirm-kbd.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/delete-confirm-kbd.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the lde mock #lobby root, from HUM-1@box-wui: our own, so both deletes are offered */
const OWN_MSG = '11111111-1111-4111-8111-111111111111'
const LOBBY_TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
/* long enough that the Tab + activate below all land inside the count's load */
const DELAY_MS = 2000

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
        headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click(); return true
}, sel)
const activeTid = (p) => p.evaluate(() => document.activeElement?.getAttribute('data-testid') || '')
const dialogOpen = (p) => p.evaluate(() => !!document.querySelector('[data-testid=ui-dialog]'))
const cardThere = (p, id) => p.evaluate((id) => !!document.querySelector(`article.msg[data-msg-id="${id}"]`), id)

async function waitDialog(p, open) {
  for (let i = 0; i < 50; i++) { if ((await dialogOpen(p)) === open) return true; await sleep(100) }
  return (await dialogOpen(p)) === open
}
/* Tab (from Cancel, the autofocus) until the Delete button holds the focus. A
   disabled Delete is skipped by the focus trap, so this never finds it. */
async function tabToConfirm(p, testid, max = 5) {
  for (let i = 0; i < max; i++) {
    if ((await activeTid(p)) === testid) return true
    await p.keyboard.press('Tab'); await sleep(80)
  }
  return (await activeTid(p)) === testid
}

async function freshLobby(p) {
  await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"]`, { timeout: NAV_TIMEOUT })
  await sleep(500)
}

const server = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  /* replay prd latency for the count the topic confirm reads */
  await page.evaluateOnNewDocument((ms) => { try { localStorage.setItem('spool-mock-topic-size-delay-ms', String(ms)) } catch {} }, DELAY_MS)

  /* ---- the topic confirm (a middle-pane card), during the count's load ---- */
  for (const key of ['Enter', 'Space']) {
    await freshLobby(page)
    await click(page, `article.msg[data-msg-id="${OWN_MSG}"] [data-testid=msg-menu-btn]`)
    await sleep(300)
    const offered = await click(page, '[data-testid=msg-menu-delete-topic]')
    await waitDialog(page, true)
    ok(`topic ${key}: Cancel is focused on open`, /cancel/.test(await activeTid(page)))
    /* act inside the load window: the count is still on its way */
    const reached = await tabToConfirm(page, 'topic-delete-confirm')
    ok(`topic ${key}: one Tab reaches the Delete button while the count loads`, offered && reached, { offered, reached })
    await page.keyboard.press(key)
    await waitDialog(page, false)
    await sleep(400)
    const deleted = !(await dialogOpen(page)) && !(await cardThere(page, OWN_MSG))
    ok(`topic ${key}: ${key} on the focused Delete button deletes the card`, deleted, { deleted })
  }

  /* ---- the message confirm (a thread row's Delete): no load gate ---- */
  for (const key of ['Enter', 'Space']) {
    await page.goto(`${server.base}/t/${LOBBY_TASK}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await page.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"]`, { timeout: NAV_TIMEOUT }).catch(() => {})
    await sleep(500)
    await click(page, `article.msg[data-msg-id="${OWN_MSG}"] [data-testid=msg-menu-btn]`)
    await sleep(300)
    const offered = await click(page, '[data-testid=msg-menu-delete]')
    await waitDialog(page, true)
    const reached = await tabToConfirm(page, 'msg-delete-confirm')
    ok(`message ${key}: one Tab reaches the Delete button`, offered && reached, { offered, reached })
    await page.keyboard.press(key)
    await waitDialog(page, false)
    await sleep(400)
    const deleted = !(await dialogOpen(page)) && !(await cardThere(page, OWN_MSG))
    ok(`message ${key}: ${key} on the focused Delete button deletes the message`, deleted, { deleted })
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `delete-confirm-kbd: ${results.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
