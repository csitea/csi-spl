// Spec 112 WUI-3 (5.3 (a), 6, 12.6): the workspace filter, the goal rows and
// the goal page, on the mock bundle. The goal events are the mock's synced-
// event fixtures (src/utils/roadmap-goals-mock.mjs): workspace `demo` (A)
// with G01 (deadline in 40 days, a milestone today, specs 112 and 089) and
// G02, and workspace `beta-ws` (B) with a private G01. roadmap.json is a
// fixture served in place of the build's copy.
//   - signed in as a member of A only: the filter lists A, the goal rows
//     show share-done and mean pct, "its specs" sets ?goal= and keeps that
//     goal's spec rows, ?when=week adds a goal's specs (5.3 (a)), the goal
//     page shows countdown, approval, done-lines, specs and calendar links.
//     CONTROL: workspace B never appears in the filter; /roadmap?ws=beta-ws
//     reads "not available" and no B goal text reaches the page.
//   - signed out: CONTROL: an `internal` roadmap shows no goal row (and the
//     goal page "not found"); a `public` one shows its goal rows.
//   - desktop and <= 820 px (each goal row a card), no sideways scroll.
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e roadmap-goals
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { MOCK_SESSION_KEY, MOCK_SIGNED_OUT_KEY } from '../../src/utils/act-as-mock.mjs'
import { MOCK_ROADMAP_PUBLIC_KEY } from '../../src/utils/roadmap-goals-mock.mjs'

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

const DAY = 86400000
const FIXTURE = {
  sha: '0123456789abcdef0123456789abcdef01234567',
  rule: 'spec 112 5.1',
  specs: [
    { id: '001-fixture-b', title: 'Fixture: B\'s spec', state: 'planned', x: 0, p: 0, o: 2, pct: 0, tasks_changed: '' },
    { id: '027-fixture-g02', title: 'Fixture: G02 spec', state: 'in-progress', x: 1, p: 0, o: 1, pct: 50, tasks_changed: new Date(Date.now() - 90 * DAY).toISOString() },
    { id: '050-fixture-now', title: 'Fixture: changed now', state: 'planned', x: 0, p: 0, o: 1, pct: 0, tasks_changed: new Date().toISOString() },
    { id: '089-fixture-done', title: 'Fixture: G01 done', state: 'done', x: 4, p: 0, o: 0, pct: 100, tasks_changed: new Date(Date.now() - 90 * DAY).toISOString() },
    { id: '112-fixture-g01', title: 'Fixture: G01 in progress', state: 'in-progress', x: 2, p: 1, o: 2, pct: 40, tasks_changed: '' },
  ],
}
const MEMBER_A = { hum: 'HUM-1', name: 'Mock Member', email: 'member@example.org', t: 'demo', tenants: [{ tenant_id: 'demo', name: 'Demo' }] }
const B_TEXT = 'Workspace B private goal'

/** A page in its own context: roadmap.json is the fixture; `who` sets the mock session. */
async function open(browser, path, { width, height, who, publicWs = [] }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  await p.evaluateOnNewDocument((sk, ok, pk, w, pub) => {
    try {
      if (w === 'out') localStorage.setItem(ok, 'true')
      else localStorage.setItem(sk, JSON.stringify(w))
      localStorage.setItem(pk, JSON.stringify(pub))
    } catch { /* no storage: the checks below fail */ }
  }, MOCK_SESSION_KEY, MOCK_SIGNED_OUT_KEY, MOCK_ROADMAP_PUBLIC_KEY, who, publicWs)
  await p.setRequestInterception(true)
  p.on('request', (r) => (new URL(r.url()).pathname === '/roadmap.json'
    ? r.respond({ status: 200, contentType: 'application/json', body: JSON.stringify(FIXTURE) })
    : r.continue()))
  await go(p, path)
  return { ctx, p }
}

async function go(p, path) {
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}

const settled = (p, sel) => p.waitForFunction((s) => {
  const el = document.querySelector(s)
  return el && el.getAttribute('data-state') !== 'loading'
}, { timeout: 20000 }, sel).then(() => true, () => false)
const goalSettled = (p) => settled(p, '[data-test=roadmap-goals]')
const goalIds = (p) => p.$$eval('[data-test=roadmap-goal-row]', (els) => els.map((e) => e.getAttribute('data-goal')))
const wsOptions = (p) => p.$$eval('[data-test=roadmap-ws-option]', (els) => els.map((e) => e.getAttribute('data-ws')))
const specIds = (p) => p.$$eval('[data-test=roadmap-spec-row]', (els) => els.map((e) => e.getAttribute('data-spec').slice(0, 3)))
const waitSpecs = (p, want) => p.waitForFunction((w) => [...document.querySelectorAll('[data-test=roadmap-spec-row]')].map((e) => e.getAttribute('data-spec').slice(0, 3)).join(',') === w, { timeout: 15000 }, want).then(() => true, () => false)
const noSideways = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `roadmap-goals-${name}.png`) })
}

const server = await startServer()
const browser = await launch()
try {
  for (const [label, size] of [['desktop', { width: 1280, height: 800 }], ['phone', { width: 390, height: 844 }]]) {
    console.log(`-- ${label}: signed in, a member of A only`)
    {
      const { ctx, p } = await open(browser, '/roadmap', { ...size, who: MEMBER_A })
      ok('the goal part settles ready on A', await goalSettled(p) && await p.$eval('[data-test=roadmap-goals]', (el) => [el.dataset.state, el.dataset.ws].join()) === 'ready,demo')
      const opts = await wsOptions(p)
      ok('the filter lists A', JSON.stringify(opts) === '["demo"]', opts)
      ok('CONTROL: workspace B never appears in the filter', !opts.includes('beta-ws'), opts)
      const ids = await goalIds(p)
      ok('one goal row per goal of A', JSON.stringify(ids) === '["G01","G02"]', ids)
      const g1 = await p.$eval('[data-goal=G01]', (el) => ({
        share: el.querySelector('[data-test=roadmap-goal-share]')?.textContent.replace(/\s+/g, ' ').trim(),
        mean: el.querySelector('[data-test=roadmap-goal-mean]')?.textContent.trim(),
        left: el.querySelector('[data-test=roadmap-goal-countdown]')?.textContent.trim(),
        approval: el.querySelector('[data-test=roadmap-goal-approval]')?.textContent.trim(),
      })).catch(() => null)
      ok('G01: share-done 50% (1 of 2), mean pct 70%', g1?.share === '50% 1 of 2' && g1?.mean === '70%', g1)
      ok('G01: a countdown and the approval state', /^in \d+ days$/.test(g1?.left || '') && g1?.approval === 'Approved', g1)
      const all = await specIds(p)
      ok('every spec row shows with no filter', all.length === FIXTURE.specs.length, all)

      await p.click('[data-goal=G01] [data-test=roadmap-goal-specs]')
      ok('"its specs" keeps G01\'s spec rows', await waitSpecs(p, '089,112'), await specIds(p))
      ok('the goal filter is in the URL', new URL(p.url()).searchParams.get('goal') === 'G01', p.url())
      ok('the G01 row is marked', await p.$eval('[data-goal=G01]', (el) => el.classList.contains('roadmap-goals__row--focus')).catch(() => false))

      await go(p, '/roadmap?ws=demo&when=week')
      await goalSettled(p)
      ok('?when=week: the row changed now plus G01\'s specs (milestone today, 5.3 (a))', await waitSpecs(p, '050,089,112'), await specIds(p))

      const display = await p.$eval('[data-test=roadmap-goal-row]', (el) => getComputedStyle(el).display).catch(() => '')
      if (size.width <= 820) ok('<= 820 px: each goal row is a card', display === 'block', display)
      else ok('desktop: goal rows are table rows', display === 'table-row', display)
      ok('no sideways scroll', (await noSideways(p)) <= 0)
      await shot(p, `member-${label}`)

      await go(p, '/roadmap?ws=beta-ws')
      await goalSettled(p)
      ok('CONTROL: ?ws=beta-ws reads "not available"', Boolean(await p.$('[data-test=roadmap-goal-blocked]')))
      const opts2 = await wsOptions(p)
      ok('CONTROL: B is still not in the filter', !opts2.includes('beta-ws'), opts2)
      const body = await p.evaluate(() => document.body.innerText)
      ok('CONTROL: no B goal text reaches the page', !body.includes(B_TEXT))

      console.log(`-- ${label}: the goal page`)
      await go(p, '/goals/G01?ws=demo')
      await p.waitForSelector('[data-test=goal-approval]', { timeout: 20000 }).catch(() => null)
      const page = await p.evaluate(() => ({
        heading: document.querySelector('[data-test=goal-heading]')?.textContent.trim(),
        left: document.querySelector('[data-test=goal-countdown]')?.textContent.trim(),
        approval: document.querySelector('[data-test=goal-approval]')?.textContent.trim(),
        lines: document.querySelectorAll('[data-test=goal-done-line]').length,
        specs: [...document.querySelectorAll('[data-test=goal-spec]')].map((e) => e.getAttribute('data-spec')),
        pcts: [...document.querySelectorAll('[data-test=goal-spec-pct]')].map((e) => e.textContent.trim()),
        share: document.querySelector('[data-test=goal-share]')?.textContent.replace(/\s+/g, ' ').trim(),
        mean: document.querySelector('[data-test=goal-mean]')?.textContent.trim(),
        cal: document.querySelector('[data-test=goal-calendar-link]')?.getAttribute('href') || '',
        milestones: document.querySelectorAll('[data-test=goal-milestone]').length,
      }))
      ok('the goal page: heading, countdown, approval', page.heading === 'G01 Every workspace has its roadmap' && /^in \d+ days$/.test(page.left || '') && page.approval === 'Approved', page)
      ok('the goal page: done-lines, linked specs with pct', page.lines === 2 && JSON.stringify(page.specs) === '["112","089"]' && JSON.stringify(page.pcts) === '["40%","100%"]', page)
      ok('the goal page: share-done and mean pct', page.share === '50% 1 of 2' && page.mean === '70%', page)
      ok('the goal page: a calendar link /calendar?d=&event= and the milestone', /\/calendar\?d=\d{4}-\d{2}-\d{2}&event=00000000-0000-4000-8000-000000011201$/.test(page.cal) && page.milestones === 1, page)
      ok('the goal page: no sideways scroll', (await noSideways(p)) <= 0)
      await shot(p, `goal-${label}`)
      await go(p, '/goals/G01?ws=beta-ws')
      await p.waitForSelector('[data-test=goal-approval],[data-test=goal-not-found]', { timeout: 20000 }).catch(() => null)
      const b = await p.evaluate(() => document.body.innerText)
      ok('CONTROL: /goals/G01?ws=beta-ws shows A\'s G01, never B\'s', !b.includes(B_TEXT))
      await ctx.close()
    }

    console.log(`-- ${label}: signed out, A's roadmap internal`)
    {
      const { ctx, p } = await open(browser, '/roadmap', { ...size, who: 'out' })
      ok('the goal part settles', await goalSettled(p))
      ok('CONTROL: an internal roadmap shows no goal row', (await goalIds(p)).length === 0, await goalIds(p))
      ok('and no workspace in the filter', (await wsOptions(p)).length === 0)
      ok('the spec rows still show', (await specIds(p)).length === FIXTURE.specs.length)
      await go(p, '/goals/G01')
      ok('the goal page reads not found', Boolean(await p.waitForSelector('[data-test=goal-not-found]', { timeout: 20000 }).catch(() => null)))
      await ctx.close()
    }

    console.log(`-- ${label}: signed out, A's roadmap public`)
    {
      const { ctx, p } = await open(browser, '/roadmap', { ...size, who: 'out', publicWs: ['demo'] })
      await goalSettled(p)
      await p.waitForSelector('[data-test=roadmap-goal-row]', { timeout: 15000 }).catch(() => null)
      ok('a public roadmap shows its goal rows', JSON.stringify(await goalIds(p)) === '["G01","G02"]', await goalIds(p))
      ok('the filter lists the host workspace only', JSON.stringify(await wsOptions(p)) === '["demo"]', await wsOptions(p))
      ok('no sideways scroll', (await noSideways(p)) <= 0)
      await shot(p, `public-${label}`)
      await go(p, '/goals/G01?ws=demo')
      await p.waitForSelector('[data-test=goal-approval]', { timeout: 20000 }).catch(() => null)
      const out = await p.evaluate(() => ({ approval: Boolean(document.querySelector('[data-test=goal-approval]')), cal: Boolean(document.querySelector('[data-test=goal-calendar-link]')) }))
      ok('the goal page reads signed out, with no calendar link (the public read has no id)', out.approval && !out.cal, out)
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `roadmap-goals: ${failed} FAILED` : `roadmap-goals: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
