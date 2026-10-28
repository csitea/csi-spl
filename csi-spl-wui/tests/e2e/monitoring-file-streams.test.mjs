// Spec 160 3.5 (SPL-3888, row B5): Monitoring -> File streams in a real
// browser against the mock bundle (monitoring-file-streams.mjs: box-a app
// grows one line per poll, cron, box-b web missing):
//   C19 pick box and file; a line the stub appends shows within 2 polls;
//       Pause sends 0 requests in 10 s; Resume shows "N new lines";
//   C20 scrolling up turns Follow off; "Jump to latest" turns it on;
//   C21 a search hit (?seq=) opens the view at that line, Follow off;
//   C18 a developer reaching the URL sees one line, no view.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-file-streams
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const POLL_MS = 3000
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: { width: 1280, height: 800 }, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const BIZ = { role: 'biz_owner', permissions: ['members.invite', 'members.roles', 'tenant.settings'] }
const DEV = { role: 'developer', permissions: ['topics.read', 'notes.send'] }
const lastSeq = (p) => p.$$eval('[data-test=fs-line]', (xs) => (xs.length ? Number(xs[xs.length - 1].getAttribute('data-seq')) : 0))
const checked = (p) => p.$eval('[data-test=fs-follow]', (x) => x.checked)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((biz) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Owner', email: 'owner@example.com', t: 'mock' }))
    localStorage.setItem('spool.mock.me', JSON.stringify(biz))
  }, BIZ)

  // C19 pick: the first box and its first file, then cron, in the URL
  await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-line]', { visible: true, timeout: 20000 }).catch(() => null)
  const pick0 = await p.evaluate(() => [document.querySelector('[data-test=fs-box]')?.value, document.querySelector('[data-test=fs-file]')?.value])
  ok('C19 the first box and file are picked, lines show', pick0[0] === 'box-a' && pick0[1] === 'app' && (await lastSeq(p)) > 0, pick0)
  await p.select('[data-test=fs-file]', 'cron')
  await p.waitForFunction(() => location.search.includes('stream=cron'), { timeout: 10000 }).catch(() => null)
  ok('C19 the pick is in the URL', (await p.evaluate(() => location.search)).includes('stream=cron'))
  await p.select('[data-test=fs-file]', 'app')
  await p.waitForFunction(() => location.search.includes('stream=app'), { timeout: 10000 }).catch(() => null)
  await sleep(500)

  // C19 a line the stub appends shows within 2 polls, Follow on
  const s0 = await lastSeq(p)
  await sleep(2 * POLL_MS + 500)
  const s1 = await lastSeq(p)
  ok('C19 a new line shows within 2 polls, Follow on', s1 > s0 && (await checked(p)), { s0, s1 })

  // C19 Pause: the mock answers in the page (no network to count), and it
  // appends one line per poll, so a poll during 10 s of Pause would add >= 3
  // lines: the view must gain none. Resume: "N new lines".
  await p.click('[data-test=fs-pause]')
  const frozen = await lastSeq(p)
  await sleep(10000)
  const during = await lastSeq(p)
  ok('C19 Pause: no poll in 10 s, the view gains no line', during === frozen, { frozen, during })
  await p.click('[data-test=fs-pause]')
  await p.waitForSelector('[data-test=fs-new]', { visible: true, timeout: 10000 }).catch(() => null)
  const note = await p.$eval('[data-test=fs-new]', (x) => x.textContent || '').catch(() => '')
  ok('C19 Resume shows "N new lines"', /\b[1-9]\d* new lines?\b/.test(note) && (await lastSeq(p)) > frozen, { note })

  // C20 scrolling up turns Follow off; Jump to latest turns it on
  await p.$eval('[data-test=fs-view]', (v) => { v.scrollTop = 0; v.dispatchEvent(new Event('scroll')) })
  await sleep(200)
  const offAfterScroll = !(await checked(p))
  await p.click('[data-test=fs-jump]')
  await sleep(300)
  const bottom = await p.$eval('[data-test=fs-view]', (v) => v.scrollTop + v.clientHeight >= v.scrollHeight - 8)
  ok('C20 scrolling up turns Follow off; Jump to latest turns it on at the bottom', offAfterScroll && (await checked(p)) && bottom, { offAfterScroll, bottom })

  // C21 a search hit opens the view at that line, Follow off
  await p.goto(server.base + '/monitoring/file-streams?box=box-a&stream=app&seq=30', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-line][data-seq="30"]', { visible: true, timeout: 20000 }).catch(() => null)
  const hit = await p.evaluate(() => {
    const v = document.querySelector('[data-test=fs-view]')
    const row = document.querySelector('[data-test=fs-line][data-seq="30"]')
    if (!v || !row) return null
    const a = v.getBoundingClientRect()
    const b = row.getBoundingClientRect()
    return { inView: b.top >= a.top && b.bottom <= a.bottom, hit: row.classList.contains('fs-hit') }
  })
  ok('C21 a hit opens at that line, marked, Follow off', Boolean(hit && hit.inView && hit.hit) && !(await checked(p)), hit)

  // C18 a developer reaching the URL: one line, no view
  await p.evaluate((dev) => localStorage.setItem('spool.mock.me', JSON.stringify(dev)), DEV)
  await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-forbidden]', { timeout: 15000 }).catch(() => null)
  ok('C18 a developer sees one line and no view', Boolean(await p.$('[data-test=fs-forbidden]')) && !(await p.$('[data-test=fs-view]')))
  await p.evaluate(() => localStorage.removeItem('spool.mock.me'))

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmonitoring-file-streams: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
