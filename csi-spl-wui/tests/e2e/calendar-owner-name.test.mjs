// SPL-5889 (owner, csitea t1 12ccd587, screenshot of /calendar?v=3day): the
// event pop-over named the event's owner "HUM-10". A human reads as their
// first and last name (the roster's display name), the id only when no name
// is known, and in the title.
//
// The fixture: two stored events in the mock workspace (localStorage, as in
// calendar-synced), one owned by HUM-10, one by HUM-9; the people store
// (useHumanNames, useState 'spool.human-names') names only HUM-10
// "FirstName LastName".
//
//   1 the 3-day view: HUM-10's event pop-over shows "FirstName LastName",
//     the id kept in the title
//   2 CONTROL: HUM-9 has no name, so its pop-over shows the id
//
// Before SPL-5889 step 1 FAILS: the owner line read "HUM-10".
//
// Run:
//   pnpm run test:e2e calendar-owner-name
//   BASE_URL=<generated mock bundle> SHOT_DIR=<dir> pnpm run test:e2e calendar-owner-name
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

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

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-owner-name-${name}.png`) })
}

const ADDED_KEY = 'spool.mock.calendar-added'
const NAMED = '00000000-0000-4000-8000-000000005889'
const NAMELESS = '00000000-0000-4000-8000-000000005890'
const NAMES = { 'HUM-10': 'FirstName LastName' }
const today = E2E_TODAY
const event = (id, title, hour, owner) => ({
  id, source: 'event', title, description: '', kind: 'meeting',
  starts_at: `${today}T${hour}:00:00Z`, ends_at: `${today}T${hour}:30:00Z`, all_day: false, audience: 'internal', mentions: [],
  creator_type: 'human', creator_id: owner, remind_at: '', topic_id: '', release_version: '', issue_key: '',
  created_at: `${today}T00:00:00Z`, updated_at: `${today}T00:00:00Z`, time_zone: 'UTC', location: '', color: '', reminders: [],
  issue_keys: [], owner_id: owner,
})
const fixture = [event(NAMED, 'Daily Scrum', '13', 'HUM-10'), event(NAMELESS, 'Planning', '15', 'HUM-9')]
const ITEM = (id) => `[data-test=calendar-item][data-id="${id}"]`
const POP = '[data-test=calendar-event-popover]'

/** The people store as useHumanNames reads it (as names-not-ids.test.mjs). */
const setNames = (p, names) => p.evaluate((n) => {
  const app = document.querySelector('#__nuxt')?.__vue_app__
  const nuxt = app && (app.$nuxt || app.config.globalProperties.$nuxt)
  if (!nuxt || !nuxt.payload || !nuxt.payload.state) return false
  nuxt.payload.state['$sspool.human-names'] = n
  return true
}, names)
const seen = (p, sel) => p.waitForSelector(sel, { timeout: 8000 }).then(() => true, () => false)
const owner = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-test=calendar-popover-owner] .human-name')
  return { text: (el?.textContent || '').trim(), title: el?.getAttribute('title') || '' }
})

const server = await startServer()
const browser = await launch()
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await pinClock(p)
  const vp = { width: 1440, height: 900 }
  await setPageViewport(p, vp)
  await p.evaluateOnNewDocument((k, evs) => {
    if (!localStorage.getItem(k)) localStorage.setItem(k, JSON.stringify(evs))
  }, ADDED_KEY, fixture)
  await p.goto(`${server.base}/calendar?v=3day&d=${today}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  ok('0 the names are in the people store', await setNames(p, NAMES))

  console.log('-- 1 a named member owns the event')
  ok('the fixture event is in the 3-day view', await seen(p, ITEM(NAMED)))
  await p.click(ITEM(NAMED))
  ok('a click opens its pop-over', await seen(p, `${POP}[data-id="${NAMED}"]`))
  const named = await owner(p)
  ok('the owner reads "FirstName LastName", not HUM-10', named.text === 'FirstName LastName', named)
  ok('the id stays in the title', named.title === 'FirstName LastName · HUM-10', named)
  await shot(p, 'named')
  await p.keyboard.press('Escape')
  await p.waitForSelector(POP, { hidden: true, timeout: 8000 }).catch(() => {})

  console.log('-- 2 CONTROL: a member with no name keeps the id')
  await p.click(ITEM(NAMELESS))
  ok('a click opens its pop-over', await seen(p, `${POP}[data-id="${NAMELESS}"]`))
  const nameless = await owner(p)
  ok('the owner reads HUM-9', nameless.text === 'HUM-9' && nameless.title === 'HUM-9', nameless)
  await shot(p, 'nameless')
  await ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-owner-name: ${failed} FAILED` : `calendar-owner-name: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
