// The workspace marketing switch (spec 090 §15; owner HUM-10, t1 f0c3927e
// msg 37bcb88b item 4), proved in a REAL browser against the mock bundle
// (tenant-settings-mock.mjs: the mock workspace is allow-listed, its admin
// is HUM-1):
//   1. Tenant settings -> General shows the toggle to the admin, OFF by
//      default (owner msg 5cd2e544: nothing posts until an admin turns it on);
//   2. the admin turns it on, then off again;
//   P. SPL-1698, while it is on: the owner (the mock's member holds the
//      LinkedIn channel) sees the unshared live posts, each with a Publish
//      button; a 409 and a 403 answer show as plain messages, a publish
//      that goes out removes its row; switched off, the list is gone;
//   P6. SPL-1856: a member who is not the LinkedIn owner (the mock answers
//      403) sees one plain line under "Publish to LinkedIn", not a gap;
//   3. a workspace outside the cnf allow-list (the mock answers 404, as the
//      hub does) shows no toggle, but ONE line saying Marketing is not
//      available here (SPL-1856, owner msg d657f49d), at 1440 and at 390,
//      while General still renders.
// The hub half (403 for a non-admin, 404 off the allow-list) is
// TestMarketingSwitch in csi-spl-api/.../hub/marketing_switch_test.go.
//
// Plant the defect and watch step 3 go red (the unlisted flag is not set):
//   PROVE_RED=listed node tests/e2e/marketing-switch.test.mjs
// (SPL-1856's red control is the old components: steps P6 and 3 fail on them.)
// or step P2 (the mock answers 200 instead of 409):
//   PROVE_RED=recorded node tests/e2e/marketing-switch.test.mjs
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-switch
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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
const checked = (p) => p.$eval(TOGGLE, (e) => e.checked)
const PUB = '[data-test=tenant-marketing-publish]'
const PUB_ROW = '[data-test=tenant-marketing-publish-row]'
const PUB_BTN = '[data-test=tenant-marketing-publish-button]'
const rows = (p) => p.$$eval(PUB_ROW, (es) => es.map((e) => e.getAttribute('data-post')))
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const mockPublish = (p, v) => p.evaluate((x) => localStorage.setItem('spool.mock.marketing.publish', x), v)
// one Publish click; resolves once the buttons are enabled again
async function clickPublish(p) {
  await p.click(PUB_BTN)
  await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 5000 }, PUB_BTN).catch(() => null)
  await new Promise((r) => setTimeout(r, 200))
}

const UNAVAILABLE = '[data-test=tenant-marketing-unavailable]'
const PUB_UNAVAILABLE = '[data-test=tenant-marketing-publish-unavailable]'

// SPL-1856: switched on, a member who is not the LinkedIn owner (403) reads
// one line under "Publish to LinkedIn" instead of a silent gap
async function publishForbiddenSteps(p) {
  await mockPublish(p, 'forbidden')
  await p.click(TOGGLE)
  await p.waitForSelector(PUB_UNAVAILABLE, { visible: true, timeout: 5000 }).catch(() => null)
  const line = await text(p, PUB_UNAVAILABLE + ' p')
  ok('P6 a 403 on the list shows one line, no list', line === 'Only the workspace owner who connected LinkedIn can publish.' &&
    !(await p.$(PUB)) && !(await p.$(UNAVAILABLE)), { line })
  await mockPublish(p, '')
  await p.click(TOGGLE)
  await p.waitForFunction((s) => document.querySelector(s)?.checked === false && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE).catch(() => null)
  await new Promise((r) => setTimeout(r, 300))
  ok('P6b switched off, the line is gone too (the list 404 stays silent)', !(await p.$(PUB_UNAVAILABLE)) && !(await p.$(PUB)))
}

// SPL-1698: the owner's Publish to LinkedIn list, while marketing is on
async function publishSteps(p) {
  await p.waitForSelector(PUB_ROW, { visible: true, timeout: 5000 }).catch(() => null)
  const first = await rows(p)
  ok('P1 the owner sees the two unshared live posts, each with a Publish button', first.length === 2 && (await p.$$(PUB_BTN)).length === 2, first)
  // 409: the post is already published, or recorded for LinkedIn
  await mockPublish(p, RED === 'recorded' ? '' : 'recorded')
  await clickPublish(p)
  const conflict = await text(p, '[data-test=tenant-marketing-publish-error]')
  ok('P2 a 409 shows as a plain message and drops the row', conflict.includes('already published') && (await rows(p)).length === 1, { conflict })
  // 403: not the owner who connected LinkedIn
  await mockPublish(p, 'forbidden')
  await clickPublish(p)
  const forbidden = await text(p, '[data-test=tenant-marketing-publish-error]')
  ok('P3 a 403 shows as a plain message and keeps the row', forbidden.startsWith('Only the workspace owner') && (await rows(p)).length === 1, { forbidden })
  // CONTROL: the owner's publish goes out and the list empties
  await mockPublish(p, '')
  await clickPublish(p)
  const done = await text(p, '[data-test=tenant-marketing-publish-notice]')
  ok('P4 CONTROL: a publish that goes out shows it and removes the row', done === 'Published on LinkedIn.' && (await rows(p)).length === 0 &&
    Boolean(await p.$('[data-test=tenant-marketing-publish-empty]')) && !(await p.$('[data-test=tenant-marketing-publish-error]')), { done })
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // the mock is signed out by default: sign in as its admin (tenant-settings.test.mjs)
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.goto(server.base + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the admin of an allow-listed workspace sees the toggle, off
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const shown = Boolean(await p.$(TOGGLE))
  ok('1 General shows the marketing toggle to the admin, off by default', shown && !(await checked(p)), { shown })

  // 2. on, then off again
  if (shown) {
    await p.click(TOGGLE)
    await p.waitForFunction((s) => document.querySelector(s)?.checked === true && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE).catch(() => null)
    ok('2 the admin turns marketing on', await checked(p))
    await publishSteps(p)
    await p.click(TOGGLE)
    await p.waitForFunction((s) => document.querySelector(s)?.checked === false && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE).catch(() => null)
    ok('2b and off again', !(await checked(p)) && !(await p.$('[data-test=tenant-marketing-error]')))
    await new Promise((r) => setTimeout(r, 300))
    ok('P5 switched off, the Publish list is gone', !(await p.$(PUB)))
    await publishForbiddenSteps(p)
  }

  // 3. outside the allow-list: no toggle, one line saying why, General still renders
  if (RED !== 'listed') await p.evaluate(() => localStorage.setItem('spool.mock.marketing', 'unlisted'))
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    await p.setViewport({ width: w, height: h })
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=tenant-general-name]', { visible: true, timeout: NAV_TIMEOUT })
    await p.waitForSelector(UNAVAILABLE, { visible: true, timeout: 5000 }).catch(() => null)
    const line = await text(p, UNAVAILABLE + ' p')
    const lines = (await p.$$(UNAVAILABLE)).length + (await p.$$(PUB_UNAVAILABLE)).length
    ok(`3 ${w}px: off the allow-list, no toggle and one line says why`, !(await p.$('[data-test=tenant-settings-marketing]')) && !(await p.$(TOGGLE)) &&
      line === 'Marketing is not available in this workspace.' && lines === 1, { line, lines })
  }
  ok('4 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
