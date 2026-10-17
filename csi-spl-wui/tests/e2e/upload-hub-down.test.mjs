// SPL-2285 (owner HUM-10, t1 f1ccedf9, 2026-10-17 17:18Z, prd hub outage):
// "trying to upload this pic ... 10 times", "does not work". The upload never
// reached the hub and the composer said nothing, so he tried again.
//
// On the mock bundle the e2e hook `spool.mock.upload-fail` makes the mock's
// POST /v1/files fail as the hub's would (utils/upload-fail.mjs):
//   down -> the connection is refused (the browser's "Failed to fetch")
//   503  -> the hub answers 503 unavailable
// Each must show the reason next to the composer within a few seconds, keep
// the picture in the box, and offer Retry; Retry with the hub back sends it.
// With no hook the upload sends exactly as before.
// CONTROL: on the pre-fix build 'down' and '503' are red (the hook does not
// exist there, so the mock "uploads" and no message is shown).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e upload-hub-down
//   SHOT_DIR=<dir> also saves the message as desktop and phone .png
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { deflateSync } from 'node:zlib'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const HOOK = 'spool.mock.upload-fail'
/** "within a few seconds" (brief SPL-2285): the message must be up by then */
const SAY_SO_MS = 5000
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** a small real PNG (24x24, one colour), so the chip shows a picture as the owner's did */
function png(w = 24, h = 24) {
  const crc = (buf) => {
    let c = ~0
    for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)) }
    return ~c >>> 0
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
    const td = Buffer.concat([Buffer.from(type), data])
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td))
    return Buffer.concat([len, td, c])
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(w * 3, Buffer.from([0x2a, 0x7a, 0xd8]))])
  const raw = Buffer.concat(Array.from({ length: h }, () => row))
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}
const FIXTURE = join(tmpdir(), `spl2285-pic-${process.pid}.png`)
writeFileSync(FIXTURE, png())

const rows = (p) => p.evaluate(() =>
  [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].map((el) => el.getAttribute('data-msg-id')))
const chips = (p) => p.$eval('form.omnibox--global', (f) => f.querySelectorAll('.file-chips li').length)
const notice = (p) => p.evaluate(() => {
  const n = document.querySelector('[data-test=omnibox-send-error]')
  return n ? { text: n.querySelector('[data-test=omnibox-send-error-message]')?.textContent?.trim() || '', retry: Boolean(n.querySelector('[data-test=omnibox-send-retry]')) } : null
})

async function openChannel(browser, vp) {
  const p = await browser.newPage()
  if (vp) await p.setViewport(vp)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.omnibox--global [data-testid=attach-input]', { timeout: NAV_TIMEOUT })
  await sleep(500)
  return { p, errors }
}

async function attachAndSend(p) {
  const input = await p.$('form.omnibox--global [data-testid=attach-input]')
  await input.uploadFile(FIXTURE)
  await sleep(400)
  await p.click('form.omnibox--global [data-testid=send]')
}

async function waitFor(fn, ms) {
  const t0 = Date.now()
  for (;;) {
    const v = await fn()
    if (v || Date.now() - t0 > ms) return { v, ms: Date.now() - t0 }
    await sleep(100)
  }
}

async function failCase(browser, mode, want, vp) {
  const tag = `${vp ? 'phone' : 'desktop'} ${mode}`
  const { p, errors } = await openChannel(browser, vp)
  await p.evaluate((k, v) => localStorage.setItem(k, v), HOOK, mode)
  const before = new Set(await rows(p))
  await attachAndSend(p)
  const { v: n, ms } = await waitFor(() => notice(p), SAY_SO_MS)
  ok(`${tag}: the composer says why, within ${SAY_SO_MS} ms`, Boolean(n) && want.test(n.text), { ms, n })
  ok(`${tag}: a Retry is offered`, Boolean(n && n.retry))
  ok(`${tag}: the picture is still in the box`, (await chips(p)) === 1)
  ok(`${tag}: nothing was posted`, (await rows(p)).every((id) => before.has(id)))
  if (SHOT_DIR && n) {
    const file = join(SHOT_DIR, `spl2285-upload-${mode}-${vp ? 'phone' : 'desktop'}.png`)
    await p.screenshot({ path: file })
    console.log(`  shot ${file}`)
  }
  /* the hub is back: Retry sends the same picture */
  await p.evaluate((k) => localStorage.removeItem(k), HOOK)
  await p.click('[data-test=omnibox-send-retry]')
  const { v: sent } = await waitFor(async () => (await rows(p)).some((id) => !before.has(id)), 5000)
  ok(`${tag}: Retry with the hub back sends it and clears the message`, Boolean(sent) && !(await notice(p)), { sent })
  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

async function okCase(browser, vp) {
  const tag = `${vp ? 'phone' : 'desktop'} working upload`
  const { p, errors } = await openChannel(browser, vp)
  const before = new Set(await rows(p))
  await attachAndSend(p)
  const { v: sent } = await waitFor(async () => (await rows(p)).some((id) => !before.has(id)), 5000)
  ok(`${tag}: sends as before`, Boolean(sent))
  ok(`${tag}: no message, box cleared`, !(await notice(p)) && (await chips(p)) === 0)
  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DOWN = /connection to the hub is down/i
const REFUSED = /hub refused the file \(503 unavailable\)/i
const server = await startServer()
const browser = await launch()
try {
  await (await openChannel(browser)).p.close() // warm chunks
  await okCase(browser)
  await failCase(browser, 'down', DOWN)
  await failCase(browser, '503', REFUSED)
  await okCase(browser, PHONE)
  await failCase(browser, 'down', DOWN, PHONE)
  await failCase(browser, '503', REFUSED, PHONE)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
