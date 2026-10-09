// HUM-10 (t1 ef57739c, a8e3d31d): the public calendar shows releases and
// feature posts and NO tenant calendar entry.
//
// A tenant event with audience `public` (the DB default: everyone in the
// workspace, not the internet) is seeded into the mock workspace, today. In a
// fresh browser context (no cookie, no sign-in):
//   - /public-calendar, on today's month and on a month with a mock release,
//     shows a release (as text, no /releases link) and never the tenant title
//   - /pub-cal/events.json, the page's only data, holds a release and not
//     the tenant title
//   - the page reads no tenant calendar API (/v1/calendar/*)
// Control: /calendar (the mock workspace, signed in) shows the same seeded
// title, so its absence above is the public view, not a seed that failed.
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e public-calendar
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const today = new Date().toISOString().slice(0, 10)
const TENANT_TITLE = 'Tenant-only board meeting 7f3c'
const SEED = [{
  id: '00000000-0000-4000-8000-0000000007f3',
  title: TENANT_TITLE,
  starts_at: `${today}T09:00:00Z`,
  ends_at: `${today}T10:00:00Z`,
  audience: 'public',
}]

/** A fresh context with the tenant event seeded in the mock workspace. */
async function seededPage(browser) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })
  await p.evaluateOnNewDocument((seed) => {
    try { localStorage.setItem('spool.mock.calendar-added', seed) } catch { /* none */ }
  }, JSON.stringify(SEED))
  const calendarApi = []
  p.on('request', (r) => { if (/\/v1\/calendar\//.test(r.url())) calendarApi.push(r.url()) })
  return { ctx, p, calendarApi }
}

const bodyText = (p) => p.evaluate(() => document.body.innerText)

async function openPublic(p, month) {
  await p.goto(`${server.base}/public-calendar${month ? `?m=${month}` : ''}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=public-calendar-heading]', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.waitForFunction(() => !document.querySelector('[data-test=public-calendar-loading]'), { timeout: NAV_TIMEOUT }).catch(() => {})
}

const server = await startServer()
const browser = await launch()
let failed = 0
try {
  const { ctx, p, calendarApi } = await seededPage(browser)

  const res = await p.goto(`${server.base}/pub-cal/events.json`, { waitUntil: 'load', timeout: NAV_TIMEOUT })
  const raw = res && res.ok() ? await res.text() : ''
  let events = []
  try { events = JSON.parse(raw).events || [] } catch { /* none */ }
  const release = events.find((e) => e.kind === 'release')
  ok('events.json holds a release', Boolean(release), release)
  ok('events.json holds no tenant title', raw !== '' && !raw.includes(TENANT_TITLE))

  await openPublic(p, '')
  ok('the public calendar renders', await p.$('[data-test=public-calendar]').then(Boolean))
  ok('today\'s month: no tenant title', !(await bodyText(p)).includes(TENANT_TITLE), await p.$eval('[data-test=public-calendar-month]', (e) => e.getAttribute('data-month')).catch(() => ''))
  await openPublic(p, today.slice(0, 7))
  ok('today\'s month (asked): no tenant title', !(await bodyText(p)).includes(TENANT_TITLE))

  const month = release ? release.day.slice(0, 7) : ''
  await openPublic(p, month)
  const rels = await p.$$eval('[data-test=public-calendar-release]', (as) => as.map((a) => ({ ref: a.getAttribute('data-ref'), href: a.getAttribute('href') })))
  ok('a release month shows releases', rels.length > 0 && rels.every((r) => /^v\d/.test(r.ref || '')), { month, n: rels.length, first: rels[0] })
  /* /releases/<ref> reads /v1/release-notes, which the hub refuses signed out */
  ok('no release links to the signed-in /releases page', rels.every((r) => r.href === null))
  ok('the release month: no tenant title', !(await bodyText(p)).includes(TENANT_TITLE))
  ok('no tenant calendar API was read', calendarApi.length === 0, calendarApi.slice(0, 3))

  /* control: the signed-in workspace calendar shows the seeded event */
  await p.goto(`${server.base}/calendar`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  const seen = await p.waitForFunction((t) => document.body.innerText.includes(t), { timeout: 15000 }, TENANT_TITLE).then(() => true, () => false)
  ok('control: the workspace calendar shows the tenant event', seen)
  await ctx.close()
} catch (e) {
  ok('suite ran', false, String(e && e.stack || e))
} finally {
  await browser.close()
  await server.stop()
}
failed = results.filter((r) => !r.ok).length
console.log(failed ? `\n${failed} FAILED` : '\nall passed')
process.exit(failed ? 1 : 0)
