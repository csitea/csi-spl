// t1 ccaee528 (owner HUM-10: "the users should be able to change their own
// picture"): the account menu's "Change picture" opens a file picker, the
// picked image is PUT to the hub's /api/v1/auth/avatar and shows at once in
// the avatar; "Remove picture" DELETEs it. Proved in Chrome at 1440 and
// 390 px against the mock bundle; the hub's three routes are answered here.
//
// CONTROLS (each next to a passing case):
//   - with no picture (GET 404) there is no "Remove picture" item;
//   - a gif is refused before any request (no PUT), with a message;
//   - the hub's 413 is shown as "too big" and the avatar is unchanged;
//   - a reload after the upload still fetches it (dev, 2026-10-07: the
//     pre-upload 404 was remembered in localStorage, so after a reload the
//     menu had no picture and no "Remove picture").
//
// SHOT_DIR=<dir> also writes the menu and the changed picture as PNGs.
//
// Run:
//   pnpm run test:e2e own-picture
//   BASE_URL=<generated bundle> pnpm run test:e2e own-picture     # what CI does
import { createRequire } from 'node:module'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { deflateSync, crc32 } from 'node:zlib'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const SHOT_DIR = process.env.SHOT_DIR || ''
const results = []
function check(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** A 64 x 64 png: four coloured quarters, so a screenshot shows it changed. */
function png() {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4)
    len.writeUInt32BE(data.length)
    const td = Buffer.concat([Buffer.from(type), data])
    const crc = Buffer.alloc(4)
    crc.writeUInt32BE(crc32(td) >>> 0)
    return Buffer.concat([len, td, crc])
  }
  const n = 64
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(n, 0)
  ihdr.writeUInt32BE(n, 4)
  ihdr.set([8, 2, 0, 0, 0], 8)
  const rows = []
  for (let y = 0; y < n; y++) {
    const row = [0]
    for (let x = 0; x < n; x++) {
      const q = (y < n / 2 ? 0 : 2) + (x < n / 2 ? 0 : 1)
      row.push(...[[230, 80, 60], [60, 160, 230], [250, 200, 40], [70, 190, 110]][q])
    }
    rows.push(Buffer.from(row))
  }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))])
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The hub's avatar routes: GET serves `hub.pic` (404 when null), PUT stores, DELETE clears. */
function fakeHub(p, hub) {
  p.on('request', async (req) => {
    if (!new URL(req.url()).pathname.endsWith('/api/v1/auth/avatar')) return req.continue()
    const m = req.method()
    if (m === 'OPTIONS') return req.respond({ status: 204 })
    if (m === 'GET') {
      return hub.pic ? req.respond({ status: 200, contentType: 'image/png', body: hub.pic }) : req.respond({ status: 404, body: '' })
    }
    if (m === 'PUT') {
      hub.puts.push({ type: req.headers()['content-type'] })
      if (hub.putStatus !== 204) return req.respond({ status: hub.putStatus, body: '' })
      hub.pic = hub.upload
      return req.respond({ status: 204 })
    }
    if (m === 'DELETE') {
      hub.deletes++
      hub.pic = null
      return req.respond({ status: 204 })
    }
    return req.continue()
  })
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', iat: 1759800000 })
  return true
})

const shown = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  const r = el.getBoundingClientRect()
  const cs = getComputedStyle(el)
  return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
}, sel)
const triggerPic = (p) => p.evaluate(() => document.querySelector('[data-test=user-menu-trigger] img[data-test=user-menu-picture]')?.getAttribute('src')?.slice(0, 22) || '')

async function waitFor(fn, ms = 5000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await fn()) return true
    await sleep(100)
  }
  return false
}

async function openMenu(p) {
  if (!(await shown(p, '[data-test=user-menu-panel]'))) await p.click('[data-test=user-menu-trigger]')
  await waitFor(() => shown(p, '[data-test=user-menu-change-picture]'))
}

async function run(p, base, width, height, files) {
  const tag = `${width}px`
  const touch = width < 821
  const hub = { pic: null, upload: files.bytes, puts: [], deletes: 0, putStatus: 204 }
  const page = await p.browser().newPage()
  await page.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await page.setRequestInterception(true)
  fakeHub(page, hub)
  await page.goto(`${base}/lobby`, { waitUntil: 'load' })
  await page.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(page))) throw new Error('no session store')
  await page.waitForSelector('[data-test=user-menu-trigger]')
  await sleep(400)

  await openMenu(page)
  check(`${tag}: the menu offers "Change picture"`, await shown(page, '[data-test=user-menu-change-picture]'))
  check(`${tag}: CONTROL no picture -> no "Remove picture"`, !(await shown(page, '[data-test=user-menu-remove-picture]')))
  if (SHOT_DIR) await page.screenshot({ path: join(SHOT_DIR, `own-picture-menu-${width}.png`) })

  // CONTROL: a gif never reaches the hub, and says why.
  const input = await page.$('[data-test=user-menu-picture-input]')
  await input.uploadFile(files.gif)
  check(`${tag}: CONTROL a gif is refused with a message, no PUT`,
    await waitFor(() => shown(page, '[data-test=user-menu-picture-error]')) && hub.puts.length === 0, { puts: hub.puts.length })

  // CONTROL: the hub says too big -> message, avatar unchanged.
  hub.putStatus = 413
  await input.uploadFile(files.png)
  await waitFor(async () => hub.puts.length === 1)
  await sleep(200)
  const big = await page.$eval('[data-test=user-menu-picture-error]', (e) => e.textContent.trim()).catch(() => '')
  check(`${tag}: CONTROL a 413 shows "too big" and keeps the avatar`, /256/.test(big) && !(await triggerPic(page)), { big })
  hub.putStatus = 204

  // The item opens the picker; the picked png is PUT and shows at once.
  const [chooser] = await Promise.all([page.waitForFileChooser({ timeout: 5000 }), page.click('[data-test=user-menu-change-picture]')])
  await chooser.accept([files.png])
  const changed = await waitFor(async () => (await triggerPic(page)).startsWith('data:image/png'))
  check(`${tag}: the item opens the picker; the png is PUT as image/png`, hub.puts.length === 2 && hub.puts[1].type === 'image/png', hub.puts)
  check(`${tag}: the new picture shows in the avatar at once, the menu closed`, changed && !(await shown(page, '[data-test=user-menu-panel]')))
  await openMenu(page)
  check(`${tag}: now "Remove picture" is offered`, await shown(page, '[data-test=user-menu-remove-picture]'))
  if (SHOT_DIR) await page.screenshot({ path: join(SHOT_DIR, `own-picture-changed-${width}.png`) })

  await page.reload({ waitUntil: 'load' })
  await page.waitForSelector('[data-test=top-bar]')
  await signIn(page)
  const kept = await waitFor(async () => (await triggerPic(page)).startsWith('data:image/png'))
  check(`${tag}: after a reload the menu still fetches the upload`, kept)
  await openMenu(page)
  check(`${tag}: after a reload "Remove picture" is still offered`, await shown(page, '[data-test=user-menu-remove-picture]'))

  await page.click('[data-test=user-menu-remove-picture]')
  const gone = await waitFor(async () => !(await triggerPic(page)))
  check(`${tag}: "Remove picture" DELETEs and the avatar falls back`, gone && hub.deletes === 1, { deletes: hub.deletes })
  await page.close()
}

const dir = mkdtempSync(join(tmpdir(), 'own-picture-'))
const bytes = png()
const files = { bytes, png: join(dir, 'me.png'), gif: join(dir, 'me.gif') }
writeFileSync(files.png, bytes)
writeFileSync(files.gif, Buffer.concat([Buffer.from('GIF89a'), Buffer.alloc(64)]))

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  await run(p, server.base, 1440, 900, files)
  await run(p, server.base, 390, 844, files)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nown-picture: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
