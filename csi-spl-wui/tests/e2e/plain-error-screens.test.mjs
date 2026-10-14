// SPL-1839 (owner HUM-10, t1 659e3927, msg 4de3b04e): "the error msgs could
// be simple error msging explainning to the regular user what happens ...
// and only when the debug pane is selected to present the technical jibr".
//
// Per screen, at 1440 and 390, Debug pane off then on:
//   lobby, channel feed, topic pane (/t/<id>), live topic pane (#lobby's
//   right pane): a failed read shows ONE plain sentence + Try again; no red
//   box, no status, no ERR id; with the Debug pane on the technical line
//   (HTTP status, raw message, ERR id) shows under the same sentence; Try
//   again reads again and the error goes.
//   under the error no list also says it is empty ("No messages yet.").
//   the top snackbar: a page error shows the plain sentence, not its text or
//   id; with the Debug pane on, both.
//   the top-bar send error: its own plain line, the ERR reference only with
//   the Debug pane on.
//
// The mock reads are failed with the mock-only hook localStorage
// `spool.mock.read-fault` (utils/plain-error.mjs), so the real store and
// pane paths run. Real browser, mock tenant.
//
// Run:
//   node tests/e2e/plain-error-screens.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/plain-error-screens.test.mjs   # what CI does
//   SHOT_DIR=<dir> ... also writes the screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const LOBBY = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const LOAD = 'This could not be loaded. Try again in a moment.'
const OTHER = 'Something did not work. Try again in a moment.'
const FAULT = { status: 500, token: 'internal', detail: 'view query failed' }
/* what a reader without the Debug pane must never see */
const TECH_WORDS = /\b(500|HTTP|ERR-|spool|internal)\b/
/* c-002 send-back (msg 5d6cbb5a): after a failed read no list may also say it is empty */
const EMPTY_LINES = ['No messages yet.', 'No messages match.', 'Empty topic.', 'No replies yet']
const NOBODY_TASK = 'e1170000-0000-4000-8000-000000000002'
const EXTRA = [
  /* the viewer's own channel-less root with no addressee: a reply is refused (dm-reply-topic-to) */
  { v: 1, msg_id: 'e1170001-0000-4000-8000-000000000002', task_id: NOBODY_TASK, ts: '2026-09-18T10:11:00Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'ALL-0', to_box: 'box-wui', kind: 'note', body: 'a line for nobody',
    files: [], channel: null, parent_task_id: null },
]

/* screen -> where it is, which read fails, its notice */
const SCREENS = [
  { name: 'lobby', path: '/lobby', only: 'topic', test: 'lobby-error' },
  { name: 'channel', path: '/channel/alerts', only: 'list', test: 'channel-error' },
  { name: 'topic', path: `/t/${LOBBY}`, only: 'topic', test: 'topic-error' },
  { name: 'live-pane', path: '/lobby', only: 'topic', test: 'live-pane-error', late: true },
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The Debug pane on, as the hub's session claim would say it. */
const debugOn = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.claims = { ...(s.claims || {}), hum: 'HUM-1', diagnostics_enabled: true }
  s.state = 'in'
  return true
})

const notice = (p, id) => p.evaluate((id) => {
  const box = document.querySelector(`[data-test=${id}]`)
  const text = (sel) => (document.querySelector(sel)?.textContent || '').trim()
  const empty = [...document.querySelectorAll('p.empty, .muted')]
    .filter((e) => e.getClientRects().length).map((e) => (e.textContent || '').trim())
  return {
    empty,
    shown: Boolean(box && box.getClientRects().length),
    msg: text(`[data-test=${id}-message]`),
    all: (box?.textContent || '').trim(),
    tech: text(`[data-test=${id}-tech]`),
    retry: Boolean(document.querySelector(`[data-test=${id}-retry]`)),
    redBox: Boolean(document.querySelector('.error-notice')),
  }
}, id)

const setFault = (p, f) => p.evaluate((f) => {
  if (f) localStorage.setItem('spool.mock.read-fault', f)
  else localStorage.removeItem('spool.mock.read-fault')
}, f ? JSON.stringify(f) : '')

async function shot(p, name) {
  if (SHOT_DIR) await p.screenshot({ path: `${SHOT_DIR}/${name}.png` })
}

/** Opens a lobby topic card in the right pane (LiveTopicPane). */
async function openPaneTopic(p) {
  return p.evaluate(() => {
    const card = document.querySelector('.feed-col article.msg[data-msg-id]')
    const open = card?.querySelector('[data-test=topic-open], [data-testid=topic-open], .msg-replies, .reply-count')
    ;(open || card)?.click()
    return Boolean(card)
  })
}

const srv = await startServer()
const browser = await launch()
try {
  for (const [width, height, mobile] of [[1440, 900, false], [390, 800, true]]) {
    for (const s of SCREENS) {
      const tag = `${width} ${s.name}`
      const page = await browser.newPage()
      page.setDefaultNavigationTimeout(NAV_TIMEOUT)
      await page.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
      if (!s.late) {
        await page.evaluateOnNewDocument((f) => {
          try { localStorage.setItem('spool.mock.read-fault', f) } catch { /* the check below fails */ }
        }, JSON.stringify({ ...FAULT, only: s.only }))
      }
      await page.goto(`${srv.base}${s.path}`, { waitUntil: 'domcontentloaded' })
      await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
      if (s.late) {
        await page.waitForSelector('.feed-col article.msg[data-msg-id]', { timeout: NAV_TIMEOUT }).catch(() => null)
        await setFault(page, { ...FAULT, only: s.only })
        ok(`${tag}: a lobby topic opens in the right pane`, await openPaneTopic(page))
      }
      const shown = Boolean(await page.waitForSelector(`[data-test=${s.test}-message]`, { timeout: 15000 }).catch(() => null))
      ok(`${tag}: the notice is shown`, shown)
      await page.waitForFunction((id, want) => document.querySelector(`[data-test=${id}-message]`)?.textContent?.includes(want),
        { timeout: 10000 }, s.test, LOAD).catch(() => null)
      await sleep(400)
      let n = await notice(page, s.test)
      ok(`${tag}: one plain sentence`, n.msg === LOAD, n.msg)
      ok(`${tag}: no status, id or raw message without the Debug pane`, !TECH_WORDS.test(n.all) && !n.tech, n.all)
      ok(`${tag}: no red error box`, !n.redBox)
      ok(`${tag}: a Try again button`, n.retry)
      ok(`${tag}: no empty-list line under the error`, !n.empty.some((e) => EMPTY_LINES.some((w) => e.includes(w))), n.empty)
      if (shown) await shot(page, `plain-${s.name}-${width}-after`)

      const on = await debugOn(page)
      const techShown = on && Boolean(await page.waitForSelector(`[data-test=${s.test}-tech]`, { timeout: 10000 }).catch(() => null))
      n = await notice(page, s.test)
      ok(`${tag}: the Debug pane shows the technical details`,
        techShown && ['HTTP 500', 'spool 500 internal', 'ERR-'].every((w) => n.tech.includes(w)), n.tech)
      ok(`${tag}: the sentence stays the same with the Debug pane on`, n.msg === LOAD, n.msg)
      if (techShown) await shot(page, `plain-${s.name}-${width}-after-debug`)

      await setFault(page, null)
      await page.click(`[data-test=${s.test}-retry]`).catch(() => null)
      const cleared = await page.waitForFunction((id) => !document.querySelector(`[data-test=${id}]`), { timeout: 15000 }, s.test)
        .then(() => true).catch(() => false)
      ok(`${tag}: Try again reads again and the error goes`, cleared)
      await page.close()
    }

    /* the top snackbar */
    {
      const tag = `${width} snackbar`
      const page = await browser.newPage()
      await page.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
      await page.goto(`${srv.base}/lobby`, { waitUntil: 'domcontentloaded' })
      await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
      await sleep(800)
      const raise = () => page.evaluate(() => {
        const s = document.createElement('script')
        s.src = URL.createObjectURL(new Blob(["setTimeout(() => { throw new Error('spl1839 e2e: upload failed') }, 0)"], { type: 'text/javascript' }))
        document.head.appendChild(s)
      })
      await raise()
      const up = Boolean(await page.waitForSelector('[data-test=error-snackbar-text-message]', { timeout: 8000 }).catch(() => null))
      await page.waitForFunction((w) => document.querySelector('[data-test=error-snackbar-text-message]')?.textContent?.includes(w),
        { timeout: 8000 }, OTHER).catch(() => null)
      const row = () => page.evaluate(() => ({
        msg: (document.querySelector('[data-test=error-snackbar-text-message]')?.textContent || '').trim(),
        all: (document.querySelector('[data-test=error-snackbar-item]')?.textContent || '').trim(),
        tech: (document.querySelector('[data-test=error-snackbar-text-tech]')?.textContent || '').trim(),
      }))
      let r = await row()
      ok(`${tag}: an error raises a row with the plain sentence`, up && r.msg === OTHER, r.msg)
      ok(`${tag}: no raw text or id without the Debug pane`, !/upload failed|ERR-/.test(r.all) && !r.tech, r.all)
      if (up) await shot(page, `plain-snackbar-${width}-after`)
      await debugOn(page)
      const tech = Boolean(await page.waitForSelector('[data-test=error-snackbar-text-tech]', { timeout: 5000 }).catch(() => null))
      r = await row()
      ok(`${tag}: the Debug pane shows its text and id`, tech && /upload failed/.test(r.tech) && /ERR-/.test(r.tech), r.tech)
      if (tech) await shot(page, `plain-snackbar-${width}-after-debug`)
      await page.close()
    }

    /* the top-bar send error */
    {
      const tag = `${width} send`
      const page = await browser.newPage()
      await page.evaluateOnNewDocument((extra) => {
        try { localStorage.setItem('spool.mock.extra-messages', extra) } catch { /* about:blank */ }
      }, JSON.stringify(EXTRA))
      await page.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
      await page.goto(`${srv.base}/t/${NOBODY_TASK}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await page.waitForSelector(`article.msg[data-msg-id="${EXTRA[0].msg_id}"]`, { timeout: NAV_TIMEOUT }).catch(() => null)
      const ta = 'form.composer.omnibox--global textarea'
      const typed = Boolean(await page.waitForSelector(ta, { timeout: NAV_TIMEOUT }).catch(() => null))
      if (typed) {
        await page.focus(ta)
        await page.type(ta, 'spl1839 reply for nobody')
        await sleep(150)
        await page.click('form.composer.omnibox--global [data-testid=send]').catch(() => null)
      }
      const shown = Boolean(await page.waitForSelector('[data-test=omnibox-send-error-message]', { timeout: 8000 }).catch(() => null))
      await sleep(400)
      const ref = () => page.evaluate(() => ({
        msg: (document.querySelector('[data-test=omnibox-send-error-message]')?.textContent || '').trim(),
        ref: (document.querySelector('[data-test=omnibox-send-error-ref]')?.textContent || '').trim(),
      }))
      let r = await ref()
      ok(`${tag}: a refused send says its plain line`, shown && r.msg.startsWith('Not sent'), r.msg)
      ok(`${tag}: no error reference without the Debug pane`, !r.ref, r.ref)
      if (shown) await shot(page, `plain-send-${width}-after`)
      await debugOn(page)
      await page.waitForSelector('[data-test=omnibox-send-error-ref]', { timeout: 5000 }).catch(() => null)
      r = await ref()
      ok(`${tag}: the Debug pane shows the error reference`, /^ERR-/.test(r.ref), r.ref)
      if (shown) await shot(page, `plain-send-${width}-after-debug`)
      await page.close()
    }
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nplain-error-screens: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
