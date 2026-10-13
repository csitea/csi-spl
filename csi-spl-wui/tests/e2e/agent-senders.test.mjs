// SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa): Workspace
// settings -> Agents -> "Who may message each agent". On the mock bundle: a
// seated agent reads "Every member" (decision 2: no list); an admin ticks one
// member and saves, the row says so and keeps it after a reload of the pane;
// unticking every member reads "Nobody" (an empty list is not "everyone");
// "Every member" drops the list again. The hub's refusal of a send is proved
// in the hub tests and live on dev (the mock bundle has no socket).
//
// Control: before SPL-1018 the Agents page has no [data-test=tenant-agent-senders].
//
// Run:
//   pnpm run test:e2e agent-senders
//   BASE_URL=<generated bundle> pnpm run test:e2e agent-senders
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

/* spec 061 FR-004: the mock ids are legacy; pin the agent-id clock before LEGACY_ID_UNTIL */
const pinAgentIdClock = (p) => p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
const firstRow = '[data-test=tenant-sender-row]'
/* a phone keeps fixed bars at the edges: bring the control to the middle, then tap it */
async function tap(p, sel) {
  const el = await p.waitForSelector(sel, { visible: true, timeout: 5000 })
  await el.evaluate((x) => x.scrollIntoView({ block: 'center' }))
  await el.click()
}
const state = (p) => p.$eval(`${firstRow} [data-test=tenant-sender-state]`, (el) => (el.textContent || '').trim()).catch(() => '')
const waitState = async (p, want) => {
  await p.waitForFunction((sel, w) => (document.querySelector(sel)?.textContent || '').trim() === w, { timeout: 5000 },
    `${firstRow} [data-test=tenant-sender-state]`, want).catch(() => {})
  return state(p)
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ name: '1280', width: 1280, height: 900, mobile: false }, { name: '390', width: 390, height: 800, mobile: true }]) {
    console.log(`-- ${vp.name}`)
    const p = await browser.newPage()
    await pinAgentIdClock(p)
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    await p.goto(server.base + '/tenant-settings/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const pane = await p.waitForSelector('[data-test=tenant-agent-senders] ' + firstRow, { timeout: 15000 }).catch(() => null)
    ok('the Agents page carries who may message each agent', Boolean(pane))
    if (!pane) { await p.close(); continue }
    ok('no list reads as every member', (await state(p)) === 'Every member', await state(p))

    await tap(p, `${firstRow} [data-test=tenant-sender-edit]`)
    await p.waitForSelector('[data-test=tenant-sender-form]', { timeout: 5000 })
    await tap(p, '[data-test=tenant-sender-mode-list]')
    const member = await p.waitForSelector('[data-test=tenant-sender-member] input', { timeout: 5000 }).catch(() => null)
    ok('the list offers the workspace members', Boolean(member))
    ok('none ticked says nobody may message it', Boolean(await p.$('[data-test=tenant-sender-none]')))
    if (member) await tap(p, '[data-test=tenant-sender-member] input')
    await tap(p, '[data-test=tenant-sender-save]')
    ok('one member ticked and saved', (await waitState(p, 'Members allowed: 1')) === 'Members allowed: 1', await state(p))

    await tap(p, `${firstRow} [data-test=tenant-sender-edit]`)
    await p.waitForSelector('[data-test=tenant-sender-member] input', { timeout: 5000 })
    const ticked = await p.$$eval('[data-test=tenant-sender-member] input', (xs) => xs.filter((x) => x.checked).length)
    ok('editing again shows the saved member ticked', ticked === 1, ticked)
    await tap(p, '[data-test=tenant-sender-member] input:checked')
    await tap(p, '[data-test=tenant-sender-save]')
    ok('an empty list reads as nobody, not everyone', (await waitState(p, 'Nobody')) === 'Nobody', await state(p))

    await tap(p, `${firstRow} [data-test=tenant-sender-edit]`)
    await p.waitForSelector('[data-test=tenant-sender-mode-all]', { timeout: 5000 })
    await tap(p, '[data-test=tenant-sender-mode-all]')
    await tap(p, '[data-test=tenant-sender-save]')
    ok('every member drops the list', (await waitState(p, 'Every member')) === 'Every member', await state(p))

    const sw = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
    ok('no sideways scroll', sw)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `agent-senders: ${failed} FAILED` : `agent-senders: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
