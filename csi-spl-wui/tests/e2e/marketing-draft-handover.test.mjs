// Spec 090 T036 (SPL-4804): the customer's draft hand-over
// (MarketingDraftHandover.vue), proved in a REAL browser against the mock
// bundle (tenant-settings-mock.mjs: the post "Mock post two" with three
// same-origin pictures and a fourth the hub built on another origin; the
// Page "Mock Studio", channel mch-fb-1). At 1440 and at 390:
//   1. "Post by hand" on the Page's list opens the card with the five
//      platform badges and the post's own picture picked (1 of 4); the
//      other-origin photo is shown on this host's own /blog/img/ path (a
//      tenant host's CSP is img-src 'self');
//   2. RED CONTROL photo toggle: pick photo 3, un-pick photo 1, pick photo 2;
//      Download makes ONE ZIP holding photos 2 and 3 only (read back from
//      the downloaded file), the un-picked photo is not in it;
//   2b. one photo picked is downloaded directly, not as a ZIP;
//   2c. a photo whose fetch is blocked: the ZIP falls back to one download
//      per photo and says so;
//   3. RED CONTROL clipboard: hashtags typed, "Copy caption & hashtags"
//      shows the toast and the clipboard holds the full string (title,
//      summary, link, hashtags);
//   4. Viber's short version is at most 200 characters and ends with the link;
//      the four launch buttons carry the hub's links (Instagram, the Facebook
//      sharer, wa.me, viber://forward);
//   5. "Mark as posted by hand" records it (the mock's manual-publish) and the
//      post leaves the Page's list;
//   6. on the LinkedIn list (no channel, and the mock has no LinkedIn
//      account) the card opens without the Mark button;
//   7. no page errors.
//
// Plant the defect and watch it go red:
//   PROVE_RED=toggle node tests/e2e/marketing-draft-handover.test.mjs  (step 2: photo 1 is never un-picked)
//   PROVE_RED=copy node tests/e2e/marketing-draft-handover.test.mjs    (step 3: the clipboard keeps the first line only)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-draft-handover
// SHOT_DIR=<dir> writes marketing-draft-handover-<width>.png.
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const SHOT_DIR = process.env.SHOT_DIR || ''
const POST = '2026-10-13-mock-second'

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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const TOGGLE = '[data-test=tenant-marketing-toggle]'
const ACCOUNT = '[data-test=marketing-meta-account]'
const PAGE_PUB = '[data-test=tenant-marketing-publish][data-channel="mch-fb-1"]'
const LI_PUB = '[data-test=tenant-marketing-publish][data-channel=""]'
const CARD = '[data-test=marketing-draft-handover]'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function tap(p, sel) {
  await p.$eval(sel, (e) => e.scrollIntoView({ block: 'center' }))
  await p.click(sel)
}
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
// the toast's text as soon as it shows (it hides itself after 4 s), '' when it never does
const toastText = (p) => p.waitForFunction((s) => document.querySelector(s)?.textContent.trim() || false,
  { timeout: 8000 }, `${CARD} [data-test=handover-toast]`).then((h) => h.jsonValue()).catch(() => '')
const attr = (p, sel, a) => p.$eval(sel, (e, n) => e.getAttribute(n), a).catch(() => null)

// zipNames: the entry names of a ZIP file, from its central directory.
function zipNames(file) {
  const b = readFileSync(file)
  const end = b.length - 22
  if (b.readUInt32LE(end) !== 0x06054b50) return []
  const names = []
  let o = b.readUInt32LE(end + 16)
  for (let i = 0; i < b.readUInt16LE(end + 10); i++) {
    const n = b.readUInt16LE(o + 28)
    names.push(b.subarray(o + 46, o + 46 + n).toString('utf8'))
    o += 46 + n + b.readUInt16LE(o + 30) + b.readUInt16LE(o + 32)
  }
  return names
}

async function waitFile(dir, name, ms) {
  for (let t = 0; t < ms; t += 200) {
    if (readdirSync(dir).includes(name)) return join(dir, name)
    await sleep(200)
  }
  return ''
}

async function openCard(p, list, w) {
  await tap(p, `${list} [data-post="${POST}"] [data-test=marketing-handover-open]`)
  await p.waitForSelector(`${list} ${CARD} [data-test=handover-photo]`, { visible: true, timeout: 8000 }).catch(() => null)
  const badges = await p.$$eval(`${list} ${CARD} [data-test=handover-badge]`, (es) => es.map((e) => e.getAttribute('data-platform')))
  const photos = await p.$$eval(`${list} ${CARD} [data-test=handover-photo-check]`, (es) => es.map((e) => e.checked))
  const srcs = await p.$$eval(`${list} ${CARD} [data-test=handover-photo] img`, (es) => es.map((e) => e.getAttribute('src')))
  return { badges, photos, srcs, w }
}

async function photoSteps(p, w, dir) {
  const card = `${PAGE_PUB} ${CARD}`
  const check = (i) => `${card} [data-test=handover-photo]:nth-of-type(${i}) [data-test=handover-photo-check]`
  await tap(p, check(3))
  if (RED !== 'toggle') await tap(p, check(1))
  await tap(p, check(2))
  const count = await attr(p, `${card} [data-test=handover-photo-count]`, 'data-count')
  await tap(p, `${card} [data-test=handover-download]`)
  const zip = await waitFile(dir, `${POST}-photos.zip`, 8000)
  const names = zip ? zipNames(zip) : []
  ok(`2 ${w}px: RED CONTROL the ZIP holds the picked photos 2 and 3, never the un-picked one`, count === '2' &&
    names.join() === 'login-wallpaper.webp,spool-hub-emblem-560.webp', { count, names, zip: Boolean(zip) })
}

// after photoSteps photos 2 and 3 are picked: un-pick 3, one photo is a direct download
async function singleSteps(p, w, dir) {
  const card = `${PAGE_PUB} ${CARD}`
  await tap(p, `${card} [data-test=handover-photo]:nth-of-type(3) [data-test=handover-photo-check]`)
  const count = await attr(p, `${card} [data-test=handover-photo-count]`, 'data-count')
  await tap(p, `${card} [data-test=handover-download]`)
  const file = await waitFile(dir, 'login-wallpaper.webp', 8000)
  const pack = await attr(p, card, 'data-pack')
  ok(`2b ${w}px: one photo picked is downloaded directly, not as a ZIP`, count === '1' && Boolean(file) && pack === 'login-wallpaper.webp', { count, file: Boolean(file), pack })
}

// photos 1 and 4 picked, photo 4's fetch blocked (as a CSP would): each photo on its own, and an error
async function fallbackSteps(p, w, dir) {
  const card = `${PAGE_PUB} ${CARD}`
  const check = (i) => `${card} [data-test=handover-photo]:nth-of-type(${i}) [data-test=handover-photo-check]`
  await p.evaluate(() => {
    const real = globalThis.fetch.bind(globalThis)
    globalThis.fetch = (u, o) => (String(u).includes('mock-foreign') ? Promise.reject(new TypeError('Failed to fetch')) : real(u, o))
  })
  await tap(p, check(2))
  await tap(p, check(1))
  await tap(p, check(4))
  await tap(p, `${card} [data-test=handover-download]`)
  const file = await waitFile(dir, 'logo.webp', 8000)
  const pack = await attr(p, card, 'data-pack')
  const err = await text(p, `${card} [data-test=handover-error]`)
  const zip = readdirSync(dir).filter((f) => f.endsWith('.zip')).length
  ok(`2c ${w}px: a blocked photo fetch falls back to one download per photo and says so`, Boolean(file) && pack === 'logo.webp,mock-foreign.webp' &&
    err !== '' && zip === 1, { file: Boolean(file), pack, err, zip })
  await tap(p, check(1))
  await tap(p, check(4))
}

async function copySteps(p, w, base) {
  const card = `${PAGE_PUB} ${CARD}`
  if (RED === 'copy') await p.evaluate(() => { const real = navigator.clipboard.writeText.bind(navigator.clipboard); navigator.clipboard.writeText = (s) => real(s.split('\n')[0]) })
  await tap(p, `${card} [data-test=handover-hashtags]`)
  await p.type(`${card} [data-test=handover-hashtags]`, 'camp, #kids')
  await tap(p, `${card} [data-test=handover-copy]`)
  const toast = await toastText(p)
  const clip = await p.evaluate(() => navigator.clipboard.readText()).catch((e) => `read failed: ${e}`)
  const want = `Mock post two\n\nThe newer mock post.\n\n${base}/blog/${POST}\n\n#camp #kids`
  ok(`3 ${w}px: RED CONTROL the toast shows and the clipboard holds the full caption with hashtags`, toast === 'Caption copied!' && clip === want, { toast, clip })
}

async function linkSteps(p, w, base) {
  const card = `${PAGE_PUB} ${CARD}`
  const viber = await text(p, `${card} [data-test=handover-viber-text]`)
  const n = await attr(p, `${card} [data-test=handover-viber-count]`, 'data-count')
  ok(`4 ${w}px: Viber's short version is <= 200 characters and ends with the link`, Number(n) <= 200 && Array.from(viber).length === Number(n) &&
    viber.endsWith(`${base}/blog/${POST}`), { n, viber })
  const opens = await p.$$eval(`${card} [data-test=handover-open]`, (es) => es.map((e) => [e.getAttribute('data-app'), e.getAttribute('href')]))
  const pre = { instagram: 'https://www.instagram.com/', facebook: 'https://www.facebook.com/sharer/sharer.php?u=', whatsapp: 'https://wa.me/?text=', viber: 'viber://forward?text=' }
  ok(`4b ${w}px: the four launch buttons carry the hub's links`, opens.length === 4 && opens.every(([app, href]) => href.startsWith(pre[app])), opens)
}

async function markSteps(p, w) {
  await tap(p, `${PAGE_PUB} ${CARD} [data-test=handover-mark-posted]`)
  const toast = await toastText(p)
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 6000 }, `${PAGE_PUB} [data-post="${POST}"]`).catch(() => null)
  const left = await p.$$eval(`${PAGE_PUB} [data-test=tenant-marketing-publish-row]`, (es) => es.map((e) => e.getAttribute('data-post')))
  ok(`5 ${w}px: Mark as posted by hand records it and the post leaves the Page's list`, toast === 'Recorded as posted by hand.' &&
    left.join() === '2026-10-12-mock-first', { toast, left })
}

async function linkedInSteps(p, w) {
  const r = await openCard(p, LI_PUB, w)
  await sleep(500)
  const mark = Boolean(await p.$(`${LI_PUB} ${CARD} [data-test=handover-mark-posted]`))
  ok(`6 ${w}px: on the LinkedIn list (no LinkedIn account) the card opens without Mark`, r.photos.length === 4 && !mark, { ...r, mark })
}

async function run(browser, base, w) {
  const phone = w < 600
  const p = await browser.newPage()
  await p.setViewport({ width: w, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
  const dir = mkdtempSync(join(tmpdir(), 'handover-dl-'))
  const cdp = await p.target().createCDPSession()
  await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem('spool.mock.marketing.meta')
    localStorage.setItem('spool-theme', 'light')
  })
  await p.goto(base + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  if (!(await p.$eval(TOGGLE, (e) => e.checked).catch(() => true))) await tap(p, TOGGLE)
  await p.waitForSelector(ACCOUNT, { visible: true, timeout: 10000 }).catch(() => null)
  await tap(p, `${ACCOUNT}[data-channel="mch-fb-1"] [data-test=marketing-meta-publish-open]`)
  await p.waitForSelector(`${PAGE_PUB} [data-test=tenant-marketing-publish-row]`, { visible: true, timeout: 5000 }).catch(() => null)
  const r = await openCard(p, PAGE_PUB, w)
  ok(`1 ${w}px: the card shows the five badges and the post's own picture picked`, r.badges.join() === 'facebook,instagram,linkedin,viber,whatsapp' &&
    r.photos.join() === 'true,false,false,false', r)
  ok(`1b ${w}px: the other-origin photo is shown on this host's own /blog/img/ path`, r.srcs[3] === '/blog/img/mock-foreign.webp', r.srcs)
  await photoSteps(p, w, dir)
  await singleSteps(p, w, dir)
  await fallbackSteps(p, w, dir)
  await copySteps(p, w, base)
  await linkSteps(p, w, base)
  if (SHOT_DIR) {
    mkdirSync(SHOT_DIR, { recursive: true })
    await p.$eval(`${PAGE_PUB} ${CARD}`, (e) => e.scrollIntoView({ block: 'start' }))
    await p.screenshot({ path: `${SHOT_DIR}/marketing-draft-handover-${w}.png`, fullPage: true })
  }
  await markSteps(p, w)
  await linkedInSteps(p, w)
  ok(`7 ${w}px: no page errors`, errors.length === 0, errors)
  rmSync(dir, { recursive: true, force: true })
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await browser.defaultBrowserContext().overridePermissions(server.base, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  for (const w of [1440, 390]) await run(browser, server.base, w)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
